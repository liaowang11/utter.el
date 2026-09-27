;;; utter-text.el --- Text preparation for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; This file is part of utter.el.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Turn a snapshot of text into what a speech backend should hear:
;;
;; - `utter-preprocess-functions' rewrites the text (markup, URLs,
;;   whitespace, pronunciations).  Each function runs with the source
;;   buffer current, so it can look at `major-mode'.
;; - `utter--split' cuts the result into request-sized segments at
;;   sentence boundaries.  Segments are an internal detail; users only
;;   ever see whole utterances.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup utter nil
  "Read text aloud through text-to-speech backends."
  :group 'multimedia
  :prefix "utter-")

;;;; Preprocessing

(defcustom utter-preprocess-functions
  '(utter-strip-markup utter-replace-urls utter-collapse-whitespace
    utter-apply-pronunciations)
  "Functions that rewrite text before it is spoken.
Each function takes a string and returns a string.  They run in
order, with the source buffer current when there is one, so a
function can check `major-mode'."
  :type 'hook
  :group 'utter)

(defcustom utter-pronunciation-alist nil
  "Alist of (REGEXP . REPLACEMENT) applied before speaking.
REPLACEMENT is a string as for `replace-regexp-in-string' (so \\1
refers to a group), or a function of the matched text.  Matching
is case sensitive.  Used by `utter-apply-pronunciations'."
  :type '(alist :key-type regexp :value-type (choice string function))
  :group 'utter)

(defun utter--replace-all (rules string)
  "Apply RULES, a list of (REGEXP . REPLACEMENT), to STRING in order."
  (let ((case-fold-search nil))
    (dolist (rule rules string)
      (setq string (replace-regexp-in-string (car rule) (cdr rule) string t)))))

(defconst utter--org-markup-rules
  '(;; Property drawers and keyword/block lines carry no speech.
    ("^[ \t]*:PROPERTIES:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\\(?:\n\\|\\'\\)" . "")
    ("^[ \t]*#\\+[A-Za-z_]+:.*\\(?:\n\\|\\'\\)" . "")
    ("^[ \t]*#\\+\\(?:begin\\|end\\|BEGIN\\|END\\)_.*\\(?:\n\\|\\'\\)" . "")
    ;; Links keep their description, or their target for the URL pass.
    ("\\[\\[\\([^]\n]+\\)\\]\\[\\([^]\n]+\\)\\]\\]" . "\\2")
    ("\\[\\[\\([^]\n]+\\)\\]\\]" . "\\1")
    ;; A heading is its own paragraph; drop stars and tags.
    ("^\\*+[ \t]+\\(.*?\\)\\(?:[ \t]+:[[:alnum:]_@#%:]+:\\)?[ \t]*$" . "\\1\n")
    ;; List items start a new paragraph.
    ("^[ \t]*\\(?:[-+]\\|[0-9]+[.)]\\)[ \t]+" . "\n")
    ;; Emphasis markers.
    ("\\(^\\|[ \t\n('\"{]\\)\\([*/=~+_]\\)\\([^ \t\n]\\|[^ \t\n].*?[^ \t\n]\\)\\2\\([ \t\n.,:!?;'\")}-]\\|$\\)"
     . "\\1\\3\\4"))
  "Rewrite rules applied by `utter-strip-markup' in Org buffers.")

(defconst utter--markdown-markup-rules
  '(("^[ \t]*\\(?:```\\|~~~\\).*\\(?:\n\\|\\'\\)" . "")
    ("!\\[\\([^]\n]*\\)\\]([^)\n]*)" . "\\1")
    ("\\[\\([^]\n]+\\)\\]([^)\n]*)" . "\\1")
    ("^#+[ \t]+\\(.*?\\)[ \t#]*$" . "\\1\n")
    ("^[ \t]*>[ \t]?" . "")
    ("\\*\\*\\(.+?\\)\\*\\*" . "\\1")
    ("__\\(.+?\\)__" . "\\1")
    ("^[ \t]*\\(?:[-*+]\\|[0-9]+[.)]\\)[ \t]+" . "\n")
    ("\\(^\\|[ \t\n(]\\)\\([*_]\\)\\([^ \t\n*_]\\|[^ \t\n*_].*?[^ \t\n]\\)\\2\\([ \t\n.,:!?;'\")}-]\\|$\\)"
     . "\\1\\3\\4")
    ("`\\([^`\n]+\\)`" . "\\1"))
  "Rewrite rules applied by `utter-strip-markup' in Markdown buffers.")

