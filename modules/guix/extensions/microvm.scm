;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix extensions microvm)
  #:use-module (guix derivations)
  #:use-module (guix discovery)
  #:use-module (guix gexp)
  #:use-module (guix monads)
  #:use-module ((guix profiles) #:select (manifest?))
  #:use-module (guix scripts)
  #:use-module (guix scripts build)
  #:use-module ((guix status) #:select (with-status-verbosity))
  #:use-module (guix store)
  #:use-module ((guix diagnostics)
                #:select (formatted-message &fix-hint))
  #:use-module (guix ui)
  #:use-module ((guix utils)
                #:select (config-directory with-atomic-file-output))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module (gnu system)
  #:use-module (guix-microvm base)
  #:use-module (guix-microvm microvm)
  #:use-module (guix-microvm control)
  #:use-module ((guix-microvm build error) #:select (%program-name))
  #:use-module ((guix-microvm build files) #:select (contains-file?))
  #:use-module ((guix-microvm build git) #:select (git-diff-process))
  #:use-module ((guix-microvm build layer)
                #:select (layer-project change-file call-with-diff-trees))
  #:use-module ((guix-microvm build merge) #:select (classify-changes))
  #:use-module ((guix-microvm build microvm)
                #:select (check-shareable volatile-vm?))
  #:use-module ((guix-microvm build review) #:select (report-skipped))
  #:use-module ((guix-microvm build state)
                #:select (data-directory layers-around))
  #:use-module ((guix-microvm build process) #:select (wait-for-exit))
  #:use-module ((ice-9 binary-ports) #:select (get-bytevector-all))
  #:use-module (ice-9 eval-string)
  #:use-module ((ice-9 exceptions) #:select (exception-kind exception-args))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module ((rnrs bytevectors) #:select (string->utf8 utf8->string))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module ((srfi srfi-35) #:select (condition make-compound-condition))
  #:use-module (srfi srfi-37)
  #:use-module (srfi srfi-71)
  #:export (guix-microvm))

