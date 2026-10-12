;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr-tui — the remote TUI client for a running sexpr image (M004/S03).
;;;;
;;;; SYSTEM BOUNDARY: this is a SEPARATE ASDF system from :sexpr, and it must
;;;; stay that way. The client is a projection renderer: it holds strings,
;;;; plists, numbers and message objects that came off the wire, never live
;;;; kernel objects (R023). Depending on :sexpr would pull the kernel into the
;;;; client process and create a second society, so :depends-on is (:tuition)
;;;; ONLY. Conversely sexpr.asd must never gain :tuition — `ql:quickload :sexpr`
;;;; must not pull a TUI library into the image. Both directions are asserted by
;;;; tests/test-tui-client.lisp, not by prose.
;;;;
;;;; Components are listed in load order and only files that exist are listed:
;;;; T01 ships package, messages, wire; T02 appends swank-rpc. Later S03 tasks add model,
;;;; view and main as their files land.

(defsystem "sexpr-tui"
  :name "sexpr-tui"
  :version "0.0.0"
  :author "David Li <taweili@gmail.com>"
  :license "GPL-3.0-or-later"
  :description "sexpr-tui — remote TUI client for a running sexpr image."
  :depends-on (:tuition)
  :components
  ((:module "src"
     :components
     ((:module "tui-client"
        :components
        ((:file "package")
         (:file "messages" :depends-on ("package"))
         (:file "wire" :depends-on ("package" "messages"))
         (:file "swank-rpc" :depends-on ("package" "messages" "wire"))
         (:file "view" :depends-on ("package" "messages"))
         (:file "model" :depends-on ("package" "messages" "wire" "swank-rpc" "view"))
         (:file "main" :depends-on ("package" "messages" "wire" "swank-rpc" "view" "model"))))))))
  ;; sb-bsd-sockets and sb-thread are SBCL built-ins reached by (require) inside
  ;; wire.lisp, exactly as src/tui/server.lisp does. They are deliberately NOT
  ;; in :depends-on so the system stays SBCL-internal rather than a Quicklisp
  ;; dependency graph.
