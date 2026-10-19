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
            apply-plan))

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
'protected, 'git, 'ignored and 'unprintable."
  (let* ((unprintable rest (partition (compose unprintable? change-file)
                                      (layer-changes layer)))
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
      (unprintable . ,unprintable))))

(define-record-type <action>
  (make-action kind file source perms conflicts reason)
  action?
  (kind      action-kind)   ;'install | 'merged | 'chmod | 'delete | 'conflict
  (file      action-file)
  (source    action-source) ;the merged file
  (perms     action-perms)
  (conflicts action-conflicts) ;of the merged file
  (reason    action-reason)) ;of a conflict

(define (install-action file)
  (make-action 'install file #f #f #f #f))

(define (merged-action file source conflicts)
  (make-action 'merged file source #f conflicts #f))

(define (chmod-action file perms)
  (make-action 'chmod file #f perms #f #f))

(define (delete-action file)
  (make-action 'delete file #f #f #f #f))

(define (conflict-action file reason)
  (make-action 'conflict file #f #f #f reason))

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
      (if (every text-file? (list host base vm))
          (let ((output (temporary-file directory)))
            (list (merged-action file output
                                 (git-merge-file git host base vm output))))
          (list (conflict-action file 'changed-on-both)))))

  (define (deletions file)
    (filter-map (lambda (entry)
                  (cond ((git-file? entry) #f)
                        ((and (not (string=? entry file))
                              (protected? entry protected-files))
                         (conflict-action entry 'protected))
                        ((not (file-stat (host-file layer entry))) #f)
                        ((host-unchanged? layer entry) (delete-action entry))
                        (else (conflict-action entry 'changed-on-host))))
                (base-entries layer file)))

  (define (change-actions change)
    (let* ((file (change-file change))
           (host (host-file layer file))
           (vm (upper-file layer file)))
      (match (change-kind change)
        ('added
         (cond ((not (file-stat host)) (list (install-action file)))
               ((same-entry? host vm) '())
               (else (three-way file (force empty)))))
        ('modified
         (cond ((eq? 'directory (change-type change))
                (if (host-unchanged? layer file)
                    (list (chmod-action file (stat:perms (lstat vm))))
                    '()))
               ((host-unchanged? layer file) (list (install-action file)))
               ((same-entry? host vm) '())
               ((not (file-stat host))
                (list (conflict-action file 'deleted-on-host)))
               ((base-contents layer file) => (cut three-way file <>))
               (else (list (conflict-action file 'changed-on-both)))))
        ('deleted (deletions file))
        ('replaced (append (deletions file) (list (install-action file)))))))

  (append-map change-actions changes))

(define (plan-problems plan)
  "Return the problems of PLAN before it is applied: conflicts and merged
files with conflict markers."
  (filter-map (lambda (action)
                (match (action-kind action)
                  ('conflict
                   (make-problem (action-file action) (action-reason action)
                                 #f))
                  ('merged
                   (and (positive? (action-conflicts action))
                        (make-problem (action-file action) 'conflict-markers
                                      #f)))
                  (_ #f)))
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
  "Replace FILE in PROJECT at once by the file that WRITE creates."
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
SOURCE.  Return the permissions to give a directory once its files are in."
  (check-parents project file)
  (let ((stat (lstat source))
        (target (file-in project file)))
    (match (stat:type stat)
      ('directory
       (match (file-type target)
         ('directory (chmod target #o700))
         (#f (mkdir target #o700))
         (_ (refuse 'file-in-the-way)))
       (stat:perms stat))
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
                                    (or perms (stat:perms stat)))))))
       #f)
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

(define (apply-plan layer plan)
  "Apply PLAN to the project of LAYER and return the problems of the files
it could not change."
  (define project
    (layer-project layer))

  (define (apply-action action)
    "Apply ACTION and return the permissions to give a directory later, as
a pair, or #f."
    (let ((file (action-file action)))
      (match (action-kind action)
        ('install
         (and=> (install (upper-file layer file) project file)
                (cut cons file <>)))
        ('merged
         (install (action-source action) project file
                  (stat:perms (lstat (file-in project file))))
         #f)
        ('chmod
         (check-parents project file)
         (cons file (action-perms action)))
        ('delete
         (remove-entry project file)
         #f)
        ('conflict #f))))

  (define (failure action error)
    (if (merge-refusal? error)
        (make-problem (action-file action) (merge-refusal-reason error)
                      (merge-refusal-detail error))
        (make-problem (action-file action) 'error
                      (strerror (system-error-errno
                                 (cons 'system-error
                                       (exception-args error)))))))

  ;; Directories get their permissions last, so that read-only ones can
  ;; still receive their files.
  (let loop ((plan plan)
             (permissions '())
             (problems '()))
    (match plan
      (()
       (for-each (match-lambda
                   ((file . perms)
                    (chmod (file-in project file) perms)))
                 permissions)
       (reverse problems))
      ((action rest ...)
       (match (guard (error ((or (merge-refusal? error)
                                 (eq? 'system-error (exception-kind error)))
                             (failure action error)))
                (apply-action action))
         ((? problem? problem)
          (loop rest permissions (cons problem problems)))
         (#f (loop rest permissions problems))
         (permission
          (loop rest (cons permission permissions) problems)))))))
