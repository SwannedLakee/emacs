;;; score-mode.el --- mode for editing Gnus score files  -*- lexical-binding: t; -*-

;; Copyright (C) 1996, 2001-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: news, mail

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'mm-util)			; for mm-universal-coding-system
(require 'gnus-util)			; for gnus-pp, gnus-run-mode-hooks

(defcustom gnus-score-edit-done-hook nil
  "Hook run at the end of closing the score buffer."
  :group 'gnus-score
  :type 'hook)

(defcustom gnus-score-mode-hook nil
  "Hook run in score mode buffers."
  :group 'gnus-score
  :type 'hook)

(defcustom gnus-score-menu-hook nil
  "Hook run after creating the score mode menu."
  :group 'gnus-score
  :type 'hook)

(defvar gnus-score-edit-exit-function nil
  "Function run on exit from the score buffer.")

(defvar-keymap gnus-score-mode-map
  :parent emacs-lisp-mode-map
  "C-c C-c" #'gnus-score-edit-exit
  "C-c C-d" #'gnus-score-edit-insert-date
  "C-c C-p" #'gnus-score-pretty-print)

(defvar score-mode-syntax-table
  (let ((table (copy-syntax-table lisp-mode-syntax-table)))
    (modify-syntax-entry ?| "w" table)
    table)
  "Syntax table used in score-mode buffers.")

;; We need this to cope with non-ASCII scoring.
(defvar score-mode-coding-system mm-universal-coding-system)

;;;###autoload
(define-derived-mode gnus-score-mode emacs-lisp-mode "Score"
  "Mode for editing Gnus score files.
This mode is an extended emacs-lisp mode.

\\{gnus-score-mode-map}"
  (gnus-score-make-menu-bar)
  (make-local-variable 'gnus-score-edit-exit-function))

(defun gnus-score-make-menu-bar ()
  (unless (boundp 'gnus-score-menu)
    (easy-menu-define
     gnus-score-menu gnus-score-mode-map ""
     '("Score"
       ["Exit" gnus-score-edit-exit t]
       ["Insert date" gnus-score-edit-insert-date t]
       ["Format" gnus-score-pretty-print t]))
    (run-hooks 'gnus-score-menu-hook)))

(defun gnus-score-edit-insert-date ()
  "Insert date in numerical format."
  (interactive nil gnus-score-mode)
  (princ (time-to-days nil) (current-buffer)))

(defun gnus-score-pretty-print ()
  "Format the current score file."
  (interactive nil gnus-score-mode)
  (goto-char (point-min))
  (let ((form (read (current-buffer))))
    (erase-buffer)
    (let ((emacs-lisp-mode-syntax-table score-mode-syntax-table))
      (gnus-pp form)))
  (goto-char (point-min)))

(defun gnus-score-edit-exit ()
  "Stop editing the score file."
  (interactive nil gnus-score-mode)
  (unless (file-exists-p (file-name-directory (buffer-file-name)))
    (make-directory (file-name-directory (buffer-file-name)) t))
  (let ((coding-system-for-write score-mode-coding-system))
    (save-buffer))
  (bury-buffer (current-buffer))
  (let ((buf (current-buffer)))
    (when gnus-score-edit-exit-function
      (funcall gnus-score-edit-exit-function))
    (when (eq buf (current-buffer))
      (switch-to-buffer (other-buffer (current-buffer))))))

(provide 'score-mode)

;;; score-mode.el ends here
