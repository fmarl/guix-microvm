;;; guix-microvm.el --- Interface to guix microvm -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;; Version: 0.3
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, vc
;; URL: https://github.com/fmarl/guix-microvm

;;; Commentary:

;; When a microvm exits, 'guix microvm' asks what to do with its changes to
;; the project.  "[s]elect" opens the list of changes in the editor; it
;; merges those still listed and not commented out.  In Emacs, that list
;; gets `guix-microvm-selection-mode', which shows the diffs and switches
;; changes between merged and skipped.
;;
;; `guix-microvm-list' lists the running microvms to open their /work with
;; TRAMP or to kill them.

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'diff-mode)
(require 'seq)
(require 'server)

(defvar-local guix-microvm-trees nil
  "Directory with the files of the selection in project/ and vm/.
They are as before the microvm ran, in project/, and after, in vm/.")
(put 'guix-microvm-trees 'safe-local-variable #'stringp)

(defvar-local guix-microvm-project nil
  "Directory of the project that the selection merges into.")
(put 'guix-microvm-project 'safe-local-variable #'stringp)

(defconst guix-microvm-selection--change
  (rx bol (group (? "# ")) (group (any "ADMR") (? "+x")) " "
      (group (+ nonl)) eol)
  "Regexp matching a change: whether it is skipped, its label and its file.")

(defconst guix-microvm-selection-font-lock-keywords
  `((,(rx bol "# " (any "ADMR") (? "+x") " " (+ nonl)) 0 'shadow)
    (,(rx bol (group "A") (? "+x") " ") 1 'diff-added)
    (,(rx bol (group "D") " ") 1 'diff-removed)
    (,(rx bol (group (any "MR")) (? "+x") " ") 1 'diff-changed)
    (,(rx bol (any "AMR") (group "+x") " ") 1 'warning)))

(defun guix-microvm-selection--changes (&optional merged)
  "Return the files of the changes in the buffer.
If MERGED is non-nil, return only those that are not skipped."
  (save-excursion
    (goto-char (point-min))
    (let (files)
      (while (re-search-forward guix-microvm-selection--change nil t)
        (when (or (not merged) (string-empty-p (match-string 1)))
          (push (match-string-no-properties 3) files)))
      (nreverse files))))

(defun guix-microvm-selection--at-change ()
  "Go to the beginning of the line and match the change on it."
  (beginning-of-line)
  (unless (looking-at guix-microvm-selection--change)
    (user-error "No change at point")))

(defun guix-microvm-selection--file ()
  "Return the file of the change at point."
  (save-excursion
    (guix-microvm-selection--at-change)
    (match-string-no-properties 3)))

(defun guix-microvm-selection--insert-alone (file side)
  "Insert the diff of FILE on SIDE, `old' or `new', against nothing."
  (let* ((root (if (eq side 'old) "project/" "vm/"))
         (top (concat root file)))
    (dolist (path (if (file-directory-p top)
                      (directory-files-recursively top "")
                    (list top)))
      (let ((name (substring path (length root))))
        (process-file diff-command nil t nil "-u"
                      "--label" (concat "project/" name)
                      "--label" (concat "vm/" name)
                      (if (eq side 'old) path null-device)
                      (if (eq side 'old) null-device path))))))

(defun guix-microvm-selection--diff (files)
  "Return the diff of FILES between project/ and vm/, fontified."
  (unless guix-microvm-trees
    (user-error "The list names no files to compare"))
  (let ((default-directory (file-name-as-directory guix-microvm-trees)))
    (with-temp-buffer
      (dolist (file files)
        (let ((old (concat "project/" file))
              (new (concat "vm/" file)))
          ;; diff compares a directory with a file inside it, not with the
          ;; file itself.
          (if (and (file-exists-p old) (file-exists-p new)
                   (not (eq (file-directory-p old) (file-directory-p new))))
              (progn
                (guix-microvm-selection--insert-alone file 'old)
                (guix-microvm-selection--insert-alone file 'new))
            (process-file diff-command nil t nil "-u" "-N" "-r" old new))))
      (delay-mode-hooks (diff-mode))
      (font-lock-ensure)
      (buffer-string))))

(defun guix-microvm-selection--show-diff (files)
  "Show the diff of FILES in a buffer."
  (let ((diff (guix-microvm-selection--diff files))
        ;; diff-mode finds vm/FILE as FILE there, for `diff-goto-source'.
        (directory (file-name-as-directory
                    (or guix-microvm-project guix-microvm-trees)))
        (buffer (get-buffer-create "*guix-microvm diff*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff))
      ;; Read-only before diff-mode, which then enables its keys such as n
      ;; and RET.
      (setq buffer-read-only t)
      (diff-mode)
      (setq default-directory directory)
      (goto-char (point-min)))
    (display-buffer buffer)))

(defun guix-microvm-selection-diff ()
  "Show the diff of the change at point in its own buffer."
  (interactive)
  (guix-microvm-selection--show-diff (list (guix-microvm-selection--file))))

(defun guix-microvm-selection-diff-all ()
  "Show the diff of all the changes to merge in one buffer."
  (interactive)
  (guix-microvm-selection--show-diff (guix-microvm-selection--changes t)))

(defun guix-microvm-selection--diff-overlay ()
  "Return the overlay showing the diff of the change at point, or nil."
  (seq-find (lambda (overlay)
              (overlay-get overlay 'guix-microvm-diff))
            (overlays-in (line-end-position) (line-end-position))))

(defun guix-microvm-selection-toggle-diff ()
  "Show or hide the diff of the change at point below it."
  (interactive)
  (let ((file (guix-microvm-selection--file)))
    (if-let* ((overlay (guix-microvm-selection--diff-overlay)))
        (delete-overlay overlay)
      (let ((overlay (make-overlay (line-end-position) (line-end-position))))
        (overlay-put overlay 'guix-microvm-diff t)
        (overlay-put overlay 'after-string
                     (concat "\n" (string-trim-right
                                   (guix-microvm-selection--diff
                                    (list file)))))))))

(defun guix-microvm-selection-toggle ()
  "Switch the change at point between merged and skipped.
Then go to the next change."
  (interactive)
  (let ((inhibit-read-only t))
    (save-excursion
      (guix-microvm-selection--at-change)
      (if (looking-at "# ")
          (delete-char 2)
        (insert "# "))))
  (guix-microvm-selection-next))

(defun guix-microvm-selection-next ()
  "Go to the next change."
  (interactive)
  (let ((start (point)))
    (end-of-line)
    (if (re-search-forward guix-microvm-selection--change nil t)
        (beginning-of-line)
      (goto-char start))))

(defun guix-microvm-selection-previous ()
  "Go to the previous change."
  (interactive)
  (beginning-of-line)
  (when (re-search-backward guix-microvm-selection--change nil t)
    (beginning-of-line)))

(defun guix-microvm-selection--done (status)
  "End the selection: merge if STATUS is 0, else go back to the question."
  (cond (server-buffer-clients
         (if (zerop status) (server-edit) (server-edit-abort)))
        ((when-let* ((file (getenv "GUIX_MICROVM_SELECTION")))
           (file-equal-p file buffer-file-name))
         (kill-emacs status))
        (t (kill-buffer))))

(defun guix-microvm-selection-finish ()
  "Merge the changes the list leaves."
  (interactive)
  (save-buffer)
  (guix-microvm-selection--done 0))

(defun guix-microvm-selection-abort ()
  "Go back to the question without merging."
  (interactive)
  (guix-microvm-selection--done 1))

(defvar-local guix-microvm-selection--header-line nil
  "The header line, and the modification tick of the buffer it is for.")

(defun guix-microvm-selection--header-line ()
  "Return the header line: how many changes are merged, and the keys."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eql tick (car guix-microvm-selection--header-line))
      (setq guix-microvm-selection--header-line
            (cons tick (guix-microvm-selection--make-header-line))))
    (cdr guix-microvm-selection--header-line)))

(defun guix-microvm-selection--make-header-line ()
  "Return a new header line."
  (format "%d of %d changes merged.  %s"
          (length (guix-microvm-selection--changes t))
          (length (guix-microvm-selection--changes))
          (substitute-command-keys
           "\\<guix-microvm-selection-mode-map>\
\\[guix-microvm-selection-toggle] merge or skip, \
\\[guix-microvm-selection-toggle-diff] diff, \
\\[guix-microvm-selection-diff-all] all diffs, \
\\[guix-microvm-selection-finish] done, \
\\[guix-microvm-selection-abort] cancel")))

(defun guix-microvm-selection--hide-preamble ()
  "Hide the comments before the first change."
  (save-excursion
    (goto-char (point-min))
    (while (and (looking-at "#")
                (not (looking-at guix-microvm-selection--change)))
      (forward-line))
    (unless (bobp)
      (overlay-put (make-overlay (point-min) (point)) 'invisible t))))

(defvar-keymap guix-microvm-selection-mode-map
  :parent special-mode-map
  "t" #'guix-microvm-selection-toggle
  "TAB" #'guix-microvm-selection-toggle-diff
  "RET" #'guix-microvm-selection-diff
  "a" #'guix-microvm-selection-diff-all
  "n" #'guix-microvm-selection-next
  "p" #'guix-microvm-selection-previous
  "C-c C-c" #'guix-microvm-selection-finish
  "C-c C-k" #'guix-microvm-selection-abort
  "q" #'guix-microvm-selection-abort)

;;;###autoload
(define-derived-mode guix-microvm-selection-mode special-mode
  "Microvm-Selection"
  "Major mode for selecting the changes of a microvm to merge.

\\{guix-microvm-selection-mode-map}"
  (setq-local font-lock-defaults
              '(guix-microvm-selection-font-lock-keywords t))
  (setq-local header-line-format
              '(:eval (guix-microvm-selection--header-line)))
  (remove-overlays)
  (guix-microvm-selection--hide-preamble)
  (goto-char (point-min))
  (when (re-search-forward guix-microvm-selection--change nil t)
    (beginning-of-line)))

(defgroup guix-microvm nil
  "Guix System VMs per project."
  :group 'tools)

(defcustom guix-microvm-command '("guix" "microvm")
  "Program and arguments that run \"guix microvm\"."
  :type '(repeat string))

(defconst guix-microvm-tramp-method "microvm"
  "TRAMP method for files in a running microvm, whose ID is the host.")

(defun guix-microvm--output (&rest arguments)
  "Run `guix-microvm-command' with ARGUMENTS.
Return its output, or signal an error with what it reported."
  ;; default-directory may be remote.
  (let ((default-directory (expand-file-name "~/"))
        (error-file (make-temp-file "guix-microvm")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (car guix-microvm-command)
                               nil (list t error-file) nil
                               (append (cdr guix-microvm-command) arguments))))
            (unless (eql status 0)
              ;; guix names itself in its messages.
              (error "%s" (with-temp-buffer
                            (insert-file-contents error-file)
                            (string-trim (buffer-string)))))
            (buffer-string)))
      (delete-file error-file))))

(defun guix-microvm--running ()
  "Return the running microvms as lists of their name, ID and directory."
  (mapcan (lambda (line)
            (pcase (split-string line "\t")
              (`(,name ,id . ,directory)
               (list (list name id (string-join directory "\t"))))))
          (split-string (guix-microvm--output "list") "\n" t)))

(defun guix-microvm-tramp-file (id)
  "Return the name of /work in the running microvm ID."
  (format "/%s:%s:/work/" guix-microvm-tramp-method id))

(defun guix-microvm-tramp--hosts (_file)
  "Return the running microvms for completing TRAMP file names."
  (mapcar (pcase-lambda (`(,_ ,id ,_)) (list nil id))
          (ignore-errors (guix-microvm--running))))

(defvar tramp-methods)
(declare-function tramp-set-completion-function "tramp")
(declare-function tramp-cleanup-connection "tramp-cmds")
(declare-function tramp-dissect-file-name "tramp")

;;;###autoload
(defun guix-microvm-tramp-add-method ()
  "Add the TRAMP method that opens files in running microvms."
  (add-to-list 'tramp-methods
               `(,guix-microvm-tramp-method
                 (tramp-login-program ,(car guix-microvm-command))
                 (tramp-login-args (,@(mapcar #'list (cdr guix-microvm-command))
                                    ("attach") ("%h")))
                 (tramp-remote-shell "/bin/sh")
                 (tramp-remote-shell-login ("-l"))
                 (tramp-remote-shell-args ("-c"))))
  (tramp-set-completion-function guix-microvm-tramp-method
                                 '((guix-microvm-tramp--hosts "")))
  ;; The login shell adds the packages of the project to PATH.
  (connection-local-set-profile-variables
   'guix-microvm-tramp '((tramp-remote-path tramp-own-remote-path)))
  (connection-local-set-profiles
   `(:application tramp :protocol ,guix-microvm-tramp-method)
   'guix-microvm-tramp))

;;;###autoload
(with-eval-after-load 'tramp
  (guix-microvm-tramp-add-method))

(defun guix-microvm-list--refresh ()
  "Fill the list with the running microvms."
  (let ((vms (guix-microvm--running)))
    (cl-flet ((width (title n)
                (list title
                      (apply #'max (length title)
                             (mapcar (lambda (vm) (length (nth n vm))) vms))
                      t)))
      (setq tabulated-list-format
            (vector (width "Name" 0) (width "ID" 1) '("Project" 0 t))))
    (setq tabulated-list-entries
          (mapcar (lambda (vm) (list vm (apply #'vector vm))) vms))
    (tabulated-list-init-header)))

(defun guix-microvm-list--kill-all (vms)
  "Kill VMS, report those that failed, and refresh the list."
  (let ((failures nil))
    (pcase-dolist (`(,_ ,id ,_) vms)
      (condition-case error
          (progn
            (guix-microvm--output "kill" id)
            (when (featurep 'tramp)
              (tramp-cleanup-connection
               (tramp-dissect-file-name (guix-microvm-tramp-file id)))))
        (error (push (error-message-string error) failures))))
    (revert-buffer)
    (when failures
      (message "%s" (string-join (nreverse failures) "\n")))))

(defun guix-microvm-list-mark ()
  "Mark the microvm at point to be killed.
\\<guix-microvm-list-mode-map>\\[guix-microvm-list-execute] kills the marked
ones."
  (interactive nil guix-microvm-list-mode)
  (tabulated-list-put-tag "D" t))

(defun guix-microvm-list-unmark ()
  "Remove the mark of the microvm at point."
  (interactive nil guix-microvm-list-mode)
  (tabulated-list-put-tag " " t))

(defun guix-microvm-list-execute ()
  "Kill the marked microvms."
  (interactive nil guix-microvm-list-mode)
  (let ((marked nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (eq (char-after) ?D)
          (push (tabulated-list-get-id) marked))
        (forward-line)))
    (unless marked
      (user-error "No microvm marked; %s marks one"
                  (substitute-command-keys "\\[guix-microvm-list-mark]")))
    (when (y-or-n-p (pcase marked
                      (`((,name ,_ ,directory))
                       (format "Kill %s in %s? "
                               name (abbreviate-file-name directory)))
                      (_ (format "Kill %d microvms? " (length marked)))))
      (guix-microvm-list--kill-all (nreverse marked)))))

(defun guix-microvm-list--vm-at-point ()
  "Return the microvm at point."
  (or (tabulated-list-get-id) (user-error "No microvm at point")))

(defun guix-microvm-list-kill ()
  "Kill the microvm at point."
  (interactive nil guix-microvm-list-mode)
  (guix-microvm-list--kill-all (list (guix-microvm-list--vm-at-point))))

(defun guix-microvm-list-dired ()
  "Open /work of the microvm at point in Dired."
  (interactive nil guix-microvm-list-mode)
  (pcase-let ((`(,_ ,id ,_) (guix-microvm-list--vm-at-point)))
    (dired (guix-microvm-tramp-file id))))

(defvar-keymap guix-microvm-list-mode-map
  "RET" #'guix-microvm-list-dired
  "d" #'guix-microvm-list-mark
  "u" #'guix-microvm-list-unmark
  "x" #'guix-microvm-list-execute
  "D" #'guix-microvm-list-kill)

(define-derived-mode guix-microvm-list-mode tabulated-list-mode "Microvms"
  "Major mode for the list of running microvms.
A microvm killed here asks about its changes in the terminal it runs in.

\\{guix-microvm-list-mode-map}"
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Name"))
  (add-hook 'tabulated-list-revert-hook #'guix-microvm-list--refresh nil t))

;;;###autoload
(defun guix-microvm-list ()
  "List the running microvms."
  (interactive)
  (let ((buffer (get-buffer-create "*Microvms*")))
    (with-current-buffer buffer
      (guix-microvm-list-mode)
      (guix-microvm-list--refresh)
      (tabulated-list-print))
    (pop-to-buffer-same-window buffer)))

(provide 'guix-microvm)

;;; guix-microvm.el ends here
