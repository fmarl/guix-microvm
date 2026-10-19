# guix-microvm
Runs commands in a Guix System VM per project.  The VM sees the project at
`/work`, has its own home and gets the packages of `manifest.scm`.

Needs x86_64 with `/dev/kvm` and `/dev/vhost-vsock`, unprivileged user
namespaces and Landlock, and user extended attributes on the file system of
`~/.local/share`; tmpfs has them with `CONFIG_TMPFS_XATTR`.

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
guix microvm --stateless -- make check  # fresh home, empty /work
guix microvm --volatile                 # empty /work, no project
guix microvm --merge -- make fmt        # merge the changes without asking
guix microvm diff                       # changes of the running VM
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

The VM sees a snapshot of the project, so it misses what you change on the
host while it runs, and changes it in a layer.  When it exits, the launcher
lists the changes and lets you diff, merge, select or discard them;
`--merge` and `--discard` decide without asking, as needed without a
terminal.  Changes to `.git` and files that `.gitignore` ignores are never
merged, nor are those to `.envrc`, `.dir-locals.el`, `.dir-locals-2.el`,
`.vscode`, `.idea` and the `protected-files` of the `microvm` unless you
select them.  On a conflict, `--merge` merges nothing and keeps the changes
for the next run; otherwise conflicting text gets conflict markers and other
files keep the host's version.  One VM at a time runs on a project.

The snapshot needs a copy-on-write file system, such as Btrfs, shared with
`~/.local/share`; elsewhere the VM sees the project as it changes.  Renaming
a directory of the snapshot fails with `EXDEV`, which `mv` handles by
copying.

Volatile VMs, with `--volatile`, `--stateless` or `(volatile? #t)`, get an
empty `/work` instead of the project; `--persistent` gives them the project.
Home, console log and `secrets` live in `~/.local/share/guix-microvm/NAME/`.

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
