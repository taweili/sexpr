;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/repl.lisp — the dev REPL.
;;;;
;;;; Scope: sexpr.repl:repl reads CL forms, evals them, prints results,
;;;; and exits on ,exit or EOF. No model, no provider — the REPL never
;;;; calls the model (it's a dev surface, reached only via /repl from
;;;; chat-loop or via sexpr.sh repl). String streams drive input/output,
;;;; the same pattern tests/cli.lisp uses.

(in-package :sexpr-tests)

;;; --- package loads ---------------------------------------------------

(rove:deftest repl-package-loads
  "The :sexpr.repl module loads and exports the :$.repl nickname."
  (ok (find-package :sexpr.repl) "the :sexpr.repl package exists")
  (ok (find-package :$.repl) "the :$.repl nickname resolves"))

;;; --- eval and print --------------------------------------------------

(rove:deftest repl-evals-and-prints-a-form
  "(+ 1 2) prints 3 to the output stream."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream (format nil "(+ 1 2)~%,exit"))
          :output out)
    (ok (search "3" (get-output-stream-string out))
        "the result 3 is rendered")))

(rove:deftest repl-evals-multiple-forms-per-line
  "(+ 1 2) (+ 3 4) on one line prints both 3 and 7."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil "(+ 1 2) (+ 3 4)~%,exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      (ok (search "3" text) "the first result 3 is rendered")
      (ok (search "7" text) "the second result 7 is rendered"))))

(rove:deftest repl-suppresses-nil-results
  "A form returning NIL prints nothing — SBCL's REPL convention — so a
side-effecting (format ...) call does not echo NIL."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil "(format t \"hi\")~%,exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      ;; "hi" is written by the form itself to *standard-output*; the
      ;; REPL must NOT echo a trailing NIL on its own line.
      (ok (search "hi" text) "the form's own output appears")
      (ok (not (search "NIL" text))
          "no NIL is echoed for a form returning nil"))))

;;; --- exit paths ------------------------------------------------------

(rove:deftest repl-comma-exit-returns-cleanly
  ",exit returns from the loop with no error printed."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream (format nil ",exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      (ok (not (search "error" text))
          "no error was printed for ,exit")
      (ok (search "REPL" text)
          "the entry banner was printed"))))

(rove:deftest repl-eof-exits
  "EOF on the input stream returns from the loop cleanly."
  (let ((out (make-string-output-stream)))
    ;; empty input stream → first read-line returns :eof
    (repl :input  (make-string-input-stream "")
          :output out)
    (ok (search "REPL" (get-output-stream-string out))
        "the entry banner was printed before EOF")))

(rove:deftest repl-unknown-meta-command-continues
  ",foo prints 'unknown meta-command' and the loop keeps going to ,exit."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil ",foo~%,exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      (ok (search "unknown meta-command" text)
          "the unknown meta-command notice was printed")
      (ok (not (search "error" text))
          "no reader error — the comma never reached the reader"))))

(rove:deftest repl-blank-line-reprompts
  "A blank line just re-prompts — no eval, no read error."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil "~%~%(+ 1 2)~%,exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      (ok (search "3" text)
          "the form after the blank lines still evaluated")
      (ok (not (search "error" text))
          "no error from the blank lines"))))

;;; --- error continuation ---------------------------------------------

(rove:deftest repl-eval-error-continues
  "A form that signals an error prints ; error: and the loop continues
to ,exit. (+ 1 'foo) signals type-error at eval."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil "(+ 1 'foo)~%,exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      (ok (search "error" text)
          "the eval error was printed")
      ;; the loop survived: the entry banner for ,exit's clean return is
      ;; not re-printed, but the prompt after the error line proves the
      ;; loop reached the next iteration.
      (ok (> (count #\> text :test #'char=) 1)
          "more than one prompt was printed — the loop continued"))))

(rove:deftest repl-read-error-continues
  "An unbalanced form '( + 1' prints a read error and the loop continues.
SBCL signals END-OF-FILE (a STREAM-ERROR sibling of READER-ERROR) for an
unclosed list at end-of-string; both are caught."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil "( + 1~%,exit"))
          :output out)
    (let ((text (get-output-stream-string out)))
      (ok (search "error" text)
          "the read error was printed")
      (ok (not (search "traceback" text))
          "no traceback leaked — just a one-line error"))))

;;; --- *agent* binding -------------------------------------------------

(rove:deftest repl-agent-binding-is-live
  "When AGENT is supplied, *agent* is bound to it at the prompt —
(agent-goal *agent*) returns the agent's goal. *agent* must be DEFVAR
(special) so EVAL sees the dynamic binding the loop establishes."
  (let ((agent (make-agent :goal "test-goal")))
    (ok (string= (agent-goal agent) "test-goal")
        "fixture sanity: the agent holds the goal")
    (let ((out (make-string-output-stream)))
      (repl :agent agent
            :input  (make-string-input-stream
                     (format nil "(agent-goal *agent*)~%,exit"))
            :output out)
      (ok (search "test-goal" (get-output-stream-string out))
          "the live agent's goal was visible via *agent* at the prompt"))))

(rove:deftest repl-standalone-agent-is-nil
  "With no :agent arg, *agent* is NIL at the prompt. Wrapping in LIST
so the NIL is visible (the REPL suppresses a bare single-nil result,
SBCL convention); (list *agent*) prints (NIL)."
  (let ((out (make-string-output-stream)))
    (repl :input  (make-string-input-stream
                   (format nil "(list *agent*)~%,exit"))
          :output out)
    (ok (search "NIL" (get-output-stream-string out))
        "the standalone *agent* is NIL — (list *agent*) printed (NIL)")))

(rove:deftest repl-can-mutate-the-live-agent
  "A (setf agent-system) on *agent* inside the REPL is visible to the
chat loop after ,exit — the whole point of escaping into the live image."
  (let ((agent (make-agent :goal "g")))
    (let ((out (make-string-output-stream)))
      (declare (ignore out))
      (repl :agent agent
            :input  (make-string-input-stream
                     (format nil
                             "(setf (agent-system *agent*) \"new persona\")~%,exit"))
            :output out))
    (ok (string= (agent-system agent) "new persona")
        "the setf inside the REPL reached the live agent object")))
