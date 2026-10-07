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
;;;;
;;;; BOUNDARY: this package never references :sexpr.kernel. The gate takes the
;;;; capability SET as an argument, not an agent, so the dependency stays
;;;; one-way (kernel -> tools); reading agent-capabilities here would create
;;;; an ASDF package cycle.

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
;;;; define-tool is the constructor for USER-DEFINED tools. The built-ins in
;;;; src/builtins/builtins.lisp register through register-tool! +
;;;; derive-schema directly (via their own helper) so that
;;;; register-default-tools! can rebuild the registry after
;;;; reset-tool-registry! in tests — the define-tool macro's expansion
;;;; runs once at file-load time and cannot be re-invoked after a reset.

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

;;; --- the gate ---------------------------------------------------------
;;;;
;;;; DESIGN (notes/sexpr.md §1.3 and R019/R020): a tool is a function wearing
;;;; metadata, and the metadata is what makes a call checkable. S02 stored
;;;; :capability on every record but enforced nothing; this section is where
;;;; the registry can refuse. Three failure shapes, all conditions:
;;;;   :unknown-tool       — the model named a tool that is not registered
;;;;   :capability-denied  — the record's capability is not in the granted set
;;;;   :argument-error     — the arguments do not match the derived schema
;;;;
;;;; No restarts. §5's condition-and-restart approval machinery is out of
;;;; scope for this milestone (R027), so this is the minimal synchronous gate:
;;;; signal, and let the caller (the kernel's dispatch) record the failure as a
;;;; result event and keep the loop alive.

(define-condition tool-error (error)
  ((tool
    :initarg :tool
    :reader tool-error-tool
    :documentation "The tool name the failure is attributed to (a lowercase string).")
   (reason
    :initarg :reason
    :reader tool-error-reason
    :documentation ":unknown-tool, :capability-denied, or :argument-error.")
   (detail
    :initarg :detail
    :reader tool-error-detail
    :documentation "What was wrong: the offending argument name, the required
capability, or the list of registered tool names."))
  (:report (lambda (condition stream)
            (format stream "tool ~a: ~a~@[ — ~a~]"
                    (tool-error-tool condition)
                    (tool-error-reason condition)
                    (tool-error-detail condition))))
  (:documentation
   "A tool failure at the gate: unknown tool, capability denial, or argument
validation failure. The kernel catches these and records a result event, so a
bad call is data in the transcript rather than an exception that kills the
agent loop."))

(defun check-capability (record capabilities)
  "Return T when RECORD's declared capability is granted in CAPABILITIES.

Signals TOOL-ERROR with :reason :capability-denied naming the required
capability when it is not granted. A record with no declared capability is
ungated and returns T: DEFINE-TOOL always declares one, but REGISTER-TOOL!
accepts hand-built records, so the gate only refuses tools that name a
capability. CAPABILITIES is the capability SET (a list of keywords), not an
agent — this package must not know about :sexpr.kernel.

The gate is a membership test, not a sandbox. A granted :process capability can
run anything through a shell tool; that is the honest limit of a v1 gate."
  (let ((required (getf record :capability)))
    (unless required
      (return-from check-capability t))
    (when (member required capabilities)
      (return-from check-capability t))
    (error 'tool-error
           :tool (getf record :name)
           :reason :capability-denied
           :detail (format nil "~(~A~) required, granted: ~a" required (or capabilities '())))))

(defun %argument-key (key)
  "Normalize an incoming argument KEY to a lowercase string.

The transport interns JSON argument keys as UPPERCASE keywords, so the schema
parameter name \"path\" arrives as :PATH on every call, and keys longer than
128 characters stay strings. Both keyword and string keys are accepted here, so
the schema name is the only thing a caller has to get right."
  (string-downcase (string key)))

(defun %type-predicate (type)
  "The predicate the six accepted schema types check values against.

NIL for a type outside the six means 'check nothing' — derive-schema already
refuses those at definition time, so this is a defensive branch, not a hole."
  (case type
    (:string #'stringp)
    (:integer #'integerp)
    (:number #'numberp)
    (:boolean #'(lambda (value) (or (eq value t) (null value))))
    (:array #'listp)
    (:object #'(lambda (value) (and (listp value) (evenp (length value)))))
    (otherwise nil)))

(defun validate-tool-arguments (record args)
  "Validate ARGS (the model's argument plist) against RECORD's derived schema.

Returns a normalized (name . value) alist on success, where each NAME is the
lowercase schema parameter name. Signals TOOL-ERROR with :reason
:argument-error naming the offending argument for: a missing required key, a
value that fails the type predicate for the six accepted types, an extra key
not in the derived schema, and NIL arguments when the tool has required
parameters — the transport returns NIL when it cannot parse the model's JSON,
so 'no arguments at all' must be a recorded failure, not a vacuously valid
zero-argument call. A malformed (odd-length) argument plist is refused the same
way.

Keys are normalized to lowercase strings, so :PATH, :path, and \"path\" all
match the schema parameter \"path\"."
  (let* ((schema (getf record :schema))
         (params (getf schema :parameters))
         (required (getf schema :required))
         (tool-name (getf record :name)))
    (when (null args)
      (when required
        (error 'tool-error
               :tool tool-name
               :reason :argument-error
               :detail (format nil "no arguments supplied; required: ~a" required)))
      (return-from validate-tool-arguments nil))
    (unless (evenp (length args))
      (error 'tool-error
             :tool tool-name
             :reason :argument-error
             :detail (format nil "malformed argument plist ~a" args)))
    (let ((normalized '()))
      (loop for (key value) on args by #'cddr
            for name = (%argument-key key)
            do (let ((param (find name params
                                  :key #'(lambda (p) (getf p :name))
                                  :test #'string=)))
                 (unless param
                   (error 'tool-error
                          :tool tool-name
                          :reason :argument-error
                          :detail (format nil "extra argument ~a is not in the schema" name)))
                 (let ((predicate (%type-predicate (getf param :type))))
                   (when (and predicate (not (funcall predicate value)))
                     (error 'tool-error
                            :tool tool-name
                            :reason :argument-error
                            :detail (format nil "argument ~a expects ~a, got ~a"
                                            name (getf param :type) value))))
                 (push (cons name value) normalized)))
      (dolist (name required)
        (unless (assoc name normalized :test #'string=)
          (error 'tool-error
                 :tool tool-name
                 :reason :argument-error
                 :detail (format nil "missing required argument ~a" name))))
      (nreverse normalized))))

(defun perform-tool (tool-call &key capabilities)
  "Execute TOOL-CALL — the transport-shaped plist (:id .. :name .. :arguments ..).

Order is the gate: find-tool on :name (TOOL-ERROR :unknown-tool with the
registered names in the detail), check-capability, validate-tool-arguments,
then apply — required parameters positional in derived-schema order, the rest
as keyword arguments. Returns the tool's return value. Errors raised inside a
tool body propagate to the caller; the kernel's dispatch catches them and
records a failure result, so nothing here swallows anything.

CAPABILITIES is the capability SET, not the agent: :sexpr.tools never reads
:sexpr.kernel, since kernel depends on tools and reading agent-capabilities
here would create an ASDF package cycle (D009).

Tools must use &key for optional parameters. A &optional parameter is not a
keyword argument, so a call that passes one signals at call time and is caught
by the loop — that is why S05's five tools use &key."
  (let* ((raw-name (getf tool-call :name))
         (tool-name (and raw-name (string-downcase (string raw-name))))
         (record (and tool-name (find-tool tool-name))))
    (unless record
      (error 'tool-error
             :tool tool-name
             :reason :unknown-tool
             :detail (tool-names)))
    (check-capability record capabilities)
    (let* ((args (validate-tool-arguments record (getf tool-call :arguments)))
          (schema (getf record :schema))
          (params (getf schema :parameters))
          (required (getf schema :required))
          (positional nil)
          (keywords nil))
      (dolist (param params)
        (let* ((name (getf param :name))
               (cell (assoc name args :test #'string=))
               (reqp (member name required :test #'string=)))
          (when (and cell reqp)
            (push (cdr cell) positional))
          (when (and cell (not reqp))
            (push (intern (string-upcase name) :keyword) keywords)
            (push (cdr cell) keywords))))
      (apply (getf record :symbol)
             (append (nreverse positional) (nreverse keywords))))))
