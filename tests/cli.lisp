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

;;; --- /repl escape (sexpr.repl integration) -------------------------
;;;
;;;; /repl hands chat-loop's input/output to sexpr.repl:repl with the
;;;; live agent. ,exit returns to chat-loop without EOF'ing the shared
;;;; input stream. The REPL is exercised in isolation in tests/repl.lisp;
;;;; these two tests prove the chat-loop wiring (dispatch, *agent*
;;;; binding, return-to-chat, continued turn).

(rove:deftest repl-command-enters-and-returns-to-chat
  "(/repl) enters the REPL, ,exit returns to chat, and a following line
runs a normal turn. The REPL shared chat-loop's input stream, so ,exit
(not EOF) returns control without ending the chat."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "reply" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream
                                  (format nil "/repl~%,exit~%hello"))
                        :output out
                        :max-steps 1)))
    (let ((text (get-output-stream-string out))
          (events (transcript-events
                   (agent-transcript (chat-session-agent session)))))
      (ok (search "REPL" text)
          "the REPL banner was printed on entry")
      (ok (search "reply" text)
          "the model reply rendered after returning from the REPL")
      (ok (= (stub-call-count stub) 1)
          "the model was called once — only the hello line ran a turn")
      (ok (= (length events) 2)
          "the transcript holds the hello user event and the reply model event")
      (ok (eq (event-type (aref events 0)) :user)
          "the first event is the hello user line")
      (ok (eq (event-type (aref events 1)) :model)
          "the second event is the model reply"))))

