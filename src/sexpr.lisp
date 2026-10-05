;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr — the Agent OS.
;;;;
;;;; This is the first real code in the project. It defines the package
;;;; identity and a `hello' entry point so the project is runnable end
;;;; to end. Real modules (kernel, transcript, tools, skills, MCP
;;;; bridge, etc.) will accumulate here.

(in-package :sexpr)

;;; --- identity ---------------------------------------------------------

(defparameter *name*    "sexpr")
(defparameter *version* "0.0.0")

(defun name ()
  "Return the project name."
  *name*)

(defun version ()
  "Return the project version."
  *version*)

;;; --- entry point ------------------------------------------------------

(defun hello (&optional (stream *standard-output*))
  "Print a greeting and return NIL.

This is the smoke-test entry point for the project: it proves that the
ASDF system loads, the package is usable, and the runtime is wired.
`asdf:test-op' on :sexpr invokes this."
  (format stream
          "~&sexpr ~a~%~
  An Agent OS in Common Lisp.~%~
  Hello from sexpr.~%~%"
          (version))
  nil)
