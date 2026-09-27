;;; utter-text-tests.el --- Tests for utter-text.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Preprocessing and splitting tests.  No network, no external programs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'utter-text)

(defun utter-text-tests--measure (s unit)
  "Return the length of S in UNIT, independently of utter-text."
  (pcase unit
    ('bytes (length (encode-coding-string s 'utf-8)))
    ('utf16 (/ (length (encode-coding-string s 'utf-16be)) 2))
    (_ (length s))))

(defun utter-text-tests--squash (s)
  "Return S without any whitespace, for content comparisons."
  (replace-regexp-in-string "[ \t\n]+" "" s))

(defun utter-text-tests--count (needle s)
  "Return how many times NEEDLE occurs in S."
  (let ((n 0) (i 0))
    (while (setq i (string-search needle s i))
      (setq n (1+ n) i (1+ i)))
    n))

;;;; Preprocessing

(ert-deftest utter-text-strip-org-markup ()
  (with-temp-buffer
    (org-mode)
    (should (equal (utter-strip-markup
                    "* Heading\nSome *bold* and /italic/ and =code= and ~verb~.\n#+TITLE: x\n")
                   "Heading\n\nSome bold and italic and code and verb.\n"))
    (should (equal (utter-strip-markup "See [[https://gnu.org][the GNU site]] now.")
                   "See the GNU site now."))
    (should (equal (utter-strip-markup
                    "Text\n:PROPERTIES:\n:ID: 1\n:END:\nMore")
                   "Text\nMore"))))

