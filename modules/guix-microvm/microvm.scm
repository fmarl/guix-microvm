;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm microvm)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module ((guix diagnostics) #:select (formatted-message))
  #:use-module (guix gexp)
  #:use-module ((guix i18n) #:select (G_))
  #:use-module (guix modules)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module ((gnu packages base) #:select (coreutils))
  #:use-module (gnu packages containers)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages version-control)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module ((gnu services configuration) #:select (list-of))
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (guix-microvm locked)
  #:use-module (guix-microvm packages virtiofsd)
  #:use-module (guix-microvm base)
  #:export (microvm
            microvm?
            microvm-operating-system
            microvm-command
            microvm-wayland?
            microvm-stateless?
            microvm-volatile?
            microvm-manifest
            microvm-ports
            microvm-secrets
            microvm-protected-files
            microvm-usb?
            microvm-network?
            microvm-memory-size
            microvm-cpu-count))

(define (validator field predicate expected)
  "Return a sanitizer that returns values satisfying PREDICATE and raises an
error naming FIELD and EXPECTED for others."
  (lambda (value)
    (if (predicate value)
        value
        (raise-exception
         (formatted-message (G_ "~a: expected ~a, got ~s")
                            field expected value)))))

(define (port-number? value)
  (and (exact-integer? value) (<= 1 value 65535)))

