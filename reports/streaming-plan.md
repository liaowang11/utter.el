# Plan: word-level highlighting, then optional streaming playback

Written 2026-10-16 by the planning subagent; coordinator decisions are in
"Coordinator decisions" at the end and override anything above them.
Line numbers refer to `main` at 4749ccb.

## 1. Facts established (2026-10-16)

- `forward-word` in batch Emacs on `"我们今天去北京看长城。The quick brown fox. 日本語のテキストです。"`
  returns `("我们今天去北京看长城" "。The" " quick" " brown" " fox" ". 日本語の" "テキストです" "。")`:
  whole CJK runs are one word and punctuation is glued to the next word, so
  CJK is per-character and spans must be trimmed of leading punctuation/whitespace.
- xAI WebSocket, verified live through a CONNECT tunnel (websocket.el 1.16, Emacs 31.1.50):
  URL `wss://api.x.ai/v1/tts?language=en&voice=eve&codec=mp3&with_timestamps=true`,
  `Authorization: Bearer` via `:custom-header-alist`. Client sends
  `{"type":"text.delta","delta":…}` then `{"type":"text.done"}`. Server:
  `audio.delta` `(type delta audio_duration)` (first at 0.45 s); some deltas also
  carry `audio_timestamps (graph_chars graph_times)` with times `((0.06 0.08) …)`;
  one had `audio_duration 0.0`; one was timestamp-only (empty `delta`, no
  `audio_duration`); then `audio.done (type trace_id)`. Times are ABSOLUTE,
  pieces split mid-sentence, all input chars covered, timestamps may lag the
  audio and arrive in audio-less deltas. Open (CONNECT+TLS+handshake) took
  1.37 s synchronously. Documented but not exercised: `text.clear`→`audio.clear`,
  `session.update`→`session.updated`, `error {type,message}`, query params
  `codec` (mp3|wav|pcm|mulaw|alaw), `sample_rate`, `bit_rate`, `speed` 0.7-1.5,
  `optimize_streaming_latency` 0-2, `text_normalization`; 50 concurrent
  sessions/team, 600 s session TTL; connection stays open across utterances.
- Network: `https_proxy`/`all_proxy` = `http://127.0.0.1:7890`; a direct
  connection to api.x.ai is intercepted (Cisco Umbrella 403). websocket.el has
  no proxy support; this curl build has no `ws`/`wss`.
- websocket.el: `websocket-open :nowait t` only sends the handshake when the
  process status is `connect`, so a pre-connected tunnel needs `:nowait nil`;
  on a non-101 response it calls `on-error` with
  `(websocket-received-error-http-response 403)` but still sets state `open`,
  fires `on-open`, and parses the HTML body as frames (observed).
  `emacs -Q --batch` NSM refuses TLS, so no wss in `make test`.
  `websocket-debug` must stay nil (it logs every frame payload).
- ElevenLabs `/stream/with-timestamps` (eleven_v4): HTTP 200, application/json,
  NEWLINE-DELIMITED JSON `{audio_base64, alignment, normalized_alignment}`,
  absolute times, some pieces with null alignment, pieces split
  mid-sentence/mid-word. `/stream`: audio/mpeg, progressive (TTFB 1.41 s of
  2.98 s), HTTP/2.
- ffplay installed, mpv not. afplay takes one file argument only (no stdin).
- OpenAI progressive delivery unverified (no key). OpenAI `stream_format` ∈
  {`sse`,`audio`}, `sse` not for tts-1/tts-1-hd; do not send it.
  Kokoro-FastAPI `stream` defaults True, streamed WAV has `0xFFFFFFFF` sizes.
  Gemini `stream: true` → `step.delta` events, base64 headerless l16 PCM 24 kHz.

## 2. Decisions (Bill)

1. afplay-only + `utter-streaming` on: `(defvar utter--stream-player-warned nil)`;
   first eligible segment messages once "utter: streaming needs ffplay or mpv;
   playing whole audio instead", then the normal path. No "chunk" wording.
