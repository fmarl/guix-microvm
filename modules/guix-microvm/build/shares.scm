;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build shares)
  #:use-module (guix build syscalls)
  #:use-module (guix build utils)
  #:use-module ((ice-9 ftw) #:select (file-system-fold))
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build process)
  #:export (share
            share-tag
            share-directory
            share-options
            share-wrapper
            id-map-options
            vm-shares
            share-servers
            share-devices
            virtiofs-device
            mount-store-items
            entries-to-hide
            hide-git))

(define-record-type <share>
  (share tag directory options wrapper)
  share?
  (tag       share-tag)
  (directory share-directory)
  (options   share-options)
  (wrapper   share-wrapper))            ;command prefix of virtiofsd

(define (id-map-options guest-uid guest-gid host-uid host-gid)
  "Return virtiofsd options mapping GUEST-UID and GUEST-GID to HOST-UID and
HOST-GID in its user namespace."
  (list "--translate-uid" (format #f "map:~a:~a:1" guest-uid host-uid)
        "--translate-gid" (format #f "map:~a:~a:1" guest-gid host-gid)))

(define (overflow-id kind)
  "Return the ID of unmapped users or groups in a user namespace, KIND being
\"uid\" or \"gid\"."
  (call-with-input-file (string-append "/proc/sys/kernel/overflow" kind)
    read))

(define* (vm-shares #:key directory home store store-items stateless? uid gid
                    mount-store hide-git (git-entries '()))
  "Return the VM's shares: STORE-ITEMS at STORE, mounted by MOUNT-STORE, and
DIRECTORY and HOME, owned by UID and GID in the VM.  DIRECTORY is read-only
if STATELESS?, and HIDE-GIT hides its GIT-ENTRIES."
  (let ((owned (id-map-options uid gid 0 0)))
    (list
     ;; Store items belong to root, who is unmapped in the namespace.
     (share "store" store
            (cons "--readonly"
                  (id-map-options 0 0 (overflow-id "uid") (overflow-id "gid")))
            (list mount-store store-items store "--"))
     ;; A stateless VM overlays it with a tmpfs.
     (share "work" directory
            (if stateless? (cons "--readonly" owned) owned)
            (if (null? git-entries) '() `(,hide-git ,@git-entries "--")))
     (share "home" home owned '()))))

(define (share-socket directory share)
  (socket-file directory (share-tag share)))

;; virtiofsd runs as root of a user namespace in which the host user is root
;; and other users are nobody.
(define* (virtiofs-server share socket #:key unshare virtiofsd cache)
  "Return a virtiofsd server for SHARE at SOCKET."
  (server unshare
          `("--user" "--map-root-user" "--mount"
            ,@(share-wrapper share)
            ,virtiofsd "--shared-dir" ,(share-directory share)
            "--socket-path" ,socket
            "--sandbox" "namespace" "--log-level" "error" "--cache" ,cache
            ,@(share-options share))
          socket))

(define* (share-servers shares directory #:key unshare virtiofsd cache)
  (map (lambda (share)
         (virtiofs-server share (share-socket directory share)
                          #:unshare unshare #:virtiofsd virtiofsd
                          #:cache cache))
       shares))

(define (virtiofs-device share socket)
  "Return QEMU options for the virtio-fs device of SHARE at SOCKET."
  (let ((tag (share-tag share)))
    (list "-chardev" (string-append "socket,id=" tag ",path=" socket)
          "-device" (string-append "vhost-user-fs-device,chardev=" tag
                                   ",tag=" tag))))

(define (share-devices shares directory)
  (append-map (lambda (share)
                (virtiofs-device share (share-socket directory share)))
              shares))

(define (mount-store-items items root)
  "Bind-mount the store items listed in ITEMS on a tmpfs at ROOT.  Needs a
private mount namespace."
  (mount "none" root "tmpfs" 0 "mode=755")
  (for-each (lambda (item)
              (let ((target (string-append root "/" (basename item))))
                (if (file-is-directory? item)
                    (mkdir target)
                    (call-with-output-file target (const #t)))
                (mount item target "none" (logior MS_BIND MS_REC))))
            (string-tokenize (call-with-input-file items get-string-all))))

;; virtiofsd overrides permissions on the user's files, so it can read
;; directories that the user cannot.
(define (find-git-entries directory)
  "Return the .git entries in DIRECTORY and its subdirectories, not looking
into .git directories.  Fail on a directory of the user that cannot be
read."
  (define (git? file)
    (string=? (basename file) ".git"))

  (define (add-if-git file stat result)
    (if (git? file) (cons file result) result))

  (define (keep file stat result)
    result)

  (define (unreadable file stat errno result)
    (if (and stat (= (stat:uid stat) (getuid)))
        (fail "not sharing ~a, ~a cannot be read" directory file)
        result))

  (reverse
   (file-system-fold (lambda (file stat result) ;enter?
                       (not (git? file)))
                     add-if-git                  ;leaf
                     keep                        ;down
                     keep                        ;up
                     add-if-git                  ;skip
                     unreadable                  ;error
                     '()
                     directory
                     lstat)))

(define (entries-to-hide directory)
  "Return the .git entries of DIRECTORY for 'hide-git'.  Fail if one is a
symbolic link: 'hide-git' would mount over its target, and the VM could
replace the link."
  (let ((entries (find-git-entries directory)))
    (match (find symbolic-link? entries)
      (#f entries)
      (link (fail "not sharing ~a, ~a is a symbolic link" directory link)))))

;; The VM must not write Git hooks or configuration that the host would run.
;; A mount point cannot be removed or renamed.
(define (hide-git . entries)
  "Mount an empty read-only file system over each .git directory in ENTRIES
and make each .git file read-only.  Needs a private mount namespace."
  (let ((flags (logior MS_RDONLY MS_NOSUID MS_NODEV MS_NOEXEC)))
    (for-each (lambda (entry)
                (match (stat:type (lstat entry))
                  ('directory (mount "none" entry "tmpfs" flags "mode=555"))
                  ('regular
                   (mount entry entry "none" MS_BIND)
                   (mount entry entry "none"
                          (logior MS_BIND MS_REMOUNT flags)))))
              entries)))
