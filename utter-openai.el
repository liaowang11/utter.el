;;; utter-openai.el --- OpenAI-compatible speech backend for utter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Keywords: multimedia, convenience
;; URL: https://github.com/liaowang11/utter.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A backend for OpenAI's POST /v1/audio/speech and the many servers
;; that copy it.  The body is
;;
;;   {"model", "input", "voice", "response_format", "speed", "instructions"}
;;
;; and the response is raw audio.  The Authorization header is left
;; out when the key resolves to nil, which is what keyless local
;; servers need.  The key defaults to auth-source:
;;
;;   machine api.openai.com login apikey password sk-...
;;
;; Vendor quirks are plain keyword combinations, not hidden logic:
;;
;; OpenAI:
;;
;;   (utter-make-openai "OpenAI")
;;
;; OpenRouter only returns mp3 or pcm and defaults to pcm, so force mp3:
;;
;;   (utter-make-openai "OpenRouter"
;;     :host "openrouter.ai" :endpoint "/api/v1/audio/speech"
;;     :models '(hexgrad/kokoro-82m) :voices '("zf_xiaoxiao" "af_heart")
;;     :formats '(mp3) :capabilities nil
;;     :request-params '(:response_format "mp3"))
;;
;; Kokoro-FastAPI streams by default and lists voices at
;; GET /v1/audio/voices:
;;
;;   (utter-make-openai "Kokoro"
;;     :protocol "http" :host "localhost:8880" :key nil
;;     :models '(kokoro) :formats '(mp3 wav)
;;     :voices #'utter-openai-fetch-voices
;;     :request-params '(:stream :false)
;;     :max-chars 1000 :capabilities nil)
;;
;; mlx-audio names the instructions field `instruct':
;;
;;   (utter-make-openai "mlx-audio"
;;     :protocol "http" :host "localhost:8000" :key nil
;;     :models '(mlx-community/Kokoro-82M-bf16) :formats '(wav mp3)
;;     :voices #'utter-openai-fetch-voices
;;     :instructions-key :instruct)
;;
;; Other renames or extra fields (mlx-audio `lang_code') go through
;; :request-params or :body-transform, a function from body plist to
;; body plist.

;;; Code:

(require 'utter-core)

(cl-defstruct (utter-openai (:include utter-backend)
                            (:constructor utter--make-openai)
                            (:copier nil))
  "An OpenAI-compatible /v1/audio/speech backend.
INSTRUCTIONS-KEY is the body key used for instructions."
  (instructions-key :instructions))

;;;###autoload
(cl-defun utter-make-openai
    (name &key (host "api.openai.com") (protocol "https") (endpoint "/v1/audio/speech")
          (key #'utter-api-key-from-auth-source) header curl-args request-params body-transform
          (models '(gpt-4o-mini-tts tts-1 tts-1-hd))
          (voices '("alloy" "ash" "coral" "echo" "fable" "nova" "onyx" "sage" "shimmer"))
          (formats '(mp3 wav opus aac flac pcm)) (max-chars 4096)
          (capabilities '(instructions)) (instructions-key :instructions))
  "Register and return an OpenAI-compatible speech backend called NAME.
HOST, PROTOCOL and ENDPOINT make the URL.  KEY is a string, symbol
or function (default: auth-source by HOST); nil means no key.
HEADER overrides the default Authorization: Bearer header, which is
omitted when the key is nil.  CURL-ARGS are extra curl arguments.
REQUEST-PARAMS is a plist merged last into the body and
BODY-TRANSFORM a function applied to the body after that.
MODELS, VOICES and FORMATS list what the server offers; the first
of each is the default.  VOICES may also be a function such as
`utter-openai-fetch-voices'.  MAX-CHARS is the per-request text
limit.  CAPABILITIES may contain `instructions'.  INSTRUCTIONS-KEY
names the body field for instructions (mlx-audio uses :instruct).
See the Commentary for OpenRouter, Kokoro-FastAPI and mlx-audio."
  (declare (indent 1))
  (setf (utter-get-backend name)
        (utter--make-openai
         :name name :host host :protocol protocol :endpoint endpoint
         :key key :header (or header #'utter-bearer-header)
         :curl-args curl-args :request-params request-params
         :body-transform body-transform
         :models models :voices voices :formats formats :max-chars max-chars
         :capabilities capabilities :instructions-key instructions-key
         :response-kind 'bytes)))

(defun utter-openai--string (value)
  "Return VALUE as a string; symbols give their name."
  (if (symbolp value) (symbol-name value) value))

(cl-defmethod utter--normalize-params ((backend utter-openai) params)
  "Clamp PARAMS' :speed to 0.25-4, then apply the default rules."
  (let ((speed (plist-get params :speed)))
    (when speed
      (setq params (plist-put params :speed (float (min 4.0 (max 0.25 speed)))))))
  (cl-call-next-method backend params))

(cl-defmethod utter--request-data ((backend utter-openai) text params)
  "Return the /v1/audio/speech body for TEXT on BACKEND with PARAMS."
  (let ((instructions (plist-get params :instructions)))
    (append
     (list :model (utter-openai--string (plist-get params :model))
           :input text)
     (when-let* ((voice (plist-get params :voice))) (list :voice voice))
     (when-let* ((fmt (plist-get params :format)))
       (list :response_format (utter-openai--string fmt)))
     (when-let* ((speed (plist-get params :speed))) (list :speed speed))
     (when (and instructions (not (string-empty-p instructions)))
       (list (utter-openai-instructions-key backend) instructions)))))

(defun utter-openai--parse-voices (json)
  "Return a voice list from a voices JSON response.
Handles Kokoro-FastAPI {\"voices\": [NAME...]} and mlx-audio
{\"data\": [{\"id\", \"name\"}...]}."
  (let ((items (or (alist-get 'voices json) (alist-get 'data json))))
    (delq nil
          (mapcar (lambda (v)
                    (cond
                     ((stringp v) v)
                     ((consp v)
                      (let ((id (or (alist-get 'id v) (alist-get 'voice_id v)
                                    (alist-get 'name v)))
                            (name (alist-get 'name v)))
                        (and id (if (and name (not (equal name id)))
                                    (list id :description name)
                                  id))))))
                  items))))

(defun utter-openai--voices-path (backend)
  "Return the voices path next to BACKEND's speech endpoint."
  (let ((ep (or (utter-backend-endpoint backend) "/v1/audio/speech")))
    (if (string-match "/speech\\'" ep)
        (replace-match "/voices" t t ep)
      "/v1/audio/voices")))

;;;###autoload
(defun utter-openai-fetch-voices (backend callback)
  "Fetch BACKEND's voices from GET /v1/audio/voices and call CALLBACK.
Use it as the :voices of Kokoro-FastAPI or mlx-audio backends; the
result is cached like any fetched voice list."
  (utter-fetch-json backend "GET" (utter-openai--voices-path backend)
                    (lambda (json) (funcall callback (utter-openai--parse-voices json)))))

(provide 'utter-openai)
;;; utter-openai.el ends here
