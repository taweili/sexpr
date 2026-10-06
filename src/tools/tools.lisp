;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.tools — the tool registry.
;;;;
;;;; DESIGN (notes/sexpr.md §1.3): a tool is a plain Lisp function wearing
;;;; metadata. The registry maps lowercase name strings to tool-record
;;;; plists; the model-visible schema is derived from the lambda list.
;;;;
;;;; BOUNDARY: no transport type is named here. Tool schemas are plain sexpr
;;;; data; sexpr.provider:translate-tool-schemas owns the conversion to
;;;; the transport's tool-definition.

(in-package :sexpr.tools)

;;; --- registry ----------------------------------------------------------
;;;;
;;;; A tool-record is a plist:
;;;;   (:name        "my-read-file"                  ; lowercase string
;;;;    :symbol      #'my-read-file                  ; the function object
;;;;    :description "Read the file at PATH."        ; the docstring
;;;;    :schema      (:parameters (...) :required (...)) ; derived plist
;;;;    :capability  :fs-read)                      ; default :fs-read
;;;;
;;;; define-tool is the ONLY constructor for tool-records.

(defparameter *tool-registry* nil
  "The tool registry: an equal-test hash table keyed by lowercase tool-name
string, values are tool-record plists. NIL until first use; the table is
created lazily on first access (see TOOL-REGISTRY).")

(defun tool-registry ()
  "Return the registry hash table, creating it lazily on first use."
  (or *tool-registry*
      (setf *tool-registry* (make-hash-table :test #'equal))))

(defun reset-tool-registry! ()
  "Test-only: empty the registry. The table is dropped; the next access
creates a fresh one, so no stale state survives."
  (setf *tool-registry* nil))

(defun register-tool! (tool-record)
  "Register TOOL-RECORD (a plist with at least :name) in the registry.
Signals an error on name collision."
  (let* ((raw-name (getf tool-record :name)))
    (unless raw-name
      (error "tool record ~S has no :name" tool-record))
    (let* ((name (string-downcase (string raw-name)))
           (table (tool-registry)))
      (when (gethash name table)
        (error "a tool named ~S is already registered" name))
      (setf (gethash name table) tool-record))))

(defun find-tool (name)
  "Return the tool-record plist for NAME (a symbol or string), or NIL
if no such tool is registered."
  (gethash (string-downcase (string name)) (tool-registry)))

(defun all-tools ()
  "Return a list of all registered tool-record plists. Order is unspecified."
  (let ((records '()))
    (maphash (lambda (name record)
               (declare (ignore name))
               (push record records))
             (tool-registry))
    records))

(defun tool-names ()
  "Return a list of registered tool names (lowercase strings)."
  (let ((names '()))
    (maphash (lambda (name record)
               (declare (ignore record))
               (push name names))
             (tool-registry))
    names))

(defun apropos-tool (pattern)
  "Return the tool records whose :description contains PATTERN as a
case-insensitive substring."
  (let ((pat (string-downcase pattern))
        (matches '()))
    (maphash (lambda (name record)
               (declare (ignore name))
               (let ((desc (getf record :description)))
                 (when (and (stringp desc)
                            (search pat (string-downcase desc)))
                   (push record matches))))
             (tool-registry))
    matches))

(defun tool-schema-list ()
  "Return a flat list of tool-schema plists, one per registered tool,
ready for sexpr.provider:translate-tool-schemas. Each plist has :name,
:description, :parameters, and :required keys."
  (mapcar (lambda (record)
            (let ((schema (getf record :schema)))
              (list :name (getf record :name)
                    :description (getf record :description)
                    :parameters (getf schema :parameters)
                    :required (getf schema :required))))
          (all-tools)))

;;; --- schema derivation ---------------------------------------------------
;;;;
;;;; derive-schema walks a raw lambda list (Lisp data) and produces the
;;;; model-visible schema as plain sexpr plists. It does NOT call
;;;; sb-introspect and adds no dependency.

(defun %param-name (param)
  "The parameter name from a lambda-list parameter (a symbol or (name ...))."
  (if (consp param) (car param) param))

(defun %param-type-annotation (param)
  "The type annotation from a lambda-list parameter, or NIL.

A (name type) parameter annotates TYPE when TYPE is a symbol; a
(name default) parameter under &key/&optional has a non-symbol default
and carries no annotation."
  (and (consp param)
       (symbolp (cadr param))
       (cadr param)))

(defun %keyword-of (name)
  "Intern NAME (a symbol or string) as a keyword."
  (intern (string name) :keyword))

(defun %check-type (type name)
  "Refuse types outside the six the transport's validator accepts."
  (unless (member type '(:string :integer :number :boolean :array :object))
    (error "unsupported tool parameter type ~S for parameter ~S" type name))
  type)

(defun derive-schema (lambda-list &optional types)
  "Derive a tool schema from a raw lambda list.

Returns two values:
  PARAMS   — a list of parameter plists:
             ((:name \"path\" :type :string :required t) ...)
             :required appears only on required parameters.
  REQUIRED — a list of lowercase parameter-name strings.

TYPES is an optional (name . type) alist overriding the default :string
type for named parameters. &rest is refused (it cannot be represented as
a JSON schema parameter); &aux/&body/&whole/&environment/&allow-other-keys
are skipped. Parameter names are lowercased so PATH and path normalize
identically."
  (let ((params '())
        (required '())
        (required-items '())
        (key-items '())
        (optional-items '())
        (section :required))
    (dolist (item lambda-list)
      (cond
        ((eq item '&key) (setf section :key))
        ((eq item '&optional) (setf section :optional))
        ((eq item '&rest)
         (error "&rest parameters cannot be represented as JSON schema"))
        ((eq item '&aux) (setf section :aux))
        ((eq item '&allow-other-keys) (setf section :skip))
        ((member item '(&body &whole &environment)) (setf section :skip))
        (t (ecase section
             (:required (push item required-items))
             (:key (push item key-items))
             (:optional (push item optional-items))
             (:aux :skip)))))
    (flet ((add-param (param &optional requiredp)
             (let* ((name (%param-name param))
                    (annotation (%param-type-annotation param))
                    (type (%check-type
                           (or (cdr (assoc name types))
                               (and annotation (%keyword-of annotation))
                               :string)
                           name))
                    (entry (list :name (string-downcase (symbol-name name))
                                 :type type)))
               (when requiredp
                 (setf entry (append entry '(:required t))))
               (push entry params)
               (when requiredp
                 (push (string-downcase (symbol-name name)) required)))))
      (dolist (item (nreverse required-items)) (add-param item t))
      (dolist (item (nreverse key-items)) (add-param item nil))
      (dolist (item (nreverse optional-items)) (add-param item nil)))
    (values (nreverse params) (nreverse required))))

;;; --- the macro ---------------------------------------------------------

(defmacro define-tool (name lambda-list &body body)
  "Define NAME as a tool: a plain function wearing metadata.

BODY must start with a docstring, followed by optional leading keyword
options (:CAPABILITY, :DESCRIPTION, :TYPES) and the function body.

Expands to a DEFUN plus a REGISTER-TOOL! call that records the tool in
the registry with its schema derived from LAMBDA-LIST. The default
capability is :FS-READ."
  (unless (and body (stringp (car body)))
    (error "define-tool ~S: BODY must start with a docstring (a string)" name))
  (let* ((docstring (car body))
         (forms (cdr body))
         (capability :fs-read)
         (description nil)
         (types nil))
    (loop
      (when (or (null forms) (not (keywordp (car forms))))
        (return))
      (unless (cdr forms)
        (error "define-tool ~S: option ~S requires a value" name (car forms)))
      (case (car forms)
        (:capability (setf capability (cadr forms)))
        (:description (setf description (cadr forms)))
        (:types (setf types (cadr forms)))
        (otherwise (return)))
      (setf forms (cddr forms)))
    (let ((doc (or description docstring)))
      `(progn
         (defun ,name ,lambda-list ,docstring ,@forms)
         (register-tool!
          (list :name ,(string-downcase (symbol-name name))
                :symbol (function ,name)
                :description ,doc
                :schema (multiple-value-call
                         (lambda (params required)
                           (list :parameters params :required required))
                         (derive-schema ',lambda-list ',types))
                :capability ,capability))
         nil))))
