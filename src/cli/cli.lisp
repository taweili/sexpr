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
;;;; never imports the provider transport. (The single qualified
;;;; sexpr.provider:configure-provider reference for --provider/--model
;;;; lands in the arg parser — a later task.)

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

;;; --- the chat loop (R009) -----------------------------------------

(defun chat-loop (session &key input output (max-steps 1))
  "Drive SESSION's chat loop: read a line from INPUT, append it as a user
event, run one bounded turn (MAX-STEPS), and render the new transcript
events to OUTPUT. Repeat until INPUT reaches EOF.

INPUT and OUTPUT default to *standard-input* and *standard-output* so the
loop runs on a live terminal, but tests pass string streams. The render
cursor skips the just-entered user event (the human already sees their
input) and prints only the model's new events in [cursor,
transcript-length). A Ctrl-C (sb-sys:interactive-interrupt) during a turn
aborts it and returns to the prompt (R013); the partial transcript stays
readable. Returns SESSION.

Read EOF with the missing-arg form (read-line input nil :eof) and test
the sentinel — never the error-signaling form, or scripted input hangs."
  (let ((agent (chat-session-agent session))
        (in    (or input  *standard-input*))
        (out   (or output *standard-output*)))
    (loop :for line = (read-line in nil :eof)
          :until (eq line :eof)
          :do
          (let ((tr (agent-transcript agent)))
            ;; The human already sees their line on the terminal; record it
            ;; and point the cursor past it so only model events render.
            (append-event tr (make-user-event line))
            (setf (chat-session-cursor session) (transcript-length tr))
            ;; One bounded turn. A Ctrl-C aborts it and returns to the
            ;; prompt (R013). The handler body is finalized in a later
            ;; task; for now it notes the abort.
            (handler-case
                (run-until-finished agent :max-steps max-steps)
              (sb-sys:interactive-interrupt ()
                (format out "~&; [interrupted — turn aborted]~%")))
            ;; Render the model's new events in [cursor, new-length).
            (let* ((events  (transcript-events tr))
                   (new-len (length events))
                   (start   (chat-session-cursor session)))
              (loop :for i :from start :below new-len
                    :do (format out "~&~a~%" (render-event (aref events i))))
              (setf (chat-session-cursor session) new-len))
            (finish-output out))))
  session)
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
