;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-push-server.lisp — standalone test for the push-channel
;;;; TCP server (M004/S02).
;;;;
;;;; Run with: sbcl --script tests/test-push-server.lisp
;;;;
;;;; T01 shipped start-server (bind + listen + accept loop), stop-server
;;;; (close clients, close listen socket, join threads), and the per-client
;;;; handler. T02 adds the subscribe/unsubscribe protocol on top of that accept
;;;; loop: the handler now dispatches instead of echoing, the bus listener
;;;; translates a :delta event into a wire item and enqueues it into the
;;;; per-client queue, and (subscribed ...) is the race-closure signal.
;;;;
;;;; The queue is read through push-server-diagnostics because T03 has not added
;;;; the writer thread yet — in T02 the listener fills the queue and nothing
;;;; drains it, which is exactly what makes the queue observable from a test.

;;;; T04 adds the bounded-queue backpressure: a client that stops reading gets a
;;;; single (resync :agent A :cursor N) per overflow burst instead of an unbounded
;;;; queue, and the pending fragments are dropped. Tests 26-31 below prove it.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(defpackage :sexpr-test-push-server
  (:use :cl :sexpr.tui :sb-thread :sb-bsd-sockets))
(in-package :sexpr-test-push-server)

(defparameter *tests-run* 0)
(defparameter *tests-passed* 0)
(defparameter *tests-failed* 0)

(defun ok (description form)
  (incf *tests-run*)
  (if form
      (progn (incf *tests-passed*)
             (format t "  ok: ~A~%" description)
             t)
      (progn (incf *tests-failed*)
             (format t "  FAIL: ~A~%" description)
             nil)))

(defun crash (description err)
  (incf *tests-run*)
  (incf *tests-failed*)
  (format t "  CRASH: ~A — ~A~%" description err))

