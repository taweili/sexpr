;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.cli — the Listener: a stream-parameterized chat loop.
;;;;
;;;; DESIGN (notes/sexpr.md §2): the Listener lives in a terminal. Each
;;;; entered line becomes a user event; one bounded run-until-finished
;;;; turn folds a model reply into the transcript, and the new events
;;;; render back to the human. The image is the state; the transcript is
;;;; its conversation slice; the model is a socket reached only through
;;;; the kernel.
;;;;
;;;; BOUNDARY (AGENT.md invariants #1/#3, R015): :sexpr.provider is
;;;; deliberately NOT in :use. The model is reached only transitively
;;;; via run-until-finished → model-step → provider-call. This module
;;;; never imports the provider transport; the single qualified
;;;; sexpr.provider:configure-provider reference (for --provider/--model)
;;;; lives in the arg parser, not here.

(defpackage :sexpr.cli
  (:nicknames :$.cli)
  (:use :cl :sexpr.transcript :sexpr.kernel)
  (:export
   #:chat
   #:chat-loop
   #:chat-session
   #:chat-session-agent
   #:chat-session-cursor))
