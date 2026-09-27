;;; utter-test-server.el --- Local HTTP stub for utter tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A tiny HTTP/1.1 server on 127.0.0.1 for tests that drive curl.
;;
;;   (utter-test-server-with (port `(("^/v1/audio/speech$"
;;                                    . (:headers (("Content-Type" . "audio/mpeg"))
;;                                       :body ,(utter-test-server-mp3-bytes)))))
;;     ... start an async request against (utter-test-server-url "/v1/...") ...
;;     (utter-test-server-wait-for (lambda () done))
;;     (should (equal (utter-test-server-header
;;                     (car (utter-test-server-requests)) "Authorization")
;;                    "Bearer sk-test")))
;;
;; ROUTES is an alist of (PATH-REGEXP . RESPONDER).  The first regexp
;; that matches the request target (path plus query string) wins; no
;; match gives a 404.  RESPONDER is either a response plist
;;
;;   (:status 200 :headers (("Content-Type" . "audio/mpeg")) :body BYTES)
;;
;; or a function (METHOD PATH HEADERS BODY) returning such a plist.
;; :status defaults to 200 and :body to "".  The server always writes its
;; own Content-Length and "Connection: close", and closes after one
;; response.  A responder that signals produces a 500.
;;
;; The server lives in the same Emacs as the test, so the client must be
;; asynchronous (`make-process', `url-retrieve'); a synchronous
;; `call-process' curl blocks the event loop and hangs.  Wait with
;; `utter-test-server-wait-for'.  Bodies are unibyte strings and
;; round-trip byte for byte.  Chunked request bodies are not supported.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar utter-test-server--process nil "The listening server process.")
(defvar utter-test-server--routes nil "Routes of the running server.")
(defvar utter-test-server--requests nil "Recorded requests, newest first.")
(defvar utter-test-server--connections nil "Open client connections.")

(defconst utter-test-server--reasons
  '((100 . "Continue") (200 . "OK") (201 . "Created") (204 . "No Content")
    (400 . "Bad Request") (401 . "Unauthorized") (403 . "Forbidden")
    (404 . "Not Found") (422 . "Unprocessable Entity")
    (429 . "Too Many Requests") (500 . "Internal Server Error")
    (502 . "Bad Gateway") (503 . "Service Unavailable"))
  "Reason phrases for status lines.")

