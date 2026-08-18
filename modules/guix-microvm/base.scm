(define-module (guix-microvm base)
  #:use-module (srfi srfi-1)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (gnu)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services ssh)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages ssh)
  #:use-module (guix-microvm kernel)
  #:export (microvm-guest-configuration
            microvm-guest-configuration?
            microvm-guest-user
            microvm-guest-uid
            microvm-guest-gid
            microvm-guest-ssh-port
            microvm-guest-network
            microvm-guest-name-server
            microvm-guest-runtime-directory
            microvm-guest-service-type
            %microvm-base-services
            %base-vm))

(define %default-network
  (static-networking
    (addresses (list (network-address
                       (device "eth0")
                       (value "10.0.2.15/24"))))
    (routes (list (network-route
                    (destination "default")
                    (gateway "10.0.2.2"))))))

(define-record-type* <microvm-guest-configuration>
  microvm-guest-configuration make-microvm-guest-configuration
  microvm-guest-configuration?
  (user     microvm-guest-user            ;string
            (default "user"))
  (uid      microvm-guest-uid             ;integer
            (default 1000))
  (gid      microvm-guest-gid             ;integer
            (default 1000))
  ;; Ports below 1024 need CAP_NET_BIND_SERVICE, which socat, as nobody,
  ;; lacks.
  (ssh-port microvm-guest-ssh-port        ;integer
            (default 2222))
  ;; One address and route, as passt serves it.
  (network  microvm-guest-network         ;<static-networking>
            (default %default-network))
  (name-server microvm-guest-name-server  ;string
               (default "10.0.2.3")))

(define (microvm-guest-runtime-directory config)
  (string-append "/run/user/" (number->string (microvm-guest-uid config))))

(define (kernel-option name)
  "Return a gexp for VALUE of NAME=VALUE on the kernel command line, or #f."
  #~(let ((prefix #$(string-append name "=")))
      (any (lambda (arg)
             (and (string-prefix? prefix arg)
                  (string-drop arg (string-length prefix))))
           (string-tokenize
            (call-with-input-file "/proc/cmdline" get-string-all)))))

