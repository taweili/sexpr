;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tools/diagnostic-tool-call.lisp — one-shot tool-call transport probe.
;;;;
;;;; WHY: M003's central assumption is that a local OpenAI-compatible
;;;; reasoning model (Qwythos-9B-v2 at http://localhost:6969/v1) emits
;;;; usable tool calls through the sexpr-owned provider seam. This script
;;;; makes that assumption checkable on demand instead of ad-hoc. It routes
;;;; configuration through SEXPR.PROVIDER:CONFIGURE-PROVIDER — which proves
;;;; the SEXPR_* env-var plumbing (T01) is real — then sends ONE message
;;;; with ONE tool-definition and pretty-prints the raw response node plus
;;;; its :TOOL-CALLS list. Those two blocks are the evidence the slice
;;;; SUMMARY cites.
;;;;
;;;; WHEN: run against a live local server via `make diagnostic-tool-call`.
;;;; Do NOT wire this into `make test`: the rove suite must stay green on a
;;;; machine with no model server running.
;;;;
;;;; GOOD RESPONSE: the model returns (:FINISH :TOOL_CALLS) with a
;;;; non-empty :TOOL-CALLS list naming "get_weather" and an :ARGUMENTS
;;;; plist carrying (:CITY "Paris"). Exit code 0. Anything else — an empty
;;;; :tool-calls list, or a transport error — exits non-zero after a clear
;;;; "FAIL:" message on *ERROR-OUTPUT*.
;;;;
;;;; NOTE: this file names CL-LLM-PROVIDER directly. It is a one-shot tool
;;;; loaded by `sbcl --load`, not shipped code, so it lives under tools/
;;;; and is outside the R015 scan (`rg cl-llm-provider src/cli/`).

(in-package :cl-user)

;;; 1. Exercise the SEXPR_* env-var plumbing. Reading SEXPR_PROVIDER,
;;;    SEXPR_MODEL, and SEXPR_BASE_URL here is exactly what proves T01's
;;;    configure-provider wiring rather than hard-coding a provider.
(sexpr.provider:configure-provider)

;;; 2. Show the effective configuration so a reader can see what loaded.
(format t "~&--- diagnostic: effective provider config ---~%")
(format t "~&provider-type:    ~s~%" sexpr.provider:*provider-type*)
(format t "~&default-model:    ~s~%" sexpr.provider:*default-model-name*)
(format t "~&default-base-url: ~s~%" sexpr.provider:*default-base-url*)
(force-output)

;;; 3. ONE tool-definition. define-tool returns a tool-definition instance
;;;    that provider-call passes through to the transport's complete :tools.
(defparameter *probe-tool*
  (cl-llm-provider:define-tool
   "get_weather"
   "Look up the weather for a city."
   '((:name "city" :type :string :description "City name."))
   :required '("city")))

;;; 4. ONE user message, ONE tool. This bypasses the kernel round loop on
;;;    purpose — it probes the transport, not the :TOOL_CALLS round handling
;;;    (that is S03's scope per MEM032).
(defparameter *probe-response*
  (sexpr.provider:provider-call
   nil
   (list (list :role "user" :content "Get the weather in Paris."))
   :tools (list *probe-tool*)
   :max-tokens 300
   :temperature 0.1))

;;; 5. Evidence blocks: the whole node, then :TOOL-CALLS explicitly.
(format t "~&--- diagnostic: raw response node ---~%")
(pprint *probe-response*)
(format t "~&--- diagnostic: :tool-calls node ---~%")
(pprint (getf *probe-response* :tool-calls))
(force-output)

;;; 6. Fail loudly when the model did not emit a usable tool call.
;;;    SBCL 2.6.8 spells the exit-status key :UNIX-STATUS, not :CODE.
(if (null (getf *probe-response* :tool-calls))
    (progn
      (format *error-output*
              "~&FAIL: no :tool-calls in response (finish=~s)~%"
              (getf *probe-response* :finish))
      (finish-output *error-output*)
      (sb-ext:quit :unix-status 1))
    (progn
      (format t "~&OK: ~d tool call(s) returned.~%"
              (length (getf *probe-response* :tool-calls)))
      (finish-output)
      (sb-ext:quit :unix-status 0)))
