;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/tui-integration.lisp — integration tests for the M004/S01 surface.
;;;;
;;;; Scope: the event bus, model-step-streaming, and the sexpr.tui RPC stubs
;;;; work together end-to-end inside the loaded :sexpr image. These are rove
;;;; tests that run under `make test` alongside the rest of the suite.
;;;;
;;;; (1) event bus: subscribe → emit → listener receives.
;;;; (2) model-step-streaming: a stubbed cl-llm-provider:complete-stream feeds
;;;;     chunks; :delta events fire on the bus and the returned model event
;;;;     carries the accumulated content + finish reason.
;;;; (3) agent-snapshot: registered agents appear as plists with the expected
;;;;     keys (name, status, transcript-length, …).
;;;; (4) transcript-delta: the cursor advances and returns the right slice.
;;;;
;;;; R015: sexpr.tui is reached by qualified name; :sexpr.provider is never
;;;; imported here. The streaming path stubs cl-llm-provider:complete-stream
;;;; (a plain function) via FDEFINITION redefinition so no network call is made.

(in-package :sexpr-tests)

;;; --- fake streaming provider ---------------------------------------
;;;;
;;;; model-step-streaming (D017) calls cl-llm-provider:complete-stream (a
;;;; plain function), so it is stubbed via FDEFINITION redefinition inside the
;;;; streaming test and restored in an UNWIND-PROTECT. read-stream-chunk and
;;;; stream-accumulated-content are generic, so a fake-stream class adds
;;;; methods specialized on it. Real cl-llm-provider:stream-chunk instances
;;;; exercise chunk-delta natively — no stub needed for that accessor.

(defclass fake-stream ()
  ((chunks :initarg :chunks :accessor fake-chunks
           :documentation "Canned stream-chunk instances, consumed in order.")
   (content :initarg :content :accessor fake-content
            :documentation "The string stream-accumulated-content returns.")))

(defmethod cl-llm-provider:read-stream-chunk ((stream fake-stream) &key timeout)
  (declare (ignore timeout))
  (if (fake-chunks stream)
      (pop (fake-chunks stream))
      nil))

(defmethod cl-llm-provider:stream-accumulated-content ((stream fake-stream))
  (fake-content stream))

(defun make-fake-chunk (delta &key (finish-reason nil) (usage nil))
  "A real cl-llm-provider:stream-chunk so chunk-delta is read natively."
  (make-instance 'cl-llm-provider:stream-chunk
                 :delta delta
                 :content delta
                 :finish-reason finish-reason
                 :usage usage
                 :index 0))

;;; --- (1) event bus --------------------------------------------------

