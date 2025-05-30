;;; ruler-mode.el --- display a ruler in the header line  -*- lexical-binding: t -*-

;; Copyright (C) 2001-2025 Free Software Foundation, Inc.

;; Author: David Ponce <david@dponce.com>
;; Created: 24 Mar 2001
;; Old-Version: 1.6
;; Keywords: convenience

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

;; This library provides a minor mode to display a ruler in the header
;; line.
;;
;; You can use the mouse to change the `fill-column' `comment-column',
;; `goal-column', `window-margins' and `tab-stop-list' settings:
;;
;; [header-line (shift down-mouse-1)] set left margin end to the ruler
;; graduation where the mouse pointer is on.
;;
;; [header-line (shift down-mouse-3)] set right margin beginning to
;; the ruler graduation where the mouse pointer is on.
;;
;; [header-line down-mouse-2] Drag the `fill-column', `comment-column'
;; or `goal-column' to a ruler graduation.
;;
;; [header-line (control down-mouse-1)] add a tab stop to the ruler
;; graduation where the mouse pointer is on.
;;
;; [header-line (control down-mouse-3)] remove the tab stop at the
;; ruler graduation where the mouse pointer is on.
;;
;; [header-line (control down-mouse-2)] or M-x
;; `ruler-mode-toggle-show-tab-stops' toggle showing and visually
;; editing `tab-stop-list' setting.  The `ruler-mode-show-tab-stops'
;; option controls if the ruler shows tab stops by default.
;;
;; In the ruler the character `ruler-mode-current-column-char' shows
;; the `current-column' location, `ruler-mode-fill-column-char' shows
;; the `fill-column' location, `ruler-mode-comment-column-char' shows
;; the `comment-column' location, `ruler-mode-goal-column-char' shows
;; the `goal-column' and `ruler-mode-tab-stop-char' shows tab stop
;; locations.  Graduations in `window-margins' and `window-fringes'
;; areas are shown with a different foreground color.
;;
;; It is also possible to customize the following characters:
;;
;; - `ruler-mode-basic-graduation-char' character used for basic
;;   graduations ('.' by default).
;; - `ruler-mode-inter-graduation-char' character used for
;;   intermediate graduations ('!' by default).
;;
;; The following faces are customizable:
;;
;; - `ruler-mode-default' the ruler default face.
;; - `ruler-mode-fill-column' the face used to highlight the
;;   `fill-column' character.
;; - `ruler-mode-comment-column' the face used to highlight the
;;   `comment-column' character.
;; - `ruler-mode-goal-column' the face used to highlight the
;;   `goal-column' character.
;; - `ruler-mode-current-column' the face used to highlight the
;;   `current-column' character.
;; - `ruler-mode-tab-stop' the face used to highlight tab stop
;;   characters.
;; - `ruler-mode-margins' the face used to highlight graduations
;;   in the `window-margins' areas.
;; - `ruler-mode-fringes' the face used to highlight graduations
;;   in the `window-fringes' areas.
;; - `ruler-mode-column-number' the face used to highlight the
;;   numbered graduations.
;;
;; `ruler-mode-default' inherits from the built-in `default' face.
;; All `ruler-mode' faces inherit from `ruler-mode-default'.
;;
;; WARNING: To keep ruler graduations aligned on text columns it is
;; important to use the same font family and size for ruler and text
;; areas.
;;
;; You can override the ruler format by defining an appropriate
;; function as the buffer-local value of `ruler-mode-ruler-function'.

;; Installation
;;
;; To automatically display the ruler in specific major modes use:
;;
;;    (add-hook '<major-mode>-hook 'ruler-mode)


;;; Code:
(eval-when-compile
  (require 'wid-edit))
(require 'scroll-bar)
(require 'fringe)

(defgroup ruler-mode nil
  "Display a ruler in the header line."
  :version "22.1"
  :group 'convenience)

(defcustom ruler-mode-show-tab-stops nil
  "If non-nil the ruler shows tab stop positions.
Also allowing to visually change `tab-stop-list' setting using
<C-down-mouse-1> and <C-down-mouse-3> on the ruler to respectively add
or remove a tab stop.  \\[ruler-mode-toggle-show-tab-stops] or
<C-down-mouse-2> on the ruler toggles showing/editing of tab stops."
  :type 'boolean)

