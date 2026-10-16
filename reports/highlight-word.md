# WP-A: word-level highlight

Written 2026-10-16. Branch `worktree-agent-acafadc470116d6f9`, based on
`main` at ae7044f.

## What was built

- `utter-highlight` accepts nil | t | `word` (utter.el; `:type` choice
  Off/Sentence/Word). `t` behaves as before: one overlay in
  `utter-highlight`, one cue and one `utter-progress-functions` call per
  sentence.
- New face `utter-highlight-sentence` (`:inherit secondary-selection`).
  It sits next to `utter-highlight` in utter-queue.el, where the old face
  already lived, not in utter.el.
- `utter--word-spans (text &optional beg end)` (utter-text.el): see
  "Deviations" for how words are found.
- utter-queue.el:
  - The cue vector is now `[SECONDS START END BEG END SENT-BEG SENT-END]`.
    Sentence cues put the same marker objects in slots 3/4 and 5/6.
  - New `utter--word-cues` and `utter--word-source`, and a dispatcher
    `utter--highlight-cues` that the `utter--segment-callback` cue line
    now calls. The callback still uses `condition-case`.
  - `utter--highlight-progress` picks the cue whose `[START,END)` contains
    START. A word cue (slot 3 not `eq` slot 5) shows the word overlay
    `utter--highlight-word-overlay` (face `utter-highlight`, priority 1)
    and the sentence overlay `utter--highlight-overlay` in
    `utter-highlight-sentence`. Any other cue, or no cue, deletes the word
    overlay and shows `utter--highlight-overlay` in `utter-highlight`,
    exactly as with `t`.
  - `utter--highlight-delete` removes both overlays.
    `utter--highlight-drop` detaches all four cue markers.
  - `utter--progress-start` no longer stops and recreates the timer. It
    ticks at once and starts a timer only if none is running. That makes
    it idempotent and safe to call again after cues are appended.
- Menu: new class `utter--highlight-variable`. `-H` cycles nil → t →
  `word`, shown as `(off)`/`(sentence)`/`(word)`. The key is unchanged.
  `utter--toggle-variable` now has no infix using it. I kept it because
  an existing test covers it.
- DESIGN.md: rule 3, a highlight paragraph, the defcustom table row, and
  the infix class list in the UI section.

## Behavior notes beyond the plan

- **The mode is captured when the utterance is queued.**
  `utter--build-item` appends `:highlight VALUE` to the item params when
  highlighting is on and there is a source buffer. Cues are built later,
  in the request callback, where the oneshot or buffer-local scope would
  already be gone. `utter--params-args` passes only known keys on, so
  `:highlight` never reaches `utter-request`. This edit is in the
  "Building an utterance" section of utter-queue.el, which is outside my
  stated ownership (WP-B does not touch utter-queue.el).
- **Fallback happens per sentence, not per segment.** If any word of a
  sentence cannot be placed in the buffer (for example a URL spoken as
  "link", or a pronunciation rewrite), that sentence keeps its sentence
  cue and looks exactly like `t`. The other sentences keep word cues.
  If the alignment does not match the segment text at all, there are no
  cues and the whole segment is highlighted, as today.
- A sentence with no words (only punctuation) keeps its sentence cue.
- Appending cues: the tick walks from the cached `utter-progress-tail`.
  Code that appends cues must either `nconc` onto
  `utter--segment-cues` or reset `utter-progress-tail` (as plan 3.4 says).
  If the list is replaced with a fresh copy, the cached tail no longer
  sees the new cues.
- `utter-highlight-follow` follows the word start in `word` mode.

## C2: header-line cost per word

`utter-mode--refresh` (utter-mode.el) runs on every
`utter-progress-functions` call. It calls `force-mode-line-update t`,
plus `tabulated-list-print t` when `*utter-queue*` exists. I timed it in
batch Emacs (no redisplay) with the queue buffer open: 0.03 ms per event
with 1 item, 0.26 ms with 10, and 2.45 ms with 100. That is about 25 µs
per row, linear in the number of listed utterances. Speech runs at about
3–5 words/s, so even 100 listed items cost about 12 ms per second.
Without the queue buffer the cost is only the mode-line update. I made
no change. If long queue histories become common, the queue buffer could
skip progress events and redraw only on state changes; that is the UI
owner's call.

## Tests

- utter-text-tests: `utter-text-word-spans-latin`,
  `-chinese-per-character`, `-mixed` (with BEG/END).
- utter-queue-tests: `utter-queue-highlight-t-is-sentence-unchanged`,
  `-word-two-overlays` (faces, priority, per-word events, mode captured
  at enqueue, an edit drops both overlays and all 4 markers),
  `-word-cjk-per-character`,
  `-word-falls-back-to-sentence-when-alignment-mismatch` (per-sentence
  URL fallback, and a whole-segment mismatch),
  `-word-cue-lookup-by-range`, `-progress-start-is-restartable` (one
  timer, catches up on a cue appended with `nconc`).
- utter-transient-tests: `utter-transient-test-highlight-cycles-off-sentence-word`.
- Each new test failed for the expected reason before its code was
  written (void function, 5-slot cues, missing overlay or class).
- `make check`: 262 tests, 0 unexpected, no byte-compile warnings.
  `make lint` (checkdoc + package-lint): exit 0.

## Deviations from the plan's contracts

1. **Word spans do not come from `forward-word`.** In batch,
   `forward-word` splits "don't", "well-known", "e.g." and "3.14" into
   two words each. The second half of each has no position tag, and the
   halves are not how the speech is heard. `utter--word-spans` uses runs
   of non-whitespace instead, trimmed of leading and trailing characters
   that are not word constituents under the source buffer's syntax table.
   Punctuation-only runs are skipped. Each CJK character is its own word
   (the plan's ranges U+4E00–9FFF, U+3040–30FF, U+AC00–D7AF, limited to
   word-syntax characters, so `・` is excluded).
2. **"Lines up" no longer means "every span has a tag".**
   `utter--tag-positions` tags only the start of each run of non-space
   text, so CJK characters after the first one in a run never have a tag.
   `utter--word-source` counts from the nearest tag at or before the word
   and checks that the buffer text there equals the word. If it does not,
   it searches for the word inside the sentence. The existing per-segment
   check (`(= (length starts) (length piece))`, all sentences tagged) still
   applies through `utter--sentence-cues`. The tagger is unchanged.
3. The fallback is per sentence rather than per segment (see above). The
   result has the same shape as the contract.

## Unverified

- The look in a real GUI frame: overlay priority and face merging of
  `utter-highlight` over `secondary-selection`. Tests run only in batch,
  as instructed.
- Live word timing from ElevenLabs or xAI. All tests use made-up
  alignments.
- Hangul: words are per syllable, as the plan specifies. Korean puts
  spaces between words, so per-word highlighting may suit it better.
  Untested with real Korean audio.
