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

(defun utter-transient-test--backends ()
  "Return a fake `utter--known-backends' alist."
  (list (cons "OpenAI"
              (utter--make-backend
               :name "OpenAI" :max-chars 4096 :capabilities '(instructions)
               :models '((gpt-4o-mini-tts :description "steerable"
                                          :capabilities (instructions)
                                          :cost 12)
                         tts-1)
               :voices '("alloy" "nova") :formats '(mp3 wav)))
        (cons "ElevenLabs"
              (utter--make-backend :name "ElevenLabs"
                                   :models '(eleven_v3) :voices nil))
        (cons "say"
              (utter--make-backend :name "say" :voices '("Samantha")
                                   :formats '(aiff)))))

(defmacro utter-transient-test-with-menu (&rest body)
  "Open `utter-menu' in a temp buffer, run BODY, then close the menu."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (utter-ui-test-with-engine
       (cl-letf ,(mapcar (lambda (cmd)
                           `((symbol-function ',cmd)
                             (lambda (&rest _) (interactive))))
                         '(utter-toggle-pause utter-next utter-previous
                           utter-rate-up utter-rate-down utter-clear
                           utter-stop))
       (let ((utter--known-backends (utter-transient-test--backends)))
         (setq utter-backend (cdar utter--known-backends))
         (unwind-protect
             (progn (utter-menu) ,@body)
           (transient--emergency-exit)
           (setq utter-backend nil)))))))

(defun utter-transient-test--suffixes ()
  "Return an alist (KEY . OBJECT) of the shown suffixes and infixes."
  (mapcar (lambda (obj) (cons (oref obj key) obj)) transient--suffixes))

(defun utter-transient-test--menu-text ()
  "Return the text of the transient menu buffer."
  (with-current-buffer transient--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

;;;; Layout

(ert-deftest utter-transient-test-layout-idle ()
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu
      (let ((keys (mapcar #'car (utter-transient-test--suffixes))))
        (dolist (key '("-m" "-v" "-s" "-f" "-l" "-i" "-H" "=" "@"
                       "r" "b" "o" "e" "y" "m" "t" "s" "S" "f" "c" "RET"))
          (should (member key keys)))
        (dolist (key '("SPC" "n" "p" "+" "_" "x" "q" "Q"))
          (should-not (member key keys))))
      (should (eq (oref (cdr (assoc "RET" (utter-transient-test--suffixes)))
                        command)
                  'utter--suffix-speak))
      (should (oref transient--prefix refresh-suffixes))
      (should (equal (oref transient--prefix incompatible)
                     '(("r" "b" "o" "e" "y" "m" "t") ("s" "S" "f" "c"))))
      (let ((text (utter-transient-test--menu-text)))
        (should (string-prefix-p "Idle" text))
        (dolist (label '("Backend" "Input <" "Output >" "Backend:model"
                         "OpenAI:gpt-4o-mini-tts" "Highlight spoken text"
                         "Region (default)" "Buffer from point"
                         "Org subtree" "EWW / Info page" "Kill-ring"
                         "Minibuffer" "String from Lisp"
                         "Speakers, append (default)" "Speakers, interrupt"
                         "Save to file" "Cache only" "Speak"))
          (should (string-search label text)))
        (should-not (string-search "Playback" text))
        (should-not (string-search "Inspect" text))))))

(ert-deftest utter-transient-test-layout-playing ()
  (let ((utter-ui-test--state utter-ui-test--playing-state))
    (utter-transient-test-with-menu
      (let ((suffixes (utter-transient-test--suffixes)))
        (pcase-dolist (`(,key . ,command)
                       '(("SPC" . utter-toggle-pause) ("n" . utter-next)
                         ("p" . utter-previous) ("+" . utter-rate-up)
                         ("_" . utter-rate-down) ("x" . utter-clear)
                         ("q" . utter-stop) ("Q" . utter-queue)))
          (let ((obj (cdr (assoc key suffixes))))
            (should obj)
            (should (eq (oref obj command) command))
            (should (eq (oref obj transient) t)))))
      (let ((text (utter-transient-test--menu-text)))
        (should (string-prefix-p
                 (concat "Playing reading-aloud.org (2/5) · "
                         "OpenAI:gpt-4o-mini-tts/nova · 1.0x")
                 text))
        (should (string-search "Playback" text))
        (should (string-search "Next utterance" text))
        (should (string-search "appends as utterance 6" text))))))

(ert-deftest utter-transient-test-inspect-needs-expert ()
  (let ((utter-ui-test--state '(:status idle))
        (utter-expert-commands t))
    (utter-transient-test-with-menu
      (should (eq (oref (cdr (assoc "I" (utter-transient-test--suffixes)))
                        command)
                  'utter--suffix-inspect))
      (should (string-search "I Inspect" (utter-transient-test--menu-text))))))

(ert-deftest utter-transient-test-refresh-hook-follows-menu ()
  (let ((utter-ui-test--state '(:status idle))
        (utter-progress-functions nil)
        (refreshed 0))
    (utter-transient-test-with-menu
      (should (memq #'utter-transient--refresh-menu utter-progress-functions))
      (cl-letf (((symbol-function 'transient--refresh-transient)
                 (lambda () (cl-incf refreshed))))
        (utter-transient--refresh-menu 'item 0 10)
        (should (= refreshed 1))))
    (should-not (memq #'utter-transient--refresh-menu utter-progress-functions))
    ;; Closed menu: the guard keeps the refresh away.
    (cl-letf (((symbol-function 'transient--refresh-transient)
               (lambda () (cl-incf refreshed))))
      (utter-transient--refresh-menu 'item 0 10)
      (should (= refreshed 1)))))

;; The real private function, on whichever transient is loaded.
(ert-deftest utter-transient-test-refresh-redraws-open-menu ()
  (let ((utter-ui-test--state '(:status idle)))
    (utter-transient-test-with-menu
      (should-not (string-search "Playback" (utter-transient-test--menu-text)))
      (setq utter-ui-test--state utter-ui-test--playing-state)
      (with-temp-buffer                 ; an unrelated current buffer
        (run-hook-with-args 'utter-progress-functions 'item 0 10))
      (let ((text (utter-transient-test--menu-text)))
        (should (string-prefix-p "Playing reading-aloud.org" text))
        (should (string-search "Playback" text))
        (should (assoc "SPC" (utter-transient-test--suffixes)))))))

(ert-deftest utter-transient-test-evil-environment-attached ()
  (if (slot-exists-p 'transient-prefix 'environment)
      (should (eq (oref (get 'utter-menu 'transient--prefix) environment)
                  #'utter--transient-fix-evil-visual))
    (should-not (slot-exists-p 'transient-prefix 'environment))))

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
                         "OpenAI:gpt-4o-mini-tts/nova · 1.0x")))
  (should (equal (utter-transient-test--heading
                  '(:status paused :index 1 :total 1 :backend "say"
                    :voice "Samantha" :rate 1.2 :source "*eww*"))
                 "Paused *eww* (1/1) · say/Samantha · 1.2x"))
  (should (equal (utter-transient-test--heading
                  '(:status synthesizing :index 3 :total 5 :backend "OpenAI"
                    :model tts-1 :source "notes.org"))
                 "Synthesizing notes.org (3/5) · OpenAI:tts-1 · 1.0x")))

;;;; Dispatch

(defmacro utter-transient-test-with-text (text &rest body)
  "Run BODY in a buffer with TEXT, the fake engine and no selection."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (rename-buffer "dispatch-source" t)
     (insert ,text)
     (goto-char (point-min))
     (utter-ui-test-with-engine
       (cl-letf (((symbol-function 'utter--text-at-point) nil))
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
    (dolist (args '(nil ("r") ("s") ("r" "s")))
      (setq utter-ui-test--calls nil)
      (utter--suffix-speak args)
      (let ((call (utter-transient-test--last-call)))
        (should (eq (car call) 'utter-enqueue))
        (should (equal (nth 1 call) "two"))
        (should (eq (plist-get (nthcdr 2 call) :source-buffer)
                    (current-buffer)))
        (should (equal (plist-get (nthcdr 2 call) :source-name)
                       (buffer-name)))))))

(ert-deftest utter-transient-test-speak-default-sentence ()
  (utter-transient-test-with-text "One two. Three four."
    (setq-local sentence-end-double-space nil)
    (goto-char 12)
    (utter--suffix-speak nil)
    (should (equal (nth 1 (utter-transient-test--last-call)) "Three four."))))

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
    (goto-char (point-min))
    (search-forward "End")
    (utter--suffix-speak '("b"))
    (should (equal (nth 1 (utter-transient-test--last-call)) " part."))
    (utter--suffix-speak '("e"))
    (should (equal (nth 1 (utter-transient-test--last-call))
                   "Head.\nMiddle part. End part."))
    (let ((kill-ring '("killed text")) (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil))
      (utter--suffix-speak '("y"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "killed text"))
      (should (equal (plist-get (nthcdr 2 (utter-transient-test--last-call))
                                :source-name)
                     "kill-ring")))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "typed")))
      (utter--suffix-speak '("m"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "typed")))
    (cl-letf (((symbol-function 'read--expression)
               (lambda (&rest _) '(concat "from " "lisp"))))
      (utter--suffix-speak '("t"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "from lisp")))
    (cl-letf (((symbol-function 'read--expression) (lambda (&rest _) 42)))
      (utter--suffix-speak '("t"))
      (should (equal (nth 1 (utter-transient-test--last-call)) "42")))))

(ert-deftest utter-transient-test-speak-org-subtree ()
  (utter-transient-test-with-text "* A\nalpha\n** A1\nbeta\n* B\ngamma\n"
    (should-error (utter--suffix-speak '("o")) :type 'user-error)
    (org-mode)
    (goto-char (point-min))
    (search-forward "alpha")
    (utter--suffix-speak '("o"))
    (should (equal (nth 1 (utter-transient-test--last-call))
                   "* A\nalpha\n** A1\nbeta\n"))))

(ert-deftest utter-transient-test-speak-outputs ()
  (utter-transient-test-with-text "Some text."
    (utter--suffix-speak '("e" "S"))
    (should (equal (utter-transient-test--last-call)
                   (list 'utter-interrupt "Some text."
                         :source-buffer (current-buffer)
                         :source-name (buffer-name))))
    (utter--suffix-speak '("e" "c"))
    (should (equal (utter-transient-test--last-call)
                   (list 'utter-enqueue "Some text." :cache-only t
                         :source-buffer (current-buffer)
                         :source-name (buffer-name))))
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (&rest _) "/tmp/out.mp3")))
      (utter--suffix-speak '("e" "f"))
      (should (equal (utter-transient-test--last-call)
                     '(utter-save-to-file "Some text." "/tmp/out.mp3"))))))

(ert-deftest utter-transient-test-speak-every-combination ()
  "Each input switch works with each output switch."
  (utter-transient-test-with-text "Alpha beta."
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "typed"))
              ((symbol-function 'read--expression) (lambda (&rest _) "lisp"))
              ((symbol-function 'read-file-name) (lambda (&rest _) "/tmp/x"))
              (kill-ring '("kill")))
      (dolist (input '(nil "r" "b" "e" "y" "m" "t"))
        (dolist (output '(nil "s" "S" "f" "c"))
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
    (should-error (utter--suffix-speak '("e")) :type 'user-error)
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
    (should (equal (substring-no-properties (transient-format-value obj))
                   "buffer"))
    (should (eql (transient-infix-read obj) 1))
    (transient-infix-set obj 1)
    (should (equal (substring-no-properties (transient-format-value obj))
                   "oneshot"))
    (should (null (transient-infix-read obj)))))

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
         collection annotate)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (setq collection (mapcar #'car coll)
                       annotate (plist-get completion-extra-properties
                                           :annotation-function))
                 "ElevenLabs:eleven_v3")))
      (let ((value (utter-transient--read-provider "Backend:model: ")))
        (should (equal collection
                       '("OpenAI:gpt-4o-mini-tts" "OpenAI:tts-1"
                         "ElevenLabs:eleven_v3" "say")))
        (should (eq (car value) (cdr (assoc "ElevenLabs" utter--known-backends))))
        (should (eq (cadr value) 'eleven_v3))
        (let ((ann (funcall annotate "OpenAI:gpt-4o-mini-tts")))
          (should (string-search "steerable" ann))
          (should (string-search "instructions" ann))
          (should (string-search "4096" ann))
          (should (string-search "12" ann)))))))

(ert-deftest utter-transient-test-provider-set-resets-voice ()
  (with-temp-buffer
    (utter-ui-test-with-engine
      (let* ((utter--known-backends (utter-transient-test--backends))
             (openai (cdr (assoc "OpenAI" utter--known-backends)))
             (say (cdr (assoc "say" utter--known-backends)))
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
                       "say"))))))

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

(ert-deftest utter-transient-test-preset ()
  (with-temp-buffer
    (utter-ui-test-with-engine
      (let ((utter--known-presets '((narrator :voice "nova")
                                    (zh :language zh)))
            (utter--set-scope t)
            (inhibit-message t)
            applied collection)
        (cl-letf (((symbol-function 'utter-get-preset)
                   (lambda (name) (alist-get name utter--known-presets)))
                  ((symbol-function 'utter--apply-preset)
                   (lambda (preset &optional setter)
                     (setq applied preset)
                     (funcall setter 'utter-voice (plist-get preset :voice))))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt coll &rest _)
                     (setq collection (all-completions "" coll))
                     "narrator")))
          (let ((obj (utter-preset-variable
                      :variable 'utter-transient--preset
                      :set-value #'utter--set-with-scope)))
            (should (eq (utter-transient--read-preset "Preset: " nil nil)
                        'narrator))
            (should (equal collection '("narrator" "zh")))
            (transient-infix-set obj 'narrator)
            (should (equal applied '(:voice "nova")))
            (should (member '(utter--set-with-scope utter-voice "nova" t)
                            utter-ui-test--calls))
            (should (equal (substring-no-properties
                            (transient-format-value obj))
                           "narrator"))))))))

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
