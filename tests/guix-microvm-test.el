;;; guix-microvm-test.el --- Tests of guix-microvm.el -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'guix-microvm)

(defmacro guix-microvm-test-with-selection (lines &rest body)
  "Run BODY in a selection listing LINES.
The microvm changed f, added n and was given .envrc."
  (declare (indent 1))
  `(let* ((trees (make-temp-file "guix-microvm-test" t))
          (file (expand-file-name "selection" trees))
          (enable-local-variables :safe))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "host" trees))
           (with-temp-file (expand-file-name "host/f" trees)
             (insert "old\n"))
           (make-directory (expand-file-name "project" trees))
           (make-directory (expand-file-name "vm" trees))
           (with-temp-file (expand-file-name "project/f" trees)
             (insert "old\n"))
           (with-temp-file (expand-file-name "vm/f" trees)
             (insert "new\n"))
           (with-temp-file (expand-file-name "vm/n" trees)
             (insert "added\n"))
           (with-temp-file (expand-file-name "vm/.envrc" trees)
             (insert "evil\n"))
           (with-temp-file file
             (insert (format "# -*- mode: guix-microvm-selection; \
guix-microvm-trees: %S; guix-microvm-project: %S -*-\n# Help.\n"
                             trees (expand-file-name "host" trees))
                     (string-join ,lines "\n") "\n"))
           (let ((buffer (find-file-noselect file)))
             (unwind-protect (with-current-buffer buffer ,@body)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (set-buffer-modified-p nil))
                 (kill-buffer buffer)))))
       (delete-directory trees t))))

(ert-deftest guix-microvm-selection-mode-from-header ()
  (guix-microvm-test-with-selection '("M f")
    (should (eq major-mode 'guix-microvm-selection-mode))
    (should (file-directory-p guix-microvm-trees))
    (should buffer-read-only)
    (should (equal (guix-microvm-selection--file) "f"))))

(ert-deftest guix-microvm-selection-preamble-hidden ()
  (guix-microvm-test-with-selection '("M f")
    (should (invisible-p (point-min)))
    (should-not (invisible-p (point)))))

(ert-deftest guix-microvm-selection-navigation ()
  (guix-microvm-test-with-selection '("M f" "A+x n" "# A .envrc")
    (should (equal (guix-microvm-selection--file) "f"))
    (guix-microvm-selection-next)
    (should (equal (guix-microvm-selection--file) "n"))
    (guix-microvm-selection-next)
    (should (equal (guix-microvm-selection--file) ".envrc"))
    (guix-microvm-selection-next)
    (should (equal (guix-microvm-selection--file) ".envrc"))
    (guix-microvm-selection-previous)
    (should (equal (guix-microvm-selection--file) "n"))))

(ert-deftest guix-microvm-selection-toggle ()
  (guix-microvm-test-with-selection '("M f" "A+x n" "# A .envrc")
    (should (equal (guix-microvm-selection--changes t) '("f" "n")))
    (guix-microvm-selection-toggle)
    (should (equal (guix-microvm-selection--file) "n"))
    (guix-microvm-selection-next)
    (guix-microvm-selection-toggle)
    (should (equal (guix-microvm-selection--changes t) '("n" ".envrc")))
    (should (equal (guix-microvm-selection--changes)
                   '("f" "n" ".envrc")))))

(ert-deftest guix-microvm-selection-diff ()
  (guix-microvm-test-with-selection '("M f" "A n")
    (let ((diff (guix-microvm-selection--diff '("f" "n"))))
      (should (string-match-p "^--- project/f" diff))
      (should (string-match-p "^\\+new" diff))
      (should (string-match-p "^\\+\\+\\+ vm/n" diff)))))

(ert-deftest guix-microvm-selection-diff-of-a-replaced-directory ()
  (guix-microvm-test-with-selection '("R r")
    (make-directory (expand-file-name "project/r" guix-microvm-trees))
    (with-temp-file (expand-file-name "project/r/x" guix-microvm-trees)
      (insert "x\n"))
    (with-temp-file (expand-file-name "vm/r" guix-microvm-trees)
      (insert "file\n"))
    (let ((diff (guix-microvm-selection--diff '("r"))))
      (should (string-search "--- project/r/x\n+++ vm/r/x\n@@ -1 +0,0 @@\n-x"
                             diff))
      (should (string-search "--- project/r\n+++ vm/r\n@@ -0,0 +1 @@\n+file"
                             diff)))))

(ert-deftest guix-microvm-selection-toggle-diff ()
  (guix-microvm-test-with-selection '("M f")
    (guix-microvm-selection-toggle-diff)
    (should (string-match-p "^\\+new"
                            (overlay-get (guix-microvm-selection--diff-overlay)
                                         'after-string)))
    (guix-microvm-selection-toggle-diff)
    (should-not (guix-microvm-selection--diff-overlay))))

(ert-deftest guix-microvm-selection-diff-all ()
  (guix-microvm-test-with-selection '("M f" "# A .envrc")
    (guix-microvm-selection-diff-all)
    (with-current-buffer "*guix-microvm diff*"
      (should (eq major-mode 'diff-mode))
      (should (string-match-p "vm/f" (buffer-string)))
      (should-not (string-match-p "\\.envrc" (buffer-string))))))

(ert-deftest guix-microvm-selection-diff-visits-the-project ()
  (guix-microvm-test-with-selection '("M f")
    (let ((host (expand-file-name "host/f" guix-microvm-trees)))
      (guix-microvm-selection-diff)
      (with-current-buffer "*guix-microvm diff*"
        (goto-char (point-min))
        (diff-hunk-next)
        (should (file-equal-p (diff-find-file-name) host))
        (should (eq (key-binding "n") 'diff-hunk-next))
        (should (eq (key-binding (kbd "RET")) 'diff-goto-source))))))

(ert-deftest guix-microvm-selection-finish-in-an-editor-for-the-list ()
  (guix-microvm-test-with-selection '("M f")
    (let ((process-environment
           (cons (concat "GUIX_MICROVM_SELECTION=" buffer-file-name)
                 process-environment))
          (status nil))
      (cl-letf (((symbol-function 'kill-emacs)
                 (lambda (&optional arg) (setq status arg))))
        (guix-microvm-selection-finish))
      (should (eql status 0)))))

(ert-deftest guix-microvm-selection-abort-in-a-running-emacs ()
  (guix-microvm-test-with-selection '("M f")
    (let ((buffer (current-buffer)))
      (guix-microvm-selection-abort)
      (should-not (buffer-live-p buffer)))))

(defmacro guix-microvm-test-with-list (vms &rest body)
  "Run BODY in the list of the running VMS: names, IDs, directories and
optionally states.  Each `guix microvm kill' adds its argument to the file
kills, and `guix microvm resolve' its directory to resolves."
  (declare (indent 1))
  `(let* ((directory (make-temp-file "guix-microvm-test" t))
          (script (expand-file-name "guix" directory))
          (kills (expand-file-name "kills" directory))
          (resolves (expand-file-name "resolves" directory))
          (guix-microvm-command (list script "microvm")))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "list" directory)
             (pcase-dolist (`(,name ,id ,vm-directory ,state) ,vms)
               (prin1 `(vm (name ,name) (id ,id) (up "5m")
                           (state ,(or state "running"))
                           (directory ,vm-directory))
                      (current-buffer))
               (insert "\n")))
           (with-temp-file script
             (insert "#!/bin/sh\n"
                     "case $2 in\n"
                     "list) cat " (expand-file-name "list" directory) ";;\n"
                     "resolve) pwd >> " resolves ";;\n"
                     "kill) if [ \"$3\" = gone ]; then\n"
                     "        echo \"no microvm 'gone' is running\" >&2\n"
                     "        exit 1\n"
                     "      fi\n"
                     "      if [ \"$3\" = asks ]; then\n"
                     "        echo 'merge?'\n"
                     "        exec sleep 30\n"
                     "      fi\n"
                     "      echo \"$3\" >> " kills ";;\n"
                     "esac\n"))
           (set-file-modes script #o700)
           (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore))
             (guix-microvm-list))
           (with-current-buffer "*Microvms*" ,@body))
       (guix-microvm-test-wait-for-kills)
       (dolist (buffer (buffer-list))
         (when (string-prefix-p "*guix-microvm " (buffer-name buffer))
           (kill-buffer buffer)))
       (when (get-buffer "*Microvms*")
         (kill-buffer "*Microvms*"))
       (delete-directory directory t))))

