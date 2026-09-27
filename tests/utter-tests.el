;;; utter-tests.el --- Tests for utter.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Commands, text selection, scope and presets.  Shares the fake core
;; and player from utter-queue-tests.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'utter-queue-tests)
(require 'utter)

(defmacro utter-tests-capturing (&rest body)
  "Run BODY with `utter-enqueue' and `utter-interrupt' recorded.
Inside BODY, `calls' is a list of (FUNCTION TEXT PARAMS), newest first."
  (declare (indent 0))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'utter-enqueue)
                (lambda (text &rest params)
                  (push (list 'utter-enqueue (substring-no-properties text) params)
                        calls)))
               ((symbol-function 'utter-interrupt)
                (lambda (text &rest params)
                  (push (list 'utter-interrupt (substring-no-properties text) params)
                        calls))))
       ,@body)))

;;;; Options

(ert-deftest utter-defaults-match-design ()
  (cl-flet ((std (sym) (eval (car (get sym 'standard-value)) t)))
    (dolist (pair `((utter-model . nil) (utter-voice . nil) (utter-format . nil)
                    (utter-voice-alist . nil) (utter-speed . 1.0)
                    (utter-playback-rate . 1.0) (utter-language . auto)
                    (utter-instructions . nil) (utter-highlight . nil)
                    (utter-highlight-follow . nil) (utter-lighter . " ♪%i/%n")
                    (utter-prefetch-depth . 2) (utter-max-concurrent-requests . 2)
                    (utter-cache-max-size . ,(* 500 1024 1024))
                    (utter-voice-cache-ttl . 86400) (utter-player . auto)
                    (utter-curl-program . "curl") (utter-proxy . "")
                    (utter-log-level . nil)
                    (utter-thing-at-point-functions . (utter--gptel-response-at-point))
                    (utter-expert-commands . nil)))
      (should (custom-variable-p (car pair)))
      (should (equal (std (car pair)) (cdr pair))))
    (should (string-suffix-p "utter" (std 'utter-cache-directory)))
    (unless (eq system-type 'darwin)
      (should-not (std 'utter-backend)))))

;;;; Text selection

(ert-deftest utter-speak-reads-region ()
  (utter-tests-capturing
    (with-temp-buffer
      (transient-mark-mode 1)
      (insert "Before. Selected words. After.")
      (goto-char 9)
      (set-mark 9)
      (goto-char 24)
      (activate-mark)
      (utter-speak)
      (should (= (point) 24))
      (should (equal (car calls)
                     (list 'utter-enqueue "Selected words."
                           (list :source-buffer (current-buffer))))))))

(ert-deftest utter-speak-reads-thing-at-point ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "Question?\n")
      (insert (propertize "The answer. It has two sentences." 'gptel 'response))
      (insert "\nNext prompt.")
      (goto-char 15)
      (utter-speak)
      (should (equal (nth 1 (car calls)) "The answer. It has two sentences."))
      (should (= (point) 15)))))

(ert-deftest utter-speak-thing-at-point-functions-are-tried-in-order ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "abcdef. ghi.")
      (goto-char 2)
      (let ((utter-thing-at-point-functions
             (list (lambda () nil) (lambda () (cons 3 5)))))
        (utter-speak)
        (should (equal (nth 1 (car calls)) "cd"))))))

(ert-deftest utter-speak-reads-sentence-at-point ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "First sentence.  Second sentence here.  Third one.")
      (goto-char 22)
      (utter-speak)
      (should (equal (nth 1 (car calls)) "Second sentence here."))
      (should (= (point) 22)))))

