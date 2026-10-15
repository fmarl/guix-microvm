# guix-microvm
Runs commands in a Guix System VM per project.  The VM sees the project at
`/work`, has its own home and gets the packages of `manifest.scm`.

Needs x86_64 with `/dev/kvm` and `/dev/vhost-vsock`, unprivileged user
namespaces and Landlock.

```scheme
(cons (channel
        (name 'guix-microvm)
        (url "https://github.com/fmarl/guix-microvm")
        (branch "main"))
      %default-channels)
```

## Usage
```
guix microvm                            # login shell in /work
guix microvm -- make check              # run a command
guix microvm -p 3000 -- npm run dev     # forward localhost:3000
guix microvm --stateless -- make check  # throw away home and changes
guix microvm --allow                    # trust new or changed project files
guix microvm --vm=NAME                  # run a predefined microvm
guix microvm list                       # running VMs
guix microvm stop NAME
```

Predefined microvms come from `(CHANNEL vms ...)` modules of any channel.

`vm.scm` and `manifest.scm` are looked up from the current directory upwards.
They run on the host, so every change has to be allowed again.

```scheme
;; vm.scm
(microvm
  (operating-system %base-vm)
  (memory-size 8192)
  (ports '(3000)))
```

`.git`, `.envrc`, `.dir-locals.el`, `.dir-locals-2.el`, `.vscode`, `.idea`
and the `read-only-files` of the `microvm` are read-only in the VM.  The
launcher warns about new ones when the VM exits.  Home, console log and
`secrets` live in `~/.local/share/guix-microvm/NAME/`.

`VM_MEMORY` and `VM_CPUS` override `memory-size` (MiB) and `cpu-count`,
`VM_BOOT_TIMEOUT` the 120 seconds to wait for SSH, `VM_FS_CACHE` virtiofsd's
`--cache` mode (`auto`) and `VM_SERIAL` sends the console to a QEMU `-serial`
instead of the log.

VMs with `usb?` can take a host device, which needs a udev rule giving you
access:

```
guix microvm usb attach librewolf 1050
guix microvm usb detach librewolf 1050
```

## Development
```
make check     # unit tests, lint
make check-vm  # boot VMs
```