(defun guix-microvm-test-wait-for-kills ()
  "Wait until no `guix microvm kill' or `resolve' runs."
  (while (seq-some (lambda (process)
                     (and (string-prefix-p "guix-microvm"
                                           (process-name process))
                          (process-live-p process)))
                   (process-list))
    (accept-process-output nil 0.05))
  (accept-process-output nil 0.05))

(defun guix-microvm-test-lines (file)
  "Return the lines of FILE, or nil if it is missing."
  (and (file-exists-p file)
       (with-temp-buffer
         (insert-file-contents file)
         (split-string (buffer-string) "\n" t))))

(ert-deftest guix-microvm-list-shows-the-running-vms ()
  (guix-microvm-test-with-list '(("b" "B1" "/tmp")
                                 ("a" "A1" "/a\tb" "detached, changed"))
    (should (equal (mapcar (lambda (entry) (seq-take (car entry) 3))
                           tabulated-list-entries)
                   '(("a" "A1" "/a\tb") ("b" "B1" "/tmp"))))
    (goto-char (point-min))
    (should (equal (seq-take (tabulated-list-get-id) 3)
                   '("a" "A1" "/a\tb")))
    (should (string-match-p "^  a +A1 +5m +detached, changed +/a"
                            (buffer-string)))
    (should (string-match-p "^  b +B1 +5m +running +/tmp$"
                            (buffer-string)))))

(ert-deftest guix-microvm-list-mark-and-execute ()
  (guix-microvm-test-with-list '(("a" "A1" "/") ("b" "B1" "/") ("c" "C1" "/"))
    (goto-char (point-min))
    (guix-microvm-list-mark)
    (guix-microvm-list-mark)
    (guix-microvm-list-mark)
    (forward-line -1)
    (guix-microvm-list-unmark)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt) (should (equal prompt "Kill 2 microvms? ")) t)))
      (guix-microvm-list-execute))
    (guix-microvm-test-wait-for-kills)
    (should (equal (sort (guix-microvm-test-lines kills) #'string<)
                   '("A1" "B1")))))

(ert-deftest guix-microvm-list-execute-asks ()
  (guix-microvm-test-with-list '(("a" "A1" "/"))
    (guix-microvm-list-mark)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt) (should (equal prompt "Kill a in /? ")) nil)))
      (guix-microvm-list-execute))
    (should-not (guix-microvm-test-lines kills))
    (goto-char (point-min))
    (should (eq (char-after) ?D))))

