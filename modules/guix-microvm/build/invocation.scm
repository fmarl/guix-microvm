;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build invocation)
  #:use-module ((guix build utils) #:select (directory-exists?))
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-71)
  #:use-module (guix-microvm build error)
  #:export (vm-config
            <vm-config>
            vm-config-name
            vm-config-command
            vm-config-stateless?
            vm-config-volatile?
            vm-config-memory-size
            vm-config-cpu-count
            vm-config-network-options
            vm-config-protected-files

            tools
            tools-qemu
            tools-virtiofsd
            tools-passt
            tools-waypipe
            tools-guest-waypipe
            tools-ssh
            tools-ssh-keygen
            tools-socat
            tools-git
            tools-unshare
            tools-cp
            tools-mount-store
            tools-mount-overlay

            invocation
            <invocation>
            invocation-directory
            invocation-name
            invocation-command
            invocation-stateless?
            invocation-volatile?
            invocation-policy
            invocation-interactive?
            invocation-memory
            invocation-cpus
            invocation-boot-timeout

            parse-arguments
            valued-flag?
            flag-value
            host-name
            default-name
            unique-name
            existing-directory
            volatile-vm?
            parse-invocation))

(define-record-type* <vm-config> vm-config make-vm-config
  vm-config?
  (name             vm-config-name)
  (command          vm-config-command)
  (stateless?       vm-config-stateless?)
  (volatile?        vm-config-volatile?)
  (kernel           vm-config-kernel)
  (initrd           vm-config-initrd)
  (kernel-arguments vm-config-kernel-arguments)
  (store-items      vm-config-store-items)      ;file listing them
  (profile          vm-config-profile)          ;file name | #f
  (memory-size      vm-config-memory-size)      ;MiB
  (cpu-count        vm-config-cpu-count)
  (network-options  vm-config-network-options)  ;passt's | #f
  (secrets          vm-config-secrets)
  (protected-files  vm-config-protected-files)
  (usb?             vm-config-usb?)
  (user             vm-config-user)
  (uid              vm-config-uid)
  (gid              vm-config-gid)
  (guest-runtime-directory vm-config-guest-runtime-directory)
  (ssh-port         vm-config-ssh-port))

(define-record-type* <tools> tools make-tools
  tools?
  (qemu            tools-qemu)
  (virtiofsd       tools-virtiofsd)
  (passt           tools-passt)
  (waypipe         tools-waypipe)               ;#f without Wayland
  (guest-waypipe   tools-guest-waypipe)         ;#f without Wayland
  (ssh             tools-ssh)
  (ssh-keygen      tools-ssh-keygen)
  (socat           tools-socat)
  (git             tools-git)
  (unshare         tools-unshare)
  (cp              tools-cp)
  (mount-store     tools-mount-store)
  (mount-overlay   tools-mount-overlay))

(define-record-type* <invocation> invocation make-invocation
  invocation?
  (directory    invocation-directory)           ;canonical
  (name         invocation-name)                ;host name
  (command      invocation-command)
  (stateless?   invocation-stateless?)
  (volatile?    invocation-volatile?)
  (policy       invocation-policy)              ;'ask | 'merge | 'discard
  (interactive? invocation-interactive?)
  (memory       invocation-memory)              ;MiB
  (cpus         invocation-cpus)
  (boot-timeout invocation-boot-timeout)        ;seconds
  (cache        invocation-cache)
  (serial       invocation-serial))             ;QEMU's -serial | #f

