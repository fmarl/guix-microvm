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
            find-protected-entries
            read-only-files
            mount-read-only))

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

(define* (vm-shares #:key directory home store store-items host-key
                    stateless? uid gid mount-store mount-read-only
                    (read-only '()))
  (let ((owned (id-map-options uid gid 0 0)))
    (list
     ;; Store items belong to root, who is unmapped in the namespace.
     (share "store" store
            (cons "--readonly"
                  (id-map-options 0 0 (overflow-id "uid") (overflow-id "gid")))
            (list mount-store store-items host-key store "--"))
     ;; A stateless VM overlays it with a tmpfs.
     (share "work" directory
            (if stateless? (cons "--readonly" owned) owned)
            (if (null? read-only) '() `(,mount-read-only ,@read-only "--")))
     (share "home" home owned '()))))

(define (share-socket directory share)
  (socket-file directory (share-tag share)))

;; virtiofsd runs as root of a user namespace in which the host user is root
;; and other users are nobody.
(define* (virtiofs-server share socket #:key unshare virtiofsd cache)
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
  (let ((tag (share-tag share)))
    (list "-chardev" (string-append "socket,id=" tag ",path=" socket)
          "-device" (string-append "vhost-user-fs-device,chardev=" tag
                                   ",tag=" tag))))

(define (share-devices shares directory)
  (append-map (lambda (share)
                (virtiofs-device share (share-socket directory share)))
              shares))

;; Same as in (guix-microvm base).
(define %host-key-name ".guix-microvm-ssh-host-key")

(define (mount-store-items items host-key root)
  "Bind-mount the store items listed in ITEMS on a tmpfs at ROOT, and copy
HOST-KEY there.  Needs a private mount namespace."
  (mount "none" root "tmpfs" 0 "mode=755")
  (copy-file host-key (string-append root "/" %host-key-name))
  (for-each (lambda (item)
              (let ((target (string-append root "/" (basename item))))
                (if (file-is-directory? item)
                    (mkdir target)
                    (call-with-output-file target (const #t)))
                (mount item target "none" (logior MS_BIND MS_REC))))
            (string-tokenize (call-with-input-file items get-string-all))))

;; Tools on the host run code from them.
(define %protected-names
  '(".git" ".envrc" ".dir-locals.el" ".dir-locals-2.el" ".vscode" ".idea"))

;; virtiofsd overrides permissions on the user's files, so it can read
;; directories that the user cannot.
(define (find-protected-entries directory)
  "Return the %PROTECTED-NAMES entries in DIRECTORY and its subdirectories,
not looking into them.  Fail on a directory of the user that cannot be
read."
  (define (protected? file)
    (member (basename file) %protected-names))

  (define (add-if-protected file stat result)
    (if (protected? file) (cons file result) result))

  (define (keep file stat result)
    result)

  (define (unreadable file stat errno result)
    (if (and stat (= (stat:uid stat) (getuid)))
        (fail "not sharing ~a, ~a cannot be read" directory file)
        result))

  (reverse
   (file-system-fold (lambda (file stat result) ;enter?
                       (not (protected? file)))
                     add-if-protected            ;leaf
                     keep                        ;down
                     keep                        ;up
                     add-if-protected            ;skip
                     unreadable                  ;error
                     '()
                     directory
                     lstat)))

(define (read-only-files files)
  "Return the existing FILES.  Fail on symbolic links, which the VM could
redirect."
  (let ((files (delete-duplicates
                (filter (lambda (file)
                          (false-if-exception (lstat file)))
                        files))))
    (for-each (lambda (file)
                (unless (equal? (false-if-exception (canonicalize-path file))
                                file)
                  (fail "~a is a symbolic link or lies under one" file)))
              files)
    files))

;; A mount point cannot be removed or renamed.
(define (mount-read-only . files)
  "Bind-mount FILES read-only on themselves."
  (for-each (lambda (file)
              (mount file file "none" (logior MS_BIND MS_REC))
              (mount file file "none"
                     (logior MS_BIND MS_REMOUNT MS_RDONLY
                             MS_NOSUID MS_NODEV MS_NOEXEC)))
            files))
