;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/tools.lisp — the tool registry and schema derivation (R018, R024).
;;;;
;;;; Scope: define-tool, derive-schema, find-tool, apropos-tool, tool-names,
;;;; tool-schema-list, register-tool! collision, and the transport translation
;;;; in sexpr.provider:translate-tool-schemas.
;;;;
;;;; Every test calls reset-tool-registry! first: the registry is a process-wide
;;;; hash table, so without that isolation a tool registered by one test leaks
;;;; into the next and makes apropos-tool/tool-names results non-deterministic.
;;;; Nothing here touches the network, the filesystem, or a model server — the
;;;; registry is pure in-memory data and the translation is pure construction.
;;;;
;;;; BOUNDARY: symbols from :sexpr.provider are referenced fully qualified (the
;;;; test package does not :use it), matching tests/kernel.lisp and
;;;; tests/provider.lisp. Test 9 names the transport class to prove the seam
;;;; produces a transport-valid definition; that is allowed in tests — the R015
;;;; seam gate scans src/cli/, and the only production function that names the
;;;; transport type is sexpr.provider:translate-tool-schemas.

(in-package :sexpr-tests)

;;; --- helpers ---------------------------------------------------------

(defun %schema-plist (name lambda-list &optional types)
  "Build one tool-schema plist the way tool-schema-list would: :name,
:description, :parameters, :required, from a raw lambda list."
  (multiple-value-bind (params required) (derive-schema lambda-list types)
    (list :name name
          :description (format nil "Tool ~a." name)
          :parameters params
          :required required)))

;;; --- tests ----------------------------------------------------------

