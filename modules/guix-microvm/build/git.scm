;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build git)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build files)
  #:use-module (guix-microvm build process)
  #:export (git-config
            git-identity
            git-merge-file
            git-check-ignore
            git-diff-process))

(define (git-config git directory name)
  (let* ((port (with-error-to-port (null-port)
                 (cut open-pipe* OPEN_READ git "-C" directory "config" name)))
         (value (string-trim-right (get-string-all port))))
    (and (eqv? 0 (status:exit-val (close-pipe port)))
         (not (string-null? value))
         value)))

(define (git-identity git directory)
  "Return GIT_AUTHOR_* and GIT_COMMITTER_* as an alist, from the environment
or else DIRECTORY's Git configuration."
  (let ((name (or (getenv "GIT_AUTHOR_NAME")
                  (git-config git directory "user.name")))
        (email (or (getenv "GIT_AUTHOR_EMAIL")
                   (git-config git directory "user.email"))))
    (filter cdr
            `(("GIT_AUTHOR_NAME" . ,name)
              ("GIT_AUTHOR_EMAIL" . ,email)
              ("GIT_COMMITTER_NAME" . ,(or (getenv "GIT_COMMITTER_NAME") name))
              ("GIT_COMMITTER_EMAIL"
               . ,(or (getenv "GIT_COMMITTER_EMAIL") email))))))

(define (git-merge-file git file base other output)
  "Merge into OUTPUT the changes from BASE to OTHER with those to FILE, and
return the number of conflicts."
  (let ((status (call-with-output-file output
                  (lambda (port)
                    (wait-for-exit
                     (spawn git (list git "merge-file" "-p"
                                      "-L" "host" "-L" "start" "-L" "vm"
                                      file base other)
                            #:output port #:error (null-port)))))))
    (if (< status 128)
        status
        (fail "git merge-file failed with status ~a" status))))

;; A repository around DIRECTORY, such as one of dotfiles, would apply its
;; configuration and could ignore everything.
(define (ceiling-environment directory)
  (cons (string-append "GIT_CEILING_DIRECTORIES=" (dirname directory))
        (environ)))

(define (git-check-ignore git directory names temporary-directory)
  "Return those of NAMES that the .gitignore files of the repository in
DIRECTORY ignore, keeping a temporary file in TEMPORARY-DIRECTORY."
  (if (null? names)
      '()
      (call-with-temporary-file temporary-directory
        (lambda (input)
          (call-with-output-file input
            (lambda (port)
              (for-each (lambda (name)
                          (display name port)
                          (write-char #\nul port))
                        names)))
          (let* ((pipe (pipe))
                 (pid (call-with-input-file input
                        (lambda (port)
                          (spawn git (list git "-C" directory "check-ignore"
                                           "--stdin" "-z")
                                 #:input port #:output (cdr pipe)
                                 #:error (null-port)
                                 #:environment
                                 (ceiling-environment directory))))))
            (close-port (cdr pipe))
            (let ((output (get-string-all (car pipe))))
              (close-port (car pipe))
              (wait-for-exit pid)
              (delete "" (string-split output #\nul))))))))

(define (git-diff-process git tool old new)
  (if tool
      (spawn "sh" (list "sh" "-c" (string-append tool " \"$1\" \"$2\"")
                        "sh" old new))
      (let ((directory (dirname old)))
        (spawn git (list git "-C" directory "diff" "--no-index"
                         "--no-prefix" "-M"
                         (basename old) (basename new))
               #:environment (ceiling-environment directory)))))
