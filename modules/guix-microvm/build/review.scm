;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build review)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build files)
  #:use-module (guix-microvm build git)
  #:use-module (guix-microvm build layer)
  #:use-module (guix-microvm build merge)
  #:use-module (guix-microvm build process)
  #:export (report-skipped
            resolve-layer))

(define (count n singular plural)
  (format #f "~a ~a" n (if (= n 1) singular plural)))

(define (report message . args)
  (apply format (current-error-port)
         (string-append "~a: " message "~%") (%program-name) args))

(define (change-label change)
  (string-append (assq-ref '((added . "A") (modified . "M") (deleted . "D")
                             (replaced . "R"))
                           (change-kind change))
                 (if (change-executable? change) "+x" "")))

(define (by-file changes)
  (sort changes
        (lambda (change other)
          (string<? (change-file change) (change-file other)))))

(define (reason-message reason detail)
  (match reason
    ('changed-on-both "changed on the host and in the VM")
    ('changed-on-host "changed on the host, deleted in the VM")
    ('deleted-on-host "deleted on the host, changed in the VM")
    ('protected "protected")
    ('missing-parent (format #f "~a is missing on the host" detail))
    ('not-a-directory (format #f "~a is not a directory on the host" detail))
    ('file-in-the-way "a file on the host is in the way")
    ('directory-in-the-way "a directory on the host is in the way")
    ('special-file "it is a special file")
    ('not-empty "the host has other files in it")
    ('error detail)))

(define (report-problem problem on-conflict)
  (let ((file (problem-file problem))
        (reason (problem-reason problem))
        (detail (problem-detail problem)))
    (match (list reason on-conflict)
      (('conflict-markers _)
       (report "conflict in ~a: resolve the conflict markers" file))
      (((or 'changed-on-both 'changed-on-host 'deleted-on-host) 'abort)
       (report "conflict in ~a: ~a" file (reason-message reason detail)))
      (((or 'changed-on-both 'changed-on-host 'deleted-on-host) _)
       (report "conflict in ~a: ~a; kept the host's version" file
               (reason-message reason detail)))
      (_
       (report "not merging ~a: ~a" file (reason-message reason detail))))))

(define (report-skipped groups)
  (for-each (lambda (change)
              (report "not merging ~s: control characters in the name"
                      (change-file change)))
            (assq-ref groups 'unprintable))
  (for-each (lambda (change)
              (report "not merging ~a: the VM left it unreadable"
                      (change-file change)))
            (assq-ref groups 'unreadable))
  (match (assq-ref groups 'git)
    (() #t)
    (changes
     (for-each (lambda (change)
                 (when (git-hook-or-config? (change-file change))
                   (report "not merging ~a: .git is never merged"
                           (change-file change))))
               changes)
     (report "not merging ~a to .git"
             (count (length changes) "change" "changes"))))
  (match (assq-ref groups 'ignored)
    (() #t)
    (changes
     (report "not merging ~a to ignored files"
             (count (length changes) "change" "changes")))))

(define (show-changes changes protected)
  (for-each (lambda (change)
              (format (current-error-port) "  ~a ~a~a~%"
                      (change-label change) (change-file change)
                      (if (memq change protected) " (protected)" "")))
            changes))

(define (read-selection file)
  (filter-map (lambda (line)
                (and (not (string-prefix? "#" line))
                     (and=> (string-index line #\space)
                            (lambda (space)
                              (substring line (+ space 1))))))
              (string-split (call-with-input-file file get-string-all)
                            #\newline)))

(define (write-selection port changes protected trees project)
  ;; The first line sets up guix-microvm-selection-mode in Emacs, which
  ;; diffs files between project/ and vm/ in TREES and visits them in
  ;; PROJECT.
  (format port "# -*- mode: guix-microvm-selection; guix-microvm-trees: ~s; \
guix-microvm-project: ~s -*-
# Delete the lines of the files not to merge.  Uncomment protected files to
# merge them.  +x marks new executables.~%"
          trees project)
  (for-each (lambda (change)
              (format port "~a~a ~a~%"
                      (if (memq change protected) "# " "")
                      (change-label change) (change-file change)))
            changes))

(define (select-changes layer changes protected)
  "Let the user edit the list of CHANGES, where PROTECTED ones start out
commented out, and return those left, or #f if the editor fails."
  (let ((file (layer-file layer "selection")))
    (call-with-diff-trees layer changes
      (lambda (before after)
        (call-with-output-file file
          (cut write-selection <> changes protected (dirname before)
               (layer-project layer)))
        (and (zero? (wait-for-exit
                     (spawn "sh" (list "sh" "-c"
                                       "exec ${VISUAL:-${EDITOR:-vi}} \"$1\""
                                       "sh" file)
                            ;; Lets an Emacs started for FILE alone exit.
                            #:environment
                            (cons (string-append "GUIX_MICROVM_SELECTION="
                                                 file)
                                  (environ)))))
             (let ((selected (read-selection file)))
               (filter (compose (cut member <> selected) change-file)
                       changes)))))))

(define* (merge-changes layer changes #:key git on-conflict protected-files)
  "Merge CHANGES of LAYER into its project and return 'merged, or
'incomplete if files could not be written.  If ON-CONFLICT is 'abort, merge
nothing and return 'conflict on a conflict; if it is 'markers, leave
conflict markers or keep the host's version."
  (let* ((directory (mkdtemp (layer-file layer "merge-XXXXXX")))
         (plan (plan-merge layer changes #:git git #:directory directory
                           #:protected-files protected-files))
         (conflicts (plan-problems plan)))
    (for-each (cut report-problem <> on-conflict) conflicts)
    (if (and (eq? on-conflict 'abort) (pair? conflicts))
        (begin
          (report "merged nothing; the changes stay in ~a"
                  (layer-directory layer))
          'conflict)
        (let* ((problems (apply-plan layer plan))
               (failures (remove (lambda (problem)
                                   (memq (problem-reason problem)
                                         '(not-empty special-file)))
                                 problems)))
          (for-each (cut report-problem <> on-conflict) problems)
          (if (null? failures)
              'merged
              (begin
                (forget-merged layer plan failures)
                'incomplete))))))

(define (ask-action layer changes protected git)
  "Ask what to do with CHANGES and return 'merge, 'select, 'discard or
'keep.  Show their diff when asked to."
  (let loop ()
    (show-changes changes protected)
    (format (current-error-port) "[d]iff, [m]erge, [s]elect or discard [x]? ")
    (force-output (current-error-port))
    (match (read-line)
      ((? eof-object?)
       (newline (current-error-port))
       'keep)
      ("d"
       (call-with-diff-trees layer changes
         (lambda (before after)
           (wait-for-exit (git-diff-process git #f before after))))
       (loop))
      ("m" 'merge)
      ("s" 'select)
      ("x" 'discard)
      (_ (loop)))))

;; Guile runs Scheme signal handlers only once 'read-line' returns, so
;; Ctrl-C at the question would wait for Enter.
(define (with-default-signal-handlers thunk)
  (let ((signals (list SIGINT SIGTERM SIGHUP))
        (handlers '()))
    (dynamic-wind
      (lambda ()
        (set! handlers (map (cut sigaction <> SIG_DFL) signals)))
      thunk
      (lambda ()
        (for-each (lambda (signal handler)
                    (sigaction signal (car handler) (cdr handler)))
                  signals handlers)))))

(define* (resolve-layer layer #:key git policy (protected-files '())
                        previous?)
  "Ask what to do with the changes of LAYER, or merge, discard or keep
them as POLICY, 'merge, 'discard or 'keep, says.  Return 'merged,
'discarded, 'kept, 'conflict or 'incomplete, if files could not be
written; LAYER is gone after 'merged and 'discarded."
  (define (discard)
    (delete-layer layer)
    'discarded)

  (define (keep)
    (report "kept the changes in ~a; the next run asks again"
            (layer-directory layer))
    'kept)

  (if (eq? policy 'discard)
      (discard)
      (let* ((groups (classify-changes layer #:git git
                                       #:protected-files protected-files))
             (mergeable (assq-ref groups 'mergeable))
             (protected (assq-ref groups 'protected))
             (changes (by-file (append mergeable protected))))
        (define (merge selected on-conflict)
          (match (merge-changes layer selected #:git git
                                #:on-conflict on-conflict
                                #:protected-files protected-files)
            ('merged
             (for-each (lambda (change)
                         (report "not merging ~a: protected"
                                 (change-file change)))
                       (lset-difference eq? protected selected))
             (delete-layer layer)
             'merged)
            ('conflict 'conflict)
            ('incomplete (keep) 'incomplete)))

        (report-skipped groups)
        (cond ((null? changes) (merge '() 'abort))
              ((eq? policy 'merge) (merge mergeable 'abort))
              ((eq? policy 'keep) (keep))
              (else
               (report (if previous?
                           "a previous VM made ~a to ~a:"
                           "the VM made ~a to ~a:")
                       (count (length changes) "change" "changes")
                       (layer-project layer))
               (match (with-default-signal-handlers
                       (lambda ()
                         (let loop ()
                           (match (ask-action layer changes protected git)
                             ('select
                              (or (select-changes layer changes protected)
                                  (loop)))
                             (action action)))))
                 ('merge (merge mergeable 'markers))
                 ('discard (discard))
                 ('keep (keep))
                 (selected (merge selected 'markers))))))))
