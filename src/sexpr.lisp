;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr — the Agent OS.
;;;;
;;;; This is the first real code in the project. It defines the package
;;;; identity and a `hello' entry point so the project is runnable end
;;;; to end. Real modules (kernel, transcript, tools, skills, MCP
;;;; bridge, etc.) will accumulate here.

(in-package :sexpr)

;;; --- identity ---------------------------------------------------------

(defparameter *name*    "sexpr")
(defparameter *version* "0.0.0")

(defun name ()
  "Return the project name."
  *name*)

(defun version ()
  "Return the project version."
  *version*)

;;; --- entry point ------------------------------------------------------

(defun hello (&optional (stream *standard-output*))
  "Print a greeting and return NIL.

This is the smoke-test entry point for the project: it proves that the
ASDF system loads, the package is usable, and the runtime is wired.
`asdf:test-op' on :sexpr invokes this."
  (format stream
          "~&sexpr ~a~%~
  An Agent OS in Common Lisp.~%~
  Hello from sexpr.~%~%"
          (version))
  nil)

;;; --- LLM smoke test --------------------------------------------------
;;;;
;;;; Configures a custom OpenAI-compatible endpoint (a local llama-server
;;;; at http://localhost:6969/v1), sends a message, and prints the model's
;;;; reply. This exercises the full provider-call transport path:
;;;; make-provider -> complete -> dexador HTTP -> response -> sexpr node.

(defun hello-llm (&optional (stream *standard-output*))
  "Send \"hello, how are yo!\" to a local OpenAI-compatible LLM at
http://localhost:6969/v1 (api key sk-12345, model Gemma-4-E2B-it) and
print the response. Returns the sexpr transcript node from provider-call."
  (let* ((provider
           (cl-llm-provider:make-provider
            :openai-compatible
            :base-url "http://localhost:6969/v1"
            :api-key  "sk-12345"
            :model    "Gemma-4-E2B-it"))
         (messages
           (list (list :role "user" :content "hello, how are yo!")))
         (response (sexpr.provider:provider-call provider messages)))
    (format stream "~&--- LLM response ---~%")
    (format stream "~&model:   ~a~%" (getf response :model))
    (format stream "~&content: ~a~%" (getf response :content))
    (when (getf response :usage)
      (format stream "~&usage:   ~a~%" (getf response :usage)))
    (force-output stream)
    response))

;;; --- test-op ---------------------------------------------------------
;;;;
;;;; Defined here (not inline in sexpr.asd) because the Quicklisp-bundled
;;;; ASDF miscompiles inline :perform bodies once the system has real
;;;; dependencies — the leading DECLARE is evaluated as a function call.

(defmethod asdf:perform ((op asdf:test-op)
                          (sys (eql (asdf:find-system :sexpr))))
  (declare (ignore op))
  (funcall (find-symbol "HELLO" "SEXPR")))
