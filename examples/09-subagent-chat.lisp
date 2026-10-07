#| 09-subagent-chat.lisp — Multi-agent coordination through the chat loop.

Demonstrates how the LLM spawns subagents via tool calls inside the
chat loop. The model emits spawn-subagent, the kernel dispatches it,
the subagent runs in a background thread, and the model collects the
result via subagent-summary.

This example uses mock providers (canned responses) so it runs without
a real model endpoint.

Run:
  sbcl --load ~/.sbclinit --load examples/09-subagent-chat.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.agents)

(format t "=== 09-subagent-chat.lisp ===~%")
(format t "~%")

;; -----------------------------------------------------------------------
;; Thread-safe mock endpoint — handles concurrent calls from parent
;; and child threads. Each call pops from a queue; the queue is
;; protected by a lock.
;; -----------------------------------------------------------------------

(defclass mock-endpoint ()
  ((queue :initarg :queue :accessor mock-queue)
   (mutex :initform nil :accessor mock-mutex)))

(defmethod initialize-instance :after ((ep mock-endpoint) &key)
  (setf (mock-mutex ep) (sb-thread:make-mutex)))

(defmethod sexpr.provider:provider-call ((ep mock-endpoint) messages
                                          &key system tools temperature max-tokens)
  (declare (ignore messages system tools temperature max-tokens))
  (sb-thread:with-mutex ((mock-mutex ep))
    (when (mock-queue ep)
      (let ((r (pop (mock-queue ep))))
        (list :content (getf r :content)
              :finish (getf r :finish)
              :model (getf r :model "mock")
              :usage nil
              :tool-calls (getf r :tool-calls nil))))))

;; -----------------------------------------------------------------------
;; 1. Subagent tool calls through the agent loop
;; -----------------------------------------------------------------------

(format t "-- 1. Subagent via tool dispatch --~%")
(clear-subagent-registry!)

