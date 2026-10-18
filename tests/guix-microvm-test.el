;;; guix-microvm-test.el --- Tests of guix-microvm.el -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;;; Code:

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
guix-microvm-trees: %S -*-\n# Help.\n" trees)
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

(ert-deftest guix-microvm-selection-abort-in-a-running-emacs ()
  (guix-microvm-test-with-selection '("M f")
    (let ((buffer (current-buffer)))
      (guix-microvm-selection-abort)
      (should-not (buffer-live-p buffer)))))

(provide 'guix-microvm-test)

;;; guix-microvm-test.el ends here
