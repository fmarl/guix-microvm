(define-module (guix-microvm kernel)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages linux)
  #:export (linux-microvm))

(define linux-microvm
  (let ((fragment (local-file "kernel/microvm.config")))
    (package
      (inherit linux-libre)
      (name "linux-microvm")
      (arguments
       (substitute-keyword-arguments (package-arguments linux-libre)
         ((#:imported-modules imported-modules %default-gnu-imported-modules)
          `((guix build kconfig) ,@imported-modules))
         ((#:modules modules)
          `((guix build kconfig) (ice-9 textual-ports) ,@modules))
         ((#:phases phases)
          #~(modify-phases #$phases
              (replace 'configure
                (lambda _
                  (setenv "EXTRAVERSION" "-microvm")
                  (invoke "make" "tinyconfig")
                  (modify-defconfig ".config"
                                    (call-with-input-file #$fragment
                                      get-string-all))
                  (invoke "make" "olddefconfig")
                  (verify-config ".config" #$fragment))))))))))
