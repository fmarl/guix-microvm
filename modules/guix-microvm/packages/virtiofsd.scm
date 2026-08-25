;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm packages virtiofsd)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages pkg-config))

(define-public virtiofsd
  (package
    (name "virtiofsd")
    (version "1.14.0")
    (source
     (origin
       (method url-fetch)
       (uri (crate-uri "virtiofsd" version))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "1haw4h0f9mgfsyf5axsyzislwaxyskk1d0jwjhjnx0gjkk6aqlbh"))))
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #f))
    (native-inputs (list pkg-config))
    (inputs (cons* libcap-ng libseccomp
                   (cargo-inputs 'virtiofsd
                                 #:module '(guix-microvm packages rust-crates))))
    (home-page "https://gitlab.com/virtio-fs/virtiofsd")
    (synopsis "Vhost-user virtio-fs device backend")
    (description "virtiofsd is a vhost-user backend for virtio-fs, which
shares a host directory with a virtual machine.")
    (license (list license:asl2.0 license:bsd-3))))
