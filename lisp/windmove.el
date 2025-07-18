;;; windmove.el --- directional window-selection routines  -*- lexical-binding:t -*-

;; Copyright (C) 1998-2025 Free Software Foundation, Inc.

;; Author: Hovav Shacham <hovav@cs.stanford.edu>
;; Created: 17 October 1998
;; Keywords: window, movement, convenience

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
;; This package defines a set of routines, windmove-{left,up,right,
;; down}, for selection of windows in a frame geometrically.  For
;; example, `windmove-right' selects the window immediately to the
;; right of the currently-selected one.  This functionality is similar
;; to the window-selection controls of the BRIEF editor of yore.
;;
;; One subtle point is what happens when the window to the right has
;; been split vertically; for example, consider a call to
;; `windmove-right' in this setup:
;;
;;                    -------------
;;                    |      | A  |
;;                    |      |    |
;;                    |      |-----
;;                    | *    |    |    (* is point in the currently
;;                    |      | B  |     selected window)
;;                    |      |    |
;;                    -------------
;;
;; There are (at least) three reasonable things to do:
;; (1) Always move to the window to the right of the top edge of the
;;     selected window; in this case, this policy selects A.
;; (2) Always move to the window to the right of the bottom edge of
;;     the selected window; in this case, this policy selects B.
;; (3) Move to the window to the right of point in the selected
;;     window.  This may select either A or B, depending on the
;;     position of point; in the illustrated example, it would select
;;     B.
;;
;; Similar issues arise for all the movement functions.  Windmove
;; resolves this problem by allowing the user to specify behavior
;; through a prefix argument.  The cases are thus:
;; * if no argument is given to the movement functions, or the
;;   argument given is zero, movement is relative to point;
;; * if a positive argument is given, movement is relative to the top
;;   or left edge of the selected window, depending on whether the
;;   movement is to be horizontal or vertical;
;; * if a negative argument is given, movement is relative to the
;;   bottom or right edge of the selected window, depending on whether
;;   the movement is to be horizontal or vertical.
;;
;;
;; Another feature enables wrap-around mode when the variable
;; `windmove-wrap-around' is set to a non-nil value.  In this mode,
;; movement that falls off the edge of the frame will wrap around to
;; find the window on the opposite side of the frame.  Windmove does
;; the Right Thing about the minibuffer; for example, consider:
;;
;;                    -------------
;;                    |    *      |
;;                    |-----------|
;;                    |     A     |
;;                    |-----------|    (* is point in the currently
;;                    |  B   | C  |     selected window)
;;                    |      |    |
;;                    -------------
;;
;; With wraparound enabled, windmove-down will move to A, while
;; windmove-up will move to the minibuffer if it is active, or to
;; either B or C depending on the prefix argument.
;;
;;
;; A set of default keybindings is supplied: shift-{left,up,right,down}
;; invoke the corresponding Windmove function.  See the installation
;; section if you wish to use these keybindings.


;; Installation:
;;
;; Put the following line in your init file:
;;
;;     (windmove-default-keybindings)         ; shifted arrow keys
;;
;; or
;;
;;     (windmove-default-keybindings 'hyper)  ; etc.
;;
;; to use another modifier key.
;;
;;
;; If you wish to enable wrap-around, also add a line like:
;;
;;    (setq windmove-wrap-around t)
;;

;; Acknowledgments:
;;
;; Special thanks to Julian Assange (proff@iq.org), whose
;; change-windows-intuitively.el predates Windmove, and provided the
;; inspiration for it.  Kin Cho (kin@symmetrycomm.com) was the first
;; to suggest wrap-around behavior.  Thanks also to Gerd Moellmann
;; (gerd@gnu.org) for his comments and suggestions.

;;; Code:


;; User configurable variables:

;; For customize ...
(defgroup windmove nil
  "Directional selection of windows in a frame."
  :prefix "windmove-"
  :version "21.1"
  :group 'windows
  :group 'convenience)


(defcustom windmove-wrap-around nil
  "Whether movement off the edge of the frame wraps around.
If this variable is set to t, moving left from the leftmost window in
a frame will find the rightmost one, and similarly for the other
directions.  The minibuffer is skipped over in up/down movements if it
is inactive."
  :type 'boolean)

(defcustom windmove-create-window nil
  "Whether movement off the edge of the frame creates a new window.
If this variable is set to t, moving left from the leftmost window in
a frame will create a new window on the left, and similarly for the other
directions.
This variable may also be a function to be called in this circumstance
by `windmove-do-window-select'.  The function should accept then as
argument the DIRECTION targeted, an interactive ARG and a WINDOW
corresponding to the currently selected window.  It should also return
a valid window that `windmove-do-window-select' will select,
or the symbol `no-select' to ignore that final selection."
  :type '(choice
          (const :tag "Don't create new windows" nil)
          (const :tag "Create new windows" t)
          (function :tag "Provide a function"))
  :version "28.1")

