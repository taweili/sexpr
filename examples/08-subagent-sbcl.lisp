#| 08-subagent-sbcl.lisp — Spawning subagents directly from SBCL.

Multi-agent coordination: spawn worker agents in parallel, collect
their results, and inspect the process tree. Workers inherit the
parent's capabilities and endpoint by default.

This example uses a stub provider (canned responses) so it runs
without a real model endpoint.

Run:
  sbcl --load ~/.sbclinit --load examples/08-subagent-sbcl.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.agents)

(format t "=== 08-subagent-sbcl.lisp ===~%")
(format t "~%")

;; -----------------------------------------------------------------------
;; Stub provider — returns canned responses from a queue.
;; -----------------------------------------------------------------------

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

;; -----------------------------------------------------------------------
;; 1. Single spawn — one parent, one child
;; -----------------------------------------------------------------------

(format t "-- 1. Single spawn --~%")
(clear-subagent-registry!)

(let* ((stub (make-instance 'stub-endpoint
                            :responses (list
                                        (list :content "I'm a worker!" :finish :stop))))
       (parent (sexpr.kernel:spawn :goal "orchestrator"
                                    :endpoint stub
                                    :name "orchestrator"))
       (id (let ((sexpr.kernel:*current-agent* parent))
             (spawn-subagent "do a task"))))
  (format t "handle id: ~a~%" id)
  (let ((summary (let ((sexpr.kernel:*current-agent* parent))
                   (subagent-summary id))))
    (format t "summary:   ~a~%" summary))
  (format t "children:  ~a~%"
          (mapcar #'(lambda (a) (sexpr.kernel:agent-name a))
                  (sexpr.kernel:agent-child-list parent))))

;; -----------------------------------------------------------------------
;; 2. Parallel spawns — one parent, two children
;; -----------------------------------------------------------------------

(format t "~%-- 2. Parallel spawns --~%")
(clear-subagent-registry!)

(let* ((stub (make-instance 'stub-endpoint
                            :responses (list
                                        (list :content "I read the file." :finish :stop)
                                        (list :content "I wrote the file." :finish :stop)
                                        (list :content "Both workers done." :finish :stop))))
       (parent (sexpr.kernel:spawn :goal "parallel orchestrator"
                                    :endpoint stub
                                    :name "orch"))
       (id1 (let ((sexpr.kernel:*current-agent* parent))
              (spawn-subagent "read something")))
       (id2 (let ((sexpr.kernel:*current-agent* parent))
              (spawn-subagent "write something"))))
  (format t "handles: ~a ~a~%" id1 id2)
  (let* ((s1 (let ((sexpr.kernel:*current-agent* parent)) (subagent-summary id1)))
         (s2 (let ((sexpr.kernel:*current-agent* parent)) (subagent-summary id2))))
    (format t "~a: ~a~%" id1 s1)
    (format t "~a: ~a~%" id2 s2))
  (format t "process tree:~%")
  (dolist (child (sexpr.kernel:agent-child-list parent))
    (format t "  ~a [~a]~%"
            (sexpr.kernel:agent-name child)
            (sexpr.kernel:agent-status child))))

;; -----------------------------------------------------------------------
;; 3. Capability inheritance
;; -----------------------------------------------------------------------

(format t "~%-- 3. Capability inheritance --~%")
(clear-subagent-registry!)

