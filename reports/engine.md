# ENGINE report

Branch `engine`, worktree `~/Repositories/worktrees/utter-engine`.

## What was built

- `utter-text.el`: `utter-preprocess-functions` with four defaults
  (`utter-strip-markup` for Org and Markdown by the source buffer's mode,
  `utter-replace-urls` for link descriptions or the word "link",
  `utter-collapse-whitespace` where a paragraph break becomes "\n", and
  `utter-apply-pronunciations`), plus `utter-pronunciation-alist`.
  `utter--split TEXT MAX-CHARS &optional UNIT` goes through `utter--split-functions`
  to `utter--split-by-sentence`. It splits on `sentence-end` (single
  space) and `。！？；` and newlines, then packs sentences under the limit.
  The first segment stays under `utter--first-segment-chars` (200).
  A sentence is hard-split, at whitespace or punctuation, only when it is
  over the limit. Splits never land inside SSML tags or non-`speak`/`p`
  elements, and the SSML check applies only when the text contains a
  tag. UNIT can be `chars`, `bytes` or `utf16`.
  `utter--tag-positions` carries buffer positions through preprocessing
  for the highlight.
- `utter-queue.el`: `utter-item` (constructors `utter--make-item` and
  `make-utter-item`; the private `utter--item-segments` and
  `utter--item-position` are setf-able), `utter--segment`, and one global
  `utter--queue` (struct `utter--qstate`). Also `utter-enqueue`,
  `utter-interrupt`, pause/resume/toggle, next/previous (these move
  between utterances), stop, clear, rate up/down, `utter-replay-item`,
  `utter-state`, `utter-active-p` and `utter-state-string`.
  - Prefetch is a window of the playing segment plus `utter-prefetch-depth`
    segments, across items, capped at `utter-max-concurrent-requests`.
    A segment waiting to retry keeps its slot.
  - A 429 or 5xx gets one retry after `utter--retry-delay` (8 s), then the
    segment is marked error and playback continues.
  - Players: afplay, ffplay and mpv are structs; `auto` picks the first
    installed player that plays the format (afplay first on darwin).
  - Lighter strings: ` ♪`, ` ♪2/5`, `⟳`, `⏸`, `✗CODE`. The lighter sits in
    `global-mode-string` only while the queue is active.
  - All hooks from DESIGN.md are implemented.
  - Highlight: an overlay moved from `utter-progress-functions`. It is
    dropped by a buffer-local `after-change-functions` check on
    `buffer-chars-modified-tick`.
  - The audio cache is pruned (`utter-cache-prune`) at every enqueue.
- `utter.el`: header kept and Commentary updated. It defines every
  defcustom in the DESIGN table except the six CORE owns (cache dir/size,
  voice TTL, curl, proxy, log level). It also has these commands:
  `utter-speak` (C-u calls `utter-menu`), `-interrupt`, `-string` (also
  takes `:interrupt t`), `-buffer`, `-kill`, `utter-save-to-file` (one
  segment only; more gives a `user-error` pointing at ffmpeg),
  `utter-inspect-query` (dry run into `*utter-inspect*`),
  `utter-select-voice` (annotated completion, scope-aware) and
  `utter-log`. Also: scope (`utter--set-scope`, `utter--set-with-scope`,
  oneshot restored from `utter-enqueue-hook`), presets
  (`utter-make-preset`, `utter-get-preset`, `utter--apply-preset`,
  `utter-with-preset` via `cl-progv`), `utter--gptel-response-at-point`
  and `utter--text-at-point`. `utter-menu` and `utter-queue` are reached
  only through `autoload`. Commands have autoload cookies; the ones in
  `utter-queue.el` autoload from "utter", so the options exist when they
  run.

## Verification

- Engine branch `make check`: compile clean, 80/80 tests on Emacs 31.1.50
  and on Emacs 30.2. `make lint` (checkdoc): 0 warnings.
- Trial merge of `engine` into current `main` (detached worktree, not
  committed): compile clean, 200/200 tests on 31.1.50 and 30.2, checkdoc
  0 warnings.
- Tests use no network, no keys and no macOS binaries. `utter-request`
  and `utter-abort` are faked, and the player is `sleep`. A
  conditional core stand-in in `tests/utter-queue-tests.el` is used only
  when `utter-core` is absent.
- Live on this Mac, merged tree, real `say` backend: pause and resume
  checked by timing with afplay and ffplay. The process goes to `stop`,
  stays alive through a 3 s pause, and finishes when the remaining audio
  ends.

## DESIGN corrections found

- **ffplay does not really pause under SIGSTOP/SIGCONT.** The process
  stops, but ffplay keeps its wall clock and skips the paused stretch
  on resume. Measured standalone: a 4.84 s clip ends 5.3 s after start
  with and without a 3 s pause. The `wait` exit code 145 in the earlier
  verification comes from bash recording the stop, not from an exit.
  Fix: `utter-player-ffplay` keeps SIGSTOP for pause, but its `:resume`
  is `utter-player-restart`, which restarts it with `-ss OFFSET`.
  The player `command` may take an optional third argument OFFSET.
  afplay keeps SIGSTOP/SIGCONT, which was verified to hold its position.
- `utter-queue-finished-hook` runs on every change to idle, including
  `utter-stop`.

## HANDOFF

Still open after the coordinator's handoff:

1. At merge, change `(require 'utter-core nil t)` in `utter-text.el`
   and `utter-queue.el` to a hard require. The soft form works, but a
   hard require states the dependency.
2. Core symbols used: `utter-request`, `utter-abort`, `utter-get-backend`,
   `utter--resolve-backend`, `utter-backend-p`/`-name`/`-models`/`-voices`/
   `-formats`/`-max-chars`/`-max-chars-unit`, `utter--model-name`,
   `utter--model-plist`, `utter--voice-name`, `utter--formats`,
   `utter--capable-p` (`stitching` gives `:context`), `utter-cache-prune`,
   `utter--list-voices`, `utter--log-buffer-name`,
   `utter-say-register-default`, and the defgroup `utter`. INFO keys read
   from callbacks: `:format`, `:duration`, `:http-status`, `:error`.
3. Provided for UI, beyond the coordinator's list: `utter--state-change-hook`
   (private; runs on every state change, including pause, resume and
   rate, for redraws without a timer), `utter--buffer-text BEG END`
   (text with position tags when `utter-highlight` is on; also what
   `utter--text-at-point` returns), `make-utter-item` (the UI tests use
   it), and `utter--queue-items` in finished, current, pending order.
4. `utter--highlight-progress` ignores non-item arguments, because a UI
   test runs `utter-progress-functions` with the symbol `item`.
5. `utter--segment` gained private slots `start end format retries`.

## Unverified

- mpv: not installed here. SIGSTOP/SIGCONT pause is untested and may
  lose its place like ffplay; `--start` would allow the same restart.
- Nothing was checked by ear; the live check is timing only.
- Emacs 30.1 exactly (tested 30.2 and 31.1.50). Linux (the tests only
  need `sleep`, but were not run there).
- `utter-highlight-follow` has no test. `utter-select-voice` was not
  tried against a fetched voice list (static stand-in only). There is no
  Retry-After support; the backoff is a fixed 8 s.
