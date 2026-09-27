;;; utter-transient.el --- Transient menu for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `utter-menu' is utter's interface: every setting, input source,
;; output target and, while something plays, every playback control.
;; `utter--suffix-speak' is its single dispatch; `utter-speak' is the
;; same thing with default arguments.  The infix classes and the evil
;; region fix follow gptel-transient.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'utter)
(require 'utter-mode)

;;;; Engine symbols (defined by ENGINE and CORE)

(defvar utter-backend)
(defvar utter-model)
(defvar utter-voice)
(defvar utter-speed)
(defvar utter-format)
(defvar utter-language)
(defvar utter-instructions)
(defvar utter-highlight)
(defvar utter-playback-rate)
(defvar utter-expert-commands)
(defvar utter-log-level)
(defvar utter-input-functions)
(defvar utter--state-change-hook)
(defvar utter--set-scope)
(defvar utter--known-backends)
(defvar utter--known-presets)
(defvar utter--preset)

(declare-function utter-state "utter-queue" ())
(declare-function utter-active-p "utter-queue" ())
(declare-function utter-enqueue "utter" (text &rest params))
(declare-function utter-interrupt "utter" (text &rest params))
(declare-function utter-save-to-file "utter" (text file))
(declare-function utter--set-with-scope "utter" (sym value &optional scope))
(declare-function utter-get-preset "utter" (name))
(declare-function utter--apply-preset "utter" (preset &optional setter))
(declare-function utter-get-backend "utter-core" (name))
(declare-function utter--list-voices "utter-core" (backend callback))
(declare-function utter--inspect-text "utter" (text))
(declare-function utter--sanitize-settings "utter" (&optional backend setter skip))
(declare-function utter--preset-spec "utter" (preset))
(declare-function utter--preset-var "utter" (key))
(declare-function utter--input-candidate "utter" ())
(declare-function utter--blank-p "utter" (beg end))
(declare-function utter--text-at-point "utter" (&optional arg))
(declare-function utter--single-segment "utter" (text params))
(declare-function utter--snapshot-params "utter-queue" (params text))
(declare-function utter--estimate-seconds "utter-queue" (text speed))
(declare-function utter--short-name "utter-queue" (text))
(declare-function utter--static-voices "utter-core" (backend &optional model))
(declare-function utter--formats "utter-core" (backend &optional model))
(declare-function utter--capable-p "utter-core" (backend model capability))
(declare-function utter-backend-max-chars-unit "utter-core" (backend))
(declare-function utter-backend-name "utter-core" (backend))
(declare-function utter-backend-models "utter-core" (backend))
(declare-function utter-backend-capabilities "utter-core" (backend))
(declare-function utter-backend-max-chars "utter-core" (backend))
(declare-function evil-visual-expand-region "evil-states" (&optional exclude-newline))
(declare-function evil-visual-contract-region "evil-states" ())
(defvar evil-visual-region-expanded)

;;;; Backends, models and voices

(defun utter-transient--backend (backend)
  "Return the backend object for BACKEND, an object or a registered name."
  (if (stringp backend) (utter-get-backend backend) backend))

(defun utter-transient--source-buffer ()
  "Return the buffer the menu was opened from, else the current buffer."
  (if (buffer-live-p transient--original-buffer)
      transient--original-buffer
    (current-buffer)))

(defun utter-transient--original (symbol)
  "Return SYMBOL's value in the buffer the menu was opened from."
  (buffer-local-value symbol (utter-transient--source-buffer)))

(defun utter-transient--model-symbol (model)
  "Return the name symbol of MODEL, a symbol or (SYMBOL . PLIST)."
  (if (consp model) (car model) model))

(defun utter-transient--model-get (model prop)
  "Return PROP of MODEL, from its plist entry or its symbol properties."
  (if (consp model)
      (plist-get (cdr model) prop)
    (and (symbolp model) model (get model prop))))

(defun utter-transient--provider-string (backend model)
  "Return \"Backend:model\" for BACKEND and MODEL.
A nil MODEL shows BACKEND's first model; a backend without models
shows its name only."
  (let ((model (or model (utter-transient--model-symbol
                          (car (and backend (utter-backend-models backend)))))))
    (concat (if backend (utter-backend-name backend) "(no backend)")
            (and model (format ":%s" model)))))

(defun utter-transient--voice-name (voice)
  "Return the name of VOICE, a string or (NAME . INFO)."
  (if (consp voice) (car voice) voice))

(defun utter-transient--capable-p (capability)
  "Return non-nil if the menu's backend and model have CAPABILITY.
Both are read in the buffer the menu was opened from."
  (when-let* ((backend (utter-transient--backend
                        (utter-transient--original 'utter-backend))))
    (utter--capable-p backend
                      (or (utter-transient--original 'utter-model)
                          (utter-transient--model-symbol
                           (car (utter-backend-models backend))))
                      capability)))

(defconst utter-transient--capabilities
  '(instructions ssml timestamps stitching clone)
  "Capabilities that `utter-backend' documents, in display order.")

(defun utter-transient--model-capabilities (backend model)
  "Return the capabilities of MODEL on BACKEND, as core applies them.
MODEL is a symbol or (SYMBOL . PLIST)."
  (let ((name (utter-transient--model-symbol model)))
    (cl-remove-if-not
     (lambda (cap) (utter--capable-p backend name cap))
     (delete-dups
      (append utter-transient--capabilities
              (copy-sequence (utter-backend-capabilities backend))
              (copy-sequence (utter-transient--model-get model :capabilities)))))))

(defun utter-transient--max-chars-string (backend)
  "Return BACKEND's request limit with its unit, such as \"4096ch\", or nil."
  (when-let* ((max (utter-backend-max-chars backend)))
    (format "%d%s" max (pcase (utter-backend-max-chars-unit backend)
                         ('bytes "B") ('utf16 "u16") (_ "ch")))))

(defun utter-transient--provider-annotation (entry)
  "Return the annotation for provider ENTRY, (NAME BACKEND MODEL).
Shows description, capabilities, the request limit and price per
million characters; nil when none of them is known."
  (pcase-let* ((`(,_ ,backend ,model) entry)
               (desc (utter-transient--model-get model :description))
               (caps (utter-transient--model-capabilities backend model))
               (max-chars (utter-transient--max-chars-string backend))
               (cost (utter-transient--model-get model :cost)))
    (when (or desc caps max-chars cost)
      (concat
       (propertize " " 'display '(space :align-to 40))
       (truncate-string-to-width (or desc "") 40 nil ?\s t)
       (propertize " " 'display '(space :align-to 82))
       (truncate-string-to-width (if caps (mapconcat #'symbol-name caps " ") "")
                                 24 nil ?\s t)
       (propertize " " 'display '(space :align-to 108))
       (format "%8s" (or max-chars "--"))
       (propertize " " 'display '(space :align-to 118))
       (cond ((null cost) "")
             ((and (numberp cost) (zerop cost)) "free")
             (t (format "$%s/1M" cost)))))))

(defun utter-transient--read-provider (prompt &rest _)
  "Read a backend and model with PROMPT; return (BACKEND MODEL).
Candidates are \"Backend:model\" for every model of every backend in
`utter--known-backends', or the backend name for backends without
models, grouped by backend."
  (let* ((entries
          (cl-loop
           for (name . backend) in utter--known-backends
           for models = (utter-backend-models backend)
           if models
           nconc (mapcar (lambda (model)
                           (list (format "%s:%s" name
                                         (utter-transient--model-symbol model))
                                 backend model))
                         models)
           else collect (list name backend nil)))
         (completion-extra-properties
          `(:group-function
            ,(lambda (candidate transform)
               (if transform
                   candidate
                 (when-let* ((entry (assoc candidate entries)))
                   (utter-backend-name (nth 1 entry)))))
            :annotation-function
            ,(lambda (candidate)
               (when-let* ((entry (assoc candidate entries)))
                 (utter-transient--provider-annotation entry)))))
         (current (utter-transient--backend utter-backend))
         (choice (assoc (completing-read
                         prompt entries nil t nil nil
                         (and current (utter-transient--provider-string
                                       current utter-model)))
                        entries)))
    (list (nth 1 choice) (utter-transient--model-symbol (nth 2 choice)))))

(defun utter-transient--refresh-menu (&rest _)
  "Redraw `utter-menu' if it is open, to update its heading and columns.
Runs from `utter--state-change-hook' and voice fetches, outside the
command loop, so errors are demoted to messages.  Does nothing when
the menu is closed, while the minibuffer is active, or while one of
the menu's own commands runs (transient redraws after it anyway)."
  (when (and transient--prefix
             (eq (oref transient--prefix command) 'utter-menu)
             (not transient-current-command)
             ;; An infix is reading input; `:refresh-suffixes' redraws
             ;; after the next key instead.
             (not (active-minibuffer-window)))
    (with-demoted-errors "utter: menu refresh failed: %S"
      (with-current-buffer (utter-transient--source-buffer)
        (if (fboundp 'transient--env-apply)
            (transient--env-apply #'transient--refresh-transient)
          (transient--refresh-transient))))))

;; Installed once: the guard makes it a no-op while the menu is closed,
;; and `C-z' suspend then resume needs no reinstall.
(add-hook 'utter--state-change-hook #'utter-transient--refresh-menu)

(defun utter-transient--voice-candidates (backend model)
  "Return the voices for BACKEND and MODEL, or nil while being fetched.
Known lists come from `utter--static-voices'.  Otherwise ask
`utter--list-voices'; a cache hit answers at once, a miss starts a
fetch whose arrival redraws the menu."
  (or (utter--static-voices backend model)
      (when (fboundp 'utter--list-voices)
        (let ((name (utter-backend-name backend))
              returned result)
          (condition-case err
              (utter--list-voices
               backend
               (lambda (voices &rest _)
                 (if (not returned)
                     (setq result voices)
                   (when voices
                     (message "utter: fetched %d voices from %s"
                              (length voices) name))
                   (utter-transient--refresh-menu))))
            (error (message "utter: cannot list voices for %s: %s"
                            name (error-message-string err))))
          (setq returned t)
          (unless result
            (message "utter: no voices cached for %s yet, fetching…" name))
          (and (listp result) result)))))

(defconst utter-transient--default-voice "(backend default)"
  "Voice candidate that clears `utter-voice'.")

(defun utter-transient--read-voice (_prompt _initial history)
  "Read a voice for the current backend and model.
RET keeps the current voice; the candidate named by
`utter-transient--default-voice', or empty input when no voice is
set, means nil.  Any name may be typed, so a voice can be chosen
before the list has been fetched.  HISTORY is the minibuffer
history."
  (let* ((backend (utter-transient--backend utter-backend))
         (voices (and backend (utter-transient--voice-candidates
                               backend utter-model)))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (candidate)
               (when-let* ((info (cdr-safe (assoc candidate voices))))
                 (concat "  " (if (stringp info) info (format "%S" info)))))))
         (choice (completing-read
                  (format "Voice for %s (%s): "
                          (utter-transient--provider-string backend utter-model)
                          (or utter-voice "backend default"))
                  (append (mapcar (lambda (v) (if (consp v) v (list v))) voices)
                          (and utter-voice
                               (list (list utter-transient--default-voice))))
                  nil nil nil history utter-voice)))
    (if (or (string-empty-p choice)
            (equal choice utter-transient--default-voice))
        nil
      choice)))

(defun utter-transient--read-format (prompt _initial history)
  "Read an audio format with PROMPT; empty input means the default.
Candidates are the formats of the current backend and model.
HISTORY is the minibuffer history."
  (let* ((backend (utter-transient--backend utter-backend))
         (choice (completing-read
                  prompt (mapcar #'symbol-name
                                 (and backend (utter--formats backend utter-model)))
                  nil t nil history)))
    (if (string-empty-p choice) nil (intern choice))))

(defun utter-transient--read-language (prompt _initial history)
  "Read a language code with PROMPT, as a symbol; empty input means `auto'.
HISTORY is the minibuffer history."
  (let ((choice (completing-read prompt '("auto" "en" "zh" "ja" "de" "fr" "es")
                                 nil nil nil history)))
    (if (string-empty-p choice) 'auto (intern choice))))

(defun utter-transient--read-instructions (prompt _initial history)
  "Read voice instructions with PROMPT; empty input means none.
HISTORY is the minibuffer history."
  (let ((text (read-string prompt utter-instructions history)))
    (if (string-empty-p (string-trim text)) nil text)))

(defun utter--transient-read-number (prompt _initial-input history)
  "Read a number from the minibuffer with PROMPT; empty input means nil.
_INITIAL-INPUT and HISTORY are as in the transient reader
documentation.  Copied from `gptel--transient-read-number'."
  ;; Workaround for transient history holding non-string values, see
  ;; https://github.com/magit/transient/issues/172
  (when-let* ((history-symbol (or (car-safe history) history))
              (val (and (symbolp history-symbol) (boundp history-symbol)
                        (symbol-value history-symbol))))
    (unless (stringp (car val))
      (setcar val (number-to-string (car val)))))
  (let* ((minibuffer-default-prompt-format "")
         (num (read-number prompt -1 history)))
    (if (= num -1) nil num)))

;;;; Presets

(defun utter-transient--read-preset (prompt _initial history)
  "Read the name of a registered preset with PROMPT.
Each candidate is annotated with its :description.  HISTORY is the
minibuffer history."
  (let* ((names (mapcar #'car (bound-and-true-p utter--known-presets)))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (candidate)
               (when-let* ((name (cl-find candidate names
                                          :key (lambda (n) (format "%s" n))
                                          :test #'equal))
                           (desc (plist-get (utter-get-preset name)
                                            :description)))
                 (concat (propertize " " 'display '(space :align-to 25))
                         desc)))))
         (choice (completing-read prompt (mapcar (lambda (n) (format "%s" n))
                                                 names)
                                  nil t nil history)))
    (cl-find choice names :key (lambda (n) (format "%s" n)) :test #'equal)))

(defun utter-transient--preset-mismatch-p (preset)
  "Return non-nil if a setting of PRESET no longer holds.
PRESET is a name or a spec.  Values are compared in the buffer the
menu was opened from; parents are checked too."
  (with-current-buffer (utter-transient--source-buffer)
    (let ((spec (ignore-errors (utter--preset-spec preset))))
      (cl-loop
       for (key val) on spec by #'cddr
       thereis
       (pcase key
         ((or :description :pre :post) nil)
         (:parents (cl-some #'utter-transient--preset-mismatch-p
                            (ensure-list val)))
         (:backend (let ((current (utter-transient--backend utter-backend)))
                     (not (if (stringp val)
                              (and current (equal (utter-backend-name current) val))
                            (eq current val)))))
         (_ (when-let* ((var (utter--preset-var key)))
              (not (equal (symbol-value var) val)))))))))

;;;; Infix classes

(defclass utter-lisp-variable (transient-lisp-variable)
  ((display-nil :initarg :display-nil :initform "(none)")
   (display-map :initarg :display-map :initform nil)
   (default :initarg :default :initform nil))
  "A Lisp variable infix that honours `utter--set-scope'.
DISPLAY-NIL is shown for a nil value; DISPLAY-MAP maps values to
display strings.  A value equal to DEFAULT is shown as inactive.")

(cl-defmethod transient-format-value ((obj utter-lisp-variable))
  "Format the value of OBJ, using its display-nil and display-map slots."
  (with-slots (value display-nil display-map default) obj
    (if (or (null value) (and default (equal value default)))
        (propertize (if value
                        (let ((shown (or (cdr (assoc value display-map)) value)))
                          (if (stringp shown) shown (prin1-to-string shown)))
                      display-nil)
                    'face 'transient-inactive-value)
      (let ((shown (or (cdr (assoc value display-map)) value)))
        (propertize (if (stringp shown) shown (prin1-to-string shown))
                    'face 'transient-value)))))

(cl-defmethod transient-infix-set ((obj utter-lisp-variable) value)
  "Set OBJ's variable to VALUE with the scope in `utter--set-scope'."
  (funcall (oref obj set-value)
           (oref obj variable)
           (oset obj value value)
           utter--set-scope))

(defclass utter--text-variable (utter-lisp-variable)
  ()
  "A free-text infix shown on one line, truncated to 35 characters.")

(cl-defmethod transient-format-value ((obj utter--text-variable))
  "Show OBJ's value flattened to one line and truncated."
  (let ((value (oref obj value)))
    (if (stringp value)
        (propertize (truncate-string-to-width
                     (replace-regexp-in-string "[ \t]*\n[ \t]*" " " value)
                     35 nil nil t)
                    'face 'transient-value)
      (cl-call-next-method))))

(defclass utter-provider-variable (utter-lisp-variable)
  ((backend :initarg :backend :initform 'utter-backend))
  "Compound infix that sets `utter-backend' and `utter-model' together.")

(cl-defmethod transient-format-value ((obj utter-provider-variable))
  "Show OBJ as \"Backend:model\"."
  (propertize (utter-transient--provider-string
               (utter-transient--backend
                (utter-transient--original (oref obj backend)))
               (oref obj value))
              'face 'transient-value))

(cl-defmethod transient-infix-set ((obj utter-provider-variable) value)
  "Set backend and model from VALUE, (BACKEND MODEL), for OBJ.
Then clear `utter-voice' when the new backend does not offer it,
and redraw the menu."
  (pcase-let ((`(,backend ,model) value)
              (set-value (oref obj set-value)))
    (funcall set-value (oref obj variable) (oset obj value model)
             utter--set-scope)
    (funcall set-value (oref obj backend) backend utter--set-scope)
    (utter--sanitize-settings
     backend (lambda (sym val) (funcall set-value sym val utter--set-scope))
     (list (oref obj variable))))
  (when transient--prefix (transient-setup)))

(defclass utter-voice-variable (utter-lisp-variable)
  ()
  "Infix for `utter-voice'; candidates depend on the backend and model.")

(defclass utter--scope-variable (utter-lisp-variable)
  ()
  "Infix that cycles `utter--set-scope' through global, buffer and oneshot.")

(defconst utter-transient--scope-names '((nil . "global") (t . "buffer")
                                         (1 . "oneshot"))
  "Display names of the values of `utter--set-scope'.")

(cl-defmethod transient-infix-read ((obj utter--scope-variable))
  "Return the scope after OBJ's current one: global, buffer, oneshot."
  (pcase (oref obj value)
    ('nil (message "Settings from the menu apply to this buffer") t)
    ('t (message "Settings from the menu apply to the next utterance only") 1)
    (_ (message "Settings from the menu apply globally") nil)))

(cl-defmethod transient-format-value ((obj utter--scope-variable))
  "Show every scope of OBJ, the active one highlighted."
  (let ((value (oref obj value)))
    (concat
     (propertize "(" 'face 'transient-delimiter)
     (mapconcat (pcase-lambda (`(,scope . ,name))
                  (propertize name 'face (if (eql scope value)
                                             'transient-value
                                           'transient-inactive-value)))
                utter-transient--scope-names
                (propertize "|" 'face 'transient-delimiter))
     (propertize ")" 'face 'transient-delimiter))))

(cl-defmethod transient-infix-set ((obj utter--scope-variable) value)
  "Set the scope of OBJ to VALUE; the scope itself is always global."
  (set (oref obj variable) (oset obj value value)))

(defclass utter--toggle-variable (utter-lisp-variable)
  ()
  "Boolean infix shown as (on) or (off).")

(cl-defmethod transient-infix-read ((obj utter--toggle-variable))
  "Flip the value of OBJ."
  (not (oref obj value)))

(cl-defmethod transient-format-value ((obj utter--toggle-variable))
  "Show OBJ as (on) or (off)."
  (if (oref obj value)
      (propertize "(on)" 'face 'transient-value)
    (propertize "(off)" 'face 'transient-inactive-value)))

(defclass utter-preset-variable (utter-lisp-variable)
  ()
  "Infix for `utter--preset' that applies a preset from `utter--known-presets'.")

(cl-defmethod transient-format-value ((obj utter-preset-variable))
  "Show OBJ's preset, struck through when its settings no longer hold."
  (let ((value (oref obj value)))
    (if (null value)
        (cl-call-next-method)
      (propertize (format "%s" value)
                  'face (if (utter-transient--preset-mismatch-p value)
                            '(:inherit transient-inactive-value :strike-through t)
                          'transient-value)))))

(cl-defmethod transient-infix-set ((obj utter-preset-variable) value)
  "Apply the preset named VALUE for OBJ with the current scope, then redraw."
  (when value
    (utter--apply-preset value
                         (lambda (sym val)
                           (funcall (oref obj set-value) sym val utter--set-scope)))
    (message "Preset %s applied" value))
  (oset obj value value)
  (when transient--prefix (transient-setup)))

;;;; Infixes

(transient-define-infix utter--infix-provider ()
  "Backend and model."
  :class 'utter-provider-variable
  :description "Backend:model"
  :key "-m"
  :prompt "Backend:model: "
  :variable 'utter-model
  :backend 'utter-backend
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-provider)

(transient-define-infix utter--infix-voice ()
  "Voice for the current backend and model."
  :class 'utter-voice-variable
  :description "Voice"
  :key "-v"
  :prompt "Voice: "
  :variable 'utter-voice
  :display-nil "(default)"
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-voice)

(transient-define-infix utter--infix-speed ()
  "Synthesis speed sent to the backend."
  :class 'utter-lisp-variable
  :description "Speed"
  :key "-s"
  :prompt "Synthesis speed (empty: default): "
  :variable 'utter-speed
  :display-nil "(default)"
  :set-value #'utter--set-with-scope
  :reader #'utter--transient-read-number)

(transient-define-infix utter--infix-format ()
  "Audio format requested from the backend."
  :class 'utter-lisp-variable
  :description "Format"
  :key "-f"
  :prompt "Audio format (empty: default): "
  :variable 'utter-format
  :display-nil "(default)"
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-format)

(transient-define-infix utter--infix-language ()
  "Language of the text."
  :class 'utter-lisp-variable
  :description "Language"
  :key "-l"
  :prompt "Language (empty: auto): "
  :variable 'utter-language
  :display-nil "auto"
  :default 'auto
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-language)

(transient-define-infix utter--infix-instructions ()
  "Voice instructions, for backends that accept them."
  :class 'utter--text-variable
  :description "Instructions"
  :key "-i"
  :prompt "Instructions (empty: none): "
  :variable 'utter-instructions
  :display-nil "(none)"
  :inapt-if (lambda () (not (utter-transient--capable-p 'instructions)))
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-instructions)

(transient-define-infix utter--infix-highlight ()
  "Highlight the text being spoken."
  :class 'utter--toggle-variable
  :description "Highlight spoken text"
  :key "-H"
  :variable 'utter-highlight
  :set-value #'utter--set-with-scope)

(transient-define-infix utter--infix-scope ()
  "Where settings from the menu apply: global, buffer or oneshot."
  :class 'utter--scope-variable
  :description "Scope"
  :key "="
  :variable 'utter--set-scope)

(transient-define-infix utter--infix-preset ()
  "Apply a named preset."
  :class 'utter-preset-variable
  :description "Preset"
  :key "@"
  :prompt "Preset: "
  :variable 'utter--preset
  :display-nil "(none)"
  :inapt-if (lambda () (null (bound-and-true-p utter--known-presets)))
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-preset)

;;;; Live arguments

(defun utter-transient--live-args ()
  "Return the menu's switches as they are now, also while it is drawn.
`transient-args' only sees the exported value inside a suffix; while
the menu is drawn this simulates the export, as gptel does."
  (or (and transient-current-command
           (transient-args transient-current-command))
      (and transient--prefix
           (eq (oref transient--prefix command) 'utter-menu)
           ;; HACK: transient internals, for live labels (see
           ;; `gptel--describe-suffix-send').
           (let* ((transient-current-command (oref transient--prefix command))
                  (transient-current-suffixes transient--suffixes))
             (transient-args transient-current-command)))))

;;;; Input and output

(defun utter-transient--latest-kill ()
  "Return the latest kill as a plain string, or nil when there is none.
Asks `current-kill' like yanking does, so the system clipboard counts."
  (when-let* ((kill (ignore-errors (current-kill 0 t))))
    (and (string-match-p "[^ \t\n\r]" kill)
         (substring-no-properties kill))))

(defun utter-transient--format-seconds (seconds)
  "Return SECONDS as a rough duration, \"~12 s\" or \"~3 min\"."
  (if (< seconds 59.5)
      (format "~%d s" (max 1 (round seconds)))
    (format "~%d min" (max 1 (round seconds 60)))))

(defun utter-transient--line-range (beg end)
  "Return \"line N\" or \"lines N-M\" for the text from BEG to END."
  (let ((first (line-number-at-pos beg))
        (last (line-number-at-pos (if (and (> end beg)
                                           (eq (char-before end) ?\n))
                                      (1- end)
                                    end))))
    (if (= first last)
        (format "line %d" first)
      (format "lines %d-%d" first last))))

(defun utter-transient--compute-plan (args)
  "Return a plist describing the text RET would read with ARGS.
Keys: :label, the source name; :lines, a line range when the text
comes from the buffer; :seconds, the estimated speaking time; :empty,
non-nil when there is nothing to read.  Never signals."
  (condition-case nil
      (cond
       ((member "m" args) (list :label "minibuffer" :what "minibuffer input"))
       ((member "y" args)
        (if-let* ((kill (utter-transient--latest-kill)))
            (let ((label (concat "kill-ring " (utter--short-name kill))))
              (list :label label :what label
                    :seconds (utter--estimate-seconds kill utter-speed)))
          (list :label "kill ring empty" :empty t)))
       (t
        (pcase-let ((`(,beg ,end ,label) (utter--input-candidate)))
          (if (utter--blank-p beg end)
              (list :label "nothing" :empty t)
            (list :label label :what label
                  :lines (utter-transient--line-range beg end)
                  :seconds (utter--estimate-seconds
                            (buffer-substring-no-properties beg end)
                            utter-speed))))))
    (error (list :label "nothing" :empty t))))

(defvar utter-transient--plan-cache nil
  "The last input plan, as (KEY . PLAN); see `utter-transient--plan'.")

(defun utter-transient--plan (args)
  "Return the input plan for ARGS, computed once per menu redraw.
The Input heading and the RET label both ask; the plan is reused
while the source buffer, point, mark, region, kill and ARGS stay
the same."
  (with-current-buffer (utter-transient--source-buffer)
    (let ((key (list (current-buffer) (buffer-chars-modified-tick) (point)
                     (mark t) (use-region-p) args (car kill-ring)
                     utter-speed utter-input-functions)))
      (if (equal key (car utter-transient--plan-cache))
          (cdr utter-transient--plan-cache)
        (let ((plan (utter-transient--compute-plan args)))
          (setq utter-transient--plan-cache (cons key plan))
          plan)))))

(defun utter-transient--input-description ()
  "Describe the Input group with the source RET would read."
  (let ((plan (utter-transient--plan (utter-transient--live-args))))
    (concat (propertize " <Read from " 'face 'transient-heading)
            (propertize (plist-get plan :label)
                        'face (if (plist-get plan :empty) 'error 'warning)))))

(defun utter-transient--describe-speak ()
  "Describe what RET sends: the text, its size and where it goes."
  (let* ((args (utter-transient--live-args))
         (plan (utter-transient--plan args))
         (state (and (fboundp 'utter-state) (utter-state)))
         (active (and state (not (memq (plist-get state :status) '(nil idle)))))
         (seconds (plist-get plan :seconds))
         (lines (plist-get plan :lines)))
    (cl-flet ((source (&optional no-time)
                (let ((details (delq nil (list lines
                                               (and seconds (not no-time)
                                                    (utter-transient--format-seconds
                                                     seconds))))))
                  (concat (propertize (plist-get plan :what) 'face 'warning)
                          (and details
                               (format " (%s)" (string-join details ", ")))))))
      (cond
       ((plist-get plan :empty)
        (propertize "Nothing to read aloud" 'face 'error))
       ((member "f" args) (concat "Save " (source t) " to file"))
       ((member "c" args) (concat "Synthesize " (source) ", cache only"))
       ((member "S" args)
        (concat "Speak " (source) (and active ", interrupt now")))
       (active (format "Speak %s, append as utterance %d"
                       (source) (1+ (or (plist-get state :total) 0))))
       (t (concat "Speak " (source)))))))

(defun utter-transient--default-input ()
  "Return (TEXT . PARAMS) chosen the way `utter-speak' chooses.
The active region, else a source from `utter-input-functions', else
the buffer up to point; see `utter--text-at-point'."
  (pcase-let ((`(,text . ,name) (utter--text-at-point)))
    (list text :source-buffer (current-buffer)
          :source-name (or name (buffer-name)))))

(defun utter-transient--input (args)
  "Return (TEXT . PARAMS) for the input switch in ARGS.
Without a switch the text is chosen like `utter-speak' does.  With
the `y' switch and a prefix argument, pick an older kill."
  (cond
   ((member "y" args)
    (let ((text (if (and current-prefix-arg kill-ring)
                    (substring-no-properties
                     (read-from-kill-ring "Read aloud from kill-ring: "))
                  (utter-transient--latest-kill))))
      (when (or (null text) (string-blank-p text))
        (user-error "Nothing to read aloud: the kill ring is empty"))
      (list text :source-name "kill-ring")))
   ((member "m" args)
    (let ((text (read-string "Text to read aloud: ")))
      (when (string-blank-p text)
        (user-error "Nothing to read aloud: the minibuffer input is blank"))
      (list text :source-name "minibuffer")))
   (t (utter-transient--default-input))))

(defun utter-transient--save-file-name (params)
  "Return the default file name for saving audio of PARAMS.
The name of the source without its extension plus the format that
would be requested, such as \"notes.mp3\"."
  (let* ((backend (utter-transient--backend utter-backend))
         (format (or utter-format
                     (and backend (car (utter--formats backend utter-model)))))
         (base (file-name-sans-extension
                (or (plist-get params :source-name) "utter"))))
    (concat (replace-regexp-in-string "[/\\:*?\"<>|]" "_" base)
            (and format (format ".%s" format)))))

(defun utter-transient--save (text params)
  "Save the audio of TEXT with PARAMS to a file read from the minibuffer.
Check that TEXT fits one request before asking for the file name."
  (utter--single-segment text (utter--snapshot-params nil text))
  (let ((default (utter-transient--save-file-name params)))
    (utter-save-to-file text (read-file-name
                              (format-prompt "Save audio to" default)
                              nil default))))

(transient-define-suffix utter--suffix-speak (args)
  "Read aloud the text chosen by the input switch in ARGS.
The output switch picks the target: append to the queue (default),
interrupt, save to a file, or fill the cache only.  With nil ARGS
this is `utter-speak': region or text at point, appended."
  :key "RET"
  :description #'utter-transient--describe-speak
  (interactive (list (transient-args (or transient-current-command 'utter-menu))))
  (pcase-let ((`(,text . ,params) (utter-transient--input args)))
    (cond
     ((member "S" args) (apply #'utter-interrupt text params))
     ((member "f" args) (utter-transient--save text params))
     ((member "c" args) (apply #'utter-enqueue text :cache-only t params))
     (t (apply #'utter-enqueue text params)))))

(transient-define-suffix utter--suffix-inspect (args)
  "Show the request RET would send for ARGS, without sending it."
  :key "I"
  :description "Inspect"
  (interactive (list (transient-args (or transient-current-command 'utter-menu))))
  (let ((text (car (utter-transient--input args))))
    (with-current-buffer (utter-transient--source-buffer)
      (utter--inspect-text text))))

;;;; Evil

(defun utter--transient-fix-evil-visual (fn)
  "Expand an evil visual selection into the region, then call FN.
Used as the `:environment' of `utter-menu', so a visual-state
selection stays the menu's region.  Without evil it just calls FN.
Copied from `gptel--transient-fix-evil-visual'."
  (if (and (boundp 'evil-visual-region-expanded)
           (not evil-visual-region-expanded)
           (fboundp 'evil-visual-expand-region)
           (fboundp 'evil-visual-contract-region))
      (progn
        (evil-visual-expand-region)
        (funcall fn)
        (when evil-visual-region-expanded
          (evil-visual-contract-region)))
    (funcall fn)))

;;;; Heading

(defun utter--menu-heading ()
  "Return the heading of `utter-menu' for the current playback state.
Either \"Idle\" or, for example,
\"Playing notes.org (2/5) · OpenAI:gpt-4o-mini-tts/nova\".  The
rate is shown once, on the rate-up key."
  (let* ((state (utter-state))
         (status (plist-get state :status)))
    (propertize
     (if (memq status '(nil idle))
         "Idle"
       (let ((model (plist-get state :model))
             (voice (plist-get state :voice)))
         (format "%s %s (%s/%s) · %s%s%s"
                 (capitalize (symbol-name status))
                 (or (plist-get state :source) "utterance")
                 (or (plist-get state :index) 1)
                 (or (plist-get state :total) 1)
                 (or (utter-mode--backend-name (plist-get state :backend)) "?")
                 (if model (format ":%s" model) "")
                 (if voice (concat "/" voice) ""))))
     'face 'transient-heading)))

;;;; The menu

;;;###autoload (autoload 'utter-menu "utter-transient" nil t)
(transient-define-prefix utter-menu ()
  "Read text aloud: settings, input, output and playback control."
  :refresh-suffixes t
  :incompatible '(("m" "y") ("S" "f" "c"))
  [:description utter--menu-heading
   ["Backend"
    (utter--infix-provider)
    (utter--infix-voice)
    (utter--infix-speed)
    (utter--infix-format)
    (utter--infix-language)
    (utter--infix-instructions)
    (utter--infix-highlight)
    (utter--infix-scope)
    (utter--infix-preset)]
   ;; What RET reads is a heuristic (region, else a claimed source, else
   ;; the buffer to point) shown in the heading; only overrides are keys.
   [:description utter-transient--input-description
    ("m" "Minibuffer instead" "m")
    ("y" "Kill-ring instead" "y")]
   ;; Appending is the default and has no switch; RET says so.
   [" >Output to"
    ("S" "Speakers, interrupt" "S")
    ("f" "Save to file" "f")
    ("c" "Cache only" "c")]
   ["Playback" :if utter-active-p
    ("SPC" "Pause/resume" utter-toggle-pause :transient t)
    ("n" "Next utterance" utter-next :transient t)
    ("p" "Previous utterance" utter-previous :transient t)
    ;; "-" cannot be a key here: it is the prefix of "-m", "-v", ...
    ("+" (lambda () (format "Rate up (%s)"
                       (utter-mode--format-rate utter-playback-rate)))
     utter-rate-up :transient t)
    ("_" "Rate down" utter-rate-down :transient t)
    ("x" "Clear pending" utter-clear :transient t)
    ("q" "Stop all" utter-stop :transient t)
    ;; Exits: the queue buffer has keys of its own.
    ("Q" "Queue buffer" utter-queue)]]
  [(utter--suffix-speak)
   (utter--suffix-inspect
    :if (lambda () (or utter-expert-commands utter-log-level)))]
  (interactive)
  (utter--sanitize-settings)
  (transient-setup 'utter-menu))

;; The `environment' slot appeared in transient 0.7.8, but Emacs 30.1
;; bundles 0.7.2.2, whose `transient-define-prefix' rejects the keyword
;; (invalid-slot-name) when `-Q' loads the bundled copy.  So attach the
;; evil fix only where the slot exists.
(when (slot-exists-p 'transient-prefix 'environment)
  (oset (get 'utter-menu 'transient--prefix) environment
        #'utter--transient-fix-evil-visual))

(provide 'utter-transient)
;;; utter-transient.el ends here
