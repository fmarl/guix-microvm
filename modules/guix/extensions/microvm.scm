;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix extensions microvm)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix monads)
  #:use-module (guix scripts)
  #:use-module (guix scripts build)
  #:use-module ((guix status) #:select (with-status-verbosity))
  #:use-module (guix store)
  #:use-module (guix ui)
  #:use-module (guix-microvm control)
  #:use-module (guix-microvm microvm)
  #:use-module (guix-microvm project)
  #:use-module ((guix-microvm build files) #:select (contains-file?))
  #:use-module ((guix-microvm build invocation) #:select (volatile-vm?))
  #:use-module ((guix-microvm build process) #:select (wait-for-exit))
  #:use-module ((guix-microvm build registry) #:select (runtime-directory))
  #:use-module ((guix-microvm build state) #:select (check-shareable))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-37)
  #:use-module (srfi srfi-71)
  #:export (guix-microvm))

(define (show-help)
  (display (G_ "Usage: guix microvm [OPTION]... [-- COMMAND...]
   or: guix microvm list [--format=sexp]
   or: guix microvm attach [NAME]
   or: guix microvm kill [--merge|--discard] [NAME]
   or: guix microvm resolve [--merge|--discard]
   or: guix microvm usb attach|detach NAME VENDOR[:PRODUCT]
   or: guix microvm diff [--tool=COMMAND] [FILE...]
Run COMMAND, or a login shell, in a microvm sharing the project directory at
/work.  The microvm is the one vm.scm defines, or the base VM, with the
packages of manifest.scm.  A microvm running a login shell keeps running
after it exits, until it is killed.  If the project's microvm runs, COMMAND
or the shell runs in it, unless options ask for a new one.

Or list the running microvms, open a login shell in the running microvm NAME,
or kill it, then ask about its changes unless --merge or --discard.  NAME
may also be the ID that 'list' shows, and defaults to the microvm of the
current project.  Or ask about the changes a killed microvm left.

Or show the changes the microvm on the project made to FILE, or to all
files, with 'git diff' or with COMMAND, which gets the old and new directory.

Or give the running microvm NAME the host's USB device with the hexadecimal
IDs VENDOR and PRODUCT, which the host lacks until it is detached again.\n"))
  (display (G_ "
      --vm=NAME          run the microvm NAME that a (CHANNEL vms ...)
                         module exports"))
  (display (G_ "
  -p, --port=PORT[:GUEST-PORT]
                         forward PORT on the host's loopback to GUEST-PORT,
                         by default PORT, in the microvm"))
  (display (G_ "
      --stateless        give the microvm a fresh home, and no project
                         directory unless with --persistent"))
  (display (G_ "
      --merge            merge the microvm's changes to the project directory
                         without asking, unless they conflict"))
  (display (G_ "
      --discard          discard the microvm's changes to the project
                         directory without asking"))
  (display (G_ "
      --persistent       share the project directory at /work, the
                         default"))
  (display (G_ "
      --volatile         give the microvm an empty /work instead of the
                         project directory"))
  (display (G_ "
      --allow            allow the current vm.scm and manifest.scm to run"))
  (display (G_ "
  -n, --dry-run          do not build or run the microvm"))
  (newline)
  (show-build-options-help)
  (newline)
  (display (G_ "
  -h, --help             display this help and exit"))
  (newline))

(define (exclusive-option name key other-name other-key)
  "Return the option NAME, which sets KEY and excludes OTHER-NAME, which
sets OTHER-KEY."
  (option (list name) #f #f
          (lambda (opt option-name arg result)
            (when (assoc-ref result other-key)
              (leave (G_ "--~a or --~a, not both~%") other-name name))
            (alist-cons key #t result))))

(define %options
  (cons* (option '(#\h "help") #f #f
                 (lambda _
                   (show-help)
                   (exit 0)))
         (option '("vm") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'vm arg result)))
         (option '(#\p "port") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'port (string->forwarded-port arg) result)))
         (option '("stateless") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'stateless? #t result)))
         (exclusive-option "volatile" 'volatile? "persistent" 'persistent?)
         (exclusive-option "persistent" 'persistent? "volatile" 'volatile?)
         (exclusive-option "merge" 'merge? "discard" 'discard?)
         (exclusive-option "discard" 'discard? "merge" 'merge?)
         (option '("allow") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'allow? #t result)))
         (option '(#\n "dry-run") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'dry-run? #t result)))
         %standard-build-options))

(define %default-options
  '((substitutes? . #t)
    (offload? . #t)
    (graft? . #t)
    (print-build-trace? . #t)
    (print-extended-build-trace? . #t)
    (multiplexed-build-output? . #t)
    (debug . 0)
    (verbosity . 1)))

(define (parse-arguments args)
  "Return the options and the command ARGS specify."
  (let ((args rest (break (cut string=? "--" <>) args)))
    (values (parse-command-line args %options (list %default-options)
                                #:argument-handler
                                (lambda (arg result)
                                  (leave (G_ "~a: extraneous argument~%")
                                         arg)))
            (match rest
              (() '())
              ((_ command ...) command)))))

(define (string->forwarded-port str)
  (match (map string->number (string-split str #\:))
    (((? integer? port)) port)
    (((? integer? host) (? integer? guest)) (cons host guest))
    (_ (leave (G_ "~a: expected PORT or PORT:GUEST-PORT~%") str))))

(define (built-launcher vm)
  "Build VM's launcher and return its file name, in the store monad."
  (mlet %store-monad ((drv (lower-object vm)))
    (mbegin %store-monad
      (built-derivations (list drv))
      (return (derivation->output-path drv)))))

(define (launcher-flags opts)
  (append (match (assoc-ref opts 'vm)
            (#f '())
            (name (list (string-append "--name=" name "-vm"))))
          (filter-map (match-lambda
                        ((key . flag) (and (assoc-ref opts key) flag)))
                      '((stateless? . "--stateless")
                        (volatile? . "--volatile")
                        (persistent? . "--persistent")
                        (merge? . "--merge")
                        (discard? . "--discard")))))

(define (gc-root store item)
  "Return a new indirect garbage collector root for ITEM."
  (let ((link (format #f "~a/guix-microvm-root.~a.~a" (runtime-directory)
                      (getpid)
                      (random (expt 2 32) (random-state-from-platform)))))
    (symlink item link)
    (add-indirect-root store link)
    link))

(define (call-with-launcher opts vm proc)
  "Build VM's launcher with the build options in OPTS and call PROC with its
file name and a garbage collector root for it, unless OPTS ask for a dry
run."
  (with-store store
    (set-build-options-from-command-line store opts)
    (with-build-handler (build-notifier #:use-substitutes?
                                        (assoc-ref opts 'substitutes?)
                                        #:verbosity
                                        (assoc-ref opts 'verbosity)
                                        #:dry-run?
                                        (assoc-ref opts 'dry-run?))
      (parameterize ((%graft? (assoc-ref opts 'graft?)))
        (with-status-verbosity (assoc-ref opts 'verbosity)
          (let ((launcher (run-with-store store (built-launcher vm))))
            ;; With nothing to build, 'build-notifier' lets a dry run get
            ;; this far.
            (unless (assoc-ref opts 'dry-run?)
              ;; Keep the garbage collector off it until the store
              ;; connection closes.
              (add-temp-root store launcher)
              (proc launcher (gc-root store launcher)))))))))

(define* (call-with-project-launcher opts proc #:key (check (const #t)))
  "Call PROC with the project directory, the launcher of its microvm, built
as OPTS say, and a garbage collector root for it.  Call CHECK with the
microvm and the directory first."
  (let* ((project (project-directory))
         (contents (read-project project))
         (directory (or project (getcwd))))
    (when (assoc-ref opts 'allow?)
      (allow-project! project contents))
    (let ((vm (project-microvm project contents
                               #:vm (assoc-ref opts 'vm)
                               #:ports (reverse
                                        (filter-map (match-lambda
                                                      (('port . port) port)
                                                      (_ #f))
                                                    opts)))))
      (check vm directory)
      (call-with-launcher opts vm (cut proc directory <> <>)))))

(define (call-with-vm-launcher vm proc)
  "Call PROC with the launcher of the running VM."
  (let ((launcher (running-vm-launcher vm)))
    (with-store store
      (add-temp-root store launcher)
      (proc launcher))))

(define (run-launcher launcher args)
  (wait-for-exit (spawn launcher (cons launcher args))))

(define (project-vm vms)
  "Return the microvm among VMS that shares the current project, or #f."
  (let ((directory (current-project)))
    (find (compose (cut string=? directory <>) running-vm-directory) vms)))

(define* (find-running-vm #:optional name)
  "Return the running microvm named NAME, or with the ID NAME.  If several
run, or without NAME, return the one sharing the current project."
  (if name
      (match (filter (lambda (vm)
                       (member name (list (running-vm-name vm)
                                          (running-vm-id vm))))
                     (running-vms))
        (() (leave (G_ "no microvm '~a' is running~%") name))
        ((vm) vm)
        (vms
         (or (project-vm vms)
             (leave (G_ "several microvms '~a' are running, none sharing \
'~a'~%")
                    name (current-project)))))
      (or (project-vm (running-vms))
          (leave (G_ "no microvm runs on '~a'~%") (current-project)))))

;; Options that a running microvm can no longer follow.
(define %start-options
  '(vm port stateless? volatile? persistent? merge? discard? allow? dry-run?))

(define (start-microvm opts command)
  (call-with-project-launcher opts
    (lambda (directory launcher root)
      (exit (run-launcher launcher
                          `(,(string-append "--gc-root=" root)
                            ,@(launcher-flags opts) ,directory "--"
                            ,@command))))
    ;; Fail before building the launcher, which checks it too.
    #:check (lambda (vm directory)
              (unless (volatile-vm? #:stateless?
                                    (or (assoc-ref opts 'stateless?)
                                        (microvm-stateless? vm))
                                    #:volatile? (assoc-ref opts 'volatile?)
                                    #:persistent? (assoc-ref opts 'persistent?)
                                    #:volatile-field? (microvm-volatile? vm))
                (check-shareable directory)))))

(define (run-in-microvm args)
  "Run the command in ARGS in the project's microvm, starting it unless it
runs, and exit with its status."
  (let ((opts command (parse-arguments args)))
    (match (and (not (any (cut assoc-ref opts <>) %start-options))
                (project-vm (remove running-vm-volatile? (running-vms))))
      (#f (start-microvm opts command))
      (vm
       (info (G_ "~a runs on the project; attaching~%") (running-vm-name vm))
       (exit (attach-vm! vm #:command command
                         #:terminal? (isatty? (current-input-port))))))))

(define (attach-command args)
  (match args
    ((or () (_))
     (exit (attach-vm! (apply find-running-vm args)
                       #:terminal? (isatty? (current-input-port)))))
    (_ (leave (G_ "usage: guix microvm attach [NAME]~%")))))

(define (kill-command args)
  "Kill the microvm ARGS name, then resolve its changes if its login shell
exited."
  (let ((flags names (partition (cut member <> '("--merge" "--discard"))
                                args)))
    (match (list flags names)
      (((or () (_)) (or () (_)))
       (let ((vm (apply find-running-vm names)))
         (if (running-vm-detached? vm)
             (call-with-vm-launcher vm
               (lambda (launcher)
                 (kill-vm! vm)
                 (exit (run-launcher
                        launcher
                        `("--resolve"
                          ,(string-append "--name=" (running-vm-name vm))
                          ,@flags ,(running-vm-directory vm))))))
             (kill-vm! vm))))
      (_
       (leave (G_ "usage: guix microvm kill [--merge|--discard] [NAME]~%"))))))

(define (resolve-command args)
  "Resolve the changes left on the project as ARGS say."
  (let ((opts command (parse-arguments args)))
    (unless (null? command)
      (leave (G_ "usage: guix microvm resolve [--merge|--discard]~%")))
    (and=> (project-vm (remove running-vm-volatile? (running-vms)))
           (lambda (vm)
             (leave (G_ "~a still runs on '~a'~%")
                    (running-vm-name vm) (running-vm-directory vm))))
    (call-with-project-launcher opts
      (lambda (directory launcher root)
        (exit (run-launcher
               launcher
               `("--resolve" ,(string-append "--gc-root=" root)
                 ,@(filter (cut member <> '("--merge" "--discard"))
                           (launcher-flags opts))
                 ,directory)))))))

(define (diff-command args)
  "Show the changes left on the project to the files in ARGS."
  (let* ((cwd (canonicalize-path (getcwd)))
         (arguments (match args
                      (((? (cut string-prefix? "--tool=" <>) tool) files ...)
                       `(,tool ,cwd ,@files))
                      (files `(,cwd ,@files)))))
    (match (find (lambda (vm)
                   (contains-file? (running-vm-directory vm) cwd))
                 (running-vms))
      (#f
       (call-with-project-launcher %default-options
         (lambda (directory launcher root)
           (exit (run-launcher launcher
                               `("--diff" ,(string-append "--gc-root=" root)
                                 ,@arguments))))))
      (vm
       (call-with-vm-launcher vm
         (lambda (launcher)
           (exit (run-launcher launcher `("--diff" ,@arguments)))))))))

(define (control-usb args)
  "Attach or detach a host USB device as ARGS say."
  (define (control action name str)
    (let ((id (or (string->usb-id str)
                  (leave (G_ "~a: expected VENDOR or VENDOR:PRODUCT~%")
                         str))))
      (action (find-running-vm name) id)))

  (match args
    (("attach" name id) (control attach-usb! name id))
    (("detach" name id) (control detach-usb! name id))
    (_
     (leave (G_ "usage: guix microvm usb attach|detach NAME \
VENDOR[:PRODUCT]~%")))))

(define (duration seconds)
  (cond ((< seconds 60) (format #f "~as" seconds))
        ((< seconds 3600) (format #f "~am" (quotient seconds 60)))
        ((< seconds 86400) (format #f "~ah" (quotient seconds 3600)))
        (else (format #f "~ad" (quotient seconds 86400)))))

(define (vm-state vm)
  (string-append (if (running-vm-detached? vm) "detached" "running")
                 (if (running-vm-changed? vm) ", changed" "")))

(define (vm-fields vm now)
  `((name ,(running-vm-name vm))
    (id ,(running-vm-id vm))
    (up ,(duration (- now (running-vm-started vm))))
    (state ,(vm-state vm))
    (directory ,(running-vm-directory vm))))

(define (list-table vms)
  (let* ((now (current-time))
         (rows (cons '("NAME" "ID" "UP" "STATE" "PROJECT")
                     (map (lambda (vm)
                            (map cadr (vm-fields vm now)))
                          vms)))
         (widths (apply map (lambda column
                              (apply max (map string-length column)))
                        rows)))
    (for-each (lambda (row)
                (display (string-trim-right
                          (string-join (map (lambda (cell width)
                                              (string-pad-right cell width))
                                            row widths)
                                       "  ")))
                (newline))
              rows)))

(define (list-sexps vms)
  (let ((now (current-time)))
    (for-each (lambda (vm)
                (write `(vm ,@(vm-fields vm now)))
                (newline))
              vms)))

(define (list-command args)
  (match args
    (() (list-table (running-vms)))
    (("--format=sexp") (list-sexps (running-vms)))
    (_ (leave (G_ "usage: guix microvm list [--format=sexp]~%")))))

(define-command (guix-microvm . args)
  (category development)
  (synopsis "run commands in a microvm with a project's packages")

  (with-error-handling
    (match args
      (("list" rest ...) (list-command rest))
      (("attach" rest ...) (attach-command rest))
      (("kill" rest ...) (kill-command rest))
      (("resolve" rest ...) (resolve-command rest))
      (("usb" rest ...) (control-usb rest))
      (("diff" rest ...) (diff-command rest))
      (_ (run-in-microvm args)))))