(let* ((stub (make-instance 'stub-endpoint
                            :responses (list (list :content "ok" :finish :stop))))
       (parent (sexpr.kernel:spawn :goal "restricted"
                                    :endpoint stub
                                    :name "restricted-parent"
                                    :capabilities '(:fs-read :spawn)))
       (child-id (let ((sexpr.kernel:*current-agent* parent))
                   (spawn-subagent "inherited"))))
  (format t "parent caps:  ~a~%"
          (sexpr.kernel:agent-capabilities parent))
  (format t "child caps:   ~a~%"
          (sexpr.kernel:agent-capabilities
           (handle-agent (find-handle child-id))))
  (format t "caps inherited: ~a~%"
          (equal (sexpr.kernel:agent-capabilities
                  (handle-agent (find-handle child-id)))
                 '(:fs-read :spawn))))

;; -----------------------------------------------------------------------
;; 4. Explicit capability override
;; -----------------------------------------------------------------------

(format t "~%-- 4. Capability override --~%")
(clear-subagent-registry!)

(let* ((stub (make-instance 'stub-endpoint
                            :responses (list (list :content "ok" :finish :stop))))
       (parent (sexpr.kernel:spawn :goal "wide"
                                    :endpoint stub
                                    :name "wide-parent"
                                    :capabilities '(:fs-read :fs-write :process :lisp-eval :spawn)))
       (child-id (let ((sexpr.kernel:*current-agent* parent))
                   (spawn-subagent "narrow"
                                   :capabilities '(:fs-read)))))
  (format t "parent caps: ~a~%"
          (sexpr.kernel:agent-capabilities parent))
  (format t "child caps:  ~a~%"
          (sexpr.kernel:agent-capabilities
           (handle-agent (find-handle child-id)))))

;; -----------------------------------------------------------------------
;; 5. Deep nesting — grandchild agents
;; -----------------------------------------------------------------------

(format t "~%-- 5. Deep nesting --~%")
(clear-subagent-registry!)

(let* ((parent-stub (make-instance 'stub-endpoint
                                   :responses (list (list :content "root done" :finish :stop))))
       (child-stub (make-instance 'stub-endpoint
                                  :responses (list (list :content "child done" :finish :stop))))
       (grandchild-stub (make-instance 'stub-endpoint
                                       :responses (list (list :content "grandchild done" :finish :stop))))
       (parent (sexpr.kernel:spawn :goal "root"
                                    :endpoint parent-stub
                                    :name "root"))
       (child-id (let ((sexpr.kernel:*current-agent* parent))
                   (spawn-subagent "mid-level" :endpoint child-stub)))
       (child-agent (handle-agent (find-handle child-id))))
  (format t "root children: ~a~%"
          (mapcar #'(lambda (a) (sexpr.kernel:agent-name a))
                  (sexpr.kernel:agent-child-list parent)))

  (let ((grandchild-id
         (let ((sexpr.kernel:*current-agent* child-agent))
           (spawn-subagent "leaf" :endpoint grandchild-stub))))
    (format t "child children: ~a~%"
            (mapcar #'(lambda (a) (sexpr.kernel:agent-name a))
                    (sexpr.kernel:agent-child-list child-agent)))
    (format t "grandchild handle: ~a~%" grandchild-id)
    ;; Collect results bottom-up
    (let ((grandchild-summary
           (let ((sexpr.kernel:*current-agent* child-agent))
             (subagent-summary grandchild-id))))
      (format t "grandchild: ~a~%" grandchild-summary))
    (let ((child-summary
           (let ((sexpr.kernel:*current-agent* parent))
             (subagent-summary child-id))))
      (format t "child:      ~a~%" child-summary))
    (format t "status tree:~%")
    (format t "  root:  ~a~%" (sexpr.kernel:agent-status parent))
    (format t "  child: ~a~%" (sexpr.kernel:agent-status child-agent))
    (format t "  grand: ~a~%"
            (sexpr.kernel:agent-status
             (handle-agent (find-handle grandchild-id))))))

;; -----------------------------------------------------------------------
;; 6. Agent error propagation
;; -----------------------------------------------------------------------

(format t "~%-- 6. Agent error propagation --~%")
(clear-subagent-registry!)

;; Endpoint that fails on the second call
(defclass error-endpoint ()
  ((call-count :initform 0 :accessor error-call-count)))

(defmethod sexpr.provider:provider-call ((ep error-endpoint) messages
                                          &key system tools temperature max-tokens)
  (declare (ignore messages system tools temperature max-tokens))
  (incf (error-call-count ep))
  (if (> (error-call-count ep) 1)
      (error "simulated worker failure")
      (list :content "starting work" :finish :stop
            :model "error-stub" :usage nil :tool-calls nil)))

(let* ((parent (sexpr.kernel:spawn :goal "will-fail"
                                    :endpoint (make-instance 'error-endpoint)
                                    :name "fail-parent"))
       (id (let ((sexpr.kernel:*current-agent* parent))
             (spawn-subagent "trigger an error"))))
  (format t "handle id: ~a~%" id)
  (handler-case
      (let ((sexpr.kernel:*current-agent* parent))
        (subagent-summary id))
    (error (err)
      (format t "caught error: ~a~%" (format nil "~a" err))
      (format t "error via subagent-error: ~a~%"
              (let ((sexpr.kernel:*current-agent* parent))
                (subagent-error id))))))

(format t "~%=== done ===~%")