(define %kernel-option-modules
  `((srfi srfi-1) (ice-9 textual-ports) ,@%default-modules))

(define (ssh-vsock-service port)
  "Return the service forwarding vsock PORT to the SSH daemon."
  (shepherd-service
    (provision '(ssh-vsock))
    (requirement '(ssh-daemon work-overlay))
    (start #~(make-forkexec-constructor
              (list #$(file-append socat "/bin/socat")
                    #$(string-append "VSOCK-LISTEN:" (number->string port)
                                     ",reuseaddr,fork")
                    "TCP:127.0.0.1:22")
              #:user "nobody" #:group "nogroup"))
    (stop #~(make-kill-destructor))))

;; The key comes from the kernel command line, not the system.
(define (ssh-authorized-key-service user)
  "Return the service that authorizes the launcher's key for USER."
  (shepherd-service
    (provision '(ssh-authorized-key))
    (one-shot? #t)
    (modules %kernel-option-modules)
    (start #~(lambda _
               (let ((key #$(kernel-option "guix-microvm.ssh-key"))
                     (file #$(string-append "/etc/ssh/authorized_keys.d/"
                                            user)))
                 (when key
                   (call-with-output-file file
                     (lambda (port)
                       (format port "ssh-ed25519 ~a~%" key)))
                   (chmod file #o444))
                 #t)))))

;; The launcher shares /work read-only with a stateless VM.
(define work-overlay-service
  (shepherd-service
    (provision '(work-overlay))
    (requirement '(file-system-/work))
    (one-shot? #t)
    (modules %kernel-option-modules)
    (start #~(lambda _
               (when #$(kernel-option "guix-microvm.stateless")
                 (let ((upper "/run/work-overlay/upper")
                       (work "/run/work-overlay/work")
                       (lower (stat "/work")))
                   (mkdir-p upper)
                   (mkdir-p work)
                   ;; The overlay's root takes after UPPER.
                   (chown upper (stat:uid lower) (stat:gid lower))
                   (chmod upper (stat:perms lower))
                   (mount "overlay" "/work" "overlay" 0
                          (string-append "lowerdir=/work,upperdir="
                                         upper ",workdir=" work))))
               #t))))

(define (guest-shepherd-services config)
  (match-record config <microvm-guest-configuration> (user ssh-port)
    (list work-overlay-service
          (ssh-vsock-service ssh-port)
          (ssh-authorized-key-service user))))

;; The root file system is an empty tmpfs.  One host key type is enough: the
;; launcher does not check it.
(define (guest-activation config)
  (match-record config <microvm-guest-configuration> (uid gid)
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (for-each mkdir-p '("/var/log" "/var/empty" "/var/db"
                              "/var/guix/gcroots" "/mnt" "/bin" "/home"))
          (for-each (lambda (directory)
                      (mkdir-p directory)
                      (chmod directory #o1777))
                    '("/tmp" "/var/tmp" "/var/lock"))
          (let ((runtime #$(microvm-guest-runtime-directory config)))
            (mkdir-p runtime)
            (chown runtime #$uid #$gid)
            (chmod runtime #o700))
          (mkdir-p "/etc/ssh")
          (invoke #$(file-append openssh "/bin/ssh-keygen") "-q"
                  "-t" "ed25519" "-N" ""
                  "-f" "/etc/ssh/ssh_host_ed25519_key")))))

;; For FIDO keys among the USB devices of the VM.
(define (guest-udev-rules config)
  (list (udev-rule "90-guix-microvm.rules"
                   (format #f "SUBSYSTEM==\"hidraw\", MODE=\"0660\", \
GROUP=\"~a\"~%"
                           (microvm-guest-user config)))))

(define (guest-accounts config)
  (match-record config <microvm-guest-configuration> (user uid gid)
    (list (user-group
            (name user)
            (id gid))
          (user-account
            (name user)
            (comment "VM user")
            (uid uid)
            (group user)
            (supplementary-groups '())
            (home-directory (string-append "/home/" user))))))

(define (guest-networks config)
  (match-record config <microvm-guest-configuration> (network name-server)
    (list (static-networking
            (inherit network)
            (name-servers (list name-server))))))

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

(define microvm-guest-service-type
  (service-type
    (name 'microvm-guest)
    (extensions
     (list (service-extension shepherd-root-service-type
                              guest-shepherd-services)
           (service-extension activation-service-type guest-activation)
           (service-extension account-service-type guest-accounts)
           (service-extension static-networking-service-type
                              guest-networks)
           (service-extension etc-service-type
                              (const `(("profile.d/guix-microvm-profile.sh"
                                        ,project-profile))))
           (service-extension udev-service-type guest-udev-rules)
           (service-extension session-environment-service-type
                              (lambda (config)
                                `(("XDG_RUNTIME_DIR"
                                   . ,(microvm-guest-runtime-directory
                                       config)))))))
    (default-value (microvm-guest-configuration))
    (description "Make the system a guix-microvm guest: accept commands over
SSH on vsock as the configured user, and overlay /work with a tmpfs in
stateless VMs.")))

(define %microvm-base-services
  (cons* (service microvm-guest-service-type)
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

(define* (virtiofs tag mount-point #:key read-only? needed-for-boot?)
  (file-system
    (mount-point mount-point)
    (device tag)
    (type "virtiofs")
    (flags (if read-only? '(read-only) '()))
    (needed-for-boot? needed-for-boot?)
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
                        (virtiofs "store" "/gnu/store"
                                  #:read-only? #t #:needed-for-boot? #t)
                        (virtiofs "work" "/work")
                        (virtiofs "home" "/home")
                        %pseudo-terminal-file-system
                        %shared-memory-file-system))
    (services %microvm-base-services)))
