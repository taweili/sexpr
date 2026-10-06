;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.cli — the Listener: a stream-parameterized chat loop.
;;;;
;;;; DESIGN (notes/sexpr.md §2): the Listener lives in a terminal. Each
;;;; entered line becomes a user event; one bounded run-until-finished
;;;; turn folds a model reply into the transcript, and the new events
;;;; render back to the human. The image is the state; the transcript is
;;;; its conversation slice; the model is a socket reached only through
;;;; the kernel.
;;;;
;;;; BOUNDARY (AGENT.md invariants #1/#3, R015): :sexpr.provider is
;;;; deliberately NOT in :use. The model is reached only transitively
;;;; via run-until-finished → model-step → provider-call. This module
;;;; never imports the provider transport; the single qualified
;;;; sexpr.provider:configure-provider reference lives in main below.

(in-package :sexpr.cli)

;;; --- the chat session ---------------------------------------------

(defstruct chat-session
  "A live chat session: the agent under conversation plus a render cursor.

CURSOR is the index of the first event not yet printed — the events in
[cursor, transcript-length) are rendered to the human after each turn.
It is set past the just-entered user event (the human already sees their
own input on the terminal) so only the model's new reply renders."
  agent
  (cursor 0))
(export 'chat-session)
(export 'chat-session-agent)
(export 'chat-session-cursor)

;;; --- slash-command parsing (R010) ---------------------------------

(defun parse-slash-command (line)
  "If LINE (after trimming whitespace) starts with #\\/, return (values
command-string argument-string); otherwise return (values nil nil).

The command is the token after the slash up to the first space; the
argument is the rest of the line, trimmed. A bare /exit has an empty
argument. A line not starting with #\\/ is the normal user-event path —
this function returns nil for the command so the caller falls through."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
    (if (and (> (length trimmed) 0) (char= (char trimmed 0) #\/))
        (let* ((body (subseq trimmed 1))
               (pos  (position #\Space body)))
          (if pos
              (values (subseq body 0 pos)
                      (string-trim '(#\Space) (subseq body (1+ pos))))
              (values body "")))
        (values nil nil))))

;;; --- turn runner (shared by chat-loop and /retry) ------------------

(defun run-turn-and-render (session output max-steps)
  "Run one bounded turn on SESSION's agent and render the new transcript
events to OUTPUT. A Ctrl-C (sb-sys:interactive-interrupt) aborts the turn
and returns to the prompt (R013). The render cursor skips already-printed
events; after the turn, events in [cursor, transcript-length) are printed
and the cursor advances to the new length."
  (let* ((agent (chat-session-agent session))
         (tr    (agent-transcript agent)))
    (handler-case
        (run-until-finished agent :max-steps max-steps)
      (sb-sys:interactive-interrupt ()
        (format output "~&; [interrupted — turn aborted]~%")))
    (let* ((events  (transcript-events tr))
           (new-len (length events))
           (start   (chat-session-cursor session)))
      (loop :for i :from start :below new-len
            :do (format output "~&~a~%" (render-event (aref events i))))
      (setf (chat-session-cursor session) new-len))
    (finish-output output)))

;;; --- slash-command handlers (R010) ---------------------------------
;;;;
;;;; Each cmd-* function takes the session (and where relevant the
;;;; argument text / output stream / max-steps) and produces its side
;;;; effect. A function returns :EXIT to signal chat-loop to return; nil
;;;; to continue. Commands never append a user event unless they choose
;;;; to (none do).

(defun cmd-exit ()
  "Signal the chat loop to terminate cleanly."
  :exit)

(defun cmd-help (&key output)
  "Print a one-line-per-command usage list to OUTPUT."
  (format output "~&Commands:~%")
  (format output "~&  /exit              quit the session~%")
  (format output "~&  /quit              quit the session~%")
  (format output "~&  /help              show this list~%")
  (format output "~&  /transcript        print the whole transcript~%")
  (format output "~&  /system TEXT       set the system prompt~%")
  (format output "~&  /save FILE         save the session to FILE~%")
  (format output "~&  /load FILE         load a session from FILE~%")
  (format output "~&  /retry             re-run the last model turn~%")
  (finish-output output))

(defun cmd-transcript (session &key output)
  "Print the whole transcript to OUTPUT, ignoring the render cursor."
  (let ((agent (chat-session-agent session)))
    (format output "~&~a~%" (render-events (agent-transcript agent)))
    (finish-output output)))

(defun cmd-system (session text &key output)
  "Set the agent's system prompt (persona) to TEXT and confirm (R014)."
  (let ((agent (chat-session-agent session)))
    (setf (agent-system agent) text)
    (format output "~&; system prompt set.~%")
    (finish-output output)))

(defun cmd-save (session file &key output)
  "Write the session transcript to FILE using print-transcript (R012).

Reuses the tested transcript round-trip: print-transcript writes under
with-standard-io-syntax; read-transcript reads back with *read-eval* nil
— no separate serializer is written here."
  (let ((agent (chat-session-agent session)))
    (with-open-file (stream file :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
      (print-transcript (agent-transcript agent) stream))
    (format output "~&; saved to ~a~%" file)
    (finish-output output)))

(defun cmd-load (session file &key output)
  "Load a transcript from FILE and install it on the agent (R012).

The render cursor resets to the new transcript-length so loaded history
is not re-printed (MEM016)."
  (let ((agent (chat-session-agent session)))
    (with-open-file (stream file :direction :input)
      (let ((new (read-transcript stream)))
        (setf (agent-transcript agent) new)
        (setf (chat-session-cursor session) (transcript-length new))))
    (format output "~&; loaded from ~a~%" file)
    (finish-output output)))

(defun cmd-retry (session &key output max-steps)
  "Pop the single trailing :model event and re-run one bounded turn.

Simplest honest semantics: remove the last model reply, move the cursor
back to that index, and run one turn — the new model event renders and
the cursor ends at length. If the last event is not a model event, there
is nothing to retry."
  (let* ((agent  (chat-session-agent session))
         (tr     (agent-transcript agent))
         (events (transcript-events tr)))
    (cond
      ((and (> (length events) 0)
            (eq (event-type (aref events (1- (length events)))) :model))
       (vector-pop events)
       (setf (chat-session-cursor session) (transcript-length tr))
       (run-turn-and-render session output max-steps))
      (t
       (format output "~&; nothing to retry — no trailing model event.~%")
       (finish-output output)))))

(defun dispatch-slash-command (session command rest &key output max-steps)
  "Dispatch COMMAND (a string) with REST (the argument text) to the
per-command function via a case. Returns :EXIT when the chat loop should
terminate; nil otherwise. An unknown command prints a notice and
continues — it never appends a user event or runs a turn."
  (case (intern (string-upcase command) :keyword)
    ((:exit :quit) (cmd-exit))
    (:help         (cmd-help :output output))
    (:transcript   (cmd-transcript session :output output))
    (:system       (cmd-system session rest :output output))
    (:save         (cmd-save session rest :output output))
    (:load         (cmd-load session rest :output output))
    (:retry        (cmd-retry session :output output :max-steps max-steps))
    (otherwise
     (format output "~&unknown command: ~a~%" command)
     (finish-output output)
     nil)))

;;; --- the chat loop (R009, R010) ------------------------------------

(defun chat-loop (session &key input output (max-steps 1))
  "Drive SESSION's chat loop: read a line from INPUT, and either dispatch
it as a slash command (R010) or append it as a user event and run one
bounded turn (MAX-STEPS). New transcript events render to OUTPUT. Repeat
until INPUT reaches EOF or a command signals exit.

INPUT and OUTPUT default to *standard-input* and *standard-output* so the
loop runs on a live terminal, but tests pass string streams. A line
starting with #\\/ is a command — it is never appended as a user event
(unknown commands print a notice and continue). All other lines follow
the T01 turn path: append a user event, set the cursor past it, run one
bounded turn, and render the model's new events in [cursor,
transcript-length). A Ctrl-C (sb-sys:interactive-interrupt) during a turn
aborts it and returns to the prompt (R013); the partial transcript stays
readable. Returns SESSION.

Read EOF with the missing-arg form (read-line input nil :eof) and test
the sentinel — never the error-signaling form, or scripted input hangs.

R013's two interrupt paths share one handler form. A Ctrl-C *inside* a
running turn aborts that turn only and returns to the prompt (see
run-turn-and-render). A Ctrl-C at an *idle* prompt is a two-press contract:
the first press prints a notice and re-prompts, the second exits.
"
  (let ((agent (chat-session-agent session))
        (in    (or input  *standard-input*))
        (out   (or output *standard-output*))
        ;; Two-Ctrl-C-at-idle-exits contract (R013). A SIGINT arriving while
        ;; read-line blocks at the prompt sets this flag, prints a notice, and
        ;; re-prompts; a SECOND SIGINT while the flag is already set returns
        ;; from chat-loop. The flag resets on every successfully-read line
        ;; (including :eof), so a turn's own work between two idle interrupts
        ;; never counts as the "second" one.
        (idle-sigint-seen nil))
    (loop
       (let (line)
         ;; Wrap the idle read-line: on a live terminal a Ctrl-C delivered
         ;; while read-line blocks arrives as sb-sys:interactive-interrupt —
         ;; the same condition run-turn-and-render catches, so this one handler
         ;; form covers both the OS-delivered and the explicitly-signaled
         ;; paths. When it fires LINE stays NIL, and the guard below re-prompts.
         (handler-case
             (setf line (read-line in nil :eof))
           (sb-sys:interactive-interrupt ()
             (cond
               (idle-sigint-seen
                (return-from chat-loop session))
               (t
                (setf idle-sigint-seen t)
                (format out
                        "~&; [interrupted at prompt — Ctrl-C again to exit]~%")
                (finish-output out)))))
         (when line
           ;; A line actually arrived — clear the idle-SIGINT flag.
           (setf idle-sigint-seen nil)
           (when (eq line :eof)
             (return-from chat-loop session))
           (multiple-value-bind (cmd rest) (parse-slash-command line)
             (cond
               (cmd
                (when (eq :exit (dispatch-slash-command
                                  session cmd rest
                                  :output out :max-steps max-steps))
                  (return-from chat-loop session)))
               (t
                (let ((tr (agent-transcript agent)))
                  ;; The human already sees their line on the terminal;
                  ;; record it and point the cursor past it so only model
                  ;; events render.
                  (append-event tr (make-user-event line))
                  (setf (chat-session-cursor session) (transcript-length tr))
                  (run-turn-and-render session out max-steps))))))))
    session))
(export 'chat-loop)

;;; --- the convenience entry point ----------------------------------

(defun chat (&key goal system endpoint input output (max-steps 1) transcript)
  "Build an agent and run chat-loop over it.

GOAL is required — an agent without a goal is not an agent; make-agent
signals if it is NIL. TRANSCRIPT, when supplied, pre-loads history: its
existing events are not re-printed, because the cursor starts at
transcript-length. SYSTEM and ENDPOINT pass straight through to make-agent
(the model is reached only transitively via run-until-finished; this
module never imports the provider — R015). INPUT and OUTPUT default to the
standard streams. Returns the chat session."
  (let* ((tr (or transcript (make-transcript)))
         (agent (make-agent :goal     goal
                            :system   system
                            :endpoint endpoint
                            :transcript tr))
         (session (make-chat-session
                   :agent  agent
                   :cursor (transcript-length tr))))
    (chat-loop session
              :input     input
              :output    output
              :max-steps max-steps)))
(export 'chat)

;;; --- the executable toplevel (T04; binary = S03) -------------------
;;;
;;; parse-args is a hand-written loop (R016: no flag library). main is
;;; the save-lisp-and-die toplevel; --help routes to an early return so it
;;; never enters the chat loop. build dumps the image; the actual ./sexpr
;;; binary and the Makefile targets are verified in S03.

(defun parse-args (argv)
  "Parse ARGV (a list of program-argument strings, argv[0] first) into a
plist of options.

argv[0] (the program name) is skipped. Recognizes --goal VALUE, --load
FILE, --help / -h, --provider VALUE, and --model VALUE. A flag expecting
a value that is last (with none following) binds nil. An unrecognized
token is collected under :rest in argv order so the caller can diagnose
it. No external dependency (R016: hand-written, not a flag library)."
  (let ((args (rest argv))            ; skip argv[0] — the program name
        (plist nil)
        (unknown nil))
    (loop :while args
          :do (let ((arg (pop args)))
                (cond
                  ((or (string= arg "--help") (string= arg "-h"))
                   (setf (getf plist :help) t))
                  ((string= arg "--goal")
                   (setf (getf plist :goal) (pop args)))
                  ((string= arg "--load")
                   (setf (getf plist :load) (pop args)))
                  ((string= arg "--provider")
                   (setf (getf plist :provider) (pop args)))
                  ((string= arg "--model")
                   (setf (getf plist :model) (pop args)))
                  (t
                   (push arg unknown)))))
    ;; unknown accumulated in reverse by push; flip to argv order.
    (when unknown
      (setf (getf plist :rest) (nreverse unknown)))
    plist))
(export 'parse-args)

(defun print-usage (&optional (stream *standard-output*))
  "Print the flag list and the slash commands to STREAM.

The flags drive the executable toplevel; the slash commands drive the
chat loop. --help is the one place a human looks, so both surfaces are
listed here."
  (format stream "~&usage: sexpr [--goal TEXT] [--load FILE]~%")
  (format stream "~&                  [--provider NAME] [--model NAME]~%")
  (format stream "~&                  [--help | -h]~%")
  (format stream "~&~%")
  (format stream "~&flags:~%")
  (format stream "~&  --goal TEXT        the agent's goal (required to enter the loop)~%")
  (format stream "~&  --load FILE        start from a saved transcript~%")
  (format stream "~&  --provider NAME    configure the provider transport~%")
  (format stream "~&  --model NAME       configure the model name~%")
  (format stream "~&  --help, -h         print this usage and exit~%")
  (format stream "~&~%")
  (format stream "~&slash commands (inside the chat loop):~%")
  (format stream "~&  /exit              quit the session~%")
  (format stream "~&  /quit              quit the session~%")
  (format stream "~&  /help              show the command list~%")
  (format stream "~&  /transcript        print the whole transcript~%")
  (format stream "~&  /system TEXT       set the system prompt~%")
  (format stream "~&  /save FILE         save the session to FILE~%")
  (format stream "~&  /load FILE         load a session from FILE~%")
  (format stream "~&  /retry             re-run the last model turn~%")
  (finish-output stream))
(export 'print-usage)

(defun main (&optional (argv sb-ext:*posix-argv*) &key input output)
  "The executable toplevel: parse ARGV (defaulting to sb-ext:*posix-argv*)
and dispatch.

--help / -h prints usage and returns — it never enters the chat loop, so
a test or a help-seeking user cannot hang. --provider / --model reach the
provider transport by the single qualified sexpr.provider:configure-provider
reference (R015: :sexpr.provider is NOT in :use). --load FILE reads a
transcript via sexpr.transcript:read-transcript. Then the chat loop runs
with :endpoint nil — the model is reached only transitively via
run-until-finished. INPUT / OUTPUT pass through to chat for testability; a
real run leaves them nil so chat defaults to the standard streams.

Returns nil for --help; otherwise returns the chat session (a real run
exits only on /exit, /quit, EOF, or a second idle Ctrl-C)."
  (let ((opts (parse-args argv)))
    (if (getf opts :help)
        (print-usage (or output *standard-output*))
        (progn
          ;; The ONLY sexpr.provider reference in this module: a qualified
          ;; call, never an import. configure-provider is called
          ;; unconditionally so SEXPR_PROVIDER / SEXPR_MODEL / SEXPR_BASE_URL
          ;; env vars take effect without a CLI flag; when no flags are given
          ;; the list is empty and every supplied-p flag stays false, so
          ;; configure-provider falls through to the env-var branches.
          (apply #'sexpr.provider:configure-provider
                 (nconc (when (getf opts :provider)
                          (list :provider (getf opts :provider)))
                        (when (getf opts :model)
                          (list :model (getf opts :model)))))
          (let ((transcript nil))
            (when (getf opts :load)
              (with-open-file (stream (getf opts :load) :direction :input)
                (setf transcript (read-transcript stream))))
            (chat :goal     (getf opts :goal)
                  :endpoint nil
                  :transcript transcript
                  :input      input
                  :output     output))))))
(export 'main)

(defun build (&optional (name "sexpr"))
  "Dump an executable image named NAME with sexpr.cli:main as the toplevel.

:save-runtime-options t preserves SBCL's SIGINT delivery so a Ctrl-C at
the binary still arrives as sb-sys:interactive-interrupt (R013 under the
executable). save-lisp-and-die terminates the image, so this is defined
but not exercised by the rove suite; the ./sexpr binary and the Makefile
build target are verified in S03."
  (sb-ext:save-lisp-and-die name
    :executable t
    :toplevel 'sexpr.cli:main
    :save-runtime-options t))
(export 'build)
