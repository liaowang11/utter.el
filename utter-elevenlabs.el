;;; utter-elevenlabs.el --- ElevenLabs backend for utter -*- lexical-binding: t; -*-

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

;; A backend for ElevenLabs text to speech:
;;
;;   POST https://api.elevenlabs.io/v1/text-to-speech/VOICE_ID?output_format=mp3_44100_128
;;   xi-api-key: KEY
;;   {"text", "model_id", "voice_settings": {"speed"}, "previous_text", "next_text"}
;;
;; The key comes from auth-source by default:
;;
;;   machine api.elevenlabs.io login apikey password ...
;;
;; Voices are fetched from GET /v2/voices and cached; voice names are
;; mapped to ids once the list is cached.  Until then a voice must be
;; given as its id.  The neighbouring text in a request's :context
;; goes into previous_text and next_text so segments join smoothly.
;;
;;   (utter-make-elevenlabs "ElevenLabs"
;;     :models '(eleven_multilingual_v2 eleven_v3))

;;; Code:

(require 'utter-core)
(require 'url-util)

(defconst utter-elevenlabs-default-voice-id "JBFqnCBsd6RMkjVDRZzb"
  "Voice id used when no voice is given (\"George\" in the ElevenLabs docs).")

(defconst utter-elevenlabs--no-language-models '(eleven_multilingual_v2)
  "Models that reject the language_code field.")

(cl-defstruct (utter-elevenlabs (:include utter-backend)
                                (:constructor utter--make-elevenlabs)
                                (:copier nil))
  "An ElevenLabs text-to-speech backend.")

(defun utter-elevenlabs--header (backend _info)
  "Return the xi-api-key header for BACKEND, or nil without a key."
  (when-let* ((key (utter--get-api-key backend)))
    `(("xi-api-key" . ,key))))

(defun utter-elevenlabs--url (backend info)
  "Return the synthesis URL for BACKEND and request INFO."
  (format "%s://%s/v1/text-to-speech/%s?output_format=%s"
          (or (utter-backend-protocol backend) "https")
          (utter-backend-host backend)
          (url-hexify-string (or (plist-get info :voice-id) utter-elevenlabs-default-voice-id))
          (if (eq (plist-get info :format) 'pcm) "pcm_24000" "mp3_44100_128")))

;;;###autoload
(cl-defun utter-make-elevenlabs
    (name &key (host "api.elevenlabs.io") (key #'utter-api-key-from-auth-source)
          curl-args request-params
          (models '(eleven_multilingual_v2 eleven_v3 eleven_flash_v2_5)))
  "Register and return an ElevenLabs backend called NAME.
HOST is the API host.  KEY is a string, symbol or function; it
defaults to auth-source by HOST.  CURL-ARGS are extra curl
arguments and REQUEST-PARAMS a plist merged last into the body,
e.g. (:voice_settings (:speed 1.0 :stability 0.5)).  MODELS lists
model ids; the first is the default."
  (declare (indent 1))
  (setf (utter-get-backend name)
        (utter--make-elevenlabs
         :name name :host host :protocol "https" :key key
         :models models :formats '(mp3 pcm) :max-chars 5000
         :response-kind 'bytes :capabilities '(stitching)
         :curl-args curl-args :request-params request-params
         :voices 'fetch
         :header #'utter-elevenlabs--header
         :url #'utter-elevenlabs--url)))

(defun utter-elevenlabs--voice-id (backend voice)
  "Return the voice id for VOICE on BACKEND.
Names are looked up in the cached voice list; anything else is
taken as an id.  nil gives `utter-elevenlabs-default-voice-id'."
  (cond
   ((null voice) utter-elevenlabs-default-voice-id)
   ((plist-get (cdr (assoc voice (utter--cached-voices backend))) :id))
   (t voice)))

(cl-defmethod utter--normalize-params ((backend utter-elevenlabs) params)
  "Resolve PARAMS' voice name to :voice-id and clamp :speed for BACKEND."
  (setq params (plist-put params :voice-id
                          (utter-elevenlabs--voice-id backend (plist-get params :voice))))
  (when-let* ((speed (plist-get params :speed)))
    (setq params (plist-put params :speed (float (min 1.2 (max 0.7 speed))))))
  (cl-call-next-method backend params))

(cl-defmethod utter--request-data ((_backend utter-elevenlabs) text params)
  "Return the ElevenLabs body for TEXT with PARAMS."
  (let ((ctx (plist-get params :context))
        (model (plist-get params :model))
        (lang (plist-get params :language)))
    (append
     (list :text text
           :model_id (if (symbolp model) (symbol-name model) model)
           :voice_settings (list :speed (or (plist-get params :speed) 1.0)))
     (when (and lang (not (eq lang 'auto))
                (not (memq model utter-elevenlabs--no-language-models)))
       (list :language_code (if (symbolp lang) (symbol-name lang) lang)))
     (when-let* ((p (plist-get ctx :previous))) (list :previous_text p))
     (when-let* ((n (plist-get ctx :next))) (list :next_text n)))))

(cl-defmethod utter--list-voices ((backend utter-elevenlabs) callback)
  "Fetch BACKEND's voices from GET /v2/voices and call CALLBACK.
Each voice is (NAME :id VOICE-ID [:description ACCENT])."
  (utter-fetch-json
   backend "GET" "/v2/voices?page_size=100"
   (lambda (json)
     (funcall callback
              (mapcar (lambda (v)
                        (let ((accent (alist-get 'accent (alist-get 'labels v))))
                          (append (list (alist-get 'name v) :id (alist-get 'voice_id v))
                                  (and accent (list :description accent)))))
                      (alist-get 'voices json))))))

(provide 'utter-elevenlabs)
;;; utter-elevenlabs.el ends here
