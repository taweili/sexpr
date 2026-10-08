(in-package :sexpr.tui)
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.tui — in-image RPC stubs for the remote TUI client (M004).
;;;;
;;;; Every public function returns a plain sexpr (plist / list / string
;;;; / keyword / number) suitable for cross-process transport over swank.
;;;; No live object ever crosses the wire.

;;;; --- helpers --------------------------------------------------------

(defun %agent-to-sexpr (agent)
  "Flatten AGENT into a plain plist of serializable values.

Every field is either a keyword, a symbol, a string, a number, a list
of those, or NIL. The status is the kernel's agent-status keyword
(:running, :finished, :failed, :killed). The budget is either the
sentinel :unlimited (both ceilings are the max-fixnum default) or a
two-key plist (:tokens N :seconds N). The endpoint is NIL (meaning
'fall back to the global default provider') or a keyword.
  "
  (let ((thread (agent-thread agent))
        (budget (agent-budget agent)))
    `(:name ,(agent-name agent)
             :status ,(agent-status agent)
             :thread-alive-p
               ,(and thread (sb-thread:thread-alive-p thread))
             :transcript-length
               ,(sexpr.transcript:transcript-length (agent-transcript agent))
             :capabilities ,(agent-capabilities agent)
             :endpoint ,(agent-endpoint agent)
             :budget
               ,(if (and (unlimited-p budget :kind :tokens)
                         (unlimited-p budget :kind :seconds))
                    :unlimited
                    (list :tokens (budget-tokens budget)
                          :seconds (budget-seconds budget))))))

(defun %lookup-agent (name)
  "Return the agent registered in the global table under NAME, or NIL."
  (gethash name sexpr.agents:*agent-table*))

;;;; --- snapshot -------------------------------------------------------

(defun agent-snapshot ()
  "Return a snapshot of the agent society as a LIST OF agent-status
plists, one per registered agent. Each plist has:
    :name STRING,
    :status KEYWORD (:running | :finished | :failed | :killed),
    :thread-alive-p BOOLEAN (T only when the agent has a live thread),
    :transcript-length INTEGER,
    :capabilities LIST-OF-KEYWORDS,
    :endpoint KEYWORD or NIL (NIL = use the global default),
    :budget either :unlimited or (:tokens N :seconds N).

The order follows hash-table iteration order and is not stable — the
TUI should sort by name. Agents spawned by sexpr.kernel:spawn (the
'root' agent of a CLI session) do not appear in the table; only agents
spawned by sexpr.agents:spawn-subagent do (D016 lineage)."
  (let ((snapshot nil))
    (maphash (lambda (name agent)
               (declare (ignore name))
               (push (%agent-to-sexpr agent) snapshot))
             sexpr.agents:*agent-table*)
    (nreverse snapshot)))

;;;; --- transcript delta ----------------------------------------------

(defun transcript-delta (agent-name &optional (cursor 0))
  "Return a dotted pair (NEW-EVENTS . NEW-CURSOR) for the agent
identified by the name string AGENT-NAME. NEW-EVENTS is the sublist
of the agent's transcript events at index >= CURSOR. NEW-CURSOR is the
current total event count. A caller that persists NEW-CURSOR between
calls gets every event exactly once, in order.

If AGENT-NAME is not in the global table this signals an error.
"
  (let ((agent (%lookup-agent agent-name)))
    (unless agent
      (error "unknown agent: ~a" agent-name))
    (let* ((events (sexpr.transcript:events-list (agent-transcript agent)))
           (new-cursor (length events)))
      (cons (nthcdr cursor events) new-cursor))))

;;;; --- delegation -----------------------------------------------------
;;;;
;;;; These three functions are pass-throughs to :sexpr.agents — the
;;;; TUI is a thin layer. The delegation keeps the boundary single:
;;;; the TUI never reaches into kernel internals beyond what agents
;;;; already exposes.

(defun inject-note (handle-id note)
  "Inject NOTE as a user event into the subagent identified by
HANDLE-ID. Delegates to sexpr.agents:subagent-note; returns the
confirmation string it produces (\"noted <id>: <note>\")."
  (subagent-note handle-id note))

(defun kill (handle-id)
  "Terminate the subagent identified by HANDLE-ID. Delegates to
sexpr.agents:subagent-kill; returns the confirmation string
(\"killed <id>\")."
  (subagent-kill handle-id))

(defun spawn (goal &key capabilities endpoint)
  "Spawn a worker subagent with GOAL and return its handle ID string.
Delegates to sexpr.agents:spawn-subagent; capabilities and endpoint
inherit from the calling agent unless overridden (R014, D013)."
  (spawn-subagent goal :capabilities capabilities :endpoint endpoint))
