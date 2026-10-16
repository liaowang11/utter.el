# WP-B stream-core report

Written 2026-10-16. Branch `worktree-agent-a0aad8999f6ac7c04`, based on
`main` at ae7044f. Files touched: `utter-core.el`,
`tests/support/utter-test-server.el`, `tests/utter-core-tests.el`,
`DESIGN.md` (Core block only).

## What was built

- `utter-request` keys `:stream` and `:stream-callback`.
- `utter--start-stream`, `utter--start-curl-stream` (curl), and
  `utter--start-stream-handle` (websocket kind, via `utter--stream-open`).
- Generics with defaults: `utter--stream-kind` (nil),
  `utter--stream-available-p` (t), `utter--stream-request-body`
  (identity), `utter--stream-alignment-piece` (nil), `utter--stream-open`
  (signals), and `utter--stream-close` (deletes a process, otherwise
  does nothing). `utter--stream-close` is new; it is not in contract 4.B.
- `utter--normalize-alignment-prefix (text characters starts ends)`.
- `utter-request` struct slot `handle`. `utter-abort` now also deletes the
  stderr pipe process (process property `utter-stderr` of the curl
  process) and calls `utter--stream-close` on `handle`.
- Refactors that keep behaviour identical: `utter--curl-outcome`, used by
  both curl paths to read the status and error text, and
  `utter--curl-response`, which holds the unary post-response checks
  (curl error, `utter--parse-error`, non-2xx, then decode) and is shared
  by both paths.
- Test server: a responder may give `:parts (BYTES...)` and `:delay
  SECONDS` (default 0.1) in place of `:body`. The head and the first
  part go out at once, then each later part after `:delay`, then
  half-close. A `Content-Length` in `:headers` is kept, so a test can
  promise more bytes than it sends and cut the body short (curl exit 18).

## Event protocol as implemented

STREAM-CALLBACK receives:

- `(:start :format FMT)` once. FMT is the container found by
  `utter--container-magic` in the first bytes, otherwise the requested
  format. For plain MPEG frames that is `mp3`; for headerless pcm it is
  `pcm`.
- `(:data BYTES)`: a unibyte string, never empty, only after `:start`.
- `(:alignment (:characters PREFIX :starts VECTOR :ends VECTOR))`: the
  cumulative, validated prefix of INFO `:text`, with absolute times.
  Each one is strictly longer than the one before. None is sent before
  `:start`; pieces that arrive before `:start` are kept and sent after
  the next `:data`.
- `(:end)` once, after the last `:data`, whenever `:start` was sent. This
  includes a failure after `:start`, where `(:end)` comes before the
  error callback. It is never sent after `utter-abort`, and no events of
  any kind follow an abort.

Then CALLBACK `(AUDIO INFO)` runs as usual. INFO has `:stream t` and
`:stream-started` (nil or t), `:alignment` (the full
`utter--normalize-alignment` result, or nil) and `:http-status`. The
sidecar is stored through the same `on-audio` path the unary request
uses.

ON-EVENT, for `websocket` transports (WP-E), accepts:
`(:status N)` sets `:http-status`;
`(:start :format FMT)`;
`(:data BYTES)`, which starts the stream with the sniffed or requested
format if `:start` has not been sent yet;
`(:alignment PIECE)`, where PIECE is ONE raw piece in the shape that
`utter--stream-alignment-piece` returns (not cumulative), and core does
the concatenation and validation;
`(:end)`, meaning success;
`(:error STRING)`, meaning failure.
The first `:end` or `:error` finishes the request, and every later event
is ignored. So `(:error S)` followed by `(:end)` and `(:end)` followed by
`(:error S)` each finish exactly once, with whichever came first.

`(:end)` with no audio before it is the error "utter: response has no
audio". Events may be sent synchronously from inside
`utter--stream-open`, as websocket.el does when it refuses a handshake
under `:nowait nil`. Core queues them and replays them, in order, from a
timer; events that arrive before that replay join the same queue. A
`utter--stream-open` that signals is reported as an error, with
`error-message-string`, from a timer after any queued events. CALLBACK
therefore never runs inside `utter-request`. The returned handle is stored in
`utter-request-handle` and cleared when the request finishes, so
`utter-abort` on a finished request never closes a reused connection.
Core never closes the handle on success or error; that is the transport's
job.

## Behaviour notes

- **Fallback when streaming is not possible.** `:stream t` takes the
  unary path when `utter--stream-kind` is nil, when
  `utter--stream-available-p` is nil, on a cache hit, and for `process`
  backends. In those cases INFO has no `:stream` key and no events are
  sent. `:stream` and `:stream-started` are added to INFO only when the
  stream path is taken.
- **curl argv**: `-sS -K - -N -o - -w %{stderr}%{http_code}`, followed by
  the backend's `curl-args`. Headers and the key still go through
  `-K -` on stdin.
- **Order of finishing.** The curl process sentinel and the stderr pipe
  sentinel fire in either order (both orders were seen). The request
  finishes only when both have closed.
