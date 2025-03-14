;;; ob-table.el --- Support for Calling Babel Functions from Tables -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2025 Free Software Foundation, Inc.

;; Author: Eric Schulte
;; Keywords: literate programming, reproducible research
;; URL: https://orgmode.org

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

;; Should allow calling functions from Org tables using the function
;; `org-sbe' as so...

;; #+begin_src emacs-lisp :results silent
;;   (defun fibbd (n) (if (< n 2) 1 (+ (fibbd (- n 1)) (fibbd (- n 2)))))
;; #+end_src

;; #+name: fibbd
;; #+begin_src emacs-lisp :var n=2 :results silent
;; (fibbd n)
;; #+end_src

;; | original | fibbd  |
;; |----------+--------|
;; |        0 |        |
;; |        1 |        |
;; |        2 |        |
;; |        3 |        |
;; |        4 |        |
;; |        5 |        |
;; |        6 |        |
;; |        7 |        |
;; |        8 |        |
;; |        9 |        |
;; #+TBLFM: $2='(org-sbe "fibbd" (n $1))

;; NOTE: The quotation marks around the function name, 'fibbd' here,
;; are optional.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'ob-core)
(require 'org-macs)

(defun org-babel-table-truncate-at-newline (string)
  "Replace newline character with ellipses.
If STRING ends in a newline character, then remove the newline
character and replace it with ellipses."
  (if (and (stringp string) (string-match "[\n\r]\\(.\\)?" string))
      (concat (substring string 0 (match-beginning 0))
	      (when (match-string 1 string) "..."))
    string))

(defmacro org-sbe (source-block &rest variables)
  "Return the results of calling SOURCE-BLOCK with VARIABLES.

Each element of VARIABLES should be a list of two elements: the
first element is the name of the variable and second element is a
string of its value.

So this `org-sbe' construct

 (org-sbe \"source-block\" (n $2) (m 3))

is the equivalent of the following source code block:

 #+begin_src emacs-lisp :var results=source-block(n=val_at_col_2, m=3) \\
     :results silent
 results
 #+end_src

The quotation marks around the function name, `source-block', are
optional.

By default, string variable names are interpreted as references to
source-code blocks, to force interpretation of a cell's value as a
string, prefix the identifier a \"$\" (e.g., \"$$2\" instead of \"$2\"
or \"$@2$2\" instead of \"@2$2\").  \"$\" will also force interpreting
string value literally: $\"value\" will refer to a string, not a
source block name.

It is also possible to pass header arguments to the code block.  In
this case a table cell should hold the string value of the header
argument which can then be passed before all variables as shown in the
example below.

| 1 | 2 | :file nothing.png | nothing.png |
#+TBLFM: @1$4=\\='(org-sbe test-sbe $3 (x $1) (y $2))"
  (declare (debug (form form)))
  (let* ((header-args (if (stringp (car variables)) (car variables) ""))
	 (variables (if (stringp (car variables)) (cdr variables) variables)))
    (let* (quote
	   (variables
	    (mapcar
	     (lambda (var)
	       ;; ensure that all cells prefixed with $'s are strings
	       (cons (car var)
		     (delq nil (mapcar
			      (lambda (el)
				(if (eq '$ el)
				    (prog1 nil (setq quote t))
				  (prog1
				      (cond
				       (quote (format "%S" el))
				       ((stringp el) (org-no-properties el))
				       (t el))
				    (setq quote nil))))
			      (cdr var)))))
	     variables)))
      (unless (stringp source-block)
	(setq source-block (symbol-name source-block)))
      `(let ((result
              (if ,(and source-block (> (length source-block) 0))
                  (let ((params
                         ',(org-babel-parse-header-arguments
                            (concat
                             ":var results="
                             source-block
                             "[" header-args "]"
                             "("
                             (mapconcat
                              (lambda (var-spec)
                                (if (> (length (cdr var-spec)) 1)
                                    (format "%S='%S"
                                            (car var-spec)
                                            (mapcar #'read (cdr var-spec)))
                                  (format "%S=%s"
                                          (car var-spec) (cadr var-spec))))
                              variables ", ")
                             ")"))))
                    (org-babel-execute-src-block
                     nil (list "emacs-lisp" "results" params)
                     '((:results . "silent"))))
                "")))
         (org-trim (if (stringp result) result (format "%S" result)))))))

(provide 'ob-table)

;;; ob-table.el ends here
