;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.kernel — the agent loop.
;;;;
;;;; DESIGN (notes/sexpr.md §9): an agent has a name, a goal, a transcript, a
;;;; budget and a capability set, and runs a loop: ask the model, fold the
;;;; answer into the transcript, repeat until the model finishes.
;;;;
;;;; BOUNDARY: this file calls sexpr.provider:provider-call by QUALIFIED name
;;;; and never imports :sexpr.provider into its package. There is exactly one
;;;; seam to the model (invariants #1 and #3), and it is visible right here.
;;;; Tool execution, approvals (§5) and capability enforcement are deferred.

(in-package :sexpr.kernel)

;;;; --- budget ---------------------------------------------------------
;;;;
;;;; DESIGN (notes/sexpr.md §2): a budget is a first-class object on an agent.
;;;; In this milestone budgets are *recorded but not enforced* — enforcement is
;;;; a later milestone. The slots are here now so that milestone fills in policy
;;;; instead of reshaping the agent class.

(defclass budget ()
  ((tokens
    :initarg :tokens
    :accessor budget-tokens
    :type (unsigned-byte 64)
    :documentation "Token ceiling, or most-positive-fixnum when unlimited.")
   (seconds
    :initarg :seconds
    :accessor budget-seconds
    :type (unsigned-byte 64)
    :documentation "Wall-clock ceiling in seconds, or most-positive-fixnum."))
  (:documentation "A cost ceiling on an agent. Not enforced in this milestone."))
(export 'budget)

(defun make-budget (&key (tokens most-positive-fixnum)
                         (seconds most-positive-fixnum))
  "Return a BUDGET.

Generous by default: nothing is enforced this milestone, so an unset ceiling
means 'no limit yet'. A later milestone turns these numbers into policy."
  (make-instance 'budget :tokens tokens :seconds seconds))
(export 'make-budget)

(defun unlimited-p (budget &key (kind :tokens))
  "Return T when the budget has no ceiling on KIND (:tokens or :seconds)."
  (case kind
    (:tokens (= (budget-tokens budget) most-positive-fixnum))
    (:seconds (= (budget-seconds budget) most-positive-fixnum))
    (otherwise (error "Unknown budget kind ~S (expected :tokens or :seconds)"
                      kind))))
(export 'unlimited-p)

;;;; --- agent ----------------------------------------------------------

(defclass agent ()
  ((name
    :initarg :name
    :accessor agent-name
    :type string
    :initform "agent"
    :documentation "A short identifier for humans and for logs.")
   (goal
    :initarg :goal
    :accessor agent-goal
    :type string
    :documentation "What this agent is here to accomplish.")
   (system
    :initarg :system
    :accessor agent-system
    :initform nil
    :documentation "The agent's system prompt, or NIL to fall back to the goal. Distinct from GOAL so chat can set a persona while autonomous agents still send their objective as the system prompt (R014).")
   (transcript
    :initarg :transcript
    :accessor agent-transcript
    :type transcript
    :documentation "The agent's conversation state — a sexpr.transcript.")
   (budget
    :initarg :budget
    :accessor agent-budget
    :type budget
    :documentation "The cost ceiling. Unenforced this milestone.")
   (capabilities
    :initarg :capabilities
    :accessor agent-capabilities
    :type list
    :initform '(:fs-read)
    :documentation "Granted capabilities. Advisory only this milestone — §5
approvals land later and will make these load-bearing.")
   (thread
    :initarg :thread
    :accessor agent-thread
    :documentation "The agent's thread, or NIL. Always NIL in this milestone:
spawning a thread is deferred, and agent-loop is called directly.")
   (endpoint
    :initarg :endpoint
    :accessor agent-endpoint
    :documentation "This agent's provider endpoint, or NIL. NIL means 'resolve
*MODEL-ENDPOINT* at call time' (invariant #4); a non-NIL value gives one agent
a different provider without touching the global."))
  (:documentation "An agent: a named goal with a transcript, a budget, a
capability set, and a provider endpoint.

This milestone gives the agent a body (the loop) and no thread."))
(export 'agent)

(defun make-agent (&key name goal system transcript budget capabilities thread endpoint)
  "Return a new agent.

Low-level constructor: supplies defaults for everything except GOAL, which is
required — an agent without a goal is not an agent. Use SPAWN for the common
case of an agent starting with an empty transcript."
  (unless goal
    (error "an agent requires a GOAL"))
  (make-instance 'agent
                 :name (or name "agent")
                 :goal goal
                 :system system
                 :transcript (or transcript (make-transcript))
                 :budget (or budget (make-budget))
                 :capabilities (or capabilities '(:fs-read))
                 :thread thread
                 :endpoint endpoint))
(export 'make-agent)

(defun spawn (&key name goal system endpoint capabilities budget)
  "Create and return a new agent with a fresh, empty transcript.

Does NOT start a thread: this milestone is single-threaded, and agent-loop is
called directly on the returned agent. The thread slot exists now so the
multi-agent milestone can fill it in without changing the class."
  (make-agent :name name
              :goal goal
              :system system
              :endpoint endpoint
              :capabilities capabilities
              :budget budget))
(export 'spawn)

;;;; --- the loop trio --------------------------------------------------
;;;;
;;;; DESIGN (notes/sexpr.md §9): model-step asks the model; integrate folds the
;;;; answer into the transcript; finished-p decides whether to stop. Keeping
;;;; them three separate, plain, redefinable functions means the loop is
;;;; inspectable: (trace sexpr.kernel:model-step) shows every model round trip.

(defun event-to-message (event)
  "Convert one transcript EVENT into a provider message plist.

Messages are the transport's vocabulary (:role/:content plists), so the
conversion lives in the kernel — the transport never sees a transcript object.
User events become :user, model events become :assistant, and result events
are folded back in as :user context so the model can see what a tool returned.

DEFERRED: this is the minimal renderer. The token-budgeted, presentation-aware
version (notes/sexpr.md §4, :view :model) is a later milestone; until then the
whole transcript is sent every turn, which is what compaction (§1.2) will fix."
  (case (event-type event)
    (:user (list :role "user" :content (event-content event)))
    (:model (list :role "assistant" :content (event-content event)))
    (:result
     (list :role "user"
           :content (format nil "Tool result: ~A" (event-value event))))
    (otherwise nil)))
(export 'event-to-message)

(defun transcript-to-messages (transcript)
  "Render TRANSCRIPT as the message list a provider expects, oldest first."
  (let ((messages nil))
    (dolist (event (events-list transcript))
      (let ((message (event-to-message event)))
        (when message
          (push message messages))))
    (nreverse messages)))
(export 'transcript-to-messages)

(defun model-step (agent)
  "Call the model with AGENT's current transcript and return a model event.

Calls sexpr.provider:provider-call — the only model entry point
(invariant #1) — with AGENT's endpoint, or NIL so the provider's resident
*MODEL-ENDPOINT* is resolved instead (invariant #4).

The agent's system prompt is sent as :system: agent-system when set, falling
back to agent-goal otherwise (R014), so NIL on the system slot stays the
meaningful 'use the goal as the system prompt' signal. The system prompt is
passed as :system, never appended to the transcript.

The provider's reply node (:content / :tool-calls / :model / :usage / :finish)
is copied straight into a sexpr.transcript:model-event. Tool calls are
RECORDED on the event but not executed in this milestone."
  (let ((node (sexpr.provider:provider-call
                (agent-endpoint agent)
                (transcript-to-messages (agent-transcript agent))
                :system (or (agent-system agent) (agent-goal agent)))))
    (make-model-event (getf node :content)
                      :tool-calls (getf node :tool-calls)
                      :model (getf node :model)
                      :usage (getf node :usage)
                      :finish (getf node :finish))))
(export 'model-step)

(defun integrate (agent event)
  "Append EVENT to AGENT's transcript and return AGENT.

The transcript is the state (§1.2): integrating a step is appending to it, and
nothing else. There is no separate 'apply' phase in this milestone because
there are no tools to run."
  (append-event (agent-transcript agent) event)
  agent)
(export 'integrate)

(defun finished-p (event)
  "Return T when EVENT carries a non-nil :finish reason.

The model says :stop when it is done and :length when it hit the token cap;
both end a turn. NIL means the model wanted to call tools, which in a real
agent is the start of a tool round — not in this milestone."
  (not (null (event-finish event))))
(export 'finished-p)

(defun run-until-finished (agent &key max-steps)
  "Run AGENT's loop: model-step, integrate, repeat until finished-p or
MAX-STEPS. Returns the transcript. With MAX-STEPS nil the loop is unbounded
(the contract agent-loop preserves); with a positive integer it stops after
that many model turns — the chat safety cap (R017)."
  (loop
     :with step-count = 0
     :for event = (model-step agent)
     :do (integrate agent event)
         (incf step-count)
         (when (or (finished-p event)
                   (and max-steps (>= step-count max-steps)))
           (return)))
  (agent-transcript agent))
(export 'run-until-finished)

(defun agent-loop (agent)
  "Run AGENT's loop to completion. Delegates to run-until-finished with no
max-steps, preserving the unbounded contract. Chat callers use
run-until-finished with :max-steps."
  (run-until-finished agent))
(export 'agent-loop)
