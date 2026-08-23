;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;; Per-directory local variables for GNU Emacs, following those of Guix.

((nil
  . ((fill-column . 78)
     (tab-width   .  8)
     (sentence-end-double-space . t)))
 (scheme-mode
  .
  ((indent-tabs-mode . nil)

   ;; Guile and Guix forms used here.
   (eval . (put 'call-with-port 'scheme-indent-function 1))
   (eval . (put 'guard 'scheme-indent-function 1))
   (eval . (put 'lambda* 'scheme-indent-function 1))
   (eval . (put 'match-record 'scheme-indent-function 3))
   (eval . (put 'modify-phases 'scheme-indent-function 1))
   (eval . (put 'modify-services 'scheme-indent-function 1))
   (eval . (put 'substitute-keyword-arguments 'scheme-indent-function 1))
   (eval . (put 'with-imported-modules 'scheme-indent-function 1))
   (eval . (put 'with-extensions 'scheme-indent-function 1))
   (eval . (put 'with-store 'scheme-indent-function 1))
   (eval . (put 'with-build-handler 'scheme-indent-function 1))
   (eval . (put 'with-status-verbosity 'scheme-indent-function 1))
   (eval . (put 'with-error-handling 'scheme-indent-function 0))
   (eval . (put 'with-atomic-file-output 'scheme-indent-function 1))
   (eval . (put 'run-with-store 'scheme-indent-function 1))
   (eval . (put 'mlet 'scheme-indent-function 2))
   (eval . (put 'mbegin 'scheme-indent-function 1))
   (eval . (put 'test-assert 'scheme-indent-function 1))
   (eval . (put 'test-equal 'scheme-indent-function 1))

   ;; Record constructors.
   (eval . (put 'bootloader-configuration 'scheme-indent-function 0))
   (eval . (put 'channel 'scheme-indent-function 0))
   (eval . (put 'file-system 'scheme-indent-function 0))
   (eval . (put 'microvm 'scheme-indent-function 0))
   (eval . (put 'microvm-guest-configuration 'scheme-indent-function 0))
   (eval . (put 'network-address 'scheme-indent-function 0))
   (eval . (put 'network-route 'scheme-indent-function 0))
   (eval . (put 'openssh-configuration 'scheme-indent-function 0))
   (eval . (put 'operating-system 'scheme-indent-function 0))
   (eval . (put 'origin 'scheme-indent-function 0))
   (eval . (put 'package 'scheme-indent-function 0))
   (eval . (put 'service-type 'scheme-indent-function 0))
   (eval . (put 'shepherd-service 'scheme-indent-function 0))
   (eval . (put 'static-networking 'scheme-indent-function 0))
   (eval . (put 'user-account 'scheme-indent-function 0))
   (eval . (put 'user-group 'scheme-indent-function 0))

   ;; Forms of this project.
   (eval . (put 'call-with-launcher 'scheme-indent-function 2))
   (eval . (put 'call-with-process 'scheme-indent-function 2))
   (eval . (put 'call-with-qmp 'scheme-indent-function 1))
   (eval . (put 'call-with-servers 'scheme-indent-function 1))
   (eval . (put 'call-with-temporary-directory 'scheme-indent-function 1))
   (eval . (put 'call-with-vm 'scheme-indent-function 3))
   (eval . (put 'with-build-modules 'scheme-indent-function 0))
   (eval . (put 'with-environment 'scheme-indent-function 1)))))
