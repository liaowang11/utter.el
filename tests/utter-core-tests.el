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
      (let ((f (expand-file-name (concat (make-string 40 ?a) ".mp3") dir)))
        (utter-test-write-bytes f "ID3xx")
        (should (equal (utter-cache-lookup (make-string 40 ?a) 'mp3) f))
        ;; pcm is stored wrapped as wav
        (should (string-suffix-p ".wav" (utter-cache-file (make-string 40 ?b) 'pcm)))
        (utter-test-write-bytes (expand-file-name "notes.txt" dir) "keep")
        (utter-cache-clear 1)
        (should (file-exists-p f))
        (utter-cache-clear)
        (should-not (file-exists-p f))
        (should (file-exists-p (expand-file-name "notes.txt" dir)))))))

(ert-deftest utter-core-test-cache-prune ()
  (utter-test-with-temp-dir dir
    (let ((utter-cache-directory dir)
          (old (expand-file-name (concat (make-string 40 ?a) ".mp3") dir))
          (new (expand-file-name (concat (make-string 40 ?b) ".mp3") dir)))
      (utter-test-write-bytes old (make-string 100 ?x))
      (utter-test-write-bytes new (make-string 100 ?x))
      (set-file-times old (time-subtract nil 1000) 'nofollow)
      (utter-cache-prune 150)
      (should-not (file-exists-p old))
      (should (file-exists-p new)))))

;;;; Text length

(ert-deftest utter-core-test-text-length ()
  (should (= (utter--text-length "你好a" 'chars) 3))
  (should (= (utter--text-length "你好a" 'bytes) 7))
  (should (= (utter--text-length "a😀" 'utf16) 3)))

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
  (let ((utter-proxy "http://proxy:8080"))
    (should (string-match-p "^proxy = \"http://proxy:8080\"$"
                            (utter--curl-config "http://h" nil nil nil)))))

(provide 'utter-core-tests)
;;; utter-core-tests.el ends here
