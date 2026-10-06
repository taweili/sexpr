;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.provider — the "Ivory" layer: LLM providers as sockets.
;;;;
;;;; DESIGN (notes/sexpr.md §2): "The model is a socket. LLM providers
;;;; are I/O endpoints (model-call provider messages → sexpr). Swapping
;;;; providers = rebinding one function." This file is that function.
;;;;
;;;; BOUNDARY: cl-llm-provider is used as transport only (complete /
;;;; response parsing) plus one construction site: TRANSLATE-TOOL-SCHEMAS
;;;; is the single function in the project that names the transport's
;;;; tool-definition class. Tool *execution* stays in the sexpr kernel;
;;;; cl-llm-provider's tool registry/approval/hooks are deliberately
;;;; not adopted here — two sources of truth for "what a tool is"
;;;; would corrupt the design.

(in-package :sexpr.provider)

;;; --- configuration ---------------------------------------------------

(defparameter *provider-type* :anthropic
  "Default provider type for newly created endpoints. Override with
the SEXPR_PROVIDER env var, e.g. `SEXPR_PROVIDER=openai`.")

(defparameter *default-model-name* nil
  "Default model name override, or NIL for the provider's default.
Override with the SEXPR_MODEL env var.")

(defparameter *default-base-url* nil
  "Default base URL override, or NIL for the provider's built-in default.
Override with the SEXPR_BASE_URL env var; R025 auto-infers the provider
to :openai-compatible when SEXPR_BASE_URL is set and SEXPR_PROVIDER is
not, so a local OpenAI-compatible server is a first-class default with
no API key.")

(defparameter *model-endpoint* nil
  "The resident provider object. Rebind this (e.g. with LET around a
subagent, or setf globally) to swap providers — the central design
invariant (notes/sexpr.md §2). NIL means resolve lazily on first call.")

(defun env (name &optional default)
  (let ((v (uiop:getenv name)))
    (if (or (null v) (string= v ""))
        default
        v)))

(defun make-default-provider ()
  "Realize a provider object from current configuration. API keys are
read directly by cl-llm-provider from OPENAI_API_KEY / ANTHROPIC_API_KEY
/ etc. Only passes :base-url when *DEFAULT-BASE-URL* is non-nil —
passing :base-url nil would clobber the transport's per-instance default
(MEM020)."
  (if *default-base-url*
      (make-provider *provider-type* :model *default-model-name*
                     :base-url *default-base-url*)
      (make-provider *provider-type* :model *default-model-name*)))
(export 'make-default-provider)

(defun configure-provider (&key (provider nil p-supp)
                              (model nil m-supp)
                              (base-url nil b-supp)
                              (max-tokens nil mt-supp)
                              (temperature nil t-supp))
  "Set provider defaults. Does NOT realize the provider object — that
is deferred to the first PROVIDER-CALL so configuration never fails just
because an API key is not yet set in the environment.

When PROVIDER/MODEL/BASE-URL are omitted, falls back to the SEXPR_PROVIDER,
SEXPR_MODEL, and SEXPR_BASE_URL env vars, then to the current
*PROVIDER-TYPE*. R025 auto-infer: when SEXPR_PROVIDER is unset but
SEXPR_BASE_URL is set, *PROVIDER-TYPE* becomes :openai-compatible so a
local OpenAI-compatible server is a first-class default with no API key.
An explicit SEXPR_PROVIDER (env or kwarg) always wins over the inference.
API keys are read by cl-llm-provider from the standard env vars
\(OPENAI_API_KEY, ANTHROPIC_API_KEY, ...); do NOT pass keys through here.

Returns *PROVIDER-TYPE* (the effective provider type)."
  (let ((env-provider (env "SEXPR_PROVIDER"))
        (env-base-url (env "SEXPR_BASE_URL"))
        (env-model    (env "SEXPR_MODEL")))
    ;; *DEFAULT-BASE-URL* is set before *PROVIDER-TYPE* so the R025
    ;; auto-infer branch below sees the effective value.
    (setf *default-base-url*
          (if b-supp base-url (or *default-base-url* env-base-url)))
    (setf *provider-type*
          (cond
            (p-supp
             (if (keywordp provider)
                 provider
                 (alexandria:make-keyword (string-upcase (string provider)))))
            (env-provider
             (alexandria:make-keyword (string-upcase env-provider)))
            ((not (null *default-base-url*))
             :openai-compatible)
            (t *provider-type*)))
    (setf *default-model-name*
          (if m-supp
              model
              (or *default-model-name* env-model)))
    ;; mirror into cl-llm-provider's own defaults so any direct complete
    ;; calls agree with provider-call's lazily-resolved endpoint.
    (setf cl-llm-provider:*default-model* *default-model-name*
          cl-llm-provider:*default-provider* *provider-type*)
    (when mt-supp (setf cl-llm-provider:*default-max-tokens* max-tokens))
    (when t-supp (setf cl-llm-provider:*default-temperature* temperature))
    ;; invalidate any previously-realized endpoint so the next call picks
    ;; up the new config.
    (setf *model-endpoint* nil))
  *provider-type*)
(export 'configure-provider)

(defun %resolve-endpoint (&optional endpoint)
  (cond
    ((null endpoint)
     (or *model-endpoint*
         (setf *model-endpoint* (make-default-provider))))
    ((typep endpoint 'cl-llm-provider:llm-provider) endpoint)
    ((keywordp endpoint)
     (make-provider endpoint :model *default-model-name*))
    (t (error "~S is not a provider designator (keyword, provider, or NIL)"
              endpoint))))

;;; --- tool-schema translation (the one transport construction site) --
;;;
;;;; sexpr.tools produces tool schemas as plain sexpr plists. This is the
;;;; ONE place those plists become cl-llm-provider:tool-definition
;;;; objects, so the kernel and the tools package never name a transport
;;;; type. Validation is fail-fast here (sexpr-shaped errors), not
;;;; deferred to the transport's validate-tool-definition.

(defun translate-tool-schemas (tool-plists)
  "Translate a list of sexpr tool-schema plists into a list of
cl-llm-provider:tool-definition objects suitable for COMPLETE's :tools
argument.

Each input plist must have the shape derive-schema produces plus :name
and :description:

  (:name        "read-file"                    ; non-empty string
   :description "Read the file at PATH."          ; string
   :parameters  ((:name "path" :type :string) ...) ; list of param plists
   :required    ("path"))                       ; list of strings

Malformed plists are rejected with an error here, not deferred to the
transport's validator, so failures are sexpr-shaped. Returns one
tool-definition per input plist, in order. NIL input yields NIL."
  (mapcar #'translate-tool-schema tool-plists))

(defun translate-tool-schema (plist)
  "Translate one sexpr tool-schema plist into a
cl-llm-provider:tool-definition. Signals an error on a malformed plist."
  (let* ((name   (getf plist :name))
         (desc   (getf plist :description))
         (params (getf plist :parameters))
         (reqs   (getf plist :required)))
    (unless (and (stringp name) (not (string= name "")))
      (error "tool-schema plist ~S: :name must be a non-empty string" plist))
    (unless (stringp desc)
      (error "tool-schema plist ~S: :description must be a string" plist))
    (unless (listp params)
      (error "tool-schema plist ~S: :parameters must be a list" plist))
    (unless (and (listp reqs) (every #'stringp reqs))
      (error "tool-schema plist ~S: :required must be a list of strings" plist))
    (make-instance 'cl-llm-provider:tool-definition
                   :name name
                   :description desc
                   :parameters (mapcar #'%translate-param params)
                   :required reqs)))

(defun %translate-param (param)
  "Copy one derived parameter plist into the transport's param shape.

The input already matches ((:name str :type keyword) ...); sexpr-only
keys are dropped. A :description is synthesized as the empty string —
the transport accepts any string, and the tool-level docstring stays the
single source of truth for documentation. A missing :type defaults to
:STRING, matching derive-schema's default."
  (list :name (getf param :name)
        :type (getf param :type :string)
        :description (or (getf param :description) "")))

;;; --- the boundary: provider-call → sexpr -----------------------------

(defgeneric provider-call (endpoint messages &key system tools temperature
                                  max-tokens)
  (:documentation
   "Call the model ENDPOINT with MESSAGES; return an sexpr transcript
node (a plist), never the raw provider object.

  (:content    string | nil)
  (:tool-calls list of (:id .. :name .. :arguments ..))
  (:model      string)
  (:usage      plist | nil)
  (:finish     keyword | nil)

ENDPOINT may be a cl-llm-provider provider object, a keyword provider
type (:anthropic, :openai, :gemini, :ollama, :openrouter, or any
OpenAI-compatible), or NIL (use *MODEL-ENDPOINT*, lazily created). This
is the only function the sexpr kernel should call to reach the model."))
(export 'provider-call)

(defmethod provider-call ((endpoint t) messages
                           &key system tools temperature max-tokens)
  (let* ((provider (%resolve-endpoint endpoint))
         (provider-tools (when tools (translate-tool-schemas tools)))
         (response (complete messages
                             :provider provider
                             :system system
                             :tools provider-tools
                             :temperature temperature
                             :max-tokens max-tokens)))
    ;; Translate the transport object into an sexpr transcript node.
    ;; This is the ONE place that knows cl-llm-provider's response
    ;; shape; everything upstream is provider-agnostic.
    (list
     :content (response-content response)
     :tool-calls
     (mapcar (lambda (tc)
               (list :id (tool-call-id tc)
                     :name (tool-call-name tc)
                     :arguments (tool-call-arguments tc)))
             (response-tool-calls response))
     :model (response-model response)
     :usage (response-usage response)
     :finish (response-finish-reason response))))
