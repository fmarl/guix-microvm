(define-module (guix-microvm packages claude-code)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system copy)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:export (claude-code))

(define claude-code
  (package
    (name "claude-code")
    (version "2.1.286")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://registry.npmjs.org/@anthropic-ai/"
                           "claude-code-linux-x64/-/claude-code-linux-x64-"
                           version ".tgz"))
       (sha256
        (base32 "1q43lvcxi0vdcf0i57nbg8w9x6j60jpcbc6m9nzyankcbq9dg1s8"))))
    (build-system copy-build-system)
    (arguments
     (list
      ;; Stripping would cut off the appended JavaScript, and the loader is
      ;; passed explicitly by the wrapper.
      #:strip-binaries? #f
      #:validate-runpath? #f
      #:install-plan #~'(("claude" "libexec/claude-code/"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'install-wrapper
            (lambda _
              (let ((wrapper (string-append #$output "/bin/claude"))
                    (libc (string-append #$(this-package-input "glibc") "/lib")))
                (mkdir-p (dirname wrapper))
                (call-with-output-file wrapper
                  (lambda (port)
                    (format port "#!~a
export DISABLE_AUTOUPDATER=1
exec ~a/ld-linux-x86-64.so.2 --library-path ~a ~a/libexec/claude-code/claude \"$@\"~%"
                            #$(file-append bash-minimal "/bin/sh")
                            libc libc #$output)))
                (chmod wrapper #o755)))))))
    (inputs (list bash-minimal glibc))
    (supported-systems '("x86_64-linux"))
    (home-page "https://github.com/anthropics/claude-code")
    (synopsis "Agentic coding tool for the terminal")
    (description "Claude Code is Anthropic's agentic coding assistant.  It
reads and edits code and runs commands in the terminal.")
    (license ((@@ (guix licenses) license) "Nonfree" "file://LICENSE.md"
              "Anthropic Commercial Terms of Service"))))
