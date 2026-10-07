;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.repl — the dev REPL loop.
;;;;
;;;; DESIGN (notes/sexpr.md §2): "the image is the state." Entered from
;;;; chat-loop via /repl, the REPL binds *agent* to the live agent so a
;;;; developer can inspect and mutate it directly; ,exit returns to chat
;;;; and the loop resumes with any redefinitions now in effect. A
;;;; standalone entry (sexpr.sh repl) shares this function with no agent.
;;;;
;;;; ,exit — the exit sentinel is a SLIME-style leading-comma meta prefix.
;;;; , (comma) is the CL unquote reader macro, so
;;;; (read-from-string ",exit") signals SB-INT:SIMPLE-READER-ERROR
;;;; "Comma not inside a backquote." (verified live on SBCL 2.6.8).
;;;; Therefore the REPL reads a whole line first, checks for a leading
;;;; comma, and only then read-from-strings the line. Consequence: one
;;;; form per prompt — no > continuation for incomplete forms. Multiple
;;;; forms on one line all eval and print. Mid-line commas outside
;;;; backquote still reach the reader and error appropriately; only a
;;;; LEADING comma (after trim) is a meta-command.

(in-package :sexpr.repl)

(defvar *agent* nil
  "Bound by REPL around its loop body. The live agent when entered from
chat-loop via /repl; NIL in standalone mode. Reach the transcript via
(agent-transcript *agent*), the system prompt via (agent-system *agent*),
etc.

DEFVAR (special) so that (eval '*agent*) inside the loop sees the dynamic
binding REPL establishes with LET — *agent* must be special for EVAL to
pick up the live value.")
(export '*agent*)

(defun repl (&key agent input output (package :sexpr.repl))
  "Run an unrestricted CL read-eval-print loop. Returns (values).

AGENT (default NIL) is bound to *agent* around the loop — the live agent
when entered from chat-loop via /repl, NIL in standalone mode. INPUT and
OUTPUT default to the standard streams; tests pass string streams. PACKAGE
(default :sexpr.repl) is the starting *package*. :sexpr.repl is an
aggregating package (see package.lisp), so make-agent, agent-transcript,
render-events, eval-in-sandbox, etc. are unqualified at the prompt.

Exit: ,exit (a leading-comma line) returns from the loop; EOF on INPUT
also returns. In escaped mode the user uses ,exit so the shared input
stream is not EOF'd (which would also end the chat loop); in standalone
either works.

One form per prompt: , collides with the unquote reader macro, so the
line is read whole and string-checked for a leading comma before
read-from-string. Multiple forms on one line all eval and print (the
line is parsed with WITH-INPUT-FROM-STRING and READ until EOF). No >
continuation for incomplete forms — use (progn ...) or (load \"file\").

Errors never crash the loop: reader-error / end-of-file, any eval error,
and a Ctrl-C (sb-sys:interactive-interrupt) during a form are all caught,
printed, and re-prompted. A Ctrl-C aborts the current form only — there
is no two-press idle-exit contract here (unlike chat-loop) because ,exit
is the explicit escape.

Print settings (*print-pretty* t, *print-length* 10, *print-level* 5,
*read-eval* t, *read-base* 10) are bound around the body so a dev's
settings don't leak into chat-loop's render-event after ,exit."
  (let ((*agent* agent)
        (*package* (or (find-package package) *package*))
        (*print-pretty* t)
        (*print-length* 10)
        (*print-level* 5)
        (*read-eval* t)
        (*read-base* 10)
        ;; Bind the standard streams to the REPL's in/out so a dev's
        ;; (format t ...), (read-line), (print ...), and error output all
        ;; land on the REPL surface — the same terminal in real use, the
        ;; test's string stream under tests. SBCL's own REPL does this.
        ;; Dynamic binding, so it reverts on ,exit — no leak into
        ;; chat-loop's render-event after the escape.
        (*standard-input*  (or input  *standard-input*))
        (*standard-output* (or output *standard-output*))
        (*error-output*    (or output *error-output*))
        (*trace-output*    (or output *trace-output*))
        (in  (or input  *standard-input*))
        (out (or output *standard-output*)))
    (format out "~&; sexpr REPL — ,exit to leave~%")
    (finish-output out)
    (loop
      (format out "~&> ")
      (finish-output out)
      (let ((line (read-line in nil :eof)))
        (when (eq line :eof)
          (return))
        (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
          (cond
            ;; ,exit — the explicit escape. Must be checked at the line
            ;; level: , is the unquote reader macro, so read-from-string
            ;; would signal "Comma not inside a backquote" before any
            ;; form could be read.
            ((string= trimmed ",exit")
             (return))
            ;; Any other leading-comma line is an unknown meta-command.
            ;; Printed and continued — never reaches the reader.
            ((and (> (length trimmed) 0) (char= (char trimmed 0) #\,))
             (format out "~&; unknown meta-command: ~a~%" trimmed)
             (finish-output out))
            ;; Blank line — just re-prompt. No eval, no read.
            ((string= trimmed ""))
            (t
             ;; Read every form on the line and eval each, printing every
             ;; non-null value list. WITH-INPUT-FROM-STRING + READ until
             ;; :eof so "(+ 1 2) (+ 3 4)" prints both 3 and 7. The whole
             ;; read+eval is one handler-case so a single error short-
             ;; circuits the remaining forms on that line (matches the
             ;; "one line = one shot" REPL contract) but never kills the
             ;; loop.
             (handler-case
                 (with-input-from-string (s trimmed)
                   (loop :for form = (read s nil :eof)
                         :until (eq form :eof)
                         :do (let ((values (multiple-value-list (eval form))))
                               ;; SBCL-REPL convention: a single NIL result
                               ;; is suppressed (so a side-effecting
                               ;; (format t ...) call echoes no trailing
                               ;; NIL). Multiple values, or any non-nil
                               ;; single value, all print.
                               (unless (and (null (cdr values))
                                            (null (car values)))
                                 (format out "~&~{~s~^~%~}~%" values)
                                 (finish-output out)))))
               (reader-error (e)
                 (format out "~&; read error: ~a~%" e)
                 (finish-output out))
               (end-of-file (e)
                 ;; An unclosed form (e.g. "( + 1") reaches end-of-string
                 ;; with a partial read — SBCL signals END-OF-FILE, a
                 ;; sibling of READER-ERROR under STREAM-ERROR. Caught
                 ;; here so the user sees a message, not a crash.
                 (format out "~&; read error: ~a~%" e)
                 (finish-output out))
               (error (e)
                 (format out "~&; error: ~a~%" e)
                 (finish-output out))
               (sb-sys:interactive-interrupt ()
                 ;; A Ctrl-C during a form aborts that form only and
                 ;; returns to the prompt. No two-press dance — ,exit is
                 ;; the explicit escape. Same condition class chat-loop
                 ;; catches; SBCL delivers interactive-interrupt from the
                 ;; OS, and a signaled one is caught identically here.
                 (format out "~&; [interrupted]~%")
                 (finish-output out))))))))   ; closes: interrupt-clause, handler-case, t-clause, cond, let-trimmed, let-line, loop
    (values)))
(export 'repl)
