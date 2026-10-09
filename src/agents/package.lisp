;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.agents - multi-agent coordination primitives.
;;;;
;;;; DESIGN (notes/sexpr.md §2): agents are lightweight processes sharing one
;;;; heap. The kernel provides the process model; this package adds the
;;;; coordination layer: spawning workers, collecting results, inspecting
;;;; transcripts, and managing the process tree.
;;;;
;;;; BOUNDARY: depends on :sexpr.kernel (for agent class, spawn, agent-loop)
;;;; and :sexpr.tools (for register-tool!, derive-schema). Tools defined here
;;;; are registered in :sexpr.tools' registry, but the package itself stays
;;;; free of transport types.
;;;;
;;;; NOTE: :sexpr.transcript is NOT :use'd - reached by qualified name
;;;; (append-event, make-user-event, events-list, event-type, event-content)
;;;; so the package dependency stays minimal.

(defpackage :sexpr.agents
  (:nicknames :$.agents)
  (:use :cl :sexpr.kernel :sexpr.tools)
  (:export
   #:subagent-handle
   #:handle-id
   #:handle-agent
   #:handle-thread
   #:handle-error
   #:handle-summary
   #:spawn-subagent
   #:subagent-summary
   #:subagent-error
   #:subagent-kill
   #:subagent-note
   #:agent-children
   #:register-agent!
   #:deregister-agent!
   #:register-multi-agent-tools!
   #:clear-subagent-registry!
   #:find-handle
   ;; *agent-table* is exported (M004/T03) so the sexpr.tui RPC layer can
   ;; walk the society read-only (maphash/gethash) for agent-snapshot and
   ;; transcript-delta. It is still maintained by register-agent!/deregister-, 
   ;; agent!; external packages should treat it as read-only.
   #:*agent-table*
   ;; *subagent-registry* is exported for the same read-only reason (M004/T03):
   ;; agent-snapshot needs the handle ID for each agent, and the only mapping
   ;; from an agent object to its handle ID is this table. Callers must not
   ;; write to it — use register-handle!/clear-subagent-registry!.
   #:*subagent-registry*))
