;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.agents — multi-agent coordination primitives.
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
;;;; NOTE: :sexpr.transcript is NOT :use'd — reached by qualified name
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
   #:register-multi-agent-tools!
   #:clear-subagent-registry!
   #:find-handle))