(define (parse-arguments args)
  "Split ARGS into flags, directory and command, returned as three values."
  (match args
    (((and flag (or "--stateless" "--volatile" "--persistent" "--merge"
                    "--discard" (? valued-flag?)))
      rest ...)
     (let ((flags directory command (parse-arguments rest)))
       (values (cons flag flags) directory command)))
    (() (values '() "." '()))
    (("--" command ...) (values '() "." command))
    ((directory) (values '() directory '()))
    ((directory "--" command ...) (values '() directory command))
    (_ (usage-error "[--name=NAME] [--stateless] \
[--volatile|--persistent] [--merge|--discard] [DIR] [-- COMMAND...]"))))

(define %valued-flags
  '("name"))

(define (valued-flag? arg)
  (any (lambda (name)
         (string-prefix? (string-append "--" name "=") arg))
       %valued-flags))

(define (flag-value name flags)
  (let ((prefix (string-append "--" name "=")))
    (any (lambda (flag)
           (and (string-prefix? prefix flag)
                (string-drop flag (string-length prefix))))
         flags)))

(define (host-name str)
  "Return STR as a host name, or #f."
  (let* ((name (string-map (lambda (char)
                             (if (or (char<=? #\a char #\z)
                                     (char<=? #\0 char #\9))
                                 char
                                 #\-))
                           (string-downcase str)))
         (name (string-trim-both (string-take name (min 56 (string-length
                                                             name)))
                                 #\-)))
    (and (not (string-null? name)) name)))

(define (default-name directory config)
  (or (host-name (string-append (basename directory) "-vm"))
      (vm-config-name config)))

(define (unique-name name taken)
  (let loop ((number 1))
    (let ((candidate (if (= number 1)
                         name
                         (format #f "~a-~a" name number))))
      (if (member candidate taken)
          (loop (+ number 1))
          candidate))))

(define (existing-directory directory)
  "Return the canonical name of DIRECTORY, which must exist."
  (if (directory-exists? directory)
      (canonicalize-path directory)
      (fail "~a is not a directory" directory)))

(define (getenv-positive-integer name default)
  "Return the positive integer in the environment variable NAME, or DEFAULT
if it is unset."
  (match (getenv name)
    (#f default)
    (value
     (let ((number (string->number value)))
       (if (and (exact-integer? number) (positive? number))
           number
           (fail "~a is not a positive integer: ~a" name value))))))

(define* (volatile-vm? #:key stateless? volatile? persistent? volatile-field?)
  "Return true if a VM gets an empty /work instead of the project."
  (cond ((and volatile? persistent?)
         (fail "--volatile or --persistent, not both"))
        (persistent? #f)
        (volatile? #t)
        (else (or stateless? volatile-field?))))

(define (parse-invocation args config)
  "Return the invocation of the VM CONFIG that the command line ARGS, the
environment and the terminal describe."
  (let* ((flags requested-directory requested-command (parse-arguments args))
         (flag? (lambda (flag) (and (member flag flags) #t)))
         (stateless? (or (vm-config-stateless? config) (flag? "--stateless")))
         (directory (existing-directory requested-directory)))
    (invocation
      (directory directory)
      (name (or (and=> (flag-value "name" flags) host-name)
                (default-name directory config)))
      (command (if (null? requested-command)
                   (vm-config-command config)
                   requested-command))
      (stateless? stateless?)
      (volatile? (volatile-vm? #:stateless? stateless?
                               #:volatile? (flag? "--volatile")
                               #:persistent? (flag? "--persistent")
                               #:volatile-field? (vm-config-volatile? config)))
      (policy (match (list (flag? "--merge") (flag? "--discard"))
                ((#f #f) 'ask)
                ((#t #f) 'merge)
                ((#f #t) 'discard)
                (_ (fail "--merge or --discard, not both"))))
      (interactive? (isatty? (current-input-port)))
      (memory (getenv-positive-integer "VM_MEMORY"
                                       (vm-config-memory-size config)))
      (cpus (getenv-positive-integer "VM_CPUS"
                                     (vm-config-cpu-count config)))
      (boot-timeout (getenv-positive-integer "VM_BOOT_TIMEOUT" 120))
      (cache (or (getenv "VM_FS_CACHE") "auto"))
      (serial (getenv "VM_SERIAL")))))
