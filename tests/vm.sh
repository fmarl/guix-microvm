#!/bin/sh
# Boot VMs and test the launcher.
# Needs /dev/kvm and /dev/vhost-vsock; the Wayland test, a Wayland session.
#
# Usage: tests/vm.sh GUIX-MICROVM-COMMAND...

set -u

failures=0
project=$(mktemp -d "${TMPDIR:-/tmp}/guix-microvm-test.XXXXXX")
out=$project.out
runtime=${XDG_RUNTIME_DIR:-/tmp}
# The default VM's home for the project, named as by 'uri-encode'.
state=${XDG_DATA_HOME:-$HOME/.local/share}/guix-microvm/vm/$(
    printf %s "$project" | sed 's|/|%2F|g')
trap 'rm -rf "$project" "$out" "$state" "$state.log" \
            "$state%2Fcustom" "$state%2Fcustom.log"' EXIT
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

before=$(temporary_directories)

check "exit status" \
      status_is 3 "$@" -- sh -c 'echo kept > /work/kept; touch ~/marker; exit 3'
check "writes to /work are kept" \
      test "$(cat kept)" = kept

check "stateless: exit status" \
      status_is 4 "$@" --stateless -- sh -c '
        cat /work/kept && echo new > /work/new && rm /work/kept &&
        test ! -e ~/marker && exit 4'
check "stateless: writes to /work are discarded" \
      test -e kept -a ! -e new

check "boot failure exits" \
      status_is 1 env VM_MEMORY=48 "$@" --stateless -- true
check "boot failure shows the console" \
      grep -q 'Kernel panic' "$out"

# As a terminal sends SIGINT or SIGHUP: to the whole process group.
check "SIGTERM stops the VM" sh -c '
  out=$1
  shift
  setsid "$@" --stateless -- sh -c "echo up; exec sleep 300" \
    </dev/null >"$out" 2>&1 &
  pid=$!
  i=0
  until grep -q "^up" "$out" || [ $i -ge 300 ]; do
    sleep 1
    i=$((i + 1))
  done
  up=$(grep -c "^up" "$out")
  kill -TERM -- -$pid
  wait $pid
  [ $? -ne 0 ] && [ "$up" -gt 0 ]' sh "$out" "$@"

# The launcher takes the user and SSH port from the guest's configuration.
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
check "vm.scm: guest configuration" sh -c '
  out=$1
  shift
  cd custom &&
  XDG_CONFIG_HOME=$PWD/../config "$@" --allow -- sh -c "
    test \"\$(id -un):\$(id -u):\$HOME\" = dev:1001:/home/dev && exit 6" \
    </dev/null >"$out" 2>&1
  [ $? -eq 6 ]' sh "$out" "$@"

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    check "Wayland: exit status" \
          status_is 5 "$@" --vm=librewolf-vm --stateless -- \
          sh -c 'test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && exit 5'
else
    echo "SKIP: Wayland: exit status (no WAYLAND_DISPLAY)"
fi

check "temporary directories are deleted" \
      wait_for_temporary_directories "$before"

echo "$failures failed"
[ $failures -eq 0 ]
