# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

GUIX := guix time-machine -C $(CURDIR)/channels-lock.scm --
VMS := $(basename $(notdir $(wildcard modules/guix-microvm/vms/*.scm)))
PACKAGES := $(filter-out rust-crates,\
    $(basename $(notdir $(wildcard modules/guix-microvm/packages/*.scm))))

export GUILE_LOAD_PATH := $(CURDIR)/modules$(if $(GUILE_LOAD_PATH),:$(GUILE_LOAD_PATH))

.PHONY: check check-vm lint update

check:
	$(GUIX) build --dry-run \
	    $(foreach vm,$(VMS),-e '(@ (guix-microvm vms $(vm)) $(vm)-vm)')
	$(GUIX) microvm --help >/dev/null
	$(GUIX) repl -- tests/unit.scm
	$(MAKE) lint

# 'guix lint' and 'guix style' exit with 0 on findings, hence the grep.
lint:
	! $(GUIX) lint -L $(CURDIR)/modules --no-network $(PACKAGES) 2>&1 \
	    | grep -v '^;;;' | grep .
	! $(GUIX) style -L $(CURDIR)/modules --dry-run $(PACKAGES) 2>&1 \
	    | grep -v '^;;;' | grep .

check-vm:
	tests/vm.sh $(GUIX)

update:
	guix time-machine -C channels.scm -- \
	    describe -f channels > channels-lock.scm.new
	mv channels-lock.scm.new channels-lock.scm
