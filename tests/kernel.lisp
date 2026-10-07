;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/kernel.lisp — the agent loop.
;;;;
;;;; Scope: budget, agent shape, spawn, model-step, integrate, finished-p, and
;;;; the whole agent-loop closing against a STUB provider.
;;;;
;;;; The stub is a defmethod on sexpr.provider:provider-call specialized on a
;;;; stub-endpoint class. The kernel still calls provider-call only, so
;;;; invariant #1 holds in the test as it does in production: nothing here
;;;; touches cl-llm-provider or the network.

(in-package :sexpr-tests)

;;; --- the stub provider ----------------------------------------------

(defclass stub-endpoint ()
  ((responses
    :initarg :responses
    :accessor stub-responses
    :initform nil
    :documentation "Canned provider nodes, one per call, consumed in order.")
   (last-messages
    :initarg :last-messages
    :accessor stub-last-messages
    :initform nil
    :documentation "The message list the last call received, for inspection.")
   (call-count
    :initarg :call-count
    :accessor stub-call-count
    :initform 0
    :documentation "How many times this endpoint has been called.")
   (last-system
    :accessor stub-last-system
    :initform nil
    :documentation "The :system argument the last call received, for inspection.")
   (last-tools
    :initarg :last-tools
    :accessor stub-last-tools
    :initform nil
    :documentation "The :tools argument the last call received, for inspection."))
  (:documentation "A canned provider endpoint for tests."))

(defmethod sexpr.provider:provider-call ((endpoint stub-endpoint) messages
                                          &key system tools temperature max-tokens)
  (declare (ignore temperature max-tokens))
  (setf (stub-last-messages endpoint) messages)
  (setf (stub-last-system endpoint) system)
  (setf (stub-last-tools endpoint) tools)
  (incf (stub-call-count endpoint))
  (let ((next (first (stub-responses endpoint)))
        (rest (rest (stub-responses endpoint))))
    (setf (stub-responses endpoint) rest)
    (if next
        next
        (error "stub-endpoint ~S exhausted" endpoint))))

;;; --- budget ---------------------------------------------------------

(rove:deftest budget-defaults-are-unlimited
  (let ((budget (make-budget)))
    (ok (= (budget-tokens budget) most-positive-fixnum)
        "the token ceiling defaults to unlimited")
    (ok (= (budget-seconds budget) most-positive-fixnum)
        "the time ceiling defaults to unlimited")
    (ok (unlimited-p budget :kind :tokens) "unlimited-p agrees on tokens")
    (ok (unlimited-p budget :kind :seconds) "unlimited-p agrees on seconds")))

(rove:deftest budget-holds-configured-values
  (let ((budget (make-budget :tokens 5000 :seconds 30)))
    (ok (= (budget-tokens budget) 5000) "a token ceiling holds")
    (ok (= (budget-seconds budget) 30) "a time ceiling holds")
    (ok (not (unlimited-p budget :kind :tokens)) "a configured token ceiling is not unlimited")
    (ok (not (unlimited-p budget :kind :seconds)) "a configured time ceiling is not unlimited")))

(rove:deftest unlimited-p-rejects-unknown-kinds
  (ok (signals (unlimited-p (make-budget) :kind :nonsense))
      "an unknown budget kind is refused rather than silently returning nil"))

;;; --- agent shape and spawn -----------------------------------------

