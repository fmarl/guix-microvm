# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

GUIX := guix time-machine -C $(CURDIR)/channels-lock.scm --
PACKAGES := -e '(@ (guix-microvm packages virtiofsd) virtiofsd)' \
    -e '(@ (guix-microvm packages emacs) emacs-guix-microvm)'
LOCKED := -e '(@ (guix-microvm locked) qemu-locked)' \
    -e '(@ (guix-microvm locked) waypipe-locked)'

export GUILE_LOAD_PATH := $(CURDIR)/modules$(if $(GUILE_LOAD_PATH),:$(GUILE_LOAD_PATH))

.PHONY: check check-vm lint update

check:
	$(GUIX) build -L $(CURDIR)/modules $(LOCKED)
	$(GUIX) microvm --help >/dev/null
	$(GUIX) repl -- tests/unit.scm
	$(GUIX) shell emacs-minimal diffutils -- emacs -Q --batch -L emacs \
	    -L tests -l guix-microvm-test -f ert-run-tests-batch-and-exit
	$(MAKE) lint

lint:
	! $(GUIX) lint -L $(CURDIR)/modules --no-network $(PACKAGES) $(LOCKED) \
	    2>&1 | grep -v '^;;;' | grep .
	! $(GUIX) style -L $(CURDIR)/modules --dry-run $(PACKAGES) 2>&1 \
	    | grep -v '^;;;' | grep .

check-vm:
	tests/vm.sh $(GUIX)

update:
	guix time-machine -C channels.scm -- \
	    describe -f channels > channels-lock.scm.new
	mv channels-lock.scm.new channels-lock.scm