;; If your Emacs sometimes places an empty column between two adjacent
;; windows, you may wish to set this delta to 2.
(defcustom windmove-window-distance-delta 1
  "How far away from the current window to look for an adjacent window.
Measured in characters either horizontally or vertically; setting this
to a value larger than 1 may be useful in getting around window-
placement bugs in old versions of Emacs."
  :type 'number)
(make-obsolete-variable 'windmove-window-distance-delta
                        "no longer used." "27.1")

(defcustom windmove-allow-all-windows nil
  "Whether the windmove commands are allowed to target all type of windows.
If this variable is set to non-nil, all windmove commands will
ignore the `no-other-window' parameter applied by `display-buffer-alist'
or `set-window-parameter'.

Another way to move into windows with the no-other-window property is
by invoking the same movement command twice in succession when
`windmove-allow-repeated-command-override' is true."
  :type 'boolean
  :version "28.1")

(defcustom windmove-allow-repeated-command-override t
  "If non-nil, using windmove commands twice overrides `no-other-window'.
Normally, the `no-other-window' window property prevents windmove
commands from moving to that window.  When this variable is non-nil,
invoking the command twice means the second invocation ignores the
property."
  :type 'boolean
  :version "31.1")


;; Note:
;;
;; The functions that follow were used in the implementation of
;; `windmove-find-other-window', but they are known to be unreliable
;; after the window and frame rework done in 2013, so they are no
;; longer used or maintained; their functionality is subsumed in the
;; new function `window-in-direction'.  They are kept only for
;; compatibility and will be removed in the future.  Please consider
;; using the new window interfaces documented in "(elisp)Windows".

;; Quick & dirty utility function to add two (x . y) coords.
(defun windmove-coord-add (coord1 coord2)
  "Add the two coordinates.
Both COORD1 and COORD2 are coordinate cons pairs, (HPOS . VPOS).  The
result is another coordinate cons pair."
  (declare (obsolete "no longer used." "27.1"))
  (cons (+ (car coord1) (car coord2))
        (+ (cdr coord1) (cdr coord2))))

(defun windmove-constrain-to-range (n min-n max-n)
  "Ensure that N is between MIN-N and MAX-N inclusive by constraining.
If N is less than MIN-N, return MIN-N; if greater than MAX-N, return
MAX-N."
  (declare (obsolete "no longer used." "27.1"))
  (max min-n (min n max-n)))

(defun windmove-constrain-around-range (n min-n max-n)
  "Ensure that N is between MIN-N and MAX-N inclusive by wrapping.
If N is less than MIN-N, return MAX-N; if greater than MAX-N, return
MIN-N."
  (declare (obsolete "no longer used." "27.1"))
  (cond
   ((< n min-n) max-n)
   ((> n max-n) min-n)
   (t n)))

(defun windmove-frame-edges (window)
  "Return (X-MIN Y-MIN X-MAX Y-MAX) for the frame containing WINDOW.
If WINDOW is nil, return the edges for the selected frame.
\(X-MIN, Y-MIN) is the zero-based coordinate of the top-left corner
of the frame; (X-MAX, Y-MAX) is the zero-based coordinate of the
bottom-right corner of the frame.
For example, if a frame has 76 rows and 181 columns, the return value
from `windmove-frame-edges' will be the list (0 0 180 75)."
  (declare (obsolete "no longer used." "27.1"))
  (window-edges (frame-root-window window)))

(defun windmove-constrain-loc-for-movement (coord window dir)
  "Constrain COORD so that it is reasonable for the given movement.
This involves two things: first, make sure that the \"off\" coordinate
-- the one not being moved on, e.g., y for horizontal movement -- is
within frame boundaries; second, if the movement is down and we're not
moving from the minibuffer, make sure that the y coordinate does not
exceed the frame max-y, so that we don't overshoot the minibuffer
accidentally.  WINDOW is the window that movement is relative to; DIR
is the direction of the movement, one of `left', `up', `right',
or `down'.
Returns the constrained coordinate."
  (declare (obsolete "no longer used." "27.1"))
  (with-suppressed-warnings ((obsolete windmove-frame-edges
                                       windmove-constrain-to-range))
    (let ((frame-edges (windmove-frame-edges window))
          (in-minibuffer (window-minibuffer-p window)))
      (let ((min-x (nth 0 frame-edges))
            (min-y (nth 1 frame-edges))
            (max-x (nth 2 frame-edges))
            (max-y (nth 3 frame-edges)))
        (let ((new-x
               (if (memq dir '(up down)) ; vertical movement
                   (windmove-constrain-to-range (car coord) min-x max-x)
                 (car coord)))
              (new-y
               (if (or (memq dir '(left right)) ; horizontal movement
                       (and (eq dir 'down)
                            (not in-minibuffer))) ; don't miss minibuffer
                   ;; (technically, we shouldn't constrain on min-y in the
                   ;; second case, but this shouldn't do any harm on a
                   ;; down movement.)
                   (windmove-constrain-to-range (cdr coord) min-y max-y)
                 (cdr coord))))
          (cons new-x new-y))))))

(defun windmove-wrap-loc-for-movement (coord window)
  "Takes the constrained COORD and wraps it around for the movement.
This makes an out-of-range x or y coordinate and wraps it around the
frame, giving a coordinate (hopefully) in the window on the other edge
of the frame.  WINDOW is the window that movement is relative to (nil
means the currently selected window).  Returns the wrapped coordinate."
  (declare (obsolete "no longer used." "27.1"))
  (with-suppressed-warnings ((obsolete windmove-frame-edges
                                       windmove-constrain-around-range))
    (let* ((frame-edges (windmove-frame-edges window))
           (frame-minibuffer (minibuffer-window (if window
                                                    (window-frame window)
                                                  (selected-frame))))
           (minibuffer-active (minibuffer-window-active-p
                               frame-minibuffer)))
      (let ((min-x (nth 0 frame-edges))
            (min-y (nth 1 frame-edges))
            (max-x (nth 2 frame-edges))
            (max-y (if (not minibuffer-active)
                       (- (nth 3 frame-edges)
                          (window-height frame-minibuffer))
                     (nth 3 frame-edges))))
        (cons
         (windmove-constrain-around-range (car coord) min-x max-x)
         (windmove-constrain-around-range (cdr coord) min-y max-y))))))

(defun windmove-reference-loc (&optional arg window)
  "Return the reference location for directional window selection.
Return a coordinate (HPOS . VPOS) that is frame-based.  If ARG is nil
or not supplied, the reference point is the buffer's point in the
currently-selected window, or WINDOW if supplied; otherwise, it is the
top-left or bottom-right corner of the selected window, or WINDOW if
supplied, if ARG is greater or smaller than zero, respectively."
  (declare (obsolete "no longer used." "27.1"))
  (let ((effective-arg (if (null arg) 0 (prefix-numeric-value arg)))
        (edges (window-inside-edges window)))
    (let ((top-left (cons (nth 0 edges)
                          (nth 1 edges)))
	  ;; Subtracting 1 converts the edge to the last column or line
	  ;; within the window.
          (bottom-right (cons (- (nth 2 edges) 1)
                              (- (nth 3 edges) 1))))
      (cond
       ((> effective-arg 0)
	top-left)
       ((< effective-arg 0)
	bottom-right)
       ((= effective-arg 0)
        (with-suppressed-warnings ((obsolete windmove-coord-add))
	  (windmove-coord-add
	   top-left
	   ;; Don't care whether window is horizontally scrolled -
	   ;; `posn-at-point' handles that already.  See also:
	   ;; https://lists.gnu.org/r/emacs-devel/2012-01/msg00638.html
	   (posn-col-row
	    (posn-at-point (window-point window) window)))))))))

