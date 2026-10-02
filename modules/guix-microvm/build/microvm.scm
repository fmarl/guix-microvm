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
  #:export (contains-home?
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
  "Call THUNK, or report the launcher error it raises and return its exit
status."
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
  "Return the flags ARGS set, as a list of strings, and the directory and
command they specify."
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

(define (contains-home? directory home)
  "Return true if DIRECTORY is HOME or one of its parents."
  (or (string=? directory "/")
      (string=? directory home)
      (string-prefix? (string-append directory "/") home)))

(define (mount-store-items items root)
  "Mount the store items listed in the file ITEMS on a tmpfs at ROOT.  This
requires a mount namespace of one's own."
  (mount "none" root "tmpfs" 0 "mode=755")
  (for-each (lambda (item)
              (let ((target (string-append root "/" (basename item))))
                (if (file-is-directory? item)
                    (mkdir target)
                    (call-with-output-file target (const #t)))
                (mount item target "none" (logior MS_BIND MS_REC))))
            (string-tokenize (call-with-input-file items get-string-all))))

(define (vm-files data tmp name directory stateless?)
  "Return the home directory, console log and SSH key of the VM NAME sharing
DIRECTORY: in DATA, or in TMP if STATELESS?."
  (if stateless?
      (values (string-append tmp "/home")
              (string-append tmp "/console.log")
              (string-append tmp "/id_ed25519"))
      (let ((home (string-append data "/" name "/" (uri-encode directory))))
        (values home
                (string-append home ".log")
                (string-append data "/ssh/id_ed25519")))))

(define (data-directory home)
  "Return the directory of the VMs' files, given the user's HOME."
  (string-append (getenv* "XDG_DATA_HOME" (string-append home "/.local/share"))
                 "/guix-microvm"))

(define (secrets-directory data name)
  "Return the directory of the secrets of the VM NAME, in DATA."
  (string-append data "/" name "/secrets"))

(define (ssh-key-blob ssh-keygen key)
  "Return the Base64 part of the public Ed25519 KEY, creating KEY unless it
exists."
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
  "Return the GIT_AUTHOR_* and GIT_COMMITTER_* variables, as an alist, taken
from the environment or else DIRECTORY's Git configuration."
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
  "Return the contents of the files NAMES in DIRECTORY, for those that exist,
as an alist of names and contents."
  (filter-map (lambda (name)
                (let ((file (string-append directory "/" name)))
                  (and (file-exists? file)
                       (cons name
                             (string-trim-right
                              (call-with-input-file file get-string-all))))))
              names))

(define (environment-with variables)
  "Return the environment of this process, as 'environ' does, with VARIABLES,
an alist of names and values, set."
  (define (entry-name entry)
    (string-take entry (or (string-index entry #\=) (string-length entry))))

  (append (map (match-lambda
                 ((name . value) (string-append name "=" value)))
               variables)
          (remove (lambda (entry)
                    (assoc (entry-name entry) variables))
                  (environ))))

(define (vm-variables git directory profile secrets-directory secrets)
  "Return the variables for the VM, as an alist: the Git identity for
DIRECTORY, the project's PROFILE, if any, and the SECRETS in
SECRETS-DIRECTORY."
  (append (git-identity git directory)
          (if profile
              `(("GUIX_MICROVM_PROFILE" . ,profile))
              '())
          (read-secrets secrets-directory secrets)))

(define (sent-variables secrets)
  "Return the patterns of the variables ssh sends to the VM, with SECRETS."
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
  "Wait for the process PID to exit and return its exit status."
  (exit-status (cdr (waitpid pid))))

(define (alive? pid)
  (match (waitpid pid WNOHANG)
    ((0 . _) #t)
    (_ #f)))

(define (wait-for-socket file pid)
  (let loop ()
    (unless (file-exists? file)
      (unless (alive? pid)
        (fail "no ~a, the program serving it exited" file))
      (usleep 100000)
      (loop))))

(define (runtime-directory)
  (getenv* "XDG_RUNTIME_DIR" "/tmp"))

;; That of the directories of the running VMs in the runtime directory.
(define %vm-directory-prefix "guix-microvm.")

(define (call-with-temporary-directory parent proc)
  "Call PROC with a new directory in PARENT, deleted when PROC returns or
exits."
  (let ((directory (mkdtemp (string-append parent "/" %vm-directory-prefix
                                           "XXXXXX"))))
    (dynamic-wind
      (const #t)
      (cut proc directory)
      (cut delete-file-recursively directory))))

(define* (call-with-process program args proc
                            #:key (error (current-error-port)))
  "Start PROGRAM with ARGS and its standard error to ERROR, call PROC with its
PID, and stop it when PROC returns or exits."
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
  "Start SERVERS one after the other, call THUNK once all serve, and stop
them when it returns or exits."
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
  "Return the QMP socket of the VM whose files are in DIRECTORY."
  (socket-file directory "qmp"))

(define (vm-info-file directory)
  "Return the file describing the VM whose files are in DIRECTORY, as an
alist."
  (string-append directory "/vm"))

(define (write-vm-info directory info)
  (call-with-output-file (vm-info-file directory)
    (cut write info <>)))

(define (passt-server passt socket options)
  "Return the server of the network at SOCKET, with the passt OPTIONS."
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
  "Return virtiofsd's options to map GUEST-UID and GUEST-GID to HOST-UID and
HOST-GID of its user namespace."
  (list "--translate-uid" (format #f "map:~a:~a:1" guest-uid host-uid)
        "--translate-gid" (format #f "map:~a:~a:1" guest-gid host-gid)))

(define (overflow-id kind)
  "Return the ID unmapped users or groups have in a user namespace, KIND being
\"uid\" or \"gid\"."
  (call-with-input-file (string-append "/proc/sys/kernel/overflow" kind)
    read))

(define* (vm-shares #:key directory home stateless? uid gid
                    store store-items mount-store)
  "Return the shares of the VM: STORE-ITEMS at STORE, mounted there by
MOUNT-STORE, and DIRECTORY and HOME, owned by UID and GID in the VM, the
former read-only if STATELESS?."
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
  "Return the server of SHARE at SOCKET."
  (server unshare
          `("--user" "--map-root-user" "--mount"
            ,@(share-wrapper share)
            ,virtiofsd "--shared-dir" ,(share-directory share)
            "--socket-path" ,socket
            "--sandbox" "namespace" "--log-level" "error" "--cache" ,cache
            ,@(share-options share))
          socket))

(define (virtiofs-device share socket)
  "Return QEMU's options for the virtio-fs device of SHARE served at SOCKET."
  (let ((tag (share-tag share)))
    (list "-chardev" (string-append "socket,id=" tag ",path=" socket)
          "-device" (string-append "vhost-user-fs-device,chardev=" tag
                                   ",tag=" tag))))

;; Forwarded over SSH, not vsock, which other guests can reach.
(define (wayland-forwarding waypipe name socket guest-socket)
  "Return the servers, the command wrapper and the ssh options that show the
Wayland clients of the VM NAME on the host's display, through SOCKET on the
host and GUEST-SOCKET in the VM, or nothing without WAYPIPE."
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
  "Return the arguments of ssh to run COMMAND at DESTINATION, reached over
vsock at CID and PORT with KEY."
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
  "Return a procedure that spawns SSH to run a command at DESTINATION, reached
over vsock at CID and PORT with KEY, sending the variables SEND-ENV of
ENVIRONMENT, and returns its PID.  It takes ssh's additional OPTIONS and the
OUTPUT and ERROR ports."
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
  "Return the shell command that runs COMMAND, or a login shell if it is
empty, in /work, under WRAPPER, and writes its exit status to STATUS-FILE."
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
  "Return QEMU's options for the serial console, appended to LOG unless
SERIAL names another chardev."
  (match serial
    (#f `("-chardev" ,(string-append "file,id=serial,path=" log ",append=on")
          "-serial" "chardev:serial"))
    (serial `("-serial" ,serial))))

(define* (qemu-arguments #:key kernel initrd kernel-arguments memory cpus cid
                         network serial devices usb? qmp)
  "Return QEMU's arguments to boot KERNEL on a microvm with MEMORY MiB and
CPUS, the vsock address CID, the NIC served at NETWORK, DEVICES and the QMP
socket QMP.  USB? adds a USB controller, which needs ACPI."
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
  "Return a port appending to FILE, emptied first.  QEMU appends its serial
console to it too."
  (let ((port (open-file file "a")))
    (truncate-file port 0)
    port))

(define (vm-kernel-arguments key-blob stateless? kernel-arguments)
  "Return the kernel command line of the VM, as a list, with KERNEL-ARGUMENTS
and the SSH key KEY-BLOB."
  ;; With -no-reboot, QEMU exits on a panic.
  `("console=ttyS0" "panic=-1"
    ,(string-append "guix-microvm.ssh-key=" key-blob)
    ,@(if stateless? '("guix-microvm.stateless=1") '())
    ,@kernel-arguments))

(define (call-with-vm qemu arguments log proc)
  "Start QEMU with ARGUMENTS and its standard error appended to LOG, call
PROC with its PID, and stop it when PROC returns or exits."
  (call-with-port (open-log log)
    (lambda (port)
      (call-with-process qemu arguments proc #:error port))))

(define* (boot-failure-handler log #:key show-log?)
  "Return a procedure that fails with a message about the boot of the VM,
whose console is in LOG, showing LOG if SHOW-LOG? or else naming it."
  (lambda (message)
    (if show-log?
        (begin
          (display (call-with-input-file log get-string-all)
                   (current-error-port))
          (fail message))
        (fail (string-append message ", see ~a") log))))

(define (wait-for-boot spawn-ssh vm timeout on-failure)
  "Wait until the VM, whose QEMU process is VM, accepts SSH connections, or
call ON-FAILURE with a message if it exits or TIMEOUT seconds pass first."
  (let ((deadline (+ (current-time) timeout)))
    (let loop ()
      (unless (ssh-succeeds? spawn-ssh "true")
        (cond ((not (alive? vm))
               (on-failure "the VM exited"))
              ((> (current-time) deadline)
               (on-failure "no SSH connection to the VM"))
              (else
               (sleep 1)
               (loop)))))))

(define (run-remote spawn-ssh command options status-file)
  "Run the shell COMMAND, which writes its exit status to STATUS-FILE, with
the ssh OPTIONS, and return that status."
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
  "Exit, which stops the VM, on the signals that would otherwise kill this
process."
  (for-each (lambda (signal)
              (sigaction signal
                (lambda (signal)
                  (exit (+ 128 signal)))))
            (list SIGINT SIGTERM SIGHUP)))

(define (check-host! directory share-home? name waypipe)
  "Fail unless the host can run the VM NAME sharing DIRECTORY."
  (when (and (not share-home?)
             (contains-home? directory (canonicalize-path (getenv "HOME"))))
    (fail "not sharing ~a, which contains the home directory, without \
--share-home" directory))
  (when (and waypipe (not (getenv "WAYLAND_DISPLAY")))
    (fail "WAYLAND_DISPLAY is not set: ~a needs a Wayland session" name))
  (check-devices!))

(define %status-file "/tmp/guix-microvm-status")

(define* (share-servers shares tmp #:key unshare virtiofsd cache)
  "Return the servers of SHARES, with their sockets in TMP."
  (map (lambda (share)
         (virtiofs-server share (share-socket tmp share)
                          #:unshare unshare #:virtiofsd virtiofsd
                          #:cache cache))
       shares))

(define (share-devices shares tmp)
  "Return QEMU's options for the devices of SHARES, served in TMP."
  (append-map (lambda (share)
                (virtiofs-device share (share-socket tmp share)))
              shares))

(define* (boot-and-run spawn-ssh vm command
                       #:key boot-timeout on-boot-failure ssh-options)
  "Wait for the VM, whose QEMU process is VM, to boot, run the shell COMMAND
in it with SSH-OPTIONS, and return its exit status."
  (wait-for-boot spawn-ssh vm boot-timeout on-boot-failure)
  (run-remote spawn-ssh command ssh-options %status-file))

(define* (run-microvm args
                      #:key name default-command stateless? kernel initrd
                      kernel-arguments store-items profile
                      memory-size cpu-count user uid gid ssh-port
                      network-options
                      qemu virtiofsd passt waypipe ssh ssh-keygen socat git
                      unshare mount-store secrets usb?)
  "Run the microvm NAME with the command line ARGS, and return the exit status
of the command run in it, by default DEFAULT-COMMAND.  With WAYPIPE, Wayland
clients in the VM show on the host's Wayland display.  STATELESS?, or
--stateless, gives the VM a fresh home and discards its changes to DIR.  USB?
gives it a USB controller, for 'guix microvm usb' to attach host devices to."
  (parameterize ((%program-name (string-append "run-" name)))
    (call-with-launcher-errors
     (lambda ()
       (let* ((flags directory command (parse-arguments args))
              (stateless? (or stateless? (member "--stateless" flags)))
              (directory (existing-directory directory))
              (command (if (null? command) default-command command))
              (data (data-directory (canonicalize-path (getenv "HOME"))))
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
