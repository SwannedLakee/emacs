;;; python.el --- Python's flying circus support for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2003-2025 Free Software Foundation, Inc.

;; Author: Fabián E. Gallina <fgallina@gnu.org>
;; Maintainer: emacs-devel@gnu.org
;; URL: https://github.com/fgallina/python.el
;; Version: 0.30
;; Package-Requires: ((emacs "29.1") (compat "29.1.1.0") (seq "2.23") (project "0.1") (flymake "1.0"))
;; Created: Jul 2010
;; Keywords: languages

;; This is a GNU ELPA :core package.  Avoid functionality that is not
;; compatible with the version of Emacs recorded above.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Major mode for editing Python files with some fontification and
;; indentation bits extracted from original Dave Love's python.el
;; found in GNU Emacs.

;; Implements Syntax highlighting, Indentation, Movement, Shell
;; interaction, Shell completion, Shell virtualenv support, Shell
;; package support, Shell syntax highlighting, Pdb tracking, Symbol
;; completion, Skeletons, FFAP, Code Check, ElDoc, Imenu, Flymake,
;; Import management.

;; Syntax highlighting: Fontification of code is provided and supports
;; python's triple quoted strings properly.

;; Indentation: Automatic indentation with indentation cycling is
;; provided, it allows you to navigate different available levels of
;; indentation by hitting <tab> several times.  Also electric-indent-mode
;; is supported such that when inserting a colon the current line is
;; dedented automatically if needed.

;; Movement: `beginning-of-defun' and `end-of-defun' functions are
;; properly implemented.  There are also specialized
;; `forward-sentence' and `backward-sentence' replacements called
;; `python-nav-forward-block', `python-nav-backward-block'
;; respectively which navigate between beginning of blocks of code.
;; Extra functions `python-nav-forward-statement',
;; `python-nav-backward-statement',
;; `python-nav-beginning-of-statement', `python-nav-end-of-statement',
;; `python-nav-beginning-of-block', `python-nav-end-of-block' and
;; `python-nav-if-name-main' are included but no bound to any key.

;; Shell interaction: is provided and allows opening Python shells
;; inside Emacs and executing any block of code of your current buffer
;; in that inferior Python process.

;; Besides that only the standard CPython (2.x and 3.x) shell and
;; IPython are officially supported out of the box, the interaction
;; should support any other readline based Python shells as well
;; (e.g. Jython and PyPy have been reported to work).  You can change
;; your default interpreter and commandline arguments by setting the
;; `python-shell-interpreter' and `python-shell-interpreter-args'
;; variables.  This example enables IPython globally:

;; (setq python-shell-interpreter "ipython"
;;       python-shell-interpreter-args "--simple-prompt")

