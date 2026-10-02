(define-module (guix-microvm build microvm)
  #:use-module (guix build syscalls)
  #:use-module (guix build utils)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-71)
  #:use-module (web uri)
  #:export (contains-home?
            mount-store-items
            run-microvm))

(define %program-name
  (make-parameter "run-vm"))

(define (fail message . args)
  (apply format (current-error-port)
         (string-append (%program-name) ": " message "~%") args)
  (exit 1))

(define (getenv* name default)
  (or (getenv name) default))

(define (getenv-number name default)
  (match (getenv name)
    (#f default)
    (value (or (string->number value)
               (fail "~a is not a number: ~a" name value)))))

(define (parse-arguments args)
  "Return whether ARGS allow sharing the home directory, and the directory and
command they specify."
  (match args
    (("--share-home" rest ...)
     (let ((_ directory command (parse-arguments rest)))
       (values #t directory command)))
    (() (values #f "." '()))
    (("--" command ...) (values #f "." command))
    ((directory) (values #f directory '()))
    ((directory "--" command ...) (values #f directory command))
    (_
     (format (current-error-port)
             "Usage: ~a [--share-home] [DIR] [-- COMMAND...]~%"
             (%program-name))
     (exit 2))))

(define (contains-home? directory)
  "Return true if DIRECTORY is the home directory or one of its parents."
  (let ((home (canonicalize-path (getenv "HOME"))))
    (or (string=? directory "/")
        (string=? directory home)
        (string-prefix? (string-append directory "/") home))))

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

(define (set-git-identity! git directory)
  "Set the unset GIT_AUTHOR_* and GIT_COMMITTER_* variables from DIRECTORY's
Git configuration."
  (define (default! name value)
    (when (and value (not (getenv name)))
      (setenv name value)))
  (default! "GIT_AUTHOR_NAME" (git-config git directory "user.name"))
  (default! "GIT_AUTHOR_EMAIL" (git-config git directory "user.email"))
  (default! "GIT_COMMITTER_NAME" (getenv "GIT_AUTHOR_NAME"))
  (default! "GIT_COMMITTER_EMAIL" (getenv "GIT_AUTHOR_EMAIL")))

(define (load-secrets! directory names)
  "Set the variables NAMES to the contents of the files of the same names in
DIRECTORY, for those that exist."
  (for-each (lambda (name)
              (let ((file (string-append directory "/" name)))
                (when (file-exists? file)
                  (setenv name (string-trim-right
                                (call-with-input-file file get-string-all))))))
            names))

(define (shell-quote str)
  (string-append "'" (string-join (string-split str #\') "'\\''") "'"))

(define %null-port
  (delay (open-file "/dev/null" "r+")))

(define (exit-status status)
  (or (status:exit-val status)
      (+ 128 (status:term-sig status))))

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

(define (call-with-temporary-directory proc)
  ;; In XDG_RUNTIME_DIR: socket file names are limited to 107 bytes.
  (let ((directory (mkdtemp (string-append (getenv* "XDG_RUNTIME_DIR" "/tmp")
                                           "/guix-microvm.XXXXXX"))))
    (dynamic-wind
      (const #t)
      (cut proc directory)
      (cut delete-file-recursively directory))))

(define (call-with-processes proc)
  "Call PROC with a procedure that starts a program with the given arguments
and returns its PID.  Stop the programs when PROC returns or exits."
  (define pids '())
  (dynamic-wind
    (const #t)
    (lambda ()
      (proc (lambda (program . args)
              (let ((pid (spawn program (cons program args)
                                #:input (force %null-port))))
                (set! pids (cons pid pids))
                pid))))
    (lambda ()
      (for-each (lambda (pid)
                  (false-if-exception (kill pid SIGTERM))
                  (false-if-exception (waitpid pid)))
                pids))))

(define (overflow-id kind)
  "Return the ID unmapped users or groups have in a user namespace, KIND being
\"uid\" or \"gid\"."
  (call-with-input-file (string-append "/proc/sys/kernel/overflow" kind)
    read))

(define* (ssh-arguments destination command
                        #:key key socat cid port (send-env '())
                        (options '()))
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

(define (remote-command command wrapper status-file)
  "Return the shell command that runs COMMAND, or a login shell if it is
empty, in /work, prefixed by WRAPPER, and writes its exit status to
STATUS-FILE."
  (string-append "cd /work && "
                 (string-join (append wrapper
                                      (if (null? command)
                                          '("\"$SHELL\"" "-l")
                                          (map shell-quote command))))
                 "; echo $? > " status-file))

(define (serial-options log)
  "Return QEMU's options for the serial console, appended to LOG unless
VM_SERIAL names another chardev."
  (match (getenv "VM_SERIAL")
    (#f `("-chardev" ,(string-append "file,id=serial,path=" log ",append=on")
          "-serial" "chardev:serial"))
    (serial `("-serial" ,serial))))

(define* (qemu-arguments #:key kernel initrd kernel-arguments memory cpus cid
                         network serial devices)
  "Return QEMU's arguments to boot KERNEL on a microvm with MEMORY MiB and
CPUS, the vsock address CID, the NIC served at NETWORK, and DEVICES."
  `("-M" "microvm,acpi=off,rtc=on,memory-backend=mem"
    "-cpu" "host" "-enable-kvm"
    "-m" ,(number->string memory) "-smp" ,(number->string cpus)
    "-object" ,(format #f "memory-backend-memfd,id=mem,size=~aM,share=on"
                       memory)
    "-nodefaults" "-no-user-config" "-no-reboot"
    "-display" "none" "-monitor" "none"
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

(define* (run-microvm args
                      #:key name default-command kernel initrd
                      kernel-arguments store-items profile
                      memory-size cpu-count user uid gid ssh-port
                      network-options
                      qemu virtiofsd passt waypipe ssh ssh-keygen socat git
                      unshare mount-store secrets)
  "Run the microvm NAME with the command line ARGS, and return the exit status
of the command run in it, by default DEFAULT-COMMAND.  With WAYPIPE, Wayland
clients in the VM show on the host's Wayland display."
  (parameterize ((%program-name (string-append "run-" name)))
    (let* ((share-home? directory command (parse-arguments args))
           (directory (if (directory-exists? directory)
                          (canonicalize-path directory)
                          (fail "~a is not a directory" directory)))
           (command (if (null? command) default-command command)))
      (when (and (not share-home?) (contains-home? directory))
        (fail "not sharing ~a, which contains the home directory, without \
--share-home" directory))
      (when (and waypipe (not (getenv "WAYLAND_DISPLAY")))
        (fail "WAYLAND_DISPLAY is not set: ~a needs a Wayland session" name))
      (check-devices!)

      (let* ((state (string-append (getenv* "XDG_DATA_HOME"
                                            (string-append (getenv "HOME")
                                                           "/.local/share"))
                                   "/guix-microvm"))
             (home (string-append state "/" name "/" (uri-encode directory)))
             (log (string-append home ".log"))
             (key (string-append state "/ssh/id_ed25519"))
             (key-blob (ssh-key-blob ssh-keygen key))
             ;; Unique among running VMs, as this process' PID.
             (cid (number->string (getpid)))
             (guest-waypipe-socket (format #f "/run/user/~a/waypipe.sock"
                                           uid))
             (status-file "/tmp/guix-microvm-status"))
        (define (ssh-arguments* options command)
          (ssh-arguments (string-append user "@" name) command
                         #:key key #:socat socat #:cid cid #:port ssh-port
                         #:send-env `("LANG" "COLORTERM" "GIT_AUTHOR_*"
                                      "GIT_COMMITTER_*" "GUIX_MICROVM_PROFILE"
                                      ,@secrets)
                         #:options options))

        (define batch-options
          '("-n" "-o" "BatchMode=yes" "-o" "ConnectTimeout=5"))

        (define (ssh-status options command)
          (exit-status
           (cdr (waitpid (spawn ssh (ssh-arguments* options command))))))

        (define (ssh-succeeds? command)
          (zero? (exit-status
                  (cdr (waitpid (spawn ssh (ssh-arguments* batch-options
                                                           command)
                                       #:output (force %null-port)
                                       #:error (force %null-port)))))))

        (define (ssh-output command)
          (match (pipe)
            ((in . out)
             (let ((pid (spawn ssh (ssh-arguments* batch-options command)
                               #:output out #:error (force %null-port))))
               (close-port out)
               (let ((output (get-string-all in)))
                 (close-port in)
                 (waitpid pid)
                 output)))))

        (set-git-identity! git directory)
        (when profile
          (setenv "GUIX_MICROVM_PROFILE" profile))
        (load-secrets! (string-append state "/" name "/secrets") secrets)
        (mkdir-p home)
        (exit-on-signals!)

        (call-with-temporary-directory
         (lambda (tmp)
           (call-with-processes
            (lambda (start)
              ;; virtiofsd runs sandboxed, as root of a user namespace in
              ;; which the host user is root and other users are nobody.
              ;; It maps the guest's UID and GID with UID-MAP and GID-MAP.
              ;; Return QEMU's options for the share.
              (define* (virtiofs tag shared #:key (wrapper '())
                                 uid-map gid-map (options '()))
                (let ((socket (string-append tmp "/" tag ".sock")))
                  (wait-for-socket
                   socket
                   (apply start unshare "--user" "--map-root-user" "--mount"
                          `(,@wrapper
                            ,virtiofsd "--shared-dir" ,shared
                            "--socket-path" ,socket "--sandbox" "namespace"
                            "--log-level" "error"
                            "--cache" ,(getenv* "VM_FS_CACHE" "auto")
                            "--translate-uid" ,uid-map
                            "--translate-gid" ,gid-map
                            ,@options)))
                  (list "-chardev"
                        (string-append "socket,id=" tag ",path=" socket)
                        "-device"
                        (string-append "vhost-user-fs-device,chardev=" tag
                                       ",tag=" tag))))

              ;; The guest user owns the host user's files.
              (define (owned-share tag shared)
                (virtiofs tag shared
                          #:uid-map (format #f "map:~a:0:1" uid)
                          #:gid-map (format #f "map:~a:0:1" gid)))

              ;; Only the store items the VM needs, owned by root as on the
              ;; host, where they are nobody's in the namespace.
              (define (store-share)
                (let ((root (string-append tmp "/store")))
                  (mkdir root)
                  (virtiofs "store" root
                            #:wrapper (list mount-store store-items root)
                            #:uid-map (format #f "map:0:~a:1"
                                              (overflow-id "uid"))
                            #:gid-map (format #f "map:0:~a:1"
                                              (overflow-id "gid"))
                            #:options '("--readonly"))))

              (define network (string-append tmp "/network.sock"))
              (define waypipe-socket (string-append tmp "/waypipe.sock"))

              (wait-for-socket
               network
               (apply start passt
                      "--foreground" "--quiet" "--one-off" "--no-dhcp"
                      "--no-map-gw" "--socket" network
                      network-options))

              ;; Forwarded to the guest by the SSH session running the
              ;; command, rather than over vsock, where other guests could
              ;; connect.  The security context keeps privileged protocols,
              ;; e.g. screen capture, from the guest, if the compositor
              ;; supports it.
              (when waypipe
                (wait-for-socket
                 waypipe-socket
                 (start waypipe "--socket" waypipe-socket "--no-gpu"
                        "--secctx" (string-append "guix-microvm." name)
                        "client")))

              (define arguments
                (qemu-arguments
                 #:kernel kernel #:initrd initrd
                 #:kernel-arguments
                 (cons* "console=ttyS0"
                        (string-append "guix-microvm.ssh-key=" key-blob)
                        kernel-arguments)
                 #:memory (getenv-number "VM_MEMORY" memory-size)
                 #:cpus (getenv-number "VM_CPUS" cpu-count)
                 #:cid cid
                 #:network network
                 #:serial (serial-options log)
                 #:devices (append (store-share)
                                   (owned-share "work" directory)
                                   (owned-share "home" home))))

              ;; QEMU's own messages, e.g. about being stopped, go to the
              ;; log too, after the serial console's.
              (define vm
                (call-with-port (begin
                                  (call-with-output-file log (const #t))
                                  (open-file log "a"))
                  (lambda (port)
                    (parameterize ((current-error-port port))
                      (apply start qemu arguments)))))

              (define deadline
                (+ (current-time) (getenv-number "VM_BOOT_TIMEOUT" 120)))

              (let loop ()
                (unless (ssh-succeeds? "true")
                  (unless (alive? vm)
                    (fail "the VM exited, see ~a" log))
                  (when (> (current-time) deadline)
                    (fail "no SSH connection to the VM, see ~a" log))
                  (sleep 1)
                  (loop)))

              (let ((status
                     (ssh-status
                      (if waypipe
                          (list "-t" "-o" "ExitOnForwardFailure=yes"
                                "-R" (string-append guest-waypipe-socket ":"
                                                    waypipe-socket))
                          '("-t"))
                      (remote-command command
                                      (if waypipe
                                          (list waypipe "--socket"
                                                guest-waypipe-socket
                                                "--no-gpu" "server" "--")
                                          '())
                                      status-file))))
                ;; Flush what the guest wrote to the shares before QEMU is
                ;; stopped, and get the command's exit status, which ssh
                ;; cannot tell apart from its own.
                (or (string->number
                     (string-trim-both
                      (ssh-output (string-append "sync; cat " status-file))))
                    (begin
                      (format (current-error-port)
                              "~a: lost the connection to the VM~%"
                              (%program-name))
                      status)))))))))))
