;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build merge)
  #:use-module ((ice-9 binary-ports) #:select (get-bytevector-n))
  #:use-module ((ice-9 exceptions)
                #:select (define-exception-type exception-kind exception-args))
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module ((rnrs bytevectors) #:select (bytevector->u8-list))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-71)
  #:use-module (guix-microvm build files)
  #:use-module (guix-microvm build git)
  #:use-module (guix-microvm build layer)
  #:export (git-file?
            git-hook-or-config?
            protected?
            classify-changes
            problem?
            problem-file
            problem-reason
            problem-detail
            plan-merge
            plan-problems
            apply-plan
            forget-merged))

(define %protected-names
  '(".envrc" ".dir-locals.el" ".dir-locals-2.el" ".vscode" ".idea"))

(define (git-file? file)
  (member ".git" (string-split file #\/)))

(define (git-hook-or-config? file)
  (string-match "(^|/)\\.git/(hooks/.|config$)" file))

;; Tools on the host run code from them.
(define (protected? file protected-files)
  (or (any (cut member <> %protected-names) (string-split file #\/))
      (any (cut contains-file? <> file) protected-files)))

;; The VM could forge lines of the selection list or send escape sequences
;; to the terminal.
(define (unprintable? file)
  (string-any (lambda (char)
                (or (char<? char #\space) (char=? char #\delete)))
              file))

(define (ignored-changes git layer changes)
  (let ((ignored (map (cut string-trim-right <> #\/)
                      (git-check-ignore
                       git (layer-project layer)
                       (map (lambda (change)
                              (if (eq? 'directory (change-type change))
                                  (string-append (change-file change) "/")
                                  (change-file change)))
                            changes)
                       (layer-directory layer)))))
    (filter (compose (cut member <> ignored) change-file) changes)))

(define* (classify-changes layer #:key git (protected-files '()))
  "Return the changes of LAYER as an alist of groups: 'mergeable,
'protected, 'git, 'ignored, 'unprintable and 'unreadable."
  (let* ((unreadable rest (partition (lambda (change)
                                       (eq? 'unreadable (change-kind change)))
                                     (layer-changes layer)))
         (unprintable rest (partition (compose unprintable? change-file)
                                      rest))
         (git-changes rest (partition (compose git-file? change-file) rest))
         ;; Before ignored files, which often include .envrc.
         (protected rest (partition (compose (cut protected? <> protected-files)
                                             change-file)
                                    rest))
         (ignored (ignored-changes git layer rest))
         (mergeable (lset-difference eq? rest ignored)))
    `((mergeable . ,mergeable)
      (protected . ,protected)
      (git . ,git-changes)
      (ignored . ,ignored)
      (unprintable . ,unprintable)
      (unreadable . ,unreadable))))

;; Actions are lists: (install FILE), (merge FILE OUTPUT CONFLICTS),
;; (chmod FILE PERMS), (delete FILE) and (conflict FILE REASON).
(define (action-file action)
  (second action))

(define-record-type <problem>
  (make-problem file reason detail)
  problem?
  (file   problem-file)
  (reason problem-reason)               ;symbol
  (detail problem-detail))              ;string | #f

(define (text-file? file)
  (and (eq? 'regular (file-type file))
       (call-with-input-file file
         (lambda (port)
           (match (get-bytevector-n port 8000)
             ((? eof-object?) #t)
             (bytes (not (memv 0 (bytevector->u8-list bytes))))))
         #:binary #t)))

(define (host-state layer file)
  "Return how the host has FILE compared with LAYER: 'missing, 'unchanged
since LAYER started, 'same as in the VM, or 'changed."
  (let ((host (host-file layer file)))
    (cond ((not (file-stat host)) 'missing)
          ((host-unchanged? layer file) 'unchanged)
          ((same-entry? host (upper-file layer file)) 'same)
          (else 'changed))))

(define* (plan-merge layer changes #:key git directory (protected-files '()))
  "Return the actions that merge CHANGES of LAYER into its project.  Run
'git merge-file' for the files changed on both sides, keeping the results
in DIRECTORY."
  (define empty
    (delay (let ((file (file-in directory "empty")))
             (call-with-output-file file (const #t))
             file)))

  (define (three-way file base)
    (let ((host (host-file layer file))
          (vm (upper-file layer file)))
      (if (and base (every text-file? (list host base vm)))
          (let ((output (temporary-file directory)))
            `((merge ,file ,output ,(git-merge-file git host base vm output))))
          `((conflict ,file changed-on-both)))))

  (define (deletions file)
    (filter-map (lambda (entry)
                  (cond ((git-file? entry) #f)
                        ((and (not (string=? entry file))
                              (protected? entry protected-files))
                         `(conflict ,entry protected))
                        (else
                         (match (host-state layer entry)
                           ('missing #f)
                           ('unchanged `(delete ,entry))
                           (_ `(conflict ,entry changed-on-host))))))
                (base-entries layer file)))

  (define (change-actions change)
    (let ((file (change-file change))
          (directory? (eq? 'directory (change-type change))))
      (match (list (change-kind change) (host-state layer file))
        (('added 'missing) `((install ,file)))
        (('added 'same) '())
        (('added _) (three-way file (force empty)))
        (('modified 'missing) `((conflict ,file deleted-on-host)))
        (('modified 'unchanged)
         (if directory?
             `((chmod ,file ,(stat:perms (lstat (upper-file layer file)))))
             `((install ,file))))
        (('modified 'same) '())
        (('modified 'changed)
         (if directory?
             '()
             (three-way file (base-contents layer file))))
        (('deleted _) (deletions file))
        (('replaced _) (append (deletions file) `((install ,file)))))))

  (append-map change-actions changes))

(define (plan-problems plan)
  (filter-map (match-lambda
                (('conflict file reason) (make-problem file reason #f))
                (('merge file _ (? positive?))
                 (make-problem file 'conflict-markers #f))
                (_ #f))
              plan))

(define-exception-type &merge-refusal &error
  make-merge-refusal merge-refusal?
  (reason merge-refusal-reason)
  (detail merge-refusal-detail))

(define* (refuse reason #:optional detail)
  (raise-exception (make-merge-refusal reason detail)))

;; A symbolic link that the host has in the project could lead the merge
;; out of it.
(define (check-parents project file)
  (let loop ((parent project)
             (parts (drop-right (string-split file #\/) 1)))
    (match parts
      (() #t)
      ((part rest ...)
       (let ((directory (file-in parent part)))
         (match (file-type directory)
           ('directory (loop directory rest))
           (#f (refuse 'missing-parent directory))
           (_ (refuse 'not-a-directory directory))))))))

(define (replace-file project file write)
  (let* ((target (file-in project file))
         (temporary (temporary-file (dirname target))))
    (with-exception-handler
        (lambda (error)
          (false-if-exception (delete-file temporary))
          (raise-exception error))
      (lambda ()
        (write temporary)
        (rename-file temporary target))
      #:unwind? #t)))

(define* (install source project file #:optional perms)
  "Install SOURCE as FILE in PROJECT with PERMS, or the permissions of
SOURCE.  A directory stays writable until 'restore-permissions'."
  (check-parents project file)
  (let ((stat (lstat source))
        (target (file-in project file)))
    (match (stat:type stat)
      ('directory
       (match (file-type target)
         ('directory (chmod target #o700))
         (#f (mkdir target #o700))
         (_ (refuse 'file-in-the-way))))
      ((and type (or 'regular 'symlink))
       (when (directory? target)
         (refuse 'directory-in-the-way))
       (replace-file project file
                     (lambda (temporary)
                       (if (eq? 'symlink type)
                           (begin
                             (delete-file temporary)
                             (symlink (readlink source) temporary))
                           (begin
                             (copy-file source temporary)
                             (chmod temporary
                                    (or perms (stat:perms stat))))))))
      (_ (refuse 'special-file)))))

(define (remove-entry project file)
  (check-parents project file)
  (let ((target (file-in project file)))
    (match (file-type target)
      (#f #t)
      ('directory
       (catch 'system-error
         (lambda () (rmdir target))
         (lambda args
           (if (= ENOTEMPTY (system-error-errno args))
               (refuse 'not-empty)
               (apply throw args)))))
      (_ (delete-file target)))))

;; Directories get their permissions last, so that read-only ones can still
;; receive their files.
(define (restore-permissions layer actions)
  (for-each (match-lambda
              ((file . perms)
               (chmod (file-in (layer-project layer) file) perms)))
            (reverse
             (filter-map (match-lambda
                           (('chmod file perms) (cons file perms))
                           (('install file)
                            (let ((stat (lstat (upper-file layer file))))
                              (and (eq? 'directory (stat:type stat))
                                   (cons file (stat:perms stat)))))
                           (_ #f))
                         actions))))

(define (apply-plan layer plan)
  "Apply PLAN to the project of LAYER and return the problems of the files
it could not change."
  (define project
    (layer-project layer))

  (define (apply-action action)
    (match action
      (('install file) (install (upper-file layer file) project file))
      (('merge file output _)
       (install output project file
                (stat:perms (lstat (file-in project file)))))
      (('chmod file _) (check-parents project file))
      (('delete file) (remove-entry project file))
      (('conflict . _) #t)))

  (define (problem action)
    "Apply ACTION and return its problem, or #f."
    (guard (error ((merge-refusal? error)
                   (make-problem (action-file action)
                                 (merge-refusal-reason error)
                                 (merge-refusal-detail error)))
                  ((eq? 'system-error (exception-kind error))
                   (make-problem (action-file action) 'error
                                 (strerror (system-error-errno
                                            (cons 'system-error
                                                  (exception-args error)))))))
      (apply-action action)
      #f))

  (let* ((results (map (lambda (action) (cons action (problem action))) plan))
         (applied (filter-map (match-lambda
                                ((action . #f) action)
                                (_ #f))
                              results)))
    (restore-permissions layer applied)
    (filter-map cdr results)))

(define (forget-merged layer plan failures)
  "Remove from LAYER what PLAN merged, but for the files of FAILURES, so
that the next run only offers these."
  (let ((failed (map problem-file failures)))
    (for-each (lambda (file)
                (let ((upper (upper-file layer file)))
                  (unless (or (any (lambda (other)
                                     (or (contains-file? file other)
                                         (contains-file? other file)))
                                   failed)
                              (memq (file-type upper) '(#f directory)))
                    (delete-file upper))))
              (delete-duplicates (map action-file plan)))))
