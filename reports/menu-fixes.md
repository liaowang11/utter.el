# Menu fixes (2026-09-28)

Scope: `utter-transient.el`, `tests/utter-transient-tests.el`, the menu
parts of `DESIGN.md` and `README.md`. Engine files untouched. Reviews in
`~/PARA/projects/emacs-tts-package/menu-review/`.

## What changed, per item

Bill's decisions
1. `s` switch gone. `:incompatible '(("m" "y") ("S" "f" "c"))`. The RET
   label says "append as utterance N" while something plays.
2. Group titles are now ` <Read from <label>` and ` >Output to`. The label
   is `minibuffer` with `m`, `kill-ring "first words…"` with `y` (or
   `kill ring empty` in the `error` face), otherwise the engine's input
   label computed in the source buffer. `nothing` also uses `error`.
3. Rate keys stay `+`/`_`. The rate shows once, as `Rate up (1.2x)`. It is
   gone from the menu heading, which was the second place it appeared. The
   header line in `utter-mode` still shows it.
4. `I` shows when `utter-expert-commands` or `utter-log-level` is set.
   `C-u` with `y` calls `read-from-kill-ring`.
5. The RET label covers source, line range, estimate and destination, for
   example `Speak region (lines 9-10, ~6 s), append as utterance 6`,
   `… , interrupt now`, `Save buffer to point (lines 1-12) to file`,
   `Synthesize … , cache only`, `Speak minibuffer input`,
   `Speak kill-ring "…" (~4 s)`, and `Nothing to read aloud` in the `error`
   face. Idle with no switch: plain `Speak <source> (…)`. `interrupt now`
   shows only while something plays, because idle means nothing to
   interrupt. Save leaves out the time estimate, as in Bill's example.
   `utter-transient--plan` is memoized on (buffer, tick, point, mark,
   region, switches, head of kill ring, speed, input functions), so the
   heading and RET share one computation per redraw. Errors in input
   functions become the `nothing` label.

Bugs
A. The voice list comes from `utter--static-voices backend utter-model`,
   with the async fetch as a fallback. A fetched result that is not a list
   is ignored. There is a new fake `xAI` backend with `:voices 'fetch`.
   Before: `(wrong-type-argument sequencep fetch)`. After: the reader opens,
   and after caching the list comes from the cache with no second fetch.
B. `utter-menu` calls `(utter--sanitize-settings)` before `transient-setup`.
   `-m` calls it after changing the backend, using the menu scope setter and
   skipping the model it just chose. `utter-transient--voice-valid-p` is
   deleted.
C. `I` resolves the text with `utter-transient--input args` and calls
   `utter--inspect-text` in the source buffer. The private `utter-request`
   call is gone (the test fails if `utter-request` is called).
D. Added `utter-transient--live-args` using gptel's binding trick. The
   heading and RET use it. Verified with real key presses
   (`execute-kbd-macro "S"`, `"f"`, `"m"`) on both transient versions.
E. `(add-hook 'utter--state-change-hook #'utter-transient--refresh-menu)`
   now runs once at load. Removed the install/remove functions and the
   progress/finished hooks. The go-idle path runs through `utter--schedule`,
   which then calls `utter--changed`, so the Playback column still
   disappears (tested). Guards: the menu is open, it is `utter-menu`, no
   minibuffer is active, and a new one: `transient-current-command` is nil.
   That last guard skips a synchronous redraw while a menu suffix such as
   SPC runs, because transient redraws in post-command anyway. The redraw
   goes through `transient--env-apply` when that function exists.
   Before/after: C-z, `transient-resume`, then a state change. Old code
   left the heading at `Idle`. New code shows `Playing …`.
F. `Q` has no `:transient` now, so it exits. Tested with a real `Q` key
   press: `transient--prefix` is nil afterwards.
G. `-i` is `:inapt-if` when `utter--capable-p` is nil for the source
   buffer's backend and model. A new `utter--text-variable` flattens
   newlines and truncates the value to 35 characters.
H. `=` renders `(global|buffer|oneshot)`. The active scope uses
   `transient-value` and the others `transient-inactive-value`.
I. `@` uses the variable `utter--preset`. `utter-transient--preset` is
   deleted. The name is struck through when any spec key no longer matches
   (`:backend` by name or object, others via `utter--preset-var`, parents
   checked recursively, values read in the source buffer). The reader shows
   each preset's `:description`. `:inapt-if` when there are no presets.
J. `-m`: `:group-function` by backend name. The limit shows as `4096ch`
   (`B`/`u16` for byte/UTF-16 backends). Capabilities are filtered through
   `utter--capable-p`, so `:capabilities nil` shows none. The annotation is
   nil when nothing is known. `-f`: `require-match t`, candidates from
   `utter--formats backend utter-model`. `-v`: the current voice is the
   default, so RET keeps it. A `(backend default)` candidate, offered when a
   voice is set, clears it. `-l`: new `default` slot, and `auto` renders
   inactive.