;; IMPORTANT: This function must be defined before the following
;; defcustoms because it is used in their :validate clause.
(defun ruler-mode-character-validate (widget)
  "Ensure WIDGET value is a valid character value."
  (save-excursion
    (let ((value (widget-value widget)))
      (unless (characterp value)
        (widget-put widget :error
                    (format "Invalid character value: %S" value))
        widget))))

(defcustom ruler-mode-fill-column-char (if (char-displayable-p ?¶)
                                           ?\¶
                                         ?\|)
  "Character used at the `fill-column' location."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-comment-column-char ?\#
  "Character used at the `comment-column' location."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-goal-column-char ?G
  "Character used at the `goal-column' location."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-current-column-char (if (char-displayable-p ?¦)
                                              ?\¦
                                            ?\@)
  "Character used at the `current-column' location."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-tab-stop-char ?\T
  "Character used at `tab-stop-list' locations."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-basic-graduation-char ?\.
  "Character used for basic graduations."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-inter-graduation-char ?\!
  "Character used for intermediate graduations."
  :type '(choice
          (character :tag "Character")
          (integer :tag "Integer char value"
                   :validate ruler-mode-character-validate)))

(defcustom ruler-mode-set-goal-column-ding-flag t
  "Non-nil means do `ding' when `goal-column' is set."
  :type 'boolean)

(defface ruler-mode-default
  '((((type tty))
     (:inherit default
               :background "grey64"
               :foreground "grey50"
               ))
    (t
     (:inherit default
               :background "grey76"
               :foreground "grey64"
               :box (:color "grey76"
                            :line-width 1
                            :style released-button)
               )))
  "Default face used by the ruler.")

(defface ruler-mode-pad
  '((((type tty))
     (:inherit ruler-mode-default
               :background "grey50"
               ))
    (t
     (:inherit ruler-mode-default
               :background "grey64"
               )))
  "Face used to pad inactive ruler areas.")

(defface ruler-mode-margins
  '((t
     (:inherit ruler-mode-default
               :foreground "white"
               )))
  "Face used to highlight margin areas.")

(defface ruler-mode-fringes
  '((t
     (:inherit ruler-mode-default
               :foreground "green"
               )))
  "Face used to highlight fringes areas.")

(defface ruler-mode-column-number
  '((t
     (:inherit ruler-mode-default
               :foreground "black"
               )))
  "Face used to highlight number graduations.")

(defface ruler-mode-fill-column
  '((t
     (:inherit ruler-mode-default
               :foreground "red"
               )))
  "Face used to highlight the fill column character.")

(defface ruler-mode-comment-column
  '((t
     (:inherit ruler-mode-default
               :foreground "red"
               )))
  "Face used to highlight the comment column character.")

(defface ruler-mode-goal-column
  '((t
     (:inherit ruler-mode-default
               :foreground "red"
               )))
  "Face used to highlight the goal column character.")

(defface ruler-mode-tab-stop
  '((t
     (:inherit ruler-mode-default
               :foreground "steelblue"
               )))
  "Face used to highlight tab stop characters.")

(defface ruler-mode-current-column
  '((t
     (:inherit ruler-mode-default
               :weight bold
               :foreground "yellow"
               )))
  "Face used to highlight the `current-column' character.")


(defsubst ruler-mode-full-window-width ()
  "Return the full width of the selected window."
  (let ((edges (window-edges)))
    (- (nth 2 edges) (nth 0 edges))))

