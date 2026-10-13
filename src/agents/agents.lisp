;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.agents — multi-agent coordination.
;;;;
;;;; DESIGN (notes/sexpr.md §2): agents are lightweight processes sharing one
;;;; heap. This module adds the coordination layer: spawning workers with
;;;; inherited capabilities and endpoint, collecting results, inspecting
;;;; transcripts, and managing the process tree.
;;;;
;;;; BOUNDARY: depends on :sexpr.kernel (agent class, spawn, *current-agent*)
;;;; and :sexpr.tools (register-tool!, derive-schema). Tools are registered
;;;; in the global registry; the package itself stays free of transport types.
;;;;
;;;; HANDLE MODEL: spawn-subagent returns a handle ID string (e.g.
;;;; "subagent-3"), not a Lisp object. The model can only emit text, so the
;;;; handle ID is the protocol between turns. The live subagent-handle lives
;;;; in a global registry keyed by ID; the other tools look it up.
;;;
;;;; WORKER RESTART: a handle outlives its worker thread. When a note is
;;;; injected into an agent whose loop has finished, ensure-subagent-running
;;;; starts a FRESH worker so the note drives a new model turn (the TUI is
;;;; a chat client: append the event, then run — the same shape as
;;;; chat-loop). The :lock and :worker-token slots make that restart race-free:
;;;; the token is bumped under the lock before a replacement worker starts,
;;;; so a dying worker's terminal status write can never clobber the
;;;; replacement's :running. The residual window — a note arriving between
;;;; the old loop's return and its terminal status write — is microscopic and
;;;; self-healing (a second note sees the terminal status and respawns);
;;;; the one-operator assumption (notes/tui.md §10) covers it.

(in-package :sexpr.agents)

;;;; --- subagent-handle ------------------------------------------------
;;;;
;;;; A wrapper for the parent to track a spawned worker. The handle owns the
;;;; thread reference (D016).

