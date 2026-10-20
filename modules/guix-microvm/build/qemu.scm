;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build qemu)
  #:use-module (ice-9 match)
  #:use-module (guix-microvm build protocol)
  #:export (serial-options
            qemu-arguments
            vm-kernel-arguments))

(define (serial-options log serial)
  "Return QEMU options for the serial console: SERIAL if set, else append to
LOG."
  (match serial
    (#f `("-chardev" ,(string-append "file,id=serial,path=" log ",append=on")
          "-serial" "chardev:serial"))
    (serial `("-serial" ,serial))))

(define* (qemu-arguments #:key kernel initrd kernel-arguments memory cpus cid
                         network serial devices usb? qmp)
  "Return QEMU arguments to boot KERNEL in a microvm.  NETWORK is the passt
socket, or #f for an unconnected NIC."
  `("-M" ,(string-append "microvm,"
                         (if usb? "acpi=on,usb=on" "acpi=off")
                         ",rtc=on,memory-backend=mem")
    "-cpu" "host" "-enable-kvm"
    "-m" ,(number->string memory) "-smp" ,(number->string cpus)
    "-object" ,(format #f "memory-backend-memfd,id=mem,size=~aM,share=on"
                       memory)
    "-nodefaults" "-no-user-config" "-no-reboot"
    "-display" "none" "-monitor" "none"
    "-sandbox" ,(string-append "on,obsolete=deny,elevateprivileges=deny,"
                               "spawn=deny,resourcecontrol=deny")
    "-qmp" ,(string-append "unix:" qmp ",server=on,wait=off")
    ,@serial
    "-kernel" ,kernel "-initrd" ,initrd
    "-append" ,(string-join kernel-arguments)
    "-object" "rng-random,filename=/dev/urandom,id=rng"
    "-device" "virtio-rng-device,rng=rng"
    "-device" ,(string-append "vhost-vsock-device,guest-cid=" cid)
    ;; The guest's static networking, and so its SSH daemon, needs eth0.
    ,@(if network
          `("-netdev" ,(string-append "stream,id=net,server=off,"
                                      "addr.type=unix,addr.path=" network)
            "-device" "virtio-net-device,netdev=net")
          '("-device" "virtio-net-device"))
    ,@devices))

(define (vm-kernel-arguments key-blob volatile? name kernel-arguments)
  "Return the kernel command line, as a list: KERNEL-ARGUMENTS, the SSH key
KEY-BLOB, VOLATILE? and the host NAME."
  ;; With -no-reboot, QEMU exits on a panic.
  `("console=ttyS0" "panic=-1"
    ,(string-append %ssh-key-option "=" key-blob)
    ,(string-append %host-name-option "=" name)
    ,@(if volatile? (list (string-append %volatile-option "=1")) '())
    ,@kernel-arguments))
