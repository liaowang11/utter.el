;;; utter-xai-tests.el --- Tests for utter-xai -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the xAI backend against the local stub server.

;;; Code:

(require 'ert)
(require 'utter-core-tests)
(require 'utter-xai)

(defconst utter-xai-test-voices-json
  "{\"voices\":[{\"voice_id\":\"eve\",\"name\":\"Eve\",\"language\":\"multilingual\",\"gender\":\"female\"},{\"voice_id\":\"atlas\",\"name\":\"Atlas\",\"language\":\"multilingual\",\"gender\":\"male\"}]}"
  "A /v1/tts/voices response.")

(ert-deftest utter-xai-test-make ()
  (let* ((utter--known-backends nil)
         (b (utter-make-xai "xAI")))
    (should (utter-xai-p b))
    (should (eq (utter-get-backend "xAI") b))
    (should (eq (utter-backend-voices b) 'fetch))
    (should (equal (utter-backend-formats b) '(mp3 wav)))
    (should (eq (utter-backend-key b) #'utter-api-key-from-auth-source))
    (should (equal (utter-backend-host b) "api.x.ai"))))

(ert-deftest utter-xai-test-dry-run ()
  (let* ((b (utter-make-xai "xAI-dry" :key "x-secret"))
         (d (utter-request "Hello" :backend b :voice "atlas" :language 'en :dry-run t)))
    (should (equal (plist-get d :url) "https://api.x.ai/v1/tts"))
    (should (equal (plist-get d :headers)
                   '(("Content-Type" . "application/json") ("Authorization" . "[redacted]"))))
    (should (equal (plist-get d :body)
                   '(:text "Hello" :voice_id "atlas" :language "en"
                     :output_format (:codec "mp3") :with_timestamps t)))
    (should-not (string-search "x-secret" (format "%S" d)))
    ;; Default voice, wav codec, explicit language string.
    (should (equal (plist-get (utter-request "Hi" :backend b :format 'wav :language "fr" :dry-run t) :body)
                   '(:text "Hi" :voice_id "eve" :language "fr"
                     :output_format (:codec "wav") :with_timestamps t)))))

(ert-deftest utter-xai-test-language-auto ()
  (let ((b (utter-make-xai "xAI-lang" :key "k")))
    (should (equal (plist-get (plist-get (utter-request "Plain English." :backend b :dry-run t) :body)
                              :language)
                   "en"))
    (should (equal (plist-get (plist-get (utter-request "你好，世界。" :backend b :dry-run t) :body)
                              :language)
                   "zh"))
    (should (equal (plist-get (plist-get (utter-request "こんにちは" :backend b :dry-run t) :body)
                              :language)
                   "ja"))))

(ert-deftest utter-xai-test-voice-name-to-id ()
  (let* ((utter--voice-cache (make-hash-table :test #'equal))
         (b (utter-make-xai "xAI-names" :key "k")))
    (utter--cache-voices b '(("Eve" :id "eve" :description "female") ("Atlas" :id "atlas" :description "male")))
    (should (equal (plist-get (plist-get (utter-request "x" :backend b :voice "Atlas" :dry-run t) :body)
                              :voice_id)
                   "atlas"))
    ;; Ids and unknown names pass through unchanged.
    (should (equal (plist-get (plist-get (utter-request "x" :backend b :voice "helios" :dry-run t) :body)
                              :voice_id)
                   "helios"))))

(ert-deftest utter-xai-test-list-voices ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/v1/tts/voices" 200 "application/json" ,utter-xai-test-voices-json))
    (let* ((utter--voice-cache (make-hash-table :test #'equal))
           (b (utter-make-xai "xAI-voices" :key "x-k"))
           got)
      (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
      (utter--list-voices b (lambda (v) (setq got v)))
      (should (utter-test-wait (lambda () got)))
      (should (equal got '(("Eve" :id "eve" :description "female")
                           ("Atlas" :id "atlas" :description "male"))))
      (let ((sreq (car utter-test-requests)))
        (should (equal (plist-get sreq :path) "/v1/tts/voices"))
        (should (equal (cdr (assoc "authorization" (plist-get sreq :headers))) "Bearer x-k"))))))

(ert-deftest utter-xai-test-request ()
  (skip-unless (executable-find "curl"))
  (let ((body (json-serialize
               (list :audio (base64-encode-string utter-test-mp3 t)
                     :content_type "audio/mpeg" :duration 2.87
                     :audio_timestamps
                     (list :graph_chars ["H" "i"]
                           :graph_times [[0 1.1] [1.1 2.87]])))))
    (utter-test-with-server `(("/v1/tts" 200 "application/json" ,body))
      (let* ((b (utter-make-xai "xAI-req" :key "x-live")))
        (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
        (let* ((res (utter-test-request "Hi" :backend b :cache nil))
               (sreq (car utter-test-requests))
               (json (json-parse-string (plist-get sreq :body) :object-type 'plist))
               (alignment (plist-get (cadr res) :alignment)))
          (should (car res))
          (should (equal (utter-test-file-bytes (car res)) utter-test-mp3))
          (should (equal (plist-get sreq :path) "/v1/tts"))
          (should (equal (cdr (assoc "authorization" (plist-get sreq :headers))) "Bearer x-live"))
          (should (equal (plist-get json :text) "Hi"))
          (should (equal (plist-get json :voice_id) "eve"))
          (should (equal (plist-get json :language) "en"))
          (should (eq (plist-get json :with_timestamps) t))
          (should (equal alignment '(:characters "Hi" :starts [0 1.1] :ends [1.1 2.87])))
          (delete-file (car res)))))))

(ert-deftest utter-xai-test-cache-alignment-and-legacy-audio-miss ()
  (skip-unless (executable-find "curl"))
  (let ((body (json-serialize
               (list :audio (base64-encode-string utter-test-mp3 t)
                     :content_type "audio/mpeg" :duration 2.87
                     :audio_timestamps
                     (list :graph_chars ["H" "i"]
                           :graph_times [[0 1.1] [1.1 2.87]])))))
    (utter-test-with-temp-dir dir
      (let* ((utter-cache-directory dir)
             (legacy-key (utter-cache-key
                          (utter--make-backend :name "xAI-cache")
                          '(:model grok-tts :speed 1.0 :format mp3) "Hi"))
             (legacy-file (utter-cache-file legacy-key 'mp3)))
        (utter-test-write-bytes legacy-file utter-test-mp3)
        (utter-test-with-server `(("/v1/tts" 200 "application/json" ,body))
          (let ((b (utter-make-xai "xAI-cache" :key "k")))
            (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
            (let* ((first (utter-test-request "Hi" :backend b))
                   (second (utter-test-request "Hi" :backend b))
                   (sidecar (utter-cache-alignment-file (file-name-base (car first))))
                   (expected '(:characters "Hi" :starts [0 1.1] :ends [1.1 2.87])))
              (should (car first))
              (should-not (plist-get (cadr first) :cached))
              (should (equal (plist-get (cadr first) :alignment) expected))
              (should (plist-get (cadr second) :cached))
              (should (equal (plist-get (cadr second) :alignment) expected))
              (should (= (length utter-test-requests) 1))
              (should (file-exists-p sidecar))
              (utter-cache-clear)
              (should-not (file-exists-p sidecar)))))))))

(ert-deftest utter-xai-test-malformed-alignment-falls-back ()
  (skip-unless (executable-find "curl"))
  (let ((body (json-serialize
               (list :audio (base64-encode-string utter-test-mp3 t)
                     :content_type "audio/mpeg"
                     :audio_timestamps
                     (list :graph_chars ["H" "o"]
                           :graph_times [[0 0.5] [0.5 1.0]])))))
    (utter-test-with-server `(("/v1/tts" 200 "application/json" ,body))
      (let ((b (utter-make-xai "xAI-malformed" :key "k")))
        (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
        (let ((res (utter-test-request "Hi" :backend b :cache nil)))
          (should (car res))
          (should (equal (utter-test-file-bytes (car res)) utter-test-mp3))
          (should-not (plist-get (cadr res) :alignment))
          (delete-file (car res)))))))

(ert-deftest utter-xai-test-error ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server
      '(("/v1/tts" 422 "text/plain; charset=utf-8"
         "Failed to deserialize the JSON body into the target type: output_format: invalid type"))
    (let* ((b (utter-make-xai "xAI-err" :key "bad")))
      (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
      (let ((res (utter-test-request "x" :backend b :cache nil)))
        (should (= (plist-get (cadr res) :http-status) 422))
        (should (string-prefix-p "HTTP 422: Failed to deserialize" (plist-get (cadr res) :error)))))))

(provide 'utter-xai-tests)
;;; utter-xai-tests.el ends here
