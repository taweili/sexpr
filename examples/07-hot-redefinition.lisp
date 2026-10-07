#| 07-hot-redefinition.lisp — Hot redefinition across provider calls.

This is the core idea of a Lisp agent OS: the agent runtime is a living
Lisp image. Code defined in one turn is visible to the next turn. When
the model asks for a function to be redefined, the new definition
replaces the old one — no restart, no reload, no "deploy and hope."

This example demonstrates:
  1. The sandbox tool: each call gets a FRESH sandbox (state does not persist)
  2. The agent image: code defined globally persists across turns

Run:
  sbcl --load ~/.sbclinit --load examples/07-hot-redefinition.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :cl)

(format t "=== 07-hot-redefinition.lisp ===~%")
(format t "~%")

;; 1. The sandbox tool: fresh sandbox per call
;;    State defined in one lisp call does NOT persist to the next.
(format t "-- Sandbox tool: fresh sandbox per call --~%")

;; Call 1: define a variable and return it
(format t "call 1 (defvar +x+ 42): ~a~%"
  (sexpr.tools:perform-tool
    (list :name "lisp" :arguments (list :source "(defvar +x+ 42)"))
    :capabilities '(:lisp-eval)))

;; Call 2: try to access +x+ — it's gone (fresh sandbox)
(format t "call 2 (+x+): ~a~%"
  (sexpr.tools:perform-tool
    (list :name "lisp" :arguments (list :source "+x+"))
    :capabilities '(:lisp-eval)))

(format t "(refused: fresh sandbox per call — no state persists)~%")

;; 2. Global eval: code persists across calls
;;    When you eval in the global environment (not the sandbox),
;;    definitions persist. This is the live image concept.
(format t "~%-- Global eval: code persists across calls --~%")

;; Turn 1: define a function globally
(format t "Turn 1: define greet v1~%")
(eval '(defun greet () "Hello, world v1"))
(format t "  (greet) -> ~a~%" (funcall #'greet))

;; Turn 2: redefine the function globally
(format t "~%Turn 2: redefine greet v2~%")
(eval '(defun greet () "Hello, world v2"))
(format t "  (greet) -> ~a~%" (funcall #'greet))

;; Turn 3: the function is still there, with the new definition
(format t "~%Turn 3: still v2~%")
(format t "  (greet) -> ~a~%" (funcall #'greet))

;; 3. The agent picks up the new definition on its next turn
;;    A real agent loop would see the updated function in its next model step.
;;    Here we simulate the agent seeing the change:
(format t "~%-- Agent picks up redefinition --~%")

(let ((agent (sexpr.kernel:make-agent
              :goal "Greet the user"
              :capabilities '(:lisp-eval))))
  ;; Simulate: the agent asked the model to define greet v1,
  ;; the model called lisp, and now the agent redefines it.
  (format t "Before redefinition:~%")
  (format t "  greet: ~a~%" (funcall #'greet))
  
  ;; Simulate the model asking for a redefinition
  (eval '(defun greet () "Hello, sexpr agent!"))
  
  (format t "After redefinition:~%")
  (format t "  greet: ~a~%" (funcall #'greet))
  
  (format t "~%The agent image is alive: code defined in one turn~%")
  (format t "is visible (and replaceable) in the next turn.~%"))

;; 4. Contrast: sandbox vs global
(format t "~%-- Summary --~%")
(format t "  sandbox tool:  fresh env per call, no state persistence~%")
(format t "  global eval:   live image, definitions persist and update~%")
(format t "  This is the core differentiator: the agent's runtime is~%")
(format t "  a living Lisp image, not a sandboxed Python process.~%")

(format t "~%=== done ===~%")
