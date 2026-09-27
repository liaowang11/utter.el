# CORE report (branch `core`)

## What was built

| File | Contents |
|---|---|
| `utter-core.el` | `utter-backend` struct (frozen slots) and registry (`utter-get-backend`, gv-setter); generics `utter--request-data`, `utter--normalize-params`, `utter--response-audio`, `utter--parse-error`, `utter--list-voices` (with an `:around` voice cache), `utter--start-process`; key lookup (`utter--get-api-key`, `utter-api-key-from-auth-source`, `utter-key-from-gptel`, `utter-bearer-header`); curl runner (`-sS -K - -o RAW -w %{http_code}`, config on stdin with url/header/data-binary/request/user/proxy lines); decoders `bytes` (magic sniffing, PCM → 44-byte WAV) and `b64-json` (by `response-path`); `hex`/`b64-lines`/`url` report "not implemented"; `utter-request`, `utter-abort`, `utter-fetch-json`; cache (`utter-cache-key`, `utter-cache-file`, `utter-cache-lookup`, `utter-cache-clear`, `utter-cache-prune`). |
| `utter-say.el` | `utter-say` struct, `utter-make-say`, `say [-v V] -r WPM -o FILE --file-format=… -f TEXTFILE` (aiff, m4a via `--file-format=m4af --data-format=aac`, wav), `say -v ?` parser, `utter-say-register-default` (called at load on darwin). |
| `utter-openai.el` | `utter-openai` (`:include utter-backend`, extra slot `instructions-key`), `utter-make-openai`, speed clamp 0.25–4, `utter-openai-fetch-voices` (Kokoro `{"voices":[…]}` and mlx-audio `{"data":[{id,name}]}`). OpenRouter / Kokoro-FastAPI / mlx-audio recipes in the Commentary and in tests. |
| `utter-elevenlabs.el` | `utter-elevenlabs`, `utter-make-elevenlabs`, `xi-api-key`, `/v1/text-to-speech/{id}?output_format=mp3_44100_128|pcm_24000`, body `text model_id voice_settings.speed previous_text next_text` (+ `language_code` except on multilingual_v2), voices from `GET /v2/voices?page_size=100`, name → id in `utter--normalize-params`, speed clamp 0.7–1.2. |
| `utter-gemini.el` (optional) | `utter-make-gemini`, `POST /v1beta/interactions`, `x-goog-api-key`, b64 WAV from the last audio part of the `model_output` steps, instructions as a `speech_metadata` annotation. |

Behaviour notes beyond DESIGN.md:
- curl config also carries `header = "Expect:"` and, for loopback URLs when
  `utter-proxy` is empty, `noproxy = "*"` (this machine's `http_proxy` would
  otherwise capture 127.0.0.1). `utter-proxy` goes into the config as `proxy =`.
- The `bytes` sniffer also accepts ADTS/MPEG frame sync (`\xff` + byte ≥ `\xe0`)
  and `ftyp` at offset 4 (m4a), otherwise OpenAI `aac` and say `m4a` would be rejected.
  Unknown bytes are accepted only for `pcm`; HTML/XML bodies are errors like JSON.
  For `pcm` requests only a string signature (`ID3 RIFF fLaC OggS FORM ftyp`)
  counts as a container and only a body that parses as JSON is an error, so raw
  samples starting `\xff\xff` or `{` are still wrapped; a container returned for a
  pcm request is kept as is and INFO `:format` names it (e.g. mp3), though the file
  name still ends in `.wav`.
