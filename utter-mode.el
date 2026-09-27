;;; utter-mode.el --- Header line, local keys and queue buffer for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `utter-mode' is a buffer-local minor mode with no lighter.  It shows
;; the playback state in the header line and gives the buffer local
;; playback keys: single keys in read-only buffers, the same commands
;; under \\`C-c C-o' elsewhere.  It turns itself on only in the queue
;; buffer, `*utter-queue*', which `utter-queue' opens.  The package binds
;; no global keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'utter)

;;;; Engine symbols (defined by ENGINE and CORE)

(defvar utter-playback-rate)
(defvar utter-progress-functions)
(defvar utter-item-finished-functions)
(defvar utter-queue-finished-hook)
(defvar utter-enqueue-hook)

(declare-function utter-state "utter-queue" ())
(declare-function utter-toggle-pause "utter-queue" ())
(declare-function utter-next "utter-queue" (&optional n))
(declare-function utter-previous "utter-queue" (&optional n))
(declare-function utter-rate-up "utter-queue" ())
(declare-function utter-rate-down "utter-queue" ())
(declare-function utter-stop "utter-queue" ())
(declare-function utter-clear "utter-queue" (&optional arg))
(declare-function utter-replay-item "utter-queue" (item))
(declare-function utter--queue-items "utter-queue" ())
(declare-function utter--queue-remove "utter-queue" (item))
(declare-function utter--item-duration "utter-queue" (item))
(declare-function utter-item-status "utter-queue" (item))
(declare-function utter-item-text "utter-queue" (item))
(declare-function utter-item-params "utter-queue" (item))
(declare-function utter-item-source-buffer "utter-queue" (item))
(declare-function utter-item-source-name "utter-queue" (item))
(declare-function utter-backend-name "utter-core" (backend))
(declare-function utter-menu "utter-transient" ())