(defun windmove-other-window-loc (dir &optional arg window)
  "Return a location in the window to be moved to.
Return value is a frame-based (HPOS . VPOS) value that should be moved
to.  DIR is one of `left', `up', `right', or `down'; an optional ARG
is handled as by `windmove-reference-loc'; WINDOW is the window that
movement is relative to."
  (declare (obsolete "no longer used." "27.1"))
  (let ((edges (window-edges window))   ; edges: (x0, y0, x1, y1)
        (refpoint (with-suppressed-warnings
                      ((obsolete windmove-reference-loc))
                    (windmove-reference-loc arg window)))) ; (x . y)
    (cond
     ((eq dir 'left)
      (cons (- (nth 0 edges)
               windmove-window-distance-delta)
            (cdr refpoint)))            ; (x0-d, y)
     ((eq dir 'up)
      (cons (car refpoint)
            (- (nth 1 edges)
               windmove-window-distance-delta))) ; (x, y0-d)
     ((eq dir 'right)
      (cons (+ (1- (nth 2 edges))	; -1 to get actual max x
               windmove-window-distance-delta)
            (cdr refpoint)))            ; (x1+d-1, y)
     ((eq dir 'down)			; -1 to get actual max y
      (cons (car refpoint)
            (+ (1- (nth 3 edges))
               windmove-window-distance-delta))) ; (x, y1+d-1)
     (t (error "Invalid direction of movement: %s" dir)))))


;; Rewritten on 2013-12-13 using `window-in-direction'.  After the
;; pixelwise change the old approach didn't work any more.  martin
(defun windmove-find-other-window (dir &optional arg window)
  "Return the window object in direction DIR as seen from WINDOW.
DIR is one of `left', `up', `right', or `down'.
WINDOW must be a live window and defaults to the selected one.
Optional ARG, if negative, means to use the right or bottom edge of
WINDOW as reference position, instead of `window-point'; if positive,
use the left or top edge of WINDOW as reference point."
  (window-in-direction dir window windmove-allow-all-windows
                       arg windmove-wrap-around t))

;; Selects the window that's hopefully at the location returned by
;; `windmove-find-other-window', or screams if there's no window there.
(defun windmove-do-window-select (dir &optional arg window calling-command)
  "Move to the window at direction DIR as seen from WINDOW.
DIR, ARG, and WINDOW are handled as by `windmove-find-other-window'.
If no window is at direction DIR, an error is signaled.
If `windmove-create-window' is a function, call that function with
DIR, ARG and WINDOW.  If it is non-nil, try to create a new window
in direction DIR instead.

When the same windmove command is invoked twice in succession,
the second invocation will override the `no-other-window' property.
CALLING-COMMAND is the command that called this function, used to detect
repeated commands."
  (let* ((repeated-command
          (and calling-command
               windmove-allow-repeated-command-override
               (eq last-command
                   (intern (format "%s-override" calling-command)))))
         (other-window (windmove-find-other-window dir arg window)))

    (when (and (null other-window) repeated-command)
      (setf other-window (window-in-direction dir window t arg windmove-wrap-around t)))

    ;; Create window if needed
    (when (and windmove-create-window
               (or (null other-window)
                   (and (window-minibuffer-p other-window)
                        (not (minibuffer-window-active-p other-window)))))
      (setf other-window
            (if (functionp windmove-create-window)
                (funcall windmove-create-window dir arg window)
              (split-window window nil dir))))

    ;; If we still don't have a window but could with allow-all-windows,
    ;; fail with a helpful message.
    (when (and (null other-window)
               calling-command
               (not windmove-allow-all-windows)
               (not repeated-command)
               windmove-allow-repeated-command-override)
      (let ((test-window (window-in-direction dir window t arg windmove-wrap-around t)))
        (when test-window
          ;; Remember that we stopped at a boundary so we don't override
          ;; a no-other-window before telling the user about it during a
          ;; multi-command movement sequence.
          (setf this-command
                (intern (format "%s-override" calling-command)))
          (user-error "No window %s (repeat to override)" dir))))

    (cond ((null other-window)
           (user-error "No window %s from selected window" dir))
          ((eq other-window 'no-select))
          ((and (window-minibuffer-p other-window)
                (not (minibuffer-window-active-p other-window)))
           (user-error "Minibuffer is inactive"))
          (t
           (select-window other-window)))))


;;; End-user functions
;; These are all simple interactive wrappers to
;; `windmove-do-window-select', meant to be bound to keys.

;;;###autoload
(defun windmove-left (&optional arg is-interactive)
  "Select the window to the left of the current one.
With no prefix argument, or with prefix argument equal to zero,
\"left\" is relative to the position of point in the window; otherwise
it is relative to the top edge (for positive ARG) or the bottom edge
\(for negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created.

If `windmove-allow-repeated-command-override' is true and this commnad
stopped because it wouldn't move into a window marked with
`no-other-window', repeating the command will move into that window."
  (interactive "P\np")
  (windmove-do-window-select
   'left (and arg (prefix-numeric-value arg)) nil
   (and is-interactive this-command)))

;;;###autoload
(defun windmove-up (&optional arg is-interactive)
  "Select the window above the current one.
With no prefix argument, or with prefix argument equal to zero, \"up\"
is relative to the position of point in the window; otherwise it is
relative to the left edge (for positive ARG) or the right edge (for
negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created.

If `windmove-allow-repeated-command-override' is true and this commnad
stopped because it wouldn't move into a window marked with
`no-other-window', repeating the command will move into that window."
  (interactive "P\np")
  (windmove-do-window-select
   'up (and arg (prefix-numeric-value arg)) nil
   (and is-interactive this-command)))

;;;###autoload
(defun windmove-right (&optional arg is-interactive)
  "Select the window to the right of the current one.
With no prefix argument, or with prefix argument equal to zero,
\"right\" is relative to the position of point in the window;
otherwise it is relative to the top edge (for positive ARG) or the
bottom edge (for negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created.

If `windmove-allow-repeated-command-override' is true and this commnad
stopped because it wouldn't move into a window marked with
`no-other-window', repeating the command will move into that window."
  (interactive "P\np")
  (windmove-do-window-select
   'right (and arg (prefix-numeric-value arg)) nil
   (and is-interactive this-command)))

;;;###autoload
(defun windmove-down (&optional arg is-interactive)
  "Select the window below the current one.
With no prefix argument, or with prefix argument equal to zero,
\"down\" is relative to the position of point in the window; otherwise
it is relative to the left edge (for positive ARG) or the right edge
\(for negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created.

If `windmove-allow-repeated-command-override' is true and this commnad
stopped because it wouldn't move into a window marked with
`no-other-window', repeating the command will move into that window."
  (interactive "P\np")
  (windmove-do-window-select
   'down (and arg (prefix-numeric-value arg)) nil
   (and is-interactive this-command)))


;;; set up keybindings
;; Idea for this function is from iswitchb.el, by Stephen Eglen
;; (stephen@cns.ed.ac.uk).
;; I don't think these bindings will work on non-X terminals; you
;; probably want to use different bindings in that case.

(defvar-keymap windmove-mode-map
  :doc "Map used by `windmove-install-defaults'.")

;;;###autoload
(define-minor-mode windmove-mode
  "Global minor mode for default windmove commands."
  :keymap windmove-mode-map
  :init-value t
  :global t)

(defun windmove-install-defaults (prefix modifiers alist &optional uninstall)
  "Install keys as specified by ALIST.
Every element of ALIST has the form (FN KEY), where KEY is
appended to MODIFIERS, adding PREFIX to the beginning, before
installing the key.  Previous bindings of FN are unbound.
If UNINSTALL is non-nil, just remove the keys from ALIST."
  (dolist (bind alist)
    (dolist (old (where-is-internal (car bind) windmove-mode-map))
      (define-key windmove-mode-map old nil))
    (unless uninstall
      (let ((key (vconcat (if (or (equal prefix [ignore])
                                  (eq prefix 'none))
                              nil prefix)
                          (list (append modifiers (cdr bind))))))
        (when (eq (key-binding key) #'self-insert-command)
          (warn "Command %S is shadowing self-insert-key" (car bind)))
        (let ((old-fn (lookup-key windmove-mode-map key)))
          (when (functionp old-fn)
            (warn "Overriding %S with %S" old-fn (car bind))))
        (define-key windmove-mode-map key (car bind))))))

;;;###autoload
(defun windmove-default-keybindings (&optional modifiers)
  "Set up keybindings for `windmove'.
Keybindings are of the form MODIFIERS-{left,right,up,down},
where MODIFIERS is either a list of modifiers or a single modifier.
If MODIFIERS is `none', the keybindings will be directly bound to
the arrow keys.
Default value of MODIFIERS is `shift'."
  (interactive)
  (unless modifiers (setq modifiers 'shift))
  (when (eq modifiers 'none) (setq modifiers nil))
  (setq modifiers (ensure-list modifiers))
  (windmove-install-defaults nil modifiers
                             '((windmove-left left)
                               (windmove-right right)
                               (windmove-up up)
                               (windmove-down down))))


;;; Directional window display and selection

(defcustom windmove-display-no-select nil
  "Whether the window should be selected after displaying the buffer in it.
If nil, then the new window where the buffer is displayed will be selected.
If `ignore', then don't select a window: neither the new nor the old window,
thus allowing the next command to decide what window it selects.
Other non-nil values will reselect the old window that was selected before.

The value of this variable can be overridden by the prefix arg of the
windmove-display-* commands that use `windmove-display-in-direction'.

When `switch-to-buffer-obey-display-actions' is non-nil,
`switch-to-buffer' commands are also supported."
  :type '(choice (const :tag "Select new window" nil)
                 (const :tag "Select old window" t)
                 (const :tag "Don't select a window" ignore))
  :version "27.1")

(defun windmove-display-in-direction (dir &optional arg)
  "Display the next buffer in the window at direction DIR.
The next buffer is the buffer displayed by the next command invoked
immediately after this command (ignoring reading from the minibuffer).
In case of multiple consecutive mouse events such as <down-mouse-1>,
a mouse release event <mouse-1>, <double-mouse-1>, <triple-mouse-1>
all bound commands are handled until one of them displays a buffer.
Create a new window if there is no window in that direction.

By default, select the new window with a displayed buffer.
If `windmove-display-no-select' is `ignore', then allow the next command
to decide what window it selects.  With other non-nil values of
`windmove-display-no-select', this function reselects
a previously selected old window.

If prefix ARG is \\[universal-argument], reselect a previously selected old window.
If `windmove-display-no-select' is non-nil, the meaning of
the prefix argument is reversed and it selects the new window.

When `switch-to-buffer-obey-display-actions' is non-nil,
`switch-to-buffer' commands are also supported."
  (let ((no-select (xor (consp arg) windmove-display-no-select)))
    (display-buffer-override-next-command
     (lambda (_buffer alist)
       (let* ((type 'reuse)
              (window (cond
                       ((eq dir 'new-tab)
                        (let ((tab-bar-new-tab-choice t))
                          (tab-bar-new-tab))
                        (setq type 'tab)
                        (selected-window))
                       ((eq dir 'new-frame)
                        (let* ((params (cdr (assq 'pop-up-frame-parameters alist)))
                               (pop-up-frame-alist (append params pop-up-frame-alist))
                               (frame (make-frame-on-current-monitor
                                       pop-up-frame-alist)))
                          (unless (cdr (assq 'inhibit-switch-frame alist))
	                    (window--maybe-raise-frame frame))
                          (setq type 'frame)
                          (frame-selected-window frame)))
                       ((eq dir 'same-window)
                        (selected-window))
                       (t (window-in-direction
                           dir nil windmove-allow-all-windows
                           (and arg (prefix-numeric-value arg))
                           windmove-wrap-around 'nomini)))))
         (unless window
           (setq window (split-window nil nil dir) type 'window))
         (cons window type)))
     (lambda (old-window new-window)
       (when (and (not (eq windmove-display-no-select 'ignore))
                  (window-live-p (if no-select old-window new-window)))
         (select-window (if no-select old-window new-window))))
     (format "[display-%s]" dir))))

;;;###autoload
(defun windmove-display-left (&optional arg)
  "Display the next buffer in window to the left of the current one.
See the logic of the prefix ARG and `windmove-display-no-select'
in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'left arg))

;;;###autoload
(defun windmove-display-up (&optional arg)
  "Display the next buffer in window above the current one.
See the logic of the prefix ARG and `windmove-display-no-select'
in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'up arg))

;;;###autoload
(defun windmove-display-right (&optional arg)
  "Display the next buffer in window to the right of the current one.
See the logic of the prefix ARG and `windmove-display-no-select'
in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'right arg))

;;;###autoload
(defun windmove-display-down (&optional arg)
  "Display the next buffer in window below the current one.
See the logic of the prefix ARG and `windmove-display-no-select'
in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'down arg))

;;;###autoload
(defun windmove-display-same-window (&optional arg)
  "Display the next buffer in the same window."
  (interactive "P")
  (windmove-display-in-direction 'same-window arg))

;;;###autoload
(defun windmove-display-new-frame (&optional arg)
  "Display the next buffer in a new frame."
  (interactive "P")
  (windmove-display-in-direction 'new-frame arg))

;;;###autoload
(defun windmove-display-new-tab (&optional arg)
  "Display the next buffer in a new tab."
  (interactive "P")
  (windmove-display-in-direction 'new-tab arg))

;;;###autoload
(defun windmove-display-default-keybindings (&optional modifiers)
  "Set up keybindings for directional buffer display.
Keys are bound to commands that display the next buffer in the specified
direction.  Keybindings are of the form MODIFIERS-{left,right,up,down},
where MODIFIERS is either a list of modifiers or a single modifier.
If MODIFIERS is `none', the keybindings will be directly bound to
the arrow keys.
Default value of MODIFIERS is `shift-meta'."
  (interactive)
  (unless modifiers (setq modifiers '(shift meta)))
  (when (eq modifiers 'none) (setq modifiers nil))
  (setq modifiers (ensure-list modifiers))
  (windmove-install-defaults nil modifiers
                             '((windmove-display-left left)
                               (windmove-display-right right)
                               (windmove-display-up up)
                               (windmove-display-down down)
                               (windmove-display-same-window ?0)
                               (windmove-display-new-frame ?f)
                               (windmove-display-new-tab ?t))))


;;; Directional window deletion

(defun windmove-delete-in-direction (dir &optional arg)
  "Delete the window at direction DIR.
If prefix ARG is \\[universal-argument], also kill the buffer in that window.
With \\`M-0' prefix, delete the selected window and
select the window at direction DIR.
When `windmove-wrap-around' is non-nil, takes the window
from the opposite side of the frame."
  (let ((other-window (window-in-direction dir nil windmove-allow-all-windows
                                           arg windmove-wrap-around 'nomini)))
    (cond ((null other-window)
           (user-error "No window %s from selected window" dir))
          (t
           (when (equal arg '(4))
             (kill-buffer (window-buffer other-window)))
           (if (not (equal arg 0))
               (delete-window other-window)
             (delete-window (selected-window))
             (select-window other-window))))))

;;;###autoload
(defun windmove-delete-left (&optional arg)
  "Delete the window to the left of the current one.
If prefix ARG is \\[universal-argument], delete the selected window and
select the window that was to the left of the current one."
  (interactive "P")
  (windmove-delete-in-direction 'left arg))

;;;###autoload
(defun windmove-delete-up (&optional arg)
  "Delete the window above the current one.
If prefix ARG is \\[universal-argument], delete the selected window and
select the window that was above the current one."
  (interactive "P")
  (windmove-delete-in-direction 'up arg))

;;;###autoload
(defun windmove-delete-right (&optional arg)
  "Delete the window to the right of the current one.
If prefix ARG is \\[universal-argument], delete the selected window and
select the window that was to the right of the current one."
  (interactive "P")
  (windmove-delete-in-direction 'right arg))

;;;###autoload
(defun windmove-delete-down (&optional arg)
  "Delete the window below the current one.
If prefix ARG is \\[universal-argument], delete the selected window and
select the window that was below the current one."
  (interactive "P")
  (windmove-delete-in-direction 'down arg))

;;;###autoload
(defun windmove-delete-default-keybindings (&optional prefix modifiers)
  "Set up keybindings for directional window deletion.
Keys are bound to commands that delete windows in the specified
direction.  Keybindings are of the form PREFIX MODIFIERS-{left,right,up,down},
where PREFIX is a prefix key and MODIFIERS is either a list of modifiers or
a single modifier.
If PREFIX is `none', no prefix is used.  If MODIFIERS is `none',
the keybindings are directly bound to the arrow keys.
Default value of PREFIX is \\`C-x' and MODIFIERS is `shift'."
  (interactive)
  (unless prefix (setq prefix '(?\C-x)))
  (when (eq prefix 'none) (setq prefix nil))
  (setq prefix (ensure-list prefix))
  (unless modifiers (setq modifiers '(shift)))
  (when (eq modifiers 'none) (setq modifiers nil))
  (setq modifiers (ensure-list modifiers))
  (windmove-install-defaults prefix modifiers
                             '((windmove-delete-left left)
                               (windmove-delete-right right)
                               (windmove-delete-up up)
                               (windmove-delete-down down))))


;;; Directional window swap states

(defun windmove-swap-states-in-direction (dir)
  "Swap the states of the selected window and the window at direction DIR.
When `windmove-wrap-around' is non-nil, takes the window
from the opposite side of the frame."
  (let ((other-window (window-in-direction dir nil windmove-allow-all-windows
                                           nil windmove-wrap-around 'nomini)))
    (cond ((or (null other-window) (window-minibuffer-p other-window))
           (user-error "No window %s from selected window" dir))
          ((window-minibuffer-p (selected-window))
           (user-error "Can't swap window with the minibuffer"))
          (t
           (window-swap-states nil other-window)))))

;;;###autoload
(defun windmove-swap-states-left ()
  "Swap the states with the window on the left from the current one."
  (interactive)
  (windmove-swap-states-in-direction 'left))

;;;###autoload
(defun windmove-swap-states-up ()
  "Swap the states with the window above from the current one."
  (interactive)
  (windmove-swap-states-in-direction 'up))

;;;###autoload
(defun windmove-swap-states-down ()
  "Swap the states with the window below from the current one."
  (interactive)
  (windmove-swap-states-in-direction 'down))

;;;###autoload
(defun windmove-swap-states-right ()
  "Swap the states with the window on the right from the current one."
  (interactive)
  (windmove-swap-states-in-direction 'right))

;;;###autoload
(defun windmove-swap-states-default-keybindings (&optional modifiers)
  "Set up keybindings for directional window swap states.
Keys are bound to commands that swap the states of the selected window
with the window in the specified direction.  Keybindings are of the form
MODIFIERS-{left,right,up,down}, where MODIFIERS is either a list of modifiers
or a single modifier.
If MODIFIERS is `none', the keybindings will be directly bound to the
arrow keys.
Default value of MODIFIERS is `shift-super'."
  (interactive)
  (unless modifiers (setq modifiers '(shift super)))
  (when (eq modifiers 'none) (setq modifiers nil))
  (setq modifiers (ensure-list modifiers))
  (windmove-install-defaults nil modifiers
                             '((windmove-swap-states-left left)
                               (windmove-swap-states-right right)
                               (windmove-swap-states-up up)
                               (windmove-swap-states-down down))))



(defconst windmove--default-keybindings-type
  `(choice (const :tag "Don't bind" nil)
           (cons :tag "Bind using"
                 (choice (key-sequence :tag "Prefix")
                         (const :tag "No Prefix" nil))
                 (set :tag "Modifier"
                      :greedy t
                      ;; See `(elisp) Keyboard Events'
                      (const :tag "Meta" meta)
                      (const :tag "Control" control)
                      (const :tag "Shift" shift)
                      (const :tag "Hyper" hyper)
                      (const :tag "Super" super)
                      (const :tag "Alt" alt))))
  "Customization type for windmove modifiers.")

(defcustom windmove-default-keybindings nil
  "Default keybindings for regular windmove commands.
See `windmove-default-keybindings' for more detail."
  :set (lambda (sym val)
         (windmove-install-defaults
          (car val) (cdr val)
          '((windmove-left left)
            (windmove-right right)
            (windmove-up up)
            (windmove-down down))
          (null val))
         (set-default sym val))
  :type windmove--default-keybindings-type
  :version "28.1")

(defcustom windmove-display-default-keybindings nil
  "Default keybindings for windmove directional buffer display commands.
See `windmove-display-default-keybindings' for more detail."
  :set (lambda (sym val)
         (windmove-install-defaults
          (car val) (cdr val)
          '((windmove-display-left left)
            (windmove-display-right right)
            (windmove-display-up up)
            (windmove-display-down down)
            (windmove-display-same-window ?0)
            (windmove-display-new-frame ?f)
            (windmove-display-new-tab ?t))
          (null val))
         (set-default sym val))
  :type windmove--default-keybindings-type
  :version "28.1")

(defcustom windmove-delete-default-keybindings nil
  "Default keybindings for windmove directional window deletion commands.
See `windmove-delete-default-keybindings' for more detail."
  :set (lambda (sym val)
         (windmove-install-defaults
          (car val) (cdr val)
          '((windmove-delete-left left)
            (windmove-delete-right right)
            (windmove-delete-up up)
            (windmove-delete-down down))
          (null val))
         (set-default sym val))
  :type windmove--default-keybindings-type
  :version "28.1")

(defcustom windmove-swap-states-default-keybindings nil
  "Default keybindings for windmove's directional window swap-state commands.
See `windmove-swap-states-default-keybindings' for more detail."
  :set (lambda (sym val)
         (windmove-install-defaults
          (car val) (cdr val)
          '((windmove-swap-states-left left)
            (windmove-swap-states-right right)
            (windmove-swap-states-up up)
            (windmove-swap-states-down down))
          (null val))
         (set-default sym val))
  :type windmove--default-keybindings-type
  :version "28.1")


(provide 'windmove)

;;; windmove.el ends here
