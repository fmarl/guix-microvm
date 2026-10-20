;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build registry)
  #:use-module ((guix build utils) #:select (delete-file-recursively))
  #:use-module (guix records)
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (guix-microvm build process)
  #:export (runtime-directory
            call-with-vm-directory
            running-vm
            running-vm?
            running-vm-state-directory
            running-vm-name
            running-vm-directory
            running-vm-usb?
            running-vm-volatile?
            running-vm-ssh
            running-vm-launcher
            running-vm-detached?
            running-vm-started
            running-vm-id
            running-vm-qmp-socket
            qmp-socket-file
            register!
            call-with-registration
            running-vms))

(define (runtime-directory)
  (or (getenv "XDG_RUNTIME_DIR") "/tmp"))

(define %prefix "guix-microvm.")

(define (call-with-vm-directory proc)
  "Call PROC with a new directory for a VM.  Delete it when PROC returns or
exits."
  (let ((directory (mkdtemp (string-append (runtime-directory) "/" %prefix
                                           "XXXXXX"))))
    (dynamic-wind
      (const #t)
      (cut proc directory)
      (cut delete-file-recursively directory))))

(define-record-type* <running-vm> running-vm make-running-vm
  running-vm?
  (state-directory running-vm-state-directory)
  (name            running-vm-name)
  (directory       running-vm-directory)        ;of the project
  (usb?            running-vm-usb? (default #f))
  (volatile?       running-vm-volatile? (default #f))
  (ssh             running-vm-ssh)              ;alist
  (launcher        running-vm-launcher)
  (detached?       running-vm-detached? (default #f))
  (started         running-vm-started))

(define (running-vm-id vm)
  (string-drop (basename (running-vm-state-directory vm))
               (string-length %prefix)))

(define (qmp-socket-file directory)
  (socket-file directory "qmp"))

(define (running-vm-qmp-socket vm)
  (qmp-socket-file (running-vm-state-directory vm)))

(define (lock-file directory)
  (string-append directory "/lock"))

(define (info-file directory)
  (string-append directory "/vm"))

(define (running-vm->sexp vm)
  (match-record vm <running-vm> (name directory usb? volatile? ssh launcher
                                 detached? started)
    `((name . ,name) (directory . ,directory) (usb? . ,usb?)
      (volatile? . ,volatile?) (ssh . ,ssh) (launcher . ,launcher)
      (detached? . ,detached?) (started . ,started))))

(define (sexp->running-vm state sexp)
  (let ((field (cut assq-ref sexp <>)))
    (running-vm
      (state-directory state)
      (name (field 'name))
      (directory (field 'directory))
      (usb? (field 'usb?))
      (volatile? (field 'volatile?))
      (ssh (field 'ssh))
      (launcher (field 'launcher))
      (detached? (field 'detached?))
      (started (field 'started)))))

(define (register! vm)
  "Write VM to its info file atomically."
  (let* ((file (info-file (running-vm-state-directory vm)))
         (new (string-append file ".new")))
    (call-with-output-file new
      (cut write (running-vm->sexp vm) <>))
    (rename-file new file)))

(define (call-with-registration vm thunk)
  "Register VM as running while THUNK runs."
  (call-with-output-file (lock-file (running-vm-state-directory vm))
    (lambda (port)
      (flock port LOCK_EX)
      (register! vm)
      (thunk))))

;; Without XDG_RUNTIME_DIR, other users can create entries in /tmp.
(define (owned? file)
  (= (stat:uid (lstat file)) (getuid)))

(define (locked? file)
  (call-with-input-file file
    (lambda (port)
      (catch 'system-error
        (lambda ()
          (flock port (logior LOCK_SH LOCK_NB))
          #f)
        (lambda args
          (= EWOULDBLOCK (system-error-errno args)))))))

(define (read-running-vm directory)
  "Return the VM running from DIRECTORY, or #f."
  (let ((lock (lock-file directory))
        (info (info-file directory)))
    (match (false-if-exception
            (and (owned? directory)
                 (owned? lock)
                 (locked? lock)
                 (owned? info)
                 (call-with-input-file info read)))
      ((? list? sexp) (sexp->running-vm directory sexp))
      (_ #f))))

(define* (running-vms #:optional (runtime (runtime-directory)))
  (filter-map (lambda (name)
                (read-running-vm (string-append runtime "/" name)))
              (or (scandir runtime (cut string-prefix? %prefix <>)) '())))
