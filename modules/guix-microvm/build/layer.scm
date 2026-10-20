;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build layer)
  #:use-module (guix build syscalls)
  #:use-module ((guix build utils) #:select (copy-recursively mkdir-p))
  #:use-module ((ice-9 hash-table) #:select (alist->hash-table))
  #:use-module (ice-9 match)
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-71)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build files)
  #:use-module (guix-microvm build process)
  #:export (layer?
            layer-directory
            layer-project
            layer-snapshot
            layer-lower
            layer-upper
            layer-merged
            layer-file
            upper-file
            layer-overlay-arguments
            create-layer!
            open-layer
            delete-layer!
            host-unchanged?
            base-type
            base-contents
            base-entries
            same-entry?
            host-file
            overlay-options
            mount-overlay!
            change?
            change-file
            change-kind
            change-type
            change-executable?
            layer-changes
            call-with-diff-trees))

(define-record-type <layer>
  (make-layer directory project snapshot manifest)
  layer?
  (directory layer-directory)
  (project   layer-project)
  (snapshot  layer-snapshot)            ;directory | #f
  (manifest  layer-manifest))           ;hash table | #f

(define (layer-file layer name)
  (file-in (layer-directory layer) name))

(define (layer-lower layer)
  (or (layer-snapshot layer) (layer-project layer)))

(define (layer-upper layer)
  (layer-file layer "upper"))

(define (layer-work layer)
  (layer-file layer "work"))

(define (layer-merged layer)
  (layer-file layer "merged"))

(define (upper-file layer file)
  (file-in (layer-upper layer) file))

(define (lower-file layer file)
  (file-in (layer-lower layer) file))

(define (host-file layer file)
  (file-in (layer-project layer) file))

(define (layer-overlay-arguments layer)
  (list (layer-lower layer) (layer-upper layer) (layer-work layer)
        (layer-merged layer)))