(defun utter-strip-markup (text)
  "Remove Org or Markdown markup from TEXT.
The current buffer's major mode decides which markup is removed;
in other modes TEXT is returned unchanged."
  (cond
   ((derived-mode-p 'org-mode)
    ;; Run twice so adjacent emphasis sharing one space is caught.
    (utter--replace-all (last utter--org-markup-rules)
                        (utter--replace-all utter--org-markup-rules text)))
   ((derived-mode-p 'markdown-mode 'gfm-mode 'markdown-ts-mode)
    (utter--replace-all utter--markdown-markup-rules text))
   (t text)))

(defconst utter--url-regexp
  "\\b\\(?:https?\\|ftp\\)://[^ \t\n<>\"]*[^] \t\n<>\".,;:!?)']"
  "Regexp matching a bare URL, without trailing punctuation.")

(defun utter-replace-urls (text)
  "Replace links and URLs in TEXT with something worth hearing.
A link with a description becomes the description; a bare URL
becomes the word \"link\"."
  (utter--replace-all
   `(("\\[\\[\\([^]\n]+\\)\\]\\[\\([^]\n]+\\)\\]\\]" . "\\2")
     ("\\[\\[[^]\n]+\\]\\]" . "link")
     ("!?\\[\\([^]\n]+\\)\\](\\(?:https?\\|ftp\\)://[^) \t\n]*)" . "\\1")
     ("<\\(?:https?\\|ftp\\)://[^> \t\n]*>" . "link")
     (,utter--url-regexp . "link"))
   text))

(defun utter-collapse-whitespace (text)
  "Collapse whitespace in TEXT.
A run containing two or more newlines becomes one newline, which
marks a paragraph; any other run becomes one space.  Leading and
trailing whitespace is removed."
  (string-trim
   (replace-regexp-in-string
    "[ \t\n\r\f\v\u00a0\u3000]+"
    (lambda (m) (if (> (cl-count ?\n m) 1) "\n" " "))
    text t t)))

(defun utter-apply-pronunciations (text)
  "Apply `utter-pronunciation-alist' to TEXT."
  (utter--replace-all utter-pronunciation-alist text))

(defun utter--preprocess (text &optional buffer)
  "Run `utter-preprocess-functions' over TEXT and return the result.
When BUFFER is a live buffer the functions run with it current;
otherwise they run in a temporary buffer in `fundamental-mode'."
  (cl-flet ((run ()
              (let ((s text))
                (dolist (f utter-preprocess-functions s)
                  (setq s (funcall f s))))))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer (run))
      (with-temp-buffer (run)))))

(defun utter--tag-positions (string start)
  "Record buffer positions in STRING and return it.
STRING was copied from a buffer at position START.  The first
character of each word and each character after CJK punctuation
gets an `utter--pos' text property holding its buffer position.
The tags survive the default preprocessing, which lets the queue
map segments back to the buffer for highlighting."
  (let ((i 0)
        (re "\\(?:\\`\\|[ \t\n\r\f。！？；，、：]\\)\\([^ \t\n\r\f]\\)"))
    (while (and (< i (length string)) (string-match re string i))
      (let ((b (match-beginning 1)))
        (put-text-property b (1+ b) 'utter--pos (+ start b) string)
        (setq i (max (1+ i) (match-end 1)))))
    string))

;;;; Splitting

(defvar utter--split-functions '(utter--split-by-sentence)
  "Functions that split text into request-sized segments.
Each is called with (TEXT MAX-CHARS UNIT) and returns a list of
strings or nil; the first non-nil result wins.")

(defvar utter--first-segment-chars 200
  "Character limit for the first segment, for fast first audio.")

(defun utter--char-units (char unit)
  "Return the size of CHAR in UNIT: `chars', `bytes' or `utf16'."
  (pcase unit
    ('bytes (cond ((< char #x80) 1) ((< char #x800) 2)
                  ((< char #x10000) 3) (t 4)))
    ('utf16 (if (> char #xffff) 2 1))
    (_ 1)))

(defun utter--range-measure (text beg end unit)
  "Return the size of TEXT between BEG and END in UNIT."
  (if (memq unit '(bytes utf16))
      (let ((n 0))
        (while (< beg end)
          (setq n (+ n (utter--char-units (aref text beg) unit))
                beg (1+ beg)))
        n)
    (- end beg)))

(defun utter--text-measure (text &optional unit)
  "Return the size of TEXT in UNIT (default `chars')."
  (utter--range-measure text 0 (length text) unit))

(defun utter--trim-end (text beg end)
  "Return END moved back over whitespace in TEXT, but not before BEG."
  (while (and (> end beg) (memq (aref text (1- end)) '(?\s ?\t ?\n ?\r ?\f)))
    (setq end (1- end)))
  end)

(defun utter--skip-space (text pos)
  "Return POS moved forward over whitespace in TEXT."
  (while (and (< pos (length text))
              (memq (aref text pos) '(?\s ?\t ?\n ?\r ?\f)))
    (setq pos (1+ pos)))
  pos)

(defconst utter--ssml-tag-regexp
  "<\\(/\\)?\\([A-Za-z][-A-Za-z0-9:_]*\\)\\(?:[^>]*?\\)\\(/\\)?>"
  "Regexp matching one SSML tag.")

(defun utter--ssml-forbidden (text)
  "Return intervals of TEXT where a split would break SSML.
The value is a list of (START . END); splitting at P is forbidden
when START < P < END.  Tags themselves and the inside of elements
other than speak and p are protected.  Nil when TEXT has no tags."
  (when (string-match-p "<[A-Za-z/][^>]*>" text)
    (let ((i 0) stack intervals)
      (while (string-match utter--ssml-tag-regexp text i)
        (let ((b (match-beginning 0)) (e (match-end 0))
              (closing (match-beginning 1)) (name (downcase (match-string 2 text)))
              (self (match-beginning 3)))
          (push (cons b e) intervals)
          (unless (member name '("speak" "p"))
            (cond (self)
                  (closing
                   (when-let* ((open (assoc name stack)))
                     (push (cons (cdr open) e) intervals)
                     (setq stack (cdr (member open stack)))))
                  (t (push (cons name b) stack))))
          (setq i e)))
      intervals)))

(defun utter--forbidden-p (pos intervals)
  "Return non-nil if POS falls strictly inside one of INTERVALS."
  (cl-some (lambda (iv) (and (< (car iv) pos) (< pos (cdr iv)))) intervals))

(defun utter--sentence-regexp ()
  "Return the regexp that ends a sentence, including trailing space."
  (concat "\\(?:" (let ((sentence-end-double-space nil)) (sentence-end)) "\\)"
          "\\|[。！？；][」』”’）)]*[ \t]*"
          "\\|\n+[ \t]*"))

(defun utter--sentence-spans (text forbidden)
  "Return contiguous (BEG . END) sentence spans covering TEXT.
Sentence ends inside FORBIDDEN intervals are ignored."
  (let ((re (utter--sentence-regexp))
        (start 0) (i 0) spans)
    (while (and (< i (length text)) (string-match re text i))
      (let ((e (match-end 0)))
        (cond ((<= e i) (setq i (1+ i)))
              ((utter--forbidden-p e forbidden) (setq i e))
              (t (when (> e start) (push (cons start e) spans))
                 (setq start e i e)))))
    (when (< start (length text))
      (push (cons start (length text)) spans))
    (nreverse spans)))

(defun utter--fit-end (text beg end max unit)
  "Return the largest P <= END with TEXT from BEG to P fitting MAX UNIT."
  (let ((n 0) (p beg))
    (while (and (< p end)
                (<= (+ n (utter--char-units (aref text p) unit)) max))
      (setq n (+ n (utter--char-units (aref text p) unit))
            p (1+ p)))
    (max p (min end (1+ beg)))))

(defun utter--hard-split (text beg end max unit forbidden)
  "Split the span of TEXT from BEG to END into spans under MAX UNIT.
Cut after whitespace or punctuation when possible, never inside
FORBIDDEN intervals unless there is no other choice."
  (let (spans)
    (while (> (utter--range-measure text beg (utter--trim-end text beg end) unit)
              max)
      (let* ((p (utter--fit-end text beg end max unit))
             (q p))
        ;; Look back for a cut after a break character.
        (while (and (> q beg)
                    (not (and (memq (aref text (1- q))
                                    '(?\s ?\t ?\n ?, ?， ?、 ?: ?： ?\; ?\) ?）))
                              (not (utter--forbidden-p q forbidden)))))
          (setq q (1- q)))
        (when (<= q beg)
          ;; No break character: cut anywhere allowed, else at P.
          (setq q p)
          (while (and (> q (1+ beg)) (utter--forbidden-p q forbidden))
            (setq q (1- q)))
          (when (utter--forbidden-p q forbidden) (setq q p)))
        (push (cons beg q) spans)
        (setq beg (utter--skip-space text q))))
    (when (< beg end) (push (cons beg end) spans))
    (nreverse spans)))

(defun utter--split-by-sentence (text max-chars unit)
  "Split TEXT into segments of at most MAX-CHARS in UNIT.
Sentences are packed together while they fit; the first segment
is also kept under `utter--first-segment-chars' characters.  A
sentence longer than MAX-CHARS is cut at whitespace or
punctuation.  SSML tags are never cut."
  (let* ((max (max 1 (or max-chars most-positive-fixnum)))
         (forbidden (utter--ssml-forbidden text))
         (segments nil)
         (cur-beg nil) (cur-end nil) (cur-size 0))
    (cl-flet ((flush ()
                (when cur-beg (push (cons cur-beg cur-end) segments))
                (setq cur-beg nil cur-end nil cur-size 0))
              (fits (beg end size)
                (and (<= size max)
                     (or segments
                         (<= (- (utter--trim-end text beg end) beg)
                             utter--first-segment-chars)))))
      (dolist (span (utter--sentence-spans text forbidden))
        (let* ((b (car span)) (e (cdr span))
               (trimmed (utter--range-measure text b (utter--trim-end text b e) unit))
               (full (utter--range-measure text b e unit)))
          (cond
           ((> trimmed max)
            (flush)
            (dolist (piece (utter--hard-split text b e max unit forbidden))
              (push piece segments)))
           ((and cur-beg (fits cur-beg e (+ cur-size trimmed)))
            (setq cur-end e cur-size (+ cur-size full)))
           (t (flush)
              (setq cur-beg b cur-end e cur-size full)))))
      (flush))
    (delq nil
          (mapcar (lambda (span)
                    (let ((s (string-trim (substring text (car span) (cdr span)))))
                      (unless (string-empty-p s) s)))
                  (nreverse segments)))))

(defun utter--split (text max-chars &optional unit)
  "Split TEXT into a list of segments that each fit MAX-CHARS.
UNIT is how size is counted: `chars' (default), `bytes' (UTF-8)
or `utf16'.  Runs `utter--split-functions'.  Private: callers
that want speech use `utter-enqueue', which splits for them."
  (let ((sentence-end-double-space nil))
    (run-hook-with-args-until-success
     'utter--split-functions text max-chars (or unit 'chars))))

(provide 'utter-text)
;;; utter-text.el ends here