(defsubst ruler-mode-window-col (event)
  "Return a column number relative to the selected window.
EVENT is the mouse event that gives the current column.
If required, account for screen estate taken by `display-line-numbers'."
  (let ((n (car (posn-col-row event))))
    (when display-line-numbers
      ;; FIXME: ruler-mode relies on N being an integer, so if the
      ;; 'line-number' face is customized to use a font that is larger
      ;; or smaller than that of the default face, the alignment might
      ;; be off by up to half a column, unless the font width is an
      ;; integral multiple or divisor of the default face's font.
      (setq n (- n (round (line-number-display-width 'columns)))))
    (- n
       (if (eq (posn-area event) 'header-line)
           (+ (or (car (window-margins)) 0)
              (fringe-columns 'left)
              (scroll-bar-columns 'left))
         0))))

(defun ruler-mode-mouse-set-left-margin (start-event)
  "Set left margin end to the graduation where the mouse pointer is on.
START-EVENT is the mouse click event."
  (interactive "e")
  (let* ((start (event-start start-event))
         (end   (event-end   start-event))
         col w lm rm)
    (when (eq start end) ;; mouse click
      (save-selected-window
        (select-window (posn-window start))
        (setq col (- (car (posn-col-row start))
                     (scroll-bar-columns 'left))
              w   (- (ruler-mode-full-window-width)
                     (scroll-bar-columns 'left)
                     (scroll-bar-columns 'right)))
        (when (and (>= col 0) (< col w))
          (setq lm (window-margins)
                rm (or (cdr lm) 0)
                lm (or (car lm) 0))
          (message "Left margin set to %d (was %d)" col lm)
          (set-window-margins nil col rm))))))

(defun ruler-mode-mouse-set-right-margin (start-event)
  "Set right margin beginning to the graduation where the mouse pointer is on.
START-EVENT is the mouse click event."
  (interactive "e")
  (let* ((start (event-start start-event))
         (end   (event-end   start-event))
         col w lm rm)
    (when (eq start end) ;; mouse click
      (save-selected-window
        (select-window (posn-window start))
        (setq col (- (car (posn-col-row start))
                     (scroll-bar-columns 'left))
              w   (- (ruler-mode-full-window-width)
                     (scroll-bar-columns 'left)
                     (scroll-bar-columns 'right)))
        (when (and (>= col 0) (< col w))
          (setq lm  (window-margins)
                rm  (or (cdr lm) 0)
                lm  (or (car lm) 0)
                col (- w col 1))
          (message "Right margin set to %d (was %d)" col rm)
          (set-window-margins nil lm col))))))

(defvar ruler-mode-dragged-symbol nil
  "Column symbol dragged in the ruler.
That is `fill-column', `comment-column', `goal-column', or nil when
nothing is dragged.")

(defun ruler-mode-text-scaled-width (width)
  "Compute scaled text width according to current font scaling.
Convert a WIDTH of char units into a text-scaled char width units,
for example `window-hscroll'."
  (/ (* width (frame-char-width)) (default-font-width)))

(defun ruler-mode-text-scaled-window-hscroll ()
  "Text scaled `window-hscroll'."
  (ruler-mode-text-scaled-width (window-hscroll)))

(defun ruler-mode-text-scaled-window-width ()
  "Text scaled `window-width'."
  (ruler-mode-text-scaled-width (window-width)))

