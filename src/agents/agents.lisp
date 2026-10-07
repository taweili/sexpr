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
    :documentation "The worker's summary, extracted after join."))
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

(defun %spawn-subagent (goal &key capabilities endpoint parent)
  "Core spawn logic. Returns the subagent-handle (not the ID)."
  (let* ((parent-agent (or parent sexpr.kernel:*current-agent*))
         (caps (or capabilities
                   (and parent-agent (sexpr.kernel:agent-capabilities parent-agent))
                   '(:fs-read)))
         (ep (or endpoint
                 (and parent-agent (sexpr.kernel:agent-endpoint parent-agent))))
         (agent (sexpr.kernel:spawn
                 :goal goal
                 :capabilities caps
                 :endpoint ep
                 :parent parent-agent))
         (id (%next-handle-id))
         (handle (make-instance 'subagent-handle
                                :id id
                                :agent agent
                                :thread nil)))
    (register-agent! agent)
    (setf (handle-thread handle)
          (sb-thread:make-thread
           (lambda ()
             (handler-case
                 (progn
                   (sexpr.kernel:agent-loop agent)
                   (setf (sexpr.kernel:agent-status agent) :finished))
               (error (err)
                 (setf (handle-error handle) err)
                 (setf (sexpr.kernel:agent-status agent) :failed))))
           :name (format nil "agent:~a" goal)))
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
    (sb-thread:terminate-thread (handle-thread handle))
    (setf (sexpr.kernel:agent-status (handle-agent handle)) :killed)
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
