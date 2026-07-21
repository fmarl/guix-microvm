(define-module (guix-microvm microvm)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module ((guix diagnostics) #:select (formatted-message))
  #:use-module (guix gexp)
  #:use-module ((guix i18n) #:select (G_))
  #:use-module (guix modules)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module (gnu packages containers)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (guix-microvm packages virtiofsd)
  #:use-module (guix-microvm base)
  #:export (microvm
            microvm?
            microvm-operating-system
            microvm-command
            microvm-wayland?
            microvm-stateless?
            microvm-manifest
            microvm-ports
            microvm-secrets
            microvm-usb?
            microvm-memory-size
            microvm-cpu-count))

(define-record-type* <microvm> microvm make-microvm
  microvm?
  (operating-system microvm-operating-system) ;<operating-system>
  (command          microvm-command           ;list of strings
                    (default '()))
  (wayland?         microvm-wayland?          ;Boolean
                    (default #f))
  (stateless?       microvm-stateless?        ;Boolean
                    (default #f))
  (manifest         microvm-manifest          ;<manifest> | #f
                    (default #f))
  (ports            microvm-ports             ;list of PORT | (HOST . GUEST)
                    (default '()))
  (secrets          microvm-secrets           ;list of variable names
                    (default '()))
  (usb?             microvm-usb?              ;Boolean
                    (default #f))
  (memory-size      microvm-memory-size       ;integer (MiB)
                    (default 4096))
  (cpu-count        microvm-cpu-count         ;integer
                    (default 4)))

(define (guest-configuration os)
  "Return the configuration of the microvm guest service of OS."
  (match (find (lambda (service)
                 (eq? (service-kind service) microvm-guest-service-type))
               (operating-system-user-services os))
    (#f (raise-exception
         (formatted-message
          (G_ "~a: the system lacks 'microvm-guest-service-type'")
          (operating-system-host-name os))))
    (service (service-value service))))

(define (passt-network-options network name-server)
  "Return the options for passt to serve NETWORK, a <static-networking> with
one address and route, and to answer DNS queries sent to NAME-SERVER."
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
  "Return the options for passt to forward PORT, a port number or a pair of
host and guest port numbers, from the host's loopback to the guest."
  (match port
    ((host . guest)
     (list "--tcp-ports" (format #f "127.0.0.1/~a:~a" host guest)))
    (port
     (list "--tcp-ports" (format #f "127.0.0.1/~a" port)))))

(define (store-items objects)
  "Return a file listing the store items OBJECTS refer to, recursively."
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

(define mount-store
  (program-file
   "mount-store"
   (with-build-modules
    #~(begin
        (use-modules (guix-microvm build microvm)
                     (ice-9 match))
        (match (cdr (command-line))
          ((items root program args ...)
           (mount-store-items items root)
           (apply execl program program args)))))))

(define (microvm-profile vm)
  "Return the profile of VM's manifest, or #f."
  (and=> (microvm-manifest vm)
         (lambda (manifest)
           (profile (content manifest)))))

(define (microvm-store-roots vm os profile)
  "Return the objects whose closures VM, running OS, sees in its store: OS,
PROFILE, if any, and waypipe if VM is graphical."
  (filter identity (list os profile (and (microvm-wayland? vm) waypipe))))

(define (microvm-network-options vm guest)
  "Return the options for passt to serve the network of GUEST, the
configuration of VM's guest service, and forward VM's ports."
  (append (passt-network-options (microvm-guest-network guest)
                                 (microvm-guest-name-server guest))
          (append-map passt-port-options (microvm-ports vm))))

(define (microvm-launcher vm)
  "Return the launcher of VM, run-NAME [DIR] [-- COMMAND...], which boots VM,
shares DIR at /work and runs COMMAND in it, as described in README.md."
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
            #:name #$name
            #:default-command '#$(microvm-command vm)
            #:stateless? #$(microvm-stateless? vm)
            #:kernel #$(operating-system-kernel-file os)
            #:initrd #$(file-append os "/initrd")
            #:kernel-arguments
            (list #$@(operating-system-kernel-arguments os root))
            #:store-items #$(store-items
                             (microvm-store-roots vm os project-profile))
            #:profile #$project-profile
            #:memory-size #$(microvm-memory-size vm)
            #:cpu-count #$(microvm-cpu-count vm)
            #:user #$(microvm-guest-user guest)
            #:uid #$(microvm-guest-uid guest)
            #:gid #$(microvm-guest-gid guest)
            #:ssh-port #$(microvm-guest-ssh-port guest)
            #:network-options
            '#$(microvm-network-options vm guest)
            #:secrets '#$(microvm-secrets vm)
            #:usb? #$(microvm-usb? vm)
            #:qemu #$(file-append qemu "/bin/qemu-system-x86_64")
            #:virtiofsd #$(file-append virtiofsd "/bin/virtiofsd")
            #:passt #$(file-append passt "/bin/passt")
            #:waypipe #$(and wayland? (file-append waypipe "/bin/waypipe"))
            #:ssh #$(file-append openssh "/bin/ssh")
            #:ssh-keygen #$(file-append openssh "/bin/ssh-keygen")
            #:socat #$(file-append socat "/bin/socat")
            #:git #$(file-append git-minimal "/bin/git")
            #:unshare #$(file-append util-linux "/bin/unshare")
            #:mount-store #$mount-store)))))))

(define-gexp-compiler (microvm-compiler (vm <microvm>) system target)
  (lower-object (microvm-launcher vm) system #:target target))
