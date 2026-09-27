;;; utter-queue-tests.el --- Tests for utter-queue.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Queue, prefetch, player and lighter tests.  No network, no API
;; keys, no macOS binaries: `utter-request' is replaced by a fake that
;; answers with a temp file, and the player runs `sleep'.
;;
;; This file also provides the shared fixtures used by
;; utter-tests.el.  When utter-core.el is not on the load path, a
;; minimal stand-in with the frozen DESIGN.md signatures is defined
;; here so the engine can be tested on its own.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;;; Core stand-in (only when the real core is absent)

(require 'utter-core nil t)
(unless (featurep 'utter-core)
  (cl-defstruct (utter-backend (:constructor utter--make-backend)
                               (:copier utter--copy-backend))
    name host protocol endpoint url header key
    models voices formats max-chars
    (max-chars-unit 'chars)
    (response-kind 'bytes)
    response-path
    capabilities
    request-params curl-args body-transform
    (coding-system 'binary))
  (defvar utter--known-backends nil)
  (defun utter-get-backend (name)
    (alist-get name utter--known-backends nil nil #'equal))
  (defun utter-request (&rest _)
    (error "Test stand-in: utter-request must be replaced in tests"))
  (defun utter-abort (_request) nil)
  ;; Helpers copied from the core so the engine behaves the same.
  (defconst utter--log-buffer-name "*utter-log*")
  (defun utter--resolve-backend (backend)
    (cond
     ((utter-backend-p backend) backend)
     ((and (stringp backend) (utter-get-backend backend)))
     ((null backend)
      (user-error "No utter backend; define one with `utter-make-openai' or `utter-make-say'"))
     (t (user-error "Unknown utter backend: %S" backend))))
  (defun utter--model-name (model) (if (consp model) (car model) model))
  (defun utter--model-plist (backend model)
    (cl-loop for m in (utter-backend-models backend)
             when (and (consp m) (eq (car m) model)) return (cdr m)))
  (defun utter--voice-name (voice) (if (consp voice) (car voice) voice))
  (defun utter--formats (backend &optional model)
    (or (plist-get (utter--model-plist backend model) :formats)
        (utter-backend-formats backend)))
  (defun utter--capable-p (backend model capability)
    (let ((mplist (utter--model-plist backend model)))
      (memq capability
            (if (plist-member mplist :capabilities)
                (plist-get mplist :capabilities)
              (utter-backend-capabilities backend)))))
  (defun utter--text-length (text unit)
    (pcase unit
      ('bytes (string-bytes (encode-coding-string text 'utf-8)))
      ('utf16 (/ (length (encode-coding-string text 'utf-16le)) 2))
      (_ (length text))))
  (defun utter-cache-prune (&optional _max-size) nil)
  (provide 'utter-core))

(require 'utter)

;;;; Fixtures

(cl-defstruct (utter-eng-req (:constructor utter-eng--make-req))
  text args callback aborted answered)

(defvar utter-eng--requests nil "Fake requests in the order they were made.")
(defvar utter-eng--auto t "When non-nil, fake requests succeed after 10 ms.")
(defvar utter-eng--played nil "List of (FILE RATE) the fake player was given.")
(defvar utter-eng--messages nil "Messages captured during a test, newest first.")
(defvar utter-eng--play-seconds "0.2" "How long the fake player plays.")
(defvar utter-eng--prunes 0 "How often the cache was pruned.")

(defvar utter-eng--audio-file
  (let ((f (make-temp-file "utter-test" nil ".wav")))
    (with-temp-file f (insert "RIFF"))
    f)
  "A file that stands in for synthesized audio.")

(defvar utter-eng--player
  (make-utter-player
   :name "fake" :formats '(wav mp3)
   :command (lambda (file rate)
              (push (list file rate) utter-eng--played)
              (list "sleep" utter-eng--play-seconds)))
  "A player that sleeps instead of playing.")

(defun utter-eng--backend (&rest keys)
  "Return a fake backend; KEYS override the defaults."
  (apply #'utter--make-backend
         (append keys
                 (list :name "Fake" :models '(fake-model) :voices '("v1" "v2")
                       :formats '(wav) :max-chars 4096))))

(defun utter-eng--answer (req)
  "Answer the fake REQ successfully."
  (unless (or (utter-eng-req-aborted req) (utter-eng-req-answered req))
    (setf (utter-eng-req-answered req) t)
    (funcall (utter-eng-req-callback req) utter-eng--audio-file
             (list :format 'wav :duration 0.2 :http-status 200
                   :text (utter-eng-req-text req)))))

(defun utter-eng--fake-request (text &rest args)
  "Record a request for TEXT with ARGS and maybe answer it later."
  (let ((req (utter-eng--make-req :text text :args args
                                   :callback (plist-get args :callback))))
    (setq utter-eng--requests (append utter-eng--requests (list req)))
    (when utter-eng--auto
      (run-at-time 0.01 nil #'utter-eng--answer req))
    req))

(defun utter-eng--fake-abort (req)
  "Abort the fake REQ, calling its callback with `abort'."
  (unless (utter-eng-req-aborted req)
    (setf (utter-eng-req-aborted req) t)
    (funcall (utter-eng-req-callback req) 'abort nil)))

(defun utter-eng--respond (n)
  "Answer the Nth fake request successfully."
  (utter-eng--answer (nth n utter-eng--requests)))

(defun utter-eng--fail (n code)
  "Answer the Nth fake request with HTTP status CODE."
  (let ((req (nth n utter-eng--requests)))
    (setf (utter-eng-req-answered req) t)
    (funcall (utter-eng-req-callback req) nil
             (list :http-status code :error (format "HTTP %s" code)))))

(defun utter-eng--texts ()
  "Return the texts of all fake requests so far."
  (mapcar #'utter-eng-req-text utter-eng--requests))

(defun utter-eng--message (format &rest args)
  "Capture a message made from FORMAT and ARGS."
  (let ((s (and format (apply #'format-message format args))))
    (push s utter-eng--messages)
    s))

(defun utter-eng--wait (pred &optional timeout)
  "Process events until PRED is non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))

(defun utter-eng--idle-p ()
  "Return non-nil when the queue is idle."
  (eq (plist-get (utter-state) :status) 'idle))

(defun utter-eng--playing-p (item)
  "Return non-nil when ITEM is current and its audio is playing."
  (and (eq (plist-get (utter-state) :item) item)
       (eq (plist-get (utter-state) :status) 'playing)))

(defun utter-eng--status ()
  "Return the queue status."
  (plist-get (utter-state) :status))

(defmacro utter-eng-with-queue (bindings &rest body)
  "Run BODY with a fresh queue, fake core and fake player.
BINDINGS are extra `let*' bindings evaluated after the defaults."
  (declare (indent 1))
  `(let* ((utter-backend (utter-eng--backend))
          (utter-model nil) (utter-voice nil) (utter-format nil)
          (utter-speed 1.0) (utter-language 'auto) (utter-instructions nil)
          (utter-voice-alist nil)
          (utter-playback-rate 1.0)
          (utter-player utter-eng--player)
          (utter-prefetch-depth 2) (utter-max-concurrent-requests 2)
          (utter-highlight nil) (utter-highlight-follow nil)
          (utter-lighter " ♪%i/%n")
          (utter--retry-delay 0.05)
          (utter-enqueue-hook nil) (utter-item-finished-functions nil)
          (utter-queue-finished-hook nil) (utter-notify-function nil)
          (utter-eng--requests nil) (utter-eng--played nil)
          (utter-eng--auto t) (utter-eng--messages nil)
          (utter-eng--play-seconds "0.2") (utter-eng--prunes 0)
          (global-mode-string nil)
          ,@bindings)
     (cl-letf (((symbol-function 'utter-request) #'utter-eng--fake-request)
               ((symbol-function 'utter-abort) #'utter-eng--fake-abort)
               ((symbol-function 'message) #'utter-eng--message)
               ((symbol-function 'utter-cache-prune)
                (lambda (&rest _) (setq utter-eng--prunes (1+ utter-eng--prunes)))))
       (utter--reset)
       (unwind-protect (progn ,@body)
         (utter--reset)))))

(defun utter-eng--three-sentences ()
  "Return text that splits into three segments at max-chars 20."
  "Alpha beta gamma. Delta epsilon zeta. Eta theta iota.")

;;;; Enqueue and playback

(ert-deftest utter-queue-single-item-plays-to-completion ()
  (utter-eng-with-queue ((enqueued nil) (progress nil) (finished nil) (idle 0))
    (add-hook 'utter-enqueue-hook (lambda (item) (push item enqueued)))
    (add-hook 'utter-item-finished-functions
              (lambda (item status) (push (cons item status) finished)))
    (add-hook 'utter-queue-finished-hook (lambda () (setq idle (1+ idle))))
    (let* ((utter-progress-functions
            (list (lambda (item start end) (push (list item start end) progress))))
           (item (utter-enqueue "Hello there." :source-name "greeting")))
      (should (utter-item-p item))
      (should (equal (utter-item-text item) "Hello there."))
      (should (equal enqueued (list item)))
      (should (utter-active-p))
      (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
      (should (eq (utter-item-status item) 'playing))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (eq (utter-item-status item) 'done))
      (should (equal progress (list (list item 0 12))))
      (should (equal finished (list (cons item 'done))))
      (should (= idle 1))
      (should-not (utter-active-p))
      (should (member "utter: queued 12 chars (~1 s) from greeting" utter-eng--messages))
      (should (member "utter: playing greeting" utter-eng--messages))
      (should (cl-some (lambda (m) (and m (string-match-p "\\`utter: finished greeting (0:0[0-9])\\'" m)))
                       utter-eng--messages)))))

(ert-deftest utter-queue-request-params-are-resolved-snapshot ()
  (utter-eng-with-queue ((utter-voice "v2") (utter-speed 1.2))
    (let ((item (utter-enqueue "Hi.")))
      (setq utter-voice "v1")
      (should (utter-eng--wait #'utter-eng--idle-p))
      (let ((args (utter-eng-req-args (car utter-eng--requests))))
        (should (eq (plist-get args :backend) utter-backend))
        (should (eq (plist-get args :model) 'fake-model))
        (should (equal (plist-get args :voice) "v2"))
        (should (= (plist-get args :speed) 1.2))
        (should (eq (plist-get args :format) 'wav))
        (should (functionp (plist-get args :callback))))
      (should (equal (plist-get (utter-item-params item) :voice) "v2")))))

(ert-deftest utter-queue-voice-alist-by-language ()
  (utter-eng-with-queue ((utter-voice-alist '((zh . "Tingting") (en . "Samantha"))))
    (utter-enqueue "你好。")
    (utter-enqueue "Hello.")
    (should (utter-eng--wait #'utter-eng--idle-p))
    (should (equal (mapcar (lambda (r) (plist-get (utter-eng-req-args r) :voice))
                           utter-eng--requests)
                   '("Tingting" "Samantha")))))

(ert-deftest utter-queue-nil-backend-is-a-user-error ()
  (utter-eng-with-queue ((utter-backend nil))
    (let ((err (should-error (utter-enqueue "Hi.") :type 'user-error)))
      (should (string-match-p "utter-make-openai" (cadr err))))
    (should-not (utter-active-p))))

(ert-deftest utter-queue-empty-text-is-a-user-error ()
  (utter-eng-with-queue ()
    (should-error (utter-enqueue "   \n ") :type 'user-error)
    (should-not (utter-active-p))))

(ert-deftest utter-queue-segments-and-progress-positions ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend :max-chars 20))
                          (utter--first-segment-chars 20)
                          (progress nil))
    (let* ((utter-progress-functions
            (list (lambda (_item start end) (push (cons start end) progress))))
           (text (utter-eng--three-sentences))
           (item (utter-enqueue text)))
      (should (= (length (utter--item-segments item)) 3))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (equal (utter-eng--texts)
                     '("Alpha beta gamma." "Delta epsilon zeta." "Eta theta iota.")))
      (should (equal (nreverse progress) '((0 . 17) (18 . 37) (38 . 53))))
      (should (equal (substring text 18 37) "Delta epsilon zeta."))
      (should (= (length utter-eng--played) 3)))))

(ert-deftest utter-queue-prefetch-depth-and-concurrency ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend :max-chars 12))
                          (utter--first-segment-chars 12)
                          (utter-eng--auto nil)
                          (utter-eng--play-seconds "0.3"))
    (let ((item (utter-enqueue "One two. Three four. Five six. Seven eight. Nine ten.")))
      (should (= (length (utter--item-segments item)) 5))
      ;; Two requests at most in flight.
      (should (equal (utter-eng--texts) '("One two." "Three four.")))
      (should (eq (utter-eng--status) 'synthesizing))
      ;; First audio arrives: it plays, and one more is requested
      ;; (window = playing segment + 2 ahead).
      (utter-eng--respond 0)
      (should (eq (utter-eng--status) 'playing))
      (should (equal (utter-eng--texts) '("One two." "Three four." "Five six.")))
      ;; The window is full: answering the second asks for nothing new.
      (utter-eng--respond 1)
      (should (= (length utter-eng--requests) 3))
      ;; When the first segment finishes, the window slides.
      (should (utter-eng--wait (lambda () (= (length utter-eng--requests) 4))))
      (should (equal (nth 3 (utter-eng--texts)) "Seven eight.")))))

(ert-deftest utter-queue-prefetch-crosses-item-boundaries ()
  (utter-eng-with-queue ((utter-eng--auto nil))
    (utter-enqueue "First.")
    (utter-enqueue "Second.")
    (utter-enqueue "Third.")
    ;; Concurrency caps it at two.
    (should (equal (utter-eng--texts) '("First." "Second.")))
    (utter-eng--respond 0)
    (should (equal (utter-eng--texts) '("First." "Second." "Third.")))))

(ert-deftest utter-queue-retries-once-then-continues ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend :max-chars 20))
                          (utter--first-segment-chars 20)
                          (utter-eng--auto nil)
                          (errors nil))
    (let* ((utter-error-functions
            (list (lambda (item err) (push (cons item err) errors))))
           (item (utter-enqueue (utter-eng--three-sentences))))
      (utter-eng--fail 0 429)
      (should (member "utter: Fake 429, retrying in 0.05 s" utter-eng--messages))
      (should (utter-eng--wait (lambda () (= (length utter-eng--requests) 3))))
      (should (equal (nth 2 (utter-eng--texts)) "Alpha beta gamma."))
      (utter-eng--fail 2 503)
      (should (= (length errors) 1))
      (should (eq (car (car errors)) item))
      (should (string-match-p "503" (cdr (car errors))))
      (should (string-match-p "✗503" (utter--lighter-string)))
      ;; Playback continues with the next segment.
      (utter-eng--respond 1)
      (should (eq (utter-eng--status) 'playing))
      (setq utter-eng--auto t)
      (dolist (r utter-eng--requests) (utter-eng--answer r))
      (should (utter-eng--wait
               (lambda ()
                 (dolist (r utter-eng--requests) (utter-eng--answer r))
                 (utter-eng--idle-p))))
      (should (eq (utter-item-status item) 'done))
      (should (eq (utter--segment-status (car (utter--item-segments item))) 'error)))))

(ert-deftest utter-queue-no-retry-on-client-error ()
  (utter-eng-with-queue ((utter-eng--auto nil) (errors nil))
    (let* ((utter-error-functions (list (lambda (_i e) (push e errors))))
           (item (utter-enqueue "Only one.")))
      (utter-eng--fail 0 401)
      (should (= (length utter-eng--requests) 1))
      (should (= (length errors) 1))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (eq (utter-item-status item) 'error)))))

(ert-deftest utter-queue-default-error-function-messages ()
  (utter-eng-with-queue ((utter-eng--auto nil))
    (utter-enqueue "Only one.")
    (utter-eng--fail 0 401)
    (should (cl-some (lambda (m) (and m (string-match-p "\\`utter: Fake 401" m)))
                     utter-eng--messages))))

(ert-deftest utter-queue-request-signal-marks-error ()
  (utter-eng-with-queue ((errors nil))
    (cl-letf (((symbol-function 'utter-request)
               (lambda (&rest _) (error "Boom"))))
      (let* ((utter-error-functions (list (lambda (_i e) (push e errors))))
             (item (utter-enqueue "Hi.")))
        (should (utter-eng--wait #'utter-eng--idle-p))
        (should (eq (utter-item-status item) 'error))
        (should (string-match-p "Boom" (car errors)))))))

;;;; Model-level settings and cache

(ert-deftest utter-queue-model-level-voices-and-formats ()
  (utter-eng-with-queue ((utter-backend
                          (utter-eng--backend
                           :models '((m1 :voices ("mv1" "mv2") :formats (mp3)) m2)
                           :voices 'fetch)))
    (let ((item (utter-enqueue "Model level.")))
      (should (eq (plist-get (utter-item-params item) :model) 'm1))
      (should (equal (plist-get (utter-item-params item) :voice) "mv1"))
      (should (eq (plist-get (utter-item-params item) :format) 'mp3)))
    (let ((item (utter-enqueue "Fetched voices." :model 'm2)))
      ;; A fetched voice list gives no default; the backend decides.
      (should-not (plist-get (utter-item-params item) :voice))
      (should (eq (plist-get (utter-item-params item) :format) 'wav)))
    (should (= utter-eng--prunes 2))
    (utter-stop)))

(ert-deftest utter-queue-items-order-and-remove ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.5"))
    (let ((a (utter-enqueue "Aaa."))
          (b (utter-enqueue "Bbb."))
          (c (utter-enqueue "Ccc.")))
      (should (utter-eng--wait (lambda () (utter-eng--playing-p a))))
      (utter-next)
      (should (utter-eng--wait (lambda () (utter-eng--playing-p b))))
      (should (equal (utter--queue-items) (list a b c)))
      (utter-previous)
      ;; a is current again, b went back to pending.
      (should (equal (utter--queue-items) (list a b c)))
      (utter--queue-remove a)
      (should (member "utter: only pending utterances can be removed"
                      utter-eng--messages))
      (utter--queue-remove c)
      (should (equal (utter--queue-items) (list a b)))
      (utter-stop)
      (utter-replay-item a)
      (should (equal (utter--queue-items) (list b a)))
      (utter-stop))))

;;;; Player control

(ert-deftest utter-queue-pause-and-resume-with-signals ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.3"))
    (let ((item (utter-enqueue "Pause me.")))
      (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
      (let ((proc (utter--qstate-process utter--queue)))
        (utter-pause)
        (should (eq (utter-eng--status) 'paused))
        (should (eq (utter-item-status item) 'paused))
        (should (member "utter: paused" utter-eng--messages))
        (should (string-suffix-p "⏸" (utter--lighter-string)))
        (should (utter-eng--wait (lambda () (eq (process-status proc) 'stop)) 1))
        ;; Paused well past the play time: still not finished.
        (utter-eng--wait #'ignore 0.6)
        (should (process-live-p proc))
        (should (eq (utter-item-status item) 'paused))
        (utter-toggle-pause)
        (should (eq (utter-eng--status) 'playing))
        (should (utter-eng--wait #'utter-eng--idle-p))
        (should (eq (utter-item-status item) 'done))))))

(ert-deftest utter-queue-restart-resume-continues-at-offset ()
  ;; Players that lose their place under SIGSTOP (ffplay) resume by
  ;; starting again at the paused position.
  (let* ((starts nil)
         (player (make-utter-player
                  :name "restarting" :formats '(wav)
                  :resume #'utter-player-restart
                  :command (lambda (_file rate &optional offset)
                             (push (list rate offset) starts)
                             (list "sleep" (if offset "0.2" "0.4"))))))
    (utter-eng-with-queue ((utter-player player) (utter-playback-rate 1.5)
                           (finished 0))
      (add-hook 'utter-item-finished-functions
                (lambda (_i _s) (setq finished (1+ finished))))
      (let ((item (utter-enqueue "Restart me.")))
        (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
        (utter-eng--wait #'ignore 0.15)
        (let ((first (utter--qstate-process utter--queue)))
          (utter-pause)
          (utter-eng--wait #'ignore 0.3)
          (utter-resume)
          (should-not (process-live-p first))
          (should (process-live-p (utter--qstate-process utter--queue))))
        (should (= (length starts) 2))
        (let ((offset (cadr (car starts))))
          ;; About 0.15 s played at rate 1.5, so about 0.22 s of audio.
          (should (and (numberp offset) (< 0.1 offset 0.8))))
        (should (equal (car (car starts)) 1.5))
        (should (utter-eng--wait #'utter-eng--idle-p))
        (should (eq (utter-item-status item) 'done))
        (should (= finished 1))))))

(ert-deftest utter-queue-ffplay-restarts-with-seek ()
  (should (eq (utter-player-resume utter-player-ffplay) #'utter-player-restart))
  (should (equal (funcall (utter-player-command utter-player-ffplay) "/a.mp3" 1.0 2.5)
                 '("ffplay" "-nodisp" "-autoexit" "-loglevel" "error"
                   "-ss" "2.50" "-af" "atempo=1.0" "/a.mp3")))
  (should (eq (utter-player-resume utter-player-afplay) #'utter-player-sigcont)))

(ert-deftest utter-queue-pause-before-audio-holds-playback ()
  (utter-eng-with-queue ((utter-eng--auto nil))
    (utter-enqueue "Wait.")
    (utter-pause)
    (utter-eng--respond 0)
    (should (eq (utter-eng--status) 'paused))
    (should-not (utter--qstate-process utter--queue))
    (utter-resume)
    (should (eq (utter-eng--status) 'playing))
    (should (utter-eng--wait #'utter-eng--idle-p))))

(ert-deftest utter-queue-interrupt-plays-new-text-now ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend :max-chars 20))
                          (utter--first-segment-chars 20)
                          (utter-eng--play-seconds "0.5")
                          (utter-eng--auto nil)
                          (finished nil))
    (add-hook 'utter-item-finished-functions
              (lambda (item status) (push (cons (utter-item-text item) status) finished)))
    (let ((a (utter-enqueue (utter-eng--three-sentences)))
          (b (utter-enqueue "Pending one.")))
      ;; First audio plays; the next two parts are still in flight.
      (utter-eng--respond 0)
      (should (eq (utter-eng--status) 'playing))
      (should (= (length utter-eng--requests) 3))
      (setq utter-eng--auto t)
      (let* ((proc (utter--qstate-process utter--queue))
             (c (utter-interrupt "Urgent news.")))
        (should (utter-eng-req-aborted (nth 1 utter-eng--requests)))
        (should (utter-eng-req-aborted (nth 2 utter-eng--requests)))
        (should-not (process-live-p proc))
        (should (eq (utter-item-status a) 'interrupted))
        (should (eq (utter-item-status b) 'interrupted))
        (should (memq a (utter--qstate-items utter--queue)))
        (should (cl-some #'utter-eng-req-aborted utter-eng--requests))
        (should (utter-eng--wait (lambda () (eq (utter-item-status c) 'playing))))
        (should (equal (plist-get (utter-state) :total) 1))
        (should (utter-eng--wait #'utter-eng--idle-p))
        (should (eq (utter-item-status c) 'done))
        (should (equal (reverse finished)
                       `((,(utter-eng--three-sentences) . interrupted)
                         ("Pending one." . interrupted)
                         ("Urgent news." . done))))))))

(ert-deftest utter-queue-next-and-previous-move-between-utterances ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.5"))
    (let ((a (utter-enqueue "Aaa."))
          (b (utter-enqueue "Bbb."))
          (c (utter-enqueue "Ccc.")))
      (should (utter-eng--wait (lambda () (utter-eng--playing-p a))))
      (should (equal (utter--lighter-string) " ♪1/3"))
      (utter-next)
      (should (eq (utter-item-status a) 'interrupted))
      (should (utter-eng--wait (lambda () (utter-eng--playing-p b))))
      (should (equal (utter--lighter-string) " ♪2/3"))
      (utter-previous)
      (should (utter-eng--wait (lambda () (eq (utter-item-status a) 'playing))))
      (should (eq (utter-item-status b) 'pending))
      (should (equal (plist-get (utter-state) :index) 1))
      (utter-next 2)
      (should (eq (utter-item-status b) 'interrupted))
      (should (utter-eng--wait (lambda () (eq (utter-item-status c) 'playing))))
      (utter-next)
      (should (utter-eng--wait #'utter-eng--idle-p))
      ;; Previous from idle replays the last utterance.
      (utter-previous)
      (should (utter-eng--wait (lambda () (eq (utter-item-status c) 'playing))))
      (utter-stop))))

(ert-deftest utter-queue-stop-goes-idle ()
  (utter-eng-with-queue ((idle 0))
    (add-hook 'utter-queue-finished-hook (lambda () (setq idle (1+ idle))))
    (let ((a (utter-enqueue "Aaa."))
          (b (utter-enqueue "Bbb.")))
      (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
      (should (member '(:eval (utter--lighter-string)) global-mode-string))
      (utter-stop)
      (should (utter-eng--idle-p))
      (should (eq (utter-item-status a) 'interrupted))
      (should (eq (utter-item-status b) 'interrupted))
      (should-not (utter--qstate-process utter--queue))
      (should-not (member '(:eval (utter--lighter-string)) global-mode-string))
      (should (= idle 1)))))

(ert-deftest utter-queue-clear-drops-pending ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.3"))
    (let ((a (utter-enqueue "Aaa."))
          (b (utter-enqueue "Bbb."))
          (c (utter-enqueue "Ccc.")))
      (should (utter-eng--wait (lambda () (eq (utter-item-status a) 'playing))))
      (utter-clear)
      (should (equal (utter--qstate-items utter--queue) (list a)))
      (should-not (memq b (utter--qstate-items utter--queue)))
      (should-not (memq c (utter--qstate-items utter--queue)))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (eq (utter-item-status a) 'done))
      (utter-clear '(4))
      (should-not (utter--qstate-items utter--queue)))))

(ert-deftest utter-queue-rate-applies-to-next-segment ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.1"))
    (utter-rate-up)
    (should (= utter-playback-rate 1.1))
    (utter-rate-up)
    (utter-rate-down)
    (should (= utter-playback-rate 1.1))
    (utter-enqueue "Faster.")
    (should (utter-eng--wait #'utter-eng--idle-p))
    (should (equal (cadr (car utter-eng--played)) 1.1))
    ;; Rate changes never make a new request.
    (should (= (length utter-eng--requests) 1))
    (dotimes (_ 40) (utter-rate-down))
    (should (= utter-playback-rate 0.5))))

(ert-deftest utter-queue-replay-item-reuses-audio ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.1"))
    (let ((a (utter-enqueue "Again.")))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (utter-replay-item a)
      (should (utter-active-p))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (eq (utter-item-status a) 'done))
      (should (= (length utter-eng--played) 2))
      (should (= (length utter-eng--requests) 1)))))

(ert-deftest utter-queue-cache-only-items-do-not-play ()
  (utter-eng-with-queue ()
    (let ((a (utter-enqueue "Cache me." :cache-only t)))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (eq (utter-item-status a) 'done))
      (should (= (length utter-eng--requests) 1))
      (should-not utter-eng--played))))

(ert-deftest utter-queue-cache-only-finish-says-cached-and-does-not-notify ()
  "Nothing played, so no \"finished\" message and no desktop notification."
  (utter-eng-with-queue ((notified nil))
    (let ((utter-notify-function (lambda (&rest args) (setq notified args))))
      (utter-enqueue "Cache me." :cache-only t :source-name "notes")
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (member "utter: cached notes" utter-eng--messages))
      (should-not (cl-some (lambda (m) (string-match-p "finished" m))
                           utter-eng--messages))
      (should-not notified))))

(ert-deftest utter-queue-context-for-stitching-backends ()
  (utter-eng-with-queue ((utter-backend (utter-eng--backend :max-chars 20
                                                              :capabilities '(stitching)))
                          (utter--first-segment-chars 20))
    (utter-enqueue (utter-eng--three-sentences))
    (should (utter-eng--wait #'utter-eng--idle-p))
    (should (equal (plist-get (utter-eng-req-args (nth 1 utter-eng--requests)) :context)
                   '(:previous "Alpha beta gamma." :next "Eta theta iota.")))
    (should-not (plist-get (plist-get (utter-eng-req-args (nth 0 utter-eng--requests))
                                      :context)
                           :previous)))
  (utter-eng-with-queue ()
    (utter-enqueue "No stitching.")
    (should (utter-eng--wait #'utter-eng--idle-p))
    (should-not (plist-member (utter-eng-req-args (car utter-eng--requests)) :context))))

;;;; State and lighter

(ert-deftest utter-queue-lighter-strings ()
  (utter-eng-with-queue ((utter-eng--auto nil))
    (should-not (utter--lighter-string))
    (utter-enqueue "One.")
    (should (equal (utter--lighter-string) " ♪⟳"))
    (utter-eng--respond 0)
    (should (equal (utter--lighter-string) " ♪"))
    (utter-enqueue "Two.")
    (should (equal (utter--lighter-string) " ♪1/2"))
    (utter-pause)
    (should (equal (utter--lighter-string) " ♪1/2⏸"))
    (let ((utter-lighter nil))
      (should-not (utter--lighter-string)))
    (utter-stop)
    (should-not (utter--lighter-string))))

(ert-deftest utter-queue-state-plist-and-string ()
  (utter-eng-with-queue ((utter-eng--play-seconds "0.3"))
    (should (eq (plist-get (utter-state) :status) 'idle))
    (let ((a (utter-enqueue "State check." :source-name "notes.org")))
      (utter-enqueue "Second.")
      (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
      (let ((st (utter-state)))
        (should (eq (plist-get st :item) a))
        (should (= (plist-get st :index) 1))
        (should (= (plist-get st :total) 2))
        (should (= (plist-get st :pending) 1))
        (should (equal (plist-get st :backend) "Fake"))
        (should (eq (plist-get st :model) 'fake-model))
        (should (equal (plist-get st :voice) "v1"))
        (should (= (plist-get st :rate) 1.0))
        (should (equal (plist-get st :source) "notes.org"))
        (should (numberp (plist-get st :elapsed))))
      (should (equal (utter-state-string "%s %i/%n %b:%m/%v %r %S")
                     "playing 1/2 Fake:fake-model/v1 1.0 notes.org"))
      (should (string-match-p "\\`[0-9]+:[0-9][0-9]\\'" (utter-state-string "%t"))))))

;;;; Players

(ert-deftest utter-queue-builtin-player-commands ()
  (should (equal (funcall (utter-player-command utter-player-afplay) "/a.mp3" 1.5)
                 '("afplay" "-r" "1.5" "/a.mp3")))
  (should (equal (funcall (utter-player-command utter-player-ffplay) "/a.mp3" 1.0)
                 '("ffplay" "-nodisp" "-autoexit" "-loglevel" "error"
                   "-af" "atempo=1.0" "/a.mp3")))
  (should (equal (funcall (utter-player-command utter-player-mpv) "/a.mp3" 1.2)
                 '("mpv" "--no-video" "--speed=1.2" "/a.mp3")))
  (should (eq (utter-player-pause utter-player-afplay) #'utter-player-sigstop))
  (should (eq (utter-player-pause utter-player-ffplay) #'utter-player-sigstop)))

(ert-deftest utter-queue-auto-player-picks-installed-and-format ()
  (let* ((missing (make-utter-player :name "missing" :formats '(wav)
                                     :command (lambda (f _r) (list "utter-no-such-program" f))))
         (sleeper (make-utter-player :name "sleeper" :formats '(mp3)
                                     :command (lambda (_f _r) (list "sleep" "0"))))
         (utter--player-candidates (list missing sleeper))
         (utter-player 'auto))
    (should (eq (utter--select-player 'mp3) sleeper))
    (should-not (utter--select-player 'wav))
    (let ((utter-player sleeper))
      (should (eq (utter--select-player 'wav) sleeper)))
    (let ((utter-player 'utter-eng--player))
      (should (eq (utter--select-player 'wav) utter-eng--player)))))

(ert-deftest utter-queue-missing-player-reports-error ()
  (utter-eng-with-queue ((utter-player 'auto)
                          (utter--player-candidates nil)
                          (errors nil))
    (let* ((utter-error-functions (list (lambda (_i e) (push e errors))))
           (item (utter-enqueue "No player.")))
      (should (utter-eng--wait #'utter-eng--idle-p))
      (should (eq (utter-item-status item) 'error))
      (should (string-match-p "player" (car errors))))))

;;;; Highlight

(defmacro utter-eng-with-source (text &rest body)
  "Run BODY in a temporary buffer holding TEXT, point at the start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(ert-deftest utter-queue-highlight-follows-playback-and-drops-on-edit ()
  (utter-eng-with-queue ((utter-highlight t)
                          (utter-backend (utter-eng--backend :max-chars 20))
                          (utter--first-segment-chars 20)
                          (utter-eng--play-seconds "0.4"))
    (utter-eng-with-source (concat "Intro. " (utter-eng--three-sentences))
      (let* ((beg 8) (end (point-max))
             (item (utter-enqueue (utter--buffer-text beg end)
                                  :source-buffer (current-buffer))))
        (should (= (length (utter-item-markers item)) 3))
        (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
        (let ((ov (cl-find-if (lambda (o) (overlay-get o 'face))
                              (overlays-in (point-min) (point-max)))))
          (should ov)
          (should (eq (overlay-get ov 'face) 'utter-highlight))
          (should (equal (buffer-substring (overlay-start ov) (overlay-end ov))
                         "Alpha beta gamma. ")))
        (should (= (point) 1))
        ;; Editing the source drops the overlay and the markers.
        (goto-char (point-max))
        (insert " More.")
        (should-not (cl-find-if (lambda (o) (eq (overlay-get o 'face) 'utter-highlight))
                                (overlays-in (point-min) (point-max))))
        (should-not (utter-item-markers item))
        (utter-stop)))))

(ert-deftest utter-queue-highlight-off-by-default ()
  (utter-eng-with-queue ()
    (utter-eng-with-source "Plain text here."
      (let ((item (utter-enqueue (utter--buffer-text (point-min) (point-max))
                                 :source-buffer (current-buffer))))
        (should (utter-eng--wait (lambda () (eq (utter-eng--status) 'playing))))
        (should-not (utter-item-markers item))
        (should-not (overlays-in (point-min) (point-max)))
        (should (= (point) 1))
        (utter-stop)))))

(ert-deftest utter-queue-item-private-accessors ()
  (utter-eng-with-queue ((utter-eng--auto nil))
    (let ((item (utter-enqueue "Private.")))
      (should (= (utter--item-position item) 0))
      (setf (utter--item-position item) 0)
      (should (utter--segment-p (car (utter--item-segments item))))
      (should (equal (utter-item-source-name item) "\"Private.\""))
      (should (numberp (utter-item-id item)))
      (should (utter-item-created item))
      ;; The UI tests build items with the default constructor.
      (let ((made (make-utter-item :id 9 :status 'done :text "x")))
        (should (= (utter--item-position made) 0))
        (should (eq (utter-item-status made) 'done))))))

(provide 'utter-queue-tests)
;;; utter-queue-tests.el ends here
