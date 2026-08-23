;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;; Unit tests of the launcher and the extension, without a VM.

(use-modules (guix-microvm build microvm)
             (guix-microvm base)
             (guix-microvm control)
             (guix-microvm microvm)
             (gnu services)
             ((gnu services base) #:select (static-networking))
             ((gnu system) #:select (operating-system))
             ((guix build utils) #:select (mkdir-p delete-file-recursively))
             ((guix diagnostics)
              #:select (guix-warning-port formatted-message?
                        formatted-message-string
                        formatted-message-arguments))
             (ice-9 match)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 threads)
             (ice-9 textual-ports)
             ((rnrs bytevectors) #:select (string->utf8))
             (srfi srfi-1)
             (srfi srfi-26)
             (srfi srfi-34)
             (srfi srfi-64)
             (srfi srfi-71)
             (json))

(define-syntax-rule (define-private module name ...)
  (begin (define name (@@ module name)) ...))

(define-private (guix-microvm build microvm)
  parse-arguments vm-files git-identity read-secrets environment-with
  shell-quote remote-command serial-options id-map-options virtiofs-device
  qemu-arguments open-log call-with-temporary-directory call-with-process
  call-with-servers server share vm-shares wayland-forwarding
  vm-kernel-arguments existing-directory launcher-error?
  launcher-error-status call-with-launcher-errors fail share-tag
  share-directory share-options share-wrapper server-program server-socket)

(define-private (guix-microvm microvm)
  passt-port-options passt-network-options guest-configuration)

(define-private (guix-microvm control)
  process-exists? usb-id-matches? usb-host-arguments running-vm)

(define-private (guix extensions microvm)
  string->port launcher-flags project-directory read-project project-digest
  allowed-project allowed-projects allow-project! project-allowed?
  project-file project-files eval-file load-object)

(define-syntax-rule (values->list exp)
  (call-with-values (lambda () exp) list))

(define (exit-code thunk)
  "Return the status THUNK exits with or raises as a launcher error, or #f
if it returns."
  (catch 'quit
    (lambda ()
      (guard (error ((launcher-error? error)
                     (launcher-error-status error)))
        (thunk)
        #f))
    (lambda (key status) status)))

(define (quietly thunk)
  (call-with-port (open-file "/dev/null" "w")
    (lambda (null)
      (parameterize ((guix-warning-port null)
                     (current-warning-port null))
        (with-error-to-port null thunk)))))

(define (with-environment variables thunk)
  "Call THUNK with VARIABLES set, an alist of names and values; #f unsets."
  (let ((old (map (match-lambda ((name . _) (cons name (getenv name))))
                  variables)))
    (define (set-all! alist)
      (for-each (match-lambda
                  ((name . #f) (unsetenv name))
                  ((name . value) (setenv name value)))
                alist))
    (dynamic-wind
      (lambda () (set-all! variables))
      thunk
      (lambda () (set-all! old)))))

(define (error-message thunk)
  "Return the message of the error THUNK raises, or #f."
  (guard (error ((formatted-message? error)
                 (string-trim-right
                  (apply format #f (formatted-message-string error)
                         (formatted-message-arguments error)))))
    (thunk)
    #f))

(define (write-file file content)
  (mkdir-p (dirname file))
  (call-with-output-file file (cut display content <>)))

(define (sh-output script)
  (let* ((port (open-pipe* OPEN_READ "sh" "-c" script))
         (output (get-string-all port)))
    (close-pipe port)
    output))

(define (server-script file)
  "Return arguments for sh that write its PID to FILE.pid, create FILE and
sleep."
  `("-c" ,(string-append "echo $$ > " file ".pid; touch " file
                         "; exec sleep 100")))

(define (stopped? pid-file)
  (not (process-exists? (call-with-input-file pid-file read))))

(define (failure-reporter)
  (let ((runner (test-runner-null)))
    (test-runner-on-test-end! runner
      (lambda (runner)
        (when (memq (test-result-kind runner) '(fail xpass))
          (format #t "FAIL: ~a~%~{  ~s~%~}"
                  (test-runner-test-name runner)
                  (test-result-alist runner)))))
    runner))

(test-runner-current (failure-reporter))
(test-begin "unit")

(define tmp
  (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                          "/guix-microvm-test.XXXXXX")))

;;; Command line

(test-equal "parse-arguments, nothing"
  '(() "." ())
  (values->list (parse-arguments '())))

(test-equal "parse-arguments, flags, directory and command"
  '(("--stateless" "--share-home") "/p" ("make" "--" "x"))
  (values->list
   (parse-arguments
    '("--stateless" "--share-home" "/p" "--" "make" "--" "x"))))

(test-equal "parse-arguments, command only"
  '(() "." ("ls"))
  (values->list (parse-arguments '("--" "ls"))))

(test-equal "parse-arguments, usage error"
  2
  (exit-code (lambda ()
               (parse-arguments '("a" "b")))))

(test-equal "existing-directory"
  (list (canonicalize-path tmp) 1)
  (list (existing-directory (string-append tmp "/."))
        (exit-code (lambda ()
                     (existing-directory (string-append tmp "/none"))))))

(test-assert "contains-home?"
  (and (contains-home? "/" "/home/u")
       (contains-home? "/home" "/home/u")
       (contains-home? "/home/u" "/home/u")
       (not (contains-home? "/home/u/src" "/home/u"))
       (not (contains-home? "/home/us" "/home/u"))
       (not (contains-home? "/home/u" "/home/us"))))

;;; Files and environment

(test-equal "vm-files"
  '("/d/vm/%2Fp%20q" "/d/vm/%2Fp%20q.log" "/d/ssh/id_ed25519")
  (values->list (vm-files "/d" "/t" "vm" "/p q" #f)))

(test-equal "vm-files, stateless"
  '("/t/home" "/t/console.log" "/t/id_ed25519")
  (values->list (vm-files "/d" "/t" "vm" "/p" #t)))

(test-equal "git-identity, from the environment"
  '(("GIT_AUTHOR_NAME" . "A") ("GIT_AUTHOR_EMAIL" . "a@x")
    ("GIT_COMMITTER_NAME" . "C") ("GIT_COMMITTER_EMAIL" . "a@x"))
  (with-environment '(("GIT_AUTHOR_NAME" . "A")
                      ("GIT_AUTHOR_EMAIL" . "a@x")
                      ("GIT_COMMITTER_NAME" . "C")
                      ("GIT_COMMITTER_EMAIL" . #f))
    (lambda ()
      (git-identity "/nonexistent/git" tmp))))

(test-equal "git-identity, from the Git configuration"
  '(("GIT_AUTHOR_NAME" . "B") ("GIT_AUTHOR_EMAIL" . "b@x")
    ("GIT_COMMITTER_NAME" . "B") ("GIT_COMMITTER_EMAIL" . "b@x"))
  (let ((repository (string-append tmp "/repo")))
    (mkdir repository)
    (with-environment `(("GIT_AUTHOR_NAME" . #f)
                        ("GIT_AUTHOR_EMAIL" . #f)
                        ("GIT_COMMITTER_NAME" . #f)
                        ("GIT_COMMITTER_EMAIL" . #f)
                        ("GIT_CONFIG_GLOBAL" . "/dev/null")
                        ("GIT_CONFIG_NOSYSTEM" . "1"))
      (lambda ()
        (sh-output (string-append "cd " repository " && git init -q"
                                  " && git config user.name B"
                                  " && git config user.email b@x"))
        (git-identity "git" repository)))))

(test-equal "read-secrets"
  '(("A" . "secret"))
  (let ((directory (string-append tmp "/secrets")))
    (write-file (string-append directory "/A") "secret\n")
    (read-secrets directory '("A" "MISSING"))))

(test-equal "environment-with"
  '("NEW=1" "PATH=/x")
  (with-environment '(("PATH" . "/usr/bin"))
    (lambda ()
      (let ((environment (environment-with '(("NEW" . "1")
                                             ("PATH" . "/x")))))
        (filter (lambda (entry)
                  (or (string-prefix? "NEW=" entry)
                      (string-prefix? "PATH=" entry)))
                environment)))))

;;; Shell commands

(test-equal "shell-quote"
  "it's \"$HOME\" `x` \\"
  (sh-output (string-append "printf %s "
                            (shell-quote "it's \"$HOME\" `x` \\"))))

(test-equal "remote-command"
  "cd /work && 'echo' 'it'\\''s'; echo $? > /s"
  (remote-command '("echo" "it's") '() "/s"))

(test-equal "remote-command, login shell"
  "cd /work && \"$SHELL\" -l; echo $? > /s"
  (remote-command '() '() "/s"))

;; The status file must be written by the shell under WRAPPER.
(test-equal "remote-command, wrapper"
  (string-append "sh\n-c\n" (remote-command '("echo" "it's") '() "/s")
                 "\n")
  (sh-output (remote-command '("echo" "it's") '("printf" "'%s\\n'")
                             "/s")))

;;; QEMU and virtiofsd

(test-equal "serial-options"
  '(("-chardev" "file,id=serial,path=/l,append=on" "-serial"
     "chardev:serial")
    ("-serial" "stdio"))
  (list (serial-options "/l" #f) (serial-options "/l" "stdio")))

(test-equal "id-map-options"
  '("--translate-uid" "map:1000:0:1" "--translate-gid" "map:100:0:1")
  (id-map-options 1000 100 0 0))

(test-equal "virtiofs-device"
  '("-chardev" "socket,id=work,path=/w.sock"
    "-device" "vhost-user-fs-device,chardev=work,tag=work")
  (virtiofs-device (share "work" "/w" '() '()) "/w.sock"))

(test-equal "vm-shares"
  '((("store" "/s" #t ("/mount-store" "/items" "/s"))
     ("work" "/p" #f ())
     ("home" "/h" #f ()))
    (#t ("--readonly" "--translate-uid" "map:1000:0:1"
         "--translate-gid" "map:100:0:1")))
  (let ((shares stateless
                (values
                 (vm-shares #:directory "/p" #:home "/h" #:stateless? #f
                            #:uid 1000 #:gid 100 #:store "/s"
                            #:store-items "/items"
                            #:mount-store "/mount-store")
                 (vm-shares #:directory "/p" #:home "/h" #:stateless? #t
                            #:uid 1000 #:gid 100 #:store "/s"
                            #:store-items "/items"
                            #:mount-store "/mount-store"))))
    (list (map (lambda (share)
                 (list (share-tag share) (share-directory share)
                       (and (member "--readonly" (share-options share)) #t)
                       (share-wrapper share)))
               shares)
          (list (equal? (map share-tag shares) (map share-tag stateless))
                (share-options (second stateless))))))

(test-equal "wayland-forwarding"
  '((() () ())
    (("/waypipe" "/h.sock")
     ("/waypipe" "--socket" "/g.sock" "--no-gpu" "server" "--")
     ("-o" "ExitOnForwardFailure=yes" "-R" "/g.sock:/h.sock")))
  (map (lambda (waypipe)
         (let ((servers wrapper options
                        (wayland-forwarding waypipe "vm" "/h.sock"
                                            "/g.sock")))
           (list (append-map (lambda (server)
                               (list (server-program server)
                                     (server-socket server)))
                             servers)
                 wrapper options)))
       '(#f "/waypipe")))

(test-equal "vm-kernel-arguments"
  '(("console=ttyS0" "panic=-1" "guix-microvm.ssh-key=K" "a")
    ("console=ttyS0" "panic=-1" "guix-microvm.ssh-key=K"
     "guix-microvm.stateless=1" "a"))
  (list (vm-kernel-arguments "K" #f '("a"))
        (vm-kernel-arguments "K" #t '("a"))))

(test-assert "qemu-arguments"
  (let ((arguments (qemu-arguments #:kernel "/k" #:initrd "/i"
                                   #:kernel-arguments '("a=1" "b")
                                   #:memory 512 #:cpus 2 #:cid "42"
                                   #:network "/n.sock"
                                   #:serial '("-serial" "stdio")
                                   #:devices '("-device" "d")
                                   #:qmp "/q.sock")))
    (and (equal? (take (member "-append" arguments) 2)
                 '("-append" "a=1 b"))
         (member "-no-reboot" arguments)
         (equal? (take (member "-m" arguments) 4) '("-m" "512" "-smp" "2"))
         (member "vhost-vsock-device,guest-cid=42" arguments)
         (member "unix:/q.sock,server=on,wait=off" arguments)
         (equal? (take-right arguments 2) '("-device" "d")))))

(test-equal "qemu-arguments, USB"
  '("microvm,acpi=off,rtc=on,memory-backend=mem"
    "microvm,acpi=on,usb=on,rtc=on,memory-backend=mem")
  (map (lambda (usb?)
         (second (qemu-arguments #:kernel "/k" #:initrd "/i"
                                 #:kernel-arguments '() #:memory 512
                                 #:cpus 2 #:cid "42" #:network "/n.sock"
                                 #:serial '() #:devices '() #:usb? usb?
                                 #:qmp "/q.sock")))
       '(#f #t)))

(test-equal "passt-port-options"
  '(("--tcp-ports" "127.0.0.1/3000")
    ("--tcp-ports" "127.0.0.1/8080:80"))
  (list (passt-port-options 3000) (passt-port-options '(8080 . 80))))

(test-equal "passt-network-options"
  '("--address" "10.0.2.15" "--netmask" "24" "--gateway" "10.0.2.2"
    "--dns-forward" "10.0.2.3")
  (let ((guest (guest-configuration %base-vm)))
    (passt-network-options (microvm-guest-configuration-network guest)
                           (microvm-guest-configuration-name-server guest))))

;;; Guest

(test-equal "guest-configuration, as configured"
  '("dev" 1001 2223)
  (let ((guest (guest-configuration
                (operating-system
                  (inherit %base-vm)
                  (services
                   (modify-services %microvm-base-services
                     (microvm-guest-service-type
                      config => (microvm-guest-configuration
                                  (inherit config)
                                  (user "dev")
                                  (uid 1001)
                                  (ssh-port 2223)))))))))
    (list (microvm-guest-configuration-user guest)
          (microvm-guest-configuration-uid guest)
          (microvm-guest-configuration-ssh-port guest))))

(test-assert "guest-configuration, without the service"
  (guard (error ((formatted-message? error) #t))
    (guest-configuration (operating-system
                           (inherit %base-vm)
                           (services
                            (remove (lambda (service)
                                      (eq? (service-kind service)
                                           microvm-guest-service-type))
                                    %microvm-base-services))))
    #f))

(test-equal "microvm, invalid fields"
  '("ports: expected a list of PORT or (HOST . GUEST), got (0)"
    "ports: expected a list of PORT or (HOST . GUEST), got ((80 . \"x\"))"
    "secrets: expected a list of variable names, got \"TOKEN\""
    "memory-size: expected a positive integer, got 0"
    #f)
  (map error-message
       (list (lambda () (microvm (operating-system %base-vm) (ports '(0))))
             (lambda ()
               (microvm (operating-system %base-vm) (ports '((80 . "x")))))
             (lambda ()
               (microvm (operating-system %base-vm) (secrets "TOKEN")))
             (lambda ()
               (microvm (operating-system %base-vm) (memory-size 0)))
             (lambda ()
               (microvm (operating-system %base-vm)
                 (ports '(3000 (8080 . 80)))
                 (secrets '("TOKEN")))))))

(test-equal "microvm-guest-configuration, invalid fields"
  '(#t #t #t #f)
  (map (lambda (thunk)
         (guard (error (#t #t))
           (thunk)
           #f))
       (list (lambda () (microvm-guest-configuration (ssh-port 22)))
             (lambda () (microvm-guest-configuration (uid "1000")))
             (lambda ()
               (microvm-guest-configuration
                 (network (static-networking
                            (addresses '())
                            (routes '())))))
             (lambda () (microvm-guest-configuration (ssh-port 2223))))))

;;; Processes

(test-equal "open-log empties the file"
  "new"
  (let ((file (string-append tmp "/log")))
    (write-file file "old")
    (call-with-port (open-log file) (cut display "new" <>))
    (call-with-input-file file get-string-all)))

(test-assert "call-with-temporary-directory deletes it on exit"
  (let ((directory #f))
    (exit-code (lambda ()
                 (call-with-temporary-directory tmp
                   (lambda (d)
                     (set! directory d)
                     (exit 3)))))
    (and directory (not (file-exists? directory)))))

(test-equal "wait-for-exit"
  '(3 143)
  (list (wait-for-exit (spawn "sh" '("sh" "-c" "exit 3")))
        (wait-for-exit (spawn "sh" '("sh" "-c" "kill $$")))))

(test-assert "call-with-process stops it"
  (not (process-exists? (call-with-process "sleep" '("100") identity))))

(test-equal "call-with-servers starts them in order and stops them"
  '(#t #t #t #t)
  (let* ((a (string-append tmp "/a.sock"))
         (b (string-append tmp "/b.sock"))
         (seen '()))
    (call-with-servers (list (server "sh" (server-script a) a)
                             (server "sh" (server-script b) b))
      (lambda ()
        (set! seen (map file-exists? (list a b)))))
    (append seen
            (map (lambda (socket)
                   (stopped? (string-append socket ".pid")))
                 (list a b)))))

(test-equal "call-with-servers fails if one exits"
  1
  (exit-code (lambda ()
               (call-with-servers
                   (list (server "true" '() (string-append tmp
                                                           "/none.sock")))
                 (const #t)))))

(test-equal "call-with-launcher-errors reports and returns the status"
  '(1 "run-vm: no x\n" 7)
  (let* ((status #f)
         (output (with-error-to-string
                  (lambda ()
                    (set! status
                          (call-with-launcher-errors
                           (lambda ()
                             (fail "no ~a" "x"))))))))
    (list status output (call-with-launcher-errors (const 7)))))

;;; Control

(define (fake-qmp-server file)
  "Serve QMP at FILE to one client.  Return the serving thread; joining it
gives the commands received.  Each reply follows an event; the command
\"fail\" gets an error."
  (let ((server (socket PF_UNIX SOCK_STREAM 0)))
    (define (send client message)
      (write-line (scm->json-string message) client)
      (force-output client))

    (bind server AF_UNIX file)
    (listen server 1)
    (call-with-new-thread
     (lambda ()
       (match (accept server)
         ((client . _)
          (send client '(("QMP" . (("version" . "test")))))
          (let loop ((commands '()))
            (match (read-line client)
              ((? eof-object?)
               (close-port client)
               (close-port server)
               (reverse commands))
              (line
               (let ((command (assoc-ref (json-string->scm line) "execute")))
                 (send client '(("event" . "TEST")))
                 (send client
                       (if (string=? command "fail")
                           '(("error" . (("class" . "GenericError")
                                         ("desc" . "failed"))))
                           `(("return" . (("answer" . ,command))))))
                 (loop (cons command commands))))))))))))


(test-equal "string->usb-id"
  '((#x1050 . #f) (#x1050 . #x0407) #f #f)
  (map string->usb-id '("1050" "1050:0407" "yubi" "1:2:3")))

(test-equal "usb-id-matches?"
  '(#t #t #f #f)
  (list (usb-id-matches? '(#x1050 . #f) '(#x1050 . #x0407))
        (usb-id-matches? '(#x1050 . #x0407) '(#x1050 . #x0407))
        (usb-id-matches? '(#x1050 . #x0402) '(#x1050 . #x0407))
        (usb-id-matches? '(#x20a0 . #f) '(#x1050 . #x0407))))

(test-equal "present-usb-devices"
  '(("/dev/bus/usb/001/009") ())
  (let ((sysfs (string-append tmp "/sysfs")))
    (for-each (match-lambda
                ((name vendor product bus device)
                 (for-each (lambda (attribute value)
                             (write-file (string-append sysfs "/" name "/"
                                                        attribute)
                                         (string-append value "\n")))
                           '("idVendor" "idProduct" "busnum" "devnum")
                           (list vendor product bus device))))
              '(("1-1" "1050" "0407" "1" "9")
                ("usb1" "1d6b" "0002" "1" "1")))
    (write-file (string-append sysfs "/1-1:1.0/bInterfaceClass") "03\n")
    (list (present-usb-devices '(#x1050 . #f) sysfs)
          (present-usb-devices '(#x1050 . #x0402) sysfs))))

(test-equal "usb-host-arguments"
  '((("driver" . "usb-host") ("id" . "usb-1050") ("vendorid" . #x1050))
    (("driver" . "usb-host") ("id" . "usb-1050-0407") ("vendorid" . #x1050)
     ("productid" . #x0407)))
  (list (usb-host-arguments '(#x1050 . #f))
        (usb-host-arguments '(#x1050 . #x0407))))

(test-equal "running-vms"
  '(("a" "/p" #t))
  (let ((runtime (string-append tmp "/runtime"))
        (exited (spawn "true" '("true"))))
    (waitpid exited)
    (for-each (match-lambda
                ((directory name pid)
                 (write-file (string-append runtime "/" directory "/vm")
                             (object->string
                              `((name . ,name) (directory . "/p")
                                (usb? . #t) (pid . ,pid))))))
              `(("guix-microvm.a" "a" ,(getpid))
                ("guix-microvm.b" "b" ,exited)
                ("other" "c" ,(getpid))))
    (mkdir-p (string-append runtime "/guix-microvm.empty"))
    (map (lambda (vm)
           (list (running-vm-name vm) (running-vm-directory vm)
                 (running-vm-usb? vm)))
         (running-vms runtime))))

(test-equal "call-with-qmp"
  '((("answer" . "query-status")) "QEMU: failed"
    ("qmp_capabilities" "query-status" "fail"))
  (let* ((file (string-append tmp "/qmp.sock"))
         (server (fake-qmp-server file))
         (results (call-with-qmp file
                    (lambda (execute)
                      (list (execute "query-status")
                            (error-message (cut execute "fail")))))))
    (append results (list (join-thread server)))))

(test-equal "attach-usb!, refused"
  '("vm has no USB controller: its microvm lacks 'usb?'"
    "no USB device ffff is plugged in")
  (map (lambda (usb?)
         (error-message
          (cut attach-usb! (running-vm "vm" "/p" usb? "/none.sock")
               '(#xffff . #f))))
       '(#f #t)))

;;; Extension

(test-equal "string->port"
  '(3000 (8080 . 80) 1)
  (list (string->port "3000")
        (string->port "8080:80")
        (exit-code (lambda ()
                     (quietly
                       (lambda ()
                         (string->port "x")))))))

(test-equal "allowed-project"
  '(("/p q" . "abc") #f #f)
  (map allowed-project '("abc /p q" "" "abc")))

(test-equal "launcher-flags"
  '(() ("--share-home" "--stateless"))
  (list (launcher-flags '((vm . "x")))
        (launcher-flags '((stateless? . #t) (share-home? . #t)))))

(let* ((project (string-append tmp "/project"))
       (sub (string-append project "/a/b"))
       (manifest (string-append project "/manifest.scm"))
       (vm (string-append project "/vm.scm")))
  (define (allowed?)
    (project-allowed? project (read-project project)))

  (define (allow!)
    (allow-project! project (read-project project)))

  (define (digest)
    (project-digest (read-project project)))

  (mkdir-p sub)
  (write-file manifest "1")

  (test-equal "project-directory"
    project
    (let ((cwd (getcwd)))
      (dynamic-wind
        (cut chdir sub)
        project-directory
        (cut chdir cwd))))

  (test-equal "read-project"
    '((("manifest.scm" . #vu8(49))) ())
    (list (read-project project) (read-project #f)))

  (test-equal "project-files"
    `((#f (,manifest . #vu8(49)))
      ((,vm . #vu8(118)) (,manifest . #vu8(49))))
    (begin
      (write-file vm "v")
      (let ((contents (read-project project)))
        (map (lambda (opts)
               (values->list (project-files opts project contents)))
             '(((vm . "claude-vm")) ())))))

  (test-equal "load-object evaluates the contents read, not the file"
    2
    (begin
      (write-file manifest "(+ 1 1)")
      (let ((file (project-file project (read-project project)
                                "manifest.scm")))
        (write-file manifest "(exit 9)")
        (quietly
         (lambda ()
           (load-object file "number" number? '()))))))

  (test-equal "eval-file, errors"
    '(1 1)
    (map (lambda (code)
           (exit-code
            (lambda ()
              (quietly
               (lambda ()
                 (eval-file manifest (string->utf8 code) '()))))))
         '("(" "unbound-variable")))

  (with-environment `(("XDG_CONFIG_HOME" . ,(string-append tmp "/config")))
    (lambda ()
      (test-equal "allow-project!"
        '(#f #t #f #t)
        (let* ((before (allowed?))
               (_ (allow!))
               (allowed (allowed?)))
          (write-file manifest "2")
          (let ((changed (allowed?)))
            (allow!)
            (list before allowed changed (allowed?)))))

      (test-equal "allow-project! keeps the other projects"
        (sort (list project "/other") string<?)
        (begin
          (write-file (string-append tmp "/config/guix/microvm-allowed")
                      (format #f "~a ~a~%digest /other~%" (digest) project))
          (allow!)
          (sort (map car (allowed-projects)) string<?)))

      (test-assert "project-digest changes when a file disappears"
        (let ((before (digest)))
          (delete-file vm)
          (not (equal? before (digest))))))))

(delete-file-recursively tmp)

(define failures (test-runner-fail-count (test-runner-current)))
(format #t "~a passed, ~a failed~%"
        (test-runner-pass-count (test-runner-current)) failures)
(test-end "unit")
(exit (zero? failures))
