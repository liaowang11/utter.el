# utter.el design contract

Read aloud in Emacs through many text-to-speech backends, driven by one
transient menu. This file is the contract between the modules. It
supersedes `~/PARA/projects/emacs-tts-package/api-design.md` where they
differ (that document still has the rationale and longer examples; its
body predates the corrections applied here).

## Rules that shaped the design (Bill, 2026-09-27)

1. **The transient menu is the product.** `utter-menu` exposes every
   parameter, input source, output target and playback control.
   `utter-speak` is the convenience command: the menu's `RET` with default
   arguments, the same relationship as `gptel-send` to `gptel-menu`.
2. **Async listening.** Text is snapshotted at request time and never
   re-read from the buffer. One global queue. Point never moves, windows
   never recenter, no buffer pops up. The only default indicator is a short
   lighter in `global-mode-string`. Completion and errors use `message`.
3. **Highlight is opt-in and off by default** (`utter-highlight`). It is
   dropped as soon as the source buffer changes after capture.
4. **Header line and local keys exist only inside `utter-mode`**, which is
   auto-enabled only in the queue buffer. Ordinary buffers never get either.
5. **Chunks are internal.** The user-facing unit is the *utterance*: one
   speak request. No user-visible string, key description, lighter, column,
   command name or defcustom may say "chunk". Internally the text is split
   into request-sized *segments*; that word stays in private symbols and
   code comments only.
6. **Append is the default.** `utter-speak` and `utter-speak-string`
   append to the queue. Interrupting is explicit: `utter-speak-interrupt`,
   `utter-interrupt`, or the `S` switch in the menu.
7. **No default keybindings.** The package binds nothing globally. The only
   keymap it owns is `utter-mode-map`, active where `utter-mode` is on.
8. **Standalone package.** Emacs 30.1+, `cl-lib`, `transient`. No other
   hard dependency. gptel is an optional key source, never required.

## Layering and file ownership

| File | Owner | Contents | Requires |
|---|---|---|---|
| `utter-core.el` | CORE | backend struct, generics, key lookup, curl runner, decoders, `utter-request`, `utter-fetch-json`, cache | cl-lib, auth-source, json |
| `utter-say.el` | CORE | macOS `say` backend (`process` kind) | core |
| `utter-openai.el` | CORE | OpenAI-compatible `/v1/audio/speech` backend (OpenAI, OpenRouter, Kokoro-FastAPI, mlx-audio, LocalAI…) | core |
| `utter-elevenlabs.el` | CORE | ElevenLabs backend (bytes; voices fetched) | core |
| `utter-gemini.el` | CORE, optional | Gemini `/v1beta/interactions` (b64-json WAV) | core |
| `utter-xai.el` | CORE, optional | xAI `/v1/tts` grok-tts (bytes mp3/wav; voices fetched from `/v1/tts/voices`) | core |
| `utter-text.el` | ENGINE | preprocessing, sentence splitting into segments (private) | core (for `max-chars`) |
| `utter-queue.el` | ENGINE | item/segment/queue structs, player struct, prefetch, `utter-state`, lighter, highlight | core, text |
| `utter.el` | ENGINE | package main file: defcustoms, `utter-speak*` commands, `utter-enqueue`/`utter-interrupt` entry points, presets, scope, thing-at-point | queue |
| `utter-transient.el` | UI | `utter-menu`, infix classes, `utter--suffix-speak` | utter, transient |
| `utter-mode.el` | UI | `utter-mode` (header line, keymap), `utter-queue-mode` and `*utter-queue*` | utter |
| `Makefile`, `.github/`, `tests/support/`, `README.md` | ENV | build, CI, test helpers incl. a local HTTP stub server | |

Dependencies point one way: backends → core ← text ← queue ← utter ←
{transient, mode}. **The menu depends on the engine, never the reverse.**
`utter-speak` lives in `utter.el` and calls `utter-enqueue` directly; the
transient suffix calls the same functions with menu arguments.

Ownership rules for parallel work:
- Owners define every symbol in their files. Non-owners `require` and use
  what this contract promises; they never add definitions to another
  owner's file.
