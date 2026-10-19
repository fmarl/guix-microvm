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

The VM works on a snapshot of the project.  When it exits, the launcher lists
its changes and asks to diff, merge, select or discard them; `--merge` and
`--discard` answer without asking, as a run without a terminal must.
Changes left by an earlier run are asked about first.

Changes to `.git` and to ignored files are never merged.  Those to `.envrc`,
`.dir-locals.el`, `.dir-locals-2.el`, `.vscode`, `.idea` and the
`protected-files` of the `microvm` are merged only when selected.  On a
conflict, `--merge` merges nothing; otherwise text gets conflict markers and
other files keep the host's version.

`[s]elect` opens the list of changes in `$VISUAL` or `$EDITOR`; lines deleted or
commented out are not merged.  With `emacs-guix-microvm` from this channel,
Emacs shows the list as a review: `t` merges or skips, `TAB` shows the diff
below, `RET` in a buffer and `a` all diffs, `C-c C-c` is done and `q` goes
back to the question.

The snapshot needs a copy-on-write file system, such as Btrfs, shared with
`~/.local/share`; otherwise the VM sees the project live.  Renaming a
directory of the snapshot fails with `EXDEV`; `mv` copies instead.  One VM at
a time runs on a project.

`--volatile`, `--stateless` and `(volatile? #t)` give the VM an empty `/work`
instead of the project; `--persistent` brings it back.

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
make check     # unit and Emacs tests, lint
make check-vm  # boot VMs
```