2. `streaming` capability is opt-in per backend: `utter-make-openai` defaults
   unchanged; Kokoro/mlx presets in Commentary show `:capabilities '(streaming)`;
   `utter-make-elevenlabs` and `utter-make-xai` gain a `:streaming` keyword
   (default nil) that appends `streaming`.
3. Mid-stream failure after audio started: INFO `:stream-started t`;
   `utter--segment-callback` resets the segment to `pending` once (slot
   `retries`, utter-queue.el:139), kills the player, lets prefetch re-request;
   second failure → existing `utter--segment-failed`. Separate from
   `utter--retryable-p` (utter-queue.el:738).
4. Dry run: pure predicate `utter--stream-eligible-p (backend model format)` in
   utter-queue.el; `utter--inspect-text` (utter.el) passes `:stream t` when it
   holds; the dry-run plist gains `:stream t` only then, else byte-identical.
5. Word-level highlight first, independent of streaming (WP-A).
6. xAI WebSocket via the optional `websocket` package (WP-E).
7. Cues for streaming timestamp backends are built incrementally.

## 3. Design

### 3.1 Word-level highlight (independent of streaming)

- `utter-highlight` accepts `nil | t | word` (`t` = sentence, unchanged).
  Faces: see coordinator decision C1. Two overlays: `utter--highlight-overlay`
  (sentence) + `utter--highlight-word-overlay`; `utter--highlight-delete`
  (utter-queue.el:667) and `utter--highlight-drop` (673) clear both.
- Cues: extend the cue vector to
  `[SECONDS START END BEG-MARKER END-MARKER SENT-BEG-MARKER SENT-END-MARKER]`
  (sentence cues repeat their own markers in 5/6). `utter--word-cues (item seg
  alignment)` next to `utter--sentence-cues` (604): spans from
  `utter--sentence-spans` (utter-text.el:241), then within each sentence word
  spans via `forward-word` under the source buffer's syntax table, replacing any
  CJK run (`[一-鿿぀-ヿ가-힯]`) by per-character spans; spans start at
  `utter--skip-space` (utter-text.el:198) and punctuation-only spans are
  skipped. Alignment lines up iff `(= (length starts) (length piece))` and every
  span has a position tag (`utter--tag-at`); otherwise fall back to
  `utter--sentence-cues` for that segment.
- `utter--progress-tick` (631) unchanged. `utter--highlight-progress` (710)
  finds the cue by exact `start` (716): change to the cue whose `[START,END)`
  contains START; sentence overlay → markers 5/6, word overlay → 3/4 when
  `word`. `utter-progress-functions (ITEM START END)` keeps its signature; it
  fires per word when `word`.
- Menu: `utter--toggle-variable` (utter-transient.el:475-487) is boolean; add
  `utter--highlight-variable` cycling nil → t → word rendered
  `(off)/(sentence)/(word)`, used by `utter--infix-highlight` (585). Key unchanged.
- Docs: utter.el defcustom (125) docstring and `:type '(choice (const nil)
  (const :tag "Sentence" t) (const word))`; DESIGN.md rule 3, highlight
  paragraph, defcustom table.
- Tests: `utter-queue-highlight-word-two-overlays`, `-word-cjk-per-character`,
  `-word-falls-back-to-sentence-when-alignment-mismatch`,
  `-word-cue-lookup-by-range`, `-t-is-sentence-unchanged`; utter-text-tests:
  `utter--word-spans` on Latin, Chinese and mixed text; transient cycling test.

### 3.2 Streaming core (transport-agnostic)

