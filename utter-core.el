;;; utter-core.el --- Backend and request layer for utter -*- lexical-binding: t; -*-

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

;; The backend layer of utter: the `utter-backend' struct and its
;; registry, the generic functions a backend implements, API key
;; lookup, the curl runner, response decoders, the audio cache and
;; `utter-request', which synthesizes one piece of text that fits the
;; backend's `max-chars'.
;;
;; curl is always run with a single config on stdin (`-K -') that
;; carries the URL, the headers and the body file, so API keys never
;; appear in the process arguments.  Every response is checked: a
;; non-2xx status is an error, `utter--parse-error' runs on every
;; response (some vendors report errors with HTTP 200), and the
;; `bytes' decoder sniffs the first bytes of the body before handing a
;; file to a player.  Raw PCM is wrapped in a WAV header.
;;
;; Splitting long text, queueing and playback live in other files.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'json)
(require 'subr-x)

;;;; Variables owned by other modules

;; Defined as defcustoms in utter.el.  `utter-request' reads them
;; through `bound-and-true-p' so this file works on its own.
(defvar utter-backend)
(defvar utter-model)
(defvar utter-voice)
(defvar utter-speed)
(defvar utter-format)

;; gptel is optional; only struct accessors are used, behind `fboundp'.
(defvar gptel--known-backends)
(declare-function gptel-backend-name "ext:gptel-request" (backend))
(declare-function gptel-backend-host "ext:gptel-request" (backend))
(declare-function gptel-backend-key "ext:gptel-request" (backend))

;;;; Customization

(defgroup utter nil
  "Read text aloud through text-to-speech backends."
  :group 'multimedia
  :prefix "utter-")

(defcustom utter-cache-directory
  (expand-file-name "utter" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory holding synthesized audio, one file per request."
  :type 'directory)

(defcustom utter-cache-max-size (* 500 1024 1024)
  "Maximum total size of `utter-cache-directory' in bytes.
`utter-cache-prune' deletes the least recently accessed files
above this size.  nil means unlimited."
  :type '(choice (const :tag "Unlimited" nil) integer))

(defcustom utter-voice-cache-ttl 86400
  "Seconds a fetched voice list stays valid."
  :type 'integer)

(defcustom utter-curl-program "curl"
  "Name or path of the curl executable."
  :type 'string)

(defcustom utter-proxy ""
  "Proxy passed to curl, or the empty string for none.
It goes into the curl config on stdin, so credentials in it do not
appear in process listings."
  :type 'string)

(defcustom utter-log-level nil
  "How much to write to the `*utter-log*' buffer.
nil logs nothing, `info' logs requests and errors, `debug' also
logs request bodies.  Header values are never logged."
  :type '(choice (const :tag "Off" nil) (const info) (const debug)))

(defcustom utter-pre-request-hook nil
  "Normal hook run before each request is started.
The request's INFO plist is available in `utter-request-info'."
  :type 'hook)

(defcustom utter-post-request-hook nil
  "Normal hook run after each request finishes, succeeds or fails.
The request's INFO plist is available in `utter-request-info'."
  :type 'hook)

(defvar utter-request-info nil
  "INFO plist of the request whose hook is running.
Bound around `utter-pre-request-hook' and `utter-post-request-hook'.")

(define-error 'utter-text-too-long "Text exceeds the backend's max-chars")

;;;; Logging

(defconst utter--log-buffer-name "*utter-log*"
  "Name of the buffer that `utter--log' writes to.")

(defun utter--log (level fmt &rest args)
  "Log FMT with ARGS to `utter--log-buffer-name' at LEVEL.
LEVEL is `info' or `debug'; see `utter-log-level'."
  (when (and utter-log-level
             (or (eq utter-log-level 'debug) (eq level 'info)))
    (with-current-buffer (get-buffer-create utter--log-buffer-name)
      (save-excursion
        (goto-char (point-max))
        (insert (format-time-string "%F %T ") (apply #'format fmt args) "\n")))))

;;;; Backend struct and registry

(cl-defstruct (utter-backend (:constructor utter--make-backend)
                             (:copier utter--copy-backend))
  "A text-to-speech backend.
See DESIGN.md for the meaning of each slot."
  name host protocol endpoint url header key
  models voices formats max-chars
  (max-chars-unit 'chars)
  (response-kind 'bytes)
  response-path
  capabilities
  request-params curl-args body-transform
  (coding-system 'binary))

(defvar utter--known-backends nil
  "Alist of registered backends, (NAME . BACKEND).")

(defun utter-get-backend (name)
  "Return the backend registered under NAME, or nil.
Use (setf (utter-get-backend NAME) BACKEND) to register one."
  (alist-get name utter--known-backends nil nil #'equal))

(gv-define-setter utter-get-backend (val name)
  `(setf (alist-get ,name utter--known-backends nil t #'equal) ,val))

(defun utter--resolve-backend (backend)
  "Return the backend object for BACKEND, a backend or a name."
  (cond
   ((utter-backend-p backend) backend)
   ((and (stringp backend) (utter-get-backend backend)))
   ((null backend)
    (user-error "No utter backend; define one with `utter-make-openai' or `utter-make-say'"))
   (t (user-error "Unknown utter backend: %S" backend))))

(defun utter--maybe-funcall (value &rest args)
  "Return VALUE, or the result of calling it with ARGS if it is a function.
Symbols that name functions are called too, except nil and t."
  (if (and (functionp value) (not (memq value '(nil t))))
      (apply value args)
    value))

;;;; Models, voices, formats

(defun utter--model-name (model)
  "Return the symbol of MODEL, a symbol or (SYMBOL . PLIST)."
  (if (consp model) (car model) model))

(defun utter--model-plist (backend model)
  "Return the plist of MODEL in BACKEND's models, or nil."
  (cl-loop for m in (utter-backend-models backend)
           when (and (consp m) (eq (car m) model)) return (cdr m)))

(defun utter--voice-name (voice)
  "Return the name of VOICE, a string or (NAME . PLIST)."
  (if (consp voice) (car voice) voice))

(defun utter--static-voices (backend &optional model)
  "Return BACKEND's voice list for MODEL without fetching.
Model-level `:voices' wins.  Fetched lists come from the voice cache.
Return nil when nothing is known yet."
  (let ((mv (plist-get (utter--model-plist backend model) :voices))
        (bv (utter-backend-voices backend)))
    (cond
     ((consp mv) mv)
     ((consp bv) bv)
     (t (utter--cached-voices backend)))))

(defun utter--formats (backend &optional model)
  "Return the formats of BACKEND for MODEL; model-level `:formats' wins."
  (or (plist-get (utter--model-plist backend model) :formats)
      (utter-backend-formats backend)))

(defun utter--capable-p (backend model capability)
  "Return non-nil if MODEL on BACKEND has CAPABILITY.
A model-level `:capabilities' list replaces the backend's."
  (let ((mplist (utter--model-plist backend model)))
    (memq capability
          (if (plist-member mplist :capabilities)
              (plist-get mplist :capabilities)
            (utter-backend-capabilities backend)))))

(defun utter--text-length (text unit)
  "Return the length of TEXT counted in UNIT.
UNIT is `chars', `bytes' (UTF-8) or `utf16' (UTF-16 code units)."
  (pcase unit
    ('bytes (string-bytes (encode-coding-string text 'utf-8)))
    ('utf16 (/ (length (encode-coding-string text 'utf-16le)) 2))
    (_ (length text))))

;;;; Generic functions

(cl-defgeneric utter--request-data (backend text params)
  "Return the request body for TEXT on BACKEND as a plist.
PARAMS is a plist (:model :voice :speed :format :language
:instructions :context), already resolved and normalized.  The
body is JSON-encoded later, after `request-params' are merged.")

(cl-defmethod utter--request-data ((backend utter-backend) _text _params)
  "Signal an error: BACKEND must implement a method."
  (error "Utter: backend %s does not implement `utter--request-data'"
         (utter-backend-name backend)))

(cl-defgeneric utter--normalize-params (backend params)
  "Return PARAMS adjusted for BACKEND: clamp values, rename, drop keys.")

(cl-defmethod utter--normalize-params ((backend utter-backend) params)
  "Drop :instructions from PARAMS when BACKEND's model cannot use them."
  (if (and (plist-get params :instructions)
           (not (utter--capable-p backend (plist-get params :model) 'instructions)))
      (plist-put params :instructions nil)
    params))

(cl-defgeneric utter--parse-error (backend info)
  "Return an error string for the response described by INFO, or nil.
It runs on every response, including HTTP 200, so a backend whose
vendor reports failures inside a 200 body can override it.  INFO
has :raw-file and :http-status.  BACKEND is the backend object.")

(cl-defmethod utter--parse-error ((_backend utter-backend) info)
  "Return an error for a non-2xx status in INFO, else nil.
The message is taken from the JSON body when there is one."
  (let ((status (plist-get info :http-status)))
    (unless (and (integerp status) (<= 200 status 299))
      (let ((msg (utter--error-from-file (plist-get info :raw-file))))
        (if msg (format "HTTP %s: %s" status msg) (format "HTTP %s" status))))))

(cl-defgeneric utter--response-audio (backend info callback)
  "Turn the raw response described by INFO into a playable file.
INFO has :raw-file :http-status :format :file.  Call CALLBACK with
\(FILE FORMAT) on success or (nil ERROR-STRING) on failure.  The
default method dispatches on BACKEND's `response-kind'.")

(cl-defmethod utter--response-audio ((backend utter-backend) info callback)
  "Decode INFO for BACKEND according to its `response-kind'; call CALLBACK."
  (pcase (utter-backend-response-kind backend)
    ('bytes (utter--decode-bytes backend info callback))
    ('b64-json (utter--decode-b64-json backend info callback))
    (kind (funcall callback nil
                   (format "utter: response kind `%s' is not implemented yet" kind)))))

(cl-defgeneric utter--list-voices (backend callback)
  "Call CALLBACK with BACKEND's voices, a list of NAME or (NAME . PLIST).
Fetched lists are cached per backend name for `utter-voice-cache-ttl'.")

(cl-defmethod utter--list-voices ((backend utter-backend) callback)
  "Call CALLBACK with BACKEND's voices from its `voices' slot.
A function in the slot is called with BACKEND and CALLBACK."
  (let ((voices (utter-backend-voices backend)))
    (cond
     ((eq voices 'fetch)
      (error "Utter: backend %s has :voices fetch but no `utter--list-voices' method"
             (utter-backend-name backend)))
     ((functionp voices) (funcall voices backend callback))
     (t (funcall callback voices)))))

(defvar utter--voice-cache (make-hash-table :test #'equal)
  "Fetched voice lists: backend name -> (TIME . VOICES).")

(defun utter--cached-voices (backend)
  "Return BACKEND's fetched voices if cached and fresh, else nil."
  (when-let* ((entry (gethash (utter-backend-name backend) utter--voice-cache)))
    (when (< (- (float-time) (car entry)) utter-voice-cache-ttl)
      (cdr entry))))

(defun utter--cache-voices (backend voices)
  "Store VOICES as BACKEND's fetched voice list and return VOICES."
  (puthash (utter-backend-name backend) (cons (float-time) voices) utter--voice-cache)
  voices)

(cl-defmethod utter--list-voices :around ((backend utter-backend) callback)
  "Serve BACKEND's fetched voices from the cache, or fetch and cache them.
Static lists bypass the cache.  CALLBACK receives the voices."
  (let ((slot (utter-backend-voices backend)))
    (if (not (or (eq slot 'fetch) (functionp slot)))
        (cl-call-next-method)
      (if-let* ((cached (utter--cached-voices backend)))
          (funcall callback cached)
        (cl-call-next-method
         backend
         (lambda (voices)
           (when voices (utter--cache-voices backend voices))
           (funcall callback voices)))))))

(cl-defgeneric utter--start-process (backend text params file callback)
  "Synthesize TEXT with PARAMS into FILE by running a program.
Only for backends whose `response-kind' is `process'.  Call
CALLBACK with (FILE FORMAT) or (nil ERROR-STRING).  Return the
process.  BACKEND is the backend object.")

(cl-defmethod utter--start-process ((backend utter-backend) _text _params _file _callback)
  "Signal an error: BACKEND has no process method."
  (error "Utter: backend %s does not implement `utter--start-process'"
         (utter-backend-name backend)))

;;;; API keys

(defun utter--get-api-key (backend)
  "Return BACKEND's API key as a string, or nil for none.
The `key' slot may be a string, a symbol whose value is resolved
again, or a function called with BACKEND (or with no argument if
it takes none).  Trailing newlines are removed."
  (utter--resolve-key (utter-backend-key backend) backend))

(defun utter--resolve-key (key backend)
  "Resolve KEY, a string, symbol or function, for BACKEND."
  (let ((val (cond
              ((null key) nil)
              ((stringp key) key)
              ((functionp key)
               (if (eq (car (func-arity key)) 0)
                   (if (and (numberp (cdr (func-arity key))) (= (cdr (func-arity key)) 0))
                       (funcall key)
                     (funcall key backend))
                 (funcall key backend)))
              ((and (symbolp key) (boundp key))
               (utter--resolve-key (symbol-value key) backend))
              (t (error "Utter: invalid key for backend %s: %S"
                        (and backend (utter-backend-name backend)) key)))))
    (when (stringp val)
      (let ((s (string-trim-right val "[\n\r]+")))
        (unless (string-empty-p s) s)))))

(defun utter-api-key-from-auth-source (&optional backend-or-host user)
  "Return the API key for BACKEND-OR-HOST from auth-source, or nil.
BACKEND-OR-HOST is a backend or a host string; it defaults to the
host of `utter-backend'.  USER defaults to \"apikey\", so the entry
looks like \"machine api.openai.com login apikey password KEY\",
the same one gptel uses."
  (let* ((host (cond ((stringp backend-or-host) backend-or-host)
                     ((utter-backend-p backend-or-host) (utter-backend-host backend-or-host))
                     ((utter-backend-p (bound-and-true-p utter-backend))
                      (utter-backend-host utter-backend))))
         (secret (and host
                      (plist-get (car (auth-source-search
                                       :host host :user (or user "apikey")
                                       :require '(:secret) :max 1))
                                 :secret))))
    (if (functionp secret) (funcall secret) secret)))

(defun utter--gptel-backend (name-or-host)
  "Return the gptel backend whose name or host is NAME-OR-HOST, or nil.
Reads `gptel--known-backends' only when it is bound; calls no gptel
function except struct accessors."
  (when (and name-or-host
             (bound-and-true-p gptel--known-backends)
             (fboundp 'gptel-backend-host))
    (or (alist-get name-or-host gptel--known-backends nil nil #'equal)
        (cl-loop for (_ . b) in gptel--known-backends
                 when (equal (gptel-backend-host b) name-or-host) return b))))

(defun utter--gptel-key-value (key)
  "Resolve gptel KEY without calling gptel code; nil if that is impossible.
Strings are used as is, variables are read, and user lambdas are
called.  Functions named gptel-* are never called."
  (cond
   ((stringp key) key)
   ((and (symbolp key) key (string-prefix-p "gptel-" (symbol-name key))
         (fboundp key))
    nil)
   ((and (symbolp key) key (boundp key)) (utter--gptel-key-value (symbol-value key)))
   ((and (functionp key) (not (symbolp key)))
    (ignore-errors (funcall key)))))

(defun utter-key-from-gptel (&optional name-or-host)
  "Return a key function that reads the key of a gptel backend.
The gptel backend is the one named NAME-OR-HOST, or with that host;
by default the host of the utter backend using the key.  When
gptel is not loaded, has no such backend, or its key is gptel's
own auth-source function, the function falls back to
`utter-api-key-from-auth-source' for the host.  gptel is never
required.  Example: :key (utter-key-from-gptel \"ChatGPT\")."
  (lambda (&optional backend)
    (let* ((wanted (or name-or-host (and backend (utter-backend-host backend))))
           (gb (utter--gptel-backend wanted))
           (key (and gb (fboundp 'gptel-backend-key)
                     (utter--gptel-key-value (gptel-backend-key gb)))))
      (or (and key (string-trim-right key "[\n\r]+"))
          (utter-api-key-from-auth-source
           (or (and gb (gptel-backend-host gb))
               (and backend (utter-backend-host backend))
               wanted))))))

;;;; Headers and URL

(defun utter--backend-url (backend info)
  "Return the request URL of BACKEND for INFO."
  (or (utter--maybe-funcall (utter-backend-url backend) backend info)
      (concat (or (utter-backend-protocol backend) "https") "://"
              (utter-backend-host backend)
              (utter-backend-endpoint backend))))

(defun utter--backend-headers (backend info)
  "Return BACKEND's header alist for INFO, with Content-Type first."
  (cons '("Content-Type" . "application/json")
        (cl-remove-if (lambda (h) (or (null h) (null (cdr h))))
                      (utter--maybe-funcall (utter-backend-header backend) backend info))))

(defun utter-bearer-header (backend _info)
  "Return an Authorization: Bearer header alist for BACKEND.
Return nil when the key resolves to nil, as keyless servers need."
  (when-let* ((key (utter--get-api-key backend)))
    `(("Authorization" . ,(concat "Bearer " key)))))

(defun utter--redact-headers (headers)
  "Return HEADERS with every value except Content-Type replaced."
  (mapcar (lambda (h)
            (if (string-equal-ignore-case (car h) "Content-Type")
                h
              (cons (car h) "[redacted]")))
          headers))

;;;; curl

(defun utter--curl-quote (s)
  "Quote S for a curl config file."
  (concat "\""
          (replace-regexp-in-string
           "[\"\\\n\r\t]"
           (lambda (m)
             (pcase m ("\"" "\\\"") ("\\" "\\\\") ("\n" "\\n") ("\r" "\\r") ("\t" "\\t")))
           s t t)
          "\""))

(defun utter--curl-config (url headers data-file method &optional user)
  "Return a curl config string for URL, HEADERS, DATA-FILE and METHOD.
HEADERS is an alist.  DATA-FILE is sent with --data-binary.
METHOD is an HTTP method string or nil.  USER is sent with --user.
The config goes to curl on stdin, so secrets stay out of argv."
  (concat
   (format "url = %s\n" (utter--curl-quote url))
   (when method (format "request = %s\n" (utter--curl-quote method)))
   (mapconcat (lambda (h) (format "header = %s\n"
                                  (utter--curl-quote (format "%s: %s" (car h) (cdr h)))))
              headers "")
   "header = \"Expect:\"\n"
   (when user (format "user = %s\n" (utter--curl-quote user)))
   (when data-file (format "data-binary = %s\n" (utter--curl-quote (concat "@" data-file))))
   (cond
    ((not (string-empty-p (or utter-proxy "")))
     (format "proxy = %s\n" (utter--curl-quote utter-proxy)))
    ;; curl applies http_proxy even to loopback; local servers never
    ;; want it.
    ((utter--loopback-url-p url) "noproxy = \"*\"\n"))))

(defun utter--loopback-url-p (url)
  "Return non-nil if URL points at localhost or a loopback address."
  (string-match-p
   "\\`[a-z]+://\\(?:[^/@]*@\\)?\\(?:localhost\\|127\\.[0-9.]+\\|\\[::1\\]\\)\\(?:[:/?#]\\|\\'\\)"
   url))

(defun utter--curl-args (backend raw-file)
  "Return the curl argv for BACKEND writing the body to RAW-FILE."
  (append (list utter-curl-program "-sS" "-K" "-" "-o" raw-file "-w" "%{http_code}")
          (utter--maybe-funcall (utter-backend-curl-args backend))))

(defun utter--curl-run (backend url headers data-file method raw-file done)
  "Run curl for BACKEND and call DONE with (STATUS ERROR) when it exits.
URL, HEADERS, DATA-FILE and METHOD are as in `utter--curl-config'.
The body is written to RAW-FILE.  STATUS is the HTTP status as an
integer or nil; ERROR is a string when curl itself failed.
Return the process."
  (let* ((buf (generate-new-buffer " *utter-curl*"))
         (proc (make-process
                :name "utter-curl" :buffer buf
                :command (utter--curl-args backend raw-file)
                :connection-type 'pipe :noquery t
                :coding '(binary . utf-8-unix)
                :sentinel
                (lambda (p _event)
                  (unless (process-live-p p)
                    (let* ((out (with-current-buffer buf (buffer-string)))
                           (code (and (string-match "\\([0-9]\\{3\\}\\)\\'" out)
                                      (string-to-number (match-string 1 out))))
                           (exit (process-exit-status p))
                           (err (unless (and (eq (process-status p) 'exit) (= exit 0))
                                  (let ((msg (string-trim
                                              (if code (substring out 0 -3) out))))
                                    (format "curl exited %s%s" exit
                                            (if (string-empty-p msg) ""
                                              (concat ": " msg)))))))
                      (kill-buffer buf)
                      (unless (process-get p 'utter-aborted)
                        (funcall done (and code (/= code 0) code) err))))))))
    (process-send-string proc (utter--curl-config url headers data-file method))
    (process-send-eof proc)
    proc))

(defun utter--write-json-file (body)
  "Write BODY, a plist, as JSON to a temp file and return its name."
  (let ((coding-system-for-write 'utf-8-unix)
        (file (make-temp-file "utter-body" nil ".json")))
    (with-temp-file file
      (set-buffer-multibyte t)
      (insert (utter--json-encode body)))
    file))

(defun utter--json-encode (body)
  "Encode BODY, a plist, as a JSON string."
  (let ((s (json-serialize body :null-object :null :false-object :false)))
    (if (multibyte-string-p s) s (decode-coding-string s 'utf-8))))

(defun utter--json-read-file (file)
  "Parse FILE as JSON; objects become alists, arrays lists.
Return nil when FILE is not valid JSON."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (goto-char (point-min))
    (condition-case nil
        (json-parse-buffer :object-type 'alist :array-type 'list
                           :null-object nil :false-object :false)
      (error nil))))

(defun utter-fetch-json (backend method path callback &optional body)
  "Request PATH on BACKEND with METHOD and call CALLBACK with the JSON.
PATH is appended to BACKEND's protocol and host unless it is a full
URL.  BODY is an optional plist sent as JSON.  The request uses
the backend's headers and key through the same curl path as
`utter-request'.  CALLBACK is called with (JSON) on success, where
objects are alists and arrays lists, and with nil on failure; if
it accepts a second argument it receives an INFO plist with
:error and :http-status.  Return the process."
  (let* ((backend (utter--resolve-backend backend))
         (url (if (string-match-p "\\`https?://" path) path
                (concat (or (utter-backend-protocol backend) "https") "://"
                        (utter-backend-host backend) path)))
         (info (list :backend backend :url url))
         (raw (make-temp-file "utter-raw"))
         (data (and body (utter--write-json-file body)))
         (reply (lambda (json info)
                  (let ((max (cdr (func-arity callback))))
                    (if (or (eq max 'many) (and (numberp max) (>= max 2)))
                        (funcall callback json info)
                      (funcall callback json))))))
    (utter--log 'info "fetch %s %s" method url)
    (utter--curl-run
     backend url (utter--backend-headers backend info) data method raw
     (lambda (status err)
       (let ((info (plist-put info :http-status status)))
         (unwind-protect
             (let* ((err (or err
                             (utter--parse-error
                              backend (list :raw-file raw :http-status status))))
                    (json (and (not err) (utter--json-read-file raw)))
                    (err (or err (and (null json) "utter: response is not JSON"))))
               (when err
                 (utter--log 'info "fetch error %s: %s" url err)
                 (setq info (plist-put info :error err)))
               (funcall reply (and (not err) json) info))
           (when data (ignore-errors (delete-file data)))
           (ignore-errors (delete-file raw))))))))

;;;; Response decoding

(defun utter--file-head (file &optional n)
  "Return the first N (default 64) bytes of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (when (file-exists-p file)
      (insert-file-contents-literally file nil 0 (or n 64)))
    (buffer-string)))

(defun utter--sniff (head)
  "Classify HEAD, the first bytes of a response body.
Return `json' for a JSON body, `text' for HTML or XML, `audio' for a
known audio container or MPEG frame, `empty' for no bytes, or nil."
  (let ((case-fold-search nil)
        (h (if (multibyte-string-p head) (encode-coding-string head 'binary) head)))
    (cond
     ((string-empty-p h) 'empty)
     ((string-match-p "\\`[ \t\r\n]*[{[]" h) 'json)
     ((string-match-p "\\`[ \t\r\n]*<" h) 'text)
     ((string-match-p "\\`\\(?:ID3\\|RIFF\\|fLaC\\|OggS\\|FORM\\)" h) 'audio)
     ((and (>= (length h) 8) (equal (substring h 4 8) "ftyp")) 'audio)
     ((and (>= (length h) 2) (= (aref h 0) #xff) (>= (aref h 1) #xe0)) 'audio))))

(defun utter--error-from-json (json)
  "Return an error message found in parsed JSON, or nil."
  (cond
   ((stringp json) json)
   ((and (consp json) (not (consp (car json))))
    nil)
   ((and (consp json) (consp (car json)) (not (symbolp (caar json))))
    ;; A list (JSON array): look at the first element.
    (utter--error-from-json (car json)))
   ((consp json)
    (let ((err (alist-get 'error json))
          (detail (alist-get 'detail json)))
      (or (and err (utter--error-from-json
                    (if (stringp err) err (or (alist-get 'message err) err))))
          (and (stringp detail) detail)
          (and (consp detail) (consp (car detail)) (symbolp (caar detail))
               (or (alist-get 'message detail) (alist-get 'msg detail)))
          (and (consp detail) (utter--error-from-json-list detail))
          (let ((m (alist-get 'message json))) (and (stringp m) m)))))))

(defun utter--error-from-json-list (list)
  "Return the first msg or message in LIST, a JSON array of objects."
  (cl-loop for e in list
           when (and (consp e) (consp (car e)))
           return (or (alist-get 'msg e) (alist-get 'message e))))

(defun utter--error-from-string (body)
  "Return a short error message extracted from response BODY, or nil.
JSON bodies are searched for .error.message, .error, .detail,
.detail.message, .detail[0].msg and .message; arrays use their
first element.  Other bodies give their first 200 characters."
  (let ((s (string-trim (if (multibyte-string-p body) body
                          (decode-coding-string body 'utf-8)))))
    (unless (string-empty-p s)
      (or (and (memq (utter--sniff s) '(json))
               (utter--error-from-json
                (condition-case nil
                    (json-parse-string s :object-type 'alist :array-type 'list
                                       :null-object nil :false-object :false)
                  (error nil))))
          (truncate-string-to-width (car (split-string s "\n")) 200)))))

(defun utter--error-from-file (file)
  "Return an error message extracted from the body in FILE, or nil."
  (and file (file-exists-p file)
       (utter--error-from-string (utter--file-head file 4096))))

(defun utter--le-bytes (n size)
  "Return N as a little-endian unibyte string of SIZE bytes."
  (apply #'unibyte-string
         (cl-loop for i below size collect (logand (ash n (* -8 i)) #xff))))

(defun utter--le-int (bytes)
  "Return the integer encoded little-endian in unibyte string BYTES."
  (cl-loop for i below (length bytes)
           sum (ash (aref bytes i) (* 8 i))))

(defun utter--wav-header (data-size sample-rate &optional channels bits)
  "Return a 44-byte WAV header for DATA-SIZE bytes of PCM.
SAMPLE-RATE is in Hz; CHANNELS defaults to 1 and BITS to 16."
  (let* ((channels (or channels 1))
         (bits (or bits 16))
         (align (* channels (/ bits 8))))
    (concat "RIFF" (utter--le-bytes (+ 36 data-size) 4) "WAVE"
            "fmt " (utter--le-bytes 16 4) (utter--le-bytes 1 2)
            (utter--le-bytes channels 2) (utter--le-bytes sample-rate 4)
            (utter--le-bytes (* sample-rate align) 4) (utter--le-bytes align 2)
            (utter--le-bytes bits 2)
            "data" (utter--le-bytes data-size 4))))

(defun utter--wav-duration (file)
  "Return the duration in seconds of the plain PCM WAV FILE, or nil."
  (let ((h (utter--file-head file 44)))
    (when (and (= (length h) 44) (string-prefix-p "RIFF" h)
               (equal (substring h 36 40) "data"))
      (let ((rate (utter--le-int (substring h 28 32)))
            (size (utter--le-int (substring h 40 44))))
        (and (> rate 0) (/ (float size) rate))))))

(defun utter--container-format (format)
  "Return the file format audio in FORMAT is stored as; pcm becomes wav."
  (if (eq format 'pcm) 'wav format))

(defun utter--write-audio (bytes-or-file info)
  "Write audio to INFO's :file and return the resulting format.
BYTES-OR-FILE is a unibyte string, or (:file NAME) for a file to
move.  Raw PCM (INFO :format `pcm' without a RIFF header) is
wrapped in a WAV header at INFO :sample-rate (default 24000)."
  (let* ((out (plist-get info :file))
         (format (plist-get info :format))
         (src (and (consp bytes-or-file) (plist-get bytes-or-file :file)))
         (head (if src (utter--file-head src 4) (substring bytes-or-file 0 (min 4 (length bytes-or-file))))))
    (make-directory (file-name-directory (expand-file-name out)) t)
    (cond
     ((and (eq format 'pcm) (not (string-prefix-p "RIFF" head)))
      (let ((coding-system-for-write 'binary))
        (with-temp-file out
          (set-buffer-multibyte nil)
          (if src (insert-file-contents-literally src) (insert bytes-or-file))
          (goto-char (point-min))
          (insert (utter--wav-header (buffer-size)
                                     (or (plist-get info :sample-rate) 24000))))))
     (src (rename-file src out t))
     (t (let ((coding-system-for-write 'binary))
          (write-region bytes-or-file nil out nil 'silent))))
    (utter--container-format format)))

(defun utter--decode-bytes (_backend info callback)
  "Decode a raw audio body described by INFO and call CALLBACK.
The first bytes are sniffed: a JSON or HTML body is an error, known
audio is moved to INFO :file, and unknown bytes are accepted only
for the headerless `pcm' format."
  (let* ((raw (plist-get info :raw-file))
         (head (utter--file-head raw))
         (kind (utter--sniff head)))
    (pcase kind
      ((or 'json 'text)
       (funcall callback nil (format "HTTP %s with a %s body: %s"
                                     (plist-get info :http-status)
                                     (if (eq kind 'json) "JSON" "text")
                                     (or (utter--error-from-file raw) "?"))))
      ('empty (funcall callback nil "utter: empty response body"))
      (_
       (if (or (eq kind 'audio) (eq (plist-get info :format) 'pcm))
           (funcall callback (plist-get info :file)
                    (utter--write-audio (list :file raw) info))
         (funcall callback nil (format "utter: response is not audio (starts with %S)"
                                       (substring head 0 (min 8 (length head))))))))))

(defun utter--json-path (json path)
  "Follow PATH into JSON and return the value, or nil.
Each element is a key symbol or string, an integer index, `last',
a cons (KEY . VALUE) selecting the first array element whose KEY
equals VALUE, or a function object (not a symbol) applied to the
current value."
  (let ((node json))
    (dolist (step path node)
      (setq node
            (cond
             ((null node) nil)
             ((integerp step) (nth step node))
             ((eq step 'last) (car (last node)))
             ((and (functionp step) (not (symbolp step))) (funcall step node))
             ((consp step)
              (cl-find-if (lambda (e) (and (consp e) (consp (car e))
                                           (equal (alist-get (car step) e) (cdr step))))
                          node))
             ((and (consp node) (consp (car node)))
              (alist-get (if (stringp step) (intern step) step) node))
             (t nil))))))

(defun utter--decode-b64-json (backend info callback)
  "Decode base64 audio at BACKEND's `response-path' in INFO's body.
Call CALLBACK with the written file and its format."
  (let* ((raw (plist-get info :raw-file))
         (json (utter--json-read-file raw))
         (data (and json (utter--json-path json (utter-backend-response-path backend)))))
    (cond
     ((null json) (funcall callback nil "utter: response is not JSON"))
     ((not (stringp data))
      (funcall callback nil (format "utter: no audio at %S%s"
                                    (utter-backend-response-path backend)
                                    (if-let* ((e (utter--error-from-json json)))
                                        (concat ": " e) ""))))
     (t
      (let ((bytes (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert (encode-coding-string data 'us-ascii))
                     (condition-case nil
                         (progn (base64-decode-region (point-min) (point-max))
                                (buffer-string))
                       (error nil)))))
        (if (or (null bytes) (string-empty-p bytes))
            (funcall callback nil "utter: invalid base64 audio")
          (funcall callback (plist-get info :file) (utter--write-audio bytes info))))))))

;;;; Cache

(defun utter-cache-file (key format)
  "Return the cache file name for KEY and FORMAT; pcm is stored as wav."
  (expand-file-name (format "%s.%s" key (utter--container-format format))
                    utter-cache-directory))

(defun utter-cache-key (backend params text)
  "Return the cache key for TEXT synthesized by BACKEND with PARAMS.
It is the sha1 of the backend name, model, voice, speed, format,
language, instructions and TEXT.  Host and key are left out, so a
rotated key keeps the cache.  BACKEND is a backend or a name."
  (let ((name (if (utter-backend-p backend) (utter-backend-name backend) backend))
        (speed (plist-get params :speed)))
    (sha1 (encode-coding-string
           (prin1-to-string
            (list name (plist-get params :model) (plist-get params :voice)
                  (and speed (float speed)) (plist-get params :format)
                  (plist-get params :language) (plist-get params :instructions)
                  text))
           'utf-8))))

(defun utter-cache-lookup (key format)
  "Return the cached file for KEY and FORMAT, or nil if absent or empty."
  (let ((f (utter-cache-file key format)))
    (and (file-exists-p f)
         (> (file-attribute-size (file-attributes f)) 0)
         f)))

(defun utter--cache-files ()
  "Return the audio files in `utter-cache-directory'."
  (and (file-directory-p utter-cache-directory)
       (directory-files utter-cache-directory t "\\`[0-9a-f]\\{40\\}\\.[a-z0-9]+\\'")))

(defun utter-cache-clear (&optional older-than-days)
  "Delete cached audio files; with OLDER-THAN-DAYS only older ones.
Age is measured from the last access time.  Interactively, a
prefix argument gives OLDER-THAN-DAYS."
  (interactive "P")
  (let ((limit (and older-than-days
                    (- (float-time) (* 86400 (prefix-numeric-value older-than-days))))))
    (dolist (f (utter--cache-files))
      (when (or (null limit)
                (< (float-time (file-attribute-access-time (file-attributes f))) limit))
        (delete-file f)))))

(defun utter-cache-prune (&optional max-size)
  "Delete least recently accessed cache files above MAX-SIZE bytes.
MAX-SIZE defaults to `utter-cache-max-size'; nil means no limit."
  (let ((max (or max-size utter-cache-max-size)))
    (when max
      (let* ((files (mapcar (lambda (f) (cons f (file-attributes f))) (utter--cache-files)))
             (total (apply #'+ (mapcar (lambda (e) (file-attribute-size (cdr e))) files))))
        (dolist (e (sort files (lambda (a b)
                                 (time-less-p (file-attribute-access-time (cdr a))
                                              (file-attribute-access-time (cdr b))))))
          (when (> total max)
            (setq total (- total (file-attribute-size (cdr e))))
            (delete-file (car e))))))))

;;;; Requests

(cl-defstruct (utter-request (:constructor utter--make-request) (:copier nil))
  "A running or finished `utter-request' call.
STATUS is one of pending, running, done, error and aborted."
  process info (status 'pending) timer callback)

(defun utter--resolve-params (backend params)
  "Fill nil entries of PARAMS with BACKEND's defaults and normalize them."
  (let* ((model (or (plist-get params :model)
                    (utter--model-name (car (utter-backend-models backend)))))
         (model (if (stringp model) (intern model) model))
         (params (plist-put (copy-sequence params) :model model)))
    (unless (plist-get params :voice)
      ;; Only declared lists give a default voice; a fetched list has no
      ;; meaningful first entry, so backends handle a nil voice themselves.
      (let ((mv (plist-get (utter--model-plist backend model) :voices))
            (bv (utter-backend-voices backend)))
        (setq params (plist-put params :voice
                                (utter--voice-name
                                 (car (cond ((consp mv) mv) ((consp bv) bv))))))))
    (unless (plist-get params :format)
      (setq params (plist-put params :format (car (utter--formats backend model)))))
    (let ((fmt (plist-get params :format)))
      (when (stringp fmt) (setq params (plist-put params :format (intern fmt)))))
    (unless (plist-get params :speed)
      (setq params (plist-put params :speed 1.0)))
    (utter--normalize-params backend params)))

(defun utter--merge-plists (&rest plists)
  "Return a new plist merging PLISTS; later ones win."
  (let (res)
    (dolist (pl plists res)
      (while pl
        (setq res (plist-put res (pop pl) (pop pl)))))))

(defun utter--request-body (backend text params)
  "Return the final JSON body plist for TEXT on BACKEND with PARAMS.
Runs `utter--request-data', merges `request-params' and applies
`body-transform'."
  (let ((body (utter--merge-plists (copy-tree (utter--request-data backend text params))
                                   (copy-tree (utter-backend-request-params backend)))))
    (if-let* ((tf (utter-backend-body-transform backend)))
        (funcall tf body)
      body)))

(defun utter--finish (req audio &optional error)
  "Finish REQ with AUDIO (file, nil or `abort') and ERROR; call its callback once."
  (unless (memq (utter-request-status req) '(done error aborted))
    (let ((info (utter-request-info req)))
      (setf (utter-request-status req)
            (cond ((eq audio 'abort) 'aborted) (audio 'done) (t 'error)))
      (when error (setq info (plist-put info :error error)))
      (when (stringp audio)
        (setq info (plist-put info :file audio))
        (unless (plist-get info :duration)
          (setq info (plist-put info :duration (utter--wav-duration audio)))))
      (setf (utter-request-info req) info)
      (dolist (f (plist-get info :temp-files)) (ignore-errors (delete-file f)))
      ;; A failed or aborted request must not leave a partial file where
      ;; a later cache lookup would find it.
      (when-let* (((not (stringp audio)))
                  (partial (plist-get info :partial-file)))
        (ignore-errors (delete-file partial)))
      (utter--log 'info "%s %s%s" (utter-backend-name (plist-get info :backend))
                  (utter-request-status req) (if error (concat ": " error) ""))
      (let ((utter-request-info info))
        (run-hooks 'utter-post-request-hook))
      (when-let* ((cb (utter-request-callback req)))
        (funcall cb audio info)))))

(cl-defun utter-request
    (text &key (backend (bound-and-true-p utter-backend))
          (model (bound-and-true-p utter-model))
          (voice (bound-and-true-p utter-voice))
          (speed (bound-and-true-p utter-speed))
          (format (bound-and-true-p utter-format))
          language instructions context file callback dry-run (cache t))
  "Synthesize TEXT, which must fit BACKEND's max-chars, asynchronously.
Return an `utter-request' struct (slots: process info status).
BACKEND is a backend or its name; MODEL, VOICE, SPEED and FORMAT
default to the backend's first model, voice and format and 1.0.
LANGUAGE, INSTRUCTIONS and CONTEXT (a plist with :previous and
:next text, for stitching backends) are passed to the backend.
FILE is where the audio goes; otherwise the cache (when CACHE is
non-nil) or a temporary file.
CALLBACK is called (AUDIO INFO): AUDIO is a file name, nil on error
\(INFO :error), or the symbol `abort'.  INFO keys: :backend :model :voice
:speed :format :text :file :cached :http-status :error :duration :request.
With DRY-RUN, return a plist (:url :headers :body :curl-args), with
header values redacted, and start nothing.
Signals `utter-text-too-long' instead of splitting."
  (let* ((backend (utter--resolve-backend backend))
         (max (utter-backend-max-chars backend))
         (unit (utter-backend-max-chars-unit backend)))
    (when (and max (> (utter--text-length text unit) max))
      (signal 'utter-text-too-long
              (list (utter-backend-name backend) (utter--text-length text unit) max)))
    (let* ((params (utter--resolve-params
                    backend (list :model model :voice voice :speed speed :format format
                                  :language language :instructions instructions
                                  :context context)))
           (fmt (plist-get params :format))
           (key (and cache (utter-cache-key backend params text)))
           (info (append (list :backend backend :text text :cached nil) params))
           (req (utter--make-request :info info :callback callback))
           (process-kind (eq (utter-backend-response-kind backend) 'process)))
      (setq info (plist-put info :request req))
      (cond
       (dry-run
        (if process-kind
            (list :url nil :headers nil :body nil :curl-args nil
                  :command (utter--process-command backend text params))
          (let ((raw "RAWFILE"))
            (list :url (utter--backend-url backend info)
                  :headers (utter--redact-headers (utter--backend-headers backend info))
                  :body (utter--request-body backend text params)
                  :curl-args (utter--curl-args backend raw)))))
       ((and key (utter-cache-lookup key fmt))
        (let ((hit (utter-cache-lookup key fmt)))
          (when file
            (make-directory (file-name-directory (expand-file-name file)) t)
            (copy-file hit file t))
          (setq info (plist-put info :cached t))
          (setf (utter-request-info req) info)
          (setf (utter-request-status req) 'running)
          (setf (utter-request-timer req)
                (run-at-time 0 nil (lambda ()
                                     (setf (utter-request-info req)
                                           (plist-put (utter-request-info req)
                                                      :format (utter--container-format fmt)))
                                     (utter--finish req (or file hit)))))
          req))
       (t
        (let* ((out (or file
                        (and key (utter-cache-file key fmt))
                        (make-temp-file "utter-" nil
                                        (concat "." (symbol-name (utter--container-format fmt))))))
               (on-audio
                (lambda (audio-file result)
                  (if (null audio-file)
                      (utter--finish req nil result)
                    (setf (utter-request-info req)
                          (plist-put (utter-request-info req) :format result))
                    (when (and file key)
                      (ignore-errors
                        (make-directory utter-cache-directory t)
                        (copy-file audio-file (utter-cache-file key fmt) t)))
                    (utter--finish req audio-file)))))
          (setq info (plist-put info :file out))
          (unless file (setq info (plist-put info :partial-file out)))
          (setf (utter-request-info req) info)
          (let ((utter-request-info info))
            (run-hooks 'utter-pre-request-hook))
          (setf (utter-request-status req) 'running)
          (make-directory (file-name-directory (expand-file-name out)) t)
          (if process-kind
              (setf (utter-request-process req)
                    (utter--start-process backend text params out on-audio))
            (utter--start-curl req backend text params out on-audio))
          req))))))

(defun utter--process-command (backend text params)
  "Return the argv a `process' BACKEND would run for TEXT and PARAMS.
Backends may define a method on `utter--process-argv'; the default
returns nil."
  (utter--process-argv backend text params "OUTFILE" "TEXTFILE"))

(cl-defgeneric utter--process-argv (backend text params file text-file)
  "Return the argv that BACKEND runs to write TEXT with PARAMS into FILE.
TEXT-FILE holds TEXT.  Used for dry runs and by process backends.")

(cl-defmethod utter--process-argv ((_backend utter-backend) _text _params _file _text-file)
  "Return nil: plain backends run no program."
  nil)

(defun utter--start-curl (req backend text params out on-audio)
  "Start the curl request REQ for TEXT on BACKEND with PARAMS.
OUT is the destination file; ON-AUDIO receives (FILE FORMAT) or
\(nil ERROR)."
  (let* ((info (utter-request-info req))
         (body (utter--request-body backend text params))
         (data (utter--write-json-file body))
         (raw (make-temp-file "utter-raw"))
         (url (utter--backend-url backend info))
         (headers (utter--backend-headers backend info)))
    (setf (utter-request-info req)
          (setq info (plist-put info :temp-files (list data raw))))
    (utter--log 'info "request %s %s" (utter-backend-name backend) url)
    (utter--log 'debug "body %s" (utter--json-encode body))
    (setf (utter-request-process req)
          (utter--curl-run
           backend url headers data nil raw
           (lambda (status err)
             (let ((info (plist-put (utter-request-info req) :http-status status)))
               (setf (utter-request-info req) info)
               (if err
                   (utter--finish req nil err)
                 (let* ((rinfo (list :raw-file raw :http-status status
                                     :format (plist-get params :format)
                                     :file out
                                     :sample-rate (plist-get params :sample-rate)))
                        (perr (or (utter--parse-error backend rinfo)
                                  (unless (and status (<= 200 status 299))
                                    (format "HTTP %s" status)))))
                   (if perr
                       (utter--finish req nil perr)
                     (condition-case e
                         (utter--response-audio backend rinfo on-audio)
                       (error (utter--finish req nil (error-message-string e)))))))))))))

(defun utter-abort (request)
  "Abort REQUEST, an `utter-request' struct.
Its process is killed and its callback called with `abort'."
  (when (utter-request-p request)
    (when-let* ((timer (utter-request-timer request)))
      (cancel-timer timer))
    (when-let* ((proc (utter-request-process request)))
      (process-put proc 'utter-aborted t)
      (when (process-live-p proc) (delete-process proc)))
    (utter--finish request 'abort)))

(provide 'utter-core)
;;; utter-core.el ends here
