;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/smoke.lisp — proves the rove harness runs.
;;;;
;;;; This is the canary: if `make test` fails to report this, the harness
;;;; (asdf:test-op -> :sexpr-tests -> rove) is broken, not the project.

(in-package :sexpr-tests)

(rove:deftest smoke
  (ok (= 1 1) "arithmetic is intact")
  (ok (= (length (list 1 2 3)) 3) "lists have length"))
