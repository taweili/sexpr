;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui-client/main.lisp — the sexpr-tui entry point (M004/S03 T05).
;;;;
;;;; This file makes the client launchable as a process. It parses command-line
;;;; arguments, connects to both the swank RPC channel and the push channel,
;;;; builds the model, and runs the TUI.
;;;;
;;;; No save-lisp-and-die binary in this slice (D022): the client is run from
;;;; source via `make tui` or directly with sbcl.
;;;;
;;;; The wire reader thread is started from init, never before run sets
;;;; program-running (MEM103). The model's init method checks program-running-p
;;;; before starting the reader, so a NIL program or a non-running program
;;;; means no reader — the status bar shows "readers: off" instead of a
;;;; silently dead connection.

(in-package :sexpr-tui)

(defparameter *default-swank-port* 4004
  "The default swank port.")
(export '*default-swank-port*)

(defun parse-args (args)
  "Parse command-line ARGS into a plist of options.
Recognizes --host, --swank-port, --push-port, and --agent, each followed by a
value. Also recognizes --help. Returns (VALUES options help-p) where options
is a plist with :host, :swank-port, :push-port, and :agent keys, and help-p
is T when --help was given."
  (let ((options (list :host "127.0.0.1"
                       :swank-port *default-swank-port*
                       :push-port nil
                       :agent nil)))
    (loop for i from 0 below (length args)
          for arg = (nth i args)
          do (cond
               ((string= arg "--help")
                (return-from parse-args (values options t)))
               ((string= arg "--host")
                (when (< (1+ i) (length args))
                  (setf (getf options :host) (nth (1+ i) args))))
               ((string= arg "--swank-port")
                (when (< (1+ i) (length args))
                  (setf (getf options :swank-port)
                        (parse-integer (nth (1+ i) args) :junk-allowed t))))
               ((string= arg "--push-port")
                (when (< (1+ i) (length args))
                  (setf (getf options :push-port)
                        (parse-integer (nth (1+ i) args) :junk-allowed t))))
               ((string= arg "--agent")
                (when (< (1+ i) (length args))
                  (setf (getf options :agent) (nth (1+ i) args)))))
          finally (return (values options nil)))))
(export 'parse-args)

(defun print-usage ()
  "Print usage information."
  (format t "usage: sexpr-tui [--host HOST] [--swank-port PORT] [--push-port PORT] [--agent NAME]~%")
  (format t "  --host HOST        Image host (default 127.0.0.1)~%")
  (format t "  --swank-port PORT  Swank port (default ~D)~%" *default-swank-port*)
  (format t "  --push-port PORT  Push channel port (required for live updates)~%")
  (format t "  --agent NAME      Agent name to pick on connect~%")
  (format t "  --help             Show this message~%"))

(defun main (&optional (args (uiop:command-line-arguments)))
  "The sexpr-tui entry point. Parses ARGS, connects to the swank and push
channels, builds the model, and runs the TUI.
Returns 0 on success, non-zero on connection failure.
ARGS defaults to UIOP:COMMAND-LINE-ARGUMENTS: SBCL 2.6.8 no longer exports
SB-EXT:COMMAND-LINE-ARGS (verified: (find-symbol \"COMMAND-LINE-ARGS\" :sb-ext)
is NIL), and UIOP is always present because ASDF is built into SBCL."
  (multiple-value-bind (options help-p)
      (parse-args args)
    (when help-p
      (print-usage)
      (return-from main 0))
    (let ((host (getf options :host))
          (swank-port (getf options :swank-port))
          (push-port (getf options :push-port))
          (agent (getf options :agent)))
      (handler-case
          (let ((swank-conn (swank-connect host swank-port)))
            (handler-case
                (let ((push-conn (when push-port
                                   (connect-push host push-port))))
                  (let ((model (make-instance 'tui-model
                                              :swank-connection swank-conn
                                              :push-connection push-conn
                                              :picked-agent agent)))
                    ;; The zone manager must exist and be enabled BEFORE the first
                    ;; view, or every zone-mark is a no-op and no row is clickable.
                    ;; :mouse :cell-motion makes the terminal report mouse presses;
                    ;; without it the mouse dispatch in update never fires.
                    (tui:init-global-zone-manager)
                    ;; TUI:MAKE-PROGRAM takes the model POSITIONALLY (its signature is
                    ;; (make-program model &key alt-screen mouse pool-size)); the old
                    ;; :model keyword form was an odd-arity call that silently bound
                    ;; nothing. :mouse :cell-motion makes the terminal report mouse
                    ;; presses, without which the mouse dispatch never fires.
                    (let ((program (tui:make-program model :mouse :cell-motion)))
                      ;; THE PROGRAM MUST REACH BOTH THE MODEL AND THE PUSH CONNECTION
                      ;; BEFORE run STARTS THE READER IN init. Neither slot is set by
                      ;; make-program, and the connection predates the program, so
                      ;; without this wiring the push channel is DEAD in production:
                      ;;   - init starts the wire reader only when (program-running-p
                      ;;     (model-program model)) — a NIL model-program means the
                      ;;     reader never starts (the status bar's "readers: off"
                      ;;     was the tell);
                      ;;   - even a started reader drops every message, because
                      ;;     deliver calls tui:send only when the connection's program
                      ;;     slot is non-NIL.
                      ;; With both slots set, status pushes and streamed deltas reach
                      ;; the TEA loop: the agent pane tracks RUNNING -> IDLE and a
                      ;; chat note's reply renders in the chat pane.
                      (setf (model-program model) program)
                      (when push-conn
                        (setf (tui-connection-program push-conn) program))
                      (tui:run program))))
              (error (e)
                (close-swank-connection swank-conn)
                (format *error-output* "sexpr-tui: ~A~%" e)
                1)))
        (error (e)
          (format *error-output* "sexpr-tui: ~A~%" e)
          1)))))
(export 'main)
