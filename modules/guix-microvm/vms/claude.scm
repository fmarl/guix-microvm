(define-module (guix-microvm vms claude)
  #:use-module (gnu)
  #:use-module (guix-microvm packages claude-code)
  #:use-module (guix-microvm base)
  #:use-module (guix-microvm microvm)
  #:export (%claude-system
            claude-vm))

(use-package-modules base compression curl less linux rust-apps
                     version-control)

(define %claude-system
  (operating-system
    (inherit %base-vm)
    (host-name "claude")
    (packages (append (list claude-code
                            git
                            gnu-make
                            ripgrep
                            curl
                            less
                            gzip
                            procps)
                      %base-packages))
    (services
     (cons (simple-service 'claude-environment
                           session-environment-service-type
                           '(("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
                              . "1")))
           (operating-system-user-services %base-vm)))))

;; CLAUDE_CODE_OAUTH_TOKEN, from `claude setup-token', logs in all projects.
(define claude-vm
  (microvm
    (operating-system %claude-system)
    (secrets '("CLAUDE_CODE_OAUTH_TOKEN" "ANTHROPIC_API_KEY"))))
