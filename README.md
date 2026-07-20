# guix-microvm
Run commands in throwaway Guix System VMs, one project at a time.  The VM
sees the project at `/work`, its own home and the packages of the
project's `manifest.scm`, nothing else of the host.

## Requirements
- x86_64 with `/dev/kvm` and `/dev/vhost-vsock` (modules `kvm_intel` or
  `kvm_amd`, and `vhost_vsock`)
- unprivileged user namespaces
- a Wayland session for graphical VMs

## Installation
Add the channel to `~/.config/guix/channels.scm` and run `guix pull`:

```scheme
(cons (channel
        (name 'guix-microvm)
        (url "https://codeberg.org/fmarl/guix-microvm")
        (branch "main"))
      %default-channels)
```

Or, from a checkout:

```
export GUILE_LOAD_PATH=$PWD/modules
guix time-machine -C channels-lock.scm -- microvm --help
```

## Usage
```
cd ~/src/project
guix microvm                            # login shell in /work
guix microvm -- make check              # run a command
guix microvm -p 3000 -- npm run dev     # forward localhost:3000
guix microvm --stateless -- make check  # keep no home, no changes to /work
guix microvm --vm=claude-vm -- claude   # Claude Code
guix microvm --vm=librewolf-vm          # LibreWolf on the host's display
```

`vm.scm` and `manifest.scm` are looked up in the current directory and its
parents, like with `guix shell`, and run on the host.  As the VM can change
them, `guix microvm` refuses new or changed ones until you review them and
allow them:

```
guix microvm --allow
```

### manifest.scm
The packages available in the VM:

```scheme
(specifications->manifest (list "node" "python"))
```

### vm.scm
The VM, if not the default one:

```scheme
(use-modules (guix-microvm vms claude))

(microvm
  (operating-system %claude-system)
  (memory-size 8192)
  (ports '(3000)))
```

Fields: `operating-system` (inheriting `%base-vm`), `command`, `wayland?`,
`stateless?`, `ports`, `secrets`, `memory-size`, `cpu-count`.

The system needs `microvm-guest-service-type`, part of
`%microvm-base-services`.  The launcher reads its configuration: `user`,
`uid`, `gid`, `ssh-port`, `network`, `name-server`.

```scheme
(modify-services %microvm-base-services
  (microvm-guest-service-type
   config => (microvm-guest-configuration
               (inherit config)
               (user "dev"))))
```

### Claude Code
Log in once for all projects:

```
guix microvm --vm=claude-vm -- claude setup-token
mkdir -p ~/.local/share/guix-microvm/claude/secrets
echo TOKEN > ~/.local/share/guix-microvm/claude/secrets/CLAUDE_CODE_OAUTH_TOKEN
```

## Files
- `~/.local/share/guix-microvm/NAME/PROJECT/`: the VM's home, per project
- `~/.local/share/guix-microvm/NAME/PROJECT.log`: its console output
- `~/.local/share/guix-microvm/NAME/secrets/`: variables in `secrets`

With `--stateless` or `(stateless? #t)`, the home, the log and the SSH key
live in `$XDG_RUNTIME_DIR` until the VM exits.  Changes to `/work` go to an
overlay in the VM's memory; don't change the project on the host meanwhile.

## Development
```
make check     # evaluate all VMs
make update    # update channels-lock.scm
```
