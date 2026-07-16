# Top-level Makefile for bookmark-plus-gt.
#
# Targets:
#   make test      - run the ERT test suite in batch mode
#   make compile   - byte-compile the source files
#   make clean     - remove .elc files

EMACS ?= emacs

# Sibling Bookmark+ submodule; loaded before our own sources.
PLUS_DIR = ../bookmark-plus

CORE_FILES = bookmark-plus-gt-jump.el bookmark-plus-gt-tags.el bookmark-plus-gt-auto-update.el bookmark-plus-gt.el

.PHONY: test compile clean

test:
	$(EMACS) -Q --batch \
	    -L $(PLUS_DIR) -L . -L test \
	    -l ert \
	    -l test/run-tests.el \
	    -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L $(PLUS_DIR) -L . \
	    -f batch-byte-compile $(CORE_FILES)

clean:
	rm -f *.elc test/*.elc
