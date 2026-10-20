;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build protocol)
  #:export (%ssh-key-option
            %host-name-option
            %volatile-option
            %host-key-name
            %work-tag
            %store-tag
            %home-tag))

(define %ssh-key-option "guix-microvm.ssh-key")
(define %host-name-option "guix-microvm.host-name")
(define %volatile-option "guix-microvm.volatile")

(define %host-key-name ".guix-microvm-ssh-host-key")

(define %work-tag "work")
(define %store-tag "store")
(define %home-tag "home")
