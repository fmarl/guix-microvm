;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build state)
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (web uri)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build files)
  #:use-module (guix-microvm build layer)
  #:export (home-directory
            data-directory
            call-with-project-lock
            project-layers
            layers-around))

(define (home-directory)
  (canonicalize-path (getenv "HOME")))

(define (data-directory)
  (string-append (or (getenv "XDG_DATA_HOME")
                     (string-append (home-directory) "/.local/share"))
                 "/guix-microvm"))

(define (overlap? directory other)
  (or (contains-file? directory other)
      (contains-file? other directory)))

(define (lock-held? file)
  (call-with-input-file file
    (lambda (port)
      (catch 'system-error
        (lambda ()
          (flock port (logior LOCK_SH LOCK_NB))
          #f)
        (lambda args
          (= EWOULDBLOCK (system-error-errno args)))))))

(define (call-with-project-lock data directory thunk)
  "Call THUNK holding the lock of the project DIRECTORY in DATA.  Fail if a
VM runs on DIRECTORY, one of its parents or one of its subdirectories."
  (let* ((locks (file-in data "locks"))
         (name (uri-encode directory))
         ;; Appending leaves the lock file of a running VM as it is.
         (port (begin
                 (mkdir-p locks)
                 (open-file (file-in locks name) "a"))))
    (dynamic-wind
      (const #t)
      (lambda ()
        (catch 'system-error
          (lambda ()
            (flock port (logior LOCK_EX LOCK_NB)))
          (lambda _
            (fail "a VM already runs on ~a" directory)))
        ;; Two VMs starting at once on overlapping projects may both fail
        ;; here, but never both run.
        (for-each (lambda (other)
                    (let ((project (uri-decode other)))
                      (when (and (overlap? directory project)
                                 (lock-held? (file-in locks other)))
                        (fail "not sharing ~a, a VM runs on ~a"
                              directory project))))
                  (delete name (directory-files locks)))
        (thunk))
      (cut close-port port))))

(define (layers data)
  (let ((directory (file-in data "layers")))
    (filter-map (compose open-layer (cut file-in directory <>))
                (or (directory-files directory) '()))))

(define (project-layers data directory)
  (filter (lambda (layer)
            (string=? directory (layer-project layer)))
          (layers data)))

(define (layers-around data file)
  (filter (lambda (layer)
            (contains-file? (layer-project layer) file))
          (layers data)))
