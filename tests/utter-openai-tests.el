;;; utter-openai-tests.el --- Tests for utter-openai -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the OpenAI-compatible backend, including the documented
;; OpenRouter, Kokoro-FastAPI and mlx-audio keyword combinations.

;;; Code:

(require 'ert)
(require 'utter-core-tests)
(require 'utter-openai)

(ert-deftest utter-openai-test-make-defaults ()
  (let* ((utter--known-backends nil)
         (b (utter-make-openai "OpenAI")))
    (should (utter-openai-p b))
    (should (utter-backend-p b))
    (should (eq (utter-get-backend "OpenAI") b))
    (should (equal (utter--backend-url b nil) "https://api.openai.com/v1/audio/speech"))
    (should (eq (utter-backend-key b) #'utter-api-key-from-auth-source))
    (should (eq (utter-backend-response-kind b) 'bytes))
    (should (= (utter-backend-max-chars b) 4096))
    (should (equal (car (utter-backend-formats b)) 'mp3))))

(ert-deftest utter-openai-test-request-data ()
  (let* ((b (utter-make-openai "OpenAI-data" :key "sk-o"))
         (d (utter-request "Hello" :backend b :voice "nova" :speed 1.25
                           :instructions "Calm" :dry-run t))
         (body (plist-get d :body)))
    (should (equal body '(:model "gpt-4o-mini-tts" :input "Hello" :voice "nova"
                          :response_format "mp3" :speed 1.25 :instructions "Calm")))
    (should (equal (plist-get d :headers)
                   '(("Content-Type" . "application/json")
                     ("Authorization" . "[redacted]"))))
    ;; Default voice and no instructions.
    (should (equal (plist-get (plist-get (utter-request "x" :backend b :model 'tts-1 :dry-run t) :body)
                              :voice)
                   "alloy"))
    (should-not (plist-member (plist-get (utter-request "x" :backend b :dry-run t) :body)
                              :instructions))))

(ert-deftest utter-openai-test-speed-clamped ()
  (let ((b (utter-make-openai "OpenAI-clamp" :key "k")))
    (should (= (plist-get (plist-get (utter-request "x" :backend b :speed 9 :dry-run t) :body) :speed)
               4.0))
    (should (= (plist-get (plist-get (utter-request "x" :backend b :speed 0.1 :dry-run t) :body) :speed)
               0.25))))

(ert-deftest utter-openai-test-no-key-no-header ()
  (let* ((b (utter-make-openai "Local" :protocol "http" :host "localhost:9" :key nil)))
    (should (equal (plist-get (utter-request "x" :backend b :dry-run t) :headers)
                   '(("Content-Type" . "application/json"))))))

(ert-deftest utter-openai-test-instructions-key ()
  (let* ((b (utter-make-openai "mlx-audio"
              :protocol "http" :host "localhost:8000" :key nil
              :models '(mlx-community/Kokoro-82M-bf16) :formats '(wav mp3)
              :instructions-key :instruct))
         (body (plist-get (utter-request "x" :backend b :instructions "Warm" :dry-run t) :body)))
    (should (equal (plist-get body :instruct) "Warm"))
    (should-not (plist-member body :instructions))
    (should (equal (plist-get body :model) "mlx-community/Kokoro-82M-bf16"))
    (should (equal (plist-get body :response_format) "wav"))))

(ert-deftest utter-openai-test-no-instructions-capability ()
  (let* ((b (utter-make-openai "NoInstr" :key "k" :capabilities nil))
         (body (plist-get (utter-request "x" :backend b :instructions "Warm" :dry-run t) :body)))
    (should-not (plist-member body :instructions))))

(ert-deftest utter-openai-test-openrouter-preset ()
  "OpenRouter: mp3 must be forced, the endpoint differs."
  (let* ((b (utter-make-openai "OpenRouter"
              :host "openrouter.ai" :endpoint "/api/v1/audio/speech" :key "k"
              :models '(hexgrad/kokoro-82m) :voices '("zf_xiaoxiao" "af_heart")
              :formats '(mp3) :capabilities nil
              :request-params '(:response_format "mp3")))
         (d (utter-request "你好" :backend b :format 'pcm :dry-run t)))
    (should (equal (plist-get d :url) "https://openrouter.ai/api/v1/audio/speech"))
    (should (equal (plist-get (plist-get d :body) :response_format) "mp3"))
    (should (equal (plist-get (plist-get d :body) :voice) "zf_xiaoxiao"))
    (should (equal (plist-get (plist-get d :body) :model) "hexgrad/kokoro-82m"))))

(ert-deftest utter-openai-test-kokoro-preset ()
  "Kokoro-FastAPI: no key, stream false, voices from GET /v1/audio/voices."
  (skip-unless (executable-find "curl"))
  (utter-test-with-temp-dir dir
    (utter-test-with-server
        `(("/v1/audio/voices" 200 "application/json" "{\"voices\":[\"af_heart\",\"zf_xiaobei\"]}")
          ("/v1/audio/speech" 200 "audio/mpeg" ,utter-test-mp3))
      (let* ((utter-cache-directory dir)
             (utter--voice-cache (make-hash-table :test #'equal))
             (b (utter-make-openai "Kokoro"
                  :protocol "http" :host host :key nil
                  :models '(kokoro) :formats '(mp3 wav)
                  :voices #'utter-openai-fetch-voices
                  :request-params '(:stream :false)
                  :max-chars 1000 :capabilities nil))
             voices)
        (utter--list-voices b (lambda (v) (setq voices v)))
        (should (utter-test-wait (lambda () voices)))
        (should (equal voices '("af_heart" "zf_xiaobei")))
        (should (equal (plist-get (car utter-test-requests) :path) "/v1/audio/voices"))
        (let* ((res (utter-test-request "你好" :backend b :voice "zf_xiaobei" :cache nil))
               (sreq (car utter-test-requests))
               (json (json-parse-string (plist-get sreq :body) :object-type 'plist)))
          (should (car res))
          (should (equal (utter-test-file-bytes (car res)) utter-test-mp3))
          (should-not (assoc "authorization" (plist-get sreq :headers)))
          (should (eq (plist-get json :stream) :false))
          (should (equal (plist-get json :input) "你好"))
          (should (equal (plist-get json :voice) "zf_xiaobei"))
          (delete-file (car res)))))))

(ert-deftest utter-openai-test-mlx-voices-shape ()
  (should (equal (utter-openai--parse-voices
                  '((data ((id . "af_heart") (name . "Heart")) ((id . "zf_xiaobei")))))
                 '(("af_heart" :description "Heart") "zf_xiaobei")))
  (should (equal (utter-openai--parse-voices '((voices "a" "b"))) '("a" "b")))
  (should-not (utter-openai--parse-voices nil)))

(ert-deftest utter-openai-test-error-body ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server
      '(("/v1/audio/speech" 400 "application/json"
         "{\"detail\":{\"error\":\"validation_error\",\"message\":\"Voice not found\",\"type\":\"invalid_request_error\"}}"))
    (let* ((b (utter-make-openai "Kokoro-err" :protocol "http" :host host :key nil))
           (res (utter-test-request "x" :backend b :cache nil)))
      (should (equal (plist-get (cadr res) :error) "HTTP 400: Voice not found")))))

(ert-deftest utter-openai-test-key-in-config-not-argv ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server `(("/v1/audio/speech" 200 "audio/mpeg" ,utter-test-mp3))
    (let* ((b (utter-make-openai "OpenAI-e2e" :protocol "http" :host host :key "sk-live-123"))
           (req nil) (res nil))
      (setq req (utter-request "x" :backend b :cache nil
                               :callback (lambda (a i) (setq res (list a i)))))
      (should-not (cl-some (lambda (a) (string-search "sk-live-123" a))
                           (process-command (utter-request-process req))))
      (should (utter-test-wait (lambda () res)))
      (should (equal (cdr (assoc "authorization" (plist-get (car utter-test-requests) :headers)))
                     "Bearer sk-live-123"))
      (delete-file (car res)))))

(provide 'utter-openai-tests)
;;; utter-openai-tests.el ends here
