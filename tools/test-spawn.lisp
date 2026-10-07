;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Quick functional test for spawn-subagent / subagent-summary.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.agents)

(defclass stub-endpoint ()
  ((responses :initarg :responses :accessor stub-responses)))

(defmethod sexpr.provider:provider-call ((ep stub-endpoint) messages
                                         &key system tools temperature max-tokens)
  (declare (ignore messages system tools temperature max-tokens))
  (let ((r (pop (stub-responses ep))))
    (list :content (getf r :content)
          :finish (getf r :finish)
          :model "stub"
          :usage nil
          :tool-calls nil)))

(defun test-spawn ()
  (clear-subagent-registry!)
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "hello" :finish :stop))))
         (parent (sexpr.kernel:spawn :goal "parent agent"
                                     :endpoint stub
                                     :name "parent"))
         (id (let ((sexpr.kernel:*current-agent* parent))
               (spawn-subagent "say hello"))))
    (format t "handle id: ~a~%" id)
    (let ((summary (let ((sexpr.kernel:*current-agent* parent))
                     (subagent-summary id))))
      (format t "summary: ~a~%" summary))
    (format t "children: ~a~%" (mapcar (lambda (a) (sexpr.kernel:agent-name a))
                                       (agent-child-list parent)))
    (let ((child (first (agent-child-list parent))))
      (format t "child status: ~a~%" (sexpr.kernel:agent-status child)))))

(format t "--- running test-spawn ---~%")
(test-spawn)
(format t "--- done ---~%")
