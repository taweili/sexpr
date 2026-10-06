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
