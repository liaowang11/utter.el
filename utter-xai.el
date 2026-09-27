;;; utter-xai.el --- xAI text-to-speech backend for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; xAI speech API (verified 2026-09-27 against the live service):
;;
;;   POST https://api.x.ai/v1/tts        Authorization: Bearer KEY
;;   {"text": ..., "voice_id": "eve", "language": "en",
;;    "output_format": {"codec": "mp3" | "wav"}}
;;   -> raw audio bytes (audio/mpeg or audio/wav)
;;
;;   GET https://api.x.ai/v1/tts/voices
;;   -> {"voices": [{"voice_id", "name", "language", "gender"}, ...]}
;;
;; Unknown body fields are ignored by the server; a malformed
;; `output_format' is a 422 with a text/plain message.  `language' is
;; required, so `auto' is resolved from the text's script.

;;; Code:

(require 'utter-core)

(defconst utter-xai-default-voice-id "eve"
  "Voice id used when no voice is given.")

(cl-defstruct (utter-xai (:include utter-backend)
                         (:constructor utter--make-xai)
                         (:copier nil))
  "An xAI text-to-speech backend.")

;;;###autoload
(cl-defun utter-make-xai
    (name &key (host "api.x.ai") (key #'utter-api-key-from-auth-source)
          curl-args request-params (max-chars 4000))
  "Register and return an xAI speech backend called NAME.
HOST is the API host.  KEY is a string, symbol or function; it
defaults to auth-source by HOST.  CURL-ARGS are extra curl
arguments and REQUEST-PARAMS a plist merged last into the body.
MAX-CHARS bounds one request; xAI documents no limit."
  (declare (indent 1))
  (setf (utter-get-backend name)
        (utter--make-xai
         :name name :host host :protocol "https" :endpoint "/v1/tts" :key key
         :models '(grok-tts) :formats '(mp3 wav) :max-chars max-chars
         :response-kind 'bytes :capabilities nil
         :curl-args curl-args :request-params request-params
         :voices 'fetch
         :header #'utter-bearer-header)))

(defun utter-xai--voice-id (backend voice)
  "Return the voice id for VOICE on BACKEND.
Names are looked up in the cached voice list; anything else is
taken as an id.  nil gives `utter-xai-default-voice-id'."
  (cond
   ((null voice) utter-xai-default-voice-id)
   ((plist-get (cdr (assoc voice (utter--cached-voices backend))) :id))
   (t voice)))

(defun utter-xai--guess-language (text)
  "Return a language code for TEXT from its script: zh, ja, ko or en."
  (cond
   ((string-match-p "[぀-ヿ]" text) "ja")
   ((string-match-p "[가-힯]" text) "ko")
   ((string-match-p "[一-鿿]" text) "zh")
   (t "en")))

(cl-defmethod utter--request-data ((backend utter-xai) text params)
  "Return the xAI body for TEXT with PARAMS, resolving voices on BACKEND."
  (let ((lang (plist-get params :language))
        (format (plist-get params :format)))
    (list :text text
          :voice_id (utter-xai--voice-id backend (plist-get params :voice))
          :language (cond ((or (null lang) (eq lang 'auto)) (utter-xai--guess-language text))
                          ((symbolp lang) (symbol-name lang))
                          (t lang))
          :output_format (list :codec (if (eq format 'wav) "wav" "mp3")))))

(cl-defmethod utter--list-voices ((backend utter-xai) callback)
  "Fetch BACKEND's voices from GET /v1/tts/voices and call CALLBACK.
Each voice is (NAME :id VOICE-ID :description GENDER)."
  (utter-fetch-json
   backend "GET" "/v1/tts/voices"
   (lambda (json)
     (funcall callback
              (mapcar (lambda (v)
                        (list (alist-get 'name v) :id (alist-get 'voice_id v)
                              :description (alist-get 'gender v)))
                      (alist-get 'voices json))))))

(provide 'utter-xai)
;;; utter-xai.el ends here
