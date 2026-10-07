;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.kernel — the agent loop.
;;;;
;;;; DESIGN (notes/sexpr.md §9): the kernel is the loop. The transcript (§1.2)
;;;; is the state; the model is a socket (§2).
;;;;
;;;; BOUNDARY: :sexpr.provider is deliberately NOT in :use. The kernel reaches
;;;; the model through sexpr.provider:provider-call by qualified name only, so
;;;; there is exactly one seam to the world and it stays visible in the source
;;;; (invariants #1 and #3). The tool registry is reached the same way —
;;;; sexpr.tools:tool-schema-list and sexpr.tools:perform-tool as qualified
;;;; calls, never :use'd — so the kernel names no transport type at all, and
;;;; :sexpr.tools keeps no knowledge of the kernel (D009, the one-way
;;;; dependency kernel -> tools). Approvals (§5) are later.

(defpackage :sexpr.kernel
  (:nicknames :$.kernel)
  (:use :cl :sexpr.transcript)
  (:export
   #:budget
   #:make-budget
   #:budget-tokens
   #:budget-seconds
   #:unlimited-p
   #:agent
   #:agent-name
   #:agent-goal
   #:agent-system
   #:agent-transcript
   #:agent-budget
   #:agent-capabilities
   #:agent-thread
   #:agent-endpoint
   #:agent-parent
   #:agent-status
   #:agent-child-list
   #:*current-agent*
   #:make-agent
   #:spawn
   #:model-step
   #:integrate
   #:tool-round-p
   #:dispatch-tool-call
   #:finished-p
   #:agent-loop
   #:run-until-finished
   #:event-to-message
   #:transcript-to-messages))