(defun ruler-mode-mouse-grab-any-column (start-event)
  "Drag a column symbol on the ruler.
Start dragging on mouse down event START-EVENT, and update the column
symbol value with the current value of the ruler graduation while
dragging.  See also the variable `ruler-mode-dragged-symbol'."
  (interactive "e")
  (setq ruler-mode-dragged-symbol nil)
  (let* ((start (event-start start-event))
         col newc oldc)
    (save-selected-window
      (select-window (posn-window start))
      (setq col  (ruler-mode-window-col start)
            newc (+ col (ruler-mode-text-scaled-window-hscroll)))
      (and
       (>= col 0) (< col (ruler-mode-text-scaled-window-width))
       (cond

        ;; Handle the fill column.
        ((eq newc fill-column)
         (setq oldc fill-column
               ruler-mode-dragged-symbol 'fill-column)
         t) ;; Start dragging

        ;; Handle the comment column.
        ((eq newc comment-column)
         (setq oldc comment-column
               ruler-mode-dragged-symbol 'comment-column)
         t) ;; Start dragging

        ;; Handle the goal column.
        ;; A. On mouse down on the goal column character on the ruler,
        ;;    update the `goal-column' value while dragging.
        ;; B. If `goal-column' is nil, set the goal column where the
        ;;    mouse is clicked.
        ;; C. On mouse click on the goal column character on the
        ;;    ruler, unset the goal column.
        ((eq newc goal-column)          ; A. Drag the goal column.
         (setq oldc goal-column
               ruler-mode-dragged-symbol 'goal-column)
         t) ;; Start dragging

        ((null goal-column)             ; B. Set the goal column.
         (setq oldc goal-column
               goal-column newc)
         ;; mouse-2 coming AFTER drag-mouse-2 invokes `ding'.  This
         ;; `ding' flushes the next messages about setting goal
         ;; column.  So here I force fetch the event(mouse-2) and
         ;; throw away.
         (read--potential-mouse-event)
         ;; Ding BEFORE `message' is OK.
         (when ruler-mode-set-goal-column-ding-flag
           (ding))
         (message "Goal column set to %d (click on %s again to unset it)"
                  newc
                  (propertize (char-to-string ruler-mode-goal-column-char)
                              'face 'ruler-mode-goal-column))
         nil) ;; Don't start dragging.
        )
       (if (eq 'click (ruler-mode-mouse-drag-any-column-iteration
                       (posn-window start)))
           (when (eq 'goal-column ruler-mode-dragged-symbol)
             ;; C. Unset the goal column.
             (set-goal-column t))
         ;; At end of dragging, report the updated column symbol.
         (message "%s is set to %d (was %d)"
                  ruler-mode-dragged-symbol
                  (symbol-value ruler-mode-dragged-symbol)
                  oldc))))))