(define (snapshot directory base data cp)
  "Snapshot DIRECTORY at BASE with CP and return true, or warn and return
false."
  (call-with-temporary-file (dirname base)
    (lambda (errors)
      (or (zero? (wait-for-exit
                  (call-with-output-file errors
                    (lambda (port)
                      (spawn cp (list cp "-a" "--reflink=always" "--"
                                      directory base)
                             #:input (null-port) #:error port)))))
          (let ((program (%program-name))
                (error (match (string-split
                               (call-with-input-file errors get-string-all)
                               #\newline)
                         ((line . _) line))))
            (when (file-exists? base)
              (delete-tree base))
            (format (current-error-port)
                    "~a: warning: cannot snapshot ~a: ~a
~a: warning: a snapshot needs a copy-on-write file system, such as Btrfs, \
shared with ~a
~a: warning: the VM sees ~a change; do not change it while the VM runs~%"
                    program directory error program data program directory)
            #f)))))

;; overlayfs mounts without them, but then fails to remove directories that
;; held whiteouts.
(define (user-xattrs? directory)
  (catch 'system-error
    (lambda ()
      (setxattr directory "user.guix-microvm" "")
      #t)
    (lambda args
      (if (= ENOTSUP (system-error-errno args))
          #f
          (apply throw args)))))

(define (stat-key stat)
  (list (stat:type stat) (stat:perms stat) (stat:size stat) (stat:mtime stat)
        (stat:mtimensec stat) (stat:ino stat)))

(define (write-manifest directory file)
  (call-with-output-file file
    (cut write
         (map (match-lambda
                ((name . stat) (cons name (stat-key stat))))
              (tree-entries directory))
         <>)))

(define* (create-layer! data project #:key cp)
  "Create a layer over PROJECT in DATA and return it.  It stays until
'delete-layer!'."
  (let ((root (begin
                (mkdir-p (string-append data "/layers"))
                (mkdtemp (string-append data "/layers/XXXXXX")))))
    (with-exception-handler
        (lambda (error)
          (delete-tree root)
          (raise-exception error))
      (lambda ()
        (unless (user-xattrs? root)
          (fail "cannot keep layers in ~a, whose file system lacks user \
extended attributes; tmpfs needs CONFIG_TMPFS_XATTR" data))
        (for-each (compose mkdir (cut file-in root <>))
                  '("upper" "work" "merged"))
        (unless (snapshot project (file-in root "base") data cp)
          (write-manifest project (file-in root "manifest")))
        ;; Last, so that a half-created layer belongs to no project.
        (call-with-output-file (file-in root "project")
          (cut display project <>))
        (open-layer root))
      #:unwind? #t)))

(define (open-layer root)
  (let ((project (false-if-exception
                  (call-with-input-file (file-in root "project")
                    get-string-all)))
        (base (file-in root "base"))
        (manifest (file-in root "manifest")))
    (and project
         (make-layer root project
                     (and (file-exists? base) base)
                     (and (file-exists? manifest)
                          (alist->hash-table
                           (call-with-input-file manifest read)))))))

(define (delete-layer! layer)
  (delete-tree (layer-directory layer)))

(define (unchanged? file stat other other-stat)
  (and (eq? (stat:type stat) (stat:type other-stat))
       (= (stat:perms stat) (stat:perms other-stat))
       (case (stat:type stat)
         ((regular)
          (and (= (stat:size stat) (stat:size other-stat))
               (same-contents? file other)))
         ((symlink)
          (string=? (readlink file) (readlink other)))
         (else #f))))

(define (same-entry? file other)
  "Return true if FILE and OTHER are both missing, both directories, or the
same file."
  (let ((stat (file-stat file))
        (other-stat (file-stat other)))
    (cond ((not stat) (not other-stat))
          ((not other-stat) #f)
          ((eq? 'directory (stat:type stat))
           (eq? 'directory (stat:type other-stat)))
          (else (unchanged? file stat other other-stat)))))

(define (host-unchanged? layer file)
  (match (layer-manifest layer)
    (#f (same-entry? (host-file layer file) (lower-file layer file)))
    (manifest
     (let ((key (hash-ref manifest file))
           (stat (file-stat (host-file layer file))))
       (cond ((not key) (not stat))
             ((not stat) #f)
             ((eq? 'directory (first key))
              (eq? 'directory (stat:type stat)))
             (else (equal? key (stat-key stat))))))))

(define (base-type layer file)
  (match (layer-manifest layer)
    (#f (file-type (lower-file layer file)))
    (manifest (and=> (hash-ref manifest file) first))))

(define (base-perms layer file)
  (match (layer-manifest layer)
    (#f (and=> (file-stat (lower-file layer file)) stat:perms))
    (manifest (and=> (hash-ref manifest file) second))))

(define (base-contents layer file)
  "Return the file with the contents of FILE when LAYER started, or #f if
the layer has no snapshot."
  (and (layer-snapshot layer) (lower-file layer file)))

(define (base-entries layer file)
  "Return FILE and the files under it when LAYER started, children first."
  (match (layer-manifest layer)
    (#f
     (if (base-type layer file)
         (reverse (cons file
                        (map (compose (cut file-in file <>) car)
                             (tree-entries (lower-file layer file)))))
         '()))
    (manifest
     (sort (filter (cut contains-file? file <>)
                   (hash-map->list (lambda (name key) name) manifest))
           string>?))))

(define (escape-option value)
  (string-concatenate
   (map (lambda (char)
          (if (memv char '(#\\ #\, #\:))
              (string #\\ char)
              (string char)))
        (string->list value))))

(define (overlay-options lower upper work)
  (string-append "lowerdir=" (escape-option lower)
                 ",upperdir=" (escape-option upper)
                 ",workdir=" (escape-option work)
                 ;; Without privileges, overlayfs keeps its metadata in
                 ;; user.overlay.* attributes.
                 ",userxattr"))

(define (mount-overlay! lower upper work merged)
  (mount "overlay" merged "overlay" 0 (overlay-options lower upper work)))

(define-record-type <change>
  (make-change file kind type executable?)
  change?
  (file        change-file)
  (kind        change-kind)         ;of 'entry-kind', or 'unreadable
  (type        change-type)         ;in the VM, or before if deleted
  (executable? change-executable?)) ;made executable by the VM

(define (whiteout? stat)
  (and (eq? 'char-special (stat:type stat))
       (zero? (stat:rdev stat))))

(define (opaque? directory)
  ;; "x" marks directories that only hide entries of lower layers further
  ;; down, which this overlay does not have.
  (equal? "y" (false-if-exception
               (getxattr directory "user.overlay.opaque"))))

(define (shows-through? upper stat lower-stat)
  (and lower-stat
       (eq? 'directory (stat:type stat))
       (eq? 'directory (stat:type lower-stat))
       (not (opaque? upper))))

(define (entry-kind upper stat lower lower-stat)
  "Return the kind of change that UPPER, with STAT, makes to LOWER, with
LOWER-STAT, or #f."
  (cond ((whiteout? stat) (and lower-stat 'deleted))
        ((not lower-stat) 'added)
        ((shows-through? upper stat lower-stat)
         (and (not (= (stat:perms stat) (stat:perms lower-stat)))
              'modified))
        ((or (eq? 'directory (stat:type stat))
             (eq? 'directory (stat:type lower-stat)))
         'replaced)
        ;; Copying up, as 'touch' or 'chmod' to the same mode do, leaves the
        ;; file as it was.
        ((unchanged? upper stat lower lower-stat) #f)
        (else 'modified)))

(define (made-executable? layer file stat)
  (define (executable? perms)
    (and perms (not (zero? (logand #o111 perms)))))

  (and (eq? 'regular (stat:type stat))
       (executable? (stat:perms stat))
       (not (and (eq? 'regular (base-type layer file))
                 (executable? (base-perms layer file))))))

(define (layer-changes layer)
  "Return the changes that LAYER makes to its project, sorted by file.  A
directory that the host user cannot read is an 'unreadable change, without
the changes in it."
  (define (walk directory names lower? result)
    (fold (lambda (name result)
            (let* ((file (file-in directory name))
                   (upper (upper-file layer file))
                   (lower (lower-file layer file))
                   (stat (lstat upper))
                   (lower-stat (and lower? (file-stat lower)))
                   (children (and (eq? 'directory (stat:type stat))
                                  (or (directory-files upper) 'unreadable)))
                   (kind (if (eq? children 'unreadable)
                             'unreadable
                             (entry-kind upper stat lower lower-stat)))
                   (result (if kind
                               (cons (make-change
                                      file kind
                                      (stat:type (if (eq? kind 'deleted)
                                                     lower-stat
                                                     stat))
                                      (made-executable? layer file stat))
                                     result)
                               result)))
              (match children
                ((? list?)
                 (walk file children
                       (shows-through? upper stat lower-stat) result))
                (_ result))))
          result
          names))

  (match (directory-files (layer-upper layer))
    (#f (list (make-change "." 'unreadable 'directory #f)))
    (names
     (sort (walk "" names #t '())
           (lambda (change other)
             (string<? (change-file change) (change-file other)))))))

(define (copy-entry source target)
  (let ((stat (lstat source)))
    (mkdir-p (dirname target))
    (case (stat:type stat)
      ((directory) (mkdir-p target))
      ((symlink) (symlink (readlink source) target))
      ((regular)
       (copy-file source target)
       (chmod target (stat:perms stat)))
      (else #f))))

(define (copy-tree source target)
  (if (directory? source)
      (copy-recursively source target
                        #:log (%make-void-port "w")
                        #:keep-permissions? #t)
      (copy-entry source target)))

(define (call-with-diff-trees layer changes proc)
  "Call PROC with two directories holding the files of CHANGES before and
after the VM, and delete them when it returns."
  (let* ((root (mkdtemp (layer-file layer "diff-XXXXXX")))
         (before (file-in root "project"))
         (after (file-in root "vm")))
    (dynamic-wind
      (const #t)
      (lambda ()
        (mkdir before)
        (mkdir after)
        ;; A file that the VM left unreadable is missing from the trees.
        (for-each (lambda (change)
                    (let ((file (change-file change)))
                      (false-if-exception
                       (match (change-kind change)
                         ('added #t)
                         ((or 'deleted 'replaced)
                          (copy-tree (lower-file layer file)
                                     (file-in before file)))
                         ('modified
                          (copy-entry (lower-file layer file)
                                      (file-in before file)))))
                      (unless (eq? 'deleted (change-kind change))
                        (false-if-exception
                         (copy-entry (upper-file layer file)
                                     (file-in after file))))))
                  changes)
        (proc before after))
      (cut delete-tree root))))