(define (forwarded-port? value)
  (match value
    (((? port-number?) . (? port-number?)) #t)
    (port (port-number? port))))

(define (positive-integer? value)
  (and (exact-integer? value) (positive? value)))

(define (relative-file-name? value)
  (and (string? value)
       (not (any (lambda (component)
                   (member component '("" "." "..")))
                 (string-split value #\/)))))

(define-record-type* <microvm> microvm make-microvm
  microvm?
  (operating-system microvm-operating-system) ;<operating-system>
  (command          microvm-command
                    (default '())
                    (sanitize (validator 'command (list-of string?)
                                         "a list of strings")))
  (wayland?         microvm-wayland?
                    (default #f))
  (stateless?       microvm-stateless?
                    (default #f))
  (volatile?        microvm-volatile?
                    (default #f))
  (manifest         microvm-manifest          ;<manifest> | #f
                    (default #f))
  (ports            microvm-ports
                    (default '())
                    (sanitize (validator 'ports (list-of forwarded-port?)
                                         "a list of PORT or (HOST . GUEST)")))
  (secrets          microvm-secrets
                    (default '())
                    (sanitize (validator 'secrets (list-of string?)
                                         "a list of variable names")))
  (protected-files  microvm-protected-files
                    (default '())
                    (sanitize (validator 'protected-files
                                         (list-of relative-file-name?)
                                         "a list of relative file names")))
  (usb?             microvm-usb?
                    (default #f))
  (network?         microvm-network?
                    (default #t))
  (memory-size      microvm-memory-size       ;MiB
                    (default 4096)
                    (sanitize (validator 'memory-size positive-integer?
                                         "a positive integer")))
  (cpu-count        microvm-cpu-count
                    (default 4)
                    (sanitize (validator 'cpu-count positive-integer?
                                         "a positive integer"))))

(define (guest-configuration os)
  "Return the 'microvm-guest-service-type' configuration of OS."
  (match (find (lambda (service)
                 (eq? (service-kind service) microvm-guest-service-type))
               (operating-system-user-services os))
    (#f (raise-exception
         (formatted-message
          (G_ "~a: the system lacks 'microvm-guest-service-type'")
          (operating-system-host-name os))))
    (service (service-value service))))

(define (passt-network-options network name-server)
  "Return passt options to serve NETWORK, a <static-networking> with one
address and route, and DNS at NAME-SERVER."
  (match (list (static-networking-addresses network)
               (static-networking-routes network))
    (((address) (route))
     (match (string-split (network-address-value address) #\/)
       ((ip prefix-length)
        (list "--address" ip "--netmask" prefix-length
              "--gateway" (network-route-gateway route)
              "--dns-forward" name-server))))
    (_ (raise-exception
        (formatted-message
         (G_ "the microvm network needs one address and route"))))))

(define (passt-port-options port)
  "Return passt options to forward PORT, a number or a host and guest pair,
from the host's loopback to the guest."
  (match port
    ((host . guest)
     (list "--tcp-ports" (format #f "127.0.0.1/~a:~a" host guest)))
    (port
     (list "--tcp-ports" (format #f "127.0.0.1/~a" port)))))

(define (store-items objects)
  "Return a file listing the closure of OBJECTS."
  (let ((graphs (map (lambda (index)
                       (string-append "graph-" (number->string index)))
                     (iota (length objects)))))
    (computed-file
     "store-items"
     (with-extensions (list guile-gcrypt)
       (with-imported-modules (source-module-closure
                               '((guix build store-copy)))
         #~(begin
             (use-modules (guix build store-copy)
                          (srfi srfi-1))
             (call-with-output-file #$output
               (lambda (port)
                 (for-each (lambda (item)
                             (display item port)
                             (newline port))
                           (delete-duplicates
                            (append-map (lambda (graph)
                                          (map store-info-item
                                               (call-with-input-file graph
                                                 read-reference-graph)))
                                        '#$graphs))))))))
     #:options `(#:references-graphs ,(map list graphs objects)))))

(define (build-module? name)
  (match name
    (('guix-microvm 'build _ ...) #t)
    (_ (guix-module-name? name))))

(define-syntax-rule (with-build-modules exp)
  (with-imported-modules (source-module-closure
                          '((guix-microvm build microvm))
                          #:select? build-module?)
    exp))

(define (namespace-wrapper name module setup)
  "Return the program NAME that applies SETUP, a procedure of MODULE, to its
arguments up to \"--\" and then executes the command after them."
  (program-file
   name
   (with-build-modules
    #~(begin
        (use-modules (ice-9 match)
                     (srfi srfi-1)
                     (srfi srfi-26)
                     (srfi srfi-71))
        (let ((arguments rest (break (cut string=? "--" <>)
                                     (cdr (command-line)))))
          (match rest
            (("--" program args ...)
             (apply (@ #$module #$setup) arguments)
             (apply execl program program args))))))))

(define mount-store
  (namespace-wrapper "mount-store" '(guix-microvm build shares)
                     'mount-store-items))

(define mount-overlay
  (namespace-wrapper "mount-overlay" '(guix-microvm build layer)
                     'mount-overlay))

(define (microvm-profile vm)
  (and=> (microvm-manifest vm)
         (lambda (manifest)
           (profile (content manifest)))))

(define (microvm-store-roots vm os profile)
  (filter identity (list os profile (and (microvm-wayland? vm) waypipe))))

(define (check-microvm vm)
  "Raise an error if fields of VM contradict each other."
  (when (and (not (microvm-network? vm))
             (pair? (microvm-ports vm)))
    (raise-exception
     (formatted-message
      (G_ "~a: ports need a network")
      (operating-system-host-name (microvm-operating-system vm))))))

(define (microvm-network-options vm guest)
  "Return passt options for the network of GUEST, VM's guest configuration,
and for VM's ports, or #f if VM has no network."
  (and (microvm-network? vm)
       (append (passt-network-options
                (microvm-guest-configuration-network guest)
                (microvm-guest-configuration-name-server guest))
               (append-map passt-port-options (microvm-ports vm)))))

(define (microvm-launcher vm)
  "Return the launcher of VM.  run-NAME [DIR] [-- COMMAND...] boots VM,
shares DIR at /work and runs COMMAND there."
  (check-microvm vm)
  (let* ((os (microvm-operating-system vm))
         (name (operating-system-host-name os))
         (root (file-system-device (operating-system-root-file-system os)))
         (project-profile (microvm-profile vm))
         (guest (guest-configuration os))
         (wayland? (microvm-wayland? vm)))
    (program-file
     (string-append "run-" name)
     (with-build-modules
      #~(begin
          (use-modules (guix-microvm build microvm))
          (exit
           (run-microvm
            (cdr (command-line))
            (vm-config
              (name #$name)
              (command '#$(microvm-command vm))
              (stateless? #$(microvm-stateless? vm))
              (volatile? #$(microvm-volatile? vm))
              (kernel #$(operating-system-kernel-file os))
              (initrd #$(file-append os "/initrd"))
              (kernel-arguments
               (list #$@(operating-system-kernel-arguments os root)))
              (store-items #$(store-items
                              (microvm-store-roots vm os project-profile)))
              (profile #$project-profile)
              (memory-size #$(microvm-memory-size vm))
              (cpu-count #$(microvm-cpu-count vm))
              (network-options '#$(microvm-network-options vm guest))
              (secrets '#$(microvm-secrets vm))
              (protected-files '#$(microvm-protected-files vm))
              (usb? #$(microvm-usb? vm))
              (user #$(microvm-guest-configuration-user guest))
              (uid #$(microvm-guest-configuration-uid guest))
              (gid #$(microvm-guest-configuration-gid guest))
              (guest-runtime-directory
               #$(microvm-guest-runtime-directory guest))
              (ssh-port #$(microvm-guest-configuration-ssh-port guest)))
            (tools
              (qemu #$(file-append qemu-locked "/bin/qemu-system-x86_64"))
              (virtiofsd #$(file-append virtiofsd "/bin/virtiofsd"))
              (passt #$(file-append passt "/bin/passt"))
              (waypipe #$(and wayland?
                              (file-append waypipe-locked "/bin/waypipe")))
              (guest-waypipe #$(and wayland?
                                    (file-append waypipe "/bin/waypipe")))
              (ssh #$(file-append openssh "/bin/ssh"))
              (ssh-keygen #$(file-append openssh "/bin/ssh-keygen"))
              (socat #$(file-append socat "/bin/socat"))
              (git #$(file-append git-minimal "/bin/git"))
              (unshare #$(file-append util-linux "/bin/unshare"))
              (cp #$(file-append coreutils "/bin/cp"))
              (mount-store #$mount-store)
              (mount-overlay #$mount-overlay)))))))))

(define-gexp-compiler (microvm-compiler (vm <microvm>) system target)
  (lower-object (microvm-launcher vm) system #:target target))