;; Parent's mock: 3 turns
;; Turn 1: model calls spawn-subagent
;; Turn 2: model calls subagent-summary
;; Turn 3: model finishes
(let* ((ep (make-instance 'mock-endpoint
                          :queue (list
                                  ;; Turn 1: spawn a subagent
                                  (list :content nil
                                        :tool-calls (list
                                                     (list :id "call_1"
                                                           :name "spawn-subagent"
                                                           :arguments (list
                                                                        :goal "Say hello from the subagent")))
                                        :model "mock"
                                        :finish :tool-calls)
                                  ;; Turn 2: collect the result
                                  (list :content nil
                                        :tool-calls (list
                                                     (list :id "call_2"
                                                           :name "subagent-summary"
                                                           :arguments (list
                                                                        :handle-id "subagent-1")))
                                        :model "mock"
                                        :finish :tool-calls)
                                  ;; Turn 3: done
                                  (list :content "Done! The subagent said: hello from the subagent"
                                        :tool-calls nil
                                        :model "mock"
                                        :finish :stop))))
       (agent (sexpr.kernel:spawn :goal "orchestrator"
                                   :endpoint ep
                                   :name "orchestrator"
                                   :capabilities '(:fs-read :spawn :collect :inspect))))
  (format t "-- Run agent loop --~%")
  (sexpr.kernel:run-until-finished agent :max-steps 10)
  (format t "-- Final transcript (~a events) --~%"
          (sexpr.transcript:transcript-length
           (sexpr.kernel:agent-transcript agent)))
  (format t "~a" (sexpr.transcript:render-events
                  (sexpr.kernel:agent-transcript agent))))

;; -----------------------------------------------------------------------
;; 2. Subagent with custom endpoint via the agent loop
;; -----------------------------------------------------------------------

(format t "~%-- 2. Subagent with separate endpoint --~%")
(clear-subagent-registry!)

;; Parent: spawn-subagent, subagent-summary, finish
;; Child: one turn that says "I'm a specialized worker"
(let* ((parent-ep (make-instance 'mock-endpoint
                                 :queue (list
                                         (list :content nil
                                               :tool-calls (list
                                                            (list :id "c1"
                                                                  :name "spawn-subagent"
                                                                  :arguments (list
                                                                               :goal "specialized task")))
                                               :model "mock"
                                               :finish :tool-calls)
                                         (list :content nil
                                               :tool-calls (list
                                                            (list :id "c2"
                                                                  :name "subagent-summary"
                                                                  :arguments (list
                                                                               :handle-id "subagent-1")))
                                               :model "mock"
                                               :finish :tool-calls)
                                         (list :content "Got the result: I'm a specialized worker"
                                               :tool-calls nil
                                               :model "mock"
                                               :finish :stop))))
       (child-ep (make-instance 'mock-endpoint
                                :queue (list
                                        (list :content "I'm a specialized worker"
                                              :tool-calls nil
                                              :model "child-mock"
                                              :finish :stop))))
       (agent (sexpr.kernel:spawn :goal "specialist orchestrator"
                                   :endpoint parent-ep
                                   :name "orch"
                                   :capabilities '(:fs-read :spawn :collect :inspect)))
       ;; Override spawn-subagent to use child-ep
       ;; (The tool dispatch can't pass an endpoint object, so we
       ;; monkey-patch the tool function for this demo.)
       old-spawn-fn)
  (let ((record (sexpr.tools:find-tool "spawn-subagent")))
    (setf old-spawn-fn (getf record :symbol))
    (setf (getf record :symbol)
          #'(lambda (goal &key capabilities endpoint)
              (let ((ep (or endpoint child-ep)))
                (sexpr.agents:spawn-subagent goal
                                             :capabilities capabilities
                                             :endpoint ep))))
    (unwind-protect
         (progn
           (format t "-- Run agent loop --~%")
           (sexpr.kernel:run-until-finished agent :max-steps 10)
           (format t "-- Final transcript (~a events) --~%"
                   (sexpr.transcript:transcript-length
                    (sexpr.kernel:agent-transcript agent)))
           (format t "~a" (sexpr.transcript:render-events
                           (sexpr.kernel:agent-transcript agent))))
      (setf (getf record :symbol) old-spawn-fn))))

;; -----------------------------------------------------------------------
;; 3. Full chat loop with subagent tool calls
;; -----------------------------------------------------------------------

(format t "~%-- 3. Chat loop with /agents command --~%")
(clear-subagent-registry!)

(let* ((ep (make-instance 'mock-endpoint
                          :queue (list
                                  ;; User says "hello" → model spawns a worker
                                  (list :content nil
                                        :tool-calls (list
                                                     (list :id "chat_1"
                                                           :name "spawn-subagent"
                                                           :arguments (list
                                                                        :goal "greet the user")))
                                        :model "mock"
                                        :finish :tool-calls)
                                  ;; Model collects result
                                  (list :content nil
                                        :tool-calls (list
                                                     (list :id "chat_2"
                                                           :name "subagent-summary"
                                                           :arguments (list
                                                                        :handle-id "subagent-1")))
                                        :model "mock"
                                        :finish :tool-calls)
                                  ;; Model finishes with greeting
                                  (list :content "Hello! The subagent greeted you."
                                        :tool-calls nil
                                        :model "mock"
                                        :finish :stop))))
       (child-ep (make-instance 'mock-endpoint
                                :queue (list
                                        (list :content "Hello from the worker!"
                                              :tool-calls nil
                                              :model "child-mock"
                                              :finish :stop))))
       old-spawn-fn)
  (let ((record (sexpr.tools:find-tool "spawn-subagent")))
    (setf old-spawn-fn (getf record :symbol))
    (setf (getf record :symbol)
          #'(lambda (goal &key capabilities endpoint)
              (let ((ep (or endpoint child-ep)))
                (sexpr.agents:spawn-subagent goal
                                             :capabilities capabilities
                                             :endpoint ep))))
    (unwind-protect
         (let ((output (make-string-output-stream)))
           (sexpr.cli:chat :goal "chat agent"
                           :endpoint ep
                           :input (make-string-input-stream "hello")
                           :output output
                           :max-steps 10
                           :capabilities '(:fs-read :spawn :collect :inspect))
           (format t "-- Chat output --~%")
           (format t "~a" (get-output-stream-string output)))
      (setf (getf record :symbol) old-spawn-fn))))

(format t "~%=== done ===~%")