- **`bytes` kind.** The first 64 bytes are held back and passed to
  `utter--sniff`. The stream starts when `utter--decode-bytes` would
  accept the body as audio: known audio, or, for `pcm`, anything that is
  not JSON, text or empty. Otherwise nothing is sent, and at the end the
  raw file goes through `utter--decode-bytes`, so the error messages are
  the same as without streaming (for example "HTTP 200 with a JSON body:
  quota exceeded" and "HTTP 401: Incorrect API key provided").
- **`b64-lines` kind.** The body is split on newlines, and a partial line
  is carried over to the next filter call. Each line that is a JSON
  object with an `audio_base64` key carries audio, which may be empty or
  null; empty audio is skipped as data, and the line's alignment piece
  still counts. Before audio starts, other lines are left for the error
  path, which reads the raw body as above. After audio starts, an object
  without `audio_base64` records its error message, and the request then
  fails after `(:end)`. Base64 that does not decode gives "utter: invalid
  base64 audio".
- **Where the bytes go (differs from the plan's "tee to the output
  file").** The raw body is written to a temp file. Decoded `b64-lines`
  and websocket audio goes to a second temp file. The final file is
  created only at the end, by `utter--decode-bytes` (rename, or WAV
  header for pcm) or `utter--write-audio`. A cache lookup therefore never
  sees a partial file, and a user `:file` is not touched unless the
  request succeeds. `:partial-file` cleanup still runs as before. WP-C:
  during the stream INFO `:file` names the destination, but that file
  does not exist until the final callback.
- **Alignment validation.** If the concatenated pieces stop being a valid
  prefix (characters differ from the text, a bad time, a piece with
  multi-character entries), alignment events stop for that request. The
  request itself goes on, and the final `:alignment` is nil.
- **Body.** `utter--request-body` takes an optional STREAM argument. When
  it is set, `utter--stream-request-body` runs after the
  `request-params` merge and before `body-transform`.
- **Dry run.** When streaming would actually be used, the result gets
  `:stream t`, the stream body, and the stream argv in `:curl-args`
  (nil for `websocket`). INFO already holds `:stream t` when the URL
  function runs, so a backend can switch its URL on it, which WP-D's
  ElevenLabs URL switch needs. Otherwise the dry-run result is
  byte-identical to today.

## Tests (tests/utter-core-tests.el)

These are the required tests from the plan, plus two extras:

- `utter-core-test-nonstream-argv-and-dry-run-unchanged` checks the exact
  dry-run plist with `:stream` omitted, with `:stream nil`, and with
  `:stream t` on a backend that cannot stream or is unavailable. It also
  checks the live unary argv and that INFO has no `:stream` keys.
- `utter-core-test-request-stream-first-bytes-before-end` checks that the
  first `:data` arrives while the request is `running` and before the
  final callback, with fewer bytes than the whole body. The test server
  sends 3 parts with a 0.3 s delay.
- `utter-core-test-stream-json-body-is-error` checks that the error
  equals the one from the same request made without streaming.
- `utter-core-test-stream-401-status-from-stderr`.
- `utter-core-test-stream-partial-after-start-reports-stream-started-and-deletes-partial`
  uses `Content-Length: 5000` to make curl exit with 18, and checks for
  exactly one `(:end)` and an empty cache directory afterwards.
- `utter-core-test-stream-abort` checks that the curl process and the
  stderr pipe are dead, that there is no `(:end)`, that the callback runs
  once with `abort`, and that no files are left behind.
- `utter-core-test-stream-b64-lines-alignment-prefix-events` uses the
  shape of the ElevenLabs capture: a first piece with null alignment,
  "The first sentence " / "is here" split mid-sentence, absolute times,
  one piece with empty audio, `normalized_alignment` null, and parts that
  cut lines in the middle. The test checks the exact event list, the
  final alignment and the sidecar.
- Extra: `utter-core-test-normalize-alignment-prefix`.
- Extra: `utter-core-test-stream-websocket-dispatch`, which runs a fake
  transport through success, error-then-end, a status error before
  audio, abort closing the handle, events sent synchronously from inside
  the open (CALLBACK still deferred, handle cleared), and an open that
  signals.

Checks: removing `-N` makes `first-bytes-before-end` (at its argv
assertion) and `stream-abort` (no data arrives before the 6 s gap) fail.
The core test file passed 8 times in a row. `make check` passes, and
`make lint` passes with package-lint (run with
`DEPS_DIR=<main checkout>/.deps/elpa`, since this worktree has no
`.deps`).

## Unverified

- `-N` progressive delivery was checked only against the local HTTP/1.1
  stub. It has not been tried against live HTTP/2 servers (OpenAI,
  ElevenLabs).
- Live ElevenLabs `/stream/with-timestamps`: whether the concatenated
  `alignment` pieces exactly equal the request text. If they do not,
  alignment events stop and the final `:alignment` is nil. WP-D should
  check this live.
- pcm/wav streaming: the `:data` bytes are passed through raw (headerless
  pcm stays headerless; WAV size fields are not fixed). That is WP-F.
- A raw `pcm` body under 64 bytes, or one that sniffs as JSON but does
  not parse, finishes successfully without any events. WP-C must treat a
  final callback with audio and `:stream-started` nil as a whole-audio
  result.

## Contract deviations and additions (WP-C/D/E)

1. The argv adds `-N`: `-sS -K - -N -o - -w %{stderr}%{http_code}`.
   Without it, curl buffers stdout to a pipe until it exits.
2. New generic `utter--stream-close (backend handle)` and new struct slot
   `utter-request-handle`. WP-E defines `utter--stream-close` for its
   handle type.
3. ON-EVENT `(:alignment PIECE)` carries one raw piece, and core
   accumulates. `(:end)` means success and `(:error S)` means failure;
   whichever comes first finishes the request. The transport does not
   need to send `(:end)` before `(:error)`.
4. `(:end)` is not sent after `utter-abort`.
5. The tee goes to temp files, and the final file appears only at the end
   (see Behaviour notes).
6. Dry run adds `:stream t` only when `:stream` was passed AND streaming
   would actually be used. `:curl-args` is nil for `websocket`.
7. `utter--stream-request-body` runs before `body-transform`.
8. ON-EVENT may be called synchronously from inside `utter--stream-open`.
   Core defers those events to a timer.
