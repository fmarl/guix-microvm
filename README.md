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
guix microvm                            # login shell in /work, VM stays
guix microvm -- make check              # run a command
guix microvm -p 3000 -- npm run dev     # forward localhost:3000
guix microvm --stateless -- make check  # fresh home, empty /work
guix microvm --volatile                 # empty /work, no project
guix microvm --merge -- make fmt        # merge the changes without asking
guix microvm diff                       # changes of the VM on the project
guix microvm --allow                    # trust new or changed project files
guix microvm --vm=NAME                  # run a predefined microvm
guix microvm list                       # running VMs, their IDs and state
guix microvm attach [NAME]              # another shell in it
guix microvm kill [--merge|--discard] [NAME]
guix microvm resolve [--merge|--discard]  # changes a killed VM left
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

A VM started for a login shell keeps running in the background after it
exits; `guix microvm` in the project, without options that only apply to a
new VM, attaches to it.  `kill` then asks about its changes, unless `--merge`
or `--discard`; without a terminal, they are kept for `resolve` or the next
run.  The output of the VM's helper programs goes to its log.

A VM is named `PROJECT-vm` after the directory of its project, or `NAME-vm`
with `--vm=NAME`, with `-2`, `-3` and so on if the name is taken; it is also
its host name.  `attach` and `kill` take a name or ID, or else
the VM of the current project.

`M-x guix-microvm-list` lists the running VMs: `RET` opens `/work` with TRAMP
(`/microvm:ID:/work/`), `s` a shell there, `d` marks one to kill, `u` unmarks
it, `x` kills the marked ones and `D` the one at point.  `M-x
guix-microvm-resolve` resolves the changes left on a project.

The snapshot needs a copy-on-write file system, such as Btrfs, shared with
`~/.local/share`; otherwise the VM sees the project live.  Renaming a
directory of the snapshot fails with `EXDEV`; `mv` copies instead.  One VM at
a time runs on a project.

`--volatile`, `--stateless` and `(volatile? #t)` give the VM an empty `/work`
instead of the project; `--persistent` brings it back.

Home, console log and `secrets` live in `~/.local/share/guix-microvm/HOST/`,
after the `host-name` of the VM's operating system, `vm` for the base VM.

`VM_MEMORY` and `VM_CPUS` override `memory-size` (MiB) and `cpu-count`,
`VM_BOOT_TIMEOUT` the 120 seconds to wait for SSH, `VM_FS_CACHE` virtiofsd's
`--cache` mode (`auto`) and `VM_SERIAL` sends the console to a QEMU `-serial`
instead of the log.

VMs with `wayland?` show their windows on the host's Wayland session, which
hides screen capture, virtual input and clipboard managers from them if it
supports the security context protocol.  They see the clipboard while one of
their windows has focus.

VMs with `usb?` can take a host device, which needs a udev rule giving you
access:

```
guix microvm usb attach NAME 1050
guix microvm usb detach NAME 1050
```

## Development
```
make check     # unit and Emacs tests, lint
make check-vm  # boot VMs
```
