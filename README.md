# guix-microvm
Runs commands in a Guix System VM per project.  The VM sees the project at
`/work`, its own home and the packages of `manifest.scm`.

## Requirements
- x86_64 with `/dev/kvm` and `/dev/vhost-vsock`
- unprivileged user namespaces
- Landlock
- a Wayland session for graphical VMs

## Installation
```scheme
(cons (channel
        (name 'guix-microvm)
        (url "https://codeberg.org/fmarl/guix-microvm")
        (branch "main"))
      %default-channels)
```

From a checkout:

```
GUILE_LOAD_PATH=$PWD/modules guix time-machine -C channels-lock.scm -- microvm
```

## Usage
```
guix microvm                            # login shell in /work
guix microvm -- make check              # run a command
guix microvm -p 3000 -- npm run dev     # forward localhost:3000
guix microvm --stateless -- make check  # discard home and changes to /work
guix microvm --vm=claude-vm -- claude
guix microvm --vm=librewolf-vm
guix microvm --allow                    # allow new or changed project files
guix microvm list                       # running VMs
guix microvm stop vm
```

`vm.scm` and `manifest.scm` are searched in the current directory and its
parents.  They run on the host, so they must be allowed after every change.

```scheme
;; manifest.scm
(specifications->manifest (list "node" "python"))

;; vm.scm
(use-modules (guix-microvm vms claude))

(microvm
  (operating-system %claude-system)
  (memory-size 8192)
  (ports '(3000)))
```

`microvm` fields: `operating-system`, `command`, `wayland?`, `stateless?`,
`usb?`, `network?`, `ports`, `secrets`, `read-only-files`, `memory-size`,
`cpu-count`.  `.git`, `.envrc`, `.dir-locals.el`, `.dir-locals-2.el`,
`.vscode`, `.idea` and `read-only-files` are read-only in the VM.

The system needs `microvm-guest-service-type` from `%microvm-base-services`.
Its fields are `user`, `uid`, `gid`, `ssh-port`, `network` and
`name-server`.

### Claude Code
```
guix microvm --vm=claude-vm -- claude setup-token
mkdir -p ~/.local/share/guix-microvm/claude/secrets
echo TOKEN > ~/.local/share/guix-microvm/claude/secrets/CLAUDE_CODE_OAUTH_TOKEN
```

### USB
VMs with `usb?` can take a host device until it is detached or the VM
exits.  The device needs a udev rule that gives you access.

```
guix microvm usb attach librewolf 1050
guix microvm usb detach librewolf 1050
```

## Files
- `~/.local/share/guix-microvm/NAME/PROJECT/`: home
- `~/.local/share/guix-microvm/NAME/PROJECT.log`: console log
- `~/.local/share/guix-microvm/NAME/secrets/`: values of `secrets`

Stateless VMs keep home and log in `$XDG_RUNTIME_DIR` until they exit.

## Development
```
make check     # evaluate VMs, unit tests
make check-vm  # boot VMs
make update    # update channels-lock.scm
```
