;;; utter.el --- Read text aloud through many TTS backends -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (transient "0.7.5"))
;; Keywords: multimedia, convenience
;; URL: https://github.com/liaowang11/utter.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; utter reads text aloud through text-to-speech backends (macOS `say',
;; OpenAI-compatible servers, ElevenLabs, ...).  `utter-menu' is the
;; interface; `utter-speak' is its default action.
;;
;; Listening is asynchronous.  Text is captured when you ask for it and
;; appended to one global queue; point never moves and no buffer pops
;; up.  A short lighter in the mode line shows that something is
;; playing.
;;
;; Main commands (none is bound by default):
;;
;; - `utter-speak': the region, else the thing at point (for example a
;;   gptel response), else the sentence at point.  With C-u, open
;;   `utter-menu'.
;; - `utter-speak-interrupt': the same, but cut in front of the queue.
;; - `utter-speak-buffer', `utter-speak-kill', `utter-speak-string'.
;; - `utter-toggle-pause', `utter-next', `utter-previous', `utter-stop',
;;   `utter-clear', `utter-rate-up', `utter-rate-down'.
;; - `utter-save-to-file', `utter-select-voice', `utter-inspect-query'.
;;
;; Other packages can call `utter-speak-string' or `utter-enqueue', and
;; `utter-with-preset' applies a preset made with `utter-make-preset'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'utter-queue)

(declare-function utter-menu "utter-transient" ())
(declare-function utter-say-register-default "utter-say" ())
(declare-function utter-request "utter-core" (text &rest keys))
(declare-function utter-get-backend "utter-core" (name))
(declare-function utter-backend-p "utter-core" (object))
(declare-function utter-backend-name "utter-core" (backend))
(declare-function utter-backend-voices "utter-core" (backend))
(declare-function utter-backend-formats "utter-core" (backend))
(declare-function utter-backend-max-chars "utter-core" (backend))
(declare-function utter-backend-max-chars-unit "utter-core" (backend))

;;;; Options

(defcustom utter-backend
  (and (eq system-type 'darwin)
       (require 'utter-say nil t)
       (fboundp 'utter-say-register-default)
       (utter-say-register-default))
  "The speech backend, an object made by an `utter-make-*' constructor.
A backend name (a string) is accepted too.  On macOS the default
is the `say' backend; elsewhere there is no default, so set this,
for example to the result of `utter-make-openai'."
  :type '(choice (const :tag "None" nil) (string :tag "Backend name") sexp)
  :group 'utter)

(defcustom utter-model nil
  "The model, a symbol; nil means the backend's first model."
  :type '(choice (const :tag "Backend default" nil) symbol)
  :group 'utter)

(defcustom utter-voice nil
  "The voice, a string.
Nil means `utter-voice-alist' for the text's language, else the
backend's first voice."
  :type '(choice (const :tag "Default" nil) string)
  :group 'utter)

(defcustom utter-format nil
  "The audio format, a symbol such as `mp3'; nil means the backend's first."
  :type '(choice (const :tag "Backend default" nil) symbol)
  :group 'utter)

(defcustom utter-voice-alist nil
  "Alist of (LANGUAGE . VOICE) used when `utter-voice' is nil.
LANGUAGE is a symbol such as `zh' or `en'.  When `utter-language'
is `auto' the language is guessed from the text."
  :type '(alist :key-type symbol :value-type string)
  :group 'utter)

(defcustom utter-speed 1.0
  "Synthesis speed, 1.0 being normal.  Part of the cache key."
  :type 'number
  :group 'utter)

(defcustom utter-playback-rate 1.0
  "Player rate, 1.0 being normal.
Unlike `utter-speed' it needs no new synthesis.  See
`utter-rate-up' and `utter-rate-down'."
  :type 'number
  :group 'utter)

(defcustom utter-language 'auto
  "Language of the text: a symbol or string, or `auto' to guess."
  :type '(choice (const auto) symbol string)
  :group 'utter)

(defcustom utter-instructions nil
  "Speaking instructions for backends that accept them, or nil."
  :type '(choice (const :tag "None" nil) string)
  :group 'utter)

(defcustom utter-highlight nil
  "When non-nil, highlight the text being spoken in its buffer.
The highlight is removed as soon as the buffer text changes."
  :type 'boolean
  :group 'utter)

(defcustom utter-highlight-follow nil
  "When non-nil, scroll windows so the highlighted text stays visible.
This is the only option that lets utter move point."
  :type 'boolean
  :group 'utter)

(defcustom utter-lighter " ♪%i/%n"
  "Mode line lighter shown while speaking, or nil for none.
A `format-spec' string, see `utter-state-string'.  \"%i/%n\" is
dropped when only one utterance is queued."
  :type '(choice (const :tag "None" nil) string)
  :group 'utter)

(defcustom utter-prefetch-depth 2
  "How many parts of the queued text to synthesize ahead of playback."
  :type 'natnum
  :group 'utter)

(defcustom utter-max-concurrent-requests 2
  "Maximum number of synthesis requests running at once."
  :type 'natnum
  :group 'utter)

(defcustom utter-cache-directory
  (expand-file-name "utter" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory for synthesized audio."
  :type 'directory
  :group 'utter)

(defcustom utter-cache-max-size (* 500 1024 1024)
  "Maximum size of `utter-cache-directory' in bytes, or nil for no limit.
The least recently used files are removed first."
  :type '(choice (const :tag "Unlimited" nil) natnum)
  :group 'utter)

(defcustom utter-voice-cache-ttl 86400
  "Seconds a fetched voice list stays valid."
  :type 'natnum
  :group 'utter)

(defcustom utter-player 'auto
  "The audio player: an `utter-player', a symbol naming one, or `auto'.
`auto' picks the first installed player that plays the audio format,
from `utter-player-afplay' (macOS), `utter-player-ffplay' and
`utter-player-mpv'."
  :type '(choice (const auto) symbol sexp)
  :group 'utter)

(defcustom utter-curl-program "curl"
  "The curl program used for requests."
  :type 'string
  :group 'utter)

(defcustom utter-proxy ""
  "Proxy for requests, as accepted by curl's --proxy; empty for none."
  :type 'string
  :group 'utter)

(defcustom utter-log-level nil
  "What to write to the *utter-log* buffer: nil, `info' or `debug'."
  :type '(choice (const :tag "Nothing" nil) (const info) (const debug))
  :group 'utter)

(defcustom utter-thing-at-point-functions '(utter--gptel-response-at-point)
  "Functions that find the text `utter-speak' reads when there is no region.
Each is called with no arguments and returns (BEG . END) or nil.
The first non-nil result wins; when all return nil, the sentence
at point is read."
  :type 'hook
  :group 'utter)

(defcustom utter-expert-commands nil
  "When non-nil, `utter-menu' shows expert commands such as Inspect."
  :type 'boolean
  :group 'utter)

(provide 'utter)
;;; utter.el ends here
