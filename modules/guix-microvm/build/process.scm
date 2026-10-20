;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build process)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (guix-microvm build error)
  #:export (null-port
            wait-for-exit
            child-alive?
            exits-within?
            call-with-process
            server
            server-program
            server-socket
            socket-file
            call-with-servers))

(define %null-port
  (delay (open-file "/dev/null" "r+")))

(define (null-port)
  (force %null-port))

(define (exit-status status)
  (or (status:exit-val status)
      (+ 128 (status:term-sig status))))

(define (wait-for-exit pid)
  (exit-status (cdr (waitpid pid))))

(define (child-alive? pid)
  "Return true if the child PID runs.  Reap it otherwise."
  (catch 'system-error
    (lambda ()
      (zero? (car (waitpid pid WNOHANG))))
    (lambda args
      (if (= ECHILD (system-error-errno args))
          #f
          (apply throw args)))))

(define (exits-within? pid seconds)
  "Return true if the child PID exits within SECONDS.  Reap it then."
  (let loop ((tenths (* 10 seconds)))
    (cond ((not (child-alive? pid)) #t)
          ((<= tenths 0) #f)
          (else
           (usleep 100000)
           (loop (- tenths 1))))))

(define* (call-with-process program args proc
                            #:key (output (current-output-port))
                            (error (current-error-port)))
  "Start PROGRAM with ARGS, stdout to OUTPUT and stderr to ERROR, and call
PROC with its PID.  Stop it when PROC returns or exits."
  (let ((pid (spawn program (cons program args)
                    #:input (null-port) #:output output #:error error)))
    (dynamic-wind
      (const #t)
      (cut proc pid)
      (lambda ()
        ;; Once reaped, PID may be another process's.
        (when (child-alive? pid)
          (kill pid SIGTERM)
          (waitpid pid))))))

;; A program that is up once it has created its socket.
(define-record-type <server>
  (server program arguments socket)
  server?
  (program   server-program)
  (arguments server-arguments)
  (socket    server-socket))

(define (socket-file directory name)
  (string-append directory "/" name ".sock"))

(define (wait-for-socket file pid on-failure)
  (let loop ()
    (unless (file-exists? file)
      (unless (child-alive? pid)
        (on-failure (format #f "no ~a, the program serving it exited" file)))
      (usleep 100000)
      (loop))))

(define* (call-with-servers servers thunk
                            #:key (log (current-error-port))
                            (on-failure (cut fail "~a" <>)))
  "Start SERVERS in order, their output to LOG, call THUNK once all are up,
and stop them when it returns or exits.  Call ON-FAILURE with a message if
one exits first."
  (match servers
    (() (thunk))
    ((first rest ...)
     (call-with-process (server-program first) (server-arguments first)
       (lambda (pid)
         (wait-for-socket (server-socket first) pid on-failure)
         (call-with-servers rest thunk #:log log #:on-failure on-failure))
       #:output log #:error log))))
