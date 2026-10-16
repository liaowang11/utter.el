# WP-D stream-http-backends report

Written 2026-10-16. Branch `worktree-agent-a5150a27e275ec92c`, based on
`main` at 0710d38. Files touched: `utter-openai.el`, `utter-elevenlabs.el`,
`tests/utter-openai-tests.el`, `tests/utter-elevenlabs-tests.el`,
`README.md` (setup snippet), `DESIGN.md` (module rows, constructor
signatures, one backend paragraph). No core, queue or `utter.el` change.

## What was built

- `utter-openai`: new slot and keyword `stream-params` (default nil).
  `utter--stream-kind` returns `bytes` when the backend-level
  `capabilities` contain `streaming`, else nil. `utter--stream-request-body`
  merges `stream-params` into the body (after `request-params`, so it wins).
  `stream_format` is never added. Defaults of `utter-make-openai` are
  unchanged, so it does not stream.
- `utter-elevenlabs`: keyword `:streaming` (default nil) appends
  `streaming` to `(stitching timestamps)`. `utter--stream-kind` returns
  `b64-lines` with it. `utter-elevenlabs--url` inserts `stream/` when INFO
  has `:stream`, giving
  `/v1/text-to-speech/ID/stream/with-timestamps?output_format=...`.
  `utter--stream-alignment-piece` reads `alignment`
  (`characters`, `character_start_times_seconds`,
  `character_end_times_seconds`), never `normalized_alignment`; a null or
  missing alignment gives nil. The unary URL and body are unchanged.
- Commentary: the Kokoro-FastAPI preset now has
  `:request-params '(:stream :false) :stream-params '(:stream t)
  :capabilities '(streaming)`. The mlx-audio preset stays without
  streaming, with a note that its stream mode is untried. A note says
  OpenAI can opt in, unverified live. ElevenLabs Commentary describes
  `:streaming t`. README snippet shows both opt-ins.

## Live check (ElevenLabs, eleven_v4, voice George, 2026-10-16)

Batch Emacs with `-L` the worktree, key passed via an env var read from
the running server's `utter--get-api-key` (never printed or in argv).
Times are seconds from `utter-request`.

| Text | `:start` | final | `:data` | `:alignment` | final alignment |
|---|---|---|---|---|---|
| "Hello there. This is a short test of streaming, with a comma." | 1.464 | 2.350 | 6 | 4 | non-nil |
| "It costs $5 on 12/3, Dr. Smith said." | 1.899 | 2.783 | 6 | 4 | non-nil |
| "你好，世界。今天天气很好。" | 3.414 | 4.213 | 5 | 3 | non-nil |
| "Line one.\nLine two,  with two spaces." | 3.411 | 5.027 | 6 | 4 | non-nil |

- In every run the concatenated `alignment` pieces equal the request
  text exactly: digits, `$`, `/`, abbreviations, CJK punctuation, a
  newline and a double space are kept as sent (the normalization shows
  only in `normalized_alignment`). No fix was needed.
- Pieces seen, e.g. `("It costs $5 " nil "on 12" "/3, Dr. " "Smith said." nil)`:
  two null-alignment pieces per response (the 2nd and the last), splits
  inside tokens ("12" / "/3"). Unlike the earlier capture, the FIRST piece
  had alignment in all four runs; both shapes are handled.
- Progressive delivery with `-N`: `:data` events spread over 0.9-1.6 s
  after `:start` (e.g. 1.465, 1.484, 1.805, 2.340, 2.342, 2.343). A direct
  curl probe of the same endpoint: `http_version=2`, TTFB 1.67 s of 2.96 s
  total. So progressive delivery over HTTP/2 works.

## Tests

- `tests/utter-openai-tests.el`: `-no-streaming-by-default` (dry run with
  `:stream t` equals the plain one), `-kokoro-stream-body` (`:stream
  :false` normally, `:stream t` and `-N` when streaming),
  `-stream-body-has-no-stream-format`, `-stream-end-to-end` (Kokoro preset
  against the progressive test server: body has `stream: true`, no
  `stream_format`, no Authorization, several `:data` events whose bytes
  equal the body, `:stream-started t`).
- `tests/utter-elevenlabs-tests.el`: `-streaming-opt-in`,
  `-stream-dry-run` (stream URL, `:stream t`, same body, key redacted),
  `-stream-alignment-piece` (reads `alignment`, null gives nil),
  `-stream-end-to-end` (NDJSON: null-alignment first piece, mid-word split
  "Hello wo" / "rld, again", absolute times, lines cut across parts; exact
  event list, final alignment, sidecar).
- Each new test failed first for the expected reason (unknown keyword /
  missing `:stream`). Existing tests unchanged.
- `make check`: 279 tests, 279 as expected, no byte-compile warnings.
  `make lint` (checkdoc + package-lint) passes.

## Unverified

- OpenAI and Kokoro-FastAPI live streaming (no key / no local server).
  Kokoro was tested only against the local stub.
- mlx-audio streaming mode.
- ElevenLabs `pcm` streaming (raw pcm passthrough is WP-F; eligibility
  is WP-C's mp3-only predicate).

## Deviations

- `utter--stream-kind` reads the backend-level `capabilities` only; a
  model-level `:capabilities` list does not turn streaming on or off.
- DESIGN.md: besides the module rows and constructor signatures, one
  paragraph on backend streaming was added after the vendor-quirks
  paragraph.
- README snippet now opts both Kokoro and ElevenLabs in; it refers to
  `utter-streaming`, which WP-C adds.
