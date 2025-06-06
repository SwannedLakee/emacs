;;; disp-table.el --- functions for dealing with char tables  -*- lexical-binding: t; -*-

;; Copyright (C) 1987, 1994-1995, 1999, 2001-2025 Free Software
;; Foundation, Inc.

;; Author: Erik Naggum <erik@naggum.no>
;; Based on a previous version by Howard Gayle
;; Maintainer: emacs-devel@gnu.org
;; Keywords: i18n
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

(put 'display-table 'char-table-extra-slots 18)

;;;###autoload
(defun make-display-table ()
  "Return a new, empty display table."
  (make-char-table 'display-table nil))

(or standard-display-table
    (setq standard-display-table (make-display-table)))

;;; Display-table slot names.  The property value says which slot.

(put 'truncation 'display-table-slot 0)
(put 'wrap 'display-table-slot 1)
(put 'escape 'display-table-slot 2)
(put 'control 'display-table-slot 3)
(put 'selective-display 'display-table-slot 4)
(put 'vertical-border 'display-table-slot 5)

(put 'box-vertical 'display-table-slot 6)
(put 'box-horizontal 'display-table-slot 7)
(put 'box-down-right 'display-table-slot 8)
(put 'box-down-left 'display-table-slot 9)
(put 'box-up-right 'display-table-slot 10)
(put 'box-up-left 'display-table-slot 11)

(put 'box-double-vertical 'display-table-slot 12)
(put 'box-double-horizontal 'display-table-slot 13)
(put 'box-double-down-right 'display-table-slot 14)
(put 'box-double-down-left 'display-table-slot 15)
(put 'box-double-up-right 'display-table-slot 16)
(put 'box-double-up-left 'display-table-slot 17)

;;;###autoload
(defun display-table-slot (display-table slot)
  "Return the value of the extra slot in DISPLAY-TABLE named SLOT.
SLOT may be a number from 0 to 17 inclusive, or a slot name (symbol).
Valid symbols are `truncation', `wrap', `escape', `control',
`selective-display', `vertical-border', `box-vertical',
`box-horizontal', `box-down-right', `box-down-left', `box-up-right',
`box-up-left',`box-double-vertical', `box-double-horizontal',
`box-double-down-right', `box-double-down-left',
`box-double-up-right', `box-double-up-left',"
  (let ((slot-number
	 (if (numberp slot) slot
	   (or (get slot 'display-table-slot)
	       (error "Invalid display-table slot name: %s" slot)))))
    (char-table-extra-slot display-table slot-number)))

;;;###autoload
(defun set-display-table-slot (display-table slot value)
  "Set the value of the extra slot in DISPLAY-TABLE named SLOT to VALUE.
SLOT may be a number from 0 to 17 inclusive, or a name (symbol).
Valid symbols are `truncation', `wrap', `escape', `control',
`selective-display', `vertical-border', `box-vertical',
`box-horizontal', `box-down-right', `box-down-left', `box-up-right',
`box-up-left',`box-double-vertical', `box-double-horizontal',
`box-double-down-right', `box-double-down-left',
`box-double-up-right', `box-double-up-left',"
  (let ((slot-number
	 (if (numberp slot) slot
	   (or (get slot 'display-table-slot)
	       (error "Invalid display-table slot name: %s" slot)))))
    (set-char-table-extra-slot display-table slot-number value)))

;;;###autoload
(defun describe-display-table (dt)
  "Describe the display table DT in a help buffer."
  (with-help-window "*Help*"
    (princ "\nTruncation glyph: ")
    (prin1 (display-table-slot dt 'truncation))
    (princ "\nWrap glyph: ")
    (prin1 (display-table-slot dt 'wrap))
    (princ "\nEscape glyph: ")
    (prin1 (display-table-slot dt 'escape))
    (princ "\nCtrl glyph: ")
    (prin1 (display-table-slot dt 'control))
    (princ "\nSelective display glyph sequence: ")
    (prin1 (display-table-slot dt 'selective-display))
    (princ "\nVertical window border glyph: ")
    (prin1 (display-table-slot dt 'vertical-border))

    (princ "\nBox vertical line glyph: ")
    (prin1 (display-table-slot dt 'box-vertical))
    (princ "\nBox horizontal line glyph: ")
    (prin1 (display-table-slot dt 'box-horizontal))
    (princ "\nBox upper left corner glyph: ")
    (prin1 (display-table-slot dt 'box-down-right))
    (princ "\nBox upper right corner glyph: ")
    (prin1 (display-table-slot dt 'box-down-left))
    (princ "\nBox lower left corner glyph: ")
    (prin1 (display-table-slot dt 'box-up-right))
    (princ "\nBox lower right corner glyph: ")
    (prin1 (display-table-slot dt 'box-up-left))

    (princ "\nBox double vertical line glyph: ")
    (prin1 (display-table-slot dt 'box-double-vertical))
    (princ "\nBox double horizontal line glyph: ")
    (prin1 (display-table-slot dt 'box-double-horizontal))
    (princ "\nBox double upper left corner glyph: ")
    (prin1 (display-table-slot dt 'box-double-down-right))
    (princ "\nBox double upper right corner glyph: ")
    (prin1 (display-table-slot dt 'box-double-down-left))
    (princ "\nBox double lower left corner glyph: ")
    (prin1 (display-table-slot dt 'box-double-up-right))
    (princ "\nBox double lower right corner glyph: ")
    (prin1 (display-table-slot dt 'box-double-up-left))

    (princ "\nCharacter display glyph sequences:\n")
    (with-current-buffer standard-output
      (let ((vector (make-vector 256 nil))
	    (i 0))
	(while (< i 256)
	  (aset vector i (aref dt i))
	  (setq i (1+ i)))
	(describe-vector
	 vector 'display-table-print-array))
      (help-mode))))

(defun display-table-print-array (desc)
  (insert "[")
  (let ((column (current-column))
	(width (window-width))
	string)
    (dotimes (i (length desc))
      (setq string (format "%s" (aref desc i)))
      (cond
       ((>= (+ (current-column) (length string) 1)
	    width)
	(insert "\n")
	(insert (make-string column ? )))
       ((> i 0)
	(insert " ")))
      (insert string)))
  (insert "]\n"))

;;;###autoload
(defun describe-current-display-table ()
  "Describe the display table in use in the selected window and buffer."
  (interactive)
  (let ((disptab (or (window-display-table)
		     buffer-display-table
		     standard-display-table)))
    (if disptab
	(describe-display-table disptab)
      (message "No display table"))))

;;;###autoload
(defun standard-display-unicode-special-glyphs ()
  "Display some glyphs using Unicode characters.
The glyphs being changed by this function are `vertical-border',
`box-vertical',`box-horizontal', `box-down-right', `box-down-left',
`box-up-right', `box-up-left',`box-double-vertical',
`box-double-horizontal', `box-double-down-right',
`box-double-down-left', `box-double-up-right', `box-double-up-left',"
  (interactive)
  (set-display-table-slot standard-display-table
			  'vertical-border (make-glyph-code #x2502))

  (set-display-table-slot standard-display-table
			  'box-vertical (make-glyph-code #x2502))
  (set-display-table-slot standard-display-table
			  'box-horizontal (make-glyph-code #x2500))
  (set-display-table-slot standard-display-table
			  'box-down-right (make-glyph-code #x250c))
  (set-display-table-slot standard-display-table
			  'box-down-left (make-glyph-code #x2510))
  (set-display-table-slot standard-display-table
			  'box-up-right (make-glyph-code #x2514))
  (set-display-table-slot standard-display-table
			  'box-up-left (make-glyph-code #x2518))

  (set-display-table-slot standard-display-table
			  'box-double-vertical (make-glyph-code #x2551))
  (set-display-table-slot standard-display-table
			  'box-double-horizontal (make-glyph-code #x2550))
  (set-display-table-slot standard-display-table
			  'box-double-down-right (make-glyph-code #x2554))
  (set-display-table-slot standard-display-table
			  'box-double-down-left (make-glyph-code #x2557))
  (set-display-table-slot standard-display-table
			  'box-double-up-right (make-glyph-code #x255a))
  (set-display-table-slot standard-display-table
			  'box-double-up-left (make-glyph-code #x255d)))

;;;###autoload
(defun standard-display-8bit (l h)
  "Display characters representing raw bytes in the range L to H literally.

On a terminal display, each character in the range is displayed
by sending the corresponding byte directly to the terminal.

On a graphic display, each character in the range is displayed
using the default font by a glyph whose code is the corresponding
byte.

Note that ASCII printable characters (SPC to TILDA) are displayed
in the default way after this call."
  (or standard-display-table
      (setq standard-display-table (make-display-table)))
  (if (> h 255)
      (setq h 255))
  (while (<= l h)
    (if (< l 128)
	(aset standard-display-table l
	      (if (or (< l ?\s) (= l 127)) (vector l)))
      (let ((c (unibyte-char-to-multibyte l)))
	(aset standard-display-table c (vector c))))
    (setq l (1+ l))))

;;;###autoload
(defun standard-display-default (l h)
  "Display characters in the range L to H using the default notation."
  (or standard-display-table
      (setq standard-display-table (make-display-table)))
  (while (<= l h)
    (if (and (>= l ?\s) (characterp l))
	(aset standard-display-table l nil))
    (setq l (1+ l))))

;; This function does NOT take terminal-dependent escape sequences.
;; For that, you need to go through create-glyph.  Use one of the
;; other functions below, or roll your own.
;;;###autoload
(defun standard-display-ascii (c s)
  "Display character C using printable string S."
  (or standard-display-table
      (setq standard-display-table (make-display-table)))
  (aset standard-display-table c (vconcat s)))

;;;###autoload
(defun standard-display-g1 (c sc)
  "Display character C as character SC in the g1 character set.
This function assumes that your terminal uses the SO/SI characters;
it is meaningless for a graphical frame."
  (if (display-graphic-p)
      (error "Cannot use string glyphs in a windowing system"))
  (or standard-display-table
      (setq standard-display-table (make-display-table)))
  (aset standard-display-table c
	(vector (create-glyph (concat "\016" (char-to-string sc) "\017")))))

;;;###autoload
(defun standard-display-graphic (c gc)
  "Display character C as character GC in graphics character set.
This function assumes VT100-compatible escapes; it is meaningless
for a graphical frame."
  (if (display-graphic-p)
      (error "Cannot use string glyphs in a windowing system"))
  (or standard-display-table
      (setq standard-display-table (make-display-table)))
  (aset standard-display-table c
	(vector (create-glyph (concat "\e(0" (char-to-string gc) "\e(B")))))

;;;###autoload
(defun standard-display-underline (c uc)
  "Display character C as character UC plus underlining."
  (or standard-display-table
      (setq standard-display-table (make-display-table)))
  (aset standard-display-table c
	(vector
	 (if window-system
	     (make-glyph-code uc 'underline)
	   (create-glyph (concat "\e[4m" (char-to-string uc) "\e[m"))))))

;;;###autoload
(defun create-glyph (string)
  "Allocate a glyph code to display by sending STRING to the terminal."
  (if (= (length glyph-table) 65536)
      (error "No free glyph codes remain"))
  ;; Don't use slots that correspond to ASCII characters.
  (if (= (length glyph-table) 32)
      (setq glyph-table (vconcat glyph-table (make-vector 224 nil))))
  (setq glyph-table (vconcat glyph-table (list string)))
  (1- (length glyph-table)))

;;;###autoload
(defun make-glyph-code (char &optional face)
  "Return a glyph code representing char CHAR with face FACE."
  (if (not face)
      char
    (let ((fid (face-id face)))
      (if (< fid 64) ; we have 32 - 3(LSB) - 1(SIGN) - 22(CHAR) = 6 bits for face id
	  (logior char (ash fid 22))
	(cons char fid)))))

;;;###autoload
(defun glyph-char (glyph)
  "Return the character of glyph code GLYPH."
  (if (consp glyph)
      (car glyph)
    (logand glyph #x3fffff)))

;;;###autoload
(defun glyph-face (glyph)
  "Return the face of glyph code GLYPH, or nil if glyph has default face."
  (let ((face-id (if (consp glyph) (cdr glyph) (ash glyph -22))))
    (and (> face-id 0)
	 (catch 'face
	   (dolist (face (face-list))
	     (when (eq (face-id face) face-id)
	       (throw 'face face)))))))

;;;###autoload
(defun standard-display-european (arg)
  "Semi-obsolete way to toggle display of ISO 8859 European characters.

This function is semi-obsolete; you probably don't need it, or else you
probably should use `set-language-environment' or `set-locale-environment'.

This function enables European character display if ARG is positive,
disables it if negative.  Otherwise, it toggles European character display.

When this mode is enabled, characters in the range of 160 to 255
display not as octal escapes, but as accented characters.  Codes 146
and 160 display as apostrophe and space, even though they are not the
ASCII codes for apostrophe and space.

Enabling European character display with this command noninteractively
from Lisp code also selects Latin-1 as the language environment.
This provides increased compatibility for users who call this function
in `.emacs'."

  (if (or (<= (prefix-numeric-value arg) 0)
	  (and (null arg)
	       (char-table-p standard-display-table)
	       ;; Test 161, because 160 displays as a space.
	       (equal (aref standard-display-table
			    (unibyte-char-to-multibyte 161))
		      (vector (unibyte-char-to-multibyte 161)))))
      (progn
	(standard-display-default
	 (unibyte-char-to-multibyte 160) (unibyte-char-to-multibyte 255))
	(unless (display-graphic-p)
	  (and (terminal-coding-system)
	       (set-terminal-coding-system nil))))

    (display-warning 'i18n
		     (format-message
		      "`standard-display-european' is semi-obsolete; see its doc string for details")
		     :warning)

    ;; Switch to Latin-1 language environment
    ;; unless some other has been specified.
    (if (equal current-language-environment "English")
	(set-language-environment "latin-1"))
    (unless (or noninteractive (display-graphic-p))
      ;; Send those codes literally to a character-based terminal.
      ;; If we are using single-byte characters,
      ;; it doesn't matter which coding system we use.
      (set-terminal-coding-system
       (let ((c (intern (downcase current-language-environment))))
	 (if (coding-system-p c) c 'latin-1))))
    (standard-display-european-internal)))


;;;###autoload
(defun standard-display-by-replacement-char (&optional repl from to)
  "Produce code to display characters between FROM and TO using REPL.
This function produces a buffer with code to set up `standard-display-table'
such that characters that cannot be displayed by the terminal, and
don't already have their display set up in `standard-display-table', will
be represented by a replacement character.  You can evaluate the produced
code to use the setup for the current Emacs session, or copy the code
into your init file, to make Emacs use it for subsequent sessions.

Interactively, the produced code arranges for any character in
the range [#x100..#x10FFFF] that the terminal cannot display to
be represented by the #xFFFD Unicode replacement character.

When called from Lisp, FROM and TO define the range of characters for
which to produce the setup code for `standard-display-table'.  If they
are omitted, they default to #x100 and #x10FFFF respectively, covering
the entire non-ASCII range of Unicode characters.
REPL is the replacement character to use.  If it's omitted, it defaults
to #xFFFD, the Unicode replacement character, usually displayed as a
black diamond with a question mark inside.
The produced code sets up `standard-display-table' to show REPL with
the `homoglyph' face, making the replacements stand out on display.

This command is most useful with text-mode terminals, such as the
Linux console, for which Emacs has a reliable way of determining
which characters can be displayed and which cannot."
  (interactive)
  (or repl
      (setq repl #xfffd))
  (or (and from to (<= from to))
      (setq from #x100
	    to (max-char 'unicode)))
  (let ((buf (get-buffer-create "*Display replacements*"))
	(ch from)
        (tbl standard-display-table)
	first)
    (with-current-buffer buf
      (erase-buffer)
      (insert "\
;; This code was produced by `standard-display-by-replacement-char'.
;; Evaluate the Lisp code below to make Emacs show the standard
;; replacement character as a substitute for each undisplayable character.
;; One way to do that is with \"C-x h M-x eval-region RET\".
;; Normally you would put this code in your Emacs initialization file,
;; perhaps conditionally based on the type of terminal, so that
;; this setup happens automatically on each startup.
(let ((tbl (or standard-display-table
               (setq standard-display-table (make-display-table)))))\n")
      (while (<= ch to)
	(cond
	 ((or (char-displayable-p ch)
	      (aref tbl ch))
	  (setq ch (1+ ch)))
	 (t
	  (setq first ch)
	  (while (and (<= ch to)
		      (not (or (char-displayable-p ch)
			       (aref tbl ch))))
	    (setq ch (1+ ch)))
	  (insert
	   "  (set-char-table-range tbl '("
	   (format "#x%x" first)
	   " . "
	   (format "#x%x" (1- ch))
	   ")\n\                        (vconcat (list (make-glyph-code "
	   (format "#x%x" repl) " 'homoglyph))))\n"))))
      (insert ")\n"))
    (pop-to-buffer buf)))


(provide 'disp-table)

;;; disp-table.el ends here