(ert-deftest utter-speak-never-reads-whole-buffer-implicitly ()
  (utter-tests-capturing
    (with-temp-buffer
      (should-error (utter-speak) :type 'user-error)
      (should-not calls))))

(ert-deftest utter-speak-prefix-opens-menu ()
  (let ((opened nil))
    (cl-letf (((symbol-function 'utter-menu)
               (lambda () (interactive) (setq opened t))))
      (utter-tests-capturing
        (with-temp-buffer
          (insert "Text.")
          (utter-speak '(4))
          (should opened)
          (should-not calls))))))

(ert-deftest utter-gptel-response-at-point-reads-only-responses ()
  (with-temp-buffer
    (insert "prompt" (propertize "reply" 'gptel 'response) "tail")
    (goto-char 3)
    (should-not (utter--gptel-response-at-point))
    (goto-char 8)
    (should (equal (utter--gptel-response-at-point) '(7 . 12)))
    ;; Point right after the response still counts.
    (goto-char 12)
    (should (equal (utter--gptel-response-at-point) '(7 . 12)))
    (put-text-property 1 7 'gptel 'ignore)
    (goto-char 3)
    (should-not (utter--gptel-response-at-point))))

;;;; Commands

(ert-deftest utter-speak-interrupt-uses-interrupt ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "Now please.")
      (goto-char 2)
      (utter-speak-interrupt)
      (should (eq (car (car calls)) 'utter-interrupt)))))

(ert-deftest utter-speak-string-appends ()
  (utter-tests-capturing
    (utter-speak-string "From Lisp." :voice "v2")
    (should (equal (car calls) '(utter-enqueue "From Lisp." (:voice "v2"))))
    (utter-speak-string "Cut in." :interrupt t)
    (should (equal (car calls) '(utter-interrupt "Cut in." nil)))))

(ert-deftest utter-speak-buffer-whole-or-from-point ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "One. Two. Three.")
      (goto-char 6)
      (utter-speak-buffer)
      (should (equal (nth 1 (car calls)) "One. Two. Three."))
      (utter-speak-buffer t)
      (should (equal (nth 1 (car calls)) "Two. Three."))
      (should (= (point) 6)))))

(ert-deftest utter-speak-kill-reads-latest-kill ()
  (utter-tests-capturing
    (let ((kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil))
      (kill-new "Killed text.")
      (utter-speak-kill)
      (should (equal (car calls)
                     '(utter-enqueue "Killed text." (:source-name "kill ring")))))))

(ert-deftest utter-speak-end-to-end-with-fake-core ()
  (utter-test-with-queue ()
    (with-temp-buffer
      (insert "Spoken for real.")
      (goto-char 3)
      (utter-speak)
      (should (utter-test--wait #'utter-test--idle-p))
      (should (equal (utter-test--texts) '("Spoken for real.")))
      (should (member (format "utter: finished %s (0:00)" (buffer-name))
                      utter-test--messages)))))

(ert-deftest utter-save-to-file-single-request ()
  (utter-test-with-queue ((utter-test--auto nil))
    (let ((file (make-temp-file "utter-save" nil ".wav")))
      (utter-save-to-file "Save me." file)
      (let ((args (utter-test-req-args (car utter-test--requests))))
        (should (equal (utter-test-req-text (car utter-test--requests)) "Save me."))
        (should (equal (plist-get args :file) file))
        (should (eq (plist-get args :format) 'wav)))
      (utter-test--respond 0)
      (should (member (format "utter: saved %s" file) utter-test--messages))
      (delete-file file))))

(ert-deftest utter-save-to-file-refuses-several-requests ()
  (utter-test-with-queue ((utter-backend (utter-test--backend :max-chars 20))
                          (utter--first-segment-chars 20))
    (let ((err (should-error (utter-save-to-file (utter-test--three-sentences)
                                                 "/tmp/x.wav")
                             :type 'user-error)))
      (should (string-match-p "ffmpeg" (cadr err)))
      (should-not (string-match-p "chunk" (cadr err))))
    (should-not utter-test--requests)))

(ert-deftest utter-inspect-query-shows-dry-run ()
  (utter-test-with-queue ((dry nil))
    (cl-letf (((symbol-function 'utter-request)
               (lambda (text &rest args)
                 (setq dry (plist-get args :dry-run))
                 (list :url "https://example.invalid/v1/audio/speech"
                       :headers '(("Authorization" . "Bearer [redacted]"))
                       :body (list :input text)
                       :curl-args '("-s")))))
      (with-temp-buffer
        (insert "Inspect this.")
        (goto-char 2)
        (utter-inspect-query))
      (should dry)
      (with-current-buffer "*utter-inspect*"
        (should (string-match-p "example.invalid" (buffer-string)))
        (should (string-match-p "Inspect this" (buffer-string))))
      (kill-buffer "*utter-inspect*"))))

(ert-deftest utter-select-voice-sets-with-scope ()
  (utter-test-with-queue ()
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (should (member "v2" (all-completions "" collection)))
                 "v2")))
      (with-temp-buffer
        (let ((utter--set-scope t))
          (call-interactively #'utter-select-voice)
          (should (local-variable-p 'utter-voice))
          (should (equal utter-voice "v2")))))))

(ert-deftest utter-log-buffer ()
  (save-window-excursion
    (utter-log)
    (should (equal (buffer-name) "*utter-log*"))))

;;;; Scope

(ert-deftest utter-scope-global-buffer-local-and-oneshot ()
  (utter-test-with-queue ((utter-voice "base"))
    (with-temp-buffer
      (utter--set-with-scope 'utter-voice "local" t)
      (should (local-variable-p 'utter-voice))
      (should (equal utter-voice "local"))
      (utter--set-with-scope 'utter-voice "global" nil)
      (should-not (local-variable-p 'utter-voice))
      (should (equal utter-voice "global")))
    ;; Oneshot lasts for exactly one utterance.
    (utter--set-with-scope 'utter-voice "once" 1)
    (should (equal utter-voice "once"))
    (let ((item (utter-enqueue "First.")))
      (should (equal (plist-get (utter-item-params item) :voice) "once")))
    (should (utter-test--wait (lambda () (equal utter-voice "global")) 1))
    (let ((item (utter-enqueue "Second.")))
      (should (equal (plist-get (utter-item-params item) :voice) "global")))
    (should-not utter-enqueue-hook)))

;;;; Presets

(ert-deftest utter-presets-apply-and-let-bind ()
  (utter-test-with-queue ((utter--known-presets nil) (order nil))
    (utter-make-preset 'base :description "Base" :voice "v1" :speed 0.9)
    (utter-make-preset 'fast
      :description "Fast English"
      :parents 'base
      :pre (lambda () (push 'pre order))
      :post (lambda () (push 'post order))
      :speed 1.5 :playback-rate 1.2)
    (should (equal (plist-get (utter-get-preset 'fast) :description) "Fast English"))
    (let ((utter-voice nil) (utter-speed 1.0) (utter-playback-rate 1.0))
      (utter-with-preset 'fast
        (should (equal utter-voice "v1"))
        (should (= utter-speed 1.5))
        (should (= utter-playback-rate 1.2))
        (let ((item (utter-speak-string "Preset text.")))
          (should (= (plist-get (utter-item-params item) :speed) 1.5))))
      (should (equal (reverse order) '(pre post)))
      (should-not utter-voice)
      (should (= utter-speed 1.0))
      (utter--apply-preset 'fast)
      (should (= utter-speed 1.5))
      (should (eq utter--preset 'fast)))))

(ert-deftest utter-preset-backend-by-name-and-setter ()
  (utter-test-with-queue ((utter--known-presets nil) (set nil))
    (let ((other (utter-test--backend :name "Other")))
      (cl-letf (((symbol-function 'utter-get-backend)
                 (lambda (name) (and (equal name "Other") other))))
        (utter--apply-preset '(:backend "Other" :voice "v2")
                             (lambda (sym val) (push (cons sym val) set)))
        (should (eq (alist-get 'utter-backend set) other))
        (should (equal (alist-get 'utter-voice set) "v2"))
        (should-error (utter--apply-preset '(:backend "Missing")) :type 'user-error)
        (should-error (utter--apply-preset 'no-such-preset) :type 'user-error)))))

;;;; Repository rules

(defconst utter-tests--source-files '("utter.el" "utter-text.el" "utter-queue.el")
  "Source files owned by the engine.")

(defun utter-tests--source (file)
  "Return the contents of FILE from the package directory."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file (file-name-directory (locate-library "utter"))))
    (buffer-string)))

(ert-deftest utter-no-user-visible-chunk ()
  (dolist (file utter-tests--source-files)
    (should-not (string-match-p "chunk" (downcase (utter-tests--source file))))))

(ert-deftest utter-commands-have-autoload-cookies ()
  (dolist (file utter-tests--source-files)
    (with-temp-buffer
      (insert (utter-tests--source file))
      (goto-char (point-min))
      (while (re-search-forward "^(defun \\(utter-[^- ][^ ]*\\) " nil t)
        (let ((name (match-string 1)))
          (when (commandp (intern name))
            (save-excursion
              (forward-line -1)
              (should (equal (list name (looking-at-p ";;;###autoload"))
                             (list name t))))))))))

(provide 'utter-tests)
;;; utter-tests.el ends here
