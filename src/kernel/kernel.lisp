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
;;;; The tool registry (:sexpr.tools) is reached the same way — by qualified
;;;; call, never :use'd — so the kernel names no transport type at all: the
;;;; model and the tools are both ordinary qualified calls into their own
;;;; packages, and :sexpr.tools stays free of knowledge of the kernel (D009,
;;;; the one-way dependency kernel -> tools).
;;;;
;;;; Approvals (§5) are deferred: the capability gate in :sexpr.tools already
;;;; refuses a denied tool, but a condition-and-restart approval flow is a
;;;; later milestone (R027).

(in-package :sexpr.kernel)

;;;; --- current agent context ------------------------------------------
;;;;
;;;; Bound during agent-loop so that spawned subagents can inherit from the
;;;; current agent (capabilities, endpoint, parent).

(defvar *current-agent* nil
  "The currently running agent, or NIL. Bound during agent-loop so that
spawned subagents can inherit from the current agent (capabilities,
endpoint, parent).")

;;;; --- event bus ------------------------------------------------------
;;;;
;;;; A thread-safe hash table mapping agent-id strings to listener function
;;;; lists. Agents run in threads, so the lock is essential: a listener may
;;;; subscribe or unsubscribe while another thread is emitting.

(defvar *event-bus* (make-hash-table :test 'equal)
  "Hash table: agent-id string → list of listener functions.")
(defvar *event-bus-lock* (sb-thread:make-mutex :name "event-bus")
  "Lock protecting *event-bus* against concurrent access.")

(defun emit-event (agent-id event)
  "Call every listener registered under AGENT-ID with EVENT. Listeners are
invoked in registration order. The lock is held only during the snapshot of
the listener list, not during each call, so a listener that signals does not
starve other listeners." (sb-thread:with-mutex (*event-bus-lock*)
    (let ((listeners (gethash agent-id *event-bus*)))
      (dolist (listener listeners)
        (funcall listener event)))))
(export 'emit-event)

(defun subscribe-event-bus (agent-id listener)
  "Register LISTENER (a function of one argument) under AGENT-ID. Subsequent
calls to emit-event on that id will invoke LISTENER. Returns LISTENER for
convenience. Thread-safe." (sb-thread:with-mutex (*event-bus-lock*)
    (setf (gethash agent-id *event-bus*)
          (cons listener (gethash agent-id *event-bus*)))
    listener))
(export 'subscribe-event-bus)

(defun unsubscribe-event-bus (agent-id listener)
  "Remove LISTENER from the listener list under AGENT-ID. If LISTENER is not
registered, this is a no-op. Thread-safe." (sb-thread:with-mutex (*event-bus-lock*)
    (setf (gethash agent-id *event-bus*)
          (remove listener (gethash agent-id *event-bus*)))))
(export 'unsubscribe-event-bus)

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
    :initform '(:fs-read :spawn)
    :documentation "Granted capabilities. Advisory only this milestone — §5
approvals land later and will make these load-bearing. :spawn is in the
default set so every agent can delegate subtasks (D013).")
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
a different provider without touching the global.")
   (parent
    :initarg :parent
    :accessor agent-parent
    :initform nil
    :documentation "The parent agent, or NIL for the root agent. Used for
process tree views and capability inheritance.")
   (status
    :accessor agent-status
    :initform :running
    :documentation "One of :running, :finished, :failed, :killed.")
   (children
    :accessor agent-child-list
    :initform nil
    :type list
    :documentation "List of direct child agent objects spawned by this agent."))
  (:documentation "An agent: a named goal with a transcript, a budget, a
capability set, and a provider endpoint.

This milestone gives the agent a body (the loop) and no thread."))
(export 'agent)

(defun make-agent (&key name goal system transcript budget capabilities thread endpoint parent)
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
                 :capabilities (or capabilities '(:fs-read :spawn))
                 :thread thread
                 :endpoint endpoint
                 :parent parent))
(export 'make-agent)

(defun spawn (&key name goal system endpoint capabilities budget parent)
  "Create and return a new agent with a fresh, empty transcript.

Does NOT start a thread: this milestone is single-threaded, and agent-loop is
called directly on the returned agent. The thread slot exists now so the
multi-agent milestone can fill it in without changing the class."
  (make-agent :name name
              :goal goal
              :system system
              :endpoint endpoint
              :capabilities capabilities
              :budget budget
              :parent parent))
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
           :content (format nil "Tool result: ~A"
                            (or (event-text event) (event-value event)))))
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
is copied straight into a sexpr.transcript:model-event. The schemas of every
registered tool are passed as :tools — sexpr.tools:tool-schema-list, a
qualified call — so the model sees what it can actually call. Dispatching the
calls the model returns is run-until-finished's job, not this one's."
  (let ((node (sexpr.provider:provider-call
                (agent-endpoint agent)
                (transcript-to-messages (agent-transcript agent))
                :system (or (agent-system agent) (agent-goal agent))
                :tools (sexpr.tools:tool-schema-list))))
    (make-model-event (getf node :content)
                      :tool-calls (getf node :tool-calls)
                      :model (getf node :model)
                      :usage (getf node :usage)
                      :finish (getf node :finish))))
(export 'model-step)

;;;; --- streaming model step (D017) -----------------------------------
;;;;
;;;; D017 places the streaming loop in the KERNEL, not at the provider seam:
;;;; the kernel is the only package that calls cl-llm-provider:complete-stream,
;;;; and provider-call stays the only NON-streaming entry point. The loop
;;;; pulls chunks via cl-llm-provider:read-stream-chunk and emits each
;;;; chunk-delta to the event bus under the agent's name, so the push channel
;;;; (S02) can forward fragments to the TUI without polling the transcript
;;;; (D015). The final event is built from
;;;; cl-llm-provider:stream-accumulated-content and
;;;; cl-llm-provider:stream-tool-calls — the same plist shape model-step
;;;; returns. Tool schemas are translated through
;;;; sexpr.provider:translate-tool-schemas (the same construction site
;;;; provider-call uses) so the transport's tool-definition type stays behind
;;;; the provider seam; the endpoint resolves through
;;;; sexpr.provider:*model-endpoint* exactly as provider-call resolves it.
;;;; :model is NIL here because the transport's stream-model reader is not
;;;; exported; :finish and :usage come from the final chunk.

(defun %stream-chunk-tokens (chunk tokens-used)
  "Return TOKENS-USED advanced by CHUNK's token contribution.

Reads cl-llm-provider:chunk-usage: when it carries a positive :total-tokens
(the provider's cumulative count) the larger of that and TOKENS-USED wins.
Otherwise falls back to a character proxy — one token per four delta
characters, at least one — because usage typically arrives only on the final
chunk (F2), so a usage-only check would never trip mid-stream. The proxy is
approximate and documented, not silent."
  (let ((reported (getf (cl-llm-provider:chunk-usage chunk) :total-tokens)))
    (if (and (integerp reported) (plusp reported))
        (max tokens-used reported)
        (let ((delta (cl-llm-provider:chunk-delta chunk)))
          (+ tokens-used (max 1 (floor (length (or delta "")) 4)))))))

(defun model-step-streaming (agent)
  "Streaming variant of model-step (D017): call the transport's streaming
endpoint, emit each chunk to the event bus as a :delta event, enforce the
agent's token budget, and return a model event with the same shape as
model-step.

The kernel is the only package that calls cl-llm-provider:complete-stream
(D017); provider-call stays the only NON-streaming entry point. Each chunk's
delta is emitted to the event bus under (agent-name agent) so the push
channel can forward fragments without polling (D015). The final event is
built from stream-accumulated-content and stream-tool-calls — the same
plist shape (:content / :tool-calls / :model / :usage / :finish) model-step
returns. Tool schemas are translated through sexpr.provider:translate-tool-
schemas; the endpoint resolves through sexpr.provider:*model-endpoint*,
both by qualified call so the transport's types stay behind the provider
seam. :model is NIL (the transport's stream-model reader is not exported);
:finish and :usage come from the final chunk.

BUDGET: cumulative tokens are compared against (agent-budget agent) after
each chunk. When the ceiling is crossed the stream is closed through the
provider's own state machine and the loop stops, emitting a :budget-exceeded
bus event and marking the returned event with :budget-exceeded t. A
provider-side interruption (cl-llm-provider:stream-interrupted-error) is
converted into the same clean abort by invoking the provider's exported
ABORT-STREAM restart; that path marks the returned event with :interrupted t.
ABORT-STREAM is a RESTART NAME, not a function — never call it."
  (let* ((endpoint (or (agent-endpoint agent)
                       sexpr.provider:*model-endpoint*
                       (setf sexpr.provider:*model-endpoint*
                             (sexpr.provider:make-default-provider))))
         (tools (sexpr.provider:translate-tool-schemas
                 (sexpr.tools:tool-schema-list)))
         (agent-id (agent-name agent))
         (budget (agent-budget agent))
         (stream (cl-llm-provider:complete-stream
                   (transcript-to-messages (agent-transcript agent))
                   :provider endpoint
                   :system (or (agent-system agent) (agent-goal agent))
                   :tools tools))
         (last-chunk nil)
         (tokens-used 0)
         (budget-exceeded-p nil)
         (interrupted-p nil))
    ;; A provider-detected interruption is converted to the provider's own
    ;; clean abort: the restart is established by read-stream-chunk's
    ;; restart-case while the condition propagates, so this caller-bound
    ;; handler is in scope, and invoking it unwinds to the restart body, which
    ;; sets stream-state :closed and returns NIL so the loop ends cleanly.
    (handler-bind ((cl-llm-provider:stream-interrupted-error
                    (lambda (c)
                      (declare (ignore c))
                      (setf interrupted-p t)
                      (invoke-restart 'cl-llm-provider:abort-stream))))
      (loop :for chunk = (cl-llm-provider:read-stream-chunk stream)
            :while chunk
            :do (setf last-chunk chunk)
                (setf tokens-used (%stream-chunk-tokens chunk tokens-used))
                (emit-event agent-id
                            (list :type :delta
                                  :agent-id agent-id
                                  :chunk-delta (cl-llm-provider:chunk-delta chunk)))
                (when (and (not (unlimited-p budget :kind :tokens))
                           (> tokens-used (budget-tokens budget)))
                  ;; Budget abort (F1 half 1): close the stream through the
                  ;; provider's state machine and break explicitly, so the abort
                  ;; does not depend on the stream honoring stream-state on the
                  ;; next pull.
                  (setf budget-exceeded-p t)
                  (setf (cl-llm-provider:stream-state stream) :closed)
                  (emit-event agent-id
                              (list :type :budget-exceeded
                                    :agent-id agent-id
                                    :tokens-used tokens-used
                                    :limit (budget-tokens budget)))
                  (return))))
    (append
     (make-model-event
      (cl-llm-provider:stream-accumulated-content stream)
      :tool-calls (mapcar (lambda (tc)
                            (list :id (cl-llm-provider:tool-call-id tc)
                                  :name (cl-llm-provider:tool-call-name tc)
                                  :arguments (cl-llm-provider:tool-call-arguments tc)))
                          (cl-llm-provider:stream-tool-calls stream))
      :model nil
      :usage (when last-chunk (cl-llm-provider:chunk-usage last-chunk))
      :finish (when last-chunk (cl-llm-provider:chunk-finish-reason last-chunk)))
     (when budget-exceeded-p (list :budget-exceeded t))
     (when interrupted-p (list :interrupted t)))))
(export 'model-step-streaming)

(defun integrate (agent event)
  "Append EVENT to AGENT's transcript and return AGENT.

The transcript is the state (§1.2): integrating a step is appending to it, and
nothing else. There is no separate 'apply' phase in this milestone because
there are no tools to run."
  (append-event (agent-transcript agent) event)
  agent)
(export 'integrate)

(defun tool-round-p (event)
  "Return T when EVENT carries a non-empty :tool-calls list.

A tool round is the model asking to call tools. :finish is irrelevant — an
OpenAI-compatible server replies :finish :tool-calls alongside the calls, so
keying on :finish here would swallow every tool round before it dispatched."
  (not (null (event-tool-calls event))))
(export 'tool-round-p)

(defun finished-p (event)
  "Return T when EVENT carries a non-nil :finish reason and is not a tool round.

The model says :stop when it is done and :length when it hit the token cap;
both end a turn. A tool round is never finished, regardless of :finish:
finished-p used to return T for a :finish :tool-calls reply, which made
run-until-finished return before dispatch ever ran — the silent failure that
no existing test could see, because no stub reply carried tool calls."
  (and (not (null (event-finish event)))
       (not (tool-round-p event))))
(export 'finished-p)

(defun dispatch-tool-call (agent tool-call)
  "Execute one TOOL-CALL for AGENT and return a sexpr.transcript result event.

This is the per-call seam where a tool round is observable: tool-schema-list
is silent on success, so nothing before here can see a call being made. It
wraps sexpr.tools:perform-tool in a handler, passing (agent-capabilities
agent) as the gate's capability set, so that no tool failure reaches the loop
(D009). A gate failure (tool-error: unknown tool, denied capability, argument
error) or an error inside a tool body becomes a result event whose :value is a
structured failure plist (:tool .. :reason .. :detail ..) and whose :text
names the offending tool and argument. The loop keeps running and the model
sees the failure as data on its next turn.

Provider failures are deliberately NOT caught here: the M002 rule stands, so a
model outage stops the loop loudly instead of being folded into the transcript
as if it were a tool result."
  (handler-case
      (make-result-event
       (sexpr.tools:perform-tool tool-call
                                 :capabilities (agent-capabilities agent)))
    (sexpr.tools:tool-error (err)
      (make-result-event
       (list :tool (sexpr.tools:tool-error-tool err)
             :reason (sexpr.tools:tool-error-reason err)
             :detail (sexpr.tools:tool-error-detail err))
       :text (format nil "Tool error: ~a — ~a: ~a"
                     (sexpr.tools:tool-error-tool err)
                     (sexpr.tools:tool-error-reason err)
                     (sexpr.tools:tool-error-detail err))))
    (error (err)
      (make-result-event
       (list :tool (getf tool-call :name)
             :reason :body-error
             :detail (format nil "~a" err))
       :text (format nil "Tool error: ~a — ~a"
                     (getf tool-call :name) err)))))
(export 'dispatch-tool-call)

(defun run-until-finished (agent &key max-steps)
  "Run AGENT's loop: model-step, integrate, repeat until finished-p or
MAX-STEPS. Returns the transcript. With MAX-STEPS nil the loop is unbounded
(the contract agent-loop preserves); with a positive integer it stops after
that many model turns — the chat safety cap (R017).

A tool round dispatches every call it carries and folds each result back as a
user event before the model is asked again, so the model sees what its own
tool calls returned (R021). The cap check runs AFTER dispatch and never as an
:until clause: a tool round at step-count == max-steps dispatches and then
stops without a follow-up model call (D005). That ordering is the one place
the cap's meaning is ambiguous — max-steps counts model turns, and a tool round
is one of them — so dispatch comes first and the stop comes after."
  (let ((*current-agent* agent))
    (loop
       :with step-count = 0
       :for event = (model-step agent)
       :do (integrate agent event)
           (incf step-count)
           (when (tool-round-p event)
             (dolist (call (event-tool-calls event))
               (integrate agent (dispatch-tool-call agent call))))
           (when (or (finished-p event)
                     (and max-steps (>= step-count max-steps)))
             (return)))
    (agent-transcript agent)))
(export 'run-until-finished)

(defun agent-loop (agent)
  "Run AGENT's loop to completion. Delegates to run-until-finished with no
max-steps, preserving the unbounded contract. Chat callers use
run-until-finished with :max-steps."
  (run-until-finished agent))
(export 'agent-loop)
