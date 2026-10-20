;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build error)
  #:use-module (ice-9 exceptions)
  #:export (%program-name
            microvm-error?
            usage-error?
            error-status
            fail
            usage-error
            call-with-launcher-errors))

(define %program-name
  (make-parameter "run-vm"))

;; A '&message', so that 'guix microvm' reports it too.
(define-exception-type &microvm-error &message
  make-microvm-error microvm-error?)

(define-exception-type &usage-error &microvm-error
  make-usage-error usage-error?)

(define (fail message . args)
  "Raise an error, formatting MESSAGE with ARGS."
  (raise-exception (make-microvm-error (apply format #f message args))))

(define (usage-error usage)
  "Raise a usage error showing USAGE."
  (raise-exception
   (make-usage-error (format #f "usage: ~a ~a" (%program-name) usage))))

(define (error-status error)
  (if (usage-error? error) 2 1))

(define (call-with-launcher-errors thunk)
  "Call THUNK.  On an error, print it and return its exit status."
  (with-exception-handler
      (lambda (error)
        (format (current-error-port) "~a: ~a~%"
                (%program-name) (exception-message error))
        (error-status error))
    thunk
    #:unwind? #t
    #:unwind-for-type &microvm-error))
