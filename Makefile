EMACS ?= emacs

# load-prefer-newer: `make compile` leaves .elc files behind, and without it a
# later `make test` silently runs the stale compiled copy.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)'

SRC = $(wildcard utter*.el)
TESTS = $(wildcard tests/*-tests.el)

.PHONY: compile test lint check clean

compile:
	$(BATCH) -L . -L tests/support -f batch-byte-compile $(SRC)

test:
	$(BATCH) -L . -L tests/support -L tests \
		$(foreach t,$(TESTS),-l $(t)) \
		-f ert-run-tests-batch-and-exit

lint:
	$(BATCH) -L . --eval '(setq checkdoc-verb-check-experimental-flag nil)' \
		--eval '(dolist (f (list $(foreach f,$(SRC),"$(f)"))) (checkdoc-file f))'

check: compile test

clean:
	rm -f *.elc tests/*.elc tests/support/*.elc
