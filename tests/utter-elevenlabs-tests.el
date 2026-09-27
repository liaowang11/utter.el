;;; utter-elevenlabs-tests.el --- Tests for utter-elevenlabs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the ElevenLabs backend against the local stub server.

;;; Code:

(require 'ert)
(require 'utter-core-tests)
(require 'utter-elevenlabs)

(defconst utter-el-test-voices-json
  "{\"voices\":[{\"voice_id\":\"JBFqnCBsd6RMkjVDRZzb\",\"name\":\"George\",\"labels\":{\"accent\":\"british\"}},{\"voice_id\":\"abcdefghij0123456789\",\"name\":\"Mei\"}],\"has_more\":false}"
  "A /v2/voices response.")

(ert-deftest utter-el-test-make ()
  (let* ((utter--known-backends nil)
         (b (utter-make-elevenlabs "ElevenLabs")))
    (should (utter-elevenlabs-p b))
    (should (eq (utter-get-backend "ElevenLabs") b))
    (should (eq (utter-backend-voices b) 'fetch))
    (should (equal (utter-backend-formats b) '(mp3 pcm)))
    (should (eq (utter-backend-key b) #'utter-api-key-from-auth-source))
    (should (equal (utter-backend-host b) "api.elevenlabs.io"))))

(ert-deftest utter-el-test-dry-run ()
  (let* ((utter--voice-cache (make-hash-table :test #'equal))
         (b (utter-make-elevenlabs "EL-dry" :key "xi-secret"))
         (d (utter-request "Hello" :backend b :voice "abcdefghij0123456789" :speed 1.1
                           :context '(:previous "Before." :next "After.") :dry-run t)))
    (should (equal (plist-get d :url)
                   "https://api.elevenlabs.io/v1/text-to-speech/abcdefghij0123456789?output_format=mp3_44100_128"))
    (should (equal (plist-get d :headers)
                   '(("Content-Type" . "application/json") ("xi-api-key" . "[redacted]"))))
    (should (equal (plist-get d :body)
                   '(:text "Hello" :model_id "eleven_multilingual_v2"
                     :voice_settings (:speed 1.1)
                     :previous_text "Before." :next_text "After.")))
    (should-not (string-search "xi-secret" (format "%S" d)))
    ;; pcm output format, default voice, clamped speed, no context
    (let ((d (utter-request "Hi" :backend b :format 'pcm :speed 3 :dry-run t)))
      (should (equal (plist-get d :url)
                     (concat "https://api.elevenlabs.io/v1/text-to-speech/"
                             utter-elevenlabs-default-voice-id "?output_format=pcm_24000")))
      (should (equal (plist-get d :body)
                     '(:text "Hi" :model_id "eleven_multilingual_v2" :voice_settings (:speed 1.2)))))
    ;; language_code is sent to models that accept it
    (should (equal (plist-get (plist-get (utter-request "Hi" :backend b :model 'eleven_v3 :language "zh"
                                                        :dry-run t)
                                         :body)
                              :language_code)
                   "zh"))
    (should-not (plist-member (plist-get (utter-request "Hi" :backend b :language "zh" :dry-run t) :body)
                              :language_code))))

(ert-deftest utter-el-test-voice-name-to-id ()
  (let* ((utter--voice-cache (make-hash-table :test #'equal))
         (b (utter-make-elevenlabs "EL-names" :key "k")))
    (utter--cache-voices b '(("George" :id "JBFqnCBsd6RMkjVDRZzb") ("Mei" :id "abcdefghij0123456789")))
    (let ((p (utter--normalize-params b (list :voice "Mei" :model 'eleven_v3 :speed 1.0))))
      (should (equal (plist-get p :voice-id) "abcdefghij0123456789"))
      (should (equal (plist-get p :voice) "Mei")))
    (should (string-search "/abcdefghij0123456789?"
                           (plist-get (utter-request "x" :backend b :voice "Mei" :dry-run t) :url)))
    ;; Unknown names and ids pass through unchanged.
    (should (equal (plist-get (utter--normalize-params b (list :voice "zzzzzzzzzzzzzzzzzzzz")) :voice-id)
                   "zzzzzzzzzzzzzzzzzzzz"))))

(ert-deftest utter-el-test-list-voices ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/v2/voices" 200 "application/json" ,utter-el-test-voices-json))
    (let* ((utter--voice-cache (make-hash-table :test #'equal))
           (b (utter-make-elevenlabs "EL-voices" :key "xi-k"))
           got)
      (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
      (utter--list-voices b (lambda (v) (setq got v)))
      (should (utter-test-wait (lambda () got)))
      (should (equal got '(("George" :id "JBFqnCBsd6RMkjVDRZzb" :description "british")
                           ("Mei" :id "abcdefghij0123456789"))))
      (let ((sreq (car utter-test-requests)))
        (should (equal (plist-get sreq :path) "/v2/voices?page_size=100"))
        (should (equal (cdr (assoc "xi-api-key" (plist-get sreq :headers))) "xi-k")))
      ;; Cached: no second request.
      (setq got nil)
      (utter--list-voices b (lambda (v) (setq got v)))
      (should got)
      (should (= (length utter-test-requests) 1))
      ;; And the names now resolve.
      (should (equal (plist-get (utter--normalize-params b (list :voice "George")) :voice-id)
                     "JBFqnCBsd6RMkjVDRZzb")))))

(ert-deftest utter-el-test-request ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/v1/text-to-speech/abcdefghij0123456789" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((b (utter-make-elevenlabs "EL-req" :key "xi-live")))
      (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
      (let* ((res (utter-test-request "你好" :backend b :voice "abcdefghij0123456789" :cache nil))
             (sreq (car utter-test-requests))
             (json (json-parse-string (plist-get sreq :body) :object-type 'plist)))
        (should (car res))
        (should (equal (utter-test-file-bytes (car res)) utter-test-mp3))
        (should (equal (plist-get sreq :path)
                       "/v1/text-to-speech/abcdefghij0123456789?output_format=mp3_44100_128"))
        (should (equal (cdr (assoc "xi-api-key" (plist-get sreq :headers))) "xi-live"))
        (should-not (assoc "authorization" (plist-get sreq :headers)))
        (should (equal (plist-get json :text) "你好"))
        (should (equal (plist-get json :voice_settings) '(:speed 1.0)))
        (delete-file (car res))))))

(ert-deftest utter-el-test-error ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server
      '(("/v1/text-to-speech/abcdefghij0123456789" 401 "application/json"
         "{\"detail\":{\"type\":\"authentication_error\",\"code\":\"invalid_api_key\",\"message\":\"Invalid API key\",\"status\":\"invalid_api_key\"}}"))
    (let* ((b (utter-make-elevenlabs "EL-err" :key "bad")))
      (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
      (let ((res (utter-test-request "x" :backend b :voice "abcdefghij0123456789" :cache nil)))
        (should (equal (plist-get (cadr res) :error) "HTTP 401: Invalid API key"))
        (should (= (plist-get (cadr res) :http-status) 401))))))

(provide 'utter-elevenlabs-tests)
;;; utter-elevenlabs-tests.el ends here
