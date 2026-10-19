;;; guix-microvm.el --- Select changes of a microvm -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright © 2026 Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>

;; Version: 0.2
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, vc
;; URL: https://github.com/fmarl/guix-microvm

;;; Commentary:

;; When a microvm exits, 'guix microvm' asks what to do with its changes to
;; the project.  "[s]elect" opens the list of changes in the editor; it
;; merges those still listed and not commented out.  In Emacs, that list
;; gets `guix-microvm-selection-mode', which shows the diffs and switches
;; changes between merged and skipped.

;;; Code:

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

(defun guix-microvm-selection--diff (files)
  "Return the diff of FILES between project/ and vm/, fontified."
  (unless guix-microvm-trees
    (user-error "The list names no files to compare"))
  (let ((default-directory (file-name-as-directory guix-microvm-trees)))
    (with-temp-buffer
      (dolist (file files)
        (process-file diff-command nil t nil "-u" "-N" "-r"
                      (concat "project/" file) (concat "vm/" file)))
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
      (diff-mode)
      (setq default-directory directory)
      (setq buffer-read-only t)
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

(defun guix-microvm-selection--header-line ()
  "Return the header line: how many changes are merged, and the keys."
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

(provide 'guix-microvm)

;;; guix-microvm.el ends here
