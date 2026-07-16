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
  #:use-module (guix ui)
  #:use-module ((guix utils)
                #:select (config-directory with-atomic-file-output))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((gcrypt hash) #:select (sha256 file-sha256))
  #:use-module (gnu system)
  #:use-module (guix-microvm base)
  #:use-module (guix-microvm microvm)
  #:use-module ((guix-microvm build microvm)
                #:select (contains-home? exit-status))
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-37)
  #:use-module (srfi srfi-71)
  #:export (guix-microvm))

(define (show-help)
  (display (G_ "Usage: guix microvm [OPTION]... [-- COMMAND...]
Run COMMAND, or a login shell, in a microvm sharing the project directory at
/work.  The microvm is the one vm.scm defines, or the base VM, with the
packages of manifest.scm.\n"))
  (display (G_ "
      --vm=NAME          run the predefined microvm NAME, e.g. claude-vm"))
  (display (G_ "
  -p, --port=PORT[:GUEST-PORT]
                         forward PORT on the host's loopback to GUEST-PORT,
                         by default PORT, in the microvm"))
  (display (G_ "
      --share-home       share the project directory even if it is the home
                         directory or one of its parents"))
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
                   (alist-cons 'port (string->port arg) result)))
         (option '("share-home") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'share-home? #t result)))
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

(define (predefined-microvms)
  "Return the names and microvms the (guix-microvm vms ...) modules export, as
an alist."
  (fold-module-public-variables*
   (lambda (module symbol variable result)
     (let ((value (variable-ref variable)))
       (if (microvm? value)
           (alist-cons (symbol->string symbol) value result)
           result)))
   '()
   (all-modules (map (cut cons <> "guix-microvm/vms") %load-path))))

(define (lookup-microvm name)
  (let ((microvms (predefined-microvms)))
    (or (assoc-ref microvms name)
        (leave (G_ "~a: no such microvm, available: ~a~%")
               name (string-join (sort (delete-duplicates (map car microvms))
                                       string<?)
                                 ", ")))))

(define (project-directory)
  "Return the closest directory, starting from the current one, that contains
vm.scm or manifest.scm, or #f."
  (let loop ((directory (getcwd)))
    (cond ((any (lambda (file)
                  (file-exists? (string-append directory "/" file)))
                '("vm.scm" "manifest.scm"))
           directory)
          ((string=? directory "/") #f)
          (else (loop (dirname directory))))))

(define (allowed-file)
  (string-append (config-directory #:ensure? #f) "/microvm-allowed"))

(define (project-digest project)
  "Return a digest of vm.scm and manifest.scm in PROJECT, which changes when
either changes, appears or disappears."
  (bytevector->base16-string
   (sha256
    (string->utf8
     (string-join
      (map (lambda (name)
             (let ((file (string-append project "/" name)))
               (if (file-exists? file)
                   (string-append name " "
                                  (bytevector->base16-string
                                   (file-sha256 file)))
                   name)))
           '("vm.scm" "manifest.scm"))
      "\n")))))

(define (allowed-projects)
  "Return the allowed projects, as an alist of directories and digests."
  (catch 'system-error
    (lambda ()
      (call-with-input-file (allowed-file)
        (lambda (port)
          (let loop ((projects '()))
            (match (read-line port)
              ((? eof-object?) projects)
              (line
               (match (string-index line #\space)
                 (#f (loop projects))
                 (index
                  (loop (alist-cons (string-drop line (+ index 1))
                                    (string-take line index)
                                    projects))))))))))
    (const '())))

(define (allow-project! project)
  (let ((others (alist-delete project (allowed-projects))))
    (config-directory)
    (with-atomic-file-output (allowed-file)
      (lambda (port)
        (for-each (match-lambda
                    ((directory . digest)
                     (format port "~a ~a~%" digest directory)))
                  (alist-cons project (project-digest project) others))))))

(define (project-files opts)
  "Return the project directory, or #f, and its vm.scm, unless OPTS name a
predefined microvm, and manifest.scm, or #f."
  (let ((project (project-directory)))
    (define (project-file name)
      (let ((file (and project (string-append project "/" name))))
        (and file (file-exists? file) file)))

    (when (assoc-ref opts 'allow?)
      (unless project
        (leave (G_ "no vm.scm or manifest.scm to allow~%")))
      (allow-project! project))

    (let ((vm (and (not (assoc-ref opts 'vm))
                   (project-file "vm.scm")))
          (manifest (project-file "manifest.scm")))
      ;; Both run on the host, and the VM can change them.
      (when (and (or vm manifest)
                 (not (equal? (assoc-ref (allowed-projects) project)
                              (project-digest project))))
        (report-error (G_ "not loading vm.scm and manifest.scm from '~a': \
they are new or changed~%")
                      project)
        (display-hint (G_ "They run on the host, and the VM can change them.
Review them, then run @command{guix microvm --allow}."))
        (exit 1))
      (values project vm manifest))))

(define (load-microvm file)
  (info (G_ "loading microvm from '~a'...~%") file)
  (match (load* file '((guix-microvm microvm) (guix-microvm base) (gnu)))
    ((? microvm? vm) vm)
    (_ (leave (G_ "~a: expected a microvm~%") file))))

(define (load-manifest file)
  (info (G_ "loading manifest from '~a'...~%") file)
  (match (load* file '((guix profiles) (gnu)))
    ((? manifest? manifest) manifest)
    (_ (leave (G_ "~a: expected a manifest~%") file))))

(define (string->port str)
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
  "Return, as a monadic value, the file name of the launcher of VM, once
built."
  (mlet %store-monad ((drv (lower-object vm)))
    (mbegin %store-monad
      (built-derivations (list drv))
      (return (derivation->output-path drv)))))

(define (run-launcher launcher directory command share-home?)
  "Run LAUNCHER with DIRECTORY and COMMAND, and return its exit status."
  (exit-status
   (cdr (waitpid (spawn launcher
                        `(,launcher
                          ,@(if share-home? '("--share-home") '())
                          ,directory "--" ,@command))))))

(define-command (guix-microvm . args)
  (category development)
  (synopsis "run commands in a microvm with a project's packages")

  (with-error-handling
    (let* ((opts command (parse-arguments args))
           (project vm-file manifest-file (project-files opts))
           (directory (or project (getcwd)))
           (share-home? (assoc-ref opts 'share-home?)))
      (when (and (contains-home? directory) (not share-home?))
        (leave (G_ "not sharing ~a, which contains the home directory, \
without --share-home~%")
               directory))
      (let ((vm (options->microvm opts vm-file manifest-file)))
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
                  ;; With nothing to build, 'build-notifier' lets a dry run
                  ;; get this far.
                  (unless (assoc-ref opts 'dry-run?)
                    ;; Until the store connection is closed.
                    (add-temp-root store launcher)
                    (exit (run-launcher launcher directory command
                                        share-home?))))))))))))