- A missing or wrong symbol goes into the `HANDOFF` section of the
  owner's report (`reports/<area>.md`), and into a test that documents the
  expectation, not into another owner's file.
- Tests live in `tests/<file>-tests.el`, one per source file, and must run
  with `make test` on Linux without network, without macOS binaries, and
  without API keys. Tests that need `say`/`afplay` use `skip-unless`.

## Frozen signatures (do not change without updating this file)

### Core

```elisp
(cl-defstruct (utter-backend (:constructor utter--make-backend) (:copier utter--copy-backend))
  name host protocol endpoint url header key
  models voices formats max-chars
  (max-chars-unit 'chars)            ; chars | bytes | utf16
  (response-kind 'bytes)             ; bytes | b64-json | b64-lines | hex | url | process
  response-path                      ; for b64-json: list of keys/indices to the audio string
  capabilities                       ; (instructions ssml timestamps stitching clone)
  request-params curl-args body-transform
  (coding-system 'binary))

(utter-get-backend NAME)                       ; gv-setf-able registry, alist utter--known-backends
(utter--get-api-key BACKEND)                   ; string | symbol | function -> string or nil
(utter-api-key-from-auth-source &optional BACKEND-OR-HOST USER) ; :host H :user "apikey"
(utter-key-from-gptel &optional NAME-OR-HOST)  ; returns a key FUNCTION; falls back to auth-source

(cl-defgeneric utter--request-data (backend text params))        ; -> plist body
(cl-defgeneric utter--normalize-params (backend params))         ; clamp/rename
(cl-defgeneric utter--response-audio (backend info callback))    ; (CALLBACK FILE FORMAT) | (CALLBACK nil ERR)
(cl-defgeneric utter--parse-error (backend info))                ; -> string or nil; RUNS ON EVERY RESPONSE
(cl-defgeneric utter--list-voices (backend callback))            ; cached per name, utter-voice-cache-ttl
(cl-defgeneric utter--start-process (backend text params file callback)) ; response-kind process

(cl-defun utter-request
    (text &key (backend utter-backend) (model utter-model) (voice utter-voice)
          (speed utter-speed) (format utter-format) language instructions
          context file callback dry-run (cache t))
  "Synthesize TEXT, which must fit BACKEND's max-chars, asynchronously.
Return an `utter-request' struct (slots: process info status).
CALLBACK is called (AUDIO INFO): AUDIO is a file name, nil on error
(INFO :error), or the symbol `abort'.  INFO keys: :backend :model :voice
:speed :format :text :file :cached :http-status :error :duration :request.
Signals `utter-text-too-long' instead of splitting.")
(utter-abort REQUEST)
(utter-fetch-json BACKEND METHOD PATH CALLBACK &optional BODY)
(utter-cache-key BACKEND PARAMS TEXT)          ; sha1 of (name model voice speed format language instructions text)
(utter-cache-lookup KEY FORMAT) (utter-cache-clear &optional OLDER-THAN-DAYS)
```

Core behaviour that is not optional:
- **curl config on stdin**: one `-K -` config carries `header = "..."`,
  `user = ...`, `url = ...`, `data = @file`. Keys never appear in argv.
  Do not use `-H@-` (curl can read only one thing from stdin).
- Body goes through a temp file (`--data-binary @file` in the config);
  `utter-request` cleans it up.
- Status via `-w '%{http_code}'` on stdout and `-o RAWFILE`.
- **Every response is checked**: non-2xx ⇒ error; then
  `utter--parse-error` runs even on 200 (MiniMax puts errors in
  `base_resp.status_code` with HTTP 200); then the `bytes` decoder sniffs
  the first bytes (`{`/`[` ⇒ JSON error body; `ID3`, `\xff\xfb`, `RIFF`,
  `fLaC`, `OggS`, `FORM` ⇒ audio) before returning a file.
- Raw PCM is wrapped in a 44-byte WAV header in the decoder, with the
  sample rate from the backend/format, so players only ever see containers.
- `b64-json` extracts by `response-path`; `b64-lines`, `hex`, `url` are
  documented extension points, not MVP.
- Dry run returns `(:url :headers :body :curl-args)` with header values
  redacted and starts no process.
- Retries are the queue's job, not core's. Core reports `:http-status`.

Constructors (all `;;;###autoload`, `(declare (indent 1))`, register and
return the backend):

```elisp
(utter-make-say NAME &key voices (formats '(aiff m4a)))   ; process kind; speed 1.0 = 175 wpm; text via -f tmpfile
(utter-make-openai NAME &key (host "api.openai.com") (protocol "https") (endpoint "/v1/audio/speech")
                   key header curl-args request-params body-transform
                   (models '(gpt-4o-mini-tts tts-1 tts-1-hd))
                   (voices '("alloy" "ash" "coral" "echo" "fable" "nova" "onyx" "sage" "shimmer"))
                   (formats '(mp3 wav opus aac flac pcm)) (max-chars 4096)
                   (capabilities '(instructions)) (instructions-key :instructions))
(utter-make-elevenlabs NAME &key (host "api.elevenlabs.io") key curl-args request-params
                       (models '(eleven_multilingual_v2 eleven_v3 eleven_flash_v2_5)))
```

Default `header` for cloud constructors is `Authorization: Bearer KEY`,
omitted when the key resolves to nil (keyless local servers). Default
`key` is auth-source by host. `request-params` is merged last into the
body; `body-transform` (function plist→plist) runs after that, for vendors
that rename keys (mlx-audio `instruct`). Known vendor quirks live in
`utter-openai.el` as documented presets of keyword args, not hidden logic:
OpenRouter needs `response_format` forced to `"mp3"`, Kokoro-FastAPI needs
`:stream :false`.

### Text (ENGINE, private except the two hooks)

```elisp
(defcustom utter-preprocess-functions
  '(utter-strip-markup utter-replace-urls utter-collapse-whitespace utter-apply-pronunciations))
(defcustom utter-pronunciation-alist nil)          ; ((REGEXP . REPLACEMENT) ...)
(utter--split TEXT MAX-CHARS &optional UNIT)         ; -> list of strings; private
(defvar utter--split-functions '(utter--split-by-sentence)) ; private abnormal hook
(defvar utter--first-segment-chars 200)             ; private; short first segment for fast first audio
```

Splitting on `sentence-end` plus `。！？；`, packing under the limit, hard
split at whitespace/punctuation only when one sentence exceeds the limit.
Never split inside SSML tags. UNIT `bytes` counts UTF-8 bytes, `utf16`
counts UTF-16 units.

### Queue and player (ENGINE)

```elisp
(cl-defstruct utter-item
  id text status                     ; pending | playing | paused | done | error | interrupted
  params                             ; resolved plist snapshot incl. the backend object
  source-buffer source-name markers  ; markers only when utter-highlight is on
  tick created
  segments (position 0))             ; PRIVATE slots: access via utter--item-segments / utter--item-position

(cl-defstruct utter--segment index text status file request error duration) ; private

(utter-enqueue TEXT &rest PARAMS)      ; snapshot, preprocess, split, append, start if idle; returns item
(utter-interrupt TEXT &rest PARAMS)    ; stop player, abort requests, mark current+pending interrupted, play TEXT now
(utter-pause) (utter-resume) (utter-toggle-pause)
(utter-next &optional N) (utter-previous &optional N)   ; move between UTTERANCES (items), not segments
(utter-stop) (utter-clear &optional ARG)                 ; clear drops pending items; C-u also finished ones
(utter-rate-up) (utter-rate-down)                        ; utter-playback-rate ± 0.1, player-side, no new request
(utter-replay-item ITEM)
(utter-state)      ; plist (:status idle|synthesizing|playing|paused :item ITEM :index I :total N
                   ;        :elapsed SECONDS :duration SECONDS-or-nil :pending N
                   ;        :backend NAME :model SYM :voice STR :rate FLOAT :source NAME)
(utter-active-p)   ; non-nil unless idle
(utter-state-string &optional FORMAT)   ; format-spec: %s status %i index %n total %b backend %m model %v voice %r rate %t elapsed %d duration %S source
```

PARAMS accepted by `utter-enqueue` / `utter-interrupt` /
`utter-speak-string`: the `utter-request` keys plus `:source-buffer
:source-name`.

Player:

```elisp
(cl-defstruct utter-player name formats command  ; command: (lambda (file rate) -> argv)
  (pause #'utter-player-sigstop) (resume #'utter-player-sigcont) (stop #'delete-process))
utter-player-afplay   ; afplay -r RATE FILE  (mp3 wav aiff m4a aac flac)
utter-player-ffplay   ; ffplay -nodisp -autoexit -loglevel error -af atempo=RATE FILE
utter-player-mpv      ; mpv --no-video --speed=RATE FILE
(defcustom utter-player 'auto)   ; first installed player that plays the segment's format
```

Pause is SIGSTOP/SIGCONT for afplay (verified: it keeps its place). ffplay
stops under SIGSTOP but skips the paused stretch on SIGCONT, so
`utter-player-ffplay` resumes by restarting at the paused offset with `-ss`
(`utter-player-restart`; a player `command` may take an optional third
argument OFFSET). mpv is not installed here and its SIGCONT path is
unverified. Prefetch
`utter-prefetch-depth` (2) segments ahead across item boundaries, at most
`utter-max-concurrent-requests` (2) curl processes. On 429/5xx retry once
with backoff, then mark the segment `error`, `message` it, continue.

Hooks (public):

```elisp
utter-pre-request-hook / utter-post-request-hook   ; per request (core)
utter-enqueue-hook            ; (ITEM) once per utterance; oneshot scope resets here
utter-progress-functions      ; (ITEM START END) START/END are positions in ITEM's text snapshot; fired when spoken text advances
utter-item-finished-functions ; (ITEM STATUS)
utter-queue-finished-hook     ; () queue went idle
utter-error-functions         ; (ITEM ERROR-STRING) default: message
utter-notify-function         ; nil | (lambda (title body))
utter--segment-context-function ; private: (ITEM INDEX) -> (:previous :next) for stitching backends
utter--state-change-hook       ; private: () on every state change incl. pause/resume/rate; UI redraws from it, no timer
```

Lighter: `utter-lighter` default `" ♪%i/%n"` where `%i/%n` counts
utterances and collapses to `" ♪"` when there is one; `⟳` while
synthesizing before first audio, `⏸` paused, `✗CODE` on error. Added to
`global-mode-string` only while active; nil disables.

Highlight: `utter-highlight` (nil). When on and the source is a live
buffer, the item keeps segment markers and one overlay (face
`utter-highlight`) follows `utter-progress-functions`. When
`buffer-chars-modified-tick` differs from the captured tick, remove the
overlay and markers for that item. `utter-highlight-follow` (nil) is the
only thing that may move point or recenter.

### Commands and defcustoms (ENGINE, in `utter.el`)

```elisp
(utter-speak &optional ARG)          ; region → source claiming point (utter-input-functions) → buffer start to point (whole buffer when point is at the start); C-u opens utter-menu
(utter-speak-interrupt &optional ARG); same text selection, via utter-interrupt
(utter-speak-string STRING &rest PARAMS)   ; non-UI entry point; works from emacsclient -e
(utter-speak-buffer &optional FROM-POINT)
(utter-speak-kill)
(utter-save-to-file TEXT FILE)       ; MVP: single segment only; several → user-error pointing at ffmpeg join (later)
(utter-inspect-query)                ; dry run into *utter-inspect*
(utter-select-voice)                 ; completing-read with annotations; sets utter-voice with scope
(utter-log)                          ; pop to *utter-log*
```

| Defcustom | Default |
|---|---|
| `utter-backend` | the `say` backend on darwin (registered by `utter-say` at load), else nil → `user-error` naming `utter-make-openai` |
| `utter-model`, `utter-voice`, `utter-format` | nil = backend's/model's first |
| `utter-voice-alist` | nil; `((zh . "Tingting") (en . "Samantha"))` used when `utter-language` is `auto` |
| `utter-speed` | 1.0 (synthesis; in the cache key) |
| `utter-playback-rate` | 1.0 (player-side) |
| `utter-language` | `auto` |
| `utter-instructions` | nil |
| `utter-highlight`, `utter-highlight-follow` | nil, nil |
| `utter-lighter` | `" ♪%i/%n"` |
| `utter-prefetch-depth`, `utter-max-concurrent-requests` | 2, 2 |
| `utter-cache-directory` | `$XDG_CACHE_HOME/utter` or `~/.cache/utter` |
| `utter-cache-max-size` | 500 MB, pruned by atime at enqueue |
| `utter-voice-cache-ttl` | 86400 |
| `utter-player` | `auto` |
| `utter-curl-program`, `utter-proxy`, `utter-log-level` | "curl", "", nil |
| `utter-input-functions` | `(utter--gptel-response-at-point utter--org-subtree-at-point utter--page-at-point)`; each returns (BEG . END) or nil, labelled for the menu by the `utter-input-label` symbol property |
| `utter-page-modes` | `(eww-mode Info-mode nov-mode help-mode Man-mode woman-mode)`, read whole |
| `utter-org-input` | `subtree` (or `to-point`) |
| `utter-expert-commands` | nil |

Scope: `utter--set-scope` (nil global, t buffer-local, 1 oneshot) and
`utter--set-with-scope (SYM VALUE &optional SCOPE)`, a copy of
`gptel--set-with-scope`; the oneshot restore hangs on `utter-enqueue-hook`
with a `(lambda (&rest _))`.

Presets: `(utter-make-preset NAME &rest KEYS)` with `:description :parents
:pre :post :backend :model :voice :speed :format :language :instructions`,
other `:foo` → `utter-foo`. `(utter-get-preset NAME)`,
`(utter--apply-preset PRESET &optional SETTER)`, `(utter-with-preset NAME
&rest BODY)`.

### UI (UI owner)

`utter-menu` layout (keys are final; 2026-09-28 Bill dropped `s`, retitled
Input/Output gptel-style, and moved the rate to the rate-up label only):

```
[:description utter--menu-heading          ; "Idle" | "Playing reading-aloud.org (2/5) · OpenAI:gpt-4o-mini-tts/nova"
 ["Backend"  -m Backend:model  -v Voice  -s Speed  -f Format  -l Language  -i Instructions
             -H Highlight spoken text  = Scope (global|buffer|oneshot)  @ Preset]
 [" <Read from <label>"  m Minibuffer instead  y Kill-ring instead]
     ; label = what RET reads: region / gptel response / Org subtree / page / buffer to point /
     ; whole buffer / nothing; `minibuffer' with m; `kill-ring "first words…"' or
     ; `kill ring empty' (error face) with y
 [" >Output to"  S Speakers, interrupt  f Save to file  c Cache only]   ; append is the default, no switch
 ["Playback" :if utter-active-p
             SPC Pause/resume  n Next utterance  p Previous utterance  + Rate up (1.0x)  _ Rate down
             x Clear pending  q Stop all  Q Queue buffer]
             ; every suffix but Q is :transient t; Q exits, since the queue buffer has keys of its own
             ; rate-down is `_' because `-' is the prefix of `-m' `-v' ...; utter-mode-map has both
 [RET <what will be sent>   I Inspect (:if utter-expert-commands or utter-log-level)]]
