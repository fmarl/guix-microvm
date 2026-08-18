(define-module (guix-microvm build microvm)
  #:use-module (guix build syscalls)
  #:use-module (guix build utils)
  #:use-module (ice-9 exceptions)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-71)
  #:use-module (web uri)
  #:export (home-directory
            contains-home?
            runtime-directory
            %vm-directory-prefix
            vm-info-file
            qmp-socket-file
            wait-for-exit
            mount-store-items
            run-microvm))

(define %program-name
  (make-parameter "run-vm"))

(define-exception-type &launcher-error &error
  make-launcher-error launcher-error?
  (message launcher-error-message)
  (status launcher-error-status))

(define (fail message . args)
  "Raise a launcher error with exit status 1, formatting MESSAGE with ARGS."
  (raise-exception
   (make-launcher-error (apply format #f (string-append (%program-name) ": "
                                                        message)
                               args)
                        1)))

(define (call-with-launcher-errors thunk)
  "Call THUNK.  On a launcher error, print it and return its exit status."
  (guard (error ((launcher-error? error)
                 (format (current-error-port) "~a~%"
                         (launcher-error-message error))
                 (launcher-error-status error)))
    (thunk)))

(define (getenv* name default)
  (or (getenv name) default))

(define (getenv-number name default)
  (match (getenv name)
    (#f default)
    (value (or (string->number value)
               (fail "~a is not a number: ~a" name value)))))

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
    (_
     (raise-exception
      (make-launcher-error
       (format #f "Usage: ~a [--share-home] [--stateless] [DIR] \
[-- COMMAND...]"
               (%program-name))
       2)))))

(define (existing-directory directory)
  "Return the canonical name of DIRECTORY, which must exist."
  (if (directory-exists? directory)
      (canonicalize-path directory)
      (fail "~a is not a directory" directory)))

(define (home-directory)
  (canonicalize-path (getenv "HOME")))

(define (contains-home? directory home)
  "Return true if DIRECTORY is HOME or one of its parents."
  (or (string=? directory "/")
      (string=? directory home)
      (string-prefix? (string-append directory "/") home)))