(ert-deftest guix-microvm-list-execute-needs-a-mark ()
  (guix-microvm-test-with-list '(("a" "A1" "/"))
    (should-error (guix-microvm-list-execute) :type 'user-error)))

(ert-deftest guix-microvm-list-kill-at-point ()
  (guix-microvm-test-with-list '(("vm" "A1" "/a") ("vm" "B1" "/b"))
    (goto-char (point-min))
    (forward-line)
    (let ((id (cadr (tabulated-list-get-id))))
      (guix-microvm-list-kill)
      (guix-microvm-test-wait-for-kills)
      (should (equal (guix-microvm-test-lines kills) (list id)))
      (should-not (get-buffer (format "*guix-microvm kill %s*" id))))
    (should (= (length tabulated-list-entries) 2))))

(ert-deftest guix-microvm-list-kill-reports-failures ()
  (guix-microvm-test-with-list '(("a" "gone" "/") ("b" "B1" "/"))
    (goto-char (point-min))
    (guix-microvm-list-mark)
    (guix-microvm-list-mark)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (guix-microvm-list-execute))
    (guix-microvm-test-wait-for-kills)
    (should (equal (guix-microvm-test-lines kills) '("B1")))
    (should-not (get-buffer "*guix-microvm kill B1*"))
    (with-current-buffer "*guix-microvm kill gone*"
      (should (string-match-p "no microvm 'gone' is running"
                              (buffer-string))))))

(ert-deftest guix-microvm-list-kill-buffer-killed-while-asking ()
  (guix-microvm-test-with-list '(("a" "asks" "/"))
    (guix-microvm-list-kill)
    (let ((buffer (get-buffer "*guix-microvm kill asks*")))
      (with-current-buffer buffer
        (while (not (string-match-p "merge\\?" (buffer-string)))
          (accept-process-output nil 0.05)))
      (setq tabulated-list-entries nil)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))
    (guix-microvm-test-wait-for-kills)
    (should tabulated-list-entries)))

(ert-deftest guix-microvm-list-kill-without-a-vm ()
  (guix-microvm-test-with-list '()
    (should-error (guix-microvm-list-kill) :type 'user-error)))

(ert-deftest guix-microvm-list-shell ()
  (guix-microvm-test-with-list '(("a" "A1" "/"))
    (let ((opened nil))
      (cl-letf (((symbol-function 'shell)
                 (lambda (buffer)
                   (setq opened (list buffer default-directory
                                      explicit-shell-file-name)))))
        (guix-microvm-list-shell))
      (should (equal opened '("*shell a*" "/microvm:A1:/work/" "bash"))))))

(ert-deftest guix-microvm-resolve-runs-in-the-project ()
  (guix-microvm-test-with-list '()
    (let ((project (file-truename (make-temp-file "guix-microvm-project" t))))
      (unwind-protect
          (progn
            (guix-microvm-resolve project)
            (guix-microvm-test-wait-for-kills)
            (should (equal (guix-microvm-test-lines resolves)
                           (list (directory-file-name project)))))
        (delete-directory project t)))))

(ert-deftest guix-microvm-list-dired ()
  (guix-microvm-test-with-list '(("a" "A1" "/"))
    (let ((opened nil))
      (cl-letf (((symbol-function 'dired) (lambda (file) (setq opened file))))
        (guix-microvm-list-dired))
      (should (equal opened "/microvm:A1:/work/")))))

(ert-deftest guix-microvm-tramp-method ()
  (require 'tramp)
  (let ((method (assoc "microvm" tramp-methods)))
    (should (equal (cadr (assq 'tramp-login-args method))
                   '(("microvm") ("attach") ("%h"))))
    (should (tramp-tramp-file-p "/microvm:A1:/work/"))
    (should (equal (tramp-file-name-host
                    (tramp-dissect-file-name "/microvm:A1:/work/"))
                   "A1"))))

(ert-deftest guix-microvm-tramp-completes-the-running-vms ()
  (guix-microvm-test-with-list '(("a" "A1" "/") ("b" "B1" "/"))
    (should (equal (guix-microvm-tramp--hosts "")
                   '((nil "A1") (nil "B1"))))))

(provide 'guix-microvm-test)

;;; guix-microvm-test.el ends here