```

- `RET`'s label states source, size and destination, computed from the
  live switches: `Speak region (lines 9-10, ~12 s), append as utterance 4`
  (while something plays; plain `Speak region (…)` when idle),
  `Speak buffer to point (lines 1-42, ~3 min), interrupt now`,
  `Save Org subtree (lines 5-30) to file`,
  `Synthesize page (lines 1-80, ~4 min), cache only`,
  `Speak minibuffer input`, `Speak kill-ring "first words…" (~5 s)`, or
  `Nothing to read aloud` in the `error` face.  The estimate is
  `utter--estimate-seconds` with `utter-speed`, as in the queued message.
  The input plan is computed once per redraw (memoized on buffer, tick,
  point, mark, region, switches and kill) and description functions never
  signal.
- Live switches while drawing: `transient-args` sees only the exported
  value inside a suffix, so `utter-transient--live-args` binds
  `transient-current-command` and `transient-current-suffixes` as gptel
  does.  `transient-get-value` is not used (not documented API in 0.7.8).
- `:refresh-suffixes t`; `:incompatible '(("m" "y") ("S" "f" "c"))`.
  Playback suffixes call the ENGINE commands directly.
- `utter--suffix-speak (args)` is the single dispatch: input switch → text,
  output switch → `utter-enqueue` / `utter-interrupt` /
  `utter-save-to-file` / cache-only (`:cache-only t` param). It must be
  callable non-interactively with `nil`.  `C-u` with `y` picks an older
  kill with `read-from-kill-ring`.  `f` checks that the text fits one
  request before asking for the file, and offers `<source>.<format>`.
