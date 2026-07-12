# guix-microvm
A Guix channel to run commands in throwaway virtual machines, one project
at a time.  `guix microvm` boots a minimal Guix System VM that shares the
project directory and has the packages of the project's `manifest.scm`,
runs a command or a shell in it, then stops it.

```
cd ~/src/project
guix microvm                            # a login shell in the VM, in /work
guix microvm -- make check              # a command, its exit status is kept
guix microvm --vm=claude-vm -- claude   # a predefined VM, Claude Code
guix microvm -p 3000 -- npm run dev     # with localhost:3000 forwarded
guix microvm --vm=librewolf-vm          # a browser, in the host's Wayland session
```

The guest sees the project, its own home and the store items it needs, and
nothing else of the host, e.g. to let a coding agent work on a project.

The VM boots directly on a QEMU microvm with KVM: no firmware tables, no
PCI, no disk, only virtio-mmio devices and a minimal kernel.  Its root file
system is a tmpfs.  The project, the guest's home and the store are shared
over virtiofs, the network is user-mode, served by passt, and SSH runs over
vsock.  Everything runs as the host user, without root.

Tested on x86_64, where a run takes about three seconds from the launcher
to the command's exit.

## Requirements
- An x86_64 host with KVM: `/dev/kvm` readable and writable by the user,
  e.g. through the `kvm` group.  Without KVM, QEMU would keep running
  stale translated code for pages virtiofsd writes into guest memory, so
  there is no fallback to emulation.
- `/dev/vhost-vsock`, from the `vhost_vsock` kernel module, readable and
  writable by the user.
- Unprivileged user namespaces, for passt and the virtiofsd sandboxes.
- For VMs with `wayland?`, a Wayland session on the host.
- Guix.  Everything else (QEMU, virtiofsd, passt, OpenSSH, socat, Git,
  util-linux, waypipe) comes from the store.

## Installation
As a channel, in `~/.config/guix/channels.scm`, followed by `guix pull`:

```scheme
(cons (channel
        (name 'guix-microvm)
        (url "https://codeberg.org/fmarl/guix-microvm")
        (branch "main"))
      %default-channels)
```

`guix microvm` is then available everywhere.  The channel has no
introduction yet, so `guix pull` cannot authenticate its commits.  It is
tested with the Guix of `channels-lock.scm` only: it uses parts of Guix's
API that change from time to time.

From a checkout, with direnv, which puts `modules/` on `GUILE_LOAD_PATH`
(see `.envrc`), or by hand:

```
export GUILE_LOAD_PATH=$PWD/modules${GUILE_LOAD_PATH:+:$GUILE_LOAD_PATH}
guix time-machine -C channels-lock.scm -- microvm --help
```

## Projects
Like `guix shell`, `guix microvm` looks for `vm.scm` and `manifest.scm` in
the current directory and its parents.  The first directory with either
is the *project directory*, shared at `/work`.  Without one, the current
directory is shared.  The home directory and its parents are only shared
with `--share-home`: running `guix microvm` in `~` would otherwise give the
guest the whole home directory.

Both files are code that runs on the host, outside the VM, so they are
only loaded from directories listed, one absolute file name per line, in
`~/.config/guix/microvm-authorized-directories`:

```
echo ~/src/project >> ~/.config/guix/microvm-authorized-directories
```

Without that, `guix microvm` stops with a hint.  The list is distinct from
`guix shell`'s.

### manifest.scm
The project's packages, as for `guix shell`, e.g. compilers and tools:

```scheme
(specifications->manifest (list "node" "python" "rust"))
```

It is evaluated with `(guix profiles)` and `(gnu)` available and must
return a manifest.  It becomes a profile in the host's store, which the
guest loads on top of its system, for login shells and commands alike (the
prompt shows `[env]`).  Changing it rebuilds the profile and the launcher,
not the operating system.

### vm.scm
The project's VM, which must evaluate to a `microvm`, see [The microvm
record](#the-microvm-record).  `(guix-microvm microvm)`, `(guix-microvm
base)` and `(gnu)` are available.  A predefined operating system with more
resources:

```scheme
(use-modules (guix-microvm vms claude))

