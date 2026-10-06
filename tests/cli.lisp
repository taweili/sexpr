;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/cli.lisp — the chat loop.
;;;;
;;;; Scope: sexpr.cli renders one model reply per entered line against a
;;;; stub-endpoint (reused from tests/kernel.lisp). No network, no real
;;;; provider (invariant #1).

(in-package :sexpr-tests)

;;; --- package loads ---------------------------------------------------

(rove:deftest sexpr-cli-package-loads
  "The :sexpr.cli module loads and exports the :$.cli nickname."
  (ok (find-package :sexpr.cli) "the :sexpr.cli package exists")
  (ok (find-package :$.cli) "the :$.cli nickname resolves"))

;;; --- chat loop ------------------------------------------------------

(rove:deftest chat-loop-runs-a-turn-per-line-and-renders-replies
  "One scripted line yields one user event, one model event, one call."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "hi there"
                                                     :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "hello")
                        :output out
                        :max-steps 1)))
    (let ((output (get-output-stream-string out))
          (events (transcript-events
                   (agent-transcript (chat-session-agent session)))))
      (ok (search "hi there" output)
          "the model reply is rendered to the output stream")
      (ok (= (length events) 2)
          "the transcript holds one user event then one model event")
      (ok (eq (event-type (aref events 0)) :user)
          "the first event is the user line")
      (ok (eq (event-type (aref events 1)) :model)
          "the second event is the model reply")
      (ok (= (stub-call-count stub) 1)
          "the model was called exactly once for one user line"))))

;;; --- slash commands (R010) ------------------------------------------
;;;;
;;;; One rove deftest per command, asserting the observable effect. Each
;;;; drives the chat loop with a scripted input stream and inspects the
;;;; session or output stream. The stub-endpoint from tests/kernel.lisp is
;;;; reused — no network, no real provider.

(rove:deftest exit-command-returns-from-chat-loop
  "(/exit) returns from chat-loop with no turn run and no user event."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/exit")
                        :output out
                        :max-steps 1)))
    (ok (= (stub-call-count stub) 0)
        "the model was never called — /exit returns before any turn")
    (ok (= (transcript-length
             (agent-transcript (chat-session-agent session))) 0)
        "no user event was appended — /exit is a command, not input")))

(rove:deftest quit-command-returns-from-chat-loop
  "(/quit) returns from chat-loop with no turn run."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/quit")
                        :output out
                        :max-steps 1)))
    (declare (ignore session))
    (ok (= (stub-call-count stub) 0)
        "the model was never called — /quit returns before any turn")))

(rove:deftest help-command-prints-usage
  "(/help) prints a usage list mentioning each command name."
  (let* ((stub (make-instance 'stub-endpoint))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/help")
                        :output out
                        :max-steps 1)))
    (declare (ignore session))
    (ok (search "transcript" (get-output-stream-string out))
        "the help output mentions /transcript")))

(rove:deftest system-command-sets-the-persona
  "(/system TEXT) sets agent-system to TEXT."
  (let* ((stub (make-instance 'stub-endpoint))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/system p")
                        :output out
                        :max-steps 1)))
    (declare (ignore out))
    (ok (string= (agent-system (chat-session-agent session)) "p")
        "agent-system holds the text after /system")))

(rove:deftest transcript-command-prints-history
  "(/transcript) prints the whole transcript including prior events."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "reply"
                                                     :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream
                                  (format nil "hello~%/transcript"))
                        :output out
                        :max-steps 1)))
    (declare (ignore session))
    ;; render-events produces numbered lines like "#0<user> hello";
    ;; the <user> marker only appears in /transcript output, not in the
    ;; normal turn rendering.
    (ok (search "<user>" (get-output-stream-string out))
        "the transcript output shows the numbered event format")))

(rove:deftest save-then-load-round-trips-a-session
  "(/save FILE then /load FILE) round-trips the transcript unchanged (R012)."
  ;; uiop:with-temporary-file generates a unique temp path — no hardcoded /tmp.
  ;; The file persists for the duration of the body and is cleaned up after.
  (uiop:with-temporary-file (:pathname file)
    (let* ((stub (make-instance 'stub-endpoint
                                :responses (list (list :content "reply"
                                                       :finish :stop))))
           (out1 (make-string-output-stream))
           (session1 (chat :goal "g" :endpoint stub
                           :input  (make-string-input-stream
                                    (format nil "hello~%/save ~a" file))
                           :output out1
                           :max-steps 1))
           (old-events (events-list
                         (agent-transcript (chat-session-agent session1)))))
      (let* ((stub2 (make-instance 'stub-endpoint))
             (out2 (make-string-output-stream))
             (session2 (chat :goal "g" :endpoint stub2
                             :input  (make-string-input-stream
                                      (format nil "/load ~a" file))
                             :output out2
                             :max-steps 1))
             (new-events (events-list
                          (agent-transcript (chat-session-agent session2)))))
        (ok (equalp old-events new-events)
            "save then load round-trips the transcript events unchanged")))))

(rove:deftest retry-command-pops-and-reruns
  "(/retry) pops the trailing model event and re-runs one turn."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "first" :finish :stop)
                                               (list :content "second" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream
                                  (format nil "hello~%/retry"))
                        :output out
                        :max-steps 1)))
    (let ((events (transcript-events
                   (agent-transcript (chat-session-agent session)))))
      (ok (= (stub-call-count stub) 2)
          "the model was called twice — once for hello, once for /retry")
      (ok (= (length events) 2)
          "the transcript holds user + one model event (the first was popped)")
      (ok (eq (event-type (aref events 0)) :user)
          "the first event is still the user line")
      (ok (eq (event-type (aref events 1)) :model)
          "the second event is the re-run model reply")
      (ok (string= (event-content (aref events 1)) "second")
          "the new model event is the second stub response"))))

(rove:deftest retry-with-no-model-event-prints-a-notice
  "(/retry) with no trailing model event prints a notice and does not call the model."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/retry")
                        :output out
                        :max-steps 1)))
    (declare (ignore session))
    (ok (search "nothing to retry" (get-output-stream-string out))
        "the output mentions 'nothing to retry'")
    (ok (= (stub-call-count stub) 0)
        "the model was not called — nothing to retry")))

(rove:deftest unknown-command-prints-and-continues
  "An unknown /foo prints 'unknown command: foo' and continues — no user event, no turn."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/nope")
                        :output out
                        :max-steps 1)))
    (ok (search "unknown" (get-output-stream-string out))
        "the output mentions 'unknown'")
    (ok (= (stub-call-count stub) 0)
        "no turn was run for an unknown command")
    (ok (= (transcript-length
             (agent-transcript (chat-session-agent session))) 0)
        "no user event was appended for an unknown command")))