K. `f`: `utter--single-segment` runs on `utter--snapshot-params` before
   `read-file-name`. The default name is
   `<source name sans extension>.<utter-format or first format>`.
L. **Not done as written.** See below.

## Not done / deviations

- **L (`:environment` inline).** Emacs 30.1/30.2 bundle transient
  0.7.2.2. CI's `emacs -Q` loads that copy, and there
  `transient-define-prefix` with `:environment` fails at load time:
  `Invalid slot name: "#<transient-prefix …>", :environment`
  (reproduced with emacs-nox 30.2 from the nix store). Putting it inline
  would break every test on CI's 30.1 job. I kept the `slot-exists-p` +
  `oset` block and wrote the reason in its comment and in DESIGN.md.
  Dropping the guard needs either CI installing transient ≥ 0.7.8 from
  ELPA or Emacs ≥ 31 as the minimum.
- The kill-ring label reads `(current-kill 0 t)`, the same text RET will
  read, so the label is true when the system clipboard holds something
  newer. Side effect: as with a yank, a changed clipboard is pushed onto
  the kill ring during a redraw.
- HANDOFF (engine): `utter--model-valid-p` accepts any model on a backend
  without a model list, so a preset or setting that leaves
  `gpt-4o-mini-tts` on `say` still shows `say:gpt-4o-mini-tts` after
  sanitizing. The menu test uses a backend with a model list.

## Verification

- TDD. The first run of the new tests against the old code had 30 of 69 (file run)
  failing. Among them: A with `wrong-type-argument sequencep fetch`, C with
  "Inspect must not call utter-request", and the layout, heading, RET,
  scope, preset, format, voice and hook tests. The suspend and `Q` tests
  were added later, failed on the old `utter-transient.el` (stashed), and
  pass now.
- `tests/utter-transient-tests.el`: 52 tests (was 29); `make test-file` on it runs 72 with the `utter-mode` tests it loads.
- `make clean && make check` (Emacs 31.1.50, transient 0.13.8): 241/241.
  `make lint`: exit 0. package-lint from the straight checkout on
  `utter-transient.el`: exit 0 (not installed for `make lint`).
- `make clean && make check EMACS=…emacs-nox-30.2` (bundled transient
  0.7.2.2): 240 pass, 1 skipped (the `transient--env-apply` test, which
  does not exist there). `make lint` exit 0.
- Batch render on both versions (script `/tmp/utter-probe/render.el`,
  fake engine from the tests). Output is the same except for trailing
  whitespace. Idle and playing:

```
===== idle, buffer to point (0.13.8) =====
Idle
Backend                                    <Read from buffer to point   >Output to
 -m Backend:model OpenAI:gpt-4o-mini-tts   m Minibuffer instead (m)     S Speakers, interrupt (S)
 -v Voice (default)                        y Kill-ring instead (y)      f Save to file (f)
 -s Speed 1.0                                                           c Cache only (c)
 -f Format (default)
 -l Language auto
 -i Instructions (none)
 -H Highlight spoken text (off)
 = Scope (global|buffer|oneshot)
 @ Preset (none)

 RET Speak buffer to point (lines 1-12, ~36 s)

===== playing, region lines 9-10 (0.13.8) =====
Playing reading-aloud.org (2/5) · OpenAI:gpt-4o-mini-tts/nova
Backend                                    <Read from region          >Output to                 Playback
 -m Backend:model OpenAI:gpt-4o-mini-tts   m Minibuffer instead (m)   S Speakers, interrupt (S)   SPC Pause/resume
 -v Voice (default)                        y Kill-ring instead (y)    f Save to file (f)          n Next utterance
 -s Speed 1.0                                                         c Cache only (c)            p Previous utterance
 -f Format (default)                                                                              + Rate up (1.0x)
 -l Language auto                                                                                 _ Rate down
 -i Instructions (none)                                                                           x Clear pending
 -H Highlight spoken text (off)                                                                   q Stop all
 = Scope (global|buffer|oneshot)                                                                  Q Queue buffer
 @ Preset (none)

 RET Speak region (lines 9-10, ~6 s), append as utterance 6

```

  With switches: `S` → `RET Speak buffer to point (lines 1-12, ~36 s), interrupt now`;
  `f` → `RET Save buffer to point (lines 1-12) to file`;
  `y` → heading ` <Read from kill-ring "The first words of the …"`, `RET Speak kill-ring "The first words of the …" (~4 s), append as utterance 6`;
  `y` with an empty kill ring → ` <Read from kill ring empty`, `RET Nothing to read aloud`.

Not verified: rendering under vertico/marginalia (group function and
annotations are tested as functions only), evil visual state in a real
session, and the real `say`/network voice fetch (stubbed).

Update (main session, same day): `make deps` now installs transient from GNU ELPA into `.deps/elpa` and CI runs it on every job, so item L is done: `:environment` is inline in the prefix and the `slot-exists-p` guard is gone.
