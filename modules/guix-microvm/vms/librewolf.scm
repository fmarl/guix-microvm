(define-module (guix-microvm vms librewolf)
  #:use-module (gnu)
  #:use-module (guix-microvm base)
  #:use-module (guix-microvm microvm)
  #:export (%librewolf-system
            librewolf-vm))

(use-package-modules glib fonts librewolf)

(define %librewolf-system
  (operating-system
    (inherit %base-vm)
    (host-name "librewolf")
    (packages (append (list librewolf
                            dbus
                            font-dejavu
                            font-liberation)
                      %base-packages))
    (services
     (cons (simple-service 'librewolf-environment
                           session-environment-service-type
                           '(("MOZ_ENABLE_WAYLAND" . "1")))
           %microvm-base-services))))

(define librewolf-vm
  (microvm
    (operating-system %librewolf-system)
    (command '("dbus-run-session" "--" "librewolf"))
    (wayland? #t)
    ;; For security keys, see 'guix microvm usb'.
    (usb? #t)
    (memory-size 6144)))
