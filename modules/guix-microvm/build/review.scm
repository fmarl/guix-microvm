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

(define (report message . args)
  (apply format (current-error-port)
         (string-append "~a: " message "~%") (%program-name) args))

(define (change-label change)
  (string-append (assq-ref '((added . "A") (modified . "M") (deleted . "D")
                             (replaced . "R"))
                           (change-kind change))
                 (if (change-executable? change) "+x" "")))

(define (problem-message problem)
  (let ((detail (problem-detail problem)))
    (match (problem-reason problem)
      ('changed-on-both "changed on the host and in the VM")
      ('changed-on-host "changed on the host, deleted in the VM")
      ('deleted-on-host "deleted on the host, changed in the VM")
      ('protected "protected")
      ('conflict-markers "conflict markers")
      ('missing-parent (format #f "~a is missing on the host" detail))
      ('not-a-directory (format #f "~a is not a directory on the host" detail))
      ('file-in-the-way "a file on the host is in the way")
      ('directory-in-the-way "a directory on the host is in the way")
      ('special-file "special files are not merged")
      ('not-empty "kept, the host has other files in it")
      ('error detail))))

(define (report-skipped groups)
  "Report the changes in GROUPS, from 'classify-changes', that are not
merged: those to .git and ignored files."
  (let ((git-changes (assq-ref groups 'git))
        (ignored (assq-ref groups 'ignored)))
    (for-each (lambda (change)
                (when (git-hook-or-config? (change-file change))
                  (report "not merging ~a: it is in .git"
                          (change-file change))))
              git-changes)
    (unless (null? git-changes)
      (report "not merging ~a changes to .git" (length git-changes)))
    (unless (null? ignored)
      (report "not merging ~a ignored files" (length ignored)))))

(define (show-changes changes protected)
  (for-each (lambda (change)
              (format (current-error-port) "  ~a ~a~a~%"
                      (change-label change) (change-file change)
                      (if (memq change protected) " (protected)" "")))
            changes))

(define (read-selection file)
  "Return the files that FILE, as 'select-changes' writes it, still lists."
  (filter-map (lambda (line)
                (and (not (string-prefix? "#" line))
                     (and=> (string-index line #\space)
                            (lambda (space)
                              (substring line (+ space 1))))))
              (string-split (call-with-input-file file get-string-all)
                            #\newline)))

(define (select-changes layer changes protected)
  "Let the user edit the list of CHANGES, where PROTECTED ones start out
commented out, and return those left, or #f if the editor fails."
  (let ((file (layer-file layer "selection")))
    (call-with-output-file file
      (lambda (port)
        (display "# Delete the lines of the files not to merge.  Uncomment \
protected files to\n# merge them.  +x marks new executables.\n" port)
        (for-each (lambda (change)
                    (format port "~a~a ~a~%"
                            (if (memq change protected) "# " "")
                            (change-label change) (change-file change)))
                  changes)))
    (and (zero? (wait-for-exit
                 (spawn "sh" (list "sh" "-c"
                                   "exec ${VISUAL:-${EDITOR:-vi}} \"$1\""
                                   "sh" file))))
         (let ((selected (read-selection file)))
           (filter (compose (cut member <> selected) change-file) changes)))))

(define* (merge-changes layer changes #:key git on-conflict protected-files)
  "Merge CHANGES of LAYER into its project and return true.  If
ON-CONFLICT is 'abort, merge nothing and return false on a conflict; if it
is 'markers, leave conflict markers."
  (let* ((directory (mkdtemp (layer-file layer "merge-XXXXXX")))
         (plan (plan-merge layer changes #:git git #:directory directory
                           #:protected-files protected-files))
         (problems (plan-problems plan)))
    (define (report-problems problems)
      (for-each (lambda (problem)
                  (report "conflict in ~a: ~a" (problem-file problem)
                          (problem-message problem)))
                problems))

    (if (and (eq? on-conflict 'abort) (pair? problems))
        (begin
          (report-problems problems)
          (report "merged nothing; the changes stay in ~a"
                  (layer-directory layer))
          #f)
        (begin
          (report-problems (append problems (apply-plan layer plan)))
          #t))))

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

(define* (resolve-layer layer #:key git policy (protected-files '())
                        previous?)
  "Ask what to do with the changes of LAYER, or merge or discard them as
POLICY, 'merge or 'discard, says.  Return 'merged, 'discarded, 'kept or
'conflict; LAYER is gone unless 'kept or 'conflict."
  (if (eq? policy 'discard)
      (begin
        (delete-layer layer)
        'discarded)
      (let* ((groups (classify-changes layer #:git git
                                       #:protected-files protected-files))
             (mergeable (assq-ref groups 'mergeable))
             (protected (assq-ref groups 'protected))
             (changes (sort (append mergeable protected)
                            (lambda (change other)
                              (string<? (change-file change)
                                        (change-file other))))))
        (define (finish skipped-protected)
          (report-skipped groups)
          (for-each (lambda (change)
                      (report "not merging ~a: protected" (change-file change)))
                    skipped-protected)
          (delete-layer layer)
          'merged)

        (define (merge changes on-conflict)
          (if (merge-changes layer changes #:git git #:on-conflict on-conflict
                             #:protected-files protected-files)
              (finish (lset-difference eq? protected changes))
              'conflict))

        (cond ((null? changes)
               (finish '()))
              ((eq? policy 'merge)
               (merge mergeable 'abort))
              (else
               (report (if previous?
                           "a previous VM changed ~a files in ~a:"
                           "the VM changed ~a files in ~a:")
                       (length changes) (layer-project layer))
               (let loop ()
                 (match (ask-action layer changes protected git)
                   ('merge (merge mergeable 'markers))
                   ('select
                    (match (select-changes layer changes protected)
                      (#f (loop))
                      (selected (merge selected 'markers))))
                   ('discard
                    (delete-layer layer)
                    'discarded)
                   ('keep
                    (report "kept the changes in ~a; the next run asks again"
                            (layer-directory layer))
                    'kept))))))))
