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
                    (utter-player . auto)
                    (utter-input-functions . (utter--gptel-response-at-point
                                              utter--org-subtree-at-point
                                              utter--page-at-point))
                    (utter-page-modes . (eww-mode Info-mode nov-mode help-mode
                                         Man-mode woman-mode))
                    (utter-org-input . subtree)
                    (utter-expert-commands . nil)))
      (should (custom-variable-p (car pair)))
      (should (equal (std (car pair)) (cdr pair))))
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

(ert-deftest utter-speak-input-functions-are-tried-in-order ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "abcdef. ghi.")
      (goto-char 2)
      (let ((utter-input-functions
             (list (lambda () nil) (lambda () (cons 3 5)))))
        (utter-speak)
        (should (equal (nth 1 (car calls)) "cd"))))))

(ert-deftest utter-speak-reads-buffer-to-point ()
  "Like gptel: no region means the buffer from its start to point."
  (utter-tests-capturing
    (with-temp-buffer
      (insert "First sentence.  Second sentence here.  Third one.")
      (goto-char 39)
      (utter-speak)
      (should (equal (nth 1 (car calls)) "First sentence.  Second sentence here."))
      (should (= (point) 39)))))

(ert-deftest utter-speak-at-buffer-start-reads-whole-buffer ()
  "Nothing before point (a freshly opened file) means the whole buffer."
  (utter-tests-capturing
    (with-temp-buffer
      (insert "Alpha.  Beta.")
      (goto-char (point-min))
      (utter-speak)
      (should (equal (nth 1 (car calls)) "Alpha.  Beta."))
      (goto-char 2)
      (utter-speak)
      (should (equal (nth 1 (car calls)) "A")))))