(unless (fboundp 'utter-menu)
  (autoload 'utter-menu "utter-transient" nil t))

;;;; Formatting helpers

(defun utter-mode--format-time (seconds)
  "Format SECONDS as M:SS, or H:MM:SS from one hour; nil stays nil."
  (when seconds
    (let* ((s (round seconds))
           (h (/ s 3600))
           (m (/ (% s 3600) 60)))
      (if (> h 0)
          (format "%d:%02d:%02d" h m (% s 60))
        (format "%d:%02d" m (% s 60))))))

(defun utter-mode--format-rate (rate)
  "Format the playback RATE as \"1.0x\" or \"1.15x\"; nil means 1.0."
  (let ((s (format "%.2f" (or rate 1.0))))
    (concat (if (string-suffix-p "0" s) (substring s 0 -1) s) "x")))

(defun utter-mode--backend-name (backend)
  "Return the display name of BACKEND, a backend object, string or symbol."
  (cond ((null backend) nil)
        ((stringp backend) backend)
        ((symbolp backend) (symbol-name backend))
        (t (utter-backend-name backend))))

(defconst utter-mode--status-labels
  '((done         . "✓ played")
    (playing      . "▶ playing")
    (paused       . "⏸ paused")
    (synthesizing . "⟳ synth")
    (pending      . "· pending")
    (error        . "✗ error")
    (interrupted  . "⏹ interrupted"))
  "Glyph and word shown for each utterance status.")

(defun utter-mode--status-label (status)
  "Return the glyph and word for STATUS."
  (or (alist-get status utter-mode--status-labels)
      (format "? %s" status)))

(defun utter-mode--glyph (status)
  "Return the one-character glyph for STATUS."
  (car (split-string (utter-mode--status-label status))))

;;;; Header line

(defconst utter-mode--header-line-format '(:eval (utter--header-line))
  "The `header-line-format' that `utter-mode' installs.")

(defun utter-mode--hint (label command help)
  "Return LABEL as a header-line button that runs COMMAND.
HELP is the button's help echo."
  (buttonize label (lambda (_) (funcall command)) nil help))

(defun utter-mode--hints (status)
  "Return the key hints for the header line; STATUS is the player status."
  (string-join
   (list (utter-mode--hint (if (eq status 'paused) "SPC resume" "SPC pause")
                           #'utter-toggle-pause "Pause or resume playback")
         (utter-mode--hint "n/p utterance" #'utter-next
                           "Next or previous utterance")
         (utter-mode--hint "+/- rate" #'utter-rate-up
                           "Raise or lower the playback rate")
         (utter-mode--hint "q stop" #'utter-stop "Stop all playback"))
   "  "))

(defun utter--header-line ()
  "Return the `utter-mode' header line for the current state.
Shows the status glyph, the source and position in the queue, the
elapsed and total time, backend and voice, rate and key hints."
  (let* ((state (utter-state))
         (status (plist-get state :status)))
    (if (memq status '(nil idle))
        "utter · idle"
      (let* ((elapsed (utter-mode--format-time (plist-get state :elapsed)))
             (duration (utter-mode--format-time (plist-get state :duration)))
             (voice (plist-get state :voice)))
        (concat
         (utter-mode--glyph status) " utter · "
         (or (plist-get state :source) "utterance")
         (format " %s/%s" (or (plist-get state :index) 1)
                 (or (plist-get state :total) 1))
         (when elapsed (format " · %s/%s" elapsed (or duration "--")))
         " · " (or (utter-mode--backend-name (plist-get state :backend)) "?")
         (when voice (concat " " voice))
         " · " (utter-mode--format-rate
                (or (plist-get state :rate) utter-playback-rate))
         " · " (unless buffer-read-only "C-c C-o: ")
         (utter-mode--hints status))))))

;;;; Keymap

(defvar-keymap utter-mode-command-map
  :prefix 'utter-mode-command-map
  :doc "Playback commands of `utter-mode'."
  "SPC" #'utter-toggle-pause
  "n"   #'utter-next
  "p"   #'utter-previous
  "+"   #'utter-rate-up
  "-"   #'utter-rate-down
  "q"   #'utter-stop
  "x"   #'utter-clear
  "m"   #'utter-menu
  "Q"   #'utter-queue
  "RET" #'utter-visit-source)

(defun utter-mode--when-read-only (command)
  "Return COMMAND when the current buffer is read-only, else nil."
  (and buffer-read-only command))

(defvar utter-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-o" 'utter-mode-command-map)
    (map-keymap (lambda (event command)
                  (define-key map (vector event)
                              `(menu-item "" ,command
                                          :filter utter-mode--when-read-only)))
                utter-mode-command-map)
    map)
  "Keymap of `utter-mode'.
The keys of `utter-mode-command-map' work as single keys in read-only
buffers, and after the prefix
\\<utter-mode-map>\\[utter-mode-command-map] everywhere.")

;;;; Refreshing

(defconst utter-mode--hooks
  '(utter-progress-functions utter-item-finished-functions
    utter-queue-finished-hook utter-enqueue-hook)
  "Engine hooks after which the header line and the queue buffer update.")

(defun utter-mode--refresh (&rest _)
  "Redraw header lines and the queue buffer after an engine event."
  (force-mode-line-update t)
  (utter-queue--refresh))

(defun utter-mode--add-hooks ()
  "Install `utter-mode--refresh' on the engine hooks."
  (dolist (hook utter-mode--hooks)
    (add-hook hook #'utter-mode--refresh)))

(defun utter-mode--remove-hooks-if-unused ()
  "Remove `utter-mode--refresh' when no buffer uses `utter-mode'."
  (unless (cl-some (lambda (buf) (buffer-local-value 'utter-mode buf))
                   (buffer-list))
    (dolist (hook utter-mode--hooks)
      (remove-hook hook #'utter-mode--refresh))))

;;;; The minor mode

(defvar-local utter-mode--saved-header-line nil
  "The `header-line-format' in effect before `utter-mode' was enabled.")

;;;###autoload
(define-minor-mode utter-mode
  "Show utter's playback state in the header line and add playback keys.

The header line shows what is being read, the position in the
queue, elapsed and total time, backend, voice and rate.  In a
read-only buffer the keys below work as single keys; in other
buffers they follow the prefix \\<utter-mode-map>\\[utter-mode-command-map].

\\{utter-mode-command-map}"
  :lighter nil
  :keymap utter-mode-map
  (if utter-mode
      (progn
        (unless (equal header-line-format utter-mode--header-line-format)
          (setq utter-mode--saved-header-line header-line-format))
        (setq header-line-format utter-mode--header-line-format)
        (add-hook 'kill-buffer-hook #'utter-mode--on-kill nil t)
        (utter-mode--add-hooks))
    (when (equal header-line-format utter-mode--header-line-format)
      (setq header-line-format utter-mode--saved-header-line))
    (kill-local-variable 'utter-mode--saved-header-line)
    (remove-hook 'kill-buffer-hook #'utter-mode--on-kill t)
    (utter-mode--remove-hooks-if-unused)))

(defun utter-mode--on-kill ()
  "Drop the engine hooks when the last `utter-mode' buffer is killed."
  (setq utter-mode nil)
  (utter-mode--remove-hooks-if-unused))

;;;; Queue buffer

(defconst utter-queue-buffer-name "*utter-queue*"
  "Name of the queue buffer.")

(defun utter-mode--items ()
  "Return all utterances in the queue, in order."
  (and (fboundp 'utter--queue-items) (utter--queue-items)))

(defun utter-queue--first-words (text)
  "Return the start of TEXT on one line, at most 40 columns."
  (truncate-string-to-width
   (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))
   40 nil nil "…"))

(defun utter-queue--row (item index state)
  "Return the row vector for ITEM at 1-based INDEX, given engine STATE."
  (let* ((current (eq item (plist-get state :item)))
         (status (if (and current
                          (memq (plist-get state :status)
                                '(paused synthesizing)))
                     (plist-get state :status)
                   (utter-item-status item)))
         (params (utter-item-params item))
         (backend (utter-mode--backend-name (plist-get params :backend)))
         (voice (plist-get params :voice))
         (source (utter-item-source-name item))
         (buffer (utter-item-source-buffer item))
         (elapsed (and current
                       (utter-mode--format-time (plist-get state :elapsed))))
         (duration (utter-mode--format-time
                    (if current
                        (plist-get state :duration)
                      (and (fboundp 'utter--item-duration)
                           (utter--item-duration item))))))
    (vector (utter-mode--status-label status)
            (number-to-string index)
            (concat (or backend "?") (and voice (concat ":" voice)))
            (utter-queue--first-words (utter-item-text item))
            (cond (elapsed (concat elapsed "/" (or duration "--")))
                  ((and duration (not current)) duration)
                  (t "--"))
            (or source
                (and (buffer-live-p buffer) (buffer-name buffer))
                ""))))

(defun utter-queue--entries ()
  "Return `tabulated-list-entries' for the queue buffer.
One row per utterance; the entry id is the item itself."
  (let ((state (utter-state))
        (index 0))
    (mapcar (lambda (item)
              (list item (utter-queue--row item (cl-incf index) state)))
            (utter-mode--items))))

(defun utter-queue--refresh ()
  "Redraw the queue buffer if it exists."
  (when-let* ((buf (get-buffer utter-queue-buffer-name)))
    (with-current-buffer buf
      (when (derived-mode-p 'utter-queue-mode)
        (tabulated-list-print t)))))

(defun utter-queue--item-at-point ()
  "Return the utterance on the current line, or signal a `user-error'."
  (or (and (derived-mode-p 'utter-queue-mode) (tabulated-list-get-id))
      (user-error "No utterance on this line")))

(defun utter-visit-source ()
  "Visit the source buffer of the utterance on this line of the queue.
Outside the queue buffer, only show a message and return it."
  (interactive)
  (if-let* ((item (and (derived-mode-p 'utter-queue-mode)
                       (tabulated-list-get-id))))
      (let ((buf (utter-item-source-buffer item)))
        (when (stringp buf) (setq buf (get-buffer buf)))
        (if (buffer-live-p buf)
            (pop-to-buffer buf)
          (message "utter: source %s is no longer open"
                   (or (utter-item-source-name item) "buffer"))))
    (message "utter: no utterance here; use RET in the queue buffer")))

(defun utter-queue-remove ()
  "Remove the pending utterance on this line from the queue."
  (interactive)
  (let ((item (utter-queue--item-at-point)))
    (unless (eq (utter-item-status item) 'pending)
      (user-error "Only pending utterances can be removed"))
    (utter--queue-remove item)
    (utter-queue--refresh)))

(defun utter-queue-replay ()
  "Play the utterance on this line again."
  (interactive)
  (utter-replay-item (utter-queue--item-at-point))
  (utter-queue--refresh))

(defvar-keymap utter-queue-mode-map
  :doc "Keymap of `utter-queue-mode'."
  :parent tabulated-list-mode-map
  "RET" #'utter-visit-source
  "o"   #'utter-visit-source
  "d"   #'utter-queue-remove
  "r"   #'utter-queue-replay)

(define-derived-mode utter-queue-mode tabulated-list-mode "Utter-Queue"
  "Major mode for the utter queue, one row per utterance.

Columns: status, position, backend and voice, first words,
elapsed and total time, source.  Turns on `utter-mode', whose
header line replaces the column header; the column names are the
first line of the buffer.

\\{utter-queue-mode-map}"
  (setq tabulated-list-format
        [("Status" 14 nil) ("#" 3 nil :right-align t)
         ("Backend:voice" 18 nil) ("Text" 41 nil) ("Time" 11 nil)
         ("Source" 0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-entries #'utter-queue--entries)
  ;; Before `tabulated-list-init-header', which otherwise takes the
  ;; header line away from `utter-mode'.
  (setq tabulated-list-use-header-line nil)
  (tabulated-list-init-header)
  (add-hook 'post-command-hook #'utter-queue--refresh nil t)
  (utter-mode 1))

;;;###autoload
(defun utter-queue ()
  "Show the queue of utterances in the `*utter-queue*' buffer.
Return the buffer."
  (interactive)
  (let ((buf (get-buffer-create utter-queue-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'utter-queue-mode)
        (utter-queue-mode))
      (tabulated-list-print t))
    (pop-to-buffer buf)
    buf))

(provide 'utter-mode)
;;; utter-mode.el ends here
