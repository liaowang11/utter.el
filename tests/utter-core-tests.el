;;; utter-core-tests.el --- Tests for utter-core -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Unit tests for `utter-core'.  The local HTTP stub server defined
;; here is shared by the other backend test files through
;; (require 'utter-core-tests).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'utter-core)
(require 'utter-test-server)

;;;; Helpers

(defmacro utter-test-with-temp-dir (var &rest body)
  "Bind VAR to a fresh temporary directory while running BODY."
  (declare (indent 1))
  `(let ((,var (make-temp-file "utter-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun utter-test-file-bytes (file)
  "Return the contents of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun utter-test-write-bytes (file bytes)
  "Write unibyte BYTES to FILE."
  (let ((coding-system-for-write 'binary))
    (write-region bytes nil file nil 'silent)))

;;;; Registry

(ert-deftest utter-core-test-registry ()
  (let ((utter--known-backends nil)
        (b (utter--make-backend :name "X")))
    (setf (utter-get-backend "X") b)
    (should (eq (utter-get-backend "X") b))
    (should-not (utter-get-backend "Y"))
    (setf (utter-get-backend "X") nil)
    (should-not (utter-get-backend "X"))
    (should-not utter--known-backends)))

;;;; Cache key

(ert-deftest utter-core-test-cache-key-stable ()
  (let ((b (utter--make-backend :name "B"))
        (p '(:model m :voice "v" :speed 1.0 :format mp3)))
    (should (equal (utter-cache-key b p "hi") (utter-cache-key b p "hi")))
    (should (equal (utter-cache-key b p "hi") (utter-cache-key "B" p "hi")))
    (should (equal (utter-cache-key b p "hi")
                   (utter-cache-key b '(:model m :voice "v" :speed 1 :format mp3
                                        :context (:previous "x"))
                                    "hi")))
    (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (utter-cache-key b p "hi")))
    (should-not (equal (utter-cache-key b p "hi") (utter-cache-key b p "ho")))
    (should-not (equal (utter-cache-key b p "hi")
                       (utter-cache-key b (plist-put (copy-sequence p) :voice "w") "hi")))
    (should-not (equal (utter-cache-key b p "hi")
                       (utter-cache-key b (append p '(:instructions "calm")) "hi")))))

(ert-deftest utter-core-test-cache-lookup-and-clear ()
  (utter-test-with-temp-dir dir
    (let ((utter-cache-directory dir))
      (should-not (utter-cache-lookup (make-string 40 ?a) 'mp3))
      (let* ((key (make-string 40 ?a))
             (f (expand-file-name (concat key ".mp3") dir))
             (sidecar (utter-cache-alignment-file key))
             (orphan (utter-cache-alignment-file (make-string 40 ?c))))
        (utter-test-write-bytes f "ID3xx")
        (utter-test-write-bytes sidecar "{}")
        (utter-test-write-bytes orphan "{}")
        (should (equal (utter-cache-lookup key 'mp3) f))
        ;; pcm is stored wrapped as wav
        (should (string-suffix-p ".wav" (utter-cache-file (make-string 40 ?b) 'pcm)))
        (utter-test-write-bytes (expand-file-name "notes.txt" dir) "keep")
        (utter-cache-clear 1)
        (should (file-exists-p f))
        (should (file-exists-p sidecar))
        (should-not (file-exists-p orphan))
        (utter-cache-clear)
        (should-not (file-exists-p f))
        (should-not (file-exists-p sidecar))
        (should (file-exists-p (expand-file-name "notes.txt" dir)))))))

(ert-deftest utter-core-test-cache-prune ()
  (utter-test-with-temp-dir dir
    (let* ((utter-cache-directory dir)
           (old-key (make-string 40 ?a))
           (old (expand-file-name (concat old-key ".mp3") dir))
           (sidecar (utter-cache-alignment-file old-key))
           (orphan (utter-cache-alignment-file (make-string 40 ?c)))
           (new (expand-file-name (concat (make-string 40 ?b) ".mp3") dir)))
      (utter-test-write-bytes old (make-string 100 ?x))
      (utter-test-write-bytes sidecar (make-string 100 ?x))
      (utter-test-write-bytes orphan "{}")
      (utter-test-write-bytes new (make-string 100 ?x))
      (set-file-times old (time-subtract nil 1000) 'nofollow)
      (utter-cache-prune 250)
      (should-not (file-exists-p old))
      (should-not (file-exists-p sidecar))
      (should-not (file-exists-p orphan))
      (should (file-exists-p new)))))

;;;; Text length

(ert-deftest utter-core-test-text-length ()
  (should (= (utter--text-length "你好a" 'chars) 3))
  (should (= (utter--text-length "你好a" 'bytes) 7))
  (should (= (utter--text-length "a😀" 'utf16) 3)))

(ert-deftest utter-core-test-normalize-alignment-validation ()
  (should (equal (utter--normalize-alignment "Hi" ["H" "i"] [0 1.0] [1.0 2.0])
                 '(:characters "Hi" :starts [0 1.0] :ends [1.0 2.0])))
  (should-not (utter--normalize-alignment "Hi" ["H"] [0 1] [1 2]))
  (should-not (utter--normalize-alignment "Hi" ["H" "o"] [0 1] [1 2]))
  (should-not (utter--normalize-alignment "Hi" ["H" "i"] [0] [1 2]))
  (should-not (utter--normalize-alignment "Hi" ["H" "i"] [0 "1"] [1 2]))
  (should-not (utter--normalize-alignment "Hi" ["H" "i"] [0 -1] [1 2]))
  (should-not (utter--normalize-alignment "Hi" ["H" "i"] [0 2] [1 1]))
  (should-not (utter--normalize-alignment "Hi" ["H" "i"] [1 0] [1 2])))

;;;; WAV header and sniffing

(ert-deftest utter-core-test-wav-header ()
  (let ((h (utter--wav-header 4800 24000)))
    (should (= (length h) 44))
    (should-not (multibyte-string-p h))
    (should (string-prefix-p "RIFF" h))
    (should (equal (substring h 8 16) "WAVEfmt "))
    (should (equal (substring h 36 40) "data"))
    ;; RIFF chunk size = 36 + data
    (should (= (utter--le-int (substring h 4 8)) 4836))
    ;; PCM format 1, 1 channel
    (should (= (utter--le-int (substring h 20 22)) 1))
    (should (= (utter--le-int (substring h 22 24)) 1))
    (should (= (utter--le-int (substring h 24 28)) 24000))
    ;; byte rate = rate * 2
    (should (= (utter--le-int (substring h 28 32)) 48000))
    (should (= (utter--le-int (substring h 32 34)) 2))
    (should (= (utter--le-int (substring h 34 36)) 16))
    (should (= (utter--le-int (substring h 40 44)) 4800))))

(ert-deftest utter-core-test-sniff ()
  (should (eq (utter--sniff "{\"error\":1}") 'json))
  (should (eq (utter--sniff "  [ {}]") 'json))
  (should (eq (utter--sniff "<html>") 'text))
  (should (eq (utter--sniff "ID3\x04\x00") 'audio))
  (should (eq (utter--sniff (unibyte-string #xff #xfb #x90 #x00)) 'audio))
  (should (eq (utter--sniff (unibyte-string #xff #xf1 #x50 #x80)) 'audio))
  (should (eq (utter--sniff "RIFF\x00\x00\x00\x00WAVE") 'audio))
  (should (eq (utter--sniff "fLaC\x00") 'audio))
  (should (eq (utter--sniff "OggS\x00") 'audio))
  (should (eq (utter--sniff "FORM\x00\x00\x00\x00AIFF") 'audio))
  (should (eq (utter--sniff (concat (unibyte-string 0 0 0 #x1c) "ftypM4A ")) 'audio))
  (should (eq (utter--sniff "") 'empty))
  (should-not (utter--sniff (unibyte-string 1 2 3 4 5 6 7 8))))

;;;; Error extraction

(ert-deftest utter-core-test-error-message-from-json ()
  (should (equal (utter--error-from-string "{\"error\":{\"message\":\"Bad key\",\"type\":\"x\"}}")
                 "Bad key"))
  (should (equal (utter--error-from-string "{\"detail\":\"Not found\"}") "Not found"))
  (should (equal (utter--error-from-string
                  "{\"detail\":{\"type\":\"x\",\"message\":\"Invalid API key\"}}")
                 "Invalid API key"))
  (should (equal (utter--error-from-string "{\"detail\":[{\"msg\":\"field required\"}]}")
                 "field required"))
  (should (equal (utter--error-from-string "{\"message\":\"m\"}") "m"))
  (should (equal (utter--error-from-string "[{\"error\":{\"code\":403,\"message\":\"denied\"}}]")
                 "denied"))
  (should (equal (utter--error-from-string "{\"error\":\"plain\"}") "plain"))
  (should (equal (utter--error-from-string "Unauthorized\n") "Unauthorized"))
  (should-not (utter--error-from-string ""))
  (should (<= (length (utter--error-from-string (make-string 500 ?x))) 200)))

(ert-deftest utter-core-test-parse-error-default ()
  (utter-test-with-temp-dir dir
    (let ((b (utter--make-backend :name "B"))
          (f (expand-file-name "raw" dir)))
      (utter-test-write-bytes f "{\"error\":{\"message\":\"Incorrect API key\"}}")
      (should (equal (utter--parse-error b (list :raw-file f :http-status 401))
                     "HTTP 401: Incorrect API key"))
      (utter-test-write-bytes f "")
      (should (equal (utter--parse-error b (list :raw-file f :http-status 401))
                     "HTTP 401"))
      (utter-test-write-bytes f "ID3")
      (should-not (utter--parse-error b (list :raw-file f :http-status 200))))))

;;;; curl config

(ert-deftest utter-core-test-curl-config ()
  (let ((cfg (utter--curl-config
              "https://h/x?a=1"
              '(("Authorization" . "Bearer sk-\"q\\")
                ("Content-Type" . "application/json"))
              "/tmp/body.json" nil)))
    (should (string-match-p "^url = \"https://h/x\\?a=1\"$" cfg))
    (should (string-match-p (regexp-quote "header = \"Authorization: Bearer sk-\\\"q\\\\\"") cfg))
    (should (string-match-p "^header = \"Content-Type: application/json\"$" cfg))
    (should (string-match-p "^data-binary = \"@/tmp/body.json\"$" cfg))
    (should (string-match-p "^header = \"Expect:\"$" cfg)))
  (let ((cfg (utter--curl-config "http://h/v" nil nil "GET" "ak:sk")))
    (should (string-match-p "^request = \"GET\"$" cfg))
    (should (string-match-p "^user = \"ak:sk\"$" cfg))
    (should-not (string-match-p "data-binary" cfg)))
  (should (string-match-p "^noproxy = \"\\*\"$" (utter--curl-config "http://127.0.0.1:9/x" nil nil nil)))
  (should (string-match-p "^noproxy" (utter--curl-config "http://localhost/x" nil nil nil)))
  (should (string-match-p "^noproxy" (utter--curl-config "http://[::1]:80/x" nil nil nil)))
  (should-not (string-match-p "noproxy" (utter--curl-config "https://api.openai.com/x" nil nil nil)))
  (should-not (string-match-p "noproxy" (utter--curl-config "https://localhost.example.com/x" nil nil nil)))
  (let ((utter-proxy "http://proxy:8080"))
    (should (string-match-p "^proxy = \"http://proxy:8080\"$"
                            (utter--curl-config "http://h" nil nil nil)))))

;;;; API keys

(defmacro utter-test-with-authinfo (lines &rest body)
  "Run BODY with `auth-sources' pointing at a temp file holding LINES."
  (declare (indent 1))
  `(let* ((file (make-temp-file "utter-authinfo"))
          (auth-sources (list file))
          (auth-source-do-cache nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert (mapconcat #'identity ,lines "\n") "\n"))
           (set-file-modes file #o600)
           (auth-source-forget-all-cached)
           ,@body)
       (auth-source-forget-all-cached)
       (delete-file file))))

(defvar utter-test--key-var nil)
(defvar gptel--known-backends)

(ert-deftest utter-core-test-get-api-key-kinds ()
  (let ((b (utter--make-backend :name "K" :host "example.test")))
    (should-not (utter--get-api-key b))
    (setf (utter-backend-key b) "sk-str\n")
    (should (equal (utter--get-api-key b) "sk-str"))
    (setq utter-test--key-var "sk-var\r\n")
    (setf (utter-backend-key b) 'utter-test--key-var)
    (should (equal (utter--get-api-key b) "sk-var"))
    (setf (utter-backend-key b) (lambda (backend) (concat "sk-" (utter-backend-host backend))))
    (should (equal (utter--get-api-key b) "sk-example.test"))
    (setf (utter-backend-key b) (lambda () "sk-thunk\n"))
    (should (equal (utter--get-api-key b) "sk-thunk"))))

(ert-deftest utter-core-test-auth-source ()
  (utter-test-with-authinfo
      '("machine example.test login apikey password sk-auth"
        "machine other.test login bob password sk-bob")
    (should (equal (utter-api-key-from-auth-source "example.test") "sk-auth"))
    (should (equal (utter-api-key-from-auth-source "other.test" "bob") "sk-bob"))
    (should-not (utter-api-key-from-auth-source "missing.test"))
    (let ((b (utter--make-backend :name "A" :host "example.test"
                                  :key #'utter-api-key-from-auth-source)))
      (should (equal (utter-api-key-from-auth-source b) "sk-auth"))
      (should (equal (utter--get-api-key b) "sk-auth")))))

(ert-deftest utter-core-test-key-from-gptel ()
  (utter-test-with-authinfo '("machine example.test login apikey password sk-auth"
                              "machine g.test login apikey password sk-g-auth")
    ;; gptel not loaded: fall back to auth-source for the backend's host.
    (let ((b (utter--make-backend :name "G" :host "example.test"
                                  :key (utter-key-from-gptel))))
      (should (equal (utter--get-api-key b) "sk-auth")))
    (cl-letf* (((symbol-function 'gptel-backend-host) (lambda (g) (plist-get g :host)))
               ((symbol-function 'gptel-backend-key) (lambda (g) (plist-get g :key)))
               ((symbol-function 'gptel-api-key-from-auth-source)
                (lambda (&rest _) (error "Must not call gptel functions")))
               (gptel--known-backends
                `(("ChatGPT" . (:host "example.test" :key "sk-gptel\n"))
                  ("Gem" . (:host "g.test" :key gptel-api-key-from-auth-source))
                  ("Var" . (:host "v.test" :key utter-test--key-var))))
               (utter-test--key-var "sk-from-var"))
      (let ((b (utter--make-backend :name "G" :host "unused.test")))
        (setf (utter-backend-key b) (utter-key-from-gptel "ChatGPT"))
        (should (equal (utter--get-api-key b) "sk-gptel"))
        ;; lookup by host
        (setf (utter-backend-key b) (utter-key-from-gptel "example.test"))
        (should (equal (utter--get-api-key b) "sk-gptel"))
        ;; gptel's own auth-source function is not called; ours is used
        (setf (utter-backend-key b) (utter-key-from-gptel "Gem"))
        (should (equal (utter--get-api-key b) "sk-g-auth"))
        (setf (utter-backend-key b) (utter-key-from-gptel "Var"))
        (should (equal (utter--get-api-key b) "sk-from-var"))))))

;;;; Local HTTP stub server

(defvar utter-test-server-proc nil "The running stub server process.")
(defvar utter-test-requests nil "Requests received, newest first.")
(defvar utter-test-routes nil
  "Alist PATH -> (STATUS CONTENT-TYPE BODY) for the stub server.
PATH is matched without the query string.")

(defun utter-test--parse-request (data)
  "Return a request plist parsed from raw DATA, or nil if incomplete."
  (when-let* ((end (string-search "\r\n\r\n" data)))
    (let* ((head (split-string (substring data 0 end) "\r\n"))
           (line (split-string (car head) " "))
           (headers (mapcar (lambda (l)
                              (when (string-match "\\`\\([^:]+\\): ?\\(.*\\)\\'" l)
                                (cons (downcase (match-string 1 l)) (match-string 2 l))))
                            (cdr head)))
           (len (string-to-number (or (cdr (assoc "content-length" headers)) "0")))
           (body (substring data (+ end 4))))
      (when (>= (length body) len)
        (list :method (nth 0 line) :path (nth 1 line) :headers headers
              :body (decode-coding-string (substring body 0 len) 'utf-8))))))

(defun utter-test--respond (proc req)
  "Send the canned response for REQ to PROC."
  (let* ((path (car (split-string (plist-get req :path) "?")))
         (route (or (cdr (assoc path utter-test-routes))
                    '(404 "application/json" "{\"detail\":\"Not Found\"}")))
         (body (nth 2 route)))
    (process-send-string
     proc (concat (format "HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                          (nth 0 route) (nth 1 route) (length body))
                  body))
    (process-send-eof proc)))

(defun utter-test-start-server ()
  "Start the stub server if needed; return its base URL host:port."
  (unless (process-live-p utter-test-server-proc)
    (setq utter-test-server-proc
          (make-network-process
           :name "utter-stub" :server t :host "127.0.0.1" :service t
           :family 'ipv4 :coding 'binary :noquery t
           :filter (lambda (proc string)
                     (let ((data (concat (or (process-get proc 'data) "") string)))
                       (process-put proc 'data data)
                       (when-let* ((req (utter-test--parse-request data)))
                         (push req utter-test-requests)
                         (utter-test--respond proc req)))))))
  (format "127.0.0.1:%d" (process-contact utter-test-server-proc :service)))

(defun utter-test-wait (pred &optional timeout)
  "Pump the event loop until PRED returns non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defmacro utter-test-with-server (routes &rest body)
  "Run BODY with the stub server serving ROUTES; bind `host' to host:port."
  (declare (indent 1))
  `(let ((utter-test-routes ,routes)
         (utter-test-requests nil)
         (host (utter-test-start-server)))
     (ignore host)
     ,@body))

(defconst utter-test-mp3 (concat "ID3" (unibyte-string 4 0 0 0 0 0 0 #xff #xfb #x90 0))
  "A tiny body that sniffs as MP3.")

(defun utter-test-wav-bytes ()
  "Return a small valid WAV file as a unibyte string."
  (concat (utter--wav-header 8 24000) (make-string 8 0)))

(defun utter-test-request (text &rest keys)
  "Call `utter-request' on TEXT with KEYS and wait; return (AUDIO INFO)."
  (let (result)
    (apply #'utter-request text
           :callback (lambda (audio info) (setq result (list audio info)))
           keys)
    (utter-test-wait (lambda () result))
    result))

;;;; A minimal backend for request tests

(cl-defstruct (utter-test-backend (:include utter-backend)
                                  (:constructor utter-test--make-backend)
                                  (:copier nil)))

(cl-defmethod utter--request-data ((_b utter-test-backend) text params)
  "Return a small body with TEXT and PARAMS."
  (list :input text :voice (plist-get params :voice)
        :response_format (symbol-name (plist-get params :format))))

(defun utter-test-backend (host &rest slots)
  "Return a test backend for HOST (host:port) with extra SLOTS."
  (apply #'utter-test--make-backend
         (append slots
                 (list :name "Test" :host host :protocol "http" :endpoint "/ok"
                       :models '(m1) :voices '("v1" "v2") :formats '(mp3 pcm)
                       :max-chars 100 :header #'utter-bearer-header
                       :key "sk-secret"))))

(cl-defstruct (utter-test-pe-backend (:include utter-test-backend)
                                     (:constructor utter-test--make-pe-backend)
                                     (:copier nil)))

(defvar utter-test--pe-seen nil "Statuses seen by the test `utter--parse-error'.")

(cl-defmethod utter--parse-error ((_b utter-test-pe-backend) info)
  "Record INFO's status and report a vendor error."
  (push (plist-get info :http-status) utter-test--pe-seen)
  "vendor says no")

;;;; Requests through curl

(ert-deftest utter-core-test-request-bytes-ok ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
      (let* ((utter-cache-directory dir)
             (b (utter-test-backend host))
             (req nil)
             (res nil))
        (setq req (utter-request "你好 world" :backend b :cache nil
                                 :callback (lambda (a i) (setq res (list a i)))))
        (should (utter-request-p req))
        ;; The key is never on the command line.
        (should-not (cl-some (lambda (a) (string-search "sk-secret" a))
                             (process-command (utter-request-process req))))
        (should (member "-K" (process-command (utter-request-process req))))
        (should (utter-test-wait (lambda () res)))
        (pcase-let ((`(,audio ,info) res))
          (should (stringp audio))
          (should (equal (utter-test-file-bytes audio) utter-test-mp3))
          (should (eq (plist-get info :format) 'mp3))
          (should (= (plist-get info :http-status) 200))
          (should (equal (plist-get info :voice) "v1"))
          (should (eq (plist-get info :model) 'm1))
          (should (eq (plist-get info :request) req))
          (should-not (plist-get info :cached))
          (should (eq (utter-request-status req) 'done))
          (dolist (f (plist-get info :temp-files)) (should-not (file-exists-p f)))
          (delete-file audio))
        (let* ((sreq (car utter-test-requests))
               (json (json-parse-string (plist-get sreq :body) :object-type 'plist)))
          (should (equal (plist-get sreq :method) "POST"))
          (should (equal (cdr (assoc "authorization" (plist-get sreq :headers)))
                         "Bearer sk-secret"))
          (should (equal (cdr (assoc "content-type" (plist-get sreq :headers)))
                         "application/json"))
          (should (equal (plist-get json :input) "你好 world")))))))

(ert-deftest utter-core-test-request-ignores-env-proxy-for-loopback ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((process-environment
            (append '("http_proxy=http://127.0.0.1:1" "HTTP_PROXY=http://127.0.0.1:1"
                      "all_proxy=http://127.0.0.1:1" "ALL_PROXY=http://127.0.0.1:1"
                      "no_proxy" "NO_PROXY")
                    process-environment))
           (res (utter-test-request "hi" :backend (utter-test-backend host) :cache nil)))
      (should (car res))
      (delete-file (car res)))))

(ert-deftest utter-core-test-request-no-key-no-header ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((b (utter-test-backend host :key nil))
           (res (utter-test-request "hi" :backend b :cache nil)))
      (should (car res))
      (delete-file (car res))
      (should-not (assoc "authorization" (plist-get (car utter-test-requests) :headers))))))

(ert-deftest utter-core-test-request-json-error-with-200 ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server '(("/ok" 200 "application/octet-stream"
                             "{\"error\":{\"message\":\"quota exceeded\"}}"))
    (let* ((res (utter-test-request "hi" :backend (utter-test-backend host) :cache nil)))
      (should-not (car res))
      (should (string-match-p "quota exceeded" (plist-get (cadr res) :error)))
      (should (= (plist-get (cadr res) :http-status) 200)))))

(ert-deftest utter-core-test-request-401 ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server '(("/ok" 401 "text/plain"
                             "{\"error\":{\"message\":\"Incorrect API key provided\"}}"))
    (let* ((res (utter-test-request "hi" :backend (utter-test-backend host) :cache nil)))
      (should-not (car res))
      (should (equal (plist-get (cadr res) :error) "HTTP 401: Incorrect API key provided"))
      (should (= (plist-get (cadr res) :http-status) 401))
      (should (eq (utter-request-status (plist-get (cadr res) :request)) 'error)))))

(ert-deftest utter-core-test-request-parse-error-runs-on-200 ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((utter-test--pe-seen nil)
           (b (utter-test--make-pe-backend
               :name "PE" :host host :protocol "http" :endpoint "/ok"
               :formats '(mp3) :header #'utter-bearer-header))
           (res (utter-test-request "hi" :backend b :cache nil)))
      (should (equal utter-test--pe-seen '(200)))
      (should-not (car res))
      (should (equal (plist-get (cadr res) :error) "vendor says no")))))

(ert-deftest utter-core-test-request-pcm-wrapped ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "audio/pcm" ,(make-string 4800 1)))
    (let* ((res (utter-test-request "hi" :backend (utter-test-backend host)
                                    :format 'pcm :cache nil))
           (bytes (utter-test-file-bytes (car res))))
      (should (string-suffix-p ".wav" (car res)))
      (should (eq (plist-get (cadr res) :format) 'wav))
      (should (= (length bytes) 4844))
      (should (string-prefix-p "RIFF" bytes))
      (should (= (utter--le-int (substring bytes 24 28)) 24000))
      (should (= (plist-get (cadr res) :duration) 0.1))
      (delete-file (car res)))))

(ert-deftest utter-core-test-request-pcm-edge-cases ()
  "PCM that looks like MPEG sync or JSON is still wrapped; containers are not."
  (skip-unless (executable-find "curl"))
  (dolist (body (list (concat (unibyte-string #xff #xff) (make-string 4798 0))
                      (concat "{" (make-string 4799 0))))
    (utter-test-with-server `(("/ok" 200 "audio/pcm" ,body))
      (let* ((res (utter-test-request "hi" :backend (utter-test-backend host)
                                      :format 'pcm :cache nil))
             (bytes (and (car res) (utter-test-file-bytes (car res)))))
        (should bytes)
        (should (= (length bytes) 4844))
        (should (string-prefix-p "RIFF" bytes))
        (delete-file (car res)))))
  ;; A server that ignores pcm and sends mp3: bytes unchanged.
  (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
    (let ((res (utter-test-request "hi" :backend (utter-test-backend host)
                                   :format 'pcm :cache nil)))
      (should (equal (utter-test-file-bytes (car res)) utter-test-mp3))
      (should (eq (plist-get (cadr res) :format) 'mp3))
      (delete-file (car res))))
  ;; A JSON error for a pcm request is still an error.
  (utter-test-with-server '(("/ok" 200 "application/json" "{\"error\":{\"message\":\"nope\"}}"))
    (let ((res (utter-test-request "hi" :backend (utter-test-backend host)
                                   :format 'pcm :cache nil)))
      (should-not (car res))
      (should (string-match-p "nope" (plist-get (cadr res) :error))))))

(ert-deftest utter-core-test-request-b64-json ()
  (skip-unless (executable-find "curl"))
  (let ((wav (utter-test-wav-bytes)))
    (utter-test-with-server
        `(("/ok" 200 "application/json"
           ,(format "{\"steps\":[{\"type\":\"thought\"},{\"type\":\"model_output\",\"content\":[{\"type\":\"text\"},{\"type\":\"audio\",\"data\":\"%s\"}]}]}"
                    (base64-encode-string wav t))))
      (let* ((b (utter-test-backend host :response-kind 'b64-json :formats '(wav)
                                    :response-path '(steps (type . "model_output")
                                                           content (type . "audio") data)))
             (res (utter-test-request "hi" :backend b :cache nil)))
        (should (car res))
        (should (equal (utter-test-file-bytes (car res)) wav))
        (should (eq (plist-get (cadr res) :format) 'wav))
        (delete-file (car res))
        ;; Missing path: an error, not a file.
        (setf (utter-backend-response-path b) '(nope))
        (should (string-match-p "no audio" (plist-get (cadr (utter-test-request "hi" :backend b :cache nil))
                                                      :error)))))))

(ert-deftest utter-core-test-request-kind-not-implemented ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "application/json" "{}"))
    (let ((res (utter-test-request "hi" :backend (utter-test-backend host :response-kind 'hex)
                                   :cache nil)))
      (should (string-match-p "not implemented" (plist-get (cadr res) :error))))))

(ert-deftest utter-core-test-request-connection-refused ()
  (skip-unless (executable-find "curl"))
  (let* ((p (make-network-process :name "utter-port" :server t :host "127.0.0.1"
                                  :service t :family 'ipv4))
         (port (process-contact p :service)))
    (delete-process p)
    (let ((res (utter-test-request "hi" :backend (utter-test-backend (format "127.0.0.1:%d" port))
                                   :cache nil)))
      (should-not (car res))
      (should (string-match-p "curl exited 7" (plist-get (cadr res) :error))))))

(ert-deftest utter-core-test-request-cache ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
      (let* ((utter-cache-directory dir)
             (b (utter-test-backend host))
             (first (utter-test-request "cache me" :backend b)))
        (should (string-prefix-p (file-name-as-directory dir) (car first)))
        (should (= (length utter-test-requests) 1))
        (let* ((sync nil)
               (res nil)
               (req (utter-request "cache me" :backend b
                                   :callback (lambda (a i) (setq res (list a i)
                                                                 sync (or sync 'async))))))
          ;; Called from a timer, not synchronously.
          (setq sync (or sync 'sync))
          (should (utter-test-wait (lambda () res)))
          (should (eq sync 'sync))
          (should (utter-request-p req))
          (should (equal (car res) (car first)))
          (should (plist-get (cadr res) :cached))
          (should (= (length utter-test-requests) 1)))
        ;; A different voice misses.
        (utter-test-request "cache me" :backend b :voice "v2")
        (should (= (length utter-test-requests) 2))
        ;; FILE with a cache hit gets a copy.
        (let* ((out (expand-file-name "out/copy.mp3" dir))
               (res (utter-test-request "cache me" :backend b :file out)))
          (should (equal (car res) out))
          (should (equal (utter-test-file-bytes out) utter-test-mp3)))))))

(ert-deftest utter-core-test-request-hooks ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((seen nil)
           (utter-cache-directory (make-temp-file "utter-hooks" t))
           (utter-pre-request-hook (list (lambda () (push (list 'pre (plist-get utter-request-info :text)) seen))))
           (utter-post-request-hook (list (lambda () (push (list 'post (plist-get utter-request-info :http-status)) seen))))
           (res (utter-test-request "hooked" :backend (utter-test-backend host))))
      (should (car res))
      (should (equal (reverse seen) '((pre "hooked") (post 200))))
      ;; A cache hit runs both hooks too.
      (setq seen nil)
      (should (plist-get (cadr (utter-test-request "hooked" :backend (utter-test-backend host)))
                         :cached))
      (should (equal (reverse seen) '((pre "hooked") (post nil))))
      (delete-directory utter-cache-directory t))))

(ert-deftest utter-core-test-abort ()
  (skip-unless (executable-find "curl"))
  ;; A server that never answers.
  (let* ((srv (make-network-process :name "utter-silent" :server t :host "127.0.0.1"
                                    :service t :family 'ipv4 :noquery t
                                    :filter #'ignore))
         (host (format "127.0.0.1:%d" (process-contact srv :service)))
         (calls nil))
    (unwind-protect
        (let ((req (utter-request "hi" :backend (utter-test-backend host) :cache nil
                                  :callback (lambda (a _i) (push a calls)))))
          (accept-process-output nil 0.2)
          (utter-abort req)
          (should (equal calls '(abort)))
          (should (eq (utter-request-status req) 'aborted))
          (accept-process-output nil 0.3)
          (utter-abort req)
          (should (equal calls '(abort)))
          (should-not (process-live-p (utter-request-process req))))
      (delete-process srv))))

(ert-deftest utter-core-test-dry-run ()
  (let* ((b (utter-test-backend "api.example.test"
                                :protocol "https" :request-params '(:extra 1)
                                :body-transform (lambda (body) (plist-put body :moved t))))
         (d (utter-request "hi" :backend b :dry-run t)))
    (should (equal (plist-get d :url) "https://api.example.test/ok"))
    (should (equal (plist-get d :headers)
                   '(("Content-Type" . "application/json")
                     ("Authorization" . "[redacted]"))))
    (should (equal (plist-get (plist-get d :body) :input) "hi"))
    (should (equal (plist-get (plist-get d :body) :extra) 1))
    (should (eq (plist-get (plist-get d :body) :moved) t))
    (should (member "-K" (plist-get d :curl-args)))
    (should-not (cl-some (lambda (a) (string-search "sk-secret" a)) (plist-get d :curl-args)))
    (should-not (string-search "sk-secret" (format "%S" d)))))

(ert-deftest utter-core-test-text-too-long ()
  (let ((b (utter-test-backend "h" :max-chars 5 :max-chars-unit 'bytes)))
    (should (utter-request "你" :backend b :dry-run t))
    (should-error (utter-request "你好" :backend b :dry-run t) :type 'utter-text-too-long)))

(ert-deftest utter-core-test-no-backend ()
  (let ((utter--known-backends nil))
    (should-error (utter-request "hi" :backend nil) :type 'user-error)
    (should-error (utter-request "hi" :backend "nope") :type 'user-error)))

(ert-deftest utter-core-test-fetch-json ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server '(("/v1/voices" 200 "application/json"
                             "{\"voices\":[{\"name\":\"A\",\"voice_id\":\"1\"}]}")
                            ("/bad" 403 "application/json" "[{\"error\":{\"message\":\"denied\"}}]"))
    (let ((b (utter-test-backend host)) got err)
      (utter-fetch-json b "GET" "/v1/voices" (lambda (json) (setq got json)))
      (should (utter-test-wait (lambda () got)))
      (should (equal (alist-get 'name (car (alist-get 'voices got))) "A"))
      (should (equal (plist-get (car utter-test-requests) :method) "GET"))
      (should (equal (cdr (assoc "authorization" (plist-get (car utter-test-requests) :headers)))
                     "Bearer sk-secret"))
      (setq got 'unset)
      (utter-fetch-json b "GET" "/bad" (lambda (json info) (setq got json err info)))
      (should (utter-test-wait (lambda () err)))
      (should-not got)
      (should (equal (plist-get err :error) "HTTP 403: denied")))))

(ert-deftest utter-core-test-json-path ()
  (let ((json '((error . ((message . "m"))) (items ((k . "a") (v . 1)) ((k . "b") (v . 2))))))
    ;; Symbols are keys even when they name functions.
    (should (equal (utter--json-path json '(error message)) "m"))
    (should (equal (utter--json-path json '(items 1 v)) 2))
    (should (equal (utter--json-path json '(items (k . "b") v)) 2))
    (should (equal (utter--json-path json '(items last k)) "b"))
    (should (equal (utter--json-path json (list 'items (lambda (l) (car l)) 'k)) "a"))
    (should-not (utter--json-path json '(nope k)))))

;;;; Voices cache

(ert-deftest utter-core-test-list-voices-cache ()
  (let* ((utter--voice-cache (make-hash-table :test #'equal))
         (calls 0)
         (b (utter--make-backend :name "V" :voices (lambda (_b cb) (cl-incf calls) (funcall cb '("a" "b")))))
         got)
    (utter--list-voices b (lambda (v) (setq got v)))
    (utter--list-voices b (lambda (v) (setq got v)))
    (should (equal got '("a" "b")))
    (should (= calls 1))
    (should (equal (utter--static-voices b) '("a" "b")))
    (let ((utter-voice-cache-ttl -1))
      (utter--list-voices b #'ignore)
      (should (= calls 2)))
    (setf (utter-backend-voices b) '("x"))
    (utter--list-voices b (lambda (v) (setq got v)))
    (should (equal got '("x")))
    (setf (utter-backend-voices b) 'fetch)
    (should-error (utter--list-voices (utter--make-backend :name "F" :voices 'fetch) #'ignore))))

(ert-deftest utter-core-test-finite-number-p ()
  (should (cl-every #'utter--finite-number-p '(0 1 1.5 -0.0)))
  (should-not (cl-some #'utter--finite-number-p
                       (list 1.0e+INF -1.0e+INF 0.0e+NaN "1" nil))))

;;;; Streaming

(ert-deftest utter-core-test-normalize-alignment-prefix ()
  (should (equal (utter--normalize-alignment-prefix "Hi there" ["H" "i"] '(0 0.5) '(0.5 1.0))
                 '(:characters "Hi" :starts [0 0.5] :ends [0.5 1.0])))
  (should (equal (utter--normalize-alignment-prefix "Hi" "Hi" [0 1] [1 2])
                 '(:characters "Hi" :starts [0 1] :ends [1 2])))
  ;; Not a prefix, too long, or bad times: nil.
  (should-not (utter--normalize-alignment-prefix "Hi there" ["i"] [0] [1]))
  (should-not (utter--normalize-alignment-prefix "Hi" "Hi!" [0 1 2] [1 2 3]))
  (should-not (utter--normalize-alignment-prefix "Hi" "H" [1.0e+INF] [1.0e+INF]))
  (should-not (utter--normalize-alignment-prefix "Hi" ["H" "i"] [1 0] [1 2]))
  (should-not (utter--normalize-alignment-prefix "Hi" "" [] [])))

(cl-defstruct (utter-test-stream-backend (:include utter-test-backend)
                                         (:constructor utter-test--make-stream-backend)
                                         (:copier nil))
  "A test backend that streams.  OPEN is the websocket transport stub."
  (stream-kind 'bytes) open (available t))

(defvar utter-test--closed-handles nil "Handles passed to `utter--stream-close'.")

(cl-defmethod utter--stream-kind ((b utter-test-stream-backend))
  "Return B's configured stream kind."
  (utter-test-stream-backend-stream-kind b))

(cl-defmethod utter--stream-available-p ((b utter-test-stream-backend))
  "Return B's configured availability."
  (utter-test-stream-backend-available b))

(cl-defmethod utter--stream-request-body ((_b utter-test-stream-backend) body _params)
  "Ask for a streamed BODY."
  (plist-put body :stream t))

(cl-defmethod utter--stream-alignment-piece ((_b utter-test-stream-backend) _info json)
  "Return the ElevenLabs-shaped alignment piece of JSON, or nil."
  (when-let* ((a (alist-get 'alignment json)))
    (list :characters (alist-get 'characters a)
          :starts (alist-get 'character_start_times_seconds a)
          :ends (alist-get 'character_end_times_seconds a))))

(cl-defmethod utter--stream-open ((b utter-test-stream-backend) info params on-event)
  "Run B's OPEN stub with INFO, PARAMS and ON-EVENT."
  (funcall (utter-test-stream-backend-open b) info params on-event))

(cl-defmethod utter--stream-close ((_b utter-test-stream-backend) handle)
  "Record HANDLE as closed."
  (push handle utter-test--closed-handles))

(defun utter-test-stream-backend (port &rest slots)
  "Return a streaming test backend for the stub on PORT with extra SLOTS."
  (apply #'utter-test--make-stream-backend
         (append slots
                 (list :name "Stream" :host (format "127.0.0.1:%d" port)
                       :protocol "http" :endpoint "/ok"
                       :models '(m1) :voices '("v1") :formats '(mp3 pcm)
                       :max-chars 100 :header #'utter-bearer-header
                       :key "sk-secret"))))

(defun utter-test-stream (text &rest keys)
  "Stream TEXT with KEYS and wait.
Return (AUDIO INFO EVENTS) with EVENTS oldest first."
  (let (result events)
    (apply #'utter-request text :stream t
           :stream-callback (lambda (e) (push e events))
           :callback (lambda (audio info) (setq result (list audio info)))
           keys)
    (utter-test-server-wait-for (lambda () result))
    (append result (list (reverse events)))))

(defun utter-test-mp3-frames (n)
  "Return N silent MP3 frames as a list of unibyte strings."
  (make-list n (utter-test-server-mp3-bytes)))

(ert-deftest utter-core-test-nonstream-argv-and-dry-run-unchanged ()
  (let* ((b (utter-test-backend "api.example.test" :protocol "https"))
         (expected `(:url "https://api.example.test/ok"
                     :headers (("Content-Type" . "application/json")
                               ("Authorization" . "[redacted]"))
                     :body (:input "hi" :voice "v1" :response_format "mp3")
                     :curl-args ("curl" "-sS" "-K" "-" "-o" "RAWFILE" "-w" "%{http_code}"))))
    (should (equal (utter-request "hi" :backend b :dry-run t) expected))
    (should (equal (utter-request "hi" :backend b :dry-run t :stream nil) expected))
    ;; A backend that cannot stream ignores :stream.
    (should (equal (utter-request "hi" :backend b :dry-run t :stream t) expected))
    (let ((sb (utter-test--make-stream-backend
               :name "S" :host "api.example.test" :protocol "https" :endpoint "/ok"
               :models '(m1) :voices '("v1") :formats '(mp3) :header #'utter-bearer-header
               :key "sk-secret")))
      (should (equal (utter-request "hi" :backend sb :dry-run t) expected))
      (setf (utter-test-stream-backend-available sb) nil)
      (should (equal (utter-request "hi" :backend sb :dry-run t :stream t) expected))
      (setf (utter-test-stream-backend-available sb) t)
      (let ((d (utter-request "hi" :backend sb :dry-run t :stream t)))
        (should (eq (plist-get d :stream) t))
        (should (eq (plist-get (plist-get d :body) :stream) t))
        (should (equal (plist-get d :curl-args)
                       '("curl" "-sS" "-K" "-" "-N" "-o" "-" "-w" "%{stderr}%{http_code}"))))))
  ;; A live non-stream request runs exactly the old argv.
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/ok" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((res nil)
           (req (utter-request "hi" :backend (utter-test-backend host) :cache nil :stream nil
                               :callback (lambda (a i) (setq res (list a i)))))
           (argv (process-command (utter-request-process req))))
      (should (equal (butlast argv 3) '("curl" "-sS" "-K" "-" "-o")))
      (should (equal (last argv 2) '("-w" "%{http_code}")))
      (should (utter-test-wait (lambda () res)))
      (should-not (plist-member (cadr res) :stream))
      (should-not (plist-member (cadr res) :stream-started))
      (delete-file (car res)))))

(ert-deftest utter-core-test-request-stream-first-bytes-before-end ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (let* ((frames (utter-test-mp3-frames 3))
           (body (apply #'concat frames)))
      (utter-test-server-with
          (port `(("^/ok$" . (:headers (("Content-Type" . "audio/mpeg"))
                              :parts ,frames :delay 0.3))))
        (let* ((utter-cache-directory dir)
               (b (utter-test-stream-backend port))
               (events nil) (res nil) (at-first-data nil) (req nil))
          (setq req (utter-request
                     "hello" :backend b :stream t
                     :stream-callback
                     (lambda (e)
                       (when (and (eq (car e) :data) (not at-first-data))
                         (setq at-first-data
                               (list (utter-request-status req) res (length (cadr e)))))
                       (push e events))
                     :callback (lambda (a i) (setq res (list a i)))))
          (should (equal (process-command (utter-request-process req))
                         '("curl" "-sS" "-K" "-" "-N" "-o" "-" "-w" "%{stderr}%{http_code}")))
          (should (utter-test-server-wait-for (lambda () res)))
          (setq events (reverse events))
          ;; The first audio arrived while the request was still running.
          (should (eq (nth 0 at-first-data) 'running))
          (should-not (nth 1 at-first-data))
          (should (< (nth 2 at-first-data) (length body)))
          (should (equal (car events) '(:start :format mp3)))
          (should (equal (car (last events)) '(:end)))
          (should (> (length events) 3))
          (should (equal (mapconcat #'cadr (cl-remove-if-not
                                            (lambda (e) (eq (car e) :data)) events)
                                    "")
                         body))
          (pcase-let ((`(,audio ,info) res))
            (should (equal audio (utter-cache-file
                                  (utter-cache-key b (list :model 'm1 :voice "v1" :speed 1.0
                                                           :format 'mp3)
                                                   "hello")
                                  'mp3)))
            (should (equal (utter-test-file-bytes audio) body))
            (should (eq (plist-get info :stream) t))
            (should (eq (plist-get info :stream-started) t))
            (should (eq (plist-get info :format) 'mp3))
            (should (= (plist-get info :http-status) 200))
            (should (eq (utter-request-status req) 'done))
            (dolist (f (plist-get info :temp-files)) (should-not (file-exists-p f))))
          (should (eq (plist-get (json-parse-string
                                  (plist-get (car (utter-test-server-requests)) :body)
                                  :object-type 'plist)
                                 :stream)
                      t)))))))

(ert-deftest utter-core-test-stream-json-body-is-error ()
  (skip-unless (executable-find "curl"))
  (let ((json "{\"error\":{\"message\":\"quota exceeded\"}}"))
    (utter-test-server-with
        (port `(("^/ok$" . (:headers (("Content-Type" . "application/octet-stream"))
                            :parts (,(substring json 0 10) ,(substring json 10))
                            :delay 0.05))))
      (let* ((b (utter-test-stream-backend port))
             (res (utter-test-stream "hi" :backend b :cache nil))
             (plain (utter-test-request "hi" :backend b :cache nil)))
        (should-not (car res))
        (should (equal (plist-get (cadr res) :error) (plist-get (cadr plain) :error)))
        (should (equal (plist-get (cadr res) :error)
                       "HTTP 200 with a JSON body: quota exceeded"))
        (should (= (plist-get (cadr res) :http-status) 200))
        (should (eq (plist-get (cadr res) :stream) t))
        (should-not (plist-get (cadr res) :stream-started))
        (should-not (nth 2 res))
        (dolist (f (plist-get (cadr res) :temp-files)) (should-not (file-exists-p f)))))))

(ert-deftest utter-core-test-stream-401-status-from-stderr ()
  (skip-unless (executable-find "curl"))
  (utter-test-server-with
      (port '(("^/ok$" . (:status 401 :headers (("Content-Type" . "application/json"))
                          :parts ("{\"error\":{\"message\":\"Incorrect API key provided\"}}")))))
    (let ((res (utter-test-stream "hi" :backend (utter-test-stream-backend port) :cache nil)))
      (should-not (car res))
      (should (equal (plist-get (cadr res) :error) "HTTP 401: Incorrect API key provided"))
      (should (= (plist-get (cadr res) :http-status) 401))
      (should-not (plist-get (cadr res) :stream-started))
      (should-not (nth 2 res)))))

(ert-deftest utter-core-test-stream-partial-after-start-reports-stream-started-and-deletes-partial ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (utter-test-server-with
        (port `(("^/ok$" . (:headers (("Content-Type" . "audio/mpeg")
                                      ("Content-Length" . "5000"))
                            :parts ,(utter-test-mp3-frames 2) :delay 0.1))))
      (let* ((utter-cache-directory dir)
             (res (utter-test-stream "partial" :backend (utter-test-stream-backend port)))
             (info (cadr res))
             (events (nth 2 res)))
        (should-not (car res))
        (should (string-match-p "\\`curl exited 18" (plist-get info :error)))
        (should (eq (plist-get info :stream-started) t))
        (should (equal (car events) '(:start :format mp3)))
        (should (equal (car (last events)) '(:end)))
        (should (= 1 (cl-count '(:end) events :test #'equal)))
        (should-not (file-exists-p (plist-get info :partial-file)))
        (dolist (f (plist-get info :temp-files)) (should-not (file-exists-p f)))
        (should-not (directory-files dir nil "\\`[^.]"))))))

(ert-deftest utter-core-test-stream-abort ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (utter-test-server-with
        (port `(("^/ok$" . (:headers (("Content-Type" . "audio/mpeg"))
                            :parts ,(utter-test-mp3-frames 4) :delay 2))))
      (let* ((utter-cache-directory dir)
             (calls nil) (events nil)
             (req (utter-request "abort me" :backend (utter-test-stream-backend port)
                                 :stream t
                                 :stream-callback (lambda (e) (push (car e) events))
                                 :callback (lambda (a _i) (push a calls))))
             (proc (utter-request-process req))
             (stderr (process-get proc 'utter-stderr)))
        (should (processp stderr))
        (should (utter-test-server-wait-for (lambda () (memq :data events))))
        (utter-abort req)
        (should (equal calls '(abort)))
        (should (eq (utter-request-status req) 'aborted))
        (accept-process-output nil 0.2)
        (should-not (process-live-p proc))
        (should-not (process-live-p stderr))
        (should (equal calls '(abort)))
        (should-not (memq :end events))
        (dolist (f (plist-get (utter-request-info req) :temp-files))
          (should-not (file-exists-p f)))
        (should-not (directory-files dir nil "\\`[^.]"))))))

(defun utter-test-elevenlabs-line (audio characters starts ends)
  "Return one ElevenLabs NDJSON line for AUDIO bytes and an alignment.
CHARACTERS, STARTS and ENDS describe it; CHARACTERS nil gives a
null alignment."
  (concat
   (json-serialize
    `(:audio_base64 ,(base64-encode-string audio t)
      :alignment ,(if characters
                      `(:characters ,(vconcat (mapcar #'char-to-string characters))
                        :character_start_times_seconds ,(vconcat starts)
                        :character_end_times_seconds ,(vconcat ends))
                    :null)
      :normalized_alignment :null))
   "\n"))

(ert-deftest utter-core-test-stream-b64-lines-alignment-prefix-events ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (let* ((text "The first sentence is here")
           (one "The first sentence ")
           (two "is here")
           (times (lambda (from n) (cl-loop for i below n collect (+ from (* 0.05 i)))))
           (mp3 (utter-test-server-mp3-bytes))
           (a (substring mp3 0 200))
           (b (substring mp3 200))
           (s1 (funcall times 0.0 (length one)))
           (e1 (mapcar (lambda (x) (+ x 0.05)) s1))
           ;; Absolute times: the second piece continues where the first ended.
           (s2 (funcall times (car (last e1)) (length two)))
           (e2 (mapcar (lambda (x) (+ x 0.05)) s2))
           (ndjson (concat (utter-test-elevenlabs-line a nil nil nil)
                           (utter-test-elevenlabs-line b one s1 e1)
                           (utter-test-elevenlabs-line "" two s2 e2)))
           ;; Split mid-line, so lines straddle process-filter calls.
           (parts (list (substring ndjson 0 37) (substring ndjson 37 400)
                        (substring ndjson 400))))
      (utter-test-server-with
          (port `(("^/ok$" . (:headers (("Content-Type" . "application/json"))
                              :parts ,parts :delay 0.1))))
        (let* ((utter-cache-directory dir)
               (backend (utter-test-stream-backend port :stream-kind 'b64-lines))
               (res (utter-test-stream text :backend backend))
               (info (cadr res))
               (events (nth 2 res))
               (prefix (lambda (chars starts ends)
                         `(:alignment (:characters ,chars :starts ,(vconcat starts)
                                       :ends ,(vconcat ends))))))
          (should (car res))
          (should (equal events
                         (list '(:start :format mp3)
                               (list :data a)
                               (list :data b)
                               (funcall prefix one s1 e1)
                               (funcall prefix text (append s1 s2) (append e1 e2))
                               '(:end))))
          (should (equal (utter-test-file-bytes (car res)) mp3))
          (should (eq (plist-get info :stream-started) t))
          (should (equal (plist-get info :alignment)
                         (list :characters text :starts (vconcat s1 s2)
                               :ends (vconcat e1 e2))))
          ;; The sidecar is stored as on the unary path.
          (should (equal (utter--cache-alignment-lookup
                          (file-name-base (car res)) text)
                         (plist-get info :alignment))))))))

(ert-deftest utter-core-test-stream-websocket-dispatch ()
  (let* ((utter-test--closed-handles nil)
         (mp3 (utter-test-server-mp3-bytes))
         (script nil)
         (seen-info nil)
         (b (utter-test--make-stream-backend
             :name "WS" :host "ws.example.test" :models '(m1) :voices '("v1")
             :formats '(mp3) :stream-kind 'websocket
             :open (lambda (info _params on-event)
                     (setq seen-info info)
                     (let ((events script))
                       (run-at-time 0 nil (lambda () (mapc on-event events))))
                     'handle-1))))
    (utter-test-with-temp-dir dir
      (let ((utter-cache-directory dir))
        ;; Success: events are passed on, the file and sidecar appear.
        (setq script `((:status 200) (:start :format mp3) (:data ,(substring mp3 0 100))
                       (:alignment (:characters ("H" "i") :starts (0.0 0.1) :ends (0.1 0.2)))
                       (:data ,(substring mp3 100)) (:end)))
        (let* ((res (utter-test-stream "Hi" :backend b))
               (info (cadr res)))
          (should (eq (plist-get seen-info :stream) t))
          (should (equal (utter-test-file-bytes (car res)) mp3))
          (should (= (plist-get info :http-status) 200))
          (should (eq (plist-get info :stream-started) t))
          (should (equal (plist-get info :alignment)
                         '(:characters "Hi" :starts [0.0 0.1] :ends [0.1 0.2])))
          (should (equal (mapcar #'car (nth 2 res))
                         '(:start :data :alignment :data :end)))
          (should (utter--cache-alignment-lookup (file-name-base (car res)) "Hi")))
        ;; An error after audio: (:end) once, then the error with :stream-started.
        (setq script `((:start :format mp3) (:data ,mp3) (:error "server went away")
                       (:end) (:data "late")))
        (let* ((res (utter-test-stream "Bye" :backend b))
               (info (cadr res)))
          (should-not (car res))
          (should (equal (plist-get info :error) "server went away"))
          (should (eq (plist-get info :stream-started) t))
          (should (equal (mapcar #'car (nth 2 res)) '(:start :data :end)))
          (should (plist-get info :partial-file))
          (should-not (file-exists-p (plist-get info :partial-file)))
          (dolist (f (plist-get info :temp-files)) (should-not (file-exists-p f))))
        ;; A status error before audio.
        (setq script '((:status 403) (:error "HTTP 403")))
        (let ((res (utter-test-stream "No" :backend b :cache nil)))
          (should (equal (plist-get (cadr res) :error) "HTTP 403"))
          (should (= (plist-get (cadr res) :http-status) 403))
          (should-not (plist-get (cadr res) :stream-started))
          (should-not (nth 2 res)))
        ;; Abort closes the handle.
        (setq script nil)
        (let* ((calls nil)
               (req (utter-request "Stop" :backend b :stream t :cache nil
                                   :callback (lambda (a _i) (push a calls)))))
          (should (eq (utter-request-handle req) 'handle-1))
          (utter-abort req)
          (should (equal calls '(abort)))
          (should (equal utter-test--closed-handles '(handle-1))))
        ;; Events sent from inside `utter--stream-open', as websocket.el
        ;; does on a refused handshake, still reach CALLBACK only later.
        (setf (utter-test-stream-backend-open b)
              (lambda (_info _params on-event)
                (funcall on-event '(:status 403))
                (funcall on-event '(:error "HTTP 403"))
                'handle-2))
        (let* ((res nil)
               (req (utter-request "Sync" :backend b :stream t :cache nil
                                   :callback (lambda (a i) (setq res (list a i))))))
          (should-not res)
          (should (utter-test-server-wait-for (lambda () res)))
          (should (equal (plist-get (cadr res) :error) "HTTP 403"))
          (should (= (plist-get (cadr res) :http-status) 403))
          (should-not (utter-request-handle req)))
        ;; A transport that fails to open reports an error asynchronously.
        (setf (utter-test-stream-backend-open b)
              (lambda (&rest _) (error "Cannot connect")))
        (let ((res (utter-test-stream "Err" :backend b :cache nil)))
          (should (equal (plist-get (cadr res) :error) "Cannot connect")))))))

(provide 'utter-core-tests)
;;; utter-core-tests.el ends here
