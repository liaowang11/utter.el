;;; utter.el --- Read text aloud through many TTS backends -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (transient "0.7.5"))
;; Keywords: multimedia, convenience
;; URL: https://github.com/liaowang11/utter.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; utter reads text aloud through text-to-speech backends (macOS `say',
;; OpenAI-compatible servers, ElevenLabs, ...).  `utter-menu' is the
;; interface; `utter-speak' is its default action.
;;
;; Listening is asynchronous.  Text is captured when you ask for it and
;; appended to one global queue; point never moves and no buffer pops
;; up.  A short lighter in the mode line shows that something is
;; playing.
;;
;; Main commands (none is bound by default):
;;
;; - `utter-speak': the region, else the thing at point (for example a
;;   gptel response), else the sentence at point.  With C-u, open
;;   `utter-menu'.
;; - `utter-speak-interrupt': the same, but cut in front of the queue.
;; - `utter-speak-buffer', `utter-speak-kill', `utter-speak-string'.
;; - `utter-toggle-pause', `utter-next', `utter-previous', `utter-stop',
;;   `utter-clear', `utter-rate-up', `utter-rate-down'.
;; - `utter-save-to-file', `utter-select-voice', `utter-inspect-query'.
;;
;; Other packages can call `utter-speak-string' or `utter-enqueue', and
;; `utter-with-preset' applies a preset made with `utter-make-preset'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'utter-queue)