(rove:deftest event-bus-delivers-emitted-events-to-subscribed-listeners
  (clrhash *event-bus*)
  ;; let* so `listener' captures `received' — a plain `let' evaluates
  ;; initforms in the outer scope where `received' is not yet visible.
  (let* ((received nil)
         (listener (lambda (event) (push event received))))
    (unwind-protect
         (progn
           (subscribe-event-bus "int-bus-1" listener)
           (emit-event "int-bus-1"
                       (list :type :delta :agent-id "int-bus-1"
                             :chunk-delta "hi"))
           (ok (= (length received) 1)
               "the listener received exactly one event")
           (ok (equal (first received)
                     (list :type :delta :agent-id "int-bus-1"
                       :chunk-delta "hi"))
               "the received event matches what was emitted"))
      (unsubscribe-event-bus "int-bus-1" listener))))

;;; --- (2) model-step-streaming ---------------------------------------

(rove:deftest model-step-streaming-emits-delta-events-and-returns-a-model-event
  (clrhash *event-bus*)
  (let ((received nil)
        (real-cs (fdefinition 'cl-llm-provider:complete-stream))
        (real-stc (fdefinition 'cl-llm-provider:stream-tool-calls)))
    (unwind-protect
         (progn
           (subscribe-event-bus "int-streamer"
                                (lambda (e) (push e received)))
           (setf (fdefinition 'cl-llm-provider:complete-stream)
                 (lambda (messages &key provider model max-tokens temperature
                                   system tools tool-choice stop
                                   on-chunk on-complete on-error
                             &allow-other-keys)
                   (declare (ignore messages provider model max-tokens
                                    temperature system tools tool-choice
                                    stop on-chunk on-complete on-error))
                   (make-instance 'fake-stream
                                  :chunks (list (make-fake-chunk "Hello")
                                                (make-fake-chunk " world")
                                                (make-fake-chunk ""
                                                                 :finish-reason :stop))
                                  :content "Hello world")))
           (setf (fdefinition 'cl-llm-provider:stream-tool-calls)
                 (lambda (stream)
                   (if (typep stream 'fake-stream)
                       nil
                       (funcall real-stc stream))))
           (let ((event (model-step-streaming
                         (spawn :goal "g" :name "int-streamer"
                                :endpoint :ollama))))
             (ok (= (length received) 3)
                 "three :delta events were emitted — one per chunk")
             (ok (every (lambda (e) (eq (getf e :type) :delta))
                        received)
                 "every emitted event is a :delta event")
             (ok (equal (mapcar (lambda (e) (getf e :chunk-delta))
                                (nreverse received))
                        '("Hello" " world" ""))
                 "chunk-deltas arrive in stream order")
             (ok (eq (event-type event) :model)
                 "the returned event is a model event")
             (ok (string= (event-content event) "Hello world")
                 "the event content is the accumulated stream content")
             (ok (eq (event-finish event) :stop)
                 "the event finish reason comes from the final chunk")))
      (setf (fdefinition 'cl-llm-provider:complete-stream) real-cs)
      (setf (fdefinition 'cl-llm-provider:stream-tool-calls) real-stc))))

;;; --- (3) agent-snapshot ---------------------------------------------

(rove:deftest agent-snapshot-returns-a-plist-per-registered-agent
  (clrhash sexpr.agents:*agent-table*)
  (unwind-protect
       (let ((a1 (sexpr.agents:register-agent!
                  (spawn :goal "g1" :name "int-snap-1")))
             (a2 (sexpr.agents:register-agent!
                  (spawn :goal "g2" :name "int-snap-2"
                         :endpoint :ollama))))
         ;; Give a1 a two-event transcript so transcript-length is observable.
         (append-event (agent-transcript a1) (make-model-event "hello"))
         (append-event (agent-transcript a1) (make-model-event "world"))
         (let ((snap (sexpr.tui:agent-snapshot)))
           (ok (= (length snap) 2)
               "one plist per registered agent")
           (ok (every (lambda (entry)
                        (and (consp entry)
                             (eq (first entry) :name)
                             (stringp (getf entry :name))
                             (member (getf entry :status)
                                     '(:running :finished :failed :killed))
                             (typep (getf entry :thread-alive-p) 'boolean)
                             (integerp (getf entry :transcript-length))
                             (listp (getf entry :capabilities))))
                      snap)
               "every entry has the required plist keys")
           (let ((e1 (find "int-snap-1" snap
                            :key (lambda (e) (getf e :name))
                            :test #'string=)))
             (ok e1 "int-snap-1 appears in the snapshot")
             (ok (= (getf e1 :transcript-length) 2)
                 "transcript-length reflects the two appended events"))
           (let ((e2 (find "int-snap-2" snap
                            :key (lambda (e) (getf e :name))
                            :test #'string=)))
             (ok (eq (getf e2 :endpoint) :ollama)
                 "int-snap-2's endpoint keyword is carried through"))))
    (clrhash sexpr.agents:*agent-table*)))

;;; --- (4) transcript-delta -------------------------------------------

(rove:deftest transcript-delta-advances-the-cursor
  (clrhash sexpr.agents:*agent-table*)
  (unwind-protect
       (let ((a (sexpr.agents:register-agent!
                 (spawn :goal "g" :name "int-delta-1"))))
         (append-event (agent-transcript a) (make-model-event "one"))
         (append-event (agent-transcript a) (make-model-event "two"))
         (append-event (agent-transcript a) (make-model-event "three"))
         ;; cursor 0 → all events, new cursor = 3
         (let ((pair0 (sexpr.tui:transcript-delta "int-delta-1" 0)))
           (ok (= (length (car pair0)) 3)
               "cursor 0 returns all three events")
           (ok (= (cdr pair0) 3)
               "the new cursor is the total event count"))
         ;; cursor 1 → events from index 1 onward, new cursor = 3
         (let ((pair1 (sexpr.tui:transcript-delta "int-delta-1" 1)))
           (ok (= (length (car pair1)) 2)
               "cursor 1 returns the last two events")
           (ok (= (cdr pair1) 3)
               "the new cursor is still the total count")
           (ok (string= (event-content (first (car pair1))) "two")
               "the first event at cursor 1 is 'two'"))
         ;; cursor 3 (at the tail) → no new events, new cursor = 3
         (let ((pair3 (sexpr.tui:transcript-delta "int-delta-1" 3)))
           (ok (null (car pair3))
               "cursor at the tail returns no new events")
           (ok (= (cdr pair3) 3)
               "the new cursor is the total count even at the tail")))
    (clrhash sexpr.agents:*agent-table*)))

;;; --- negative: transcript-delta on an unknown agent ----------------

(rove:deftest transcript-delta-signals-on-an-unknown-agent
  (clrhash sexpr.agents:*agent-table*)
  (ok (signals (sexpr.tui:transcript-delta "int-nope" 0))
      "transcript-delta on an unknown agent name signals an error"))