(defclass subagent-handle ()
  ((id
    :initarg :id
    :accessor handle-id
    :type string
    :documentation "The handle's registry ID (e.g. \"subagent-3\").")
   (agent
    :initarg :agent
    :accessor handle-agent
    :type sexpr.kernel:agent
    :documentation "The worker agent.")
   (thread
    :initarg :thread
    :accessor handle-thread
    :documentation "The worker's sb-thread:thread, or NIL.")
   (error
    :accessor handle-error
    :initform nil
    :documentation "The error signaled by the worker, or NIL if successful.")
   (summary
    :accessor handle-summary
    :initform nil
    :documentation "The worker's summary, extracted after join.")
   (lock
    :accessor handle-lock
    :initform (sb-thread:make-mutex :name "subagent-handle")
    :documentation "Guards the worker-thread restart (ensure-subagent-running)
and the worker's terminal status write. Never held while calling
agent-loop-streaming: the loop runs for minutes, and a caller blocked on
this lock must not stall a turn.")
   (worker-token
    :accessor handle-worker-token
    :initform 0
    :type integer
    :documentation "Bumped under :lock every time a (replacement) worker
thread starts. A worker writes its terminal status only when its token
still matches, so a dying worker cannot clobber a replacement's :running."))
  (:documentation "A handle to a spawned worker agent."))
(export 'subagent-handle)

;;;; --- handle registry -------------------------------------------------
;;;;
;;;; Maps handle ID strings to subagent-handle objects. The model emits text,
;;;; not objects, so the ID is the cross-turn protocol.

(defvar *subagent-registry* (make-hash-table :test #'equal)
  "Maps handle ID strings to subagent-handle objects.")

(defvar *subagent-counter* 0
  "Monotonic counter for generating unique handle IDs.")

(defun %next-handle-id ()
  "Return a fresh, unique handle ID string."
  (format nil "subagent-~d" (incf *subagent-counter*)))

(defun register-handle! (handle)
  "Store HANDLE in the registry and return HANDLE."
  (setf (gethash (handle-id handle) *subagent-registry*) handle)
  handle)

(defun find-handle (id)
  "Return the subagent-handle for ID, or NIL."
  (gethash id *subagent-registry*))

(defun clear-subagent-registry! ()
  "Test-only: empty the handle registry and reset the counter."
  (clrhash *subagent-registry*)
  (setf *subagent-counter* 0))

;;;; --- agent lineage --------------------------------------------------
;;;;
;;;; Global agent table for process-tree views and child lookups.

(defvar *agent-table* (make-hash-table :test #'equal)
  "Maps agent names to agent objects, for lineage tracking.")

(defun register-agent! (agent)
  "Register AGENT in the global table. Returns AGENT."
  (setf (gethash (sexpr.kernel:agent-name agent) *agent-table*) agent)
  (let ((parent (sexpr.kernel:agent-parent agent)))
    (when parent
      (setf (sexpr.kernel:agent-child-list parent)
            (append (sexpr.kernel:agent-child-list parent)
                    (list agent)))))
  agent)

(defun deregister-agent! (agent)
  "Remove AGENT from the global table. Returns AGENT."
  (remhash (sexpr.kernel:agent-name agent) *agent-table*)
  agent)

(defun agent-children ()
  "Tool-facing wrapper: list the child agent IDs of the current agent.
Returns a list of agent-name strings (model-passable)."
  (let ((current sexpr.kernel:*current-agent*))
    (unless current
      (return-from agent-children '()))
    (mapcar (lambda (a)
              (format nil "~a" (sexpr.kernel:agent-name a)))
            (sexpr.kernel:agent-child-list current))))
(export 'agent-children)

;;;; --- spawn-subagent -------------------------------------------------
;;;;
;;;; The LLM's interface to spawning workers. Inherits capabilities and
;;;; endpoint from the parent by default (D014, D017).

(defun %worker-thread-body (handle token)
  "The subagent worker thread body, shared by %spawn-subagent and
ensure-subagent-running.

Runs sexpr.kernel:agent-loop-streaming (so the turn streams onto the event
bus), then announces the outcome on the bus so a connected TUI's agent
pane leaves the stale :running status behind: without the :status event the
pane keeps the initform :running forever, and an operator cannot tell a busy
agent from a finished one. Every status write is under the handle lock and
token-checked, so a dying worker cannot clobber a replacement worker's
:running (the worker-restart contract in the file header). The event itself
carries no :pending-approval: the approval registry lives in :sexpr.tui,
which :sexpr.agents must not depend on, and a status frame without the key
leaves the client's pending-approval untouched.

TOKEN MISMATCH: the worker was superseded while looping (ensure-subagent-
running started a replacement). It still records its error on the handle if
it has one (subagent-error reads it), but writes no status and announces
nothing, so the replacement's :running stands."
  (let ((agent (handle-agent handle))
        (announced nil))
    (handler-case
        (progn
          (let ((mine nil))
            (sb-thread:with-mutex ((handle-lock handle))
              (when (eql (handle-worker-token handle) token)
                (setf (sexpr.kernel:agent-status agent) :running
                      mine t)))
            ;; The start announcement flips a connected TUI's agent row from
            ;; IDLE back to RUNNING the instant a note revives a finished
            ;; agent — without it the row reads IDLE until the first
            ;; streamed fragment arrives, which a model latency of seconds
            ;; makes visible. The token is read under the lock but the emit
            ;; happens outside it: emit-event takes the event-bus lock, and
            ;; no listener may take the handle lock while holding it.
            (when mine
              (sexpr.kernel:emit-event
               (sexpr.kernel:agent-name agent)
               (list :type :status
                     :agent-id (sexpr.kernel:agent-name agent)
                     :status :running))))
          ;; S05/T03: the worker runs the STREAMING loop, so a subagent's
          ;; model turn emits :delta/:finalize/:tool-start/:tool-result onto
          ;; the event bus and :streaming is true in agent-snapshot while
          ;; the model stream is in flight. The finished/failed status
          ;; handling below is unchanged: agent-loop and
          ;; agent-loop-streaming share the same error contract.
          (sexpr.kernel:agent-loop-streaming agent)
          (sb-thread:with-mutex ((handle-lock handle))
            (when (eql (handle-worker-token handle) token)
              (setf (sexpr.kernel:agent-status agent) :finished
                    announced t))))
      (error (err)
        (setf (handle-error handle) err)
        (sb-thread:with-mutex ((handle-lock handle))
          (when (eql (handle-worker-token handle) token)
            (setf (sexpr.kernel:agent-status agent) :failed
                  announced t)))))
    ;; The announcement is tied to THIS worker's terminal write, so a
    ;; superseded worker stays silent and a replacement's status stands.
    (when announced
      (sexpr.kernel:emit-event
       (sexpr.kernel:agent-name agent)
       (list :type :status
             :agent-id (sexpr.kernel:agent-name agent)
             :status (sexpr.kernel:agent-status agent))))))

(defun %start-worker (handle)
  "Start a fresh worker thread for HANDLE. THE CALLER MUST HOLD the handle
lock: the token bump, the status reset and the thread slot update are one
critical section with the caller's check, so two callers cannot both spawn
and a dying worker's terminal writes are void (they fail the token check)."
  (let ((token (1+ (handle-worker-token handle))))
    (setf (handle-worker-token handle) token
          (sexpr.kernel:agent-status (handle-agent handle)) :running
          (handle-thread handle)
          (sb-thread:make-thread
            (lambda () (%worker-thread-body handle token))
            :name (format nil "agent:~a"
                          (sexpr.kernel:agent-goal (handle-agent handle)))))))

(defun %spawn-subagent (goal &key capabilities endpoint parent)
  "Core spawn logic. Returns the subagent-handle (not the ID).

The generated handle ID is also the agent's NAME (e.g. "subagent-1"), so
register-agent! keys *agent-table* by a distinct string per spawn and
agent-snapshot can list the whole society. Without this, make-agent's
default name "agent" makes every spawn overwrite the previous table entry.

The worker thread runs sexpr.kernel:agent-loop-streaming (S05/T03), not the
non-streaming agent-loop, so the subagent's model turn streams onto the event
bus. A provider failure still lands in handle-error with status :failed."
  (let* ((parent-agent (or parent sexpr.kernel:*current-agent*))
         (caps (or capabilities
                   (and parent-agent (sexpr.kernel:agent-capabilities parent-agent))
                   '(:fs-read)))
         (ep (or endpoint
                 (and parent-agent (sexpr.kernel:agent-endpoint parent-agent))))
         (id (%next-handle-id))
         (agent (sexpr.kernel:spawn
                 :name id
                 :goal goal
                 :capabilities caps
                 :endpoint ep
                 :parent parent-agent))
         (handle (make-instance 'subagent-handle
                                :id id
                                :agent agent
                                :thread nil)))
    (register-agent! agent)
    (sb-thread:with-mutex ((handle-lock handle))
      (%start-worker handle))
    (register-handle! handle)
    handle))

(defun spawn-subagent (goal &key capabilities endpoint)
  "Spawn a worker agent to run a subtask in parallel.

Inherits capabilities and endpoint from the calling agent unless overridden.
Returns a handle ID string (e.g. \"subagent-1\") that can be passed to
subagent-summary, subagent-error, subagent-kill, and subagent-note."
  (let ((handle (%spawn-subagent goal
                                 :capabilities capabilities
                                 :endpoint endpoint)))
    (handle-id handle)))

;;;; --- worker restart -------------------------------------------------
;;;
;;;; A handle outlives its worker thread: the loop ends, the thread exits,
;;;; and the handle stays in the registry. The TUI is a chat client, so a
;;;; note injected into a finished agent must drive a NEW turn — the same
;;;; append-then-run shape as chat-loop. ensure-subagent-running is that
;;;; second half, and it is the only caller besides %spawn-subagent that
;;;; starts a worker thread.

(defun ensure-subagent-running (handle-id)
  "Make sure the subagent identified by HANDLE-ID has a live worker thread.
Returns the handle. Signals on an unknown handle, matching subagent-note.

The check-and-spawn runs under the handle lock, so two callers cannot both
spawn. A worker that is alive AND :running is left alone: the kernel sends
the whole transcript to the model each turn, so a running loop picks up the
note the caller is about to inject on its next model call. A dead thread or
a terminal status (:finished/:failed/:killed) means the loop is over and the
note would sit unanswered — a fresh worker is started, which re-sends the whole
transcript (note included) on its first model call.

The residual race — a note arriving in the microseconds between the old
loop's return and its terminal status write — loses that one note; a second
note sees the terminal status and respawns. Covered by the one-operator
assumption (notes/tui.md §10)."
  (let ((handle (find-handle handle-id)))
    (unless handle
      (error "unknown subagent handle: ~a" handle-id))
    ;; The check-and-spawn is ONE critical section under the handle lock (see
    ;; %start-worker): a worker that is alive AND :running is left alone — the
    ;; kernel sends the whole transcript to the model each turn, so a running
    ;; loop picks up the note the caller is about to inject on its next model
    ;; call. A dead thread or a terminal status (:finished/:failed/:killed)
    ;; means the loop is over and the note would sit unanswered, so a fresh
    ;; worker is started and re-sends the whole transcript (note included) on
    ;; its first model call.
    (sb-thread:with-mutex ((handle-lock handle))
      (let ((thread (handle-thread handle))
            (agent (handle-agent handle)))
        (unless (and thread
                     (sb-thread:thread-alive-p thread)
                     (eq (sexpr.kernel:agent-status agent) :running))
          (%start-worker handle))))
    handle))
(export 'ensure-subagent-running)

;;;; --- coordination tools --------------------------------------------

(defun subagent-summary (handle-id)
  "Wait for the subagent identified by HANDLE-ID to finish and return its
summary (the last model event's content). Signals an error if the subagent
failed or the handle is unknown."
  (let ((handle (find-handle handle-id)))
    (unless handle
      (error "unknown subagent handle: ~a" handle-id))
    (sb-thread:join-thread (handle-thread handle))
    (when (handle-error handle)
      (error "subagent ~a failed: ~a" handle-id (handle-error handle)))
    (let ((summary (extract-summary
                     (sexpr.kernel:agent-transcript (handle-agent handle)))))
      (setf (handle-summary handle) summary)
      summary)))

(defun subagent-error (handle-id)
  "Return the error signaled by the subagent identified by HANDLE-ID, or
NIL if it succeeded or is still running."
  (let ((handle (find-handle handle-id)))
    (if handle
        (let ((err (handle-error handle)))
          (if err (format nil "~a" err) nil))
        (error "unknown subagent handle: ~a" handle-id))))

(defun subagent-kill (handle-id)
  "Terminate a running subagent identified by HANDLE-ID. Returns a
confirmation string."
  (let ((handle (find-handle handle-id)))
    (unless handle
      (error "unknown subagent handle: ~a" handle-id))
    ;; Invalidate the worker token under the lock FIRST, so the unwound
    ;; worker's terminal status write is void and cannot clobber :killed.
    (sb-thread:with-mutex ((handle-lock handle))
      (setf (handle-worker-token handle) (1+ (handle-worker-token handle))
            (sexpr.kernel:agent-status (handle-agent handle)) :killed)
      (let ((thread (handle-thread handle)))
        (when thread
          (sb-thread:terminate-thread thread))))
    (sexpr.kernel:emit-event
     (sexpr.kernel:agent-name (handle-agent handle))
     (list :type :status
           :agent-id (sexpr.kernel:agent-name (handle-agent handle))
           :status :killed))
    (format nil "killed ~a" handle-id)))

(defun subagent-note (handle-id note)
  "Inject a user message into a running subagent's transcript. Returns a
confirmation string."
  (let ((handle (find-handle handle-id)))
    (unless handle
      (error "unknown subagent handle: ~a" handle-id))
    (sexpr.transcript:append-event
     (sexpr.kernel:agent-transcript (handle-agent handle))
     (sexpr.transcript:make-user-event note))
    (format nil "noted ~a: ~a" handle-id note)))

(defun extract-summary (transcript)
  "Extract the summary (last model event content) from a TRANSCRIPT."
  (let ((last-model nil))
    (dolist (event (sexpr.transcript:events-list transcript))
      (when (eq (sexpr.transcript:event-type event) :model)
        (setf last-model event)))
    (if last-model
        (sexpr.transcript:event-content last-model)
        "(no model output)")))

;;;; --- registration ----------------------------------------------------
;;;;
;;;; Register the multi-agent tools in the global registry, using the same
;;;; register-tool! + derive-schema pattern as the five built-ins.

(defun %register-agent-tool! (name symbol description lambda-list capability)
  "Register one tool record built from register-tool! + derive-schema.
Mirrors builtins:%register-tool-directly!."
  (sexpr.tools:register-tool!
   (list :name (string-downcase (string name))
         :symbol symbol
         :description description
         :schema (multiple-value-call
                  #'(lambda (params required)
                      (list :parameters params :required required))
                  (sexpr.tools:derive-schema lambda-list))
         :capability capability)))

(defun register-multi-agent-tools! ()
  "Register the multi-agent coordination tools in the global registry.

Call after register-default-tools! (or after reset-tool-registry!) to
populate the six coordination tools: spawn-subagent, subagent-summary,
subagent-error, subagent-kill, subagent-note, and agent-children."
  (%register-agent-tool!
   :spawn-subagent #'spawn-subagent
   "Spawn a worker agent to run a subtask in parallel. Inherits capabilities
and endpoint from the parent by default. Returns a handle ID string (e.g.
\"subagent-1\") for tracking and collecting results."
   '(goal &key capabilities endpoint) :spawn)
  (%register-agent-tool!
   :subagent-summary #'subagent-summary
   "Wait for a subagent to finish and return its summary (last model output).
Signals an error if the subagent failed."
   '(handle-id) :collect)
  (%register-agent-tool!
   :subagent-error #'subagent-error
   "Return the error from a subagent, or nil if it succeeded or is still
running."
   '(handle-id) :collect)
  (%register-agent-tool!
   :subagent-kill #'subagent-kill
   "Terminate a running subagent. Returns a confirmation string."
   '(handle-id) :manage)
  (%register-agent-tool!
   :subagent-note #'subagent-note
   "Inject a user message into a running subagent's transcript."
   '(handle-id note) :manage)
  (%register-agent-tool!
   :agent-children #'agent-children
   "List the child agents of the current agent. Returns a list of agent
objects."
   '() :inspect))
(export 'register-multi-agent-tools!)
