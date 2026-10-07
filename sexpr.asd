;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr — an Agent OS in Common Lisp
;;;;
;;;; System definition. Loads the package, then the library proper,
;;;; then the provider ("Ivory") layer, the transcript, and the kernel.

(defsystem "sexpr"
  :name "sexpr"
  :version "0.0.0"
  :author "David Li <taweili@gmail.com>"
  :license "GPL-3.0-or-later"
  :description "sexpr — an Agent OS in Common Lisp."
  :depends-on (:cl-llm-provider :eclector)
  :components
  ((:module "src"
     :components
     ((:file "package")
      (:module "provider"
        :depends-on ("package")
        :components
        ((:file "package")
         (:file "provider" :depends-on ("package"))))
      (:module "transcript"
        :depends-on ("package")
        :components
        ((:file "package")
         (:file "transcript" :depends-on ("package"))))
      (:module "kernel"
        :depends-on ("package" "transcript" "tools")
        :components
        ((:file "package")
         (:file "kernel" :depends-on ("package"))))
      (:module "cli"
        :depends-on ("package" "transcript" "kernel")
        :components
        ((:file "package")
         (:file "cli" :depends-on ("package"))))
      (:module "tools"
        :depends-on ("package")
        :components
        ((:file "package")
         (:file "tools" :depends-on ("package"))))
      (:module "sandbox"
        :depends-on ("package" "kernel")
        :components
        ((:file "package")
         (:file "sandbox" :depends-on ("package"))))
      ;; builtins depends on BOTH tools (register-tool!, derive-schema)
      ;; and sandbox (make-sandbox, eval-in-sandbox, condition taxonomy).
      ;; The tools module is loaded first, so a file in tools/ that named
      ;; sexpr.sandbox:make-sandbox would fail at read time, not call time.
      ;; This module exists only to give the five built-ins a legal place to
      ;; reference both. Placed after sandbox so the sandbox module is
      ;; already loaded by the time the built-ins file names it.
      (:module "builtins" :depends-on ("tools" "sandbox")
        :components
        ((:file "builtins")))
      ;; :sexpr.repl is an aggregating dev package (:use transcript/kernel/
      ;; tools/sandbox). It loads AFTER those four so defpackage's :use lists
      ;; resolve. :sexpr.cli references sexpr.repl:repl by qualified name
      ;; (Task 2), so :cli also depends-on "repl" — repl must exist at
      ;; cli.lisp read time. NOT :use'ing :sexpr.cli here avoids the cycle
      ;; (cli -> repl at read time, repl -> cli at defpackage time).
      (:module "repl"
        :depends-on ("transcript" "kernel" "tools" "sandbox")
        :components
        ((:file "package")
         (:file "repl" :depends-on ("package"))))
      (:file "sexpr" :depends-on ("provider" "transcript" "kernel" "cli" "tools" "sandbox" "builtins" "repl")))))
  ;; test-op is defined as a method in src/sexpr.lisp, not inline here:
  ;; inline :perform bodies are miscompiled by this Quicklisp-bundled
  ;; ASDF when the system has real dependencies (the leading DECLARE is
  ;; evaluated as a call). Defining the method in source is robust.
  :in-order-to ((test-op (load-op "sexpr") (load-op "sexpr/tests"))))

;;; --- tests -----------------------------------------------------------
;;;
;; A secondary system, so `ql:quickload :sexpr` never pulls in rove: rove is a
;; dependency of this system alone. asdf:test-op on :sexpr (defined in
;; src/sexpr.lisp, never inline here) runs rove over it — see :in-order-to above.

(defsystem "sexpr/tests"
  :name "sexpr/tests"
  :version "0.0.0"
  :author "David Li <taweili@gmail.com>"
  :license "GPL-3.0-or-later"
  :description "Test suite for sexpr (rove)."
  :depends-on (:sexpr :rove)
  :components
  ((:module "tests"
     :components
     ((:file "package")
      (:file "provider" :depends-on ("package"))
      (:file "smoke" :depends-on ("package"))
      (:file "transcript" :depends-on ("package"))
      (:file "kernel" :depends-on ("package"))
      (:file "cli" :depends-on ("package" "kernel"))
      (:file "tools" :depends-on ("package"))
      (:file "sandbox" :depends-on ("package"))
      (:file "repl" :depends-on ("package"))
      (:file "five" :depends-on ("package"))))))
