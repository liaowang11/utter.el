;;; utter-gemini.el --- Gemini speech backend for utter -*- lexical-binding: t; -*-

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

;; A backend for Gemini text to speech through the Interactions API:
;;
;;   POST https://generativelanguage.googleapis.com/v1beta/interactions
;;   x-goog-api-key: KEY
;;
;; The response is JSON; the audio is base64 WAV (24 kHz mono) in the
;; last audio part of the model_output steps.  Gemini has no speed or
;; language field: the language is detected from the text, and
;; instructions go into a speech_metadata annotation.  The key comes
;; from auth-source, the same entry gptel uses:
;;
;;   machine generativelanguage.googleapis.com login apikey password ...
;;
;;   (utter-make-gemini "Gemini")

;;; Code:

(require 'utter-core)

(defconst utter-gemini-voices
  '("Kore" "Zephyr" "Puck" "Charon" "Fenrir" "Leda" "Orus" "Aoede" "Callirrhoe"
    "Autonoe" "Enceladus" "Iapetus" "Umbriel" "Algieba" "Despina" "Erinome"
    "Algenib" "Rasalgethi" "Laomedeia" "Achernar" "Alnilam" "Schedar" "Gacrux"
    "Pulcherrima" "Achird" "Zubenelgenubi" "Vindemiatrix" "Sadachbia"
    "Sadaltager" "Sulafat")
  "The prebuilt Gemini TTS voices.")

(cl-defstruct (utter-gemini (:include utter-backend)
                            (:constructor utter--make-gemini)
                            (:copier nil))
  "A Gemini Interactions text-to-speech backend.")

(defun utter-gemini--header (backend _info)
  "Return the x-goog-api-key header for BACKEND, or nil without a key."
  (when-let* ((key (utter--get-api-key backend)))
    `(("x-goog-api-key" . ,key))))

(defun utter-gemini--last-audio (steps)
  "Return the last audio part in the model_output entries of STEPS."
  (car (last
        (cl-loop for step in steps
                 when (equal (alist-get 'type step) "model_output")
                 append (cl-remove-if-not
                         (lambda (part) (equal (alist-get 'type part) "audio"))
                         (alist-get 'content step))))))

;;;###autoload
(cl-defun utter-make-gemini
    (name &key (host "generativelanguage.googleapis.com")
          (key #'utter-api-key-from-auth-source) curl-args request-params
          (models '(gemini-3.8-flash-tts gemini-3.8-flash-lite-tts))
          (voices utter-gemini-voices))
  "Register and return a Gemini speech backend called NAME.
HOST is the API host.  KEY is a string, symbol or function; it
defaults to auth-source by HOST.  CURL-ARGS are extra curl
arguments and REQUEST-PARAMS a plist merged last into the body.
MODELS and VOICES list model ids and voice names; the first of
each is the default."
  (declare (indent 1))
  (setf (utter-get-backend name)
        (utter--make-gemini
         :name name :host host :protocol "https" :endpoint "/v1beta/interactions"
         :key key :header #'utter-gemini--header
         :models models :voices voices :formats '(wav) :max-chars 4000
         :response-kind 'b64-json
         :response-path (list 'steps (lambda (steps) (utter-gemini--last-audio steps)) 'data)
         :capabilities '(instructions)
         :curl-args curl-args :request-params request-params)))

(cl-defmethod utter--normalize-params ((backend utter-gemini) params)
  "Set PARAMS' :format to wav, the only output of Gemini BACKEND."
  (setq params (plist-put params :format 'wav))
  (cl-call-next-method backend params))

(cl-defmethod utter--request-data ((_backend utter-gemini) text params)
  "Return the Interactions body for TEXT with PARAMS."
  (let ((model (plist-get params :model))
        (style (plist-get params :instructions)))
    (list :model (if (symbolp model) (symbol-name model) model)
          :input (vector
                  (append (list :type "user_input"
                                :content (vector (list :type "text" :text text)))
                          (when (and style (not (string-empty-p style)))
                            (list :annotations
                                  (vector (list :type "speech_metadata" :style style))))))
          :response_format (list :type "audio")
          :generation_config
          (list :speech_config (vector (list :voice (or (plist-get params :voice) "Kore")))))))

(provide 'utter-gemini)
;;; utter-gemini.el ends here