(define (mount-store-items items root)
  "Bind-mount the store items listed in ITEMS on a tmpfs at ROOT.  Needs a
private mount namespace."
  (mount "none" root "tmpfs" 0 "mode=755")
  (for-each (lambda (item)
              (let ((target (string-append root "/" (basename item))))
                (if (file-is-directory? item)
                    (mkdir target)
                    (call-with-output-file target (const #t)))
                (mount item target "none" (logior MS_BIND MS_REC))))
            (string-tokenize (call-with-input-file items get-string-all))))

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

(define (data-directory home)
  (string-append (getenv* "XDG_DATA_HOME" (string-append home "/.local/share"))
                 "/guix-microvm"))

(define (secrets-directory data name)
  (string-append data "/" name "/secrets"))

(define (ssh-key-blob ssh-keygen key)
  "Return the Base64 part of the public Ed25519 KEY.  Create KEY if
missing."
  (unless (file-exists? key)
    (mkdir-p (dirname key))
    (invoke ssh-keygen "-q" "-t" "ed25519" "-N" "" "-C" "guix-microvm"
            "-f" key))
  (match (string-tokenize
          (call-with-input-file (string-append key ".pub") get-string-all))
    (("ssh-ed25519" blob _ ...) blob)
    (_ (fail "~a.pub is not an Ed25519 key" key))))

(define (git-config git directory name)
  (let* ((port (open-pipe* OPEN_READ git "-C" directory "config" name))
         (value (string-trim-right (get-string-all port))))
    (close-pipe port)
    (and (not (string-null? value)) value)))

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

(define (sent-variables secrets)
  "Return the SendEnv patterns for ssh, SECRETS included."
  `("LANG" "COLORTERM" "GIT_AUTHOR_*" "GIT_COMMITTER_*" "GUIX_MICROVM_PROFILE"
    ,@secrets))

(define (shell-quote str)
  (string-append "'" (string-join (string-split str #\') "'\\''") "'"))

(define %null-port
  (delay (open-file "/dev/null" "r+")))

(define (exit-status status)
  (or (status:exit-val status)
      (+ 128 (status:term-sig status))))

(define (wait-for-exit pid)
  (exit-status (cdr (waitpid pid))))

(define (child-alive? pid)
  (match (waitpid pid WNOHANG)
    ((0 . _) #t)
    (_ #f)))

(define (wait-for-socket file pid)
  (let loop ()
    (unless (file-exists? file)
      (unless (child-alive? pid)
        (fail "no ~a, the program serving it exited" file))
      (usleep 100000)
      (loop))))

(define (runtime-directory)
  (getenv* "XDG_RUNTIME_DIR" "/tmp"))

;; That of the directories of the running VMs in the runtime directory.
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

(define* (call-with-process program args proc
                            #:key (error (current-error-port)))
  "Start PROGRAM with ARGS, stderr to ERROR, and call PROC with its PID.
Stop it when PROC returns or exits."
  (let ((pid (spawn program (cons program args)
                    #:input (force %null-port) #:error error)))
    (dynamic-wind
      (const #t)
      (cut proc pid)
      (lambda ()
        (false-if-exception (kill pid SIGTERM))
        (false-if-exception (waitpid pid))))))

(define-record-type <server>
  (server program arguments socket)
  server?
  (program   server-program)
  (arguments server-arguments)
  (socket    server-socket))

(define (call-with-servers servers thunk)
  "Start SERVERS in order, call THUNK once all are up, and stop them when it
returns or exits."
  (match servers
    (() (thunk))
    ((first rest ...)
     (call-with-process (server-program first) (server-arguments first)
       (lambda (pid)
         (wait-for-socket (server-socket first) pid)
         (call-with-servers rest thunk))))))

(define (socket-file directory name)
  ;; In XDG_RUNTIME_DIR: socket file names are limited to 107 bytes.
  (string-append directory "/" name ".sock"))

(define (qmp-socket-file directory)
  (socket-file directory "qmp"))

(define (vm-info-file directory)
  (string-append directory "/vm"))

(define (write-vm-info directory info)
  (call-with-output-file (vm-info-file directory)
    (cut write info <>)))

(define (passt-server passt socket options)
  (server passt
          `("--foreground" "--quiet" "--one-off" "--no-dhcp" "--no-map-gw"
            "--socket" ,socket ,@options)
          socket))

(define-record-type <share>
  (share tag directory options wrapper)
  share?
  (tag       share-tag)
  (directory share-directory)
  (options   share-options)             ;virtiofsd options
  (wrapper   share-wrapper))            ;command prefix of virtiofsd

(define (id-map-options guest-uid guest-gid host-uid host-gid)
  "Return virtiofsd options mapping GUEST-UID and GUEST-GID to HOST-UID and
HOST-GID in its user namespace."
  (list "--translate-uid" (format #f "map:~a:~a:1" guest-uid host-uid)
        "--translate-gid" (format #f "map:~a:~a:1" guest-gid host-gid)))

(define (overflow-id kind)
  "Return the ID of unmapped users or groups in a user namespace, KIND being
\"uid\" or \"gid\"."
  (call-with-input-file (string-append "/proc/sys/kernel/overflow" kind)
    read))

(define* (vm-shares #:key directory home stateless? uid gid
                    store store-items mount-store)
  "Return the VM's shares: STORE-ITEMS at STORE, mounted by MOUNT-STORE, and
DIRECTORY and HOME, owned by UID and GID in the VM.  DIRECTORY is read-only
if STATELESS?."
  (let ((owned (id-map-options uid gid 0 0)))
    (list
     ;; Store items are root's, hence nobody's in the namespace.
     (share "store" store
            (cons "--readonly"
                  (id-map-options 0 0 (overflow-id "uid") (overflow-id "gid")))
            (list mount-store store-items store))
     ;; A stateless VM overlays it with a tmpfs.
     (share "work" directory
            (if stateless? (cons "--readonly" owned) owned)
            '())
     (share "home" home owned '()))))

(define (share-socket tmp share)
  (socket-file tmp (share-tag share)))

;; virtiofsd runs as root of a user namespace in which the host user is root
;; and other users are nobody.
(define* (virtiofs-server share socket #:key unshare virtiofsd cache)
  "Return a virtiofsd server for SHARE at SOCKET."
  (server unshare
          `("--user" "--map-root-user" "--mount"
            ,@(share-wrapper share)
            ,virtiofsd "--shared-dir" ,(share-directory share)
            "--socket-path" ,socket
            "--sandbox" "namespace" "--log-level" "error" "--cache" ,cache
            ,@(share-options share))
          socket))

(define (virtiofs-device share socket)
  "Return QEMU options for the virtio-fs device of SHARE at SOCKET."
  (let ((tag (share-tag share)))
    (list "-chardev" (string-append "socket,id=" tag ",path=" socket)
          "-device" (string-append "vhost-user-fs-device,chardev=" tag
                                   ",tag=" tag))))

;; Forwarded over SSH, not vsock, which other guests can reach.
(define (wayland-forwarding waypipe name socket guest-socket)
  "Return the servers, command wrapper and ssh options that show Wayland
clients of VM NAME on the host's display, via SOCKET on the host and
GUEST-SOCKET in the VM.  Without WAYPIPE, return empty lists."
  (if waypipe
      (values (list (server waypipe
                            `("--socket" ,socket "--no-gpu"
                              "--secctx" ,(string-append "guix-microvm." name)
                              "client")
                            socket))
              (list waypipe "--socket" guest-socket "--no-gpu" "server" "--")
              (list "-o" "ExitOnForwardFailure=yes"
                    "-R" (string-append guest-socket ":" socket)))
      (values '() '() '())))

(define* (ssh-arguments destination command
                        #:key key socat cid port send-env options)
  "Return ssh arguments to run COMMAND at DESTINATION over vsock CID:PORT
with KEY."
  `("ssh" "-F" "/dev/null" "-q"
    "-i" ,key "-o" "IdentitiesOnly=yes"
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "ForwardAgent=no" "-o" "ForwardX11=no"
    "-o" ,(string-append "SendEnv=" (string-join send-env))
    "-o" ,(format #f "ProxyCommand=~a - VSOCK-CONNECT:~a:~a" socat cid port)
    ,@options
    ,destination
    ,command))

(define* (ssh-spawner ssh destination
                      #:key key socat cid port send-env environment)
  "Return a procedure that runs a command at DESTINATION with SSH and returns
its PID.  SSH connects over vsock CID:PORT with KEY and sends the SEND-ENV
variables of ENVIRONMENT.  The procedure takes extra ssh OPTIONS and OUTPUT
and ERROR ports."
  (lambda* (command #:key (options '())
                    (output (current-output-port))
                    (error (current-error-port)))
    (spawn ssh (ssh-arguments destination command
                              #:key key #:socat socat #:cid cid #:port port
                              #:send-env send-env #:options options)
           #:environment environment #:output output #:error error)))

(define %batch-options
  '("-n" "-o" "BatchMode=yes" "-o" "ConnectTimeout=5"))

(define (ssh-succeeds? spawn-ssh command)
  (zero? (wait-for-exit (spawn-ssh command
                                   #:options %batch-options
                                   #:output (force %null-port)
                                   #:error (force %null-port)))))

(define (ssh-output spawn-ssh command)
  (match (pipe)
    ((in . out)
     (let ((pid (spawn-ssh command
                           #:options %batch-options
                           #:output out #:error (force %null-port))))
       (close-port out)
       (let ((output (get-string-all in)))
         (close-port in)
         (waitpid pid)
         output)))))

(define (remote-command command wrapper status-file)
  "Return a shell command that runs COMMAND, or a login shell if it is empty,
in /work under WRAPPER and writes the exit status to STATUS-FILE."
  (let ((script (string-append "cd /work && "
                               (string-join (if (null? command)
                                                '("\"$SHELL\"" "-l")
                                                (map shell-quote command)))
                               "; echo $? > " status-file)))
    ;; waypipe exits with its own status.
    (if (null? wrapper)
        script
        (string-join (append wrapper (list "sh" "-c" (shell-quote script)))))))

(define (serial-options log serial)
  "Return QEMU options for the serial console: SERIAL if set, else append to
LOG."
  (match serial
    (#f `("-chardev" ,(string-append "file,id=serial,path=" log ",append=on")
          "-serial" "chardev:serial"))
    (serial `("-serial" ,serial))))

(define* (qemu-arguments #:key kernel initrd kernel-arguments memory cpus cid
                         network serial devices usb? qmp)
  "Return QEMU arguments to boot KERNEL on a microvm with MEMORY MiB, CPUS,
vsock CID, a NIC at NETWORK, DEVICES and the QMP socket QMP.  USB? adds a
USB controller, which needs ACPI."
  `("-M" ,(string-append "microvm,"
                         (if usb? "acpi=on,usb=on" "acpi=off")
                         ",rtc=on,memory-backend=mem")
    "-cpu" "host" "-enable-kvm"
    "-m" ,(number->string memory) "-smp" ,(number->string cpus)
    "-object" ,(format #f "memory-backend-memfd,id=mem,size=~aM,share=on"
                       memory)
    "-nodefaults" "-no-user-config" "-no-reboot"
    "-display" "none" "-monitor" "none"
    "-qmp" ,(string-append "unix:" qmp ",server=on,wait=off")
    ,@serial
    "-kernel" ,kernel "-initrd" ,initrd
    "-append" ,(string-join kernel-arguments)
    "-object" "rng-random,filename=/dev/urandom,id=rng"
    "-device" "virtio-rng-device,rng=rng"
    "-device" ,(string-append "vhost-vsock-device,guest-cid=" cid)
    "-netdev" ,(string-append "stream,id=net,server=off,"
                              "addr.type=unix,addr.path=" network)
    "-device" "virtio-net-device,netdev=net"
    ,@devices))

(define (open-log file)
  "Empty FILE and return a port appending to it.  QEMU appends the serial
console to it too."
  (let ((port (open-file file "a")))
    (truncate-file port 0)
    port))

(define (vm-kernel-arguments key-blob stateless? kernel-arguments)
  "Return the VM's kernel command line as a list: KERNEL-ARGUMENTS and the
SSH key KEY-BLOB."
  ;; With -no-reboot, QEMU exits on a panic.
  `("console=ttyS0" "panic=-1"
    ,(string-append "guix-microvm.ssh-key=" key-blob)
    ,@(if stateless? '("guix-microvm.stateless=1") '())
    ,@kernel-arguments))

(define (call-with-vm qemu arguments log proc)
  "Start QEMU with ARGUMENTS, stderr appended to LOG, and call PROC with its
PID.  Stop it when PROC returns or exits."
  (call-with-port (open-log log)
    (lambda (port)
      (call-with-process qemu arguments proc #:error port))))

(define* (boot-failure-handler log #:key show-log?)
  "Return a procedure that fails with a boot error message.  It prints LOG,
the console output, if SHOW-LOG?, or else names it."
  (lambda (message)
    (if show-log?
        (begin
          (display (call-with-input-file log get-string-all)
                   (current-error-port))
          (fail message))
        (fail (string-append message ", see ~a") log))))

(define (wait-for-boot spawn-ssh vm timeout on-failure)
  "Wait until the QEMU process VM accepts SSH.  Call ON-FAILURE with a
message if it exits or TIMEOUT seconds pass first."
  (let ((deadline (+ (current-time) timeout)))
    (let loop ()
      (unless (ssh-succeeds? spawn-ssh "true")
        (cond ((not (child-alive? vm))
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

(define (check-devices!)
  ;; Without KVM, QEMU would keep running stale translated code for pages
  ;; virtiofsd writes into guest memory.
  (for-each (lambda (device)
              (unless (access? device (logior R_OK W_OK))
                (fail "~a is not accessible" device)))
            '("/dev/kvm" "/dev/vhost-vsock")))

(define (exit-on-signals!)
  "Exit, stopping the VM, on SIGINT, SIGTERM and SIGHUP."
  (for-each (lambda (signal)
              (sigaction signal
                (lambda (signal)
                  (exit (+ 128 signal)))))
            (list SIGINT SIGTERM SIGHUP)))

(define (check-host! directory share-home? name waypipe)
  "Fail unless the host can run the VM NAME sharing DIRECTORY."
  (when (and (not share-home?)
             (contains-home? directory (home-directory)))
    (fail "not sharing ~a, which contains the home directory, without \
--share-home" directory))
  (when (and waypipe (not (getenv "WAYLAND_DISPLAY")))
    (fail "WAYLAND_DISPLAY is not set: ~a needs a Wayland session" name))
  (check-devices!))

(define %status-file "/tmp/guix-microvm-status")

(define* (share-servers shares tmp #:key unshare virtiofsd cache)
  (map (lambda (share)
         (virtiofs-server share (share-socket tmp share)
                          #:unshare unshare #:virtiofsd virtiofsd
                          #:cache cache))
       shares))

(define (share-devices shares tmp)
  (append-map (lambda (share)
                (virtiofs-device share (share-socket tmp share)))
              shares))

(define* (boot-and-run spawn-ssh vm command
                       #:key boot-timeout on-boot-failure ssh-options)
  "Wait for the QEMU process VM to boot, run the shell COMMAND with
SSH-OPTIONS and return its exit status."
  (wait-for-boot spawn-ssh vm boot-timeout on-boot-failure)
  (run-remote spawn-ssh command ssh-options %status-file))

(define* (run-microvm args
                      #:key name default-command stateless? kernel initrd
                      kernel-arguments store-items profile
                      memory-size cpu-count user uid gid ssh-port
                      network-options
                      qemu virtiofsd passt waypipe ssh ssh-keygen socat git
                      unshare mount-store secrets usb?)
  "Run microvm NAME with the command line ARGS and return the exit status of
its command, DEFAULT-COMMAND unless ARGS name one.  WAYPIPE shows Wayland
clients on the host's display.  STATELESS? or --stateless gives a fresh home
and discards changes to DIR.  USB? adds a controller for 'guix microvm usb'."
  (parameterize ((%program-name (string-append "run-" name)))
    (call-with-launcher-errors
     (lambda ()
       (let* ((flags directory command (parse-arguments args))
              (stateless? (or stateless? (member "--stateless" flags)))
              (directory (existing-directory directory))
              (command (if (null? command) default-command command))
              (data (data-directory (home-directory)))
              (memory (getenv-number "VM_MEMORY" memory-size))
              (cpus (getenv-number "VM_CPUS" cpu-count))
              (boot-timeout (getenv-number "VM_BOOT_TIMEOUT" 120))
              (cache (getenv* "VM_FS_CACHE" "auto"))
              (serial (getenv "VM_SERIAL"))
              ;; Unique among running VMs.
              (cid (number->string (getpid))))
         (check-host! directory (member "--share-home" flags) name waypipe)
         (exit-on-signals!)
         (call-with-temporary-directory (runtime-directory)
           (lambda (tmp)
             (let* ((home log key (vm-files data tmp name directory
                                            stateless?))
                    (shares (vm-shares #:directory directory #:home home
                                       #:stateless? stateless?
                                       #:uid uid #:gid gid
                                       #:store (string-append tmp "/store")
                                       #:store-items store-items
                                       #:mount-store mount-store))
                    (key-blob (ssh-key-blob ssh-keygen key))
                    (network (socket-file tmp "network"))
                    (wayland-servers wrapper forward-options
                                     (wayland-forwarding
                                      waypipe name (socket-file tmp "waypipe")
                                      (format #f "/run/user/~a/waypipe.sock"
                                              uid)))
                    (spawn-ssh
                     (ssh-spawner ssh (string-append user "@" name)
                                  #:key key #:socat socat #:cid cid
                                  #:port ssh-port
                                  #:send-env (sent-variables secrets)
                                  #:environment
                                  (environment-with
                                   (vm-variables git directory profile
                                                 (secrets-directory data name)
                                                 secrets)))))
               (for-each mkdir-p (map share-directory shares))
               (write-vm-info tmp `((name . ,name)
                                    (directory . ,directory)
                                    (usb? . ,usb?)
                                    (pid . ,(getpid))))
               (call-with-servers
                   `(,(passt-server passt network network-options)
                     ,@wayland-servers
                     ,@(share-servers shares tmp #:unshare unshare
                                      #:virtiofsd virtiofsd #:cache cache))
                 (lambda ()
                   (call-with-vm qemu
                       (qemu-arguments
                        #:kernel kernel #:initrd initrd
                        #:kernel-arguments
                        (vm-kernel-arguments key-blob stateless?
                                             kernel-arguments)
                        #:memory memory #:cpus cpus #:cid cid
                        #:network network
                        #:serial (serial-options log serial)
                        #:devices (share-devices shares tmp)
                        #:usb? usb?
                        #:qmp (qmp-socket-file tmp))
                       log
                     (cut boot-and-run spawn-ssh <>
                          (remote-command command wrapper %status-file)
                          #:boot-timeout boot-timeout
                          ;; A stateless VM's log is deleted on exit, so
                          ;; show it.
                          #:on-boot-failure (boot-failure-handler
                                             log #:show-log? stateless?)
                          #:ssh-options (cons "-t" forward-options)))))))))))))
