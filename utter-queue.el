;;; utter-queue.el --- Queue, prefetch and playback for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; This file is part of utter.el.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; One global queue of utterances.  An utterance (`utter-item') is one
;; speak request: its text is snapshotted and preprocessed when it is
;; queued, then split into request-sized segments that are synthesized
;; a few ahead of playback (`utter-prefetch-depth') and played one
;; after another by an external player (`utter-player').
;;
;; Nothing here moves point, recenters a window or displays a buffer.
;; The only default indicator is a short lighter in
;; `global-mode-string' while the queue is active; completion and
;; errors are reported with `message'.
;;
;; The options this file reads are defined in utter.el, the package
;; main file, which loads this one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'format-spec)
(require 'utter-text)
;; Soft while utter-core.el is written in parallel.
(require 'utter-core nil t)

;;;; Core symbols (defined in utter-core.el)

(declare-function utter-request "utter-core" (text &rest keys))
(declare-function utter-abort "utter-core" (request))
(declare-function utter-get-backend "utter-core" (name))
(declare-function utter-backend-p "utter-core" (object))
(declare-function utter-backend-name "utter-core" (backend))
(declare-function utter-backend-models "utter-core" (backend))
(declare-function utter-backend-voices "utter-core" (backend))
(declare-function utter-backend-formats "utter-core" (backend))
(declare-function utter-backend-max-chars "utter-core" (backend))
(declare-function utter-backend-max-chars-unit "utter-core" (backend))
(declare-function utter-backend-capabilities "utter-core" (backend))
(declare-function utter--resolve-backend "utter-core" (backend))
(declare-function utter--model-name "utter-core" (model))
(declare-function utter--model-plist "utter-core" (backend model))
(declare-function utter--voice-name "utter-core" (voice))
(declare-function utter--formats "utter-core" (backend &optional model))
(declare-function utter--capable-p "utter-core" (backend model capability))
(declare-function utter-cache-prune "utter-core" (&optional max-size))

;;;; Options (defined in utter.el)

(defvar utter-backend)
(defvar utter-model)
(defvar utter-voice)
(defvar utter-format)
(defvar utter-speed)
(defvar utter-language)
(defvar utter-instructions)
(defvar utter-voice-alist)
(defvar utter-playback-rate)
(defvar utter-highlight)
(defvar utter-highlight-follow)
(defvar utter-lighter)
(defvar utter-prefetch-depth)
(defvar utter-max-concurrent-requests)
(defvar utter-player)

;;;; Hooks

(defvar utter-enqueue-hook nil
  "Hook run with one argument, the new `utter-item', once per utterance.
It runs after the text and parameters are snapshotted.  The
oneshot scope of `utter--set-with-scope' is reset from here.")

(defvar utter-progress-functions '(utter--highlight-progress)
  "Functions called when the spoken text advances.
Each is called with (ITEM START END), where START and END are
positions in the text of ITEM (see `utter-item-text') that is
being spoken now.")

(defvar utter-item-finished-functions nil
  "Functions called with (ITEM STATUS) when an utterance ends.
STATUS is `done', `error' or `interrupted'.")

(defvar utter-queue-finished-hook nil
  "Hook run when the queue becomes idle.")

(defvar utter-error-functions '(utter--message-error)
  "Functions called with (ITEM ERROR-STRING) on a synthesis or player error.")

(defvar utter-notify-function nil
  "Function called with (TITLE BODY) for notifications, or nil.
It is called when an utterance finishes and on errors, for example
to send a desktop or terminal notification.")

(defvar utter--state-change-hook nil
  "Hook run after any change of the queue state.
Used by the header line and the menu heading to redraw.")

(defvar utter--segment-context-function #'utter--segment-context
  "Function of (ITEM INDEX) returning a plist (:previous :next).
The result is passed as :context to backends that have the
`stitching' capability.")

(defface utter-highlight '((t :inherit highlight))
  "Face for the text being spoken, when `utter-highlight' is on."
  :group 'utter)

;;;; Data

(cl-defstruct (utter-item (:constructor utter--make-item)
                          (:constructor make-utter-item
                                        (&key id text status params source-buffer
                                              source-name markers tick created
                                              segments (position 0)))
                          (:copier nil))
  "One utterance: the text of one speak request and its state.
STATUS is one of `pending', `playing', `paused', `done', `error'
or `interrupted'.  The `segments' and `position' slots are
private; use `utter--item-segments' and `utter--item-position'."
  id text status params source-buffer source-name markers tick created
  segments (position 0))

(cl-defstruct (utter--segment (:constructor utter--make-segment) (:copier nil))
  "A request-sized piece of an utterance.  Private.
STATUS is one of `pending', `synthesizing', `retry', `ready',
`playing', `done' or `error'.  START and END are positions in the
item text."
  index text status file request error duration start end format (retries 0))

(defsubst utter--item-segments (item)
  "Return the segments of ITEM."
  (utter-item-segments item))

(gv-define-setter utter--item-segments (value item)
  `(setf (utter-item-segments ,item) ,value))

(defsubst utter--item-position (item)
  "Return the index of the segment of ITEM to play next or playing now."
  (utter-item-position item))

(gv-define-setter utter--item-position (value item)
  `(setf (utter-item-position ,item) ,value))

(cl-defstruct (utter--qstate (:constructor utter--make-qstate) (:copier nil))
  "The playback queue.  Private.
ITEMS is every utterance still listed, oldest first.  RUN is the
utterances counted by the lighter since the queue was last idle."
  items current process paused run timers active announced
  (played 0) seg-start pause-start (paused-total 0) error-code)

(defvar utter--queue (utter--make-qstate)
  "The global queue.")

(defvar utter--item-counter 0
  "Last utterance id handed out.")

(defvar utter--retry-delay 8
  "Seconds to wait before retrying a request that failed with 429 or 5xx.")

(defvar utter--default-max-chars 4000
  "Segment size used when a backend declares no `max-chars'.")

;;;; Players

(cl-defstruct utter-player
  "An external audio player.
COMMAND is a function of (FILE RATE) returning the argument list.
PAUSE, RESUME and STOP are functions of the player process."
  name formats command
  (pause #'utter-player-sigstop)
  (resume #'utter-player-sigcont)
  (stop #'delete-process))

(defun utter-player-sigstop (process)
  "Pause PROCESS with SIGSTOP."
  (signal-process process 'SIGSTOP))

(defun utter-player-sigcont (process)
  "Resume PROCESS with SIGCONT."
  (signal-process process 'SIGCONT))

(defun utter--rate-string (rate)
  "Return RATE as a short decimal string."
  (number-to-string (/ (round (* rate 100)) 100.0)))

(defvar utter-player-afplay
  (make-utter-player
   :name "afplay" :formats '(mp3 wav aiff m4a aac flac)
   :command (lambda (file rate)
              (list "afplay" "-r" (utter--rate-string rate) file)))
  "The macOS afplay player.")

(defvar utter-player-ffplay
  (make-utter-player
   :name "ffplay" :formats '(mp3 wav aiff m4a aac flac opus ogg)
   :command (lambda (file rate)
              (list "ffplay" "-nodisp" "-autoexit" "-loglevel" "error"
                    "-af" (concat "atempo=" (utter--rate-string rate)) file)))
  "The ffplay player from FFmpeg.")

(defvar utter-player-mpv
  (make-utter-player
   :name "mpv" :formats '(mp3 wav aiff m4a aac flac opus ogg)
   :command (lambda (file rate)
              (list "mpv" "--no-video"
                    (concat "--speed=" (utter--rate-string rate)) file)))
  "The mpv player.")

(defvar utter--player-candidates
  (if (eq system-type 'darwin)
      '(utter-player-afplay utter-player-ffplay utter-player-mpv)
    '(utter-player-ffplay utter-player-mpv))
  "Players tried in order when `utter-player' is `auto'.")

(defun utter--resolve-player (player)
  "Return the `utter-player' PLAYER stands for, or nil.
PLAYER is a player or a symbol whose value is one."
  (cond ((utter-player-p player) player)
        ((and (symbolp player) (boundp player)
              (utter-player-p (symbol-value player)))
         (symbol-value player))))

(defun utter--player-installed-p (player)
  "Return non-nil if the program of PLAYER is installed."
  (when-let* ((argv (ignore-errors (funcall (utter-player-command player) "x" 1.0))))
    (executable-find (car argv))))

(defun utter--select-player (format)
  "Return the player to use for audio in FORMAT, or nil."
  (let ((choice (default-value 'utter-player)))
    (if (not (eq choice 'auto))
        (utter--resolve-player choice)
      (cl-find-if (lambda (p)
                    (and p
                         (or (null format) (memq format (utter-player-formats p)))
                         (utter--player-installed-p p)))
                  (mapcar #'utter--resolve-player utter--player-candidates)))))

;;;; Helpers

(defun utter--format-symbol (format)
  "Return FORMAT as a lower-case symbol, or nil."
  (cond ((null format) nil)
        ((stringp format) (intern (downcase format)))
        (t format)))

(defun utter--format-duration (seconds)
  "Format SECONDS as M:SS."
  (let ((s (round (or seconds 0))))
    (format "%d:%02d" (/ s 60) (% s 60))))

(defun utter--guess-language (text)
  "Guess the language of TEXT: `ja', `ko', `zh' or `en'."
  (cond ((string-match-p "[぀-ヿ]" text) 'ja)
        ((string-match-p "[가-힯]" text) 'ko)
        ((string-match-p "[一-鿿]" text) 'zh)
        (t 'en)))

(defun utter--estimate-seconds (text speed)
  "Estimate how long TEXT takes to speak at SPEED."
  (let ((cjk (cl-count-if (lambda (c) (<= #x3040 c #xd7af)) text)))
    (/ (+ (/ (- (length text) cjk) 12.0) (/ cjk 4.5))
       (if (and (numberp speed) (> speed 0)) speed 1.0))))

(defun utter--short-name (text)
  "Return a short quoted name for TEXT from Lisp."
  (format "\"%s\"" (truncate-string-to-width
                    (car (split-string text "\n")) 24 nil nil "…")))

(defun utter--message-error (_item error)
  "Show ERROR with `message'."
  (message "utter: %s" error))

(defun utter--prune-cache ()
  "Keep the audio cache under its size limit."
  (when (fboundp 'utter-cache-prune)
    (with-demoted-errors "utter: cache prune failed: %S"
      (utter-cache-prune))))

(defun utter--notify (body)
  "Pass BODY to `utter-notify-function', if set."
  (when utter-notify-function
    (with-demoted-errors "utter: notify failed: %S"
      (funcall utter-notify-function "utter" body))))

(defun utter--buffer-text (beg end)
  "Return the text between BEG and END, ready for `utter-enqueue'.
When `utter-highlight' is on the text carries position tags so
the spoken text can be highlighted in the buffer."
  (let ((s (buffer-substring-no-properties beg end)))
    (if utter-highlight (utter--tag-positions s beg) s)))

;;;; Parameters

(defun utter--snapshot-params (params text)
  "Resolve PARAMS against the current options for TEXT.
Return a plist of request keys plus :cache-only."
  (cl-flet ((get (key default)
              (if (plist-member params key) (plist-get params key) default)))
    (let* ((backend (utter--resolve-backend (get :backend utter-backend)))
           (model (let ((m (or (get :model utter-model)
                               (utter--model-name (car (utter-backend-models backend))))))
                    (if (stringp m) (intern m) m)))
           (language (get :language utter-language))
           (lang (if (memq language '(nil auto)) (utter--guess-language text) language))
           ;; Only declared voice lists give a default; a fetched list
           ;; has no meaningful first entry.
           (declared (let ((mv (plist-get (utter--model-plist backend model) :voices))
                           (bv (utter-backend-voices backend)))
                       (cond ((consp mv) mv) ((consp bv) bv))))
           (voice (or (get :voice utter-voice)
                      (and (symbolp lang) (alist-get lang utter-voice-alist))
                      (utter--voice-name (car declared)))))
      (list :backend backend
            :model model
            :voice voice
            :speed (or (get :speed utter-speed) 1.0)
            :format (utter--format-symbol
                     (or (get :format utter-format)
                         (car (utter--formats backend model))))
            :language (unless (eq language 'auto) language)
            :instructions (get :instructions utter-instructions)
            :cache (get :cache t)
            :cache-only (plist-get params :cache-only)))))

(defun utter--params-args (params)
  "Return the `utter-request' keyword arguments in resolved PARAMS."
  (list :backend (plist-get params :backend)
        :model (plist-get params :model)
        :voice (plist-get params :voice)
        :speed (plist-get params :speed)
        :format (plist-get params :format)
        :language (plist-get params :language)
        :instructions (plist-get params :instructions)
        :cache (plist-get params :cache)))

(defun utter--request-args (item seg)
  "Return the `utter-request' keyword arguments for SEG of ITEM."
  (let* ((p (utter-item-params item))
         (backend (plist-get p :backend))
         (args (utter--params-args p)))
    (if (utter--capable-p backend (plist-get p :model) 'stitching)
        (append args (list :context (funcall utter--segment-context-function
                                             item (utter--segment-index seg))))
      args)))

(defun utter--segment-context (item index)
  "Return the text around segment INDEX of ITEM as (:previous :next)."
  (let ((segs (utter--item-segments item)))
    (list :previous (and (> index 0) (utter--segment-text (nth (1- index) segs)))
          :next (and-let* ((s (nth (1+ index) segs))) (utter--segment-text s)))))

;;;; Building an utterance

(defun utter--tag-at (string)
  "Return the first buffer position tag in STRING, or nil."
  (when-let* ((i (text-property-not-all 0 (length string) 'utter--pos nil string)))
    (get-text-property i 'utter--pos string)))

(defun utter--source-end (text)
  "Return the buffer position just after TEXT, from its position tags."
  (let ((i (length text)) found)
    (while (and (> i 0) (not found))
      (setq i (1- i))
      (when-let* ((pos (get-text-property i 'utter--pos text)))
        (setq found (+ pos (- (length text) i)))))
    found))

(defun utter--make-markers (buffer pieces text)
  "Return (BEG . END) marker pairs in BUFFER for PIECES of TEXT.
TEXT is the unprocessed text with position tags.  Return nil
when the tags did not survive preprocessing."
  (let* ((starts (mapcar #'utter--tag-at pieces))
         (end (utter--source-end text)))
    (when (and (car starts) end)
      (with-current-buffer buffer
        (cl-loop for (s . rest) on starts
                 for next = (cl-find-if #'identity rest)
                 collect (and s (cons (copy-marker s)
                                      (copy-marker (or next end)))))))))

(defun utter--build-item (text params)
  "Snapshot TEXT and PARAMS into a new `utter-item'."
  (let* ((buffer (let ((b (plist-get params :source-buffer)))
                   (and b (get-buffer b))))
         (resolved (utter--snapshot-params params text))
         (backend (plist-get resolved :backend))
         (processed (utter--preprocess text buffer))
         (pieces (utter--split processed
                               (or (utter-backend-max-chars backend)
                                   utter--default-max-chars)
                               (or (utter-backend-max-chars-unit backend) 'chars)))
         (plain (substring-no-properties processed))
         (from 0) (index -1))
    (unless pieces (user-error "Nothing to read"))
    (utter--make-item
     :id (cl-incf utter--item-counter)
     :text plain
     :status 'pending
     :params resolved
     :source-buffer buffer
     :source-name (or (plist-get params :source-name)
                      (and buffer (buffer-name buffer))
                      (utter--short-name plain))
     :markers (and utter-highlight buffer
                   (utter--make-markers buffer pieces text))
     :tick (and buffer (buffer-chars-modified-tick buffer))
     :created (current-time)
     :segments
     (mapcar (lambda (piece)
               (let* ((s (substring-no-properties piece))
                      (start (or (string-search s plain from) from)))
                 (setq from (+ start (length s)))
                 (utter--make-segment :index (cl-incf index) :text s
                                      :status 'pending
                                      :start start :end from)))
             pieces))))

;;;; Status

(defun utter--status ()
  "Return the queue status: idle, synthesizing, playing or paused."
  (let ((q utter--queue))
    (cond ((not (utter--qstate-current q)) 'idle)
          ((utter--qstate-paused q) 'paused)
          ((utter--qstate-process q) 'playing)
          (t 'synthesizing))))

(defun utter-active-p ()
  "Return non-nil unless the queue is idle."
  (not (eq (utter--status) 'idle)))

(defun utter--elapsed ()
  "Return the seconds played of the current utterance."
  (let ((q utter--queue))
    (+ (utter--qstate-played q)
       (if (and (utter--qstate-process q) (utter--qstate-seg-start q))
           (- (or (utter--qstate-pause-start q) (float-time))
              (utter--qstate-seg-start q)
              (utter--qstate-paused-total q))
         0))))

(defun utter--item-duration (item)
  "Return the total duration of ITEM when every part is known."
  (let ((ds (mapcar #'utter--segment-duration (utter--item-segments item))))
    (and ds (cl-every #'numberp ds) (apply #'+ ds))))

(defun utter-state ()
  "Return the queue state as a plist.
Keys: :status (idle, synthesizing, playing or paused) :item :index
:total :elapsed :duration :pending :backend :model :voice :rate
:source.  :index and :total count utterances."
  (let* ((q utter--queue)
         (item (utter--qstate-current q))
         (params (and item (utter-item-params item)))
         (backend (if item (plist-get params :backend) utter-backend))
         (run (utter--qstate-run q)))
    (list :status (utter--status)
          :item item
          :index (if item (1+ (or (cl-position item run) 0)) 0)
          :total (length run)
          :elapsed (and item (utter--elapsed))
          :duration (and item (utter--item-duration item))
          :pending (cl-count 'pending (utter--qstate-items q) :key #'utter-item-status)
          :backend (cond ((stringp backend) backend)
                         ((and backend (utter-backend-p backend))
                          (utter-backend-name backend)))
          :model (if item (plist-get params :model) utter-model)
          :voice (if item (plist-get params :voice) utter-voice)
          :rate (default-value 'utter-playback-rate)
          :source (and item (utter-item-source-name item)))))

(defun utter-state-string (&optional format)
  "Render the queue state with FORMAT, a `format-spec' string.
%s status, %i index and %n total (utterances), %b backend, %m
model, %v voice, %r rate, %t elapsed, %d duration, %S source.
FORMAT defaults to \"%s %i/%n\"."
  (let ((st (utter-state)))
    (cl-flet ((str (x) (if x (format "%s" x) "")))
      (format-spec
       (or format "%s %i/%n")
       `((?s . ,(symbol-name (plist-get st :status)))
         (?i . ,(number-to-string (plist-get st :index)))
         (?n . ,(number-to-string (plist-get st :total)))
         (?b . ,(str (plist-get st :backend)))
         (?m . ,(str (plist-get st :model)))
         (?v . ,(str (plist-get st :voice)))
         (?r . ,(format "%.1f" (plist-get st :rate)))
         (?t . ,(utter--format-duration (plist-get st :elapsed)))
         (?d . ,(if-let* ((d (plist-get st :duration)))
                    (utter--format-duration d)
                  "-:--"))
         (?S . ,(str (plist-get st :source))))))))

;;;; Queue contents

(defun utter--queue-items ()
  "Return the listed utterances: finished ones, the current one, then pending.
Within each group the queue order is kept."
  (let ((cur (utter--qstate-current utter--queue)))
    (cl-stable-sort (copy-sequence (utter--qstate-items utter--queue)) #'<
                    :key (lambda (item)
                           (cond ((eq item cur) 1)
                                 ((eq (utter-item-status item) 'pending) 2)
                                 (t 0))))))

(defun utter--drop-items (items)
  "Remove ITEMS from the queue, aborting their requests."
  (let ((q utter--queue))
    (dolist (item items)
      (utter--abort-item item)
      (utter--highlight-drop item))
    (setf (utter--qstate-items q) (cl-remove-if (lambda (i) (memq i items))
                                                (utter--qstate-items q))
          (utter--qstate-run q) (cl-remove-if (lambda (i) (memq i items))
                                              (utter--qstate-run q)))))

(defun utter--queue-remove (item)
  "Remove ITEM from the queue if it is pending.
Other utterances stay; a message says why."
  (if (and (eq (utter-item-status item) 'pending)
           (not (eq item (utter--qstate-current utter--queue))))
      (progn (utter--drop-items (list item))
             (message "utter: removed %s" (utter-item-source-name item))
             (utter--schedule))
    (message "utter: only pending utterances can be removed")))

;;;; Lighter

(defconst utter--lighter-construct '(:eval (utter--lighter-string))
  "The entry `utter' adds to `global-mode-string'.")

(defun utter--lighter-string ()
  "Return the lighter for the current state, or nil when idle."
  (when (and utter-lighter (utter-active-p))
    (let* ((status (utter--status))
           (code (utter--qstate-error-code utter--queue))
           (fmt (if (<= (length (utter--qstate-run utter--queue)) 1)
                    (replace-regexp-in-string "%i/%n" "" utter-lighter t t)
                  utter-lighter)))
      (concat (utter-state-string fmt)
              (pcase status ('synthesizing "⟳") ('paused "⏸") (_ ""))
              (when code (format "✗%s" (if (eq code t) "" code)))))))

(defun utter--update-lighter ()
  "Show the lighter in `global-mode-string' only while active."
  (let ((gms (if (listp global-mode-string)
                 global-mode-string
               (list global-mode-string))))
    (if (and utter-lighter (utter-active-p))
        (unless (member utter--lighter-construct gms)
          (setq global-mode-string (append gms (list utter--lighter-construct))))
      (when (member utter--lighter-construct gms)
        (setq global-mode-string (remove utter--lighter-construct gms)))))
  (force-mode-line-update t))

(defun utter--changed ()
  "Update indicators after a state change."
  (utter--update-lighter)
  (run-hooks 'utter--state-change-hook))

;;;; Highlight

(defvar utter--highlight-overlay nil
  "The overlay on the text being spoken, when highlighting.")

(defun utter--highlight-delete ()
  "Remove the highlight overlay."
  (when (overlayp utter--highlight-overlay)
    (delete-overlay utter--highlight-overlay))
  (setq utter--highlight-overlay nil))

(defun utter--highlight-drop (item)
  "Forget the markers of ITEM and remove its highlight."
  (when-let* ((buf (utter-item-source-buffer item)))
    (when (and (overlayp utter--highlight-overlay)
               (eq (overlay-buffer utter--highlight-overlay) buf))
      (utter--highlight-delete)))
  (dolist (m (utter-item-markers item))
    (when m (set-marker (car m) nil) (set-marker (cdr m) nil)))
  (setf (utter-item-markers item) nil))

(defun utter--highlight-stale-p (item)
  "Return non-nil if the source of ITEM changed since it was captured."
  (let ((buf (utter-item-source-buffer item)))
    (or (not (buffer-live-p buf))
        (/= (buffer-chars-modified-tick buf) (utter-item-tick item)))))

(defun utter--highlight-after-change (&rest _)
  "Drop highlights of utterances whose source buffer was edited."
  (dolist (item (utter--qstate-items utter--queue))
    (when (and (utter-item-markers item)
               (eq (utter-item-source-buffer item) (current-buffer))
               (utter--highlight-stale-p item))
      (utter--highlight-drop item)))
  (unless (cl-some (lambda (item) (and (utter-item-markers item)
                                       (eq (utter-item-source-buffer item)
                                           (current-buffer))))
                   (utter--qstate-items utter--queue))
    (remove-hook 'after-change-functions #'utter--highlight-after-change t)))

(defun utter--highlight-progress (item _start _end)
  "Move the highlight to the part of ITEM being spoken."
  (when (utter-item-markers item)
    (if (utter--highlight-stale-p item)
        (utter--highlight-drop item)
      (let* ((m (nth (utter--item-position item) (utter-item-markers item)))
             (buf (utter-item-source-buffer item)))
        (if (not m)
            (utter--highlight-delete)
          (if (overlayp utter--highlight-overlay)
              (move-overlay utter--highlight-overlay (car m) (cdr m) buf)
            (setq utter--highlight-overlay (make-overlay (car m) (cdr m) buf))
            (overlay-put utter--highlight-overlay 'face 'utter-highlight)
            (overlay-put utter--highlight-overlay 'utter t))
          (with-current-buffer buf
            (add-hook 'after-change-functions #'utter--highlight-after-change nil t))
          (when utter-highlight-follow
            (dolist (w (get-buffer-window-list buf nil t))
              (unless (pos-visible-in-window-p (car m) w)
                (set-window-point w (car m))))))))))

;;;; Requests

(defun utter--retryable-p (code)
  "Return non-nil if HTTP status CODE is worth one retry."
  (and (integerp code) (or (= code 429) (<= 500 code 599))))

(defun utter--backend-name (item)
  "Return the backend name of ITEM."
  (let ((b (plist-get (utter-item-params item) :backend)))
    (if (utter-backend-p b) (utter-backend-name b) (format "%s" b))))

(defun utter--segment-failed (item seg error &optional code)
  "Mark SEG of ITEM as failed with ERROR and HTTP status CODE."
  (setf (utter--segment-status seg) 'error
        (utter--segment-error seg) error
        (utter--segment-request seg) nil
        (utter--qstate-error-code utter--queue) (or code t))
  (let ((text (format "%s%s: %s" (utter--backend-name item)
                      (if code (format " %s" code) "") error)))
    (run-hook-with-args 'utter-error-functions item text)
    (utter--notify text))
  (utter--schedule))

(defun utter--live-item-p (item)
  "Return non-nil if ITEM is current or pending in the queue."
  (and (memq item (utter--qstate-items utter--queue))
       (memq (utter-item-status item) '(pending playing paused))))

(defun utter--segment-callback (item seg audio info)
  "Handle the `utter-request' result AUDIO and INFO for SEG of ITEM."
  (when (and (eq (utter--segment-status seg) 'synthesizing)
             (utter--live-item-p item))
    (setf (utter--segment-request seg) nil)
    (cond
     ((stringp audio)
      (setf (utter--segment-file seg) audio
            (utter--segment-format seg)
            (utter--format-symbol (or (plist-get info :format)
                                      (file-name-extension audio)))
            (utter--segment-duration seg) (plist-get info :duration)
            (utter--segment-status seg) 'ready))
     ((eq audio 'abort)
      (utter--segment-failed item seg "request aborted"))
     (t
      (let ((code (plist-get info :http-status))
            (error (or (plist-get info :error) "request failed")))
        (if (and (utter--retryable-p code) (< (utter--segment-retries seg) 1))
            (let ((delay utter--retry-delay))
              (cl-incf (utter--segment-retries seg))
              (setf (utter--segment-status seg) 'retry)
              (message "utter: %s %s, retrying in %s s"
                       (utter--backend-name item) code delay)
              (push (run-at-time delay nil #'utter--retry seg)
                    (utter--qstate-timers utter--queue)))
          (utter--segment-failed item seg error code)))))
    (utter--schedule)))

(defun utter--retry (seg)
  "Make SEG eligible for another request."
  (when (eq (utter--segment-status seg) 'retry)
    (setf (utter--segment-status seg) 'pending)
    (utter--schedule)))

(defun utter--request-segment (item seg)
  "Start synthesizing SEG of ITEM."
  (setf (utter--segment-status seg) 'synthesizing)
  (condition-case err
      (let ((req (apply #'utter-request (utter--segment-text seg)
                        :callback (lambda (audio info)
                                    (utter--segment-callback item seg audio info))
                        (utter--request-args item seg))))
        (when (eq (utter--segment-status seg) 'synthesizing)
          (setf (utter--segment-request seg) req)))
    (error
     (when (eq (utter--segment-status seg) 'synthesizing)
       (utter--segment-failed item seg (error-message-string err))))))

(defun utter--abort-item (item)
  "Abort the in-flight requests and retries of ITEM."
  (dolist (seg (utter--item-segments item))
    (pcase (utter--segment-status seg)
      ('synthesizing
       (let ((req (utter--segment-request seg)))
         (setf (utter--segment-status seg) 'pending
               (utter--segment-request seg) nil)
         (when req (ignore-errors (utter-abort req)))))
      ('retry (setf (utter--segment-status seg) 'pending)))))

(defun utter--prefetch ()
  "Request segments ahead of playback, within the configured limits."
  (let* ((q utter--queue)
         (current (utter--qstate-current q))
         (window-size (1+ (max 0 utter-prefetch-depth)))
         (max-flight (max 1 utter-max-concurrent-requests))
         (in-flight 0)
         (window 0))
    (dolist (item (utter--qstate-items q))
      (dolist (seg (utter--item-segments item))
        ;; A segment waiting to retry keeps its slot.
        (when (memq (utter--segment-status seg) '(synthesizing retry))
          (cl-incf in-flight))))
    (catch 'full
      (dolist (item (cons current
                          (cl-remove-if-not
                           (lambda (i) (and (not (eq i current))
                                            (eq (utter-item-status i) 'pending)))
                           (utter--qstate-items q))))
        (when item
          (dolist (seg (nthcdr (if (eq item current) (utter--item-position item) 0)
                               (utter--item-segments item)))
            (when (>= window window-size) (throw 'full nil))
            (unless (eq (utter--segment-status seg) 'error)
              (cl-incf window)
              (when (eq (utter--segment-status seg) 'pending)
                (when (>= in-flight max-flight) (throw 'full nil))
                (utter--request-segment item seg)
                (when (eq (utter--segment-status seg) 'synthesizing)
                  (cl-incf in-flight))))))))))

;;;; Playback

(defun utter--run-index (item)
  "Return the 1-based index of ITEM among the utterances of this run."
  (1+ (or (cl-position item (utter--qstate-run utter--queue)) 0)))

(defun utter--start-item (item)
  "Make ITEM the current utterance."
  (let ((q utter--queue))
    (setf (utter--qstate-current q) item
          (utter--qstate-played q) 0
          (utter--qstate-error-code q) nil
          (utter-item-status item) (if (utter--qstate-paused q) 'paused 'playing))
    (unless (memq item (utter--qstate-run q))
      (setf (utter--qstate-run q) (append (utter--qstate-run q) (list item))))))

(defun utter--account-segment ()
  "Add the play time of the current segment to the utterance total."
  (let ((q utter--queue))
    (when (utter--qstate-seg-start q)
      (setf (utter--qstate-played q) (utter--elapsed)
            (utter--qstate-seg-start q) nil
            (utter--qstate-pause-start q) nil
            (utter--qstate-paused-total q) 0))))

(defun utter--finish-item (item)
  "Finish the current utterance ITEM."
  (let* ((q utter--queue)
         (segs (utter--item-segments item))
         (status (if (cl-every (lambda (s) (eq (utter--segment-status s) 'error)) segs)
                     'error 'done))
         (elapsed (utter--elapsed)))
    (setf (utter-item-status item) status
          (utter--qstate-current q) nil)
    (utter--highlight-delete)
    (when (eq status 'done)
      (message "utter: finished %s (%s)" (utter-item-source-name item)
               (utter--format-duration elapsed))
      (utter--notify (format "Finished %s" (utter-item-source-name item))))
    (run-hook-with-args 'utter-item-finished-functions item status)))

(defun utter--play-segment (item seg)
  "Start the player on SEG of ITEM."
  (let* ((q utter--queue)
         (player (utter--select-player (utter--segment-format seg)))
         (argv (and player
                    (funcall (utter-player-command player) (utter--segment-file seg)
                             (default-value 'utter-playback-rate))))
         (proc (and argv
                    (condition-case err
                        (make-process :name "utter-player" :command argv
                                      :buffer nil :noquery t
                                      :connection-type 'pipe
                                      :sentinel #'utter--player-sentinel)
                      (error (utter--segment-failed
                              item seg (format "cannot start player: %s"
                                               (error-message-string err)))
                             nil)))))
    (cond
     (proc
      (process-put proc 'utter-player player)
      (process-put proc 'utter-segment seg)
      (setf (utter--segment-status seg) 'playing
            (utter--qstate-process q) proc
            (utter--qstate-seg-start q) (float-time)
            (utter--qstate-pause-start q) nil
            (utter--qstate-paused-total q) 0)
      (unless (eq (utter--qstate-announced q) item)
        (setf (utter--qstate-announced q) item)
        (let ((n (length (utter--qstate-run q))))
          (message "utter: playing %s%s" (utter-item-source-name item)
                   (if (> n 1) (format " (%d/%d)" (utter--run-index item) n) ""))))
      (run-hook-with-args 'utter-progress-functions item
                          (utter--segment-start seg) (utter--segment-end seg)))
     ((not player)
      (utter--segment-failed
       item seg (format "no player for %s audio; install ffplay or mpv, or set `utter-player'"
                        (or (utter--segment-format seg) "this")))))
    proc))

(defun utter--player-sentinel (proc _event)
  "Advance the queue when the player PROC exits."
  (when (and (memq (process-status proc) '(exit signal))
             (not (process-get proc 'utter-stopped))
             (eq proc (utter--qstate-process utter--queue)))
    (let ((seg (process-get proc 'utter-segment))
          (item (utter--qstate-current utter--queue)))
      (utter--account-segment)
      (setf (utter--qstate-process utter--queue) nil
            (utter--segment-status seg) 'done)
      (when (and (eq (process-status proc) 'exit)
                 (/= (process-exit-status proc) 0)
                 (not (process-get proc 'utter-was-paused))
                 item)
        (run-hook-with-args 'utter-error-functions item
                            (format "player exited with status %d"
                                    (process-exit-status proc))))
      (when item (cl-incf (utter--item-position item)))
      (utter--schedule))))

(defun utter--kill-player ()
  "Stop the player without advancing the queue."
  (let ((q utter--queue))
    (when-let* ((proc (utter--qstate-process q)))
      (process-put proc 'utter-stopped t)
      (let ((seg (process-get proc 'utter-segment)))
        (when (and seg (eq (utter--segment-status seg) 'playing))
          (setf (utter--segment-status seg) 'ready)))
      (utter--account-segment)
      (setf (utter--qstate-process q) nil)
      (ignore-errors
        (funcall (or (utter-player-stop (process-get proc 'utter-player))
                     #'delete-process)
                 proc)))))

(defun utter--go-idle ()
  "Enter the idle state."
  (let ((q utter--queue))
    (setf (utter--qstate-paused q) nil
          (utter--qstate-run q) nil
          (utter--qstate-announced q) nil)
    (when (utter--qstate-active q)
      (setf (utter--qstate-active q) nil)
      (utter--highlight-delete)
      (run-hooks 'utter-queue-finished-hook))))

(defun utter--advance ()
  "Pick the current utterance and start playback when audio is ready."
  (let ((q utter--queue) (again t))
    (while again
      (setq again nil)
      (let ((item (utter--qstate-current q)))
        (unless item
          (when (setq item (cl-find 'pending (utter--qstate-items q)
                                    :key #'utter-item-status))
            (utter--start-item item)))
        (cond
         ((null item) (utter--go-idle))
         ((utter--qstate-process q))
         (t
          (setf (utter--qstate-active q) t)
          (let ((seg (nth (utter--item-position item) (utter--item-segments item))))
            (pcase (and seg (utter--segment-status seg))
              ('nil (utter--finish-item item) (setq again t))
              ('error (cl-incf (utter--item-position item)) (setq again t))
              ((or 'ready 'done)
               (cond ((plist-get (utter-item-params item) :cache-only)
                      (setf (utter--segment-status seg) 'done)
                      (cl-incf (utter--item-position item))
                      (setq again t))
                     ((utter--qstate-paused q))
                     ((not (utter--play-segment item seg))
                      (setq again t))))))))))))

(defvar utter--scheduling nil "Non-nil while `utter--schedule' runs.")
(defvar utter--schedule-again nil "Non-nil when a nested schedule was asked for.")

(defun utter--schedule ()
  "Bring playback and prefetch up to date with the queue."
  (if utter--scheduling
      (setq utter--schedule-again t)
    (let ((utter--scheduling t))
      (setq utter--schedule-again t)
      (while utter--schedule-again
        (setq utter--schedule-again nil)
        (utter--advance)
        (utter--prefetch))))
  (unless utter--scheduling
    (utter--changed)))

;;;; Resetting items

(defun utter--reset-item (item)
  "Make ITEM playable again from its start."
  (utter--abort-item item)
  (dolist (seg (utter--item-segments item))
    (setf (utter--segment-retries seg) 0
          (utter--segment-status seg)
          (if (and (utter--segment-file seg)
                   (file-exists-p (utter--segment-file seg)))
              'ready
            'pending)))
  (setf (utter--item-position item) 0
        (utter-item-status item) 'pending))

(defun utter--interrupt-item (item)
  "Mark ITEM interrupted and abort its requests."
  (let ((q utter--queue))
    (when (eq item (utter--qstate-current q))
      (utter--kill-player)
      (utter--highlight-delete)
      (setf (utter--qstate-current q) nil)))
  (utter--abort-item item)
  (setf (utter-item-status item) 'interrupted)
  (run-hook-with-args 'utter-item-finished-functions item 'interrupted))

(defun utter--interrupt-all ()
  "Interrupt the current and every pending utterance."
  (let ((q utter--queue))
    (when-let* ((cur (utter--qstate-current q)))
      (utter--interrupt-item cur))
    (dolist (item (utter--qstate-items q))
      (when (eq (utter-item-status item) 'pending)
        (utter--interrupt-item item)))
    (setf (utter--qstate-paused q) nil)))

(defun utter--reset ()
  "Throw away the queue: stop playback, requests and timers."
  (let ((q utter--queue))
    (utter--kill-player)
    (mapc #'cancel-timer (utter--qstate-timers q))
    (dolist (item (utter--qstate-items q))
      (utter--abort-item item)
      (utter--highlight-drop item)))
  (utter--highlight-delete)
  (setq utter--queue (utter--make-qstate))
  (utter--update-lighter))

;;;; Entry points

;;;###autoload (autoload 'utter-enqueue "utter")
(defun utter-enqueue (text &rest params)
  "Queue TEXT to be spoken after what is already queued.
PARAMS are the keyword arguments of `utter-request' (:backend
:model :voice :speed :format :language :instructions :cache),
plus :source-buffer and :source-name, and :cache-only to
synthesize without playing.  Options not given are read now, so
later changes do not affect this utterance.  Return the new
`utter-item'."
  (let* ((item (utter--build-item text params))
         (q utter--queue)
         (speed (plist-get (utter-item-params item) :speed)))
    (utter--prune-cache)
    (setf (utter--qstate-items q) (append (utter--qstate-items q) (list item)))
    (when (utter-active-p)
      (setf (utter--qstate-run q) (append (utter--qstate-run q) (list item))))
    (run-hook-with-args 'utter-enqueue-hook item)
    (message "utter: queued %d chars (~%d s) from %s"
             (length (utter-item-text item))
             (max 1 (round (utter--estimate-seconds (utter-item-text item) speed)))
             (utter-item-source-name item))
    (utter--schedule)
    item))

;;;###autoload (autoload 'utter-interrupt "utter")
(defun utter-interrupt (text &rest params)
  "Stop what is playing and speak TEXT now.
The current and pending utterances are marked `interrupted'; they
stay listed and can be replayed.  PARAMS are as for
`utter-enqueue'.  Return the new `utter-item'."
  (let ((item (utter--build-item text params))
        (q utter--queue))
    (utter--interrupt-all)
    (setf (utter--qstate-items q) (append (utter--qstate-items q) (list item))
          (utter--qstate-run q) (list item))
    (run-hook-with-args 'utter-enqueue-hook item)
    (utter--schedule)
    item))

;;;; Commands

(defun utter--require-active ()
  "Signal a `user-error' when nothing is queued."
  (unless (utter-active-p) (user-error "Nothing is playing")))

;;;###autoload (autoload 'utter-pause "utter" nil t)
(defun utter-pause ()
  "Pause playback.  Synthesis ahead of playback continues."
  (interactive)
  (utter--require-active)
  (let ((q utter--queue))
    (unless (utter--qstate-paused q)
      (setf (utter--qstate-paused q) t)
      (when-let* ((proc (utter--qstate-process q)))
        (process-put proc 'utter-was-paused t)
        (funcall (utter-player-pause (process-get proc 'utter-player)) proc)
        (setf (utter--qstate-pause-start q) (float-time)))
      (setf (utter-item-status (utter--qstate-current q)) 'paused)
      (message "utter: paused")
      (utter--changed))))

;;;###autoload (autoload 'utter-resume "utter" nil t)
(defun utter-resume ()
  "Resume paused playback."
  (interactive)
  (utter--require-active)
  (let ((q utter--queue))
    (when (utter--qstate-paused q)
      (setf (utter--qstate-paused q) nil)
      (when-let* ((proc (utter--qstate-process q)))
        (funcall (utter-player-resume (process-get proc 'utter-player)) proc)
        (when (utter--qstate-pause-start q)
          (cl-incf (utter--qstate-paused-total q)
                   (- (float-time) (utter--qstate-pause-start q))))
        (setf (utter--qstate-pause-start q) nil))
      (setf (utter-item-status (utter--qstate-current q)) 'playing)
      (message "utter: resumed")
      (utter--schedule))))

;;;###autoload (autoload 'utter-toggle-pause "utter" nil t)
(defun utter-toggle-pause ()
  "Pause or resume playback."
  (interactive)
  (if (utter--qstate-paused utter--queue) (utter-resume) (utter-pause)))

;;;###autoload (autoload 'utter-next "utter" nil t)
(defun utter-next (&optional n)
  "Skip to the Nth next utterance (default 1).
Skipped utterances are marked `interrupted'."
  (interactive "p")
  (utter--require-active)
  (let ((q utter--queue))
    (dotimes (_ (max 1 (or n 1)))
      (when-let* ((item (or (utter--qstate-current q)
                            (cl-find 'pending (utter--qstate-items q)
                                     :key #'utter-item-status))))
        (utter--interrupt-item item)))
    (setf (utter--qstate-paused q) nil)
    (utter--schedule)))

;;;###autoload (autoload 'utter-previous "utter" nil t)
(defun utter-previous (&optional n)
  "Go back N utterances (default 1) and play from there.
At the first utterance, restart it.  When idle, replay the last."
  (interactive "p")
  (let* ((q utter--queue)
         (items (utter--qstate-items q))
         (cur (utter--qstate-current q))
         (idx (if cur (cl-position cur items) (length items)))
         (target (and items (nth (max 0 (- idx (max 1 (or n 1)))) items))))
    (unless target (user-error "No previous utterance"))
    (utter--restart-from target)))

(defun utter--restart-from (target)
  "Play TARGET from its start, then what follows it in the queue."
  (let* ((q utter--queue)
         (cur (utter--qstate-current q)))
    (when cur
      (utter--kill-player)
      (utter--highlight-delete)
      (setf (utter--qstate-current q) nil)
      (utter--reset-item cur))
    (utter--reset-item target)
    (unless (memq target (utter--qstate-run q))
      (setf (utter--qstate-run q) (cons target (utter--qstate-run q))))
    (setf (utter--qstate-paused q) nil)
    (utter--schedule)))

;;;###autoload (autoload 'utter-stop "utter" nil t)
(defun utter-stop ()
  "Stop playback and synthesis; mark everything queued `interrupted'."
  (interactive)
  (utter--interrupt-all)
  (utter--schedule))

;;;###autoload (autoload 'utter-clear "utter" nil t)
(defun utter-clear (&optional arg)
  "Drop pending utterances; the current one finishes.
With prefix ARG, also drop finished ones."
  (interactive "P")
  (let* ((q utter--queue)
         (cur (utter--qstate-current q))
         (drop (cl-remove-if-not
                (lambda (item)
                  (and (not (eq item cur))
                       (or (eq (utter-item-status item) 'pending)
                           (and arg (memq (utter-item-status item)
                                          '(done error interrupted))))))
                (utter--qstate-items q))))
    (utter--drop-items drop)
    (message "utter: cleared %d utterance%s" (length drop)
             (if (= (length drop) 1) "" "s"))
    (utter--schedule)))

(defun utter--set-rate (rate)
  "Set `utter-playback-rate' to RATE, clamped and rounded."
  (set-default 'utter-playback-rate
               (/ (round (* 10 (min 3.0 (max 0.5 rate)))) 10.0))
  (message "utter: rate %sx" (utter--rate-string utter-playback-rate))
  (utter--changed))

;;;###autoload (autoload 'utter-rate-up "utter" nil t)
(defun utter-rate-up ()
  "Play 0.1 faster, from the next part of the utterance on."
  (interactive)
  (utter--set-rate (+ (default-value 'utter-playback-rate) 0.1)))

;;;###autoload (autoload 'utter-rate-down "utter" nil t)
(defun utter-rate-down ()
  "Play 0.1 slower, from the next part of the utterance on."
  (interactive)
  (utter--set-rate (- (default-value 'utter-playback-rate) 0.1)))

(defun utter--last-finished-item ()
  "Return the most recent finished or interrupted utterance."
  (or (cl-find-if (lambda (item)
                    (memq (utter-item-status item) '(done error interrupted)))
                  (reverse (utter--qstate-items utter--queue)))
      (user-error "Nothing to replay")))

;;;###autoload (autoload 'utter-replay-item "utter" nil t)
(defun utter-replay-item (item)
  "Queue ITEM again; audio already synthesized is reused.
Interactively, replay the most recent finished utterance."
  (interactive (list (utter--last-finished-item)))
  (let ((q utter--queue))
    (if (eq item (utter--qstate-current q))
        (utter--restart-from item)
      (utter--reset-item item)
      (setf (utter--qstate-items q)
            (append (delq item (utter--qstate-items q)) (list item)))
      (when (utter-active-p)
        (setf (utter--qstate-run q)
              (append (delq item (utter--qstate-run q)) (list item))))
      (utter--schedule))))

(provide 'utter-queue)
;;; utter-queue.el ends here
