;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build terminal)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-26)
  #:use-module (guix-microvm build process)
  #:export (exit-on-signals!
            call-with-detachable))

(define (exit-on-signals!)
  (for-each (lambda (signal)
              (sigaction signal
                (lambda (signal)
                  (exit (+ 128 signal)))))
            (list SIGINT SIGTERM SIGHUP)))

(define (give-terminal! group)
  (let ((handler (sigaction SIGTTOU SIG_IGN)))
    (tcsetpgrp (current-input-port) group)
    (sigaction SIGTTOU (car handler) (cdr handler))))

(define (call-with-detachable detachable? proc)
  "Call PROC with a procedure that detaches it, or with #f unless
DETACHABLE?, and return its result.  Detaching exits this process with the
status passed to the procedure; PROC goes on in a child, its standard ports
on /dev/null."
  (if detachable?
      (match (pipe)
        ((input . output)
         (for-each (cut fcntl <> F_SETFD FD_CLOEXEC) (list input output))
         (flush-all-ports)
         (let* ((group (getpgrp))
                ;; Without job control, the hangup of the terminal would
                ;; reach the VM in the group of the session leader.
                (own-group? (= group (getsid 0))))
           (match (primitive-fork)
             (0
              (close-port input)
              (when own-group?
                (setpgid 0 0)
                (give-terminal! (getpid)))
              (proc (lambda (status)
                      (when own-group?
                        (give-terminal! group))
                      (write status output)
                      (newline output)
                      (close-port output)
                      (for-each (cut dup2 (fileno (null-port)) <>)
                                '(0 1 2)))))
             (pid
              (close-port output)
              (for-each (cut sigaction <> SIG_IGN)
                        (list SIGINT SIGTERM SIGHUP))
              (match (read input)
                ((? eof-object?)
                 (let ((status (wait-for-exit pid)))
                   (when own-group?
                     (give-terminal! group))
                   status))
                (status
                 (flush-all-ports)
                 (primitive-exit status))))))))
      (proc #f)))