(rove:deftest repl-command-sees-live-agent
  "(/repl) binds *agent* to the session's agent — (agent-goal *agent*)
at the REPL prompt returns the live goal. No turn runs: ,exit returns
before the model is ever called."
  (let* ((stub (make-instance 'stub-endpoint))
         (out (make-string-output-stream))
         (session (chat :goal "live-goal" :endpoint stub
                        :input  (make-string-input-stream
                                  (format nil "/repl~%(agent-goal *agent*)~%,exit"))
                        :output out
                        :max-steps 1)))
    (declare (ignore session))
    (ok (search "live-goal" (get-output-stream-string out))
        "the live agent's goal was visible via *agent* at the REPL prompt")))

;;;; --- SIGINT abort fixture ------------------------------------------
;;;;
;;;; sigint-stub raises sb-sys:interactive-interrupt on its FIRST provider
;;;; call and returns a normal node afterwards, so the abort path is driven
;;;; deterministically — no real signals, no threads. It is signaled, not
;;;; thrown, because that is the same path a live Ctrl-C takes: SBCL delivers
;;;; an interactive-interrupt from the OS, and a signaled one is caught by the
;;;; identical handler-case form in cli.lisp. Both routes share one handler.
;;;;
;;;; The IDLE two-Ctrl-C-exits contract in chat-loop is implemented in code
;;;; but deliberately NOT covered by an automated test. Simulating a Ctrl-C
;;;; that lands while read-line blocks needs either a real signal (out of
;;;; scope here) or a fixture stream that overrides read-line to signal — but
;;;; in SBCL 2.6.8 both read-line and read-char are ordinary functions, not
;;;; generic, so no stream subclass can interpose. Verified on this build.

(defclass sigint-stub (stub-endpoint)
  ()
  (:documentation "A stub-endpoint that raises sb-sys:interactive-interrupt on
its first provider call and returns a normal node thereafter."))

(defmethod sexpr.provider:provider-call ((endpoint sigint-stub) messages
                                          &key system tools temperature
                                          max-tokens)
  "First call raises sb-sys:interactive-interrupt (an aborted turn); later
calls return a normal :stop node."
  (declare (ignore messages system tools temperature max-tokens))
  (incf (stub-call-count endpoint))
  (if (= (stub-call-count endpoint) 1)
      (error 'sb-sys:interactive-interrupt)
      (list :content "resumed reply" :finish :stop)))

(rove:deftest chat-aborts-a-turn-on-sigint-and-continues
  "A Ctrl-C during a turn aborts it — notice printed, transcript not rolled
back — and the loop returns to the prompt and keeps going (R013)."
  (let* ((stub (make-instance 'sigint-stub))
         (out  (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream
                                  (format nil "hello~%world"))
                        :output out
                        :max-steps 1)))
    (let* ((agent  (chat-session-agent session))
           (tr     (agent-transcript agent))
           (events (transcript-events tr))
           (output (get-output-stream-string out)))
      (ok (search "turn aborted" output)
          "the aborted turn printed its notice")
      (ok (= (stub-call-count stub) 2)
          "the model was called twice — once aborted for hello, once for world")
      (ok (search "resumed reply" output)
          "the second turn ran normally and its reply was rendered")
      (ok (= (length events) 3)
          "the transcript holds user-hello, user-world, and one model reply")
      (ok (eq (event-type (aref events 0)) :user)
          "the aborted turn's user event was kept — no rollback")
      (ok (eq (event-type (aref events 1)) :user)
          "the second line's user event landed after the abort")
      (ok (eq (event-type (aref events 2)) :model)
          "the resumed turn's model reply is the final event")
      (ok (render-events tr)
          "the transcript reads back without error after the abort")
      (ok (= (chat-session-cursor session) (transcript-length tr))
          "the render cursor is consistent with the transcript after the abort"))))

;;; --- parse-args / main (T04; binary build = S03) --------------------
;;;
;;; parse-args is pure: a list of strings in, a plist out. main routes
;;; --help to an early return so the help test never enters the chat loop.
;;; build (sexpr.cli:build) is defined but intentionally NOT exercised —
;;; sb-ext:save-lisp-and-die terminates the image; the ./sexpr binary and
;;; the Makefile build target are verified in S03.

(rove:deftest parse-args-parses-goal-and-load
  "parse-args skips argv[0] and binds --goal and --load to their values."
  (let ((opts (parse-args (list "sexpr" "--goal" "g" "--load" "f.sexp"))))
    (ok (string= (getf opts :goal) "g")
        ":goal is the value after --goal")
    (ok (string= (getf opts :load) "f.sexp")
        ":load is the value after --load")))

(rove:deftest parse-args-help-flag-returns-help
  "parse-args binds :help to t for --help and for -h."
  (ok (getf (parse-args (list "sexpr" "--help")) :help)
      ":help is true for --help")
  (ok (getf (parse-args (list "sexpr" "-h")) :help)
      ":help is true for -h"))

(rove:deftest parse-args-collects-unknown-flags-under-rest
  "An unrecognized token does not crash parse-args; known flags still bind
and unknown tokens collect under :rest in argv order (negative path)."
  (let ((opts (parse-args (list "sexpr" "--bogus" "--goal" "g" "--zzz"))))
    (ok (string= (getf opts :goal) "g")
        "the known --goal still binds despite surrounding unknowns")
    (ok (equal (getf opts :rest) '("--bogus" "--zzz"))
        "unknown tokens are collected under :rest in argv order")))

(rove:deftest parse-args-capability-flag-adds-to-grants
  "--capability VALUE appends the value (lowercased) to :capabilities,
and is repeatable so multiple grants accumulate in argv order."
  (let ((opts (parse-args (list "sexpr"
                                "--capability" "fs-write"
                                "--capability" "process"))))
    (ok (equal (getf opts :capabilities)
               '("fs-write" "process"))
        "two --capability flags produce two entries in argv order")))

(rove:deftest parse-args-capability-accepts-comma-separated-list
  "A single --capability flag accepts a comma-separated list, so the
shell wrapper can forward the SEXPR_CAPABILITIES env var (e.g. the
value fs-read,fs-write) as one flag; entries are lowercased,
whitespace-trimmed, and empty entries dropped."
  (let ((opts (parse-args (list "sexpr"
                                "--capability" "fs-read,FS-WRITE"))))
    (ok (equal (getf opts :capabilities)
               '("fs-read" "fs-write"))
        "comma-separated values are split, lowercased, and both kept"))
  (let ((opts (parse-args (list "sexpr"
                                "--capability" " fs-read ,, fs-write "))))
    (ok (equal (getf opts :capabilities)
               '("fs-read" "fs-write"))
        "empty entries and whitespace are dropped")))

(rove:deftest parse-args-capability-without-value-signals
  "--capability as the last token with no value following signals an
error — a truncated argv must not silently grant nothing."
  (ok (not (null (handler-case (parse-args (list "sexpr" "--capability"))
                                     (error (c) c))))
      "--capability with no value signals an error"))

(rove:deftest chat-capabilities-keyword-grants-write
  "chat with :capabilities '(:fs-read :fs-write) gives the agent that
exact set — the caller supplies the final grant list; chat does not
union. A chat with no :capabilities argument keeps make-agent's default
'(:fs-read)."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :capabilities '(:fs-read :fs-write)
                        :input  (make-string-input-stream "/exit")
                        :output out
                        :max-steps 1)))
    (declare (ignore out))
    (ok (equal (agent-capabilities (chat-session-agent session))
               '(:fs-read :fs-write))
        ":capabilities '(:fs-read :fs-write) reaches the agent")))

(rove:deftest chat-defaults-to-fs-read-without-capabilities-arg
  "Omitting :capabilities from chat leaves make-agent's default
(:fs-read) intact — chat must not clobber it."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (out (make-string-output-stream))
         (session (chat :goal "g" :endpoint stub
                        :input  (make-string-input-stream "/exit")
                        :output out
                        :max-steps 1)))
    (declare (ignore out))
    (ok (equal (agent-capabilities (chat-session-agent session))
               '(:fs-read))
        "omitting :capabilities leaves the default (:fs-read)")))

(rove:deftest main-help-prints-usage-and-returns-without-chat
  "main with --help prints usage to the output stream and returns without
entering the chat loop — no endpoint, no goal, so make-agent would signal
if main had called chat."
  (let ((out (make-string-output-stream)))
    (ok (null (main (list "sexpr" "--help") :output out))
        "main returns nil for --help without entering chat")
    (ok (search "--goal" (get-output-stream-string out))
        "the usage output mentions the --goal flag")))

(rove:deftest main-help-mentions-capability-flag
  "print-usage mentions --capability and the four known capability names
so a help-seeking user can discover the flag without grepping source."
  (let ((out (make-string-output-stream)))
    (declare (ignore out))
    (print-usage out)
    (let ((text (get-output-stream-string out)))
      (ok (search "--capability" text)
          "usage mentions --capability")
      (ok (search "fs-write" text)
          "usage names fs-write")
      (ok (search "process" text)
          "usage names process")
      (ok (search "lisp-eval" text)
          "usage names lisp-eval"))))

(rove:deftest main-capability-flag-grants-are-unioned-with-default
  "main --capability fs-write passes :fs-read :fs-write (union with the
default) through to chat → make-agent, and does not clobber it. --capability
without a companion flag still grants fs-read via the default; fs-read is
added exactly once, so requesting it explicitly is a no-op that stays
idempotent."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (in (make-string-input-stream "/exit"))
         (out (make-string-output-stream))
         (session (main (list "sexpr" "--goal" "g" "--capability" "fs-write")
                        :input in
                        :output out)))
    (declare (ignore out))
    (let ((caps (agent-capabilities (chat-session-agent session))))
      (ok (member :fs-write caps :test #'eq)
          "--capability fs-write grants :fs-write")
      (ok (member :fs-read caps :test #'eq)
          "the default :fs-read is still granted alongside")
      (ok (= (count :fs-read caps :test #'eq) 1)
          ":fs-read appears exactly once after the union"))))

(rove:deftest main-multiple-capability-grants-accumulate-and-dedup
  "Multiple --capability occurrences accumulate and duplicates collapse:
`--capability fs-write --capability fs-write --capability process`
yields {:fs-read :fs-write :process}, each exactly once."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (in (make-string-input-stream "/exit"))
         (out (make-string-output-stream))
         (session (main (list "sexpr" "--goal" "g"
                              "--capability" "fs-write"
                              "--capability" "fs-write"
                              "--capability" "process")
                        :input in
                        :output out)))
    (declare (ignore out))
    (let ((caps (agent-capabilities (chat-session-agent session))))
      (ok (member :fs-write caps :test #'eq)
          "--capability fs-write (twice) grants :fs-write once")
      (ok (member :process caps :test #'eq)
          "--capability process grants :process")
      (ok (member :fs-read caps :test #'eq)
          "the default :fs-read is still granted")
      (ok (= (length caps) 3)
          "no duplicates: the union collapses to three distinct capabilities"))))

(rove:deftest main-comma-separated-capability-works-through-chat
  "A single --capability fs-read,fs-write flag grants both capabilities
through to the agent."
  (let* ((stub (make-instance 'stub-endpoint
                              :responses (list (list :content "r" :finish :stop))))
         (in (make-string-input-stream "/exit"))
         (out (make-string-output-stream))
         (session (main (list "sexpr" "--goal" "g"
                              "--capability" "fs-read,fs-write")
                        :input in
                        :output out)))
    (declare (ignore out))
    (let ((caps (agent-capabilities (chat-session-agent session))))
      (ok (member :fs-write caps :test #'eq)
          "comma-separated fs-write is granted")
      (ok (member :fs-read caps :test #'eq)
          "comma-separated fs-read is granted (via union with default)")
      (ok (= (length caps) 2)
          "no duplicates across the union"))))
