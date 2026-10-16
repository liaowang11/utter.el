# WP-C stream-engine report

Written 2026-10-16. Branch `worktree-agent-a322bbb22f320946f`, based on
`main` at 0710d38. Files touched: `utter.el`, `utter-queue.el`,
`tests/utter-queue-tests.el`, `tests/utter-tests.el`, `DESIGN.md`
(queue/player block and defcustom table). `utter-core.el`,
`utter-openai.el` and `utter-elevenlabs.el` are untouched.

## What was built

- `utter-streaming` defcustom (nil), with the docstring from plan 3.2.
  `utter--inspect-text` passes `:stream t` only when
  `utter--stream-eligible-p` holds and a stream player exists, so the
  dry run shows `:stream t` (from core) only then. Otherwise the key is
  not passed at all.
- `utter-player` slot `stdin-command`, a function of `(RATE FORMAT
  &optional OFFSET)`. afplay has none. ffplay:
  `ffplay -nodisp -autoexit -infbuf -loglevel error -af
  [atrim=start=OFFSET,]atempo=R -i pipe:0`. mpv: `mpv --no-video
  --speed=R -`.
- `utter--select-stream-player (format)`, which mirrors
  `utter--select-player` but only considers players with a
  `stdin-command`. If `utter-player` names a player that has none, it
  returns nil.
- `utter--stream-eligible-p (backend model format)`: `utter-streaming`
  is on (read with `default-value`, like `utter-player`), the format is
  mp3, the backend or model has the `streaming` capability,
  `utter--stream-kind` is non-nil, and `utter--stream-available-p` holds.
  It does not check players.
- `utter--stream-wanted-p (item seg)`, called from
  `utter--request-segment`, holds only for the current item's segment at
  `utter--item-position`, with no player running, playback not paused,
  the item not `:cache-only`, and the segment eligible. If no stream
  player exists, utter messages "utter: streaming needs ffplay or mpv;
  playing whole audio instead" once per session
  (`utter--stream-player-warned`) and makes a whole-audio request.
  Prefetched segments always download whole, and cache hits never
  stream (core).
- Segment status `streaming`, and a private `utter--feed` struct in the
  new segment slot `feed`: the pipe player, every byte received, the
  bytes held back while paused, and the ended, EOF-sent and off flags.
- Event handler `utter--feed-event`:
  - `(:start)` checks again that this segment is still the one to play
    and that nothing is paused or playing. It then starts the stdin
    player (binary coding). The segment becomes `streaming`, the queue
    becomes `playing`, the item is announced, and a segment-level
    progress event is sent. If any check fails, the feed is marked
    `off` and the segment waits for its file.
  - `(:data)` writes the bytes to the player. While paused it holds
    them back.
  - `(:alignment)` calls `utter--feed-cues`. That function pads the
    prefix alignment to the full segment, calls WP-A's
    `utter--highlight-cues`, keeps the cues whose END lies inside the
    timed prefix and that are not cued yet, and `nconc`s them onto
    `utter--segment-cues`. It detaches the markers of the cues it
    throws away, then calls `utter--progress-start` when not paused.
  - `(:end)` sends EOF, or holds it back while paused.
- Final callback:
  - Audio while the segment is `streaming`: set the file, format and
    duration, append any cues still missing from the full alignment,
    and set the status to `playing`.
  - `:stream-started` nil, or a stream that was not played: whole
    audio, exactly as before.
  - Error with `:stream-started` t: kill the player (its play time is
    not counted), drop the partial cues, and set the segment to
    `pending` once (slot `retries`). The message is "utter: NAME
    stopped sending audio, retrying". Prefetch then asks again, and the
    request streams again. A second failure goes to
    `utter--segment-failed` with no HTTP code, because 200 would be
    misleading.