- PCM output is stored as `.wav` (cache file `<key>.wav`) and INFO `:format` is `wav`.
- A default voice comes only from declared voice lists (model `:voices`, then the
  backend's list), never from a fetched list; so say's default backend uses the
  system voice.
- Failed or aborted requests delete their partial output file (else a partial say
  file in the cache would be served later).
- `utter-request` default forms use `(bound-and-true-p utter-…)` (same keys as the
  frozen signature) because `utter.el` is a stub; nil → backend default, speed 1.0.
- Dry run of a `process` backend returns the same keys plus `:command`.
- `utter-fetch-json` CALLBACK gets `(JSON)`, or `(JSON INFO)` if it accepts two args;
  JSON objects are alists, arrays lists; nil on failure.
- `utter-pre-request-hook` / `utter-post-request-hook` are normal hooks; the INFO
  plist is in the dynamic variable `utter-request-info` while they run. Both run
  once per request, including cache hits.

## Verification

- `make check` (compile + test), GNU Emacs 31.1.50: compile clean, `Ran 63 tests, 63 results as expected, 0 unexpected`.
- `make EMACS=…/emacs-nox-30.2/bin/emacs check`: compile clean, 63/63.
- `make lint`: checkdoc clean on all five files.
- curl path tested end to end against an in-process stub server
  (`make-network-process :server t` in `tests/utter-core-tests.el`): 200 mp3,
  200 with a JSON error body (sniff), 401 JSON (text/plain content type), 403
  array-wrapped error, raw PCM → WAV, b64 WAV JSON, connection refused (curl 7),
  never-answering server + abort, env `http_proxy` pointing at a dead proxy.
  Assertions check the key is absent from `process-command` and present in the
  headers the server received; nil key → no auth header.
- Key resolution with a temp authinfo file (`auth-sources` bound), and gptel
  lookup with a faked `gptel--known-backends` (gptel's own key function is
  asserted never to be called).
- `say` tests use a fake `say` shell script (run anywhere) plus two real-`say`
  tests guarded by `skip-unless` (they passed on this Mac: aiff, m4a, voice list).
- Shell probes before writing the runner: `-K -` honours `data-binary = "@file"`
  and headers; stdout is exactly the 3-digit status; closed port gives `000`, exit 7;
  no `Expect: 100-continue` stall with curl 8.21 (header sent anyway).

## HANDOFF

Needed from ENGINE (`utter.el`):
- Define the defcustoms `utter-backend utter-model utter-voice utter-speed
  utter-format` (core only `defvar`s them).
- Do **not** redefine these; core defines them as defcustoms (core loads first and
  must work alone): `utter-cache-directory`, `utter-cache-max-size`,
  `utter-voice-cache-ttl`, `utter-curl-program`, `utter-proxy`, `utter-log-level`,
  `utter-pre-request-hook`, `utter-post-request-hook`, and the group `utter`.
- `utter-backend` default on darwin: `(and (eq system-type 'darwin) (require 'utter-say) (utter-say-register-default))`.
  It registers "say" (voices `fetch`) if absent and returns it; it never sets `utter-backend`.
- `utter-log` command: pop to buffer `utter--log-buffer-name` ("*utter-log*"), written by `utter--log`.
- Cache pruning at enqueue: call `(utter-cache-prune)`.
- Segment sizing: `(utter--text-length TEXT UNIT)` counts chars/bytes/utf16, and
  `utter-text-too-long` is signalled with data `(NAME LENGTH MAX)`.
- ElevenLabs voice names resolve to ids only after the voice list is cached: the
  voice infix / `utter-select-voice` must call `utter--list-voices` first (ids work
  without it). Sync lookup for UIs: `(utter--static-voices BACKEND MODEL)` returns
  declared or cached voices, `(utter--cached-voices BACKEND)` the fetched ones.
- Other private helpers ENGINE/UI may use: `utter--resolve-backend`,
  `utter--model-name`, `utter--model-plist`, `utter--voice-name`, `utter--formats`,
  `utter--capable-p`, `utter--container-format` (pcm → wav), `utter--sniff`,
  `utter--file-head`, `utter--wav-duration`.
- Test helpers: consolidate the stub server in `tests/utter-core-tests.el`
  (`utter-test-with-server`, `utter-test-requests`, `utter-test-wait`,
  `utter-test-request`, `utter-test-mp3`, `utter-test-wav-bytes`; the file
  `provide`s `utter-core-tests`) with ENV's `tests/support/utter-test-server.el`.
  Symbols it defines, to grep for collisions: `utter-test-server`,
  `utter-test-requests`, `utter-test-routes`, `utter-test-server-start`,
  `utter-test--parse-request`, `utter-test--respond`, `utter-test-wait`,
  `utter-test-with-server`, `utter-test-request`, `utter-test-mp3`,
  `utter-test-wav-bytes`, `utter-test-with-temp-dir`, `utter-test-file-bytes`,
  `utter-test-write-bytes`, `utter-test-with-authinfo`, `utter-test-backend`,
  `utter-test--make-backend`, `utter-test-pe-backend`, `utter-test--pe-seen`,
  `utter-test--key-var`.

## Unverified

- No real network call to OpenAI, OpenRouter, ElevenLabs or Gemini, and no local
  Kokoro-FastAPI / mlx-audio server was run; shapes come from platform-apis.md.
- ElevenLabs: `language_code` handling per model, `/v2/voices` pagination beyond
  100 voices (only the first page is read), `labels.accent` as description.
- Gemini: the `annotations`/`speech_metadata` placement for instructions, the
  voice list (from memory), the 4000-char `max-chars` (a guess under 8192 tokens).
- Linux run: not run on Linux; the say fake script uses `/bin/sh` `printf` with
  `\000` escapes (POSIX), and real-`say` tests skip without `say`.
- Emacs 30.1 exactly: tested on 30.2 and 31.1.50.
