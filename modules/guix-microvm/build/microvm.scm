;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build microvm)
  #:use-module (guix build utils)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-71)
  #:use-module (web uri)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build process)
  #:use-module (guix-microvm build shares)
  #:use-module (guix-microvm build ssh)
  #:export (vm-config
            tools
            check-shareable
            runtime-directory
            %vm-directory-prefix
            vm-info-file
            qmp-socket-file
            run-microvm))

(define-record-type* <vm-config> vm-config make-vm-config
  vm-config?
  (name             vm-config-name)
  (command          vm-config-command)
  (stateless?       vm-config-stateless?)
  (kernel           vm-config-kernel)
  (initrd           vm-config-initrd)
  (kernel-arguments vm-config-kernel-arguments)
  (store-items      vm-config-store-items)      ;file listing them
  (profile          vm-config-profile)          ;file name | #f
  (memory-size      vm-config-memory-size)      ;MiB
  (cpu-count        vm-config-cpu-count)
  (network-options  vm-config-network-options)  ;passt's | #f
  (secrets          vm-config-secrets)
  (read-only-files  vm-config-read-only-files)
  (usb?             vm-config-usb?)
  (user             vm-config-user)
  (uid              vm-config-uid)
  (gid              vm-config-gid)
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
  (mount-store     tools-mount-store)
  (mount-read-only tools-mount-read-only))

(define-record-type* <invocation> invocation make-invocation
  invocation?
  (directory    invocation-directory)           ;canonical
  (command      invocation-command)
  (stateless?   invocation-stateless?)
  (share-home?  invocation-share-home?)
  (memory       invocation-memory)              ;MiB
  (cpus         invocation-cpus)
  (boot-timeout invocation-boot-timeout)        ;seconds
  (cache        invocation-cache)
  (serial       invocation-serial))             ;QEMU's -serial | #f

