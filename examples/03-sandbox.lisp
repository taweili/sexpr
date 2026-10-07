#| 03-sandbox.lisp — The restricted read eval sandbox.

The sandbox provides a restricted Common Lisp eval environment:
  - A restricted readtable (#S, #C disabled; #. blocked by *read-eval* nil)
  - A locked package (no new symbol interning)
  - A wall-clock timeout (sb-ext:with-timeout)
  - A condition taxonomy (read-refusal, eval-refusal, timeout-refusal)

Run:
  sbcl --load ~/.sbclinit --load examples/03-sandbox.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :cl)

(format t "=== 03-sandbox.lisp ===~%")
(format t "~%")

;; 1. Successful eval
(format t "-- Successful eval --~%")
(let* ((sb (sexpr.sandbox:make-sandbox))
       (sb (sexpr.sandbox:lock-sandbox sb))
       (form (sexpr.sandbox:read-sandboxed-form "(+ 1 2 3)"))
       (result (sexpr.sandbox:eval-in-sandbox form sb)))
  (format t "form:   ~a~%" form)
  (format t "result: ~a~%" result))

;; 2. Read refusal: #. (read-time evaluation)
(format t "~%-- Read refusal: #. (read-eval) --~%")
(handler-case
    (sexpr.sandbox:read-sandboxed-form "#.(+ 1 2) ")
  (sexpr.sandbox:read-refusal (cond)
    (format t "refused!~%")
    (format t "  reason: ~a~%" (sexpr.sandbox:read-refusal-reason cond))
    (format t "  text:   ~a~%" (sexpr.sandbox:read-refusal-text cond))))

;; 3. Read refusal: #S (structure literal)
(format t "~%-- Read refusal: #S (sharp-S) --~%")
(handler-case
    (sexpr.sandbox:read-sandboxed-form "#S(some struct)")
  (sexpr.sandbox:read-refusal (cond)
    (format t "refused!~%")
    (format t "  reason: ~a~%" (sexpr.sandbox:read-refusal-reason cond))
    (format t "  text:   ~a~%" (sexpr.sandbox:read-refusal-text cond))))

;; 4. Read refusal: #C (complex constructor)
(format t "~%-- Read refusal: #C (sharp-C) --~%")
(handler-case
    (sexpr.sandbox:read-sandboxed-form "#C(1 2)")
  (sexpr.sandbox:read-refusal (cond)
    (format t "refused!~%")
    (format t "  reason: ~a~%" (sexpr.sandbox:read-refusal-reason cond))
    (format t "  text:   ~a~%" (sexpr.sandbox:read-refusal-text cond))))

;; 5. Eval refusal: undefined function
(format t "~%-- Eval refusal: undefined function --~%")
(let* ((sb (sexpr.sandbox:lock-sandbox (sexpr.sandbox:make-sandbox)))
       (form (sexpr.sandbox:read-sandboxed-form "(undefined-function 1 2)")))
  (handler-case
      (sexpr.sandbox:eval-in-sandbox form sb)
    (sexpr.sandbox:eval-refusal (cond)
      (format t "refused!~%")
      (format t "  reason: ~a~%" (sexpr.sandbox:eval-refusal-reason cond))
      (format t "  form:   ~a~%" (sexpr.sandbox:eval-refusal-form cond))
      (format t "  error:  ~a~%" (type-of (sexpr.sandbox:eval-refusal-error cond))))))

;; 6. Timeout refusal
(format t "~%-- Timeout refusal --~%")
(let* ((sb (sexpr.sandbox:lock-sandbox (sexpr.sandbox:make-sandbox)))
       (form (sexpr.sandbox:read-sandboxed-form "(loop)")))
  (handler-case
      (sexpr.sandbox:eval-in-sandbox form sb :seconds 1.0)
    (sexpr.sandbox:timeout-refusal (cond)
      (format t "refused!~%")
      (format t "  seconds: ~a~%" (sexpr.sandbox:timeout-seconds cond)))))

;; 7. The lisp tool (builtins) — wraps the sandbox
;;    The lisp function is not exported; call it via perform-tool.
(format t "~%-- The lisp tool (builtins) --~%")

(let ((args-ok (list :name "lisp" :arguments (list :source "(+ 1 2 3)"))))
  (format t "success: ~a~%"
    (sexpr.tools:perform-tool args-ok :capabilities '(:lisp-eval))))

(let ((args-bad (list :name "lisp" :arguments (list :source "#.(+ 1 2)"))))
  (format t "refusal: ~a~%"
    (sexpr.tools:perform-tool args-bad :capabilities '(:lisp-eval))))

(format t "~%=== done ===~%")
