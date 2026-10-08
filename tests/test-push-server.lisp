;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-push-server.lisp — standalone test for the push-channel
;;;; TCP server (M004/S02/T01).
;;;;
;;;; Run with: sbcl --script tests/test-push-server.lisp
;;;;
;;;; T01 ships start-server (bind + listen + accept loop), stop-server
;;;; (close clients, close listen socket, join threads), and a minimal
;;;; per-client handler that echoes. T02 adds the subscribe/delta/resync
;;;; protocol on top of the same accept loop.

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

(defun reset! ()
  "Ensure no push-server is running (idempotent)."
  (when sexpr.tui:*push-server*
    (handler-case
        (stop-server sexpr.tui:*push-server*)
      (error () nil))))

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

(format t "Push server tests (T01):~%~%")

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

(test "3. a client connects and echoes a sexpr back over the socket"
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
                    (format stream "(hello world)")
                    (terpri stream)
                    (force-output stream)
                    (let ((back (read stream nil 'eof)))
                      (equal back '(hello world))))
               (safe-close-socket c))))
      (stop-server server)
      (reset!))))

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
           (null (threads-named "push-server")))
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
                  (null (threads-named "push-server")))))
      (reset!))))

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
                  (progn
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
                           (typep (getf (getf diag :stats) :last-error) 'reader-error)
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
                                      (send-sexpr s2 '(still alive))
                                      (equal (read-or-eof s2) '(still alive)))
                                 (safe-close-socket c2)))))))
               (safe-close-socket c))))
      (stop-server server)
      (reset!))))

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
               (safe-close-socket c))))
      (stop-server server)
      (reset!))))

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
                             (send-sexpr s '(after churn))
                             (equal (read-or-eof s) '(after churn)))
                        (safe-close-socket c)))))))
      (stop-server server)
      (reset!))))

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
                    (send-sexpr stream '(vanish))
                    (safe-close-socket c)   ; gone before the echo is read
                    (wait-for (lambda ()
                                (plusp (stats-value (push-server-diagnostics server) :client-exits)))
                              3.0)
                    (let ((diag (push-server-diagnostics server)))
                      (and (plusp (stats-value diag :client-exits))
                           (= (getf diag :clients) 1)
                           (every (lambda (rec) (getf rec :exited))
                                  (getf diag :per-client)))))
               (safe-close-socket c))))
      (stop-server server)
      (reset!))))

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
                     (safe-close-socket c))))
               (stop-server server)
               (drain)
               (and (search "stop" log) t))
          (reset!))))))

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
        (loop for s in streams for i from 1 do (send-sexpr s (list 'load-test i)))
        (let ((replies (loop for s in streams collect (read-or-eof s)))
              (live-threads (length (threads-named "push-server-client")))
              (fds-at-load (fd-count)))
          (setf result
                (and (= (stats-value (push-server-diagnostics server) :accepted) n)
                     (= (getf (push-server-diagnostics server) :clients) n)
                     (= (length replies) n)
                     (every (lambda (r) (and (consp r) (eq (car r) 'load-test))) replies)
                     ;; 1:1 scaling: one handler thread per connection
                     (= live-threads n)
                     ;; client-side + server-side fds bounded by connection count
                     (<= fds-at-load (+ baseline (* 2 n) 2))))
          ;; teardown under load: stop-server must unwind all n handler threads
          (loop for s in streams do (close s))
          (stop-server server)
          (sleep 0.2)
          (setf result (and result
                            (null (threads-named "push-server"))
                            (<= (fd-count) (+ baseline 2)))))
      (loop for s in streams do (close s))
      (loop for c in sockets do (safe-close-socket c))
      (stop-server server))
    result)))
;;;; --- summary -------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%"
        *tests-run* *tests-passed* *tests-failed*)

(reset!)

(if (= *tests-failed* 0)
    (format t "~%ALL PASSED~%")
    (progn
      (format *error-output* "~%FAILED~%")
      (sb-ext:exit :code 1)))
