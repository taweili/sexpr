;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.tui — RPC stub layer for the remote TUI client (M004).
;;;;
;;;; BOUNDARY: this package is the in-image half of the TUI wire. Every
;;;; function returns plain sexprs (plists, lists, strings, keywords,
;;;; numbers) — never a live object — so the result can cross the
;;;; process boundary as S-expression text over swank. The client side
;;;; (S03) reads these as data, not as references.
;;;;
;;;; :use's :sexpr.kernel (agent class, budget, event bus) and
;;;; :sexpr.agents (spawn/kill/note). :sexpr.transcript is reached by
;;;; qualified name (events-list, transcript-length) so the boundary
;;;; stays as thin as the kernel's.
;;;;
;;;; R015 invariant: :sexpr.provider is deliberately NOT :use'd. The
;;;; TUI never names a transport type — it asks the kernel to speak.

(defpackage :sexpr.tui
  (:nicknames :$.tui)
  (:use :cl :sexpr.kernel :sexpr.agents)
  ;; :sexpr.agents:spawn-subagent is imported through :use. Our own
  ;; `spawn` here is a thin pass-through (see tui.lisp) — it shadows the
  ;; imported `spawn` so it's visible as `sexpr.tui:spawn` rather than
  ;; re-exporting the agents-side kernel:spawn. Same for `kill` (CL has
  ;; no `kill`, so nothing is being shadowed, but we keep :shadow for
  ;; the symmetric declaration). Note: `kill` is only `spawn` that
  ;; would shadow — `kill` is not imported from any of the :use'd
  ;; packages, so it stays a fresh defun.
  (:shadow #:spawn)
  (:export
   #:agent-snapshot
   #:transcript-delta
   #:inject-note
   #:kill
   #:spawn
   #:push-server
   #:push-server-port
   #:push-server-stats
   #:push-server-diagnostics
   #:push-server-stopped-p
   #:start-server
   #:stop-server
   #:*push-server*
   #:*push-server-log*))
