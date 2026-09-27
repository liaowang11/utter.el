;;; utter-transient-tests.el --- Tests for utter-menu -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for `utter-menu', its infix classes and `utter--suffix-speak'.
;; The fake engine comes from `utter-mode-tests'.  The menu really is
;; set up with `transient-setup' (this works in batch) and torn down with
;; `transient--emergency-exit'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'utter-mode-tests)
(require 'utter-transient)

;; Fake backends.  xAI's voices are fetched, like the real xAI,
;; ElevenLabs and say backends, so its slot holds the symbol `fetch'.
(defun utter-transient-test--backends ()
  "Return a fake `utter--known-backends' alist."
  (list (cons "OpenAI"
              (utter--make-backend
               :name "OpenAI" :max-chars 4096 :capabilities '(instructions)
               :models '((gpt-4o-mini-tts :description "steerable"
                                          :capabilities (instructions)
                                          :cost 12)
                         (tts-1 :capabilities nil :formats (mp3 opus)))
               :voices '("alloy" "nova") :formats '(mp3 wav)))
        (cons "ElevenLabs"
              (utter--make-backend :name "ElevenLabs"
                                   :models '(eleven_v3) :voices nil))
        (cons "xAI"
              (utter--make-backend :name "xAI" :voices 'fetch
                                   :formats '(mp3 wav)))
        (cons "say"
              (utter--make-backend :name "say" :voices '("Samantha")
                                   :formats '(aiff)))))

(cl-defmacro utter-transient-test-with-menu ((&key text value setup)
                                             &rest body)
  "Open `utter-menu' in a temp buffer, run BODY, then close the menu.
The buffer holds TEXT with point at its end; SETUP runs before the
menu opens; VALUE is the menu's initial switches."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (rename-buffer "menu-source" t)
     (insert (or ,text ""))
     (utter-ui-test-with-engine
       (cl-letf ,(mapcar (lambda (cmd)
                           `((symbol-function ',cmd)
                             (lambda (&rest _) (interactive))))
                         '(utter-toggle-pause utter-next utter-previous
                           utter-rate-up utter-rate-down utter-clear
                           utter-stop))
         (let* ((utter--known-backends (utter-transient-test--backends))
                (utter-backend (cdar utter--known-backends))
                (utter-model nil)
                (utter-voice nil)
                (transient-values (list (cons 'utter-menu ,value))))
           ,setup
           (unwind-protect
               (progn (utter-menu) ,@body)
             (transient--emergency-exit)))))))

(defun utter-transient-test--suffixes ()
  "Return an alist (KEY . OBJECT) of the shown suffixes and infixes."
  (mapcar (lambda (obj) (cons (oref obj key) obj)) transient--suffixes))

(defun utter-transient-test--menu-text ()
  "Return the text of the transient menu buffer."
  (with-current-buffer transient--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun utter-transient-test--menu-line (needle)
  "Return the line of the menu text that contains NEEDLE, or nil."
  (cl-find-if (lambda (line) (string-search needle line))
              (split-string (utter-transient-test--menu-text) "\n")))

(defun utter-transient-test--face-at (needle)
  "Return the face at the start of NEEDLE in the menu buffer."
  (with-current-buffer transient--buffer-name
    (goto-char (point-min))
    (and (search-forward needle nil t)
         (get-text-property (match-beginning 0) 'face))))

(defun utter-transient-test--has-face-p (face value)
  "Return non-nil when FACE, a face property VALUE, includes FACE."
  (or (eq value face)
      (and (consp value)
           (or (memq face value)
               (eq (plist-get value :inherit) face)))))

;;;; Layout

(ert-deftest utter-transient-test-layout-idle ()
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu ()
      (let ((keys (mapcar #'car (utter-transient-test--suffixes))))
        (dolist (key '("-m" "-v" "-s" "-f" "-l" "-i" "-H" "=" "@"
                       "y" "m" "S" "f" "c" "RET"))
          (should (member key keys)))
        ;; Append is the default and has no switch of its own.
        (should-not (member "s" keys))
        ;; Input is a heuristic, not a switch per source.
        (dolist (key '("SPC" "n" "p" "+" "_" "x" "q" "Q" "r" "b" "o" "e" "t"))
          (should-not (member key keys))))
      (should (eq (oref (cdr (assoc "RET" (utter-transient-test--suffixes)))
                        command)
                  'utter--suffix-speak))
      (should (oref transient--prefix refresh-suffixes))
      (should (equal (oref transient--prefix incompatible)
                     '(("m" "y") ("S" "f" "c"))))
      (let ((text (utter-transient-test--menu-text)))
        (should (string-prefix-p "Idle" text))
        (dolist (label '("Backend" " <Read from nothing" " >Output to"
                         "Backend:model" "OpenAI:gpt-4o-mini-tts"
                         "Highlight spoken text"
                         "Kill-ring instead" "Minibuffer instead"
                         "Speakers, interrupt" "Save to file" "Cache only"
                         "RET Nothing to read aloud"))
          (should (string-search label text)))
        (dolist (label '("Speakers, append" "Input <" "Output >"
                         "Region (default)" "Buffer from point" "Org subtree"
                         "EWW / Info page" "String from Lisp"))
          (should-not (string-search label text)))
        (should-not (string-search "Playback" text))
        (should-not (string-search "Inspect" text)))
      (should (eq (utter-transient-test--face-at "Nothing to read aloud")
                  'error)))))

(ert-deftest utter-transient-test-layout-playing ()
  (let ((utter-ui-test--state utter-ui-test--playing-state))
    (utter-transient-test-with-menu (:text "One two.")
      (let ((suffixes (utter-transient-test--suffixes)))
        (pcase-dolist (`(,key . ,command)
                       '(("SPC" . utter-toggle-pause) ("n" . utter-next)
                         ("p" . utter-previous) ("+" . utter-rate-up)
                         ("_" . utter-rate-down) ("x" . utter-clear)
                         ("q" . utter-stop)))
          (let ((obj (cdr (assoc key suffixes))))
            (should obj)
            (should (eq (oref obj command) command))
            (should (eq (oref obj transient) t))))
        ;; The queue buffer has keys of its own, so the menu must go.
        (let ((queue (cdr (assoc "Q" suffixes))))
          (should (eq (oref queue command) 'utter-queue))
          (should-not (and (slot-boundp queue 'transient)
                           (eq (oref queue transient) t)))))
      (let ((text (utter-transient-test--menu-text)))
        (should (string-prefix-p
                 "Playing reading-aloud.org (2/5) · OpenAI:gpt-4o-mini-tts/nova"
                 text))
        (should (string-search "Playback" text))
        (should (string-search "Next utterance" text))
        (should (string-search "append as utterance 6" text))))))

(ert-deftest utter-transient-test-rate-shown-once ()
  "The rate appears once, on the rate-up key, not in the heading too."
  (let ((utter-ui-test--state (plist-put (copy-sequence
                                          utter-ui-test--playing-state)
                                         :rate 1.2))
        (utter-playback-rate 1.2))
    (utter-transient-test-with-menu ()
      (let ((text (utter-transient-test--menu-text)))
        (should (string-search "Rate up (1.2x)" text))
        (should (string-search "Rate down" text))
        (should-not (string-search "Rate down (" text))
        (should (= 1 (with-temp-buffer
                       (insert text)
                       (how-many "1\\.2x" (point-min) (point-max)))))))))

(ert-deftest utter-transient-test-inspect-needs-expert ()
  (let ((utter-ui-test--state '(:status idle)))
    (dolist (setting '((t . nil) (nil . info)))
      (let ((utter-expert-commands (car setting))
            (utter-log-level (cdr setting)))
        (utter-transient-test-with-menu ()
          (should (eq (oref (cdr (assoc "I" (utter-transient-test--suffixes)))
                            command)
                      'utter--suffix-inspect))
          (should (string-search "I Inspect" (utter-transient-test--menu-text))))))
    (let ((utter-expert-commands nil) (utter-log-level nil))
      (utter-transient-test-with-menu ()
        (should-not (string-search "Inspect" (utter-transient-test--menu-text)))))))

;;;; Live refresh

(ert-deftest utter-transient-test-refresh-hook-installed-at-load ()
  "The menu listens to every engine state change, open or closed."
  (should (memq #'utter-transient--refresh-menu utter--state-change-hook))
  (should-not (memq #'utter-transient--refresh-menu utter-progress-functions))
  (should-not (memq #'utter-transient--refresh-menu utter-queue-finished-hook))
  (should-not (fboundp 'utter-transient--install-refresh))
  (should-not (fboundp 'utter-transient--remove-refresh)))

(ert-deftest utter-transient-test-refresh-guards ()
  (let ((utter-ui-test--state '(:status idle))
        (refreshed 0))
    (cl-letf (((symbol-function 'transient--refresh-transient)
               (lambda () (cl-incf refreshed))))
      (utter-transient-test-with-menu ()
        (utter-transient--refresh-menu)
        (should (= refreshed 1))
        ;; A menu suffix is running: its post-command redraws anyway.
        (let ((transient-current-command 'utter-menu))
          (utter-transient--refresh-menu)
          (should (= refreshed 1))))
      ;; Closed menu: the guard keeps the refresh away.
      (utter-transient--refresh-menu)
      (should (= refreshed 1)))))

(ert-deftest utter-transient-test-no-refresh-while-reading ()
  "A refresh while an infix reads from the minibuffer waits for the next key."
  (let ((transient--prefix (transient-prefix :command 'utter-menu))
        (refreshed 0))
    (cl-letf (((symbol-function 'transient--refresh-transient)
               (lambda () (cl-incf refreshed)))
              ((symbol-function 'active-minibuffer-window)
               (lambda () (selected-window))))
      (utter-transient--refresh-menu)
      (should (= refreshed 0)))))

;; The real private function, on whichever transient is loaded.
(ert-deftest utter-transient-test-refresh-redraws-open-menu ()
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu ()
      (should-not (string-search "Playback" (utter-transient-test--menu-text)))
      (setq utter-ui-test--state utter-ui-test--playing-state)
      (with-temp-buffer                 ; an unrelated current buffer
        (run-hooks 'utter--state-change-hook))
      (let ((text (utter-transient-test--menu-text)))
        (should (string-prefix-p "Playing reading-aloud.org" text))
        (should (string-search "Playback" text))
        (should (assoc "SPC" (utter-transient-test--suffixes))))
      ;; Going idle hides the column again.
      (setq utter-ui-test--state '(:status idle))
      (run-hooks 'utter--state-change-hook)
      (should-not (string-search "Playback" (utter-transient-test--menu-text))))))

(ert-deftest utter-transient-test-refresh-survives-suspend ()
  "After C-z and `transient-resume' the heading still follows the engine."
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu (:text "Some text.")
      (execute-kbd-macro (kbd "C-z"))
      (should-not transient--prefix)
      (transient-resume)
      (setq utter-ui-test--state utter-ui-test--playing-state)
      (run-hooks 'utter--state-change-hook)
      (should (string-prefix-p "Playing reading-aloud.org"
                               (utter-transient-test--menu-text))))))

(ert-deftest utter-transient-test-queue-key-exits ()
  (let ((utter-ui-test--state utter-ui-test--playing-state)
        opened)
    (cl-letf (((symbol-function 'utter-queue)
               (lambda () (interactive) (setq opened t))))
      (utter-transient-test-with-menu ()
        (execute-kbd-macro (kbd "Q"))
        (should opened)
        (should-not transient--prefix)))))

(ert-deftest utter-transient-test-refresh-applies-environment ()
  "An async redraw runs inside the prefix environment, like a keypress one."
  (skip-unless (fboundp 'transient--env-apply))
  (let ((utter-ui-test--state '(:status idle))
        applied)
    (utter-transient-test-with-menu ()
      (cl-letf (((symbol-function 'transient--env-apply)
                 (lambda (fn &rest _) (setq applied fn))))
        (utter-transient--refresh-menu)
        (should (eq applied #'transient--refresh-transient))))))

(ert-deftest utter-transient-test-evil-environment-attached ()
  (if (slot-exists-p 'transient-prefix 'environment)
      (should (eq (oref (get 'utter-menu 'transient--prefix) environment)
                  #'utter--transient-fix-evil-visual))
    (should-not (slot-exists-p 'transient-prefix 'environment))))

;;;; Live labels: the Input heading and RET

(ert-deftest utter-transient-test-live-args ()
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu (:value '("S"))
      (should (equal (utter-transient--live-args) '("S"))))
    (utter-transient-test-with-menu ()
      (should (null (utter-transient--live-args))))))

(ert-deftest utter-transient-test-input-heading ()
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu (:text "One two. Three four.")
      (should (utter-transient-test--menu-line " <Read from buffer to point")))
    (utter-transient-test-with-menu
        (:text "One two. Three four."
         :setup (progn (transient-mark-mode 1) (set-mark 1) (goto-char 4)
                       (activate-mark)))
      (should (utter-transient-test--menu-line " <Read from region")))
    (utter-transient-test-with-menu (:text "One two." :value '("m"))
      (should (utter-transient-test--menu-line " <Read from minibuffer")))
    (let ((kill-ring '("killed text\nsecond line")) (interprogram-paste-function nil))
      (utter-transient-test-with-menu (:text "One two." :value '("y"))
        (should (utter-transient-test--menu-line
                 " <Read from kill-ring \"killed text\""))))
    (let ((kill-ring nil) (interprogram-paste-function nil))
      (utter-transient-test-with-menu (:text "One two." :value '("y"))
        (should (utter-transient-test--menu-line " <Read from kill ring empty"))
        (should (utter-transient-test--has-face-p
                 'error (utter-transient-test--face-at "kill ring empty")))))))

(defun utter-transient-test--ret (&rest menu-args)
  "Return the RET line of the menu opened with MENU-ARGS, trimmed.
MENU-ARGS are :text, :value and :setup (a function) as for the menu
macro."
  (let (line)
    (utter-transient-test-with-menu
        (:text (plist-get menu-args :text)
         :value (plist-get menu-args :value)
         :setup (when-let* ((setup (plist-get menu-args :setup)))
                  (funcall setup)))
      (setq line (utter-transient-test--menu-line "RET ")))
    (and line (string-trim (substring line (string-search "RET " line))))))

(ert-deftest utter-transient-test-ret-describes-the-request ()
  (let* ((utter-ui-test--state '(:status idle))
         ;; 10 lines of 22 characters and 9 newlines: 229 chars, 19 s at 12/s.
         (lines (mapconcat (lambda (i) (format "Line %02d is some prose." i))
                           (number-sequence 1 10) "\n"))
         (region (lambda ()
                   (transient-mark-mode 1)
                   (goto-char (point-min)) (forward-line 8) (set-mark (point))
                   (goto-char (point-max)) (activate-mark))))
    (should (equal (utter-transient-test--ret :text lines)
                   "RET Speak buffer to point (lines 1-10, ~19 s)"))
    (should (equal (utter-transient-test--ret :text lines :setup region)
                   "RET Speak region (lines 9-10, ~4 s)"))
    (should (equal (utter-transient-test--ret :text lines :value '("S"))
                   "RET Speak buffer to point (lines 1-10, ~19 s)"))
    (should (equal (utter-transient-test--ret :text lines :value '("f"))
                   "RET Save buffer to point (lines 1-10) to file"))
    (should (equal (utter-transient-test--ret :text lines :value '("c"))
                   "RET Synthesize buffer to point (lines 1-10, ~19 s), cache only"))
    (should (equal (utter-transient-test--ret :text lines :value '("m"))
                   "RET Speak minibuffer input"))
    (let ((kill-ring '("first words of a kill")) (interprogram-paste-function nil))
      (should (equal (utter-transient-test--ret :text lines :value '("y"))
                     "RET Speak kill-ring \"first words of a kill\" (~2 s)")))
    (let ((kill-ring nil) (interprogram-paste-function nil))
      (should (equal (utter-transient-test--ret :text lines :value '("y"))
                     "RET Nothing to read aloud")))
    (should (equal (utter-transient-test--ret :text "   ")
                   "RET Nothing to read aloud"))
    ;; Minutes once the estimate passes a minute: 40 lines ~ 1.3 min.
    (should (equal (utter-transient-test--ret
                    :text (mapconcat #'identity (make-list 40 "Line 01 is some prose.  ")
                                     "\n"))
                   "RET Speak buffer to point (lines 1-40, ~1 min)"))))

(ert-deftest utter-transient-test-ret-while-playing ()
  (let ((utter-ui-test--state utter-ui-test--playing-state))
    (should (equal (utter-transient-test--ret :text "One two three.")
                   "RET Speak buffer to point (line 1, ~1 s), append as utterance 6"))
    (should (equal (utter-transient-test--ret :text "One two three." :value '("S"))
                   "RET Speak buffer to point (line 1, ~1 s), interrupt now"))
    (should (equal (utter-transient-test--ret :text "One two three." :value '("f"))
                   "RET Save buffer to point (line 1) to file"))))

(ert-deftest utter-transient-test-labels-follow-key-presses ()
  "Toggling a switch with its key relabels RET and the Input heading."
  (let ((utter-ui-test--state utter-ui-test--playing-state)
        (kill-ring nil) (interprogram-paste-function nil))
    (utter-transient-test-with-menu (:text "One two three.")
      (should (string-search "append as utterance 6"
                             (utter-transient-test--menu-line "RET ")))
      (execute-kbd-macro (kbd "S"))
      (should (string-search "interrupt now"
                             (utter-transient-test--menu-line "RET ")))
      (execute-kbd-macro (kbd "f"))
      (should (string-search "RET Save buffer to point"
                             (utter-transient-test--menu-line "RET ")))
      (execute-kbd-macro (kbd "m"))
      (should (utter-transient-test--menu-line " <Read from minibuffer"))
      (should (string-search "RET Save minibuffer input to file"
                             (utter-transient-test--menu-line "RET "))))))

(ert-deftest utter-transient-test-descriptions-never-signal ()
  "A failing input function yields a label, not an error."
  (let ((utter-ui-test--state '(:status idle))
        (utter-input-functions (list (lambda () (error "Boom")))))
    (should (equal (utter-transient-test--ret :text "Some text.")
                   "RET Nothing to read aloud"))))

(ert-deftest utter-transient-test-plan-computed-once-per-redraw ()
  (let ((utter-ui-test--state '(:status idle))
        (calls 0))
    (utter-transient-test-with-menu (:text "Some text here.")
      (cl-letf* ((orig (symbol-function 'utter--input-candidate))
                 ((symbol-function 'utter--input-candidate)
                  (lambda () (cl-incf calls) (funcall orig))))
        (setq utter-transient--plan-cache nil)
        (transient--refresh-transient)
        (should (= calls 1))))))

;;;; Heading

(defun utter-transient-test--heading (state)
  "Return the menu heading for STATE, without properties."
  (let ((utter-ui-test--state state))
    (utter-ui-test-with-engine
      (substring-no-properties (utter--menu-heading)))))

(ert-deftest utter-transient-test-heading ()
  (should (equal (utter-transient-test--heading '(:status idle)) "Idle"))
  (should (equal (utter-transient-test--heading nil) "Idle"))
  (should (equal (utter-transient-test--heading utter-ui-test--playing-state)
                 (concat "Playing reading-aloud.org (2/5) · "
                         "OpenAI:gpt-4o-mini-tts/nova")))
  ;; The rate is shown once, on the rate-up key, so not here.
  (should (equal (utter-transient-test--heading
                  '(:status paused :index 1 :total 1 :backend "say"
                    :voice "Samantha" :rate 1.2 :source "*eww*"))
                 "Paused *eww* (1/1) · say/Samantha"))
  (should (equal (utter-transient-test--heading
                  '(:status synthesizing :index 3 :total 5 :backend "OpenAI"
                    :model tts-1 :source "notes.org"))
                 "Synthesizing notes.org (3/5) · OpenAI:tts-1")))

;;;; Dispatch

(defmacro utter-transient-test-with-text (text &rest body)
  "Run BODY in a buffer with TEXT, the fake engine and no selection."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (rename-buffer "dispatch-source" t)
     (insert ,text)
     (goto-char (point-min))
     (utter-ui-test-with-engine
       (let* ((utter--known-backends (utter-transient-test--backends))
              (utter-backend (cdar utter--known-backends))
              (utter-model nil) (utter-voice nil) (utter-format nil))
         ,@body))))

(defun utter-transient-test--last-call ()
  "Return the newest recorded engine call."
  (car utter-ui-test--calls))

(ert-deftest utter-transient-test-speak-default-region ()
  (utter-transient-test-with-text "One two. Three four."
    (transient-mark-mode 1)
    (set-mark 5)
    (goto-char 8)
    (activate-mark)
    (dolist (args '(nil ("-H")))
      (setq utter-ui-test--calls nil)
      (utter--suffix-speak args)
      (let ((call (utter-transient-test--last-call)))
        (should (eq (car call) 'utter-enqueue))
        (should (equal (nth 1 call) "two"))
        (should (eq (plist-get (nthcdr 2 call) :source-buffer)
                    (current-buffer)))
        (should (equal (plist-get (nthcdr 2 call) :source-name)
                       (buffer-name)))))))

(ert-deftest utter-transient-test-speak-default-buffer-to-point ()
  "Without a region RET reads the buffer up to point, as gptel does."
  (utter-transient-test-with-text "One two. Three four."
    (goto-char 9)
    (utter--suffix-speak nil)
    (should (equal (nth 1 (utter-transient-test--last-call)) "One two."))
    (goto-char (point-max))
    (utter--suffix-speak nil)
    (should (equal (nth 1 (utter-transient-test--last-call))
                   "One two. Three four."))))

(ert-deftest utter-transient-test-input-description-shows-the-source ()
  (utter-transient-test-with-text "One two. Three four."
    (goto-char 9)
    (should (equal (substring-no-properties (utter-transient--input-description))
                   " <Read from buffer to point"))
    (transient-mark-mode 1)
    (set-mark 1) (goto-char 4) (activate-mark)
    (should (equal (substring-no-properties (utter-transient--input-description))
                   " <Read from region"))))

(ert-deftest utter-transient-test-speak-highlight-carries-tags ()
  "RET goes through the engine's text path, so highlight tags survive."
  (utter-transient-test-with-text "Some text."
    (goto-char (point-max))
    (let ((utter-highlight t))
      (utter--suffix-speak nil)
      (should (equal (nth 1 (utter-transient-test--last-call))
                     (utter--buffer-text (point-min) (point-max)))))))

(ert-deftest utter-transient-test-speak-uses-engine-text-at-point ()
  (utter-transient-test-with-text "whatever"
    (cl-letf (((symbol-function 'utter--text-at-point)
               (lambda (&optional _) (cons "response" "gptel response"))))
      (utter--suffix-speak nil)
      (let ((call (utter-transient-test--last-call)))
        (should (equal (nth 1 call) "response"))
        (should (equal (plist-get (nthcdr 2 call) :source-name)
                       "gptel response"))))))

(ert-deftest utter-transient-test-speak-inputs ()
  (utter-transient-test-with-text "Head.\nMiddle part. End part."
    (let ((kill-ring '("killed text")) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil))
      (utter--suffix-speak '("y"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "killed text"))
      (should (equal (plist-get (nthcdr 2 (utter-transient-test--last-call))
                                :source-name)
                     "kill-ring")))
    (let ((kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil))
      (let ((err (should-error (utter--suffix-speak '("y")) :type 'user-error)))
        (should (string-match-p "kill ring" (cadr err)))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "typed")))
      (utter--suffix-speak '("m"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "typed")))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
      (let ((err (should-error (utter--suffix-speak '("m")) :type 'user-error)))
        (should (string-match-p "minibuffer" (cadr err)))))))

(ert-deftest utter-transient-test-speak-outputs ()
  (utter-transient-test-with-text "Some text."
    (goto-char (point-max))
    (utter--suffix-speak '("S"))
    (should (equal (utter-transient-test--last-call)
                   (list 'utter-interrupt "Some text."
                         :source-buffer (current-buffer)
                         :source-name (buffer-name))))
    (utter--suffix-speak '("c"))
    (should (equal (utter-transient-test--last-call)
                   (list 'utter-enqueue "Some text." :cache-only t
                         :source-buffer (current-buffer)
                         :source-name (buffer-name))))
    (let (default)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (_prompt _dir def &rest _)
                   (setq default def)
                   "/tmp/out.mp3")))
        (utter--suffix-speak '("f"))
        (should (equal (utter-transient-test--last-call)
                       '(utter-save-to-file "Some text." "/tmp/out.mp3")))
        ;; The source name and the current format make the default.
        (should (equal default "dispatch-source.mp3"))
        (let ((utter-format 'wav))
          (utter--suffix-speak '("f"))
          (should (equal default "dispatch-source.wav")))))))

(ert-deftest utter-transient-test-save-checks-fit-before-asking ()
  "Text that needs several requests fails before the file prompt."
  (utter-transient-test-with-text (make-string 30 ?a)
    (goto-char (point-max))
    (setf (utter-backend-max-chars utter-backend) 10)
    (let (asked)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) (setq asked t) "/tmp/out.mp3")))
        (let ((err (should-error (utter--suffix-speak '("f"))
                                 :type 'user-error)))
          (should (string-match-p "requests" (cadr err))))
        (should-not asked)
        (should-not utter-ui-test--calls)))))

(ert-deftest utter-transient-test-kill-ring-prefix-picks-older-kill ()
  (utter-transient-test-with-text "Text."
    (let ((kill-ring '("newest" "older")) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil)
          (current-prefix-arg '(4)))
      (cl-letf (((symbol-function 'read-from-kill-ring)
                 (lambda (&rest _) "older")))
        (utter--suffix-speak '("y"))
        (should (equal (nth 1 (utter-transient-test--last-call)) "older"))))
    (let ((kill-ring '("newest")) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil)
          (current-prefix-arg nil))
      (utter--suffix-speak '("y"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "newest")))))

(ert-deftest utter-transient-test-inspect-shows-what-ret-sends ()
  "I resolves the text like RET and hands it to the engine's inspect path."
  (utter-transient-test-with-text "Some text."
    (goto-char (point-max))
    (let (inspected)
      (cl-letf (((symbol-function 'utter--inspect-text)
                 (lambda (text) (setq inspected (list text (current-buffer)))))
                ((symbol-function 'utter-request)
                 (lambda (&rest _) (error "Inspect must not call utter-request"))))
        (utter--suffix-inspect nil)
        (should (equal inspected (list "Some text." (current-buffer))))
        (let ((kill-ring '("killed")) (interprogram-paste-function nil))
          (utter--suffix-inspect '("y"))
          (should (equal (car inspected) "killed")))))))

(ert-deftest utter-transient-test-speak-every-combination ()
  "Each input switch works with each output switch."
  (utter-transient-test-with-text "Alpha beta."
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "typed"))
              ((symbol-function 'read--expression) (lambda (&rest _) "lisp"))
              ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/x"))
              (kill-ring '("kill")))
      (dolist (input '(nil "y" "m"))
        (dolist (output '(nil "S" "f" "c"))
          (setq utter-ui-test--calls nil)
          (goto-char (point-min))
          (utter--suffix-speak (delq nil (list input output)))
          (should (eq (car (utter-transient-test--last-call))
                      (pcase output
                        ("S" 'utter-interrupt)
                        ("f" 'utter-save-to-file)
                        (_ 'utter-enqueue))))
          (should (stringp (nth 1 (utter-transient-test--last-call)))))))))

(ert-deftest utter-transient-test-speak-empty ()
  (utter-transient-test-with-text "   "
    (should-error (utter--suffix-speak nil) :type 'user-error)
    (should-not utter-ui-test--calls)))

;;;; Infix classes

(ert-deftest utter-transient-test-lisp-variable ()
  (with-temp-buffer
    (utter-ui-test-with-engine
      (let ((obj (utter-lisp-variable :variable 'utter-instructions
                                      :set-value #'utter--set-with-scope
                                      :display-nil "(none)"
                                      :display-map '((x . "Ex"))))
            (utter--set-scope t)
            (utter-instructions nil))
        (should (equal (substring-no-properties (transient-format-value obj))
                       "(none)"))
        (transient-infix-set obj 'x)
        (should (equal (car utter-ui-test--calls)
                       '(utter--set-with-scope utter-instructions x t)))
        (should (local-variable-p 'utter-instructions))
        (should (equal (substring-no-properties (transient-format-value obj))
                       "Ex"))))))

(ert-deftest utter-transient-test-scope-cycles ()
  (let ((obj (utter--scope-variable :variable 'utter--set-scope))
        (transient--prefix (transient-prefix :command 'utter-menu))
        (utter--set-scope nil)
        (inhibit-message t))
    (should (eq (transient-infix-read obj) t))
    (transient-infix-set obj t)
    (should (eq utter--set-scope t))
    (should (eql (transient-infix-read obj) 1))
    (transient-infix-set obj 1)
    (should (null (transient-infix-read obj)))))

(ert-deftest utter-transient-test-scope-shows-all-three ()
  "The scope renders every choice, the active one highlighted."
  (let ((obj (utter--scope-variable :variable 'utter--set-scope)))
    (pcase-dolist (`(,value . ,active) '((nil . "global") (t . "buffer")
                                         (1 . "oneshot")))
      (oset obj value value)
      (let ((shown (transient-format-value obj)))
        (should (equal (substring-no-properties shown)
                       "(global|buffer|oneshot)"))
        (dolist (name '("global" "buffer" "oneshot"))
          (should (eq (get-text-property (string-search name shown) 'face shown)
                      (if (equal name active) 'transient-value
                        'transient-inactive-value))))))))

(ert-deftest utter-transient-test-toggle ()
  (let ((obj (utter--toggle-variable :variable 'utter-highlight))
        (transient--prefix (transient-prefix :command 'utter-menu)))
    (should (equal (substring-no-properties (transient-format-value obj))
                   "(off)"))
    (should (eq (transient-infix-read obj) t))
    (oset obj value t)
    (should (equal (substring-no-properties (transient-format-value obj))
                   "(on)"))))

(ert-deftest utter-transient-test-read-number ()
  (cl-letf (((symbol-function 'read-number) (lambda (&rest _) -1)))
    (should (null (utter--transient-read-number "Speed: " nil nil))))
  (cl-letf (((symbol-function 'read-number) (lambda (&rest _) 1.2)))
    (should (= (utter--transient-read-number "Speed: " nil nil) 1.2))))

(ert-deftest utter-transient-test-read-provider ()
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "OpenAI" utter--known-backends)))
         (utter-model nil)
         collection annotate group)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (mapcar #'car coll)
                       annotate (plist-get completion-extra-properties
                                           :annotation-function)
                       group (plist-get completion-extra-properties
                                        :group-function))
                 "ElevenLabs:eleven_v3")))
      (let ((value (utter-transient--read-provider "Backend:model: ")))
        (should (equal collection
                       '("OpenAI:gpt-4o-mini-tts" "OpenAI:tts-1"
                         "ElevenLabs:eleven_v3" "xAI" "say")))
        (should (eq (car value) (cdr (assoc "ElevenLabs" utter--known-backends))))
        (should (eq (cadr value) 'eleven_v3))
        ;; Grouped by backend, as gptel groups its models.
        (should (equal (funcall group "OpenAI:tts-1" nil) "OpenAI"))
        (should (equal (funcall group "say" nil) "say"))
        (should (equal (funcall group "OpenAI:tts-1" t) "OpenAI:tts-1"))
        (let ((ann (funcall annotate "OpenAI:gpt-4o-mini-tts")))
          (should (string-search "steerable" ann))
          (should (string-search "instructions" ann))
          (should (string-search "4096ch" ann))
          (should (string-search "12" ann)))
        ;; tts-1 declares no capabilities, which core honours.
        (should-not (string-search "instructions"
                                   (funcall annotate "OpenAI:tts-1")))
        ;; Nothing known: no padding either.
        (should (null (funcall annotate "say")))))))

(ert-deftest utter-transient-test-provider-set-sanitizes ()
  (with-temp-buffer
    (utter-ui-test-with-engine
      (let* ((utter--known-backends (utter-transient-test--backends))
             (openai (cdr (assoc "OpenAI" utter--known-backends)))
             (say (cdr (assoc "say" utter--known-backends)))
             (xai (cdr (assoc "xAI" utter--known-backends)))
             (utter-backend openai)
             (utter-model 'gpt-4o-mini-tts)
             (utter-voice "nova")
             (utter--set-scope nil)
             (obj (utter-provider-variable :variable 'utter-model
                                           :backend 'utter-backend
                                           :set-value #'utter--set-with-scope)))
        (transient-infix-set obj (list openai 'tts-1))
        (should (eq utter-model 'tts-1))
        (should (equal utter-voice "nova"))
        (should (equal (substring-no-properties (transient-format-value obj))
                       "OpenAI:tts-1"))
        (transient-infix-set obj (list say nil))
        (should (eq utter-backend say))
        (should (null utter-model))
        (should (null utter-voice))
        (should (equal (substring-no-properties (transient-format-value obj))
                       "say"))
        ;; A fetched list cannot be checked yet: no crash, voice kept.
        (setq utter-voice "Samantha")
        (transient-infix-set obj (list xai nil))
        (should (eq utter-backend xai))
        (should (equal utter-voice "Samantha"))))))

(ert-deftest utter-transient-test-menu-open-sanitizes ()
  "Opening the menu drops a model or voice the backend does not have."
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu
        (:setup (setq utter-model 'eleven_v3 utter-voice "Rachel"))
      (should (null utter-model))
      (should (null utter-voice))
      (should (utter-transient-test--menu-line "-m Backend:model OpenAI:gpt-4o-mini-tts"))
      (should-not (string-search "Rachel" (utter-transient-test--menu-text)))
      (should-not (string-search "eleven_v3" (utter-transient-test--menu-text))))))

(ert-deftest utter-transient-test-read-voice-static ()
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "OpenAI" utter--known-backends)))
         (utter-voice nil)
         collection)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (all-completions "" coll))
                 "nova")))
      (should (equal (utter-transient--read-voice "Voice: " nil nil) "nova"))
      (should (equal collection '("alloy" "nova"))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should (null (utter-transient--read-voice "Voice: " nil nil))))))

(ert-deftest utter-transient-test-read-voice-model-voices ()
  "Model-level voices win over the backend's."
  (let* ((backend (utter--make-backend
                   :name "OR" :voices '("alloy")
                   :models '((flux :voices ("flux-a-en" "flux-b-en")))))
         (utter-backend backend) (utter-model 'flux) (utter-voice nil)
         collection)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (all-completions "" coll))
                 "")))
      (utter-transient--read-voice "Voice: " nil nil)
      (should (equal collection '("flux-a-en" "flux-b-en"))))))

(ert-deftest utter-transient-test-read-voice-ret-keeps-current ()
  "The prompt shows the current voice, and RET keeps it."
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "OpenAI" utter--known-backends)))
         (utter-voice "nova")
         prompt default collection)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (p coll _pred _match _init _hist def &rest _)
                 (setq prompt p default def
                       collection (all-completions "" coll))
                 def)))
      (should (equal (utter-transient--read-voice "Voice: " nil nil) "nova"))
      (should (string-search "(nova)" prompt))
      (should (equal default "nova"))
      ;; The backend default stays reachable.
      (should (member utter-transient--default-voice collection)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) utter-transient--default-voice)))
      (should (null (utter-transient--read-voice "Voice: " nil nil))))))

(ert-deftest utter-transient-test-read-voice-fetch-backend ()
  "A backend whose voices are fetched opens the reader without error."
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "xAI" utter--known-backends)))
         (utter-voice nil)
         (inhibit-message t)
         pending collection)
    (cl-letf (((symbol-function 'utter--cached-voices) (lambda (_) nil))
              ((symbol-function 'utter--list-voices)
               (lambda (_backend callback) (setq pending callback)))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (all-completions "" coll))
                 "Eve")))
      (should (equal (utter-transient--read-voice "Voice: " nil nil) "Eve"))
      (should (functionp pending))
      (should (null collection)))
    ;; Once cached, the list comes from `utter--static-voices'.
    (cl-letf (((symbol-function 'utter--cached-voices)
               (lambda (_) '("Ara" "Eve")))
              ((symbol-function 'utter--list-voices)
               (lambda (&rest _) (error "No fetch on a cache hit")))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (all-completions "" coll))
                 "Ara")))
      (should (equal (utter-transient--read-voice "Voice: " nil nil) "Ara"))
      (should (equal collection '("Ara" "Eve"))))))

(ert-deftest utter-transient-test-read-voice-cache-hit ()
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "ElevenLabs" utter--known-backends)))
         collection)
    (cl-letf (((symbol-function 'utter--list-voices)
               (lambda (_backend callback)
                 (funcall callback '(("Rachel" . "calm") "Adam"))))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (all-completions "" coll))
                 "Rachel")))
      (should (equal (utter-transient--read-voice "Voice: " nil nil) "Rachel"))
      (should (equal collection '("Rachel" "Adam"))))))

(ert-deftest utter-transient-test-read-voice-cache-miss ()
  "A cache miss starts the fetch, allows free input, refreshes on arrival."
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "ElevenLabs" utter--known-backends)))
         (inhibit-message t)
         pending require-match (refreshed 0))
    (cl-letf (((symbol-function 'utter--list-voices)
               (lambda (_backend callback) (setq pending callback)))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll _pred match &rest _)
                 (should (null (all-completions "" coll)))
                 (setq require-match match)
                 "MyClone"))
              ((symbol-function 'transient--refresh-transient)
               (lambda () (cl-incf refreshed))))
      (should (equal (utter-transient--read-voice "Voice: " nil nil) "MyClone"))
      (should (functionp pending))
      (should-not require-match)
      ;; The list lands while the menu is open.
      (let ((transient--prefix (transient-prefix :command 'utter-menu)))
        (funcall pending '("Rachel")))
      (should (= refreshed 1))
      ;; ... and after it closed: no refresh.
      (funcall pending '("Rachel"))
      (should (= refreshed 1)))))

(ert-deftest utter-transient-test-read-format ()
  "Formats come from the model when it declares them; typos are refused."
  (let* ((utter--known-backends (utter-transient-test--backends))
         (utter-backend (cdr (assoc "OpenAI" utter--known-backends)))
         (utter-model 'tts-1)
         collection require-match)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll _pred match &rest _)
                 (setq collection (all-completions "" coll)
                       require-match match)
                 "opus")))
      (should (eq (utter-transient--read-format "Format: " nil nil) 'opus))
      (should (equal collection '("mp3" "opus")))
      (should (eq require-match t)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should (null (utter-transient--read-format "Format: " nil nil))))))

(ert-deftest utter-transient-test-language-auto-is-inactive ()
  (let ((obj (utter-lisp-variable :variable 'utter-language
                                  :display-nil "auto" :default 'auto)))
    (oset obj value 'auto)
    (let ((shown (transient-format-value obj)))
      (should (equal (substring-no-properties shown) "auto"))
      (should (eq (get-text-property 0 'face shown) 'transient-inactive-value)))
    (oset obj value 'zh)
    (should (eq (get-text-property 0 'face (transient-format-value obj))
                'transient-value)))
  (should (eq (oref (get 'utter--infix-language 'transient--suffix) default)
              'auto)))

(ert-deftest utter-transient-test-instructions ()
  (let ((utter-ui-test--state '(:status idle))
        (long "Speak slowly and warmly,\nlike a late-night radio host reading poetry."))
    ;; OpenAI:gpt-4o-mini-tts takes instructions.
    (let ((utter-instructions long))
      (utter-transient-test-with-menu ()
        (let ((obj (cdr (assoc "-i" (utter-transient-test--suffixes))))
              (line (utter-transient-test--menu-line "-i Instructions")))
          (should-not (oref obj inapt))
          (should (string-search "Speak slowly and warmly, like a la…" line))
          (should-not (string-search "radio host" line)))))
    ;; say does not: the infix stays visible but inapt.
    (utter-transient-test-with-menu
        (:setup (setq utter-backend (cdr (assoc "say" utter--known-backends))))
      (should (oref (cdr (assoc "-i" (utter-transient-test--suffixes))) inapt)))
    ;; Nor does tts-1, whose own list replaces the backend's.
    (utter-transient-test-with-menu (:setup (setq utter-model 'tts-1))
      (should (oref (cdr (assoc "-i" (utter-transient-test--suffixes))) inapt)))))

(ert-deftest utter-transient-test-preset ()
  (with-temp-buffer
    (utter-ui-test-with-engine
      (let ((utter--known-presets '((narrator :description "Warm narrator"
                                              :voice "nova")
                                    (zh :language zh)))
            (utter--set-scope t)
            (utter--preset nil)
            (utter-voice nil)
            (inhibit-message t)
            collection annotate)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt coll &rest _)
                     (setq collection (all-completions "" coll)
                           annotate (plist-get completion-extra-properties
                                               :annotation-function))
                     "narrator")))
          (let ((obj (utter-preset-variable
                      :variable 'utter--preset
                      :set-value #'utter--set-with-scope)))
            (should (eq (utter-transient--read-preset "Preset: " nil nil)
                        'narrator))
            (should (equal collection '("narrator" "zh")))
            (should (string-search "Warm narrator" (funcall annotate "narrator")))
            (should (null (funcall annotate "zh")))
            (transient-infix-set obj 'narrator)
            (should (member '(utter--set-with-scope utter-voice "nova" t)
                            utter-ui-test--calls))
            (should (eq utter--preset 'narrator))
            (let ((shown (transient-format-value obj)))
              (should (equal (substring-no-properties shown) "narrator"))
              (should-not (plist-get (get-text-property 0 'face shown)
                                     :strike-through)))
            ;; A setting changed since: the name is struck through.
            (setq utter-voice "alloy")
            (should (plist-get (get-text-property 0 'face
                                                  (transient-format-value obj))
                               :strike-through))))))))

(ert-deftest utter-transient-test-preset-follows-engine ()
  "A preset applied from Lisp shows in the menu."
  (should-not (boundp 'utter-transient--preset))
  (should (eq (oref (get 'utter--infix-preset 'transient--suffix) variable)
              'utter--preset))
  (let ((utter-ui-test--state '(:status idle)))
    (let ((utter--known-presets '((narrator :voice "nova")))
          (utter--preset 'narrator))
      (utter-transient-test-with-menu (:setup (setq utter-voice "nova"))
        (should (utter-transient-test--menu-line "@ Preset narrator"))
        (should-not (oref (cdr (assoc "@" (utter-transient-test--suffixes)))
                          inapt))))
    (let ((utter--known-presets nil) (utter--preset nil))
      (utter-transient-test-with-menu ()
        (should (oref (cdr (assoc "@" (utter-transient-test--suffixes)))
                      inapt))))))

(ert-deftest utter-transient-test-evil-visual-fix ()
  (defvar evil-visual-region-expanded)
  (let ((order nil)
        (evil-visual-region-expanded nil))
    (cl-letf (((symbol-function 'evil-visual-expand-region)
               (lambda () (push 'expand order)
                 (setq evil-visual-region-expanded t)))
              ((symbol-function 'evil-visual-contract-region)
               (lambda () (push 'contract order))))
      (utter--transient-fix-evil-visual (lambda () (push 'menu order)))
      (should (equal (nreverse order) '(expand menu contract)))))
  (let (called)
    (utter--transient-fix-evil-visual (lambda () (setq called t)))
    (should called)))

(provide 'utter-transient-tests)
;;; utter-transient-tests.el ends here