(rove:deftest spawn-returns-an-agent-with-an-empty-transcript
  (let ((agent (spawn :goal "fix the bug" :name "fixer")))
    (ok (typep agent 'agent) "spawn returns an agent")
    (ok (empty-p (agent-transcript agent)) "its transcript is empty")
    (ok (string= (agent-name agent) "fixer") "the name is set")
    (ok (string= (agent-goal agent) "fix the bug") "the goal is set")
    (ok (null (agent-thread agent)) "there is no thread in this milestone")
    (ok (null (agent-endpoint agent)) "there is no per-agent endpoint by default")
    (ok (equal (agent-capabilities agent) '(:fs-read :spawn)) "capabilities default to (:fs-read :spawn)")
    (ok (unlimited-p (agent-budget agent) :kind :tokens) "the budget is unlimited by default")))

(rove:deftest spawn-holds-a-per-agent-endpoint
  (let* ((stub (make-instance 'stub-endpoint))
         (agent (spawn :goal "g" :endpoint stub)))
    (ok (eq (agent-endpoint agent) stub) "the endpoint is held on the agent")))

(rove:deftest make-agent-requires-a-goal
  (ok (signals (make-agent)) "make-agent requires :goal")
  (ok (signals (spawn)) "spawn requires :goal too"))

;;; --- transcript to messages ----------------------------------------

(rove:deftest event-to-message-maps-roles
  (ok (equal (event-to-message (make-user-event "hello"))
             (list :role "user" :content "hello"))
      "a user event becomes a :user message")
  (ok (equal (event-to-message (make-model-event "hi"))
             (list :role "assistant" :content "hi"))
      "a model event becomes an :assistant message")
  (ok (equal (event-to-message (make-result-event "42"))
             (list :role "user" :content "Tool result: 42"))
      "a result event is folded back as :user context"))

(rove:deftest transcript-to-messages-preserves-order
  (let ((tr (make-transcript)))
    (progn
      (append-event tr (make-user-event "a"))
      (append-event tr (make-model-event "b" :finish :stop))
      (append-event tr (make-user-event "c")))
    (ok (equal (transcript-to-messages tr)
               (list (list :role "user" :content "a")
                     (list :role "assistant" :content "b")
                     (list :role "user" :content "c")))
        "messages are rendered oldest first")))

;;; --- model-step, integrate, finished-p -----------------------------

(rove:deftest model-step-records-the-node-as-a-model-event
  (let* ((stub (make-instance
                 'stub-endpoint
                 :responses (list (list :content "done"
                                        :tool-calls '((:id "1" :name "edit-file"
                                                             :arguments "x"))
                                        :model "stub-1"
                                        :usage (list :input-tokens 3 :output-tokens 5)
                                        :finish :stop))))
         (event (model-step (spawn :goal "g" :endpoint stub))))
    (ok (eq (event-type event) :model) "it is a model event")
    (ok (string= (event-content event) "done") "content is carried over")
    (ok (equal (event-model event) "stub-1") "the model id is carried over")
    (ok (eq (event-finish event) :stop) "the finish reason is carried over")
    (ok (equal (event-usage event) (list :input-tokens 3 :output-tokens 5))
        "the usage plist is carried over")
    (ok (= (length (event-tool-calls event)) 1)
        "tool calls are RECORDED on the event (execution deferred)")))

(rove:deftest model-step-sends-the-transcript-as-messages
  (let ((stub (make-instance 'stub-endpoint
                             :responses (list (list :content "ok" :finish :stop)))))
    (let ((agent (spawn :goal "g" :endpoint stub)))
      (progn
        (integrate agent (make-user-event "fix the bug"))
        (integrate agent (make-model-event "thinking..." :model "stub-1")))
      (model-step agent)
      (ok (= (length (stub-last-messages stub)) 2) "two messages were sent")
      (ok (equal (first (stub-last-messages stub))
                 (list :role "user" :content "fix the bug"))
          "the first message is the user turn")
      (ok (equal (second (stub-last-messages stub))
                 (list :role "assistant" :content "thinking..."))
          "the second message is the model turn"))))

(rove:deftest model-step-sends-the-goal-as-system-by-default
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "ok" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub)))
    (model-step agent)
    (ok (string= (stub-last-system stub) "g")
        "with no :system set, the goal is sent as :system (goal fallback)")
    (ok (null (agent-system agent))
        "agent-system reads nil when no persona was set")))

(rove:deftest model-step-sends-an-explicit-system-prompt
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "ok" :finish :stop))))
         (agent (spawn :goal "g" :system "persona" :endpoint stub)))
    (model-step agent)
    (ok (string= (stub-last-system stub) "persona")
        "an explicit :system prompt is sent as :system, not the goal")
    (ok (string= (agent-system agent) "persona")
        "agent-system reads the persona back")))

(rove:deftest integrate-appends-to-the-transcript
  (let ((agent (spawn :goal "g"))
        (event (make-model-event "hi")))
    (let ((result (integrate agent event)))
      (ok (eq result agent) "integrate returns the agent")
      (ok (= (transcript-length (agent-transcript agent)) 1) "one event appended")
      (ok (equalp (aref (transcript-events (agent-transcript agent)) 0) event)
          "that event is the one appended"))))

