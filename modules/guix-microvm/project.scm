;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm project)
  #:use-module (guix discovery)
  #:use-module ((guix diagnostics)
                #:select (formatted-message &fix-hint))
  #:use-module ((guix profiles) #:select (manifest?))
  #:use-module (guix ui)
  #:use-module ((guix utils)
                #:select (config-directory with-atomic-file-output))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module (gnu system)
  #:use-module (guix-microvm base)
  #:use-module (guix-microvm microvm)
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
  #:export (project-directory
            current-project
            read-project
            allow-project!
            project-microvm))

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

(define (current-project)
  "Return the canonical project directory, or else the current directory."
  (canonicalize-path (or (project-directory) (getcwd))))

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

(define (project-file project contents name)
  "Return NAME in PROJECT paired with its contents, or #f."
  (and=> (assoc-ref contents name)
         (cut cons (string-append project "/" name) <>)))

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

(define* (project-microvm project contents #:key vm (ports '()))
  "Return the microvm of PROJECT, with CONTENTS from 'read-project': the
predefined microvm VM, the one vm.scm defines or the base VM, with the
packages of manifest.scm and the forwarded PORTS.  Fail unless the files are
allowed."
  (let ((vm-file (and (not vm) (project-file project contents "vm.scm")))
        (manifest-file (project-file project contents "manifest.scm")))
    (when (or vm-file manifest-file)
      (ensure-allowed project contents))
    (let ((base (cond (vm (lookup-microvm vm))
                      (vm-file (load-microvm vm-file))
                      (else (microvm (operating-system %base-vm))))))
      (microvm
        (inherit base)
        (manifest (if manifest-file
                      (load-manifest manifest-file)
                      (microvm-manifest base)))
        (ports (append (microvm-ports base) ports))))))
