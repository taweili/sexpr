(in-package :sexpr.tui)
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.tui — in-image RPC stubs for the remote TUI client (M004).
;;;;
;;;; Every public function returns a plain sexpr (plist / list / string
;;;; / keyword / number) suitable for cross-process transport over swank.
;;;; No live object ever crosses the wire.

;;;; --- helpers --------------------------------------------------------

(defun %agent-handle-index (&optional (registry sexpr.agents:*subagent-registry*))
  "Return a hash table mapping each live AGENT object to its handle ID string.

Built in ONE pass over the registry so `agent-snapshot` stays O(n) in the size
of the society. Scanning the registry per agent would be O(n^2): at 10x load
(1000 agents, 1000 handles) that is 1,000,000 probes instead of 2,000. Keys
are agent objects with :test #'eq, so an agent with no handle is simply absent
from the index and reads back as NIL. Handles whose handle-agent is NIL are
skipped — a NIL key would otherwise pollute the index.

If two handles share one agent (possible if a handle is re-registered), the
last one wins; the registry is keyed by handle ID, so this is a rendering
choice, not data loss. The index is private: only the string it yields crosses
the wire, never the live handle object."
  (let ((index (make-hash-table :test #'eq)))
    (maphash (lambda (handle-id handle)
               (declare (ignore handle-id))
               (let ((agent (sexpr.agents:handle-agent handle)))
                 (when agent
                   (setf (gethash agent index) (sexpr.agents:handle-id handle)))))
             registry)
    index))

(defun %agent-to-sexpr (agent &optional (handle-index (%agent-handle-index)))
  "Flatten AGENT into a plain plist of serializable values.

Every field is either a keyword, a symbol, a string, a number, a list
of those, or NIL. The status is the kernel's agent-status keyword
(:running, :finished, :failed, :killed). The streaming flag is a
data-only boolean — T exactly while a model stream is in flight (F6, the
red-light busy signal) — never the raw slot value or a live stream
object, so the print/read round-trip still holds (R023). The
pending-approval is NIL or
a data-only plist (:agent N :capability C :target T :description D
:restarts R) from the approval registry — never a live condition or
restart object, so the print/read round-trip still holds (R023). The
budget is either the sentinel :unlimited (both ceilings are the
max-fixnum default) or a two-key plist (:tokens N :seconds N). The
endpoint is NIL (meaning 'fall back to the global default provider') or
a keyword. The handle is a string or NIL — never the live
subagent-handle object — so the print/read round-trip still holds.

HANDLE-INDEX is the agent -> handle-ID map built by `agent-snapshot`; when
called directly it builds its own."
  (let ((thread (agent-thread agent))
        (budget (agent-budget agent)))
    `(:name ,(agent-name agent)
             :handle ,(gethash agent handle-index)
             :status ,(agent-status agent)
             :streaming ,(and (sexpr.kernel:agent-streaming-p agent) t)
             :pending-approval ,(pending-approval-for (agent-name agent))
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
    :handle STRING or NIL (the handle ID from *subagent-registry*; NIL when
      the agent has no subagent handle). inject-note and kill take handle IDs,
      not agent names, so the client needs this field to route chat input.
    :status KEYWORD (:running | :finished | :failed | :killed),
    :streaming BOOLEAN (T exactly while a model stream is in flight — the
      red-light busy signal; NIL otherwise, never a live stream object),
    :pending-approval NIL or a data-only plist
      (:agent N :capability C :target T :description D :restarts R) from
      the approval registry. NIL means no approval is pending; the client
      renders a yellow light when it is non-NIL.
    :thread-alive-p BOOLEAN (T only when the agent has a live thread),
    :transcript-length INTEGER,
    :capabilities LIST-OF-KEYWORDS,
    :endpoint KEYWORD or NIL (NIL = use the global default),
    :budget either :unlimited or (:tokens N :seconds N).

The order follows hash-table iteration order and is not stable — the
TUI should sort by name. Agents spawned by sexpr.kernel:spawn (the
'root' agent of a CLI session) do not appear in the table; only agents
spawned by sexpr.agents:spawn-subagent do (D016 lineage)."
  (let ((handle-index (%agent-handle-index))
        (snapshot nil))
    (maphash (lambda (name agent)
               (declare (ignore name))
               (push (%agent-to-sexpr agent handle-index) snapshot))
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
HANDLE-ID, then make sure the note gets a response.

The append delegates to sexpr.agents:subagent-note (which signals on an
unknown handle and returns the confirmation string). The second half —
ensure-subagent-running — is what makes the TUI a chat client rather than a
transcript editor: the kernel sends the whole transcript to the model each
turn, so a RUNNING loop picks the note up on its next model call, but a
finished agent's loop is over and the note would sit unanswered. In that
case a fresh worker thread is started and re-sends the whole transcript
(note included) on its first model call — the same append-then-run shape as
chat-loop. Returns the confirmation string subagent-note produced."
  (let ((confirmation (subagent-note handle-id note)))
    (ensure-subagent-running handle-id)
    confirmation))

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
