;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm packages emacs)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix build-system emacs)
  #:use-module ((guix licenses) #:prefix license:))

;; guix pull links the module directory into the whole checkout of the
;; channel, so emacs/ is found next to it.
(define %emacs-directory
  (canonicalize-path
   (string-append (dirname (search-path %load-path
                                        "guix-microvm/packages/emacs.scm"))
                  "/../../../emacs")))

(define-public emacs-guix-microvm
  (package
    (name "emacs-guix-microvm")
    (version "0.2")
    (source
     (local-file (string-append %emacs-directory "/guix-microvm.el")))
    (build-system emacs-build-system)
    (home-page "https://github.com/fmarl/guix-microvm")
    (synopsis "Emacs mode for selecting the changes of a microvm")
    (description
     "This package provides an Emacs mode for the list of changes
that @command{guix microvm} opens to select the ones to merge.  It shows the
diff of the file at point and finishes or aborts the selection.")
    (license license:gpl3+)))
