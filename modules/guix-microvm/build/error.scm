;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build error)
  #:use-module (ice-9 exceptions)
  #:export (%program-name
            launcher-error?
            launcher-error-status
            fail
            usage-error
            call-with-launcher-errors))

(define %program-name
  (make-parameter "run-vm"))

;; A '&message', so that 'guix microvm' reports it too.
(define-exception-type &launcher-error &message
  make-launcher-error launcher-error?
  (status launcher-error-status))

(define (fail message . args)
  "Raise a launcher error with exit status 1, formatting MESSAGE with ARGS."
  (raise-exception (make-launcher-error (apply format #f message args) 1)))

(define (usage-error usage)
  "Raise a launcher error with exit status 2 showing USAGE."
  (raise-exception
   (make-launcher-error (format #f "usage: ~a ~a" (%program-name) usage) 2)))

(define (call-with-launcher-errors thunk)
  "Call THUNK.  On a launcher error, print it and return its exit status."
  (with-exception-handler
      (lambda (error)
        (format (current-error-port) "~a: ~a~%"
                (%program-name) (exception-message error))
        (launcher-error-status error))
    thunk
    #:unwind? #t
    #:unwind-for-type &launcher-error))
