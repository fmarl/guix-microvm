#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

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
data=${XDG_DATA_HOME:-$HOME/.local/share}/guix-microvm
# The default VM's home for the project, named as by 'uri-encode'.
state=$data/vm/$(printf %s "$project" | sed 's|/|%2F|g')
trap 'rm -rf "$project" "$out" "$state"*' EXIT
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
                   microvm --allow --discard -- \
                   sh -c 'test "$(id -un):$(id -u):$HOME" = \
                                   dev:1001:/home/dev && exit 6')
}

wayland_socket() {
    mkdir wayland
    echo '(microvm (operating-system %base-vm) (wayland? #t))' > wayland/vm.scm
    (cd wayland &&
         status_is 5 with_environment XDG_CONFIG_HOME="$project/config" \
                   microvm --allow --stateless -- \
                   sh -c 'test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && exit 5')
}

# An emulated USB device stands in for one of the host.
usb_hotplug() {
    mkdir usb
    echo '(microvm (operating-system %base-vm) (usb? #t))' > usb/vm.scm
    (cd usb &&
         with_environment XDG_CONFIG_HOME="$project/config" \
                          microvm --allow --discard -- sh -c '
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

protected_files() {
    mkdir -p git/.git/hooks
    printf '[core]\n\tbare = false\n' > git/.git/config
    echo kept > git/.envrc
    (cd git &&
         status_is 7 microvm --merge -- sh -c '
           echo changed >> /work/.git/config &&
           touch /work/.git/hooks/pre-commit &&
           echo changed > /work/.envrc && exit 7') &&
        ! grep -q changed git/.git/config &&
        test -z "$(ls -A git/.git/hooks)" &&
        test "$(cat git/.envrc)" = kept
}

offline() {
    mkdir offline
    echo '(microvm (operating-system %base-vm) (network? #f))' \
         > offline/vm.scm
    (cd offline &&
         status_is 10 with_environment XDG_CONFIG_HOME="$project/config" \
                   microvm --allow --discard -- sh -c 'exit 10')
}

# Start microvm with ARGS in DIRECTORY, in the background, and wait until
# its command prints "up".
start_vm() {
    directory=$1
    shift
    (cd "$directory" && microvm "$@") </dev/null >"$out" 2>&1 &
    pid=$!
    wait_for_output up
}

kill_vm() {
    (cd "$1" && microvm kill vm)
    wait $pid
}

second_vm() {
    mkdir -p locked/sub
    start_vm locked --discard -- sh -c 'echo up; exec sleep 300'
    up=$?
    (cd locked/sub && status_is 1 microvm --discard -- true)
    refused=$?
    grep -q 'a VM runs on' "$out"
    reported=$?
    kill_vm locked
    [ $up -eq 0 ] && [ $refused -eq 0 ] && [ $reported -eq 0 ]
}

diff_shows_changes() {
    mkdir diffed
    echo old > diffed/file
    echo gone > diffed/gone
    start_vm diffed --discard -- sh -c '
      echo new > /work/file && rm /work/gone && echo added > /work/added &&
      echo up && exec sleep 300'
    up=$?
    (cd diffed && microvm diff) >diff.out 2>&1
    kill_vm diffed
    [ $up -eq 0 ] && grep -q '^+new' diff.out && grep -q '^-gone' diff.out &&
        grep -q '^+added' diff.out
}

shell_keeps_running() {
    mkdir shell
    (cd shell &&
         printf 'echo shell > /work/file; exit\n' |
             script -qfec "$guix microvm --merge" /dev/null) >"$out" 2>&1 &
    pid=$!
    i=0
    until grep -q 'the VM keeps running' "$out" || [ $i -ge 300 ]; do
        sleep 1
        i=$((i + 1))
    done
    attached=$(cd shell && echo 'cat file' | microvm attach vm 2>&1)
    kill_vm shell
    [ "$attached" = shell ] && [ "$(cat shell/file)" = shell ]
}

piped_shell_exits() {
    mkdir piped
    (cd piped && echo 'exit 5' | microvm --discard) >"$out" 2>&1
    [ $? -eq 5 ]
}

can_snapshot() {
    mkdir -p "$data" &&
        probe=$(mktemp "$data/probe.XXXXXX") &&
        echo probe > snapshot-probe &&
        cp --reflink=always snapshot-probe "$probe" 2>/dev/null
    status=$?
    rm -f snapshot-probe "${probe:-}"
    return $status
}

snapshot() {
    mkdir snapshot
    echo old > snapshot/file
    start_vm snapshot --discard -- sh -c 'echo up; sleep 5; cat /work/file' &&
        echo new > snapshot/file &&
        wait $pid &&
        grep -q '^old' "$out"
}

merges() {
    mkdir merging
    echo old > merging/file
    echo gone > merging/gone
    (cd merging &&
         status_is 0 microvm --merge -- sh -c '
           echo new > /work/file && rm /work/gone &&
           echo added > /work/added') &&
        test "$(cat merging/file)" = new &&
        test ! -e merging/gone &&
        test "$(cat merging/added)" = added
}

merge_conflict() {
    mkdir conflict
    echo start > conflict/file
    start_vm conflict --merge -- sh -c 'echo vm > /work/file && echo up &&
                                        sleep 5' &&
        echo host > conflict/file
    wait $pid
    status=$?
    grep -q 'conflict in file' "$out"
    reported=$?
    (cd conflict && status_is 1 microvm --discard -- true) &&
        grep -q 'previous VM' "$out"
    refused=$?
    # Discarded at the prompt, which needs a terminal.
    (cd conflict &&
         printf 'x\n' | script -qec "$guix microvm --discard -- true" \
                                /dev/null) >"$out" 2>&1
    discarded=$?
    [ $status -eq 1 ] && [ $reported -eq 0 ] && [ $refused -eq 0 ] &&
        [ $discarded -eq 0 ] && grep -q 'a previous VM made' "$out" &&
        test "$(cat conflict/file)" = host
}

volatile_field() {
    mkdir volatile
    echo '(microvm (operating-system %base-vm) (volatile? #t))' \
         > volatile/vm.scm
    (cd volatile &&
         status_is 12 with_environment XDG_CONFIG_HOME="$project/config" \
                   microvm --allow -- sh -c 'test -z "$(ls -A /work)" &&
                                             exit 12')
}

rename_directory() {
    mkdir -p renamed/dir/sub
    echo f > renamed/dir/sub/f
    (cd renamed &&
         status_is 0 microvm --merge -- sh -c '
           mv /work/dir /work/moved && test -e /work/moved/sub/f') &&
        test "$(cat renamed/moved/sub/f)" = f &&
        test ! -e renamed/dir
}

no_terminal() {
    status_is 1 microvm -- true &&
        grep -q 'without a terminal' "$out"
}

before=$(temporary_directories)

echo kept > kept
check "exit status" \
      status_is 3 microvm --discard -- sh -c '
        cat /work/kept && echo new > /work/new && rm /work/kept &&
        touch ~/marker && exit 3'
check "writes to /work stay out of the project" \
      test -e kept -a ! -e new
check "without a terminal, --merge or --discard is needed" no_terminal
check "--merge merges the changes" merges
check "--merge keeps conflicting changes" merge_conflict

check "stateless: exit status" \
      status_is 4 microvm --stateless -- sh -c '
        test -z "$(ls -A /work)" && echo new > /work/new &&
        test ! -e ~/marker && exit 4'
check "stateless: /work is empty and discarded" \
      test -e kept -a ! -e new
check "stateless and persistent: a fresh home, merged changes" \
      status_is 0 microvm --stateless --persistent --merge -- sh -c '
        test ! -e ~/marker && cat /work/kept && echo sp > /work/sp'
check "stateless and persistent: the changes are merged" \
      test "$(cat sp)" = sp
check "volatile? needs no terminal and has an empty /work" volatile_field
check "a directory of the snapshot can be renamed" rename_directory

check "boot failure exits" \
      status_is 1 with_environment VM_MEMORY=48 microvm --stateless -- true
check "boot failure shows the console" \
      grep -q 'Kernel panic' "$out"

check "SIGTERM stops the VM" sigterm_stops_vm
check "vm.scm: guest configuration" guest_configuration
check "USB: hotplug" usb_hotplug
check "protected files change only in the layer" protected_files
check "no network" offline
check "one VM per project" second_vm
check "diff shows the changes" diff_shows_changes
check "a shell's VM runs until it is killed, and can be attached" \
      shell_keeps_running
check "a shell without a terminal ends its VM" piped_shell_exits

if can_snapshot; then
    check "the VM sees a snapshot" snapshot
else
    echo "SKIP: the VM sees a snapshot (no copy-on-write file system)"
fi

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    check "Wayland: exit status" wayland_socket
else
    echo "SKIP: Wayland: exit status (no WAYLAND_DISPLAY)"
fi

check "temporary directories are deleted" \
      wait_for_temporary_directories "$before"
check "layers are deleted" \
      test -z "$(ls -A "$data/layers" 2>/dev/null)"

echo "$failures failed"
[ $failures -eq 0 ]
