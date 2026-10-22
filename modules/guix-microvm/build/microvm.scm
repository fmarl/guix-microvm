;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build microvm)
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module (guix records)
  #:use-module ((ice-9 exceptions) #:select (exception-message))
  #:use-module (ice-9 match)
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-71)
  #:use-module ((web uri) #:select (uri-encode))
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build files)
  #:use-module ((guix-microvm build git) #:select (git-identity))
  #:use-module (guix-microvm build invocation)
  #:use-module (guix-microvm build layer)
  #:use-module (guix-microvm build process)
  #:use-module (guix-microvm build qemu)
  #:use-module (guix-microvm build registry)
  #:use-module (guix-microvm build review)
  #:use-module (guix-microvm build shares)
  #:use-module (guix-microvm build ssh)
  #:use-module (guix-microvm build state)
  #:use-module (guix-microvm build terminal)
  #:re-export (vm-config tools)
  #:export (run-microvm))

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

(define (network-socket-file directory config)
  (and (vm-config-network-options config)
       (socket-file directory "network")))

(define (guest-status-file guest-runtime-directory)
  ;; Only the guest user can write there, so other guest users cannot fake
  ;; it.
  (string-append guest-runtime-directory "/guix-microvm-status"))

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

(define (vm-ssh config name tools data directory key known-hosts cid)
  "Return how ssh reaches the VM CONFIG named NAME, as an alist."
  (match-record config <vm-config> (user ssh-port profile secrets)
    `((program . ,(tools-ssh tools))
      (options . ,(ssh-options #:key key #:known-hosts known-hosts
                               #:socat (tools-socat tools) #:cid cid
                               #:port ssh-port
                               #:send-env (send-env-patterns secrets)))
      (destination . ,(string-append user "@" name))
      (variables . ,(vm-variables (tools-git tools) directory profile))
      ;; Read when sending them, to keep them out of the VM's info file.
      (secrets . (,(secrets-directory data (vm-config-name config))
                  ,@secrets)))))

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

(define* (vm-qemu-arguments directory invocation config shares
                            #:key key-blob cid log)
  (match-record invocation <invocation> (volatile? name memory cpus serial)
    (match-record config <vm-config> (kernel initrd kernel-arguments usb?)
      (qemu-arguments #:kernel kernel #:initrd initrd
                      #:kernel-arguments
                      (vm-kernel-arguments key-blob volatile? name
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

(define (printable str)
  "Return STR without carriage returns and with control characters other
than newline and tab replaced by ?."
  (string-map (lambda (char)
                (if (and (char-set-contains? char-set:iso-control char)
                         (not (memv char '(#\newline #\tab))))
                    #\?
                    char))
              (string-delete #\return str)))

(define* (call-with-boot-log log thunk #:key show-log?)
  "Call THUNK.  On a boot failure, print the console LOG if SHOW-LOG?, or
else name it."
  (with-exception-handler
      (lambda (error)
        (let ((message (exception-message error)))
          (if show-log?
              (begin
                (display (printable (call-with-input-file log get-string-all))
                         (current-error-port))
                (fail "~a" message))
              (fail "~a, see ~a" message log))))
    thunk
    #:unwind? #t
    #:unwind-for-type &boot-failure))

(define (wait-for-boot spawn-ssh qemu timeout)
  "Wait until the VM of the QEMU process accepts SSH.  Raise a boot failure
if QEMU exits or TIMEOUT seconds pass first."
  (let ((deadline (+ (current-time) timeout)))
    (let loop ()
      (unless (ssh-succeeds? spawn-ssh "true")
        (cond ((not (child-alive? qemu))
               (boot-failure "the VM exited"))
              ((> (current-time) deadline)
               (boot-failure "no SSH connection to the VM"))
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

(define (wait-until-killed qemu)
  (let loop ()
    (unless (exits-within? qemu 60)
      (loop))))

(define (check-devices)
  ;; Without KVM, QEMU would keep running stale translated code for pages
  ;; virtiofsd writes into guest memory.
  (for-each (lambda (device)
              (unless (access? device (logior R_OK W_OK))
                (fail "~a is not accessible" device)))
            '("/dev/kvm" "/dev/vhost-vsock")))

(define (check-host invocation waypipe)
  "Fail unless the host can run INVOCATION, with WAYPIPE if it is
graphical."
  (unless (invocation-volatile? invocation)
    (check-shareable (invocation-directory invocation)))
  (when (and waypipe (not (getenv "WAYLAND_DISPLAY")))
    (fail "WAYLAND_DISPLAY is not set: ~a needs a Wayland session"
          (invocation-name invocation)))
  (check-devices))

(define (check-policy invocation)
  (when (and (not (invocation-volatile? invocation))
             (eq? 'ask (invocation-policy invocation))
             (not (invocation-interactive? invocation)))
    (fail "without a terminal to ask about its changes, pass --merge or \
--discard")))

(define (run-vm tmp invocation config tools layer detach)
  "Run INVOCATION of the VM CONFIG in TMP, sharing the project through LAYER
unless it is #f.  Return the command's exit status and whether it detached.
If DETACH is a procedure, call it with the status of the login shell, then
wait until the VM is killed."
  (match-record invocation <invocation> (directory name command stateless?
                                         volatile? cache)
    (match-record config <vm-config> (uid gid usb? store-items
                                      guest-runtime-directory)
      (let* ((data (data-directory))
             (home log key (vm-files data tmp (vm-config-name config)
                                     directory stateless?))
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
             (ssh (vm-ssh config name tools data directory key known-hosts
                          cid))
             (spawn-ssh (vm-ssh-spawner ssh))
             (status-file (guest-status-file guest-runtime-directory))
             (vm (running-vm
                   (state-directory tmp)
                   (name name)
                   (directory directory)
                   (usb? usb?)
                   (volatile? volatile?)
                   (ssh ssh)
                   (launcher (canonicalize-path (car (command-line))))
                   (started (current-time)))))
        (define (boot qemu)
          (wait-for-boot spawn-ssh qemu (invocation-boot-timeout invocation))
          (let ((status
                 (run-remote spawn-ssh qemu
                             (remote-command command wrapper status-file)
                             (cons "-t" forward-options) status-file)))
            (if (and detach (child-alive? qemu))
                (begin
                  (format (current-error-port) "~a: runs on; 'guix \
microvm attach' opens a shell, 'guix microvm kill' stops it~%"
                          (%program-name))
                  (register! (running-vm (inherit vm) (detached? #t)))
                  (detach status)
                  (wait-until-killed qemu)
                  (values status #t))
                (values status #f))))

        (write-known-hosts! known-hosts
                            (ssh-key-blob (tools-ssh-keygen tools) host-key))
        (for-each mkdir-p (map share-directory shares))
        (call-with-registration vm
          (lambda ()
            (call-with-port (open-log log)
              (lambda (port)
                (call-with-boot-log log
                  (lambda ()
                    (call-with-servers servers
                        (lambda ()
                          (call-with-process (tools-qemu tools)
                              (vm-qemu-arguments tmp invocation config shares
                                                 #:key-blob key-blob #:cid cid
                                                 #:log log)
                            boot
                            #:output port #:error port))
                      #:log port))
                  #:show-log? stateless?)))))))))

(define (effective-policy policy interactive?)
  "Return POLICY, or 'keep for 'ask unless INTERACTIVE?."
  (if (and (eq? policy 'ask) (not interactive?))
      'keep
      policy))

(define (call-with-project invocation config tools proc)
  "Call PROC with the layer over the project, or #f for a volatile VM, then
resolve its changes.  PROC returns an exit status and whether it detached
from the terminal.  Return that status, or 1 if merging failed."
  (define directory
    (invocation-directory invocation))

  (define interactive?
    (invocation-interactive? invocation))

  (define* (resolve! layer policy #:key previous?)
    (resolve-layer! layer
                    #:git (tools-git tools)
                    #:policy policy
                    #:protected-files (vm-config-protected-files config)
                    #:previous? previous?))

  (if (invocation-volatile? invocation)
      (call-with-values (cut proc #f)
        (lambda (status . _) status))
      (let ((data (data-directory)))
        (call-with-project-lock data directory
          (lambda ()
            ;; Asked even with --merge or --discard, which are meant for
            ;; this run.
            (for-each (lambda (layer)
                        (when (memq (resolve! layer
                                              (effective-policy 'ask
                                                                interactive?)
                                              #:previous? #t)
                                    '(kept conflict incomplete))
                          (fail "the changes of a previous VM on ~a are left; \
decide on them in a terminal" directory)))
                      (project-layers data directory))
            (let* ((layer (create-layer! data directory #:cp (tools-cp tools)))
                   (status detached? (proc layer)))
              (if (memq (resolve! layer
                                  (effective-policy
                                   (invocation-policy invocation)
                                   (and interactive? (not detached?))))
                        '(conflict incomplete))
                  1
                  status)))))))

(define (call-with-program-name name thunk)
  (parameterize ((%program-name name))
    (call-with-launcher-errors thunk)))

(define (resolve-project args config tools)
  "Resolve the changes left on the project in ARGS once its VM is gone.
Return 1 if some could not be merged."
  (let* ((flags requested-directory command (parse-arguments args))
         (directory (existing-directory requested-directory))
         (data (data-directory))
         (interactive? (isatty? (current-input-port)))
         (policy (match (cons command (remove valued-flag? flags))
                   ((()) (effective-policy 'ask interactive?))
                   ((() "--merge") 'merge)
                   ((() "--discard") 'discard)
                   (_ (usage-error "--resolve [--name=NAME] \
[--merge|--discard] DIR")))))
    (call-with-program-name (or (flag-value "name" flags)
                                (default-name directory config))
      (lambda ()
        (call-with-project-lock data directory
          (lambda ()
            (match (project-layers data directory)
              (()
               (display "no changes left\n")
               0)
              (layers
               (let ((results
                      (map (cut resolve-layer! <>
                                #:git (tools-git tools)
                                #:policy policy
                                #:protected-files
                                (vm-config-protected-files config))
                           layers)))
                 (if (any (cut memq <> '(conflict incomplete)) results)
                     1
                     0)))))
          #:wait? #t)))))

(define (diff-project args config tools)
  "Show the changes left on the project around the directory in ARGS, to
the files in ARGS or to all."
  (let ((tool rest (match args
                     (((? (cut string-prefix? "--tool=" <>) option)
                       rest ...)
                      (values (string-drop option (string-length "--tool="))
                              rest))
                     (_ (values #f args)))))
    (match rest
      ((requested-directory files ...)
       (let* ((directory (existing-directory requested-directory))
              (layer (match (layers-around (data-directory) directory)
                       (() (fail "no microvm left changes on a project \
containing ~a" directory))
                       ((layer) layer)
                       (_ (fail "several microvms left changes on projects \
containing ~a" directory))))
              (project (layer-project layer))
              (cwd (canonicalize-path (getcwd))))
         (show-diff layer
                    (map (lambda (file)
                           (or (file-under project
                                           (if (absolute-file-name? file)
                                               file
                                               (string-append cwd "/" file)))
                               (fail "~a: not in the project ~a"
                                     file project)))
                         files)
                    #:git (tools-git tools)
                    #:tool tool
                    #:protected-files (vm-config-protected-files config))
         0))
      (_ (usage-error "--diff [--tool=COMMAND] DIR [FILE...]")))))

(define (launch args config tools)
  (let* ((parsed (parse-invocation args config))
         (name (unique-name (invocation-name parsed)
                            (map running-vm-name (running-vms))))
         (invocation (invocation (inherit parsed) (name name))))
    (call-with-program-name name
      (lambda ()
        (check-host invocation (tools-waypipe tools))
        (check-policy invocation)
        ;; Without a terminal, nobody would kill it.
        (call-with-detachable (and (null? (invocation-command invocation))
                                   (invocation-interactive? invocation))
          (lambda (detach)
            (exit-on-signals!)
            (call-with-project invocation config tools
              (lambda (layer)
                (call-with-vm-directory
                  (cut run-vm <> invocation config tools layer
                       detach))))))))))

(define (run-microvm args config tools)
  "Run the VM CONFIG with TOOLS as the command line ARGS ask: share DIR at
/work and run COMMAND there, or resolve or show the changes left on DIR.
Return the exit status."
  (call-with-program-name (string-append "run-" (vm-config-name config))
    (lambda ()
      (let* ((options command (break (cut string=? "--" <>) args))
             (root (flag-value "gc-root" options))
             (args (append (remove (cut string-prefix? "--gc-root=" <>)
                                   options)
                           command)))
        (dynamic-wind
          (const #t)
          (lambda ()
            (match args
              (("--resolve" rest ...)
               (resolve-project rest config tools))
              (("--diff" rest ...)
               (diff-project rest config tools))
              (_
               (launch args config tools))))
          (lambda ()
            (when root
              (false-if-exception (delete-file root)))))))))
