;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr — an Agent OS in Common Lisp
;;;;
;;;; System definition. Loads the package, then the library proper,
;;;; then the provider ("Ivory") layer.

(defsystem "sexpr"
  :name "sexpr"
  :version "0.0.0"
  :author "David Li <taweili@gmail.com>"
  :license "GPL-3.0-or-later"
  :description "sexpr — an Agent OS in Common Lisp."
  :depends-on (:cl-llm-provider)
  :components
  ((:module "src"
     :components
     ((:file "package")
      (:module "provider"
        :depends-on ("package")
        :components
        ((:file "package")
         (:file "provider" :depends-on ("package"))))
      (:file "sexpr" :depends-on ("provider")))))
  ;; test-op is defined as a method in src/sexpr.lisp, not inline here:
  ;; inline :perform bodies are miscompiled by this Quicklisp-bundled
  ;; ASDF when the system has real dependencies (the leading DECLARE is
  ;; evaluated as a call). Defining the method in source is robust.
  :in-order-to ((test-op (load-op "sexpr"))))