(microvm
  (operating-system %claude-system)
  (memory-size 8192)
  (cpu-count 8)
  (ports '(3000)))
```

Or an operating system of its own, which must inherit `%base-vm`:

```scheme
(use-service-modules databases)

(define %redis-system
  (operating-system
    (inherit %base-vm)
    (host-name "redis-test")
    (services (cons (service redis-service-type)
                    (operating-system-user-services %base-vm)))))

(microvm
  (operating-system %redis-system))
```

Without `vm.scm`, the VM runs `%base-vm`.  `--vm=NAME` runs a predefined VM
instead of either; `manifest.scm` still applies.

## The guix microvm command
```
guix microvm [OPTION]... [-- COMMAND...]
```

Builds the VM and the profile of the project, boots the VM, runs COMMAND,
or a login shell, in `/work`, then stops the VM.  COMMAND's arguments are
passed as they are, without a shell: use `sh -c '...'` for shell syntax.

| Option | |
|---|---|
| `--vm=NAME` | Run the predefined VM NAME, e.g. `claude-vm`, rather than `vm.scm` or `%base-vm`.  An unknown NAME lists the available ones. |
| `-p`, `--port=PORT[:GUEST-PORT]` | Forward TCP port PORT of the host's loopback to GUEST-PORT, by default PORT, in the guest.  Repeatable, added to the `microvm`'s `ports`. |
| `--share-home` | Share the project directory even if it is the home directory or one of its parents. |
| `-n`, `--dry-run` | Show what would be built, do not build or run anything. |
| `-h`, `--help` | Show the usage. |

The common build options of Guix are accepted too, e.g. `-L DIR`,
`--no-substitutes`, `--no-grafts` or `-K`; see `guix microvm --help`.

The exit status is COMMAND's.  It is 128 plus the signal number if the
launcher is killed, and 255 with "lost the connection to the VM" if the
guest could not report it.

## The microvm record
`(guix-microvm microvm)` provides the `microvm` record.  It is file-like: it
lowers to the VM's *launcher*, so it can be built with `guix build`,
installed with `guix home`, or used in a gexp.

| Field | Default | |
|---|---|---|
| `operating-system` | | The guest's `operating-system`, inheriting `%base-vm`.  Its host name names the VM. |
| `command` | `'()` | The command to run without one on the command line; a login shell if empty. |
| `wayland?` | `#f` | Whether Wayland clients in the guest show on the host's Wayland display, see [Wayland](#wayland). |
| `manifest` | `#f` | A manifest whose profile the guest loads.  `guix microvm` sets it from `manifest.scm`. |
| `ports` | `'()` | TCP ports to forward from the host's loopback: numbers, or `(HOST . GUEST)` pairs. |
| `secrets` | `'()` | Names of environment variables to pass to the guest, see [Secrets](#secrets). |
| `memory-size` | `4096` | Memory in MiB. |
| `cpu-count` | `4` | Virtual CPUs. |
| `qemu` | `qemu` | The QEMU package. |
| `virtiofsd` | `virtiofsd` | The virtiofsd package, from `(guix-microvm packages virtiofsd)`. |
| `passt` | `passt` | The passt package. |
| `waypipe` | `waypipe` | The waypipe package. |

The launcher, `run-NAME`, is what `guix microvm` runs:

```
run-NAME [--share-home] [DIR] [-- COMMAND...]
```

It shares DIR, by default the current directory, at `/work`, refusing the
home directory and its parents without `--share-home`, and runs
COMMAND as described above.  Built from a `microvm` with a manifest, it
loads that manifest's profile; the launcher refers to the profile, so it
keeps it from being garbage-collected.

## Operating systems
`(guix-microvm base)` provides `%base-vm`, the operating system all VMs
inherit.  A derived system should keep:

- `kernel`, `initrd-modules`, `firmware`, `bootloader` and `file-systems`:
  the VM boots `linux-microvm` directly, without bootloader or disk, and
  mounts the shares from tags the launcher serves.
- The services of `%base-vm`, through `(operating-system-user-services
  %base-vm)`: sshd over vsock, the network, the guest's host key and the
  loading of the profile.
- `users` and `groups`: the launcher maps `%vm-user`'s UID and GID to the
  host user's.

`%base-vm` has the locale `en_US.utf8`, the time zone `Europe/Berlin` and
`%base-packages`.  Packages for a project belong in its `manifest.scm`
rather than in the operating system, so changing them does not rebuild it.

It also exports:

| Variable | |
|---|---|
| `%vm-user` | `"user"`, the user commands run as, with UID `%vm-uid` and GID `%vm-gid`, both 1000. |
| `%vm-ssh-port` | 2222, the vsock port of sshd. |
| `%vm-network` | The guest's static network, see [Network](#network). |
| `%vm-name-server` | `"10.0.2.3"`, the address passt answers DNS queries on. |

`(guix-microvm kernel)` provides `linux-microvm`, linux-libre configured with
`make tinyconfig` and `modules/guix-microvm/kernel/microvm.config` merged on
top.

## Predefined VMs
`guix microvm --vm=NAME` finds NAME among the `microvm`s exported by the
modules under `guix-microvm/vms/` on the load path.

### claude-vm
Claude Code with Git, Make, ripgrep, curl, less, gzip and procps, from
`(guix-microvm vms claude)`, which also exports its operating system,
`%claude-system`.  Claude Code's configuration lives in the guest's home,
`~/.claude`, so it persists per project.  Non-essential traffic is
disabled and so is the auto-updater: Claude Code's version is that of the
`claude-code` package.

To log in once for all projects, create a long-lived token and keep it as
a secret:

```
guix microvm --vm=claude-vm -- claude setup-token
mkdir -p ~/.local/share/guix-microvm/claude/secrets
echo TOKEN > ~/.local/share/guix-microvm/claude/secrets/CLAUDE_CODE_OAUTH_TOKEN
chmod 600 ~/.local/share/guix-microvm/claude/secrets/CLAUDE_CODE_OAUTH_TOKEN
```

`ANTHROPIC_API_KEY` is passed the same way, for an API key.

### librewolf-vm
LibreWolf, shown in the host's Wayland session, from `(guix-microvm vms
librewolf)`, which also exports `%librewolf-system`.  Run it from the
directory downloads should go to; its profile persists per directory, so
directories can serve as separate identities:

```
mkdir -p ~/Downloads/browser && cd ~/Downloads/browser
guix microvm --vm=librewolf-vm
```

It renders in software, without GPU: browsing is smooth, video takes CPU.
The file dialogs show the guest's file system, so uploads come from
`/work`.  There is no audio.

## The guest
The guest sees only what it needs of the host:

| Path | Access | |
|---|---|---|
| `/work` | read-write | The project directory. |
| `/home` | read-write | `~/.local/share/guix-microvm/NAME/PROJECT`, NAME being the VM's host name and PROJECT the URI-encoded project directory.  The guest user's home, `/home/user`, with its caches and configuration, persists there, separately for each project and VM. |
| `/gnu/store` | read-only | Only the store items of the operating system and of the profile. |

Everything else is a tmpfs, lost when the VM stops.  There is no access to
the host's home, SSH agent or GPG agent.  In `/work` and `/home`, the
guest user owns what the host user owns, whatever the host user's UID, and
what the guest user creates belongs to the host user.

Commands run as `user`, who cannot become root: `user` is not in `wheel`,
and `su` refuses empty passwords, root's included.  There is no `guix` in the
guest: the store is read-only, so packages come from `manifest.scm`.

When the command exits, the launcher has the guest flush its writes to the
shares, then stops QEMU.  The guest does not shut down.  Serial console
output goes to `~/.local/share/guix-microvm/NAME/PROJECT.log`.

Commits made in the guest use the Git identity of the project directory
on the host, `git config user.name` and `user.email`; `GIT_AUTHOR_*` and
`GIT_COMMITTER_*` override it.

## Network
The guest has one NIC, served by passt on the host.  It reaches the
outside like an unprivileged process on the host would: passt turns its
traffic into sockets of the host user.  passt does not map the gateway to
the host's loopback, so services listening only there are out of reach.

The addresses are fixed, since the network exists only between the guest
and its own passt: each VM has its own, they cannot collide, and they do
not appear on the host's network.

| | |
|---|---|
| Guest | `10.0.2.15/24` on `eth0` |
| Gateway | `10.0.2.2`, mapped to nothing |
| DNS | `10.0.2.3`, forwarded by passt to the host's name server |
| IPv6 | Router advertisements from passt, if the host has IPv6 |

Destinations in `10.0.2.0/24` on the host's network are out of reach.

Ports forwarded with `-p` or `ports` listen on the host's `127.0.0.1` only,
for TCP.  Connections arrive on the guest's address, not its loopback, so
servers must listen on all addresses, e.g. `npm run dev -- --host` for
Vite.

## Wayland
With `wayland?`, Wayland clients in the guest show on the host's Wayland
display through waypipe: the launcher runs a waypipe client on the host,
the command runs under a waypipe server in the guest, and the SSH session
running the command forwards the client's socket to the guest.  Unlike a
vsock port, it is out of other guests' reach.  There is no GPU in the
guest, so clients render in software.
Clipboard and multiple windows work through the Wayland protocol.

The waypipe client creates a security context, with the application ID
`guix-microvm.NAME`, so that compositors supporting it, like niri, keep
privileged protocols from the guest.  Under niri, the guest sees no
protocol to capture the screen, read the clipboard in the background, list
other windows or inject input.  Compositors without security contexts
expose what they expose to any client.

## Secrets
A `microvm`'s `secrets` names environment variables.  For each, the
launcher reads the file of the same name in
`~/.local/share/guix-microvm/NAME/secrets`, if it exists, strips trailing
whitespace and passes its contents to the guest in the SSH environment,
not on a command line.  The files are shared by all projects of the VM.
Everything in the guest can read the variables.

## Environment variables
Read by the launcher:

| Variable | Default | |
|---|---|---|
| `VM_MEMORY` | `memory-size` | Memory in MiB. |
| `VM_CPUS` | `cpu-count` | Virtual CPUs. |
| `VM_BOOT_TIMEOUT` | `120` | Seconds to wait for SSH. |
| `VM_FS_CACHE` | `auto` | virtiofsd's `--cache` for the shares: `auto`, `always`, `never` or `metadata`. |
| `VM_SERIAL` | `file:LOG` | A QEMU chardev for the serial console, e.g. `stdio`. |
| `XDG_DATA_HOME` | `~/.local/share` | Where `guix-microvm/` lives. |
| `XDG_RUNTIME_DIR` | `/tmp` | Where the sockets of a run live. |
| `GIT_AUTHOR_*`, `GIT_COMMITTER_*` | project's Git identity | Passed to the guest. |
| `LANG`, `COLORTERM` | | Passed to the guest. |

## Files on the host
```
~/.config/guix/microvm-authorized-directories   projects to load files from
~/.local/share/guix-microvm/
  ssh/id_ed25519{,.pub}            the launcher's SSH key, created on first use
  NAME/secrets/VARIABLE            secrets of the VM NAME
  NAME/PROJECT/                    /home of the VM NAME for PROJECT
  NAME/PROJECT.log                 its serial console output
$XDG_RUNTIME_DIR/guix-microvm.XXXXXX/  sockets of a run, removed at its end
```

## How it works
At build time, a `microvm` lowers to its launcher, a Guile program with
the store file names of everything it needs:

- the operating system's kernel, initrd and kernel arguments;
- the profile of the manifest;
- a list of the store items of the operating system and of the profile,
  from their reference graphs;
- QEMU, virtiofsd, passt, waypipe, OpenSSH, socat, Git and util-linux's
  `unshare`.

The logic of the launcher is in `(guix-microvm build microvm)`.  When run, it:

1. checks the directory, `/dev/kvm` and `/dev/vhost-vsock`, and creates the
   SSH key and the home directory if needed;
2. reads the Git identity of the project and the secrets;
3. starts passt with the guest's network and the forwarded ports, and,
   with `wayland?`, a waypipe client on the host's Wayland display;
4. starts three virtiofsd, each with `--sandbox namespace` as root of a
   user namespace of its own, in which the host user is root:
   - `store`: in a mount namespace, the listed store items are bind-mounted
     on a tmpfs, and that is shared, read-only.  Root's files, which are
     nobody's in the namespace, are root's again in the guest;
   - `work` and `home`: shared read-write, the guest user mapped to the
     host user;
5. boots QEMU's `microvm` machine on the kernel and initrd, with the
   shares, the NIC and a vsock device whose address is the launcher's PID,
   unique among running VMs.  The kernel command line carries the public
   SSH key;
6. in the guest, Guix's initrd mounts the store share and boots the system:
   a service writes the key to `/etc/ssh/authorized_keys.d/user`, socat
   bridges vsock port 2222 to sshd, `/etc/profile.d` loads the profile;
7. polls SSH over vsock until the guest answers, then runs the command in
   `/work` with a terminal, under a waypipe server with `wayland?`,
   recording its exit status in the guest;
8. has the guest `sync`, reads the exit status, and stops QEMU, virtiofsd
   and passt, also on SIGINT, SIGTERM or SIGHUP.

`guix microvm`, `(guix extensions microvm)`, finds and loads `vm.scm` and
`manifest.scm`, builds the launcher, keeps it from being garbage-collected
while it runs, and runs it on the project directory.

## Security model
The VM is meant to contain what runs in it, e.g. a coding agent, with
KVM's hardware isolation.  From inside, it can:

- read and write the project, and its own home of that project;
- read the store items of its system and profile, but no others, e.g.
  configuration files of the host user with secrets in them;
- reach the Internet, as the host user, without restriction: what it can
  read, it can send away, the project included;
- read its secrets;
- with `wayland?`, show windows on the host's display and use the
  clipboard while focused, see [Wayland](#wayland).

It cannot reach the host's loopback, the homes of other projects, the
host's home, or SSH and GPG agents.  It cannot become root in the guest.

On the host, everything runs as the user: QEMU, passt and virtiofsd, which
are sandboxed in namespaces.  A flaw in QEMU, passt or virtiofsd could
still give the guest the host user's rights.

`vm.scm` and `manifest.scm` run on the host, hence their authorization.
Only the launcher has the SSH key, so the guest's sshd accepts any
environment variable it sends.

## Limitations
- IPv6 is untested: the test host had none.
- Guest users other than `user` and root cannot create files in `/work`
  and `/home`, e.g. a service's own user.
- Servers in the guest must listen on all addresses for forwarded ports;
  forwarding is TCP over IPv4 only, and only from host to guest.
- Each project has its own home: caches are not shared between projects,
  and Claude Code needs a login per project unless the token is set.
- Changing packages takes a new run, with an updated `manifest.scm`.
- x86_64 only.
- VMs with `wayland?` render in software and have no audio.

## Troubleshooting
| Message | |
|---|---|
| `/dev/kvm is not accessible` | Load `kvm_intel` or `kvm_amd`, and give the user access, e.g. through the `kvm` group. |
| `/dev/vhost-vsock is not accessible` | Load `vhost_vsock`. |
| `not loading files from ...` | Authorize the project directory, see [Projects](#projects). |
| `the VM exited, see ...` | The log shows why; `VM_SERIAL=stdio` shows it on the terminal. |
| `no SSH connection to the VM` | The guest did not boot in time: see the log, or raise `VM_BOOT_TIMEOUT`. |
| `no ..., the program serving it exited` | passt or virtiofsd failed, e.g. without unprivileged user namespaces. |
| `lost the connection to the VM` | The guest could not report the exit status, e.g. because it crashed. |
| `not sharing ..., which contains the home directory` | Run in the project directory, or pass `--share-home` to share the home directory. |
| `record ABI mismatch; recompilation needed` | Stale compiled modules from a checkout: remove `~/.cache/guile/ccache/*/PATH-OF-THE-CHECKOUT`. |

## Development
```
.guix-channel              the channel, with its modules in modules/
channels.scm               channels to pin, channels-lock.scm the pinned ones
manifest.scm, .envrc       the development environment
modules/guix-microvm/
  base.scm                 %base-vm and the guest's constants
  microvm.scm              the microvm record and its launcher
  build/microvm.scm        the launcher's logic, run on the host
  kernel.scm               linux-microvm
  kernel/microvm.config    its configuration fragment
  packages/                virtiofsd and its crates, claude-code
  vms/NAME.scm             predefined VMs
modules/guix/extensions/microvm.scm
                           guix microvm
```

The Makefile pins Guix to `channels-lock.scm`:

```
make check     # evaluate all predefined VMs and guix microvm
make update    # pin channels.scm's channels to their latest commits
```

To add a predefined VM, add `modules/guix-microvm/vms/NAME.scm`, a module
`(guix-microvm vms NAME)` exporting `NAME-vm`, a `microvm`, which `make check`
evaluates.

To change the kernel, edit `modules/guix-microvm/kernel/microvm.config`.  The
build fails if an option does not end up in the kernel's configuration,
which happens when one of its dependencies is missing; add those too.
Each change rebuilds the kernel.