- `I` resolves the text like `RET` and calls `utter--inspect-text` in the
  source buffer, so the dry run is exactly what `RET` would send.
- `utter-menu` runs `utter--sanitize-settings` before `transient-setup`,
  and `-m` runs it after changing the backend, so a model or voice the
  backend does not offer is neither shown nor sent.
- Infix classes: `utter-lisp-variable` (display-nil, display-map, and a
  `default` shown inactive, e.g. `-l auto`; scope aware),
  `utter--text-variable` (`-i`: one line, 35 chars),
  `utter-provider-variable` (compound backend+model, completion grouped by
  backend, annotation with description, capabilities as `utter--capable-p`
  sees them, `4096ch` limit and cost; `(transient-setup)` to redraw),
  `utter-voice-variable` (voices from `utter--static-voices` for the
  backend and model, else an async fetch on cache miss; free-form input
  allowed; RET keeps the current voice, the `(backend default)` candidate
  clears it), `utter-preset-variable` (reads the engine's `utter--preset`;
  struck through when a setting of the preset spec no longer holds; reader
  annotated with `:description`), `utter--scope-variable`,
  `utter--toggle-variable`.  `-f` completes with `require-match` over
  `utter--formats` for the backend and model.  `-i` is `:inapt-if` the
  model lacks `instructions`; `@` is `:inapt-if` no presets exist.  Numeric
  reader copied from `gptel--transient-read-number`.
