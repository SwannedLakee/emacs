;;; eieio.el --- Enhanced Implementation of Emacs Interpreted Objects  -*- lexical-binding:t -*-
;;;              or maybe Eric's Implementation of Emacs Interpreted Objects

;; Copyright (C) 1995-2025 Free Software Foundation, Inc.

;; Author: Eric M. Ludlam <zappo@gnu.org>
;; Old-Version: 1.4
;; Keywords: OO, lisp

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
;; EIEIO is a series of Lisp routines which implements a subset of
;; CLOS, the Common Lisp Object System.  In addition, EIEIO also adds
;; a few new features which help it integrate more strongly with the
;; Emacs running environment.
;;
;; See eieio.texi for complete documentation on using this package.
;;
;; Note: the implementation of the c3 algorithm is based on:
;;   Kim Barrett et al.: A Monotonic Superclass Linearization for Dylan
;;   Retrieved from:
;;   http://192.220.96.201/dylan/linearization-oopsla96.html

;; @TODO - fix :initform to be a form, not a quoted value
;; @TODO - Prefix non-clos functions with `eieio-'.

;; TODO: better integrate CL's defstructs and classes.  E.g. make it possible
;; to create a new class that inherits from a struct.

;;; Code:

(require 'eieio-core)
(eval-when-compile (require 'subr-x))


;;; Defining a new class
;;
;;;###autoload
(defmacro defclass (name superclasses slots &rest options-and-doc)
  "Define NAME as a new class derived from SUPERCLASS with SLOTS.
OPTIONS-AND-DOC is used as the class' options and base documentation.
SUPERCLASSES is a list of superclasses to inherit from, with SLOTS
being the slots residing in that class definition.  Supported tags are:

  :initform   - Initializing form.
  :initarg    - Tag used during initialization.
  :accessor   - Tag used to create a function to access this slot.
  :allocation - Specify where the value is stored.
                Defaults to `:instance', but could also be `:class'.
  :writer     - A function symbol which will `write' an object's slot.
  :reader     - A function symbol which will `read' an object.
  :type       - The type of data allowed in this slot (see `typep').
  :documentation
              - A string documenting use of this slot.

The following are extensions on CLOS:
  :custom     - When customizing an object, the custom :type.  Public only.
  :label      - A text string label used for a slot when customizing.
  :group      - Name of a customization group this slot belongs in.
  :printer    - A function to call to print the value of a slot.
                See `eieio-override-prin1' as an example.

A class can also have optional options.  These options happen in place
of documentation (including a :documentation tag), in addition to
documentation, or not at all.  Supported options are:

  :documentation - The doc-string used for this class.

Options added to EIEIO:

  :allow-nil-initform - Non-nil to skip typechecking of null initforms.
  :custom-groups      - List of custom group names.  Organizes slots into
                        reasonable groups for customizations.
  :abstract           - Non-nil to prevent instances of this class.
                        If a string, use as an error string if someone does
                        try to make an instance.
  :method-invocation-order
                      - Control the method invocation order if there is
                        multiple inheritance.  Valid values are:
                         :breadth-first - The default.
                         :depth-first

Options in CLOS not supported in EIEIO:

  :metaclass - Class to use in place of `standard-class'
  :default-initargs - Initargs to use when initializing new objects of
                      this class.

Due to the way class options are set up, you can add any tags you wish,
and reference them using the function `class-option'."
  (declare (doc-string 4) (indent defun))
  (cl-check-type superclasses list)

  (cond ((and (stringp (car options-and-doc))
              (evenp (length options-and-doc)))
         (error "Too many arguments to `defclass'"))
        ((and (symbolp (car options-and-doc))
              (oddp (length options-and-doc)))
         (error "Too many arguments to `defclass'")))

  (if (stringp (car options-and-doc))
      (setq options-and-doc
            (cons :documentation options-and-doc)))

  ;; Make sure the method invocation order is a valid value.
  (let ((io (eieio--class-option-assoc options-and-doc
                                       :method-invocation-order)))
    (when (and io (not (member io '(:depth-first :breadth-first :c3))))
      (error "Method invocation order %s is not allowed" io)))

  (let ((testsym1 (intern (concat (symbol-name name) "-p")))
        (testsym2 (intern (format "%s--eieio-childp" name)))
        (warnings '())
        (accessors ()))

    ;; Collect the accessors we need to define.
    (setq slots (mapcar (lambda (x) (if (consp x) x (list x))) slots))
    (pcase-dolist (`(,sname . ,soptions) slots)
      (let* ((acces   (plist-get soptions :accessor))
	     (initarg (plist-get soptions :initarg))
	     (reader  (plist-get soptions :reader))
	     (writer  (plist-get soptions :writer))
	     (alloc   (plist-get soptions :allocation))
	     (label   (plist-get soptions :label)))

        ;; Update eieio--known-slot-names already in case we compile code which
        ;; uses this before the class is loaded.
        (cl-pushnew sname eieio--known-slot-names)
        (when (eq alloc :class)
          (cl-pushnew sname eieio--known-class-slot-names))

	(if eieio-error-unsupported-class-tags
	    (let ((tmp soptions))
	      (while tmp
		(if (not (member (car tmp) '(:accessor
					     :initform
					     :initarg
					     :documentation
					     :protection
					     :reader
					     :writer
					     :allocation
					     :type
					     :custom
					     :label
					     :group
					     :printer
					     :allow-nil-initform
					     :custom-groups)))
		    (signal 'invalid-slot-type (list (car tmp))))
		(setq tmp (cdr (cdr tmp))))))

	;; Make sure the :allocation parameter has a valid value.
	(if (not (memq alloc '(nil :class :instance)))
	    (signal 'invalid-slot-type (list :allocation alloc)))

	;; Label is nil, or a string
	(if (not (or (null label) (stringp label)))
	    (signal 'invalid-slot-type (list :label label)))

	;; Is there an initarg, but allocation of class?
	(when (and initarg (eq alloc :class))
	  (push
           (cons sname
                 (format-message
                  "Meaningless :initarg for class allocated slot `%S'"
	          sname))
	   warnings))

        (let ((init (plist-get soptions :initform)))
          (unless (or (macroexp-const-p init)
                      (eieio--eval-default-p init))
            ;; FIXME: Historically, EIEIO used a heuristic to try and guess
            ;; whether the initform is a form to be evaluated or just
            ;; a constant.  We use `eieio--eval-default-p' to see what the
            ;; heuristic says and if it disagrees with normal evaluation
            ;; then tweak the initform to make it fit and emit
            ;; a warning accordingly.
            (push
             (cons init (format "Ambiguous initform needs quoting: %S" init))
             warnings)))

	;; Anyone can have an accessor function.  This creates a function
	;; of the specified name, and also performs a `defsetf' if applicable
	;; so that users can `setf' the space returned by this function.
	(when acces
          (push `(cl-defmethod (setf ,acces) (value (this ,name))
                   (eieio-oset this ',sname value))
                accessors)
          (push `(cl-defmethod ,acces ((this ,name))
                   ,(internal--format-docstring-line
                     "Retrieve the slot `%S' from an object of class `%S'."
                     sname name)
                   (slot-value this ',sname))
                  accessors)
          (when (and eieio-backward-compatibility (eq alloc :class))
            ;; FIXME: How could I declare this *method* as obsolete.
            (push `(cl-defmethod ,acces ((this (subclass ,name)))
                     ,(concat
                       (internal--format-docstring-line
                        "Retrieve the class slot `%S' from a class `%S'."
                        sname name)
                       "\nThis method is obsolete.")
                     (when (eq eieio-backward-compatibility 'warn)
                       (message "Use of obsolete method %S on %S"
                                ',acces '(subclass ,name)))
                     (if (slot-boundp this ',sname)
                         (eieio-oref-default this ',sname)))
                  accessors)))

	;; If a writer is defined, then create a generic method of that
	;; name whose purpose is to set the value of the slot.
	(if writer
            (push `(cl-defmethod ,writer ((this ,name) value)
                     ,(internal--format-docstring-line
                       "Set the slot `%S' of an object of class `%S'."
                       sname name)
                     (setf (slot-value this ',sname) value))
                  accessors))
	;; If a reader is defined, then create a generic method
	;; of that name whose purpose is to access this slot value.
	(if reader
            (push `(cl-defmethod ,reader ((this ,name))
                     ,(internal--format-docstring-line
                       "Access the slot `%S' from object of class `%S'."
                       sname name)
                     (slot-value this ',sname))
                  accessors))
	))

    `(progn
       ,@(mapcar (lambda (w)
                   (macroexp-warn-and-return
                    (cdr w) `(progn ',(cdr w)) nil 'compile-only (car w)))
                 warnings)
       ;; This test must be created right away so we can have self-
       ;; referencing classes.  ei, a class whose slot can contain only
       ;; pointers to itself.

       ;; Create the test functions.
       (defalias ',testsym1 (eieio-make-class-predicate ',name))
       (defalias ',testsym2 (eieio-make-child-predicate ',name))

       ,@(when eieio-backward-compatibility
           (let ((f (intern (format "%s-child-p" name))))
             `((defalias ',f #',testsym2)
               (make-obsolete
                ',f ,(format "use (cl-typep ... '%s) instead" name)
                "25.1"))))

       ;; When using typep, (typep OBJ 'myclass) returns t for objects which
       ;; are subclasses of myclass.  For our predicates, however, it is
       ;; important for EIEIO to be backwards compatible, where
       ;; myobject-p, and myobject-child-p are different.
       ;; "cl" uses this technique to specify symbols with specific typep
       ;; test, so we can let typep have the CLOS documented behavior
       ;; while keeping our above predicate clean.

       (eval-and-compile
         (define-symbol-prop ',name 'cl-deftype-satisfies #',testsym2))

       (eieio-defclass-internal ',name ',superclasses ',slots ',options-and-doc)

       ,@accessors

       ;; Create the constructor function
       ,(if (eieio--class-option-assoc options-and-doc :abstract)
            ;; Abstract classes cannot be instantiated.  Say so.
            (let ((abs (eieio--class-option-assoc options-and-doc :abstract)))
              (if (not (stringp abs))
                  (setq abs (format "Class %s is abstract" name)))
              `(defun ,name (&rest _)
                 ,(format "You cannot create a new object of type `%S'." name)
                 (error ,abs)))

          ;; Non-abstract classes need a constructor.
          `(defun ,name (&rest slots)
             ,(internal--format-docstring-line
               "Create a new object of class type `%S'." name)
             (declare (compiler-macro eieio--constructor-macro))
             (apply #'make-instance ',name slots))))))

(defun eieio--constructor-macro (whole &rest slots)
  ;; When `eieio-backward-compatibility' is removed, we should
  ;; remove this compiler-macro, until then, it's best to emit a compile-time
  ;; warning even if `eieio-backward-compatibility' is nil, I think.
  (if (or (null slots) (keywordp (car slots))
          ;; Detect the second pass!
          (eq 'identity (car-safe (car slots))))
      whole
    (macroexp-warn-and-return
     (format "Obsolete name argument %S to constructor %S"
             (car slots) (car whole))
     ;; Keep the name arg, for backward compatibility,
     ;; but hide it so we don't trigger indefinitely.
     `(,(car whole) (identity ,(car slots))
       ,@(cdr slots))
     '(obsolete eieio-constructor-name-arg) nil (car slots))))

;;; Get/Set slots in an object.
;;
(defmacro oref (obj slot)
  "Retrieve the value stored in OBJ in the slot named by SLOT."
  (declare (debug (form symbolp)))
  `(eieio-oref ,obj (quote ,slot)))

(defalias 'slot-value #'eieio-oref)
(defalias 'set-slot-value #'eieio-oset)
(make-obsolete 'set-slot-value "use (setf (slot-value ..) ..) instead" "25.1")

(defmacro oref-default (class slot)
  "Get the value of class allocated slot SLOT.
CLASS can also be an object, in which case we use the object's class."
  (declare (debug (form symbolp)))
  `(eieio-oref-default ,class (quote ,slot)))

;;; Handy CLOS macros
;;
(defmacro with-slots (spec-list object &rest body)
  "Bind SPEC-LIST lexically to slot values in OBJECT, and execute BODY.
This establishes a lexical environment for referring to the slots in
the instance named by the given slot-names as though they were
variables.  Within such a context the value of the slot can be
specified by using its slot name, as if it were a lexically bound
variable.  Both setf and setq can be used to set the value of the
slot.

SPEC-LIST is of a form similar to `let'.  For example:

  ((VAR1 SLOT1)
    SLOT2
    SLOTN
   (VARN+1 SLOTN+1))

Where each VAR is the local variable given to the associated
SLOT.  A slot specified without a variable name is given a
variable name of the same name as the slot."
  (declare (indent 2) (debug (sexp sexp def-body)))
  (require 'cl-lib)
  ;; Transform the spec-list into a cl-symbol-macrolet spec-list.
  (macroexp-let2 nil object object
    `(cl-symbol-macrolet
         ,(mapcar (lambda (entry)
                    (let ((var  (if (listp entry) (car entry) entry))
                          (slot (if (listp entry) (cadr entry) entry)))
                      (list var `(slot-value ,object ',slot))))
                  spec-list)
       ,@body)))

;; Keep it as a non-inlined function, so the internals of object don't get
;; hard-coded in random .elc files.
(defun eieio-pcase-slot-index-table (obj)
  "Return some data structure from which can be extracted the slot offset."
  (eieio--class-index-table (eieio--object-class obj)))

(defun eieio-pcase-slot-index-from-index-table (index-table slot)
  "Find the index to pass to `aref' to access SLOT."
  (gethash slot index-table))

(pcase-defmacro eieio (&rest fields)
  "Pcase patterns that match EIEIO object EXPVAL.
Elements of FIELDS can be of the form (NAME PAT) in which case the
contents of field NAME is matched against PAT, or they can be of
 the form NAME which is a shorthand for (NAME NAME)."
  (declare (debug (&rest [&or (sexp pcase-PAT) sexp])))
  ;; FIXME: This generates a horrendous mess of redundant let bindings.
  ;; `pcase' needs to be improved somehow to introduce let-bindings more
  ;; sparingly, or the byte-compiler needs to be taught to optimize
  ;; them away.
  ;; FIXME: `pcase' does not do a good job here of sharing tests&code among
  ;; various branches.
  `(and (pred eieio-object-p)
        ,@(mapcar (lambda (field)
                    (pcase-exhaustive field
                      (`(,name ,pat)
                       `(app (eieio-oref _ ',name) ,pat))
                      ((pred symbolp)
                       `(app (eieio-oref _ ',field) ,field))))
                  fields)))

;;; Simple generators, and query functions.  None of these would do
;;  well embedded into an object.
;;

(define-obsolete-function-alias
  'object-class-fast #'eieio-object-class "24.4")

;; In the past, every EIEIO object had a `name' field, so we had the
;; two methods `eieio-object-name-string' and
;; `eieio-object-set-name-string' "for free".  Since this field is
;; very rarely used, we got rid of it and instead we keep it in a weak
;; hash-tables, for those very rare objects that use it.
;; Really, those rare objects should inherit from `eieio-named' instead!
(defconst eieio--object-names (make-hash-table :test #'eq :weakness 'key))

(cl-defgeneric eieio-object-name-string (obj)
  "Return a string which is OBJ's name."
  (or (gethash obj eieio--object-names)
      (format "%x" (sxhash-eq obj))))

(define-obsolete-function-alias
  'object-name-string #'eieio-object-name-string "24.4")

(defun eieio-object-name (obj &optional extra)
  "Return a printed representation for object OBJ.
If EXTRA, include that in the string returned to represent the symbol."
  (cl-check-type obj eieio-object)
  (format "#<%s %s%s>" (eieio-object-class obj)
	  (eieio-object-name-string obj)
          (cond
           ((null extra)
            "")
           ((listp extra)
            (concat " " (mapconcat #'identity extra " ")))
           (t
            extra))))
(define-obsolete-function-alias 'object-name #'eieio-object-name "24.4")

(defun eieio-object-class (obj)
  "Return the class struct defining OBJ."
  ;; FIXME: We say we return a "struct" but we return a symbol instead!
  (cl-check-type obj eieio-object)
  (eieio--class-name (eieio--object-class obj)))
(define-obsolete-function-alias 'object-class #'eieio-object-class "24.4")
;; CLOS name, maybe?
(define-obsolete-function-alias 'class-of #'eieio-object-class "24.4")

(defun eieio-object-class-name (obj)
  "Return a Lisp like symbol name for OBJ's class."
  (cl-check-type obj eieio-object)
  (eieio-class-name (eieio--object-class obj)))
(define-obsolete-function-alias
  'object-class-name #'eieio-object-class-name "24.4")

(defun eieio-class-parents (class)
  ;; FIXME: What does "(overload of variable)" mean here?
  "Return parent classes to CLASS.  (overload of variable)."
  ;; (declare (obsolete cl--class-parents "30.1"))
  (let ((parents (eieio--class-parents (eieio--full-class-object class))))
    (if (and (null (cdr parents))
             (eq (car parents) (cl--find-class 'eieio-default-superclass)))
        nil
      parents)))

(define-obsolete-function-alias 'class-parents #'eieio-class-parents "24.4")

(defun eieio-class-children (class)
  "Return child classes to CLASS."
  (cl-check-type class class)
  (eieio--class-children (cl--find-class class)))
(define-obsolete-function-alias
  'class-children #'eieio-class-children "24.4")

;; Official CLOS functions.
(define-obsolete-function-alias
  'class-direct-superclasses #'eieio-class-parents "24.4")
(define-obsolete-function-alias
  'class-direct-subclasses #'eieio-class-children "24.4")

(defmacro eieio-class-parent (class)
  "Return first parent class to CLASS.  (overload of variable)."
  `(car (eieio-class-parents ,class)))
(define-obsolete-function-alias 'class-parent #'eieio-class-parent "24.4")

(defun same-class-p (obj class)
  "Return t if OBJ is of class-type CLASS."
  (setq class (eieio--class-object class))
  (cl-check-type class eieio--class)
  (cl-check-type obj eieio-object)
  (eq (eieio--object-class obj) class))

(defun object-of-class-p (obj class)
  "Return non-nil if OBJ is an instance of CLASS or CLASS' subclasses."
  (cl-check-type obj eieio-object)
  ;; class will be checked one layer down
  (child-of-class-p (eieio--object-class obj) class))
;; Backwards compatibility
(defalias 'obj-of-class-p #'object-of-class-p)

(defun child-of-class-p (child class)
  "Return non-nil if CHILD class is a subclass of CLASS."
  (setq child (eieio--full-class-object child))
  (cl-check-type child eieio--class)
  ;; `eieio-default-superclass' is never mentioned in eieio--class-parents,
  ;; so we have to special case it here.
  (or (eq class 'eieio-default-superclass)
      (let ((p nil))
        (setq class (eieio--class-object class))
        (cl-check-type class eieio--class)
        (while (and child (not (eq child class)))
          (setq p (append p (cl--class-parents child))
                child (pop p)))
        (if child t))))

(defun eieio-slot-descriptor-name (slot)
  (cl--slot-descriptor-name slot))

(defun eieio-class-slots (class)
  "Return list of slots available in instances of CLASS."
  ;; FIXME: This only gives the instance slots and ignores the
  ;; class-allocated slots.
  (setq class (eieio--class-object class))
  (cl-check-type class eieio--class)
  (mapcar #'identity (eieio--class-slots class)))

(defun object-slots (obj)
  "Return list of slot names available in OBJ."
  (declare (obsolete eieio-class-slots "25.1"))
  (cl-check-type obj eieio-object)
  (mapcar #'cl--slot-descriptor-name
	  (eieio-class-slots (eieio--object-class obj))))

(defun eieio--class-slot-initarg (class slot)
  "Fetch from CLASS, SLOT's :initarg."
  (cl-check-type class eieio--class)
  (let ((ia (eieio--class-initarg-tuples class))
	(f nil))
    (while (and ia (not f))
      (if (eq (cdr (car ia)) slot)
	  (setq f (car (car ia))))
      (setq ia (cdr ia)))
    f))

;;; Object Set macros
;;
(defmacro oset (obj slot value)
  "Set the value in OBJ for slot SLOT to VALUE.
SLOT is the slot name as specified in `defclass' or the tag created
with in the :initarg slot.  VALUE can be any Lisp object."
  (declare (debug (form symbolp form)))
  `(eieio-oset ,obj (quote ,slot) ,value))

(defmacro oset-default (class slot value)
  "Set the default slot in CLASS for SLOT to VALUE.
The default value is usually set with the :initform tag during class
creation.  This allows users to change the default behavior of classes
after they are created."
  (declare (debug (form symbolp form)))
  `(eieio-oset-default ,class (quote ,slot) ,value))

;;; CLOS queries into classes and slots
;;
(defun slot-boundp (object slot)
  "Return non-nil if OBJECT's SLOT is bound.
Setting a slot's value makes it bound.  Calling `slot-makeunbound' will
make a slot unbound.
OBJECT can be an instance or a class."
  (declare (compiler-macro eieio--check-slot-name))
  ;; Skip typechecking while retrieving this value.
  (let ((eieio-skip-typecheck t))
    ;; Return nil if the magic symbol is in there.
    (not (eq (cond
	      ((eieio-object-p object) (eieio-oref object slot))
	      ((symbolp object)        (eieio-oref-default object slot))
	      (t (signal 'wrong-type-argument (list 'eieio-object-p object))))
	     eieio--unbound))))

(defun slot-makeunbound (object slot)
  "In OBJECT, make SLOT unbound."
  (eieio-oset object slot eieio--unbound))

(defun slot-exists-p (object-or-class slot)
  "Return non-nil if OBJECT-OR-CLASS has SLOT."
  (let ((cv (cond ((eieio-object-p object-or-class)
                   (eieio--object-class object-or-class))
                  ((eieio--class-p object-or-class) object-or-class)
                  (t (find-class object-or-class 'error)))))
    (or (gethash slot (eieio--class-index-table cv))
        ;; FIXME: We could speed this up by adding class slots into the
        ;; index-table (e.g. with a negative index?).
	(let ((cs (eieio--class-class-slots cv))
	      found)
	  (dotimes (i (length cs))
	    (if (eq slot (cl--slot-descriptor-name (aref cs i)))
		(setq found t)))
	  found))))

(defun find-class (symbol &optional errorp)
  "Return the class that SYMBOL represents.
If there is no class, nil is returned if ERRORP is nil.
If ERRORP is non-nil, `wrong-argument-type' is signaled."
  (let ((class (cl--find-class symbol)))
    (cond
     ((eieio--class-p class) class)
     (errorp (signal 'wrong-type-argument (list 'class-p symbol))))))

;;; Slightly more complex utility functions for objects
;;
(defun object-assoc (key slot list)
  "Return an object if KEY is `equal' to SLOT's value of an object in LIST.
LIST is a list of objects whose slots are searched.
Objects in LIST do not need to have a slot named SLOT, nor does
SLOT need to be bound.  If these errors occur, those objects will
be ignored."
  (cl-check-type list list)
  (while (and list (not (condition-case nil
			    ;; This prevents errors for missing slots.
			    (equal key (eieio-oref (car list) slot))
			  (error nil))))
    (setq list (cdr list)))
  (car list))

(defun object-assoc-list (slot list)
  "Return an association list with the contents of SLOT as the key element.
LIST must be a list of objects with SLOT in it.
This is useful when you need to do completing read on an object group."
  (cl-check-type list list)
  (let ((assoclist nil))
    (while list
      (setq assoclist (cons (cons (eieio-oref (car list) slot)
				  (car list))
			    assoclist))
      (setq list (cdr list)))
    (nreverse assoclist)))

(defun object-assoc-list-safe (slot list)
  "Return an association list with the contents of SLOT as the key element.
LIST must be a list of objects, but those objects do not need to have
SLOT in it.  If it does not, then that element is left out of the association
list."
  (cl-check-type list list)
  (let ((assoclist nil))
    (while list
      (if (slot-exists-p (car list) slot)
	  (setq assoclist (cons (cons (eieio-oref (car list) slot)
				      (car list))
				assoclist)))
      (setq list (cdr list)))
    (nreverse assoclist)))

(defun object-add-to-list (object slot item &optional append)
  "In OBJECT's SLOT, add ITEM to the list of elements.
Optional argument APPEND indicates we need to append to the list.
If ITEM already exists in the list in SLOT, then it is not added.
Comparison is done with `equal' through the `member' function call.
If SLOT is unbound, bind it to the list containing ITEM."
  (let (ov)
    ;; Find the originating list.
    (if (not (slot-boundp object slot))
	(setq ov (list item))
      (setq ov (eieio-oref object slot))
      ;; turn it into a list.
      (setq ov (ensure-list ov))
      ;; Do the combination
      (if (not (member item ov))
	  (setq ov
		(if append
		    (append ov (list item))
		  (cons item ov)))))
    ;; Set back into the slot.
    (eieio-oset object slot ov)))

(defun object-remove-from-list (object slot item)
  "In OBJECT's SLOT, remove occurrences of ITEM.
Deletion is done with `delete', which deletes by side effect,
and comparisons are done with `equal'.
If SLOT is unbound, do nothing."
  (if (not (slot-boundp object slot))
      nil
    (eieio-oset object slot (delete item (eieio-oref object slot)))))


;;;
;; We want all objects created by EIEIO to have some default set of
;; behaviors so we can create object utilities, and allow various
;; types of error checking.  To do this, create the default EIEIO
;; class, and when no parent class is specified, use this as the
;; default.  (But don't store it in the other classes as the default,
;; allowing for transparent support.)
;;

(defclass eieio-default-superclass nil
  nil
  "Default parent class for classes with no specified parent class.
Its slots are automatically adopted by classes with no specified parents."
  :abstract t)

(setq eieio-default-superclass (cl--find-class 'eieio-default-superclass))

(define-obsolete-function-alias 'standard-class
  #'eieio-default-superclass "26.1")

;;;###autoload
(cl-defgeneric make-instance (class &rest initargs)
  "Make a new instance of CLASS based on INITARGS.
For example:

  (make-instance \\='foo)

INITARGS is a property list with keywords based on the `:initarg'
for each slot.  For example:

  (make-instance \\='foo :slot1 value1 :slotN valueN)")

(put 'make-instance 'compiler-macro
     ;; When `eieio-backward-compatibility' is removed, we should
     ;; remove this compiler-macro, until then, it's best to emit a compile-time
     ;; warning even if `eieio-backward-compatibility' is nil, I think.
     (lambda (whole class &rest slots)
       (if (or (null slots) (keywordp (car slots))
               ;; Detect the second pass!
               (eq 'identity (car-safe (car slots))))
           whole
         (macroexp-warn-and-return
          (format "Obsolete name arg %S to `make-instance'" (car slots))
          ;; Keep the name arg, for backward compatibility,
          ;; but hide it so we don't trigger indefinitely.
          `(,(car whole) ,class (identity ,(car slots))
            ,@(cdr slots))
          '(obsolete eieio-constructor-name-arg) nil (car slots)))))

(define-obsolete-function-alias 'constructor #'make-instance "25.1")

(cl-defmethod make-instance
    ((class (subclass eieio-default-superclass)) &rest slots)
  "Default constructor for CLASS `eieio-default-superclass'.
SLOTS are the initialization slots used by `initialize-instance'.
This static method is called when an object is constructed.
It allocates the vector used to represent an EIEIO object, and then
calls `initialize-instance' on that object."
  (let* ((new-object (copy-sequence (eieio--class-default-object-cache
                                     (eieio--class-object class)))))
    (when (and eieio-backward-compatibility slots
               (let ((x (car slots)))
                 (or (stringp x) (null x))))
      (let ((name (pop slots)))
        (when (eq eieio-backward-compatibility 'warn)
          (message "Obsolete name argument %S passed to %S constructor"
                   name class))))
    ;; Call the initialize method on the new object with the slots
    ;; that were passed down to us.
    (initialize-instance new-object slots)
    (when eieio-backward-compatibility
      ;; Use symbol as type descriptor, for backwards compatibility.
      (aset new-object 0 class))
    ;; Return the created object.
    new-object))

;; FIXME: CLOS uses "&rest INITARGS" instead.
(cl-defgeneric shared-initialize (obj slots)
  "Set slots of OBJ with SLOTS which is a list of name/value pairs.
Called from the constructor routine.")

(cl-defmethod shared-initialize ((obj eieio-default-superclass) slots)
  "Set slots of OBJ with SLOTS which is a list of name/value pairs.
Called from the constructor routine."
  (while slots
    (let ((rn (eieio--initarg-to-attribute (eieio--object-class obj)
                                           (car slots))))
      (if (not rn)
          (slot-missing obj (car slots) 'oset (car (cdr slots)))
        (eieio-oset obj rn (car (cdr slots)))))
    (setq slots (cdr (cdr slots)))))

;; FIXME: CLOS uses "&rest INITARGS" instead.
(cl-defgeneric initialize-instance (this &optional slots)
  "Construct the new object THIS based on SLOTS.")

(cl-defmethod initialize-instance ((this eieio-default-superclass)
				   &optional args)
  "Construct the new object THIS based on ARGS.
ARGS is a property list where odd numbered elements are tags, and
even numbered elements are the values to store in the tagged slot.
If you overload the `initialize-instance', there you will need to
call `shared-initialize' yourself, or you can call `call-next-method'
to have this constructor called automatically.  If these steps are
not taken, then new objects of your class will not have their values
dynamically set from ARGS."
  (let* ((this-class (eieio--object-class this))
         (initargs args)
         (slots (eieio--class-slots this-class)))
    (dotimes (i (length slots))
      ;; For each slot, see if we need to evaluate its initform.
      (let* ((slot (aref slots i))
             (slot-name (eieio-slot-descriptor-name slot))
             (initform (cl--slot-descriptor-initform slot)))
        (unless (or (when-let* ((initarg
                                 (car (rassq slot-name
                                             (eieio--class-initarg-tuples
                                              this-class)))))
                      (plist-get initargs initarg))
                    ;; Those slots whose initform is constant already have
                    ;; the right value set in the default-object.
                    (macroexp-const-p initform))
          ;; FIXME: Use `aset' instead of `eieio-oset', relying on that
          ;; vector returned by `eieio--class-slots'
          ;; should be congruent with the object itself.
          (eieio-oset this slot-name (eval initform t))))))
  ;; Shared initialize will parse our args for us.
  (shared-initialize this args))

(cl-defgeneric slot-missing (object slot-name _operation &optional _new-value)
  "Method invoked when an attempt to access a slot in OBJECT fails.
SLOT-NAME is the name of the failed slot, OPERATION is the type of access
that was requested, and optional NEW-VALUE is the value that was desired
to be set.

This method is called from `oref', `oset', and other functions which
directly reference slots in EIEIO objects."
  (signal 'invalid-slot-name
          (list (if (eieio-object-p object) (eieio-object-name object) object)
                slot-name)))

(cl-defgeneric slot-unbound (object class slot-name fn)
  "Slot unbound is invoked during an attempt to reference an unbound slot.")

(cl-defmethod slot-unbound ((object eieio-default-superclass)
			 class slot-name fn)
  "Slot unbound is invoked during an attempt to reference an unbound slot.
OBJECT is the instance of the object being reference.  CLASS is the
class of OBJECT, and SLOT-NAME is the offending slot.  This function
throws the signal `unbound-slot'.  You can overload this function and
return the value to use in place of the unbound value.
Argument FN is the function signaling this error.
Use `slot-boundp' to determine if a slot is bound or not.

In CLOS, the argument list is (CLASS OBJECT SLOT-NAME), but
EIEIO can only dispatch on the first argument, so the first two are swapped."
  (signal 'unbound-slot (list (eieio-class-name class)
                              (eieio-object-name object)
			      slot-name fn)))

(cl-defgeneric clone (obj &rest params)
  "Make a copy of OBJ, and then supply PARAMS.
PARAMS is a parameter list of the same form used by `initialize-instance'.

When overloading `clone', be sure to call `call-next-method'
first and modify the returned object.")

(cl-defmethod clone ((obj eieio-default-superclass) &rest params)
  "Make a copy of OBJ, and then apply PARAMS."
  (let ((nobj (copy-sequence obj)))
    (when (and eieio-backward-compatibility params
               (let ((x (car params)))
                 (or (stringp x) (null x))))
     (let ((name (pop params)))
       (when (eq eieio-backward-compatibility 'warn)
         (message "Obsolete name argument %S passed to clone" name))))
    (if params (shared-initialize nobj params))
    nobj))

(cl-defgeneric destructor (_this &rest _params)
  "Destructor for cleaning up any dynamic links to our object."
  (declare (obsolete nil "26.1"))
  ;; No cleanup... yet.
  nil)

(cl-defgeneric object-print (this &rest _strings)
  "Pretty printer for object THIS.

It is sometimes useful to put a summary of the object into the
default #<notation> string when using EIEIO browsing tools.
Implement this method to customize the summary."
  (declare (obsolete cl-print-object "26.1"))
  (format "%S" this))

(with-suppressed-warnings ((obsolete object-print))
  (cl-defmethod object-print ((this eieio-default-superclass) &rest strings)
    "Pretty printer for object THIS.  Call function `object-name' with STRINGS.
The default method for printing object THIS is to use the
function `object-name'.

It is sometimes useful to put a summary of the object into the
default #<notation> string when using EIEIO browsing tools.

Implement this function and specify STRINGS in a call to
`call-next-method' to provide additional summary information.
When passing in extra strings from child classes, always remember
to prepend a space."
    (eieio-object-name this (apply #'concat strings))))

(with-suppressed-warnings ((obsolete object-print))
  (cl-defmethod cl-print-object ((object eieio-default-superclass) stream)
    "Default printer for EIEIO objects."
    ;; Fallback to the old `object-print'.  There should be no
    ;; `object-print' methods in the Emacs tree, but there may be some
    ;; out-of-tree.
    (princ (object-print object) stream)))


(defvar eieio-print-depth 0
  "The current indentation depth while printing.
Ignored if `eieio-print-indentation' is nil.")

(defvar eieio-print-indentation t
  "When non-nil, indent contents of printed objects.")

(defvar eieio-print-object-name t
  "When non-nil write the object name in `object-write'.
Does not affect objects subclassing `eieio-named'.  Note that
Emacs<26 requires that object names be present.")

(cl-defgeneric object-write (this &optional comment)
  "Write out object THIS to the current stream.
Optional COMMENT will add comments to the beginning of the output.")

(cl-defmethod object-write ((this eieio-default-superclass) &optional comment)
  "Write object THIS out to the current stream.
This writes out the vector version of this object.  Complex and recursive
object are discouraged from being written.
  If optional COMMENT is non-nil, include comments when outputting
this object."
  (when (and comment eieio-print-object-name)
    (princ ";; Object ")
    (princ (eieio-object-name-string this))
    (princ "\n"))
  (when comment
    (princ comment)
    (princ "\n"))
  (let* ((cl (eieio-object-class this))
	 (cv (cl--find-class cl)))
    ;; Now output readable lisp to recreate this object
    ;; It should look like this:
    ;; (<constructor> <name> <slot> <slot> ... )
    ;; Each slot's slot is written using its :writer.
    (when eieio-print-indentation
      (princ (make-string (* eieio-print-depth 2) ? )))
    (princ "(")
    (princ (symbol-name (eieio--class-constructor (eieio-object-class this))))
    (when eieio-print-object-name
      (princ " ")
      (prin1 (eieio-object-name-string this))
      (princ "\n"))
    ;; Loop over all the public slots
    (let ((slots (eieio--class-slots cv))
	  (eieio-print-depth (1+ eieio-print-depth)))
      (dotimes (i (length slots))
        (let ((slot (aref slots i)))
          (when (slot-boundp this (cl--slot-descriptor-name slot))
            (let ((i (eieio--class-slot-initarg
                      cv (cl--slot-descriptor-name slot)))
                  (v (eieio-oref this (cl--slot-descriptor-name slot))))
              (unless (or (not i) (equal v (cl--slot-descriptor-initform slot)))
                (unless (bolp)
                  (princ "\n"))
                (when eieio-print-indentation
                  (princ (make-string (* eieio-print-depth 2) ? )))
                (princ (symbol-name i))
                (if (alist-get :printer (cl--slot-descriptor-props slot))
                    ;; Use our public printer
                    (progn
                      (princ " ")
                      (funcall (alist-get :printer
                                          (cl--slot-descriptor-props slot))
                               v))
                  ;; Use our generic override prin1 function.
                  (princ (if (or (eieio-object-p v)
                                 (eieio-object-p (car-safe v)))
                             "\n" " "))
                  (eieio-override-prin1 v))))))))
    (princ ")")
    (when (zerop eieio-print-depth)
      (princ "\n"))))

(defun eieio-override-prin1 (thing)
  "Perform a `prin1' on THING taking advantage of object knowledge."
  (cond ((eieio-object-p thing)
	 (object-write thing))
	((consp thing)
	 (eieio-list-prin1 thing))
	((hash-table-p thing)
         (let ((copy (copy-hash-table thing)))
	   (maphash
	    (lambda (key val)
	      (setf (gethash key copy)
		    (read
		     (with-output-to-string
		       (eieio-override-prin1 val)))))
	    copy)
	   (prin1 copy)))
	((vectorp thing)
         (let ((copy (copy-sequence thing)))
	  (dotimes (i (length copy))
	    (aset copy i
		  (read
		   (with-output-to-string
		     (eieio-override-prin1
		      (aref copy i))))))
	  (prin1 copy)))
	((eieio--class-p thing)
	 (princ (eieio--class-print-name thing)))
	(t (prin1 thing))))

(defun eieio-list-prin1 (list)
  "Display LIST where list may contain objects."
  (if (not (eieio-object-p (car list)))
      (progn
	(princ "'")
	(prin1 list))
    (when eieio-print-indentation
      (princ (make-string (* eieio-print-depth 2) ? )))
    (princ "(list")
    (let ((eieio-print-depth (1+ eieio-print-depth)))
      (while list
	(princ "\n")
	(if (eieio-object-p (car list))
	    (object-write (car list))
          (when eieio-print-indentation
	   (princ (make-string (* eieio-print-depth) ? )))
	  (eieio-override-prin1 (car list)))
	(setq list (cdr list))))
    (princ ")")))


;;; Unimplemented functions from CLOS
;;
(defun eieio-change-class (_obj _class)
  "Change the class of OBJ to type CLASS.
This may create or delete slots, but does not affect the return value
of `eq'."
  (error "EIEIO: `change-class' is unimplemented"))
(define-obsolete-function-alias 'change-class #'eieio-change-class "26.1")


;;; Obsolete
;;
(make-obsolete-variable 'eieio-version 'emacs-version "31.1")
(defvar eieio-version "1.4"
  "Current version of EIEIO.")

(defun eieio-version ()
  "Display the current version of EIEIO."
  (declare (obsolete emacs-version "31.1"))
  (interactive)
  (message eieio-version))

(provide 'eieio)

;;; eieio.el ends here
