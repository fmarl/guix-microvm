;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build locked-rules)
  #:use-module (ice-9 match)
  #:use-module (ice-9 receive)
  #:use-module (guix-cage build locked file-names)
  #:use-module (guix-cage build locked grants)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:export (%qemu
            %waypipe-client))

(define %server-options
  '("server" "server=on" "server=yes" "server=true"))

(define %read-only-options
  '("readonly" "readonly=on" "readonly=yes" "read-only=on" "read-only=yes"))

;; Options whose values are text, such as the kernel command line
(define %text-options
  '("append" "name" "smbios" "prom-env"))

;; Suboptions such as file=, or blockdev's file.filename=
(define %file-keys
  '("file" "filename" "path" "mem-path" "addr" "script" "downscript"))

(define (text-option? argument)
  (member (string-trim argument #\-) %text-options))

(define (file-arguments arguments)
  "Return ARGUMENTS without the values of %text-options."
  (match arguments
    (() '())
    (((? text-option?) _ . rest) (file-arguments rest))
    ((argument . rest) (cons argument (file-arguments rest)))))

(define (parse-argument argument)
  (let ((options (string-split argument #\,)))
    (values options
            (any (cut member <> %server-options) options)
            (any (cut member <> %read-only-options) options))))

(define (option-value option)
  "Return the value of OPTION if it is one that can name a file, such as
file=VALUE or a VALUE without key, or #f."
  (match (string-index option #\=)
    (#f option)
    (index
     (let ((key (substring option 0 index)))
       (and (member (last (string-split key #\.)) %file-keys)
            (substring option (1+ index)))))))

(define (option-file option)
  (let* ((value (option-value option))
         (file (if (and value (string-prefix? "unix:" value))
                   (string-drop value (string-length "unix:"))
                   value)))
    (and file
         (string-prefix? "/" file)
         (not (string-prefix? "/gnu/store/" file))
         (not (string-any char-whitespace? file))
         file)))

(define (file-type file)
  (and=> (false-if-exception (stat file)) stat:type))

(define (option-access file server? read-only?)
  "Return the access to FILE that QEMU needs.  Remove a stale socket that
it listens on."
  (let ((file (absolute-file-name file)))
    (match (file-type file)
      ('regular
       (file-access file (if read-only? '(read) '(read write))))
      ((or 'char-special 'block-special)
       (file-access file (if read-only? '(read ioctl) '(read write ioctl))))
      ('fifo (file-access file '(read write)))
      ('directory (read-access file))
      ('socket
       (if server?
           (begin
             (delete-file file)
             (socket-directory-access file))
           (file-access file '(connect))))
      (#f
       (and server? (socket-directory-access file)))
      (_ #f))))

(define (usb-accesses arguments)
  (if (any (cut string-contains <> "usb=on") arguments)
      (list (file-access "/dev/bus/usb" '(read write ioctl)))
      '()))

(define (qemu-accesses arguments)
  (append (append-map (lambda (argument)
                        (receive (options server? read-only?)
                            (parse-argument argument)
                          (filter-map (cut option-access <> server? read-only?)
                                      (filter-map option-file options))))
                      (file-arguments arguments))
          (usb-accesses arguments)))

(define (waypipe-socket arguments)
  (match arguments
    (() #f)
    (((or "--socket" "-s") socket . _) socket)
    ((argument . rest)
     (if (string-prefix? "--socket=" argument)
         (string-drop argument (string-length "--socket="))
         (waypipe-socket rest)))))

(define (waypipe-client-accesses arguments)
  (match (and (member "client" arguments)
              (waypipe-socket arguments))
    (#f '())
    (socket (list (socket-directory-access (absolute-file-name socket))))))

(define (%qemu command-line)
  "Grant the files and sockets that the options of QEMU name."
  (grant #:files (qemu-accesses (cdr command-line))))

(define (%waypipe-client command-line)
  "Grant creating the socket of a waypipe client."
  (grant #:files (waypipe-client-accesses (cdr command-line))))