- Heading refresh while the menu is open: `utter-transient--refresh-menu`
  sits on `utter--state-change-hook` from load time (a hook removed on
  `transient-exit-hook` would be lost on `C-z` suspend, which
  `transient-resume` never reinstalls).  It redraws with
  `transient--refresh-transient` wrapped in `transient--env-apply` when
  that exists, guarded by `(and transient--prefix (eq (oref transient--prefix
  command) 'utter-menu))`, and skips while the minibuffer is active or a
  menu suffix runs (`transient-current-command` non-nil; post-command
  redraws then).  `transient--refresh` does not exist in transient 0.13.7.
- Evil: gptel's visual-state `:environment` fix, guarded by `fboundp` and
  written inline in `transient-define-prefix`.  That slot needs transient
  0.7.8 (the declared minimum); Emacs 30.x bundles 0.7.2.2, so `make deps`
  installs transient from GNU ELPA into `.deps/elpa` and every batch target
  loads it from there when present (CI does this on every job).
- `utter-mode`: buffer-local minor mode, no lighter, sets
  `header-line-format` to `(:eval (utter--header-line))` and restores the
  old one on exit. `utter-mode-map`: `SPC` pause, `n`/`p` utterance,
  `+`/`-` rate, `q` stop, `x` clear, `m` menu, `Q` queue, `RET` visit
  source. Header line refreshes from `utter-progress-functions` and state
  changes, no timer.
