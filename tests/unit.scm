;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

(use-modules (guix-microvm build error)
             (guix-microvm build files)
             (guix-microvm build git)
             (guix-microvm build invocation)
             (guix-microvm build layer)
             (guix-microvm build merge)
             (guix-microvm build microvm)
             (guix-microvm build process)
             (guix-microvm build qemu)
             (guix-microvm build registry)
             (guix-microvm build shares)
             (guix-microvm build review)
             (guix-microvm build ssh)
             (guix-microvm build state)
             (guix-microvm base)
             (guix-microvm control)
             (guix-microvm microvm)
             (guix-microvm project)
             (gnu services)
             ((gnu services base) #:select (static-networking))
             ((gnu system) #:select (operating-system))
             ((guix-cage build locked grants)
              #:select (file-access-file file-access-permissions))
             ((guix build utils)
              #:select (mkdir-p delete-file-recursively find-files))
             ((guix diagnostics)
              #:select (guix-warning-port formatted-message?
                        formatted-message-string
                        formatted-message-arguments))
             (ice-9 match)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 threads)
             (ice-9 textual-ports)
             ((rnrs bytevectors) #:select (string->utf8))
             (srfi srfi-1)
             (srfi srfi-26)
             (srfi srfi-34)
             (srfi srfi-64)
             (srfi srfi-71)
             (json))

(define-syntax-rule (define-private module name ...)
  (begin (define name (@@ module name)) ...))

(define-private (guix-microvm build locked-rules)
  qemu-accesses waypipe-client-accesses)

(define-private (guix-microvm build invocation)
  getenv-positive-integer)

(define-private (guix-microvm build microvm)
  vm-files open-log printable)

(define-private (guix-microvm build layer)
  make-layer make-change user-xattrs?)

(define-private (guix-microvm build review)
  read-selection merge-changes selected-changes)

(define-private (guix-microvm microvm)
  passt-port-options passt-network-options microvm-network-options
  check-microvm
  guest-configuration)

(define-private (guix-microvm control)
  usb-id-matches? usb-host-arguments running-vm-ssh)

(define-private (guix extensions microvm)
  string->forwarded-port launcher-flags)

(define-private (guix-microvm project)
  project-digest line->allowed-project allowed-projects project-allowed?
  project-file eval-file load-object vm-module-directories)

(define-syntax-rule (values->list exp)
  (call-with-values (lambda () exp) list))

;; An ssh that does nothing.
(define %fake-ssh
  '((program . "true") (options) (destination . "vm") (variables)
    (secrets "/none")))

(define (exit-code thunk)
  "Return the status THUNK exits with or raises an error for, or #f if it
returns."
  (catch 'quit
    (lambda ()
      (guard (error ((microvm-error? error)
                     (error-status error)))
        (thunk)
        #f))
    (lambda (key status) status)))

(define (quietly thunk)
  (call-with-port (open-file "/dev/null" "w")
    (lambda (null)
      (parameterize ((guix-warning-port null)
                     (current-warning-port null))
        (with-error-to-port null thunk)))))

(define (with-environment variables thunk)
  "Call THUNK with VARIABLES set, an alist of names and values; #f unsets."
  (let ((old (map (match-lambda ((name . _) (cons name (getenv name))))
                  variables)))
    (define (set-all! alist)
      (for-each (match-lambda
                  ((name . #f) (unsetenv name))
                  ((name . value) (setenv name value)))
                alist))
    (dynamic-wind
      (lambda () (set-all! variables))
      thunk
      (lambda () (set-all! old)))))

(define (error-message thunk)
  "Return the message of the error THUNK raises, or #f."
  (guard (error ((formatted-message? error)
                 (string-trim-right
                  (apply format #f (formatted-message-string error)
                         (formatted-message-arguments error)))))
    (thunk)
    #f))

(define (write-file file content)
  (mkdir-p (dirname file))
  (call-with-output-file file (cut display content <>)))

(define (sh-output script)
  (let* ((port (open-pipe* OPEN_READ "sh" "-c" script))
         (output (get-string-all port)))
    (close-pipe port)
    output))

(define (server-script file)
  "Return arguments for sh that write its PID to FILE.pid, create FILE and
sleep."
  `("-c" ,(string-append "echo $$ > " file ".pid; touch " file
                         "; exec sleep 100")))

(define (process-exists? pid)
  (false-if-exception (begin (kill pid 0) #t)))

(define (stopped? pid-file)
  (not (process-exists? (call-with-input-file pid-file read))))

(define (failure-reporter)
  (let ((runner (test-runner-null)))
    (test-runner-on-test-end! runner
      (lambda (runner)
        (when (memq (test-result-kind runner) '(fail xpass))
          (format #t "FAIL: ~a~%~{  ~s~%~}"
                  (test-runner-test-name runner)
                  (test-result-alist runner)))))
    runner))

(test-runner-current (failure-reporter))
(test-begin "unit")

(define tmp
  (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                          "/guix-microvm-test.XXXXXX")))

(test-equal "parse-arguments, nothing"
  '(() "." ())
  (values->list (parse-arguments '())))

(test-equal "parse-arguments, flags, directory and command"
  '(("--stateless" "--persistent") "/p" ("make" "--" "x"))
  (values->list
   (parse-arguments
    '("--stateless" "--persistent" "/p" "--" "make" "--" "x"))))

(test-equal "parse-arguments, command only"
  '(() "." ("ls"))
  (values->list (parse-arguments '("--" "ls"))))

(test-equal "parse-arguments, usage error"
  2
  (exit-code (lambda ()
               (parse-arguments '("a" "b")))))

(test-equal "existing-directory"
  (list (canonicalize-path tmp) 1)
  (list (existing-directory (string-append tmp "/."))
        (exit-code (lambda ()
                     (existing-directory (string-append tmp "/none"))))))

(test-equal "getenv-positive-integer"
  '(7 3 1 1 1)
  (map (lambda (value)
         (with-environment `(("VM_TEST" . ,value))
           (lambda ()
             (or (exit-code (lambda () (getenv-positive-integer "VM_TEST" 7)))
                 (getenv-positive-integer "VM_TEST" 7)))))
       '(#f "3" "1.5" "0" "x")))

(define* (test-config #:key stateless? volatile?)
  (vm-config
    (name "vm") (command '("sh")) (stateless? stateless?)
    (volatile? volatile?) (kernel "/k") (initrd "/i") (kernel-arguments '())
    (store-items "/s") (profile #f) (memory-size 4096)
    (cpu-count 4) (network-options #f) (secrets '())
    (protected-files '())
    (usb? #f) (user "u") (uid 1000) (gid 1000)
    (guest-runtime-directory "/run/user/1000") (ssh-port 2222)))

(test-equal "volatile-vm?"
  '(#f #t #f #t #t 1)
  (list (volatile-vm?)
        (volatile-vm? #:stateless? #t)
        (volatile-vm? #:stateless? #t #:persistent? #t)
        (volatile-vm? #:volatile? #t)
        (volatile-vm? #:volatile-field? #t)
        (exit-code (cut volatile-vm? #:volatile? #t #:persistent? #t))))

(test-equal "host-name"
  '("my-project-vm" "my-project" #f)
  (map host-name '("my-project-vm" "-My_Project." "...")))

(test-equal "unique-name"
  '("a-vm" "a-vm-3")
  (list (unique-name "a-vm" '("b-vm"))
        (unique-name "a-vm" '("a-vm" "a-vm-2"))))

(test-equal "parse-invocation, name"
  '("project-vm" "browser-vm")
  (let ((project (string-append tmp "/Project")))
    (mkdir-p project)
    (map (lambda (args)
           (invocation-name (parse-invocation args (test-config))))
         `((,project) ("--name=browser-vm" ,project)))))

(test-equal "parse-invocation"
  `(,(canonicalize-path tmp) ("make") #t #t 512 4)
  (with-environment '(("VM_MEMORY" . "512") ("VM_CPUS" . #f))
    (lambda ()
      (let ((invocation
             (parse-invocation
              `(,tmp "--" "make")
              (test-config #:stateless? #t))))
        (list (invocation-directory invocation)
              (invocation-command invocation)
              (invocation-stateless? invocation)
              (invocation-volatile? invocation)
              (invocation-memory invocation)
              (invocation-cpus invocation))))))

(test-equal "check-shareable"
  '(1 1 #f 1)
  (with-environment `(("HOME" . ,(string-append tmp "/home"))
                      ("XDG_DATA_HOME" . ,(string-append tmp "/xdg/data")))
    (lambda ()
      (mkdir-p (string-append tmp "/home"))
      (mkdir-p (string-append tmp "/real"))
      (symlink "real" (string-append tmp "/link"))
      (list (exit-code (cut check-shareable tmp))
            (exit-code (cut check-shareable (string-append tmp "/xdg")))
            (exit-code (cut check-shareable (string-append tmp "/p")))
            (with-environment `(("XDG_DATA_HOME"
                                 . ,(string-append tmp "/link/data")))
              (lambda ()
                (exit-code (cut check-shareable
                                (string-append tmp "/real")))))))))

(test-assert "contains-file?"
  (and (contains-file? "/" "/home/u")
       (contains-file? "/home" "/home/u")
       (contains-file? "/home/u" "/home/u")
       (not (contains-file? "/home/u/src" "/home/u"))
       (not (contains-file? "/home/us" "/home/u"))
       (not (contains-file? "/home/u" "/home/us"))))

(test-equal "call-with-project-lock"
  '(1 1 1 #f ok)
  (let ((data (string-append tmp "/locks-data")))
    (call-with-project-lock data "/p"
      (lambda ()
        (list (exit-code (cut call-with-project-lock data "/p" (const #t)))
              (exit-code (cut call-with-project-lock data "/p/q" (const #t)))
              (exit-code (cut call-with-project-lock data "/" (const #t)))
              (exit-code (cut call-with-project-lock data "/pq" (const #t)))
              (call-with-project-lock data "/pq" (const 'ok)))))))

(test-equal "call-with-project-lock, waiting"
  '(1 ok)
  (match (pipe)
    ((input . output)
     (let* ((data (string-append tmp "/waiting-data"))
            (holder (call-with-new-thread
                     (lambda ()
                       (call-with-project-lock data "/p"
                         (lambda ()
                           (write-char #\x output)
                           (force-output output)
                           (usleep 200000)))))))
       (read-char input)
       (list (exit-code (cut call-with-project-lock data "/p" (const #t)))
             (call-with-project-lock data "/p" (const 'ok) #:wait? #t))))))

(test-equal "overlay-options"
  "lowerdir=/a\\,b\\:c\\\\d,upperdir=/u,workdir=/w,userxattr"
  (overlay-options "/a,b:c\\d" "/u" "/w"))

(test-assert "delete-tree"
  (let ((directory (string-append tmp "/tree")))
    (write-file (string-append directory "/locked/sub/file") "")
    (chmod (string-append directory "/locked/sub") #o500)
    (chmod (string-append directory "/locked") #o000)
    (delete-tree directory)
    (not (file-exists? directory))))

(test-equal "tree-entries, parents first"
  '("a" "a/b" "a/b/c")
  (let ((directory (string-append tmp "/entries")))
    (write-file (string-append directory "/a/b/c") "")
    (map car (tree-entries directory))))

(define* (test-layer name #:key (start '()) (host start) (vm '())
                     (deleted '()))
  "Return the layer NAME in TMP over a new project with the files HOST,
which had the contents START when the layer started.  The VM made the files
VM and deleted DELETED.  Files are pairs of a name and contents, or #f for a
directory."
  (let* ((root (string-append tmp "/" name))
         (project (string-append root "-project"))
         (upper (string-append root "/upper")))
    (define (write-files directory files)
      (mkdir-p directory)
      (for-each (match-lambda
                  ((file . #f) (mkdir-p (string-append directory "/" file)))
                  ((file . contents)
                   (write-file (string-append directory "/" file) contents)))
                files))

    (write-files project host)
    (write-files (string-append root "/base") start)
    (write-files upper vm)
    (for-each (lambda (file)
                (let ((whiteout (string-append upper "/" file)))
                  (mkdir-p (dirname whiteout))
                  (mknod whiteout 'char-special #o600 0)))
              deleted)
    (call-with-output-file (string-append root "/project")
      (cut display project <>))
    (open-layer root)))

(define (summary changes)
  (map (lambda (change)
         (list (change-file change) (change-kind change)
               (change-executable? change)))
       changes))

(let ((project (string-append tmp "/snapshot-project"))
      (data (string-append tmp "/data")))
  (write-file (string-append project "/file") "x")

  (unless (user-xattrs? tmp)
    (test-skip "create-layer"))
  (test-assert "create-layer"
    (let ((layer (quietly (cut create-layer! data project #:cp "cp"))))
      (and (file-exists? (layer-upper layer))
           (file-exists? (string-append (layer-lower layer) "/file"))
           (equal? project
                   (layer-project (open-layer (layer-directory layer))))
           (begin
             (delete-layer! layer)
             (not (file-exists? (layer-directory layer)))))))

  (unless (user-xattrs? tmp)
    (test-skip "create-layer, no snapshot"))
  (test-equal "create-layer, no snapshot"
    '(#f #t #t #f)
    (let* ((layer #f)
           (warning (with-error-to-string
                     (lambda ()
                       (set! layer (create-layer! data project
                                                 #:cp "false"))))))
      (list (layer-snapshot layer)
            (and (string-contains warning "cannot snapshot") #t)
            (host-unchanged? layer "file")
            (begin
              (write-file (string-append project "/file") "y")
              (host-unchanged? layer "file")))))

  (when (user-xattrs? tmp)
    (test-skip "create-layer, no user extended attributes"))
  (test-equal "create-layer, no user extended attributes"
    1
    (exit-code (cut create-layer! data project #:cp "cp"))))

(let ((project (string-append tmp "/overlaid")))
  (for-each (lambda (file)
              (write-file (string-append project "/" file) file))
            '("a" "b" "c" "d" "e" "g" "dir/x" "sub/x"))

  (unless (user-xattrs? tmp)
    (test-skip "layer-changes, overlayfs"))
  (test-equal "layer-changes, overlayfs"
    '(("a" modified #f) ("c" modified #t) ("d" deleted #f)
      ("dir" replaced #f) ("dir/n" added #f) ("f" added #f) ("g" deleted #f)
      ("g2" added #f) ("link" added #f) ("new" added #f) ("new/f" added #f)
      ("sub/y" added #f))
    (let ((layer (quietly (cut create-layer! (string-append tmp "/data")
                               project #:cp "cp"))))
      (match (layer-overlay-arguments layer)
        ((lower upper work merged)
         (and (zero? (system* "unshare" "--user" "--map-root-user" "--mount"
                              "sh" "-ec" "
mount -t overlay overlay -o \"$1\" \"$2\"
cd \"$2\"
echo more >> a
touch b
chmod +x c
rm d
printf e > e
rm -r dir
mkdir dir
echo n > dir/n
echo f > f
mv g g2
ln -s a link
mkdir new
echo f > new/f
echo y > sub/y"
                              "sh" (overlay-options lower upper work)
                              merged))
              (summary (layer-changes layer))))))))

(test-equal "layer-changes"
  '(("a" modified #f) ("d" deleted #f) ("n" added #f) ("tool" added #t))
  (let ((layer (test-layer "changes"
                           #:start '(("a" . "a") ("b" . "b") ("d" . "d"))
                           #:vm '(("a" . "vm") ("b" . "b") ("n" . "n")
                                  ("tool" . "#!/bin/sh"))
                           #:deleted '("d"))))
    (chmod (string-append (layer-upper layer) "/tool") #o755)
    (summary (layer-changes layer))))

(test-equal "layer-changes, unreadable directory"
  '(("locked" unreadable #f) ("n" added #f))
  (let ((layer (test-layer "unreadable"
                           #:vm '(("locked/x" . "") ("n" . "")))))
    (chmod (string-append (layer-upper layer) "/locked") 0)
    (summary (layer-changes layer))))

(test-equal "call-with-diff-trees"
  '(("d" "m" "r/x") ("a" "m" "r") #f)
  (let ((layer (test-layer "diff"
                           #:start '(("m" . "m") ("d" . "d") ("r/x" . "x"))
                           #:vm '(("m" . "vm") ("a" . "a") ("r" . "r"))
                           #:deleted '("d"))))
    (define (files directory)
      (sort (map (cut string-drop <> (+ 1 (string-length directory)))
                 (find-files directory))
            string<?))

    (match (call-with-diff-trees layer (layer-changes layer)
             (lambda (before after)
               (list (files before) (files after) before)))
      ((before after directory)
       (list before after (file-exists? directory))))))

(test-assert "git-file?, git-hook-or-config? and protected?"
  (and (git-file? ".git/config")
       (git-file? "sub/.git")
       (not (git-file? ".gitignore"))
       (git-hook-or-config? ".git/hooks/pre-commit")
       (git-hook-or-config? "sub/.git/config")
       (not (git-hook-or-config? ".git/configx"))
       (not (git-hook-or-config? ".git/objects/ab/cd"))
       (protected? "a/.envrc" '())
       (protected? "conf/x" '("conf"))
       (not (protected? "configure" '("conf")))))

(test-equal "classify-changes"
  '((mergeable "src" "src/c" "tracked.o")
    (protected ".envrc")
    (git ".git" ".git/config")
    (ignored "a.o" "build" "build/x")
    (unprintable "x\nM .envrc")
    (unreadable))
  (let ((layer (test-layer "classify"
                           #:host '((".gitignore" . "build/\n*.o\n")
                                    ("tracked.o" . ""))
                           #:vm '(("build/x" . "") ("a.o" . "")
                                  ("tracked.o" . "vm") ("src/c" . "")
                                  (".envrc" . "") (".git/config" . "")
                                  ("x\nM .envrc" . "")))))
    (with-environment '(("GIT_CONFIG_GLOBAL" . "/dev/null")
                        ("GIT_CONFIG_NOSYSTEM" . "1"))
      (lambda ()
        (system* "git" "-C" (layer-project layer) "init" "-q")
        (system* "git" "-C" (layer-project layer) "add" "-f" "tracked.o")
        (map (match-lambda
               ((group . changes) (cons group (map change-file changes))))
             (classify-changes layer #:git "git"))))))

(test-equal "git-check-ignore, only the project's repository"
  '("b/x")
  (let ((project (string-append tmp "/outer/project")))
    (write-file (string-append tmp "/outer/.gitignore") "*\n")
    (write-file (string-append project "/.gitignore") "b/\n")
    (with-environment '(("GIT_CONFIG_GLOBAL" . "/dev/null")
                        ("GIT_CONFIG_NOSYSTEM" . "1"))
      (lambda ()
        (system* "git" "-C" (string-append tmp "/outer") "init" "-q")
        (system* "git" "-C" project "init" "-q")
        (git-check-ignore "git" project '("a" "b/x") tmp)))))

(define (read-file file)
  (call-with-input-file file get-string-all))

(define (merge-test-layer name)
  (test-layer name
              #:start '(("a" . "a\n") ("b" . "b1\nb2\nb3\n") ("d/x" . "x\n")
                        ("d/.git/HEAD" . "") ("d/.envrc" . "")
                        ("e" . "e\n") ("gone" . ""))
              #:host '(("a" . "a\n") ("b" . "B1\nb2\nb3\n") ("d/x" . "x\n")
                       ("d/.git/HEAD" . "") ("d/.envrc" . "")
                       ("e" . "host\n"))
              #:vm '(("a" . "vm\n") ("b" . "b1\nb2\nB3\n") ("e" . "vm\n")
                     ("n" . "n\n") ("link/f" . "f\n"))
              #:deleted '("d" "gone")))

(test-equal "plan-merge and apply-plan"
  '(("vm\n" "B1\nb2\nB3\n" #f #t #t #t "n\n")
    (("d" not-empty) ("d/.envrc" protected) ("e" conflict-markers)
     ("link" changed-on-both) ("link/f" not-a-directory)))
  (let* ((layer (merge-test-layer "merge"))
         (project (layer-project layer))
         (directory (mkdtemp (string-append tmp "/merge-XXXXXX"))))
    (symlink "/nowhere" (string-append project "/link"))
    (let* ((plan (plan-merge layer (layer-changes layer)
                             #:git "git" #:directory directory))
           (problems (append (plan-problems plan) (apply-plan! layer plan))))
      (list (list (read-file (string-append project "/a"))
                  (read-file (string-append project "/b"))
                  (file-exists? (string-append project "/d/x"))
                  (file-exists? (string-append project "/d/.git/HEAD"))
                  (file-exists? (string-append project "/d/.envrc"))
                  (and (string-contains (read-file (string-append project "/e"))
                                        "<<<<<<< host")
                       #t)
                  (read-file (string-append project "/n")))
            (sort (map (lambda (problem)
                         (list (problem-file problem)
                               (problem-reason problem)))
                       problems)
                  (lambda (problem other)
                    (string<? (first problem) (first other))))))))

(test-assert "plan-merge, selected deletion of a protected file"
  (let ((layer (test-layer "protected-deletion"
                           #:start '((".envrc" . ""))
                           #:deleted '(".envrc"))))
    (apply-plan! layer (plan-merge layer (layer-changes layer)
                                  #:git "git" #:directory tmp))
    (not (file-exists? (string-append (layer-project layer) "/.envrc")))))

(test-equal "merge-changes, incomplete"
  '(incomplete "vm\n" #f #t)
  (let ((layer (test-layer "incomplete"
                           #:start '(("a" . "a\n") ("src/x" . "x\n"))
                           #:host '(("a" . "a\n"))
                           #:vm '(("a" . "vm\n") ("src/new" . "new\n")))))
    (list (quietly (cut merge-changes layer (layer-changes layer)
                        #:git "git" #:on-conflict 'markers))
          (read-file (string-append (layer-project layer) "/a"))
          (file-exists? (string-append (layer-upper layer) "/a"))
          (file-exists? (string-append (layer-upper layer) "/src/new")))))

(test-equal "apply-plan, read-only directory"
  '("f" #o555)
  (let* ((layer (test-layer "read-only" #:vm '(("ro/f" . "f"))))
         (upper-ro (string-append (layer-upper layer) "/ro")))
    (chmod upper-ro #o555)
    (apply-plan! layer (plan-merge layer (layer-changes layer)
                                  #:git "git" #:directory tmp))
    (list (read-file (string-append (layer-project layer) "/ro/f"))
          (stat:perms (stat (string-append (layer-project layer) "/ro"))))))

(test-equal "read-selection"
  '("a" "dir/c d")
  (let ((file (string-append tmp "/selection")))
    (write-file file "# Comment\nM a\n# A b\n\nA+x dir/c d\n")
    (read-selection file)))

(test-equal "resolve-layer, discard"
  '(discarded #f "B1\nb2\nb3\n")
  (let ((layer (merge-test-layer "discard")))
    (list (quietly (cut resolve-layer! layer #:git "git" #:policy 'discard))
          (file-exists? (layer-directory layer))
          (read-file (string-append (layer-project layer) "/b")))))

(define (strict-test-layer name host)
  (test-layer name
              #:start '(("f" . "start\n"))
              #:host `(("f" . ,host))
              #:vm '(("f" . "vm\n") ("new" . "new\n")
                     (".envrc" . "evil\n"))))

(test-equal "resolve-layer, merge with a conflict"
  '(conflict #t "host\n" #f)
  (let ((layer (strict-test-layer "conflict" "host\n")))
    (list (quietly (cut resolve-layer! layer #:git "git" #:policy 'merge))
          (file-exists? (layer-directory layer))
          (read-file (string-append (layer-project layer) "/f"))
          (file-exists? (string-append (layer-project layer) "/new")))))

(test-equal "resolve-layer, merge leaves protected files"
  '(merged #f "vm\n" "new\n" #f)
  (let ((layer (strict-test-layer "protected" "start\n")))
    (list (quietly (cut resolve-layer! layer #:git "git" #:policy 'merge))
          (file-exists? (layer-directory layer))
          (read-file (string-append (layer-project layer) "/f"))
          (read-file (string-append (layer-project layer) "/new"))
          (file-exists? (string-append (layer-project layer) "/.envrc")))))

(test-equal "resolve-layer, keep"
  '(kept #t "start\n")
  (let ((layer (strict-test-layer "keep" "start\n")))
    (list (quietly (cut resolve-layer! layer #:git "git" #:policy 'keep))
          (file-exists? (layer-directory layer))
          (read-file (string-append (layer-project layer) "/f")))))

(test-equal "resolve-layer, nothing to keep"
  '(merged #f)
  (let ((layer (test-layer "empty")))
    (list (quietly (cut resolve-layer! layer #:git "git" #:policy 'keep))
          (file-exists? (layer-directory layer)))))

(test-equal "vm-files"
  '("/d/vm/%2Fp%20q" "/d/vm/%2Fp%20q.log" "/d/ssh/id_ed25519")
  (values->list (vm-files "/d" "/t" "vm" "/p q" #f)))

(test-equal "vm-files, stateless"
  '("/t/home" "/t/console.log" "/t/id_ed25519")
  (values->list (vm-files "/d" "/t" "vm" "/p" #t)))

(test-equal "git-identity, from the environment"
  '(("GIT_AUTHOR_NAME" . "A") ("GIT_AUTHOR_EMAIL" . "a@x")
    ("GIT_COMMITTER_NAME" . "C") ("GIT_COMMITTER_EMAIL" . "a@x"))
  (with-environment '(("GIT_AUTHOR_NAME" . "A")
                      ("GIT_AUTHOR_EMAIL" . "a@x")
                      ("GIT_COMMITTER_NAME" . "C")
                      ("GIT_COMMITTER_EMAIL" . #f))
    (lambda ()
      (git-identity "/nonexistent/git" tmp))))

(test-equal "git-config, unset or failing"
  '(#f #f)
  (list (with-environment '(("GIT_CONFIG_GLOBAL" . "/dev/null")
                            ("GIT_CONFIG_NOSYSTEM" . "1"))
          (lambda ()
            (git-config "git" tmp "user.name")))
        (git-config "git" "/nonexistent" "user.name")))

(test-equal "git-identity, from the Git configuration"
  '(("GIT_AUTHOR_NAME" . "B") ("GIT_AUTHOR_EMAIL" . "b@x")
    ("GIT_COMMITTER_NAME" . "B") ("GIT_COMMITTER_EMAIL" . "b@x"))
  (let ((repository (string-append tmp "/repo")))
    (mkdir repository)
    (with-environment `(("GIT_AUTHOR_NAME" . #f)
                        ("GIT_AUTHOR_EMAIL" . #f)
                        ("GIT_COMMITTER_NAME" . #f)
                        ("GIT_COMMITTER_EMAIL" . #f)
                        ("GIT_CONFIG_GLOBAL" . "/dev/null")
                        ("GIT_CONFIG_NOSYSTEM" . "1"))
      (lambda ()
        (sh-output (string-append "cd " repository " && git init -q"
                                  " && git config user.name B"
                                  " && git config user.email b@x"))
        (git-identity "git" repository)))))

(test-equal "read-secrets"
  '(("A" . "secret"))
  (let ((directory (string-append tmp "/secrets")))
    (write-file (string-append directory "/A") "secret\n")
    (read-secrets directory '("A" "MISSING"))))

(test-equal "environment-with"
  '("NEW=1" "PATH=/x")
  (with-environment '(("PATH" . "/usr/bin"))
    (lambda ()
      (let ((environment (environment-with '(("NEW" . "1")
                                             ("PATH" . "/x")))))
        (filter (lambda (entry)
                  (or (string-prefix? "NEW=" entry)
                      (string-prefix? "PATH=" entry)))
                environment)))))

(test-equal "shell-quote"
  "it's \"$HOME\" `x` \\"
  (sh-output (string-append "printf %s "
                            (shell-quote "it's \"$HOME\" `x` \\"))))

(test-equal "child-alive?"
  '(#t #f #f)
  (let ((sleeper (spawn "sleep" '("sleep" "60")))
        (done (spawn "true" '("true"))))
    (let ((alive? (child-alive? sleeper)))
      (kill sleeper SIGKILL)
      (waitpid sleeper)
      (let loop ()
        (when (child-alive? done)
          (usleep 10000)
          (loop)))
      (list alive? (child-alive? sleeper) (child-alive? done)))))

(test-equal "exits-within?"
  '(#f #f #t)
  (let ((sleeper (spawn "sleep" '("sleep" "60")))
        (done (spawn "true" '("true"))))
    (let ((results (list (exits-within? sleeper 0.2)
                         (exits-within? sleeper 0.25)
                         (exits-within? done 5))))
      (kill sleeper SIGKILL)
      (waitpid sleeper)
      results)))

(test-equal "vm-ssh-spawner sends the secrets from their directory"
  "s3cret\n"
  (let ((directory (string-append tmp "/spawner-secrets")))
    (write-file (string-append directory "/SECRET") "s3cret")
    (let ((spawn-ssh (vm-ssh-spawner
                      `((program . "sh")
                        (options . ("-c" "echo \"$SECRET\""))
                        (destination . "vm")
                        (variables . ())
                        (secrets . (,directory "SECRET"))))))
      (ssh-output spawn-ssh "true"))))

(test-equal "ssh-spawner"
  "-F x -n -o BatchMode=yes -o ConnectTimeout=5 vm sync\n"
  (ssh-output (ssh-spawner "echo" '("-F" "x") "vm") "sync"))

(test-equal "remote-command"
  "cd /work && 'echo' 'it'\\''s'; echo $? > /s"
  (remote-command '("echo" "it's") '() "/s"))

(test-equal "remote-command, login shell"
  "cd /work && \"$SHELL\" -l; echo $? > /s"
  (remote-command '() '() "/s"))

;; The status file must be written by the shell under WRAPPER.
(test-equal "remote-command, wrapper"
  (string-append "sh\n-c\n" (remote-command '("echo" "it's") '() "/s")
                 "\n")
  (sh-output (remote-command '("echo" "it's") '("printf" "'%s\\n'")
                             "/s")))

(test-equal "serial-options"
  '(("-chardev" "file,id=serial,path=/l,append=on" "-serial"
     "chardev:serial")
    ("-serial" "stdio"))
  (list (serial-options "/l" #f) (serial-options "/l" "stdio")))

(test-equal "vm-shares"
  '((("store" "/s" #t ("/mount-store" "/items" "/k" "/s" "--"))
     ("work" "/l/merged" #f ("/mount-overlay" "/l/base" "/l/upper" "/l/work"
                             "/l/merged" "--"))
     ("home" "/h" #f ()))
    ("store" "home"))
  (let ((shares volatile
                (values
                 (vm-shares #:layer (make-layer "/l" "/p" "/l/base" #f)
                            #:home "/h" #:uid 1000 #:gid 100 #:store "/s"
                            #:store-items "/items" #:host-key "/k"
                            #:mount-store "/mount-store"
                            #:mount-overlay "/mount-overlay")
                 (vm-shares #:layer #f #:home "/h" #:uid 1000 #:gid 100
                            #:store "/s" #:store-items "/items"
                            #:host-key "/k" #:mount-store "/mount-store"
                            #:mount-overlay "/mount-overlay"))))
    (list (map (lambda (share)
                 (list (share-tag share) (share-directory share)
                       (and (member "--readonly" (share-options share)) #t)
                       (share-wrapper share)))
               shares)
          (map share-tag volatile))))

(test-equal "wayland-forwarding"
  '((() () ())
    (("/host/waypipe" "/h.sock")
     ("/guest/waypipe" "--socket" "/g.sock" "--no-gpu" "server" "--")
     ("-o" "ExitOnForwardFailure=yes" "-R" "/g.sock:/h.sock")))
  (map (match-lambda
         ((waypipe guest-waypipe)
          (let ((servers wrapper options
                         (wayland-forwarding waypipe guest-waypipe "vm"
                                             "/h.sock" "/g.sock")))
            (list (append-map (lambda (server)
                                (list (server-program server)
                                      (server-socket server)))
                              servers)
                  wrapper options))))
       '((#f #f) ("/host/waypipe" "/guest/waypipe"))))

(test-equal "printable"
  "a\tb\n?]52;c;eA==?\\ä?"
  (printable "a\tb\r\n\x1b]52;c;eA==\x1b\\ä\x9b"))

(test-equal "vm-kernel-arguments"
  '(("console=ttyS0" "panic=-1" "guix-microvm.ssh-key=K"
     "guix-microvm.host-name=n" "a")
    ("console=ttyS0" "panic=-1" "guix-microvm.ssh-key=K"
     "guix-microvm.host-name=n" "guix-microvm.volatile=1" "a"))
  (list (vm-kernel-arguments "K" #f "n" '("a"))
        (vm-kernel-arguments "K" #t "n" '("a"))))

(test-assert "qemu-arguments"
  (let ((arguments (qemu-arguments #:kernel "/k" #:initrd "/i"
                                   #:kernel-arguments '("a=1" "b")
                                   #:memory 512 #:cpus 2 #:cid "42"
                                   #:network "/n.sock"
                                   #:serial '("-serial" "stdio")
                                   #:devices '("-device" "d")
                                   #:qmp "/q.sock")))
    (and (equal? (take (member "-append" arguments) 2)
                 '("-append" "a=1 b"))
         (member "-no-reboot" arguments)
         (string-prefix? "on," (second (member "-sandbox" arguments)))
         (equal? (take (member "-m" arguments) 4) '("-m" "512" "-smp" "2"))
         (member "vhost-vsock-device,guest-cid=42" arguments)
         (member "unix:/q.sock,server=on,wait=off" arguments)
         (equal? (take-right arguments 2) '("-device" "d")))))

(test-equal "qemu-arguments, USB"
  '("microvm,acpi=off,rtc=on,memory-backend=mem"
    "microvm,acpi=on,usb=on,rtc=on,memory-backend=mem")
  (map (lambda (usb?)
         (second (qemu-arguments #:kernel "/k" #:initrd "/i"
                                 #:kernel-arguments '() #:memory 512
                                 #:cpus 2 #:cid "42" #:network "/n.sock"
                                 #:serial '() #:devices '() #:usb? usb?
                                 #:qmp "/q.sock")))
       '(#f #t)))

(test-equal "qemu-arguments, no network"
  '(#f ("-device" "virtio-net-device"))
  (let ((arguments (qemu-arguments #:kernel "/k" #:initrd "/i"
                                   #:kernel-arguments '() #:memory 512
                                   #:cpus 2 #:cid "42" #:network #f
                                   #:serial '() #:devices '()
                                   #:qmp "/q.sock")))
    (list (member "-netdev" arguments)
          (take-right arguments 2))))

(test-equal "passt-port-options"
  '(("--tcp-ports" "127.0.0.1/3000")
    ("--tcp-ports" "127.0.0.1/8080:80"))
  (list (passt-port-options 3000) (passt-port-options '(8080 . 80))))

(test-equal "passt-network-options"
  '("--address" "10.0.2.15" "--netmask" "24" "--gateway" "10.0.2.2"
    "--dns-forward" "10.0.2.3")
  (let ((guest (guest-configuration %base-vm)))
    (passt-network-options (microvm-guest-configuration-network guest)
                           (microvm-guest-configuration-name-server guest))))

(test-equal "microvm-network-options"
  '(#t #f)
  (let* ((vm (microvm (operating-system %base-vm) (ports '(3000))))
         (guest (guest-configuration %base-vm)))
    (list (and (member "127.0.0.1/3000" (microvm-network-options vm guest))
               #t)
          (microvm-network-options (microvm (inherit vm) (network? #f))
                                   guest))))

(test-equal "check-microvm"
  '("vm: ports need a network" #f)
  (map (lambda (ports)
         (error-message
          (cut check-microvm (microvm (operating-system %base-vm)
                               (network? #f)
                               (ports ports)))))
       '((3000) ())))

(test-equal "guest-configuration, as configured"
  '("dev" 1001 2223)
  (let ((guest (guest-configuration
                (operating-system
                  (inherit %base-vm)
                  (services
                   (modify-services %microvm-base-services
                     (microvm-guest-service-type
                      config => (microvm-guest-configuration
                                  (inherit config)
                                  (user "dev")
                                  (uid 1001)
                                  (ssh-port 2223)))))))))
    (list (microvm-guest-configuration-user guest)
          (microvm-guest-configuration-uid guest)
          (microvm-guest-configuration-ssh-port guest))))

(test-assert "guest-configuration, without the service"
  (guard (error ((formatted-message? error) #t))
    (guest-configuration (operating-system
                           (inherit %base-vm)
                           (services
                            (remove (lambda (service)
                                      (eq? (service-kind service)
                                           microvm-guest-service-type))
                                    %microvm-base-services))))
    #f))

(test-equal "microvm, invalid fields"
  '("ports: expected a list of PORT or (HOST . GUEST), got (0)"
    "ports: expected a list of PORT or (HOST . GUEST), got ((80 . \"x\"))"
    "secrets: expected a list of variable names, got \"TOKEN\""
    "memory-size: expected a positive integer, got 0"
    "protected-files: expected a list of relative file names, got (\"../x\")"
    #f)
  (map error-message
       (list (lambda () (microvm (operating-system %base-vm) (ports '(0))))
             (lambda ()
               (microvm (operating-system %base-vm) (ports '((80 . "x")))))
             (lambda ()
               (microvm (operating-system %base-vm) (secrets "TOKEN")))
             (lambda ()
               (microvm (operating-system %base-vm) (memory-size 0)))
             (lambda ()
               (microvm (operating-system %base-vm)
                 (protected-files '("../x"))))
             (lambda ()
               (microvm (operating-system %base-vm)
                 (ports '(3000 (8080 . 80)))
                 (secrets '("TOKEN")))))))

(test-equal "microvm-guest-configuration, invalid fields"
  '(#t #t #t #f)
  (map (lambda (thunk)
         (and=> (error-message thunk)
                (cut string-prefix? "invalid value" <>)))
       (list (lambda () (microvm-guest-configuration (ssh-port 22)))
             (lambda () (microvm-guest-configuration (uid "1000")))
             (lambda ()
               (microvm-guest-configuration
                 (network (static-networking
                            (addresses '())
                            (routes '())))))
             (lambda () (microvm-guest-configuration (ssh-port 2223))))))

(test-equal "open-log empties the file"
  "new"
  (let ((file (string-append tmp "/log")))
    (write-file file "old")
    (call-with-port (open-log file) (cut display "new" <>))
    (call-with-input-file file get-string-all)))

(test-assert "call-with-vm-directory deletes it on exit"
  (let ((directory #f))
    (with-environment `(("XDG_RUNTIME_DIR" . ,tmp))
      (lambda ()
        (exit-code (lambda ()
                     (call-with-vm-directory
                       (lambda (d)
                         (set! directory d)
                         (exit 3)))))))
    (and directory (not (file-exists? directory)))))

(test-equal "vm-module-directories finds the vms of every channel"
  `((,tmp . "a/vms") (,tmp . "c/vms"))
  (let ((saved %load-path))
    (for-each (lambda (directory)
                (mkdir-p (string-append tmp "/" directory)))
              '("a/vms" "b/build" "c/vms"))
    (dynamic-wind
      (lambda () (set! %load-path (list tmp)))
      (lambda () (sort (vm-module-directories)
                       (lambda (x y) (string<? (cdr x) (cdr y)))))
      (lambda () (set! %load-path saved)))))

(test-equal "wait-for-exit"
  '(3 143)
  (list (wait-for-exit (spawn "sh" '("sh" "-c" "exit 3")))
        (wait-for-exit (spawn "sh" '("sh" "-c" "kill $$")))))

(test-assert "call-with-process stops it"
  (not (process-exists? (call-with-process "sleep" '("100") identity))))

(test-equal "call-with-servers starts them in order and stops them"
  '(#t #t #t #t)
  (let* ((a (string-append tmp "/a.sock"))
         (b (string-append tmp "/b.sock"))
         (seen '()))
    (call-with-servers (list (server "sh" (server-script a) a)
                             (server "sh" (server-script b) b))
      (lambda ()
        (set! seen (map file-exists? (list a b)))))
    (append seen
            (map (lambda (socket)
                   (stopped? (string-append socket ".pid")))
                 (list a b)))))

(test-equal "call-with-servers fails if one exits"
  1
  (exit-code (lambda ()
               (call-with-servers
                   (list (server "true" '() (string-append tmp
                                                           "/none.sock")))
                 (const #t)))))

(test-equal "call-with-launcher-errors reports and returns the status"
  '(1 "run-vm: no x\n" 7)
  (let* ((status #f)
         (output (with-error-to-string
                  (lambda ()
                    (set! status
                          (call-with-launcher-errors
                           (lambda ()
                             (fail "no ~a" "x"))))))))
    (list status output (call-with-launcher-errors (const 7)))))

(define (fake-qmp-server file)
  "Serve QMP at FILE to one client.  Return the serving thread; joining it
gives the commands received.  Each reply follows an event; the command
\"fail\" gets an error."
  (let ((server (socket PF_UNIX SOCK_STREAM 0)))
    (define (send client message)
      (write-line (scm->json-string message) client)
      (force-output client))

    (bind server AF_UNIX file)
    (listen server 1)
    (call-with-new-thread
     (lambda ()
       (match (accept server)
         ((client . _)
          (send client '(("QMP" . (("version" . "test")))))
          (let loop ((commands '()))
            (match (read-line client)
              ((? eof-object?)
               (close-port client)
               (close-port server)
               (reverse commands))
              (line
               (let ((command (assoc-ref (json-string->scm line) "execute")))
                 (send client '(("event" . "TEST")))
                 (send client
                       (if (string=? command "fail")
                           '(("error" . (("class" . "GenericError")
                                         ("desc" . "failed"))))
                           `(("return" . (("answer" . ,command))))))
                 (loop (cons command commands))))))))))))

(test-equal "string->usb-id"
  '((#x1050 . #f) (#x1050 . #x0407) #f #f #f #f)
  (map string->usb-id '("1050" "1050:0407" "yubi" "1:2:3" "10000" "-1")))

(test-equal "usb-id-matches?"
  '(#t #t #f #f)
  (list (usb-id-matches? '(#x1050 . #f) '(#x1050 . #x0407))
        (usb-id-matches? '(#x1050 . #x0407) '(#x1050 . #x0407))
        (usb-id-matches? '(#x1050 . #x0402) '(#x1050 . #x0407))
        (usb-id-matches? '(#x20a0 . #f) '(#x1050 . #x0407))))

(test-equal "present-usb-devices"
  '(("/dev/bus/usb/001/009") ())
  (let ((sysfs (string-append tmp "/sysfs")))
    (for-each (match-lambda
                ((name vendor product bus device)
                 (for-each (lambda (attribute value)
                             (write-file (string-append sysfs "/" name "/"
                                                        attribute)
                                         (string-append value "\n")))
                           '("idVendor" "idProduct" "busnum" "devnum")
                           (list vendor product bus device))))
              '(("1-1" "1050" "0407" "1" "9")
                ("usb1" "1d6b" "0002" "1" "1")))
    (write-file (string-append sysfs "/1-1:1.0/bInterfaceClass") "03\n")
    (list (present-usb-devices '(#x1050 . #f) sysfs)
          (present-usb-devices '(#x1050 . #x0402) sysfs))))

(test-equal "usb-host-arguments"
  '((("driver" . "usb-host") ("id" . "usb-1050") ("vendorid" . #x1050))
    (("driver" . "usb-host") ("id" . "usb-1050-0407") ("vendorid" . #x1050)
     ("productid" . #x0407)))
  (list (usb-host-arguments '(#x1050 . #f))
        (usb-host-arguments '(#x1050 . #x0407))))

(test-equal "running-vms"
  '(("a" "a" "/p" #t #t "guix-microvm.a/qmp.sock" ((program . "/ssh"))
     "/run-vm" #t 42))
  (let ((runtime (string-append tmp "/runtime")))
    (for-each (lambda (name)
                (mkdir-p (string-append runtime "/" name)))
              '("guix-microvm.empty" "guix-microvm.b" "other"))
    (register! (running-vm (state-directory (string-append runtime
                                                           "/guix-microvm.b"))
                           (name "b") (directory "/p") (ssh %fake-ssh)
                           (launcher "/run-vm") (started 0)))
    (let ((a (running-vm (state-directory (string-append runtime
                                                         "/guix-microvm.a"))
                         (name "a") (directory "/p") (usb? #t) (volatile? #t)
                         (ssh '((program . "/ssh"))) (launcher "/run-vm")
                         (started 42))))
      (mkdir-p (running-vm-state-directory a))
      (call-with-registration a
        (lambda ()
          (register! (running-vm (inherit a) (detached? #t)))
          (map (lambda (vm)
                 (list (running-vm-name vm) (running-vm-id vm)
                       (running-vm-directory vm) (running-vm-usb? vm)
                       (running-vm-volatile? vm)
                       (string-drop (running-vm-qmp-socket vm)
                                    (+ 1 (string-length runtime)))
                       (running-vm-ssh vm) (running-vm-launcher vm)
                       (running-vm-detached? vm) (running-vm-started vm)))
               (running-vms runtime)))))))

(test-equal "kill-vm!"
  '("qmp_capabilities" "quit")
  (let* ((state (string-append tmp "/stop"))
         (server (begin
                   (mkdir-p state)
                   (fake-qmp-server (qmp-socket-file state)))))
    (kill-vm! (running-vm (state-directory state) (name "vm")
                          (directory "/p") (ssh %fake-ssh)
                          (launcher "/run-vm") (started 0)))
    (join-thread server)))

(test-equal "call-with-qmp"
  '((("answer" . "query-status")) "QEMU: failed"
    ("qmp_capabilities" "query-status" "fail"))
  (let* ((file (string-append tmp "/qmp.sock"))
         (server (fake-qmp-server file))
         (results (call-with-qmp file
                    (lambda (execute)
                      (list (execute "query-status")
                            (error-message (cut execute "fail")))))))
    (append results (list (join-thread server)))))

(test-equal "attach-usb!, refused"
  '("vm has no USB controller: its microvm lacks 'usb?'"
    "no USB device ffff is plugged in")
  (map (lambda (usb?)
         (error-message
          (cut attach-usb! (running-vm (state-directory "/none") (name "vm")
                                       (directory "/p") (usb? usb?)
                                       (ssh %fake-ssh) (launcher "/run-vm")
                                       (started 0))
               '(#xffff . #f))))
       '(#f #t)))

(test-equal "normalize-file-name"
  '("/a/c" "/" "/a")
  (map normalize-file-name '("/a/./b/../c/" "/.." "//a//")))

(test-equal "file-under"
  '("" "x" #f)
  (list (file-under "/p" "/p/")
        (file-under "/p" "/p/src/../x")
        (file-under "/p" "/q")))

(test-equal "selected-changes"
  '(3 ("src/b") 3)
  (let ((changes (map (lambda (file)
                         (make-change file 'added 'regular #f))
                       '("a" "src/b" "srcx"))))
    (list (length (selected-changes changes '()))
          (map change-file (selected-changes changes '("src")))
          (length (selected-changes changes '(""))))))

(test-equal "string->forwarded-port"
  '(3000 (8080 . 80) 1)
  (list (string->forwarded-port "3000")
        (string->forwarded-port "8080:80")
        (exit-code (lambda ()
                     (quietly
                       (lambda ()
                         (string->forwarded-port "x")))))))

(test-equal "line->allowed-project"
  '(("/p q" . "abc") #f #f)
  (map line->allowed-project '("abc /p q" "" "abc")))

(test-equal "launcher-flags"
  '(("--name=x-vm") ("--stateless" "--persistent" "--merge"))
  (list (launcher-flags '((vm . "x")))
        (launcher-flags '((merge? . #t) (stateless? . #t)
                          (persistent? . #t)))))

(let* ((project (string-append tmp "/project"))
       (sub (string-append project "/a/b"))
       (manifest (string-append project "/manifest.scm"))
       (vm (string-append project "/vm.scm")))
  (define (allowed?)
    (project-allowed? project (read-project project)))

  (define (allow!)
    (allow-project! project (read-project project)))

  (define (digest)
    (project-digest (read-project project)))

  (mkdir-p sub)
  (write-file manifest "1")

  (test-equal "project-directory"
    project
    (let ((cwd (getcwd)))
      (dynamic-wind
        (cut chdir sub)
        project-directory
        (cut chdir cwd))))

  (test-equal "read-project"
    '((("manifest.scm" . #vu8(49))) ())
    (list (read-project project) (read-project #f)))

  (test-equal "load-object evaluates the contents read, not the file"
    2
    (begin
      (write-file manifest "(+ 1 1)")
      (let ((file (project-file project (read-project project)
                                "manifest.scm")))
        (write-file manifest "(exit 9)")
        (quietly
         (lambda ()
           (load-object file "number" number? '()))))))

  (test-equal "eval-file uses MODULES"
    1
    (quietly
     (lambda ()
       (eval-file manifest (string->utf8 "(match '(1) ((x) (first '(1))))")
                  '((ice-9 match) (srfi srfi-1))))))

  (test-assert "eval-file, errors"
    (every (lambda (code)
             (string-prefix?
              (string-append "failed to load '" manifest "': ")
              (error-message
               (cut eval-file manifest (string->utf8 code) '()))))
           '("(" "unbound-variable")))

  (with-environment `(("XDG_CONFIG_HOME" . ,(string-append tmp "/config")))
    (lambda ()
      (test-equal "allow-project!"
        '(#f #t #f #t)
        (let* ((before (allowed?))
               (_ (allow!))
               (allowed (allowed?)))
          (write-file manifest "2")
          (let ((changed (allowed?)))
            (allow!)
            (list before allowed changed (allowed?)))))

      (test-equal "allow-project! keeps the other projects"
        (sort (list project "/other") string<?)
        (begin
          (write-file (string-append tmp "/config/guix/microvm-allowed")
                      (format #f "~a ~a~%digest /other~%" (digest) project))
          (allow!)
          (sort (map car (allowed-projects)) string<?)))

      (test-assert "project-digest changes when a file disappears"
        (let ((before (begin
                        (write-file vm "v")
                        (digest))))
          (delete-file vm)
          (not (equal? before (digest))))))))

(define (access->list access)
  (list (file-access-file access) (file-access-permissions access)))

(define (unix-socket file)
  (bind (socket PF_UNIX SOCK_STREAM 0) AF_UNIX file)
  file)

(define (call-with-rules-directory proc)
  (proc (mkdtemp (string-append tmp "/rules-XXXXXX"))))

(test-equal "qemu-accesses, missing file"
  '()
  (qemu-accesses '("-append" "rdinit=/init")))

(test-equal "qemu-accesses, files only in file options"
  '(() () (("/dev/null" (read write ioctl))))
  (map (compose (cut map access->list <>) qemu-accesses)
       '(("-append" "root=/dev/null")
         ("-device" "root=/dev/null")
         ("-drive" "file=/dev/null"))))

(test-equal "qemu-accesses, server socket"
  '(("/tmp" (make-socket)))
  (map access->list
       (qemu-accesses
        '("-chardev" "socket,id=m,path=/tmp/qmp.sock,server=on"))))

(test-equal "qemu-accesses, read-only file"
  '((read))
  (call-with-rules-directory
   (lambda (directory)
     (let ((image (string-append directory "/disk.img")))
       (write-file image "")
       (map (compose cadr access->list)
            (qemu-accesses
             (list (string-append "file=" image ",readonly=on"))))))))

(test-assert "qemu-accesses, client socket"
  (call-with-rules-directory
   (lambda (directory)
     (let ((path (unix-socket (string-append directory "/s"))))
       (equal? (map access->list
                    (qemu-accesses
                     (list (string-append "socket,id=c,path=" path))))
               `((,path (connect))))))))

(test-assert "qemu-accesses, unix: prefix"
  (call-with-rules-directory
   (lambda (directory)
     (let ((path (unix-socket (string-append directory "/s"))))
       (equal? (map access->list
                    (qemu-accesses (list "-qmp" (string-append "unix:" path))))
               `((,path (connect))))))))

(test-assert "qemu-accesses, stale server socket"
  (call-with-rules-directory
   (lambda (directory)
     (let ((path (unix-socket (string-append directory "/s"))))
       (and (equal? (map access->list
                         (qemu-accesses
                          (list (string-append "socket,id=m,path=" path
                                               ",server=on"))))
                    `((,directory (make-socket))))
            (not (file-exists? path)))))))

(test-equal "waypipe-client-accesses"
  `((("/run/vm" (make-socket))) (("/run/vm" (make-socket)))
    (("/run/vm" (make-socket))) ((,(getcwd) (make-socket))) () ())
  (map (compose (cut map access->list <>) waypipe-client-accesses)
       '(("--socket" "/run/vm/w.sock" "--no-gpu" "client")
         ("-s" "/run/vm/w.sock" "client")
         ("--socket=/run/vm/w.sock" "client")
         ("--socket" "w.sock" "client")
         ("--socket" "/run/vm/w.sock" "server" "--" "foot")
         ("client"))))

(delete-tree tmp)

(define failures (test-runner-fail-count (test-runner-current)))
(format #t "~a passed, ~a failed~%"
        (test-runner-pass-count (test-runner-current)) failures)
(test-end "unit")
(exit (zero? failures))