(ert-deftest utter-speak-errors-on-a-blank-buffer ()
  (utter-tests-capturing
    (with-temp-buffer
      (should-error (utter-speak) :type 'user-error)
      (insert "  \n\t")
      (should-error (utter-speak) :type 'user-error)
      (should-not calls))))

(ert-deftest utter-speak-errors-on-a-blank-region ()
  (utter-tests-capturing
    (with-temp-buffer
      (transient-mark-mode 1)
      (insert "Words   here.")
      (set-mark 6)
      (goto-char 9)
      (activate-mark)
      (let ((err (should-error (utter-speak) :type 'user-error)))
        (should (string-match-p "region" (cadr err))))
      (should-not calls))))

(ert-deftest utter-speak-org-reads-the-subtree-at-point ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "Preamble.\n* A\nalpha\n** A1\nbeta\n* B\ngamma\n")
      (org-mode)
      (goto-char (point-min))
      (search-forward "alpha")
      (utter-speak)
      (should (equal (nth 1 (car calls)) "* A\nalpha\n** A1\nbeta\n"))
      ;; Before the first heading there is no subtree: buffer to point.
      (goto-char 6)
      (utter-speak)
      (should (equal (nth 1 (car calls)) "Pream"))
      ;; The option turns the heuristic off.
      (search-forward "beta")
      (let ((utter-org-input 'to-point))
        (utter-speak)
        (should (equal (nth 1 (car calls))
                       "Preamble.\n* A\nalpha\n** A1\nbeta"))))))

(ert-deftest utter-speak-page-modes-read-the-whole-page ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "Rendered page text.  More of it.")
      (goto-char 10)
      (setq major-mode 'eww-mode)
      (utter-speak)
      (should (equal (nth 1 (car calls)) "Rendered page text.  More of it."))
      (let ((utter-page-modes nil))
        (utter-speak)
        (should (equal (nth 1 (car calls)) "Rendered "))))))

(ert-deftest utter-input-label-names-the-source ()
  (with-temp-buffer
    (insert "Some text.")
    (goto-char (point-max))
    (should (equal (utter-input-label) "buffer to point"))
    (goto-char (point-min))
    (should (equal (utter-input-label) "whole buffer"))
    (transient-mark-mode 1)
    (set-mark 1) (goto-char 5) (activate-mark)
    (should (equal (utter-input-label) "region"))
    (deactivate-mark)
    (setq major-mode 'Info-mode)
    (should (equal (utter-input-label) "page"))
    (org-mode)
    (erase-buffer)
    (insert "* H\nbody")
    (should (equal (utter-input-label) "Org subtree"))
    (erase-buffer)
    (should (equal (utter-input-label) "nothing"))))

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
  (utter-eng-with-queue ()
    (with-temp-buffer
      (insert "Spoken for real.")
      (utter-speak)
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (equal (utter-eng--texts) '("Spoken for real.")))
      (should (member (format "utter: finished %s (0:00)" (buffer-name))
                      utter-eng--messages)))))

(ert-deftest utter-save-to-file-single-request ()
  (utter-eng-with-queue ((utter-eng--auto nil))
    (let ((file (make-temp-file "utter-save" nil ".wav")))
      (utter-save-to-file "Save me." file)
      (let ((args (utter-eng-req-args (car utter-eng--requests))))
        (should (equal (utter-eng-req-text (car utter-eng--requests)) "Save me."))
        (should (equal (plist-get args :file) file))
        (should (eq (plist-get args :format) 'wav)))
      (utter-eng--respond 0)
      (should (member (format "utter: saved %s" file) utter-eng--messages))
      (delete-file file))))

(ert-deftest utter-save-to-file-refuses-several-requests ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend :max-chars 20))
                          (utter--first-segment-chars 20))
    (let ((err (should-error (utter-save-to-file (utter-eng--three-sentences)
                                                 "/tmp/x.wav")
                             :type 'user-error)))
      (should (string-match-p "ffmpeg" (cadr err)))
      (should-not (string-match-p "chunk" (cadr err))))
    (should-not utter-eng--requests)))

(ert-deftest utter-inspect-query-shows-dry-run ()
  (utter-eng-with-queue ((dry nil))
    (cl-letf (((symbol-function 'utter-request)
               (lambda (text &rest args)
                 (setq dry (plist-get args :dry-run))
                 (list :url "https://example.invalid/v1/audio/speech"
                       :headers '(("Authorization" . "Bearer [redacted]"))
                       :body (list :input text)
                       :curl-args '("-s")))))
      (with-temp-buffer
        (insert "Inspect this.")
        (utter-inspect-query))
      (should dry)
      (with-current-buffer "*utter-inspect*"
        (should (string-match-p "example.invalid" (buffer-string)))
        (should (string-match-p "Inspect this" (buffer-string))))
      (kill-buffer "*utter-inspect*")
      ;; The menu shares the same path for any text.
      (with-temp-buffer
        (utter--inspect-text "Given text."))
      (with-current-buffer "*utter-inspect*"
        (should (string-match-p "Given text" (buffer-string))))
      (kill-buffer "*utter-inspect*"))))

(ert-deftest utter-select-voice-sets-with-scope ()
  (utter-eng-with-queue ()
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
    (should (equal (buffer-name) utter--log-buffer-name))))

(ert-deftest utter-text-at-point-for-the-menu ()
  (with-temp-buffer
    (insert "One here.  Two there.")
    (goto-char 10)
    (should (equal (utter--text-at-point) (cons "One here." (buffer-name))))
    (erase-buffer)
    (should-error (utter--text-at-point) :type 'user-error)))

;;;; Scope

(ert-deftest utter-scope-global-buffer-local-and-oneshot ()
  (utter-eng-with-queue ((utter-voice "base"))
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
    (should (utter-eng--wait (lambda () (equal utter-voice "global")) 1))
    (let ((item (utter-enqueue "Second.")))
      (should (equal (plist-get (utter-item-params item) :voice) "global")))
    (should-not utter-enqueue-hook)))

(ert-deftest utter-scope-oneshot-restores-buffer-local-values ()
  "A oneshot set where the option is buffer-local restores that buffer, not the default."
  (utter-eng-with-queue ((utter-speed 1.0))
    (let ((a (generate-new-buffer "oneshot-a")) (b (generate-new-buffer "oneshot-b")))
      (unwind-protect
          (progn
            (with-current-buffer a
              (utter--set-with-scope 'utter-speed 1.5 t)
              (utter--set-with-scope 'utter-speed 2.0 1)
              (should (= utter-speed 2.0)))
            (with-current-buffer b
              (utter-enqueue "Next.")
              (should (utter-eng--wait
                       (lambda () (= (buffer-local-value 'utter-speed a) 1.5)) 1)))
            (should (= (default-value 'utter-speed) 1.0))
            (should (local-variable-p 'utter-speed a)))
        (kill-buffer a) (kill-buffer b)))))

;;;; Sanitizing settings

(ert-deftest utter-sanitize-clears-settings-foreign-to-the-backend ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend))
                          (utter-model 'other-model) (utter-voice "nova"))
    (utter--sanitize-settings)
    (should-not utter-model)
    (should-not utter-voice)
    (setq utter-model 'fake-model utter-voice "v2")
    (utter--sanitize-settings)
    (should (eq utter-model 'fake-model))
    (should (equal utter-voice "v2"))
    ;; No model list means nothing to pick, so a model there is stale.
    (let ((utter-backend (utter-eng--backend :models nil)))
      (setq utter-model 'fake-model)
      (utter--sanitize-settings)
      (should-not utter-model))
    ;; A voice list that is still to be fetched cannot be checked: keep it.
    (let ((utter-backend (utter-eng--backend :voices 'fetch)))
      (setq utter-voice "anything")
      (utter--sanitize-settings)
      (should (equal utter-voice "anything")))
    ;; SKIP protects values the caller just set; SETTER receives the clears.
    (let (set)
      (setq utter-model 'other-model utter-voice "nova")
      (utter--sanitize-settings nil (lambda (sym val) (push (cons sym val) set))
                                '(utter-voice))
      (should (equal set '((utter-model . nil)))))))

(ert-deftest utter-preset-with-only-a-backend-drops-stale-model-and-voice ()
  (utter-eng-with-queue ((utter--known-presets nil)
                          (utter-backend (utter-eng--backend :name "A" :models '(a-model)
                                                             :voices '("a1")))
                          (utter-model 'a-model) (utter-voice "a1"))
    (let ((b (utter-eng--backend :name "B" :models '(b-model) :voices '("b1"))))
      (cl-letf (((symbol-function 'utter-get-backend)
                 (lambda (name) (and (equal name "B") b))))
        (utter--apply-preset '(:backend "B"))
        (should (eq utter-backend b))
        (should-not utter-model)
        (should-not utter-voice)
        ;; Values the preset sets itself are trusted.
        (utter--apply-preset '(:backend "B" :voice "b1" :model b-model))
        (should (equal utter-voice "b1"))
        (should (eq utter-model 'b-model))))))

;;;; Error wording

(ert-deftest utter-command-errors-start-with-nothing-to-read-aloud ()
  (utter-tests-capturing
    (with-temp-buffer
      (insert "text")
      (let ((err (should-error (utter-speak-buffer t) :type 'user-error)))
        (should (string-prefix-p "Nothing to read aloud" (cadr err)))))
    (let ((kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil))
      (let ((err (should-error (utter-speak-kill) :type 'user-error)))
        (should (string-prefix-p "Nothing to read aloud" (cadr err)))))
    (should-not calls)))

;;;; Presets

(ert-deftest utter-presets-apply-and-let-bind ()
  (utter-eng-with-queue ((utter--known-presets nil) (order nil))
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
  (utter-eng-with-queue ((utter--known-presets nil) (set nil))
    (let ((other (utter-eng--backend :name "Other")))
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
