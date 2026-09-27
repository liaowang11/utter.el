# ENV report (branch `env`)

## What was built

- `Makefile`: same targets and `load-prefer-newer` BATCH as before, plus
  - `test` loads `ert` explicitly; with zero `tests/*-tests.el` it runs
    0 tests and exits 0 (checked).
  - `test-file FILE=tests/x-tests.el` runs one file; without FILE it
    prints usage and exits 2.
  - `lint` now **fails** on checkdoc problems. `checkdoc-file` only
    `warn`s in batch and exits 0, so the target advises `checkdoc-error`
    and exits 1 listing the failing files. Then package-lint runs with
    `package-lint-main-file` = `utter.el` over every `utter*.el`, or
    prints "package-lint not installed (make lint-deps); skipping".
  - `lint-deps` installs package-lint from MELPA into the user package
    dir (CI runs it).
- `.github/workflows/ci.yml`: push to main + pull_request.
  `linux` job: ubuntu-latest, matrix `30.1` / `snapshot`, steps
  `make lint-deps`, `compile`, `lint`, `test`; `fail-fast: false` and
  `continue-on-error` only for snapshot. `macos` job: macos-latest,
  Emacs 30.1, `make test`.
- `tests/support/utter-test-server.el`: local HTTP stub (API below).
- `tests/utter-test-server-tests.el`: 9 self-tests against real curl.
- `README.md` (176 lines), `.gitignore` (`*.elc`, `/reports/*.tmp`,
  `.agent-shell/`, `/.eask`, `/tmp/`).
- `.dir-locals.el` did not exist on main; none was created.

## Verification

- Emacs 31.1.50 (local) and Emacs 30.2 (`nixpkgs#emacs30-nox`):
  `make compile lint test` pass; 9/9 server tests in ~0.6 s. Emacs 30.1 itself was
  not run locally.
- Zero-test path: `make test` before the server tests existed printed
  "Ran 0 tests" and exited 0.
- `make lint` negative checks: a file with a bad docstring makes checkdoc
  fail with exit 1; with package-lint installed (temp HOME, `make
  lint-deps` against MELPA) a wrong-prefix defun fails package-lint. The
  stub `utter.el` passes both.
- Support files byte-compile with `byte-compile-error-on-warn t` and pass
  checkdoc.
- Workflow YAML parsed with `python3 -c 'import yaml; ...'`.

## Using the stub server

```elisp
(require 'utter-test-server)   ; tests/support is on the load path in make

(ert-deftest utter-openai-sends-bearer ()
  (utter-test-server-with
      (port `(("^/v1/audio/speech$"
               . (:headers (("Content-Type" . "audio/mpeg"))
                  :body ,(utter-test-server-mp3-bytes)))))
    (let ((backend (utter-make-openai "Test"
                     :host (format "127.0.0.1:%d" port) :protocol "http"
                     :key "sk-test"))
          result)
      (utter-request "hi" :backend backend :cache nil
                     :callback (lambda (audio info) (setq result (list audio info))))
      (utter-test-server-wait-for (lambda () result))
      (should (equal (utter-test-server-header
                      (car (utter-test-server-requests)) "Authorization")
                     "Bearer sk-test")))))
```

- `(utter-test-server-start ROUTES)` -> port; `(utter-test-server-stop)`
  also closes open connections. `utter-test-server-with (PORT-VAR ROUTES)
  BODY` wraps start/stop in `unwind-protect`.
- ROUTES: `((PATH-REGEXP . RESPONDER) ...)`, first match against the
  request target (path + query) wins, no match = 404. RESPONDER is a
  plist `(:status :headers :body)` (defaults 200, nil, "") or a function
  `(METHOD PATH HEADERS BODY)` returning one; a signalling responder
  gives a 500 with the error message as body.
- `(utter-test-server-requests)` -> oldest first, plists
  `(:method :path :headers :body)`; HEADERS is an alist with names as
  sent; `(utter-test-server-header REQ NAME)` is case-insensitive.
- `utter-test-server-url PATH`, `utter-test-server-port`,
  `utter-test-server-running-p`.
- `(utter-test-server-wait-for PRED &optional TIMEOUT)` pumps events
  until PRED is non-nil; signals an error after TIMEOUT (10 s).
- Bodies: `utter-test-server-mp3-bytes` (one `\xff\xfb` frame; with arg
  prefixed by an `ID3` tag), `utter-test-server-wav-bytes &optional
  SAMPLES RATE` (44-byte header, 16-bit mono, default 24 kHz, 8 samples),
  `utter-test-server-json OBJ &optional STATUS` (`json-encode`, UTF-8
  bytes, JSON content type).
- The server always sets its own `Content-Length` and
  `Connection: close`, answers `Expect: 100-continue`, and closes after
  one response. Chunked request bodies are not supported (curl with
  `--data-binary @file` never sends them).

Pitfalls for other agents:

1. **Never drive the stub with a synchronous `call-process`.** The
   server runs in the test's own Emacs; a blocking call stops the event
   loop and curl hangs. The task text suggested `call-process` for the
   self-test; I used `make-process` + `utter-test-server-wait-for`
   instead for this reason. `utter-request` is async, so it is fine.
2. **HTTP proxies.** curl honors `http_proxy` for 127.0.0.1 (Bill's
   machine sets proxies). `utter-test-server-with` binds
   `no_proxy`/`NO_PROXY=127.0.0.1,localhost` in `process-environment`,
   so curl started inside the macro bypasses the proxy. Verified both
   ways: `utter-test-server-with-bypasses-proxy` passes with a dead
   `http_proxy=127.0.0.1:9` set, and the same curl without the binding
   exits 7. Tests that call
   `utter-test-server-start` directly must do the same, or CORE's curl
   runner must pass `--noproxy` for localhost. A proxied request shows up
   as a timeout or a proxy error page, not as a route miss.
3. Give `make-process` a `:sentinel` (e.g. `#'ignore`) when capturing
   stdout into a buffer, or the default sentinel appends "Process ...
   finished" to the output.

## HANDOFF / notes for the merge

- The Makefile gained `test-file` and `lint-deps`, and `lint` now fails
  on checkdoc warnings. Other branches that run `make lint` after the
  merge will see failures they did not see before if their docstrings
  are not checkdoc-clean. No other Makefile behavior changed, so merges
  should be conflict-free unless another branch edited the Makefile.
- `make compile` still does not treat byte-compile warnings as errors.
  Consider `byte-compile-error-on-warn` once all modules land.
- README uses exact constructor names and keywords from DESIGN.md.
  Guesses that owners should confirm: `utter-make-preset`'s `:backend`
  takes the backend name string; `utter-speak-buffer`'s prefix argument
  means "from point"; `utter-speak-kill` speaks the latest kill. The
  queue buffer is described as "`Q` in the menu" because the command
  name is not frozen.

## Unverified

- Emacs 30.1 exactly (tested 30.2 and 31.1.50).
- CI has never run. `purcell/setup-emacs@master` with 30.1 on
  `macos-latest` (arm64) and with `snapshot` on ubuntu are unverified,
  as is `make lint-deps` reaching MELPA from the runner.
- Server tests were run on macOS only; Linux (CI) is expected to work
  (plain IPv4 loopback, curl only) but untested. Ubuntu's older curl
  sends `Expect: 100-continue` for bodies > 1 KB; the self-test forces
  that header, so the path is covered.