(defun utter-test-server-start (routes)
  "Start the stub server with ROUTES and return its port.
Any running stub is stopped first and the request log is cleared."
  (utter-test-server-stop)
  (setq utter-test-server--routes routes
        utter-test-server--requests nil)
  (setq utter-test-server--process
        (make-network-process
         :name "utter-test-server" :server t :family 'ipv4
         :host "127.0.0.1" :service t :coding 'binary :noquery t
         :filter #'utter-test-server--filter
         :sentinel #'utter-test-server--sentinel
         :log #'utter-test-server--accept))
  (process-contact utter-test-server--process :service))

(defun utter-test-server-stop ()
  "Stop the stub server and close every open connection."
  (mapc #'delete-process utter-test-server--connections)
  (setq utter-test-server--connections nil)
  (when (process-live-p utter-test-server--process)
    (delete-process utter-test-server--process))
  (setq utter-test-server--process nil))

(defun utter-test-server-running-p ()
  "Return non-nil when the stub server is listening."
  (process-live-p utter-test-server--process))

(defun utter-test-server-port ()
  "Return the port of the running stub server."
  (unless (utter-test-server-running-p)
    (error "The utter test server is not running"))
  (process-contact utter-test-server--process :service))

(defun utter-test-server-url (&optional path)
  "Return the URL of PATH (default \"/\") on the running stub server."
  (format "http://127.0.0.1:%d%s" (utter-test-server-port) (or path "/")))

(defun utter-test-server-requests ()
  "Return the recorded requests, oldest first.
Each is a plist (:method STRING :path STRING :headers ALIST :body BYTES).
HEADERS keeps names as the client sent them; see
`utter-test-server-header' for case-insensitive lookup."
  (reverse utter-test-server--requests))

(defun utter-test-server-header (request name)
  "Return the value of header NAME in REQUEST, ignoring case, or nil."
  (cdr (assoc name (plist-get request :headers) #'string-equal-ignore-case)))

(defun utter-test-server-wait-for (predicate &optional timeout)
  "Process events until PREDICATE returns non-nil; return its value.
Signal an error after TIMEOUT seconds (default 10)."
  (let ((deadline (+ (float-time) (or timeout 10)))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (or value (funcall predicate)
        (error "Timed out after %ss waiting for %S" (or timeout 10) predicate))))

(defmacro utter-test-server-with (spec &rest body)
  "Run BODY with a stub server; SPEC is (PORT-VAR ROUTES).
PORT-VAR is bound to the port.  `process-environment' gets no_proxy
for 127.0.0.1 so curl started in BODY bypasses any HTTP proxy.  The
server is stopped when BODY exits."
  (declare (indent 1) (debug ((symbolp form) body)))
  `(let* ((process-environment
           (append '("no_proxy=127.0.0.1,localhost"
                     "NO_PROXY=127.0.0.1,localhost")
                   process-environment))
          (,(car spec) (utter-test-server-start ,(cadr spec))))
     (ignore ,(car spec))
     (unwind-protect (progn ,@body)
       (utter-test-server-stop))))

;;;; Response helpers

(defun utter-test-server-json (object &optional status)
  "Return a response plist whose body is OBJECT encoded as JSON.
OBJECT is anything `json-encode' accepts, typically an alist.
STATUS defaults to 200."
  (list :status (or status 200)
        :headers '(("Content-Type" . "application/json"))
        :body (encode-coding-string (json-encode object) 'utf-8)))

(defun utter-test-server-mp3-bytes (&optional id3)
  "Return one silent MPEG-1 Layer III frame as a unibyte string.
The frame starts with the sync bytes \\xff\\xfb.  With ID3 non-nil,
prefix an empty ID3v2.4 tag so the bytes start with \"ID3\"."
  (concat (if id3 (unibyte-string ?I ?D ?3 4 0 0 0 0 0 0) "")
          ;; 128 kbit/s, 44.1 kHz, no padding: 417 bytes per frame.
          (unibyte-string #xff #xfb #x90 #x64)
          (make-string 413 0)))

(defun utter-test-server--u16 (n)
  "Return N as two little-endian bytes."
  (unibyte-string (logand n #xff) (logand (ash n -8) #xff)))

(defun utter-test-server--u32 (n)
  "Return N as four little-endian bytes."
  (concat (utter-test-server--u16 (logand n #xffff))
          (utter-test-server--u16 (logand (ash n -16) #xffff))))

(defun utter-test-server-wav-bytes (&optional samples rate)
  "Return a 16-bit mono PCM WAV file as a unibyte string.
SAMPLES is a list of signed 16-bit integers (default a short
triangle wave); RATE is the sample rate (default 24000).  The header
is the canonical 44 bytes."
  (let* ((samples (or samples '(0 8000 16000 8000 0 -8000 -16000 -8000)))
         (rate (or rate 24000))
         (data (mapconcat (lambda (s) (utter-test-server--u16 (logand s #xffff)))
                          samples ""))
         (size (length data)))
    (concat "RIFF" (utter-test-server--u32 (+ 36 size)) "WAVE"
            "fmt " (utter-test-server--u32 16)
            (utter-test-server--u16 1)           ; PCM
            (utter-test-server--u16 1)           ; mono
            (utter-test-server--u32 rate)
            (utter-test-server--u32 (* rate 2))  ; byte rate
            (utter-test-server--u16 2)           ; block align
            (utter-test-server--u16 16)          ; bits per sample
            "data" (utter-test-server--u32 size)
            data)))

;;;; Internals

(defun utter-test-server--accept (_server client _message)
  "Register the new CLIENT connection."
  (set-process-coding-system client 'binary 'binary)
  (set-process-query-on-exit-flag client nil)
  (push client utter-test-server--connections))

(defun utter-test-server--sentinel (proc _event)
  "Forget PROC once its connection has closed."
  (unless (process-live-p proc)
    (setq utter-test-server--connections
          (delq proc utter-test-server--connections))
    (delete-process proc)))

(defun utter-test-server--parse-head (head)
  "Parse the request line and headers in HEAD.
Return (METHOD TARGET HEADERS)."
  (let* ((lines (split-string head "\r\n"))
         (request-line (split-string (car lines) " ")))
    (list (nth 0 request-line)
          (nth 1 request-line)
          (delq nil
                (mapcar (lambda (line)
                          (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'"
                                              line)
                            (cons (match-string 1 line)
                                  (string-trim-right (match-string 2 line)))))
                        (cdr lines))))))

(defun utter-test-server--filter (proc string)
  "Accumulate STRING from PROC and answer once a full request is in."
  (let ((data (concat (or (process-get proc 'utter-data) "") string)))
    (process-put proc 'utter-data data)
    (unless (process-get proc 'utter-head)
      (when-let* ((end (string-search "\r\n\r\n" data)))
        (pcase-let* ((`(,method ,target ,headers)
                      (utter-test-server--parse-head (substring data 0 end)))
                     (len (cdr (assoc "content-length" headers
                                      #'string-equal-ignore-case))))
          (process-put proc 'utter-head
                       (list method target headers (+ end 4)
                             (if len (string-to-number len) 0)))
          (when (string-equal-ignore-case
                 (or (cdr (assoc "expect" headers #'string-equal-ignore-case))
                     "")
                 "100-continue")
            (process-send-string proc "HTTP/1.1 100 Continue\r\n\r\n")))))
    (pcase (process-get proc 'utter-head)
      (`(,method ,target ,headers ,start ,len)
       (when (and (>= (- (length data) start) len)
                  (not (process-get proc 'utter-answered)))
         (process-put proc 'utter-answered t)
         (let ((body (substring data start (+ start len))))
           (push (list :method method :path target :headers headers :body body)
                 utter-test-server--requests)
           (process-send-string
            proc (utter-test-server--response method target headers body))
           ;; Half-close: curl reads to Content-Length and closes; the
           ;; sentinel then deletes the connection.
           (process-send-eof proc)))))))

(defun utter-test-server--dispatch (method target headers body)
  "Return the response plist for a request of METHOD to TARGET.
HEADERS and BODY are passed to function responders."
  (let ((route (cl-find-if (lambda (r) (string-match-p (car r) target))
                           utter-test-server--routes)))
    (cond
     ((null route) (list :status 404 :body (format "No route for %s" target)))
     ((functionp (cdr route))
      (condition-case err
          (funcall (cdr route) method target headers body)
        (error (list :status 500 :body (error-message-string err)))))
     (t (cdr route)))))

(defun utter-test-server--response (method target headers body)
  "Return the raw HTTP response bytes for the request.
METHOD, TARGET, HEADERS and BODY describe the request."
  (let* ((resp (utter-test-server--dispatch method target headers body))
         (status (or (plist-get resp :status) 200))
         (payload (or (plist-get resp :body) ""))
         (payload (if (multibyte-string-p payload)
                      (encode-coding-string payload 'utf-8)
                    payload))
         (head (concat
                (format "HTTP/1.1 %d %s\r\n" status
                        (alist-get status utter-test-server--reasons "Status"))
                (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h)))
                           (cl-remove-if
                            (lambda (h)
                              (member (downcase (car h))
                                      '("content-length" "connection")))
                            (plist-get resp :headers))
                           "")
                (format "Content-Length: %d\r\nConnection: close\r\n\r\n"
                        (length payload)))))
    (concat (encode-coding-string head 'utf-8) payload)))

(provide 'utter-test-server)
;;; utter-test-server.el ends here
