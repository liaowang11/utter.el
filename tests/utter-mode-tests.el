;;; utter-mode-tests.el --- Tests for utter-mode and the queue buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for `utter-mode' (header line, keymap) and `utter-queue-mode'.
;; The engine is faked: plain functions are stubbed with `cl-letf' inside
;; `utter-ui-test-with-engine', and the item and backend structs are
;; defined here only when the real ones are not loaded, with the slots
;; from DESIGN.md, so the tests use the real constructors once ENGINE and
;; CORE land.  This file also provides the fake engine to
;; `utter-transient-tests'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'utter-mode)

;;;; Fake engine

(unless (fboundp 'make-utter-item)
  (cl-defstruct utter-item
    id text status params source-buffer source-name markers tick created
    segments (position 0)))

(unless (fboundp 'utter--make-backend)
  (cl-defstruct (utter-backend (:constructor utter--make-backend)
                               (:copier utter--copy-backend))
    name host protocol endpoint url header key
    models voices formats max-chars
    (max-chars-unit 'chars) (response-kind 'bytes) response-path
    capabilities request-params curl-args body-transform
    (coding-system 'binary)))

;; No-ops once the real defcustoms and defvars exist.
(defvar utter-backend nil)
(defvar utter-model nil)
(defvar utter-voice nil)
(defvar utter-speed 1.0)
(defvar utter-format nil)
(defvar utter-language 'auto)
(defvar utter-instructions nil)
(defvar utter-highlight nil)
(defvar utter-playback-rate 1.0)
(defvar utter-expert-commands nil)
(defvar utter--set-scope nil)
(defvar utter--known-backends nil)
(defvar utter--known-presets nil)
(defvar utter-progress-functions nil)
(defvar utter-item-finished-functions nil)
(defvar utter-queue-finished-hook nil)
(defvar utter-enqueue-hook nil)

(defvar utter-ui-test--state '(:status idle)
  "Value returned by the fake `utter-state'.")

(defvar utter-ui-test--items nil
  "Items returned by the fake `utter--queue-items'.")

(defvar utter-ui-test--calls nil
  "Calls recorded by the fake engine, newest first.")

(defun utter-ui-test--recorder (name)
  "Return a function that records its arguments under NAME."
  (lambda (&rest args)
    (push (cons name args) utter-ui-test--calls)
    name))

