;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr-tests — the rove test package.
;;;;
;;;; All test files live in this package. `make test` (asdf:test-op on :sexpr)
;;;; loads the :sexpr-tests system and runs rove over this package. Keeping
;;;; the tests in their own system keeps rove out of :sexpr's dependency graph.

(defpackage :sexpr-tests
  (:nicknames :$-tests)
  (:use :cl :rove :sexpr.transcript :sexpr.kernel))