(ert-deftest utter-text-strip-markdown-markup ()
  (with-temp-buffer
    ;; markdown-mode is not part of Emacs; derived-mode-p still matches
    ;; the symbol itself.
    (setq major-mode 'markdown-mode)
    (should (equal (utter-strip-markup
                    "## Title\nSome **bold**, _em_ and `code`.\n> quoted\n![alt text](a.png) [desc](https://x.org)")
                   "Title\n\nSome bold, em and code.\nquoted\nalt text desc"))
    (should (equal (utter-strip-markup "```elisp\n(setq a 1)\n```\nafter")
                   "(setq a 1)\nafter"))))

(ert-deftest utter-text-strip-markup-list-items-are-paragraphs ()
  (with-temp-buffer
    (org-mode)
    (should (equal (utter-collapse-whitespace
                    (utter-strip-markup "Intro:\n- one\n- two"))
                   "Intro:\none\ntwo"))))

(ert-deftest utter-text-strip-markup-leaves-other-modes ()
  (with-temp-buffer
    (fundamental-mode)
    (should (equal (utter-strip-markup "*not bold* # not heading")
                   "*not bold* # not heading"))))

(ert-deftest utter-text-replace-urls ()
  (should (equal (utter-replace-urls "Go to https://example.com/a?b=1 now.")
                 "Go to link now."))
  (should (equal (utter-replace-urls "Read [the docs](https://x.org/d) please")
                 "Read the docs please"))
  (should (equal (utter-replace-urls "Org [[https://x.org][site]] and [[https://y.org]]")
                 "Org site and link"))
  (should (equal (utter-replace-urls "Angle <https://x.org> end")
                 "Angle link end")))

(ert-deftest utter-text-collapse-whitespace ()
  (should (equal (utter-collapse-whitespace "  a \t b\n c\n\n\n d  ")
                 "a b c\nd")))

(ert-deftest utter-text-apply-pronunciations ()
  (let ((utter-pronunciation-alist '(("\\bSQL\\b" . "sequel") ("Emacs" . "ee-macs"))))
    (should (equal (utter-apply-pronunciations "SQL in Emacs, not sql")
                   "sequel in ee-macs, not sql"))))

(ert-deftest utter-text-preprocess-runs-in-source-buffer ()
  (let ((buf (generate-new-buffer " *utter-org*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (org-mode))
          (should (equal (utter--preprocess
                          "* Head\nSee https://a.b  and *this*." buf)
                         "Head\nSee link and this."))
          ;; Without a source buffer no markup is stripped.
          (should (equal (utter--preprocess "*this*" nil) "*this*")))
      (kill-buffer buf))))

(ert-deftest utter-text-preprocess-keeps-position-tags ()
  (let ((s (utter--tag-positions (copy-sequence "Hello   https://x.org world") 10)))
    (let ((out (utter-collapse-whitespace (utter-replace-urls s))))
      (should (equal out "Hello link world"))
      (should (eql (get-text-property 0 'utter--pos out) 10))
      (should (eql (get-text-property (string-search "world" out) 'utter--pos out)
                   (+ 10 (string-search "world" "Hello   https://x.org world")))))))

;;;; Splitting

(ert-deftest utter-text-split-short-text-is-one-segment ()
  (should (equal (utter--split "Hello world. How are you?" 4096)
                 '("Hello world. How are you?"))))

(ert-deftest utter-text-split-english-packs-sentences ()
  (let* ((utter--first-segment-chars 30)
         (text "One two three. Four five six. Seven eight nine. Ten eleven twelve. Thirteen fourteen.")
         (segs (utter--split text 40)))
    (should (equal segs '("One two three. Four five six."
                          "Seven eight nine. Ten eleven twelve."
                          "Thirteen fourteen.")))
    (dolist (s segs) (should (<= (length s) 40)))))

(ert-deftest utter-text-split-first-segment-is-short ()
  (let* ((sentence "This sentence has exactly fifty characters in it. ")
         (text (apply #'concat (make-list 40 sentence)))
         (segs (utter--split text 4096)))
    (should (<= (length (car segs)) utter--first-segment-chars))
    (should (> (length segs) 1))
    (should (equal (utter-text-tests--squash (apply #'concat segs))
                   (utter-text-tests--squash text)))))

(ert-deftest utter-text-split-chinese ()
  (let* ((utter--first-segment-chars 10)
         (text "今天天气很好。我们去公园吧！你想去吗？好的；走吧。")
         (segs (utter--split text 12)))
    (should (equal segs '("今天天气很好。" "我们去公园吧！你想去吗？" "好的；走吧。")))))

(ert-deftest utter-text-split-mixed ()
  (let* ((utter--first-segment-chars 20)
         (text "Emacs 很好用。It is extensible. 我喜欢它！Really.")
         (segs (utter--split text 25)))
    (dolist (s segs) (should (<= (length s) 25)))
    (should (equal (car segs) "Emacs 很好用。"))
    (should (equal (utter-text-tests--squash (apply #'concat segs))
                   (utter-text-tests--squash text)))))

(ert-deftest utter-text-split-5000-char-paragraph ()
  (let* ((sentence "The quick brown fox jumps over the lazy dog again. ")
         (text (string-trim (apply #'concat (make-list 100 sentence))))
         (segs (utter--split text 1000)))
    (should (>= (length text) 5000))
    (dolist (s segs)
      (should (<= (length s) 1000))
      ;; Packing never cuts a sentence when sentences are short.
      (should (string-suffix-p "again." s)))
    (should (equal (utter-text-tests--squash (apply #'concat segs))
                   (utter-text-tests--squash text)))))

(ert-deftest utter-text-split-6000-char-sentence ()
  (let* ((text (string-trim (apply #'concat (make-list 1000 "word, "))))
         (segs (utter--split text 4096)))
    (should (> (length text) 5990))
    (should (>= (length segs) 2))
    (dolist (s segs) (should (<= (length s) 4096)))
    ;; Hard split lands at whitespace or punctuation, never inside a word.
    (dolist (s segs) (should (string-match-p "\\`word\\b" s)))
    (should (equal (utter-text-tests--squash (apply #'concat segs))
                   (utter-text-tests--squash text)))))

(ert-deftest utter-text-split-6000-char-chinese-without-punctuation ()
  (let* ((text (make-string 6000 ?字))
         (segs (utter--split text 4096)))
    (dolist (s segs) (should (<= (length s) 4096)))
    (should (equal (apply #'concat segs) text))))

(ert-deftest utter-text-split-units ()
  (let ((text (apply #'concat (make-list 50 "你好世界。"))))
    (dolist (unit '(chars bytes utf16))
      (let ((segs (utter--split text 60 unit)))
        (dolist (s segs)
          (should (<= (utter-text-tests--measure s unit) 60)))
        (should (equal (apply #'concat segs) text)))))
  ;; Astral characters count twice in UTF-16.
  (should (= (utter--text-measure "a😀" 'utf16) 3))
  (should (= (utter--text-measure "a😀" 'bytes) 5))
  (should (= (utter--text-measure "a😀" 'chars) 2)))

(ert-deftest utter-text-split-never-inside-ssml-tags ()
  (let* ((utter--first-segment-chars 1000)
         (text (concat "<speak>"
                       (apply #'concat
                              (make-list 20 "Hi. <say-as interpret-as=\"characters\">A. B. C.</say-as> "))
                       "</speak>"))
         (segs (utter--split text 120)))
    (should (> (length segs) 1))
    (dolist (s segs)
      (should (<= (length s) 120))
      ;; Every say-as element is whole.
      (should (= (utter-text-tests--count "<say-as" s)
                 (utter-text-tests--count "</say-as>" s)))
      (should-not (string-match-p "<[^>]*\\'" s))
      (should-not (string-match-p "\\`[^<]*>" s)))))

(ert-deftest utter-text-split-plain-less-than-is-not-ssml ()
  (let ((utter--first-segment-chars 10))
    (should (equal (utter--split "If a < b. Then c > d." 12)
                   '("If a < b." "Then c > d.")))))

(ert-deftest utter-text-split-functions-hook ()
  (let ((utter--split-functions
         (list (lambda (_text _max _unit) nil)
               (lambda (text _max _unit) (list (upcase text))))))
    (should (equal (utter--split "abc" 10) '("ABC")))))

(provide 'utter-text-tests)
;;; utter-text-tests.el ends here
