EMACS ?= emacs

# load-prefer-newer: `make compile` leaves .elc files behind, and without it a
# later `make test` silently runs the stale compiled copy.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)'

SRC = $(wildcard utter*.el)
TESTS = $(wildcard tests/*-tests.el)

# Dependencies live in the project-local .deps/elpa (gitignored), filled by
# `make deps': transient from GNU ELPA, because the copy bundled with Emacs
# 30.x (0.7.2.2) predates the `:environment' slot the menu needs, and
# package-lint from MELPA for `make lint'.  When .deps is absent the batch
# Emacs runs on whatever it bundles, and `make lint' skips package-lint.
DEPS_DIR = $(CURDIR)/.deps/elpa
DEPS_INIT = --eval '(when (file-directory-p "$(DEPS_DIR)") (require (quote package)) (setq package-user-dir "$(DEPS_DIR)") (package-initialize))'
BATCH += $(DEPS_INIT)

.PHONY: compile test test-file lint deps lint-deps check clean

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
	$(BATCH) -L . \
		--eval '(unless (require (quote package-lint) nil t) (message "package-lint not installed (make deps); skipping") (kill-emacs 0))' \
		--eval '(setq package-lint-main-file "utter.el")' \
		-f package-lint-batch-and-exit $(SRC)

deps:
	mkdir -p $(DEPS_DIR)
	$(BATCH) \
		--eval '(add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")) t)' \
		--eval '(package-refresh-contents)' \
		--eval '(let ((descs (cdr (assq (quote transient) package-archive-contents)))) (package-install (or (seq-find (lambda (d) (equal (package-desc-archive d) "gnu")) descs) (car descs))))' \
		--eval '(package-install (quote package-lint))'
	$(BATCH) --eval '(progn (require (quote transient)) (message "transient %s from %s" transient-version (locate-library "transient")))'

lint-deps: deps

check: compile test

clean:
	rm -f *.elc tests/*.elc tests/support/*.elc
