;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.kernel — the agent loop.
;;;;
;;;; DESIGN (notes/sexpr.md §9): the kernel is the loop. The transcript (§1.2)
;;;; is the state; the model is a socket (§2).
;;;;
;;;; BOUNDARY: :sexpr.provider is deliberately NOT in :use. The kernel reaches
;;;; the model through sexpr.provider:provider-call by qualified name only, so
;;;; there is exactly one seam to the world and it stays visible in the source
;;;; (invariants #1 and #3). Tool execution, approvals (§5) and capability
;;;; enforcement are later milestones.

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
   #:agent-transcript
   #:agent-budget
   #:agent-capabilities
   #:agent-thread
   #:agent-endpoint
   #:make-agent
   #:spawn
   #:model-step
   #:integrate
   #:finished-p
   #:agent-loop
   #:event-to-message
   #:transcript-to-messages))
