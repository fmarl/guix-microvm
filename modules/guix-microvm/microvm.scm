(define-module (guix-microvm microvm)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module (gnu packages containers)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (guix-microvm packages virtiofsd)
  #:use-module (guix-microvm base)
  #:export (microvm
            microvm?
            microvm-operating-system
            microvm-manifest
            microvm-ports
            microvm-secrets
            microvm-memory-size
            microvm-cpu-count
            microvm-qemu
            microvm-virtiofsd
            microvm-passt
            microvm-launcher))

(define-record-type* <microvm> microvm make-microvm
  microvm?
  (operating-system microvm-operating-system) ;<operating-system>
  (manifest         microvm-manifest          ;<manifest> | #f
                    (default #f))
  (ports            microvm-ports             ;list of PORT | (HOST . GUEST)
                    (default '()))
  (secrets          microvm-secrets           ;list of variable names
                    (default '()))
  (memory-size      microvm-memory-size       ;integer (MiB)
                    (default 4096))
  (cpu-count        microvm-cpu-count         ;integer
                    (default 4))
  (qemu             microvm-qemu              ;<package>
                    (default qemu))
  (virtiofsd        microvm-virtiofsd         ;<package>
                    (default virtiofsd))
  (passt            microvm-passt             ;<package>
                    (default passt)))

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
              "--dns-forward" name-server))))))

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

;; Run as root of a user namespace: mount store items on a tmpfs, then run a
;; program.
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

(define (microvm-launcher vm)
  "Return the launcher of VM, run-NAME [DIR] [-- COMMAND...], which boots VM,
shares DIR at /work and runs COMMAND in it, as described in README.md."
  (let* ((os (microvm-operating-system vm))
         (name (operating-system-host-name os))
         (root (file-system-device (operating-system-root-file-system os)))
         (project-profile (and=> (microvm-manifest vm)
                                 (lambda (manifest)
                                   (profile (content manifest))))))
    (program-file
     (string-append "run-" name)
     (with-build-modules
      #~(begin
          (use-modules (guix-microvm build microvm))
          (exit
           (run-microvm
            (cdr (command-line))
            #:name #$name
            #:kernel #$(operating-system-kernel-file os)
            #:initrd #$(file-append os "/initrd")
            #:kernel-arguments
            (list #$@(operating-system-kernel-arguments os root))
            #:store-items #$(store-items
                             (filter identity (list os project-profile)))
            #:profile #$project-profile
            #:memory-size #$(microvm-memory-size vm)
            #:cpu-count #$(microvm-cpu-count vm)
            #:user #$%vm-user
            #:uid #$%vm-uid
            #:gid #$%vm-gid
            #:ssh-port #$%vm-ssh-port
            #:network-options
            '#$(append (passt-network-options %vm-network %vm-name-server)
                       (append-map passt-port-options (microvm-ports vm)))
            #:secrets '#$(microvm-secrets vm)
            #:qemu #$(file-append (microvm-qemu vm)
                                  "/bin/qemu-system-x86_64")
            #:virtiofsd #$(file-append (microvm-virtiofsd vm)
                                       "/bin/virtiofsd")
            #:passt #$(file-append (microvm-passt vm) "/bin/passt")
            #:ssh #$(file-append openssh "/bin/ssh")
            #:ssh-keygen #$(file-append openssh "/bin/ssh-keygen")
            #:socat #$(file-append socat "/bin/socat")
            #:git #$(file-append git-minimal "/bin/git")
            #:unshare #$(file-append util-linux "/bin/unshare")
            #:mount-store #$mount-store)))))))

(define-gexp-compiler (microvm-compiler (vm <microvm>) system target)
  (lower-object (microvm-launcher vm) system #:target target))
