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
;; interface; `utter-speak' is its default action.  See DESIGN.md.
;;
;; This file is the package main file and is owned by the ENGINE module;
;; it is a stub until that module lands.

;;; Code:

(provide 'utter)
;;; utter.el ends here