(rove:deftest finished-p-checks-the-finish-reason
  (ok (finished-p (make-model-event "done" :finish :stop)) ":stop finishes")
  (ok (finished-p (make-model-event "done" :finish :length)) ":length finishes")
  (ok (not (finished-p (make-model-event "thinking"))) "nil does not finish")
  (ok (not (finished-p (make-user-event "hello"))) "a user event does not finish"))

;;; --- the loop ------------------------------------------------------

(rove:deftest agent-loop-terminates-and-records-the-model-event
  (let* ((stub (make-instance
                 'stub-endpoint
                 :responses (list (list :content "I fixed the bug."
                                        :model "stub-1"
                                        :usage (list :input-tokens 3
                                                     :output-tokens 5)
                                        :finish :stop))))
         (agent (spawn :goal "fix the bug" :endpoint stub)))
    (let ((tr (agent-loop agent)))
      (ok (= (transcript-length tr) 1) "one model event was recorded")
      (ok (eq (event-type (aref (transcript-events tr) 0)) :model)
          "the event is a model event")
      (ok (string= (event-content (aref (transcript-events tr) 0)) "I fixed the bug.")
          "the model's content is recorded")
      (ok (eq (event-model (aref (transcript-events tr) 0)) "stub-1")
          "the model id is recorded")
      (ok (eq (event-finish (aref (transcript-events tr) 0)) :stop)
          "the finish reason is recorded")
      (ok (equal (event-usage (aref (transcript-events tr) 0))
                 (list :input-tokens 3 :output-tokens 5))
          "the usage plist is recorded")
      (ok (eq tr (agent-transcript agent))
          "agent-loop returns the agent's transcript")
      (ok (= (stub-call-count stub) 1) "the model was called exactly once"))))

