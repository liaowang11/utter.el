;;; utter-say.el --- macOS say backend for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Keywords: multimedia, convenience
;; URL: https://github.com/liaowang11/utter.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A backend that runs the macOS `say' program:
;;
;;   say [-v VOICE] -r WPM -o FILE [--file-format=... --data-format=...] -f TEXTFILE
;;
;; Speed 1.0 is 175 words per minute.  The text goes through a
;; temporary file, never argv, so long text works.  Output formats are
;; aiff (the default) and m4a (AAC).
;;
;;   (utter-make-say "say" :voices '("Samantha" "Daniel" "Tingting"))
;;   (utter-make-say "say" :voices 'fetch)   ; parse `say -v ?'
;;
;; On macOS a backend named "say" is registered when this file loads,
;; by `utter-say-register-default'.

;;; Code:

(require 'utter-core)

(defcustom utter-say-program "say"
  "Name or path of the macOS `say' program."
  :type 'string
  :group 'utter)

(defconst utter-say--base-wpm 175
  "Words per minute at speed 1.0.")

(cl-defstruct (utter-say (:include utter-backend)
                         (:constructor utter--make-say)
                         (:copier nil))
  "A backend that runs the macOS `say' program.")

;;;###autoload
(cl-defun utter-make-say (name &key voices (formats '(aiff m4a)))
  "Register and return a macOS `say' backend called NAME.
VOICES is a list of voice names, or `fetch' to read them from
`say -v ?' when first needed.  With no voice, `say' uses the
system voice.  FORMATS lists output formats; the first is the
default.  Supported: aiff, m4a, wav."
  (declare (indent 1))
  (setf (utter-get-backend name)
        (utter--make-say :name name :voices voices :formats formats
                         :models '(say) :response-kind 'process
                         :capabilities nil)))

(defun utter-say--format-args (format)
  "Return the `say' arguments that select FORMAT."
  (pcase format
    ('m4a '("--file-format=m4af" "--data-format=aac"))
    ('wav '("--file-format=WAVE" "--data-format=LEI16@22050"))
    (_ '("--file-format=AIFF"))))

(cl-defmethod utter--process-argv ((_backend utter-say) _text params file text-file)
  "Return the `say' argv writing PARAMS' voice and speed to FILE from TEXT-FILE."
  (let ((voice (plist-get params :voice))
        (speed (or (plist-get params :speed) 1.0)))
    (append (list utter-say-program)
            (and voice (list "-v" voice))
            (list "-r" (number-to-string (round (* utter-say--base-wpm speed)))
                  "-o" file)
            (utter-say--format-args (plist-get params :format))
            (list "-f" text-file))))

(cl-defmethod utter--start-process ((backend utter-say) text params file callback)
  "Run `say' for BACKEND on TEXT with PARAMS into FILE; then call CALLBACK."
  (let* ((text-file (make-temp-file "utter-say" nil ".txt"))
         (buf (generate-new-buffer " *utter-say*"))
         (format (plist-get params :format)))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region text nil text-file nil 'silent))
    (make-process
     :name "utter-say" :buffer buf :noquery t
     :connection-type 'pipe :coding 'utf-8
     :command (utter--process-argv backend text params file text-file)
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((out (string-trim (with-current-buffer buf (buffer-string)))))
           (kill-buffer buf)
           (ignore-errors (delete-file text-file))
           (cond
            ((process-get proc 'utter-aborted))
            ((and (eq (process-status proc) 'exit) (= (process-exit-status proc) 0)
                  (file-exists-p file)
                  (> (file-attribute-size (file-attributes file)) 0))
             (funcall callback file format))
            (t (funcall callback nil
                        (format "say exited %s%s" (process-exit-status proc)
                                (if (string-empty-p out) "" (concat ": " out))))))))))))

(defun utter-say--parse-voices (output)
  "Parse OUTPUT of `say -v ?' into a list of (NAME . PLIST).
PLIST has :language and :description."
  (let (voices)
    (dolist (line (split-string output "\n" t) (nreverse voices))
      (when (string-match
             "\\`\\(.+?\\) +\\([a-z]\\{2,3\\}\\(?:[_-][A-Za-z0-9]+\\)+\\) +# ?\\(.*\\)\\'"
             line)
        (push (list (match-string 1 line)
                    :language (match-string 2 line)
                    :description (match-string 3 line))
              voices)))))

(cl-defmethod utter--list-voices ((backend utter-say) callback)
  "Call CALLBACK with BACKEND's voices, running `say -v ?' for `fetch'."
  (if (not (eq (utter-backend-voices backend) 'fetch))
      (cl-call-next-method)
    (let ((buf (generate-new-buffer " *utter-say-voices*")))
      (make-process
       :name "utter-say-voices" :buffer buf :noquery t
       :connection-type 'pipe :coding 'utf-8
       :command (list utter-say-program "-v" "?")
       :sentinel
       (lambda (proc _event)
         (unless (process-live-p proc)
           (let ((out (with-current-buffer buf (buffer-string))))
             (kill-buffer buf)
             (funcall callback
                      (and (= (process-exit-status proc) 0)
                           (utter-say--parse-voices out))))))))))

;;;###autoload
(defun utter-say-register-default ()
  "Register the default \"say\" backend unless it exists, and return it.
Its voices are fetched from `say -v ?'.  This file calls it at load
time on macOS; `utter.el' may call it for the default of
`utter-backend'."
  (or (utter-get-backend "say")
      (utter-make-say "say" :voices 'fetch)))

(when (eq system-type 'darwin)
  (utter-say-register-default))

(provide 'utter-say)
;;; utter-say.el ends here