(defmacro utter-ui-test-with-engine (&rest body)
  "Run BODY with the engine's plain functions replaced by fakes.
Recorded calls end up in `utter-ui-test--calls'."
  (declare (indent 0) (debug t))
  `(let ((utter-ui-test--calls nil))
     (cl-letf (((symbol-function 'utter-state)
                (lambda () utter-ui-test--state))
               ((symbol-function 'utter-active-p)
                (lambda ()
                  (not (memq (plist-get utter-ui-test--state :status)
                             '(nil idle)))))
               ((symbol-function 'utter--queue-items)
                (lambda () utter-ui-test--items))
               ((symbol-function 'utter-enqueue)
                (utter-ui-test--recorder 'utter-enqueue))
               ((symbol-function 'utter-interrupt)
                (utter-ui-test--recorder 'utter-interrupt))
               ((symbol-function 'utter-save-to-file)
                (utter-ui-test--recorder 'utter-save-to-file))
               ((symbol-function 'utter-toggle-pause)
                (utter-ui-test--recorder 'utter-toggle-pause))
               ((symbol-function 'utter-replay-item)
                (utter-ui-test--recorder 'utter-replay-item))
               ((symbol-function 'utter--queue-remove)
                (utter-ui-test--recorder 'utter--queue-remove))
               ((symbol-function 'utter--item-duration)
                (lambda (item) (and (eq (utter-item-status item) 'done) 22)))
               ((symbol-function 'utter--set-with-scope)
                (lambda (sym value &optional scope)
                  (push (list 'utter--set-with-scope sym value scope)
                        utter-ui-test--calls)
                  (if (eq scope t)
                      (set (make-local-variable sym) value)
                    (set sym value)))))
       ,@body)))

(defconst utter-ui-test--playing-state
  '(:status playing :index 2 :total 5 :elapsed 31 :duration 72
    :backend "OpenAI" :model gpt-4o-mini-tts :voice "nova" :rate 1.0
    :source "reading-aloud.org")
  "A playing state as `utter-state' returns it.")

(defun utter-ui-test--own-files ()
  "Return the UI source and test files."
  (delq nil
        (mapcar (lambda (lib)
                  (when-let* ((f (locate-library lib)))
                    (if (string-suffix-p ".elc" f) (substring f 0 -1) f)))
                '("utter-mode" "utter-transient" "utter-mode-tests"
                  "utter-transient-tests"))))

;;;; Formatting helpers

(ert-deftest utter-mode-test-format-time ()
  (should (equal (utter-mode--format-time 0) "0:00"))
  (should (equal (utter-mode--format-time 31) "0:31"))
  (should (equal (utter-mode--format-time 72.4) "1:12"))
  (should (equal (utter-mode--format-time 3725) "1:02:05"))
  (should (null (utter-mode--format-time nil))))

(ert-deftest utter-mode-test-format-rate ()
  (should (equal (utter-mode--format-rate 1.0) "1.0x"))
  (should (equal (utter-mode--format-rate 1.2) "1.2x"))
  (should (equal (utter-mode--format-rate 1.15) "1.15x"))
  (should (equal (utter-mode--format-rate 1) "1.0x"))
  (should (equal (utter-mode--format-rate nil) "1.0x")))

;;;; Header line

(defun utter-ui-test--header (state read-only)
  "Return the header line text for STATE in a buffer with READ-ONLY."
  (let ((utter-ui-test--state state))
    (with-temp-buffer
      (setq buffer-read-only read-only)
      (utter-ui-test-with-engine
        (utter--header-line)))))

(ert-deftest utter-mode-test-header-line-playing ()
  (should (equal (substring-no-properties
                  (utter-ui-test--header utter-ui-test--playing-state t))
                 (concat "▶ utter · reading-aloud.org 2/5 · 0:31/1:12 · "
                         "OpenAI nova · 1.0x · "
                         "SPC pause  n/p utterance  +/- rate  q stop"))))

(ert-deftest utter-mode-test-header-line-paused ()
  (should (equal (substring-no-properties
                  (utter-ui-test--header
                   '(:status paused :index 1 :total 1 :elapsed 125
                     :duration 400 :backend "Kokoro" :voice "af_heart"
                     :rate 1.2 :source "*eww*")
                   t))
                 (concat "⏸ utter · *eww* 1/1 · 2:05/6:40 · Kokoro af_heart"
                         " · 1.2x · "
                         "SPC resume  n/p utterance  +/- rate  q stop"))))

(ert-deftest utter-mode-test-header-line-synthesizing ()
  "No elapsed time yet, no voice, unknown duration."
  (should (equal (substring-no-properties
                  (utter-ui-test--header
                   '(:status synthesizing :index 3 :total 5
                     :backend "say" :rate 1.0 :source "notes.org")
                   t))
                 (concat "⟳ utter · notes.org 3/5 · say · 1.0x · "
                         "SPC pause  n/p utterance  +/- rate  q stop")))
  (should (string-match-p
           "· 0:04/-- ·"
           (utter-ui-test--header
            '(:status playing :index 1 :total 1 :elapsed 4 :backend "say"
              :source "x")
            t))))

(ert-deftest utter-mode-test-header-line-idle ()
  (should (equal (substring-no-properties
                  (utter-ui-test--header '(:status idle) t))
                 "utter · idle")))

(ert-deftest utter-mode-test-header-line-writable-prefix ()
  "In a writable buffer the hints show the \\`C-c C-o' prefix."
  (should (string-suffix-p
           " · C-c C-o: SPC pause  n/p utterance  +/- rate  q stop"
           (substring-no-properties
            (utter-ui-test--header utter-ui-test--playing-state nil)))))

(ert-deftest utter-mode-test-header-line-buttons ()
  (let* ((str (utter-ui-test--header utter-ui-test--playing-state t))
         (pos (string-search "SPC pause" str)))
    (should pos)
    (should (get-text-property pos 'button str))
    (utter-ui-test-with-engine
      (funcall (get-text-property pos 'action str)
               (get-text-property pos 'button-data str))
      (should (assq 'utter-toggle-pause utter-ui-test--calls)))))

;;;; The minor mode

(ert-deftest utter-mode-test-header-line-format-restored ()
  (with-temp-buffer
    (setq header-line-format "old")
    (utter-mode 1)
    (should (equal header-line-format '(:eval (utter--header-line))))
    (utter-mode 1)                      ; enabling twice keeps the old value
    (utter-mode -1)
    (should (equal header-line-format "old"))
    (should-not utter-mode)))

(ert-deftest utter-mode-test-no-lighter ()
  (should-not (cadr (assq 'utter-mode minor-mode-alist))))

(ert-deftest utter-mode-test-hooks-follow-mode ()
  (let ((utter-progress-functions nil)
        (utter-item-finished-functions nil))
    (with-temp-buffer
      (utter-mode 1)
      (should (memq #'utter-mode--refresh utter-progress-functions))
      (should (memq #'utter-mode--refresh utter-item-finished-functions))
      (utter-mode -1)
      (should-not (memq #'utter-mode--refresh utter-progress-functions)))))

(defun utter-ui-test--binding (key read-only)
  "Return the command KEY runs under `utter-mode' with READ-ONLY."
  (with-temp-buffer
    (utter-mode 1)
    (setq buffer-read-only read-only)
    (key-binding (kbd key))))

(ert-deftest utter-mode-test-keymap-read-only ()
  (dolist (pair '(("SPC" . utter-toggle-pause) ("n" . utter-next)
                  ("p" . utter-previous) ("+" . utter-rate-up)
                  ("-" . utter-rate-down) ("q" . utter-stop)
                  ("x" . utter-clear) ("m" . utter-menu)
                  ("Q" . utter-queue) ("RET" . utter-visit-source)))
    (should (eq (utter-ui-test--binding (car pair) t) (cdr pair)))
    (should (eq (utter-ui-test--binding (concat "C-c C-o " (car pair)) nil)
                (cdr pair)))))

(ert-deftest utter-mode-test-keymap-writable-has-no-single-keys ()
  (dolist (key '("SPC" "n" "p" "+" "-" "q" "x" "m" "Q"))
    (should-not (memq (utter-ui-test--binding key nil)
                      '(utter-toggle-pause utter-next utter-previous
                        utter-rate-up utter-rate-down utter-stop utter-clear
                        utter-menu utter-queue)))))

(ert-deftest utter-mode-test-no-global-bindings ()
  (dolist (cmd '(utter-queue utter-visit-source utter-mode))
    (should-not (where-is-internal cmd global-map))))

(ert-deftest utter-mode-test-visit-source-outside-queue ()
  (with-temp-buffer
    (let ((inhibit-message t))
      (should (stringp (utter-visit-source))))))

;;;; Queue buffer

(defun utter-ui-test--sample-items (source)
  "Return five fake items; SOURCE is the live source buffer."
  (let ((openai (utter--make-backend :name "OpenAI"))
        (kokoro (utter--make-backend :name "Kokoro")))
    (list
     (make-utter-item :id 1 :status 'done
                      :text "Listening is also cheaper than it looks. A two-minute paragraph."
                      :params (list :backend openai :voice "nova")
                      :source-buffer source :source-name "reading-aloud.org")
     (make-utter-item :id 2 :status 'playing
                      :text "Hearing the gaps.\nReading a draft aloud catches errors."
                      :params (list :backend openai :voice "nova")
                      :source-buffer source :source-name "reading-aloud.org")
     (make-utter-item :id 3 :status 'pending :text "Run nix flake update first."
                      :params (list :backend kokoro :voice "af_heart")
                      :source-name "*agent-shell: flake*")
     (make-utter-item :id 4 :status 'error :text "Broken."
                      :params (list :backend "say") :source-name "a")
     (make-utter-item :id 5 :status 'interrupted :text "Stopped."
                      :params (list :backend "say" :voice "Tingting")
                      :source-name "b"))))

(ert-deftest utter-mode-test-queue-entries ()
  (with-temp-buffer
    (let* ((items (utter-ui-test--sample-items (current-buffer)))
           (utter-ui-test--items items)
           (utter-ui-test--state (append (list :item (nth 1 items))
                                         utter-ui-test--playing-state)))
      (utter-ui-test-with-engine
        (let ((entries (utter-queue--entries)))
          (should (eq (car (nth 0 entries)) (nth 0 items)))
          (should (equal (cadr (nth 0 entries))
                         ["✓ played" "1" "OpenAI:nova"
                          "Listening is also cheaper than it looks…"
                          "0:22" "reading-aloud.org"]))
          (should (equal (cadr (nth 1 entries))
                         ["▶ playing" "2" "OpenAI:nova"
                          "Hearing the gaps. Reading a draft aloud…"
                          "0:31/1:12" "reading-aloud.org"]))
          (should (equal (cadr (nth 2 entries))
                         ["· pending" "3" "Kokoro:af_heart"
                          "Run nix flake update first."
                          "--" "*agent-shell: flake*"]))
          (should (equal (aref (cadr (nth 3 entries)) 0) "✗ error"))
          (should (equal (aref (cadr (nth 3 entries)) 2) "say"))
          (should (equal (aref (cadr (nth 4 entries)) 0) "⏹ interrupted")))))))

(ert-deftest utter-mode-test-queue-entries-current-status ()
  "The current item shows the player state, not only the item status."
  (let* ((items (utter-ui-test--sample-items nil))
         (utter-ui-test--items items))
    (dolist (case '((paused . "⏸ paused") (synthesizing . "⟳ synth")))
      (let ((utter-ui-test--state (list :status (car case)
                                        :item (nth 1 items))))
        (utter-ui-test-with-engine
          (should (equal (aref (cadr (nth 1 (utter-queue--entries))) 0)
                         (cdr case)))
          (should (equal (aref (cadr (nth 1 (utter-queue--entries))) 4)
                         "--")))))))

(ert-deftest utter-mode-test-queue-buffer ()
  (let* ((items (utter-ui-test--sample-items nil))
         (utter-ui-test--items items)
         (utter-ui-test--state (append (list :item (nth 1 items))
                                       utter-ui-test--playing-state))
         (utter-progress-functions nil))
    (utter-ui-test-with-engine
      (save-window-excursion
        (unwind-protect
            (with-current-buffer (utter-queue)
              (should (equal (buffer-name) "*utter-queue*"))
              (should (derived-mode-p 'utter-queue-mode))
              (should utter-mode)
              (should buffer-read-only)
              (should-not tabulated-list-use-header-line)
              (should (equal header-line-format '(:eval (utter--header-line))))
              (should (string-match-p "Backend:voice" (buffer-string)))
              (should (string-match-p "Hearing the gaps" (buffer-string)))
              (goto-char (point-min))
              (search-forward "Run nix")
              (should (eq (tabulated-list-get-id) (nth 2 items)))
              (utter-queue-remove)
              (should (equal (assq 'utter--queue-remove utter-ui-test--calls)
                             (list 'utter--queue-remove (nth 2 items))))
              (utter-queue-replay)
              (should (assq 'utter-replay-item utter-ui-test--calls))
              (search-backward "Hearing")
              (should-error (utter-queue-remove) :type 'user-error)
              (should (eq (key-binding (kbd "d")) 'utter-queue-remove))
              (should (eq (key-binding (kbd "r")) 'utter-queue-replay))
              (should (eq (key-binding (kbd "o")) 'utter-visit-source))
              (should (eq (key-binding (kbd "RET")) 'utter-visit-source)))
          (when (get-buffer "*utter-queue*")
            (kill-buffer "*utter-queue*")))))))

(ert-deftest utter-mode-test-queue-visit-source ()
  (let ((source (generate-new-buffer "source")))
    (unwind-protect
        (let* ((items (utter-ui-test--sample-items source))
               (utter-ui-test--items items)
               (utter-ui-test--state '(:status idle)))
          (utter-ui-test-with-engine
            (save-window-excursion
              (with-current-buffer (utter-queue)
                (goto-char (point-min))
                (search-forward "Listening")
                (utter-visit-source)
                (should (eq (window-buffer (selected-window)) source))))))
      (kill-buffer source)
      (when (get-buffer "*utter-queue*")
        (kill-buffer "*utter-queue*")))))

;;;; Rule 5: the internal unit never shows

(ert-deftest utter-ui-test-internal-unit-never-named ()
  "DESIGN rule 5: no UI file mentions the internal unit."
  (dolist (file (utter-ui-test--own-files))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((case-fold-search t))
        (should-not (re-search-forward (concat "chu" "nk") nil t))))))

(provide 'utter-mode-tests)
;;; utter-mode-tests.el ends here
