;;; gnus-util.el --- utility functions for Gnus  -*- lexical-binding: t; -*-

;; Copyright (C) 1996-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: news

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

;; Nothing in this file depends on any other parts of Gnus -- all
;; functions and macros in this file are utility functions that are
;; used by Gnus and may be used by any other package without loading
;; Gnus first.

;; [Unfortunately, it does depend on other parts of Gnus, e.g. the
;; autoloads and defvars below...]

;;; Code:

(eval-when-compile (require 'cl-lib))

(require 'seq)
(require 'time-date)
(require 'text-property-search)

(defcustom gnus-completing-read-function 'gnus-emacs-completing-read
  "Function use to do completing read."
  :version "29.1"
  :group 'gnus-meta
  :type '(radio (function-item
                 :doc "Use Emacs standard `completing-read' function."
                 gnus-emacs-completing-read)
		(function-item
		 :doc "Use `ido-completing-read' function."
                 gnus-ido-completing-read)))

(defcustom gnus-completion-styles
  (append (when (and (assq 'substring completion-styles-alist)
		     (not (memq 'substring completion-styles)))
	    (list 'substring))
	  completion-styles)
  "Value of `completion-styles' to use when completing."
  :version "24.1"
  :group 'gnus-meta
  :type '(repeat symbol))

;; Fixme: this should be a gnus variable, not nnmail-.
(defvar nnmail-pathname-coding-system)
(defvar nnmail-active-file-coding-system)

;; Inappropriate references to other parts of Gnus.
(defvar gnus-emphasize-whitespace-regexp)
(defvar gnus-original-article-buffer)
(defvar gnus-user-agent)

(autoload 'gnus-get-buffer-window "gnus-win")
(autoload 'nnheader-narrow-to-headers "nnheader")
(autoload 'nnheader-replace-chars-in-string "nnheader")
(autoload 'mail-header-remove-comments "mail-parse")

(defun gnus-replace-in-string  (string regexp newtext &optional literal)
  "Replace all matches for REGEXP with NEWTEXT in STRING.
If LITERAL is non-nil, insert NEWTEXT literally.  Return a new
string containing the replacements.

This is a compatibility function for different Emacsen."
  (declare (obsolete replace-regexp-in-string "26.1"))
  (replace-regexp-in-string regexp newtext string nil literal))

(defmacro gnus-eval-in-buffer-window (buffer &rest forms)
  "Pop to BUFFER, evaluate FORMS, and then return to the original window."
  (declare (indent 1) (debug t))
  (let ((tempvar (make-symbol "GnusStartBufferWindow"))
	(w (make-symbol "w"))
	(buf (make-symbol "buf")))
    `(let* ((,tempvar (selected-window))
	    (,buf ,buffer)
	    (,w (gnus-get-buffer-window ,buf 'visible)))
       (unwind-protect
	   (progn
	     (if ,w
		 (progn
		   (select-window ,w)
		   (set-buffer (window-buffer ,w)))
	       (pop-to-buffer ,buf))
	     ,@forms)
	 (select-window ,tempvar)))))

(defsubst gnus-goto-char (point)
  (and point (goto-char point)))

(defun gnus-delete-first (elt list)
  "Delete by side effect the first occurrence of ELT as a member of LIST."
  (if (equal (car list) elt)
      (cdr list)
    (let ((total list))
      (while (and (cdr list)
		  (not (equal (cadr list) elt)))
	(setq list (cdr list)))
      (when (cdr list)
	(setcdr list (cddr list)))
      total)))

;; Delete the current line (and the next N lines).
(defmacro gnus-delete-line (&optional n)
  `(delete-region (line-beginning-position)
		  (progn (forward-line ,(or n 1)) (point))))

(defun gnus-extract-address-components (from)
  "Extract address components from a From header.
Given an RFC-822 (or later) address FROM, extract name and address.
Returns a list of the form (FULL-NAME CANONICAL-ADDRESS).  Much more simple
solution than `mail-header-parse-address', which works much better, but
is slower."
  (let (name address)
    ;; First find the address - the thing with the @ in it.  This may
    ;; not be accurate in mail addresses, but does the trick most of
    ;; the time in news messages.
    (cond (;; Check ``<foo@bar>'' first in order to handle the quite common
	   ;; form ``"abc@xyz" <foo@bar>'' (i.e. ``@'' as part of a comment)
	   ;; correctly.
	   (string-match "<\\([^@ \t<>]+[!@][^@ \t<>]+\\)>" from)
	   (setq address (substring from (match-beginning 1) (match-end 1))))
	  ((string-match "\\b[^@ \t<>]+[!@][^@ \t<>]+\\b" from)
	   (setq address (substring from (match-beginning 0) (match-end 0)))))
    ;; Then we check whether the "name <address>" format is used.
    (and address
	 ;; Linear white space is not required.
	 (string-match (concat "[ \t]*<" (regexp-quote address) ">") from)
	 (and (setq name (substring from 0 (match-beginning 0)))
	      ;; Strip any quotes from the name.
	      (string-match "^\".*\"$" name)
	      (setq name (substring name 1 (1- (match-end 0))))))
    ;; If not, then "address (name)" is used.
    (or name
	(and (string-match "(.+)" from)
	     (setq name (substring from (1+ (match-beginning 0))
				   (1- (match-end 0)))))
	(and (string-search "()" from)
	     (setq name address))
	;; XOVER might not support folded From headers.
	(and (string-match "(.*" from)
	     (setq name (substring from (1+ (match-beginning 0))
				   (match-end 0)))))
    (list (if (string= name "") nil name) (or address from))))

(declare-function message-fetch-field "message" (header &optional not-all))

(defun gnus-fetch-field (field)
  "Return the value of the header FIELD of current article."
  (require 'message)
  (save-excursion
    (save-restriction
      (nnheader-narrow-to-headers)
      (message-fetch-field field))))

(defun gnus-fetch-original-field (field)
  "Fetch FIELD from the original version of the current article."
  (with-current-buffer gnus-original-article-buffer
    (gnus-fetch-field field)))


(defun gnus-goto-colon ()
  (move-beginning-of-line 1)
  (let ((eol (line-end-position)))
    (goto-char (or (text-property-any (point) eol 'gnus-position t)
		   (search-forward ":" eol t)
		   (point)))))

(defun gnus-text-property-search (prop value &optional forward-only goto end)
  "Search current buffer for text property PROP with VALUE.
Behaves like a combination of `text-property-any' and
`text-property-search-forward'.  Searches for the beginning of a
text property `equal' to VALUE.  Returns the value of point at
the beginning of the matching text property span.

If FORWARD-ONLY is non-nil, only search forward from point.

If GOTO is non-nil, move point to the beginning of that span
instead.

If END is non-nil, use the end of the span instead."
  (let* ((start (point))
	 (found (progn
		  (unless forward-only
		    (goto-char (point-min)))
		  (text-property-search-forward
		   prop value #'equal)))
	 (target (when found
		   (if end
		       (prop-match-end found)
		     (prop-match-beginning found)))))
    (when target
      (if goto
	  (goto-char target)
	(prog1
	    target
	  (goto-char start))))))

(declare-function gnus-find-method-for-group "gnus" (group &optional info))
(declare-function gnus-group-name-decode "gnus-group" (string charset))
(declare-function gnus-group-name-charset "gnus-group" (method group))
;; gnus-group requires gnus-int which requires message.
(declare-function message-tokenize-header "message"
                  (header &optional separator))

(defun gnus-decode-newsgroups (newsgroups group &optional method)
  (require 'gnus-group)
  (let ((method (or method (gnus-find-method-for-group group))))
    (mapconcat (lambda (group)
		 (gnus-group-name-decode group (gnus-group-name-charset
						method group)))
	       (message-tokenize-header newsgroups)
	       ",")))

(defun gnus-remove-text-with-property (prop)
  "Delete all text in the current buffer with text property PROP."
  (let ((start (point-min))
	end)
    (unless (get-text-property start prop)
      (setq start (next-single-property-change start prop)))
    (while start
      (setq end (text-property-any start (point-max) prop nil))
      (delete-region start (or end (point-max)))
      (setq start (when end
		    (next-single-property-change start prop))))))

(defun gnus-find-text-property-region (start end prop)
  "Return a list of text property regions that has property PROP."
  (let (regions value)
    (unless (get-text-property start prop)
      (setq start (next-single-property-change start prop)))
    (while start
      (setq value (get-text-property start prop)
	    end (text-property-not-all start (point-max) prop value))
      (if (not end)
	  (setq start nil)
	(when value
	  (push (list (set-marker (make-marker) start)
		      (set-marker (make-marker) end)
		      value)
		regions))
	(setq start (next-single-property-change start prop))))
    (nreverse regions)))

(defun gnus-newsgroup-directory-form (newsgroup)
  "Make hierarchical directory name from NEWSGROUP name."
  (let* ((newsgroup (gnus-newsgroup-savable-name newsgroup))
	 (idx (string-search ":" newsgroup)))
    (concat
     (if idx (substring newsgroup 0 idx))
     (if idx "/")
     (nnheader-replace-chars-in-string
      (if idx (substring newsgroup (1+ idx)) newsgroup)
      ?. ?/))))

(defun gnus-newsgroup-savable-name (group)
  ;; Replace any slashes in a group name (eg. an ange-ftp nndoc group)
  ;; with dots.
  (nnheader-replace-chars-in-string group ?/ ?.))

(defun gnus-string> (s1 s2)
  (not (or (string< s1 s2)
	   (string= s1 s2))))

(defun gnus-string< (s1 s2)
  "Return t if first arg string is less than second in lexicographic order.
Case is significant if and only if `case-fold-search' is nil.
Symbols are also allowed; their print names are used instead."
  (if case-fold-search
      (string-lessp (downcase (if (symbolp s1) (symbol-name s1) s1))
		    (downcase (if (symbolp s2) (symbol-name s2) s2)))
    (string-lessp s1 s2)))

;;; Time functions.

(defun gnus-file-newer-than (file date)
  (time-less-p date (file-attribute-modification-time (file-attributes file))))

;;; Keymap macros.

(defmacro gnus-local-set-keys (&rest plist)
  "Set the keys in PLIST in the current keymap."
  (declare (obsolete define-keymap "29.1") (indent 1))
  `(gnus-define-keys-1 (current-local-map) ',plist))

(defmacro gnus-define-keys (keymap &rest plist)
  "Define all keys in PLIST in KEYMAP."
  (declare (obsolete define-keymap "29.1") (indent 1))
  `(gnus-define-keys-1 ,(if (symbolp keymap) keymap `',keymap) (quote ,plist)))

(defmacro gnus-define-keys-safe (keymap &rest plist)
  "Define all keys in PLIST in KEYMAP without overwriting previous definitions."
  (declare (obsolete define-keymap "29.1") (indent 1))
  `(gnus-define-keys-1 (quote ,keymap) (quote ,plist) t))

(defmacro gnus-define-keymap (keymap &rest plist)
  "Define all keys in PLIST in KEYMAP."
  (declare (obsolete define-keymap "29.1") (indent 1))
  `(gnus-define-keys-1 ,keymap (quote ,plist)))

(defun gnus-define-keys-1 (keymap plist &optional safe)
  (declare (obsolete define-keymap "29.1"))
  (when (null keymap)
    (error "Can't set keys in a null keymap"))
  (cond ((symbolp keymap) (error "First arg should be a keymap object"))
	((keymapp keymap))
	((listp keymap)
	 (set (car keymap) nil)
	 (define-prefix-command (car keymap))
	 (define-key (symbol-value (caddr keymap)) (cadr keymap) (car keymap))
	 (setq keymap (symbol-value (car keymap)))))
  (let (key)
    (while plist
      (when (symbolp (setq key (pop plist)))
	(setq key (symbol-value key)))
      (if (or (not safe)
	      (eq (lookup-key keymap key) 'undefined))
	  (define-key keymap key (pop plist))
	(pop plist)))))

(defun gnus-y-or-n-p (prompt)
  (prog1
      (y-or-n-p prompt)
    (message "")))
(defun gnus-yes-or-no-p (prompt)
  (prog1
      (yes-or-no-p prompt)
    (message "")))

;; By Frank Schmitt <ich@Frank-Schmitt.net>.  Enables age-dependent
;; date representations.  (e.g. just the time if it's from today, the
;; day of the week if it's within the last 7 days and the full date if
;; it's older)

(defun gnus-seconds-today ()
  "Return the integer number of seconds passed today."
  (let ((now (decode-time nil nil 'integer)))
    (+ (decoded-time-second now)
       (* (decoded-time-minute now) 60)
       (* (decoded-time-hour now) 3600))))

(defun gnus-seconds-month ()
  "Return the integer number of seconds passed this month."
  (let ((now (decode-time nil nil 'integer)))
    (+ (decoded-time-second now)
       (* (decoded-time-minute now) 60)
       (* (decoded-time-hour now) 3600)
       (* (- (decoded-time-day now) 1) 3600 24))))

(defun gnus-seconds-year ()
  "Return the integer number of seconds passed this year."
  (let* ((current (current-time))
	 (now (decode-time current nil 'integer))
	 (days (format-time-string "%j" current)))
    (+ (decoded-time-second now)
       (* (decoded-time-minute now) 60)
       (* (decoded-time-hour now) 3600)
       (* (- (string-to-number days) 1) 3600 24))))

(defmacro gnus-date-get-time (date)
  "Convert DATE string to Emacs time.
Cache the result as a text property stored in DATE."
  ;; Either return the cached value...
  `(let ((d ,date))
     (if (equal "" d)
	 0
       (or (get-text-property 0 'gnus-time d)
	   ;; or compute the value...
	   (let ((time (safe-date-to-time d)))
	     ;; and store it back in the string.
	     (put-text-property 0 1 'gnus-time time d)
	     time)))))

(defun gnus-dd-mmm (messy-date)
  "Return a string like DD-MMM from a big messy string."
  (condition-case ()
      (format-time-string "%d-%b" (gnus-date-get-time messy-date))
    (error "  -   ")))

(defsubst gnus-time-iso8601 (time)
  "Return a string of TIME in YYYYMMDDTHHMMSS format."
  (format-time-string "%Y%m%dT%H%M%S" time))

(defun gnus-date-iso8601 (date)
  "Convert the DATE to YYYYMMDDTHHMMSS."
  (condition-case ()
      (gnus-time-iso8601 (gnus-date-get-time date))
    (error "")))

(defun gnus-mode-string-quote (string)
  "Quote all \"%\"'s in STRING."
  (string-replace "%" "%%" string))

(defsubst gnus-make-hashtable (&optional size)
  "Make a hash table of SIZE, testing on `equal'."
  (make-hash-table :size (or size 300) :test #'equal))

(defcustom gnus-verbose 6
  "Integer that says how verbose Gnus should be.
The higher the number, the more messages Gnus will flash to say what
it's doing.  At zero, Gnus will be totally mute; at five, Gnus will
display most important messages; and at ten, Gnus will keep on
jabbering all the time."
  :version "24.1"
  :group 'gnus-start
  :type 'integer)

(defcustom gnus-add-timestamp-to-message nil
  "Non-nil means add timestamps to messages that Gnus issues.
If it is `log', add timestamps to only the messages that go into
the \"*Messages*\" buffer.  If it is neither nil nor `log', add
timestamps not only to log messages but also to the ones
displayed in the echo area."
  :version "23.1" ;; No Gnus
  :group  'gnus-various
  :type '(choice :format "%{%t%}:\n %[Value Menu%] %v"
		 (const :tag "Logged messages only" log)
		 (sexp :tag "All messages"
		       :match (lambda (widget value) value)
		       :value t)
		 (const :tag "No timestamp" nil)))

(eval-when-compile
  (defmacro gnus-message-with-timestamp-1 (format-string args)
    (let ((timestamp '(format-time-string "%Y%m%dT%H%M%S.%3N> " time)))
      `(let (str time)
	 (cond ((eq gnus-add-timestamp-to-message 'log)
		(setq str (let (message-log-max)
			    (apply #'message ,format-string ,args)))
		(when (and message-log-max
			   (> message-log-max 0)
			   (/= (length str) 0))
		  (setq time (current-time))
		  (with-current-buffer (messages-buffer)
		    (goto-char (point-max))
		    (let ((inhibit-read-only t))
		      (insert ,timestamp str "\n")
		      (forward-line (- message-log-max))
		      (delete-region (point-min) (point)))
		    (goto-char (point-max))))
		str)
	       (gnus-add-timestamp-to-message
		(if (or (and (null ,format-string) (null ,args))
			(progn
			  (setq str (apply #'format-message ,format-string
					   ,args))
			  (zerop (length str))))
		    (prog1
			(and ,format-string str)
		      (message nil))
		  (setq time (current-time))
		  (message "%s" (concat ,timestamp str))
		  str))
	       (t
		(apply #'message ,format-string ,args)))))))

(defvar gnus-action-message-log nil)

(defun gnus-message-with-timestamp (format-string &rest args)
  "Display message with timestamp.  Arguments are the same as `message'.
The `gnus-add-timestamp-to-message' variable controls how to add
timestamp to message."
  (gnus-message-with-timestamp-1 format-string args))

(defun gnus-message (level &rest args)
  "If LEVEL is lower than `gnus-verbose' print ARGS using `message'.

Guideline for numbers:
1 - error messages, 3 - non-serious error messages, 5 - messages for things
that take a long time, 7 - not very important messages on stuff, 9 - messages
inside loops."
  (if (<= level gnus-verbose)
      (let ((message
	     (if gnus-add-timestamp-to-message
		 (apply #'gnus-message-with-timestamp args)
	       (apply #'message args))))
	(when (and (consp gnus-action-message-log)
		   (<= level 3))
	  (push message gnus-action-message-log))
	message)
    ;; We have to do this format thingy here even if the result isn't
    ;; shown - the return value has to be the same as the return value
    ;; from `message'.
    (apply #'format-message args)))

(defun gnus-final-warning ()
  (when (and (consp gnus-action-message-log)
	     (setq gnus-action-message-log
		   (delete nil gnus-action-message-log)))
    (message "Warning: %s"
	     (mapconcat #'identity gnus-action-message-log "; "))))

(defun gnus-error (level &rest args)
  "Beep an error if LEVEL is equal to or less than `gnus-verbose'.
ARGS are passed to `message'."
  (when (<= (floor level) gnus-verbose)
    (apply #'message args)
    (ding)
    (let (duration)
      (when (and (floatp level)
		 (not (zerop (setq duration (* 10 (- level (floor level)))))))
	(sit-for duration))))
  nil)

(defun gnus-split-references (references)
  "Return a list of Message-IDs in REFERENCES."
  (let ((beg 0)
	(references (mail-header-remove-comments (or references "")))
	ids)
    (while (string-match "<[^<]+[^< \t]" references beg)
      (push (substring references (match-beginning 0) (setq beg (match-end 0)))
	    ids))
    (nreverse ids)))

(defun gnus-extract-references (references)
  "Return a list of Message-IDs in REFERENCES (in In-Reply-To
format), trimmed to only contain the Message-IDs."
  (let ((ids (gnus-split-references references))
	refs)
    (dolist (id ids)
      (when (string-match "<[^<>]+>" id)
	(push (match-string 0 id) refs)))
    refs))

(defsubst gnus-parent-id (references &optional n)
  "Return the last Message-ID in REFERENCES.
If N, return the Nth ancestor instead."
  (when (and references
	     (not (zerop (length references))))
    (if n
	(let ((ids (inline (gnus-split-references references))))
	  (while (nthcdr n ids)
	    (setq ids (cdr ids)))
	  (car ids))
      (let ((references (mail-header-remove-comments references)))
	(when (string-match "\\(<[^<]+>\\)[ \t]*\\'" references)
	  (match-string 1 references))))))

(defsubst gnus-buffer-live-p (buffer)
  "If BUFFER names a live buffer, return its object; else nil."
  (and buffer (buffer-live-p (setq buffer (get-buffer buffer)))
       buffer))

(define-obsolete-function-alias 'gnus-buffer-exists-p
  #'gnus-buffer-live-p "27.1")

(defun gnus-horizontal-recenter ()
  "Recenter the current buffer horizontally."
  (if (< (current-column) (/ (window-width) 2))
      (set-window-hscroll (gnus-get-buffer-window (current-buffer) t) 0)
    (let* ((orig (point))
	   (end (window-end (gnus-get-buffer-window (current-buffer) t)))
	   (max 0))
      (when end
	;; Find the longest line currently displayed in the window.
	(goto-char (window-start))
	(while (and (not (eobp))
		    (< (point) end))
	  (end-of-line)
	  (setq max (max max (current-column)))
	  (forward-line 1))
	(goto-char orig)
	;; Scroll horizontally to center (sort of) the point.
	(if (> max (window-width))
	    (set-window-hscroll
	     (gnus-get-buffer-window (current-buffer) t)
	     (min (- (current-column) (/ (window-width) 3))
		  (+ 2 (- max (window-width)))))
	  (set-window-hscroll (gnus-get-buffer-window (current-buffer) t) 0))
	max))))

(defun gnus-read-event-char (&optional prompt)
  "Get the next event."
  (let ((event (read-event prompt)))
    (cons (and (numberp event) event) event)))

(defun gnus-copy-file (file &optional to)
  "Copy FILE to TO."
  (interactive
   (list (read-file-name "Copy file: " default-directory)
	 (read-file-name "Copy file to: " default-directory)))
  (unless to
    (setq to (read-file-name "Copy file to: " default-directory)))
  (copy-file file to))

(defvar gnus-work-buffer " *gnus work*")

(declare-function gnus-get-buffer-create "gnus" (name))
;; gnus.el requires mm-util.
(declare-function mm-enable-multibyte "mm-util")

(defun gnus-set-work-buffer ()
  "Put point in the empty Gnus work buffer."
  (if (get-buffer gnus-work-buffer)
      (progn
	(set-buffer gnus-work-buffer)
	(erase-buffer))
    (set-buffer (gnus-get-buffer-create gnus-work-buffer))
    (kill-all-local-variables)
    (mm-enable-multibyte)))

(defmacro gnus-group-real-name (group)
  "Find the real name of a foreign newsgroup."
  `(let ((gname ,group))
     (if (string-match "^[^:]+:" gname)
	 (substring gname (match-end 0))
       gname)))

(defmacro gnus-group-server (group)
  "Find the server name of a foreign newsgroup.
For example, (gnus-group-server \"nnimap+yxa:INBOX.foo\") would
yield \"nnimap:yxa\"."
  `(let ((gname ,group))
     (if (string-match "^\\([^:+]+\\)\\(?:\\+\\([^:]*\\)\\)?:" gname)
	 (format "%s:%s" (match-string 1 gname) (or
						 (match-string 2 gname)
						 ""))
       (format "%s:%s" (car gnus-select-method) (cadr gnus-select-method)))))

(defun gnus-make-sort-function (funs)
  "Return a composite sort condition based on the functions in FUNS."
  (cond
   ;; Just a simple function.
   ((functionp funs) funs)
   ;; No functions at all.
   ((null funs) funs)
   ;; A list of functions.
   ((or (cdr funs)
	(listp (car funs)))
    (gnus-byte-compile
     `(lambda (t1 t2)
	,(gnus-make-sort-function-1 (reverse funs)))))
   ;; A list containing just one function.
   (t
    (car funs))))

(defun gnus-make-sort-function-1 (funs)
  "Return a composite sort condition based on the functions in FUNS."
  (let ((function (car funs))
	(first 't1)
	(last 't2))
    (when (consp function)
      (cond
       ;; Reversed spec.
       ((eq (car function) 'not)
	(setq function (cadr function)
	      first 't2
	      last 't1))
       ((functionp function)
	;; Do nothing.
	)
       (t
	(error "Invalid sort spec: %s" function))))
    (if (cdr funs)
	`(or (,function ,first ,last)
	     (and (not (,function ,last ,first))
		  ,(gnus-make-sort-function-1 (cdr funs))))
      `(,function ,first ,last))))

(defun gnus-turn-off-edit-menu (type)
  "Turn off edit menu in `gnus-TYPE-mode-map'."
  (define-key (symbol-value (intern (format "gnus-%s-mode-map" type)))
    [menu-bar edit] #'undefined))

(defvar print-string-length)

(defmacro gnus-bind-print-variables (&rest forms)
  "Bind print-* variables and evaluate FORMS.
This macro is used with `prin1', `pp', etc. in order to ensure
printed Lisp objects are loadable.  Bind `print-quoted' to t, and
`print-escape-multibyte', `print-escape-newlines',
`print-escape-nonascii', `print-length', `print-level' and
`print-string-length' to nil."
  `(let ((print-quoted t)
	 ;;print-circle
	 ;;print-continuous-numbering
	 print-escape-multibyte
	 print-escape-newlines
	 print-escape-nonascii
	 ;;print-gensym
	 print-length
	 print-level
	 print-string-length)
     ,@forms))

(defun gnus-prin1 (form)
  "Use `prin1' on FORM in the current buffer.
Bind `print-quoted' to t, and `print-length' and `print-level' to
nil.  See also `gnus-bind-print-variables'."
  (gnus-bind-print-variables (prin1 form (current-buffer))))

(defun gnus-prin1-to-string (form)
  "The same as `prin1'.
Bind `print-quoted' to t, and `print-length' and `print-level' to
nil.  See also `gnus-bind-print-variables'."
  (gnus-bind-print-variables (prin1-to-string form)))

(defun gnus-pp (form &optional stream)
  "Use `pp' on FORM in the current buffer.
Bind `print-quoted' to t, and `print-length' and `print-level' to
nil.  See also `gnus-bind-print-variables'."
  (gnus-bind-print-variables (pp form (or stream (current-buffer)))))

(defun gnus-pp-to-string (form)
  "The same as `pp-to-string'.
Bind `print-quoted' to t, and `print-length' and `print-level' to
nil.  See also `gnus-bind-print-variables'."
  (gnus-bind-print-variables (pp-to-string form)))

(defun gnus-make-directory (directory)
  "Make DIRECTORY (and all its parents) if it doesn't exist."
  (require 'nnmail)
  (let ((file-name-coding-system nnmail-pathname-coding-system))
    (when (and directory
	       (not (file-exists-p directory)))
      (make-directory directory t)))
  t)

(defun gnus-write-buffer (file)
  "Write the current buffer's contents to FILE."
  (require 'nnmail)
  (let ((file-name-coding-system nnmail-pathname-coding-system))
    ;; Make sure the directory exists.
    (gnus-make-directory (file-name-directory file))
    ;; Write the buffer.
    (write-region (point-min) (point-max) file nil 'quietly)))

(defun gnus-delete-file (file)
  "Delete FILE if it exists."
  (when (file-exists-p file)
    (delete-file file)))

(defun gnus-delete-directory (directory)
  "Delete files in DIRECTORY.  Subdirectories remain.
If there's no subdirectory, delete DIRECTORY as well."
  (when (file-directory-p directory)
    (let ((files (directory-files
		  directory t directory-files-no-dot-files-regexp))
	  file dir)
      (while files
	(setq file (pop files))
	(if (eq t (car (file-attributes file)))
	    ;; `file' is a subdirectory.
	    (setq dir t)
	  ;; `file' is a file or a symlink.
	  (delete-file file)))
      (unless dir
	(delete-directory directory)))))

(defun gnus-strip-whitespace (string)
  "Return STRING stripped of all whitespace."
  (while (string-match "[\r\n\t ]+" string)
    (setq string (replace-match "" t t string)))
  string)

(defsubst gnus-put-text-property-excluding-newlines (beg end prop val)
  "Like `put-text-property', but don't put this prop on any newlines in the region."
  (save-match-data
    (save-excursion
      (save-restriction
	(goto-char beg)
	(while (re-search-forward gnus-emphasize-whitespace-regexp end 'move)
	  (put-text-property beg (match-beginning 0) prop val)
	  (setq beg (point)))
	(put-text-property beg (point) prop val)))))

(defsubst gnus-put-overlay-excluding-newlines (beg end prop val)
  "Like `put-text-property', but don't put this prop on any newlines in the region."
  (save-match-data
    (save-excursion
      (save-restriction
	(goto-char beg)
	(while (re-search-forward gnus-emphasize-whitespace-regexp end 'move)
	  (overlay-put (make-overlay beg (match-beginning 0)) prop val)
	  (setq beg (point)))
	(overlay-put (make-overlay beg (point)) prop val)))))

(defun gnus-put-text-property-excluding-characters-with-faces (beg end prop val)
  "The same as `put-text-property', except where `gnus-face' is set.
If so, and PROP is `face', set the second element of its value to VAL.
Otherwise, do nothing."
  (while (< beg end)
    ;; Property values are compared with `eq'.
    (let ((stop (next-single-property-change beg 'face nil end)))
      (if (get-text-property beg 'gnus-face)
	  (when (eq prop 'face)
	    (setcar (cdr (get-text-property beg 'face)) (or val 'default)))
	(inline
	  (put-text-property beg stop prop val)))
      (setq beg stop))))

(defun gnus-get-text-property-excluding-characters-with-faces (pos prop)
  "The same as `get-text-property', except where `gnus-face' is set.
If so, and PROP is `face', return the second element of its value.
Otherwise, return the value."
  (let ((val (get-text-property pos prop)))
    (if (and (get-text-property pos 'gnus-face)
	     (eq prop 'face))
	(cadr val)
      (get-text-property pos prop))))

(defmacro gnus-faces-at (position)
  "Return a list of faces at POSITION."
  `(let ((pos ,position))
     (delq nil (cons (get-text-property pos 'face)
		     (mapcar
		      (lambda (overlay)
			(overlay-get overlay 'face))
		      (overlays-at pos))))))

;;; Protected and atomic operations.  dmoore@ucsd.edu 21.11.1996
;; The primary idea here is to try to protect internal data structures
;; from becoming corrupted when the user hits C-g, or if a hook or
;; similar blows up.  Often in Gnus multiple tables/lists need to be
;; updated at the same time, or information can be lost.

(defvar gnus-atomic-be-safe t
  "If t, certain operations will be protected from interruption by C-g.")

(defmacro gnus-atomic-progn (&rest forms)
  "Evaluate FORMS atomically, which means to protect the evaluation
from being interrupted by the user.  An error from the forms themselves
will return without finishing the operation.  Since interrupts from
the user are disabled, it is recommended that only the most minimal
operations are performed by FORMS.  If you wish to assign many
complicated values atomically, compute the results into temporary
variables and then do only the assignment atomically."
  (declare (indent 0) (debug t))
  `(let ((inhibit-quit gnus-atomic-be-safe))
     ,@forms))

(defvar mm-text-coding-system)
(declare-function mm-append-to-file "mm-util"
                  (start end filename &optional codesys inhibit))

(defun gnus-output-to-mail (filename &optional ask)
  "Append the current article to a mail file named FILENAME."
  (require 'nnmail)
  (setq filename (expand-file-name filename))
  (let ((artbuf (current-buffer))
	(tmpbuf (gnus-get-buffer-create " *Gnus-output*")))
    (save-excursion
      ;; Create the file, if it doesn't exist.
      (when (and (not (get-file-buffer filename))
		 (not (file-exists-p filename)))
	(if (or (not ask)
		(gnus-y-or-n-p
		 (concat "\"" filename "\" does not exist, create it? ")))
	    (let ((file-buffer (create-file-buffer filename)))
	      (with-current-buffer file-buffer
		(let ((require-final-newline nil)
		      (coding-system-for-write mm-text-coding-system))
		  (gnus-write-buffer filename)))
	      (kill-buffer file-buffer))
	  (error "Output file does not exist")))
      (set-buffer tmpbuf)
      (erase-buffer)
      (insert-buffer-substring artbuf)
      (goto-char (point-min))
      (if (looking-at "From ")
	  (forward-line 1)
	(insert "From nobody " (current-time-string) "\n"))
      (let (case-fold-search)
	(while (re-search-forward "^From " nil t)
	  (beginning-of-line)
	  (insert ">")))
      ;; Decide whether to append to a file or to an Emacs buffer.
      (let ((outbuf (get-file-buffer filename)))
	(if (not outbuf)
	    (let ((buffer-read-only nil))
	      (save-excursion
		(goto-char (point-max))
		(forward-char -2)
		(unless (looking-at "\n\n")
		  (goto-char (point-max))
		  (unless (bolp)
		    (insert "\n"))
		  (insert "\n"))
		(goto-char (point-max))
		(let ((file-name-coding-system nnmail-pathname-coding-system))
		  (mm-append-to-file (point-min) (point-max) filename))))
	  ;; File has been visited, in buffer OUTBUF.
	  (set-buffer outbuf)
	  (let ((buffer-read-only nil))
	    (goto-char (point-max))
	    (unless (eobp)
	      (insert "\n"))
	    (insert "\n")
	    (insert-buffer-substring tmpbuf)))))
    (kill-buffer tmpbuf)))

(defun gnus-map-function (funs arg)
  "Apply the result of the first function in FUNS to the second, and so on.
ARG is passed to the first function."
  (while funs
    (setq arg (funcall (pop funs) arg)))
  arg)

(defun gnus-run-hooks (&rest funcs)
  "Does the same as `run-hooks', but saves the current buffer."
  (save-current-buffer
    (apply #'run-hooks funcs)))

(defun gnus-run-hook-with-args (hook &rest args)
  "Does the same as `run-hook-with-args', but saves the current buffer."
  (save-current-buffer
    (apply #'run-hook-with-args hook args)))

(defun gnus-run-mode-hooks (&rest funcs)
  "Run `run-mode-hooks', saving the current buffer."
  (save-current-buffer (apply #'run-mode-hooks funcs)))

;;; Various

(defmacro gnus--\,@ (exp)
  "Splice EXP's value (a list of Lisp forms) into the code."
  (declare (debug t))
  `(progn ,@(eval exp t)))

(defvar gnus-group-buffer)		; Compiler directive
(defun gnus-alive-p ()
  "Say whether Gnus is running or not."
  (and (boundp 'gnus-group-buffer)
       (get-buffer gnus-group-buffer)
       (with-current-buffer gnus-group-buffer
	 (eq major-mode 'gnus-group-mode))))

(define-obsolete-function-alias 'gnus-remove-if #'seq-remove "27.1")

(define-obsolete-function-alias 'gnus-remove-if-not #'seq-filter "27.1")

(defun gnus-grep-in-list (word list)
  "Find if a WORD matches any regular expression in the given LIST."
  (when (and word list)
    (catch 'found
      (dolist (r list)
	(when (string-match r word)
	  (throw 'found r))))))

(defmacro gnus-alist-pull (key alist &optional assoc-p)
  "Modify ALIST to be without KEY."
  (unless (symbolp alist)
    (error "Not a symbol: %s" alist))
  (let ((fun (if assoc-p 'assoc 'assq)))
    `(setq ,alist (delq (,fun ,key ,alist) ,alist))))

(defun gnus-globalify-regexp (re)
  "Return a regexp that matches a whole line, if RE matches a part of it."
  (concat (unless (string-match "^\\^" re) "^.*")
	  re
	  (unless (string-match "\\$$" re) ".*$")))

(defun gnus-set-window-start (&optional point)
  "Set the window start to POINT, or (point) if nil."
  (let ((win (gnus-get-buffer-window (current-buffer) t)))
    (when win
      (set-window-start win (or point (point))))))

(defun gnus-annotation-in-region-p (b e)
  (if (= b e)
      (eq (cadr (memq 'gnus-undeletable (text-properties-at b))) t)
    (text-property-any b e 'gnus-undeletable t)))

(defun gnus-or (&rest elements)
  "Return non-nil if any one of ELEMENTS is non-nil."
  (seq-drop-while #'null elements))

(defun gnus-and (&rest elements)
  "Return non-nil if all ELEMENTS are non-nil."
  (not (memq nil elements)))

(defun gnus-write-active-file (file hashtb &optional full-names)
  (let ((coding-system-for-write nnmail-active-file-coding-system))
    (with-temp-file file
      (maphash
       (lambda (group active)
	 (when active
	   (insert (format "%S %d %d y\n"
			   (if full-names
			       group
			     (gnus-group-real-name group))
			   (or (cdr active)
			       (car active))
			   (car active)))))
       hashtb)
      (goto-char (point-max))
      (while (search-backward "\\." nil t)
	(delete-char 1)))))

;; Fixme: Why not use `with-output-to-temp-buffer'?
(defmacro gnus-with-output-to-file (file &rest body)
  (declare (indent 1) (debug t))
  (let ((buffer (make-symbol "output-buffer"))
        (size (make-symbol "output-buffer-size"))
        (leng (make-symbol "output-buffer-length"))
        (append (make-symbol "output-buffer-append")))
    `(let* ((,size 131072)
            (,buffer (make-string ,size 0))
            (,leng 0)
            (,append nil)
            (standard-output
	     (lambda (c)
               (aset ,buffer ,leng c)

	       (if (= ,size (setq ,leng (1+ ,leng)))
		   (progn (write-region ,buffer nil ,file ,append 'no-msg)
			  (setq ,leng 0
				,append t))))))
       ,@body
       (when (> ,leng 0)
         (let ((coding-system-for-write 'no-conversion))
	 (write-region (substring ,buffer 0 ,leng) nil ,file
		       ,append 'no-msg))))))

(defun gnus-add-text-properties-when
  (property value start end properties &optional object)
  "Like `add-text-properties', only applied on where PROPERTY is VALUE."
  (let (point)
    (while (and start
		(< start end) ;; XEmacs will loop for every when start=end.
		(setq point (text-property-not-all start end property value)))
      (add-text-properties start point properties object)
      (setq start (text-property-any point end property value)))
    (if start
	(add-text-properties start end properties object))))

(defun gnus-remove-text-properties-when
  (property value start end properties &optional object)
  "Like `remove-text-properties', only applied on where PROPERTY is VALUE."
  (let (point)
    (while (and start
		(< start end)
		(setq point (text-property-not-all start end property value)))
      (remove-text-properties start point properties object)
      (setq start (text-property-any point end property value)))
    (if start
	(remove-text-properties start end properties object))
    t))

(defun gnus-string-remove-all-properties (string)
  (condition-case ()
      (let ((s string))
	(set-text-properties 0 (length string) nil string)
	s)
    (error string)))

;; This might use `compare-strings' to reduce consing in the
;; case-insensitive case, but it has to cope with null args.
;; (`string-equal' uses symbol print names.)
(defun gnus-string-equal (x y)
  "Like `string-equal', except it compares case-insensitively."
  (declare (obsolete string-equal-ignore-case "29.1"))
  (and (= (length x) (length y))
       (or (string-equal x y)
	   (string-equal (downcase x) (downcase y)))))

(defcustom gnus-use-byte-compile t
  "If non-nil, byte-compile crucial run-time code."
  :type 'boolean
  :version "22.1"
  :group 'gnus-various)

(defun gnus-byte-compile (form)
  "Byte-compile FORM if `gnus-use-byte-compile' is non-nil."
  (if gnus-use-byte-compile
      (let ((byte-compile-warnings '(unresolved callargs redefine))
	    (lexical-binding t))
	(byte-compile form))
    (eval form t)))

(defun gnus-remassoc (key alist)
  "Delete by side effect any elements of LIST whose car is `equal' to KEY.
The modified LIST is returned.  If the first member
of LIST has a car that is `equal' to KEY, there is no way to remove it
by side effect; therefore, write `(setq foo (gnus-remassoc key foo))' to be
sure of changing the value of `foo'."
  (when alist
    (if (equal key (caar alist))
	(cdr alist)
      (setcdr alist (gnus-remassoc key (cdr alist)))
      alist)))

(defun gnus-update-alist-soft (key value alist)
  (if value
      (cons (cons key value) (gnus-remassoc key alist))
    (gnus-remassoc key alist)))

(defvar gnus-info-buffer)
(declare-function gnus-configure-windows "gnus-win" (setting &optional force))

(defun gnus-create-info-command (node)
  "Create a command that will go to info NODE."
  (lambda ()
    (:documentation (format "Enter the info system at node %s." node))
    (interactive)
    (info node)
    (setq gnus-info-buffer (current-buffer))
    (gnus-configure-windows 'info)))

(defalias 'gnus-not-ignore #'always)

(defvar gnus-directory-sep-char-regexp "/"
  "The regexp of directory separator character.
If you find some problem with the directory separator character, try
\"[/\\\\]\" for some systems.")

(autoload 'url-unhex "url-util")
(define-obsolete-function-alias 'gnus-url-unhex #'url-unhex "29.1")

;; FIXME: Make obsolete in favor of `url-unhex-string', which is
;;        identical except for the call to `char-to-string'.
(defun gnus-url-unhex-string (str &optional allow-newlines)
  "Remove %XX, embedded spaces, etc in a url.
If optional second argument ALLOW-NEWLINES is non-nil, then allow the
decoding of carriage returns and line feeds in the string, which is normally
forbidden in URL encoding."
  (let ((tmp "")
	(case-fold-search t))
    (while (string-match "%[0-9a-f][0-9a-f]" str)
      (let* ((start (match-beginning 0))
             (ch1 (url-unhex (elt str (+ start 1))))
	     (code (+ (* 16 ch1)
                      (url-unhex (elt str (+ start 2))))))
	(setq tmp (concat
		   tmp (substring str 0 start)
		   (cond
		    (allow-newlines
		     (char-to-string code))
		    ((or (= code ?\n) (= code ?\r))
		     " ")
		    (t (char-to-string code))))
	      str (substring str (match-end 0)))))
    (setq tmp (concat tmp str))
    tmp))

(defun gnus-make-predicate (spec)
  "Transform SPEC into a function that can be called.
SPEC is a predicate specifier that contains stuff like `or', `and',
`not', lists and functions.  The functions all take one parameter."
  `(lambda (elem) ,(gnus-make-predicate-1 spec)))

(defun gnus-make-predicate-1 (spec)
  (cond
   ((symbolp spec)
    `(,spec elem))
   ((listp spec)
    (if (memq (car spec) '(or and not))
	`(,(car spec) ,@(mapcar #'gnus-make-predicate-1 (cdr spec)))
      (error "Invalid predicate specifier: %s" spec)))))

(defun gnus-completing-read (prompt collection &optional require-match
                                    initial-input history def)
  "Call `gnus-completing-read-function'."
  (funcall gnus-completing-read-function
           (format-prompt prompt def)
           collection require-match initial-input history def))

(defun gnus-emacs-completing-read (prompt collection &optional require-match
                                          initial-input history def)
  "Call standard `completing-read-function'."
  (let ((completion-styles gnus-completion-styles))
    (completing-read prompt collection
                     nil require-match initial-input history def)))

(autoload 'ido-completing-read "ido")
(defun gnus-ido-completing-read (prompt collection &optional require-match
                                        initial-input history def)
  "Call `ido-completing-read'."
  (ido-completing-read prompt collection nil require-match
		       initial-input history def))


(declare-function iswitchb-read-buffer "iswitchb"
		  (prompt &optional default require-match
			  _predicate start matches-set))
(declare-function iswitchb-minibuffer-setup "iswitchb")
(defvar iswitchb-temp-buflist)
(defvar iswitchb-mode)
(defvar iswitchb-make-buflist-hook)

(defun gnus-iswitchb-completing-read (prompt collection &optional require-match
                                            initial-input history def)
  "`iswitchb' based completing-read function."
  (declare (obsolete nil "29.1"))
  ;; Make sure iswitchb is loaded before we let-bind its variables.
  ;; If it is loaded inside the let, variables can become unbound afterwards.
  (require 'iswitchb)
  (let ((iswitchb-make-buflist-hook
         (lambda ()
           (setq iswitchb-temp-buflist
                 (let ((choices (append
                                 (when initial-input (list initial-input))
                                 (symbol-value history) collection))
                       filtered-choices)
                   (dolist (x choices)
                     (setq filtered-choices (cl-adjoin x filtered-choices)))
                   (nreverse filtered-choices))))))
    (unwind-protect
        (progn
          (or iswitchb-mode
	      (add-hook 'minibuffer-setup-hook #'iswitchb-minibuffer-setup))
          (iswitchb-read-buffer prompt def require-match))
      (or iswitchb-mode
	  (remove-hook 'minibuffer-setup-hook #'iswitchb-minibuffer-setup)))))

(defmacro gnus-parse-without-error (&rest body)
  "Allow continuing onto the next line even if an error occurs."
  (declare (indent 0) (debug t))
  `(while (not (eobp))
     (condition-case ()
	 (progn
	   ,@body
	   (goto-char (point-max)))
       (error
	(gnus-error 4 "Invalid data on line %d"
		    (count-lines (point-min) (point)))
	(forward-line 1)))))

(defun gnus-cache-file-contents (file variable function)
  "Cache the contents of FILE in VARIABLE.  The contents come from FUNCTION."
  (let ((time (file-attribute-modification-time (file-attributes file)))
	contents value)
    (if (or (null (setq value (symbol-value variable)))
	    (not (equal (car value) file))
	    (not (time-equal-p (nth 1 value) time)))
	(progn
	  (setq contents (funcall function file))
	  (set variable (list file time contents))
	  contents)
      (nth 2 value))))

(defun gnus-multiple-choice (prompt choice &optional idx)
  "Ask user a multiple choice question.
CHOICE is a list of the choice char and help message at IDX."
  (let (tchar buf)
    (save-window-excursion
      (save-excursion
	(while (not tchar)
	  (message "%s (%s): "
		   prompt
		   (concat
		    (mapconcat (lambda (s) (char-to-string (car s)))
			       choice ", ")
		    ", ?"))
	  (setq tchar (read-char))
	  (when (not (assq tchar choice))
	    (setq tchar nil)
	    (setq buf (gnus-get-buffer-create "*Gnus Help*"))
	    (pop-to-buffer buf)
	    (fundamental-mode)
	    (buffer-disable-undo)
	    (erase-buffer)
	    (insert prompt ":\n\n")
	    (let ((max -1)
		  (list choice)
		  (alist choice)
		  (idx (or idx 1))
		  (i 0)
		  n width pad format)
	      ;; find the longest string to display
	      (while list
		(setq n (length (nth idx (car list))))
		(unless (> max n)
		  (setq max n))
		(setq list (cdr list)))
	      (setq max (+ max 4))	; %c, `:', SPACE, a SPACE at end
	      (setq n (/ (1- (window-width)) max)) ; items per line
	      (setq width (/ (1- (window-width)) n)) ; width of each item
	      ;; insert `n' items, each in a field of width `width'
	      (while alist
		(if (< i n)
		    ()
		  (setq i 0)
		  (delete-char -1)		; the `\n' takes a char
		  (insert "\n"))
		(setq pad (- width 3))
		(setq format (concat "%c: %-" (int-to-string pad) "s"))
		(insert (format format (caar alist) (nth idx (car alist))))
		(setq alist (cdr alist))
		(setq i (1+ i))))))))
    (if (buffer-live-p buf)
	(kill-buffer buf))
    tchar))

(defun gnus-frame-or-window-display-name (object)
  "Given a frame or window, return the associated display name.
Return nil otherwise."
  (if (or (framep object)
	  (and (windowp object)
	       (setq object (window-frame object))))
      (let ((display (frame-parameter object 'display)))
	(if (and (stringp display)
		 ;; Exclude invalid display names.
		 (string-match "\\`[^:]*:[0-9]+\\(\\.[0-9]+\\)?\\'"
			       display))
	    display))))

(defvar tool-bar-mode)

(defun gnus-tool-bar-update (&rest _ignore)
  "Update the tool bar."
  (when (and (boundp 'tool-bar-mode)
	     tool-bar-mode)
    (let* ((args nil)
	   (func (cond ((fboundp 'tool-bar-update)
			'tool-bar-update)
		       ((fboundp 'force-window-update)
			'force-window-update)
		       ((fboundp 'redraw-frame)
			(setq args (list (selected-frame)))
			'redraw-frame)
		       (t 'ignore))))
      (apply func args))))

;; Fixme: This has only one use (in gnus-agent), which isn't worthwhile.
(defmacro gnus-mapcar (function seq1 &rest seqs2_n)
  "Apply FUNCTION to each element of the sequences, and make a list of the results.
If there are several sequences, FUNCTION is called with that many arguments,
and mapping stops as soon as the shortest sequence runs out.  With just one
sequence, this is like `mapcar'.  With several, it is like the Common Lisp
`mapcar' function extended to arbitrary sequence types."

  (if seqs2_n
      (let* ((seqs (cons seq1 seqs2_n))
	     (cnt 0)
	     (heads (mapcar (lambda (_seq)
			      (make-symbol (concat "head"
						   (int-to-string
						    (setq cnt (1+ cnt))))))
			    seqs))
	     (result (make-symbol "result"))
	     (result-tail (make-symbol "result-tail")))
	`(let* ,(let* ((bindings (cons nil nil))
		       (heads heads))
		  (nconc bindings (list (list result '(cons nil nil))))
		  (nconc bindings (list (list result-tail result)))
		  (while heads
		    (nconc bindings (list (list (pop heads) (pop seqs)))))
		  (cdr bindings))
	   (while (and ,@heads)
	     (setcdr ,result-tail (cons (funcall ,function
						 ,@(mapcar (lambda (h) (list 'car h))
							   heads))
					nil))
	     (setq ,result-tail (cdr ,result-tail)
		   ,@(mapcan (lambda (h) (list h (list 'cdr h))) heads)))
	   (cdr ,result)))
    `(mapcar ,function ,seq1)))

(defun gnus-emacs-version ()
  "Stringified Emacs version."
  (let* ((lst (if (listp gnus-user-agent)
		  gnus-user-agent
		'(gnus emacs type)))
	 (system-v (cond ((memq 'config lst)
			  system-configuration)
			 ((memq 'type lst)
			  (symbol-name system-type))
                         (t nil))))
    (cond
     ((not (memq 'emacs lst))
      nil)
     ((string-match "^[.0-9]*\\.[0-9]+$" emacs-version)
      (concat "Emacs/" emacs-version
	      (if system-v
		  (concat " (" system-v ")")
		"")))
     (t emacs-version))))

(defun gnus-rename-file (old-path new-path &optional trim)
  "Rename OLD-PATH as NEW-PATH.
If TRIM, recursively delete empty directories from OLD-PATH."
  (when (file-exists-p old-path)
    (let* ((old-dir (file-name-directory old-path))
	   ;; (old-name (file-name-nondirectory old-path))
	   (new-dir (file-name-directory new-path))
	   ;; (new-name (file-name-nondirectory new-path))
	   temp)
      (gnus-make-directory new-dir)
      (rename-file old-path new-path t)
      (when trim
	(while (progn (setq temp (directory-files old-dir))
		      (while (member (car temp) '("." ".."))
			(setq temp (cdr temp)))
		      (= (length temp) 0))
	  (delete-directory old-dir)
	  (setq old-dir (file-name-as-directory
			 (file-truename
			  (concat old-dir "..")))))))))

(defun gnus-set-file-modes (filename mode &optional flag)
  "Wrapper for `set-file-modes'."
  (ignore-errors
    (set-file-modes filename mode flag)))

(defun gnus-rescale-image (image size)
  "Rescale IMAGE to SIZE if possible.
SIZE is in format (WIDTH . HEIGHT).  Return a new image.
Sizes are in pixels."
  (when (display-images-p)
    (declare-function image-size "image.c" (spec &optional pixels frame))
    (let ((new-width (car size))
          (new-height (cdr size)))
      (when (> (cdr (image-size image t)) new-height)
	(setq image (create-image (plist-get (cdr image) :data) nil t
                                  :max-height new-height)))
      (when (> (car (image-size image t)) new-width)
	(setq image (create-image (plist-get (cdr image) :data) nil t
                                  :max-width new-width)))))
  image)

(defun gnus-recursive-directory-files (dir)
  "Return all regular files below DIR.
The first found will be returned if a file has hard or symbolic links."
  (let (files attr attrs)
    (cl-labels
	((fn (directory)
	     (dolist (file (directory-files directory t))
	       (setq attr (file-attributes (file-truename file)))
	       (when (and (not (member attr attrs))
			  (not (member (file-name-nondirectory file)
				       '("." "..")))
			  (file-readable-p file))
		 (push attr attrs)
		 (cond ((file-regular-p file)
			(push file files))
		       ((file-directory-p file)
			(fn file)))))))
      (fn dir))
    files))

(defun gnus-list-memq-of-list (elements list)
  "Return non-nil if any of the members of ELEMENTS are in LIST."
  (let ((found nil))
    (dolist (elem elements)
      (setq found (or found
		      (memq elem list))))
    found))

(defun gnus-test-list (list predicate)
  "To each element of LIST apply PREDICATE.
Return nil if LIST is no list or is empty or some test returns nil;
otherwise, return t."
  (declare (obsolete nil "28.1"))
  (when (and list (listp list))
    (let ((result (mapcar predicate list)))
      (not (memq nil result)))))

(defun gnus-subsetp (list1 list2)
  "Return t if LIST1 is a subset of LIST2.
Similar to `subsetp' but use member for element test so that this works for
lists of strings."
  (when (and (listp list1) (listp list2))
    (if list1
	(and (member (car list1) list2)
	     (gnus-subsetp (cdr list1) list2))
      t)))

(defun gnus-setdiff (list1 list2)
  "Return member-based set difference of LIST1 and LIST2."
  (when (and list1 (listp list1) (listp list2))
    (if (member (car list1) list2)
	(gnus-setdiff (cdr list1) list2)
      (cons (car list1) (gnus-setdiff (cdr list1) list2)))))

;;; Image functions.

(defun gnus-image-type-available-p (type)
  (and (display-images-p)
       (image-type-available-p type)))

(defun gnus-create-image (file &optional type data-p &rest props)
  (let ((face (plist-get props :face)))
    (when face
      (setq props (plist-put props :foreground (face-foreground face)))
      (setq props (plist-put props :background (face-background face))))
    (ignore-errors
      (apply #'create-image file type data-p props))))

(defun gnus-put-image (glyph &optional string category)
  (let ((point (point)))
    (insert-image glyph (or string " "))
    (put-text-property point (point) 'gnus-image-category category)
    (unless string
      (put-text-property (1- (point)) (point)
			 'gnus-image-text-deletable t))
    glyph))

(defun gnus-remove-image (image &optional category)
  "Remove the image matching IMAGE and CATEGORY found first."
  (let ((start (point-min))
	val end)
    (while (and (not end)
		(or (setq val (get-text-property start 'display))
		    (and (setq start
			       (next-single-property-change start 'display))
			 (setq val (get-text-property start 'display)))))
      (setq end (or (next-single-property-change start 'display)
		    (point-max)))
      (if (and (equal val image)
	       (equal (get-text-property start 'gnus-image-category)
		      category))
	  (progn
	    (put-text-property start end 'display nil)
	    (when (get-text-property start 'gnus-image-text-deletable)
	      (delete-region start end)))
	(unless (= end (point-max))
	  (setq start end
		end nil))))))

(defun gnus-kill-all-overlays ()
  "Delete all overlays in the current buffer."
  (let* ((overlayss (overlay-lists))
	 (buffer-read-only nil)
	 (overlays (delq nil (nconc (car overlayss) (cdr overlayss)))))
    (while overlays
      (delete-overlay (pop overlays)))))

;; This function used to live in this file, but was moved to a
;; separate file to avoid pulling in rmail.el when requiring
;; gnus-util.
(autoload 'gnus-output-to-rmail "gnus-rmail")

(define-obsolete-function-alias 'gnus-delete-duplicates #'seq-uniq "29.1")

(provide 'gnus-util)

;;; gnus-util.el ends here
