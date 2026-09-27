;;; utter-test-server-tests.el --- Self-tests for the local HTTP stub -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise `utter-test-server' with real curl.  curl runs as an async
;; process: a synchronous `call-process' would block the event loop that
;; serves the stub, and curl would hang.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'utter-test-server)

(defun utter-test-server-tests--curl (&rest args)
  "Run curl with ARGS, bypassing any proxy, and wait for it.
Return a plist (:exit CODE :stdout STRING)."
  (apply #'utter-test-server-tests--curl-raw "--noproxy" "*" args))

(defun utter-test-server-tests--curl-raw (&rest args)
  "Run curl with ARGS asynchronously and wait for it.
Return a plist (:exit CODE :stdout STRING)."
  (let* ((buf (generate-new-buffer " *curl*"))
         (proc (make-process :name "curl" :buffer buf
                             :command (append '("curl" "--silent" "--show-error")
                                              args)
                             :connection-type 'pipe
                             :coding 'binary
                             :sentinel #'ignore :noquery t)))
    (unwind-protect
        (progn
          (utter-test-server-wait-for (lambda () (not (process-live-p proc))))
          (list :exit (process-exit-status proc)
                :stdout (with-current-buffer buf (buffer-string))))
      (kill-buffer buf))))

(defun utter-test-server-tests--read-bytes (file)
  "Return FILE's contents as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(ert-deftest utter-test-server-get ()
  (utter-test-server-with (port '(("^/hello$" . (:body "hi"))))
    (let ((r (utter-test-server-tests--curl
              (format "http://127.0.0.1:%d/hello" port))))
      (should (equal (plist-get r :exit) 0))
      (should (equal (plist-get r :stdout) "hi"))
      (let ((req (car (utter-test-server-requests))))
        (should (equal (plist-get req :method) "GET"))
        (should (equal (plist-get req :path) "/hello"))
        (should (equal (plist-get req :body) ""))))))

(ert-deftest utter-test-server-with-bypasses-proxy ()
  ;; A dead proxy in the environment: without the macro's no_proxy
  ;; binding curl would fail to connect.
  (let ((process-environment
         (append '("http_proxy=http://127.0.0.1:9" "HTTP_PROXY=http://127.0.0.1:9")
                 process-environment)))
    (utter-test-server-with (port '(("^/p$" . (:body "direct"))))
      (let ((r (utter-test-server-tests--curl-raw
                (format "http://127.0.0.1:%d/p" port))))
        (should (equal r '(:exit 0 :stdout "direct")))))))

(ert-deftest utter-test-server-post-json-and-headers ()
  (utter-test-server-with
      (port `(("^/v1/audio/speech$"
               . ,(lambda (method _path headers body)
                    (utter-test-server-json
                     `((method . ,method)
                       (auth . ,(cdr (assoc "authorization" headers
                                            #'string-equal-ignore-case)))
                       (input . ,(alist-get 'input (json-read-from-string
                                                    body)))))))))
    (let* ((body "{\"input\":\"hello\",\"voice\":\"nova\"}")
           (r (utter-test-server-tests--curl
               "-X" "POST" "-H" "Authorization: Bearer sk-test"
               "-H" "Content-Type: application/json"
               "--data-binary" body
               (utter-test-server-url "/v1/audio/speech")))
           (reply (json-read-from-string (plist-get r :stdout)))
           (req (car (utter-test-server-requests))))
      (should (equal (plist-get r :exit) 0))
      (should (equal (alist-get 'method reply) "POST"))
      (should (equal (alist-get 'auth reply) "Bearer sk-test"))
      (should (equal (alist-get 'input reply) "hello"))
      (should (equal (plist-get req :body) body))
      (should (equal (utter-test-server-header req "AUTHORIZATION")
                     "Bearer sk-test"))
      (should (equal (utter-test-server-header req "content-type")
                     "application/json"))
      (should-not (utter-test-server-header req "X-Missing")))))

(ert-deftest utter-test-server-binary-round-trip ()
  ;; Several hundred KB so the request and response span many filter
  ;; calls, and every byte value appears.
  (let* ((all (apply #'unibyte-string (number-sequence 0 255)))
         (payload (apply #'concat (utter-test-server-mp3-bytes)
                         (make-list 1024 all)))
         (upload (make-temp-file "utter-up"))
         (out (make-temp-file "utter-out")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region payload nil upload nil 'silent))
          (utter-test-server-with
              (port `(("^/echo" . ,(lambda (_m _p _h body)
                                     (list :headers '(("Content-Type"
                                                       . "audio/mpeg"))
                                           :body body)))))
            (let ((r (utter-test-server-tests--curl
                      ;; Old curl (Ubuntu 22.04) sends this itself for
                      ;; bodies over 1 KB; force it so the path is covered.
                      "-H" "Expect: 100-continue"
                      "-X" "POST" "--data-binary" (concat "@" upload)
                      "-o" out "-w" "%{http_code}"
                      (utter-test-server-url "/echo"))))
              (should (equal (plist-get r :stdout) "200"))
              (should (equal (plist-get (car (utter-test-server-requests))
                                        :body)
                             payload))
              (should (equal (utter-test-server-tests--read-bytes out)
                             payload)))))
      (delete-file upload)
      (delete-file out))))

(ert-deftest utter-test-server-audio-helpers ()
  (let ((mp3 (utter-test-server-mp3-bytes))
        (wav (utter-test-server-wav-bytes)))
    (should-not (multibyte-string-p mp3))
    (should (string-prefix-p "\xff\xfb" mp3))
    (should-not (multibyte-string-p wav))
    (should (string-prefix-p "RIFF" wav))
    (should (equal (substring wav 8 16) "WAVEfmt "))
    (should (equal (substring wav 36 40) "data"))
    ;; RIFF size = file length - 8; data size = file length - 44.
    (cl-flet ((u32 (s i) (+ (aref s i) (ash (aref s (+ i 1)) 8)
                            (ash (aref s (+ i 2)) 16) (ash (aref s (+ i 3)) 24))))
      (should (= (u32 wav 4) (- (length wav) 8)))
      (should (= (u32 wav 40) (- (length wav) 44)))
      (should (> (u32 wav 40) 0)))
    (utter-test-server-with
        (port `(("^/a\\.mp3$" . (:body ,mp3))
                ("^/a\\.wav$" . (:body ,wav))))
      (dolist (case `(("/a.mp3" . ,mp3) ("/a.wav" . ,wav)))
        (let ((out (make-temp-file "utter-audio")))
          (unwind-protect
              (progn
                (utter-test-server-tests--curl
                 "-o" out (utter-test-server-url (car case)))
                (should (equal (utter-test-server-tests--read-bytes out)
                               (cdr case))))
            (delete-file out)))))))

(ert-deftest utter-test-server-error-status ()
  (utter-test-server-with
      (port '(("^/v1/audio/speech$"
               . (:status 401 :headers (("Content-Type" . "application/json"))
                  :body "{\"error\":{\"message\":\"bad key\"}}"))))
    (let ((r (utter-test-server-tests--curl
              "-w" "\n%{http_code}" "-X" "POST" "--data-binary" "{}"
              (utter-test-server-url "/v1/audio/speech"))))
      (should (equal (plist-get r :exit) 0))
      (should (equal (plist-get r :stdout)
                     "{\"error\":{\"message\":\"bad key\"}}\n401")))))

(ert-deftest utter-test-server-json-helper ()
  (let ((resp (utter-test-server-json '((a . 1)) 422)))
    (should (= (plist-get resp :status) 422))
    (should (equal (cdr (assoc "Content-Type" (plist-get resp :headers)))
                   "application/json"))
    (should (equal (json-read-from-string (plist-get resp :body))
                   '((a . 1)))))
  ;; Non-ASCII text is encoded to UTF-8 bytes.
  (should-not (multibyte-string-p
               (plist-get (utter-test-server-json '((t . "你好"))) :body))))

(ert-deftest utter-test-server-unmatched-route-is-404 ()
  (utter-test-server-with (port '(("^/only$" . (:body "x"))))
    (let ((r (utter-test-server-tests--curl
              "-o" "/dev/null" "-w" "%{http_code}"
              (utter-test-server-url "/other"))))
      (should (equal (plist-get r :stdout) "404"))
      (should (equal (plist-get (car (utter-test-server-requests)) :path)
                     "/other")))))

(ert-deftest utter-test-server-records-in-order-and-stops ()
  (let (port)
    (utter-test-server-with (p '(("" . (:body "ok"))))
      (setq port p)
      (utter-test-server-tests--curl (utter-test-server-url "/1"))
      (utter-test-server-tests--curl (utter-test-server-url "/2"))
      (should (equal (mapcar (lambda (r) (plist-get r :path))
                             (utter-test-server-requests))
                     '("/1" "/2"))))
    ;; After the macro exits the port no longer accepts connections.
    (should-not (utter-test-server-running-p))
    (let ((r (utter-test-server-tests--curl
              "--max-time" "5" (format "http://127.0.0.1:%d/" port))))
      (should-not (equal (plist-get r :exit) 0)))))

(provide 'utter-test-server-tests)
;;; utter-test-server-tests.el ends here
