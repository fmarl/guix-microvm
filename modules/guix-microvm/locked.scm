;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm locked)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages virtualization)
  #:use-module (guix gexp)
  #:use-module (guix-cage locked))

(define-locked-rules (guix-microvm build locked-rules)
  %qemu
  %waypipe-client)

(define-public qemu-locked
  (make-locked-package
   qemu
   (list (locked-command
           (name "qemu-system-x86_64")
           (program (file-append qemu "/bin/qemu-system-x86_64"))
           (rules (list (absolute-file "/dev/kvm" '(read write ioctl))
                        (absolute-file "/dev/vhost-vsock" '(read write ioctl))
                        (absolute-file "/sys")
                        %qemu))
           (preserved-environment-variables
            (cons "QEMU_*" %default-preserved-environment-variables))
           ;; KVM only, without TCG's code generator
           (executes? #f)
           (deny-write-execute? #t)))))

(define-public waypipe-locked
  (make-locked-package
   waypipe
   (list (locked-command
           (name "waypipe")
           (program (file-append waypipe "/bin/waypipe"))
           (rules (list %waypipe-client
                        ;; Outside a security context, to create its own
                        %full-wayland
                        ;; For the socket of its security context
                        %runtime-directory))
           (executes? #f)
           (deny-write-execute? #t)))))