- Status audit (plan 3.4):
  - `utter--segment-callback` guard: accepts `synthesizing` and
    `streaming`.
  - `utter--abort-item`: handles `streaming` and tears the feed down.
  - `utter--prefetch`: counts `streaming` as in flight.
  - `utter--kill-player`: a `streaming` segment has its request aborted
    and goes back to `pending`.
  - `utter--player-sentinel`: if the player exits while the segment is
    `streaming`, the request is aborted and the segment fails ("player
    exited while the audio was arriving"). The position is advanced by
    `utter--advance` on `error`, never twice.
  - `utter--advance` and `utter--reset-item` needed no change, because
    `streaming` always has a process, and abort-item turns it into
    `pending` first.
- Pause and resume: pause is unchanged (SIGSTOP and offset capture).
  `utter-resume` sends a player that has `utter-feed` to
  `utter--feed-resume`:
  - SIGCONT-type players: resume, then flush the held bytes, then EOF
    if the stream ended.
  - Restart-type players (ffplay), stream already ended: restart from
    the finished file with `-ss` (the existing `utter-player-restart`).
  - Restart-type players, stream not ended: start a new pipe player
    with `atrim=start=OFFSET` and write every byte received so far.
  - Paused before `(:start)`: nothing is played, the segment ends
    `ready`, and resume plays the file.
- Refactor: `utter--player-started` holds the bookkeeping that
  `utter--play-segment` did, so the file and stream paths share it.

## Behaviour notes

- `utter-player-sigcont` now calls `continue-process` instead of
  `signal-process 'SIGCONT`. Emacs never sees the continue: after a
  bare SIGCONT, `process-status` stays `stop` and `process-send-string`
  signals "not running". `continue-process` sends SIGCONT and marks the
  process `run` (verified in batch). This also applies to afplay
  whole-file pause. The behaviour is the same, except that the status
  is now right. `utter--feed-resume` also calls `continue-process` if a
  custom resume function left the status at `stop`.
- On darwin with `utter-player` `auto`, whole files play with afplay but
  streams play with ffplay, because afplay has no `stdin-command`.
  Pause then behaves the ffplay way (restart) for the streamed segment
  only.
- The play clock starts when the player process starts. If the network
  is slower than playback, ffplay stalls and the highlight runs ahead.

## ffplay spike (ffplay at /etc/profiles/per-user/bill.liao/bin/ffplay)

Test file: `say` → ffmpeg → mp3, 64 kb/s, 7.57 s, 61 KB, piped into
`ffplay -nodisp -autoexit -i pipe:0` with `-stats`:

- No pause: 7.89 s wall.
- SIGSTOP at 2.0 s for 2 s, then SIGCONT: 7.83 s wall. The audio clock
  jumped from 2.38 to 4.29, so the paused stretch was **skipped** on a
  pipe, just as with a file. A throttled writer (4 KB / 0.25 s) gave the
  same result: 8.36 s wall, clock 2.00 → 3.54. SIGCONT is therefore not
  usable for ffplay.
- `-af atrim=start=3,atempo=1.0` on the pipe: 4.84 s wall, so it works
  as a seek. It decodes from byte 0 and drops the audio before the
  offset, so a restart must write ALL bytes received so far.
- Without `-infbuf`, `aq` stays at 8 KB: ffplay reads only about 1 s
  ahead, and the 64 KB pipe holds the rest. TTS output arrives faster
  than real time, so the pipe would fill after about 9 s of audio at
  64 kb/s and `process-send-string` would block Emacs. With `-infbuf`,
  `aq` was 59 KB at once. It is in the stdin argv.
- Engine run with the real ffplay (volume 5), mp3 sent in 4 KB pieces
  every 0.1 s through the queue: 7.95 s wall without a pause. With a
  2 s pause about 1 s in, which restarted the player on a new pipe with
  atrim, it took 9.89 s, which is consistent with nothing being skipped.
  Both utterances ended `done`. I did not listen for a gap or repeated
  audio at the restart.

## Tests

tests/utter-queue-tests.el, new "Streaming" block (fake `streaming`
backend struct with kind `bytes`, and a capture player whose stdin
command is `sh -c 'cat > FILE'`). The shared fake player gained
`:stdin-command` → `("cat")`. `utter-eng-with-queue` binds
`utter-streaming` and `utter--stream-player-warned` to nil.

- `utter-queue-stream-off-never-passes-stream`: `plist-member`, no
  `:stream` and no `:stream-callback`.
- `-stream-eligible-p`
- `-stream-plays-while-receiving`
- `-stream-only-the-segment-about-to-play`
- `-stream-not-for-cache-only-or-while-paused`
- `-stream-afplay-only-warns-once`
- `-stream-final-without-start-plays-whole`
- `-stream-error-after-start-retries-once`
- `-stream-pause-buffers-and-resume-flushes`
- `-stream-restart-resume-replays-stream-or-file`
- `-stream-pause-before-start-plays-file`
- `-stream-player-exit-mid-stream-is-an-error`
- `-stream-stop-aborts-the-request`
- `-stream-cues-grow-with-alignment`: sentence cues, the list grows in
  place, and the final alignment adds no duplicates.
- `-stream-word-cues-grow-with-alignment`
- `-stream-retry-drops-partial-cues`
- `-stream-player-commands`

tests/utter-tests.el:

- `utter-defaults-match-design` now includes `utter-streaming` nil.
- New `utter-inspect-query-shows-stream-only-when-streaming`.

TDD notes: the queue file first failed to load on the unknown
`:stdin-command` keyword. The pause-buffers test then failed on the
real `signal-process` bug above. The cue test failed because of a test
bug (the player ended before the second cue), and I fixed the test. The
inspect test failed with the utter.el change mutated out.
`make check`: 289 tests, 0 unexpected, no byte-compile warnings. The
queue file passed 5 runs in a row. `make lint` exited 0.

## Unverified

- mpv (not installed): its stdin argv, and whether SIGCONT keeps its
  place on a pipe. It is treated as a SIGCONT player.
- Underrun behaviour (stalled ffplay, highlight running ahead).
- Live backends: no real streaming backend was exercised. That is
  WP-D's live check.
- Audible quality at a mid-stream restart (see the spike).

## Deviations

1. `stdin-command` takes an optional OFFSET (contract C says `(rate
   format)`), so ffplay can restart mid-stream with atrim.
2. Plan 3.3 says resume after a stream ended should restart from the
   file. I do that only for restart-type players. SIGCONT players are
   continued and flushed instead, because a two-argument `command` such
   as mpv's cannot seek.
3. ffplay pauses by restarting, not by SIGCONT (spike), and the stdin
   argv adds `-infbuf`.
4. `utter-player-sigcont` uses `continue-process` (see Behaviour notes).
5. A second mid-stream failure is reported without the HTTP code.
6. WP-A's highlight functions are unchanged; I only call
   `utter--highlight-cues`.

## For WP-D and the coordinator

- Streaming needs both the `streaming` capability and a non-nil
  `utter--stream-kind`, and only mp3 streams in stage 1. A backend whose
  default format is not mp3 will not stream until WP-F.
- The queue relies on core's order: `(:end)`, then the final callback
  in the same step. A transport that runs the callback later could let
  a fast player exit first, which the sentinel would report as a
  player error.
