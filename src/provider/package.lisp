;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.provider — the "Ivory" layer: LLM providers as sockets.
;;;;
;;;; This is the boundary between sexpr and the world of LLM HTTP APIs.
;;;; cl-llm-provider is the concrete transport; sexpr owns the agent
;;;; loop, transcript, and tool execution. This package exposes one
;;;; generic function, PROVIDER-CALL, that returns s-expressions
;;;; (transcript-shaped plists), never raw provider objects — so the
;;;; rest of sexpr never imports the transport.

(defpackage :sexpr.provider
  (:nicknames :$.provider)
  (:use :cl)
  (:import-from :cl-llm-provider
   #:complete
   #:make-provider
   #:llm-provider
   #:response-content
   #:response-tool-calls
   #:response-usage
   #:response-model
   #:response-finish-reason
   #:tool-call-id
   #:tool-call-name
   #:tool-call-arguments
   #:*default-provider*
   #:*default-model*
   #:*default-max-tokens*
   #:*default-temperature*)
  (:export
   #:provider-call
   #:*model-endpoint*
   #:*provider-type*
   #:*default-model-name*
   #:make-default-provider
   #:configure-provider))
