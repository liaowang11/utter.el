;;; utter-say-tests.el --- Tests for utter-say -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the macOS `say' backend.  Most run anywhere by pointing
;; `utter-say-program' at a small shell script; the ones that need the
;; real `say' are skipped elsewhere.

;;; Code:

(require 'ert)
(require 'utter-core-tests)
(require 'utter-say)

(defconst utter-say-test-voices-output
  "Albert              en_US    # Hello! My name is Albert.
Tünde               hu_HU    # Üdvözlöm! A nevem Tünde.
Eddy (English (US)) en_US    # Hello! My name is Eddy.
Tingting            zh_CN    # 你好！我叫婷婷。
garbage line
"
  "A sample of `say -v ?' output.")

(defmacro utter-say-test-with-fake-say (&rest body)
  "Run BODY with `utter-say-program' set to a fake say script.
The script writes an AIFF-looking file to the -o argument, records
its arguments in ARGS-FILE and prints the voice list for -v ?."
  (declare (indent 0))
  `(utter-test-with-temp-dir fake-dir
     (let* ((args-file (expand-file-name "args" fake-dir))
            (script (expand-file-name "say" fake-dir))
            (voices (expand-file-name "voices" fake-dir))
            (utter-say-program script))
       (let ((coding-system-for-write 'utf-8))
         (write-region utter-say-test-voices-output nil voices nil 'silent))
       (with-temp-file script
         (insert "#!/bin/sh\n"
                 "printf '%s\\n' \"$@\" > " (shell-quote-argument args-file) "\n"
                 "if [ \"$1\" = -v ] && [ \"$2\" = '?' ]; then cat "
                 (shell-quote-argument voices) "; exit 0; fi\n"
                 "out=''; while [ $# -gt 0 ]; do\n"
                 "  case \"$1\" in -o) out=$2; shift;; -f) cp \"$2\" " (shell-quote-argument fake-dir) "/text;; esac; shift\n"
                 "done\n"
                 "[ -z \"$out\" ] && { echo 'no output' >&2; exit 1; }\n"
                 "printf 'FORM\\000\\000\\000\\004AIFF' > \"$out\"\n"))
       (set-file-modes script #o755)
       ,@body)))

(defun utter-say-test-args (args-file)
  "Return the arguments recorded by the fake say in ARGS-FILE."
  (with-temp-buffer
    (insert-file-contents args-file)
    (split-string (buffer-string) "\n" t)))

(ert-deftest utter-say-test-make ()
  (let* ((utter--known-backends nil)
         (b (utter-make-say "Say" :voices '("Samantha" "Tingting"))))
    (should (utter-say-p b))
    (should (eq (utter-get-backend "Say") b))
    (should (eq (utter-backend-response-kind b) 'process))
    (should (equal (utter-backend-formats b) '(aiff m4a)))
    (should (equal (utter-backend-voices b) '("Samantha" "Tingting")))))

(ert-deftest utter-say-test-argv ()
  (let ((b (utter-make-say "Say-argv")))
    (should (equal (utter--process-argv b "hi" '(:voice "Samantha" :speed 1.0 :format aiff)
                                        "/o.aiff" "/t.txt")
                   (list utter-say-program "-v" "Samantha" "-r" "175" "-o" "/o.aiff"
                         "--file-format=AIFF" "-f" "/t.txt")))
    (should (equal (utter--process-argv b "hi" '(:speed 2.0 :format m4a) "/o.m4a" "/t.txt")
                   (list utter-say-program "-r" "350" "-o" "/o.m4a"
                         "--file-format=m4af" "--data-format=aac" "-f" "/t.txt")))
    (let ((d (utter-request "hi" :backend b :voice "Daniel" :speed 1.2 :dry-run t)))
      (should (member "Daniel" (plist-get d :command)))
      (should (member "210" (plist-get d :command))))))

(ert-deftest utter-say-test-parse-voices ()
  (let ((v (utter-say--parse-voices utter-say-test-voices-output)))
    (should (= (length v) 4))
    (should (equal (car v) '("Albert" :language "en_US" :description "Hello! My name is Albert.")))
    (should (equal (car (nth 1 v)) "Tünde"))
    (should (equal (car (nth 2 v)) "Eddy (English (US))"))
    (should (equal (plist-get (cdr (nth 3 v)) :language) "zh_CN"))))

(ert-deftest utter-say-test-fetch-voices ()
  (utter-say-test-with-fake-say
    (let* ((utter--voice-cache (make-hash-table :test #'equal))
           (b (utter-make-say "Say-fetch" :voices 'fetch))
           got)
      (utter--list-voices b (lambda (v) (setq got v)))
      (should (utter-test-wait (lambda () got)))
      (should (equal (mapcar #'car got)
                     '("Albert" "Tünde" "Eddy (English (US))" "Tingting")))
      ;; A fetched list does not pick the default voice.
      (should-not (member "-v" (plist-get (utter-request "hi" :backend b :dry-run t)
                                          :command))))))

(ert-deftest utter-say-test-request-fake ()
  (utter-say-test-with-fake-say
    (utter-test-with-temp-dir dir
      (let* ((utter-cache-directory dir)
             (b (utter-make-say "Say-fake" :voices '("Samantha")))
             (res (utter-test-request "你好, long text" :backend b :speed 1.5)))
        (should (car res))
        (should (string-suffix-p ".aiff" (car res)))
        (should (string-prefix-p "FORM" (utter-test-file-bytes (car res))))
        (should (eq (plist-get (cadr res) :format) 'aiff))
        (let ((args (utter-say-test-args args-file)))
          (should (equal (seq-take args 4) '("-v" "Samantha" "-r" "262")))
          (should (member "-f" args)))
        ;; The text went through a file, not argv.
        (should (equal (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8))
                           (insert-file-contents (expand-file-name "text" fake-dir)))
                         (buffer-string))
                       "你好, long text"))
        ;; Second call is a cache hit.
        (should (plist-get (cadr (utter-test-request "你好, long text" :backend b :speed 1.5))
                           :cached))))))

(ert-deftest utter-say-test-request-failure ()
  (utter-test-with-temp-dir dir
    (let* ((script (expand-file-name "say" dir))
           (utter-say-program script)
           (b (utter-make-say "Say-fail")))
      (with-temp-file script (insert "#!/bin/sh\necho 'Voice not found' >&2\nexit 1\n"))
      (set-file-modes script #o755)
      (let ((res (utter-test-request "hi" :backend b :cache nil)))
        (should-not (car res))
        (should (string-match-p "Voice not found" (plist-get (cadr res) :error)))))))

(ert-deftest utter-say-test-failure-leaves-no-cache-file ()
  (utter-test-with-temp-dir dir
    (let* ((script (expand-file-name "say" dir))
           (utter-cache-directory (expand-file-name "cache" dir))
           (utter-say-program script)
           (b (utter-make-say "Say-partial")))
      (with-temp-file script
        (insert "#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = -o ] && printf FORM > \"$2\"; shift; done\nexit 1\n"))
      (set-file-modes script #o755)
      (let ((res (utter-test-request "partial" :backend b)))
        (should-not (car res))
        (should-not (utter--cache-files))))))

(ert-deftest utter-say-test-register-default ()
  (let* ((utter--known-backends nil)
         (b (utter-say-register-default)))
    (should (utter-say-p b))
    (should (eq (utter-get-backend "say") b))
    (should (eq (utter-say-register-default) b))
    (should (eq (utter-backend-voices b) 'fetch))))

(ert-deftest utter-say-test-real-say ()
  (skip-unless (executable-find "say"))
  (utter-test-with-temp-dir dir
    (let* ((utter-cache-directory dir)
           (utter-say-program "say")
           (b (utter-make-say "Say-real"))
           (res (utter-test-request "Hello from utter." :backend b)))
      (should (car res))
      (should (string-prefix-p "FORM" (utter-test-file-bytes (car res))))
      (let ((m4a (utter-test-request "Hello again." :backend b :format 'm4a)))
        (should (car m4a))
        (should (eq (utter--sniff (utter--file-head (car m4a))) 'audio))))))

(ert-deftest utter-say-test-real-voices ()
  (skip-unless (executable-find "say"))
  (let* ((utter--voice-cache (make-hash-table :test #'equal))
         (utter-say-program "say")
         (b (utter-make-say "Say-real-v" :voices 'fetch))
         got)
    (utter--list-voices b (lambda (v) (setq got v)))
    (should (utter-test-wait (lambda () got)))
    (should (> (length got) 5))))

(provide 'utter-say-tests)
;;; utter-say-tests.el ends here
