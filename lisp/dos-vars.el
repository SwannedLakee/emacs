;;; dos-vars.el --- MS-Dos specific user options  -*- lexical-binding:t -*-

;; Copyright (C) 1998, 2001-2025 Free Software Foundation, Inc.

;; Maintainer: emacs-devel@gnu.org
;; Keywords: internal
;; Package: emacs

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

(defgroup dos-fns nil
  "MS-DOS specific functions."
  :group 'environment)

(defcustom msdos-shells '("command.com" "4dos.com" "ndos.com")
  "List of shells that use `/c' instead of `-c' and a backslashed command."
  :type '(repeat string))

(defcustom dos-codepage-setup-hook nil
  "List of functions to call after setting up DOS terminal and coding systems.
This is the place, e.g., to set specific entries in
`standard-display-table' as appropriate for your codepage, if
`IT-display-table-setup' doesn't do a perfect job."
  :type '(hook)
  :version "20.3.3")

(provide 'dos-vars)

;;; dos-vars.el ends here