(define (show-help)
  (display (G_ "Usage: guix microvm [OPTION]... [-- COMMAND...]
   or: guix microvm list
   or: guix microvm attach NAME
   or: guix microvm kill NAME
   or: guix microvm usb attach|detach NAME VENDOR[:PRODUCT]
   or: guix microvm diff [--tool=COMMAND] [FILE...]
Run COMMAND, or a login shell, in a microvm sharing the project directory at
/work.  The microvm is the one vm.scm defines, or the base VM, with the
packages of manifest.scm.  A microvm running a login shell keeps running
after it exits, until it is killed.

Or list the running microvms, open a login shell in the running microvm NAME,
or kill it.  NAME may also be the ID that 'list' shows.

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

(define (vm-module-directories)
  "Return the CHANNEL/vms directories of %load-path, as pairs of the
directory in %load-path and CHANNEL/vms."
  (define (directory? file)
    (and=> (stat file #f)
           (lambda (st)
             (eq? 'directory (stat:type st)))))

  (append-map (lambda (directory)
                (filter-map (lambda (name)
                              (let ((sub (string-append name "/vms")))
                                (and (directory? (string-append directory
                                                                "/" sub))
                                     (cons directory sub))))
                            (or (scandir directory
                                         (negate (cut member <> '("." ".."))))
                                '())))
              %load-path))

(define (predefined-microvms)
  "Return the microvms the (CHANNEL vms ...) modules export, as an alist by
name."
  (fold-module-public-variables*
   (lambda (module symbol variable result)
     (let ((value (variable-ref variable)))
       (if (microvm? value)
           (alist-cons (symbol->string symbol) value result)
           result)))
   '()
   (all-modules (vm-module-directories))))

(define (lookup-microvm name)
  (let ((microvms (predefined-microvms)))
    (or (assoc-ref microvms name)
        (leave (G_ "~a: no such microvm, available: ~a~%")
               name (string-join (sort (delete-duplicates (map car microvms))
                                       string<?)
                                 ", ")))))

(define %project-file-names
  '("vm.scm" "manifest.scm"))

(define (project-directory)
  "Return the nearest directory, from the current one up, that contains
vm.scm or manifest.scm, or #f."
  (let loop ((directory (getcwd)))
    (cond ((any (lambda (file)
                  (file-exists? (string-append directory "/" file)))
                %project-file-names)
           directory)
          ((string=? directory "/") #f)
          (else (loop (dirname directory))))))

(define* (allowed-file #:key ensure?)
  (string-append (config-directory #:ensure? ensure?) "/microvm-allowed"))

(define (file-bytes file)
  (match (call-with-input-file file get-bytevector-all #:binary #t)
    ((? eof-object?) #vu8())
    (bytes bytes)))

;; Read once: the VM can change the files between check and load.
(define (read-project project)
  "Return vm.scm and manifest.scm of PROJECT as an alist of names and
bytevectors, leaving out missing ones."
  (if project
      (filter-map (lambda (name)
                    (let ((file (string-append project "/" name)))
                      (and (file-exists? file)
                           (cons name (file-bytes file)))))
                  %project-file-names)
      '()))

(define (project-digest contents)
  "Return a digest of CONTENTS, as returned by 'read-project'."
  (bytevector->base16-string
   (sha256
    (string->utf8
     (string-join
      (map (lambda (name)
             (match (assoc-ref contents name)
               (#f name)
               (bytes (string-append name " "
                                     (bytevector->base16-string
                                      (sha256 bytes))))))
           %project-file-names)
      "\n")))))

(define (line->allowed-project line)
  "Parse LINE of the allowed file into a directory and digest pair, or #f."
  (match (string-index line #\space)
    (#f #f)
    (index (cons (string-drop line (+ index 1))
                 (string-take line index)))))

(define (allowed-projects)
  "Return the allowed projects as an alist of directories and digests."
  (catch 'system-error
    (lambda ()
      (filter-map line->allowed-project
                  (string-split (call-with-input-file (allowed-file)
                                  get-string-all)
                                #\newline)))
    (const '())))

(define (allow-project! project contents)
  (unless project
    (leave (G_ "no vm.scm or manifest.scm to allow~%")))
  (let ((others (alist-delete project (allowed-projects))))
    (with-atomic-file-output (allowed-file #:ensure? #t)
      (lambda (port)
        (for-each (match-lambda
                    ((directory . digest)
                     (format port "~a ~a~%" digest directory)))
                  (alist-cons project (project-digest contents) others))))))

(define (project-allowed? project contents)
  (equal? (assoc-ref (allowed-projects) project)
          (project-digest contents)))

(define (project-file project contents name)
  "Return NAME in PROJECT paired with its contents, or #f."
  (and=> (assoc-ref contents name)
         (cut cons (string-append project "/" name) <>)))

(define (project-files opts project contents)
  "Return vm.scm, unless OPTS name a predefined microvm, and manifest.scm of
PROJECT, each paired with its contents, or #f."
  (values (and (not (assoc-ref opts 'vm))
               (project-file project contents "vm.scm"))
          (project-file project contents "manifest.scm")))

(define (ensure-allowed project contents)
  (unless (project-allowed? project contents)
    (raise
     (make-compound-condition
      (formatted-message (G_ "not loading vm.scm and manifest.scm from '~a': \
they are new or changed")
                         project)
      (condition
       (&fix-hint
        (hint (G_ "They run on the host, and the VM can change them.
Review them, then run @command{guix microvm --allow}."))))))))

(define (eval-file file bytes modules)
  "Evaluate BYTES, read from FILE, in a new module using MODULES.  Return the
last value."
  ;; Guix conditions and 'leave' go on to 'with-error-handling'.
  (guard (error ((not (memq (exception-kind error) '(quit %exception)))
                 (raise
                  (formatted-message
                   (G_ "failed to load '~a': ~a")
                   file
                   (string-trim-right
                    (call-with-output-string
                      (cut print-exception <> #f
                           (exception-kind error)
                           (exception-args error))))))))
    ;; Not compiled: 'eval-string' would compile in a fresh module, without
    ;; MODULES.
    (eval-string (utf8->string bytes)
                 #:module (make-user-module modules)
                 #:file file)))

(define (load-object file kind valid? modules)
  "Evaluate FILE, from 'project-file', in MODULES.  Return the value, failing
unless VALID? says it is a KIND."
  (match file
    ((name . bytes)
     (info (G_ "loading ~a from '~a'...~%") kind name)
     (let ((object (eval-file name bytes modules)))
       (if (valid? object)
           object
           (leave (G_ "~a: expected a ~a~%") name kind))))))

(define (load-microvm file)
  (load-object file "microvm" microvm?
               '((guix-microvm microvm) (guix-microvm base) (gnu))))

(define (load-manifest file)
  (load-object file "manifest" manifest? '((guix profiles) (gnu))))

(define (string->forwarded-port str)
  (match (map string->number (string-split str #\:))
    (((? integer? port)) port)
    (((? integer? host) (? integer? guest)) (cons host guest))
    (_ (leave (G_ "~a: expected PORT or PORT:GUEST-PORT~%") str))))

(define (options->microvm opts vm-file manifest-file)
  (let ((vm (cond ((assoc-ref opts 'vm) => lookup-microvm)
                  (vm-file (load-microvm vm-file))
                  (else (microvm (operating-system %base-vm))))))
    (microvm
      (inherit vm)
      (manifest (if manifest-file
                    (load-manifest manifest-file)
                    (microvm-manifest vm)))
      (ports (append (microvm-ports vm)
                     (reverse (filter-map (match-lambda
                                            (('port . port) port)
                                            (_ #f))
                                          opts)))))))

(define (built-launcher vm)
  "Build VM's launcher and return its file name, in the store monad."
  (mlet %store-monad ((drv (lower-object vm)))
    (mbegin %store-monad
      (built-derivations (list drv))
      (return (derivation->output-path drv)))))

(define (launcher-flags opts)
  (filter-map (match-lambda
                ((key . flag) (and (assoc-ref opts key) flag)))
              '((stateless? . "--stateless")
                (volatile? . "--volatile")
                (persistent? . "--persistent")
                (merge? . "--merge")
                (discard? . "--discard"))))

(define (call-with-launcher opts vm proc)
  "Build VM's launcher with the build options in OPTS and call PROC with its
file name, unless OPTS ask for a dry run."
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
              (proc launcher))))))))

(define (run-launcher launcher directory command flags)
  (wait-for-exit
   (spawn launcher `(,launcher ,@flags ,directory "--" ,@command))))

(define (run-in-microvm args)
  "Run the command in ARGS in the project's microvm and exit with its
status."
  (let* ((opts command (parse-arguments args))
         (project (project-directory))
         (contents (read-project project))
         (vm-file manifest-file (project-files opts project contents))
         (directory (or project (getcwd))))
    (when (assoc-ref opts 'allow?)
      (allow-project! project contents))
    (when (or vm-file manifest-file)
      (ensure-allowed project contents))
    (let ((vm (options->microvm opts vm-file manifest-file)))
      ;; Fail before building the launcher, which checks it too.
      (unless (volatile-vm? #:stateless? (or (assoc-ref opts 'stateless?)
                                             (microvm-stateless? vm))
                            #:volatile? (assoc-ref opts 'volatile?)
                            #:persistent? (assoc-ref opts 'persistent?)
                            #:volatile-field? (microvm-volatile? vm))
        (check-shareable directory))
      (call-with-launcher opts vm
        (lambda (launcher)
          (exit (run-launcher launcher directory command
                              (launcher-flags opts))))))))

(define (find-running-vm name)
  "Return the running microvm named NAME, or with the ID NAME.  If several
run, return the one sharing the current project."
  (match (filter (lambda (vm)
                   (member name (list (running-vm-name vm)
                                      (running-vm-id vm))))
                 (running-vms))
    (() (leave (G_ "no microvm '~a' is running~%") name))
    ((vm) vm)
    (vms
     (let ((directory (canonicalize-path (or (project-directory) (getcwd)))))
       (or (find (compose (cut string=? directory <>) running-vm-directory)
                 vms)
           (leave (G_ "several microvms '~a' are running, none sharing \
'~a'~%")
                  name directory))))))

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

(define (list-vms)
  (for-each (lambda (vm)
              (format #t "~a\t~a\t~a~%"
                      (running-vm-name vm) (running-vm-id vm)
                      (running-vm-directory vm)))
            (running-vms)))

(define (normalize-file-name file)
  (string-append
   "/"
   (string-join (reverse
                 (fold (lambda (part result)
                         (match part
                           ((or "" ".") result)
                           (".." (if (pair? result) (cdr result) result))
                           (_ (cons part result))))
                       '()
                       (string-split file #\/)))
                "/")))

(define (file-in-project project file)
  (let ((file (normalize-file-name
               (if (absolute-file-name? file)
                   file
                   (string-append (canonicalize-path (getcwd)) "/" file)))))
    (cond ((string=? file project) "")
          ((string-prefix? (string-append project "/") file)
           (string-drop file (+ 1 (string-length project))))
          (else (leave (G_ "~a: not in the project ~a~%") file project)))))

(define (selected-changes changes files)
  (if (null? files)
      changes
      (filter (lambda (change)
                (any (lambda (selected)
                       (or (string-null? selected)
                           (contains-file? selected (change-file change))))
                     files))
              changes)))

(define (current-layer)
  "Return the layer over the project that contains the current directory."
  (let ((directory (canonicalize-path (getcwd))))
    (match (layers-around (data-directory) directory)
      (() (leave (G_ "no microvm runs on a project containing ~a~%")
                 directory))
      ((layer) layer)
      (_ (leave (G_ "several microvms left changes to projects containing \
~a~%")
                directory)))))

(define (show-diff args)
  "Show the changes of the microvm on the project to the files in ARGS, with
'git diff' or the tool ARGS name."
  (unless (search-path (parse-path (getenv "PATH")) "git")
    (leave (G_ "'guix microvm diff' needs git~%")))
  (let* ((tool files (match args
                       (((? (cut string-prefix? "--tool=" <>) option)
                         files ...)
                        (values (string-drop option
                                             (string-length "--tool="))
                                files))
                       (_ (values #f args))))
         (layer (current-layer))
         (project (layer-project layer))
         (groups (classify-changes layer #:git "git"))
         (changes (selected-changes
                   (append (assq-ref groups 'mergeable)
                           (assq-ref groups 'protected))
                   (map (cut file-in-project project <>) files))))
    (parameterize ((%program-name "guix microvm"))
      (report-skipped groups))
    (if (null? changes)
        (display (G_ "no changes\n"))
        (call-with-diff-trees layer changes
          (lambda (old new)
            (let ((status (wait-for-exit
                           (git-diff-process "git" tool old new))))
              (unless (<= status (if tool 0 1))
                (leave (G_ "~a exited with status ~a~%")
                       (or tool "git diff") status))))))))

(define-command (guix-microvm . args)
  (category development)
  (synopsis "run commands in a microvm with a project's packages")

  (with-error-handling
    (match args
      (("list") (list-vms))
      (("attach" name) (exit (attach-vm! (find-running-vm name))))
      (("kill" name) (kill-vm! (find-running-vm name)))
      (("usb" rest ...) (control-usb rest))
      (("diff" rest ...) (show-diff rest))
      (_ (run-in-microvm args)))))
