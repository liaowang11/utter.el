# utter.el

Read text aloud in Emacs through many text-to-speech backends: macOS
`say`, any OpenAI-compatible `/v1/audio/speech` server (OpenAI,
OpenRouter, Kokoro-FastAPI, mlx-audio, LocalAI, ...) and ElevenLabs. One
transient menu drives everything.

**Status: work in progress.** The API is being built against the
contract in [DESIGN.md](DESIGN.md); names there are authoritative where
this README and the code disagree. Requires Emacs 30.1 or later.

## Design rules

- **The menu is the product.** `utter-menu` exposes every parameter,
  input source, output target and playback control. `utter-speak` is the
  menu's `RET` with default arguments, as `gptel-send` is to `gptel-menu`.
- **Async listening.** Text is copied when you ask for it and never
  re-read from the buffer. There is one global queue. Point never moves,
  windows never recenter, no buffer pops up. The only default indicator
  is a short lighter in the mode line (`♪`, `♪2/5`, `⏸`); completion and
  errors go to the echo area.
- **Highlighting is opt-in** (`utter-highlight`, off by default), and it
  is dropped as soon as the source buffer changes.
- **The header line and local keys exist only in `utter-mode`**, which
  turns on by itself only in the queue buffer. Ordinary buffers are never
  touched.
- **The utterance is the unit.** One speak request is one utterance;
  next/previous, the lighter and the queue buffer all count utterances.
- **Append by default.** Speaking adds to the queue. Interrupting is
  explicit: `utter-speak-interrupt`, or `S` in the menu.
- **No default keybindings.** The package binds nothing globally; bind
  `utter-menu` or `utter-speak` yourself.

## Install

Not on MELPA yet. With Emacs 30's built-in `use-package` and `:vc`:

```elisp
(use-package utter
  :vc (:url "https://github.com/liaowang11/utter.el" :rev :newest)
  :commands (utter-menu utter-speak))
```

With straight.el:

```elisp
(straight-use-package
 '(utter :host github :repo "liaowang11/utter.el"))
```

Runtime needs: `curl` for cloud and local servers, and a player
(`afplay` on macOS; `ffplay` or `mpv` elsewhere).

## Configuration

On macOS the `say` backend is registered and selected at load time, so
`M-x utter-speak` works with no setup. Elsewhere there is no default
backend; define one.

```elisp
(use-package utter
  :vc (:url "https://github.com/liaowang11/utter.el" :rev :newest)
  :commands (utter-menu utter-speak)
  :config
  ;; macOS say, limited to two voices in the voice picker.
  (utter-make-say "say" :voices '("Samantha" "Tingting"))

  ;; OpenAI.  The key comes from auth-source for api.openai.com.
  (setq utter-backend (utter-make-openai "OpenAI"))

  ;; Kokoro-FastAPI on this machine: same protocol, no key.
  (utter-make-openai "Kokoro"
    :host "localhost:8880" :protocol "http"
    :models '(kokoro)
    :voices '("af_heart" "zf_xiaobei")
    :formats '(mp3 wav)
    :request-params '(:stream :false))

  ;; ElevenLabs.  Voices are fetched from the API when you pick one.
  (utter-make-elevenlabs "ElevenLabs")

  ;; A named bundle of settings, selectable with @ in the menu.
  (utter-make-preset 'zh-narrator
    :description "Chinese narration on local Kokoro"
    :backend "Kokoro" :voice "zf_xiaobei" :speed 1.1 :language 'zh)

  ;; Voice per detected language when utter-language is auto.
  (setq utter-voice-alist '((zh . "Tingting") (en . "Samantha"))))

;; Your own binding; the package ships none.
(keymap-global-set "C-c u" #'utter-menu)
```

Keys are looked up in auth-source by host with the user `apikey`, the
same entry gptel uses. In `~/.authinfo.gpg`:

```
machine api.openai.com login apikey password sk-...
machine api.elevenlabs.io login apikey password ...
```

`:key` also accepts a string, a variable symbol, or a function. Keys
are passed to curl on stdin, never on the command line.

## Commands

| Command | What it does |
|---|---|
| `utter-menu` | The transient menu: backend, voice, speed, format, language, input, output, playback |
| `utter-speak` | Speak the region, else the thing at point (such as a gptel response), else the sentence at point; appends. `C-u` opens the menu |
| `utter-speak-interrupt` | Same text selection, but stop what is playing and speak it now |
| `utter-speak-buffer` | Speak the buffer (from point with a prefix argument) |
| `utter-speak-kill` | Speak the latest kill |
| `utter-speak-string` | Lisp entry point for other packages and `emacsclient -e` |
| `utter-save-to-file` | Synthesize text into an audio file |
| `utter-select-voice` | Pick a voice for the current backend |
| `utter-pause`, `utter-resume`, `utter-toggle-pause` | Pause and resume playback |
| `utter-next`, `utter-previous` | Move between utterances |
| `utter-rate-up`, `utter-rate-down` | Change playback rate by 0.1 without new requests |
| `utter-stop`, `utter-clear` | Stop everything; drop pending utterances (`C-u` also finished ones) |
| `utter-log` | Show the request log |

The queue buffer (`Q` in the menu) lists one row per utterance with its
status, backend and voice, first words, progress and source. There,
`utter-mode` provides `SPC` pause, `n`/`p` next/previous, `+`/`-` rate,
`x` clear, `q` stop, `m` menu and `RET` visit source.

## How it works

1. **Snapshot.** The text is copied as a string when you ask. Editing or
   killing the buffer afterwards does not change what is spoken.
2. **Clean up and split.** `utter-preprocess-functions` strip markup,
   replace URLs and apply `utter-pronunciation-alist`. The text is then
   split at sentence ends into pieces that fit the backend's per-request
   limit, with a short first piece so audio starts quickly.
3. **Prefetch.** Each piece is synthesized by an async `curl` process
   (or `say -o`), two pieces ahead of playback, so audio stays
   continuous while you work elsewhere.
4. **Cache.** Audio lands in `utter-cache-directory`, keyed by backend,
   model, voice, speed, format, language, instructions and text, so
   repeats are free. The cache is pruned at 500 MB.
5. **Play.** `afplay` plays each file in order (`ffplay` or `mpv` where
   `afplay` is missing). Pause and resume are SIGSTOP and SIGCONT;
   rate changes go to the player.

Every response is checked: HTTP errors, JSON error bodies returned with
status 200, and non-audio bytes are reported instead of played.

## Backends

| Backend | Constructor | Status |
|---|---|---|
| macOS `say` | `utter-make-say` | MVP |
| OpenAI `/v1/audio/speech` and compatibles: OpenAI, OpenRouter, Kokoro-FastAPI, mlx-audio, LocalAI, speaches | `utter-make-openai` | MVP |
| ElevenLabs | `utter-make-elevenlabs` | MVP |
| Gemini (`/v1beta/interactions`) | | Optional, after MVP |
| Azure, Amazon Polly, Cartesia, Deepgram, Fish Audio, Piper, MiniMax, DashScope Qwen TTS, Volcengine, Hume, Inworld | | Planned |

## Development

```sh
make compile                             # byte-compile
make test                                # all ERT tests, batch
make test-file FILE=tests/utter-core-tests.el
make lint                                # checkdoc, plus package-lint if installed
make lint-deps                           # install package-lint from MELPA
make check                               # compile + test
```

Tests run without network, API keys or macOS binaries;
`tests/support/utter-test-server.el` is a local HTTP stub for backend
tests. See [DESIGN.md](DESIGN.md) for the module layout and conventions.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
