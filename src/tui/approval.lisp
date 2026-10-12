;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.tui — data-only pending-approval projection (M004/S04).
;;;;
;;;; SCOPE: This is a DATA-ONLY projection, NOT the §5 effect-requested
;;;; condition/restart machinery (R027). It stores plain plists and emits
;;;; plain bus events so the remote TUI can render a yellow "waiting"
;;;; light and clear it with a resolution. REQUEST-APPROVAL is the seam a
;;;; future effect-requested signaler will call; when §5 lands the registry
;;;; stores a projection of the condition, never a live condition or
;;;; restart object (R023).
;;;;
;;;; LOCK ORDER: approvals-lock -> bus-lock -> (push server) queue-lock.
;;;; Never call emit-event while holding the approvals lock: emit-event
;;;; takes the bus lock and a bus listener may take the queue lock, so
;;;; holding approvals-lock across the emit would invert the order. Every
;;;; emit below happens after the approvals lock is released.
;;;;
;;;; THREAD SAFETY: agents run in threads (MEM085), so the registry is
;;;; guarded by a dedicated sb-thread mutex — never bordeaux-threads.

(in-package :sexpr.tui)

;;;; --- registry --------------------------------------------------------

(defvar *pending-approvals* (make-hash-table :test #'equal)
  "Maps agent NAME strings to a data-only pending-approval plist:
  (:agent NAME :capability C :target T :description D :restarts R).
A name with no pending approval is absent from the table. Resolved per
entry by resolve-approval.")

(defvar *pending-approvals-lock* (sb-thread:make-mutex :name "pending-approvals")
  "Guards *pending-approvals*. See the file header for lock ordering.")

;;;; --- queries ---------------------------------------------------------

(defun pending-approval-for (agent-name)
  "Return the pending-approval plist stored for AGENT-NAME, or NIL.

Data-only: the value crosses the wire unchanged. Thread-safe. Used by
`%agent-to-sexpr` to populate the snapshot's :pending-approval field."
  (sb-thread:with-mutex (*pending-approvals-lock*)
    (gethash agent-name *pending-approvals*)))

(defun pending-approvals (&optional agent-name)
  "Return the pending-approval plists currently registered.

With AGENT-NAME NIL, return a list of every agent's plist (unsorted);
otherwise return that one agent's plist or NIL. Data-only and
thread-safe — for the client's initial snapshot or a reconciliation
refetch."
  (sb-thread:with-mutex (*pending-approvals-lock*)
    (if agent-name
        (gethash agent-name *pending-approvals*)
        (let ((rows nil))
          (maphash (lambda (name plist)
                     (declare (ignore name))
                     (push plist rows))
                   *pending-approvals*)
          (nreverse rows)))))
(export 'pending-approvals)

;;;; --- transitions -----------------------------------------------------

(defun request-approval (agent-name capability target description &optional restarts)
  "Record a pending approval for AGENT-NAME and announce it on the bus.

Stores the data-only plist
  (:agent NAME :capability C :target T :description D :restarts R)
under the approvals lock, releases the lock, then emits two events under
AGENT-NAME (in this order):
  (:type :status :agent-id NAME :status :waiting :pending-approval PLIST)
  (:type :approval-needed :agent-id NAME :capability C :target T
   :description D :restarts R)
Returns the stored plist.

This is the seam a future §5 effect-requested signaler will call; the
registry holds a projection, not a condition (see the file header)."
  (let ((plist (list :agent agent-name
                     :capability capability
                     :target target
                     :description description
                     :restarts restarts)))
    (sb-thread:with-mutex (*pending-approvals-lock*)
      (setf (gethash agent-name *pending-approvals*) plist))
    ;; Emit AFTER releasing the approvals lock (lock order: approvals -> bus).
    (sexpr.kernel:emit-event
     agent-name
     (list :type :status
           :agent-id agent-name
           :status :waiting
           :pending-approval plist))
    (sexpr.kernel:emit-event
     agent-name
     (list :type :approval-needed
           :agent-id agent-name
           :capability capability
           :target target
           :description description
           :restarts restarts))
    plist))
(export 'request-approval)

(defun resolve-approval (agent-name decision)
  "Resolve a pending approval for AGENT-NAME with DECISION.

DECISION must be one of :grant-once, :grant-session, :grant-always, :deny;
anything else signals an error naming the valid set. Removes the pending
entry, then emits a (:type :status ...) event carrying the agent's current
kernel status — :finished when the agent is unknown — with
:pending-approval NIL, so the client clears its yellow light. Returns a
confirmation string \"resolved NAME: DECISION\"."
  (unless (member decision '(:grant-once :grant-session :grant-always :deny))
    (error "unknown approval decision ~s; expected one of ~s"
           decision '(:grant-once :grant-session :grant-always :deny)))
  (let (status)
    (sb-thread:with-mutex (*pending-approvals-lock*)
      (remhash agent-name *pending-approvals*)
      (let ((agent (gethash agent-name sexpr.agents:*agent-table*)))
        (setf status (if agent (agent-status agent) :finished))))
    ;; Emit AFTER releasing the approvals lock (lock order: approvals -> bus).
    (sexpr.kernel:emit-event
     agent-name
     (list :type :status
           :agent-id agent-name
           :status status
           :pending-approval nil))
    (format nil "resolved ~a: ~a" agent-name decision)))
(export 'resolve-approval)
