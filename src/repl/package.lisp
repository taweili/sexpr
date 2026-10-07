;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.repl — the dev REPL: an unrestricted CL read-eval-print loop.
;;;;
;;;; DESIGN (notes/sexpr.md §2): "the image is the state." A REPL on the
;;;; running image is the natural dev surface — it sees the live agent and
;;;; transcript a chat loop is mid-conversation with, and any redefinition
;;;; made here takes effect on the next chat turn. The REPL is
;;;; unrestricted: a dev tool, not a sandboxed surface.
;;;;
;;;; PACKAGE: :sexpr.repl is an aggregating package — it :use's
;;;; transcript, kernel, tools, and sandbox so a dev at the prompt gets
;;;; make-agent, agent-transcript, render-events, eval-in-sandbox,
;;;; define-tool, etc. unqualified. *agent* is :sexpr.repl's own exported
;;;; symbol, so reading *agent* at the prompt (where *package* =
;;;; :sexpr.repl) finds it.
;;;;
;;;; :sexpr.cli is deliberately NOT :use'd. It would create a load-order
;;;; cycle: cli references sexpr.repl:repl, so repl must load before cli;
;;;; repl :use'ing cli would require cli before repl. Reach chat ops via
;;;; sexpr.cli:chat or (in-package :sexpr.cli).
;;;;
;;;; BOUNDARY: the REPL knows nothing about the chat loop. The dependency
;;;; is one-way — cli -> repl (cli calls sexpr.repl:repl by qualified name;
;;;; repl never references cli). The REPL reaches the model only
;;;; transitively: a dev can (sexpr.provider:provider-call ...) by
;;;; qualified name, but the REPL itself never imports the provider.

(defpackage :sexpr.repl
  (:nicknames :$.repl)
  (:use :cl :sexpr.transcript :sexpr.kernel :sexpr.tools :sexpr.sandbox)
  (:export
   #:repl
   #:*agent*))
