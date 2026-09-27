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
(defvar utter-progress-functions)
(defvar utter-queue-finished-hook)
(defvar utter--set-scope)
(defvar utter--known-backends)
(defvar utter--known-presets)

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
(declare-function utter-request "utter-core" (text &rest keys))
(declare-function utter-backend-name "utter-core" (backend))
(declare-function utter-backend-models "utter-core" (backend))
(declare-function utter-backend-voices "utter-core" (backend))
(declare-function utter-backend-formats "utter-core" (backend))
(declare-function utter-backend-capabilities "utter-core" (backend))
(declare-function utter-backend-max-chars "utter-core" (backend))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading))
(declare-function evil-visual-expand-region "evil-states" (&optional exclude-newline))
(declare-function evil-visual-contract-region "evil-states" ())
(defvar evil-visual-region-expanded)

;;;; Backends, models and voices

(defun utter-transient--backend (backend)
  "Return the backend object for BACKEND, an object or a registered name."
  (if (stringp backend) (utter-get-backend backend) backend))

(defun utter-transient--original (symbol)
  "Return SYMBOL's value in the buffer the menu was opened from."
  (buffer-local-value symbol (if (buffer-live-p transient--original-buffer)
                                 transient--original-buffer
                               (current-buffer))))

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

(defun utter-transient--voice-valid-p (voice backend old-backend)
  "Return non-nil if VOICE can stay selected after switching to BACKEND.
OLD-BACKEND is the backend VOICE was chosen for."
  (or (null voice)
      (if-let* ((voices (utter-backend-voices backend)))
          (member voice (mapcar #'utter-transient--voice-name voices))
        (eq backend old-backend))))

(defun utter-transient--provider-annotation (entry)
  "Return the annotation for provider ENTRY, (NAME BACKEND MODEL).
Shows description, capabilities, max characters and price per
million characters from MODEL's plist."
  (pcase-let* ((`(,_ ,backend ,model) entry)
               (desc (utter-transient--model-get model :description))
               (caps (or (utter-transient--model-get model :capabilities)
                         (utter-backend-capabilities backend)))
               (max-chars (utter-backend-max-chars backend))
               (cost (utter-transient--model-get model :cost)))
    (concat
     (propertize " " 'display '(space :align-to 40))
     (truncate-string-to-width (or desc "") 40 nil ?\s t)
     (propertize " " 'display '(space :align-to 82))
     (truncate-string-to-width (if caps (mapconcat #'symbol-name caps " ") "")
                               24 nil ?\s t)
     (propertize " " 'display '(space :align-to 108))
     (format "%6s" (if max-chars (number-to-string max-chars) "--"))
     (propertize " " 'display '(space :align-to 116))
     (cond ((null cost) "")
           ((and (numberp cost) (zerop cost)) "free")
           (t (format "$%s/1M" cost))))))

(defun utter-transient--read-provider (prompt &rest _)
  "Read a backend and model with PROMPT; return (BACKEND MODEL).
Candidates are \"Backend:model\" for every model of every backend in
`utter--known-backends', or the backend name for backends without
models."
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
          `(:annotation-function
            ,(lambda (candidate)
               (utter-transient--provider-annotation
                (assoc candidate entries)))))
         (current (utter-transient--backend utter-backend))
         (choice (assoc (completing-read
                         prompt entries nil t nil nil
                         (and current (utter-transient--provider-string
                                       current utter-model)))
                        entries)))
    (list (nth 1 choice) (utter-transient--model-symbol (nth 2 choice)))))

(defun utter-transient--refresh-menu (&rest _)
  "Redraw `utter-menu' if it is open, to update its heading and columns.
Called from engine hooks and voice fetches, outside the command loop,
so errors are demoted to messages.  Does nothing while the minibuffer
is active."
  (when (and transient--prefix
             (eq (oref transient--prefix command) 'utter-menu)
             ;; An infix is reading input; `:refresh-suffixes' redraws
             ;; after the next key instead.
             (not (active-minibuffer-window)))
    (with-demoted-errors "utter: menu refresh failed: %S"
      (with-current-buffer (if (buffer-live-p transient--original-buffer)
                               transient--original-buffer
                             (current-buffer))
        (transient--refresh-transient)))))

(defun utter-transient--voice-candidates (backend)
  "Return the voices for BACKEND, or nil while they are being fetched.
Static voices come from the backend.  Otherwise ask
`utter--list-voices'; a cache hit answers at once, a miss starts a
fetch whose arrival redraws the menu."
  (or (utter-backend-voices backend)
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
          result))))

(defun utter-transient--read-voice (_prompt _initial history)
  "Read a voice for the current backend and model; empty input means nil.
Any name may be typed, so a voice can be chosen before the list has
been fetched.  HISTORY is the minibuffer history."
  (let* ((backend (utter-transient--backend utter-backend))
         (voices (and backend (utter-transient--voice-candidates backend)))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (candidate)
               (when-let* ((info (cdr-safe (assoc candidate voices))))
                 (concat "  " (if (stringp info) info (format "%S" info)))))))
         (choice (completing-read
                  (format "Voice for %s (%s): "
                          (utter-transient--provider-string backend utter-model)
                          (or utter-voice "default"))
                  (mapcar (lambda (v) (if (consp v) v (list v))) voices)
                  nil nil nil history)))
    (if (string-empty-p choice) nil choice)))

(defun utter-transient--read-format (prompt _initial history)
  "Read an audio format with PROMPT; empty input means the default.
HISTORY is the minibuffer history."
  (let* ((backend (utter-transient--backend utter-backend))
         (choice (completing-read
                  prompt (mapcar #'symbol-name
                                 (and backend (utter-backend-formats backend)))
                  nil nil nil history)))
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

(defvar utter-transient--preset nil
  "Name of the preset last applied from `utter-menu'.")

(defun utter-transient--read-preset (prompt _initial history)
  "Read the name of a registered preset with PROMPT.
HISTORY is the minibuffer history."
  (let* ((names (mapcar #'car (bound-and-true-p utter--known-presets)))
         (choice (completing-read prompt (mapcar (lambda (n) (format "%s" n))
                                                 names)
                                  nil t nil history)))
    (cl-find choice names :key (lambda (n) (format "%s" n)) :test #'equal)))

;;;; Infix classes

(defclass utter-lisp-variable (transient-lisp-variable)
  ((display-nil :initarg :display-nil :initform "(none)")
   (display-map :initarg :display-map :initform nil))
  "A Lisp variable infix that honours `utter--set-scope'.
DISPLAY-NIL is shown for a nil value; DISPLAY-MAP maps values to
display strings.")

(cl-defmethod transient-format-value ((obj utter-lisp-variable))
  "Format the value of OBJ, using its display-nil and display-map slots."
  (with-slots (value display-nil display-map) obj
    (if (null value)
        (propertize display-nil 'face 'transient-inactive-value)
      (let ((shown (or (cdr (assoc value display-map)) value)))
        (propertize (if (stringp shown) shown (prin1-to-string shown))
                    'face 'transient-value)))))

(cl-defmethod transient-infix-set ((obj utter-lisp-variable) value)
  "Set OBJ's variable to VALUE with the scope in `utter--set-scope'."
  (funcall (oref obj set-value)
           (oref obj variable)
           (oset obj value value)
           utter--set-scope))

(defclass utter-provider-variable (utter-lisp-variable)
  ((backend :initarg :backend :initform 'utter-backend)
   (always-read :initform t))
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
Reset `utter-voice' when the old voice does not exist for the new
backend, then redraw the menu."
  (pcase-let ((`(,backend ,model) value)
              (old-backend (utter-transient--backend
                            (symbol-value (oref obj backend)))))
    (funcall (oref obj set-value) (oref obj variable)
             (oset obj value model) utter--set-scope)
    (funcall (oref obj set-value) (oref obj backend) backend utter--set-scope)
    (unless (utter-transient--voice-valid-p utter-voice backend old-backend)
      (funcall (oref obj set-value) 'utter-voice nil utter--set-scope)))
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
  "Show the scope name of OBJ."
  (propertize (alist-get (oref obj value) utter-transient--scope-names
                         "global" nil #'eql)
              'face 'transient-value))

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
  "Infix that applies a named preset from `utter--known-presets'.")

(cl-defmethod transient-infix-set ((_obj utter-preset-variable) value)
  "Apply the preset named VALUE with the current scope, then set the infix."
  (when value
    (utter--apply-preset (utter-get-preset value)
                         (lambda (sym val)
                           (utter--set-with-scope sym val utter--set-scope)))
    (message "Preset %s applied" value))
  (cl-call-next-method)
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
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-language)

(transient-define-infix utter--infix-instructions ()
  "Voice instructions, for backends that accept them."
  :class 'utter-lisp-variable
  :description "Instructions"
  :key "-i"
  :prompt "Instructions (empty: none): "
  :variable 'utter-instructions
  :display-nil "(none)"
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
  :variable 'utter-transient--preset
  :display-nil "(none)"
  :set-value #'utter--set-with-scope
  :reader #'utter-transient--read-preset)

;;;; Input and output

(defun utter-transient--default-input ()
  "Return (TEXT . PARAMS) chosen the way `utter-speak' chooses.
The active region, else a source from `utter-input-functions', else
the buffer up to point; see `utter--text-at-point'."
  (pcase-let ((`(,text . ,name) (utter--text-at-point)))
    (list text :source-buffer (current-buffer)
          :source-name (or name (buffer-name)))))

(defun utter-transient--input (args)
  "Return (TEXT . PARAMS) for the input switch in ARGS.
Without a switch the text is chosen like `utter-speak' does."
  (cond
   ((member "y" args)
    (let ((text (and (or kill-ring interprogram-paste-function)
                     (substring-no-properties (current-kill 0)))))
      (when (or (null text) (string-blank-p text))
        (user-error "Nothing to read aloud: the kill ring is empty"))
      (list text :source-name "kill-ring")))
   ((member "m" args)
    (let ((text (read-string "Text to read aloud: ")))
      (when (string-blank-p text)
        (user-error "Nothing to read aloud: the minibuffer input is blank"))
      (list text :source-name "minibuffer")))
   (t (utter-transient--default-input))))

(defun utter-transient--input-description ()
  "Describe the Input group with the source RET would read."
  (format "Input < %s"
          (with-current-buffer (if (buffer-live-p transient--original-buffer)
                                   transient--original-buffer
                                 (current-buffer))
            (utter-input-label))))

(defun utter-transient--describe-speak ()
  "Describe the RET suffix, with the queue position while playing."
  (let ((state (and (fboundp 'utter-state) (utter-state)))
        (args (and transient--prefix (ignore-errors (transient-args 'utter-menu)))))
    (if (and state (not (memq (plist-get state :status) '(nil idle)))
             (not (cl-intersection args '("S" "f" "c") :test #'equal)))
        (format "Speak (appends as utterance %d)"
                (1+ (or (plist-get state :total) 0)))
      "Speak")))

(transient-define-suffix utter--suffix-speak (args)
  "Read aloud the text chosen by the input switch in ARGS.
The output switch picks the target: append to the queue (default),
interrupt, save to a file, or fill the cache only.  With nil ARGS
this is `utter-speak': region or text at point, appended."
  :key "RET"
  :description #'utter-transient--describe-speak
  (interactive (list (transient-args (or transient-current-command 'utter-menu))))
  (pcase-let ((`(,text . ,params) (utter-transient--input args)))
    (when (or (null text) (string-empty-p (string-trim text)))
      (user-error "Nothing to read aloud"))
    (cond
     ((member "S" args) (apply #'utter-interrupt text params))
     ((member "f" args)
      (utter-save-to-file text (read-file-name "Save audio to: ")))
     ((member "c" args) (apply #'utter-enqueue text :cache-only t params))
     (t (apply #'utter-enqueue text params)))))

(transient-define-suffix utter--suffix-inspect (args)
  "Show the request the menu would send for ARGS, without sending it."
  :key "I"
  :description "Inspect"
  (interactive (list (transient-args (or transient-current-command 'utter-menu))))
  (let* ((text (car (utter-transient--input args)))
         (backend (utter-transient--backend utter-backend))
         (max (and backend (utter-backend-max-chars backend)))
         (request (utter-request (if (and max (> (length text) max))
                                     (substring text 0 max)
                                   text)
                                 :dry-run t)))
    (with-current-buffer (get-buffer-create "*utter-inspect*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pp-to-string request)))
      (lisp-data-mode)
      (display-buffer (current-buffer)))))

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

;;;; Heading and live refresh

(defun utter--menu-heading ()
  "Return the heading of `utter-menu' for the current playback state.
Either \"Idle\" or, for example,
\"Playing notes.org (2/5) · OpenAI:gpt-4o-mini-tts/nova · 1.0x\"."
  (let* ((state (utter-state))
         (status (plist-get state :status)))
    (propertize
     (if (memq status '(nil idle))
         "Idle"
       (let ((model (plist-get state :model))
             (voice (plist-get state :voice)))
         (format "%s %s (%s/%s) · %s%s%s · %s"
                 (capitalize (symbol-name status))
                 (or (plist-get state :source) "utterance")
                 (or (plist-get state :index) 1)
                 (or (plist-get state :total) 1)
                 (or (utter-mode--backend-name (plist-get state :backend)) "?")
                 (if model (format ":%s" model) "")
                 (if voice (concat "/" voice) "")
                 (utter-mode--format-rate (plist-get state :rate)))))
     'face 'transient-heading)))

(defun utter-transient--remove-refresh ()
  "Stop refreshing the menu once it has really closed."
  (unless transient--prefix
    (remove-hook 'utter-progress-functions #'utter-transient--refresh-menu)
    (remove-hook 'utter-queue-finished-hook #'utter-transient--refresh-menu)
    (remove-hook 'transient-exit-hook #'utter-transient--remove-refresh)))

(defun utter-transient--install-refresh ()
  "Refresh the menu while it is open.
Progress updates the heading; the end of the queue hides the
Playback column."
  (add-hook 'utter-progress-functions #'utter-transient--refresh-menu)
  (add-hook 'utter-queue-finished-hook #'utter-transient--refresh-menu)
  (add-hook 'transient-exit-hook #'utter-transient--remove-refresh))

;;;; The menu

;;;###autoload (autoload 'utter-menu "utter-transient" nil t)
(transient-define-prefix utter-menu ()
  "Read text aloud: settings, input, output and playback control."
  :refresh-suffixes t
  :incompatible '(("m" "y") ("s" "S" "f" "c"))
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
   ["Output >"
    ("s" "Speakers, append (default)" "s")
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
    ("Q" "Queue buffer" utter-queue :transient t)]]
  [(utter--suffix-speak)
   (utter--suffix-inspect :if (lambda () utter-expert-commands))]
  (interactive)
  (utter-transient--install-refresh)
  (transient-setup 'utter-menu))

;; The `environment' slot appeared in transient 0.7.8; Emacs 30.1
;; bundles 0.7.2.2.  Attach the evil fix only where the slot exists.
(when (slot-exists-p 'transient-prefix 'environment)
  (oset (get 'utter-menu 'transient--prefix) environment
        #'utter--transient-fix-evil-visual))

(provide 'utter-transient)
;;; utter-transient.el ends here
