;;; vc-annotate.el --- VC Annotate Support  -*- lexical-binding: t -*-

;; Copyright (C) 1997-1998, 2000-2025 Free Software Foundation, Inc.

;; Author: Martin Lorentzson <emwson@emw.ericsson.se>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: vc tools
;; Package: vc

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
;;

(require 'vc-hooks)
(require 'vc)

;;; Code:
(eval-when-compile (require 'cl-lib))

(defcustom vc-annotate-display-mode 'fullscale
  "Which mode to color the output of \\[vc-annotate] with by default."
  :type '(choice (const :tag "By Color Map Range" nil)
		 (const :tag "Scale to Oldest" scale)
		 (const :tag "Scale Oldest->Newest" fullscale)
		 (number :tag "Specify Fractional Number of Days"
			 :value "20.5"))
  :group 'vc)

(defcustom vc-annotate-background-mode
  (not (or (eq (or frame-background-mode
		   (frame-parameter nil 'background-mode))
	       'dark)
	   (and (tty-display-color-p) (<= (display-color-cells) 8))))
  "Non-nil means `vc-annotate-color-map' is applied to the background.

When non-nil, the color range from `vc-annotate-color-map' is applied
to the background, while the foreground remains default.

When nil, the color range from `vc-annotate-color-map' is applied
to the foreground, and the color from the option `vc-annotate-background'
is applied to the background."
  :type 'boolean
  :set (lambda (symbol value)
	 (set-default symbol value)
	 (when (boundp 'vc-annotate-color-map)
	   (with-demoted-errors "VC color map error: %S"
	     ;; Update the value of the dependent variable.
	     (custom-reevaluate-setting 'vc-annotate-color-map))))
  :version "25.1"
  :group 'vc)

(defcustom vc-annotate-color-map
  (if (and (tty-display-color-p) (<= (display-color-cells) 8))
      ;; A custom sorted TTY colormap
      (let* ((colors
	      (sort
	       (delq nil
		     (mapcar (lambda (x)
			       (if (not (or
					 (string-equal (car x) "white")
					 (string-equal (car x) "black") ))
				   (car x)))
			     (tty-color-alist)))
	       (lambda (a b)
		 (cond
		  ((or (string-equal a "red") (string-equal b "blue")) t)
		  ((or (string-equal b "red") (string-equal a "blue")) nil)
		  ((string-equal a "yellow") t)
		  ((string-equal b "yellow") nil)
		  ((string-equal a "cyan") t)
		  ((string-equal b "cyan") nil)
		  ((string-equal a "green") t)
		  ((string-equal b "green") nil)
		  ((string-equal a "magenta") t)
		  ((string-equal b "magenta") nil)
		  (t (string< a b))))))
	     (date 20.)
	     (delta (/ (- 360. date) (1- (length colors)))))
	(mapcar (lambda (x)
		  (prog1
		      (cons date x)
		    (setq date (+ date delta)))) colors))
    (cond
     ;; Normal colormap for background colors with dark foreground:
     ;; hue stepped from 0-240deg, value=1., saturation=0.20
     (vc-annotate-background-mode
      '(( 20. . "#FFCCCC")
	( 40. . "#FFD8CC")
	( 60. . "#FFE4CC")
	( 80. . "#FFF0CC")
	(100. . "#FFFCCC")
	(120. . "#F6FFCC")
	(140. . "#EAFFCC")
	(160. . "#DEFFCC")
	(180. . "#D2FFCC")
	(200. . "#CCFFD2")
	(220. . "#CCFFDE")
	(240. . "#CCFFEA")
	(260. . "#CCFFF6")
	(280. . "#CCFCFF")
	(300. . "#CCF0FF")
	(320. . "#CCE4FF")
	(340. . "#CCD8FF")
	(360. . "#CCCCFF")))
     ;; Normal colormap for foreground colors on dark background:
     ;; hue stepped from 0-240deg, value=1., saturation=0.75
     (t
      '(( 20. . "#FF3F3F")
	( 40. . "#FF6C3F")
	( 60. . "#FF993F")
	( 80. . "#FFC63F")
	(100. . "#FFF33F")
	(120. . "#DDFF3F")
	(140. . "#B0FF3F")
	(160. . "#83FF3F")
	(180. . "#56FF3F")
	(200. . "#3FFF56")
	(220. . "#3FFF83")
	(240. . "#3FFFB0")
	(260. . "#3FFFDD")
	(280. . "#3FF3FF")
	(300. . "#3FC6FF")
	(320. . "#3F99FF")
	(340. . "#3F6CFF")
	(360. . "#3F3FFF")))))
  "Association list of age versus color, for \\[vc-annotate].
Ages are given in units of fractional days.  Default is eighteen
steps using a twenty day increment, from red to blue.  For TTY
displays with 8 or fewer colors, the default is red to blue with
all other colors between (excluding black and white)."
  :type 'alist
  :group 'vc)

(defcustom vc-annotate-very-old-color (if vc-annotate-background-mode "#CCCCFF" "#3F3FFF")
  "Color for lines older than the current color range in \\[vc-annotate]."
  :type 'string
  :group 'vc)

(defcustom vc-annotate-background nil
  "Background color for \\[vc-annotate].
Default color is used if nil."
  :type '(choice (const :tag "Default background" nil) (color))
  :group 'vc)

(defcustom vc-annotate-menu-elements '(2 0.5 0.1 0.01)
  "Menu elements for the mode-specific menu of VC-Annotate mode.
List of factors, used to expand/compress the time scale.  See `vc-annotate'."
  :type '(repeat number)
  :group 'vc)

(defcustom vc-annotate-use-short-revision t
  "If non-nil, \\[vc-annotate] will use short revisions in its buffer name."
  :type 'boolean
  :version "30.1"
  :group 'vc)

(defvar-keymap vc-annotate-mode-map
  :doc "Local keymap used for VC-Annotate mode."
  "a"   #'vc-annotate-revision-previous-to-line
  "d"   #'vc-annotate-show-diff-revision-at-line
  "="   #'vc-annotate-show-diff-revision-at-line
  "D"   #'vc-annotate-show-changeset-diff-revision-at-line
  "f"   #'vc-annotate-find-revision-at-line
  "j"   #'vc-annotate-revision-at-line
  "l"   #'vc-annotate-show-log-revision-at-line
  "n"   #'vc-annotate-next-revision
  "p"   #'vc-annotate-prev-revision
  "w"   #'vc-annotate-working-revision
  "v"   #'vc-annotate-toggle-annotation-visibility
  "RET" #'vc-annotate-goto-line)

;;; Annotate functionality

;; Declare globally instead of additional parameter to
;; temp-buffer-show-function (not possible to pass more than one
;; parameter).  The use of annotate-ratio is deprecated in favor of
;; annotate-mode, which replaces it with the more sensible "span-to
;; days", along with autoscaling support.
(defvar vc-annotate-ratio nil "Global variable.")

;; internal buffer-local variables
(defvar vc-annotate-backend nil)
(defvar vc-annotate-parent-display-mode nil)

(defconst vc-annotate-font-lock-keywords
  ;; The fontification is done by vc-annotate-lines instead of font-lock.
  '((vc-annotate-lines)))

(define-derived-mode vc-annotate-mode special-mode "Annotate"
  "Major mode for output buffers of the `vc-annotate' command.

You can use the mode-specific menu to alter the time-span of the used
colors.  See variable `vc-annotate-menu-elements' for customizing the
menu items."
  ;; Frob buffer-invisibility-spec so that if it is originally a naked t,
  ;; it will become a list, to avoid initial annotations being invisible.
  (add-to-invisibility-spec 'foo)
  (remove-from-invisibility-spec 'foo)
  (setq-local truncate-lines t)
  (setq-local font-lock-defaults '(vc-annotate-font-lock-keywords t))
  (hack-dir-local-variables-non-file-buffer))

(defun vc-annotate-toggle-annotation-visibility ()
  "Toggle whether or not the annotation is visible."
  (interactive)
  (funcall (if (memq 'vc-annotate-annotation buffer-invisibility-spec)
               'remove-from-invisibility-spec
             'add-to-invisibility-spec)
           'vc-annotate-annotation)
  (force-window-update (current-buffer)))

(defun vc-annotate-display-default (ratio)
  "Display the output of \\[vc-annotate] using the default color range.
The color range is given by `vc-annotate-color-map', scaled by RATIO.
The current time is used as the offset."
  (interactive (progn (kill-local-variable 'vc-annotate-color-map) '(1.0)))
  (message "Redisplaying annotation...")
  (vc-annotate-display ratio)
  (message "Redisplaying annotation...done"))

(defun vc-annotate-oldest-in-map (color-map)
  "Return the oldest time in the COLOR-MAP."
  ;; Since entries should be sorted, we can just use the last one.
  (caar (last color-map)))

(defun vc-annotate-get-time-set-line-props ()
  (let ((bol (point))
        (date (vc-call-backend vc-annotate-backend 'annotate-time))
        (inhibit-read-only t))
    (cl-assert (>= (point) bol))
    (put-text-property bol (point) 'invisible 'vc-annotate-annotation)
    date))

(defun vc-annotate-display-autoscale (&optional full)
  "Highlight the output of \\[vc-annotate] using an autoscaled color map.
Autoscaling means that the map is scaled from the current time to the
oldest annotation in the buffer, or, with prefix argument FULL, to
cover the range from the oldest annotation to the newest."
  (interactive "P")
  (let ((newest 0.0)
	(oldest 999999.)		;Any CVS users at the founding of Rome?
	(current (vc-annotate-convert-time))
	date)
    (message "Redisplaying annotation...")
    ;; Run through this file and find the oldest and newest dates annotated.
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (setq date (vc-annotate-get-time-set-line-props))
          (when (> date newest)
	    (setq newest date))
          (when (< date oldest)
	    (setq oldest date)))
        (forward-line 1)))
    (vc-annotate-display
     (/ (- (if full newest current) oldest)
        (vc-annotate-oldest-in-map vc-annotate-color-map))
     (if full newest))
    (message "Redisplaying annotation...done (%s)"
	     (if full
		 (format "Spanned from %.1f to %.1f days old"
			 (- current oldest)
			 (- current newest))
	       (format "Spanned to %.1f days old" (- current oldest))))))

;; Menu -- Using easymenu.el
(easy-menu-define vc-annotate-mode-menu vc-annotate-mode-map
  "VC Annotate Display Menu."
  `("VC-Annotate"
    ["By Color Map Range" (unless (null vc-annotate-display-mode)
                 (setq vc-annotate-display-mode nil)
                 (vc-annotate-display-select))
     :style toggle :selected (null vc-annotate-display-mode)]
    ,@(let ((oldest-in-map (vc-annotate-oldest-in-map vc-annotate-color-map)))
        (mapcar (lambda (element)
                  (let ((days (* element oldest-in-map)))
                    `[,(format "Span %.1f days" days)
                      (vc-annotate-display-select nil ,days)
                      :style toggle :selected
                      (eql vc-annotate-display-mode ,days) ]))
                vc-annotate-menu-elements))
    ["Span ..."
     (vc-annotate-display-select
      nil (float (string-to-number (read-string "Span how many days? "))))]
    "--"
    ["Span to Oldest"
     (unless (eq vc-annotate-display-mode 'scale)
       (vc-annotate-display-select nil 'scale))
     :help
     "Use an autoscaled color map from the oldest annotation to the current time"
     :style toggle :selected
     (eq vc-annotate-display-mode 'scale)]
    ["Span Oldest->Newest"
     (unless (eq vc-annotate-display-mode 'fullscale)
       (vc-annotate-display-select nil 'fullscale))
     :help
     "Use an autoscaled color map from the oldest to the newest annotation"
     :style toggle :selected
     (eq vc-annotate-display-mode 'fullscale)]
    "--"
    ["Toggle annotation visibility" vc-annotate-toggle-annotation-visibility
     :help
     "Toggle whether the annotation is visible or not"]
    ["Annotate previous revision" vc-annotate-prev-revision
     :help "Visit the annotation of the revision previous to this one"]
    ["Annotate next revision" vc-annotate-next-revision
     :help "Visit the annotation of the revision after this one"]
    ["Annotate revision at line" vc-annotate-revision-at-line
     :help
     "Visit the annotation of the revision identified in the current line"]
    ["Annotate revision previous to line" vc-annotate-revision-previous-to-line
     :help "Visit the annotation of the revision before the revision at line"]
    ["Annotate latest revision" vc-annotate-working-revision
     :help "Visit the annotation of the working revision of this file"]
    "--"
    ["Show log of revision at line" vc-annotate-show-log-revision-at-line
     :help "Visit the log of the revision at line"]
    ["Show diff of revision at line" vc-annotate-show-diff-revision-at-line
     :help "Visit the diff of the revision at line from its previous revision"]
    ["Show changeset diff of revision at line"
     vc-annotate-show-changeset-diff-revision-at-line
     :enable
     (eq 'repository (vc-call-backend vc-annotate-backend 'revision-granularity))
     :help "Visit the diff of the revision at line from its previous revision"]
    ["Visit revision at line" vc-annotate-find-revision-at-line
     :help "Visit the revision identified in the current line"]))

(defun vc-annotate-display-select (&optional buffer mode)
  "Highlight the output of \\[vc-annotate].
By default, the current buffer is highlighted, unless overridden by
BUFFER.  `vc-annotate-display-mode' specifies the highlighting mode to
use; you may override this using the second optional arg MODE."
  (interactive)
  (when mode (setq vc-annotate-display-mode mode))
  (pop-to-buffer (or buffer (current-buffer)))
  (cond ((null vc-annotate-display-mode)
         ;; The ratio is global, thus relative to the global color-map.
         (kill-local-variable 'vc-annotate-color-map)
	 (vc-annotate-display-default (or vc-annotate-ratio 1.0)))
        ;; One of the auto-scaling modes
	((eq vc-annotate-display-mode 'scale)
	 (vc-run-delayed (vc-annotate-display-autoscale)))
	((eq vc-annotate-display-mode 'fullscale)
	 (vc-run-delayed (vc-annotate-display-autoscale t)))
	((numberp vc-annotate-display-mode) ; A fixed number of days lookback
	 (vc-annotate-display-default
	  (/ vc-annotate-display-mode
             (vc-annotate-oldest-in-map vc-annotate-color-map))))
	(t (error "No such display mode: %s"
		  vc-annotate-display-mode))))

(defvar vc-sentinel-movepoint)

;;;###autoload
(defun vc-annotate (file rev &optional display-mode buf move-point-to backend)
  "Display the edit history of the current FILE using colors.

This command creates a buffer that shows, for each line of the current
file, when it was last edited and by whom.  Additionally, colors are
used to show the age of each line--blue means oldest, red means
youngest, and intermediate colors indicate intermediate ages.  By
default, the time scale stretches back one year into the past;
everything that is older than that is shown in blue.

With a prefix argument, this command asks two questions in the
minibuffer.  First, you may enter a revision number REV; then the buffer
displays and annotates that revision instead of the working revision
\(type RET in the minibuffer to leave that default unchanged).  Then,
you are prompted for the time span in days which the color range
should cover.  For example, a time span of 20 days means that changes
over the past 20 days are shown in red to blue, according to their
age, and everything that is older than that is shown in blue.

If MOVE-POINT-TO is given, move the point to that line.

If BACKEND is given, use that VC backend.

Customization variables:

`vc-annotate-menu-elements' customizes the menu elements of the
mode-specific menu.  `vc-annotate-color-map' and
`vc-annotate-very-old-color' define the mapping of time to colors.
`vc-annotate-background' specifies the background color.
`vc-annotate-background-mode' specifies whether the color map
should be applied to the background or to the foreground."
  (interactive
   (save-current-buffer
     (let ((name (if (length= (cadr vc-buffer-overriding-fileset) 1)
                     (caadr vc-buffer-overriding-fileset)
                   (vc-ensure-vc-buffer)
                   buffer-file-name)))
       (list name
	     (let ((def (or vc-buffer-revision
                            (funcall (if vc-annotate-use-short-revision
                                         #'vc-short-revision
                                       #'vc-working-revision)
                                     name))))
	       (if (null current-prefix-arg) def
	         (vc-read-revision
		  (format-prompt "Annotate from revision" def)
		  (list name) nil def)))
	     (if (null current-prefix-arg)
	         vc-annotate-display-mode
	       (float (string-to-number
		       (read-string (format-prompt "Annotate span days" 20)
				    nil nil "20"))))))))
  (setq vc-annotate-display-mode display-mode) ;Not sure why.  --Stef
  (let* ((backend (or backend
                      (car vc-buffer-overriding-fileset)
                      (vc-backend file)))
         (file-buffer (get-file-buffer file))
         (temp-buffer-name
          (format "*Annotate %s (rev %s)*"
                  (if file-buffer
                      (buffer-name file-buffer)
                    ;; Try to avoid ambiguity.
                    (file-relative-name file
                                        (vc-call-backend backend 'root
                                                         default-directory)))
                  rev))
         (temp-buffer-show-function 'vc-annotate-display-select)
         ;; If BUF is specified, we presume the caller maintains current line,
         ;; so we don't need to do it here.  This implementation may give
         ;; strange results occasionally in the case of REV != WORKFILE-REV.
         (current-line (or move-point-to (unless buf
					   (save-restriction
					     (widen)
					     (line-number-at-pos))))))
    (message "Annotating...")
    ;; If BUF is specified it tells in which buffer we should put the
    ;; annotations.  This is used when switching annotations to another
    ;; revision, so we should update the buffer's name.
    (when buf (with-current-buffer buf
		(rename-buffer temp-buffer-name t)
		;; In case it had to be uniquified.
		(setq temp-buffer-name (buffer-name))))
    (let ((coding-system-for-read buffer-file-coding-system))
      (with-output-to-temp-buffer temp-buffer-name
        ;; For a VC backend running on DOS/Windows, it's normal to
        ;; produce CRLF EOLs even if the original file has Unix EOLs,
        ;; which will show ^M characters in the Annotate buffer.  (One
        ;; known case in point is "svn annotate".)  Prevent that by
        ;; forcing DOS EOL decoding.
        (if (memq system-type '(windows-nt ms-dos))
            (setq coding-system-for-read
                  (coding-system-change-eol-conversion coding-system-for-read
                                                       'dos)))
        (vc-call-backend backend 'annotate-command file
                         (get-buffer temp-buffer-name) rev)
        ;; we must setup the mode first, and then set our local
        ;; variables before the show-function is called at the exit of
        ;; with-output-to-temp-buffer
        (with-current-buffer temp-buffer-name
          (unless (equal major-mode 'vc-annotate-mode)
            (vc-annotate-mode))
          (setq-local vc-annotate-backend backend)
          (setq-local vc-buffer-overriding-fileset `(,backend (,file)))
          (setq-local vc-buffer-revision rev)
          (setq-local vc-annotate-parent-display-mode display-mode)
          (kill-local-variable 'revert-buffer-function))))

    (with-current-buffer temp-buffer-name
      (vc-run-delayed
        ;; Ideally, we'd rather not move point if the user has already
        ;; moved it elsewhere, but really point here is not the position
        ;; of the user's cursor :-(
        (when current-line              ;(and (bobp))
          (goto-char (point-min))
          (forward-line (1- current-line))
          (setq vc-sentinel-movepoint (point)))
        (unless (active-minibuffer-window)
          (message "Annotating... done"))))))

(defun vc-annotate-prev-revision (prefix)
  "Visit the annotation of the revision previous to this one.

With a numeric prefix argument, annotate the revision that many
revisions previous."
  (interactive "p")
  (vc-annotate-warp-revision (- 0 prefix)))

(defun vc-annotate-next-revision (prefix)
  "Visit the annotation of the revision after this one.

With a numeric prefix argument, annotate the revision that many
revisions after."
  (interactive "p")
  (vc-annotate-warp-revision prefix))

(defun vc-annotate-working-revision ()
  "Visit the annotation of the working revision of this file."
  (interactive)
  (if (not (equal major-mode 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let ((warp-rev (vc-working-revision (caadr vc-buffer-overriding-fileset))))
      (if (equal warp-rev vc-buffer-revision)
	  (message "Already at revision %s" warp-rev)
	(vc-annotate-warp-revision warp-rev)))))

(defun vc-annotate-extract-revision-at-line ()
  "Extract the revision number of the current line.
Return a cons (REV . FILENAME)."
  ;; This function must be invoked from a buffer in vc-annotate-mode
  (let ((rev (vc-call-backend vc-annotate-backend
			      'annotate-extract-revision-at-line)))
    (if (or (null rev) (consp rev))
	rev
      (cons rev (caadr vc-buffer-overriding-fileset)))))

(defun vc-annotate-revision-at-line ()
  "Visit the annotation of the revision identified in the current line."
  (interactive)
  (if (not (equal major-mode 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let ((rev-at-line (vc-annotate-extract-revision-at-line)))
      (if (not rev-at-line)
	  (message "Cannot extract revision number from the current line")
	(if (and (equal (car rev-at-line) vc-buffer-revision)
		 (string= (cdr rev-at-line) (caadr vc-buffer-overriding-fileset)))
	    (message "Already at revision %s" rev-at-line)
	  (vc-annotate-warp-revision (car rev-at-line) (cdr rev-at-line)))))))

(defun vc-annotate-find-revision-at-line ()
  "Visit the revision identified in the current line."
  (interactive)
  (if (not (equal major-mode 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let ((rev-at-line (vc-annotate-extract-revision-at-line)))
      (if (not rev-at-line)
	  (message "Cannot extract revision number from the current line")
	(switch-to-buffer-other-window
	 (vc-find-revision (cdr rev-at-line) (car rev-at-line) vc-annotate-backend))))))

(defun vc-annotate-revision-previous-to-line ()
  "Visit the annotation of the revision before the revision at line."
  (interactive)
  (if (not (equal major-mode 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let* ((rev-at-line (vc-annotate-extract-revision-at-line))
	   (prev-rev nil)
	   (rev (car rev-at-line))
	   (fname (cdr rev-at-line)))
      (if (not rev-at-line)
	  (message "Cannot extract revision number from the current line")
	(setq prev-rev
              (let ((vc-use-short-revision vc-annotate-use-short-revision))
                (vc-call-backend vc-annotate-backend 'previous-revision
                                 fname rev)))
	(if (not prev-rev)
            (message "No previous revisions")
          (vc-annotate-warp-revision prev-rev fname))))))

(defvar log-view-vc-backend)
(defvar log-view-vc-fileset)
(defvar vc-git-print-log-follow)

(defun vc-annotate-show-log-revision-at-line ()
  "Visit the log of the revision at line.
If the VC backend supports it, only show the log entry for the revision.
If a *vc-change-log* buffer exists and already shows a log for
the file in question, search for the log entry required and move point."
  (interactive)
  (if (not (equal major-mode 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let ((rev-at-line (vc-annotate-extract-revision-at-line)))
      (if (not rev-at-line)
	  (message "Cannot extract revision number from the current line")
	(let ((backend vc-annotate-backend)
	      (log-buf (get-buffer "*vc-change-log*"))
              ;; No need to follow renames: we specify the historical file name.
              vc-git-print-log-follow
	      pos)
	  (if (and
	       log-buf
	       ;; Look for a log buffer that already displays the correct file.
	       (with-current-buffer log-buf
		 (and (eq backend log-view-vc-backend)
		      (null (cdr log-view-vc-fileset))
		      (string= (car log-view-vc-fileset) (cdr rev-at-line))
		      ;; Check if the entry we require can be found.
		      (vc-call-backend
		       backend 'show-log-entry (car rev-at-line))
		      (setq pos (point)))))
	      (progn
		(pop-to-buffer log-buf)
		(goto-char pos))
	    ;; Ask the backend to display a single log entry.
	    (vc-print-log-internal
	     vc-annotate-backend (list (cdr rev-at-line))
	     (car rev-at-line) t 1)))))))

(defun vc-annotate-show-diff-revision-at-line-internal (filediff)
  (defvar vc-allow-async-diff)
  (if (not (derived-mode-p 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let* ((rev-at-line (vc-annotate-extract-revision-at-line))
           (prev-rev nil)
           (rev (car rev-at-line))
           (fname (cdr rev-at-line)))
      (if (not rev-at-line)
	  (message "Cannot extract revision number from the current line")
	(setq prev-rev
              (let ((vc-use-short-revision vc-annotate-use-short-revision))
                (vc-call-backend vc-annotate-backend 'previous-revision
                                 (if filediff fname nil) rev)))
	(vc-diff-internal
         vc-allow-async-diff
         ;; The value passed here should follow what
         ;; `vc-deduce-fileset' returns.
         (list vc-annotate-backend
               (if filediff
                   (list fname)
                 nil))
         prev-rev rev)))))

(defun vc-annotate-show-diff-revision-at-line ()
  "Visit the diff of the revision at line from its previous revision."
  (interactive)
  (vc-annotate-show-diff-revision-at-line-internal t))

(defun vc-annotate-show-changeset-diff-revision-at-line ()
  "Show the diffs of revision at current line relative to previous revision.
This is done for all files in changeset."
  (interactive)
  (when (eq 'file (vc-call-backend vc-annotate-backend 'revision-granularity))
    (error "The %s backend does not support changeset diffs" vc-annotate-backend))
  ;; Make sure `diff-goto-source' will be able to find all files.
  (let ((default-directory (vc-call-backend vc-annotate-backend
                                            'root default-directory)))
    (vc-annotate-show-diff-revision-at-line-internal nil)))

(defun vc-annotate-warp-revision (revspec &optional file)
  "Annotate the revision described by REVSPEC.

If REVSPEC is a positive integer, warp that many revisions forward,
if possible, otherwise echo a warning message.  If REVSPEC is a
negative integer, warp that many revisions backward, if possible,
otherwise echo a warning message.  If REVSPEC is a string, then it
describes a revision number, so warp to that revision."
  (if (not (equal major-mode 'vc-annotate-mode))
      (message "Cannot be invoked outside of a vc annotate buffer")
    (let* ((buf (current-buffer))
	   (oldline (line-number-at-pos))
	   (revspeccopy revspec)
	   (newrev nil))
      (cond
       ((and (integerp revspec) (> revspec 0))
	(setq newrev vc-buffer-revision)
        (let ((vc-use-short-revision vc-annotate-use-short-revision))
	  (while (and (> revspec 0) newrev)
            (setq newrev
                  (vc-call-backend vc-annotate-backend 'next-revision
                                   (or file
                                       (caadr vc-buffer-overriding-fileset))
                                   newrev))
            (setq revspec (1- revspec))))
	(unless newrev
	  (message "Cannot increment %d revisions from revision %s"
		   revspeccopy vc-buffer-revision)))
       ((and (integerp revspec) (< revspec 0))
	(setq newrev vc-buffer-revision)
        (let ((vc-use-short-revision vc-annotate-use-short-revision))
	  (while (and (< revspec 0) newrev)
            (setq newrev
                  (vc-call-backend vc-annotate-backend 'previous-revision
                                   (or file
                                       (caadr vc-buffer-overriding-fileset))
                                   newrev))
            (setq revspec (1+ revspec))))
	(unless newrev
	  (message "Cannot decrement %d revisions from revision %s"
		   (- 0 revspeccopy) vc-buffer-revision)))
       ((stringp revspec) (setq newrev revspec))
       (t (error "Invalid argument to vc-annotate-warp-revision")))
      (when newrev
	(vc-annotate (or file
                         (caadr vc-buffer-overriding-fileset))
                     newrev
                     vc-annotate-parent-display-mode
                     buf
		     ;; Pass the current line so that vc-annotate will
		     ;; place the point in the line.
		     (min oldline (progn (goto-char (point-max))
                                         (forward-line -1)
                                         (line-number-at-pos)))
		     vc-annotate-backend)))))

(defun vc-annotate-compcar (threshold a-list)
  "Test successive cons cells of A-LIST against THRESHOLD.
Return the first cons cell with a car that is not less than THRESHOLD,
nil if no such cell exists."
 (let ((i 1)
       (tmp-cons (car a-list)))
   (while (and tmp-cons (< (car tmp-cons) threshold))
     (setq tmp-cons (car (nthcdr i a-list)))
     (setq i (+ i 1)))
   tmp-cons))				; Return the appropriate value

(defun vc-annotate-convert-time (&optional time)
  "Convert optional value TIME to a floating-point number of days.
TIME defaults to the current time."
  (/ (float-time time) 86400))

(defun vc-annotate-difference (&optional offset)
  "Return the time span in days to the next annotation.
This calls the backend function annotate-time, and returns the
difference in days between the time returned and the current time,
or OFFSET if present."
   (let ((next-time (vc-annotate-get-time-set-line-props)))
     (when next-time
       (- (or offset
	      (vc-call-backend vc-annotate-backend 'annotate-current-time))
	  next-time))))

(defun vc-default-annotate-current-time (_backend)
  "Return the current time, encoded as fractional days."
  (vc-annotate-convert-time))

(defvar vc-annotate-offset nil)

(defun vc-annotate-display (ratio &optional offset)
  "Highlight `vc-annotate' output in the current buffer.
RATIO is the expansion that should be applied to `vc-annotate-color-map'.
The annotations are relative to the current time, unless overridden by OFFSET."
  (when (/= ratio 1.0)
    (setq-local vc-annotate-color-map
	 (mapcar (lambda (elem) (cons (* (car elem) ratio) (cdr elem)))
		 vc-annotate-color-map)))
  (setq-local vc-annotate-offset offset)
  (font-lock-mode 1))

(defun vc-annotate-lines (limit)
  (while (< (point) limit)
    (let ((difference (vc-annotate-difference vc-annotate-offset))
          (start (point))
          (end (progn (forward-line 1) (point))))
      (when difference
        (let* ((color (or (vc-annotate-compcar difference vc-annotate-color-map)
                          (cons nil vc-annotate-very-old-color)))
               ;; substring from index 1 to remove any leading `#' in the name
               (face (intern (concat "vc-annotate-face-"
                                     (if (string-equal
                                          (substring (cdr color) 0 1) "#")
                                         (substring (cdr color) 1)
                                       (cdr color)))))
               ;; Make the face if not done.
               (face (if (facep face)
                         face
                       (make-face face)
                       (set-face-extend face t)
                       (cond
                        (vc-annotate-background-mode
                         (set-face-background face (cdr color)))
                        (t
                         (set-face-foreground face (cdr color))
                         (when vc-annotate-background
			   (set-face-background face vc-annotate-background))))
                       face)))
          (put-text-property start end 'face face)))))
  ;; Pretend to font-lock there were no matches.
  nil)

(defun vc-annotate-goto-line ()
  "Go to the line corresponding to the current VC Annotate line."
  (interactive)
  (unless (eq major-mode 'vc-annotate-mode)
    (error "Not in a VC-Annotate buffer"))
  (let ((line (save-restriction
		(widen)
		(line-number-at-pos)))
	(rev vc-buffer-revision)
        (file (caadr vc-buffer-overriding-fileset)))
    (pop-to-buffer
     (or (and (buffer-live-p vc-parent-buffer)
	      vc-parent-buffer)
	 (and (file-exists-p file) (find-file-noselect file))
	 (error "File not found: %s" file)))
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- line))
      (recenter))
    ;; Issue a warning if the lines might be incorrect.
    (cond
     ((buffer-modified-p)
      (message "Buffer modified; annotated line numbers may be incorrect"))
     ((not (eq (vc-state buffer-file-name) 'up-to-date))
      (message "File is not up-to-date; annotated line numbers may be incorrect"))
     ((not (equal rev (vc-working-revision buffer-file-name)))
      (message "Annotations were for revision %s; line numbers may be incorrect"
	       rev)))))

(provide 'vc-annotate)

;;; vc-annotate.el ends here
