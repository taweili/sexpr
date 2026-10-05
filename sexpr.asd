;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr — an Agent OS in Common Lisp
;;;;
;;;; System definition. Loads the package, then the library proper.

(defsystem "sexpr"
  :name "sexpr"
  :version "0.0.0"
  :author "David Li <taweili@gmail.com>"
  :license "GPL-3.0-or-later"
  :description "sexpr — an Agent OS in Common Lisp."
  :depends-on ()
  :components
  ((:module "src"
     :components
     ((:file "package")
      (:file "sexpr"))))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (funcall (find-symbol 'hello 'sexpr))))