;; Using the "console" subcommand to start IPython in server-client
;; mode is known to fail intermittently due a bug on IPython itself
;; (see URL `https://debbugs.gnu.org/cgi/bugreport.cgi?bug=18052#27').
;; There seems to be a race condition in the IPython server (A.K.A
;; kernel) when code is sent while it is still initializing, sometimes
;; causing the shell to get stalled.  With that said, if an IPython
;; kernel is already running, "console --existing" seems to work fine.

;; Running IPython on Windows needs more tweaking.  The way you should
;; set `python-shell-interpreter' and `python-shell-interpreter-args'
;; is as follows (of course you need to modify the paths according to
;; your system):

;; (setq python-shell-interpreter "C:/Python27/python.exe"
;;       python-shell-interpreter-args
;;       "-i C:/Python27/Scripts/ipython-script.py")

;; Missing or delayed output used to happen due to differences between
;; Operating Systems' pipe buffering (e.g. CPython 3.3.4 in Windows 7.
;; See URL `https://debbugs.gnu.org/cgi/bugreport.cgi?bug=17304').  To
;; avoid this, the `python-shell-unbuffered' defaults to non-nil and
;; controls whether `python-shell--calculate-process-environment'
;; should set the "PYTHONUNBUFFERED" environment variable on startup:
;; See URL `https://docs.python.org/3/using/cmdline.html#cmdoption-u'.

;; The interaction relies upon having prompts for input (e.g. ">>> "
;; and "... " in standard Python shell) and output (e.g. "Out[1]: " in
;; IPython) detected properly.  Failing that Emacs may hang but, in
;; the case that happens, you can recover with \\[keyboard-quit].  To
;; avoid this issue, a two-step prompt autodetection mechanism is
;; provided: the first step is manual and consists of a collection of
;; regular expressions matching common prompts for Python shells
;; stored in `python-shell-prompt-input-regexps' and
;; `python-shell-prompt-output-regexps', and dir-local friendly vars
;; `python-shell-prompt-regexp', `python-shell-prompt-block-regexp',
;; `python-shell-prompt-output-regexp' which are appended to the
;; former automatically when a shell spawns; the second step is
;; automatic and depends on the `python-shell-prompt-detect' helper
;; function.  See its docstring for details on global variables that
;; modify its behavior.

;; Shell completion: hitting tab will try to complete the current
;; word.  The two built-in mechanisms depend on Python's readline
;; module: the "native" completion is tried first and is activated
;; when `python-shell-completion-native-enable' is non-nil, the
;; current `python-shell-interpreter' is not a member of the
;; `python-shell-completion-native-disabled-interpreters' variable and
;; `python-shell-completion-native-setup' succeeds; the "fallback" or
;; "legacy" mechanism works by executing Python code in the background
;; and enables auto-completion for shells that do not support
;; receiving escape sequences (with some limitations, i.e. completion
;; in blocks does not work).  The code executed for the "fallback"
;; completion can be found in `python-shell-completion-setup-code' and
;; `python-shell-completion-get-completions'.  Their default values
;; enable completion for both CPython and IPython, and probably any
;; readline based shell (it's known to work with PyPy).  If your
;; Python installation lacks readline (like CPython for Windows),
;; installing pyreadline (URL `https://ipython.org/pyreadline.html')
;; should suffice.  To troubleshoot why you are not getting any
;; completions, you can try the following in your Python shell:

;; >>> import readline, rlcompleter

;; If you see an error, then you need to either install pyreadline or
;; setup custom code that avoids that dependency.

;; By default, the "native" completion uses the built-in rlcompleter.
;; To use other readline completer (e.g. Jedi) or a custom one, you just
;; need to set it in the PYTHONSTARTUP file.  You can set an
;; Emacs-specific completer by testing the environment variable
;; INSIDE_EMACS.

;; Shell virtualenv support: The shell also contains support for
;; virtualenvs and other special environment modifications thanks to
;; `python-shell-process-environment' and `python-shell-exec-path'.
;; These two variables allows you to modify execution paths and
;; environment variables to make easy for you to setup virtualenv rules
;; or behavior modifications when running shells.  Here is an example
;; of how to make shell processes to be run using the /path/to/env/
;; virtualenv:

;; (setq python-shell-process-environment
;;       (list
;;        (format "PATH=%s" (mapconcat
;;                           #'identity
;;                           (reverse
;;                            (cons (getenv "PATH")
;;                                  '("/path/to/env/bin/")))
;;                           ":"))
;;        "VIRTUAL_ENV=/path/to/env/"))
;; (python-shell-exec-path . ("/path/to/env/bin/"))

;; Since the above is cumbersome and can be programmatically
;; calculated, the variable `python-shell-virtualenv-root' is
;; provided.  When this variable is set with the path of the
;; virtualenv to use, `process-environment' and `exec-path' get proper
;; values in order to run shells inside the specified virtualenv.  So
;; the following will achieve the same as the previous example:

;; (setq python-shell-virtualenv-root "/path/to/env/")

;; Also the `python-shell-extra-pythonpaths' variable have been
;; introduced as simple way of adding paths to the PYTHONPATH without
;; affecting existing values.

;; Shell package support: you can enable a package in the current
;; shell so that relative imports work properly using the
;; `python-shell-package-enable' command.

;; Shell remote support: remote Python shells are started with the
;; correct environment for files opened remotely through tramp, also
;; respecting dir-local variables provided `enable-remote-dir-locals'
;; is non-nil.  The logic for this is transparently handled by the
;; `python-shell-with-environment' macro.

;; Shell syntax highlighting: when enabled current input in shell is
;; highlighted.  The variable `python-shell-font-lock-enable' controls
;; activation of this feature globally when shells are started.
;; Activation/deactivation can be also controlled on the fly via the
;; `python-shell-font-lock-toggle' command.

;; Pdb tracking: when you execute a block of code that contains some
;; call to pdb (or ipdb) it will prompt the block of code and will
;; follow the execution of pdb marking the current line with an arrow.

;; Symbol completion: you can complete the symbol at point.  It uses
;; the shell completion in background so you should run
;; `python-shell-send-buffer' from time to time to get better results.

;; Skeletons: skeletons are provided for simple inserting of things like class,
;; def, for, import, if, try, and while.  These skeletons are
;; integrated with abbrev.  If you have `abbrev-mode' activated and
;; `python-skeleton-autoinsert' is set to t, then whenever you type
;; the name of any of those defined and hit SPC, they will be
;; automatically expanded.  As an alternative you can use the defined
;; skeleton commands: `python-skeleton-<foo>'.

;; FFAP: You can find the filename for a given module when using ffap
;; out of the box.  This feature needs an inferior python shell
;; running.

;; Code check: Check the current file for errors with `python-check'
;; using the program defined in `python-check-command'.

;; ElDoc: returns documentation for object at point by using the
;; inferior python subprocess to inspect its documentation.  As you
;; might guessed you should run `python-shell-send-buffer' from time
;; to time to get better results too.

;; Imenu: There are two index building functions to be used as
;; `imenu-create-index-function': `python-imenu-create-index' (the
;; default one, builds the alist in form of a tree) and
;; `python-imenu-create-flat-index'.  See also
;; `python-imenu-format-item-label-function',
;; `python-imenu-format-parent-item-label-function',
;; `python-imenu-format-parent-item-jump-label-function' variables for
;; changing the way labels are formatted in the tree version.

;; Flymake: A Flymake backend, using the pyflakes program by default,
;; is provided.  You can also use flake8 or pylint by customizing
;; `python-flymake-command'.

;; Import management: The commands `python-sort-imports',
;; `python-add-import', `python-remove-import', and
;; `python-fix-imports' automate the editing of import statements at
;; the top of the buffer, which tend to be a tedious task in larger
;; projects.  These commands require that the isort library is
;; available to the interpreter pointed at by `python-interpreter'.
;; The last command also requires pyflakes.  These dependencies can be
;; installed, among other methods, with the following command:
;;
;;     pip install isort pyflakes

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'comint)
(eval-when-compile (require 'subr-x))   ;For `string-empty-p' and `string-join'.
(require 'treesit)
(require 'pcase)
(require 'compat)
(require 'project nil 'noerror)
(require 'seq)

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-induce-sparse-tree "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-prev-sibling "treesit.c")

(add-to-list
 'treesit-language-source-alist
 '(python "https://github.com/tree-sitter/tree-sitter-python"
          :commit "bffb65a8cfe4e46290331dfef0dbf0ef3679de11")
 t)

;; Avoid compiler warnings
(defvar compilation-error-regexp-alist)
(defvar outline-heading-end-regexp)
(defvar treesit-thing-settings)

(autoload 'comint-mode "comint")
(autoload 'help-function-arglist "help-fns")

;;;###autoload
(defconst python--auto-mode-alist-regexp
  ;; (rx (or
  ;;      (seq "." (or "py"
  ;;                   "pth"               ; Python Path Configuration File
  ;;                   "pyi"               ; Python Stub File (PEP 484)
  ;;                   "pyw"))             ; MS-Windows specific extension
  ;;      (seq "/" (or "SConstruct" "SConscript"))) ; SCons Build Files
  ;;     eos)
  "\\(?:\\.\\(?:p\\(?:th\\|y[iw]?\\)\\)\\|/\\(?:SCons\\(?:\\(?:crip\\|truc\\)t\\)\\)\\)\\'"
  )

;;;###autoload
(add-to-list 'auto-mode-alist (cons python--auto-mode-alist-regexp 'python-mode))
;;;###autoload
(add-to-list 'interpreter-mode-alist '("python[0-9.]*" . python-mode))

(defgroup python nil
  "Python Language's flying circus support for Emacs."
  :group 'languages
  :version "24.3"
  :link '(emacs-commentary-link "python"))

(defcustom python-interpreter
  (cond ((executable-find "python") "python")
        (t "python3"))
  "Python interpreter for noninteractive use.
Some Python interpreters also require changes to
`python-interpreter-args'.

To customize the Python interpreter for interactive use, modify
`python-shell-interpreter' instead."
  :version "31.1"
  :type 'string)

(defcustom python-interpreter-args ""
  "Arguments for the Python interpreter for noninteractive use."
  :version "30.1"
  :type 'string)

(defcustom python-2-support nil
  "If non-nil, enable Python 2 support.
Currently only affects highlighting.

After customizing this variable, you must restart Emacs for it to take
effect."
  :version "31.1"
  :type 'boolean
  :safe 'booleanp)


;;; Bindings

(defvar-keymap python-base-mode-map
  :doc "Keymap for `python-base-mode'."
  ;; Movement
  "<remap> <backward-sentence>" #'python-nav-backward-block
  "<remap> <forward-sentence>"  #'python-nav-forward-block
  "<remap> <backward-up-list>"  #'python-nav-backward-up-list
  "<remap> <up-list>"           #'python-nav-up-list
  "<remap> <mark-defun>"        #'python-mark-defun
  "C-c C-j"     #'imenu
  ;; Indent specific
  "DEL"         #'python-indent-dedent-line-backspace
  "<backtab>"   #'python-indent-dedent-line
  "C-c <"       #'python-indent-shift-left
  "C-c >"       #'python-indent-shift-right
  ;; Skeletons
  "C-c C-t c"   #'python-skeleton-class
  "C-c C-t d"   #'python-skeleton-def
  "C-c C-t f"   #'python-skeleton-for
  "C-c C-t i"   #'python-skeleton-if
  "C-c C-t m"   #'python-skeleton-import
  "C-c C-t t"   #'python-skeleton-try
  "C-c C-t w"   #'python-skeleton-while
  ;; Shell interaction
  "C-c C-p"     #'run-python
  "C-c C-s"     #'python-shell-send-string
  "C-c C-e"     #'python-shell-send-statement
  "C-c C-r"     #'python-shell-send-region
  "C-M-x"       #'python-shell-send-defun
  "C-c C-b"     #'python-shell-send-block
  "C-c C-c"     #'python-shell-send-buffer
  "C-c C-l"     #'python-shell-send-file
  "C-c C-z"     #'python-shell-switch-to-shell
  ;; Some util commands
  "C-c C-v"     #'python-check
  "C-c C-f"     #'python-eldoc-at-point
  "C-c C-d"     #'python-describe-at-point
  ;; Import management
  "C-c C-i a"   #'python-add-import
  "C-c C-i f"   #'python-fix-imports
  "C-c C-i r"   #'python-remove-import
  "C-c C-i s"   #'python-sort-imports
  ;; Utilities
  "<remap> <complete-symbol>" #'completion-at-point)

(defvar-keymap python-indent-repeat-map
  :doc "Keymap to repeat Python indentation commands.
Used in `repeat-mode'."
  :repeat t
  "<" #'python-indent-shift-left
  ">" #'python-indent-shift-right)

(defvar subword-mode nil)

(easy-menu-define python-menu python-base-mode-map
  "Menu used for ´python-mode'."
  '("Python"
    :help "Python-specific Features"
    ["Shift region left" python-indent-shift-left :active mark-active
     :help "Shift region left by a single indentation step"]
    ["Shift region right" python-indent-shift-right :active mark-active
     :help "Shift region right by a single indentation step"]
    "-----"
    ["Start of def/class" beginning-of-defun
     :help "Go to start of outermost definition around point"]
    ["End of def/class" end-of-defun
     :help "Go to end of definition around point"]
    ["Mark def/class" mark-defun
     :help "Mark outermost definition around point"]
    ["Jump to def/class" imenu
     :help "Jump to a class or function definition"]
    "-----"
    ("Skeletons")
    "-----"
    ["Start interpreter" run-python
     :help "Run inferior Python process in a separate buffer"]
    ["Switch to shell" python-shell-switch-to-shell
     :help "Switch to running inferior Python process"]
    ["Eval string" python-shell-send-string
     :help "Eval string in inferior Python session"]
    ["Eval block" python-shell-send-block
     :help "Eval block in inferior Python session"]
    ["Eval buffer" python-shell-send-buffer
     :help "Eval buffer in inferior Python session"]
    ["Eval statement" python-shell-send-statement
     :help "Eval statement in inferior Python session"]
    ["Eval region" python-shell-send-region
     :help "Eval region in inferior Python session"]
    ["Eval defun" python-shell-send-defun
     :help "Eval defun in inferior Python session"]
    ["Eval file" python-shell-send-file
     :help "Eval file in inferior Python session"]
    ["Debugger" pdb :help "Run pdb under GUD"]
    "-----"
    ["Check file" python-check
     :help "Check file for errors"]
    ["Help on symbol" python-eldoc-at-point
     :help "Get help on symbol at point"]
    ["Complete symbol" completion-at-point
     :help "Complete symbol before point"]
    "-----"
    ["Add import" python-add-import
     :help "Add an import statement to the top of this buffer"]
    ["Remove import" python-remove-import
     :help "Remove an import statement from the top of this buffer"]
    ["Sort imports" python-sort-imports
     :help "Sort the import statements at the top of this buffer"]
    ["Fix imports" python-fix-imports
     :help "Add missing imports and remove unused ones from the current buffer"]
    "-----"
    ("Toggle..."
     ["Subword Mode" subword-mode
      :style toggle :selected subword-mode
      :help "Toggle subword movement and editing mode"])))

(defvar python-mode-map (make-composed-keymap nil python-base-mode-map)
 "Keymap for `python-mode'.")

(defvar python-ts-mode-map (make-composed-keymap nil python-base-mode-map)
  "Keymap for `python-ts-mode'.")


;;; Python specialized rx

(defmacro python-rx (&rest regexps)
  "Python mode specialized rx macro.
This variant of `rx' supports common Python named REGEXPS."
  `(rx-let ((sp-bsnl (or space (and ?\\ ?\n)))
            (block-start       (seq symbol-start
                                    (or "def" "class" "if" "elif" "else" "try"
                                        "except" "finally" "for" "while" "with"
                                        ;; Python 3.10+ PEP634
                                        "match" "case"
                                        ;; Python 3.5+ PEP492
                                        (and "async" (+ space)
                                             (or "def" "for" "with")))
                                    symbol-end))
            (dedenter          (seq symbol-start
                                    (or "elif" "else" "except" "finally" "case")
                                    symbol-end))
            (block-ender       (seq
                                symbol-start
                                (or
                                 (seq (or
                                       "break" "continue" "pass" "raise" "return")
                                  symbol-end)
                                 (seq
                                  (or
                                   (seq (? (or (seq "os." (? ?_)) "sys.")) "exit")
                                   "quit")
                                  (* space) "("))))
            (decorator         (seq line-start (* space) ?@ (any letter ?_)
                                    (* (any word ?_))))
            (defun             (seq symbol-start
                                    (or "def" "class"
                                        ;; Python 3.5+ PEP492
                                        (and "async" (+ space) "def"))
                                    symbol-end))
            (if-name-main      (seq line-start "if" (+ space) "__name__"
                                    (+ space) "==" (+ space)
                                    (any ?' ?\") "__main__" (any ?' ?\")
                                    (* space) ?:))
            (symbol-name       (seq (any letter ?_) (* (any word ?_))))
            (assignment-target (seq (? ?*)
                                    (* symbol-name ?.) symbol-name
                                    (? ?\[ (+ (not ?\])) ?\])))
            (grouped-assignment-target (seq (? ?*)
                                            (* symbol-name ?.) (group symbol-name)
                                            (? ?\[ (+ (not ?\])) ?\])))
            (open-paren        (or "{" "[" "("))
            (close-paren       (or "}" "]" ")"))
            (simple-operator   (any ?+ ?- ?/ ?& ?^ ?~ ?| ?* ?< ?> ?= ?%))
            (not-simple-operator (not (or simple-operator ?\n)))
            (operator          (or "==" ">="
                                   "**" "//" "<<" ">>" "<=" "!="
                                   "+" "-" "/" "&" "^" "~" "|" "*" "<" ">"
                                   "=" "%"))
            (assignment-operator (or "+=" "-=" "*=" "/=" "//=" "%=" "**="
                                     ">>=" "<<=" "&=" "^=" "|="
                                     "="))
            (string-delimiter  (seq
                                ;; Match even number of backslashes.
                                (or (not (any ?\\ ?\' ?\")) point
                                    ;; Quotes might be preceded by an
                                    ;; escaped quote.
                                    (and (or (not (any ?\\)) point) ?\\
                                         (* ?\\ ?\\) (any ?\' ?\")))
                                (* ?\\ ?\\)
                                ;; Match single or triple quotes of any kind.
                                (group (or  "\"\"\"" "\"" "'''" "'"))))
            (coding-cookie (seq line-start ?# (* space)
                                (or
                                 ;; # coding=<encoding name>
                                 (: "coding" (or ?: ?=) (* space)
                                    (group-n 1 (+ (or word ?-))))
                                 ;; # -*- coding: <encoding name> -*-
                                 (: "-*-" (* space) "coding:" (* space)
                                    (group-n 1 (+ (or word ?-)))
                                    (* space) "-*-")
                                 ;; # vim: set fileencoding=<encoding name> :
                                 (: "vim:" (* space) "set" (+ space)
                                    "fileencoding" (* space) ?= (* space)
                                    (group-n 1 (+ (or word ?-)))
                                    (* space) ":"))))
            (bytes-escape-sequence
             (seq (not "\\")
                  (group (or "\\\\" "\\'" "\\a" "\\b" "\\f"
                             "\\n" "\\r" "\\t" "\\v"
                             (seq "\\" (** 1 3 (in "0-7")))
                             (seq "\\x" hex hex)))))
            (string-escape-sequence
             (or bytes-escape-sequence
                 (seq (not "\\")
                      (or (group-n 1 "\\u" (= 4 hex))
                          (group-n 1 "\\U" (= 8 hex))
                          (group-n 1 "\\N{" (*? anychar) "}"))))))
     (rx ,@regexps)))


;;; Font-lock and syntax

(eval-and-compile
  (defun python-syntax--context-compiler-macro (form type &optional syntax-ppss)
    (pcase type
      (''comment
       `(let ((ppss (or ,syntax-ppss (syntax-ppss))))
          (and (nth 4 ppss) (nth 8 ppss))))
      (''string
       `(let ((ppss (or ,syntax-ppss (syntax-ppss))))
          (and (nth 3 ppss) (nth 8 ppss))))
      (''single-quoted-string
       `(let ((ppss (or ,syntax-ppss (syntax-ppss))))
          (and (characterp (nth 3 ppss)) (nth 8 ppss))))
      (''triple-quoted-string
       `(let ((ppss (or ,syntax-ppss (syntax-ppss))))
          (and (eq t (nth 3 ppss)) (nth 8 ppss))))
      (''paren
       `(nth 1 (or ,syntax-ppss (syntax-ppss))))
      (_ form))))

(defun python-syntax-context (type &optional syntax-ppss)
  "Return non-nil if point is on TYPE using SYNTAX-PPSS.
TYPE can be `comment', `string', `single-quoted-string',
`triple-quoted-string' or `paren'.  It returns the start
character address of the specified TYPE."
  (declare (compiler-macro python-syntax--context-compiler-macro))
  (let ((ppss (or syntax-ppss (syntax-ppss))))
    (pcase type
      ('comment (and (nth 4 ppss) (nth 8 ppss)))
      ('string (and (nth 3 ppss) (nth 8 ppss)))
      ('single-quoted-string (and (characterp (nth 3 ppss)) (nth 8 ppss)))
      ('triple-quoted-string (and (eq t (nth 3 ppss)) (nth 8 ppss)))
      ('paren (nth 1 ppss))
      (_ nil))))

(defun python-syntax-context-type (&optional syntax-ppss)
  "Return the context type using SYNTAX-PPSS.
The type returned can be `comment', `string' or `paren'."
  (let ((ppss (or syntax-ppss (syntax-ppss))))
    (cond
     ((nth 8 ppss) (if (nth 4 ppss) 'comment 'string))
     ((nth 1 ppss) 'paren))))

(defsubst python-syntax-comment-or-string-p (&optional ppss)
  "Return non-nil if PPSS is inside comment or string."
  (nth 8 (or ppss (syntax-ppss))))

(defsubst python-syntax-closing-paren-p ()
  "Return non-nil if char after point is a closing paren."
  (eql (syntax-class (syntax-after (point)))
       (syntax-class (string-to-syntax ")"))))

(defun python-font-lock-syntactic-face-function (state)
  "Return syntactic face given STATE."
  (if (nth 3 state)
      (if (python-info-docstring-p state)
          'font-lock-doc-face
        'font-lock-string-face)
    'font-lock-comment-face))

(defconst python--f-string-start-regexp
  (rx bow
      (or "f" "F" "fr" "Fr" "fR" "FR" "rf" "rF" "Rf" "RF")
      (or "\"" "\"\"\"" "'" "'''"))
  "A regular expression matching the beginning of an f-string.

See URL `https://docs.python.org/3/reference/lexical_analysis.html#string-and-bytes-literals'.")

(defun python--f-string-p (ppss)
  "Return non-nil if the pos where PPSS was found is inside an f-string."
  (and (nth 3 ppss)
       (let* ((spos (1- (nth 8 ppss)))
              (before-quote
               (buffer-substring-no-properties (max (- spos 4) (point-min))
                                               (min (+ spos 2) (point-max)))))
         (and (string-match-p python--f-string-start-regexp before-quote)
              (or (< (point-min) spos)
                  (not (memq (char-syntax (char-before spos)) '(?w ?_))))))))

(defun python--font-lock-f-strings (limit)
  "Mark {...} holes as being code.
Remove the (presumably `font-lock-string-face') `face' property from
the {...} holes that appear within f-strings."
  ;; FIXME: This will fail to properly highlight strings appearing
  ;; within the {...} of an f-string.
  ;; We could presumably fix it by running
  ;; `font-lock-default-fontify-syntactically-region' (as is done in
  ;; `sm-c--cpp-fontify-syntactically', for example) after removing
  ;; the `face' property, but I'm not sure it's worth the effort and
  ;; the risks.
  (let ((ppss (syntax-ppss)))
    (while
        (progn
          (while (and (not (python--f-string-p ppss))
                      (re-search-forward python--f-string-start-regexp limit 'move))
            (setq ppss (syntax-ppss)))
          (< (point) limit))
      (cl-assert (python--f-string-p ppss))
      (let ((send (save-excursion
                   (goto-char (nth 8 ppss))
                   (condition-case nil
                       (progn (let ((forward-sexp-function nil))
                                (forward-sexp 1))
                              (min limit (1- (point))))
                     (scan-error limit)))))
        (while (re-search-forward "{" send t)
          (if (eq ?\{ (char-after))
              (forward-char 1)          ;Just skip over {{
            (let ((beg (match-beginning 0))
                  (end (condition-case nil
                           (let ((forward-sexp-function)
                                 (parse-sexp-ignore-comments))
                             (up-list 1)
                             (min send (point)))
                         (scan-error send))))
              (goto-char end)
              (put-text-property beg end 'face nil))))
        (goto-char (min limit (1+ send)))
        (setq ppss (syntax-ppss))))))

(defconst python--not-raw-bytes-literal-start-regexp
  (rx (or bos (not alnum)) (or "b" "B") (or "\"" "\"\"\"" "'" "'''") eos)
  "A regular expression matching the start of a not-raw bytes literal.")

(defconst python--not-raw-string-literal-start-regexp
  (rx bos (or
           ;; Multi-line string literals
           (seq (? (? (not alnum)) (or "u" "U" "F" "f")) (or "\"\"\"" "'''"))
           (seq (? anychar) (not alnum) (or "\"\"\"" "'''"))
           ;; Single line string literals
           (seq (? (** 0 2 anychar) (not alnum)) (or "u" "U" "F" "f") (or "'" "\""))
           (seq (? (** 0 3 anychar) (not (any "'\"" alnum))) (or "'" "\"")))
      eos)
  "A regular expression matching the start of a not-raw string literal.")

(defun python--string-bytes-literal-matcher (regexp start-regexp)
  "Match REGEXP within a string or bytes literal whose start matches START-REGEXP."
  (lambda (limit)
    (cl-loop for result = (re-search-forward regexp limit t)
             for result-valid = (and
                                 result
                                 (when-let* ((pos (nth 8 (syntax-ppss)))
                                             (before-quote
                                              (buffer-substring-no-properties
                                               (max (- pos 4) (point-min))
                                               (min (+ pos 1) (point-max)))))
                                   (backward-char)
                                   (string-match-p start-regexp before-quote)))
             until (or (not result) result-valid)
             finally return (and result-valid result))))

(defvar python-font-lock-keywords-level-1
  `((,(python-rx symbol-start "def" (1+ space) (group symbol-name))
     (1 font-lock-function-name-face))
    (,(python-rx symbol-start "class" (1+ space) (group symbol-name))
     (1 font-lock-type-face)))
  "Font lock keywords to use in `python-mode' for level 1 decoration.

This is the minimum decoration level, including function and
class declarations.")

(defvar python-font-lock-builtin-types
  '("bool" "bytearray" "bytes" "complex" "dict" "float" "frozenset"
    "int" "list" "memoryview" "range" "set" "str" "tuple"))

(defvar python-font-lock-builtins-python3
  '("abs" "aiter" "all" "anext" "any" "ascii" "bin" "breakpoint"
    "callable" "chr" "classmethod" "compile" "delattr" "dir" "divmod"
    "enumerate" "eval" "exec" "filter" "format" "getattr" "globals"
    "hasattr" "hash" "help" "hex" "id" "input" "isinstance"
    "issubclass" "iter" "len" "locals" "map" "max" "min" "next"
    "object" "oct" "open" "ord" "pow" "print" "property" "repr"
    "reversed" "round" "setattr" "slice" "sorted" "staticmethod" "sum"
    "super" "type" "vars" "zip" "__import__"))

(defvar python-font-lock-builtins-python2
  '("basestring" "cmp" "execfile" "file" "long" "raw_input" "reduce"
    "reload" "unichr" "unicode" "xrange" "apply" "buffer" "coerce"
    "intern"))

(defvar python-font-lock-builtins
  (append python-font-lock-builtins-python3
          (when python-2-support
            python-font-lock-builtins-python2)))

(defvar python-font-lock-special-attributes
  '(;; https://docs.python.org/3/reference/datamodel.html
    "__annotations__" "__bases__" "__closure__" "__code__"
    "__defaults__" "__dict__" "__doc__" "__firstlineno__"
    "__globals__" "__kwdefaults__" "__name__" "__module__"
    "__mro__" "__package__" "__qualname__"
    "__static_attributes__" "__type_params__"
    ;; Extras:
    "__all__"))

(defvar python-font-lock-keywords-level-2
  `(,@python-font-lock-keywords-level-1
    ,(rx symbol-start
         (or
          "and" "del" "from" "not" "while" "as" "elif" "global" "or" "with"
          "assert" "else" "if" "pass" "yield" "break" "except" "import" "class"
          "in" "raise" "continue" "finally" "is" "return" "def" "for" "lambda"
          "try"
          ;; False, None, and True are listed as keywords on the Python 3
          ;; documentation, but since they also qualify as constants they are
          ;; fontified like that in order to keep font-lock consistent between
          ;; Python versions.
          "nonlocal"
          ;; Python 3.5+ PEP492
          (and "async" (+ space) (or "def" "for" "with"))
          "await"
          ;; Python 3.10+
          "match" "case"
          ;; Extra:
          "self")
         symbol-end)
    ;; Builtins
    (,(rx-to-string `(seq symbol-start
                          (or ,@(append python-font-lock-builtin-types
                                        python-font-lock-builtins
                                        python-font-lock-special-attributes))
                          symbol-end)) . font-lock-builtin-face))
  "Font lock keywords to use in `python-mode' for level 2 decoration.

This is the medium decoration level, including everything in
`python-font-lock-keywords-level-1', as well as keywords and
builtins.")

(defun python-font-lock-assignment-matcher (regexp)
  "Font lock matcher for assignments based on REGEXP.
Search for next occurrence if REGEXP matched within a `paren'
context (to avoid, e.g., default values for arguments or passing
arguments by name being treated as assignments) or is followed by
an '=' sign (to avoid '==' being treated as an assignment.  Set
point to the position one character before the end of the
occurrence found so that subsequent searches can detect the '='
sign in chained assignment."
  (lambda (limit)
    (cl-loop while (re-search-forward regexp limit t)
             unless (or (python-syntax-context 'paren)
                        (equal (char-after) ?=))
               return (progn (backward-char) t))))

(defvar python-font-lock-builtin-exceptions-python3
  '(;; Python 2 and 3:
    "ArithmeticError" "AssertionError" "AttributeError" "BaseException"
    "BufferError" "BytesWarning" "DeprecationWarning" "EOFError"
    "EnvironmentError" "Exception" "FloatingPointError" "FutureWarning"
    "GeneratorExit" "IOError" "ImportError" "ImportWarning"
    "IndentationError" "IndexError" "KeyError" "KeyboardInterrupt"
    "LookupError" "MemoryError" "NameError" "NotImplementedError"
    "OSError" "OverflowError" "PendingDeprecationWarning"
    "ReferenceError" "RuntimeError" "RuntimeWarning" "StopIteration"
    "SyntaxError" "SyntaxWarning" "SystemError" "SystemExit" "TabError"
    "TypeError" "UnboundLocalError" "UnicodeDecodeError"
    "UnicodeEncodeError" "UnicodeError" "UnicodeTranslateError"
    "UnicodeWarning" "UserWarning" "ValueError" "Warning"
    "ZeroDivisionError"
    ;; Python 3:
    "BlockingIOError" "BrokenPipeError" "ChildProcessError"
    "ConnectionAbortedError" "ConnectionError" "ConnectionRefusedError"
    "ConnectionResetError" "EncodingWarning" "FileExistsError"
    "FileNotFoundError" "InterruptedError" "IsADirectoryError"
    "NotADirectoryError" "ModuleNotFoundError" "PermissionError"
    "ProcessLookupError" "PythonFinalizationError" "RecursionError"
    "ResourceWarning" "StopAsyncIteration" "TimeoutError"
    "BaseExceptionGroup" "ExceptionGroup"
    ;; OS specific
    "VMSError" "WindowsError"))

(defvar python-font-lock-builtin-exceptions-python2
  '("StandardError"))

(defvar python-font-lock-builtin-exceptions
  (append python-font-lock-builtin-exceptions-python3
          (when python-2-support
            python-font-lock-builtin-exceptions-python2)))

(defvar python-font-lock-keywords-maximum-decoration
  `((python--font-lock-f-strings)
    ,@python-font-lock-keywords-level-2
    ;; Constants
    (,(rx symbol-start
          (or
           "Ellipsis" "False" "None" "NotImplemented" "True" "__debug__"
           ;; copyright, license, credits, quit and exit are added by the site
           ;; module and they are not intended to be used in programs
           "copyright" "credits" "exit" "license" "quit")
          symbol-end)
     . font-lock-constant-face)
    ;; Decorators.
    (,(rx line-start (* (any " \t")) (group "@" (1+ (or word ?_))
                                            (0+ "." (1+ (or word ?_)))))
     (1 font-lock-type-face))
    ;; Builtin Exceptions
    (,(rx-to-string `(seq symbol-start
                          (or ,@python-font-lock-builtin-exceptions)
                          symbol-end)) . font-lock-type-face)
    ;; single assignment with/without type hints, e.g.
    ;;   a: int = 5
    ;;   b: Tuple[Optional[int], Union[Sequence[str], str]] = (None, 'foo')
    ;;   c: Collection = {1, 2, 3}
    ;;   d: Mapping[int, str] = {1: 'bar', 2: 'baz'}
    (,(python-font-lock-assignment-matcher
       (python-rx grouped-assignment-target (* space)
                  (? ?: (* space) (group (+ not-simple-operator)) (* space))
                  (group assignment-operator)))
     (1 font-lock-variable-name-face)
     (3 'font-lock-operator-face)
     (,(python-rx symbol-name)
      (progn
        (when-let* ((type-start (match-beginning 2)))
          (goto-char type-start))
        (match-end 0))
      nil
      (0 font-lock-type-face)))
    ;; multiple assignment
    ;; (note that type hints are not allowed for multiple assignments)
    ;;   a, b, c = 1, 2, 3
    ;;   a, *b, c = 1, 2, 3, 4, 5
    ;;   [a, b] = (1, 2)
    ;;   (l[1], l[2]) = (10, 11)
    ;;   (a, b, c, *d) = *x, y = 5, 6, 7, 8, 9
    ;;   (a,) = 'foo'
    ;;   (*a,) = ['foo', 'bar', 'baz']
    ;;   d.x, d.y[0], *d.z = 'a', 'b', 'c', 'd', 'e'
    ;; and variants thereof
    ;; the cases
    ;;   (a) = 5
    ;;   [a] = 5,
    ;;   [*a] = 5, 6
    ;; are handled separately below
    (,(python-font-lock-assignment-matcher
        (python-rx (? (or "[" "(") (* space))
                   grouped-assignment-target (* space) ?, (* space)
                   (* assignment-target (* space) ?, (* space))
                   (? assignment-target (* space))
                   (? ?, (* space))
                   (? (or ")" "]") (* space))
                   (group assignment-operator)))
     (1 font-lock-variable-name-face)
     (2 'font-lock-operator-face)
     (,(python-rx grouped-assignment-target)
      (progn
        (goto-char (match-end 1))       ; go back after the first symbol
        (match-beginning 2))            ; limit the search until the assignment
      nil
      (1 font-lock-variable-name-face)))
    ;; special cases
    ;;   (a) = 5
    ;;   [a] = 5,
    ;;   [*a] = 5, 6
    (,(python-font-lock-assignment-matcher
       (python-rx (or line-start ?\; ?=) (* space)
                  (or "[" "(") (* space)
                  grouped-assignment-target (* space)
                  (or ")" "]") (* space)
                  (group assignment-operator)))
     (1 font-lock-variable-name-face)
     (2 'font-lock-operator-face))
    ;; Operators.
    (,(python-rx operator) . 'font-lock-operator-face)
    ;; escape sequences within bytes literals
    ;;   "\\" "\'" "\a" "\b" "\f" "\n" "\r" "\t" "\v"
    ;;   "\ooo" character with octal value ooo
    ;;   "\xhh" character with hex value hh
    (,(python--string-bytes-literal-matcher
       (python-rx bytes-escape-sequence)
       python--not-raw-bytes-literal-start-regexp)
     (1 font-lock-constant-face t))
    ;; escape sequences within string literals, the same as appear in bytes
    ;; literals in addition to:
    ;;   "\uxxxx" Character with 16-bit hex value xxxx
    ;;   "\Uxxxxxxxx" Character with 32-bit hex value xxxxxxxx
    ;;   "\N{name}" Character named name in the Unicode database
    (,(python--string-bytes-literal-matcher
       (python-rx string-escape-sequence)
       python--not-raw-string-literal-start-regexp)
     (1 'font-lock-constant-face t)))
  "Font lock keywords to use in `python-mode' for maximum decoration.

This decoration level includes everything in
`python-font-lock-keywords-level-2', as well as constants,
decorators, exceptions, and assignments.")

(defvar python-font-lock-keywords
  '(python-font-lock-keywords-level-1   ; When `font-lock-maximum-decoration' is nil.
    python-font-lock-keywords-level-1   ; When `font-lock-maximum-decoration' is 1.
    python-font-lock-keywords-level-2   ; When `font-lock-maximum-decoration' is 2.
    python-font-lock-keywords-maximum-decoration ; When `font-lock-maximum-decoration'
                                                 ; is more than 1, or t (which it is,
                                                 ; by default).
    )
  "List of font lock keyword specifications to use in `python-mode'.

Which one will be chosen depends on the value of
`font-lock-maximum-decoration'.")


(defconst python-syntax-propertize-function
  (syntax-propertize-rules
   ((rx (or "\"\"\"" "'''"))
    (0 (ignore (python-syntax-stringify))))))

(define-obsolete-variable-alias 'python--prettify-symbols-alist
  'python-prettify-symbols-alist "26.1")

(defvar python-prettify-symbols-alist
  '(("lambda"  . ?λ)
    ("and" . ?∧)
    ("or" . ?∨))
  "Value for `prettify-symbols-alist' in `python-mode'.")

(defsubst python-syntax-count-quotes (quote-char &optional point limit)
  "Count number of quotes around point (max is 3).
QUOTE-CHAR is the quote char to count.  Optional argument POINT is
the point where scan starts (defaults to current point), and LIMIT
is used to limit the scan."
  (let ((i 0))
    (while (and (< i 3)
                (or (not limit) (< (+ point i) limit))
                (eq (char-after (+ point i)) quote-char))
      (setq i (1+ i)))
    i))

(defun python-syntax-stringify ()
  "Put `syntax-table' property correctly on single/triple quotes."
  (let* ((ppss (save-excursion (backward-char 3) (syntax-ppss)))
         (string-start (and (eq t (nth 3 ppss)) (nth 8 ppss)))
         (string-literal-concat (numberp (nth 3 ppss)))
         (quote-starting-pos (- (point) 3))
         (quote-ending-pos (point)))
    (cond ((or (nth 4 ppss)             ;Inside a comment
               (and string-start
                    ;; Inside of a string quoted with different triple quotes.
                    (not (eql (char-after string-start)
                              (char-after quote-starting-pos)))))
           ;; Do nothing.
           nil)
          ((nth 5 ppss)
           ;; The first quote is escaped, so it's not part of a triple quote!
           (goto-char (1+ quote-starting-pos)))
          ;; Handle string literal concatenation (bug#45897)
          (string-literal-concat nil)
          ((null string-start)
           ;; This set of quotes delimit the start of a string.  Put
           ;; string fence syntax on last quote. (bug#49518)
           ;; FIXME: This makes sexp-movement a bit suboptimal since """a"""
           ;; is now treated as 3 strings.
           ;; We could probably have our cake and eat it too by
           ;; putting the string fence on the first quote and then
           ;; convincing `syntax-ppss-flush-cache' to flush to before
           ;; that fence when any char of the 3-char delimiter
           ;; is modified.
           (put-text-property (1- quote-ending-pos) quote-ending-pos
                              'syntax-table (string-to-syntax "|")))
          (t
           ;; This set of quotes delimit the end of a string.  Put
           ;; string fence syntax on first quote. (bug#49518)
           (put-text-property quote-starting-pos (1+ quote-starting-pos)
                              'syntax-table (string-to-syntax "|"))))))

(defvar python-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Give punctuation syntax to ASCII that normally has symbol
    ;; syntax or has word syntax and isn't a letter.
    (let ((symbol (string-to-syntax "_"))
          (sst (standard-syntax-table)))
      (dotimes (i 128)
        (unless (= i ?_)
          (if (equal symbol (aref sst i))
              (modify-syntax-entry i "." table)))))
    (modify-syntax-entry ?$ "." table)
    (modify-syntax-entry ?% "." table)
    ;; exceptions
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?` "$" table)
    table)
  "Syntax table for Python files.")

(defvar python-dotty-syntax-table
  (let ((table (make-syntax-table python-mode-syntax-table)))
    (modify-syntax-entry ?. "w" table)
    (modify-syntax-entry ?_ "w" table)
    table)
  "Dotty syntax table for Python files.
It makes underscores and dots word constituent chars.")

;;; Tree-sitter font-lock

;; NOTE: Tree-sitter and font-lock works differently so this can't
;; merge with `python-font-lock-keywords-level-2'.

(defvar python--treesit-keywords
  '("as" "assert" "async" "await" "break" "case" "class" "continue" "def"
    "del" "elif" "else" "except" "exec" "finally" "for" "from"
    "global" "if" "import" "lambda" "match" "nonlocal" "pass" "print"
    "raise" "return" "try" "while" "with" "yield"
    ;; These are technically operators, but we fontify them as
    ;; keywords.
    "and" "in" "is" "not" "or" "not in" "is not"))

(defvar python--treesit-builtin-types
  python-font-lock-builtin-types)

(defvar python--treesit-type-regex
  (rx-to-string `(seq bol (or
                           ,@python--treesit-builtin-types
                           (seq (?  "_") (any "A-Z") (+ (any "a-zA-Z_0-9"))))
                  eol)))

(defvar python--treesit-builtins
  python-font-lock-builtins)

(defvar python--treesit-constants
  '("Ellipsis" "False" "None" "NotImplemented" "True" "__debug__"
    "copyright" "credits" "exit" "license" "quit"))

(defvar python--treesit-operators
  '("-" "-=" "!=" "*" "**" "**=" "*=" "/" "//" "//=" "/=" "&" "&=" "%" "%="
    "^" "^=" "+" "->" "+=" "<" "<<" "<<=" "<=" "<>" "=" ":=" "==" ">" ">="
    ">>" ">>=" "|" "|=" "~" "@" "@="))

(defvar python--treesit-special-attributes
  python-font-lock-special-attributes)

(defvar python--treesit-exceptions
  python-font-lock-builtin-exceptions)

(defun python--treesit-fontify-string (node override start end &rest _)
  "Fontify string.
NODE is the string node.  Do not fontify the initial f for
f-strings.  OVERRIDE is the override flag described in
`treesit-font-lock-rules'.  START and END mark the region to be
fontified."
  (let* ((maybe-expression (treesit-node-parent node))
         (grandparent (treesit-node-parent
                       (treesit-node-parent
                        maybe-expression)))
         (maybe-defun grandparent)
         (face (if (and (or (member (treesit-node-type maybe-defun)
                                    '("function_definition"
                                      "class_definition"))
                            ;; If the grandparent is null, meaning the
                            ;; string is top-level, and the string has
                            ;; no node or only comment preceding it,
                            ;; it's a BOF docstring.
                            (and (null grandparent)
                                 (cl-loop
                                  for prev = (treesit-node-prev-sibling
                                              maybe-expression)
                                  then (treesit-node-prev-sibling prev)
                                  while prev
                                  if (not (equal (treesit-node-type prev)
                                                 "comment"))
                                  return nil
                                  finally return t)))
                        ;; This check filters out this case:
                        ;; def function():
                        ;;     return "some string"
                        (equal (treesit-node-type maybe-expression)
                               "expression_statement"))
                   'font-lock-doc-face
                 'font-lock-string-face))

         (ignore-interpolation
          (not (seq-some
                (lambda (feats) (memq 'string-interpolation feats))
                (seq-take treesit-font-lock-feature-list
                          (if (fboundp 'treesit--compute-font-lock-level)
                              (treesit--compute-font-lock-level
                               treesit-font-lock-level)
                            treesit-font-lock-level)))))
         ;; If interpolation is enabled, highlight only
         ;; string_start/string_content/string_end children.  Do not
         ;; touch interpolation node that can occur inside of the
         ;; string.
         (string-nodes (if ignore-interpolation
                           (list node)
                         (treesit-filter-child
                          node
                          (lambda (ch) (member (treesit-node-type ch)
                                               '("string_start"
                                                 "string_content"
                                                 "string_end")))
                          t))))

    (dolist (string-node string-nodes)
      (let ((string-beg (treesit-node-start string-node))
            (string-end (treesit-node-end string-node)))
        (when (or ignore-interpolation
                  (equal (treesit-node-type string-node) "string_start"))
          ;; Don't highlight string prefixes like f/r/b.
          (save-excursion
            (goto-char string-beg)
            (when (re-search-forward "[\"']" string-end t)
              (setq string-beg (match-beginning 0)))))

        (treesit-fontify-with-override
         string-beg string-end face override start end)))))

(defun python--treesit-fontify-union-types (node override start end &optional type-regex &rest _)
  "Fontify nested union types in the type hints.
For example, Lvl1 | Lvl2[Lvl3[Lvl4[Lvl5 | None]], Lvl2].  This
structure is represented via nesting binary_operator and
subscript nodes.  This function iterates over all levels and
highlight identifier nodes.  If TYPE-REGEX is not nil fontify type
identifier only if it matches against TYPE-REGEX.  NODE is the
binary_operator node.  OVERRIDE is the override flag described in
`treesit-font-lock-rules'.  START and END mark the region to be
fontified."
  (dolist (child (treesit-node-children node t))
    (let (font-node)
      (pcase (treesit-node-type child)
        ((or "identifier" "none")
         (setq font-node child))
        ("attribute"
         (when-let* ((type-node (treesit-node-child-by-field-name child "attribute")))
           (setq font-node type-node)))
        ((or "binary_operator" "subscript")
         (python--treesit-fontify-union-types child override start end type-regex)))

      (when (and font-node
                 (or (null type-regex)
                     (let ((case-fold-search nil))
                       (string-match-p type-regex (treesit-node-text font-node)))))
        (treesit-fontify-with-override
         (treesit-node-start font-node) (treesit-node-end font-node)
         'font-lock-type-face override start end)))))

(defun python--treesit-fontify-union-types-strict (node override start end &rest _)
  "Fontify nested union types.
Same as `python--treesit-fontify-union-types' but type identifier
should match against `python--treesit-type-regex'.  For NODE,
OVERRIDE, START and END description see
`python--treesit-fontify-union-types'."
  (python--treesit-fontify-union-types node override start end python--treesit-type-regex))

(defun python--treesit-fontify-dotted-decorator (node override start end &rest _)
  "Fontify dotted decorators.
For example @pytes.mark.skip.  Iterate over all nested attribute
nodes and highlight identifier nodes.  NODE is the first attribute
node.  OVERRIDE is the override flag described in
`treesit-font-lock-rules'.  START and END mark the region to be
fontified."
  (dolist (child (treesit-node-children node t))
    (pcase (treesit-node-type child)
      ("identifier"
       (treesit-fontify-with-override
        (treesit-node-start child) (treesit-node-end child)
        'font-lock-type-face override start end))
      ("attribute"
       (python--treesit-fontify-dotted-decorator child override start end)))))

(defvar python--treesit-settings
  (treesit-font-lock-rules
   :feature 'comment
   :language 'python
   '((comment) @font-lock-comment-face)

   :feature 'string
   :language 'python
   '((string) @python--treesit-fontify-string
     (interpolation ["{" "}"] @font-lock-misc-punctuation-face))


   :feature 'keyword
   :language 'python
   `([,@python--treesit-keywords] @font-lock-keyword-face
     ((identifier) @font-lock-keyword-face
      (:match "\\`self\\'" @font-lock-keyword-face)))

   :feature 'definition
   :language 'python
   '((function_definition
      name: (identifier) @font-lock-function-name-face)
     (class_definition
      name: (identifier) @font-lock-type-face)
     (parameters (identifier) @font-lock-variable-name-face)
     (parameters (typed_parameter (identifier) @font-lock-variable-name-face))
     (parameters (default_parameter name: (identifier) @font-lock-variable-name-face))
     (parameters (typed_default_parameter name: (identifier) @font-lock-variable-name-face))
     (lambda_parameters (identifier) @font-lock-variable-name-face)
     (for_in_clause
      left: (identifier) @font-lock-variable-name-face)
     ((import_from_statement
       name: ((dotted_name (identifier) @font-lock-type-face)))
      (:match "\\`[A-Z][A-Za-z0-9]+\\'" @font-lock-type-face))
     (import_from_statement
      name: ((dotted_name (identifier) @font-lock-variable-name-face))))

   :feature 'builtin
   :language 'python
   `((call function: (identifier) @font-lock-builtin-face
           (:match ,(rx-to-string
                     `(seq bol (or ,@python--treesit-builtins) eol))
                   @font-lock-builtin-face))
     (attribute attribute: (identifier) @font-lock-builtin-face
                (:match ,(rx-to-string
                          `(seq bol
                                (or ,@python--treesit-special-attributes) eol))
                        @font-lock-builtin-face)))

   :feature 'decorator
   :language 'python
   '((decorator "@" @font-lock-type-face)
     (decorator (call function: (identifier) @font-lock-type-face))
     (decorator (identifier) @font-lock-type-face)
     (decorator [(attribute) (call (attribute))] @python--treesit-fontify-dotted-decorator))

   :feature 'function
   :language 'python
   '(((call function: (identifier) @font-lock-type-face)
      (:match "\\`[A-Z][A-Za-z0-9]+\\'" @font-lock-type-face))
     (call function: (identifier) @font-lock-function-call-face)
     (call arguments: (argument_list (keyword_argument
                                      name: (identifier) @font-lock-property-name-face)))
     (call function: (attribute
                      attribute: (identifier) @font-lock-function-call-face)))

   :feature 'constant
   :language 'python
   '([(true) (false) (none)] @font-lock-constant-face
     ((assignment  (identifier) @font-lock-constant-face)
      (:match "\\`[A-Z][A-Z0-9_]+\\'" @font-lock-constant-face))
     ((call arguments: (argument_list (identifier) @font-lock-constant-face))
      (:match "\\`[A-Z][A-Z0-9_]+\\'" @font-lock-constant-face))
     ((attribute
       attribute: (identifier) @font-lock-constant-face)
      (:match "\\`[A-Z][A-Z0-9_]+\\'" @font-lock-constant-face)))

   :feature 'assignment
   :language 'python
   `(;; Variable names and LHS.
     (assignment left: (identifier)
                 @font-lock-variable-name-face)
     (assignment left: (attribute
                        attribute: (identifier)
                        @font-lock-variable-name-face))
     (augmented_assignment left: (identifier)
                           @font-lock-variable-name-face)
     (named_expression name: (identifier)
                       @font-lock-variable-name-face)
     (for_statement left: (identifier) @font-lock-variable-name-face)
     (pattern_list [(identifier)
                    (list_splat_pattern (identifier))]
                   @font-lock-variable-name-face)
     (tuple_pattern [(identifier)
                     (list_splat_pattern (identifier))]
                    @font-lock-variable-name-face)
     (list_pattern [(identifier)
                    (list_splat_pattern (identifier))]
                   @font-lock-variable-name-face))


   :feature 'type
   :language 'python
   `(((identifier) @font-lock-type-face
      (:match ,(rx-to-string
                `(seq bol (or ,@python--treesit-exceptions)
                  eol))
              @font-lock-type-face))
     (type [(identifier) (none)] @font-lock-type-face)
     (type (attribute attribute: (identifier) @font-lock-type-face))
     ;; We don't want to highlight a package of the type
     ;; (e.g. pack.ClassName).  So explicitly exclude patterns with
     ;; attribute, since we handle dotted type name in the previous
     ;; rule.  The following rule handle
     ;; generic_type/list/tuple/splat_type nodes.
     (type (_ !attribute [[(identifier) (none)] @font-lock-type-face
                          (attribute attribute: (identifier) @font-lock-type-face) ]))
     ;; collections.abc.Iterator[T] case.
     (type (subscript (attribute attribute: (identifier) @font-lock-type-face)))
     ;; Nested optional type hints, e.g. val: Lvl1 | Lvl2[Lvl3[Lvl4]].
     (type (binary_operator) @python--treesit-fontify-union-types)
     ;;class Type(Base1, Sequence[T]).
     (class_definition
      superclasses:
      (argument_list [(identifier) @font-lock-type-face
                      (attribute attribute: (identifier) @font-lock-type-face)
                      (subscript (identifier) @font-lock-type-face)
                      (subscript (attribute attribute: (identifier) @font-lock-type-face))]))

     ;; Pattern matching: case [str(), pack0.Type0()].  Take only the
     ;; last identifier.
     (class_pattern (dotted_name (identifier) @font-lock-type-face :anchor))

     ;; Highlight the second argument as a type in isinstance/issubclass.
     ((call function: (identifier) @func-name
            (argument_list :anchor (_)
                           [(identifier) @font-lock-type-face
                            (attribute attribute: (identifier) @font-lock-type-face)
                            (tuple (identifier) @font-lock-type-face)
                            (tuple (attribute attribute: (identifier) @font-lock-type-face))]
                           (:match ,python--treesit-type-regex @font-lock-type-face)))
      (:match "^is\\(?:instance\\|subclass\\)$" @func-name))

     ;; isinstance(t, int|float).
     ((call function: (identifier) @func-name
            (argument_list :anchor (_)
                           (binary_operator) @python--treesit-fontify-union-types-strict))
      (:match "^is\\(?:instance\\|subclass\\)$" @func-name))
     ((identifier) @font-lock-type-face
      (:match "\\`[A-Z][A-Za-z0-9]+\\'" @font-lock-type-face)))

   :feature 'escape-sequence
   :language 'python
   :override t
   '((escape_sequence) @font-lock-escape-face)

   :feature 'number
   :language 'python
   '([(integer) (float)] @font-lock-number-face)

   :feature 'property
   :language 'python
   '((attribute
      attribute: (identifier) @font-lock-property-use-face)
     (class_definition
      body: (block
             (expression_statement
              (assignment left:
                          (identifier) @font-lock-property-use-face)))))

   :feature 'operator
   :language 'python
   `([,@python--treesit-operators] @font-lock-operator-face)

   :feature 'bracket
   :language 'python
   '(["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face)

   :feature 'delimiter
   :language 'python
   '(["," "." ":" ";" (ellipsis)] @font-lock-delimiter-face)

   :feature 'variable
   :language 'python
   '((identifier) @python--treesit-fontify-variable))
  "Tree-sitter font-lock settings.")

(defun python--treesit-variable-p (node)
  "Check whether NODE is a variable.
NODE's type should be \"identifier\"."
  ;; An identifier can be a function/class name, a property, or a
  ;; variables.  This function filters out function/class names,
  ;; properties and method parameters.
  (pcase (treesit-node-type (treesit-node-parent node))
    ((or "function_definition" "class_definition" "parameters") nil)
    ("attribute"
     (pcase (treesit-node-field-name node)
       ("object" t)
       (_ nil)))
    (_ t)))

(defun python--treesit-fontify-variable (node override start end &rest _)
  "Fontify an identifier node if it is a variable.
For NODE, OVERRIDE, START, END, and ARGS, see
`treesit-font-lock-rules'."
  (when (python--treesit-variable-p node)
    (treesit-fontify-with-override
     (treesit-node-start node) (treesit-node-end node)
     'font-lock-variable-use-face override start end)))

(defun python--treesit-syntax-propertize (start end)
  "Propertize triple-quote strings between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward (rx (or "\"\"\"" "'''")) end t)
      (let ((node (treesit-node-at (- (point) 3))))
        ;; Handle triple-quoted strings.
        (pcase (treesit-node-type node)
          ("string_start"
           (put-text-property (1- (point)) (point)
                              'syntax-table (string-to-syntax "|")))
          ("string_end"
           (put-text-property (- (point) 3) (- (point) 2)
                              'syntax-table (string-to-syntax "|"))))))))


;;; Indentation

(defcustom python-indent-offset 4
  "Default indentation offset for Python."
  :type 'integer
  :safe 'integerp)

(defcustom python-indent-guess-indent-offset t
  "Non-nil tells Python mode to guess `python-indent-offset' value."
  :type 'boolean
  :safe 'booleanp)

(defcustom python-indent-guess-indent-offset-verbose t
  "Non-nil means to emit a warning when indentation guessing fails."
  :version "25.1"
  :type 'boolean
  :safe' booleanp)

(defcustom python-indent-trigger-commands
  '(indent-for-tab-command yas-expand yas/expand)
  "Commands that might trigger a `python-indent-line' call."
  :type '(repeat symbol))

(defcustom python-indent-def-block-scale 2
  "Multiplier applied to indentation inside multi-line blocks.
The indentation in parens in the block header will be the current
indentation plus `python-indent-offset' multiplied by this
variable.  For example, the arguments are indented as follows if
this variable is 1:

    def do_something(
        arg1,
        arg2):
        print('hello')

if this variable is 2 (default):

    def do_something(
            arg1,
            arg2):
        print('hello')

This variable has an effect on all blocks, not just def block.
This variable only works if the opening paren is not followed by
non-whitespace characters on the same line.  Modify
`python-indent-block-paren-deeper' to customize the case where
non-whitespace characters follow the opening paren on the same
line."
  :version "26.1"
  :type 'integer
  :safe 'natnump)

(defcustom python-indent-block-paren-deeper nil
  "Increase indentation inside parens of a block.
If non-nil, increase the indentation of the lines inside parens
in a header of a block when they are indented to the same level
as the body of the block:

    if (some_expression
            and another_expression):
        do_something()

instead of:

    if (some_expression
        and another_expression):
        do_something()

This variable only works if the opening paren is followed by
non-whitespace characters on the same line.  Modify
`python-indent-def-block-scale' to customize the case where
non-whitespace character does not follow the opening paren on the
same line."
  :version "30.1"
  :type 'boolean
  :safe 'booleanp)

(defvar python-indent-current-level 0
  "Deprecated var available for compatibility.")

(defvar python-indent-levels '(0)
  "Deprecated var available for compatibility.")

(make-obsolete-variable
 'python-indent-current-level
 "The indentation API changed to avoid global state.
The function `python-indent-calculate-levels' does not use it
anymore.  If you were defadvising it and or depended on this
variable for indentation customizations, refactor your code to
work on `python-indent-calculate-indentation' instead."
 "24.5")

(make-obsolete-variable
 'python-indent-levels
 "The indentation API changed to avoid global state.
The function `python-indent-calculate-levels' does not use it
anymore.  If you were defadvising it and or depended on this
variable for indentation customizations, refactor your code to
work on `python-indent-calculate-indentation' instead."
 "24.5")

(defun python-indent-guess-indent-offset ()
  "Guess and set `python-indent-offset' for the current buffer."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((block-end))
        (while (and (not block-end)
                    (re-search-forward
                     (python-rx line-start block-start) nil t))
          (when (and
                 (not (python-syntax-context-type))
                 (progn
                   (goto-char (line-end-position))
                   (python-util-forward-comment -1)
                   (if (equal (char-before) ?:)
                       t
                     (forward-line 1)
                     (when (python-info-block-continuation-line-p)
                       (while (and (python-info-continuation-line-p)
                                   (not (eobp)))
                         (forward-line 1))
                       (python-util-forward-comment -1)
                       (when (equal (char-before) ?:)
                         t)))))
            (setq block-end (point-marker))))
        (let ((indentation
               (when block-end
                 (goto-char block-end)
                 (python-util-forward-comment)
                 (current-indentation))))
          (if (and indentation (not (zerop indentation)))
              (setq-local python-indent-offset indentation)
            (when python-indent-guess-indent-offset-verbose
              (message "Can't guess python-indent-offset, using defaults: %s"
                       python-indent-offset))))))))

(defun python-indent-context ()
  "Get information about the current indentation context.
Context is returned in a cons with the form (STATUS . START).

STATUS can be one of the following:

keyword
-------

:after-comment
 - Point is after a comment line.
 - START is the position of the \"#\" character.
:inside-string
 - Point is inside string.
 - START is the position of the first quote that starts it.
:no-indent
 - No possible indentation case matches.
 - START is always zero.

:inside-paren
 - Fallback case when point is inside paren.
 - START is the first non space char position *after* the open paren.
:inside-paren-at-closing-nested-paren
 - Point is on a line that contains a nested paren closer.
 - START is the position of the open paren it closes.
:inside-paren-at-closing-paren
 - Point is on a line that contains a paren closer.
 - START is the position of the open paren.
:inside-paren-newline-start
 - Point is inside a paren with items starting in their own line.
 - START is the position of the open paren.
:inside-paren-newline-start-from-block
 - Point is inside a paren with items starting in their own line
   from a block start.
 - START is the position of the open paren.
:inside-paren-from-block
 - Point is inside a paren from a block start followed by some
   items on the same line.
 - START is the first non space char position *after* the open paren.
:inside-paren-continuation-line
 - Point is on a continuation line inside a paren.
 - START is the position where the previous line (excluding lines
   for inner parens) starts.

:after-backslash
 - Fallback case when point is after backslash.
 - START is the char after the position of the backslash.
:after-backslash-assignment-continuation
 - Point is after a backslashed assignment.
 - START is the char after the position of the backslash.
:after-backslash-block-continuation
 - Point is after a backslashed block continuation.
 - START is the char after the position of the backslash.
:after-backslash-dotted-continuation
 - Point is after a backslashed dotted continuation.  Previous
   line must contain a dot to align with.
 - START is the char after the position of the backslash.
:after-backslash-first-line
 - First line following a backslashed continuation.
 - START is the char after the position of the backslash.

:after-block-end
 - Point is after a line containing a block ender.
 - START is the position where the ender starts.
:after-block-start
 - Point is after a line starting a block.
 - START is the position where the block starts.
:after-line
 - Point is after a simple line.
 - START is the position where the previous line starts.
:at-dedenter-block-start
 - Point is on a line starting a dedenter block.
 - START is the position where the dedenter block starts."
    (let ((ppss (save-excursion
                  (beginning-of-line)
                  (syntax-ppss))))
      (cond
       ;; Beginning of buffer.
       ((= (line-number-at-pos) 1)
        (cons :no-indent 0))
       ;; Inside a string.
       ((let ((start (python-syntax-context 'string ppss)))
          (when start
            (cons (if (python-info-docstring-p)
                      :inside-docstring
                    :inside-string) start))))
       ;; Inside a paren.
       ((let* ((start (python-syntax-context 'paren ppss))
               (starts-in-newline
                (when start
                  (save-excursion
                    (goto-char start)
                    (forward-char)
                    (not
                     (= (line-number-at-pos)
                        (progn
                          (python-util-forward-comment)
                          (line-number-at-pos)))))))
               (continuation-start
                (when start
                  (save-excursion
                    (forward-line -1)
                    (back-to-indentation)
                    ;; Skip inner parens.
                    (cl-loop with prev-start = (python-syntax-context 'paren)
                             while (and prev-start (>= prev-start start))
                             if (= prev-start start)
                             return (point)
                             else do (goto-char prev-start)
                                     (back-to-indentation)
                                     (setq prev-start
                                           (python-syntax-context 'paren)))))))
          (when start
            (cond
             ;; Current line only holds the closing paren.
             ((save-excursion
                (skip-syntax-forward " ")
                (when (and (python-syntax-closing-paren-p)
                           (progn
                             (forward-char 1)
                             (not (python-syntax-context 'paren))))
                  (cons :inside-paren-at-closing-paren start))))
             ;; Current line only holds a closing paren for nested.
             ((save-excursion
                (back-to-indentation)
                (python-syntax-closing-paren-p))
              (cons :inside-paren-at-closing-nested-paren start))
             ;; This line is a continuation of the previous line.
             (continuation-start
              (cons :inside-paren-continuation-line continuation-start))
             ;; This line starts from an opening block in its own line.
             ((save-excursion
                (goto-char start)
                (when (and
                       starts-in-newline
                       (save-excursion
                         (back-to-indentation)
                         (looking-at (python-rx block-start))))
                  (cons
                   :inside-paren-newline-start-from-block start))))
             (starts-in-newline
              (cons :inside-paren-newline-start start))
             ;; General case.
             (t (let ((after-start (save-excursion
                               (goto-char (1+ start))
                               (skip-syntax-forward "(" 1)
                               (skip-syntax-forward " ")
                               (point))))
                  (if (save-excursion
                        (python-nav-beginning-of-statement)
                        (python-info-looking-at-beginning-of-block))
                      (cons :inside-paren-from-block after-start)
                    (cons :inside-paren after-start))))))))
       ;; After backslash.
       ((let ((start (when (not (python-syntax-comment-or-string-p ppss))
                       (python-info-line-ends-backslash-p
                        (1- (line-number-at-pos))))))
          (when start
            (cond
             ;; Continuation of dotted expression.
             ((save-excursion
                (back-to-indentation)
                (when (eq (char-after) ?\.)
                  ;; Move point back until it's not inside a paren.
                  (while (prog2
                             (forward-line -1)
                             (and (not (bobp))
                                  (python-syntax-context 'paren))))
                  (goto-char (line-end-position))
                  (while (and (search-backward
                               "." (line-beginning-position) t)
                              (python-syntax-context-type)))
                  ;; Ensure previous statement has dot to align with.
                  (when (and (eq (char-after) ?\.)
                             (not (python-syntax-context-type)))
                    (cons :after-backslash-dotted-continuation (point))))))
             ;; Continuation of block definition.
             ((let ((block-continuation-start
                     (python-info-block-continuation-line-p)))
                (when block-continuation-start
                  (save-excursion
                    (goto-char block-continuation-start)
                    (re-search-forward
                     (python-rx block-start (* space))
                     (line-end-position) t)
                    (cons :after-backslash-block-continuation (point))))))
             ;; Continuation of assignment.
             ((let ((assignment-continuation-start
                     (python-info-assignment-continuation-line-p)))
                (when assignment-continuation-start
                  (save-excursion
                    (goto-char assignment-continuation-start)
                    (cons :after-backslash-assignment-continuation (point))))))
             ;; First line after backslash continuation start.
             ((save-excursion
                (goto-char start)
                (when (or (= (line-number-at-pos) 1)
                          (not (python-info-beginning-of-backslash
                                (1- (line-number-at-pos)))))
                  (cons :after-backslash-first-line start))))
             ;; General case.
             (t (cons :after-backslash start))))))
       ;; After beginning of block.
       ((let ((start (save-excursion
                       (back-to-indentation)
                       (python-util-forward-comment -1)
                       (when (equal (char-before) ?:)
                         (python-nav-beginning-of-block)))))
          (when start
            (cons :after-block-start start))))
       ;; At dedenter statement.
       ((let ((start (python-info-dedenter-statement-p)))
          (when start
            (cons :at-dedenter-block-start start))))
       ;; After normal line, comment or ender (default case).
       ((save-excursion
          (back-to-indentation)
          (skip-chars-backward " \t\n")
          (if (bobp)
              (cons :no-indent 0)
            (python-nav-beginning-of-statement)
            (cons
             (cond ((python-info-current-line-comment-p)
                    :after-comment)
                   ((save-excursion
                      (goto-char (line-end-position))
                      (python-util-forward-comment -1)
                      (python-nav-beginning-of-statement)
                      (looking-at (python-rx block-ender)))
                    :after-block-end)
                   (t :after-line))
             (point))))))))

(defun python-indent--calculate-indentation ()
  "Internal implementation of `python-indent-calculate-indentation'.
May return an integer for the maximum possible indentation at
current context or a list of integers.  The latter case is only
happening for :at-dedenter-block-start context since the
possibilities can be narrowed to specific indentation points."
    (save-excursion
      (pcase (python-indent-context)
        (`(:no-indent . ,_) (prog-first-column)) ; usually 0
        (`(,(or :after-line
                :after-comment
                :inside-string
                :after-backslash
                :inside-paren-continuation-line) . ,start)
         ;; Copy previous indentation.
         (goto-char start)
         (current-indentation))
        (`(,(or :inside-paren-at-closing-paren
                :inside-paren-at-closing-nested-paren) . ,start)
         (goto-char (+ 1 start))
         (if (looking-at "[ \t]*\\(?:#\\|$\\)")
             ;; Copy previous indentation.
             (current-indentation)
           ;; Align with opening paren.
           (current-column)))
        (`(:inside-docstring . ,start)
         (let* ((line-indentation (current-indentation))
                (base-indent (progn
                               (goto-char start)
                               (current-indentation))))
           (max line-indentation base-indent)))
        (`(,(or :after-block-start
                :after-backslash-first-line
                :after-backslash-assignment-continuation
                :inside-paren-newline-start) . ,start)
         ;; Add one indentation level.
         (goto-char start)
         (+ (current-indentation) python-indent-offset))
        (`(:after-backslash-block-continuation . ,start)
         (goto-char start)
         (let ((column (current-column)))
           (if (= column (+ (current-indentation) python-indent-offset))
               ;; Add one level to avoid same indent as next logical line.
               (+ column python-indent-offset)
             column)))
        (`(,(or :inside-paren
                :after-backslash-dotted-continuation) . ,start)
         ;; Use the column given by the context.
         (goto-char start)
         (current-column))
        (`(:after-block-end . ,start)
         ;; Subtract one indentation level.
         (goto-char start)
         (max 0 (- (current-indentation) python-indent-offset)))
        (`(:at-dedenter-block-start . ,_)
         ;; List all possible indentation levels from opening blocks.
         (let ((opening-block-start-points
                (python-info-dedenter-opening-block-positions)))
           (if (not opening-block-start-points)
               (prog-first-column) ; if not found default to first column
             (mapcar (lambda (pos)
                       (save-excursion
                         (goto-char pos)
                         (current-indentation)))
                     opening-block-start-points))))
        (`(,(or :inside-paren-newline-start-from-block) . ,start)
         (goto-char start)
         (+ (current-indentation)
            (* python-indent-offset python-indent-def-block-scale)))
        (`(,:inside-paren-from-block . ,start)
         (goto-char start)
         (let ((column (current-column)))
           (if (and python-indent-block-paren-deeper
                    (= column (+ (save-excursion
                                   (python-nav-beginning-of-statement)
                                   (current-indentation))
                                 python-indent-offset)))
               (+ column python-indent-offset)
             column))))))

(defun python-indent--calculate-levels (indentation)
  "Calculate levels list given INDENTATION.
Argument INDENTATION can either be an integer or a list of
integers.  Levels are returned in ascending order, and in the
case INDENTATION is a list, this order is enforced."
  (if (listp indentation)
      (sort (copy-sequence indentation) #'<)
    (nconc (number-sequence (prog-first-column) (1- indentation)
                            python-indent-offset)
           (list indentation))))

(defun python-indent--previous-level (levels indentation)
  "Return previous level from LEVELS relative to INDENTATION."
  (let* ((levels (sort (copy-sequence levels) #'>))
         (default (car levels)))
    (catch 'return
      (dolist (level levels)
        (when (funcall #'< level indentation)
          (throw 'return level)))
      default)))

(defun python-indent-calculate-indentation (&optional previous)
  "Calculate indentation.
Get indentation of PREVIOUS level when argument is non-nil.
Return the max level of the cycle when indentation reaches the
minimum."
  (let* ((indentation (python-indent--calculate-indentation))
         (levels (python-indent--calculate-levels indentation)))
    (if previous
        (python-indent--previous-level levels (current-indentation))
      (if levels
          (apply #'max levels)
        (prog-first-column)))))

(defun python-indent-line (&optional previous)
  "Internal implementation of `python-indent-line-function'.
Use the PREVIOUS level when argument is non-nil, otherwise indent
to the maximum available level.  When indentation is the minimum
possible and PREVIOUS is non-nil, cycle back to the maximum
level."
  (let ((follow-indentation-p
         ;; Check if point is within indentation.
         (and (<= (line-beginning-position) (point))
              (>= (+ (line-beginning-position)
                     (current-indentation))
                  (point)))))
    (save-excursion
      (indent-line-to
       (python-indent-calculate-indentation previous))
      (python-info-dedenter-opening-block-message))
    (when follow-indentation-p
      (back-to-indentation))))

(defun python-indent-calculate-levels ()
  "Return possible indentation levels."
  (python-indent--calculate-levels
   (python-indent--calculate-indentation)))

(defun python-indent-line-function ()
  "`indent-line-function' for Python mode.
When the variable `last-command' is equal to one of the symbols
inside `python-indent-trigger-commands' it cycles possible
indentation levels from right to left."
  (python-indent-line
   (and (memq this-command python-indent-trigger-commands)
        (eq last-command this-command))))

(defun python-indent-dedent-line ()
  "De-indent current line."
  (interactive "*")
  (when (and (not (bolp))
           (not (python-syntax-comment-or-string-p))
           (= (current-indentation) (current-column)))
      (python-indent-line t)
      t))

(defun python-indent-dedent-line-backspace (arg)
  "De-indent current line.
Argument ARG is passed to `backward-delete-char-untabify' when point is
not in between the indentation or when Transient Mark mode is enabled,
the mark is active, and ARG is 1."
  (interactive "*p")
  (when (or
         (and (use-region-p) (= arg 1))
         (not (python-indent-dedent-line)))
    (backward-delete-char-untabify arg)))

(put 'python-indent-dedent-line-backspace 'delete-selection 'supersede)

(defun python-indent-region (start end)
  "Indent a Python region automagically.

Called from a program, START and END specify the region to indent."
  (let ((deactivate-mark nil))
    (save-excursion
      (goto-char end)
      (setq end (point-marker))
      (goto-char start)
      (or (bolp) (forward-line 1))
      (while (< (point) end)
        (or (and (bolp) (eolp))
            (when (and
                   ;; Skip if previous line is empty or a comment.
                   (save-excursion
                     (let ((line-is-comment-p
                            (python-info-current-line-comment-p)))
                       (forward-line -1)
                       (not
                        (or (and (python-info-current-line-comment-p)
                                 ;; Unless this line is a comment too.
                                 (not line-is-comment-p))
                            (python-info-current-line-empty-p)))))
                   ;; Don't mess with strings, unless it's the
                   ;; enclosing set of quotes or a docstring.
                   (or (not (python-syntax-context 'string))
                       (equal
                        (syntax-after
                         (+ (1- (point))
                            (current-indentation)
                            (python-syntax-count-quotes (char-after) (point))))
                        (string-to-syntax "|"))
                       (python-info-docstring-p))
                   ;; Skip if current line is a block start, a
                   ;; dedenter or block ender.
                   (save-excursion
                     (back-to-indentation)
                     (not (looking-at
                           (python-rx
                            (or block-start dedenter block-ender))))))
              (python-indent-line)))
        (forward-line 1))
      (move-marker end nil))))

(defun python-indent-shift-left (start end &optional count)
  "Shift lines contained in region START END by COUNT columns to the left.
COUNT defaults to `python-indent-offset'.  If region isn't
active, the current line is shifted.  The shifted region includes
the lines in which START and END lie.  An error is signaled if
any lines in the region are indented less than COUNT columns."
  (interactive
   (if mark-active
       (list (region-beginning) (region-end) current-prefix-arg)
     (list (line-beginning-position) (line-end-position) current-prefix-arg)))
  (if count
      (setq count (prefix-numeric-value count))
    (setq count python-indent-offset))
  (when (> count 0)
    (let ((deactivate-mark nil))
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (if (and (< (current-indentation) count)
                   (not (looking-at "[ \t]*$")))
              (user-error "Can't shift all lines enough"))
          (forward-line))
        (indent-rigidly start end (- count))))))

(defun python-indent-shift-right (start end &optional count)
  "Shift lines contained in region START END by COUNT columns to the right.
COUNT defaults to `python-indent-offset'.  If region isn't
active, the current line is shifted.  The shifted region includes
the lines in which START and END lie."
  (interactive
   (if mark-active
       (list (region-beginning) (region-end) current-prefix-arg)
     (list (line-beginning-position) (line-end-position) current-prefix-arg)))
  (let ((deactivate-mark nil))
    (setq count (if count (prefix-numeric-value count)
                  python-indent-offset))
    (indent-rigidly start end count)))

(defun python-indent-post-self-insert-function ()
  "Adjust indentation after insertion of some characters.
This function is intended to be added to `post-self-insert-hook.'
If a line renders a paren alone, after adding a char before it,
the line will be re-indented automatically if needed."
  (when (and electric-indent-mode
             (eq (char-before) last-command-event)
             (not (python-syntax-context 'string))
             (save-excursion
               (beginning-of-line)
               (not (python-syntax-context 'string (syntax-ppss)))))
    (cond
     ;; Electric indent inside parens
     ((and
       (not (bolp))
       (let ((paren-start (python-syntax-context 'paren)))
         ;; Check that point is inside parens.
         (when paren-start
           (not
            ;; Filter the case where input is happening in the same
            ;; line where the open paren is.
            (= (line-number-at-pos)
               (line-number-at-pos paren-start)))))
       ;; When content has been added before the closing paren or a
       ;; comma has been inserted, it's ok to do the trick.
       (or
        (memq (char-after) '(?\) ?\] ?\}))
        (eq (char-before) ?,)))
      (save-excursion
        (goto-char (line-beginning-position))
        (let ((indentation (python-indent-calculate-indentation)))
          (when (and (numberp indentation) (< (current-indentation) indentation))
            (indent-line-to indentation)))))
     ;; Electric colon
     ((and (eq ?: last-command-event)
           (memq ?: electric-indent-chars)
           (not current-prefix-arg)
           ;; Trigger electric colon only at end of line
           (eolp)
           ;; Avoid re-indenting on extra colon
           (not (equal ?: (char-before (1- (point)))))
           (not (python-syntax-comment-or-string-p)))
      ;; Just re-indent dedenters
      (let ((dedenter-pos (python-info-dedenter-statement-p)))
        (when dedenter-pos
          (let ((start (copy-marker dedenter-pos))
                (end (point-marker)))
            (save-excursion
              (goto-char start)
              (python-indent-line)
              (unless (= (line-number-at-pos start)
                         (line-number-at-pos end))
                ;; Reindent region if this is a multiline statement
                (python-indent-region start end))))))))))


;;; Mark

(defun python-mark-defun (&optional allow-extend)
  "Put mark at end of this defun, point at beginning.
The defun marked is the one that contains point or follows point.

Interactively (or with ALLOW-EXTEND non-nil), if this command is
repeated or (in Transient Mark mode) if the mark is active, it
marks the next defun after the ones already marked."
  (interactive "p")
  (when (python-info-looking-at-beginning-of-defun)
    (end-of-line 1))
  (mark-defun allow-extend))


;;; Navigation

(defcustom python-forward-sexp-function #'python-nav-forward-sexp
  "Function to use when navigating between expressions."
  :version "28.1"
  :type '(choice (const :tag "Python blocks" python-nav-forward-sexp)
                 (const :tag "CC-mode like" nil)
                 function))

(defvar python-nav-beginning-of-defun-regexp
  (python-rx line-start (* space) defun (+ sp-bsnl) (group symbol-name))
  "Regexp matching class or function definition.
The name of the defun should be grouped so it can be retrieved
via `match-string'.")

(defvar python-nav-beginning-of-block-regexp
  (python-rx line-start (* space) block-start)
  "Regexp matching block start.")

(defun python-nav--beginning-of-defun (&optional arg)
  "Internal implementation of `python-nav-beginning-of-defun'.
With positive ARG search backwards, else search forwards."
  (when (or (null arg) (= arg 0)) (setq arg 1))
  (let* ((re-search-fn (if (> arg 0)
                           #'re-search-backward
                         #'re-search-forward))
         (line-beg-pos (line-beginning-position))
         (line-content-start (+ line-beg-pos (current-indentation)))
         (pos (point-marker))
         (min-indentation (if (python-info-current-line-empty-p)
                              most-positive-fixnum
                            (current-indentation)))
         (body-indentation
          (and (> arg 0)
               (or (and (python-info-looking-at-beginning-of-defun nil t)
                        (+ (save-excursion
                             (python-nav-beginning-of-statement)
                             (current-indentation))
                           python-indent-offset))
                   (save-excursion
                     (while
                         (and
                          (python-nav-backward-block)
                          (or (not (python-info-looking-at-beginning-of-defun))
                              (>= (current-indentation) min-indentation))
                          (setq min-indentation
                                (min min-indentation (current-indentation)))))
                     (or (and (python-info-looking-at-beginning-of-defun)
                              (+ (current-indentation) python-indent-offset))
                         0)))))
         (found
          (progn
            (when (and (python-info-looking-at-beginning-of-defun nil t)
                       (or (< arg 0)
                           ;; If looking at beginning of defun, and if
                           ;; pos is > line-content-start, ensure a
                           ;; backward re search match this defun by
                           ;; going to end of line before calling
                           ;; re-search-fn bug#40563
                           (and (> arg 0)
                                (or (python-info-continuation-line-p)
                                    (> pos line-content-start)))))
              (python-nav-end-of-statement))

            (while (and (funcall re-search-fn
                                 python-nav-beginning-of-defun-regexp nil t)
                        (or (python-syntax-context-type)
                            ;; Handle nested defuns when moving
                            ;; backwards by checking indentation.
                            (and (> arg 0)
                                 (not (= (current-indentation) 0))
                                 (>= (current-indentation) body-indentation)))))
            (and (python-info-looking-at-beginning-of-defun nil t)
                 (or (not (= (line-number-at-pos pos)
                             (line-number-at-pos)))
                     (and (>= (point) line-beg-pos)
                          (<= (point) line-content-start)
                          (> pos line-content-start)))))))
    (if found
        (progn
          (when (< arg 0)
            (python-nav-beginning-of-statement))
          (beginning-of-line 1)
          t)
      (and (goto-char pos) nil))))

(defun python-nav-beginning-of-defun (&optional arg)
  "Move point to `beginning-of-defun'.
With positive ARG search backwards else search forward.
ARG nil or 0 defaults to 1.  When searching backwards,
nested defuns are handled with care depending on current
point position.  Return non-nil if point is moved to
`beginning-of-defun'."
  (when (or (null arg) (= arg 0)) (setq arg 1))
  (let ((found))
    (while (and (not (= arg 0))
                (let ((keep-searching-p
                       (python-nav--beginning-of-defun arg)))
                  (when (and keep-searching-p (null found))
                    (setq found t))
                  keep-searching-p))
      (setq arg (if (> arg 0) (1- arg) (1+ arg))))
    found))

(defun python-nav-end-of-defun ()
  "Move point to the end of def or class.
Returns nil if point is not in a def or class."
  (interactive)
  (let ((beg-defun-indent)
        (beg-pos (point)))
    (when (or (python-info-looking-at-beginning-of-defun)
              (python-nav-beginning-of-defun 1)
              (python-nav-beginning-of-defun -1))
      (setq beg-defun-indent (current-indentation))
      (while (progn
               (python-nav-end-of-statement)
               (python-util-forward-comment 1)
               (and (> (current-indentation) beg-defun-indent)
                    (not (eobp)))))
      (python-util-forward-comment -1)
      (forward-line 1)
      ;; Ensure point moves forward.
      (and (> beg-pos (point)) (goto-char beg-pos))
      ;; Return non-nil if we did something (because then we were in a
      ;; def/class).
      (/= beg-pos (point)))))

(defun python-nav--syntactically (fn poscompfn &optional contextfn)
  "Move point using FN avoiding places with specific context.
FN must take no arguments.  POSCOMPFN is a two arguments function
used to compare current and previous point after it is moved
using FN, this is normally a less-than or greater-than
comparison.  Optional argument CONTEXTFN defaults to
`python-syntax-context-type' and is used for checking current
point context, it must return a non-nil value if this point must
be skipped."
  (let ((contextfn (or contextfn 'python-syntax-context-type))
        (start-pos (point-marker))
        (prev-pos))
    (catch 'found
      (while t
        (let* ((newpos
                (and (funcall fn) (point-marker)))
               (context (funcall contextfn)))
          (cond ((and (not context) newpos
                      (or (and (not prev-pos) newpos)
                          (and prev-pos newpos
                               (funcall poscompfn newpos prev-pos))))
                 (throw 'found (point-marker)))
                ((and newpos context)
                 (setq prev-pos (point)))
                (t (when (not newpos) (goto-char start-pos))
                   (throw 'found nil))))))))

(defun python-nav--forward-defun (arg)
  "Internal implementation of python-nav-{backward,forward}-defun.
Uses ARG to define which function to call, and how many times
repeat it."
  (let ((found))
    (while (and (> arg 0)
                (setq found
                      (python-nav--syntactically
                       (lambda ()
                         (re-search-forward
                          python-nav-beginning-of-defun-regexp nil t))
                       '>)))
      (setq arg (1- arg)))
    (while (and (< arg 0)
                (setq found
                      (python-nav--syntactically
                       (lambda ()
                         (re-search-backward
                          python-nav-beginning-of-defun-regexp nil t))
                       '<)))
      (setq arg (1+ arg)))
    found))

(defun python-nav-backward-defun (&optional arg)
  "Navigate to closer defun backward ARG times.
Unlikely `python-nav-beginning-of-defun' this doesn't care about
nested definitions."
  (interactive "^p")
  (python-nav--forward-defun (- (or arg 1))))

(defun python-nav-forward-defun (&optional arg)
  "Navigate to closer defun forward ARG times.
Unlikely `python-nav-beginning-of-defun' this doesn't care about
nested definitions."
  (interactive "^p")
  (python-nav--forward-defun (or arg 1)))

(defun python-nav-beginning-of-statement ()
  "Move to start of current statement."
  (interactive "^")
  (forward-line 0)
  (let* ((ppss (syntax-ppss))
         (context-point
          (or
           (python-syntax-context 'paren ppss)
           (python-syntax-context 'string ppss))))
    (cond ((bobp))
          (context-point
           (goto-char context-point)
           (python-nav-beginning-of-statement))
          ((save-excursion
             (forward-line -1)
             (python-info-line-ends-backslash-p))
           (forward-line -1)
           (python-nav-beginning-of-statement))))
  (back-to-indentation)
  (point-marker))

(defun python-nav-end-of-statement (&optional noend)
  "Move to end of current statement.
Optional argument NOEND is internal and makes the logic to not
jump to the end of line when moving forward searching for the end
of the statement."
  (interactive "^")
  (let (string-start bs-pos (last-string-end 0))
    (while (and (or noend (goto-char (line-end-position)))
                (not (eobp))
                (cond ((setq string-start (python-syntax-context 'string))
                       ;; The condition can be nil if syntax table
                       ;; text properties and the `syntax-ppss' cache
                       ;; are somehow out of whack.  This has been
                       ;; observed when using `syntax-ppss' during
                       ;; narrowing.
                       (when (>= string-start last-string-end)
                         (goto-char string-start)
                         (if (python-syntax-context 'paren)
                             ;; Ended up inside a paren, roll again.
                             (python-nav-end-of-statement t)
                           ;; This is not inside a paren, move to the
                           ;; end of this string.
                           (goto-char (+ (point)
                                         (python-syntax-count-quotes
                                          (char-after (point)) (point))))
                           (setq
                            last-string-end
                            (or (if (eq t (nth 3 (syntax-ppss)))
                                    (cl-loop
                                     while (re-search-forward
                                            (rx (or "\"\"\"" "'''")) nil t)
                                     unless (python-syntax-context 'string)
                                     return (point))
                                  (ignore-error scan-error
                                    (goto-char string-start)
                                    (python-nav--lisp-forward-sexp)
                                    (point)))
                                (goto-char (point-max)))))))
                      ((python-syntax-context 'paren)
                       ;; The statement won't end before we've escaped
                       ;; at least one level of parenthesis.
                       (condition-case err
                           (goto-char (scan-lists (point) 1 -1))
                         (scan-error (goto-char (nth 3 err)))))
                      ((setq bs-pos (python-info-line-ends-backslash-p))
                       (goto-char bs-pos)
                       (forward-line 1))))))
  (point-marker))

(defun python-nav-backward-statement (&optional arg)
  "Move backward to previous statement.
With ARG, repeat.  See `python-nav-forward-statement'."
  (interactive "^p")
  (or arg (setq arg 1))
  (python-nav-forward-statement (- arg)))

(defun python-nav-forward-statement (&optional arg)
  "Move forward to next statement.
With ARG, repeat.  With negative argument, move ARG times
backward to previous statement."
  (interactive "^p")
  (or arg (setq arg 1))
  (while (> arg 0)
    (python-nav-end-of-statement)
    (python-util-forward-comment)
    (python-nav-beginning-of-statement)
    (setq arg (1- arg)))
  (while (< arg 0)
    (python-nav-beginning-of-statement)
    (python-util-forward-comment -1)
    (python-nav-beginning-of-statement)
    (setq arg (1+ arg))))

(defvar python-nav-cache nil
  "Cache to hold the results of navigation functions.")

(defvar python-nav-cache-tick 0
  "`buffer-chars-modified-tick' when registering the navigation cache.")

(defun python-nav-cache-get (kind)
  "Get value from the navigation cache.
If the current buffer is not modified, the navigation cache is searched
using KIND and the current line number as a key."
  (and (= (buffer-chars-modified-tick) python-nav-cache-tick)
       (cdr (assoc (cons kind (line-number-at-pos nil t)) python-nav-cache))))

(defun python-nav-cache-set (kind current target)
  "Add a key-value pair to the navigation cache.
Invalidate the navigation cache if the current buffer has been modified.
Then add a key-value pair to the navigation cache.  The key consists of
KIND and CURRENT line number, and the value is TARGET position."
  (let ((tick (buffer-chars-modified-tick)))
    (when (/= tick python-nav-cache-tick)
      (setq-local python-nav-cache nil
                  python-nav-cache-tick tick))
    (push (cons (cons kind current) target) python-nav-cache)
    target))

(defun python-nav-with-cache (kind func)
  "Cached version of the navigation FUNC.
If a value is obtained from the navigation cache using KIND, it will
navigate there and return the position.  Otherwise, use FUNC to navigate
and cache the result."
  (let ((target (python-nav-cache-get kind)))
    (if target
        (progn
          (goto-char target)
          (point-marker))
      (let ((current (line-number-at-pos nil t)))
        (python-nav-cache-set kind current (funcall func))))))

(defun python-nav-beginning-of-block ()
  "Move to start of current block."
  (interactive "^")
  (python-nav-with-cache
   'beginning-of-block #'python-nav--beginning-of-block))

(defun python-nav--beginning-of-block ()
  "Move to start of current block.
This is an internal implementation of `python-nav-beginning-of-block'
without the navigation cache."
  (let ((starting-pos (point)))
    ;; Go to first line beginning a statement
    (while (and (not (bobp))
                (or (and (python-nav-beginning-of-statement) nil)
                    (python-info-current-line-comment-p)
                    (python-info-current-line-empty-p)))
      (forward-line -1))
    (if (progn
          (python-nav-beginning-of-statement)
          (looking-at (python-rx block-start)))
        (point-marker)
      (let ((block-matching-indent
             (- (current-indentation) python-indent-offset)))
        (while
            (and (python-nav-backward-block)
                 (> (current-indentation) block-matching-indent)))
        (if (and (looking-at (python-rx block-start))
                 (= (current-indentation) block-matching-indent))
            (point-marker)
          (and (goto-char starting-pos) nil))))))

(defun python-nav-end-of-block ()
  "Move to end of current block."
  (interactive "^")
  (python-nav-with-cache
   'end-of-block #'python-nav--end-of-block))

(defun python-nav--end-of-block ()
  "Move to end of current block.
This is an internal implementation of `python-nav-end-of-block' without
the navigation cache."
  (when (python-nav-beginning-of-block)
    (let ((block-indentation (current-indentation)))
      (python-nav-end-of-statement)
      (while (and (forward-line 1)
                  (not (eobp))
                  (or (and (> (current-indentation) block-indentation)
                           (or (python-nav-end-of-statement) t))
                      (python-info-current-line-comment-p)
                      (python-info-current-line-empty-p))))
      (python-util-forward-comment -1)
      (point-marker))))

(defun python-nav-backward-block (&optional arg)
  "Move backward to previous block of code.
With ARG, repeat.  See `python-nav-forward-block'."
  (interactive "^p")
  (or arg (setq arg 1))
  (python-nav-forward-block (- arg)))

(defun python-nav-forward-block (&optional arg)
  "Move forward to next block of code.
With ARG, repeat.  With negative argument, move ARG times
backward to previous block."
  (interactive "^p")
  (or arg (setq arg 1))
  (let ((block-start-regexp
         (python-rx line-start (* whitespace) block-start))
        (starting-pos (point))
        (orig-arg arg))
    (while (> arg 0)
      (python-nav-end-of-statement)
      (while (and
              (re-search-forward block-start-regexp nil t)
              (python-syntax-context-type)))
      (setq arg (1- arg)))
    (while (< arg 0)
      (python-nav-beginning-of-statement)
      (while (and
              (re-search-backward block-start-regexp nil t)
              (python-syntax-context-type)))
      (setq arg (1+ arg)))
    (python-nav-beginning-of-statement)
    (if (or (and (> orig-arg 0) (< (point) starting-pos))
            (not (looking-at (python-rx block-start))))
        (and (goto-char starting-pos) nil)
      (and (not (= (point) starting-pos)) (point-marker)))))

(defun python-nav--lisp-forward-sexp (&optional arg)
  "Standard version `forward-sexp'.
It ignores completely the value of `forward-sexp-function' by
setting it to nil before calling `forward-sexp'.  With positive
ARG move forward only one sexp, else move backwards."
  (let ((forward-sexp-function)
        (arg (if (or (not arg) (> arg 0)) 1 -1)))
    (forward-sexp arg)))

(defun python-nav--lisp-forward-sexp-safe (&optional arg)
  "Safe version of standard `forward-sexp'.
When at end of sexp (i.e. looking at an opening/closing paren)
skips it instead of throwing an error.  With positive ARG move
forward only one sexp, else move backwards."
  (let* ((arg (if (or (not arg) (> arg 0)) 1 -1))
         (paren-regexp
          (if (> arg 0) (python-rx close-paren) (python-rx open-paren)))
         (search-fn
          (if (> arg 0) #'re-search-forward #'re-search-backward)))
    (condition-case nil
        (python-nav--lisp-forward-sexp arg)
      (error
       (while (and (funcall search-fn paren-regexp nil t)
                   (python-syntax-context 'paren)))))))

(defun python-nav--forward-sexp (&optional dir safe skip-parens-p)
  "Move to forward sexp.
With positive optional argument DIR direction move forward, else
backwards.  When optional argument SAFE is non-nil do not throw
errors when at end of sexp, skip it instead.  With optional
argument SKIP-PARENS-P force sexp motion to ignore parenthesized
expressions when looking at them in either direction."
  (setq dir (or dir 1))
  (unless (= dir 0)
    (let* ((forward-p (if (> dir 0)
                          (and (setq dir 1) t)
                        (and (setq dir -1) nil)))
           (context-type (python-syntax-context-type)))
      (cond
       ((memq context-type '(string comment))
        ;; Inside of a string, get out of it.
        (let ((forward-sexp-function))
          (forward-sexp dir)))
       ((and (not skip-parens-p)
             (or (eq context-type 'paren)
                 (if forward-p
                     (eq (syntax-class (syntax-after (point)))
                         (car (string-to-syntax "(")))
                   (eq (syntax-class (syntax-after (1- (point))))
                       (car (string-to-syntax ")"))))))
        ;; Inside a paren or looking at it, lisp knows what to do.
        (if safe
            (python-nav--lisp-forward-sexp-safe dir)
          (python-nav--lisp-forward-sexp dir)))
       (t
        ;; This part handles the lispy feel of
        ;; `python-nav-forward-sexp'.  Knowing everything about the
        ;; current context and the context of the next sexp tries to
        ;; follow the lisp sexp motion commands in a symmetric manner.
        (let* ((context
                (cond
                 ((python-info-beginning-of-block-p) 'block-start)
                 ((python-info-end-of-block-p) 'block-end)
                 ((python-info-beginning-of-statement-p) 'statement-start)
                 ((python-info-end-of-statement-p) 'statement-end)))
               (next-sexp-pos
                (save-excursion
                  (if safe
                      (python-nav--lisp-forward-sexp-safe dir)
                    (python-nav--lisp-forward-sexp dir))
                  (point)))
               (next-sexp-context
                (save-excursion
                  (goto-char next-sexp-pos)
                  (cond
                   ((python-info-beginning-of-block-p) 'block-start)
                   ((python-info-end-of-block-p) 'block-end)
                   ((python-info-beginning-of-statement-p) 'statement-start)
                   ((python-info-end-of-statement-p) 'statement-end)
                   ((python-info-statement-starts-block-p) 'starts-block)
                   ((python-info-statement-ends-block-p) 'ends-block)))))
          (if forward-p
              (cond ((and (not (eobp))
                          (python-info-current-line-empty-p))
                     (python-util-forward-comment dir)
                     (python-nav--forward-sexp dir safe skip-parens-p))
                    ((eq context 'block-start)
                     (python-nav-end-of-block))
                    ((eq context 'statement-start)
                     (python-nav-end-of-statement))
                    ((and (memq context '(statement-end block-end))
                          (eq next-sexp-context 'ends-block))
                     (goto-char next-sexp-pos)
                     (python-nav-end-of-block))
                    ((and (memq context '(statement-end block-end))
                          (eq next-sexp-context 'starts-block))
                     (goto-char next-sexp-pos)
                     (python-nav-end-of-block))
                    ((memq context '(statement-end block-end))
                     (goto-char next-sexp-pos)
                     (python-nav-end-of-statement))
                    (t (goto-char next-sexp-pos)))
            (cond ((and (not (bobp))
                        (python-info-current-line-empty-p))
                   (python-util-forward-comment dir)
                   (python-nav--forward-sexp dir safe skip-parens-p))
                  ((eq context 'block-end)
                   (python-nav-beginning-of-block))
                  ((eq context 'statement-end)
                   (python-nav-beginning-of-statement))
                  ((and (memq context '(statement-start block-start))
                        (eq next-sexp-context 'starts-block))
                   (goto-char next-sexp-pos)
                   (python-nav-beginning-of-block))
                  ((and (memq context '(statement-start block-start))
                        (eq next-sexp-context 'ends-block))
                   (goto-char next-sexp-pos)
                   (python-nav-beginning-of-block))
                  ((memq context '(statement-start block-start))
                   (goto-char next-sexp-pos)
                   (python-nav-beginning-of-statement))
                  (t (goto-char next-sexp-pos))))))))))

(defun python-nav-forward-sexp (&optional arg safe skip-parens-p)
  "Move forward across expressions.
With ARG, do it that many times.  Negative arg -N means move
backward N times.  When optional argument SAFE is non-nil do not
throw errors when at end of sexp, skip it instead.  With optional
argument SKIP-PARENS-P force sexp motion to ignore parenthesized
expressions when looking at them in either direction (forced to t
in interactive calls)."
  (interactive "^p")
  (or arg (setq arg 1))
  ;; Do not follow parens on interactive calls.  This hack to detect
  ;; if the function was called interactively copes with the way
  ;; `forward-sexp' works by calling `forward-sexp-function', losing
  ;; interactive detection by checking `current-prefix-arg'.  The
  ;; reason to make this distinction is that lisp functions like
  ;; `blink-matching-open' get confused causing issues like the one in
  ;; Bug#16191.  With this approach the user gets a symmetric behavior
  ;; when working interactively while called functions expecting
  ;; paren-based sexp motion work just fine.
  (or
   skip-parens-p
   (setq skip-parens-p
         (memq real-this-command
               (list
                #'forward-sexp #'backward-sexp
                #'python-nav-forward-sexp #'python-nav-backward-sexp
                #'python-nav-forward-sexp-safe #'python-nav-backward-sexp))))
  (while (> arg 0)
    (python-nav--forward-sexp 1 safe skip-parens-p)
    (setq arg (1- arg)))
  (while (< arg 0)
    (python-nav--forward-sexp -1 safe skip-parens-p)
    (setq arg (1+ arg))))

(defun python-nav-backward-sexp (&optional arg safe skip-parens-p)
  "Move backward across expressions.
With ARG, do it that many times.  Negative arg -N means move
forward N times.  When optional argument SAFE is non-nil do not
throw errors when at end of sexp, skip it instead.  With optional
argument SKIP-PARENS-P force sexp motion to ignore parenthesized
expressions when looking at them in either direction (forced to t
in interactive calls)."
  (interactive "^p")
  (or arg (setq arg 1))
  (python-nav-forward-sexp (- arg) safe skip-parens-p))

(defun python-nav-forward-sexp-safe (&optional arg skip-parens-p)
  "Move forward safely across expressions.
With ARG, do it that many times.  Negative arg -N means move
backward N times.  With optional argument SKIP-PARENS-P force
sexp motion to ignore parenthesized expressions when looking at
them in either direction (forced to t in interactive calls)."
  (interactive "^p")
  (python-nav-forward-sexp arg t skip-parens-p))

(defun python-nav-backward-sexp-safe (&optional arg skip-parens-p)
  "Move backward safely across expressions.
With ARG, do it that many times.  Negative arg -N means move
forward N times.  With optional argument SKIP-PARENS-P force sexp
motion to ignore parenthesized expressions when looking at them in
either direction (forced to t in interactive calls)."
  (interactive "^p")
  (python-nav-backward-sexp arg t skip-parens-p))

(defun python-nav--up-list (&optional dir)
  "Internal implementation of `python-nav-up-list'.
DIR is always 1 or -1 and comes sanitized from
`python-nav-up-list' calls."
  (let ((context (python-syntax-context-type))
        (forward-p (> dir 0)))
    (cond
     ((memq context '(string comment)))
     ((eq context 'paren)
      (let ((forward-sexp-function))
        (up-list dir)))
     ((and forward-p (python-info-end-of-block-p))
      (let ((parent-end-pos
             (save-excursion
               (let ((indentation (and
                                   (python-nav-beginning-of-block)
                                   (current-indentation))))
                 (while (and indentation
                             (> indentation 0)
                             (>= (current-indentation) indentation)
                             (python-nav-backward-block)))
                 (python-nav-end-of-block)))))
        (and (> (or parent-end-pos (point)) (point))
             (goto-char parent-end-pos))))
     (forward-p (python-nav-end-of-block))
     ((and (not forward-p)
           (> (current-indentation) 0)
           (python-info-beginning-of-block-p))
      (let ((prev-block-pos
             (save-excursion
               (let ((indentation (current-indentation)))
                 (while (and (python-nav-backward-block)
                             (>= (current-indentation) indentation))))
               (point))))
        (and (> (point) prev-block-pos)
             (goto-char prev-block-pos))))
     ((not forward-p) (python-nav-beginning-of-block)))))

(defun python-nav-up-list (&optional arg)
  "Move forward out of one level of parentheses (or blocks).
With ARG, do this that many times.
A negative argument means move backward but still to a less deep spot.
This command assumes point is not in a string or comment."
  (interactive "^p")
  (or arg (setq arg 1))
  (while (> arg 0)
    (python-nav--up-list 1)
    (setq arg (1- arg)))
  (while (< arg 0)
    (python-nav--up-list -1)
    (setq arg (1+ arg))))

(defun python-nav-backward-up-list (&optional arg)
  "Move backward out of one level of parentheses (or blocks).
With ARG, do this that many times.
A negative argument means move forward but still to a less deep spot.
This command assumes point is not in a string or comment."
  (interactive "^p")
  (or arg (setq arg 1))
  (python-nav-up-list (- arg)))

(defun python-nav-if-name-main ()
  "Move point at the beginning the __main__ block.
When \"if __name__ == \\='__main__\\=':\" is found returns its
position, else returns nil."
  (interactive)
  (let ((point (point))
        (found (catch 'found
                 (goto-char (point-min))
                 (while (re-search-forward
                         (python-rx line-start
                                    "if" (+ space)
                                    "__name__" (+ space)
                                    "==" (+ space)
                                    (group-n 1 (or ?\" ?\'))
                                    "__main__" (backref 1) (* space) ":")
                         nil t)
                   (when (not (python-syntax-context-type))
                     (beginning-of-line)
                     (throw 'found t))))))
    (if found
        (point)
      (ignore (goto-char point)))))


;;; Shell integration

(defcustom python-shell-buffer-name "Python"
  "Default buffer name for Python interpreter."
  :type 'string
  :safe 'stringp)

(defcustom python-shell-interpreter
  (cond ((executable-find "python") "python")
        (t "python3"))
  "Python interpreter for interactive use.

Some Python interpreters also require changes to
`python-shell-interpreter-args'.  In particular, setting
`python-shell-interpreter' to \"ipython3\" requires setting
`python-shell-interpreter-args' to \"--simple-prompt\"."
  :version "31.1"
  :type 'string)

(defcustom python-shell-internal-buffer-name "Python Internal"
  "Default buffer name for the Internal Python interpreter."
  :type 'string
  :safe 'stringp)

(defcustom python-shell-interpreter-args "-i"
  "Arguments for the Python interpreter for interactive use."
  :type 'string)

(defcustom python-shell-interpreter-interactive-arg "-i"
  "Interpreter argument to force it to run interactively.
This is used only for prompt detection."
  :type 'string
  :version "24.4")

(defcustom python-shell-prompt-detect-enabled t
  "Non-nil enables autodetection of interpreter prompts."
  :type 'boolean
  :safe 'booleanp
  :version "24.4")

(defcustom python-shell-prompt-detect-failure-warning t
  "Non-nil enables warnings when detection of prompts fail."
  :type 'boolean
  :safe 'booleanp
  :version "24.4")

(defcustom python-shell-prompt-input-regexps
  '(">>> " "\\.\\.\\. "                 ; Python
    "In \\[[0-9]+\\]: "                 ; IPython
    "   \\.\\.\\.: "                    ; IPython
    ;; Using ipdb outside IPython may fail to cleanup and leave static
    ;; IPython prompts activated, this adds some safeguard for that.
    "In : " "\\.\\.\\.: ")
  "List of regular expressions matching input prompts."
  :type '(repeat regexp)
  :version "24.4")

(defcustom python-shell-prompt-output-regexps
  '(""                                  ; Python
    "Out\\[[0-9]+\\]: "                 ; IPython
    "Out :")                            ; ipdb safeguard
  "List of regular expressions matching output prompts."
  :type '(repeat regexp)
  :version "24.4")

(defcustom python-shell-prompt-regexp ">>> "
  "Regular expression matching top level input prompt of Python shell.
It should not contain a caret (^) at the beginning."
  :type 'regexp)

(defcustom python-shell-prompt-block-regexp "\\.\\.\\.:? "
  "Regular expression matching block input prompt of Python shell.
It should not contain a caret (^) at the beginning."
  :type 'regexp)

(defcustom python-shell-prompt-output-regexp ""
  "Regular expression matching output prompt of Python shell.
It should not contain a caret (^) at the beginning."
  :type 'regexp)

(defcustom python-shell-prompt-pdb-regexp "[(<]*[Ii]?[Pp]db[>)]+ "
  "Regular expression matching pdb input prompt of Python shell.
It should not contain a caret (^) at the beginning."
  :type 'regexp)

(define-obsolete-variable-alias
  'python-shell-enable-font-lock 'python-shell-font-lock-enable "25.1")

(defcustom python-shell-font-lock-enable t
  "Should syntax highlighting be enabled in the Python shell buffer?
Restart the Python shell after changing this variable for it to take effect."
  :type 'boolean
  :safe 'booleanp)

(defcustom python-shell-unbuffered t
  "Should shell output be unbuffered?.
When non-nil, this may prevent delayed and missing output in the
Python shell.  See commentary for details."
  :type 'boolean
  :safe 'booleanp)

(defcustom python-shell-process-environment nil
  "List of overridden environment variables for subprocesses to inherit.
Each element should be a string of the form ENVVARNAME=VALUE.
When this variable is non-nil, values are exported into the
process environment before starting it.  Any variables already
present in the current environment are superseded by variables
set here."
  :type '(repeat string))

(defcustom python-shell-extra-pythonpaths nil
  "List of extra pythonpaths for Python shell.
When this variable is non-nil, values added at the beginning of
the PYTHONPATH before starting processes.  Any values present
here that already exists in PYTHONPATH are moved to the beginning
of the list so that they are prioritized when looking for
modules."
  :type '(repeat string))

(defcustom python-shell-exec-path nil
  "List of paths for searching executables.
When this variable is non-nil, values added at the beginning of
the PATH before starting processes.  Any values present here that
already exists in PATH are moved to the beginning of the list so
that they are prioritized when looking for executables."
  :type '(repeat string))

(defcustom python-shell-remote-exec-path nil
  "List of paths to be ensured remotely for searching executables.
When this variable is non-nil, values are exported into remote
hosts PATH before starting processes.  Values defined in
`python-shell-exec-path' will take precedence to paths defined
here.  Normally you won't use this variable directly unless you
plan to ensure a particular set of paths to all Python shell
executed through tramp connections."
  :version "25.1"
  :type '(repeat string))

(define-obsolete-variable-alias
  'python-shell-virtualenv-path 'python-shell-virtualenv-root "25.1")

(defcustom python-shell-virtualenv-root nil
  "Path to virtualenv root.
This variable, when set to a string, makes the environment to be
modified such that shells are started within the specified
virtualenv."
  :type '(choice (const nil) directory))

(defcustom python-shell-setup-codes nil
  "List of code run by `python-shell-send-setup-code'."
  :type '(repeat symbol))

(defcustom python-shell-compilation-regexp-alist
  `((,(rx line-start (1+ (any " \t")) (? ?| (1+ (any " \t"))) "File \""
          (group (1+ (not (any "\"<")))) ; avoid `<stdin>' &c
          "\", line " (group (1+ digit)))
     1 2)
    (,(rx " in file " (group (1+ not-newline)) " on line "
          (group (1+ digit)))
     1 2)
    (,(rx line-start "> " (group (1+ (not (any "(\"<"))))
          "(" (group (1+ digit)) ")" (1+ (not (any "("))) "()")
     1 2))
  "`compilation-error-regexp-alist' for inferior Python."
  :type '(alist regexp)
  :version "30.1")

(defcustom python-shell-dedicated nil
  "Whether to make Python shells dedicated by default.
This option influences `run-python' when called without a prefix
argument.  If `buffer' or `project', create a Python shell
dedicated to the current buffer or its project (if one is found)."
  :version "29.1"
  :type '(choice (const :tag "To buffer" buffer)
                 (const :tag "To project" project)
                 (const :tag "Not dedicated" nil)))

(defvar python-shell-output-filter-in-progress nil)
(defvar python-shell-output-filter-buffer nil)

(defmacro python-shell--add-to-path-with-priority (pathvar paths)
  "Modify PATHVAR and ensure PATHS are added only once at beginning."
  `(dolist (path (reverse ,paths))
     (setq ,pathvar (cons path (cl-delete path ,pathvar :test #'string=)))))

(defun python-shell-calculate-pythonpath ()
  "Calculate the PYTHONPATH using `python-shell-extra-pythonpaths'."
  (let ((pythonpath
         (split-string
          (or (getenv "PYTHONPATH") "") path-separator 'omit)))
    (python-shell--add-to-path-with-priority
     pythonpath python-shell-extra-pythonpaths)
    (mapconcat #'identity pythonpath path-separator)))

(defun python-shell-calculate-process-environment ()
  (declare (obsolete python-shell--calculate-process-environment "29.1"))
  (defvar tramp-remote-process-environment)
  (let* ((remote-p (file-remote-p default-directory)))
    (append (python-shell--calculate-process-environment)
            (if remote-p
                tramp-remote-process-environment
              process-environment))))

(defun python-shell--calculate-process-environment ()
  "Return a list of entries to add to the `process-environment'.
Prepends `python-shell-process-environment', sets extra
pythonpaths from `python-shell-extra-pythonpaths' and sets a few
virtualenv related vars."
  (let* ((virtualenv (when python-shell-virtualenv-root
                       (directory-file-name python-shell-virtualenv-root)))
         (res python-shell-process-environment))
    (push "PYTHON_BASIC_REPL=1" res)
    (when python-shell-unbuffered
      (push "PYTHONUNBUFFERED=1" res))
    (when python-shell-extra-pythonpaths
      (push (concat "PYTHONPATH=" (python-shell-calculate-pythonpath)) res))
    (if (not virtualenv)
        nil
      (push "PYTHONHOME" res)
      (push (concat "VIRTUAL_ENV=" virtualenv) res))
    res))

(defun python-shell-calculate-exec-path ()
  "Calculate `exec-path'.
Prepends `python-shell-exec-path' and adds the binary directory
for virtualenv if `python-shell-virtualenv-root' is set - this
will use the python interpreter from inside the virtualenv when
starting the shell.  If `default-directory' points to a remote host,
the returned value appends `python-shell-remote-exec-path' instead
of `exec-path'."
  (let ((new-path (copy-sequence
                   (if (file-remote-p default-directory)
                       python-shell-remote-exec-path
                     exec-path)))

        ;; Windows and POSIX systems use different venv directory structures
        (virtualenv-bin-dir (if (eq system-type 'windows-nt) "Scripts" "bin")))
    (python-shell--add-to-path-with-priority
     new-path python-shell-exec-path)
    (if (not python-shell-virtualenv-root)
        new-path
      (python-shell--add-to-path-with-priority
       new-path
       (list (expand-file-name virtualenv-bin-dir python-shell-virtualenv-root)))
      new-path)))

(defun python-shell-tramp-refresh-remote-path (vec paths)
  "Update VEC's remote-path giving PATHS priority."
  (cl-assert (featurep 'tramp))
  (declare-function tramp-set-remote-path "tramp-sh")
  (declare-function tramp-set-connection-property "tramp-cache")
  (declare-function tramp-get-connection-property "tramp-cache")
  (let ((remote-path (tramp-get-connection-property vec "remote-path" nil)))
    (when remote-path
      ;; FIXME: This part of the Tramp code still knows about Python!
      (python-shell--add-to-path-with-priority remote-path paths)
      (tramp-set-connection-property vec "remote-path" remote-path)
      (tramp-set-remote-path vec))))


(defun python-shell-tramp-refresh-process-environment (vec env)
  "Update VEC's process environment with ENV."
  (cl-assert (featurep 'tramp))
  (defvar tramp-end-of-heredoc)
  (defvar tramp-end-of-output)
  ;; Do we even know that `tramp-sh' is loaded at this point?
  ;; What about files accessed via FTP, sudo, ...?
  (declare-function tramp-send-command "tramp-sh")
  ;; Stolen from `tramp-open-connection-setup-interactive-shell'.
  (let ((env (append (when (fboundp 'tramp-get-remote-locale)
                       ;; Emacs<24.4 compat.
                       (list (tramp-get-remote-locale vec)))
		     (copy-sequence env)))
        (tramp-end-of-heredoc
         (if (boundp 'tramp-end-of-heredoc)
             tramp-end-of-heredoc
           (md5 tramp-end-of-output)))
	unset vars item)
    (while env
      (setq item (split-string (car env) "=" 'omit))
      (setcdr item (mapconcat #'identity (cdr item) "="))
      (if (and (stringp (cdr item)) (not (string-equal (cdr item) "")))
	  (push (format "%s %s" (car item) (cdr item)) vars)
	(push (car item) unset))
      (setq env (cdr env)))
    (when vars
      (tramp-send-command
       vec
       (format "while read var val; do export $var=$val; done <<'%s'\n%s\n%s"
	       tramp-end-of-heredoc
	       (mapconcat #'identity vars "\n")
	       tramp-end-of-heredoc)
       t))
    (when unset
      (tramp-send-command
       vec (format "unset %s" (mapconcat #'identity unset " ")) t))))

(defmacro python-shell-with-environment (&rest body)
  "Modify shell environment during execution of BODY.
Temporarily sets `process-environment' and `exec-path' during
execution of body.  If `default-directory' points to a remote
machine then modifies `tramp-remote-process-environment' and
`python-shell-remote-exec-path' instead."
  (declare (indent 0) (debug (body)))
  `(python-shell--with-environment
    (python-shell--calculate-process-environment)
    (lambda () ,@body)))

(defun python-shell--with-environment (extraenv bodyfun)
  ;; FIXME: This is where the generic code delegates to Tramp.
  (let* ((vec
          (and (file-remote-p default-directory)
               (fboundp 'tramp-dissect-file-name)
               (ignore-errors
                 (tramp-dissect-file-name default-directory 'noexpand)))))
    (if vec
        (python-shell--tramp-with-environment vec extraenv bodyfun)
      (cl-letf (((default-value 'process-environment)
		 (append extraenv process-environment))
		((default-value 'exec-path)
		 ;; FIXME: This is still Python-specific.
		 (python-shell-calculate-exec-path)))
        (funcall bodyfun)))))

(defun python-shell--tramp-with-environment (vec extraenv bodyfun)
  (defvar tramp-remote-process-environment)
  (declare-function tramp-get-connection-process "tramp" (vec))
  (let* ((tramp-remote-process-environment
          (append extraenv tramp-remote-process-environment)))
    (when (tramp-get-connection-process vec)
      ;; For already existing connections, the new exec path must
      ;; be re-set, otherwise it won't take effect.  One example
      ;; of such case is when remote dir-locals are read and
      ;; *then* subprocesses are triggered within the same
      ;; connection.
      (python-shell-tramp-refresh-remote-path
       ;; FIXME: This is still Python-specific.
       vec (python-shell-calculate-exec-path))
      ;; The `tramp-remote-process-environment' variable is only
      ;; effective when the started process is an interactive
      ;; shell, otherwise (like in the case of processes started
      ;; with `process-file') the environment is not changed.
      ;; This makes environment modifications effective
      ;; unconditionally.
      (python-shell-tramp-refresh-process-environment
       vec tramp-remote-process-environment))
    (funcall bodyfun)))

(defvar python-shell--prompt-calculated-input-regexp nil
  "Calculated input prompt regexp for inferior python shell.
Do not set this variable directly, instead use
`python-shell-prompt-set-calculated-regexps'.")

(defvar python-shell--block-prompt nil
  "Input block prompt for inferior python shell.
Do not set this variable directly, instead use
`python-shell-prompt-set-calculated-regexps'.")

(defvar python-shell--prompt-calculated-output-regexp nil
  "Calculated output prompt regexp for inferior python shell.
Do not set this variable directly, instead use
`python-shell-prompt-set-calculated-regexps'.")

(defalias 'python--parse-json-array
  (if (fboundp 'json-parse-string)
      (lambda (string)
        (json-parse-string string :array-type 'list))
    (require 'json)
    (defvar json-array-type)
    (declare-function json-read-from-string "json" (string))
    (lambda (string)
      (let ((json-array-type 'list))
        (json-read-from-string string))))
  "Parse the JSON array in STRING into a Lisp list.")

(defun python-shell-prompt-detect ()
  "Detect prompts for the current `python-shell-interpreter'.
When prompts can be retrieved successfully from the
`python-shell-interpreter' run with
`python-shell-interpreter-interactive-arg', returns a list of
three elements, where the first two are input prompts and the
last one is an output prompt.  When no prompts can be detected
and `python-shell-prompt-detect-failure-warning' is non-nil,
shows a warning with instructions to avoid hangs and returns nil.
When `python-shell-prompt-detect-enabled' is nil avoids any
detection and just returns nil."
  (when python-shell-prompt-detect-enabled
    (python-shell-with-environment
      (let* ((code (concat
                    "import sys\n"
                    "ps = [getattr(sys, 'ps%s' % i, '') for i in range(1,4)]\n"
                    "try:\n"
                    "    import json\n"
                    "    ps_json = '\\n' + json.dumps(ps)\n"
                    "except ImportError:\n"
                    ;; JSON is built manually for compatibility
                    "    ps_json = '\\n[\"%s\", \"%s\", \"%s\"]\\n' % tuple(ps)\n"
                    "\n"
                    "print (ps_json)\n"
                    "sys.exit(0)\n"))
             (interpreter python-shell-interpreter)
             (interpreter-arg python-shell-interpreter-interactive-arg)
             (output
              (with-temp-buffer
                ;; TODO: improve error handling by using
                ;; `condition-case' and displaying the error message to
                ;; the user in the no-prompts warning.
                (ignore-errors
                  (let ((code-file
                         ;; Python 2.x on Windows does not handle
                         ;; carriage returns in unbuffered mode.
                         (let ((inhibit-eol-conversion (getenv "PYTHONUNBUFFERED")))
                           (python-shell--save-temp-file code))))
                    (unwind-protect
                        ;; Use `process-file' as it is remote-host friendly.
                        (process-file
                         interpreter
                         code-file
                         '(t nil)
                         nil
                         interpreter-arg)
                      ;; Try to cleanup
                      (delete-file code-file))))
                (buffer-string)))
             (prompts
              (catch 'prompts
                (dolist (line (split-string output "\n" t))
                  (let ((res
                         ;; Check if current line is a valid JSON array.
                         (and (string-prefix-p "[\"" line)
                              (ignore-errors
                                ;; Return prompts as a list.
                                (python--parse-json-array line)))))
                    ;; The list must contain 3 strings, where the first
                    ;; is the input prompt, the second is the block
                    ;; prompt and the last one is the output prompt.  The
                    ;; input prompt is the only one that can't be empty.
                    (when (and (= (length res) 3)
                               (cl-every #'stringp res)
                               (not (string= (car res) "")))
                      (throw 'prompts res))))
                nil)))
        (when (and (not prompts)
                   python-shell-prompt-detect-failure-warning)
          (lwarn
           '(python python-shell-prompt-regexp)
           :warning
           (concat
            "Python shell prompts cannot be detected.\n"
            "If your emacs session hangs when starting python shells\n"
            "recover with `keyboard-quit' and then try fixing the\n"
            "interactive flag for your interpreter by adjusting the\n"
            "`python-shell-interpreter-interactive-arg' or add regexps\n"
            "matching shell prompts in the directory-local friendly vars:\n"
            "  + `python-shell-prompt-regexp'\n"
            "  + `python-shell-prompt-block-regexp'\n"
            "  + `python-shell-prompt-output-regexp'\n"
            "Or alternatively in:\n"
            "  + `python-shell-prompt-input-regexps'\n"
            "  + `python-shell-prompt-output-regexps'")))
        (mapcar #'ansi-color-filter-apply prompts)))))

(defun python-shell-prompt-validate-regexps ()
  "Validate all user provided regexps for prompts.
Signals `user-error' if any of these vars contain invalid
regexps: `python-shell-prompt-regexp',
`python-shell-prompt-block-regexp',
`python-shell-prompt-pdb-regexp',
`python-shell-prompt-output-regexp',
`python-shell-prompt-input-regexps',
`python-shell-prompt-output-regexps'."
  (dolist (symbol (list 'python-shell-prompt-input-regexps
                        'python-shell-prompt-output-regexps
                        'python-shell-prompt-regexp
                        'python-shell-prompt-block-regexp
                        'python-shell-prompt-pdb-regexp
                        'python-shell-prompt-output-regexp))
    (dolist (regexp (let ((regexps (symbol-value symbol)))
                      (if (listp regexps)
                          regexps
                        (list regexps))))
      (when (not (python-util-valid-regexp-p regexp))
        (user-error "Invalid regexp %s in `%s'"
                    regexp symbol)))))

(defun python-shell-prompt-set-calculated-regexps ()
  "Detect and set input and output prompt regexps.
Build and set the values for
`python-shell--prompt-calculated-input-regexp' and
`python-shell--prompt-calculated-output-regexp' using the values
from `python-shell-prompt-regexp',
`python-shell-prompt-block-regexp',
`python-shell-prompt-pdb-regexp',
`python-shell-prompt-output-regexp',
`python-shell-prompt-input-regexps',
`python-shell-prompt-output-regexps' and detected prompts from
`python-shell-prompt-detect'."
  (when (not (and python-shell--prompt-calculated-input-regexp
                  python-shell--prompt-calculated-output-regexp))
    (let* ((detected-prompts (python-shell-prompt-detect))
           (input-prompts nil)
           (output-prompts nil)
           (build-regexp
            (lambda (prompts)
              (concat "^\\("
                      (mapconcat #'identity
                                 (sort prompts
                                       (lambda (a b)
                                         (let ((length-a (length a))
                                               (length-b (length b)))
                                           (if (= length-a length-b)
                                               (string< a b)
                                             (> (length a) (length b))))))
                                 "\\|")
                      "\\)"))))
      ;; Validate ALL regexps
      (python-shell-prompt-validate-regexps)
      ;; Collect all user defined input prompts
      (dolist (prompt (append python-shell-prompt-input-regexps
                              (list python-shell-prompt-regexp
                                    python-shell-prompt-block-regexp
                                    python-shell-prompt-pdb-regexp)))
        (cl-pushnew prompt input-prompts :test #'string=))
      ;; Collect all user defined output prompts
      (dolist (prompt (cons python-shell-prompt-output-regexp
                            python-shell-prompt-output-regexps))
        (cl-pushnew prompt output-prompts :test #'string=))
      ;; Collect detected prompts if any
      (when detected-prompts
        (dolist (prompt (butlast detected-prompts))
          (setq prompt (regexp-quote prompt))
          (cl-pushnew prompt input-prompts :test #'string=))
        (setq python-shell--block-prompt (nth 1 detected-prompts))
        (cl-pushnew (regexp-quote
                     (car (last detected-prompts)))
                    output-prompts :test #'string=))
      ;; Set input and output prompt regexps from collected prompts
      (setq python-shell--prompt-calculated-input-regexp
            (funcall build-regexp input-prompts)
            python-shell--prompt-calculated-output-regexp
            (funcall build-regexp output-prompts)))))

(defun python-shell-get-process-name (dedicated)
  "Calculate the appropriate process name for inferior Python process.
If DEDICATED is nil, this is simply `python-shell-buffer-name'.
If DEDICATED is `buffer' or `project', append the current buffer
name respectively the current project name."
  (pcase dedicated
    ('nil python-shell-buffer-name)
    ('project
     (if-let* ((proj (and (featurep 'project)
                          (project-current))))
         (format "%s[%s]" python-shell-buffer-name (file-name-nondirectory
                                                    (directory-file-name
                                                     (project-root proj))))
       python-shell-buffer-name))
    (_ (format "%s[%s]" python-shell-buffer-name (buffer-name)))))

(defun python-shell-internal-get-process-name ()
  "Calculate the appropriate process name for Internal Python process.
The name is calculated from `python-shell-buffer-name' and
the `buffer-name'."
  (format "%s[%s]" python-shell-internal-buffer-name (buffer-name)))

(defun python-shell-calculate-command ()
  "Calculate the string used to execute the inferior Python process."
  (format "%s %s"
          ;; `python-shell-make-comint' expects to be able to
          ;; `split-string-and-unquote' the result of this function.
          (combine-and-quote-strings (list python-shell-interpreter))
          python-shell-interpreter-args))

(define-obsolete-function-alias
  'python-shell-parse-command
  #'python-shell-calculate-command "25.1")

(defvar python-shell--package-depth 10)

(defun python-shell-package-enable (directory package)
  "Add DIRECTORY parent to $PYTHONPATH and enable PACKAGE."
  (interactive
   (let* ((dir (expand-file-name
                (read-directory-name
                 "Package root: "
                 (file-name-directory
                  (or (buffer-file-name) default-directory)))))
          (name (completing-read
                 "Package: "
                 (python-util-list-packages
                  dir python-shell--package-depth))))
     (list dir name)))
  (python-shell-send-string
   (format
    (concat
     "import os.path;import sys;"
     "sys.path.append(os.path.dirname(os.path.dirname(%s)));"
     "__package__ = %s;"
     "import %s")
    (python-shell--encode-string directory)
    (python-shell--encode-string package)
    package)
   (python-shell-get-process)))

(defun python-shell-accept-process-output (process &optional timeout regexp)
  "Accept PROCESS output with TIMEOUT until REGEXP is found.
Optional argument TIMEOUT is the timeout argument to
`accept-process-output' calls.  Optional argument REGEXP
overrides the regexp to match the end of output, defaults to
`comint-prompt-regexp'.  Returns non-nil when output was
properly captured.

This utility is useful in situations where the output may be
received in chunks, since `accept-process-output' gives no
guarantees they will be grabbed in a single call.  An example use
case for this would be the CPython shell start-up, where the
banner and the initial prompt are received separately."
  (let ((regexp (or regexp comint-prompt-regexp)))
    (catch 'found
      (while t
        (when (not (accept-process-output process timeout))
          (throw 'found nil))
        (when (looking-back
               regexp (car (python-util-comint-last-prompt)))
          (throw 'found t))))))

(defun python-shell-comint-end-of-output-p (output)
  "Return non-nil if OUTPUT ends with input prompt."
  (string-match
   ;; XXX: It seems on macOS an extra carriage return is attached
   ;; at the end of output, this handles that too.
   (concat
    "\r?\n?"
    ;; Remove initial caret from calculated regexp
    (replace-regexp-in-string
     (rx string-start ?^) ""
     python-shell--prompt-calculated-input-regexp)
    (rx eos))
   output))

(define-obsolete-function-alias
  'python-comint-output-filter-function
  #'ansi-color-filter-apply
  "25.1")

(defun python-comint-postoutput-scroll-to-bottom (output)
  "Faster version of `comint-postoutput-scroll-to-bottom'.
Avoids `recenter' calls until OUTPUT is completely sent."
  (declare (obsolete nil "29.1")) ; Not used.
  (when (and (not (string= "" output))
             (python-shell-comint-end-of-output-p
              (ansi-color-filter-apply output)))
    (comint-postoutput-scroll-to-bottom output))
  output)

(defvar python-shell--parent-buffer nil)

(defmacro python-shell-with-shell-buffer (&rest body)
  "Execute the forms in BODY with the shell buffer temporarily current.
Signals an error if no shell buffer is available for current buffer."
  (declare (indent 0) (debug t))
  (let ((shell-process (make-symbol "shell-process")))
    `(let ((,shell-process (python-shell-get-process-or-error)))
       (with-current-buffer (process-buffer ,shell-process)
         ,@body))))

(defvar python-shell--font-lock-buffer nil)

(defun python-shell-font-lock-get-or-create-buffer ()
  "Get or create a font-lock buffer for current inferior process."
  (python-shell-with-shell-buffer
    (if python-shell--font-lock-buffer
        python-shell--font-lock-buffer
      (let ((process-name
             (process-name (get-buffer-process (current-buffer)))))
        (generate-new-buffer
         (format " *%s-font-lock*" process-name))))))

(defun python-shell-font-lock-kill-buffer ()
  "Kill the font-lock buffer safely."
  (when (and python-shell--font-lock-buffer
             (buffer-live-p python-shell--font-lock-buffer))
    (kill-buffer python-shell--font-lock-buffer)
    (when (derived-mode-p 'inferior-python-mode)
      (setq python-shell--font-lock-buffer nil))))

(defmacro python-shell-font-lock-with-font-lock-buffer (&rest body)
  "Execute the forms in BODY in the font-lock buffer.
The value returned is the value of the last form in BODY.  See
also `with-current-buffer'."
  (declare (indent 0) (debug t))
  `(python-shell-with-shell-buffer
     (save-current-buffer
       (when (not (and python-shell--font-lock-buffer
                       (get-buffer python-shell--font-lock-buffer)))
         (setq python-shell--font-lock-buffer
               (python-shell-font-lock-get-or-create-buffer)))
       (set-buffer python-shell--font-lock-buffer)
       (when (not font-lock-mode)
         (font-lock-mode 1))
       (setq-local delay-mode-hooks t)
       (let ((python-indent-guess-indent-offset nil))
         (when (not (derived-mode-p 'python-mode))
           (python-mode))
         ,@body))))

(defun python-shell-font-lock-cleanup-buffer ()
  "Cleanup the font-lock buffer.
Provided as a command because this might be handy if something
goes wrong and syntax highlighting in the shell gets messed up."
  (interactive)
  (python-shell-with-shell-buffer
    (python-shell-font-lock-with-font-lock-buffer
      (erase-buffer))))

(defun python-shell-font-lock-comint-output-filter-function (output)
  "Clean up the font-lock buffer after any OUTPUT."
   (unless (string= output "") ;; See Bug#33959.
    (if (let ((output (ansi-color-filter-apply output)))
          (and (python-shell-comint-end-of-output-p output)
               ;; Assume "..." represents a continuation prompt.
               (not (string-match "\\.\\.\\." output))))
        ;; If output ends with an initial (not continuation) input prompt
        ;; then the font-lock buffer must be cleaned up.
        (python-shell-font-lock-cleanup-buffer)
      ;; Otherwise just add a newline.
      (python-shell-font-lock-with-font-lock-buffer
        (goto-char (point-max))
        (newline)))
    output))

(defun python-shell-font-lock-post-command-hook ()
  "Fontifies current line in shell buffer."
  (let ((prompt-end (cdr (python-util-comint-last-prompt))))
    (when (and prompt-end (> (point) prompt-end)
               (process-live-p (get-buffer-process (current-buffer))))
      (let* ((input (buffer-substring-no-properties
                     prompt-end (point-max)))
             (deactivate-mark nil)
             (start-pos prompt-end)
             (buffer-undo-list t)
             (replacement
              (python-shell-font-lock-with-font-lock-buffer
                (delete-region (point-min) (point-max))
                (insert input)
                (font-lock-ensure)
                (buffer-string)))
             (replacement-length (length replacement))
             (i 0))
        ;; Inject text properties to get input fontified.
        (while (not (= i replacement-length))
          (let* ((plist (text-properties-at i replacement))
                 (next-change (or (next-property-change i replacement)
                                  replacement-length))
                 (plist (let ((face (plist-get plist 'face)))
                          (if (not face)
                              plist
                            ;; Replace FACE text properties with
                            ;; FONT-LOCK-FACE so input is fontified.
                            (plist-put plist 'face nil)
                            (plist-put plist 'font-lock-face face)))))
            (set-text-properties
             (+ start-pos i) (+ start-pos next-change) plist)
            (setq i next-change)))))))

(defun python-shell-font-lock-turn-on (&optional msg)
  "Turn on shell font-lock.
With argument MSG show activation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (python-shell-font-lock-kill-buffer)
    (setq-local python-shell--font-lock-buffer nil)
    (add-hook 'post-command-hook
              #'python-shell-font-lock-post-command-hook nil 'local)
    (add-hook 'kill-buffer-hook
              #'python-shell-font-lock-kill-buffer nil 'local)
    (add-hook 'comint-output-filter-functions
              #'python-shell-font-lock-comint-output-filter-function
              'append 'local)
    (when msg
      (message "Shell font-lock is enabled"))))

(defun python-shell-font-lock-turn-off (&optional msg)
  "Turn off shell font-lock.
With argument MSG show deactivation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (python-shell-font-lock-kill-buffer)
    (when (python-util-comint-last-prompt)
      ;; Cleanup current fontification
      (remove-text-properties
       (cdr (python-util-comint-last-prompt))
       (line-end-position)
       '(face nil font-lock-face nil)))
    (setq-local python-shell--font-lock-buffer nil)
    (remove-hook 'post-command-hook
                 #'python-shell-font-lock-post-command-hook 'local)
    (remove-hook 'kill-buffer-hook
                 #'python-shell-font-lock-kill-buffer 'local)
    (remove-hook 'comint-output-filter-functions
                 #'python-shell-font-lock-comint-output-filter-function
                 'local)
    (when msg
      (message "Shell font-lock is disabled"))))

(defun python-shell-font-lock-toggle (&optional msg)
  "Toggle font-lock for shell.
With argument MSG show activation/deactivation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (setq-local python-shell-font-lock-enable
                (not python-shell-font-lock-enable))
    (if python-shell-font-lock-enable
        (python-shell-font-lock-turn-on msg)
      (python-shell-font-lock-turn-off msg))
    python-shell-font-lock-enable))

(defvar python-shell--first-prompt-received-output-buffer nil)
(defvar python-shell--first-prompt-received nil)

(defcustom python-shell-first-prompt-hook nil
  "Hook run upon first (non-pdb) shell prompt detection.
This is the place for shell setup functions that need to wait for
output.  Since the first prompt is ensured, this helps the
current process to not hang while waiting.  This is useful to
safely attach setup code for long-running processes that
eventually provide a shell."
  :version "25.1"
  :type 'hook)

(defconst python-shell-setup-code
  "\
try:
    import termios
except ImportError:
    pass
else:
    attr = termios.tcgetattr(0)
    attr[3] &= ~termios.ECHO
    termios.tcsetattr(0, termios.TCSADRAIN, attr)"
  "Code used to setup the inferior Python processes.")

(defconst python-shell-eval-setup-code
  "\
def __PYTHON_EL_eval(source, filename):
    import ast, sys
    if sys.version_info[0] == 2:
        from __builtin__ import compile, eval, globals
    else:
        from builtins import compile, eval, globals
    try:
        p, e = ast.parse(source, filename), None
    except SyntaxError:
        t, v, tb = sys.exc_info()
        sys.excepthook(t, v, tb.tb_next)
        return
    if p.body and isinstance(p.body[-1], ast.Expr):
        e = p.body.pop()
    try:
        g = globals()
        exec(compile(p, filename, 'exec'), g, g)
        if e:
            return eval(compile(ast.Expression(e.value), filename, 'eval'), g, g)
    except Exception:
        t, v, tb = sys.exc_info()
        sys.excepthook(t, v, tb.tb_next)"
  "Code used to evaluate statements in inferior Python processes.")

(defconst python-shell-eval-file-setup-code
  "\
def __PYTHON_EL_eval_file(filename, tempname, delete):
    import codecs, os, re
    pattern = r'^[ \t\f]*#.*?coding[:=][ \t]*([-_.a-zA-Z0-9]+)'
    with codecs.open(tempname or filename, encoding='latin-1') as file:
        match = re.match(pattern, file.readline())
        match = match or re.match(pattern, file.readline())
        encoding = match.group(1) if match else 'utf-8'
    with codecs.open(tempname or filename, encoding=encoding) as file:
        source = file.read().encode(encoding)
    if delete and tempname:
        os.remove(tempname)
    return __PYTHON_EL_eval(source, filename)"
  "Code used to evaluate files in inferior Python processes.
The coding cookie regexp is specified in PEP 263.")

(defun python-shell-comint-watch-for-first-prompt-output-filter (output)
  "Run `python-shell-first-prompt-hook' when first prompt is found in OUTPUT."
  (when (not python-shell--first-prompt-received)
    (setq-local python-shell--first-prompt-received-output-buffer
                (concat python-shell--first-prompt-received-output-buffer
                        (ansi-color-filter-apply output)))
    (when (python-shell-comint-end-of-output-p
           python-shell--first-prompt-received-output-buffer)
      (if (string-match-p
           (concat python-shell-prompt-pdb-regexp (rx eos))
           (or python-shell--first-prompt-received-output-buffer ""))
          ;; Skip pdb prompts and reset the buffer.
          (setq python-shell--first-prompt-received-output-buffer nil)
        (setq-local python-shell--first-prompt-received t)
        (setq python-shell--first-prompt-received-output-buffer nil)
        (cl-letf (((symbol-function 'python-shell-send-string)
                   (lambda (string process)
                     (comint-send-string
                      process
                      (format "exec(%s)\n" (python-shell--encode-string string))))))
          ;; Bootstrap: the normal definition of `python-shell-send-string'
          ;; depends on the Python code sent here.
          (python-shell-send-string-no-output python-shell-setup-code)
          (python-shell-send-string-no-output python-shell-eval-setup-code)
          (python-shell-send-string-no-output python-shell-eval-file-setup-code))
        (with-current-buffer (current-buffer)
          (let ((inhibit-quit nil))
            (python-shell-readline-detect)
            (run-hooks 'python-shell-first-prompt-hook))))))
  output)

;; Used to hold user interactive overrides to
;; `python-shell-interpreter' and `python-shell-interpreter-args' that
;; will be made buffer-local by `inferior-python-mode':
(defvar python-shell--interpreter)
(defvar python-shell--interpreter-args)

(define-derived-mode inferior-python-mode comint-mode "Inferior Python"
  "Major mode for Python inferior process.
Runs a Python interpreter as a subprocess of Emacs, with Python
I/O through an Emacs buffer.  Variables `python-shell-interpreter'
and `python-shell-interpreter-args' control which Python
interpreter is run.  Variables
`python-shell-prompt-regexp',
`python-shell-prompt-output-regexp',
`python-shell-prompt-block-regexp',
`python-shell-font-lock-enable',
`python-shell-completion-setup-code',
`python-eldoc-setup-code',
`python-ffap-setup-code' can
customize this mode for different Python interpreters.

This mode resets `comint-output-filter-functions' locally, so you
may want to re-add custom functions to it using the
`inferior-python-mode-hook'.

You can also add additional setup code to be run at
initialization of the interpreter via `python-shell-setup-codes'
variable.

\(Type \\[describe-mode] in the process buffer for a list of commands.)"
  (when python-shell--parent-buffer
    (python-util-clone-local-variables python-shell--parent-buffer))
  (setq-local indent-tabs-mode nil)
  ;; Users can interactively override default values for
  ;; `python-shell-interpreter' and `python-shell-interpreter-args'
  ;; when calling `run-python'.  This ensures values let-bound in
  ;; `python-shell-make-comint' are locally set if needed.
  (setq-local python-shell-interpreter
              (or python-shell--interpreter python-shell-interpreter))
  (setq-local python-shell-interpreter-args
              (or python-shell--interpreter-args python-shell-interpreter-args))
  (setq-local python-shell--prompt-calculated-input-regexp nil)
  (setq-local python-shell--block-prompt nil)
  (setq-local python-shell--prompt-calculated-output-regexp nil)
  (python-shell-prompt-set-calculated-regexps)
  (setq comint-prompt-regexp python-shell--prompt-calculated-input-regexp)
  (setq-local comint-prompt-read-only t)
  (setq mode-line-process '(":%s"))
  (setq-local comint-output-filter-functions
              '(ansi-color-process-output
                python-shell-comint-watch-for-first-prompt-output-filter
                comint-watch-for-password-prompt))
  (setq-local comint-highlight-input nil)
  (setq-local compilation-error-regexp-alist
              python-shell-compilation-regexp-alist)
  (setq-local scroll-conservatively 1)
  (setq-local comint-dynamic-complete-functions
              '(comint-c-a-p-replace-by-expanded-history))
  (add-hook 'completion-at-point-functions
            #'python-shell-completion-at-point nil 'local)
  (define-key inferior-python-mode-map "\t"
    #'python-shell-completion-complete-or-indent)
  (make-local-variable 'python-shell-internal-last-output)
  (when python-shell-font-lock-enable
    (python-shell-font-lock-turn-on))
  (compilation-shell-minor-mode 1)
  (python-pdbtrack-setup-tracking))

(defun python-shell-make-comint (cmd proc-name &optional show internal)
  "Create a Python shell comint buffer.
CMD is the Python command to be executed and PROC-NAME is the
process name the comint buffer will get.  After the comint buffer
is created the `inferior-python-mode' is activated.  When
optional argument SHOW is non-nil the buffer is shown.  When
optional argument INTERNAL is non-nil this process is run on a
buffer with a name that starts with a space, following the Emacs
convention for temporary/internal buffers, and also makes sure
the user is not queried for confirmation when the process is
killed."
  (save-excursion
    (python-shell-with-environment
      (let* ((proc-buffer-name
              (format (if (not internal) "*%s*" " *%s*") proc-name)))
        (when (not (comint-check-proc proc-buffer-name))
          (let* ((cmdlist (split-string-and-unquote cmd))
                 (interpreter (car cmdlist))
                 (args (cdr cmdlist))
                 (buffer (apply #'make-comint-in-buffer proc-name
                                proc-buffer-name
                                interpreter nil args))
                 (python-shell--parent-buffer (current-buffer))
                 (process (get-buffer-process buffer))
                 ;; Users can override the interpreter and args
                 ;; interactively when calling `run-python', let-binding
                 ;; these allows having the new right values in all
                 ;; setup code that is done in `inferior-python-mode',
                 ;; which is important, especially for prompt detection.
                 (python-shell--interpreter interpreter)
                 (python-shell--interpreter-args
                  (mapconcat #'identity args " ")))
            (with-current-buffer buffer
              (inferior-python-mode))
            (and internal (set-process-query-on-exit-flag process nil))))
        (when show
          (pop-to-buffer proc-buffer-name))
        proc-buffer-name))))

;;;###autoload
(defun run-python (&optional cmd dedicated show)
  "Run an inferior Python process.

Argument CMD defaults to `python-shell-calculate-command' return
value.  When called interactively with `prefix-arg', it allows
the user to edit such value and choose whether the interpreter
should be DEDICATED to the current buffer or project.  When
numeric prefix arg is other than 0 or 4 do not SHOW.

For a given buffer and same values of DEDICATED, if a process is
already running for it, it will do nothing.  This means that if
the current buffer is using a global process, the user is still
able to switch it to use a dedicated one.

Runs the hook `inferior-python-mode-hook' after
`comint-mode-hook' is run.  (Type \\[describe-mode] in the
process buffer for a list of commands.)"
  (interactive
   (if current-prefix-arg
       (list
        (read-shell-command "Run Python: " (python-shell-calculate-command))
        (alist-get (car (read-multiple-choice "Make dedicated process?"
                                              '((?b "to buffer")
                                                (?p "to project")
                                                (?n "no"))))
                   '((?b . buffer) (?p . project)))
        (= (prefix-numeric-value current-prefix-arg) 4))
     (list (python-shell-calculate-command)
           python-shell-dedicated
           t)))
  (let* ((project (and (eq 'project dedicated)
                       (featurep 'project)
                       (project-current t)))
         (default-directory (if project
                                (project-root project)
                              default-directory))
         (buffer (python-shell-make-comint
                  (or cmd (python-shell-calculate-command))
                  (python-shell-get-process-name dedicated)
                  show)))
    (get-buffer-process buffer)))

(defun python-shell-restart (&optional show)
  "Restart the Python shell.
Optional argument SHOW (interactively, the prefix argument), if
non-nil, means also display the Python shell buffer."
  (interactive "P")
  (with-current-buffer
      (or (and (derived-mode-p 'inferior-python-mode)
               (current-buffer))
          (seq-some (lambda (dedicated)
                      (get-buffer (format "*%s*" (python-shell-get-process-name
                                                  dedicated))))
                    '(buffer project nil))
          (user-error "No Python shell"))
    (when-let* ((proc (get-buffer-process (current-buffer))))
      (kill-process proc)
      (while (accept-process-output proc)))
    (python-shell-make-comint (python-shell-calculate-command)
                              (string-trim (buffer-name) "\\*" "\\*")
                              show)))

(defun run-python-internal ()
  "Run an inferior Internal Python process.
Input and output via buffer named after
`python-shell-internal-buffer-name' and what
`python-shell-internal-get-process-name' returns.

This new kind of shell is intended to be used for generic
communication related to defined configurations; the main
difference with global or dedicated shells is that these ones are
attached to a configuration, not a buffer.  This means that can
be used for example to retrieve the sys.path and other stuff,
without messing with user shells.  Note that
`python-shell-font-lock-enable' and `inferior-python-mode-hook'
are set to nil for these shells, so setup codes are not sent at
startup."
  (let ((python-shell-font-lock-enable nil)
        (inferior-python-mode-hook nil))
    (get-buffer-process
     (python-shell-make-comint
      (python-shell-calculate-command)
      (python-shell-internal-get-process-name) nil t))))

(defun python-shell-get-buffer ()
  "Return inferior Python buffer for current buffer.
If current buffer is in `inferior-python-mode', return it."
  (if (derived-mode-p 'inferior-python-mode)
      (current-buffer)
    (seq-some
     (lambda (dedicated)
       (let* ((proc-name (python-shell-get-process-name dedicated))
              (buffer-name (format "*%s*" proc-name)))
         (when (comint-check-proc buffer-name)
           buffer-name)))
     '(buffer project nil))))

(defun python-shell-get-process ()
  "Return inferior Python process for current buffer."
  (get-buffer-process (python-shell-get-buffer)))

(defun python-shell-get-process-or-error (&optional interactivep)
  "Return inferior Python process for current buffer or signal error.
When argument INTERACTIVEP is non-nil, use `user-error' instead
of `error' with a user-friendly message."
  (or (python-shell-get-process)
      (if interactivep
          (user-error
           (substitute-command-keys
            "Start a Python process first with \\`M-x run-python' or `%s'")
           ;; Get the binding.
           (key-description
            (where-is-internal
             #'run-python overriding-local-map t)))
        (error "No inferior Python process running"))))

(defun python-shell-get-or-create-process (&optional cmd dedicated show)
  "Get or create an inferior Python process for current buffer and return it.
Arguments CMD, DEDICATED and SHOW are those of `run-python' and
are used to start the shell.  If those arguments are not
provided, `run-python' is called interactively and the user will
be asked for their values."
  (let ((shell-process (python-shell-get-process)))
    (when (not shell-process)
      (if (not cmd)
          ;; XXX: Refactor code such that calling `run-python'
          ;; interactively is not needed anymore.
          (call-interactively 'run-python)
        (run-python cmd dedicated show)))
    (or shell-process (python-shell-get-process))))

(make-obsolete
 #'python-shell-get-or-create-process
 "Instead call `python-shell-get-process' and create one if returns nil."
 "25.1")

(defvar python-shell-internal-buffer nil
  "Current internal shell buffer for the current buffer.
This is really not necessary at all for the code to work but it's
there for compatibility with CEDET.")

(defvar python-shell-internal-last-output nil
  "Last output captured by the internal shell.
This is really not necessary at all for the code to work but it's
there for compatibility with CEDET.")

(defun python-shell-internal-get-or-create-process ()
  "Get or create an inferior Internal Python process."
  (let ((proc-name (python-shell-internal-get-process-name)))
    (if (process-live-p proc-name)
        (get-process proc-name)
      (run-python-internal))))

(defun python-shell--save-temp-file (string)
  (let* ((temporary-file-directory
          (if (file-remote-p default-directory)
              (concat (file-remote-p default-directory) "/tmp")
            temporary-file-directory))
         (temp-file-name (make-temp-file "py"))
         (coding-system-for-write (python-info-encoding)))
    (with-temp-file temp-file-name
      (if (bufferp string)
          (insert-buffer-substring string)
        (insert string))
      (delete-trailing-whitespace))
    temp-file-name))

(defalias 'python-shell--encode-string
  (let ((fun (if (and (fboundp 'json-serialize)
                      (>= emacs-major-version 28))
                 'json-serialize
               (require 'json)
               'json-encode-string)))
    (lambda (text)
      (if (stringp text)
          (funcall fun text)
        (signal 'wrong-type-argument (list 'stringp text)))))
  "Encode TEXT as a valid Python string.")

(defun python-shell-send-string (string &optional process msg)
  "Send STRING to inferior Python PROCESS.
When optional argument MSG is non-nil, forces display of a
user-friendly message if there's no process running; defaults to
t when called interactively."
  (interactive
   (list (read-string "Python command: ") nil t))
  (let ((process (or process (python-shell-get-process-or-error msg)))
        (code (format "__PYTHON_EL_eval(%s, %s)\n"
                      (python-shell--encode-string string)
                      (python-shell--encode-string (or (buffer-file-name)
                                                       "<string>")))))
    (unless python-shell-output-filter-in-progress
      (with-current-buffer (process-buffer process)
        (save-excursion
          (goto-char (process-mark process))
          (insert-before-markers "\n"))))
    (if (or (null (process-tty-name process))
            (<= (string-bytes code)
                (or (bound-and-true-p comint-max-line-length)
                    1024))) ;; For Emacs < 28
        (comint-send-string process code)
      (let* ((temp-file-name (with-current-buffer (process-buffer process)
                               (python-shell--save-temp-file string)))
             (file-name (or (buffer-file-name) temp-file-name)))
        (python-shell-send-file file-name process temp-file-name t)))))

(defun python-shell-output-filter (string)
  "Filter used in `python-shell-send-string-no-output' to grab output.
STRING is the output received to this point from the process.
This filter saves received output from the process in
`python-shell-output-filter-buffer' and stops receiving it after
detecting a prompt at the end of the buffer."
  (setq
   string (ansi-color-filter-apply string)
   python-shell-output-filter-buffer
   (concat python-shell-output-filter-buffer string))
  (when (python-shell-comint-end-of-output-p
         python-shell-output-filter-buffer)
    ;; Output ends when `python-shell-output-filter-buffer' contains
    ;; the prompt attached at the end of it.
    (setq python-shell-output-filter-in-progress nil
          python-shell-output-filter-buffer
          (substring python-shell-output-filter-buffer
                     0 (match-beginning 0)))
    (when (string-match
           python-shell--prompt-calculated-output-regexp
           python-shell-output-filter-buffer)
      ;; Some shells, like IPython might append a prompt before the
      ;; output, clean that.
      (setq python-shell-output-filter-buffer
            (substring python-shell-output-filter-buffer (match-end 0)))))
  "")

(defun python-shell-send-string-no-output (string &optional process)
  "Send STRING to PROCESS and inhibit output.
Return the output."
  (or process (setq process (python-shell-get-process-or-error)))
  (cl-letf* (((process-filter process)
              (lambda (_proc str)
                (with-current-buffer (process-buffer process)
                  (python-shell-output-filter str))))
             (python-shell-output-filter-in-progress t)
             (inhibit-quit t)
             (buffer (process-buffer process))
             (last-prompt (cond ((boundp 'comint-last-prompt-overlay)
                                 'comint-last-prompt-overlay)
                                ((boundp 'comint-last-prompt)
                                 'comint-last-prompt)))
             (last-prompt-value (buffer-local-value last-prompt buffer)))
    (or
     (with-local-quit
       (unwind-protect
           (python-shell-send-string string process)
         (when (not (null last-prompt))
           (with-current-buffer buffer
             (set last-prompt last-prompt-value))))
       (while python-shell-output-filter-in-progress
         ;; `python-shell-output-filter' takes care of setting
         ;; `python-shell-output-filter-in-progress' to NIL after it
         ;; detects end of output.
         (accept-process-output process))
       (prog1
           python-shell-output-filter-buffer
         (setq python-shell-output-filter-buffer nil)))
     (with-current-buffer buffer
       (comint-interrupt-subjob)))))

(defun python-shell-internal-send-string (string)
  "Send STRING to the Internal Python interpreter.
Returns the output.  See `python-shell-send-string-no-output'."
  ;; XXX Remove `python-shell-internal-last-output' once CEDET is
  ;; updated to support this new mode.
  (setq python-shell-internal-last-output
        (python-shell-send-string-no-output
         ;; Makes this function compatible with the old
         ;; python-send-receive. (At least for CEDET).
         (replace-regexp-in-string "_emacs_out +" "" string)
         (python-shell-internal-get-or-create-process))))

(defun python-shell-buffer-substring (start end &optional nomain no-cookie)
  "Send buffer substring from START to END formatted for shell.
This is a wrapper over `buffer-substring' that takes care of
different transformations for the code sent to be evaluated in
the python shell:
  1. When optional argument NOMAIN is non-nil everything under an
     \"if __name__ == \\='__main__\\='\" block will be removed.
  2. When a subregion of the buffer is sent, it takes care of
     appending extra empty lines so tracebacks are correct.
  3. When the region sent is a substring of the current buffer, a
     coding cookie is added.
  4. When the region consists of a single statement, leading
     whitespaces will be removed.  Otherwise, wraps indented
     regions under an \"if True:\" block so the interpreter
     evaluates them correctly."
  (let* ((single-p (save-excursion
                     (save-restriction
                       (narrow-to-region start end)
                       (= (progn
                            (goto-char start)
                            (python-nav-beginning-of-statement))
                          (progn
                            (goto-char end)
                            (python-nav-beginning-of-statement))))))
         (start (save-excursion
                  ;; If we're at the start of the expression, and if
                  ;; the region consists of a single statement, then
                  ;; remove leading whitespaces, else if there's just
                  ;; blank space ahead of it, then expand the region
                  ;; to include the start of the line.  This makes
                  ;; things work better with the rest of the data
                  ;; we're sending over.
                  (goto-char start)
                  (if single-p
                      (progn
                        (skip-chars-forward "[:space:]" end)
                        (point))
                    (if (string-blank-p
                         (buffer-substring (line-beginning-position) start))
                        (line-beginning-position)
                      start))))
         (substring (buffer-substring-no-properties start end))
         (starts-at-first-line-p (save-excursion
                                   (save-restriction
                                     (widen)
                                     (goto-char start)
                                     (= (line-number-at-pos) 1))))
         (encoding (python-info-encoding))
         (toplevel-p (zerop (save-excursion
                              (goto-char start)
                              (python-util-forward-comment 1)
                              (current-indentation))))
         (fillstr (cond (starts-at-first-line-p
                         nil)
                        ((not no-cookie)
                         (concat
                          (format "# -*- coding: %s -*-\n" encoding)
                          (make-string
                           ;; Subtract 2 because of the coding cookie.
                           (- (line-number-at-pos start) 2) ?\n)))
                        (t
                         (make-string (- (line-number-at-pos start) 1) ?\n)))))
    (with-temp-buffer
      (python-mode)
      (when fillstr
        (insert fillstr))
      (when (and (not single-p) (not toplevel-p))
        (forward-line -1)
        (insert "if True:\n")
        (delete-region (point) (line-end-position)))
      (insert substring)
      (when nomain
        (let* ((if-name-main-start-end
                (and nomain
                     (save-excursion
                       (when (python-nav-if-name-main)
                         (cons (point)
                               (progn (python-nav-forward-sexp-safe)
                                      ;; Include ending newline
                                      (forward-line 1)
                                      (point)))))))
               ;; Oh destructuring bind, how I miss you.
               (if-name-main-start (car if-name-main-start-end))
               (if-name-main-end (cdr if-name-main-start-end))
               (fillstr (make-string
                         (- (line-number-at-pos if-name-main-end)
                            (line-number-at-pos if-name-main-start)) ?\n)))
          (when if-name-main-start-end
            (goto-char if-name-main-start)
            (delete-region if-name-main-start if-name-main-end)
            (insert fillstr))))
      ;; Ensure there's only one coding cookie in the generated string.
      (goto-char (point-min))
      (when (looking-at-p (python-rx coding-cookie))
        (forward-line 1)
        (when (looking-at-p (python-rx coding-cookie))
          (delete-region
           (line-beginning-position) (line-end-position))))
      (buffer-substring-no-properties (point-min) (point-max)))))

(declare-function compilation-forget-errors "compile")

(defun python-shell-send-region (start end &optional send-main msg
                                       no-cookie)
  "Send the region delimited by START and END to inferior Python process.
When optional argument SEND-MAIN is non-nil, allow execution of
code inside blocks delimited by \"if __name__== \\='__main__\\=':\".
When called interactively SEND-MAIN defaults to nil, unless it's
called with prefix argument.  When optional argument MSG is
non-nil, forces display of a user-friendly message if there's no
process running; defaults to t when called interactively.  The
substring to be sent is retrieved using `python-shell-buffer-substring'."
  (interactive
   (list (region-beginning) (region-end) current-prefix-arg t))
  (let* ((string (python-shell-buffer-substring start end (not send-main)
                                                no-cookie))
         (process (python-shell-get-process-or-error msg))
         (original-string (buffer-substring-no-properties start end))
         (_ (string-match "\\`\n*\\(.*\\)" original-string)))
    (message "Sent: %s..." (match-string 1 original-string))
    ;; Recalculate positions to avoid landing on the wrong line if
    ;; lines have been removed/added.
    (with-current-buffer (process-buffer process)
      (compilation-forget-errors))
    (python-shell-send-string string process)
    (deactivate-mark)))

(defun python-shell-send-statement (&optional send-main msg)
  "Send the statement at point to inferior Python process.
The statement is delimited by `python-nav-beginning-of-statement' and
`python-nav-end-of-statement', but if the region  is active, the text
in the region is sent instead via `python-shell-send-region'.
Optional argument SEND-MAIN, if non-nil, means allow execution of code
inside blocks delimited by \"if __name__ == \\='__main__\\=':\".
Interactively, SEND-MAIN is the prefix argument.
Optional argument MSG, if non-nil, forces display of a user-friendly
message if there's no process running; it defaults to t when called
interactively."
  (interactive (list current-prefix-arg t))
  (if (region-active-p)
      (python-shell-send-region (region-beginning) (region-end) send-main msg)
    (python-shell-send-region
     (save-excursion (python-nav-beginning-of-statement))
     (save-excursion (python-nav-end-of-statement))
     send-main msg t)))

(defun python-shell-send-block (&optional arg msg)
  "Send the block at point to inferior Python process.
The block is delimited by `python-nav-beginning-of-block' and
`python-nav-end-of-block'.  If optional argument ARG is non-nil
\(interactively, the prefix argument), send the block body with
its header.  If optional argument MSG is non-nil, force display
of a user-friendly message if there's no process running; this
always happens interactively."
  (interactive (list current-prefix-arg t))
  (let ((beg (save-excursion
               (when (python-nav-beginning-of-block)
                 (if arg
                     (beginning-of-line)
                   (python-nav-end-of-statement)
                   (beginning-of-line 2)))
               (point-marker)))
        (end (save-excursion (python-nav-end-of-block)))
        (python-indent-guess-indent-offset-verbose nil))
    (if (and beg end)
        (python-shell-send-region beg end nil msg t)
      (user-error "Can't get code block from current position"))))

(defun python-shell-send-buffer (&optional send-main msg)
  "Send the entire buffer to inferior Python process.
When optional argument SEND-MAIN is non-nil, allow execution of
code inside blocks delimited by \"if __name__== \\='__main__\\=':\".
When called interactively SEND-MAIN defaults to nil, unless it's
called with prefix argument.  When optional argument MSG is
non-nil, forces display of a user-friendly message if there's no
process running; defaults to t when called interactively."
  (interactive (list current-prefix-arg t))
  (save-restriction
    (widen)
    (python-shell-send-region (point-min) (point-max) send-main msg)))

(defun python-shell-send-defun (&optional arg msg)
  "Send the current defun to inferior Python process.
When argument ARG is non-nil do not include decorators.  When
optional argument MSG is non-nil, forces display of a
user-friendly message if there's no process running; defaults to
t when called interactively."
  (interactive (list current-prefix-arg t))
  (let ((starting-pos (point)))
    (save-excursion
      (python-shell-send-region
       (progn
         (end-of-line 1)
         (while (and (or (python-nav-beginning-of-defun)
                         (beginning-of-line 1))
                     (> (current-indentation) 0)))
         (when (not arg)
           (while (and
                   (eq (forward-line -1) 0)
                   (if (looking-at (python-rx decorator))
                       t
                     (forward-line 1)
                     nil))))
         (point-marker))
       (progn
         (goto-char starting-pos)
         (or (python-nav-end-of-defun)
             (end-of-line 1))
         (point-marker))
       nil ;; noop
       msg))))

(defun python-shell-send-file (file-name &optional process temp-file-name
                                         delete msg)
  "Send FILE-NAME to inferior Python PROCESS.

If TEMP-FILE-NAME is passed then that file is used for processing
instead, while internally the shell will continue to use
FILE-NAME.  FILE-NAME can be remote, but TEMP-FILE-NAME must be
in the same host as PROCESS.  If TEMP-FILE-NAME and DELETE are
non-nil, then TEMP-FILE-NAME is deleted after evaluation is
performed.

When optional argument MSG is non-nil, forces display of a
user-friendly message if there's no process running; defaults to
t when called interactively."
  (interactive
   (list
    (read-file-name "File to send: ")   ; file-name
    nil                                 ; process
    nil                                 ; temp-file-name
    nil                                 ; delete
    t))                                 ; msg
  (setq process (or process (python-shell-get-process-or-error msg)))
  (with-current-buffer (process-buffer process)
    (unless (or temp-file-name
                (string= (file-remote-p file-name)
                         (file-remote-p default-directory)))
      (setq delete t
            temp-file-name (with-temp-buffer
                             (insert-file-contents file-name)
                             (python-shell--save-temp-file (current-buffer))))))
  (let* ((file-name (file-local-name (expand-file-name file-name)))
         (temp-file-name (when temp-file-name
                           (file-local-name (expand-file-name
                                             temp-file-name)))))
    (comint-send-string
     process
     (format
      "__PYTHON_EL_eval_file(%s, %s, %s)\n"
      (python-shell--encode-string file-name)
      (python-shell--encode-string (or temp-file-name ""))
      (if delete "True" "False")))))

(defun python-shell-switch-to-shell (&optional msg)
  "Switch to inferior Python process buffer.
When optional argument MSG is non-nil, forces display of a
user-friendly message if there's no process running; defaults to
t when called interactively."
  (interactive "p")
  (pop-to-buffer
   (process-buffer (python-shell-get-process-or-error msg))
   nil 'mark-for-redisplay))

(defun python-shell-send-setup-code ()
  "Send all setup code for shell.
This function takes the list of setup code to send from the
`python-shell-setup-codes' list."
  (when python-shell-setup-codes
    (let ((process (python-shell-get-process))
          (code (concat
                 (mapconcat
                  (lambda (elt)
                    (cond ((stringp elt) elt)
                          ((symbolp elt) (symbol-value elt))
                          (t "")))
                  python-shell-setup-codes
                  "\n\nprint ('python.el: sent setup code')"))))
      (python-shell-send-string code process)
      (python-shell-accept-process-output process))))

(add-hook 'python-shell-first-prompt-hook
          #'python-shell-send-setup-code)


;;; Shell completion

(defcustom python-shell-completion-setup-code
  "
def __PYTHON_EL_get_completions(text):
    completions = []
    completer = None

    import json
    try:
        import readline, re

        try:
            import __builtin__
        except ImportError:
            # Python 3
            import builtins as __builtin__
        builtins = dir(__builtin__)

        is_ipython = ('__IPYTHON__' in builtins or
                      '__IPYTHON__active' in builtins)

        if is_ipython and 'get_ipython' in builtins:
            def filter_c(prefix, c):
                if re.match('_+(i?[0-9]+)?$', c):
                    return False
                elif c[0] == '%' and not re.match('[%a-zA-Z]+$', prefix):
                    return False
                return True

            import IPython
            try:
                if IPython.version_info[0] >= 6:
                    from IPython.core.completer import provisionalcompleter
                    with provisionalcompleter():
                        completions = [
                            [c.text, c.start, c.end, c.type or '?', c.signature or '']
                             for c in get_ipython().Completer.completions(text, len(text))
                             if filter_c(text, c.text)]
                else:
                    part, matches = get_ipython().Completer.complete(line_buffer=text)
                    completions = [text + m[len(part):] for m in matches if filter_c(text, m)]
            except:
                pass
        else:
            # Try to reuse current completer.
            completer = readline.get_completer()
            if not completer:
                # importing rlcompleter sets the completer, use it as a
                # last resort to avoid breaking customizations.
                import rlcompleter
                completer = readline.get_completer()
            if getattr(completer, 'PYTHON_EL_WRAPPED', False):
                completer.print_mode = False
            i = 0
            while True:
                completion = completer(text, i)
                if not completion:
                    break
                i += 1
                completions.append(completion)
    except:
        pass
    finally:
        if getattr(completer, 'PYTHON_EL_WRAPPED', False):
            completer.print_mode = True
    return json.dumps(completions)"
  "Code used to setup completion in inferior Python processes."
  :type 'string)

(define-obsolete-variable-alias
  'python-shell-completion-module-string-code
  'python-shell-completion-string-code
  "24.4"
  "Completion string code must also autocomplete modules.")

(define-obsolete-variable-alias
  'python-shell-completion-pdb-string-code
  'python-shell-completion-string-code
  "25.1"
  "Completion string code must work for (i)pdb.")

(defcustom python-shell-completion-native-disabled-interpreters
  ;; PyPy's readline cannot handle some escape sequences yet.  Native
  ;; completion doesn't work on w32 (Bug#28580).
  (if (eq system-type 'windows-nt) '("")
    '("pypy"))
  "List of disabled interpreters.
When a match is found, native completion is disabled."
  :version "28.1"
  :type '(repeat string))

(defcustom python-shell-completion-native-enable t
  "Enable readline based native completion."
  :version "25.1"
  :type 'boolean)

(defcustom python-shell-completion-native-output-timeout 5.0
  "Time in seconds to wait for completion output before giving up."
  :version "25.1"
  :type 'number)

(defcustom python-shell-completion-native-try-output-timeout 1.0
  "Time in seconds to wait for *trying* native completion output."
  :version "25.1"
  :type 'number)

(defvar python-shell-readline-completer-delims nil
  "Word delimiters used by the readline completer.
It is automatically set by Python shell.  An empty string means no
characters are considered delimiters and the readline completion
considers the entire line of input.  A value of nil means the Python
shell has no readline support.")

(defun python-shell-readline-detect ()
  "Detect the readline support for Python shell completion."
  (let* ((process (python-shell-get-process))
         (output (python-shell-send-string-no-output "
try:
    import readline
    print(readline.get_completer_delims())
except:
    print('No readline support')" process)))
    (setq-local python-shell-readline-completer-delims
                (unless (string-search "No readline support" output)
                  (string-trim-right output)))))

(defvar python-shell-completion-native-redirect-buffer
  " *Python completions redirect*"
  "Buffer to be used to redirect output of readline commands.")

(defun python-shell-completion-native-interpreter-disabled-p ()
  "Return non-nil if interpreter has native completion disabled."
  (when python-shell-completion-native-disabled-interpreters
    (string-match
     (regexp-opt python-shell-completion-native-disabled-interpreters)
     (file-name-nondirectory python-shell-interpreter))))

(defun python-shell-completion-native-try ()
  "Return non-nil if can trigger native completion."
  (let ((python-shell-completion-native-enable t)
        (python-shell-completion-native-output-timeout
         python-shell-completion-native-try-output-timeout))
    (python-shell-completion-native-get-completions
     (get-buffer-process (current-buffer))
     "_")))

(defun python-shell-completion-native-setup ()
  "Try to setup native completion, return non-nil on success."
  (let* ((process (python-shell-get-process))
         (output (python-shell-send-string-no-output "
def __PYTHON_EL_native_completion_setup():
    try:
        import readline

        try:
            import __builtin__
        except ImportError:
            # Python 3
            import builtins as __builtin__

        builtins = dir(__builtin__)
        is_ipython = ('__IPYTHON__' in builtins or
                      '__IPYTHON__active' in builtins)

        class __PYTHON_EL_Completer:
            '''Completer wrapper that prints candidates to stdout.

            It wraps an existing completer function and changes its behavior so
            that the user input is unchanged and real candidates are printed to
            stdout.

            Returned candidates are '0__dummy_completion__' and
            '1__dummy_completion__' in that order ('0__dummy_completion__' is
            returned repeatedly until all possible candidates are consumed).

            The real candidates are printed to stdout so that they can be
            easily retrieved through comint output redirect trickery.
            '''

            PYTHON_EL_WRAPPED = True

            def __init__(self, completer):
                self.completer = completer
                self.last_completion = None
                self.print_mode = True

            def __call__(self, text, state):
                if state == 0:
                    # Set the first dummy completion.
                    self.last_completion = None
                    completion = '0__dummy_completion__'
                else:
                    completion = self.completer(text, state - 1)

                if not completion:
                    if self.last_completion != '1__dummy_completion__':
                        # When no more completions are available, returning a
                        # dummy with non-sharing prefix allow ensuring output
                        # while preventing changes to current input.
                        # Coincidentally it's also the end of output.
                        completion = '1__dummy_completion__'
                elif completion.endswith('('):
                    # Remove parens on callables as it breaks completion on
                    # arguments (e.g. str(Ari<tab>)).
                    completion = completion[:-1]
                self.last_completion = completion

                if completion in (
                        '0__dummy_completion__', '1__dummy_completion__'):
                    return completion
                elif completion:
                    # For every non-dummy completion, return a repeated dummy
                    # one and print the real candidate so it can be retrieved
                    # by comint output filters.
                    if self.print_mode:
                        print (completion)
                        return '0__dummy_completion__'
                    else:
                        return completion
                else:
                    return completion

        completer = readline.get_completer()

        if not completer:
            # Used as last resort to avoid breaking customizations.
            import rlcompleter
            completer = readline.get_completer()

        if completer and not getattr(completer, 'PYTHON_EL_WRAPPED', False):
            # Wrap the existing completer function only once.
            new_completer = __PYTHON_EL_Completer(completer)
            if not is_ipython:
                readline.set_completer(new_completer)
            else:
                # Ensure that rlcompleter.__main__ and __main__ are identical.
                # (Bug#76205)
                import sys
                try:
                    sys.modules['rlcompleter'].__main__ = sys.modules['__main__']
                except KeyError:
                    pass
                # Try both initializations to cope with all IPython versions.
                # This works fine for IPython 3.x but not for earlier:
                readline.set_completer(new_completer)
                # IPython<3 hacks readline such that `readline.set_completer`
                # won't work.  This workaround injects the new completer
                # function into the existing instance directly:
                instance = getattr(completer, 'im_self', completer.__self__)
                instance.rlcomplete = new_completer

        if readline.__doc__ and 'libedit' in readline.__doc__:
            raise Exception('''libedit based readline is known not to work,
      see etc/PROBLEMS under \"In Inferior Python mode, input is echoed\".''')
            readline.parse_and_bind('bind ^I rl_complete')
        else:
            readline.parse_and_bind('tab: complete')
            # Require just one tab to send output.
            readline.parse_and_bind('set show-all-if-ambiguous on')
            # Avoid ANSI escape characters in the output
            readline.parse_and_bind('set colored-completion-prefix off')
            readline.parse_and_bind('set colored-stats off')
            # Avoid replacing common prefix with ellipsis.
            readline.parse_and_bind('set completion-prefix-display-length 0')

        print ('python.el: native completion setup loaded')
    except:
        import sys
        print ('python.el: native completion setup failed, %s: %s'
               % sys.exc_info()[:2])

__PYTHON_EL_native_completion_setup()" process)))
    (when (string-match-p "python\\.el: native completion setup loaded"
                          output)
      (python-shell-completion-native-try))))

(defun python-shell-completion-native-turn-off (&optional msg)
  "Turn off shell native completions.
With argument MSG show deactivation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (setq-local python-shell-completion-native-enable nil)
    (when msg
      (message "Shell native completion is disabled, using fallback"))))

(defun python-shell-completion-native-turn-on (&optional msg)
  "Turn on shell native completions.
With argument MSG show deactivation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (setq-local python-shell-completion-native-enable t)
    (python-shell-completion-native-turn-on-maybe msg)))

(defun python-shell-completion-native-turn-on-maybe (&optional msg)
  "Turn on native completions if enabled and available.
With argument MSG show activation/deactivation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (when python-shell-completion-native-enable
      (cond
       ((python-shell-completion-native-interpreter-disabled-p)
        (python-shell-completion-native-turn-off msg))
       ((and python-shell-readline-completer-delims
             (python-shell-completion-native-setup))
        (when msg
          (message "Shell native completion is enabled.")))
       (t
        (when msg
          (message (concat "Python does not use GNU readline;"
                           " no completion in multi-line commands.")))
        (python-shell-completion-native-turn-off nil))))))

(defun python-shell-completion-native-turn-on-maybe-with-msg ()
  "Like `python-shell-completion-native-turn-on-maybe' but force messages."
  (python-shell-completion-native-turn-on-maybe t))

(add-hook 'python-shell-first-prompt-hook
          #'python-shell-completion-native-turn-on-maybe-with-msg)

(defun python-shell-completion-native-toggle (&optional msg)
  "Toggle shell native completion.
With argument MSG show activation/deactivation message."
  (interactive "p")
  (python-shell-with-shell-buffer
    (if python-shell-completion-native-enable
        (python-shell-completion-native-turn-off msg)
      (python-shell-completion-native-turn-on msg))
    python-shell-completion-native-enable))

(defun python-shell-completion-native-get-completions (process input)
  "Get completions of INPUT using native readline for PROCESS."
  (with-current-buffer (process-buffer process)
    (let* ((original-filter-fn (process-filter process))
           (redirect-buffer (get-buffer-create
                             python-shell-completion-native-redirect-buffer))
           (sep (if (string= python-shell-readline-completer-delims "")
                    "[\n\r]+" "[ \f\t\n\r\v()]+"))
           (trigger "\t")
           (new-input (concat input trigger))
           (input-length
            (save-excursion
              (+ (- (point-max) (comint-bol)) (length new-input))))
           (delete-line-command (make-string input-length ?\b))
           (input-to-send (concat new-input delete-line-command)))
      ;; Ensure restoring the process filter, even if the user quits
      ;; or there's some other error.
      (unwind-protect
          (with-current-buffer redirect-buffer
            ;; Cleanup the redirect buffer
            (erase-buffer)
            ;; Mimic `comint-redirect-send-command', unfortunately it
            ;; can't be used here because it expects a newline in the
            ;; command and that's exactly what we are trying to avoid.
            (let ((comint-redirect-echo-input nil)
                  (comint-redirect-completed nil)
                  (comint-redirect-perform-sanity-check nil)
                  (comint-redirect-insert-matching-regexp t)
                  (comint-redirect-finished-regexp
                   "1__dummy_completion__.*\n")
                  (comint-redirect-output-buffer redirect-buffer))
              ;; Compatibility with Emacs 24.x.  Comint changed and
              ;; now `comint-redirect-filter' gets 3 args.  This
              ;; checks which version of `comint-redirect-filter' is
              ;; in use based on its args and uses `apply-partially'
              ;; to make it up for the 3 args case.
              (if (= (length
                      (help-function-arglist 'comint-redirect-filter))
                     3)
                  (set-process-filter
                   process (apply-partially
                            #'comint-redirect-filter original-filter-fn))
                (set-process-filter process #'comint-redirect-filter))
              (process-send-string process input-to-send)
              ;; Grab output until our dummy completion used as
              ;; output end marker is found.
              (when (python-shell-accept-process-output
                     process python-shell-completion-native-output-timeout
                     comint-redirect-finished-regexp)
                (re-search-backward "0__dummy_completion__" nil t)
                (let ((str (buffer-substring-no-properties
                            (line-beginning-position) (point-min))))
                  ;; The readline completer is allowed to return a list
                  ;; of (text start end type signature) as a JSON
                  ;; string.  See the return value for IPython in
                  ;; `python-shell-completion-setup-code'.
                  (if (string= "[" (substring str 0 1))
                      (condition-case nil
                          (python--parse-json-array str)
                        (t (cl-remove-duplicates (split-string str sep t)
                                                 :test #'string=)))
                    (cl-remove-duplicates (split-string str sep t)
                                          :test #'string=))))))
        (set-process-filter process original-filter-fn)))))

(defun python-shell-completion-get-completions (process input)
  "Get completions of INPUT using PROCESS."
  (with-current-buffer (process-buffer process)
    (python--parse-json-array
     (python-shell-send-string-no-output
      (format "%s\nprint(__PYTHON_EL_get_completions(%s))"
              python-shell-completion-setup-code
              (python-shell--encode-string input))
      process))))

(defun python-shell--get-multiline-input ()
  "Return lines at a multi-line input in Python shell."
  (save-excursion
    (let ((p (point)) lines)
      (when (progn
              (beginning-of-line)
              (looking-back python-shell-prompt-block-regexp (pos-bol)))
        (push (buffer-substring-no-properties (point) p) lines)
        (while (progn (comint-previous-prompt 1)
                      (looking-back python-shell-prompt-block-regexp (pos-bol)))
          (push (buffer-substring-no-properties (point) (pos-eol)) lines))
        (push (buffer-substring-no-properties (point) (pos-eol)) lines))
      lines)))

(defun python-shell--extra-completion-context ()
  "Get extra completion context of current input in Python shell."
  (let ((lines (python-shell--get-multiline-input))
        (python-indent-guess-indent-offset nil))
    (when (not (zerop (length lines)))
      (with-temp-buffer
        (delay-mode-hooks
          (insert (string-join lines "\n"))
          (python-mode)
          (python-shell-completion-extra-context))))))

(defun python-shell-completion-extra-context (&optional pos)
  "Get extra completion context at position POS in Python buffer.
If optional argument POS is nil, use current position.

Readline completers could use current line as the completion
context, which may be insufficient.  In this function, extra
context (e.g. multi-line function call) is found and reformatted
as one line, which is required by native completion."
  (let (bound p)
    (save-excursion
      (and pos (goto-char pos))
      (setq bound (pos-bol))
      (python-nav-up-list -1)
      (when (and (< (point) bound)
                 (or
                  (looking-back
                   (python-rx (group (+ (or "." symbol-name)))) (pos-bol) t)
                  (progn
                    (forward-line 0)
                    (looking-at "^[ \t]*\\(from \\)"))))
        (setq p (match-beginning 1))))
    (when p
      (replace-regexp-in-string
       "\n[ \t]*" "" (buffer-substring-no-properties p (1- bound))))))

(defvar-local python-shell--capf-cache nil
  "Variable to store cached completions and invalidation keys.")

(defun python-shell-completion-at-point (&optional process)
  "Function for `completion-at-point-functions' in `inferior-python-mode'.
Optional argument PROCESS forces completions to be retrieved
using that one instead of current buffer's process."
  (setq process (or process (get-buffer-process (current-buffer))))
  (unless process
    (user-error "No active python inferior process"))
  (let* ((is-shell-buffer (derived-mode-p 'inferior-python-mode))
         (line-start (if is-shell-buffer
                         ;; Working on a shell buffer: use prompt end.
                         (cdr (python-util-comint-last-prompt))
                       (line-beginning-position)))
         (no-delims
          (and (not (if is-shell-buffer
                        (eq 'font-lock-comment-face
                            (get-text-property (1- (point)) 'face))
                      (python-syntax-context 'comment)))
               (with-current-buffer (process-buffer process)
                 (if python-shell-completion-native-enable
                     (string= python-shell-readline-completer-delims "")
                   (or (string-match-p "ipython[23]?\\'" python-shell-interpreter)
                       (equal python-shell-readline-completer-delims ""))))))
         (start
          (if (< (point) line-start)
              (point)
            (save-excursion
              (if (or no-delims
                      (not (re-search-backward
                            (python-rx
                             (or whitespace open-paren close-paren
                                 string-delimiter simple-operator))
                            line-start
                            t 1)))
                  line-start
                (forward-char (length (match-string-no-properties 0)))
                (point)))))
         (end (point))
         (prompt-boundaries
          (with-current-buffer (process-buffer process)
            (python-util-comint-last-prompt)))
         (prompt
          (with-current-buffer (process-buffer process)
            (when prompt-boundaries
              (buffer-substring-no-properties
               (car prompt-boundaries) (cdr prompt-boundaries)))))
         (completion-fn
          (with-current-buffer (process-buffer process)
            (cond ((or (null prompt)
                       (and is-shell-buffer
                            (< (point) (cdr prompt-boundaries)))
                       (and (not is-shell-buffer)
                            (string-match-p
                             python-shell-prompt-pdb-regexp prompt)))
                   #'ignore)
                  ((or (not python-shell-completion-native-enable)
                       ;; Even if native completion is enabled, for
                       ;; pdb interaction always use the fallback
                       ;; mechanism since the completer is changed.
                       ;; Also, since pdb interaction is single-line
                       ;; based, this is enough.
                       (string-match-p python-shell-prompt-pdb-regexp prompt))
                   (if (or (equal python-shell--block-prompt prompt)
                           (string-match-p
                            python-shell-prompt-block-regexp prompt))
                       ;; The non-native completion mechanism sends
                       ;; newlines to the interpreter, so we can't use
                       ;; it during a multiline statement (Bug#28051).
                       #'ignore
                     #'python-shell-completion-get-completions))
                  (t #'python-shell-completion-native-get-completions))))
         (prev-prompt (car python-shell--capf-cache))
         (re (or (cadr python-shell--capf-cache) regexp-unmatchable))
         (prefix (buffer-substring-no-properties start end))
         (prefix-offset 0)
         (extra-context (when no-delims
                          (if is-shell-buffer
                              (python-shell--extra-completion-context)
                            (python-shell-completion-extra-context))))
         (extra-offset (length extra-context)))
    (unless (zerop extra-offset)
      (setq prefix (concat extra-context prefix)))
    ;; To invalidate the cache, we check if the prompt position or the
    ;; completion prefix changed.
    (unless (and (equal prev-prompt (car prompt-boundaries))
                 (string-match re prefix)
                 (setq prefix-offset (- (length prefix) (match-end 1))))
      (setq python-shell--capf-cache
            `(,(car prompt-boundaries)
              ,(if (string-empty-p prefix)
                   regexp-unmatchable
                 (concat "\\`\\(" (regexp-quote prefix) "\\)\\(?:\\sw\\|\\s_\\)*\\'"))
              ,@(funcall completion-fn process prefix))))
    (let ((cands (cddr python-shell--capf-cache)))
      (cond
       ((stringp (car cands))
        (if no-delims
            ;; Reduce completion candidates due to long prefix.
            (if-let* ((Lp (length prefix))
                      ((string-match "\\(\\sw\\|\\s_\\)+\\'" prefix))
                      (L (match-beginning 0)))
                ;; If extra-offset is not zero:
                ;;                  start              end
                ;; o------------------o---------o-------o
                ;; |<- extra-offset ->|
                ;; |<----------- L ------------>|
                ;;                          new-start
                (list (+ start L (- extra-offset)) end
                      (mapcar (lambda (s) (substring s L)) cands))
              (list end end (mapcar (lambda (s) (substring s Lp)) cands)))
          (list start end cands)))
       ;; python-shell-completion(-native)-get-completions may produce a
       ;; list of (text start end type signature) for completion.
       ((consp (car cands))
        (list (+ start (nth 1 (car cands)) (- extra-offset))
              ;; Candidates may be cached, so the end position should
              ;; be adjusted according to current completion prefix.
              (+ start (nth 2 (car cands)) (- extra-offset) prefix-offset)
              cands
              :annotation-function
              (lambda (c) (concat " " (nth 3 (assoc c cands))))
              :company-docsig
              (lambda (c) (nth 4 (assoc c cands)))))))))

(define-obsolete-function-alias
  'python-shell-completion-complete-at-point
  #'python-shell-completion-at-point
  "25.1")

(defun python-shell-completion-complete-or-indent ()
  "Complete or indent depending on the context.
If content before pointer is all whitespace, indent.
If not try to complete."
  (interactive)
  (if (string-match "^[[:space:]]*$"
                    (buffer-substring (comint-line-beginning-position)
                                      (point)))
      (indent-for-tab-command)
    (completion-at-point)))


;;; PDB Track integration

(defcustom python-pdbtrack-activate t
  "Non-nil makes Python shell enable pdbtracking.
Pdbtracking would open the file for current stack frame found in pdb output by
`python-pdbtrack-stacktrace-info-regexp' and add overlay arrow in currently
inspected line in that file.

After the command listed in `python-pdbtrack-continue-command' or
`python-pdbtrack-exit-command' is sent to pdb, the pdbtracking session is
considered over.  The overlay arrow will be removed from the currently tracked
buffer.  Additionally, if `python-pdbtrack-kill-buffers' is non-nil, all
files opened by pdbtracking will be killed."
  :type 'boolean
  :safe 'booleanp)

(defcustom python-pdbtrack-stacktrace-info-regexp
  "> \\([^\"(]+\\)(\\([0-9]+\\))\\([?a-zA-Z0-9_<>]+\\)()"
  "Regular expression matching stacktrace information.
Used to extract the current line and module being inspected.

Must match lines with real filename, like
 > /path/to/file.py(42)<module>()->None
and lines in which filename starts with `<', e.g.
 > <stdin>(1)<module>()->None

In the first case /path/to/file.py file will be visited and overlay icon
will be placed in line 42.
In the second case pdbtracking session will be considered over because
the top stack frame has been reached.

Filename is expected in the first parenthesized expression.
Line number is expected in the second parenthesized expression."
  :type 'regexp
  :version "27.1"
  :safe 'stringp)

(defcustom python-pdbtrack-continue-command '("c" "cont" "continue")
  "Pdb `continue' command aliases.
After one of these commands is sent to pdb, the pdbtracking session is
considered over.

This command is remembered by pdbtracking.  If the next command sent to pdb
is the empty string, it is treated as `continue' if the previous command
was `continue'.  This behavior slightly differentiates the `continue' command
from the `exit' command listed in `python-pdbtrack-exit-command'.

See `python-pdbtrack-activate' for pdbtracking session overview."
  :type '(repeat string)
  :version "27.1")

(defcustom python-pdbtrack-exit-command '("q" "quit" "exit")
  "Pdb `exit' command aliases.
After one of this commands is sent to pdb, pdbtracking session is
considered over.

See `python-pdbtrack-activate' for pdbtracking session overview."
  :type '(repeat string)
  :version "27.1")

(defcustom python-pdbtrack-kill-buffers t
  "If non-nil, kill buffers when pdbtracking session is over.
Only buffers opened by pdbtracking will be killed.

See `python-pdbtrack-activate' for pdbtracking session overview."
  :type 'boolean
  :version "27.1")

(defvar python-pdbtrack-tracked-buffer nil
  "Variable containing the value of the current tracked buffer.
Never set this variable directly, use
`python-pdbtrack-set-tracked-buffer' instead.")

(defvar python-pdbtrack-buffers-to-kill nil
  "List of buffers to be deleted after tracking finishes.")

(defvar python-pdbtrack-prev-command-continue nil
  "Is t if previous pdb command was `continue'.")

(defun python-pdbtrack-set-tracked-buffer (file-name)
  "Set the buffer for FILE-NAME as the tracked buffer.
Internally it uses the `python-pdbtrack-tracked-buffer' variable.
Returns the tracked buffer."
  (let* ((file-name-prospect (concat (file-remote-p default-directory)
                              file-name))
         (file-buffer (get-file-buffer file-name-prospect)))
    (unless file-buffer
      (cond
       ((file-exists-p file-name-prospect)
        (setq file-buffer (find-file-noselect file-name-prospect)))
       ((and (not (equal file-name file-name-prospect))
             (file-exists-p file-name))
        ;; Fallback to a locally available copy of the file.
        (setq file-buffer (find-file-noselect file-name-prospect))))
      (when (and python-pdbtrack-kill-buffers
                 (not (member file-buffer python-pdbtrack-buffers-to-kill)))
        (add-to-list 'python-pdbtrack-buffers-to-kill file-buffer)))
    (setq python-pdbtrack-tracked-buffer file-buffer)
    file-buffer))

(defun python-pdbtrack-unset-tracked-buffer ()
  "Untrack currently tracked buffer."
  (when (buffer-live-p python-pdbtrack-tracked-buffer)
    (with-current-buffer python-pdbtrack-tracked-buffer
      (set-marker overlay-arrow-position nil)))
  (setq python-pdbtrack-tracked-buffer nil))

(defun python-pdbtrack-tracking-finish ()
  "Finish tracking."
  (python-pdbtrack-unset-tracked-buffer)
  (when python-pdbtrack-kill-buffers
    (mapc (lambda (buffer)
            (ignore-errors (kill-buffer buffer)))
            python-pdbtrack-buffers-to-kill))
  (setq python-pdbtrack-buffers-to-kill nil))

(defun python-pdbtrack-process-sentinel (process _event)
  "Untrack buffers when PROCESS is killed."
  (unless (process-live-p process)
    (let ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (python-pdbtrack-tracking-finish))))))

(defun python-pdbtrack-comint-input-filter-function (input)
  "Finish tracking session depending on command in INPUT.
Commands that must finish the tracking session are listed in
`python-pdbtrack-exit-command'."
  (when (and python-pdbtrack-tracked-buffer
             ;; Empty input is sent by C-d or `comint-send-eof'
             (or (string-empty-p input)
                 ;; "n some text" is "n" command for pdb. Split input and get first part
                 (let* ((command (car (split-string (string-trim input) " "))))
                   (setq python-pdbtrack-prev-command-continue
                         (or (member command python-pdbtrack-continue-command)
                             ;; if command is empty and previous command was 'continue'
                             ;; then current command is 'continue' too.
                             (and (string-empty-p command)
                                  python-pdbtrack-prev-command-continue)))
                   (or python-pdbtrack-prev-command-continue
                       (member command python-pdbtrack-exit-command)))))
    (python-pdbtrack-tracking-finish)))

(defun python-pdbtrack-comint-output-filter-function (output)
  "Move overlay arrow to current pdb line in tracked buffer.
Argument OUTPUT is a string with the output from the comint process."
  (when (and python-pdbtrack-activate (not (string= output "")))
    (let* ((full-output (ansi-color-filter-apply
                         (buffer-substring comint-last-input-end (point-max))))
           (line-number)
           (file-name
            (with-temp-buffer
              (insert full-output)
              ;; When the debugger encounters a pdb.set_trace()
              ;; command, it prints a single stack frame.  Sometimes
              ;; it prints a bit of extra information about the
              ;; arguments of the present function.  When ipdb
              ;; encounters an exception, it prints the _entire_ stack
              ;; trace.  To handle all of these cases, we want to find
              ;; the _last_ stack frame printed in the most recent
              ;; batch of output, then jump to the corresponding
              ;; file/line number.
              ;; Parse output only if at pdb prompt to avoid double code
              ;; run in situation when output and pdb prompt received in
              ;; different hunks
              (goto-char (point-max))
              (goto-char (line-beginning-position))
              (when (and (looking-at python-shell-prompt-pdb-regexp)
                         (re-search-backward python-pdbtrack-stacktrace-info-regexp nil t))
                (setq line-number (string-to-number
                                   (match-string-no-properties 2)))
                (match-string-no-properties 1)))))
      (when (and file-name line-number)
        (if (string-prefix-p "<" file-name)
            ;; Finish tracking session if stacktrace info is like
            ;; "> <stdin>(1)<module>()->None"
            (python-pdbtrack-tracking-finish)
          (python-pdbtrack-unset-tracked-buffer)
          (let* ((tracked-buffer (python-pdbtrack-set-tracked-buffer file-name))
                 (shell-buffer (current-buffer))
                 (tracked-buffer-window (get-buffer-window tracked-buffer))
                 (tracked-buffer-line-pos))
            (with-current-buffer tracked-buffer
              (setq-local overlay-arrow-position (make-marker))
              (setq tracked-buffer-line-pos (progn
                                              (goto-char (point-min))
                                              (forward-line (1- line-number))
                                              (point-marker)))
              (when tracked-buffer-window
                (set-window-point
                 tracked-buffer-window tracked-buffer-line-pos))
              (set-marker overlay-arrow-position tracked-buffer-line-pos))
            (pop-to-buffer tracked-buffer)
            (switch-to-buffer-other-window shell-buffer))))))
  output)

(defun python-pdbtrack-setup-tracking ()
  "Setup pdb tracking in current buffer."
  (make-local-variable 'python-pdbtrack-buffers-to-kill)
  (make-local-variable 'python-pdbtrack-tracked-buffer)
  (add-hook 'comint-input-filter-functions
            #'python-pdbtrack-comint-input-filter-function nil t)
  (add-to-list (make-local-variable 'comint-output-filter-functions)
               #'python-pdbtrack-comint-output-filter-function)
  (add-function :before (process-sentinel (get-buffer-process (current-buffer)))
                #'python-pdbtrack-process-sentinel)
  (add-hook 'kill-buffer-hook #'python-pdbtrack-tracking-finish nil t))


;;; Symbol completion

(defun python-completion-at-point ()
  "Function for `completion-at-point-functions' in `python-mode'.
For this to work as best as possible you should call
`python-shell-send-buffer' from time to time so context in
inferior Python process is updated properly."
  (let ((process (python-shell-get-process)))
    (when (and process
               (python-shell-with-shell-buffer
                 (python-util-comint-end-of-output-p)))
      (python-shell-completion-at-point process))))

(define-obsolete-function-alias
  'python-completion-complete-at-point
  #'python-completion-at-point
  "25.1")


;;; Fill paragraph

(defcustom python-fill-comment-function 'python-fill-comment
  "Function to fill comments.
This is the function used by `python-fill-paragraph' to
fill comments."
  :type 'symbol)

(defcustom python-fill-string-function 'python-fill-string
  "Function to fill strings.
This is the function used by `python-fill-paragraph' to
fill strings."
  :type 'symbol)

(defcustom python-fill-decorator-function 'python-fill-decorator
  "Function to fill decorators.
This is the function used by `python-fill-paragraph' to
fill decorators."
  :type 'symbol)

(defcustom python-fill-paren-function 'python-fill-paren
  "Function to fill parens.
This is the function used by `python-fill-paragraph' to
fill parens."
  :type 'symbol)

(defcustom python-fill-docstring-style 'pep-257
  "Style used to fill docstrings.
This affects `python-fill-string' behavior with regards to
triple quotes positioning.

Possible values are `django', `onetwo', `pep-257', `pep-257-nn',
`symmetric', and nil.  A value of nil won't care about quotes
position and will treat docstrings a normal string, any other
value may result in one of the following docstring styles:

`django':

    \"\"\"
    Process foo, return bar.
    \"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

`onetwo':

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.

    \"\"\"

`pep-257':

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"Process foo, return bar.

    If processing fails throw ProcessingError.

    \"\"\"

`pep-257-nn':

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\"

`symmetric':

    \"\"\"Process foo, return bar.\"\"\"

    \"\"\"
    Process foo, return bar.

    If processing fails throw ProcessingError.
    \"\"\""
  :type '(choice
          (const :tag "Don't format docstrings" nil)
          (const :tag "Django's coding standards style." django)
          (const :tag "One newline and start and Two at end style." onetwo)
          (const :tag "PEP-257 with 2 newlines at end of string." pep-257)
          (const :tag "PEP-257 with 1 newline at end of string." pep-257-nn)
          (const :tag "Symmetric style." symmetric))
  :safe (lambda (val)
          (memq val '(django onetwo pep-257 pep-257-nn symmetric nil))))

(defun python-fill-paragraph (&optional justify)
  "`fill-paragraph-function' handling multi-line strings and possibly comments.
If any of the current line is in or at the end of a multi-line string,
fill the string or the paragraph of it that point is in, preserving
the string's indentation.
Optional argument JUSTIFY defines if the paragraph should be justified."
  (interactive "P")
  (save-excursion
    (cond
     ;; Comments
     ((python-syntax-context 'comment)
      (funcall python-fill-comment-function justify))
     ;; Strings/Docstrings
     ((python-info-triple-quoted-string-p)
      (funcall python-fill-string-function justify))
     ;; Decorators
     ((equal (char-after (save-excursion
                           (python-nav-beginning-of-statement))) ?@)
      (funcall python-fill-decorator-function justify))
     ;; Parens
     ((or (python-syntax-context 'paren)
          (looking-at (python-rx open-paren))
          (save-excursion
            (skip-syntax-forward "^(" (line-end-position))
            (looking-at (python-rx open-paren))))
      (funcall python-fill-paren-function justify))
     (t t))))

(defun python-fill-comment (&optional justify)
  "Comment fill function for `python-fill-paragraph'.
JUSTIFY should be used (if applicable) as in `fill-paragraph'."
  (fill-comment-paragraph justify))

(defun python-fill-string (&optional justify)
  "String fill function for `python-fill-paragraph'.
JUSTIFY should be used (if applicable) as in `fill-paragraph'."
  (let* ((str-start-pos
          (set-marker
           (make-marker)
           (python-info-triple-quoted-string-p)))
         ;; JT@2021-09-21: Since bug#49518's fix this will always be 1
         (num-quotes (python-syntax-count-quotes
                      (char-after str-start-pos) str-start-pos))
         (str-line-start-pos
          (save-excursion
            (goto-char str-start-pos)
            (beginning-of-line)
            (point-marker)))
         (str-end-pos
          (save-excursion
            (goto-char (+ str-start-pos num-quotes))
            (or (re-search-forward (rx (syntax string-delimiter)) nil t)
                (goto-char (point-max)))
            (point-marker)))
         (multi-line-p
          ;; Docstring styles may vary for one-liners and multi-liners.
          (> (count-matches "\n" str-start-pos str-end-pos) 0))
         (delimiters-style
          (pcase python-fill-docstring-style
            ;; delimiters-style is a cons cell with the form
            ;; (START-NEWLINES .  END-NEWLINES). When any of the sexps
            ;; is NIL means to not add any newlines for start or end
            ;; of docstring.  See `python-fill-docstring-style' for a
            ;; graphic idea of each style.
            ('django (cons 1 1))
            ('onetwo (and multi-line-p (cons 1 2)))
            ('pep-257 (and multi-line-p (cons nil 2)))
            ('pep-257-nn (and multi-line-p (cons nil 1)))
            ('symmetric (and multi-line-p (cons 1 1)))))
         (fill-paragraph-function))
    (save-restriction
      (narrow-to-region str-line-start-pos str-end-pos)
      (fill-paragraph justify))
    (save-excursion
      (when (and (python-info-docstring-p) python-fill-docstring-style)
        ;; Add the number of newlines indicated by the selected style
        ;; at the start of the docstring.
        (goto-char (+ str-start-pos num-quotes))
        (delete-region (point) (progn
                                 (skip-syntax-forward "> ")
                                 (point)))
        (and (car delimiters-style)
             (or (newline (car delimiters-style)) t)
             ;; Indent only if a newline is added.
             (indent-according-to-mode))
        ;; Add the number of newlines indicated by the selected style
        ;; at the end of the docstring.
        (goto-char (if (not (= str-end-pos (point-max)))
                       (- str-end-pos num-quotes)
                     str-end-pos))
        (delete-region (point) (progn
                                 (skip-syntax-backward "> ")
                                 (point)))
        (and (cdr delimiters-style)
             ;; Add newlines only if string ends.
             (not (= str-end-pos (point-max)))
             (or (newline (cdr delimiters-style)) t)
             ;; Again indent only if a newline is added.
             (indent-according-to-mode))))) t)

(defun python-fill-decorator (&optional _justify)
  "Decorator fill function for `python-fill-paragraph'.
JUSTIFY should be used (if applicable) as in `fill-paragraph'."
  t)

(defun python-fill-paren (&optional justify)
  "Paren fill function for `python-fill-paragraph'.
JUSTIFY should be used (if applicable) as in `fill-paragraph'."
  (save-restriction
    (narrow-to-region (progn
                        (while (python-syntax-context 'paren)
                          (goto-char (1- (point))))
                        (line-beginning-position))
                      (progn
                        (when (not (python-syntax-context 'paren))
                          (end-of-line)
                          (when (not (python-syntax-context 'paren))
                            (skip-syntax-backward "^)")))
                        (while (and (python-syntax-context 'paren)
                                    (not (eobp)))
                          (goto-char (1+ (point))))
                        (point)))
    (let ((paragraph-start "\f\\|[ \t]*$")
          (paragraph-separate ",")
          (fill-paragraph-function))
      (goto-char (point-min))
      (fill-paragraph justify))
    (while (not (eobp))
      (forward-line 1)
      (python-indent-line)
      (goto-char (line-end-position))))
  t)

(defun python-do-auto-fill ()
  "Like `do-auto-fill', but bind `fill-indent-according-to-mode'."
  ;; See Bug#36056.
  (let ((fill-indent-according-to-mode t))
    (do-auto-fill)))


;;; Skeletons

(defcustom python-skeleton-autoinsert nil
  "Non-nil means template skeletons will be automagically inserted.
This happens when pressing \"if<SPACE>\", for example, to prompt for
the if condition."
  :type 'boolean
  :safe 'booleanp)

(defvar python-skeleton-available '()
  "Internal list of available skeletons.")

(define-abbrev-table 'python-mode-skeleton-abbrev-table ()
  "Abbrev table for Python mode skeletons."
  :case-fixed t
  ;; Allow / inside abbrevs.
  :regexp "\\(?:^\\|[^/]\\)\\<\\([[:word:]/]+\\)\\W*"
  ;; Only expand in code.
  :enable-function (lambda ()
                     (and
                      (not (python-syntax-comment-or-string-p))
                      python-skeleton-autoinsert)))

(defmacro python-skeleton-define (name doc &rest skel)
  "Define a `python-mode' skeleton using NAME DOC and SKEL.
The skeleton will be bound to python-skeleton-NAME and will
be added to `python-mode-skeleton-abbrev-table'."
  (declare (indent 2))
  (let* ((name (symbol-name name))
         (function-name (intern (concat "python-skeleton-" name))))
    `(progn
       (function-put ',function-name 'command-modes '(python-base-mode))
       (define-abbrev python-mode-skeleton-abbrev-table
         ,name "" ',function-name :system t)
       (setq python-skeleton-available
             (cons ',function-name python-skeleton-available))
       (define-skeleton ,function-name
         ,(or doc
              (format "Insert %s statement." name))
         ,@skel))))

(define-abbrev-table 'python-base-mode-abbrev-table ()
  "Abbrev table for Python modes."
  :parents (list python-mode-skeleton-abbrev-table))

(defmacro python-define-auxiliary-skeleton (name &optional doc &rest skel)
  "Define a `python-mode' auxiliary skeleton using NAME DOC and SKEL.
The skeleton will be bound to python-skeleton-NAME."
  (declare (indent 2))
  (let* ((name (symbol-name name))
         (function-name (intern (concat "python-skeleton--" name)))
         (msg (funcall (if (fboundp 'format-message) #'format-message #'format)
                       "Add `%s' clause? " name)))
    (when (not skel)
      (setq skel
            `(< ,(format "%s:" name) \n \n
                > _ \n)))
    `(progn
       (function-put ',function-name 'completion-predicate #'ignore)
       (define-skeleton ,function-name
         ,(or doc
              (format "Auxiliary skeleton for %s statement." name))
         nil
         (unless (y-or-n-p ,msg)
           (signal 'quit t))
         ,@skel))))

(python-define-auxiliary-skeleton else)

(python-define-auxiliary-skeleton except)

(python-define-auxiliary-skeleton finally)

(python-skeleton-define if nil
  "Condition: "
  "if " str ":" \n
  _ \n
  ("other condition, %s: "
   <
   "elif " str ":" \n
   > _ \n nil)
  '(python-skeleton--else) | ^)

(python-skeleton-define while nil
  "Condition: "
  "while " str ":" \n
  > _ \n
  '(python-skeleton--else) | ^)

(python-skeleton-define for nil
  "Iteration spec: "
  "for " str ":" \n
  > _ \n
  '(python-skeleton--else) | ^)

(python-skeleton-define import nil
  "Import from module: "
  "from " str & " " | -5
  "import "
  ("Identifier: " str ", ") -2 \n _)

(python-skeleton-define try nil
  nil
  "try:" \n
  > _ \n
  ("Exception, %s: "
   <
   "except " str ":" \n
   > _ \n nil)
  resume:
  '(python-skeleton--except)
  '(python-skeleton--else)
  '(python-skeleton--finally) | ^)

(python-skeleton-define def nil
  "Function name: "
  "def " str "(" ("Parameter, %s: "
                  (unless (equal ?\( (char-before)) ", ")
                  str) "):" \n
                  "\"\"\"" - "\"\"\"" \n
                  > _ \n)

(python-skeleton-define class nil
  "Class name: "
  "class " str "(" ("Inheritance, %s: "
                    (unless (equal ?\( (char-before)) ", ")
                    str)
  & ")" | -1
  ":" \n
  "\"\"\"" - "\"\"\"" \n
  > _ \n)

(defun python-skeleton-add-menu-items ()
  "Add menu items to Python->Skeletons menu."
  (let ((skeletons (sort python-skeleton-available #'string<)))
    (dolist (skeleton skeletons)
      (easy-menu-add-item
       nil '("Python" "Skeletons")
       `[,(format
           "Insert %s" (nth 2 (split-string (symbol-name skeleton) "-")))
         ,skeleton t]))))

;;; FFAP

(defcustom python-ffap-setup-code
  "
def __FFAP_get_module_path(objstr):
    try:
        import inspect
        import os.path
        # NameError exceptions are delayed until this point.
        obj = eval(objstr)
        module = inspect.getmodule(obj)
        filename = module.__file__
        ext = os.path.splitext(filename)[1]
        if ext in ('.pyc', '.pyo'):
            # Point to the source file.
            filename = filename[:-1]
        if os.path.exists(filename):
            return filename
        return ''
    except:
        return ''"
  "Python code to get a module path."
  :type 'string)

(defun python-ffap-module-path (module)
  "Function for `ffap-alist' to return path for MODULE."
  (when-let* ((process (python-shell-get-process))
              (ready (python-shell-with-shell-buffer
                      (python-util-comint-end-of-output-p)))
              (module-file
               (python-shell-send-string-no-output
                (format "%s\nprint(__FFAP_get_module_path(%s))"
                        python-ffap-setup-code
                        (python-shell--encode-string module)))))
    (unless (string-empty-p module-file)
      (python-util-strip-string module-file))))

(defvar ffap-alist)

(eval-after-load "ffap"
  '(dolist (mode '(python-mode python-ts-mode inferior-python-mode))
     (add-to-list 'ffap-alist `(,mode . python-ffap-module-path))))


;;; Code check

(defcustom python-check-command
  (cond ((executable-find "pyflakes") "pyflakes")
        ((executable-find "ruff") "ruff")
        ((executable-find "flake8") "flake8")
        ((executable-find "epylint") "epylint")
        (t "pyflakes"))
  "Command used to check a Python file."
  :type 'string
  :version "30.1")

(defcustom python-check-buffer-name
  "*Python check: %s*"
  "Buffer name used for check commands."
  :type 'string)

(defvar-local python-check-custom-command nil
  "Internal use.")

(defun python-check (command)
  "Check a Python file (default current buffer's file).
Runs COMMAND, a shell command, as if by `compile'.
See `python-check-command' for the default."
  (interactive
   (list (read-string "Check command: "
                      (or python-check-custom-command
                          (concat python-check-command " "
                                  (shell-quote-argument
                                   (or
                                    (let ((name (buffer-file-name)))
                                      (and name
                                           (file-name-nondirectory name)))
                                    "")))))))
  (setq python-check-custom-command command)
  (save-some-buffers (not compilation-ask-about-save) nil)
  (python-shell-with-environment
    (compilation-start command nil
                       (lambda (_modename)
                         (format python-check-buffer-name command)))))


;;; ElDoc

(defcustom python-eldoc-setup-code
  "def __PYDOC_get_help(obj):
    try:
        import inspect
        try:
            str_type = basestring
            argspec_function = inspect.getargspec
        except NameError:
            str_type = str
            argspec_function = inspect.getfullargspec
        if isinstance(obj, str_type):
            obj = eval(obj, globals())
        doc = inspect.getdoc(obj)
        if not doc and callable(obj):
            target = None
            if inspect.isclass(obj) and hasattr(obj, '__init__'):
                target = obj.__init__
                objtype = 'class'
            else:
                target = obj
                objtype = 'def'
            if target:
                if hasattr(inspect, 'signature'):
                    args = str(inspect.signature(target))
                else:
                    args = inspect.formatargspec(*argspec_function(target))
                name = obj.__name__
                doc = '{objtype} {name}{args}'.format(
                    objtype=objtype, name=name, args=args
                )
    except:
        doc = ''
    return doc"
  "Python code to setup documentation retrieval."
  :type 'string)

(defun python-eldoc--get-symbol-at-point ()
  "Get the current symbol for eldoc.
Returns the current symbol handling point within arguments."
  (save-excursion
    (let ((start (python-syntax-context 'paren)))
      (when start
        (goto-char start))
      (when (or start
                (eobp)
                (memq (char-syntax (char-after)) '(?\ ?-)))
        ;; Try to adjust to closest symbol if not in one.
        (python-util-forward-comment -1)))
    (python-info-current-symbol t)))

(defun python-eldoc--get-doc-at-point (&optional force-input force-process)
  "Internal implementation to get documentation at point.
If not FORCE-INPUT is passed then what `python-eldoc--get-symbol-at-point'
returns will be used.  If not FORCE-PROCESS is passed what
`python-shell-get-process' returns is used."
  (let ((process (or force-process (python-shell-get-process))))
    (when (and process
               (python-shell-with-shell-buffer
                 (python-util-comint-end-of-output-p)))
      (let* ((input (or force-input
                        (python-eldoc--get-symbol-at-point)))
             (docstring
              (when input
                ;; Prevent resizing the echo area when iPython is
                ;; enabled.  Bug#18794.
                (python-util-strip-string
                 (python-shell-send-string-no-output
                  (format
                   "%s\nprint(__PYDOC_get_help(%s))"
                   python-eldoc-setup-code
                   (python-shell--encode-string input))
                  process)))))
        (unless (string-empty-p docstring)
          docstring)))))

(defvar-local python-eldoc-get-doc t
  "Non-nil means eldoc should fetch the documentation automatically.
Set to nil by `python-eldoc-function' if
`python-eldoc-function-timeout-permanent' is non-nil and
`python-eldoc-function' times out.")

(defcustom python-eldoc-function-timeout 1
  "Timeout for `python-eldoc-function' in seconds."
  :type 'integer
  :version "25.1")

(defcustom python-eldoc-function-timeout-permanent t
  "If non-nil, a timeout in Python-Eldoc will disable it permanently.
Python-Eldoc can be re-enabled manually by setting `python-eldoc-get-doc'
back to t in the affected buffer."
  :type 'boolean
  :version "25.1")

(defun python-eldoc-function (&rest _ignored)
  "`eldoc-documentation-function' for Python.
For this to work as best as possible you should call
`python-shell-send-buffer' from time to time so context in
inferior Python process is updated properly.

If `python-eldoc-function-timeout' seconds elapse before this
function returns then if
`python-eldoc-function-timeout-permanent' is non-nil
`python-eldoc-get-doc' will be set to nil and eldoc will no
longer return the documentation at the point automatically.

Set `python-eldoc-get-doc' to t to reenable eldoc documentation
fetching."
  (when python-eldoc-get-doc
    (with-timeout (python-eldoc-function-timeout
                   (if python-eldoc-function-timeout-permanent
                       (progn
                         (message "ElDoc echo-area display muted in this buffer, see `python-eldoc-function'")
                         (setq python-eldoc-get-doc nil))
                     (message "`python-eldoc-function' timed out, see `python-eldoc-function-timeout'")))
      (python-eldoc--get-doc-at-point))))

(defun python-eldoc-at-point (symbol)
  "Get help on SYMBOL using `help'.
Interactively, prompt for symbol."
  (interactive
   (let ((symbol (python-eldoc--get-symbol-at-point))
         (enable-recursive-minibuffers t))
     (list (read-string
            ;; `format-prompt' is new in Emacs 28.1.
            (if (fboundp 'format-prompt)
                (format-prompt "Describe symbol" symbol)
              (if symbol
                  (format "Describe symbol (default %s): " symbol)
                "Describe symbol: "))
            nil nil symbol))))
  (message (python-eldoc--get-doc-at-point symbol)))

(defun python-describe-at-point (symbol process)
  (interactive (list (python-info-current-symbol)
                     (python-shell-get-process)))
  (comint-send-string process (concat "help('" symbol "')\n")))


;;; Hideshow

(defun python-hideshow-forward-sexp-function (_arg)
  "Python specific `forward-sexp' function for `hs-minor-mode'.
Argument ARG is ignored."
  (python-nav-end-of-block)
  (end-of-line))

(defun python-hideshow-find-next-block (regexp maxp comments)
  "Python specific `hs-find-next-block' function for `hs-minor-mode'.
Call `python-nav-forward-block' to find next block and check if
block-start ends within MAXP.  If COMMENTS is not nil, comments
are also searched.  REGEXP is passed to `looking-at' to set
`match-data'."
  (let* ((next-block (save-excursion
                       (or (and
                            (python-info-looking-at-beginning-of-block)
                            (re-search-forward
                             (python-rx block-start) maxp t))
                           (and (python-nav-forward-block)
                                (< (point) maxp)
                                (re-search-forward
                                 (python-rx block-start) maxp t))
                           (1+ maxp))))
         (next-comment
          (or (when comments
                (save-excursion
                  (cl-loop while (re-search-forward "#" maxp t)
                           if (python-syntax-context 'comment)
                           return (point))))
              (1+ maxp)))
         (next-block-or-comment (min next-block next-comment)))
    (when (<= next-block-or-comment maxp)
      (goto-char next-block-or-comment)
      (save-excursion
        (beginning-of-line)
        (looking-at regexp)))))


;;; Imenu

(defvar python-imenu-format-item-label-function
  'python-imenu-format-item-label
  "Imenu function used to format an item label.
It must be a function with two arguments: TYPE and NAME.")

(defvar python-imenu-format-parent-item-label-function
  'python-imenu-format-parent-item-label
  "Imenu function used to format a parent item label.
It must be a function with two arguments: TYPE and NAME.")

(defvar python-imenu-format-parent-item-jump-label-function
  'python-imenu-format-parent-item-jump-label
  "Imenu function used to format a parent jump item label.
It must be a function with two arguments: TYPE and NAME.")

(defun python-imenu-format-item-label (type name)
  "Return Imenu label for single node using TYPE and NAME."
  (format "%s (%s)" name type))

(defun python-imenu-format-parent-item-label (type name)
  "Return Imenu label for parent node using TYPE and NAME."
  (format "%s..." (python-imenu-format-item-label type name)))

(defun python-imenu-format-parent-item-jump-label (type _name)
  "Return Imenu label for parent node jump using TYPE and NAME."
  (if (string= type "class")
      "*class definition*"
    "*function definition*"))

(defun python-imenu--get-defun-type-name ()
  "Return defun type and name at current position."
  (when (looking-at python-nav-beginning-of-defun-regexp)
    (let ((split (split-string (match-string-no-properties 0))))
      (if (= (length split) 2)
          split
        (list (concat (car split) " " (cadr split))
              (car (last split)))))))

(defun python-imenu--put-parent (type name pos tree)
  "Add the parent with TYPE, NAME and POS to TREE."
  (let ((label
         (funcall python-imenu-format-item-label-function type name))
        (jump-label
         (funcall python-imenu-format-parent-item-jump-label-function type name)))
    (if (not tree)
        (cons label pos)
      (cons label (cons (cons jump-label pos) tree)))))

(defun python-imenu--build-tree (&optional min-indent prev-indent tree)
  "Recursively build the tree of nested definitions of a node.
Arguments MIN-INDENT, PREV-INDENT and TREE are internal and should
not be passed explicitly unless you know what you are doing."
  (setq min-indent (or min-indent 0)
        prev-indent (or prev-indent python-indent-offset))
  (let* ((pos (python-nav-backward-defun))
         (defun-type-name (and pos (python-imenu--get-defun-type-name)))
         (type (car defun-type-name))
         (name (cadr defun-type-name))
         (label (when name
                  (funcall python-imenu-format-item-label-function type name)))
         (indent (current-indentation))
         (children-indent-limit (+ python-indent-offset min-indent)))
    (cond ((not pos)
           ;; Nothing found, probably near to bobp.
           nil)
          ((<= indent min-indent)
           ;; The current indentation points that this is a parent
           ;; node, add it to the tree and stop recursing.
           (python-imenu--put-parent type name pos tree))
          (t
           (python-imenu--build-tree
            min-indent
            indent
            (if (<= indent children-indent-limit)
                ;; This lies within the children indent offset range,
                ;; so it's a normal child of its parent (i.e., not
                ;; a child of a child).
                (cons (cons label pos) tree)
              ;; Oh no, a child of a child?!  Fear not, we
              ;; know how to roll.  We recursively parse these by
              ;; swapping prev-indent and min-indent plus adding this
              ;; newly found item to a fresh subtree.  This works, I
              ;; promise.
              (cons
               (python-imenu--build-tree
                prev-indent indent (list (cons label pos)))
               tree)))))))

(defun python-imenu-create-index ()
  "Return tree Imenu alist for the current Python buffer.
Change `python-imenu-format-item-label-function',
`python-imenu-format-parent-item-label-function',
`python-imenu-format-parent-item-jump-label-function' to
customize how labels are formatted."
  (goto-char (point-max))
  (let ((index)
        (tree))
    (while (setq tree (python-imenu--build-tree))
      (setq index (cons tree index)))
    index))

(defun python-imenu-create-flat-index (&optional alist prefix)
  "Return flat outline of the current Python buffer for Imenu.
Optional argument ALIST is the tree to be flattened; when nil
`python-imenu-create-index' is used with
`python-imenu-format-parent-item-jump-label-function'
`python-imenu-format-parent-item-label-function'
`python-imenu-format-item-label-function' set to
  (lambda (type name) name)
Optional argument PREFIX is used in recursive calls and should
not be passed explicitly.

Converts this:

    ((\"Foo\" . 103)
     (\"Bar\" . 138)
     (\"decorator\"
      (\"decorator\" . 173)
      (\"wrap\"
       (\"wrap\" . 353)
       (\"wrapped_f\" . 393))))

To this:

    ((\"Foo\" . 103)
     (\"Bar\" . 138)
     (\"decorator\" . 173)
     (\"decorator.wrap\" . 353)
     (\"decorator.wrapped_f\" . 393))"
  ;; Inspired by imenu--flatten-index-alist removed in revno 21853.
  (apply
   #'nconc
   (mapcar
    (lambda (item)
      (let ((name (if prefix
                      (concat prefix "." (car item))
                    (car item)))
            (pos (cdr item)))
        (cond ((or (numberp pos) (markerp pos))
               (list (cons name pos)))
              ((listp pos)
               (cons
                (cons name (cdar pos))
                (python-imenu-create-flat-index (cddr item) name))))))
    (or alist
        (let* ((fn (lambda (_type name) name))
               (python-imenu-format-item-label-function fn)
              (python-imenu-format-parent-item-label-function fn)
              (python-imenu-format-parent-item-jump-label-function fn))
          (python-imenu-create-index))))))

;;; Tree-sitter imenu

(defun python--treesit-defun-name (node)
  "Return the defun name of NODE.
Return nil if there is no name or if NODE is not a defun node."
  (pcase (treesit-node-type node)
    ((or "function_definition" "class_definition")
     (treesit-node-text
      (treesit-node-child-by-field-name
       node "name")
      t))))

(defun python--imenu-treesit-create-index-1 (node)
  "Given a sparse tree, create an imenu alist.

NODE is the root node of the tree returned by
`treesit-induce-sparse-tree' (not a tree-sitter node, its car is
a tree-sitter node).  Walk that tree and return an imenu alist.

Return a list of ENTRY where

ENTRY := (NAME . MARKER)
       | (NAME . ((JUMP-LABEL . MARKER)
                  ENTRY
                  ...)

NAME is the function/class's name, JUMP-LABEL is like \"*function
definition*\"."
  (let* ((ts-node (car node))
         (children (cdr node))
         (subtrees (mapcan #'python--imenu-treesit-create-index-1
                           children))
         (type (pcase (treesit-node-type ts-node)
                 ("function_definition" 'def)
                 ("class_definition" 'class)))
         ;; The root of the tree could have a nil ts-node.
         (name (when ts-node
                 (or (treesit-defun-name ts-node)
                     "Anonymous")))
         (marker (when ts-node
                   (set-marker (make-marker)
                               (treesit-node-start ts-node)))))
    (cond
     ((null ts-node)
      subtrees)
     (subtrees
      (let ((parent-label
             (funcall python-imenu-format-parent-item-label-function
                      type name))
            (jump-label
             (funcall
              python-imenu-format-parent-item-jump-label-function
              type name)))
        `((,parent-label
           ,(cons jump-label marker)
           ,@subtrees))))
     (t (let ((label
               (funcall python-imenu-format-item-label-function
                        type name)))
          (list (cons label marker)))))))

(defun python-imenu-treesit-create-index (&optional node)
  "Return tree Imenu alist for the current Python buffer.

Change `python-imenu-format-item-label-function',
`python-imenu-format-parent-item-label-function',
`python-imenu-format-parent-item-jump-label-function' to
customize how labels are formatted.

NODE is the root node of the subtree you want to build an index
of.  If nil, use the root node of the whole parse tree.

Similar to `python-imenu-create-index' but use tree-sitter."
  (let* ((node (or node (treesit-buffer-root-node 'python)))
         (tree (treesit-induce-sparse-tree
                node
                (rx (seq bol
                         (or "function" "class")
                         "_definition"
                         eol))
                nil 1000)))
    (python--imenu-treesit-create-index-1 tree)))

(defun python-imenu-treesit-create-flat-index ()
  "Return flat outline of the current Python buffer for Imenu.

Change `python-imenu-format-item-label-function',
`python-imenu-format-parent-item-label-function',
`python-imenu-format-parent-item-jump-label-function' to
customize how labels are formatted.

Similar to `python-imenu-create-flat-index' but use
tree-sitter."
  (python-imenu-create-flat-index
   (python-imenu-treesit-create-index)))


;;; Tree-sitter things

(defvar python--thing-settings
  `((python
     (defun ,(rx (or "function" "class") "_definition"))
     (sexp (not (or (and named
                         ,(rx bos (or "module"
                                      "block"
                                      "comment")
                              eos))
                    (and anonymous
                         ,(rx bos (or "(" ")" "[" "]" "{" "}" ",")
                              eos)))))
     (list ,(rx bos (or "parameters"
                        "type_parameter"
                        "parenthesized_list_splat"
                        "argument_list"
                        "_list_pattern"
                        "_tuple_pattern"
                        "dict_pattern"
                        "tuple_pattern"
                        "list_pattern"
                        "list"
                        "set"
                        "tuple"
                        "dictionary"
                        "list_comprehension"
                        "dictionary_comprehension"
                        "set_comprehension"
                        "generator_expression"
                        "parenthesized_expression"
                        "interpolation")
                eos))
     (sentence ,(rx (or "statement"
                        "clause")))
     (text ,(rx (or "string" "comment")))))
  "`treesit-thing-settings' for Python.")

;;; Misc helpers

(defun python-info-current-defun (&optional include-type)
  "Return name of surrounding function with Python compatible dotty syntax.
Optional argument INCLUDE-TYPE indicates to include the type of the defun.
This function can be used as the value of `add-log-current-defun-function'
since it returns nil if point is not inside a defun."
  (save-restriction
    (widen)
    (save-excursion
      (end-of-line 1)
      (let ((names)
            (starting-indentation (current-indentation))
            (starting-pos (point))
            (first-run t)
            (last-indent)
            (type))
        (catch 'exit
          (while (python-nav-beginning-of-defun 1)
            (when (save-match-data
                    (and
                     (or (not last-indent)
                         (< (current-indentation) last-indent))
                     (or
                      (and first-run
                           (save-excursion
                             ;; If this is the first run, we may add
                             ;; the current defun at point.
                             (setq first-run nil)
                             (goto-char starting-pos)
                             (python-nav-beginning-of-statement)
                             (beginning-of-line 1)
                             (looking-at-p
                              python-nav-beginning-of-defun-regexp)))
                      (< starting-pos
                         (save-excursion
                           (let ((min-indent
                                  (+ (current-indentation)
                                     python-indent-offset)))
                             (if (< starting-indentation  min-indent)
                                 ;; If the starting indentation is not
                                 ;; within the min defun indent make the
                                 ;; check fail.
                                 starting-pos
                               ;; Else go to the end of defun and add
                               ;; up the current indentation to the
                               ;; ending position.
                               (python-nav-end-of-defun)
                               (+ (point)
                                  (if (>= (current-indentation) min-indent)
                                      (1+ (current-indentation))
                                    0)))))))))
              (save-match-data (setq last-indent (current-indentation)))
              (if (or (not include-type) type)
                  (setq names (cons (match-string-no-properties 1) names))
                (let ((match (split-string (match-string-no-properties 0))))
                  (setq type (car match))
                  (setq names (cons (cadr match) names)))))
            ;; Stop searching ASAP.
            (and (= (current-indentation) 0) (throw 'exit t))))
        (and names
             (concat (and type (format "%s " type))
                     (mapconcat #'identity names ".")))))))

(defun python-info-treesit-current-defun (&optional include-type)
  "Identical to `python-info-current-defun' but use tree-sitter.
For INCLUDE-TYPE see `python-info-current-defun'."
  (let ((node (treesit-node-at (point)))
        (name-list ())
        (type 'def))
    (cl-loop while node
             if (pcase (treesit-node-type node)
                  ("function_definition"
                   (setq type 'def))
                  ("class_definition"
                   (setq type 'class))
                  (_ nil))
             do (push (treesit-node-text
                       (treesit-node-child-by-field-name node "name")
                       t)
                      name-list)
             do (setq node (treesit-node-parent node))
             finally return (concat (if include-type
                                        (format "%s " type)
                                      "")
                                    (string-join name-list ".")))))

(defun python-info-current-symbol (&optional replace-self)
  "Return current symbol using dotty syntax.
With optional argument REPLACE-SELF convert \"self\" to current
parent defun name."
  (let ((name
         (and (not (python-syntax-comment-or-string-p))
              (with-syntax-table python-dotty-syntax-table
                (let ((sym (symbol-at-point)))
                  (and sym
                       (substring-no-properties (symbol-name sym))))))))
    (when name
      (if (not replace-self)
          name
        (let ((current-defun (python-info-current-defun)))
          (if (not current-defun)
              name
            (replace-regexp-in-string
             (python-rx line-start word-start "self" word-end ?.)
             (concat
              (mapconcat #'identity
                         (butlast (split-string current-defun "\\."))
                         ".")
              ".")
             name)))))))

(defun python-info-statement-starts-block-p ()
  "Return non-nil if current statement opens a block."
  (save-excursion
    (python-nav-beginning-of-statement)
    (looking-at (python-rx block-start))))

(defun python-info-statement-ends-block-p ()
  "Return non-nil if point is at end of block."
  (let* (current-statement
         (current-indentation (save-excursion
                                (setq current-statement
                                      (python-nav-beginning-of-statement))
                                (current-indentation)))
         next-statement
         (next-indentation (save-excursion
                             (python-nav-forward-statement)
                             (setq next-statement (point))
                             (current-indentation))))
    (unless (and (< current-statement next-statement)
                 (<= current-indentation next-indentation))
      (and-let* ((end-of-statement-pos (save-excursion
                                         (python-nav-end-of-statement)
                                         (python-util-forward-comment -1)
                                         (point)))
                 (end-of-block-pos (save-excursion
                                     (python-nav-end-of-block))))
        (= end-of-block-pos end-of-statement-pos)))))

(defun python-info-beginning-of-statement-p ()
  "Return non-nil if point is at beginning of statement."
  (= (point) (save-excursion
               (python-nav-beginning-of-statement)
               (point))))

(defun python-info-end-of-statement-p ()
  "Return non-nil if point is at end of statement."
  (= (point) (save-excursion
               (python-nav-end-of-statement)
               (point))))

(defun python-info-beginning-of-block-p ()
  "Return non-nil if point is at beginning of block."
  (and (python-info-beginning-of-statement-p)
       (python-info-statement-starts-block-p)))

(defun python-info-end-of-block-p ()
  "Return non-nil if point is at end of block."
  (and (= (point) (save-excursion
                    (python-nav-end-of-statement)
                    (python-util-forward-comment -1)
                    (point)))
       (python-info-statement-ends-block-p)))

(define-obsolete-function-alias
  'python-info-closing-block
  #'python-info-dedenter-opening-block-position "24.4")

(defun python-info-dedenter-opening-block-position ()
  "Return the point of the closest block the current line closes.
Returns nil if point is not on a dedenter statement or no opening
block can be detected.  The latter case meaning current file is
likely an invalid python file."
  (let ((positions (python-info-dedenter-opening-block-positions))
        (indentation (current-indentation))
        (position))
    (while (and (not position)
                positions)
      (save-excursion
        (goto-char (car positions))
        (if (<= (current-indentation) indentation)
            (setq position (car positions))
          (setq positions (cdr positions)))))
    position))

(defun python-info-dedenter-opening-block-positions ()
  "Return points of blocks the current line may close sorted by closer.
Returns nil if point is not on a dedenter statement or no opening
block can be detected.  The latter case meaning current file is
likely an invalid python file."
  (save-excursion
    (let ((dedenter-pos (python-info-dedenter-statement-p)))
      (when dedenter-pos
        (goto-char dedenter-pos)
        (let* ((cur-line (line-beginning-position))
               (pairs '(("elif" "elif" "if")
                        ("else" "if" "elif" "except" "for" "while")
                        ("except" "except" "try")
                        ("finally" "else" "except" "try")
                        ("case" "case")))
               (dedenter (match-string-no-properties 0))
               (possible-opening-blocks (cdr (assoc-string dedenter pairs)))
               (collected-indentations)
               (opening-blocks))
          (catch 'exit
            (while (python-nav--syntactically
                    (lambda ()
                      (cl-loop while (re-search-backward (python-rx block-start) nil t)
                               if (save-match-data
                                    (looking-back (rx line-start (* whitespace))
                                                  (line-beginning-position)))
                               return t))
                    #'<)
              (let ((indentation (current-indentation)))
                (when (and (not (memq indentation collected-indentations))
                           (or (not collected-indentations)
                               (< indentation
                                  (apply #'min collected-indentations)))
                           ;; There must be no line with indentation
                           ;; smaller than `indentation' (except for
                           ;; blank lines) between the found opening
                           ;; block and the current line, otherwise it
                           ;; is not an opening block.
                           (save-excursion
                             (python-nav-end-of-statement)
                             (forward-line)
                             (let ((no-back-indent t))
                               (save-match-data
                                 (while (and (< (point) cur-line)
                                             (setq no-back-indent
                                                   (or (> (current-indentation) indentation)
                                                       (python-info-current-line-empty-p)
                                                       (python-info-current-line-comment-p))))
                                   (forward-line)))
                               no-back-indent)))
                  (setq collected-indentations
                        (cons indentation collected-indentations))
                  (when (member (match-string-no-properties 0)
                                possible-opening-blocks)
                    (setq opening-blocks (cons (point) opening-blocks))))
                (when (zerop indentation)
                  (throw 'exit nil)))))
          ;; sort by closer
          (nreverse opening-blocks))))))

(define-obsolete-function-alias
  'python-info-closing-block-message
  #'python-info-dedenter-opening-block-message "24.4")

(defun python-info-dedenter-opening-block-message  ()
  "Message the first line of the block the current statement closes."
  (let ((point (python-info-dedenter-opening-block-position)))
    (when point
        (message "Closes %s" (save-excursion
                               (goto-char point)
                               (buffer-substring
                                (point) (line-end-position)))))))

(defun python-info-dedenter-statement-p ()
  "Return point if current statement is a dedenter.
Sets `match-data' to the keyword that starts the dedenter
statement."
  (save-excursion
    (python-nav-beginning-of-statement)
    (when (and (not (python-syntax-context-type))
               (looking-at (python-rx dedenter))
               ;; Exclude the first "case" in the block.
               (not (and (string= (match-string-no-properties 0)
                                  "case")
                         (save-excursion
                           (back-to-indentation)
                           (python-util-forward-comment -1)
                           (equal (char-before) ?:)))))
      (point))))

(defun python-info-line-ends-backslash-p (&optional line-number)
  "Return non-nil if current line ends with backslash.
With optional argument LINE-NUMBER, check that line instead."
  (save-excursion
      (when line-number
        (python-util-goto-line line-number))
      (while (and (not (eobp))
                  (goto-char (line-end-position))
                  (python-syntax-context 'paren)
                  (not (equal (char-before (point)) ?\\)))
        (forward-line 1))
      (when (equal (char-before) ?\\)
        (point-marker))))

(defun python-info-beginning-of-backslash (&optional line-number)
  "Return the point where the backslashed line starts.
Optional argument LINE-NUMBER forces the line number to check against."
  (save-excursion
      (when line-number
        (python-util-goto-line line-number))
      (when (python-info-line-ends-backslash-p)
        (while (save-excursion
                 (goto-char (line-beginning-position))
                 (python-syntax-context 'paren))
          (forward-line -1))
        (back-to-indentation)
        (point-marker))))

(defun python-info-continuation-line-p ()
  "Check if current line is continuation of another.
When current line is continuation of another return the point
where the continued line ends."
  (save-excursion
      (let* ((context-type (progn
                             (back-to-indentation)
                             (python-syntax-context-type)))
             (line-start (line-number-at-pos))
             (context-start (when context-type
                              (python-syntax-context context-type))))
        (cond ((equal context-type 'paren)
               ;; Lines inside a paren are always a continuation line
               ;; (except the first one).
               (python-util-forward-comment -1)
               (point-marker))
              ((member context-type '(string comment))
               ;; move forward an roll again
               (goto-char context-start)
               (python-util-forward-comment)
               (python-info-continuation-line-p))
              (t
               ;; Not within a paren, string or comment, the only way
               ;; we are dealing with a continuation line is that
               ;; previous line contains a backslash, and this can
               ;; only be the previous line from current
               (back-to-indentation)
               (python-util-forward-comment -1)
               (when (and (equal (1- line-start) (line-number-at-pos))
                          (python-info-line-ends-backslash-p))
                 (point-marker)))))))

(defun python-info-block-continuation-line-p ()
  "Return non-nil if current line is a continuation of a block."
  (save-excursion
    (when (python-info-continuation-line-p)
      (forward-line -1)
      (back-to-indentation)
      (when (looking-at (python-rx block-start))
        (point-marker)))))

(defun python-info-assignment-statement-p (&optional current-line-only)
  "Check if current line is an assignment.
With argument CURRENT-LINE-ONLY is non-nil, don't follow any
continuations, just check the if current line is an assignment."
  (save-excursion
    (let ((found nil))
      (if current-line-only
          (back-to-indentation)
        (python-nav-beginning-of-statement))
      (while (and
              (re-search-forward (python-rx not-simple-operator
                                            assignment-operator
                                            (group not-simple-operator))
                                 (line-end-position) t)
              (not found))
        (save-excursion
          ;; The assignment operator should not be inside a string.
          (backward-char (length (match-string-no-properties 1)))
          (setq found (not (python-syntax-context-type)))))
      (when found
        (skip-syntax-forward " ")
        (point-marker)))))

;; TODO: rename to clarify this is only for the first continuation
;; line or remove it and move its body to `python-indent-context'.
(defun python-info-assignment-continuation-line-p ()
  "Check if current line is the first continuation of an assignment.
When current line is continuation of another with an assignment
return the point of the first non-blank character after the
operator."
  (save-excursion
    (when (python-info-continuation-line-p)
      (forward-line -1)
      (python-info-assignment-statement-p t))))

(defun python-info-looking-at-beginning-of-defun (&optional syntax-ppss
                                                            check-statement)
  "Check if point is at `beginning-of-defun' using SYNTAX-PPSS.
When CHECK-STATEMENT is non-nil, the current statement is checked
instead of the current physical line."
  (save-excursion
    (when check-statement
      (python-nav-beginning-of-statement))
    (beginning-of-line 1)
    (and (not (python-syntax-context-type (or syntax-ppss (syntax-ppss))))
         (looking-at python-nav-beginning-of-defun-regexp))))

(defun python-info-looking-at-beginning-of-block ()
  "Check if point is at the beginning of block."
  (let ((pos (point)))
    (save-excursion
      (python-nav-beginning-of-statement)
      (beginning-of-line)
      (and
       (<= (point) pos (+ (point) (current-indentation)))
       (looking-at python-nav-beginning-of-block-regexp)))))

(defun python-info-current-line-comment-p ()
  "Return non-nil if current line is a comment line."
  (char-equal
   (or (char-after (+ (line-beginning-position) (current-indentation))) ?_)
   ?#))

(defun python-info-current-line-empty-p ()
  "Return non-nil if current line is empty, ignoring whitespace."
  (save-excursion
    (beginning-of-line 1)
    (looking-at
     (python-rx line-start (* whitespace)
                (group (* not-newline))
                (* whitespace) line-end))
    (string-equal "" (match-string-no-properties 1))))

(defun python-info-docstring-p (&optional syntax-ppss)
  "Return non-nil if point is in a docstring.
When optional argument SYNTAX-PPSS is given, use that instead of
point's current `syntax-ppss'."
  ;;; https://www.python.org/dev/peps/pep-0257/#what-is-a-docstring
  (save-excursion
    (when (and syntax-ppss (python-syntax-context 'string syntax-ppss))
      (goto-char (nth 8 syntax-ppss)))
    (python-nav-beginning-of-statement)
    (let ((counter 1)
          (indentation (current-indentation))
          (backward-sexp-point)
          (re "[uU]?[rR]?[\"']"))
      (when (and
             (not (python-info-assignment-statement-p))
             (looking-at-p re)
             ;; Allow up to two consecutive docstrings only.
             (>=
              2
              (let (last-backward-sexp-point)
                (while (and (<= counter 2)
                            (save-excursion
                              (python-nav-backward-sexp)
                              (setq backward-sexp-point (point))
                              (and (= indentation (current-indentation))
                                   ;; Make sure we're always moving point.
                                   ;; If we get stuck in the same position
                                   ;; on consecutive loop iterations,
                                   ;; bail out.
                                   (prog1 (not (eql last-backward-sexp-point
                                                    backward-sexp-point))
                                     (setq last-backward-sexp-point
                                           backward-sexp-point))
                                   (looking-at-p re))))
                  ;; Previous sexp was a string, restore point.
                  (goto-char backward-sexp-point)
                  (cl-incf counter))
                counter)))
        (python-util-forward-comment -1)
        (python-nav-beginning-of-statement)
        (cond ((and (bobp) (save-excursion
                             (python-util-forward-comment)
                             (looking-at-p re))))
              ((python-info-assignment-statement-p) t)
              ((python-info-looking-at-beginning-of-defun))
              (t nil))))))

(defun python-info-triple-quoted-string-p ()
  "Check if point is in a triple quoted string including quotes.
It returns the position of the third quote character of the start
of the string."
  (save-excursion
    (let ((pos (point)))
      (cl-loop
       for offset in '(0 3 -2 2 -1 1)
       if (let ((check-pos (+ pos offset)))
            (and (>= check-pos (point-min))
                 (<= check-pos (point-max))
                 (python-syntax-context
                  'triple-quoted-string (syntax-ppss check-pos))))
       return it))))

(defun python-info-encoding-from-cookie ()
  "Detect current buffer's encoding from its coding cookie.
Returns the encoding as a symbol."
  (let ((first-two-lines
         (save-excursion
           (save-restriction
             (widen)
             (goto-char (point-min))
             (forward-line 2)
             (buffer-substring-no-properties
              (point)
              (point-min))))))
    (when (string-match (python-rx coding-cookie) first-two-lines)
      (intern (match-string-no-properties 1 first-two-lines)))))

(defun python-info-encoding ()
  "Return encoding for file.
Try `python-info-encoding-from-cookie', if none is found then
default to utf-8."
  ;; If no encoding is defined, then it's safe to use UTF-8: Python 2
  ;; uses ASCII as default while Python 3 uses UTF-8.  This means that
  ;; in the worst case scenario python.el will make things work for
  ;; Python 2 files with unicode data and no encoding defined.
  (or (python-info-encoding-from-cookie)
      'utf-8))


;;; Utility functions

(defun python-util-goto-line (line-number)
  "Move point to LINE-NUMBER."
  (goto-char (point-min))
  (forward-line (1- line-number)))

;; Stolen from org-mode
(defun python-util-clone-local-variables (from-buffer &optional regexp)
  "Clone local variables from FROM-BUFFER.
Optional argument REGEXP selects variables to clone and defaults
to \"^python-\"."
  (mapc
   (lambda (pair)
     (and (consp pair)
          (symbolp (car pair))
          (string-match (or regexp "^python-")
                        (symbol-name (car pair)))
          (set (make-local-variable (car pair))
               (cdr pair))))
   (buffer-local-variables from-buffer)))

(defvar comint-last-prompt-overlay)     ; Shut up, byte compiler.

(defun python-util-comint-last-prompt ()
  "Return comint last prompt overlay start and end.
This is for compatibility with Emacs < 24.4."
  (cond ((bound-and-true-p comint-last-prompt-overlay)
         (cons (overlay-start comint-last-prompt-overlay)
               (overlay-end comint-last-prompt-overlay)))
        ((bound-and-true-p comint-last-prompt)
         comint-last-prompt)
        (t nil)))

(defun python-util-comint-end-of-output-p ()
  "Return non-nil if the last prompt matches input prompt."
  (when-let* ((prompt (python-util-comint-last-prompt)))
    (python-shell-comint-end-of-output-p
     (buffer-substring-no-properties
      (car prompt) (cdr prompt)))))

(defun python-util-forward-comment (&optional direction)
  "Python mode specific version of `forward-comment'.
Optional argument DIRECTION defines the direction to move to."
  (let ((comment-start (python-syntax-context 'comment))
        (factor (if (< (or direction 0) 0)
                    -99999
                  99999)))
    (when comment-start
      (goto-char comment-start))
    (forward-comment factor)))

(defun python-util-list-directories (directory &optional predicate max-depth)
  "List DIRECTORY subdirs, filtered by PREDICATE and limited by MAX-DEPTH.
Argument PREDICATE defaults to `identity' and must be a function
that takes one argument (a full path) and returns non-nil for
allowed files.  When optional argument MAX-DEPTH is non-nil, stop
searching when depth is reached, else don't limit."
  (let* ((dir (expand-file-name directory))
         (dir-length (length dir))
         (predicate (or predicate #'identity))
         (to-scan (list dir))
         (tally nil))
    (while to-scan
      (let ((current-dir (car to-scan)))
        (when (funcall predicate current-dir)
          (setq tally (cons current-dir tally)))
        (setq to-scan (append (cdr to-scan)
                              (python-util-list-files
                               current-dir #'file-directory-p)
                              nil))
        (when (and max-depth
                   (<= max-depth
                       (length (split-string
                                (substring current-dir dir-length)
                                "/\\|\\\\" t))))
          (setq to-scan nil))))
    (nreverse tally)))

(defun python-util-list-files (dir &optional predicate)
  "List files in DIR, filtering with PREDICATE.
Argument PREDICATE defaults to `identity' and must be a function
that takes one argument (a full path) and returns non-nil for
allowed files."
  (let ((dir-name (file-name-as-directory dir)))
    (apply #'nconc
           (mapcar (lambda (file-name)
                     (let ((full-file-name
                            (expand-file-name file-name dir-name)))
                       (when (and
                              (not (member file-name '("." "..")))
                              (funcall (or predicate #'identity)
                                       full-file-name))
                         (list full-file-name))))
                   (directory-files dir-name)))))

(defun python-util-list-packages (dir &optional max-depth)
  "List packages in DIR, limited by MAX-DEPTH.
When optional argument MAX-DEPTH is non-nil, stop searching when
depth is reached, else don't limit."
  (let* ((dir (expand-file-name dir))
         (parent-dir (file-name-directory
                      (directory-file-name
                       (file-name-directory
                        (file-name-as-directory dir)))))
         (subpath-length (length parent-dir)))
    (mapcar
     (lambda (file-name)
       (replace-regexp-in-string
        (rx (or ?\\ ?/)) "." (substring file-name subpath-length)))
     (python-util-list-directories
      (directory-file-name dir)
      (lambda (dir)
        (file-exists-p (expand-file-name "__init__.py" dir)))
      max-depth))))

(defun python-util-popn (lst n)
  "Return LST first N elements.
N should be an integer, when negative its opposite is used.
When N is bigger than the length of LST, the list is
returned as is."
  (let* ((n (min (abs n)))
         (len (length lst))
         (acc))
    (if (> n len)
        lst
      (while (< 0 n)
        (setq acc (cons (car lst) acc)
              lst (cdr lst)
              n (1- n)))
      (reverse acc))))

(defun python-util-strip-string (string)
  "Strip STRING whitespace and newlines from end and beginning."
  (replace-regexp-in-string
   (rx (or (: string-start (* (any whitespace ?\r ?\n)))
           (: (* (any whitespace ?\r ?\n)) string-end)))
   ""
   string))

(defun python-util-valid-regexp-p (regexp)
  "Return non-nil if REGEXP is valid."
  (ignore-errors (string-match regexp "") t))


;;; Flymake integration

(defgroup python-flymake nil
  "Integration between Python and Flymake."
  :group 'python
  :link '(custom-group-link :tag "Flymake" flymake)
  :version "26.1")

(defcustom python-flymake-command '("pyflakes")
  "The external tool that will be used to perform the syntax check.
This is a non-empty list of strings: the checker tool possibly followed by
required arguments.  Once launched it will receive the Python source to be
checked as its standard input.
To use `flake8' you would set this to (\"flake8\" \"-\").
To use `pylint' you would set this to (\"pylint\" \"--from-stdin\" \"stdin\")."
  :version "26.1"
  :type '(choice (const :tag "Pyflakes" ("pyflakes"))
                 (const :tag "Flake8" ("flake8" "-"))
                 (const :tag "Pylint" ("pylint" "--from-stdin" "stdin"))
                 (repeat :tag "Custom command" string)))

;; The default regexp accommodates for older pyflakes, which did not
;; report the column number, and at the same time it's compatible with
;; flake8 output, although it may be redefined to explicitly match the
;; TYPE
(defcustom python-flymake-command-output-pattern
  (list
   "^\\(?:<?stdin>?\\):\\(?1:[0-9]+\\):\\(?:\\(?2:[0-9]+\\):?\\)? \\(?3:.*\\)$"
   1 2 nil 3)
  "Specify how to parse the output of `python-flymake-command'.
The value has the form (REGEXP LINE COLUMN TYPE MESSAGE): if
REGEXP matches, the LINE'th subexpression gives the line number,
the COLUMN'th subexpression gives the column number on that line,
the TYPE'th subexpression gives the type of the message and the
MESSAGE'th gives the message text itself.

If COLUMN or TYPE are nil or that index didn't match, that
information is not present on the matched line and a default will
be used."
  :type '(list regexp
               (integer :tag "Line's index")
               (choice
                (const :tag "No column" nil)
                (integer :tag "Column's index"))
               (choice
                (const :tag "No type" nil)
                (integer :tag "Type's index"))
               (integer :tag "Message's index"))
  :version "29.1")

(defcustom python-flymake-msg-alist
  '(("\\(^redefinition\\|.*unused.*\\|used$\\)" . :warning))
  "Alist used to associate messages to their types.
Each element should be a cons-cell (REGEXP . TYPE), where TYPE
should be a diagnostic type symbol like `:error', `:warning' or
`:note'.  For example, when using `flake8' a possible
configuration could be:

  ((\"\\(^redefinition\\|.*unused.*\\|used$\\)\" . :warning)
   (\"^E999\" . :error)
   (\"^[EW][0-9]+\" . :note))

By default messages are considered errors."
  :version "26.1"
  :type '(alist :key-type (regexp)
                :value-type (symbol)))

(defvar-local python--flymake-proc nil)

(defun python--flymake-parse-output (source proc report-fn)
  "Collect diagnostics parsing checker tool's output line by line."
  (let ((rx (nth 0 python-flymake-command-output-pattern))
        (lineidx (nth 1 python-flymake-command-output-pattern))
        (colidx (nth 2 python-flymake-command-output-pattern))
        (typeidx (nth 3 python-flymake-command-output-pattern))
        (msgidx (nth 4 python-flymake-command-output-pattern)))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-min))
      (cl-loop
       while (search-forward-regexp rx nil t)
       for msg = (match-string msgidx)
       for (beg . end) = (flymake-diag-region
                          source
                          (string-to-number
                           (match-string lineidx))
                          (and colidx
                               (match-string colidx)
                               (string-to-number
                                (match-string colidx))))
       for type = (or (and typeidx
                           (match-string typeidx)
                           (assoc-default
                            (match-string typeidx)
                            python-flymake-msg-alist
                            #'string-match))
                      (assoc-default msg
                                     python-flymake-msg-alist
                                     #'string-match)
                      :error)
       collect (flymake-make-diagnostic
                source beg end type msg)
       into diags
       finally (funcall report-fn diags)))))

(defun python-flymake (report-fn &rest _args)
  "Flymake backend for Python.
This backend uses `python-flymake-command' (which see) to launch a process
that is passed the current buffer's content via stdin.
REPORT-FN is Flymake's callback function."
  (unless (executable-find (car python-flymake-command))
    (error "Cannot find a suitable checker"))

  (when (process-live-p python--flymake-proc)
    (kill-process python--flymake-proc))

  (let ((source (current-buffer)))
    (save-restriction
      (widen)
      (setq python--flymake-proc
            (make-process
             :name "python-flymake"
             :noquery t
             :connection-type 'pipe
             :buffer (generate-new-buffer " *python-flymake*")
             :command python-flymake-command
             :sentinel
             (lambda (proc _event)
               (when (eq 'exit (process-status proc))
                 (unwind-protect
                     (when (with-current-buffer source
                             (eq proc python--flymake-proc))
                       (python--flymake-parse-output source proc report-fn))
                   (kill-buffer (process-buffer proc)))))))
      (process-send-region python--flymake-proc (point-min) (point-max))
      (process-send-eof python--flymake-proc))))


;;; Import management
(defconst python--list-imports "\
from sys import argv, exit, stdin

try:
    from isort import find_imports_in_stream, find_imports_in_paths
except ModuleNotFoundError:
    exit(2)
except ImportError:
    exit(3)

query, files, result = argv[1] or None, argv[2:], {}

if files:
    imports = find_imports_in_paths(files, top_only=True)
else:
    imports = find_imports_in_stream(stdin, top_only=True)

for imp in imports:
    if query is None or query == (imp.alias or imp.attribute or imp.module):
        key = (imp.module, imp.attribute or '', imp.alias or '')
        if key not in result:
            result[key] = imp.statement()

for key in sorted(result):
    print(result[key])
"
  "Script to list import statements in Python code.")

(defvar python-import-history nil
  "History variable for `python-import' commands.")

(defun python--import-sources ()
  "List files containing Python imports that may be useful in the current buffer."
  (if-let* (((featurep 'project))        ;For compatibility with Emacs < 26
            (proj (project-current)))
      (seq-filter (lambda (s) (string-match-p "\\.py[iwx]?\\'" s))
                  (project-files proj))
    (list default-directory)))

(defun python--list-imports-check-status (status)
  (unless (eq 0 status)
    (let* ((details
            (cond
             ((eq 2 status) " (maybe isort is missing?)")
             ((eq 3 status) " (maybe isort version is older than 5.7.0?)")
             (t "")))
           (msg
            (concat "%s exited with status %s" details)))
      (error msg python-interpreter status))))

(defun python--list-imports (name source)
  "List all Python imports matching NAME in SOURCE.
If NAME is nil, list all imports.  SOURCE can be a buffer or a
list of file names or directories; the latter are searched
recursively."
  (let ((buffer (current-buffer)))
    (with-temp-buffer
      (let* ((temp (current-buffer))
             (status (if (bufferp source)
                         (with-current-buffer source
                           (apply #'call-process-region
                                  (point-min) (point-max)
                                  python-interpreter
                                  nil (list temp nil) nil
                                  (append
                                   (split-string-shell-command
                                    python-interpreter-args)
                                   `("-c" ,python--list-imports)
                                    (list (or name "")))))
                       (with-current-buffer buffer
                         (apply #'call-process
                                python-interpreter
                                nil (list temp nil) nil
                                (append
                                 (split-string-shell-command
                                  python-interpreter-args)
                                 `("-c" ,python--list-imports)
                                 (list (or name ""))
                                 (mapcar #'file-local-name source))))))
             lines)
        (python--list-imports-check-status status)
        (goto-char (point-min))
        (while (not (eobp))
	  (push (buffer-substring-no-properties (point) (pos-eol))
                lines)
	  (forward-line 1))
        (nreverse lines)))))

(defun python--query-import (name source prompt)
  "Read a Python import statement defining NAME.
A list of candidates is produced by `python--list-imports' using
the NAME and SOURCE arguments.  An interactive query, using the
PROMPT string, is made unless there is a single candidate."
  (let* ((cands (python--list-imports name source))
         ;; Don't use DEF argument of `completing-read', so it is able
         ;; to return the empty string.
         (minibuffer-default-add-function
          (lambda ()
            (setq minibuffer-default (with-minibuffer-selected-window
                                       (thing-at-point 'symbol)))))
         (statement (cond ((and name (length= cands 1))
                           (car cands))
                          (prompt
                           (completing-read prompt
                                            (or cands python-import-history)
                                            nil nil nil
                                            'python-import-history)))))
    (unless (string-empty-p statement)
      statement)))

(defun python--do-isort (&rest args)
  "Edit the current buffer using isort called with ARGS.
Return non-nil if the buffer was actually modified."
  (let ((buffer (current-buffer)))
    (with-temp-buffer
      (let ((temp (current-buffer)))
        (with-current-buffer buffer
          (let ((status (apply #'call-process-region
                               (point-min) (point-max)
                               python-interpreter
                               nil (list temp nil) nil
                               (append
                                 (split-string-shell-command
                                  python-interpreter-args)
                                 '("-m" "isort" "-")
                                 args)))
                (tick (buffer-chars-modified-tick)))
            (unless (eq 0 status)
              (error "%s exited with status %s (maybe isort is missing?)"
                     python-interpreter status))
            (replace-region-contents (point-min) (point-max) temp)
            (not (eq tick (buffer-chars-modified-tick)))))))))

;;;###autoload
(defun python-add-import (name)
  "Add an import statement to the current buffer.

Interactively, ask for an import statement using all imports
found in the current project as suggestions.  With a prefix
argument, restrict the suggestions to imports defining the symbol
at point.  If there is only one such suggestion, act without
asking.

If the buffer does not belong to a project, the import statement is
searched under the buffer's default directory.  For example, if the file
is located directly under the home directory, all files under the home
directory will be searched.  Please note that this can take a long time
and may appear to hang.

When calling from Lisp, use a non-nil NAME to restrict the
suggestions to imports defining NAME."
  (interactive (list (when current-prefix-arg (thing-at-point 'symbol))))
  (when-let* ((statement (python--query-import name
                                               (python--import-sources)
                                               "Add import: ")))
    (if (python--do-isort "--add" statement)
        (message "Added `%s'" statement)
      (message "(No changes in Python imports needed)"))))

;;;###autoload
(defun python-import-symbol-at-point ()
  "Add an import statement for the symbol at point to the current buffer.
This works like `python-add-import', but with the opposite
behavior regarding the prefix argument."
  (interactive nil)
  (python-add-import (unless current-prefix-arg (thing-at-point 'symbol))))

;;;###autoload
(defun python-remove-import (name)
  "Remove an import statement from the current buffer.

Interactively, ask for an import statement to remove, displaying
the imports of the current buffer as suggestions.  With a prefix
argument, restrict the suggestions to imports defining the symbol
at point.  If there is only one such suggestion, act without
asking."
  (interactive (list (when current-prefix-arg (thing-at-point 'symbol))))
  (when-let* ((statement (python--query-import name (current-buffer)
                                               "Remove import: ")))
    (if (python--do-isort "--rm" statement)
        (message "Removed `%s'" statement)
      (message "(No changes in Python imports needed)"))))

;;;###autoload
(defun python-sort-imports ()
  "Sort Python imports in the current buffer."
  (interactive)
  (if (python--do-isort)
      (message "Sorted imports")
    (message "(No changes in Python imports needed)")))

;;;###autoload
(defun python-fix-imports ()
  "Add missing imports and remove unused ones from the current buffer.

If there are missing imports, ask for an import statement using all
imports found in the current project as suggestions.  If there is only
one such suggestion, act without asking.

If the buffer does not belong to a project, the import statement is
searched under the buffer's default directory.  For example, if the file
is located directly under the home directory, all files under the home
directory will be searched.  Please note that this can take a long time
and may appear to hang."
  (interactive)
  (let ((buffer (current-buffer))
        undefined unused add remove)
    ;; Compute list of undefined and unused names
    (with-temp-buffer
      (let ((temp (current-buffer)))
        (with-current-buffer buffer
          (apply #'call-process-region
                  (point-min) (point-max)
                  python-interpreter
                  nil temp nil
                  (append
                   (split-string-shell-command
                    python-interpreter-args)
                   '("-m" "pyflakes"))))
        (goto-char (point-min))
        (when (looking-at-p ".* No module named pyflakes$")
          (error "%s couldn't find pyflakes" python-interpreter))
        (while (not (eobp))
          (cond ((looking-at ".* undefined name '\\([^']+\\)'$")
                 (push (match-string 1) undefined))
                ((looking-at ".*'\\([^']+\\)' imported but unused$")
                 (push (match-string 1) unused)))
	  (forward-line 1))))
    ;; Compute imports to be added
    (dolist (name (seq-uniq undefined))
      (when-let* ((statement (python--query-import name
                                                   (python--import-sources)
                                                   (format "\
Add import for undefined name `%s' (empty to skip): "
                                                           name))))
        (push statement add)))
    ;; Compute imports to be removed
    (dolist (name (seq-uniq unused))
      ;; The unused imported names, as provided by pyflakes, are of
      ;; the form "module.var" or "module.var as alias", independently
      ;; of style of import statement used.
      (let* ((filter
              (lambda (statement)
                (string= name
                         (thread-last
                           statement
                           (replace-regexp-in-string "^\\(from\\|import\\) " "")
                           (replace-regexp-in-string " import " ".")))))
             (statements (seq-filter filter (python--list-imports nil buffer))))
        (when (length= statements 1)
          (push (car statements) remove))))
    ;; Edit buffer and say goodbye
    (if (not (or add remove))
        (message "(No changes in Python imports needed)")
      (apply #'python--do-isort
             (append (mapcan (lambda (x) (list "--add" x)) add)
                     (mapcan (lambda (x) (list "--rm" x)) remove)))
      (message "%s" (concat (when add "Added ")
                            (when add (string-join add ", "))
                            (when remove (if add " and removed " "Removed "))
                            (when remove (string-join remove ", " )))))))


;;; Major mode
(defun python-electric-pair-string-delimiter ()
  (when (and electric-pair-mode
             (memq last-command-event '(?\" ?\'))
             (let ((count 0))
               (while (eq (char-before (- (point) count)) last-command-event)
                 (cl-incf count))
               (= count 3))
             (eq (char-after) last-command-event))
    (save-excursion (insert (make-string 2 last-command-event)))))

(defvar prettify-symbols-alist)
(defvar python--installed-grep-hook nil)

;;;###autoload
(define-derived-mode python-base-mode prog-mode "Python"
  "Generic major mode for editing Python files.

This is a generic major mode intended to be inherited by
concrete implementations.  Currently there are two concrete
implementations: `python-mode' and `python-ts-mode'."
  (setq-local tab-width 8)
  (setq-local indent-tabs-mode nil)

  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+\\s-*")

  (setq-local parse-sexp-lookup-properties t)
  (setq-local parse-sexp-ignore-comments t)

  (setq-local forward-sexp-function python-forward-sexp-function)

  (setq-local indent-line-function #'python-indent-line-function)
  (setq-local indent-region-function #'python-indent-region)
  ;; Because indentation is not redundant, we cannot safely reindent code.
  (setq-local electric-indent-inhibit t)
  (setq-local electric-indent-chars
              (cons ?: electric-indent-chars))
  (setq-local electric-layout-rules
              `((?: . ,(lambda ()
                         (and (zerop (car (syntax-ppss)))
                              (python-info-statement-starts-block-p)
                              ;; Heuristic for walrus operator :=
                              (save-excursion
                                (goto-char (- (point) 2))
                                (looking-at (rx (not space) ":" eol)))
                              'after)))))

  ;; Add """ ... """ pairing to electric-pair-mode.
  (add-hook 'post-self-insert-hook
            #'python-electric-pair-string-delimiter 'append t)

  (setq-local paragraph-start "\\s-*$")
  (setq-local fill-paragraph-function #'python-fill-paragraph)
  (setq-local normal-auto-fill-function #'python-do-auto-fill)

  (setq-local beginning-of-defun-function #'python-nav-beginning-of-defun)
  (setq-local end-of-defun-function #'python-nav-end-of-defun)

  (add-hook 'completion-at-point-functions
            #'python-completion-at-point nil 'local)

  (add-hook 'post-self-insert-hook
            #'python-indent-post-self-insert-function 'append 'local)

  (setq-local add-log-current-defun-function
              #'python-info-current-defun)

  (setq-local skeleton-further-elements
              '((abbrev-mode nil)
                (< '(backward-delete-char-untabify (min python-indent-offset
                                                        (current-column))))
                (^ '(- (1+ (current-indentation))))))

  (with-no-warnings
    ;; suppress warnings about eldoc-documentation-function being obsolete
    (if (null eldoc-documentation-function)
        ;; Emacs<25
        (setq-local eldoc-documentation-function #'python-eldoc-function)
      (if (boundp 'eldoc-documentation-functions)
          (add-hook 'eldoc-documentation-functions #'python-eldoc-function nil t)
        (add-function :before-until (local 'eldoc-documentation-function)
                      #'python-eldoc-function))))
  (eldoc-add-command-completions "python-indent-dedent-line-backspace")

  ;; TODO: Use tree-sitter to figure out the block in `python-ts-mode'.
  (dolist (mode '(python-mode python-ts-mode))
    (add-to-list
     'hs-special-modes-alist
     `(,mode
       ,python-nav-beginning-of-block-regexp
       ;; Use the empty string as end regexp so it doesn't default to
       ;; "\\s)".  This way parens at end of defun are properly hidden.
       ""
       "#"
       python-hideshow-forward-sexp-function
       nil
       python-nav-beginning-of-block
       python-hideshow-find-next-block
       python-info-looking-at-beginning-of-block)))

  (setq-local outline-regexp (python-rx (* space) block-start))
  (setq-local outline-level
              (lambda ()
                "`outline-level' function for Python mode."
                (1+ (/ (current-indentation) python-indent-offset))))

  (unless python--installed-grep-hook
    (setq python--installed-grep-hook t)
    (with-eval-after-load 'grep
      (defvar grep-files-aliases)
      (defvar grep-find-ignored-directories)
      (cl-pushnew '("py" . "*.py") grep-files-aliases :test #'equal)
      (dolist (dir '(".mypy_cache" ".pytest_cache" ".ropeproject"
                     ".ruff_cache" ".tox" ".venv"))
        (cl-pushnew dir grep-find-ignored-directories))))

  (setq-local prettify-symbols-alist python-prettify-symbols-alist)

  (make-local-variable 'python-shell-internal-buffer)

  (add-hook 'flymake-diagnostic-functions #'python-flymake nil t))

;;;###autoload
(define-derived-mode python-mode python-base-mode "Python"
  "Major mode for editing Python files.

\\{python-mode-map}"
  (setq-local font-lock-defaults
              `(,python-font-lock-keywords
                nil nil nil nil
                (font-lock-syntactic-face-function
                 . python-font-lock-syntactic-face-function)))
  (setq-local syntax-propertize-function
              python-syntax-propertize-function)
  (setq-local imenu-create-index-function
              #'python-imenu-create-index)

  (add-hook 'which-func-functions #'python-info-current-defun nil t)

  (python-skeleton-add-menu-items)

  (when python-indent-guess-indent-offset
    (python-indent-guess-indent-offset)))

;;;###autoload
(define-derived-mode python-ts-mode python-base-mode "Python"
  "Major mode for editing Python files, using tree-sitter library.

\\{python-ts-mode-map}"
  :syntax-table python-mode-syntax-table
  (when (if (fboundp 'treesit-ensure-installed) ; Emacs 31
            (treesit-ensure-installed 'python)
          (treesit-ready-p 'python))
    (setq treesit-primary-parser (treesit-parser-create 'python))
    (setq-local treesit-font-lock-feature-list
                '(( comment definition)
                  ( keyword string type)
                  ( assignment builtin constant decorator
                    escape-sequence number string-interpolation )
                  ( bracket delimiter function operator variable property)))
    (setq-local treesit-font-lock-settings python--treesit-settings)
    (setq-local imenu-create-index-function
                #'python-imenu-treesit-create-index)
    (setq-local treesit-defun-name-function
                #'python--treesit-defun-name)

    (setq-local treesit-thing-settings python--thing-settings)
    (treesit-major-mode-setup)
    ;; Enable the `sexp' navigation by default
    (setq-local forward-sexp-function #'treesit-forward-sexp
                treesit-sexp-thing 'sexp)

    (setq-local syntax-propertize-function #'python--treesit-syntax-propertize)

    (python-skeleton-add-menu-items)

    (when python-indent-guess-indent-offset
      (python-indent-guess-indent-offset))

    (add-to-list 'auto-mode-alist (cons python--auto-mode-alist-regexp 'python-ts-mode))
    (add-to-list 'interpreter-mode-alist '("python[0-9.]*" . python-ts-mode))))

(when (fboundp 'derived-mode-add-parents) ; Emacs 30.1
  (derived-mode-add-parents 'python-ts-mode '(python-mode)))

;;; Completion predicates for M-x
;; Commands that only make sense when editing Python code.
(dolist (sym '(python-add-import
               python-check
               python-fill-paragraph
               python-fix-imports
               python-indent-dedent-line
               python-indent-dedent-line-backspace
               python-indent-guess-indent-offset
               python-indent-shift-left
               python-indent-shift-right
               python-mark-defun
               python-nav-backward-block
               python-nav-backward-defun
               python-nav-backward-sexp
               python-nav-backward-sexp-safe
               python-nav-backward-statement
               python-nav-backward-up-list
               python-nav-beginning-of-block
               python-nav-beginning-of-statement
               python-nav-end-of-block
               python-nav-end-of-defun
               python-nav-end-of-statement
               python-nav-forward-block
               python-nav-forward-defun
               python-nav-forward-sexp
               python-nav-forward-sexp-safe
               python-nav-forward-statement
               python-nav-if-name-main
               python-nav-up-list
               python-remove-import
               python-shell-send-block
               python-shell-send-buffer
               python-shell-send-defun
               python-shell-send-statement
               python-sort-imports))
  (function-put sym 'command-modes '(python-base-mode)))

;; Commands that only make sense in the Python shell or when editing
;; Python code.
(dolist (sym '(python-describe-at-point
               python-eldoc-at-point
               python-shell-completion-native-toggle
               python-shell-completion-native-turn-off
               python-shell-completion-native-turn-on
               python-shell-completion-native-turn-on-maybe
               python-shell-font-lock-cleanup-buffer
               python-shell-font-lock-toggle
               python-shell-font-lock-turn-off
               python-shell-font-lock-turn-on
               python-shell-package-enable
               python-shell-completion-complete-or-indent))
  (function-put sym 'command-modes '(python-base-mode inferior-python-mode)))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("/\\(?:Pipfile\\|\\.?flake8\\)\\'" . conf-mode))

(provide 'python)

;;; python.el ends here