- `utter-streaming` defcustom (utter.el) nil: "When non-nil, start playing
  audio while it is still being received. Only backends with the `streaming'
  capability and a player that reads from a pipe (ffplay or mpv; afplay cannot)
  are affected; with afplay alone utter says so once and plays whole audio as
  when this is nil. Streamed audio is still cached. Highlighting follows timing
  data as it arrives."
- `utter-request` (utter-core.el:1092) gains `:stream` (nil) and
  `:stream-callback`; with `:stream nil` nothing changes: `utter--curl-args`
  (502), `utter--curl-run` (507), `utter--start-curl` (1210), `utter-fetch-json`
  (565) untouched.
- New `utter--start-curl-stream`: argv `-sS -K - -o - -w %{stderr}%{http_code}`;
  `make-process :coding '(binary . utf-8-unix) :stderr <pipe>`; filter holds
  the first 64 bytes, `utter--sniff` (614): `json`/`text` ⇒ no `:start`,
  collect into the raw file, finish with the same messages as
  `utter--decode-bytes` (751); `audio` ⇒ emit `(:start …)`, tee each chunk to
  the output file (binary `write-region … t 'silent`) and emit `(:data BYTES)`.
  Sentinel parses the status from stderr like 520-534; exit 18/reset after
  `:start` ⇒ `(:end)` then error with `:stream-started t`; `:partial-file`
  cleanup (1082) deletes the partial cache file.
- Stream kinds (generic `utter--stream-kind (backend)`, default nil): `bytes`
  (OpenAI-compatible, ElevenLabs `/stream`), `b64-lines` (ElevenLabs NDJSON:
  per line decode `audio_base64` → `(:data)`, `alignment` → piece),
  `websocket` (xAI). Stage 1 formats mp3 only; wav header rewrite and pcm are WP-F.
- Body/URL: `utter--request-body` (1057) applies generic
  `utter--stream-request-body (backend body params)` (identity default) AFTER
  the request-params merge, so Kokoro's `:request-params '(:stream :false)` can
  be overridden by `:stream-params '(:stream t)` (new `utter-openai` slot).
  `utter-elevenlabs--url` (utter-elevenlabs.el:57) switches to
  `/stream/with-timestamps` on `(plist-get info :stream)`.
- Incremental alignment: core keeps pieces, concatenates, validates the covered
  prefix (`utter--normalize-alignment-prefix`: chars equal `(substring text 0
  n)`, times finite/nondecreasing/start≤end) and emits `(:alignment PLIST)`
  with the cumulative validated prefix; on `(:end)` the full
  `utter--normalize-alignment` (811) runs and the sidecar is stored as today.
  Null-alignment and zero-length-audio pieces are legal. Use `alignment`, not
  `normalized_alignment`.

### 3.3 Player

- `utter-player` struct (utter-queue.el:176) gains `stdin-command`
  `(rate format) → argv`, nil = cannot stream. afplay nil; ffplay
  `("ffplay" "-nodisp" "-autoexit" "-loglevel" "error" "-af" "atempo=R" "-i" "pipe:0")`;
  mpv `("mpv" "--no-video" "--speed=R" "-")`. `utter--select-stream-player
  (format)` mirrors `utter--select-player` (257).
- Pause: SIGSTOP the player; `process-send-string` blocks when the pipe fills,
  so while paused `:data` is queued and flushed on resume. On resume, if the
  stream has ended kill the stopped player and restart from the file at
  `utter-offset`; else SIGCONT + flush. ffplay SIGCONT on a pipe UNVERIFIED
  (spike in WP-C). Paused before `:start`: file-only, segment ends `ready`.

### 3.4 Queue

