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
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module (gnu system)
  #:use-module (guix-microvm base)
  #:use-module (guix-microvm microvm)
  #:use-module (guix-microvm control)
  #:use-module ((guix-microvm build microvm)
                #:select (home-directory contains-home? wait-for-exit))
  #:use-module ((ice-9 binary-ports) #:select (get-bytevector-all))
  #:use-module (ice-9 eval-string)
  #:use-module ((ice-9 exceptions) #:select (exception-kind exception-args))
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module ((rnrs bytevectors) #:select (string->utf8 utf8->string))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-37)
  #:use-module (srfi srfi-71)
  #:export (guix-microvm))

(define (show-help)
  (display (G_ "Usage: guix microvm [OPTION]... [-- COMMAND...]
   or: guix microvm usb attach|detach NAME VENDOR[:PRODUCT]
Run COMMAND, or a login shell, in a microvm sharing the project directory at
/work.  The microvm is the one vm.scm defines, or the base VM, with the
packages of manifest.scm.

Or give the running microvm NAME the host's USB device with the hexadecimal
IDs VENDOR and PRODUCT, which the host lacks until it is detached again.\n"))
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
      --stateless        keep nothing: give the microvm a fresh home and
                         discard its changes to the project directory"))
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
         (option '("stateless") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'stateless? #t result)))
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
  "Return the microvms the (guix-microvm vms ...) modules export, as an alist
by name."
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

(define (allowed-project line)
  "Parse LINE of the allowed file into a directory and digest pair, or #f."
  (match (string-index line #\space)
    (#f #f)
    (index (cons (string-drop line (+ index 1))
                 (string-take line index)))))

(define (allowed-projects)
  "Return the allowed projects as an alist of directories and digests."
  (catch 'system-error
    (lambda ()
      (filter-map allowed-project
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
  "Return vm.scm, unless OPTS name a predefined microvm, and manifest.scm, as
'project-file' does."
  (values (and (not (assoc-ref opts 'vm))
               (project-file project contents "vm.scm"))
          (project-file project contents "manifest.scm")))

(define (ensure-allowed project contents)
  (unless (project-allowed? project contents)
    (report-error (G_ "not loading vm.scm and manifest.scm from '~a': \
they are new or changed~%")
                  project)
    (display-hint (G_ "They run on the host, and the VM can change them.
Review them, then run @command{guix microvm --allow}."))
    (exit 1)))

(define (eval-file file bytes modules)
  "Evaluate BYTES, read from FILE, in a new module using MODULES.  Return the
last value."
  ;; Guix conditions and 'leave' go on to 'with-error-handling'.
  (guard (error ((not (memq (exception-kind error) '(quit %exception)))
                 (report-error (G_ "failed to load '~a':~%") file)
                 (print-exception (current-error-port) #f
                                  (exception-kind error)
                                  (exception-args error))
                 (exit 1)))
    (eval-string (utf8->string bytes)
                 #:module (make-user-module modules)
                 #:file file
                 #:compile? #t)))

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
  "Build VM's launcher and return its file name, in the store monad."
  (mlet %store-monad ((drv (lower-object vm)))
    (mbegin %store-monad
      (built-derivations (list drv))
      (return (derivation->output-path drv)))))

(define (launcher-flags opts)
  (filter-map (match-lambda
                ((key . flag) (and (assoc-ref opts key) flag)))
              '((share-home? . "--share-home")
                (stateless? . "--stateless"))))

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
              ;; Until the store connection is closed.
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
    (when (and (contains-home? directory (home-directory))
               (not (assoc-ref opts 'share-home?)))
      (leave (G_ "not sharing ~a, which contains the home directory, \
without --share-home~%")
             directory))
    (call-with-launcher opts (options->microvm opts vm-file manifest-file)
      (lambda (launcher)
        (exit (run-launcher launcher directory command
                            (launcher-flags opts)))))))

(define (find-running-vm name)
  "Return the running microvm NAME.  If several run, return the one sharing
the current project."
  (match (filter (compose (cut string=? name <>) running-vm-name)
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
  (match args
    (((and action (or "attach" "detach")) name id)
     (let* ((id (or (string->usb-id id)
                    (leave (G_ "~a: expected VENDOR or VENDOR:PRODUCT~%")
                           id)))
            (vm (find-running-vm name)))
       ((if (string=? action "attach") attach-usb! detach-usb!) vm id)))
    (_
     (leave (G_ "usage: guix microvm usb attach|detach NAME \
VENDOR[:PRODUCT]~%")))))

(define-command (guix-microvm . args)
  (category development)
  (synopsis "run commands in a microvm with a project's packages")

  (with-error-handling
    (match args
      (("usb" rest ...) (control-usb rest))
      (_ (run-in-microvm args)))))