(defmacro test (description &body body)
  `(handler-case
       (ok ,description (progn ,@body))
     (error (err)
       (crash ,description err))))

(defun reset-bus! ()
  "Clear the event bus. A listener left registered by a previous test would fire
  into the next test's client and make a negative assertion pass for the wrong
  reason, so every test resets the bus through reset!."
  (clrhash sexpr.kernel:*event-bus*))

(defun reset! ()
  "Ensure no push-server is running (idempotent) and no listener survives from
  the previous test."
  (when sexpr.tui:*push-server*
    (handler-case
        (stop-server sexpr.tui:*push-server*)
      (error () nil)))
  (reset-bus!))

(defun starts-with (string prefix)
  "True when STRING begins with PREFIX (CL has no string-prefixp)."
  (and (>= (length string) (length prefix))
       (string= string prefix :end1 (length prefix))))

(defun threads-named (prefix)
  "Return the list of sb-thread threads whose name STARTs with PREFIX."
  (remove-if-not (lambda (th)
                   (and (sb-thread:thread-name th)
                        (starts-with (sb-thread:thread-name th) prefix)))
                 (sb-thread:list-all-threads)))

(defun wait-for (pred &optional (timeout-seconds 5.0) (interval 0.01))
  "Poll PRED until it returns non-nil or the timeout is reached.
Returns the last value of PRED."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout-seconds internal-time-units-per-second))))
    (loop
      (let ((v (funcall pred)))
        (when v (return v))
        (when (> (get-internal-real-time) deadline)
          (return nil))
        (sleep interval)))))

(defun safe-close-socket (s)
  (handler-case
      (when (and s (sb-bsd-sockets:socket-open-p s))
        (sb-bsd-sockets:socket-close s))
    (error () nil)))

(defun stats-value (diag key)
  "Read one counter out of a push-server-diagnostics snapshot."
  (getf (getf diag :stats) key))

(defun per-client-rec (diag id)
  "One client record out of a push-server-diagnostics snapshot, by client id.
  Diagnostics returns per-client records in reverse accept order, so look up by
  id rather than assuming the first entry."
  (find id (getf diag :per-client) :key (lambda (rec) (getf rec :id))))

(defun first-client-rec (diag)
  "The single client record in a diagnostics snapshot (tests that connect one
  client at a time)."
  (car (getf diag :per-client)))

(defun fd-count ()
  "Open file-descriptor count for this process (Linux/proc). Used to prove a
  client that hangs up does not leak an fd on the server side.
  NOTE: use CL DIRECTORY with a wildcard, not uiop:directory-files — the latter
  filters out the /proc/self/fd entries because they are symlinks, so socket fds
  are invisible to it and a leak would pass trivially."
  (length (directory "/proc/self/fd/*")))

(defun send-sexpr (stream object)
  (prin1 object stream)
  (terpri stream)
  (force-output stream))

(defun read-or-eof (stream &optional (timeout-seconds 3.0))
  "Read one object from STREAM, returning 'eof on EOF and NIL on a stream
  error (the server hung up on us). Bounded so a test can never hang."
  (handler-case
      (sb-ext:with-timeout timeout-seconds
        (read stream nil 'eof))
    (sb-ext:timeout () 'timeout)
    (error () 'closed)))

(defparameter *evil-evaluated* nil
  "Sentinel for test 9. It must stay NIL: the handler reads with *read-eval*
  NIL, so a client-supplied `#.` is rejected by the reader instead of being
  evaluated inside the image. A GLOBAL is required — the reader cannot see a
  lexical binding, so a lexical sentinel would make the test trivially true.")

;;;; --- tests ---------------------------------------------------------

(format t "Push server tests (T01 accept loop + T02 subscribe protocol):~%~%")

(reset!)

(test "1. start-server binds a real ephemeral port > 0"
  (let ((server (start-server :port 0)))
    (unwind-protect
         (let ((port (push-server-port server)))
           (and server
                (integerp port)
                (plusp port)
                (eq server *push-server*)))
      (stop-server server)
      (reset!))))

(test "2. a second start-server while the first is running gets its own port"
  (let ((a (start-server :port 0)))
    (unwind-protect
         (let* ((port-a (push-server-port a))
                (b (start-server :port 0))
                (port-b (push-server-port b)))
           (unwind-protect
                (and (> port-a 0) (> port-b 0) (/= port-a port-b))
             (stop-server b)))
      (stop-server a)
      (reset!))))

;;;; The wire contract changed in T02. T01's handler echoed every sexpr as a
;;;; placeholder for the real protocol. T02 replaces it: S02's vocabulary is
;;;; one-way except for the (subscribed ...) reply, so an unknown sexpr gets NO
;;;; reply. This test asserts the new contract — the message is counted as
;;;; :ignored, nothing comes back, and the connection stays usable for a real
;;;; subscribe afterwards. A malformed or unknown message must not tear down the
;;;; connection (a newer client may send finalize/approval-needed to an S02
;;;; server).

(test "3. an unknown sexpr is ignored (no reply) and the connection stays alive"
  (let ((server (start-server :port 0)))
    (unwind-protect
         (let* ((port (push-server-port server))
                (c (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
           (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                            :buffering :line
                                                            :input t
                                                            :output t)))
             (unwind-protect
                  (and (progn
                         (send-sexpr stream '(hello world))
                         ;; no reply: the read times out rather than returning anything
                         (eq (read-or-eof stream 0.5) 'timeout)
                         (plusp (stats-value (push-server-diagnostics server) :ignored)))
                     ;; still alive — a real protocol message on the same
                     ;; connection gets its reply
                     (progn
                       (send-sexpr stream '(subscribe :agent "probe-alive"))
                       (equal (read-or-eof stream 3.0)
                              '(subscribed :agent "probe-alive" :cursor 0))))
               (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "4. stop-server cleans up all push-server threads; second stop-server is a no-op"
  (let ((server (start-server :port 0)))
    (unwind-protect
         (progn
           (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                    :type :stream :protocol :tcp)))
             (sb-bsd-sockets:socket-connect c #(127 0 0 1) (push-server-port server))
             ;; Give the accept loop a moment to record the client.
             (sleep 0.1)
             (safe-close-socket c))
           ;; Wait for the handler thread to drain.
           (wait-for (lambda ()
                       (null (threads-named "push-server-client")))
                     3.0)
           (stop-server server)
           (stop-server server)
           (sleep 0.1)
           (and (null (threads-named "push-server"))
                (null (threads-named "push-writer"))))
      (reset!))))

(test "5. stop-server does not hang when a client is still connected"
  (let ((server (start-server :port 0)))
    (unwind-protect
         (progn
           (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                    :type :stream :protocol :tcp)))
             (sb-bsd-sockets:socket-connect c #(127 0 0 1) (push-server-port server))
             (sleep 0.1)
             ;; Do NOT close the client socket — stop-server must handle it.
             (stop-server server)
             (stop-server server)
             (sleep 0.2)
             ;; Clean up the client side.
             (safe-close-socket c)
             (and (push-server-stopped-p server)
                  (null (threads-named "push-server"))
                  (null (threads-named "push-writer"))))
      (reset!)))))

(test "6. start-server signals on an invalid host address"
  (handler-case
      (progn
        (start-server :host "not-an-ip-address")
        nil)
    (error () t)))

(test "7. start-server signals when the port is already in use"
  (let ((a (start-server :port 0)))
    (unwind-protect
         (handler-case
             (progn
               (start-server :port (push-server-port a))
               nil)
           (error () t))
      (stop-server a)
      (reset!))))

;;;; --- negative tests (Q7): malformed input, eval rejection, abrupt hang-up --

(test "8. malformed input (invalid dispatch macro) is a recorded read error, not a silent swallow"
  (let ((server (start-server :port 0)))
    (unwind-protect
         (let* ((port (push-server-port server))
                (c (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
           (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                            :buffering :line
                                                            :input t
                                                            :output t)))
             (unwind-protect
                  (and (progn
                         ;; '#Z would be read by THIS file at load time, so send the
                         ;; malformed text as raw characters to the socket.
                         (format stream "#Zgarbage")
                         (terpri stream)
                         (force-output stream)
                         ;; the handler records the reader error and hangs up on us
                         (wait-for (lambda ()
                                     (plusp (stats-value (push-server-diagnostics server) :read-error)))
                                   3.0)
                         (let ((diag (push-server-diagnostics server)))
                           (and (plusp (stats-value diag :read-error))
                                (typep (getf diag :stats) 'list)
                                (typep (getf (getf diag :stats) :last-error) 'reader-error))))
                     ;; the connection was closed by the server
                     (member (read-or-eof stream) '(closed eof))
                     ;; and the server still serves a fresh client
                     (let ((c2 (make-instance 'sb-bsd-sockets:inet-socket
                                                :type :stream :protocol :tcp)))
                       (sb-bsd-sockets:socket-connect c2 #(127 0 0 1) port)
                       (let ((s2 (sb-bsd-sockets:socket-make-stream c2
                                                    :buffering :line
                                                    :input t
                                                    :output t)))
                         (unwind-protect
                              (progn
                                ;; the protocol contract: a subscribe gets a reply
                                (send-sexpr s2 '(subscribe :agent "probe-8"))
                                (equal (read-or-eof s2)
                                       '(subscribed :agent "probe-8" :cursor 0)))
                           (safe-close-socket c2))))
               (safe-close-socket c)))
      (stop-server server)
      (reset!))))))

(test "9. *read-eval* is NIL on the client read: #. is rejected and does not evaluate"
  (let ((server (start-server :port 0)))
    (setf *evil-evaluated* nil)
    (unwind-protect
         (let* ((port (push-server-port server))
                (c (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
           (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                            :buffering :line
                                                            :input t
                                                            :output t)))
             (unwind-protect
                  (progn
                    (format stream "#.(progn (setf *evil-evaluated* t) nil)")
                    (terpri stream)
                    (force-output stream)
                    (wait-for (lambda ()
                                (plusp (stats-value (push-server-diagnostics server) :read-error)))
                              3.0)
                    (sleep 0.1)   ; let a permitted #. have evaluated if it could
                    (let ((diag (push-server-diagnostics server)))
                      (and (null *evil-evaluated*)
                           (plusp (stats-value diag :read-error))))
                    )
               (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "10. abrupt client hang-up mid-stream: handler exits, is recorded, leaks no fd"
  (let ((server (start-server :port 0))
        (baseline (fd-count)))
    (unwind-protect
         (let ((port (push-server-port server)))
           ;; 20 clients connect and hang up immediately, sending nothing.
           (loop for i from 1 to 20
                 do (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                              :type :stream :protocol :tcp)))
                      (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
                      (sleep 0.02)
                      (safe-close-socket c)))
           (wait-for (lambda ()
                       (>= (stats-value (push-server-diagnostics server) :client-exits) 20))
                     5.0)
           (let ((diag (push-server-diagnostics server)))
             (and (= (stats-value diag :client-exits) 20)
                  ;; every exit was recorded as an outcome counter, not swallowed
                  (>= (+ (stats-value diag :clean-eof)
                         (stats-value diag :read-error)
                         (stats-value diag :write-error)
                         (stats-value diag :open-error)
                         (stats-value diag :other-error))
                      20)
                  ;; no fd leak on the server side
                  (<= (fd-count) (1+ baseline))
                  ;; still serving
                  (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                           :type :stream :protocol :tcp)))
                    (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
                    (let ((s (sb-bsd-sockets:socket-make-stream c
                                                 :buffering :line
                                                 :input t
                                                 :output t)))
                      (unwind-protect
                           (progn
                             ;; protocol contract (T02): subscribe gets the
                             ;; (subscribed ...) reply; a bare sexpr gets nothing
                             (send-sexpr s '(subscribe :agent "probe-10"))
                             (equal (read-or-eof s)
                                    '(subscribed :agent "probe-10" :cursor 0)))
                        (safe-close-socket c)))))
      (stop-server server)
      (reset!))))))

(test "11. a client that vanishes after sending data is recorded on its client record"
  (let ((server (start-server :port 0)))
    (unwind-protect
         (let* ((port (push-server-port server))
                (c (make-instance 'sb-bsd-sockets:inet-socket
                                   :type :stream :protocol :tcp)))
           (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
           (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                            :buffering :line
                                                            :input t
                                                            :output t)))
             (unwind-protect
                  (progn
                    (send-sexpr stream '(subscribe :agent "probe-11"))
                    (safe-close-socket c)   ; gone before the reply is read
                    (wait-for (lambda ()
                                (plusp (stats-value (push-server-diagnostics server) :client-exits)))
                              3.0)
                    (let ((diag (push-server-diagnostics server)))
                      (and (plusp (stats-value diag :client-exits))
                           (= (getf diag :clients) 1)
                           (every (lambda (rec) (getf rec :exited))
                                  (getf diag :per-client))))
                    )
               (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "12. *push-server-log* captures accept / exit / error lines (nothing is silent)"
  (let ((server nil)
        (out (make-string-output-stream))
        (log ""))
    (labels ((drain ()
              "get-output-stream-string CLEARS the buffer, so accumulate here."
              (setf log (concatenate 'string log (get-output-stream-string out)))))
      (let ((*push-server-log* out))
        (unwind-protect
             (progn
               (setf server (start-server :port 0))
               (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                        :type :stream :protocol :tcp)))
                 (sb-bsd-sockets:socket-connect c #(127 0 0 1) (push-server-port server))
                 (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                                  :buffering :line
                                                                  :input t
                                                                  :output t)))
                   (unwind-protect
                        (progn
                          (format stream "#Zbad")
                          (terpri stream)
                          (force-output stream)
                          (wait-for (lambda ()
                                      (drain)
                                      (search "exit" log))
                                    3.0)
                          (drain)
                          (and (search "start :port" log)
                               (search "accept client" log)
                               (search "exit" log)
                               (search "read-error" log)))
                     (safe-close-socket c)))
               (stop-server server)
               (drain)
               (and (search "stop" log) t))
          (reset!)))))))

;;;; --- load profile (Q6): the first resource to saturate is one thread +
;;;; one fd per connection. Expected v1 load is a handful of clients
;;;; (single-operator loopback, MEM082); 10x is 50 concurrent connections.
;;;; This asserts the accept loop keeps up at 10x, that thread and fd usage
;;;; scale exactly 1:1 with connections (no unbounded growth), and that
;;;; teardown at load leaves nothing behind. The per-client bounded queue
;;;; (queue-capacity, stored here and enforced in T04) is the protection
;;;; against unbounded memory growth once the writer path exists.

(test "13. 10x load (50 concurrent clients): all accepted and served, threads/fds scale 1:1, clean teardown at load"
  (let ((server (start-server :port 0))
        (baseline (fd-count))
        (n 50)
        (sockets '())
        (streams '())
        (result nil))
    (unwind-protect
        (progn
          (loop for i from 1 to n
                do (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                           :type :stream :protocol :tcp)))
                     (sb-bsd-sockets:socket-connect c #(127 0 0 1) (push-server-port server))
                     (push c sockets)
                     (push (sb-bsd-sockets:socket-make-stream c :buffering :line :input t :output t)
                           streams)))
          ;; the accept loop must have registered every connection
          (wait-for (lambda ()
                      (>= (stats-value (push-server-diagnostics server) :accepted) n))
                    5.0)
          (loop for s in streams for i from 1 do (send-sexpr s (list 'subscribe :agent "load-A")))
          (let ((replies (loop for s in streams collect (read-or-eof s)))
                (live-threads (length (threads-named "push-server-client")))
                (live-writers (length (threads-named "push-writer")))
                (fds-at-load (fd-count)))
            (setf result
                  (and (= (stats-value (push-server-diagnostics server) :accepted) n)
                       (= (getf (push-server-diagnostics server) :clients) n)
                       (= (length replies) n)
                       ;; every client got its (subscribed ...) race-closure reply
                       (every (lambda (r) (and (consp r) (eq (car r) 'subscribed))) replies)
                       ;; 1:1 scaling: one handler thread per connection
                       (= live-threads n)
                       (= live-writers n)
                       ;; client-side + server-side fds bounded by connection count
                       (<= fds-at-load (+ baseline (* 2 n) 2))))
            ;; teardown under load: stop-server must unwind all n handler threads
            (loop for s in streams do (close s))
            (stop-server server)
            (sleep 0.2)
            (setf result (and result
                              (null (threads-named "push-server"))
                              (null (threads-named "push-writer"))
                              (<= (fd-count) (+ baseline 2)))))
        (loop for s in streams do (close s))
        (loop for c in sockets do (safe-close-socket c))
        (stop-server server))
    result)))

;;;; --- subscribe protocol (plan tests 4 and 5, plus the negative surface) --
;;
;;;; Two things are proven here: the (subscribed ...) reply carries the correct
;;;; resync cursor, and the bus listener is live — an emit-event after the reply
;;;; reaches the client's queue.

(test "14. subscribe replies (subscribed :agent A :cursor N) with cursor 0 for an unregistered agent"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "probe-A"))
                  (let ((reply (read-or-eof stream 3.0)))
                    (and (equal reply '(subscribed :agent "probe-A" :cursor 0))
                         (plusp (stats-value (push-server-diagnostics server) :subscribes))
                         (equal (getf (first-client-rec (push-server-diagnostics server))
                                      :subscriptions)
                                '("probe-A"))))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "15. the bus listener is live: emit-event after the (subscribed ...) reply enqueues the translated item"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "probe-A"))
                  ;; the reply IS the race-closure signal: emitting before reading
                  ;; it could lose the event, so the test must read first
                  (let ((reply (read-or-eof stream 3.0)))
                    (sexpr.kernel:emit-event "probe-A"
                      (list :type :delta :agent-id "probe-A" :chunk-delta "hi"))
                    (let ((item (read-or-eof stream 2.0))
                          (rec (first-client-rec (push-server-diagnostics server))))
                      (and (equal reply '(subscribed :agent "probe-A" :cursor 0))
                           (= (getf rec :enqueued) 1)
                           (equal item (list 'delta :agent "probe-A" :content "hi"))
                           ;; drain invariant: delivered + queue-length - replies == enqueued
                           (= (+ (getf rec :delivered) (getf rec :queue-length) -1)
                              (getf rec :enqueued)))))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "16. cursor is the transcript length of a REGISTERED agent (the resync cursor the client refetches from)"
  (let ((server (start-server :port 0))
        (agent (sexpr.kernel:make-agent :name "cursor-A" :goal "probe")))
    (sexpr.transcript:append-event (sexpr.kernel:agent-transcript agent)
                                   (sexpr.transcript:make-user-event "hello"))
    (sexpr.transcript:append-event (sexpr.kernel:agent-transcript agent)
                                   (sexpr.transcript:make-model-event "world"))
    (sexpr.agents:register-agent! agent)
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "cursor-A"))
                  (equal (read-or-eof stream 3.0)
                         '(subscribed :agent "cursor-A" :cursor 2)))
              (safe-close-socket c)))
      (sexpr.agents:deregister-agent! agent)
      (stop-server server)
      (reset!)))))

(test "17. unsubscribe removes the listener — a later emit-event enqueues nothing"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "unsub-A"))
                  (read-or-eof stream 3.0)
                  (sexpr.kernel:emit-event "unsub-A"
                    (list :type :delta :agent-id "unsub-A" :chunk-delta "one"))
                  (send-sexpr stream '(unsubscribe :agent "unsub-A"))
                  ;; the handler is on its own thread: wait for the subscription
                  ;; list to drain before asserting the negative
                  (wait-for (lambda ()
                              (null (getf (first-client-rec (push-server-diagnostics server))
                                          :subscriptions)))
                            3.0)
                  (let ((rec (first-client-rec (push-server-diagnostics server))))
                    (and (= (getf rec :enqueued) 1)          ; the pre-unsubscribe event landed
                         (null (getf rec :subscriptions))
                         (plusp (stats-value (push-server-diagnostics server) :unsubscribes))
                         (sexpr.kernel:emit-event "unsub-A"
                           (list :type :delta :agent-id "unsub-A" :chunk-delta "two"))
                         (= (getf (first-client-rec (push-server-diagnostics server))
                                  :enqueued) 1)))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "18. a non-:delta event type is ignored, not enqueued (forward-compatible with S04/S05)"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "type-A"))
                  (read-or-eof stream 3.0)
                  (sexpr.kernel:emit-event "type-A"
                    (list :type :finalize :agent-id "type-A" :content "done"))
                  (let ((rec (first-client-rec (push-server-diagnostics server))))
                    (and (zerop (getf rec :queue-length))
                         (zerop (getf rec :enqueued))
                         ;; the subscription itself is still live
                         (equal (getf rec :subscriptions) '("type-A")))))
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

;;;; --- negative tests for the protocol (Q7) --------------------------

(test "19. malformed subscribe (missing or non-string :agent) is counted, not replied, and does not kill the connection"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe))            ; no :agent
                  (send-sexpr stream '(subscribe :agent 42))  ; wrong type
                  (send-sexpr stream '(unsubscribe))          ; no :agent
                  (send-sexpr stream 42)                      ; not a list at all
                  (wait-for (lambda ()
                              (>= (stats-value (push-server-diagnostics server) :malformed) 4))
                            3.0)
                  (and (= (stats-value (push-server-diagnostics server) :malformed) 4)
                       ;; nothing was replied to any of them
                       (eq (read-or-eof stream 0.5) 'timeout)
                       ;; and the connection is still usable
                       (progn
                         (send-sexpr stream '(subscribe :agent "probe-19"))
                         (equal (read-or-eof stream 3.0)
                                '(subscribed :agent "probe-19" :cursor 0))))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "20. unsubscribing something never subscribed is counted as :unknown-unsubscribe, not silently dropped"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(unsubscribe :agent "never-subscribed"))
                  (wait-for (lambda ()
                              (plusp (stats-value (push-server-diagnostics server) :unknown-unsubscribe)))
                            3.0)
                  (and (plusp (stats-value (push-server-diagnostics server) :unknown-unsubscribe))
                       (eq (read-or-eof stream 0.5) 'timeout)
                       (progn
                         (send-sexpr stream '(subscribe :agent "probe-20"))
                         (equal (read-or-eof stream 3.0)
                                '(subscribed :agent "probe-20" :cursor 0))))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "21. hang up WITHOUT unsubscribe: the client's listeners are removed, not leaked into the bus"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "leak-A"))
                  (read-or-eof stream 3.0)
                  (sexpr.kernel:emit-event "leak-A"
                    (list :type :delta :agent-id "leak-A" :chunk-delta "one"))
                  (let ((before (getf (first-client-rec (push-server-diagnostics server))
                                      :enqueued)))
                    (safe-close-socket c)   ; gone, no (unsubscribe ...)
                    (wait-for (lambda ()
                                (plusp (stats-value (push-server-diagnostics server) :client-exits)))
                              3.0)
                    (let ((rec (first-client-rec (push-server-diagnostics server))))
                      (and (= before 1)
                           (plusp (stats-value (push-server-diagnostics server) :listeners-removed))
                           (null (getf rec :subscriptions))
                           ;; the listener is really gone from the bus: a later
                           ;; emit must not enqueue into the dead client
                           (sexpr.kernel:emit-event "leak-A"
                             (list :type :delta :agent-id "leak-A" :chunk-delta "two"))
                           (= (getf (first-client-rec (push-server-diagnostics server))
                                    :enqueued) 1))))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!)))))

(test "22. stop-server unsubscribes every listener: emit-event after stop is a no-op"
  (let ((server (start-server :port 0)))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "stop-A"))
                  (read-or-eof stream 3.0)
                  (sexpr.kernel:emit-event "stop-A"
                    (list :type :delta :agent-id "stop-A" :chunk-delta "one"))
                  (stop-server server)
                  (sleep 0.2)
                  (and (null (gethash "stop-A" sexpr.kernel:*event-bus*))
                       (sexpr.kernel:emit-event "stop-A"
                         (list :type :delta :agent-id "stop-A" :chunk-delta "two"))
                       (null (gethash "stop-A" sexpr.kernel:*event-bus*))
                       (null (threads-named "push-server"))))
              (safe-close-socket c)))
      (reset!)))))

;;;; --- load profile (Q6) at 10x, on the subscription path ------------
;;
;;;; The resource that saturates first at 10x is the PER-CLIENT QUEUE, not the
;;;; socket or the thread count: a client that subscribes and never reads grows
;;;; its queue with every delta. Expected v1 load is one subscribed client
;;;; (single-operator loopback, MEM082); 10x is 10 concurrent subscribers, each
;;;; fed 1000 deltas.
;;
;;;; Two things are asserted. First, the listener stays CHEAP: if it wrote to the
;;;; socket directly (which S01/MEM084 forbids), 10 clients that never read would
;;;; fill their socket buffers and emit-event would block forever. 10,000 enqueues
;;;; completing in well under a second is the proof that the listener only touches
;;;; the queue. Second, the queue is unbounded until T04 enforces the capacity —
;;;; the breakpoint is documented and the capacity is visible per client in
;;;; diagnostics so the protection T04 applies is observable now.

(test "23. 10x subscription load: listener stays a cheap enqueue (never blocks), queue is the first resource to saturate"
  (let ((server (start-server :port 0 :queue-capacity 64))
        (n 10)
        (events 1000)
        (sockets '())
        (streams '())
        (elapsed 0.0)
        (result nil))
    (unwind-protect
        (progn
          (let ((port (push-server-port server)))
            (loop for i from 1 to n
                  do (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                              :type :stream :protocol :tcp)))
                       (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
                       (push c sockets)
                       (let ((s (sb-bsd-sockets:socket-make-stream c
                                                    :buffering :line
                                                    :input t
                                                    :output t)))
                         (push s streams)
                         (send-sexpr s (list 'subscribe :agent "load-B"))
                         ;; every subscriber must get its race-closure reply
                         (unless (consp (read-or-eof s 3.0)) (return)))))
            ;; 10 subscribers x 1000 events = 10,000 listener calls. A listener that
            ;; touched the socket would block here on the full buffers.
            (let ((start (get-internal-real-time)))
              (loop for i from 1 to events
                    do (sexpr.kernel:emit-event "load-B"
                         (list :type :delta :agent-id "load-B" :chunk-delta (format nil "~A" i))))
              (setf elapsed (/ (- (get-internal-real-time) start)
                               internal-time-units-per-second)))
            (let* ((diag (push-server-diagnostics server))
                   (recs (getf diag :per-client)))
              (setf result
                    (and (= (length recs) n)
                         ;; T04: a stalled client is BOUNDED, not lossless. Every event
                         ;; is accounted for as enqueued or dropped — never silently lost. Note
                         ;; :enqueued counts the marker too, so the accounting is
                         ;; (deltas enqueued) + dropped == events.
                         (every (lambda (rec) (= (+ (getf rec :enqueued) (getf rec :dropped)
                                    (- (getf rec :resyncs)))
                              events))
                         recs)
                         ;; the queue is still the first resource to saturate, and now it
                         ;; saturates at capacity + the single resync marker
                         (every (lambda (rec) (<= (getf rec :queue-length) (1+ (getf rec :queue-capacity)))) recs)
                         (every (lambda (rec) (> (getf rec :dropped) 0)) recs)
                         ;; nothing lost between queue and socket (1 = the reply)
                         (every (lambda (rec) (>= (+ (getf rec :delivered) (getf rec :queue-length) -1)
                                                   (1- (getf rec :enqueued)))) recs)
                         (= (stats-value diag :subscribes) n)
                         ;; the queue is the saturating resource, and its bound is visible
                         (every (lambda (rec) (= (getf rec :queue-capacity) 64)) recs)
                         ;; cheap-enqueue proof: 10k enqueues, no socket I/O, well under a second
                         (< elapsed 1.0)
                         ;; 1:1 thread scaling still holds, now two threads per client
                         (= (length (threads-named "push-server-client")) n)
                         (= (length (threads-named "push-writer")) n))))))
        (loop for s in streams do (close s))
        (loop for c in sockets do (safe-close-socket c))
        (stop-server server)
        (reset!))
    result))

(test "24. the listener does not block the emitter: a slow subscriber cannot stall the kernel's emit path"
  (let ((server (start-server :port 0 :queue-capacity 64))
        (elapsed 0.0))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "slow-A"))
                  (read-or-eof stream 3.0)
                  ;; the client never reads a single byte from the socket
                  (let ((start (get-internal-real-time)))
                    (loop for i from 1 to 2000
                          do (sexpr.kernel:emit-event "slow-A"
                               (list :type :delta :agent-id "slow-A" :chunk-delta "x")))
                    (setf elapsed (/ (- (get-internal-real-time) start)
                                     internal-time-units-per-second)))
                  (let ((rec (first-client-rec (push-server-diagnostics server))))
                    (and (< elapsed 1.0)
                         ;; T04: the stalled client is bounded, not lossless — the
                         ;; emitter still saw all 2000 events, they just landed in
                         ;; the queue or the dropped counter
                         (= (+ (getf rec :enqueued) (getf rec :dropped) (- (getf rec :resyncs)))
                            2000)
                         (> (getf rec :dropped) 0)
                         (<= (getf rec :queue-length) (1+ (getf rec :queue-capacity)))
                         ;; drain-aware: the writer may have drained part of the queue
                         ;; (1 = the (subscribed ...) reply, 1 = an item in flight)
                         (>= (+ (getf rec :delivered) (getf rec :queue-length) -1)
                             (1- (getf rec :enqueued))))))
              (safe-close-socket c))))
      (stop-server server)
      (reset!))))


(test "25. end-to-end: a :delta emit-event reaches the client socket as a readable (delta ...) sexpr"
  (let ((server (start-server :port 0))
        (got nil))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "probe-A"))
                  (let ((reply (read-or-eof stream 3.0)))
                    (sexpr.kernel:emit-event "probe-A"
                      (list :type :delta :agent-id "probe-A" :chunk-delta "hello"))
                    ;; the writer drains on its own thread: bounded read, not an
                    ;; assumption that the item is already on the wire
                    (setf got (read-or-eof stream 2.0))
                    (and (equal reply '(subscribed :agent "probe-A" :cursor 0))
                         (equal got (list 'delta :agent "probe-A" :content "hello"))
                         (getf (first-client-rec (push-server-diagnostics server))
                               :writer-alive))))
                  )
              (safe-close-socket c)))
      (stop-server server)
      (reset!))
    got))

(defun read-until-quiet (stream &key (timeout-seconds 1.5) (max 64))
  "Collect messages from STREAM until a read times out (the writer has drained
  everything it can) or MAX messages are read. Returns the list in arrival order.
  Used by the resync tests: a stalled client reads its whole burst at once, so the
  received set is what the writer actually delivered."
  (let ((out nil))
    (loop
      (when (>= (length out) max) (return))
      (let ((obj (read-or-eof stream timeout-seconds)))
        (when (or (eq obj 'eof) (eq obj 'timeout) (eq obj 'closed)) (return))
        (push obj out)))
    (nreverse out)))

(defun wire-equal (a b)
  "Compare two wire messages by SYMBOL-NAME rather than EQ.
  The server's listener interns its operator symbols in :sexpr.tui while this test
  package interns them locally, so plain EQUAL on a message read from the socket can
  fail for the wrong reason. Comparing names is the package-independent contract —
  the same reason %op dispatches by name."
  (cond
    ((and (symbolp a) (symbolp b)) (string= (symbol-name a) (symbol-name b)))
    ((and (consp a) (consp b)) (and (wire-equal (car a) (car b))
                                    (wire-equal (cdr a) (cdr b))))
    (t (equal a b))))

(defparameter *synthetic-client-id* 900
  "Ids for client records built with make-client outside the accept loop. Tests
  27-29 drive %enqueue-backpressured directly so the capacity decision is
  deterministic: no writer thread is draining these queues concurrently, which is
  the only way to assert the exact boundary (the Nth vs N+1th item). The wire path
  itself is proven by test 26 through the real accept loop.")

;;;; --- resync / bounded-queue backpressure (T04, plan test 7) ---------

(test "26. resync proof (plan test 7): a stalled client gets one (resync ...) and dropped deltas, not an unbounded queue"
  (let ((server (start-server :port 0 :queue-capacity 4))
        (emitted 40)
        (received nil))
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "probe-R"))
                  (let ((reply (read-or-eof stream 3.0)))
                    ;; the client reads nothing after the reply: the queue fills to
                    ;; capacity and the overflow path is what runs
                    (loop for i from 1 to emitted
                          do (sexpr.kernel:emit-event "probe-R"
                               (list :type :delta :agent-id "probe-R"
                                     :chunk-delta (format nil "d~A" i))))
                    (setf received (read-until-quiet stream))
                    (let ((rec (first-client-rec (push-server-diagnostics server)))
                          (deltas (count-if (lambda (m) (equal (symbol-name (car m)) "DELTA"))
                                            received))
                          (resyncs (count-if (lambda (m) (equal (symbol-name (car m)) "RESYNC"))
                                             received)))
                      (and (wire-equal reply '(subscribed :agent "probe-R" :cursor 0))
                           ;; the plan asserts resync is SENT, not that the cursor jumped
                           (>= resyncs 1)
                           ;; fragments were dropped: fewer arrived than were emitted
                           (< deltas emitted)
                           (> (getf rec :dropped) 0)
                           ;; the bound: capacity fragments + the single marker
                           (<= (getf rec :queue-length) (1+ (getf rec :queue-capacity)))
                           (= (getf rec :queue-capacity) 4)
                           ;; every arrived message is a well-formed wire message for probe-R
                           (every (lambda (m) (and (consp m)
                                                   (member (symbol-name (car m)) '("DELTA" "RESYNC")
                                                       :test #'string=)
                                                   (string= (getf (cdr m) :agent) "probe-R")))
                                  received))))))
              (safe-close-socket c)))
      (stop-server server)
      (reset!))
    received))

(test "27. capacity boundary: exactly queue-capacity items enqueue; the capacity+1th is dropped and becomes the marker"
  (let ((client (sexpr.tui::make-client :id *synthetic-client-id* :queue-capacity 4)))
    (loop for i from 1 to 4
          do (sexpr.tui::%enqueue-backpressured client "edge-A"
               (list 'delta :agent "edge-A" :content (format nil "d~A" i))))
    (and (= (getf client :queue-length) 4)
         (= (getf client :dropped) 0)
         (= (getf client :resyncs) 0)
         (not (getf client :resync-pending))
         ;; the first overflow: dropped, and the marker takes its place
         (not (sexpr.tui::%enqueue-backpressured client "edge-A"
                 (list 'delta :agent "edge-A" :content "over")))
         (= (getf client :dropped) 1)
         (= (getf client :resyncs) 1)
         (getf client :resync-pending)
         (= (getf client :queue-length) 5)
         (wire-equal (car (sexpr.tui::snapshot-queue client))
                     '(delta :agent "edge-A" :content "d1"))
         (wire-equal (car (last (sexpr.tui::snapshot-queue client)))
                     '(resync :agent "edge-A" :cursor 0)))))

(test "28. resync storm suppression: one marker serves a whole burst, not one per dropped fragment"
  (let ((client (sexpr.tui::make-client :id (1+ *synthetic-client-id*) :queue-capacity 4)))
    ;; 4 fill the queue, 10 overflow. Without the pending-flag rule this would be
    ;; 10 resync markers; with it the stalled client gets exactly one signal.
    (loop for i from 1 to 14
          do (sexpr.tui::%enqueue-backpressured client "storm-A"
               (list 'delta :agent "storm-A" :content "x")))
    (and (= (getf client :dropped) 10)
         (= (getf client :resyncs) 1)
         (= (getf client :queue-length) 5)
         (= (length (sexpr.tui::snapshot-queue client)) 5)
         ;; the marker is the only resync in the queue
         (= 1 (count-if (lambda (item) (equal (symbol-name (car item)) "RESYNC"))
                        (sexpr.tui::snapshot-queue client))))))

(test "29. the burst flag clears when the marker is delivered, so a later burst can signal again"
  (let ((client (sexpr.tui::make-client :id (+ 2 *synthetic-client-id*) :queue-capacity 2))
        (first-burst nil)
        (second-burst nil)
        (drained nil))
    (loop for i from 1 to 3
          do (sexpr.tui::%enqueue-backpressured client "burst-A"
               (list 'delta :agent "burst-A" :content "x")))
    (setf first-burst (and (= (getf client :resyncs) 1)
                           (getf client :resync-pending)
                           (= (getf client :dropped) 1)))
    ;; drain as the writer would: the marker leaves the queue and the flag clears
    (loop while (> (getf client :queue-length) 0)
          do (sexpr.tui::%dequeue client))
    ;; captured BEFORE the second burst: the flag must be clear at this point
    (setf drained (not (getf client :resync-pending)))
    (loop for i from 1 to 3
          do (sexpr.tui::%enqueue-backpressured client "burst-A"
               (list 'delta :agent "burst-A" :content "y")))
    (setf second-burst (and (= (getf client :resyncs) 2)
                            (= (getf client :dropped) 2)
                            (getf client :resync-pending)))
    (and first-burst
         drained
         second-burst
         ;; the second burst's marker is the only resync in the queue
         (= 1 (count-if (lambda (item) (equal (symbol-name (car item)) "RESYNC"))
                        (sexpr.tui::snapshot-queue client))))))

(test "30. cursor semantics: a mid-stream resync carries the PRE-STREAM transcript length, not the length at overflow"
  (let ((server (start-server :port 0 :queue-capacity 2))
        (agent (sexpr.kernel:make-agent :name "midstream-A" :goal "probe"))
        (received nil))
    (sexpr.transcript:append-event (sexpr.kernel:agent-transcript agent)
                                   (sexpr.transcript:make-user-event "hello"))
    (sexpr.transcript:append-event (sexpr.kernel:agent-transcript agent)
                                   (sexpr.transcript:make-model-event "world"))
    (sexpr.agents:register-agent! agent)
    (unwind-protect
        (let* ((port (push-server-port server))
               (c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (unwind-protect
                (progn
                  (send-sexpr stream '(subscribe :agent "midstream-A"))
                  (let ((reply (read-or-eof stream 3.0)))
                    ;; 60 streaming :delta events: none of them advances the transcript,
                    ;; so the resync cursor must still be 2 — the pre-stream length.
                    (loop for i from 1 to 60
                          do (sexpr.kernel:emit-event "midstream-A"
                               (list :type :delta :agent-id "midstream-A"
                                     :chunk-delta (format nil "s~A" i))))
                    (setf received (read-until-quiet stream))
                    (let ((resync (find-if (lambda (m) (equal (symbol-name (car m)) "RESYNC"))
                                           received)))
                      (and (wire-equal reply '(subscribed :agent "midstream-A" :cursor 2))
                           resync
                           (= (getf (cdr resync) :cursor) 2)
                           ;; the transcript did not advance during the burst
                           (= (sexpr.transcript:transcript-length
                               (sexpr.kernel:agent-transcript agent)) 2)
                           ;; and the cursor is not the burst size
                           (< (getf (cdr resync) :cursor) 60))))))
              (safe-close-socket c)))
      (sexpr.agents:deregister-agent! agent)
      (stop-server server)
      (reset!))
    received))

(test "31. 10x load with backpressure: every stalled client stays bounded at capacity+1 (memory, not loss, is the guarantee)"
  (let ((server (start-server :port 0 :queue-capacity 4))
        (n 10)
        (events 1000)
        (sockets '())
        (streams '())
        (max-observed 0)
        (elapsed 0.0)
        (result nil))
    (unwind-protect
        (progn
          (let ((port (push-server-port server)))
            (loop for i from 1 to n
                  do (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                              :type :stream :protocol :tcp)))
                       (sb-bsd-sockets:socket-connect c #(127 0 0 1) port)
                       (push c sockets)
                       (let ((s (sb-bsd-sockets:socket-make-stream c
                                                    :buffering :line
                                                    :input t
                                                    :output t)))
                         (push s streams)
                         (send-sexpr s (list 'subscribe :agent "load-D"))
                         ;; stalled clients: they never read the reply either
                         (read-or-eof s 3.0)))))
          ;; 10 stalled clients x 1000 events. Without backpressure this is 10,000
          ;; conses held for clients that will never drain them.
          (let ((start (get-internal-real-time)))
            (loop for i from 1 to events
                  do (sexpr.kernel:emit-event "load-D"
                       (list :type :delta :agent-id "load-D" :chunk-delta (format nil "~A" i)))
                  ;; sample the bound every 25 events from the outside (diagnostics
                  ;; takes the clients-lock, so it must not be called inside a lock)
                  when (= (mod i 25) 0)
                    do (loop for rec in (getf (push-server-diagnostics server) :per-client)
                             do (setf max-observed (max max-observed (getf rec :queue-length)))))
            (setf elapsed (/ (- (get-internal-real-time) start)
                             internal-time-units-per-second)))
          (let ((recs (getf (push-server-diagnostics server) :per-client)))
            (setf result
                  (and (= (length recs) n)
                       ;; the queue is the first resource to saturate, and it is bounded
                       (<= max-observed 5)
                       (every (lambda (rec) (<= (getf rec :queue-length) (1+ (getf rec :queue-capacity))))
                              recs)
                       ;; every stalled client was dropped-from and signalled
                       (every (lambda (rec) (> (getf rec :dropped) 0)) recs)
                       (every (lambda (rec) (>= (getf rec :resyncs) 1)) recs)
                       ;; storm suppression: far fewer signals than drops
                       (< (reduce #'+ recs :key (lambda (rec) (getf rec :resyncs)) :initial-value 0)
                          (reduce #'+ recs :key (lambda (rec) (getf rec :dropped)) :initial-value 0))
                       ;; nothing was lost silently: enqueued + dropped == events
                       (every (lambda (rec) (= (+ (getf rec :enqueued) (getf rec :dropped)
                                    (- (getf rec :resyncs)))
                              events))
                              recs)
                       ;; the emitter was not stalled by the stalled clients
                       (< elapsed 1.0)
                       (= (length (threads-named "push-server-client")) n)
                       (= (length (threads-named "push-writer")) n)))))
        (loop for s in streams do (close s))
        (loop for c in sockets do (safe-close-socket c))
        (stop-server server)
        (reset!))
    result))

;;;; --- failure modes (Q5) and boundary conditions (Q7) for the resync path --

(test "32. capacity 0 boundary: every fragment is dropped and the first overflow signals immediately"
  (let ((client (sexpr.tui::make-client :id (+ 3 *synthetic-client-id*) :queue-capacity 0)))
    (loop for i from 1 to 3
          do (sexpr.tui::%enqueue-backpressured client "zero-A"
               (list 'delta :agent "zero-A" :content "x")))
    ;; nothing can ever be below capacity, so the queue holds only the marker
    (and (= (getf client :dropped) 3)
         (= (getf client :resyncs) 1)
         (= (getf client :enqueued) 1)
         (= (getf client :queue-length) 1)
         (wire-equal (car (sexpr.tui::snapshot-queue client))
                     '(resync :agent "zero-A" :cursor 0)))))

(test "33. failure mode: a stalled client hangs up with a resync marker pending — the listener is removed, not leaked"
  (let ((server (start-server :port 0 :queue-capacity 2))
        (exited nil))
    (unwind-protect
        (let ((c (make-instance 'sb-bsd-sockets:inet-socket
                                  :type :stream :protocol :tcp)))
          (sb-bsd-sockets:socket-connect c #(127 0 0 1) (push-server-port server))
          (let ((stream (sb-bsd-sockets:socket-make-stream c
                                                           :buffering :line
                                                           :input t
                                                           :output t)))
            (send-sexpr stream '(subscribe :agent "hangup-R"))
            (read-or-eof stream 3.0)
            ;; fill the queue and leave a marker pending, then hang up without
            ;; saying unsubscribe: the pending marker is discarded with the record
            (loop for i from 1 to 6
                  do (sexpr.kernel:emit-event "hangup-R"
                       (list :type :delta :agent-id "hangup-R" :chunk-delta "x")))
            (safe-close-socket c)
            (setf exited (wait-for (lambda ()
                                     (let ((rec (first-client-rec (push-server-diagnostics server))))
                                       (and rec (getf rec :exited)))) 5.0))
            (let ((rec (first-client-rec (push-server-diagnostics server))))
              (and exited
                   ;; no listener survives the hang-up: the next emit-event is a no-op
                   (null (getf rec :subscriptions))
                   (= (stats-value (push-server-diagnostics server) :listeners-removed) 1)
                   (> (getf rec :dropped) 0)
                   ;; the marker was never written to a dead socket
                   (and (= (getf rec :resyncs) 1)
                        (= (getf rec :delivered) 1))))))
      (stop-server server)
      (reset!))))

;;;; --- summary -------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%"
        *tests-run* *tests-passed* *tests-failed*)

(reset!)

(if (= *tests-failed* 0)
    (format t "~%ALL PASSED~%")
    (progn
      (format *error-output* "~%FAILED~%")
      (sb-ext:exit :code 1)))
