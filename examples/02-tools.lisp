#| 02-tools.lisp — The tool registry: plain functions wearing metadata.

A tool is a plain Lisp function with a name, a description, a schema
derived from its lambda list, and a capability requirement. The registry
maps tool names to records; the model sees the schema, the kernel dispatches
the call.

Run:
  sbcl --load ~/.sbclinit --load examples/02-tools.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.tools)

(format t "=== 02-tools.lisp ===~%")
(format t "~%")

;; 1. List all registered tools
(format t "-- Registered tool names --~%")
(format t "~a~%" (sort (tool-names) #'string<))

;; 2. Look up a tool record
(format t "~%-- Tool record for read-file --~%")
(let ((record (find-tool "read-file")))
  (format t "name:        ~a~%" (getf record :name))
  (format t "description: ~a~%" (getf record :description))
  (format t "capability:  ~a~%" (getf record :capability))
  (format t "symbol:      ~a~%" (type-of (getf record :symbol))))

;; 3. Schema derivation from a lambda list
(format t "~%-- Schema derivation --~%")
(multiple-value-bind (params required)
    (derive-schema '(path &key (verbose nil)))
  (format t "params:   ~a~%" params)
  (format t "required: ~a~%" required))

(multiple-value-bind (params required)
    (derive-schema '(command &key (seconds 30.0))
                   '((seconds . :number)))
  (format t "~%with type overrides:~%")
  (format t "params:   ~a~%" params)
  (format t "required: ~a~%" required))

;; 4. The full tool-schema-list (what the model sees)
(format t "~%-- tool-schema-list (model-visible) --~%")
(dolist (schema (tool-schema-list))
  (format t "~a: ~a~%"
          (getf schema :name)
          (getf schema :required)))

;; 5. Register a custom tool with define-tool
(format t "~%-- Register a custom tool --~%")
(define-tool greet (name &key (times 1))
  "Return NAME greeted TIMES times."
  :description "Greet someone N times."
  (format nil "~{~a ~%~}" (make-list times :initial-element name)))

(format t "Registered: ~a~%" (tool-names))
(format t "~%Call it directly:~%")
(format t "~a~%" (greet "Alice"))
(format t "~a~%" (greet "Bob" :times 3))

;; 6. Custom tool schema
(format t "~%-- Custom tool schema --~%")
(let ((record (find-tool "greet")))
  (format t "schema: ~a~%" (getf record :schema)))

(format t "~%=== done ===~%")