- `utter-queue-mode` derives from `tabulated-list-mode`; buffer
  `*utter-queue*`, one row per utterance: status glyph, #, backend:voice,
  first words, `elapsed/duration`, source. `RET` visit source, `d` remove,
  `r` replay, `o` visit source buffer. It enables `utter-mode`.

## Decisions adopted as defaults (from api-design.md K1–K9)

- `+`/`-` change the player rate, not synthesis speed.
- Interrupted items stay listed as `interrupted`, replayable, never auto-resumed.
- No default backend off macOS.
- Voices are fetched only when the voice infix opens; cached one day.
- Oneshot scope covers one utterance.
- Highlight follows the playing text, not the synthesizing one.
- `utter-speak` with no region (decided 2026-09-28, matching gptel): a
  source from `utter-input-functions` may claim point (gptel response, Org
  subtree, page); else the buffer from its start to point, or the whole
  buffer when nothing precedes point.  The menu exposes no per-source
  switches, only the label of what RET will read plus the minibuffer and
  kill-ring overrides.  Blank input errors name the source.
- Cache pruned at 500 MB by atime.
- Multi-segment save-to-file is post-MVP.

## Repository conventions

- Emacs 30.1+ (bundled transient 0.7.2.2 has `:refresh-suffixes` and
  `transient--refresh-transient`; the `:environment` slot needs transient
  0.7.8, hence `Package-Requires` `(transient "0.7.8")`), `lexical-binding: t`,
  SPDX `GPL-3.0-or-later`, header shape as in `utter.el`.
