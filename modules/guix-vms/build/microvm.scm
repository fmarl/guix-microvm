(define-module (guix-vms build microvm)
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
    (invoke ssh-keygen "-q" "-t" "ed25519" "-N" "" "-C" "guix-vms" "-f" key))
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
                                           "/guix-vms.XXXXXX"))))
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

(define* (run-microvm args
                      #:key name kernel initrd kernel-arguments
                      store-items profile
                      memory-size cpu-count user uid gid ssh-port
                      network-options
                      qemu virtiofsd passt ssh ssh-keygen socat git
                      unshare mount-store secrets)
  "Run the microvm NAME with the command line ARGS, and return the exit status
of the command run in it."
  (parameterize ((%program-name (string-append "run-" name)))
    (let* ((share-home? directory command (parse-arguments args))
           (directory (if (directory-exists? directory)
                          (canonicalize-path directory)
                          (fail "~a is not a directory" directory))))
      (when (and (not share-home?) (contains-home? directory))
        (fail "not sharing ~a, which contains the home directory, without \
--share-home" directory))
      ;; Without KVM, QEMU would keep running stale translated code for pages
      ;; virtiofsd writes into guest memory.
      (for-each (lambda (device)
                  (unless (access? device (logior R_OK W_OK))
                    (fail "~a is not accessible" device)))
                '("/dev/kvm" "/dev/vhost-vsock"))
      (set-git-identity! git directory)
      (when profile
        (setenv "GUIX_VMS_PROFILE" profile))

      (let* ((state (string-append (getenv* "XDG_DATA_HOME"
                                            (string-append (getenv "HOME")
                                                           "/.local/share"))
                                   "/guix-vms"))
             (home (string-append state "/" name "/" (uri-encode directory)))
             (log (string-append home ".log"))
             (key (string-append state "/ssh/id_ed25519"))
             (key-blob (ssh-key-blob ssh-keygen key))
             (memory (number->string (getenv-number "VM_MEMORY" memory-size)))
             ;; Unique among running VMs, as this process' PID.
             (cid (number->string (getpid)))
             (status-file "/tmp/guix-vms-status"))
        (define (ssh-arguments options command)
          `("ssh" "-F" "/dev/null" "-q"
            "-i" ,key "-o" "IdentitiesOnly=yes"
            "-o" "StrictHostKeyChecking=no"
            "-o" "UserKnownHostsFile=/dev/null"
            "-o" "ForwardAgent=no" "-o" "ForwardX11=no"
            "-o" ,(string-join
                   (cons "SendEnv=LANG COLORTERM GIT_AUTHOR_* GIT_COMMITTER_* \
GUIX_VMS_PROFILE"
                         secrets))
            "-o" ,(format #f "ProxyCommand=~a - VSOCK-CONNECT:~a:~a"
                          socat cid ssh-port)
            ,@options
            ,(string-append user "@" name)
            ,command))

        (define* (ssh* options command
                       #:key (output (current-output-port))
                       (error (current-error-port)))
          (exit-status
           (cdr (waitpid (spawn ssh (ssh-arguments options command)
                                #:output output #:error error)))))

        (define batch-options
          '("-n" "-o" "BatchMode=yes" "-o" "ConnectTimeout=5"))

        (define (ssh-output command)
          (match (pipe)
            ((in . out)
             (let ((pid (spawn ssh (ssh-arguments batch-options command)
                               #:output out #:error (force %null-port))))
               (close-port out)
               (let ((output (get-string-all in)))
                 (close-port in)
                 (waitpid pid)
                 output)))))

        (mkdir-p home)
        (load-secrets! (string-append state "/" name "/secrets") secrets)
        (for-each (lambda (signal)
                    (sigaction signal
                      (lambda (signal)
                        (exit (+ 128 signal)))))
                  (list SIGINT SIGTERM SIGHUP))

        (call-with-temporary-directory
         (lambda (tmp)
           (call-with-processes
            (lambda (start)
              ;; virtiofsd runs sandboxed, as root of a user namespace in
              ;; which the host user is root and other users are nobody.
              (define* (virtiofs tag shared #:key (wrapper '()) id-map
                                 (options '()))
                (let ((socket (string-append tmp "/" tag ".sock")))
                  (wait-for-socket
                   socket
                   (apply start unshare "--user" "--map-root-user" "--mount"
                          `(,@wrapper
                            ,virtiofsd "--shared-dir" ,shared
                            "--socket-path" ,socket "--sandbox" "namespace"
                            "--log-level" "error"
                            "--cache" ,(getenv* "VM_FS_CACHE" "auto")
                            "--translate-uid" ,(id-map uid "uid")
                            "--translate-gid" ,(id-map gid "gid")
                            ,@options)))
                  (list "-chardev"
                        (string-append "socket,id=" tag ",path=" socket)
                        "-device"
                        (string-append "vhost-user-fs-device,chardev=" tag
                                       ",tag=" tag))))

              (define (owned-share tag shared)
                (virtiofs tag shared
                          #:id-map (lambda (id _)
                                     (format #f "map:~a:0:1" id))))

              ;; Only the store items the VM needs, owned by root as on the
              ;; host, where they are nobody's in the namespace.
              (define (store-share)
                (let ((root (string-append tmp "/store")))
                  (mkdir root)
                  (virtiofs "store" root
                            #:wrapper (list mount-store store-items root)
                            #:id-map
                            (lambda (_ kind)
                              (format #f "map:0:~a:1"
                                      (call-with-input-file
                                          (string-append
                                           "/proc/sys/kernel/overflow" kind)
                                        read)))
                            #:options '("--readonly"))))

              (define network (string-append tmp "/network.sock"))
              (wait-for-socket
               network
               (apply start passt
                      "--foreground" "--quiet" "--one-off" "--no-dhcp"
                      "--no-map-gw" "--socket" network
                      network-options))

              (define shares
                (append (store-share)
                        (owned-share "work" directory)
                        (owned-share "home" home)))

              (define (start-qemu)
                (apply start qemu
                       `("-M" "microvm,acpi=off,rtc=on,memory-backend=mem"
                         "-cpu" "host" "-enable-kvm" "-m" ,memory
                         "-smp" ,(number->string
                                  (getenv-number "VM_CPUS" cpu-count))
                         "-object" ,(string-append
                                     "memory-backend-memfd,id=mem,size="
                                     memory "M,share=on")
                         "-nodefaults" "-no-user-config" "-no-reboot"
                         "-display" "none" "-monitor" "none"
                         ,@(match (getenv "VM_SERIAL")
                             (#f `("-chardev"
                                   ,(string-append "file,id=serial,path="
                                                   log ",append=on")
                                   "-serial" "chardev:serial"))
                             (serial `("-serial" ,serial)))
                         "-kernel" ,kernel "-initrd" ,initrd
                         "-append" ,(string-join
                                     (cons* "console=ttyS0"
                                            (string-append "guix-vms.ssh-key="
                                                           key-blob)
                                            kernel-arguments))
                         "-object" "rng-random,filename=/dev/urandom,id=rng"
                         "-device" "virtio-rng-device,rng=rng"
                         "-device" ,(string-append
                                     "vhost-vsock-device,guest-cid=" cid)
                         "-netdev" ,(string-append
                                     "stream,id=net,server=off,"
                                     "addr.type=unix,addr.path=" network)
                         "-device" "virtio-net-device,netdev=net"
                         ,@shares)))

              ;; QEMU's own messages, e.g. about being stopped, go to the
              ;; log too, after the serial console's.
              (define vm
                (call-with-port (begin
                                  (call-with-output-file log (const #t))
                                  (open-file log "a"))
                  (lambda (port)
                    (parameterize ((current-error-port port))
                      (start-qemu)))))

              (define deadline
                (+ (current-time) (getenv-number "VM_BOOT_TIMEOUT" 120)))

              (let loop ()
                (unless (zero? (ssh* batch-options "true"
                                     #:output (force %null-port)
                                     #:error (force %null-port)))
                  (unless (alive? vm)
                    (fail "the VM exited, see ~a" log))
                  (when (> (current-time) deadline)
                    (fail "no SSH connection to the VM, see ~a" log))
                  (sleep 1)
                  (loop)))

              (let ((ssh-status
                     (ssh* '("-t")
                           (string-append
                            "cd /work && "
                            (if (null? command)
                                "\"$SHELL\" -l"
                                (string-join (map shell-quote command)))
                            "; echo $? > " status-file))))
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
                      ssh-status)))))))))))
