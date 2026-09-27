# UI report (branch `ui`)

## What was built

- `utter-transient.el`: `utter-menu` with the DESIGN.md layout: heading
  `utter--menu-heading`, then Backend, Input, Output and Playback columns,
  then `RET`/`I`. Uses `:refresh-suffixes t` and `:incompatible` for the input
  switches and for the output switches. Playback has `:if utter-active-p` and
  every suffix is `:transient t`. `I` has `:if utter-expert-commands`.
  - Infix classes: `utter-lisp-variable` (display-nil and display-map; set
    through `(funcall set-value var value utter--set-scope)`),
    `utter-provider-variable` (one reader for `Backend:model` with an
    annotation for description, capabilities, max chars and cost; sets both
    variables, resets `utter-voice` when the voice is not valid for the new
    backend, then calls `(transient-setup)`), `utter-voice-variable`, plus
    `utter--scope-variable` (cycles global, buffer, oneshot),
    `utter--toggle-variable` (`-H`) and `utter-preset-variable` (`@`).
  - Readers: `utter--transient-read-number` (a copy of gptel's), voice
    (static list, or `utter--list-voices` with a callback; a cache miss
    starts the fetch, accepts free input, and redraws the menu when the list
    arrives), format, language, instructions, preset.
  - `utter--suffix-speak (args)` is the single dispatch and works when called
    with `nil`. `r` or no switch uses `utter--text-at-point` when it is
    defined, otherwise the region or the sentence at point. `b` reads from
    point to the end, `o` the Org subtree, `e` the whole (narrowed) buffer,
    `y` `current-kill`, `m` `read-string`, `t` the evaluated
    `read--expression`. `s` or no switch calls `utter-enqueue`, `S`
    `utter-interrupt`, `f` `utter-save-to-file` with a `read-file-name`, and
    `c` `utter-enqueue ... :cache-only t`. Buffer inputs pass `:source-buffer`
    and `:source-name`; other inputs pass `:source-name` only
    (`"kill-ring"`, `"minibuffer"`, `"Lisp"`).
  - `utter--suffix-inspect` runs a dry-run `utter-request` into
    `*utter-inspect*`, truncated to the backend's max-chars.
  - Live heading: opening the menu puts `utter-transient--refresh-menu` on
    `utter-progress-functions`. I also put it on `utter-queue-finished-hook`,
    which goes beyond the brief, so the Playback column disappears as soon as
    the queue empties (mockup screen B). The function calls
    `transient--refresh-transient` only under the
    `(eq (oref transient--prefix command) 'utter-menu)` guard, only when no
    minibuffer is active (an infix reader may be open, for example while a
    voice list arrives), inside the original buffer and
    `with-demoted-errors`. A
    `transient-exit-hook` removes it once `transient--prefix` is nil, which
    means the menu really closed. The exit hook also runs on a `replace`
    redraw, so it checks before removing.
  - Evil fix: `utter--transient-fix-evil-visual` is copied from gptel and
    guarded by `fboundp`/`boundp`. It is attached to the `environment` slot
    only when that slot exists (see the transient findings below).
- `utter-mode.el`
  - `utter-mode`: buffer-local, no lighter. It saves `header-line-format`,
    installs `(:eval (utter--header-line))`, and restores the old value on
    exit; enabling it twice is safe. Header example:
    `▶ utter · NAME 2/5 · 0:31/1:12 · Backend voice · 1.0x · SPC pause  n/p utterance  +/- rate  q stop`.
    The glyph is `⏸` when paused and `⟳` while synthesizing; when paused the
    first hint reads `SPC resume`. With unknown duration the time shows
    `0:04/--`. The idle header is `utter · idle`. The hints are `buttonize`
    buttons. In writable buffers the hints start with `C-c C-o: `.
  - `utter-mode-map`: the keys of `utter-mode-command-map` (`SPC n p + - q
    x m Q RET`) work as single keys through a `menu-item :filter` that
    passes only in read-only buffers. The same map is always available
    under `C-c C-o`.
  - Refresh: `utter-mode--refresh` (`force-mode-line-update` plus redrawing
    the queue buffer) runs on `utter-progress-functions`,
    `utter-item-finished-functions`, `utter-queue-finished-hook` and
    `utter-enqueue-hook`. It is removed when the last `utter-mode` buffer
    disables the mode or is killed. There is no timer.
  - `utter-queue-mode` (derived from `tabulated-list-mode`, with
    `tabulated-list-use-header-line` nil) and the `utter-queue` command show
    `*utter-queue*` with one row per utterance. Columns: status (`✓ played`,
    `▶ playing`, `⏸ paused`, `⟳ synth`, `· pending`, `✗ error`,
    `⏹ interrupted`), `#`, `Backend:voice`, first words (40 columns),
    time, and source. Time is `elapsed/duration` for the current item,
    the duration alone for finished ones, and `--` when unknown. The current
    item shows the player's paused or synthesizing status. Keys: `RET`/`o`
    `utter-visit-source`, `d` `utter-queue-remove` (pending only), `r`
    `utter-queue-replay`. The mode turns on `utter-mode` and redraws after
    each command in the buffer.

## Verification

- `make check` on Emacs 31.1.50 with transient 0.13.8: compile clean,
  **48 tests, 48 expected**.
- `make check EMACS=/nix/store/b6n5yar58b47aby6zi51vxlh901rdw4a-emacs-30.2/bin/emacs`
  (bare Emacs 30.2 with its bundled transient 0.7.2.2): compile clean, 48/48.
- `make lint` (checkdoc): clean for `utter-mode.el`, `utter-transient.el` and `utter.el`.
- The menu tests really run `transient-setup` in batch. They check the
  shown keys and commands, `:transient t`, `refresh-suffixes`,
  `incompatible`, the rendered labels and heading, the Playback column
  hiding when idle and showing when playing, and `I` appearing only with
  `utter-expert-commands`. A test also calls the real
  `transient--refresh-transient` from a progress hook, with an unrelated
  current buffer, and checks that the Playback column and heading show up.
- The fake engine lives in `tests/utter-mode-tests.el`. It stubs only plain
  functions, inside `cl-letf`. `utter-item` and `utter-backend` structs are
  defined only when `(cl-find-class ...)` finds no class, using DESIGN.md's
  slots, so after the merge the tests use the real structs. The
  `cl-defstruct` forms are quoted and `eval`ed, because eager
  macroexpansion would otherwise register the class before the guard runs.
  The tests `let`-bind `utter-backend`; they never `setq` it. There are no top-level `defalias` calls on engine symbols.
- A test greps the four UI files for the internal unit word, case-insensitive.

## Transient version findings

- Emacs 30.1 bundles **transient 0.7.2.2**. I confirmed this in
  `emacs-mac-30_1_exp:lisp/transient.el` and in the Emacs 30.2 store build.
  0.7.2.2 already has the `refresh-suffixes` slot,
  `transient--refresh-transient`, `transient--redisplay`,
  `transient-exit-hook` and the `set-value` slot. `transient--refresh`
  does not exist in 0.7.2.2, 0.13.7 or 0.13.8.
- The `environment` prefix slot was added in **transient 0.7.8** (transient
  CHANGELOG, v0.7.8, 2024-11-02). So `:environment` in
  `transient-define-prefix` fails on bundled 0.7.2.2. I attach it with
  `(when (slot-exists-p 'transient-prefix 'environment) (oset ...))`
  instead. According to the CHANGELOG, v0.8.0 is where returning to a
  prefix re-initializes the suffixes of a `refresh-suffixes` prefix.
- The current `Package-Requires` `(transient "0.7.5")` is above the bundled
  0.7.2.2, so stock Emacs 30.1 already installs transient from ELPA.
  Recommendation: raise the minimum to **0.7.8**, which gptel also
  requires, so the evil fix is always active. The code also works on
  0.7.2.2 without the evil fix, so lowering to 0.7.2.2 is the other option.

## Deviations from DESIGN.md (decide in the main session)

1. **Rate down in the menu is `_`, not `-`.** In transient, `-` cannot be a
   suffix key while `-m`, `-v`, `-s`, ... exist, because it is their prefix
   key. Transient signals "Key sequence - y starts with non-prefix key -"
   (0.13) or a wrong-type error (0.7). `+`/`_` are the shifted `=`/`-`
   keys. `utter-mode-map` keeps `+`/`-`. DESIGN.md's menu diagram should
   say `+/_`.
2. `RET` as a single key in read-only buffers shadows link activation in
   EWW and Info when the user turns on `utter-mode` there (mockup screen E).
   I implemented it as specified; outside the queue buffer it only shows a
   message. Consider limiting the single-key `RET` to `utter-queue-mode`.
3. `Q` sits only in the Playback column as DESIGN specifies, so the menu
   cannot open the queue buffer while idle (`M-x utter-queue` still can).

## HANDOFF

Symbols from DESIGN.md that the UI uses:
`utter-state`, `utter-active-p`, `utter-enqueue`, `utter-interrupt`,
`utter-save-to-file`, `utter-toggle-pause`, `utter-next`, `utter-previous`,
`utter-rate-up`, `utter-rate-down`, `utter-stop`, `utter-clear`,
`utter-replay-item`, `utter-item-status`, `utter-item-text`,
`utter-item-params`, `utter-item-source-buffer`, `utter-item-source-name`,
`utter-backend-name`, `utter-backend-models`, `utter-backend-voices`,
`utter-backend-formats`, `utter-backend-capabilities`,
`utter-backend-max-chars`, `utter-get-backend`, `utter--known-backends`,
`utter--list-voices`, `utter-get-preset`, `utter--apply-preset`,
`utter--set-with-scope`, `utter--set-scope`, `utter-request` (`:dry-run t`),
`utter-progress-functions`, `utter-item-finished-functions`,
`utter-queue-finished-hook`, `utter-enqueue-hook`, and the variables
`utter-backend utter-model utter-voice utter-speed utter-format
utter-language utter-instructions utter-highlight utter-playback-rate
utter-expert-commands`.

Symbols or conventions the UI expects that DESIGN.md does not define
(ENGINE/CORE please provide or say otherwise). Each call is guarded, and
the guard is noted:

- ENGINE `utter--text-at-point (&optional ARG) -> (TEXT . SOURCE-NAME)`: the
  text selection `utter-speak` uses. If it is missing, the UI falls back to
  the region or the sentence at point (`fboundp`).
- ENGINE `utter--queue-items () -> list of utter-item`, in queue order,
  including finished, current and pending items. The queue buffer is empty
  without it (`fboundp`).
- ENGINE `utter--queue-remove (ITEM)`: removes a pending item (the `d` key).
  Not guarded; it errors if missing.
- ENGINE `utter--item-duration (ITEM) -> seconds or nil`: duration of a
  non-current item for the Time column (`fboundp`).
- ENGINE `utter--known-presets`: alist `(NAME . PLIST)` of registered
  presets, used for `@` candidates (`bound-and-true-p`).
- ENGINE `utter--apply-preset PRESET SETTER` calls `(funcall SETTER SYM VAL)`,
  as in gptel. The UI passes a setter that applies `utter--set-scope`.
- ENGINE `utter-enqueue` accepts `:cache-only t`: synthesize and cache
  without playing (Output `c`).
- ENGINE `utter-state` returns `:status idle` (or nil) when idle; `:backend`
  may be a name string or a backend object (both are displayed). `:rate`
  falls back to `utter-playback-rate`.
- ENGINE `utter-language` holds a symbol (`auto`, `en`, `zh-CN`, ...); the
  menu reader interns what the user types.
- ENGINE `utter-backend` holds a backend object; a registered name string
  also works (it goes through `utter-get-backend`).
- ENGINE playback commands (`utter-toggle-pause`, `utter-next`, ...) must be
  interactive commands, because transient refuses non-command suffixes.
- CORE `utter--list-voices BACKEND CALLBACK` calls `(CALLBACK VOICES &rest _)`.
  It may call synchronously on a cache hit, which the UI detects, or later
  after a fetch. VOICES are strings or `(NAME . INFO)`; INFO shows as the
  annotation.
- CORE model entries in the `models` slot are symbols (metadata through
  `(get MODEL :description)` and so on) or `(SYMBOL . PLIST)`. The plist
  keys the UI reads are `:description`, `:capabilities` (list of symbols)
  and `:cost` (dollars per 1M characters, 0 shows as "free"). The UI stores
  the bare symbol in `utter-model`. The `(SYMBOL . PLIST)` form keeps the
  metadata with the backend definition and does not touch global symbol
  plists.
- ENGINE `utter.el` must reach `utter-menu` and `utter-queue` through
  autoloads (`utter-transient.el` has the `;;;###autoload` cookie for
  `utter-menu`). It must never `require` `utter-transient` or `utter-mode`,
  because both `(require 'utter)`, so that would create a require cycle.
  This matters for `C-u utter-speak`, which opens the menu.
- Package: `Package-Requires` `transient` minimum, see above.

## Unverified

- Real keyboard use in an interactive Emacs: pressing infixes, readers in
  the minibuffer, `(transient-setup)` redraw after `-m`/`@`, and header-line
  mouse clicks on the hint buttons (`buttonize` binds `<header-line>
  <mouse-2>`; `mouse-1` may not activate them). The batch tests call
  readers and `transient-infix-set` directly.
- `transient--refresh-transient` from a real process filter or sentinel
  while the user is typing in the menu. It is tested in batch from a hook
  call on both transient versions, but not under a live command loop.
- The evil visual-state fix with real evil (tested with stubbed evil
  functions only).
- Behaviour against the real ENGINE/CORE: every engine call here is a fake.
- Not run on Linux. I ran only on darwin, and the tests need no
  macOS-only binaries: Org is bundled, and nothing calls `say`, `afplay`,
  or the network.
- The `RET` label "(appends as utterance N)" reads `(transient-args
  'utter-menu)` while the menu renders. On transient 0.7.2.2 this may
  return saved values rather than the live switches, so the label can be
  wrong for one redraw when `S`/`f`/`c` is toggled. This is cosmetic.
- The `o` input before the first Org heading signals Org's own error, not
  a friendly message.
