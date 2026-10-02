(define-module (guix-microvm base)
  #:use-module (srfi srfi-1)
  #:use-module (guix gexp)
  #:use-module (gnu)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services ssh)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages ssh)
  #:use-module (guix-microvm kernel)
  #:export (%vm-user
            %vm-uid
            %vm-gid
            %vm-ssh-port
            %vm-name-server
            %vm-network
            %base-vm))

(define %vm-user "user")
(define %vm-uid 1000)
(define %vm-gid 1000)

;; Ports below 1024 need CAP_NET_BIND_SERVICE, which socat, as nobody, lacks.
(define %vm-ssh-port 2222)

(define %vm-name-server "10.0.2.3")
(define %vm-network
  (static-networking
    (addresses (list (network-address
                       (device "eth0")
                       (value "10.0.2.15/24"))))
    (routes (list (network-route
                    (destination "default")
                    (gateway "10.0.2.2"))))
    (name-servers (list %vm-name-server))))

(define (kernel-option name)
  "Return a gexp for the value of NAME=VALUE on the kernel command line, or
#f."
  #~(let ((prefix #$(string-append name "=")))
      (any (lambda (arg)
             (and (string-prefix? prefix arg)
                  (string-drop arg (string-length prefix))))
           (string-tokenize
            (call-with-input-file "/proc/cmdline" get-string-all)))))

;; The key comes from the kernel command line, not the system.
(define ssh-services
  (list (shepherd-service
          (provision '(ssh-vsock))
          (requirement '(ssh-daemon))
          (start #~(make-forkexec-constructor
                    (list #$(file-append socat "/bin/socat")
                          #$(string-append "VSOCK-LISTEN:"
                                           (number->string %vm-ssh-port)
                                           ",reuseaddr,fork")
                          "TCP:127.0.0.1:22")
                    #:user "nobody" #:group "nogroup"))
          (stop #~(make-kill-destructor)))
        (shepherd-service
          (provision '(ssh-authorized-key))
          (one-shot? #t)
          (modules `((srfi srfi-1) (ice-9 textual-ports)
                     ,@%default-modules))
          (start #~(lambda _
                     (let ((key #$(kernel-option "guix-microvm.ssh-key"))
                           (file #$(string-append "/etc/ssh/authorized_keys.d/"
                                                  %vm-user)))
                       (when key
                         (call-with-output-file file
                           (lambda (port)
                             (format port "ssh-ed25519 ~a~%" key)))
                         (chmod file #o444))
                       #t))))))

;; The root file system is an empty tmpfs.
(define root-directories
  (with-imported-modules '((guix build utils))
    #~(begin
        (use-modules (guix build utils))
        (for-each mkdir-p '("/var/log" "/var/empty" "/var/db"
                            "/var/guix/gcroots" "/mnt" "/bin" "/home"))
        (for-each (lambda (directory)
                    (mkdir-p directory)
                    (chmod directory #o1777))
                  '("/tmp" "/var/tmp" "/var/lock"))
        (let ((runtime #$(string-append "/run/user/"
                                        (number->string %vm-uid))))
          (mkdir-p runtime)
          (chown runtime #$%vm-uid #$%vm-gid)
          (chmod runtime #o700)))))

;; One key type is enough: the launcher does not check it.
(define ssh-host-key
  (with-imported-modules '((guix build utils))
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p "/etc/ssh")
        (invoke #$(file-append openssh "/bin/ssh-keygen") "-q" "-t" "ed25519"
                "-N" "" "-f" "/etc/ssh/ssh_host_ed25519_key"))))

(define project-profile
  (plain-file "guix-microvm-profile.sh" "\
if [ -n \"$GUIX_MICROVM_PROFILE\" ]
then
  GUIX_PROFILE=\"$GUIX_MICROVM_PROFILE\"
  . \"$GUIX_PROFILE/etc/profile\"
  unset GUIX_PROFILE
  export GUIX_ENVIRONMENT=\"$GUIX_MICROVM_PROFILE\"
fi
"))

(define base-services
  (cons* (simple-service 'root-directories activation-service-type
                         root-directories)
         (simple-service 'ssh shepherd-root-service-type ssh-services)
         (simple-service 'ssh-host-key activation-service-type ssh-host-key)
         (simple-service 'network static-networking-service-type
                         (list %vm-network))
         (simple-service 'project-profile etc-service-type
                         `(("profile.d/guix-microvm-profile.sh"
                            ,project-profile)))
         (simple-service 'runtime-directory session-environment-service-type
                         `(("XDG_RUNTIME_DIR"
                            . ,(string-append "/run/user/"
                                              (number->string %vm-uid)))))
         (service openssh-service-type
                  (openssh-configuration
                    (password-authentication? #f)
                    (permit-root-login #f)
                    (challenge-response-authentication? #f)
                    (x11-forwarding? #f)
                    (allow-agent-forwarding? #f)
                    ;; For the Wayland socket; only the launcher has the key.
                    (allow-tcp-forwarding? #t)
                    (generate-host-keys? #f)
                    (extra-content "\
HostKey /etc/ssh/ssh_host_ed25519_key
AcceptEnv *\n")))
         (service special-files-service-type
                  `(("/bin/sh" ,(file-append bash "/bin/sh"))
                    ("/usr/bin/env" ,(file-append coreutils "/bin/env"))))
         (modify-services %base-services
           (delete special-files-service-type)
           (delete virtual-terminal-service-type)
           (delete console-font-service-type)
           (delete mingetty-service-type)
           (delete guix-service-type)
           (delete nscd-service-type)
           (delete log-rotation-service-type)
           (delete log-cleanup-service-type))))

(define (virtiofs tag mount-point . flags)
  (file-system
    (mount-point mount-point)
    (device tag)
    (type "virtiofs")
    (flags flags)
    (needed-for-boot? (string=? mount-point "/gnu/store"))
    (create-mount-point? #t)
    (check? #f)))

(define %base-vm
  (operating-system
    (host-name "vm")
    (locale "en_US.utf8")
    (timezone "Europe/Berlin")
    (kernel linux-microvm)
    ;; Name the NIC eth0, it has no PCI slot to name it after.
    (kernel-arguments (list "net.ifnames=0"))
    (initrd-modules '())
    (firmware '())
    (bootloader (bootloader-configuration
                  (bootloader grub-bootloader)
                  (targets '("/dev/null"))))
    (file-systems (list (file-system
                          (mount-point "/")
                          (device "none")
                          (type "tmpfs")
                          (options "mode=755")
                          (check? #f))
                        (virtiofs "store" "/gnu/store" 'read-only)
                        (virtiofs "work" "/work")
                        (virtiofs "home" "/home")
                        %pseudo-terminal-file-system
                        %shared-memory-file-system))
    (groups (cons (user-group
                    (name %vm-user)
                    (id %vm-gid))
                  %base-groups))
    (users (cons (user-account
                   (name %vm-user)
                   (comment "VM user")
                   (uid %vm-uid)
                   (group %vm-user)
                   (supplementary-groups '())
                   (home-directory (string-append "/home/" %vm-user)))
                 %base-user-accounts))
    (services base-services)))
