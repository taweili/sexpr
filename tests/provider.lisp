;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/provider.lisp — the provider configuration seam.
;;;;
;;;; Scope: SEXPR_BASE_URL env var reading, SEXPR_PROVIDER auto-infer
;;;; (R025), kwarg override precedence, and MEM020 no-clobber discipline.
;;;; All tests run without a model server — they exercise env-var reading
;;;; and defaults only, no HTTP.
;;;;
;;;; The tests reference sexpr.provider symbols by fully qualified name,
;;;; matching how tests/kernel.lisp references sexpr.provider:provider-call.
;;;; No :use :sexpr.provider — the boundary stays visible. Special variables
;;;; are accessed via find-symbol + symbol-value / set since the test
;;;; package does not :use :sexpr.provider.

(in-package :sexpr-tests)

;;; --- env-var save/restore helper -------------------------------------

(defun %with-sexpr-env (fn)
  "Run FN with SEXPR_PROVIDER, SEXPR_MODEL, SEXPR_BASE_URL cleared and
the affected sexpr.provider specials reset, restoring everything on exit."
  (let ((old-provider (uiop:getenv "SEXPR_PROVIDER"))
        (old-model    (uiop:getenv "SEXPR_MODEL"))
        (old-base-url (uiop:getenv "SEXPR_BASE_URL"))
        (old-type     (symbol-value (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER")))
        (old-model-name (symbol-value (find-symbol "*DEFAULT-MODEL-NAME*" "SEXPR.PROVIDER")))
        (old-base-url-var (symbol-value (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER"))))
    (unwind-protect
         (progn
           ;; Clear env vars by setting to empty string — the env() helper
           ;; in provider.lisp treats both nil and "" as "not set".
           (setf (uiop:getenv "SEXPR_PROVIDER") ""
                 (uiop:getenv "SEXPR_MODEL") ""
                 (uiop:getenv "SEXPR_BASE_URL") "")
           (set (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER") :anthropic)
           (set (find-symbol "*DEFAULT-MODEL-NAME*" "SEXPR.PROVIDER") nil)
           (set (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER") nil)
           (funcall fn))
      (when old-provider (setf (uiop:getenv "SEXPR_PROVIDER") old-provider))
      (when old-model    (setf (uiop:getenv "SEXPR_MODEL") old-model))
      (when old-base-url (setf (uiop:getenv "SEXPR_BASE_URL") old-base-url))
      (set (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER") old-type)
      (set (find-symbol "*DEFAULT-MODEL-NAME*" "SEXPR.PROVIDER") old-model-name)
      (set (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER") old-base-url-var))))

;;; --- tests ----------------------------------------------------------

(rove:deftest configure-provider-reads-sexpr-base-url-env
  "SEXPR_BASE_URL, SEXPR_PROVIDER, and SEXPR_MODEL env vars are read
when no kwargs are supplied."
  (%with-sexpr-env
   (lambda ()
     (setf (uiop:getenv "SEXPR_BASE_URL") "http://localhost:6969/v1"
           (uiop:getenv "SEXPR_PROVIDER") "openai-compatible"
           (uiop:getenv "SEXPR_MODEL") "Qwythos-9B-v2")
     (sexpr.provider:configure-provider)
     (ok (string= (symbol-value (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER"))
                  "http://localhost:6969/v1")
         "*default-base-url* is set from SEXPR_BASE_URL")
     (ok (eq (symbol-value (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER"))
             :openai-compatible)
         "*provider-type* is set from SEXPR_PROVIDER")
     (ok (string= (symbol-value (find-symbol "*DEFAULT-MODEL-NAME*" "SEXPR.PROVIDER"))
                  "Qwythos-9B-v2")
         "*default-model-name* is set from SEXPR_MODEL"))))

(rove:deftest configure-provider-base-url-keyword-overrides-env
  "An explicit :base-url kwarg wins over the SEXPR_BASE_URL env var."
  (%with-sexpr-env
   (lambda ()
     (setf (uiop:getenv "SEXPR_BASE_URL") "http://env-host/v1")
     (sexpr.provider:configure-provider :base-url "http://kw-host/v1")
     (ok (string= (symbol-value (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER"))
                  "http://kw-host/v1")
         "the kwarg value is used, not the env var"))))

(rove:deftest configure-provider-without-base-url-keyword-reads-env
  "When :base-url kwarg is omitted, SEXPR_BASE_URL env var is the fallback."
  (%with-sexpr-env
   (lambda ()
     (setf (uiop:getenv "SEXPR_BASE_URL") "http://env-host/v1")
     (set (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER") nil)
     (sexpr.provider:configure-provider)
     (ok (string= (symbol-value (find-symbol "*DEFAULT-BASE-URL*" "SEXPR.PROVIDER"))
                  "http://env-host/v1")
         "env var is read when kwarg is omitted"))))

(rove:deftest configure-provider-auto-infers-openai-compatible-from-base-url
  "SEXPR_BASE_URL set + SEXPR_PROVIDER unset → :openai-compatible (R025)."
  (%with-sexpr-env
   (lambda ()
     (setf (uiop:getenv "SEXPR_BASE_URL") "http://localhost:6969/v1")
     (set (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER") :anthropic)
     (sexpr.provider:configure-provider)
     (ok (eq (symbol-value (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER"))
             :openai-compatible)
         "provider type is inferred from base URL when SEXPR_PROVIDER is unset"))))

(rove:deftest configure-provider-sexpr-provider-wins-over-auto-infer
  "Explicit SEXPR_PROVIDER always wins over the base-url auto-infer."
  (%with-sexpr-env
   (lambda ()
     (setf (uiop:getenv "SEXPR_PROVIDER") "anthropic"
           (uiop:getenv "SEXPR_BASE_URL") "http://localhost:6969/v1")
     (set (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER") :anthropic)
     (sexpr.provider:configure-provider)
     (ok (eq (symbol-value (find-symbol "*PROVIDER-TYPE*" "SEXPR.PROVIDER"))
             :anthropic)
         "explicit SEXPR_PROVIDER beats the base-url inference"))))