- Segment status `streaming`; audit `utter--segment-callback` guard (766),
  `utter--abort-item` (817), in-flight count in `utter--prefetch` (839),
  `utter--kill-player` (973: also abort the segment's request),
  `utter--advance` (1016), `utter--reset-item` (1046), `utter--player-sentinel`
  (951: player exits while the request is live ⇒ abort request, segment error
  unless `utter-stopped`).
- Eligibility in `utter--request-segment` (803): `utter-streaming`,
  `utter--stream-eligible-p`, no player running, segment at
  `utter--item-position` of the current/first pending item, not `:cache-only`,
  not paused. Later prefetched segments download whole. Cache hits never stream.
- On `(:start)`: start the stdin player via `utter--start-player-process`
  (940), set process/seg-start, announce, segment-level progress event. On
  `(:alignment)`: build cues for sentences/words whose END is covered and not
  yet cued; append to `utter--segment-cues`, reset `utter-progress-tail`; make
  `utter--progress-start` (658) restartable. On `(:end)`: `process-send-eof`.

### 3.5 xAI WebSocket transport

- Soft dependency: `(require 'websocket nil t)` + `declare-function …
  "ext:websocket"`; no Package-Requires entry. `utter--stream-available-p
  (backend)` default t; xAI method `(featurep 'websocket)` ⇒ silent fallback to unary.
- `utter--stream-open ((backend utter-xai) info params on-event)`: URL
  `wss://HOST/v1/tts?language=…&voice=…&codec=mp3&with_timestamps=true[&speed=…]`;
  header from `utter-bearer-header`; `on-open` sends `text.delta` +
  `text.done`; `on-message`: `audio.delta` → base64-decode `delta` (skip when
  empty) → `(:data)`, `audio_timestamps` → alignment piece; first audio ⇒
  `(:start :format mp3)`; `audio.done` ⇒ `(:end)` + success; `error` ⇒
  `(:end)` + error `message`; `on-close` before `audio.done` ⇒ error with
  `:stream-started`; `on-error` with `websocket-received-error-http-response N`
  ⇒ latch a fatal flag so later spurious `on-open`/`on-message` are ignored,
  set `:http-status N`. Abort: `websocket-close` (`utter-abort` must handle a
  non-process handle).
- Proxy: resolve like curl — `utter-proxy`, else
  `https_proxy`/`HTTPS_PROXY`/`all_proxy`, honouring `no_proxy`. With a proxy:
  `make-network-process` to it, `CONNECT host:443`, wait for `HTTP/1.x 200`,
  `gnutls-negotiate … :verify-error t` plus NSM, then `websocket-open … :nowait
  nil` over the tunnel. Certificate verification must be real.
- Authorization header must never reach a backtrace, `message` or `*utter-log*`:
  wrap the open in `condition-case` and report `error-message-string` only.
- Alignment sidecar stored at `(:end)` so cache replays keep cues.

## 4. Interface contracts

A. `utter-request` keys: `:stream BOOL` (nil default) and `:stream-callback
   (lambda (event) …)` where EVENT is one of
   `(:start :format FMT)` once, FMT `mp3`|`wav`|`pcm`;
   `(:data BYTES)` unibyte string, zero or more, only after `:start`;
   `(:alignment ALIGNMENT)` zero or more, ALIGNMENT = `(:characters PREFIX
   :starts VECTOR :ends VECTOR)`, cumulative validated prefix of INFO `:text`
   (absolute seconds), each strictly longer than the last;
   `(:end)` once, after the last `:data`;
   then the unchanged final CALLBACK `(AUDIO INFO)`; INFO gains `:stream t` and
   `:stream-started BOOL`; `:alignment` is the full validated alignment or nil;
   `:http-status` as today. Errors before `:start` are reported exactly like
   non-stream errors. Dry run adds `:stream t` only when `:stream` was passed.
B. Core generics (utter-core.el): `utter--stream-kind (backend) →
   bytes|b64-lines|websocket|nil`; `utter--stream-available-p (backend)`
   (default t); `utter--stream-request-body (backend body params) → body`;
   `utter--stream-alignment-piece (backend info json) → (:characters
   STRING-OR-LIST :starts LIST :ends LIST)|nil`; `utter--stream-open (backend
   info params on-event) → handle` for kind `websocket`, where ON-EVENT takes
   the events of A plus `(:status N)` and `(:error STRING)`, and the handle is
   closed by `utter-abort`.
C. Player: `utter-player-stdin-command` slot `(rate format) → argv|nil`.
D. Queue predicate: `utter--stream-eligible-p (backend model format) → bool`.
E. Cue vector: `[SECONDS START END BEG END SENT-BEG SENT-END]`;
   `utter--segment-cues` may grow during playback; `utter--progress-start`
   idempotent/restartable.
F. Test support: `utter-test-server` responder `(:status 200 :headers …
   :parts (BYTES…) :delay SECONDS)`; `utter-test-ws-server` on
   `websocket-server` at `ws://127.0.0.1` emulating xAI, guarded by
   `skip-unless (require 'websocket nil t)`; Makefile `deps` installs
   `websocket` from GNU ELPA into `.deps/elpa`.

## 5. Work packages

Each in its own git worktree, writes `reports/<area>.md`, max 3-4 concurrent.

Wave 1 (concurrent): WP-A, WP-B.

- WP-A `highlight-word`: owns utter-queue.el highlight section (594-734) and
  the `utter--segment-callback` cue line (776-779); utter-text.el
  `utter--word-spans`; utter.el `utter-highlight` defcustom + new faces;
  utter-transient.el toggle class / `utter--infix-highlight`; DESIGN.md rule 3,
  highlight paragraph, table row; tests in utter-queue-tests highlight block,
  utter-text-tests, utter-transient-tests. Acceptance: `make check` green; `t`
  behaviour identical; word tests pass.
- WP-B `stream-core`: owns utter-core.el (`utter-request`,
  `utter--start-curl-stream`, stream generics,
  `utter--normalize-alignment-prefix`, `utter-abort` handle),
  tests/support/utter-test-server.el `:parts/:delay`, tests/utter-core-tests.el
  stream tests, DESIGN.md Core block. Does not touch queue/utter.el.
  Acceptance tests: `-request-stream-first-bytes-before-end`,
  `-stream-json-body-is-error`, `-stream-401-status-from-stderr`,
  `-stream-partial-after-start-reports-stream-started-and-deletes-partial`,
  `-stream-abort`, `-stream-b64-lines-alignment-prefix-events`,
  `-nonstream-argv-and-dry-run-unchanged`.

Wave 2 (after A and B merge; concurrent): WP-C, WP-D, WP-E.

- WP-C `stream-engine`: utter.el `utter-streaming` + inspect `:stream`;
  utter-queue.el players, segment status, eligibility, stream event handler,
  pause buffering, retry-once-after-start, warn-once, incremental cues;
  DESIGN.md player/queue blocks; queue tests (fake request gains
  `:stream`/`:stream-callback`; fake player `:stdin-command '("cat")`); spike
  note on ffplay SIGCONT-on-pipe.
- WP-D `stream-http-backends`: utter-openai.el (`stream-params`,
  `utter--stream-request-body`, kind `bytes`, Kokoro/mlx Commentary + README),
  utter-elevenlabs.el (`:streaming`, URL switch, kind `b64-lines`, alignment
  piece); tests; live ElevenLabs check in the report.
- WP-E `stream-xai-ws`: utter-xai.el (`:streaming`, kind `websocket`,
  `utter--stream-available-p`, `utter--stream-open` incl. tunnel + connection
  reuse + fatal-flag latch, alignment piece), tests/support/utter-test-ws-server.el,
  xai ws tests, Makefile `deps` websocket install, README/DESIGN xAI rows; no
  test touches wss; live probe through the proxy recorded (redacted).

Wave 3 (optional): WP-F `stream-formats` (wav header rewrite, pcm), WP-G
`stream-gemini` (SSE + l16 PCM; depends on F).

## 6. Open questions for Bill (wave 2)

1. xAI streaming unavailable when the proxy CONNECT fails, rather than falling
   back to an unverified connection? (planner recommends yes)
2. Rebind `open-network-stream` via `cl-letf` (websocket.el 1.16 internals) vs
   a small handshake reimplementation?
3. Keep one xAI WebSocket open per backend across segments (saves ~1.4 s per
   segment, uses one of 50 team sessions) vs open per segment?
4. ffplay SIGCONT on a pipe unverified; fallback restarts from file only after
   the stream ends.
5. OpenAI progressive delivery unverified.

## Coordinator decisions (wave 1)

C1. Faces: `utter-highlight` stays the face of the highlighted text in sentence
    mode, so `t` looks exactly as today. In `word` mode the word overlay uses
    `utter-highlight` and the sentence overlay uses a new lighter face
    `utter-highlight-sentence` (`:inherit secondary-selection`), with higher
    overlay priority on the word.
C2. `utter-progress-functions` firing per word is accepted; WP-A checks that
    utter-mode's header-line consumer stays cheap and notes it in its report.