- `make compile` (byte-compile with `load-prefer-newer`), `make test`
  (ERT batch), `make lint` (checkdoc + package-lint when available),
  `make check` = compile + test.
- TDD: write the failing test first, then the code. Commit small and
  often with terse messages. No `Co-Authored-By` or agent trailers. Never
  `--no-verify`.
- Parallel work happens in git worktrees under `~/Repositories/worktrees/utter-<area>`
  on branch `<area>`; the main session merges into `main` and deletes the
  branches. Never commit to `main` from a worktree.
- Each agent writes `reports/<area>.md` (what was built, how it was
  verified, HANDOFF list, unverified items) before finishing.

## Status (2026-09-27)

Merged from four parallel worktrees (env, core, ui, engine): 200 ERT tests
pass with `make check` on Emacs 31.1.50 and 30.2 on macOS; CI runs Linux
30.1, Linux snapshot and macOS. End-to-end in batch with the `say` backend:
`utter-speak-string` → aiff in the cache → afplay → idle in 4.3 s.
Per-module reports with HANDOFF and unverified lists are in `reports/`.

Real-server checks (2026-09-27, batch Emacs, keys from `pass`):
- OpenAI `/v1/audio/speech`: request accepted, 401 with the vendor message
  parsed (the stored key is dead); the shape is right, audio not yet heard.
- OpenRouter: `utter-fetch-json` listed 21 speech models;
  `google/gemini-3.8-flash-tts` requires `response_format` `pcm` (400 with a
  clear message otherwise); with `:format pcm` core wrapped the PCM into a
  7.3 s WAV that afplay played. Deepgram `flux-tts:free` needs its own voice
  names (`flux-*-en`), so per-model voice lists matter.
- Gemini native `/v1beta/interactions` with the key from `pass`
  (`generativelanguage.googleapis.com/apikey`, the host/user layout
  auth-source-pass resolves by default): 200, base64 WAV decoded, 5.8 s
  played. Body shape `input[user_input] / response_format audio /
  generation_config.speech_config[voice]` accepted as sent.
- xAI `/v1/tts` with the key from `pass` (`api.x.ai/apikey`): `output_format`
  must be the struct `{"codec": "mp3"|"wav"}` (422 text/plain otherwise);
  200 audio/mpeg and audio/wav decoded and played (English mp3 3.9 s, Chinese
  wav 2.7 s with `language` auto-detected as zh); `GET /v1/tts/voices` listed
  28 voices.
- Menu opened against the real engine in batch; `utter--suffix-speak nil`
  spoke the sentence at point; heading rendered live state; three-utterance
  run exercised prefetch, pause/resume (SIGSTOP), `utter-next`, lighter
  strings `♪1/3⟳ ♪1/3 ♪1/3⏸ ♪2/3`.
