;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build microvm)
  #:use-module (guix build utils)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-71)
  #:use-module (web uri)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build files)
  #:use-module (guix-microvm build git)
  #:use-module (guix-microvm build layer)
  #:use-module (guix-microvm build process)
  #:use-module (guix-microvm build review)
  #:use-module (guix-microvm build shares)
  #:use-module (guix-microvm build ssh)
  #:use-module (guix-microvm build state)
  #:export (vm-config
            tools
            check-shareable
            volatile-vm?
            runtime-directory
            %vm-directory-prefix
            vm-info-file
            vm-ssh-spawner
            qmp-socket-file
            run-microvm))

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
  (command      invocation-command)
  (stateless?   invocation-stateless?)
  (volatile?    invocation-volatile?)
  (policy       invocation-policy)              ;'ask | 'merge | 'discard
  (memory       invocation-memory)              ;MiB
  (cpus         invocation-cpus)
  (boot-timeout invocation-boot-timeout)        ;seconds
  (cache        invocation-cache)
  (serial       invocation-serial))             ;QEMU's -serial | #f

(define (parse-arguments args)
  "Split ARGS into flags, directory and command, returned as three values."
  (match args
    (((and flag (or "--stateless" "--volatile" "--persistent" "--merge"
                    "--discard"))
      rest ...)
     (let ((flags directory command (parse-arguments rest)))
       (values (cons flag flags) directory command)))
    (() (values '() "." '()))
    (("--" command ...) (values '() "." command))
    ((directory) (values '() directory '()))
    ((directory "--" command ...) (values '() directory command))
    (_ (usage-error "[--stateless] [--volatile|--persistent] \
[--merge|--discard] [DIR] [-- COMMAND...]"))))

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
  "Return the invocation of the VM CONFIG that the command line ARGS and the
environment describe."
  (let* ((flags requested-directory requested-command (parse-arguments args))
         (flag? (lambda (flag) (and (member flag flags) #t)))
         (stateless? (or (vm-config-stateless? config) (flag? "--stateless"))))
    (invocation
      (directory (existing-directory requested-directory))
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
      (memory (getenv-positive-integer "VM_MEMORY"
                                       (vm-config-memory-size config)))
      (cpus (getenv-positive-integer "VM_CPUS"
                                     (vm-config-cpu-count config)))
      (boot-timeout (getenv-positive-integer "VM_BOOT_TIMEOUT" 120))
      (cache (or (getenv "VM_FS_CACHE") "auto"))
      (serial (getenv "VM_SERIAL")))))

(define (check-shareable directory)
  (let ((home (home-directory)))
    (cond ((contains-file? directory home)
           (fail "not sharing ~a, which contains the home directory, as a \
project; use a subdirectory, or --volatile" directory))
          ;; The snapshot of the project would include the layers.
          ((contains-file? directory (canonical-data-directory))
           (fail "not sharing ~a, which contains ~a, as a project"
                 directory (data-directory))))))

(define (canonical-data-directory)
  (let ((data (data-directory)))
    (mkdir-p data)
    (canonicalize-path data)))

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

(define (guest-status-file guest-runtime-directory)
  ;; Only the guest user can write there, so other guest users cannot fake
  ;; it.
  (string-append guest-runtime-directory "/guix-microvm-status"))

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

(define (vm-variables git directory profile)
  "Return the Git identity for DIRECTORY and PROFILE, if any, as an alist
of variables."
  (append (git-identity git directory)
          (if profile
              `(("GUIX_MICROVM_PROFILE" . ,profile))
              '())))

(define (send-env-patterns secrets)
  `("LANG" "COLORTERM" "GIT_AUTHOR_*" "GIT_COMMITTER_*" "GUIX_MICROVM_PROFILE"
    ,@secrets))

(define (vm-ssh config tools data directory key known-hosts cid)
  "Return how ssh reaches the VM CONFIG, as an alist."
  (match-record config <vm-config> (name user ssh-port profile secrets)
    `((program . ,(tools-ssh tools))
      (options . ,(ssh-options #:key key #:known-hosts known-hosts
                               #:socat (tools-socat tools) #:cid cid
                               #:port ssh-port
                               #:send-env (send-env-patterns secrets)))
      (destination . ,(string-append user "@" name))
      (variables . ,(vm-variables (tools-git tools) directory profile))
      ;; Read when sending them, to keep them out of the VM's info file.
      (secrets . (,(secrets-directory data name) ,@secrets)))))

(define (vm-ssh-spawner ssh)
  "Return the procedure that runs commands with SSH, from 'vm-ssh'."
  (ssh-spawner (assq-ref ssh 'program) (assq-ref ssh 'options)
               (assq-ref ssh 'destination)
               #:environment
               (environment-with
                (append (assq-ref ssh 'variables)
                        (match (assq-ref ssh 'secrets)
                          ((directory . names)
                           (read-secrets directory names)))))))

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

(define (vm-kernel-arguments key-blob volatile? kernel-arguments)
  "Return the VM's kernel command line as a list: KERNEL-ARGUMENTS, the SSH
key KEY-BLOB and whether the VM is VOLATILE?, without the project."
  ;; With -no-reboot, QEMU exits on a panic.
  `("console=ttyS0" "panic=-1"
    ,(string-append "guix-microvm.ssh-key=" key-blob)
    ,@(if volatile? '("guix-microvm.volatile=1") '())
    ,@kernel-arguments))

(define* (vm-qemu-arguments directory invocation config shares
                            #:key key-blob cid log)
  (match-record invocation <invocation> (volatile? memory cpus serial)
    (match-record config <vm-config> (kernel initrd kernel-arguments usb?)
      (qemu-arguments #:kernel kernel #:initrd initrd
                      #:kernel-arguments
                      (vm-kernel-arguments key-blob volatile?
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

(define (run-remote spawn-ssh qemu command options status-file)
  "Run the shell COMMAND with ssh OPTIONS in the VM of the QEMU process and
return the exit status it writes to STATUS-FILE."
  (let ((status (wait-for-exit (spawn-ssh command #:options options))))
    ;; Sync before QEMU is stopped.  The exit status comes from a file, as
    ;; ssh's own cannot be told apart from the command's.
    (or (string->number
         (string-trim-both
          (ssh-output spawn-ssh (string-append "sync; cat " status-file))))
        (begin
          (format (current-error-port) "~a: ~a~%" (%program-name)
                  ;; QEMU takes a moment to exit.
                  (if (exits-within? qemu 5)
                      "the VM was killed"
                      "lost the connection to the VM"))
          status))))

(define (wait-until-killed qemu name)
  (when (child-alive? qemu)
    (format (current-error-port) "~a: the VM keeps running; \
'guix microvm attach ~a' opens a shell and 'guix microvm kill ~a' stops it~%"
            (%program-name) name name)
    (let loop ()
      (unless (exits-within? qemu 60)
        (loop)))))

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
  (unless (invocation-volatile? invocation)
    (check-shareable (invocation-directory invocation)))
  (when (and waypipe (not (getenv "WAYLAND_DISPLAY")))
    (fail "WAYLAND_DISPLAY is not set: ~a needs a Wayland session" name))
  (check-devices))

(define (exit-on-signals!)
  (for-each (lambda (signal)
              (sigaction signal
                (lambda (signal)
                  (exit (+ 128 signal)))))
            (list SIGINT SIGTERM SIGHUP)))

(define (run-vm tmp invocation config tools layer)
  "Run INVOCATION of the VM CONFIG in TMP, sharing the project through LAYER
unless it is #f, and return the command's exit status."
  (match-record invocation <invocation> (directory command stateless? cache)
    (match-record config <vm-config> (name uid gid usb? store-items
                                      guest-runtime-directory)
      (let* ((data (data-directory))
             (home log key (vm-files data tmp name directory stateless?))
             (host-key (string-append tmp "/ssh_host_ed25519_key"))
             (shares (vm-shares #:layer layer #:home home
                                #:store (string-append tmp "/store")
                                #:store-items store-items #:host-key host-key
                                #:uid uid #:gid gid
                                #:mount-store (tools-mount-store tools)
                                #:mount-overlay (tools-mount-overlay tools)))
             (wayland-servers wrapper forward-options
                              (wayland-forwarding
                               (tools-waypipe tools)
                               (tools-guest-waypipe tools) name
                               (socket-file tmp "waypipe")
                               (string-append guest-runtime-directory
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
             (ssh (vm-ssh config tools data directory key known-hosts cid))
             (spawn-ssh (vm-ssh-spawner ssh))
             (status-file (guest-status-file guest-runtime-directory)))
        (define (boot qemu)
          (wait-for-boot spawn-ssh qemu (invocation-boot-timeout invocation)
                         ;; A stateless VM's log is deleted on exit, so show
                         ;; it.
                         (boot-failure-handler log #:show-log? stateless?))
          (let ((status
                 (run-remote spawn-ssh qemu
                             (remote-command command wrapper status-file)
                             (cons "-t" forward-options) status-file)))
            ;; Without a terminal, nobody would kill it.
            (when (and (null? command) (isatty? (current-input-port)))
              (wait-until-killed qemu name))
            status))

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
                                 (usb? . ,usb?)
                                 (ssh . ,ssh))
          (cut call-with-servers servers start-vm))))))

(define (check-policy invocation)
  (when (and (not (invocation-volatile? invocation))
             (eq? 'ask (invocation-policy invocation))
             (not (isatty? (current-input-port))))
    (fail "without a terminal to ask about its changes, pass --merge or \
--discard")))

(define (call-with-project invocation config tools proc)
  "Call PROC with the layer over the project, or #f for a volatile VM, then
resolve its changes.  Return the result of PROC, or 1 if merging failed."
  (define directory
    (invocation-directory invocation))

  (define* (resolve layer #:key (policy (invocation-policy invocation))
                    previous?)
    (resolve-layer layer
                   #:git (tools-git tools)
                   #:policy policy
                   #:protected-files (vm-config-protected-files config)
                   #:previous? previous?))

  (if (invocation-volatile? invocation)
      (proc #f)
      (let ((data (data-directory)))
        (call-with-project-lock data directory
          (lambda ()
            ;; Asked even with --merge or --discard, which are meant for
            ;; this run.
            (for-each (lambda (layer)
                        (when (memq (resolve layer
                                             #:policy
                                             (if (isatty? (current-input-port))
                                                 'ask
                                                 'keep)
                                             #:previous? #t)
                                    '(kept conflict incomplete))
                          (fail "the changes of a previous VM on ~a are left; \
decide on them in a terminal" directory)))
                      (project-layers data directory))
            (let* ((layer (create-layer data directory #:cp (tools-cp tools)))
                   (status (proc layer)))
              (if (memq (resolve layer) '(conflict incomplete))
                  1
                  status)))))))

(define (run-microvm args config tools)
  "Run the VM CONFIG with TOOLS as the command line ARGS ask: share DIR at
/work and run COMMAND there.  Return the exit status of COMMAND."
  (parameterize ((%program-name (string-append "run-"
                                               (vm-config-name config))))
    (call-with-launcher-errors
     (lambda ()
       (let ((invocation (parse-invocation args config)))
         (check-host invocation (vm-config-name config) (tools-waypipe tools))
         (check-policy invocation)
         (exit-on-signals!)
         (call-with-project invocation config tools
           (lambda (layer)
             (call-with-temporary-directory (runtime-directory)
               (cut run-vm <> invocation config tools layer)))))))))
