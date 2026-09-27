EMACS ?= emacs

# load-prefer-newer: `make compile` leaves .elc files behind, and without it a
# later `make test` silently runs the stale compiled copy.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)'

SRC = $(wildcard utter*.el)
TESTS = $(wildcard tests/*-tests.el)

# package-lint lives in the user's package directory.  `make lint-deps'
# installs it from MELPA (CI does this); without it `make lint' skips it.
PACKAGE_INIT = --eval '(progn (require (quote package)) (package-initialize))'

.PHONY: compile test test-file lint lint-deps check clean

compile:
	$(BATCH) -L . -L tests/support -f batch-byte-compile $(SRC)

# With no test files yet this runs ERT on zero tests, which exits 0.
test:
	$(BATCH) -L . -L tests/support -L tests -l ert \
		$(foreach t,$(TESTS),-l $(t)) \
		-f ert-run-tests-batch-and-exit

# make test-file FILE=tests/utter-core-tests.el
test-file:
	@test -n "$(FILE)" || { echo "usage: make test-file FILE=tests/NAME-tests.el"; exit 2; }
	$(BATCH) -L . -L tests/support -L tests -l ert -l $(FILE) \
		-f ert-run-tests-batch-and-exit

# checkdoc only `warn's in batch and exits 0, so count `checkdoc-error'
# calls per file and fail at the end.  package-lint runs when installed.
lint:
	$(BATCH) -L . -l checkdoc --eval '(setq checkdoc-verb-check-experimental-flag nil)' \
		--eval '(let (bad hit) (advice-add (quote checkdoc-error) :before (lambda (&rest _) (setq hit t))) (dolist (f (list $(foreach f,$(SRC),"$(f)"))) (setq hit nil) (checkdoc-file f) (when hit (push f bad))) (when bad (message "checkdoc failed: %s" (nreverse bad)) (kill-emacs 1)))'
	$(BATCH) -L . $(PACKAGE_INIT) \
		--eval '(unless (require (quote package-lint) nil t) (message "package-lint not installed (make lint-deps); skipping") (kill-emacs 0))' \
		--eval '(setq package-lint-main-file "utter.el")' \
		-f package-lint-batch-and-exit $(SRC)

lint-deps:
	$(BATCH) $(PACKAGE_INIT) \
		--eval '(add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")) t)' \
		--eval '(package-refresh-contents)' \
		--eval '(package-install (quote package-lint))'

check: compile test

clean:
	rm -f *.elc tests/*.elc tests/support/*.elc