(defun ruler-mode-mouse-drag-any-column-iteration (window)
  "Update the ruler while dragging the mouse.
WINDOW is the window where occurred the last down-mouse event.
Return the symbol `drag' if the mouse has been dragged, or `click' if
the mouse has been clicked."
  (let ((drags 0)
        event)
    (track-mouse
      ;; Signal the display engine to freeze the mouse pointer shape.
      (setq track-mouse 'dragging)
      (while (mouse-movement-p (setq event (read--potential-mouse-event)))
        (setq drags (1+ drags))
        (when (eq window (posn-window (event-end event)))
          (ruler-mode-mouse-drag-any-column event)
          (force-mode-line-update))))
    (if (and (zerop drags) (eq 'click (car (event-modifiers event))))
        'click
      'drag)))

(defun ruler-mode-mouse-drag-any-column (start-event)
  "Update the value of the symbol dragged on the ruler.
Called on each mouse motion event START-EVENT."
  (let* ((start (event-start start-event))
         (end   (event-end   start-event))
         col newc)
    (save-selected-window
      (select-window (posn-window start))
      (setq col  (ruler-mode-window-col end)
            newc (+ col (ruler-mode-text-scaled-window-hscroll)))
      (when (and (>= col 0) (< col (ruler-mode-text-scaled-window-width)))
        (set ruler-mode-dragged-symbol newc)))))

(defun ruler-mode-mouse-add-tab-stop (start-event)
  "Add a tab stop to the graduation where the mouse pointer is on.
START-EVENT is the mouse click event."
  (interactive "e")
  (when ruler-mode-show-tab-stops
    (let* ((start (event-start start-event))
           (end   (event-end   start-event))
           col ts)
      (when (eq start end) ;; mouse click
        (save-selected-window
          (select-window (posn-window start))
          (setq col (ruler-mode-window-col start)
                ts  (+ col (ruler-mode-text-scaled-window-hscroll)))
          (and (>= col 0) (< col (ruler-mode-text-scaled-window-width))
               (not (member ts tab-stop-list))
               (progn
                 (message "Tab stop set to %d" ts)
                 (when (null tab-stop-list)
                   (setq tab-stop-list (indent-accumulate-tab-stops (1- ts))))
                 (setq tab-stop-list (sort (cons ts tab-stop-list) #'<)))))))))

(defun ruler-mode-mouse-del-tab-stop (start-event)
  "Delete tab stop at the graduation where the mouse pointer is on.
START-EVENT is the mouse click event."
  (interactive "e")
  (when ruler-mode-show-tab-stops
    (let* ((start (event-start start-event))
           (end   (event-end   start-event))
           col ts)
      (when (eq start end) ;; mouse click
        (save-selected-window
          (select-window (posn-window start))
          (setq col (ruler-mode-window-col start)
                ts  (+ col (ruler-mode-text-scaled-window-hscroll)))
          (and (>= col 0) (< col (ruler-mode-text-scaled-window-width))
               (member ts tab-stop-list)
               (progn
                 (message "Tab stop at %d deleted" ts)
                 (setq tab-stop-list (delete ts tab-stop-list)))))))))

(defun ruler-mode-toggle-show-tab-stops ()
  "Toggle showing of tab stops on the ruler."
  (interactive)
  (setq ruler-mode-show-tab-stops (not ruler-mode-show-tab-stops))
  (force-mode-line-update))

(defvar-keymap ruler-mode-map
  :doc "Keymap for `ruler-mode'."
  "<header-line> <down-mouse-3>"   #'ignore
  "<header-line> <down-mouse-2>"   #'ruler-mode-mouse-grab-any-column
  "<header-line> S-<down-mouse-1>" #'ruler-mode-mouse-set-left-margin
  "<header-line> S-<down-mouse-3>" #'ruler-mode-mouse-set-right-margin
  "<header-line> C-<down-mouse-1>" #'ruler-mode-mouse-add-tab-stop
  "<header-line> C-<down-mouse-3>" #'ruler-mode-mouse-del-tab-stop
  "<header-line> C-<down-mouse-2>" #'ruler-mode-toggle-show-tab-stops
  "<header-line> S-<mouse-1>"      #'ignore
  "<header-line> S-<mouse-3>"      #'ignore
  "<header-line> C-<mouse-1>"      #'ignore
  "<header-line> C-<mouse-3>"      #'ignore
  "<header-line> C-<mouse-2>"      #'ignore)

(defvar ruler-mode-header-line-format-old nil
  "Hold previous value of `header-line-format'.")

(defvar ruler-mode-ruler-function #'ruler-mode-ruler
  "Function to call to return ruler header line format.
This variable is expected to be made buffer-local by modes.")

(defconst ruler-mode-header-line-format
  '(:eval (funcall ruler-mode-ruler-function))
  "`header-line-format' used in ruler mode.
Call `ruler-mode-ruler-function' to compute the ruler value.")

;;;###autoload
(defvar-local ruler-mode nil
  "Non-nil if Ruler mode is enabled.
Use the command `ruler-mode' to change this variable.")

(defun ruler--save-header-line-format ()
  "Install the header line format for Ruler mode.
Unless Ruler mode is already enabled, save the old header line
format first."
  (when (and (not ruler-mode)
	     (local-variable-p 'header-line-format)
	     (not (local-variable-p 'ruler-mode-header-line-format-old)))
    (setq-local ruler-mode-header-line-format-old
                header-line-format))
  (setq header-line-format ruler-mode-header-line-format))

;;;###autoload
(define-minor-mode ruler-mode
  "Toggle display of ruler in header line (Ruler mode)."
  :group 'ruler-mode
  :variable (ruler-mode
	     . (lambda (enable)
		 (when enable
		   (ruler--save-header-line-format))
		 (setq ruler-mode enable)))
  (if ruler-mode
      (add-hook 'post-command-hook #'force-mode-line-update nil t)
    ;; When `ruler-mode' is off restore previous header line format if
    ;; the current one is the ruler header line format.
    (when (eq header-line-format ruler-mode-header-line-format)
      (kill-local-variable 'header-line-format)
      (when (local-variable-p 'ruler-mode-header-line-format-old)
        (setq header-line-format ruler-mode-header-line-format-old)
        (kill-local-variable 'ruler-mode-header-line-format-old)))
    (remove-hook 'post-command-hook #'force-mode-line-update t)))

;; Add ruler-mode to the minor mode menu in the mode line
(define-key mode-line-mode-menu [ruler-mode]
  '(menu-item "Ruler" ruler-mode
              :button (:toggle . ruler-mode)))

(defconst ruler-mode-ruler-help-echo
  "\
S-mouse-1/3: set L/R margin, \
mouse-2: set goal column, \
C-mouse-2: show tabs"
  "Help string shown when mouse is over the ruler.
`ruler-mode-show-tab-stops' is nil.")

(defconst ruler-mode-ruler-help-echo-when-goal-column
  "\
S-mouse-1/3: set L/R margin, \
C-mouse-2: show tabs"
  "Help string shown when mouse is over the ruler.
`goal-column' is set and `ruler-mode-show-tab-stops' is nil.")

(defconst ruler-mode-ruler-help-echo-when-tab-stops
  "\
C-mouse1/3: set/unset tab, \
C-mouse-2: hide tabs"
  "Help string shown when mouse is over the ruler.
`ruler-mode-show-tab-stops' is non-nil.")

(defconst ruler-mode-fill-column-help-echo
  "drag-mouse-2: set fill column"
  "Help string shown when mouse is on the fill column character.")

(defconst ruler-mode-comment-column-help-echo
  "drag-mouse-2: set comment column"
  "Help string shown when mouse is on the comment column character.")

(defconst ruler-mode-goal-column-help-echo
  "\
drag-mouse-2: set goal column, \
mouse-2: unset goal column"
  "Help string shown when mouse is on the goal column character.")

(defconst ruler-mode-margin-help-echo
  "%s margin %S"
  "Help string shown when mouse is over a margin area.")

(defconst ruler-mode-fringe-help-echo
  "%s fringe %S"
  "Help string shown when mouse is over a fringe area.")

(defsubst ruler-mode-space (width &rest props)
  "Return a single space string of WIDTH times the normal character width.
Optional argument PROPS specifies other text properties to apply."
  (apply #'propertize " " 'display (list 'space :width width) props))

(defun ruler-mode-ruler ()
  "Compute and return a header line ruler."
  (let* ((w (ruler-mode-text-scaled-window-width))
         (m (window-margins))
         (f (window-fringes))
         (i 0)
         (j (ruler-mode-text-scaled-window-hscroll))
         ;; Setup the scrollbar, fringes, and margins areas.
         (lf (ruler-mode-space
              'left-fringe
              'face 'ruler-mode-fringes
              'help-echo (format ruler-mode-fringe-help-echo
                                 "Left" (or (car f) 0))))
         (rf (ruler-mode-space
              'right-fringe
              'face 'ruler-mode-fringes
              'help-echo (format ruler-mode-fringe-help-echo
                                 "Right" (or (cadr f) 0))))
         (lm (ruler-mode-space
              'left-margin
              'face 'ruler-mode-margins
              'help-echo (format ruler-mode-margin-help-echo
                                 "Left" (or (car m) 0))))
         (rm (ruler-mode-space
              'right-margin
              'face 'ruler-mode-margins
              'help-echo (format ruler-mode-margin-help-echo
                                 "Right" (or (cdr m) 0))))
         (sb (ruler-mode-space
              'scroll-bar
              'face 'ruler-mode-pad))
         ;; Remember the scrollbar vertical type.
         (sbvt (car (window-current-scroll-bars)))
         ;; Create a "clean" ruler.
         (ruler
          ;; Make the part of header-line corresponding to the
          ;; line-number display be blank, not filled with
          ;; ruler-mode-basic-graduation-char.
          (if (> i 0)
              (vconcat (make-vector i ?\s)
                       (make-vector (- w i)
                                    ruler-mode-basic-graduation-char))
             (make-vector w ruler-mode-basic-graduation-char)))
         (ruler-wide-props
          `( face ruler-mode-default
             ;; This is redundant with the minor mode map.
             ;;local-map ruler-mode-map
             help-echo ,(cond (ruler-mode-show-tab-stops
                               ruler-mode-ruler-help-echo-when-tab-stops)
                              (goal-column
                               ruler-mode-ruler-help-echo-when-goal-column)
                              (ruler-mode-ruler-help-echo))))
         (props nil)
         k c)
    ;; Setup the active area.
    (while (< i w)
      ;; Graduations.
      (cond
       ;; Show a number graduation.
       ((= (mod j 10) 0)
        (setq c (number-to-string (/ j 10))
              m (length c)
              k i)
        (push `(,i ,(1+ i) face ruler-mode-column-number) props)
        (while (and (> m 0) (>= k 0))
          (aset ruler k (aref c (setq m (1- m))))
          (setq k (1- k))))
       ;; Show an intermediate graduation.
       ((= (mod j 5) 0)
        (aset ruler i ruler-mode-inter-graduation-char)))
      ;; Special columns.
      (cond
       ;; Show the `current-column' marker.
       ((= j (current-column))
        (aset ruler i ruler-mode-current-column-char)
        (push `(,i ,(1+ i) face ruler-mode-current-column) props))
       ;; Show the `goal-column' marker.
       ((and goal-column (= j goal-column))
        (aset ruler i ruler-mode-goal-column-char)
        (push `(,i ,(1+ i)
                   help-echo ,ruler-mode-goal-column-help-echo
                   face ruler-mode-goal-column
                   mouse-face mode-line-highlight)
              props))
       ;; Show the `comment-column' marker.
       ((= j comment-column)
        (aset ruler i ruler-mode-comment-column-char)
        (push `(,i ,(1+ i)
                   help-echo ,ruler-mode-comment-column-help-echo
                   face ruler-mode-comment-column
                   mouse-face mode-line-highlight)
              props))
       ;; Show the `fill-column' marker.
       ((= j fill-column)
        (aset ruler i ruler-mode-fill-column-char)
        (push `(,i ,(1+ i)
                   help-echo ,ruler-mode-fill-column-help-echo
                   face ruler-mode-fill-column
                   mouse-face mode-line-highlight)
              props))
       ;; Show the `tab-stop-list' markers.
       ((and ruler-mode-show-tab-stops (= j (indent-next-tab-stop (1- j))))
        (aset ruler i ruler-mode-tab-stop-char)
        (push `(,i ,(1+ i) face ruler-mode-tab-stop) props)))
      (setq i (1+ i)
            j (1+ j)))

    (let ((ruler-str (concat ruler))
          (len (length ruler)))
      (add-text-properties 0 len ruler-wide-props ruler-str)
      (dolist (p (nreverse props))
        (add-text-properties (nth 0 p) (nth 1 p) (nthcdr 2 p) ruler-str))

      ;; Attach an alignment indent.
      (if display-line-numbers
          (setq ruler-str
                (concat (ruler-mode-space `(,(line-number-display-width t)))
                        ruler-str)))

      ;; Return the ruler propertized string.  Using list here,
      ;; instead of concat visually separate the different areas.
      (if (nth 2 (window-fringes))
          ;; fringes outside margins.
          (list "" (and (eq 'left sbvt) sb) lf lm
                ruler-str rm rf (and (eq 'right sbvt) sb))
        ;; fringes inside margins.
        (list "" (and (eq 'left sbvt) sb) lm lf
              ruler-str rf rm (and (eq 'right sbvt) sb))))))

(provide 'ruler-mode)

;;; ruler-mode.el ends here
