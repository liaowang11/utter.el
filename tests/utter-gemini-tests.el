;;; utter-gemini-tests.el --- Tests for utter-gemini -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the Gemini Interactions backend against the stub server.

;;; Code:

(require 'ert)
(require 'utter-core-tests)
(require 'utter-gemini)

(ert-deftest utter-gemini-test-dry-run ()
  (let* ((b (utter-make-gemini "Gemini-dry" :key "g-secret"))
         (d (utter-request "你好" :backend b :voice "Puck" :instructions "Cheerful" :dry-run t)))
    (should (utter-gemini-p b))
    (should (eq (utter-backend-response-kind b) 'b64-json))
    (should (equal (plist-get d :url)
                   "https://generativelanguage.googleapis.com/v1beta/interactions"))
    (should (equal (plist-get d :headers)
                   '(("Content-Type" . "application/json") ("x-goog-api-key" . "[redacted]"))))
    (should (equal (plist-get d :body)
                   '(:model "gemini-3.8-flash-tts"
                     :input [(:type "user_input"
                              :content [(:type "text" :text "你好")]
                              :annotations [(:type "speech_metadata" :style "Cheerful")])]
                     :response_format (:type "audio")
                     :generation_config (:speech_config [(:voice "Puck")]))))
    ;; Serializable as JSON.
    (should (stringp (utter--json-encode (plist-get d :body))))
    (should (equal (plist-get (aref (plist-get (plist-get (plist-get (utter-request "x" :backend b :dry-run t) :body)
                                                          :generation_config)
                                               :speech_config)
                                    0)
                              :voice)
                   "Kore"))))

(ert-deftest utter-gemini-test-request ()
  (skip-unless (executable-find "curl"))
  (let* ((wav (utter-test-wav-bytes))
         (old (base64-encode-string (concat (utter--wav-header 2 24000) "\0\0") t))
         (new (base64-encode-string wav t)))
    (utter-test-with-server
        `(("/v1beta/interactions" 200 "application/json"
           ,(format "{\"steps\":[{\"type\":\"model_output\",\"content\":[{\"type\":\"audio\",\"data\":\"%s\"}]},{\"type\":\"thought\"},{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\"x\"},{\"type\":\"audio\",\"data\":\"%s\"}]}]}"
                    old new)))
      (let* ((b (utter-make-gemini "Gemini-req" :key "g-live")))
        (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
        (let* ((res (utter-test-request "Hello" :backend b :cache nil))
               (sreq (car utter-test-requests)))
          (should (car res))
          ;; The last audio part wins.
          (should (equal (utter-test-file-bytes (car res)) wav))
          (should (eq (plist-get (cadr res) :format) 'wav))
          (should (equal (cdr (assoc "x-goog-api-key" (plist-get sreq :headers))) "g-live"))
          (delete-file (car res)))))))

(ert-deftest utter-gemini-test-error-array ()
  (skip-unless (executable-find "curl"))
  (utter-test-with-server
      '(("/v1beta/interactions" 403 "application/json"
         "[{\"error\":{\"code\":403,\"message\":\"Method doesn't allow unregistered callers.\",\"status\":\"PERMISSION_DENIED\"}}]"))
    (let* ((b (utter-make-gemini "Gemini-err" :key nil)))
      (setf (utter-backend-protocol b) "http" (utter-backend-host b) host)
      (let ((res (utter-test-request "x" :backend b :cache nil)))
        (should (equal (plist-get (cadr res) :error)
                       "HTTP 403: Method doesn't allow unregistered callers."))
        (should-not (assoc "x-goog-api-key" (plist-get (car utter-test-requests) :headers)))))))

(provide 'utter-gemini-tests)
;;; utter-gemini-tests.el ends here