(define (parse-arguments args)
  "Split ARGS into flags, directory and command, returned as three values."
  (match args
    (((and flag (or "--share-home" "--stateless")) rest ...)
     (let ((flags directory command (parse-arguments rest)))
       (values (cons flag flags) directory command)))
    (() (values '() "." '()))
    (("--" command ...) (values '() "." command))
    ((directory) (values '() directory '()))
    ((directory "--" command ...) (values '() directory command))
    (_ (usage-error "[--share-home] [--stateless] [DIR] [-- COMMAND...]"))))

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

(define (parse-invocation args config)
  "Return the invocation of the VM CONFIG that the command line ARGS and the
environment describe."
  (let ((flags requested-directory requested-command (parse-arguments args)))
    (invocation
      (directory (existing-directory requested-directory))
      (command (if (null? requested-command)
                   (vm-config-command config)
                   requested-command))
      (stateless? (or (vm-config-stateless? config)
                      (and (member "--stateless" flags) #t)))
      (share-home? (and (member "--share-home" flags) #t))
      (memory (getenv-positive-integer "VM_MEMORY"
                                       (vm-config-memory-size config)))
      (cpus (getenv-positive-integer "VM_CPUS"
                                     (vm-config-cpu-count config)))
      (boot-timeout (getenv-positive-integer "VM_BOOT_TIMEOUT" 120))
      (cache (or (getenv "VM_FS_CACHE") "auto"))
      (serial (getenv "VM_SERIAL")))))

(define (home-directory)
  (canonicalize-path (getenv "HOME")))

(define (contains-home? directory home)
  "Return true if DIRECTORY is HOME or one of its parents."
  (or (string=? directory "/")
      (string=? directory home)
      (string-prefix? (string-append directory "/") home)))

(define (check-shareable directory share-home?)
  "Fail if DIRECTORY contains the home directory, unless SHARE-HOME?."
  (when (and (not share-home?)
             (contains-home? directory (home-directory)))
    (fail "not sharing ~a, which contains the home directory, without \
--share-home" directory)))

(define (data-directory home)
  (string-append (or (getenv "XDG_DATA_HOME")
                     (string-append home "/.local/share"))
                 "/guix-microvm"))

(define (vm-files data tmp name directory stateless?)
  "Return the home, console log and SSH key of VM NAME for DIRECTORY.  They
are in DATA, or in TMP if STATELESS?."
  (if stateless?
      (values (string-append tmp "/home")
              (string-append tmp "/console.log")
              (string-append tmp "/id_ed25519"))
      (let ((home (string-append data "/" name "/" (uri-encode directory))))
        (values home
                (string-append home ".log")
                (string-append data "/ssh/id_ed25519")))))

(define (secrets-directory data name)
  (string-append data "/" name "/secrets"))

(define (runtime-directory)
  (or (getenv "XDG_RUNTIME_DIR") "/tmp"))

(define %vm-directory-prefix "guix-microvm.")

(define (call-with-temporary-directory parent proc)
  "Call PROC with a new directory in PARENT.  Delete it when PROC returns or
exits."
  (let ((directory (mkdtemp (string-append parent "/" %vm-directory-prefix
                                           "XXXXXX"))))
    (dynamic-wind
      (const #t)
      (cut proc directory)
      (cut delete-file-recursively directory))))

(define (qmp-socket-file directory)
  (socket-file directory "qmp"))

(define (network-socket-file directory config)
  (and (vm-config-network-options config)
       (socket-file directory "network")))

(define (vm-info-file directory)
  (string-append directory "/vm"))

(define (call-with-vm-info directory info thunk)
  "Write INFO to the info file in DIRECTORY, locked while THUNK runs."
  (call-with-output-file (vm-info-file directory)
    (lambda (port)
      (flock port LOCK_EX)
      (write info port)
      (force-output port)
      (thunk))))

(define (guest-runtime-directory uid)
  ;; Same as 'microvm-guest-runtime-directory' in (guix-microvm base).
  (format #f "/run/user/~a" uid))

;; Only the guest user can write there, so other guest users cannot fake it.
(define (guest-status-file uid)
  (string-append (guest-runtime-directory uid) "/guix-microvm-status"))

(define (git-config git directory name)
  (let* ((port (with-error-to-port (null-port)
                 (cut open-pipe* OPEN_READ git "-C" directory "config" name)))
         (value (string-trim-right (get-string-all port))))
    (and (eqv? 0 (status:exit-val (close-pipe port)))
         (not (string-null? value))
         value)))

(define (git-identity git directory)
  "Return GIT_AUTHOR_* and GIT_COMMITTER_* as an alist, from the environment
or else DIRECTORY's Git configuration."
  (let ((name (or (getenv "GIT_AUTHOR_NAME")
                  (git-config git directory "user.name")))
        (email (or (getenv "GIT_AUTHOR_EMAIL")
                   (git-config git directory "user.email"))))
    (filter cdr
            `(("GIT_AUTHOR_NAME" . ,name)
              ("GIT_AUTHOR_EMAIL" . ,email)
              ("GIT_COMMITTER_NAME" . ,(or (getenv "GIT_COMMITTER_NAME") name))
              ("GIT_COMMITTER_EMAIL"
               . ,(or (getenv "GIT_COMMITTER_EMAIL") email))))))

(define (read-secrets directory names)
  "Return the existing files NAMES in DIRECTORY as an alist of names and
contents."
  (filter-map (lambda (name)
                (let ((file (string-append directory "/" name)))
                  (and (file-exists? file)
                       (cons name
                             (string-trim-right
                              (call-with-input-file file get-string-all))))))
              names))

(define (environment-with variables)
  "Return (environ) with VARIABLES, an alist of names and values, set."
  (define (entry-name entry)
    (string-take entry (or (string-index entry #\=) (string-length entry))))

  (append (map (match-lambda
                 ((name . value) (string-append name "=" value)))
               variables)
          (remove (lambda (entry)
                    (assoc (entry-name entry) variables))
                  (environ))))

(define (vm-variables git directory profile secrets-directory secrets)
  "Return the VM's variables as an alist: the Git identity for DIRECTORY,
PROFILE if any, and SECRETS from SECRETS-DIRECTORY."
  (append (git-identity git directory)
          (if profile
              `(("GUIX_MICROVM_PROFILE" . ,profile))
              '())
          (read-secrets secrets-directory secrets)))

(define (send-env-patterns secrets)
  "Return the SendEnv patterns for ssh, SECRETS included."
  `("LANG" "COLORTERM" "GIT_AUTHOR_*" "GIT_COMMITTER_*" "GUIX_MICROVM_PROFILE"
    ,@secrets))

(define (vm-ssh-spawner config tools data directory key known-hosts cid)
  "Return the procedure that runs commands in the VM CONFIG over SSH."
  (match-record config <vm-config> (name user ssh-port profile secrets)
    (ssh-spawner (tools-ssh tools) (string-append user "@" name)
                 #:key key #:known-hosts known-hosts
                 #:socat (tools-socat tools) #:cid cid
                 #:port ssh-port
                 #:send-env (send-env-patterns secrets)
                 #:environment
                 (environment-with
                  (vm-variables (tools-git tools) directory profile
                                (secrets-directory data name) secrets)))))

;; vsock CIDs are global on the host.  The PID keeps them unique among
;; launchers, and the offset keeps them above the CIDs other hypervisors
;; assign.
(define (vm-cid)
  (number->string (+ #x40000000 (getpid))))

(define (passt-server passt socket options)
  (server passt
          `("--foreground" "--quiet" "--one-off" "--ipv4-only" "--no-dhcp"
            "--no-map-gw" "--socket" ,socket ,@options)
          socket))

(define (network-servers directory config tools)
  (match (network-socket-file directory config)
    (#f '())
    (socket (list (passt-server (tools-passt tools) socket
                                (vm-config-network-options config))))))

(define (serial-options log serial)
  "Return QEMU options for the serial console: SERIAL if set, else append to
LOG."
  (match serial
    (#f `("-chardev" ,(string-append "file,id=serial,path=" log ",append=on")
          "-serial" "chardev:serial"))
    (serial `("-serial" ,serial))))

(define* (qemu-arguments #:key kernel initrd kernel-arguments memory cpus cid
                         network serial devices usb? qmp)
  "Return QEMU arguments to boot KERNEL in a microvm.  NETWORK is the passt
socket, or #f for an unconnected NIC."
  `("-M" ,(string-append "microvm,"
                         (if usb? "acpi=on,usb=on" "acpi=off")
                         ",rtc=on,memory-backend=mem")
    "-cpu" "host" "-enable-kvm"
    "-m" ,(number->string memory) "-smp" ,(number->string cpus)
    "-object" ,(format #f "memory-backend-memfd,id=mem,size=~aM,share=on"
                       memory)
    "-nodefaults" "-no-user-config" "-no-reboot"
    "-display" "none" "-monitor" "none"
    "-sandbox" ,(string-append "on,obsolete=deny,elevateprivileges=deny,"
                               "spawn=deny,resourcecontrol=deny")
    "-qmp" ,(string-append "unix:" qmp ",server=on,wait=off")
    ,@serial
    "-kernel" ,kernel "-initrd" ,initrd
    "-append" ,(string-join kernel-arguments)
    "-object" "rng-random,filename=/dev/urandom,id=rng"
    "-device" "virtio-rng-device,rng=rng"
    "-device" ,(string-append "vhost-vsock-device,guest-cid=" cid)
    ;; The guest's static networking, and so its SSH daemon, needs eth0.
    ,@(if network
          `("-netdev" ,(string-append "stream,id=net,server=off,"
                                      "addr.type=unix,addr.path=" network)
            "-device" "virtio-net-device,netdev=net")
          '("-device" "virtio-net-device"))
    ,@devices))

(define (vm-kernel-arguments key-blob stateless? kernel-arguments)
  "Return the VM's kernel command line as a list: KERNEL-ARGUMENTS, the SSH
key KEY-BLOB and whether the VM is STATELESS?."
  ;; With -no-reboot, QEMU exits on a panic.
  `("console=ttyS0" "panic=-1"
    ,(string-append "guix-microvm.ssh-key=" key-blob)
    ,@(if stateless? '("guix-microvm.stateless=1") '())
    ,@kernel-arguments))

(define* (vm-qemu-arguments directory invocation config shares
                            #:key key-blob cid log)
  "Return the QEMU arguments for INVOCATION of the VM CONFIG."
  (match-record invocation <invocation> (stateless? memory cpus serial)
    (match-record config <vm-config> (kernel initrd kernel-arguments usb?)
      (qemu-arguments #:kernel kernel #:initrd initrd
                      #:kernel-arguments
                      (vm-kernel-arguments key-blob stateless?
                                           kernel-arguments)
                      #:memory memory #:cpus cpus #:cid cid
                      #:network (network-socket-file directory config)
                      #:serial (serial-options log serial)
                      #:devices (share-devices shares directory)
                      #:usb? usb?
                      #:qmp (qmp-socket-file directory)))))

(define (open-log file)
  "Empty FILE and return a port appending to it.  QEMU appends the serial
console to it too."
  (let ((port (open-file file "a")))
    (truncate-file port 0)
    port))

(define (call-with-vm qemu arguments log proc)
  "Start QEMU with ARGUMENTS, stderr appended to LOG, and call PROC with its
PID.  Stop it when PROC returns or exits."
  (call-with-port (open-log log)
    (cut call-with-process qemu arguments proc #:error <>)))

(define (printable str)
  "Return STR without carriage returns and with control characters other
than newline and tab replaced by ?."
  (string-map (lambda (char)
                (if (and (char-set-contains? char-set:iso-control char)
                         (not (memv char '(#\newline #\tab))))
                    #\?
                    char))
              (string-delete #\return str)))

(define* (boot-failure-handler log #:key show-log?)
  "Return a procedure that fails with a boot error message.  It prints the
console LOG if SHOW-LOG?, or else names it."
  (lambda (message)
    (if show-log?
        (begin
          (display (printable (call-with-input-file log get-string-all))
                   (current-error-port))
          (fail "~a" message))
        (fail "~a, see ~a" message log))))

(define (wait-for-boot spawn-ssh qemu timeout on-failure)
  "Wait until the VM of the QEMU process accepts SSH.  Call ON-FAILURE with
a message if QEMU exits or TIMEOUT seconds pass first."
  (let ((deadline (+ (current-time) timeout)))
    (let loop ()
      (unless (ssh-succeeds? spawn-ssh "true")
        (cond ((not (child-alive? qemu))
               (on-failure "the VM exited"))
              ((> (current-time) deadline)
               (on-failure "no SSH connection to the VM"))
              (else
               (sleep 1)
               (loop)))))))

(define (run-remote spawn-ssh command options status-file)
  "Run the shell COMMAND with ssh OPTIONS and return the exit status it
writes to STATUS-FILE."
  (let ((status (wait-for-exit (spawn-ssh command #:options options))))
    ;; Sync before QEMU is stopped.  The exit status comes from a file, as
    ;; ssh's own cannot be told apart from the command's.
    (or (string->number
         (string-trim-both
          (ssh-output spawn-ssh (string-append "sync; cat " status-file))))
        (begin
          (format (current-error-port) "~a: lost the connection to the VM~%"
                  (%program-name))
          status))))

(define* (boot-and-run spawn-ssh qemu command
                       #:key boot-timeout on-boot-failure ssh-options
                       status-file)
  "Wait for the VM of the QEMU process to boot, run the shell COMMAND with
SSH-OPTIONS and return the exit status it writes to STATUS-FILE."
  (wait-for-boot spawn-ssh qemu boot-timeout on-boot-failure)
  (run-remote spawn-ssh command ssh-options status-file))

(define (check-devices)
  ;; Without KVM, QEMU would keep running stale translated code for pages
  ;; virtiofsd writes into guest memory.
  (for-each (lambda (device)
              (unless (access? device (logior R_OK W_OK))
                (fail "~a is not accessible" device)))
            '("/dev/kvm" "/dev/vhost-vsock")))

(define (check-host invocation name waypipe)
  "Fail unless the host can run INVOCATION of the VM NAME, with WAYPIPE if
it is graphical."
  (check-shareable (invocation-directory invocation)
                   (invocation-share-home? invocation))
  (when (and waypipe (not (getenv "WAYLAND_DISPLAY")))
    (fail "WAYLAND_DISPLAY is not set: ~a needs a Wayland session" name))
  (check-devices))

(define (exit-on-signals!)
  "Exit, stopping the VM, on SIGINT, SIGTERM and SIGHUP."
  (for-each (lambda (signal)
              (sigaction signal
                (lambda (signal)
                  (exit (+ 128 signal)))))
            (list SIGINT SIGTERM SIGHUP)))

(define (run-vm tmp invocation config tools read-only)
  "Run INVOCATION of the VM CONFIG in TMP and return the command's exit
status."
  (match-record invocation <invocation> (directory command stateless? cache)
    (match-record config <vm-config> (name uid gid usb? store-items)
      (let* ((data (data-directory (home-directory)))
             (home log key (vm-files data tmp name directory stateless?))
             (host-key (string-append tmp "/ssh_host_ed25519_key"))
             (shares (vm-shares #:directory directory #:home home
                                #:store (string-append tmp "/store")
                                #:store-items store-items #:host-key host-key
                                #:stateless? stateless? #:uid uid #:gid gid
                                #:mount-store (tools-mount-store tools)
                                #:mount-read-only (tools-mount-read-only tools)
                                #:read-only read-only))
             (wayland-servers wrapper forward-options
                              (wayland-forwarding
                               (tools-waypipe tools)
                               (tools-guest-waypipe tools) name
                               (socket-file tmp "waypipe")
                               (string-append (guest-runtime-directory uid)
                                              "/waypipe.sock")))
             (servers (append (network-servers tmp config tools)
                              wayland-servers
                              (share-servers
                               shares tmp
                               #:unshare (tools-unshare tools)
                               #:virtiofsd (tools-virtiofsd tools)
                               #:cache cache)))
             (known-hosts (string-append tmp "/known_hosts"))
             (cid (vm-cid))
             (key-blob (ssh-key-blob (tools-ssh-keygen tools) key))
             (spawn-ssh (vm-ssh-spawner config tools data directory key
                                        known-hosts cid))
             (status-file (guest-status-file uid)))
        (define (boot qemu)
          (boot-and-run spawn-ssh qemu
                        (remote-command command wrapper status-file)
                        #:boot-timeout (invocation-boot-timeout invocation)
                        ;; A stateless VM's log is deleted on exit, so show it.
                        #:on-boot-failure (boot-failure-handler
                                           log #:show-log? stateless?)
                        #:ssh-options (cons "-t" forward-options)
                        #:status-file status-file))

        (define (start-vm)
          (call-with-vm (tools-qemu tools)
              (vm-qemu-arguments tmp invocation config shares
                                 #:key-blob key-blob #:cid cid #:log log)
              log
            boot))

        (write-known-hosts known-hosts
                           (ssh-key-blob (tools-ssh-keygen tools) host-key))
        (for-each mkdir-p (map share-directory shares))
        (call-with-vm-info tmp `((name . ,name)
                                 (directory . ,directory)
                                 (usb? . ,usb?))
          (cut call-with-servers servers start-vm))))))

(define (run-microvm args config tools)
  "Run the VM CONFIG with TOOLS as the command line ARGS ask: share DIR at
/work and run COMMAND there.  Return the exit status of COMMAND."
  (parameterize ((%program-name (string-append "run-"
                                               (vm-config-name config))))
    (call-with-launcher-errors
     (lambda ()
       (let ((invocation (parse-invocation args config)))
         (check-host invocation (vm-config-name config) (tools-waypipe tools))
         (let* ((directory (invocation-directory invocation))
                (read-only (read-only-files
                            (append (find-git-entries directory)
                                    (map (cut string-append directory "/" <>)
                                         (vm-config-read-only-files
                                          config))))))
           (exit-on-signals!)
           (call-with-temporary-directory (runtime-directory)
             (cut run-vm <> invocation config tools read-only))))))))
