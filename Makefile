GUIX := guix time-machine -C $(CURDIR)/channels-lock.scm --
VMS := $(basename $(notdir $(wildcard modules/guix-vms/vms/*.scm)))

export GUILE_LOAD_PATH := $(CURDIR)/modules$(if $(GUILE_LOAD_PATH),:$(GUILE_LOAD_PATH))

.PHONY: check update

check:
	$(GUIX) build --dry-run \
	    $(foreach vm,$(VMS),-e '(@ (guix-vms vms $(vm)) $(vm)-vm)')
	$(GUIX) microvm --help >/dev/null

update:
	guix time-machine -C channels.scm -- \
	    describe -f channels > channels-lock.scm.new
	mv channels-lock.scm.new channels-lock.scm