(rove:deftest agent-loop-sends-each-turn-back-to-the-model
  (let* ((stub (make-instance
                 'stub-endpoint
                 ;; The first reply does not finish, so the loop must take a
                 ;; second turn; the second reply ends it.
                 :responses (list (list :content "let me look")
                                  (list :content "done" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub)))
    (progn
      (integrate agent (make-user-event "fix the bug"))
      (agent-loop agent))
    (ok (= (stub-call-count stub) 2) "the loop took a second turn")
    (ok (equal (stub-last-messages stub)
               (list (list :role "user" :content "fix the bug")
                     (list :role "assistant" :content "let me look")))
        "the second call included the model's own previous reply")))

(rove:deftest agent-loop-keeps-the-goal-outside-the-transcript
  (let ((agent (spawn :goal "fix the bug in parser.lisp"
                      :endpoint (make-instance
                                  'stub-endpoint
                                  :responses (list (list :content "ok" :finish :stop))))))
    (agent-loop agent)
    (ok (= (transcript-length (agent-transcript agent)) 1) "only the model turn is recorded")
    (ok (string= (agent-goal agent) "fix the bug in parser.lisp") "the goal is still on the agent")))

(rove:deftest run-until-finished-respects-max-steps
  (let* ((stub (make-instance
                 'stub-endpoint
                 ;; Ten never-finishing replies; max-steps must stop the loop.
                 :responses (loop :repeat 10 :collect (list :content "thinking"))))
         (agent (spawn :goal "g" :endpoint stub)))
    (let ((tr (run-until-finished agent :max-steps 3)))
      (ok (= (stub-call-count stub) 3)
          "max-steps 3 stops the loop after exactly three model calls")
      (ok (= (transcript-length tr) 3)
          "the transcript holds exactly three events")
      (ok (eq tr (agent-transcript agent))
          "run-until-finished returns the agent's transcript"))))

;;; --- tool rounds ---------------------------------------------------
;;; R021: the loop acts on a tool round. R019/R020: the gate refuses before a
;;; tool body runs. Two notes on these groups:
;
;;;; Each one starts with reset-tool-registry! — the registry is process-wide,
;;;; so a tool registered by an earlier group would otherwise leak in and change
;;;; what the model is told it can call.
;
;;;; Tool names are unique per group. define-tool emits a defun, so a repeated
;;;; name would make a later group's definition replace an earlier group's under
;;;; a record that still holds the first group's schema.
;
;;;; Nothing here reaches a model server: every reply comes from stub-endpoint.

(rove:deftest finished-p-and-tool-round-p-agree-on-a-tool-round
  (let* ((calls (list (list :id "1" :name "get-weather"
                            :arguments (list :city "Paris"))))
         ;; :finish :tool-calls alongside :tool-calls is exactly what an
         ;; OpenAI-compatible server returns; keying finished-p on :finish
         ;; alone made the loop return before dispatch ever ran.
         (event (make-model-event "" :tool-calls calls :finish :tool-calls)))
    (ok (tool-round-p event) "tool-round-p sees the non-empty :tool-calls list")
    (ok (not (finished-p event))
        "finished-p stays nil for a tool round despite :finish :tool-calls")
    (ok (tool-round-p (make-model-event "thinking" :tool-calls calls))
        "tool-round-p does not depend on :finish at all")
    (ok (not (tool-round-p (make-model-event "thinking")))
        "a reply with no tool calls is not a tool round")
    (ok (not (tool-round-p (make-model-event "thinking" :tool-calls '())))
        "an empty :tool-calls list is not a tool round")))

(rove:deftest model-step-passes-the-tool-schema-list-to-the-provider
  (reset-tool-registry!)
  (define-tool lookup-things (path)
    "Look up PATH."
    path)
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "ok" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub)))
    (model-step agent)
    (ok (not (null (stub-last-tools stub))) ":tools was actually sent")
    (ok (equal (stub-last-tools stub) (tool-schema-list))
        ":tools carries the derived sexpr schemas, not the transport's type")))

(rove:deftest a-tool-round-dispatches-and-folds-back-as-a-user-message
  (reset-tool-registry!)
  (define-tool add-one-to (n)
    "Add one to N."
    :types ((n . :integer))
    (1+ n))
  (let* ((stub (make-instance
                 'stub-endpoint
                 :responses (list
                             (list :content ""
                                   :finish :tool-calls
                                   :tool-calls (list
                                               (list :id "1"
                                                     :name "add-one-to"
                                                     :arguments (list :n 5))))
                             (list :content "done" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub))
         (tr (run-until-finished agent)))
      (ok (= (stub-call-count stub) 2)
          "the tool round took a follow-up turn, so the loop did not stop early")
      (ok (= (transcript-length tr) 3)
          "a model turn, a result event, then the final model turn")
      (ok (eq (event-type (aref (transcript-events tr) 0)) :model)
          "the first event is the model's tool round")
      (let ((result (aref (transcript-events tr) 1)))
        (ok (eq (event-type result) :result) "the second event is a result event")
        (ok (eq (event-value result) 6) "it carries the live object")
        (ok (string= (event-text result) "6")
            "it carries the printed projection, recorded at record time"))
      (ok (eq (event-type (aref (transcript-events tr) 2)) :model)
          "the third event is the final model turn")
      (ok (equal (stub-last-messages stub)
                 (list (list :role "assistant" :content "")
                       (list :role "user" :content "Tool result: 6")))
          "the result folded back as a :user message on the next call")
      (ok (equal (event-to-message (aref (transcript-events tr) 1))
                 (list :role "user" :content "Tool result: 6"))
          "event-to-message renders the :text projection for a result event")))

(rove:deftest a-tool-body-that-signals-becomes-a-caught-result-and-the-loop-continues
  (reset-tool-registry!)
  (define-tool explode-quietly (path)
    "Always signals."
    (error "the disk is on fire"))
  (let* ((stub (make-instance
                 'stub-endpoint
                 :responses (list
                             (list :content ""
                                   :finish :tool-calls
                                   :tool-calls (list
                                               (list :id "1"
                                                     :name "explode-quietly"
                                                     :arguments (list :path "/x"))))
                             (list :content "recovered" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub)))
    (let ((tr (run-until-finished agent)))
      (ok (= (stub-call-count stub) 2)
          "the loop survived the tool body signal — nothing propagated")
      (let ((result (aref (transcript-events tr) 1)))
        (ok (eq (event-type result) :result)
            "the failure is a result event, not an escaping exception")
        (ok (equal (event-value result)
                   '(:tool "explode-quietly" :reason :body-error
                     :detail "the disk is on fire"))
            "the :value is a structured failure plist")
        (ok (search "explode-quietly" (event-text result))
            "the :text names the offending tool")
        (ok (search "the disk is on fire" (event-text result))
            "the :text carries the error text for the model to read")))))

(rove:deftest a-capability-denial-records-a-refusal-and-the-loop-continues
  (reset-tool-registry!)
  (define-tool run-shell-command (cmd)
    "Run a shell command."
    :capability :lisp-eval
    cmd)
  (let* ((stub (make-instance
                 'stub-endpoint
                 :responses (list
                             (list :content ""
                                   :finish :tool-calls
                                   :tool-calls (list
                                               (list :id "1"
                                                     :name "run-shell-command"
                                                     :arguments (list :cmd "ls"))))
                             (list :content "denied" :finish :stop))))
         ;; The agent is granted :fs-read only, so the :lisp-eval gate refuses.
         (agent (spawn :goal "g" :endpoint stub
                       :capabilities '(:fs-read))))
    (let ((tr (run-until-finished agent)))
      (ok (= (stub-call-count stub) 2) "the loop survived the refusal")
      (let ((result (aref (transcript-events tr) 1)))
        (ok (eq (event-type result) :result) "the refusal is a result event")
        (ok (eq (getf (event-value result) :reason) :capability-denied)
            "the :value plist carries :capability-denied")
        (ok (string= (getf (event-value result) :tool) "run-shell-command")
            "the :value plist names the refused tool")
        (ok (search "CAPABILITY-DENIED" (event-text result))
            "the :text names the reason")
        (ok (search "lisp-eval" (event-text result))
            "the :text names the capability that was required")))))

(rove:deftest an-unknown-tool-records-a-result-naming-the-available-tools
  (reset-tool-registry!)
  (define-tool the-only-tool (path)
    "The only registered tool."
    path)
  (let* ((stub (make-instance
                 'stub-endpoint
                 :responses (list
                             (list :content ""
                                   :finish :tool-calls
                                   :tool-calls (list
                                               (list :id "1"
                                                     :name "no-such-tool"
                                                     :arguments nil)))
                             (list :content "ok" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub)))
    (let ((tr (run-until-finished agent)))
      (let ((result (aref (transcript-events tr) 1)))
        (ok (eq (getf (event-value result) :reason) :unknown-tool)
            "the :value plist carries :unknown-tool")
        (ok (string= (getf (event-value result) :tool) "no-such-tool")
            "the :value plist names the unknown tool")
        (ok (equal (getf (event-value result) :detail) (tool-names))
            "the :detail is the list of registered tool names")
        (ok (search "the-only-tool" (event-text result))
            "the :text names an available tool so the model can retry")))))

(rove:deftest a-tool-round-at-max-steps-dispatches-and-then-stops
  (reset-tool-registry!)
  (define-tool read-some-file (path)
    "Read PATH."
    path)
  (let* ((stub (make-instance
                 'stub-endpoint
                 ;; Only ONE reply: a tool round. If the loop asked the model
                 ;; again after the cap, the stub would signal "exhausted" and
                 ;; this test would fail loudly.
                 :responses (list
                             (list :content ""
                                   :finish :tool-calls
                                   :tool-calls (list
                                               (list :id "1"
                                                     :name "read-some-file"
                                                     :arguments (list :path "/x")))))))
         (agent (spawn :goal "g" :endpoint stub)))
    (let ((tr (run-until-finished agent :max-steps 1)))
      (ok (= (stub-call-count stub) 1)
          "max-steps 1 made exactly one model call — no follow-up turn")
      (ok (= (transcript-length tr) 2)
          "the tool round dispatched BEFORE the cap stopped the loop")
      (ok (eq (event-type (aref (transcript-events tr) 0)) :model)
          "the first event is the model's tool round")
      (let ((result (aref (transcript-events tr) 1)))
        (ok (eq (event-type result) :result) "the second event is the dispatched result")
        (ok (string= (event-value result) "/x") "the tool's return value is recorded")
        (ok (string= (event-text result) "/x") "and its projection")))))

(rove:deftest event-to-message-falls-back-to-the-value-for-a-result-without-text
  "A result event holding only :value (no recorded :text) still renders." (let ((event (list :type :result :value 42)))
    (ok (equal (event-to-message event)
               (list :role "user" :content "Tool result: 42"))
        "event-to-message falls back to the printed :value")))
