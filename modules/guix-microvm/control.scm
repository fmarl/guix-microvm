;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm control)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module (guix-microvm build microvm)
  #:use-module (guix-microvm build process)
  #:use-module (guix-microvm build ssh)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:export (running-vm?
            running-vm-name
            running-vm-id
            running-vm-directory
            running-vm-usb?
            running-vm-qmp-socket
            running-vms
            attach-vm!
            kill-vm!
            call-with-qmp
            string->usb-id
            present-usb-devices
            attach-usb!
            detach-usb!))

(define-record-type <running-vm>
  (running-vm name id directory usb? qmp-socket ssh)
  running-vm?
  (name       running-vm-name)
  (id         running-vm-id)
  (directory  running-vm-directory)
  (usb?       running-vm-usb?)
  (qmp-socket running-vm-qmp-socket)
  (ssh        running-vm-ssh))              ;alist | #f

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

(define (directory->running-vm directory)
  "Return the VM running from DIRECTORY, or #f if it exited."
  (let ((file (vm-info-file directory)))
    (match (false-if-exception
            (and (owned? directory)
                 (owned? file)
                 (locked? file)
                 (call-with-input-file file read)))
      ((? list? info)
       (running-vm (assq-ref info 'name)
                   (string-drop (basename directory)
                                (string-length %vm-directory-prefix))
                   (assq-ref info 'directory)
                   (assq-ref info 'usb?)
                   (qmp-socket-file directory)
                   (assq-ref info 'ssh)))
      (_ #f))))

(define* (running-vms #:optional (runtime (runtime-directory)))
  (filter-map (lambda (name)
                (directory->running-vm (string-append runtime "/" name)))
              (or (scandir runtime
                           (cut string-prefix? %vm-directory-prefix <>))
                  '())))

(define (qmp-receive port)
  "Return the next message on PORT, skipping events."
  (match (read-line port)
    ((? eof-object?)
     (raise-exception
      (formatted-message (G_ "the VM closed its QMP connection"))))
    (line
     (let ((message (json-string->scm line)))
       (if (assoc "event" message)
           (qmp-receive port)
           message)))))

(define* (qmp-execute port command #:optional arguments)
  "Run COMMAND with the alist ARGUMENTS over PORT and return the result."
  (write-line (scm->json-string
               `(("execute" . ,command)
                 ,@(if arguments `(("arguments" . ,arguments)) '())))
              port)
  (force-output port)
  (let ((reply (qmp-receive port)))
    (match (assoc-ref reply "error")
      (#f (assoc-ref reply "return"))
      (error (raise-exception
              (formatted-message (G_ "QEMU: ~a")
                                 (assoc-ref error "desc")))))))

(define (call-with-qmp file proc)
  "Connect to the QMP socket FILE and call PROC with a procedure that runs a
command, with optional arguments, and returns the result."
  (let ((port (socket PF_UNIX SOCK_STREAM 0)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (connect port AF_UNIX file)
        (qmp-receive port)                ;greeting
        (qmp-execute port "qmp_capabilities")
        (proc (cut qmp-execute port <> <...>)))
      (cut close-port port))))

(define (usb-id-part? value)
  (and (exact-integer? value) (<= 0 value #xffff)))

(define (string->usb-id str)
  "Parse STR, VENDOR or VENDOR:PRODUCT in hexadecimal, into a pair.  The
product is #f if left out.  Return #f if STR is invalid."
  (match (map (cut string->number <> 16) (string-split str #\:))
    (((? usb-id-part? vendor)) (cons vendor #f))
    (((? usb-id-part? vendor) (? usb-id-part? product)) (cons vendor product))
    (_ #f)))

(define (usb-id->string id)
  (match id
    ((vendor . #f) (format #f "~4,'0x" vendor))
    ((vendor . product) (format #f "~4,'0x:~4,'0x" vendor product))))

(define (usb-id-matches? pattern id)
  "Return true if ID, a vendor and product pair, matches PATTERN.  A PATTERN
product of #f matches any product."
  (match (list pattern id)
    (((vendor . product) (vendor* . product*))
     (and (= vendor vendor*)
          (or (not product) (= product product*))))))

(define (sysfs-attribute directory name)
  (let ((file (string-append directory "/" name)))
    (and (file-exists? file)
         (string-trim-right (call-with-input-file file get-string-all)))))

(define (sysfs-usb-device directory)
  "Return the IDs and device file of the USB device at the sysfs DIRECTORY,
as a pair, or #f for an interface."
  (let ((attribute (cut sysfs-attribute directory <>)))
    (and (attribute "idVendor")
         (cons (cons (string->number (attribute "idVendor") 16)
                     (string->number (attribute "idProduct") 16))
               (format #f "/dev/bus/usb/~3,'0d/~3,'0d"
                       (string->number (attribute "busnum"))
                       (string->number (attribute "devnum")))))))

(define* (present-usb-devices pattern
                              #:optional (sysfs "/sys/bus/usb/devices"))
  "Return the device files of the plugged in USB devices matching PATTERN."
  (filter-map (lambda (name)
                (match (sysfs-usb-device (string-append sysfs "/" name))
                  ((id . file) (and (usb-id-matches? pattern id) file))
                  (#f #f)))
              (or (scandir sysfs (negate (cut string-prefix? "." <>))) '())))

(define (usb-device-name id)
  (string-append "usb-" (string-map (match-lambda (#\: #\-) (c c))
                                    (usb-id->string id))))

(define (usb-host-arguments id)
  "Return the 'device_add' arguments for the host USB device ID."
  (match id
    ((vendor . product)
     `(("driver" . "usb-host")
       ("id" . ,(usb-device-name id))
       ("vendorid" . ,vendor)
       ,@(if product `(("productid" . ,product)) '())))))

(define (check-usb-device id)
  "Raise an error unless the USB device ID is plugged in and accessible."
  (define (accessible? file)
    (access? file (logior R_OK W_OK)))

  (match (present-usb-devices id)
    (()
     (raise-exception
      (formatted-message (G_ "no USB device ~a is plugged in")
                         (usb-id->string id))))
    (files
     (for-each (lambda (file)
                 (unless (accessible? file)
                   (raise-exception
                    (formatted-message (G_ "~a is not accessible: a udev \
rule can give you access to it")
                                       file))))
               files))))

(define (attach-usb! vm id)
  "Move the host's USB device ID to VM until it is detached or VM exits."
  (unless (running-vm-usb? vm)
    (raise-exception
     (formatted-message (G_ "~a has no USB controller: its microvm lacks \
'usb?'")
                        (running-vm-name vm))))
  (check-usb-device id)
  (call-with-qmp (running-vm-qmp-socket vm)
    (cut <> "device_add" (usb-host-arguments id))))

(define (detach-usb! vm id)
  (call-with-qmp (running-vm-qmp-socket vm)
    (cut <> "device_del" `(("id" . ,(usb-device-name id))))))

(define (attach-vm! vm)
  "Run a login shell in /work of VM and return its exit status."
  (match (running-vm-ssh vm)
    (#f
     (raise-exception
      (formatted-message (G_ "~a was started by an older guix-microvm, \
which does not allow attaching")
                         (running-vm-name vm))))
    (ssh
     (wait-for-exit ((vm-ssh-spawner ssh) "cd /work && exec \"$SHELL\" -l"
                     #:options '("-e" "none" "-t"))))))

(define (kill-vm! vm)
  ;; Writes the guest still caches would be lost.  A stuck guest must not
  ;; keep it from being killed.
  (and=> (running-vm-ssh vm)
         (lambda (ssh)
           (let ((pid (spawn-batch-ssh (vm-ssh-spawner ssh) "sync")))
             (unless (exits-within? pid 10)
               (kill pid SIGKILL)
               (waitpid pid)))))
  (call-with-qmp (running-vm-qmp-socket vm)
    (lambda (execute)
      ;; QEMU may exit before it replies.
      (false-if-exception (execute "quit")))))