(rove:deftest define-tool-registers-a-plain-function
  "define-tool makes a plain callable function plus a registry record."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (ok (string= (my-read-file "/etc/hosts") "/etc/hosts")
      "the tool is an ordinary function: calling it returns the path")
  (let ((record (find-tool 'my-read-file)))
    (ok record "the tool is registered under its lowercase name")
    (ok (string= (getf record :name) "my-read-file") ":name is a lowercase string")
    (ok (eq (getf record :symbol) (fdefinition 'my-read-file))
        ":symbol is the function object itself")
    (ok (string= (getf record :description) "Read the file at PATH.")
        ":description is the docstring")
    (ok (equal (getf record :schema)
               '(:parameters ((:name "path" :type :string :required t))
                 :required ("path")))
        ":schema is the plain sexpr plist derived from the lambda list")
    (ok (eq (getf record :capability) :fs-read)
        ":capability defaults to :fs-read")))

(rove:deftest derive-schema-simple-path
  "(derive-schema '(path)) yields one required string parameter."
  (multiple-value-bind (params required) (derive-schema '(path))
    (ok (equal params '((:name "path" :type :string :required t)))
        "the single param is a required string")
    (ok (equal required '("path")) "the required list names path")))

(rove:deftest derive-schema-multi-key
  "(derive-schema '(path &key verbose)) marks only path required."
  (multiple-value-bind (params required) (derive-schema '(path &key verbose))
    (ok (equal params '((:name "path" :type :string :required t)
                        (:name "verbose" :type :string)))
        "the &key param carries no :required key")
    (ok (equal required '("path")) "required lists only the positional param")
    (ok (null (getf (second params) :required))
        "the verbose param has no :required key at all")))

(rove:deftest derive-schema-zero-params
  "(derive-schema '()) yields no parameters and no required names."
  (multiple-value-bind (params required) (derive-schema '())
    (ok (null params) "no parameters")
    (ok (null required) "no required names")))

(rove:deftest derive-schema-type-override
  "A (name . type) alist overrides the default :string type."
  (multiple-value-bind (params required)
      (derive-schema '(path &key count) '((count . :integer)))
    (declare (ignore required))
    (let ((count (find "count" params :key #'(lambda (p) (getf p :name))
                       :test #'string=)))
      (ok count "the count param is present")
      (ok (eq (getf count :type) :integer) "count is typed :integer")
      (ok (eq (getf (first params) :type) :string)
          "path keeps the default :string type"))))

(rove:deftest find-tool-by-symbol-and-string
  "find-tool accepts a symbol or a string and returns the same record."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (let ((by-symbol (find-tool 'my-read-file))
        (by-string (find-tool "my-read-file")))
    (ok by-symbol "find-tool by symbol returns a record")
    (ok (eq by-symbol by-string)
        "find-tool by symbol and by string return the same record"))
  (ok (null (find-tool 'no-such-tool)) "an unregistered name returns NIL"))

(rove:deftest apropos-tool-narrows-by-docstring
  "apropos-tool matches :description case-insensitively."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (define-tool my-list-dir (path)
    "List the entries of DIRECTORY."
    path)
  (let ((matches (apropos-tool "read")))
    (ok (= (length matches) 1) "only the read tool matches \"read\"")
    (ok (string= (getf (first matches) :name) "my-read-file")
        "the match is the read tool")
    (ok (equal (mapcar #'(lambda (r) (getf r :name)) (apropos-tool "READ"))
               '("my-read-file"))
        "the match is case-insensitive")
    (ok (null (apropos-tool "zzz")) "a pattern that matches nothing returns NIL")))

(rove:deftest register-tool-collision-errors
  "register-tool! signals an error when a name is already taken."
  (reset-tool-registry!)
  (register-tool! (list :name "dup-tool" :description "first"))
  (ok (signals (register-tool! (list :name "dup-tool" :description "second")))
      "the second registration of the same name signals an error")
  (ok (string= (getf (find-tool "dup-tool") :description) "first")
      "the original record survives the rejected collision"))

(rove:deftest translate-tool-schemas-produces-valid-definitions
  "sexpr tool-schema plists become transport-valid tool definitions (R024)."
  (let* ((plists (list (%schema-plist "read-file" '(path))
                       (%schema-plist "search" '(path &key verbose))
                       (%schema-plist "ping" '())))
         (definitions (sexpr.provider:translate-tool-schemas plists)))
    (ok (= (length definitions) 3) "one definition per input plist")
    (ok (every #'(lambda (d) (typep d 'cl-llm-provider:tool-definition))
               definitions)
        "each result is a transport tool-definition object")
    (ok (every #'cl-llm-provider:validate-tool-definition definitions)
        "every definition passes the transport's validator")
    (ok (string= (cl-llm-provider:tool-name (first definitions)) "read-file")
        "the name crosses the boundary unchanged")
    (ok (equal (cl-llm-provider:tool-required-params (second definitions))
               '("path"))
        "the required list crosses unchanged, without the optional key param")
    (ok (null (cl-llm-provider:tool-parameters (third definitions)))
        "the zero-parameter tool keeps an empty parameter list")))

(rove:deftest tool-schema-list-shape
  "tool-schema-list returns :name/:description/:parameters/:required plists."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (let ((schemas (tool-schema-list)))
    (ok (= (length schemas) 1) "one schema for one registered tool")
    (let ((plist (first schemas)))
      (ok (string= (getf plist :name) "my-read-file") ":name present")
      (ok (string= (getf plist :description) "Read the file at PATH.")
          ":description present")
      (ok (equal (getf plist :parameters)
                 '((:name "path" :type :string :required t)))
          ":parameters present")
      (ok (equal (getf plist :required) '("path")) ":required present"))
    (ok (equal (tool-names) '("my-read-file")) "tool-names lists the tool")))

;;; --- negative surface (Q7) -----------------------------------------

(rove:deftest translate-tool-schemas-rejects-malformed-plists
  "Malformed tool-schema plists fail fast in sexpr, not on the wire."
  (let ((bad (list (list :name "" :description "d" :parameters '() :required '())
                   (list :name "t" :parameters '() :required '())
                   (list :name "t" :description "d" :parameters 'x :required '())
                   (list :name "t" :description "d" :parameters '() :required '(:path)))))
    (dolist (plist bad)
      (ok (signals (sexpr.provider:translate-tool-schemas (list plist)))
          (format nil "~S is rejected" plist))
      (ok (null (sexpr.provider:translate-tool-schemas nil))
          "NIL input yields NIL"))))

(rove:deftest derive-schema-refuses-unrepresentable-shapes
  "derive-schema refuses &rest and types the transport cannot express."
  (ok (signals (derive-schema '(path &rest more)))
      "&rest cannot be represented as a JSON schema parameter")
  (ok (signals (derive-schema '(path) '((path . :blob))))
      "a type outside the six the transport validator accepts is refused"))
