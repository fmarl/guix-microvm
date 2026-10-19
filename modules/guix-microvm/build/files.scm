;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(define-module (guix-microvm build files)
  #:use-module ((guix build utils) #:select (delete-file-recursively))
  #:use-module ((ice-9 binary-ports) #:select (get-bytevector-n))
  #:use-module ((ice-9 ftw) #:select (file-system-fold scandir))
  #:use-module (srfi srfi-26)
  #:export (file-in
            contains-file?
            file-stat
            file-type
            directory?
            directory-files
            tree-entries
            same-contents?
            delete-tree
            temporary-file
            call-with-temporary-file))

(define (file-in directory file)
  (cond ((string-null? file) directory)
        ((string-null? directory) file)
        (else (string-append directory "/" file))))

(define (contains-file? directory file)
  (or (string=? directory "/")
      (string=? directory file)
      (string-prefix? (string-append directory "/") file)))

(define (file-stat file)
  (false-if-exception (lstat file)))

(define (file-type file)
  (and=> (file-stat file) stat:type))

(define (directory? file)
  (eq? 'directory (file-type file)))

(define (directory-files directory)
  "Return the names in DIRECTORY, or #f if it cannot be read."
  (scandir directory (negate (cut member <> '("." "..")))))

(define (tree-entries root)
  "Return the files under ROOT, parents first, as pairs of a name relative
to ROOT and its stat."
  (define (add name stat result)
    (if (string=? name root)
        result
        (cons (cons (string-drop name (+ 1 (string-length root))) stat)
              result)))

  (reverse (file-system-fold (const #t) add add
                             (lambda (name stat result) result)
                             add
                             (lambda (name stat errno result) result)
                             '() root lstat)))

(define (same-contents? file other)
  (call-with-input-file file
    (lambda (port)
      (call-with-input-file other
        (lambda (other-port)
          (let loop ()
            (let ((chunk (get-bytevector-n port 65536))
                  (other-chunk (get-bytevector-n other-port 65536)))
              (cond ((eof-object? chunk) (eof-object? other-chunk))
                    ((equal? chunk other-chunk) (loop))
                    (else #f)))))
        #:binary #t))
    #:binary #t))

(define (delete-tree directory)
  ;; overlayfs leaves its work directory without permissions.
  (file-system-fold (lambda (directory stat result) ;enter?
                      (chmod directory #o700)
                      #t)
                    (const #t)          ;leaf
                    (const #t)          ;down
                    (const #t)          ;up
                    (const #t)          ;skip
                    (const #t)          ;error
                    #t
                    directory
                    lstat)
  (delete-file-recursively directory))

(define (temporary-file directory)
  (let* ((port (mkstemp! (string-append directory "/.guix-microvm-XXXXXX")))
         (file (port-filename port)))
    (close-port port)
    file))

(define (call-with-temporary-file directory proc)
  (let ((file (temporary-file directory)))
    (dynamic-wind
      (const #t)
      (cut proc file)
      (lambda ()
        (false-if-exception (delete-file file))))))