(autoload 'utter-menu "utter-transient" nil t)
(autoload 'utter-queue "utter-mode" nil t)
(defvar utter--log-buffer-name)
(declare-function utter-say-register-default "utter-say" ())
(declare-function utter-request "utter-core" (text &rest keys))
(declare-function utter-get-backend "utter-core" (name))
(declare-function utter-backend-p "utter-core" (object))
(declare-function utter-backend-name "utter-core" (backend))
(declare-function utter-backend-voices "utter-core" (backend))
(declare-function utter-backend-formats "utter-core" (backend))
(declare-function utter-backend-max-chars "utter-core" (backend))
(declare-function utter-backend-max-chars-unit "utter-core" (backend))
(declare-function utter--resolve-backend "utter-core" (backend))
(declare-function utter--list-voices "utter-core" (backend callback))

;;;; Options

(defcustom utter-backend
  (and (eq system-type 'darwin)
       (require 'utter-say nil t)
       (fboundp 'utter-say-register-default)
       (utter-say-register-default))
  "The speech backend, an object made by an `utter-make-*' constructor.
A backend name (a string) is accepted too.  On macOS the default
is the `say' backend; elsewhere there is no default, so set this,
for example to the result of `utter-make-openai'."
  :type '(choice (const :tag "None" nil) (string :tag "Backend name") sexp)
  :group 'utter)

(defcustom utter-model nil
  "The model, a symbol; nil means the backend's first model."
  :type '(choice (const :tag "Backend default" nil) symbol)
  :group 'utter)

(defcustom utter-voice nil
  "The voice, a string.
Nil means `utter-voice-alist' for the text's language, else the
backend's first voice."
  :type '(choice (const :tag "Default" nil) string)
  :group 'utter)

(defcustom utter-format nil
  "The audio format, a symbol such as `mp3'; nil means the backend's first."
  :type '(choice (const :tag "Backend default" nil) symbol)
  :group 'utter)

(defcustom utter-voice-alist nil
  "Alist of (LANGUAGE . VOICE) used when `utter-voice' is nil.
LANGUAGE is a symbol such as `zh' or `en'.  When `utter-language'
is `auto' the language is guessed from the text."
  :type '(alist :key-type symbol :value-type string)
  :group 'utter)

(defcustom utter-speed 1.0
  "Synthesis speed, 1.0 being normal.  Part of the cache key."
  :type 'number
  :group 'utter)

(defcustom utter-playback-rate 1.0
  "Player rate, 1.0 being normal.
Unlike `utter-speed' it needs no new synthesis.  See
`utter-rate-up' and `utter-rate-down'."
  :type 'number
  :group 'utter)

(defcustom utter-language 'auto
  "Language of the text: a symbol or string, or `auto' to guess."
  :type '(choice (const auto) symbol string)
  :group 'utter)

(defcustom utter-instructions nil
  "Speaking instructions for backends that accept them, or nil."
  :type '(choice (const :tag "None" nil) string)
  :group 'utter)

(defcustom utter-highlight nil
  "When non-nil, highlight the text being spoken in its buffer.
The highlight is removed as soon as the buffer text changes."
  :type 'boolean
  :group 'utter)

(defcustom utter-highlight-follow nil
  "When non-nil, scroll windows so the highlighted text stays visible.
This is the only option that lets utter move point."
  :type 'boolean
  :group 'utter)

(defcustom utter-lighter " ♪%i/%n"
  "Mode line lighter shown while speaking, or nil for none.
A `format-spec' string, see `utter-state-string'.  \"%i/%n\" is
dropped when only one utterance is queued."
  :type '(choice (const :tag "None" nil) string)
  :group 'utter)

(defcustom utter-prefetch-depth 2
  "How many parts of the queued text to synthesize ahead of playback."
  :type 'natnum
  :group 'utter)

(defcustom utter-max-concurrent-requests 2
  "Maximum number of synthesis requests running at once."
  :type 'natnum
  :group 'utter)

(defcustom utter-player 'auto
  "The audio player: an `utter-player', a symbol naming one, or `auto'.
`auto' picks the first installed player that plays the audio format,
from `utter-player-afplay' (macOS), `utter-player-ffplay' and
`utter-player-mpv'."
  :type '(choice (const auto) symbol sexp)
  :group 'utter)

(defcustom utter-thing-at-point-functions '(utter--gptel-response-at-point)
  "Functions that find the text `utter-speak' reads when there is no region.
Each is called with no arguments and returns (BEG . END) or nil.
The first non-nil result wins; when all return nil, the sentence
at point is read."
  :type 'hook
  :group 'utter)

(defcustom utter-expert-commands nil
  "When non-nil, `utter-menu' shows expert commands such as Inspect."
  :type 'boolean
  :group 'utter)

;;;; Scope

(defvar utter--set-scope nil
  "Scope for settings changed from `utter-menu'.
Nil sets the global value, t sets it buffer-locally, and 1 sets
it for the next utterance only.")

;;;; Text at point

(defun utter--gptel-response-p (pos)
  "Return non-nil if the character at POS is part of a gptel response."
  (eq (get-text-property pos 'gptel) 'response))

(defun utter--gptel-response-at-point ()
  "Return (BEG . END) of the gptel response at point, or nil.
Reads the `gptel' text property, so gptel need not be loaded."
  (when-let* ((pos (cond ((and (< (point) (point-max))
                               (utter--gptel-response-p (point)))
                          (point))
                         ((and (> (point) (point-min))
                               (utter--gptel-response-p (1- (point))))
                          (1- (point))))))
    (cons (previous-single-property-change (1+ pos) 'gptel nil (point-min))
          (next-single-property-change pos 'gptel nil (point-max)))))

(defun utter--text-bounds ()
  "Return (BEG . END) of the text `utter-speak' reads, or nil.
The region if active, else the first claim of
`utter-thing-at-point-functions', else the sentence at point."
  (let ((b (cond ((use-region-p) (cons (region-beginning) (region-end)))
                 ((run-hook-with-args-until-success 'utter-thing-at-point-functions))
                 (t (bounds-of-thing-at-point 'sentence)))))
    (and b (< (car b) (cdr b))
         (string-match-p "[^ \t\n]" (buffer-substring-no-properties (car b) (cdr b)))
         b)))

(defun utter--text-at-point (&optional _arg)
  "Return (TEXT . SOURCE-NAME) for what `utter-speak' reads.
TEXT is the region, else the first claim of
`utter-thing-at-point-functions', else the sentence at point.
When `utter-highlight' is on, TEXT carries position tags.  Signal
a `user-error' when there is nothing to read."
  (let ((b (or (utter--text-bounds) (user-error "Nothing to read here"))))
    (cons (utter--buffer-text (car b) (cdr b)) (buffer-name))))

(defun utter--speak-at-point (function)
  "Pass the text at point to FUNCTION, `utter-enqueue' or `utter-interrupt'."
  (funcall function (car (utter--text-at-point))
           :source-buffer (current-buffer)))

(defun utter--open-menu ()
  "Open `utter-menu'."
  (call-interactively #'utter-menu))

;;;; Commands

;;;###autoload
(defun utter-speak (&optional arg)
  "Read aloud the region, the thing at point, or the sentence at point.
The text is appended to the queue.  The thing at point is found by
`utter-thing-at-point-functions', for example a gptel response.
With prefix ARG, open `utter-menu' instead."
  (interactive "P")
  (if arg
      (utter--open-menu)
    (utter--speak-at-point #'utter-enqueue)))

;;;###autoload
(defun utter-speak-interrupt (&optional arg)
  "Like `utter-speak', but stop what is playing and read the text now.
With prefix ARG, open `utter-menu' instead."
  (interactive "P")
  (if arg
      (utter--open-menu)
    (utter--speak-at-point #'utter-interrupt)))

;;;###autoload
(defun utter-speak-string (string &rest params)
  "Read STRING aloud after what is already queued.
PARAMS are as for `utter-enqueue'; in addition :interrupt non-nil
cuts in front of the queue with `utter-interrupt'.  This is the
entry point for other packages and for emacsclient -e.  Return the
new `utter-item'."
  (interactive (list (read-string "Speak: ")))
  (if (plist-get params :interrupt)
      (apply #'utter-interrupt string
             (cl-loop for (k v) on params by #'cddr
                      unless (eq k :interrupt) append (list k v)))
    (apply #'utter-enqueue string params)))

;;;###autoload
(defun utter-speak-buffer (&optional from-point)
  "Read the whole buffer aloud, or from point to the end with FROM-POINT."
  (interactive "P")
  (let ((beg (if from-point (point) (point-min))))
    (when (>= beg (point-max)) (user-error "Nothing to read here"))
    (utter-enqueue (utter--buffer-text beg (point-max))
                   :source-buffer (current-buffer))))

;;;###autoload
(defun utter-speak-kill ()
  "Read the latest kill aloud."
  (interactive)
  (let ((text (current-kill 0 t)))
    (unless (and text (string-match-p "[^ \t\n]" text))
      (user-error "The kill ring is empty"))
    (utter-enqueue (substring-no-properties text) :source-name "kill ring")))

(defun utter--text-for-command ()
  "Return the text `utter-speak' would read, as a plain string."
  (substring-no-properties (car (utter--text-at-point))))

(defun utter--single-segment (text params)
  "Return TEXT preprocessed for resolved PARAMS as one request-sized string.
Signal a `user-error' when TEXT needs several requests."
  (let* ((backend (plist-get params :backend))
         (pieces (utter--split (utter--preprocess text (current-buffer))
                               (or (utter-backend-max-chars backend)
                                   utter--default-max-chars)
                               (or (utter-backend-max-chars-unit backend) 'chars))))
    (cond ((null pieces) (user-error "Nothing to read"))
          ((cdr pieces)
           (user-error "The text needs %d requests; joining them into one \
file (with ffmpeg) is not supported yet" (length pieces)))
          (t (car pieces)))))

;;;###autoload
(defun utter-save-to-file (text file)
  "Synthesize TEXT and save the audio to FILE.
Interactively, TEXT is what `utter-speak' would read.  The audio
format follows the extension of FILE when the backend supports it.
Only text that fits one request can be saved for now."
  (interactive
   (let ((text (utter--text-for-command)))
     (list text (read-file-name "Save audio to: "))))
  (let* ((file (expand-file-name file))
         (ext (utter--format-symbol (file-name-extension file)))
         (params (utter--snapshot-params
                  (and ext (memq ext (utter-backend-formats
                                      (utter--resolve-backend utter-backend)))
                       (list :format ext))
                  text))
         (segment (utter--single-segment text params)))
    (apply #'utter-request segment
           :file file
           :callback (lambda (audio info)
                       (cond ((stringp audio) (message "utter: saved %s" file))
                             ((eq audio 'abort))
                             (t (message "utter: could not save %s: %s" file
                                         (or (plist-get info :error) "request failed")))))
           (utter--params-args params))))

;;;###autoload
(defun utter-inspect-query ()
  "Show the request `utter-speak' would send, without sending it.
The dry run goes to the *utter-inspect* buffer; secrets are redacted."
  (interactive)
  (let* ((text (utter--text-for-command))
         (params (utter--snapshot-params nil text))
         (pieces (utter--split (utter--preprocess text (current-buffer))
                               (or (utter-backend-max-chars (plist-get params :backend))
                                   utter--default-max-chars)
                               (or (utter-backend-max-chars-unit (plist-get params :backend))
                                   'chars)))
         (dry (apply #'utter-request (car pieces) :dry-run t
                     (utter--params-args params))))
    (with-current-buffer (get-buffer-create "*utter-inspect*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (lisp-data-mode)
        (insert (format ";; Dry run of the first of %d request%s.\n\n"
                        (length pieces) (if (cdr pieces) "s" "")))
        (pp dry (current-buffer))
        (goto-char (point-min)))
      (display-buffer (current-buffer)))))

(defun utter--voice-candidates (backend)
  "Return the voices of BACKEND as a list of (NAME . DESCRIPTION)."
  (let ((voices (utter-backend-voices backend)))
    (unless (consp voices)
      (setq voices nil)
      (when (fboundp 'utter--list-voices)
        ;; Static lists answer at once; fetched ones are cached by core.
        (let ((done nil) (deadline (+ (float-time) 5)))
          (with-demoted-errors "utter: cannot list voices: %S"
            (utter--list-voices backend
                                (lambda (result &rest _)
                                  (setq voices result done t))))
          (while (and (not done) (< (float-time) deadline))
            (accept-process-output nil 0.05)))))
    (mapcar (lambda (v)
              (cond ((consp v)
                     (cons (format "%s" (car v))
                           (let ((d (cdr v)))
                             (cond ((stringp d) d)
                                   ((and (consp d) (plist-get d :description)))
                                   ((stringp (car-safe d)) (car d))))))
                    (t (cons (format "%s" v) nil))))
            voices)))

(defun utter--read-voice ()
  "Read a voice for the current backend, with descriptions."
  (let* ((cands (utter--voice-candidates (utter--resolve-backend utter-backend)))
         (annotate (lambda (c)
                     (when-let* ((d (cdr (assoc c cands))))
                       (concat "  " d)))))
    (completing-read
     "Voice: "
     (lambda (str pred action)
       (if (eq action 'metadata)
           `(metadata (category . utter-voice) (annotation-function . ,annotate))
         (complete-with-action action (mapcar #'car cands) str pred)))
     nil nil nil nil (or utter-voice (caar cands)))))

;;;###autoload
(defun utter-select-voice (voice)
  "Set `utter-voice' to VOICE, respecting `utter--set-scope'."
  (interactive (list (utter--read-voice)))
  (utter--set-with-scope 'utter-voice voice utter--set-scope)
  (message "utter: voice %s" voice))

;;;###autoload
(defun utter-log ()
  "Show the *utter-log* buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create (or (bound-and-true-p utter--log-buffer-name)
                                       "*utter-log*"))))

;;;; Setting options with scope

(defun utter--set-with-scope (sym value &optional scope)
  "Set SYM to VALUE with SCOPE.
If SCOPE is t, set it buffer-locally.  If SCOPE is 1, set it for
the next utterance only: the old value comes back after the next
`utter-enqueue'.  Otherwise, clear any buffer-local value and set
the global value."
  (pcase scope
    (1 (unless (get sym 'utter-history)
         (put sym 'utter-history (list (symbol-value sym)))
         (letrec ((restore
                   (lambda (&rest _)
                     (remove-hook 'utter-enqueue-hook restore)
                     ;; Deferred so a surrounding let binding does not
                     ;; undo the restore.
                     (run-at-time 0 nil
                                  (lambda (s)
                                    (set s (car (get s 'utter-history)))
                                    (put s 'utter-history nil))
                                  sym))))
           (add-hook 'utter-enqueue-hook restore)))
       (set sym value))
    ('t (set (make-local-variable sym) value))
    (_ (kill-local-variable sym)
       (set sym value))))

;;;; Presets

(defvar utter--known-presets nil
  "Alist of (NAME . SPEC) for presets made with `utter-make-preset'.")

(defvar utter--preset nil
  "Name of the preset applied last, or nil.")

(defun utter-make-preset (name &rest keys)
  "Define an utter preset called NAME, a symbol, from KEYS.
Recognized KEYS are :description, :parents (a preset name or a
list of them, applied first), :pre and :post (functions of no
arguments run before and after applying), and the settings
:backend (a backend or its name), :model, :voice, :speed,
:format, :language and :instructions.  Any other :foo sets the
option `utter-foo', for example :playback-rate or :highlight.

  (utter-make-preset \\='en-fast
    :description \"Fast English\" :voice \"nova\" :speed 1.3)"
  (declare (indent 1))
  (if-let* ((p (assoc name utter--known-presets)))
      (setcdr p keys)
    (setq utter--known-presets
          (nconc utter--known-presets (list (cons name keys)))))
  name)

(defun utter-get-preset (name)
  "Return the spec of the utter preset called NAME."
  (alist-get name utter--known-presets nil nil #'equal))

(defun utter--preset-spec (preset)
  "Return the plist spec of PRESET, a name or a spec."
  (if (memq (type-of preset) '(symbol string))
      (or (utter-get-preset preset)
          (user-error "Cannot find utter preset %s" preset))
    preset))

(defun utter--preset-var (key)
  "Return the variable set by preset KEY, or nil."
  (let ((suffix (substring (symbol-name key) 1)))
    (cl-find-if #'boundp
                (list (intern-soft (concat "utter-" suffix))
                      (intern-soft (concat "utter--" suffix))))))

(defun utter--preset-syms (preset)
  "Return the variables PRESET, a name or a spec, sets."
  (let ((spec (utter--preset-spec preset)) syms)
    (cl-loop for (key val) on spec by #'cddr
             do (pcase key
                  ((or :description :pre :post))
                  (:parents (setq syms (append (mapcan #'utter--preset-syms
                                                       (ensure-list val))
                                               syms)))
                  (_ (when-let* ((var (utter--preset-var key)))
                       (push var syms)))))
    (delete-dups syms)))

(defun utter--apply-preset (preset &optional setter)
  "Apply PRESET, a preset name or a spec, using SETTER.
SETTER is a function of (SYMBOL VALUE) and defaults to `set'."
  (unless setter (setq setter #'set))
  (when (memq (type-of preset) '(symbol string))
    (funcall setter 'utter--preset preset))
  (let ((spec (utter--preset-spec preset)))
    (when-let* ((pre (plist-get spec :pre))) (funcall pre))
    (dolist (parent (ensure-list (plist-get spec :parents)))
      (utter--apply-preset (utter--preset-spec parent) setter))
    (cl-loop
     for (key val) on spec by #'cddr
     do (pcase key
          ((or :description :parents :pre :post))
          (:backend
           (funcall setter 'utter-backend
                    (if (stringp val)
                        (or (utter-get-backend val)
                            (user-error "Cannot find utter backend %s" val))
                      val)))
          (_ (if-let* ((var (utter--preset-var key)))
                 (funcall setter var val)
               (display-warning
                '(utter presets)
                (format "utter preset: no setting for %s, ignoring" key))))))
    (when-let* ((post (plist-get spec :post))) (funcall post))))

(defmacro utter-with-preset (name &rest body)
  "Run BODY with utter preset NAME applied.
NAME is a preset name or a spec plist, and must be quoted.  The
settings are let-bound, so they only last for BODY; since
utterances snapshot their settings when queued, wrapping
`utter-speak-string' is enough."
  (declare (indent 1) (debug t))
  (let ((syms (make-symbol "syms")))
    `(let ((,syms (cons 'utter--preset (utter--preset-syms ,name))))
       (cl-progv ,syms (mapcar #'symbol-value ,syms)
         (utter--apply-preset ,name)
         ,@body))))

(provide 'utter)
;;; utter.el ends here
