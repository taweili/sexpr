;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/tools.lisp — the tool registry and schema derivation (R018, R024).
;;;;
;;;; Scope: define-tool, derive-schema, find-tool, apropos-tool, tool-names,
;;;; tool-schema-list, register-tool! collision, the capability gate and
;;;; argument validation (R019, R020), and the transport translation in
;;;; sexpr.provider:translate-tool-schemas.
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

;;; --- the gate (R019, R020) -----------------------------------------
;;;;
;;;; The registry was honest about being unenforced in S02: every record
;;;; carried :capability and nothing refused. These groups are where the gate
;;;; has something real to refuse — the three failure shapes (unknown tool,
;;;; capability denial, argument validation failure) and the apply step that
;;;; turns a validated argument alist back into a lambda-list call.
;;;;
;;;; Each group calls reset-tool-registry! first, like the rest of this file.
;;;; Conditions are captured with handler-case rather than rove's `signals`,
;;;; because `signals` returns T and the assertions here need the condition's
;;;; readers (tool-error-tool / -reason / -detail).

(rove:deftest perform-tool-unknown-tool-names-the-registered-tools
  "perform-tool signals :unknown-tool with the registered names in the detail."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (let ((err (handler-case (perform-tool (list :id "1" :name "no-such-tool"
                                               :arguments (list :path "/x")))
              (tool-error (c) c))))
    (ok err "an unregistered name signals")
    (ok (eq (tool-error-reason err) :unknown-tool) ":reason is :unknown-tool")
    (ok (string= (tool-error-tool err) "no-such-tool")
        ":tool names the tool the model asked for")
    (ok (equal (tool-error-detail err) '("my-read-file"))
        "the detail lists the tools that do exist"))
  (let ((err (handler-case (perform-tool (list :id "2" :arguments (list :path "/x")))
              (tool-error (c) c))))
    (ok err "a call with no :name signals rather than erroring on the name")
    (ok (eq (tool-error-reason err) :unknown-tool)
        "a nameless call is the same failure shape")))

(rove:deftest tool-error-report-names-the-tool-and-the-reason
  "The condition prints a readable log line naming the tool and the reason."
  (reset-tool-registry!)
  (define-tool my-eval (form)
    "Evaluate FORM."
    :capability :lisp-eval
    form)
  (let ((err (handler-case (check-capability (find-tool 'my-eval) '(:fs-read))
              (tool-error (c) c))))
    ;; ~A prints the condition through its :report option, which is the log
    ;; line. The case is normalized because the reason keyword prints through
    ;; *print-case*, so an exact lowercase search would be implementation noise.
    (let ((msg (string-downcase (format nil "~a" err))))
      (ok (search "my-eval" msg) "the report names the tool")
      (ok (search "capability-denied" msg) "the report names the reason")
      (ok (search "lisp-eval" msg) "and the required capability"))))

(rove:deftest check-capability-refuses-an-unganted-capability
  "The gate refuses a tool whose declared capability is not in the granted set."
  (reset-tool-registry!)
  (define-tool my-eval (form)
    "Evaluate FORM."
    :capability :lisp-eval
    form)
  (let ((record (find-tool 'my-eval)))
    (let ((err (handler-case (check-capability record '(:fs-read)) (tool-error (c) c))))
      (ok err "an unganted capability signals")
      (ok (eq (tool-error-reason err) :capability-denied) ":reason is :capability-denied")
      (ok (string= (tool-error-tool err) "my-eval") ":tool names the tool")
      (ok (search "lisp-eval" (tool-error-detail err))
          "the detail names the required capability"))
    (ok (eq (check-capability record '(:fs-read :lisp-eval)) t)
        "the same tool is granted when the capability is in the set")
    (ok (eq (check-capability (list :name "hand-built" :description "d") '(:fs-read)) t)
        "a record with no declared capability is ungated")))

(rove:deftest perform-tool-runs-a-tool-when-its-capability-is-granted
  "A granted capability lets the tool run and returns its value."
  (reset-tool-registry!)
  (define-tool my-add (a b)
    "Add A and B."
    :types ((a . :integer) (b . :integer))
    (+ a b))
  (ok (= (perform-tool (list :id "1" :name "my-add" :arguments (list :a 2 :b 3))
                       :capabilities '(:fs-read))
         5)
      "the tool ran and returned 5")
  (ok (= (perform-tool (list :id "2" :name "my-add" :arguments (list :A 10 :B 20))
                       :capabilities '(:fs-read))
         30)
      "the transport's uppercase keyword keys reach the tool unchanged")
  (define-tool my-failing (path)
    "Read PATH and fail."
    (error "the tool body signals"))
  (ok (signals (perform-tool (list :id "3" :name "my-failing"
                                   :arguments (list :path "/x"))
                             :capabilities '(:fs-read)))
      "a tool body that signals propagates to the caller — the gate swallows nothing"))

(rove:deftest validate-tool-arguments-refuses-missing-wrong-typed-and-extra-keys
  "Missing key, wrong type, and extra key each signal :argument-error naming the argument."
  (reset-tool-registry!)
  (define-tool my-read-file (path &key count)
    "Read the file at PATH."
    :types ((count . :integer))
    (list path count))
  (let ((record (find-tool 'my-read-file)))
    (let ((err (handler-case (validate-tool-arguments record (list :count 2))
                (tool-error (c) c))))
      (ok err "a missing required key signals")
      (ok (eq (tool-error-reason err) :argument-error) ":reason is :argument-error")
      (ok (search "path" (tool-error-detail err)) "the detail names the missing argument"))
    (let ((err (handler-case (validate-tool-arguments record (list :path "/x" :count "3"))
                (tool-error (c) c))))
      (ok err "a value that fails its type predicate signals")
      (ok (search "count" (tool-error-detail err)) "the detail names the mistyped argument"))
    (let ((err (handler-case (validate-tool-arguments record (list :path "/x" :mode "r"))
                (tool-error (c) c))))
      (ok err "an extra key not in the derived schema signals")
      (ok (search "mode" (tool-error-detail err)) "the detail names the extra argument"))
    (ok (equal (validate-tool-arguments record (list :path "/x"))
               '(("path" . "/x")))
        "a call that supplies only the required parameters is valid")))

(rove:deftest validate-tool-arguments-refuses-nil-arguments-for-required-params
  "NIL arguments with required parameters is a recorded failure, not a vacuous pass."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (define-tool my-ping ()
    "Ping."
    'pong)
  (let ((err (handler-case (validate-tool-arguments (find-tool 'my-read-file) nil)
              (tool-error (c) c))))
    (ok err "the transport returns NIL when it cannot parse the model's JSON")
    (ok (eq (tool-error-reason err) :argument-error) ":reason is :argument-error")
    (ok (search "path" (tool-error-detail err)) "the detail names the required argument"))
  (ok (null (validate-tool-arguments (find-tool 'my-ping) nil))
      "a zero-parameter tool still accepts NIL: nothing was required"))

(rove:deftest validate-tool-arguments-checks-the-six-schema-types
  "Each of the six accepted types has its own predicate."
  (reset-tool-registry!)
  (define-tool my-tool (path &key count flag tags obj)
    "Read PATH with options."
    :types ((count . :integer) (flag . :boolean) (tags . :array) (obj . :object))
    (list path count flag tags obj))
  (let ((record (find-tool 'my-tool)))
    (ok (equal (validate-tool-arguments record
                                       (list :path "/x" :count 3 :flag t :tags '("a")
                                             :obj '("k" 1)))
               '(("path" . "/x") ("count" . 3) ("flag" . t) ("tags" . ("a"))
                 ("obj" . ("k" 1))))
        "a well-typed call returns the normalized (name . value) alist")
    (dolist (bad (list (list :path 42)
                       (list :path "/x" :count "3")
                       (list :path "/x" :flag "yes")
                       (list :path "/x" :tags "a b")
                       (list :path "/x" :obj '("k"))
                       (list :path "/x" :count 3.5)))
      (let ((err (handler-case (validate-tool-arguments record bad) (tool-error (c) c))))
        (ok err (format nil "~a is refused" bad))
        (ok (eq (tool-error-reason err) :argument-error)
            "the failure shape is the same for every type")))))

(rove:deftest argument-keys-normalize-to-lowercase-schema-names
  ":PATH, :path, and \"path\" all match the schema parameter \"path\"."
  (reset-tool-registry!)
  (define-tool my-read-file (path)
    "Read the file at PATH."
    path)
  (let ((record (find-tool 'my-read-file)))
    (ok (equal (validate-tool-arguments record (list :PATH "/etc/hosts"))
               '(("path" . "/etc/hosts")))
        "the transport's uppercase keyword key normalizes to the schema name")
    (ok (equal (validate-tool-arguments record (list "path" "/etc/hosts"))
               '(("path" . "/etc/hosts")))
        "a key the transport keeps as a string (longer than 128 chars) matches too")
    (ok (string= (perform-tool (list :id "1" :name 'my-read-file
                                     :arguments (list :PATH "/etc/hosts"))
                               :capabilities '(:fs-read))
                 "/etc/hosts")
        "perform-tool applies the normalized key through the gate")))

(rove:deftest perform-tool-applies-parameters-in-lambda-list-shape
  "Required parameters go positional in derived-schema order; the rest as keywords."
  (reset-tool-registry!)
  (define-tool my-describe (dir depth &key verbose)
    "Describe DIR to DEPTH."
    :types ((depth . :integer) (verbose . :boolean))
    (format nil "~a:~a~a" dir depth (if verbose "*" "")))
  (ok (string= (perform-tool (list :id "1" :name "my-describe"
                                   :arguments (list :dir "/tmp" :depth 2 :verbose t))
                             :capabilities '(:fs-read))
               "/tmp:2*")
      "the required params went positional in schema order, the &key param as a keyword")
  (ok (string= (perform-tool (list :id "2" :name "my-describe"
                                   :arguments (list :dir "/tmp" :depth 1))
                             :capabilities '(:fs-read))
               "/tmp:1")
      "an omitted optional key keeps its lambda-list default"))

(rove:deftest perform-tool-signals-at-call-time-for-an-optional-parameter
  "A &optional parameter is not a keyword argument: the call itself signals."
  (reset-tool-registry!)
  (define-tool my-optional (path &optional verbose)
    "Read PATH, optionally verbosely."
    (list path verbose))
  (ok (signals (perform-tool (list :id "1" :name "my-optional"
                                   :arguments (list :path "/x" :verbose "yes"))
                             :capabilities '(:fs-read)))
      "the argument passes validation but the apply signals — tools must use &key"))
