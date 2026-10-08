;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-event-bus.lisp — standalone test for the event bus.
;;;;
;;;; Run with: sbcl --script tests/test-event-bus.lisp

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(defpackage :sexpr-test-event-bus
  (:use :cl :sexpr.kernel))

(in-package :sexpr-test-event-bus)

(defparameter *tests-run* 0)
(defparameter *tests-passed* 0)
(defparameter *tests-failed* 0)

(defun ok (description form)
  (incf *tests-run*)
  (if form
      (progn (incf *tests-passed*)
             (format t "  ok: ~A~%" description))
      (progn (incf *tests-failed*)
             (format t "  FAIL: ~A~%" description))))

(defun crash (description err)
  (incf *tests-run*)
  (incf *tests-failed*)
  (format t "  CRASH: ~A — ~A~%" description err))

(defmacro test (description &body body)
  `(handler-case
       (ok ,description (progn ,@body))
     (error (err)
       (crash ,description err))))

;;; --- reset the bus (idempotent) -------------------------------------

(clrhash *event-bus*)

;;; --- Event bus tests ------------------------------------------------

(format t "Event bus tests:~%~%")

(test "1. subscribe + emit delivers event to listener"
  (let ((received nil))
    (subscribe-event-bus "agent-1"
      (lambda (event) (push event received)))
    (emit-event "agent-1" '(hello world))
    (and (equal received '((hello world)))
         (= (length received) 1))))

(test "2. multiple listeners under the same agent-id"
  (let ((l1 nil) (l2 nil))
    (subscribe-event-bus "agent-2" (lambda (e) (push e l1)))
    (subscribe-event-bus "agent-2" (lambda (e) (push e l2)))
    (emit-event "agent-2" "event-1")
    (and (equal l1 '("event-1"))
         (equal l2 '("event-1")))))

(test "3. unsubscribe stops delivery"
  (let* ((events nil)
         (listener (lambda (e) (push e events))))
    (subscribe-event-bus "agent-3" listener)
    (emit-event "agent-3" "a")
    (unsubscribe-event-bus "agent-3" listener)
    (emit-event "agent-3" "b")
    (= (length events) 1)))

(test "4. agent-ids are isolated"
  (let ((a-events nil) (b-events nil))
    (subscribe-event-bus "agent-A" (lambda (e) (push e a-events)))
    (subscribe-event-bus "agent-B" (lambda (e) (push e b-events)))
    (emit-event "agent-A" "only-for-A")
    (and (equal a-events '("only-for-A"))
         (null b-events))))

(test "5. unsubscribe of unregistered listener is safe"
  (unsubscribe-event-bus "nonexistent" (lambda (x) x))
  t)

(test "6. emit to agent-id with no listeners is safe"
  (emit-event "nobody" "event")
  t)

;;; --- Summary --------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%"
        *tests-run* *tests-passed* *tests-failed*)

(if (= *tests-failed* 0)
    (format t "~%ALL PASSED~%")
    (progn
      (format *error-output* "~%FAILED~%")
      (sb-ext:exit :code 1)))
