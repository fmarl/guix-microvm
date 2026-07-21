#!/bin/sh
# Boot VMs and test the launcher.
# Needs /dev/kvm and /dev/vhost-vsock; the Wayland test, a Wayland session.
#
# Usage: tests/vm.sh GUIX-COMMAND...

set -u

# GUIX-COMMAND, quoted for 'eval'.
guix=
for argument in "$@"; do
    guix="$guix '$(printf %s "$argument" | sed "s/'/'\\\\''/g")'"
done

microvm() { eval "$guix microvm \"\$@\""; }
repl() { eval "$guix repl \"\$@\""; }

failures=0
project=$(mktemp -d "${TMPDIR:-/tmp}/guix-microvm-test.XXXXXX")
out=$project.out
runtime=${XDG_RUNTIME_DIR:-/tmp}
# The default VM's home for the project, named as by 'uri-encode'.
state=${XDG_DATA_HOME:-$HOME/.local/share}/guix-microvm/vm/$(
    printf %s "$project" | sed 's|/|%2F|g')
trap 'rm -rf "$project" "$out" "$state" "$state.log" \
            "$state%2Fcustom" "$state%2Fcustom.log" \
            "$state%2Fusb" "$state%2Fusb.log"' EXIT
cd "$project" || exit 1

check() {
    name=$1
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        tail -20 "$out" | sed 's/^/  /'
        failures=$((failures + 1))
    fi
}

status_is() {
    expected=$1
    shift
    "$@" </dev/null >"$out" 2>&1
    [ $? -eq "$expected" ]
}

with_environment() {
    (export "$1" && shift && "$@")
}

wait_for_output() {
    i=0
    until grep -q "^$1" "$out" || [ $i -ge 300 ]; do
        sleep 1
        i=$((i + 1))
    done
    grep -q "^$1" "$out"
}

temporary_directories() {
    ls -d "$runtime"/guix-microvm.* 2>/dev/null | sort
}

wait_for_temporary_directories() {
    i=0
    while [ "$(temporary_directories)" != "$1" ]; do
        [ $i -lt 10 ] || return 1
        sleep 1
        i=$((i + 1))
    done
}

# As a terminal sends SIGINT or SIGHUP: to the whole process group.
sigterm_stops_vm() {
    setsid sh -c "$guix microvm --stateless -- \
                  sh -c 'echo up; exec sleep 300'" </dev/null >"$out" 2>&1 &
    pid=$!
    wait_for_output up
    up=$?
    kill -TERM -- -$pid
    wait $pid
    [ $? -ne 0 ] && [ $up -eq 0 ]
}

# The launcher takes the user and SSH port from the guest's configuration.
guest_configuration() {
    mkdir custom
    cat > custom/vm.scm <<'EOF'
(microvm
  (operating-system
    (operating-system
      (inherit %base-vm)
      (services
       (modify-services %microvm-base-services
         (microvm-guest-service-type
          config => (microvm-guest-configuration
                      (inherit config)
                      (user "dev")
                      (uid 1001)
                      (gid 1001)
                      (ssh-port 2223))))))))
EOF
    (cd custom &&
         status_is 6 with_environment XDG_CONFIG_HOME="$project/config" \
                   microvm --allow -- \
                   sh -c 'test "$(id -un):$(id -u):$HOME" = \
                                   dev:1001:/home/dev && exit 6')
}

# An emulated USB device stands in for one of the host.
usb_hotplug() {
    mkdir usb
    echo '(microvm (operating-system %base-vm) (usb? #t))' > usb/vm.scm
    (cd usb &&
         with_environment XDG_CONFIG_HOME="$project/config" \
                          microvm --allow -- sh -c '
           devices() {
             ls /sys/bus/usb/devices | grep -cE "^[0-9]+-[0-9.]+$"
           }
           wait_for() {
             i=0
             until [ "$(devices)" "$1" 0 ]; do
               [ $i -lt 60 ] || exit 1
               sleep 1
               i=$((i + 1))
             done
           }
           echo up
           wait_for -gt
           echo attached
           wait_for -eq
           exit 9' </dev/null >"$out" 2>&1) &
    pid=$!
    wait_for_output up &&
        repl -- /dev/stdin >>"$out" 2>&1 <<'EOF'
(use-modules (guix-microvm control) (srfi srfi-1))

(call-with-qmp (running-vm-qmp-socket
                (find (lambda (vm)
                        (string=? (running-vm-directory vm)
                                  (canonicalize-path "usb")))
                      (running-vms)))
  (lambda (execute)
    (execute "device_add" '(("driver" . "usb-kbd") ("id" . "kbd")))
    (sleep 3)
    (execute "device_del" '(("id" . "kbd")))))
EOF
    wait $pid
    [ $? -eq 9 ] && grep -q '^attached' "$out"
}

before=$(temporary_directories)

check "exit status" \
      status_is 3 microvm -- \
                sh -c 'echo kept > /work/kept; touch ~/marker; exit 3'
check "writes to /work are kept" \
      test "$(cat kept)" = kept

check "stateless: exit status" \
      status_is 4 microvm --stateless -- sh -c '
        cat /work/kept && echo new > /work/new && rm /work/kept &&
        test ! -e ~/marker && exit 4'
check "stateless: writes to /work are discarded" \
      test -e kept -a ! -e new

check "boot failure exits" \
      status_is 1 with_environment VM_MEMORY=48 microvm --stateless -- true
check "boot failure shows the console" \
      grep -q 'Kernel panic' "$out"

check "SIGTERM stops the VM" sigterm_stops_vm
check "vm.scm: guest configuration" guest_configuration
check "USB: hotplug" usb_hotplug

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    check "Wayland: exit status" \
          status_is 5 microvm --vm=librewolf-vm --stateless -- \
          sh -c 'test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && exit 5'
else
    echo "SKIP: Wayland: exit status (no WAYLAND_DISPLAY)"
fi

check "temporary directories are deleted" \
      wait_for_temporary_directories "$before"

echo "$failures failed"
[ $failures -eq 0 ]
