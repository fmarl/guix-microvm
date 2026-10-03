;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build ssh)
  #:use-module (guix build utils)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (guix-microvm build error)
  #:use-module (guix-microvm build process)
  #:export (shell-quote
            ssh-key-blob
            ssh-spawner
            ssh-succeeds?
            ssh-output
            remote-command
            wayland-forwarding))

(define (shell-quote str)
  (string-append "'" (string-join (string-split str #\') "'\\''") "'"))

(define (ssh-key-blob ssh-keygen key)
  "Return the Base64 part of the public Ed25519 KEY.  Create KEY if
missing."
  (unless (file-exists? key)
    (mkdir-p (dirname key))
    (invoke ssh-keygen "-q" "-t" "ed25519" "-N" "" "-C" "guix-microvm"
            "-f" key))
  (match (string-tokenize
          (call-with-input-file (string-append key ".pub") get-string-all))
    (("ssh-ed25519" blob _ ...) blob)
    (_ (fail "~a.pub is not an Ed25519 key" key))))

(define* (ssh-arguments destination command
                        #:key key socat cid port send-env options)
  "Return ssh arguments to run COMMAND at DESTINATION over vsock CID:PORT
with KEY."
  `("ssh" "-F" "/dev/null" "-q"
    "-i" ,key "-o" "IdentitiesOnly=yes"
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "ForwardAgent=no" "-o" "ForwardX11=no"
    "-o" ,(string-append "SendEnv=" (string-join send-env))
    "-o" ,(format #f "ProxyCommand=~a - VSOCK-CONNECT:~a:~a" socat cid port)
    ,@options
    ,destination
    ,command))

(define* (ssh-spawner ssh destination
                      #:key key socat cid port send-env environment)
  "Return a procedure that runs a command at DESTINATION with SSH over vsock
and returns its PID."
  (lambda* (command #:key (options '())
                    (output (current-output-port))
                    (error (current-error-port)))
    (spawn ssh (ssh-arguments destination command
                              #:key key #:socat socat #:cid cid #:port port
                              #:send-env send-env #:options options)
           #:environment environment #:output output #:error error)))

(define %batch-options
  '("-n" "-o" "BatchMode=yes" "-o" "ConnectTimeout=5"))

(define (ssh-succeeds? spawn-ssh command)
  (zero? (wait-for-exit (spawn-ssh command
                                   #:options %batch-options
                                   #:output (null-port)
                                   #:error (null-port)))))

(define (ssh-output spawn-ssh command)
  (match (pipe)
    ((in . out)
     (let ((pid (spawn-ssh command
                           #:options %batch-options
                           #:output out #:error (null-port))))
       (close-port out)
       (let ((output (get-string-all in)))
         (close-port in)
         (waitpid pid)
         output)))))

(define (remote-command command wrapper status-file)
  "Return a shell command that runs COMMAND, or a login shell if it is empty,
in /work under WRAPPER and writes the exit status to STATUS-FILE."
  (let ((script (string-append "cd /work && "
                               (string-join (if (null? command)
                                                '("\"$SHELL\"" "-l")
                                                (map shell-quote command)))
                               "; echo $? > " status-file)))
    ;; waypipe exits with its own status, so the shell under it writes the
    ;; command's.
    (if (null? wrapper)
        script
        (string-join (append wrapper (list "sh" "-c" (shell-quote script)))))))

;; Over SSH: a vsock listener on the host would be open to every guest.
(define (wayland-forwarding waypipe guest-waypipe name socket guest-socket)
  "Return the servers, command wrapper and ssh options that forward Wayland
from VM NAME to the host, or empty lists without WAYPIPE."
  (if waypipe
      (values (list (server waypipe
                            `("--socket" ,socket "--no-gpu"
                              "--secctx" ,(string-append "guix-microvm." name)
                              "client")
                            socket))
              (list guest-waypipe "--socket" guest-socket "--no-gpu" "server"
                    "--")
              (list "-o" "ExitOnForwardFailure=yes"
                    "-R" (string-append guest-socket ":" socket)))
      (values '() '() '())))
