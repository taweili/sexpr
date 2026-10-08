;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui/server.lisp — Push-channel TCP server for the remote TUI (M004/S02).
;;;;
;;;; BOUNDARY: this file is the in-image half of the push channel. It accepts
;;;; TCP clients on a socket SEPARATE from Swank, and (in later tasks) pushes
;;;; newline-delimited sexprs (`(delta …)` / `(resync …)`) to each subscribed
;;;; client. The kernel's event bus is reached by QUALIFIED name
;;;; (sexpr.kernel:emit-event / subscribe-event-bus / unsubscribe-event-bus)
;;;; so the seam to the model layer stays single (R015). This file never
;;;; names the provider package.
;;;;
;;;; SBCL-native only (MEM019): :sb-bsd-sockets and :sb-thread, no usocket
;;;; and no bordeaux-threads. Never :use :sb-bsd-sockets — the package is
;;;; huge; always reference by qualified name.

(in-package :sexpr.tui)

(require :sb-bsd-sockets)

;;;; --- server state -------------------------------------------------
;;;;
;;;; A `push-server` is the handle returned by start-server. It owns the
;;;; listening socket, the accept-loop thread, and a mutex-guarded list of
;;;; connected clients. Client records are minimal in T01 (the protocol
;;;; arrives in T02): each is a plist with the accepted socket, its handler
;;;; thread, a mutex (guards the client record itself, not yet the queue —
;;;; that is T02), and the queue-capacity hint passed to start-server.
;;;;
;;;; OBSERVABILITY (R007 failure-visibility): the accept loop and the client
;;;; handler run on their own threads, so a condition there cannot bubble to a
;;;; caller. Every condition is therefore counted in the server's `stats`
;;;; plist, recorded on the client record as `:error`, and written as one
;;;; structured line to *push-server-log* when that is bound. Nothing is
;;;; swallowed silently — `push-server-diagnostics` is the health handle.
;;;;
;;;; SHUTDOWN (verified empirically in probe3.lisp): closing the listen
;;;; socket does NOT reliably wake up a thread blocked in socket-accept in
;;;; this SBCL — the accept syscall catches :interrupted internally and
;;;; returns nil, and close() on a listening fd does not wake a blocked
;;;; accept reliably. stop-server therefore uses a two-phase approach:
;;;; close every client socket and listen socket first, then
;;;; terminate-thread every thread. This is not the ideal shutdown
;;;; (research preferred close-listen-first), but it is the ONLY reliable
;;;; one under this SBCL.

(defclass push-server ()
  ((listen-socket
    :initarg :listen-socket
    :accessor push-server-listen-socket
    :type (or sb-bsd-sockets:socket null))
   (host
    :initarg :host
    :accessor push-server-host
    :type (vector (unsigned-byte 8) 4))
   (port
    :initarg :port
    :accessor push-server-port
    :type (unsigned-byte 16)
    :documentation "The REAL bound port. When start-server is called with
port 0 this is the ephemeral port the OS chose.")
   (clients
    :initarg :clients
    :accessor push-server-clients
    :type list)
   (clients-lock
    :initarg :clients-lock
    :accessor push-server-clients-lock
    :type sb-thread:mutex)
   (queue-capacity
    :initarg :queue-capacity
    :accessor push-server-queue-capacity
    :type (unsigned-byte 32)
    :documentation "Per-client bounded queue capacity. Read here for T02's
resync-on-overflow logic; not enforced in T01.")
   (accept-thread
    :initarg :accept-thread
    :accessor push-server-accept-thread
    :type (or sb-thread:thread null))
   (stopped
    :initarg :stopped
    :accessor push-server-stopped-p
    :type boolean
    :documentation "Set by stop-server so a second call is a no-op.")
   (stats
    :initarg :stats
    :accessor push-server-stats
    :type list
    :documentation "Outcome counters as a plist, guarded by clients-lock: :accepted,
:client-exits, and per-outcome counters (:clean-eof / :read-error /
:write-error / :open-error / :other-error), plus :last-error (the most recent
condition seen by any server thread). Every error a thread catches lands
here — no silent swallow."))
  (:documentation "A running push-channel TCP server."))
(export 'push-server)
(export 'push-server-port)
(export 'push-server-stats)
(export 'push-server-diagnostics)

(defparameter *push-server-log* nil
  "When non-nil, the stream the push server writes one structured line per
significant lifecycle event to (accept, client exit, stop-server). `t` means
*error-output*. Default NIL so normal runs stay quiet; bind it to a string
stream in tests to prove that thread-side failures are observable rather than
swallowed.")
(export '*push-server-log*)

(defparameter *push-server* nil
  "The default push-server started by start-server with no argument.
Callers that do not want to manage a handle can rely on this.")
(export '*push-server*)

;;;; --- helpers ------------------------------------------------------

(defun split-string (string &key delimiter (test #'char=))
  "A tiny dependency-free delimiter split (sbcl has no built-in)."
  (labels ((rec (start end)
             (if (>= start end)
                 nil
                 (let ((find (position delimiter string
                                       :start start :test test)))
                   (cond
                     ((null find)
                      (list (subseq string start end)))
                     ((> find start)
                      (cons (subseq string start find)
                            (rec (1+ find) end)))
                     (t
                      (rec (1+ find) end)))))))
    (rec 0 (length string))))

(defun %addr-from-host (host-str)
  "Return the IPv4 (vector unsigned-byte 8 4) for a dotted-decimal string
such as \"127.0.0.1\". Only dotted IPv4 is supported (MEM082: single-operator
loopback v1). Errors on malformed input."
  (let ((octets (split-string host-str :delimiter #\.)))
    (unless (= (length octets) 4)
      (error "bad IPv4 address: ~a" host-str))
    (let ((result (make-array 4 :element-type '(unsigned-byte 8)
                              :initial-element 0)))
      (loop for i from 0 to 3
            for part = (elt octets i)
            for octet = (parse-integer part :junk-allowed nil)
            do (setf (elt result i) octet))
      result)))

(defun close-socket-safe (socket)
  "Close SOCKET, swallowing any error. Never signals."
  (when (and socket (sb-bsd-sockets:socket-open-p socket))
    (handler-case
        (sb-bsd-sockets:socket-close socket)
      (error () nil))))

(defun %record (server client outcome error)
  "Record one thread-side outcome on the server counters and CLIENT's record.
OUTCOME is a keyword: :accepted for a new connection, or one of the exit
outcomes (:clean-eof / :read-error / :write-error / :open-error /
:other-error / :accept-error). ERROR is a condition or NIL.

An exit outcome also bumps :client-exits and marks CLIENT :closed/:exited;
:accepted does not (it is not an exit). ACQUIRES the clients-lock, so it must
NOT be called while already holding it (SBCL mutexes are not recursive). This
is the failure-visibility path: a condition caught on a server thread cannot
bubble to a caller, so it is counted here and readable through
push-server-diagnostics."
  (sb-thread:with-mutex ((push-server-clients-lock server))
    (let ((stats (push-server-stats server)))
      (incf (getf stats outcome 0))
      (unless (eq outcome :accepted)
        (when error (setf (getf stats :last-error) error))
        (when client
          (setf (getf client :closed) t
                (getf client :exited) t)
          (incf (getf stats :client-exits 0))
          (when error (setf (getf client :error) error))))))
  nil)

(defun %log (server event detail)
  "Write one structured lifecycle line to *push-server-log* when logging is
enabled: `[push-server :port N] EVENT — DETAIL`. Never acquires the lock, so
it is safe inside a locked section. DETAIL may be NIL."
  (unless *push-server-log*
    (return-from %log nil))
  (let ((dest (if (eq *push-server-log* t) *error-output* *push-server-log*)))
    (format dest "~&[push-server :port ~D] ~A~@[ — ~A~]%"
            (push-server-port server) event detail))
  nil)

(defun push-server-diagnostics (server)
  "Health snapshot of SERVER as a plist: port, stopped-p, live client count,
the outcome counters, the last condition any server thread caught, and the
per-client error/exited flags. Acquires the clients-lock once, so it is safe
to call from any thread — but not from inside a locked section. Returns NIL
for a NIL SERVER. This is the operator surface for inspecting what the accept
loop and the client handlers saw."
  (unless server
    (return-from push-server-diagnostics nil))
  (sb-thread:with-mutex ((push-server-clients-lock server))
    (list :port (push-server-port server)
          :stopped (push-server-stopped-p server)
          :clients (length (push-server-clients server))
          :stats (copy-list (push-server-stats server))
          :per-client (loop for c in (push-server-clients server)
                            collect (list :id (getf c :id)
                                          :closed (getf c :closed)
                                          :exited (getf c :exited)
                                          :error (getf c :error))))))

;;;; --- per-client thread (T01: minimal handler) --------------------
;;;
;;;; T01 deliberately does not implement the subscribe/delta/resync
;;;; protocol — that arrives in T02. The handler here reads newline-
;;;; delimited sexprs from the client and echoes each one back. The
;;;; echo is intentional: it proves the full accept-loop -> stream ->
;;;; read/write -> close path works end-to-end (the T01 test asserts
;;;; an echo round-trip), while still being a drop-in replacement for
;;;; the real protocol in T02. On any error (client gone, socket
;;;; closed by stop-server) we close our end and return; the handler
;;;; is expected to be joined by stop-server, and if still alive at
;;;; stop-time we fall back to sb-thread:terminate-thread.
;;;
;;;; FAILURE CLASSIFICATION (Q5): PHASE records where the failure happened —
;;;; stream creation (:open-error), the read (:read-error: malformed or
;;;; unreadable input, an unbalanced sexpr, EOF), or the write (:write-error:
;;;; a broken pipe to a client that has gone away). A clean EOF is :clean-eof.
;;;; Every condition is recorded on the server stats and logged when
;;;; *push-server-log* is bound — nothing is swallowed silently.
;;;
;;;; *READ-EVAL* is bound NIL for the read: the client is untrusted input, so
;;;; `#.` must not evaluate code inside the image. The plan specified this for
;;;; T02's protocol read; it costs nothing here and the negative tests assert it.

(defun client-handler-loop (server client)
  "Run the T01 client handler for one accepted connection.

Echoes every sexpr the client sends, until the connection closes.
This gives us a real read/write round-trip on the socket stream — the
T01 test writes a sexpr from a client and reads it back — without
inventing the subscribe/delta/resync protocol that T02 supplies.

Always closes the server side of the socket on exit so a client that
hung up mid-stream does not leak an fd; and marks the client record
:closed so a concurrent stop-server iteration can skip it. The exit reason
is recorded on the server stats and logged when *push-server-log* is bound."
  (let* ((socket (getf client :socket))
         (stream nil)
         (phase :open)
         (outcome :clean-eof)
         (err nil))
    (handler-case
        (let ((*read-eval* nil))
          (setf stream (sb-bsd-sockets:socket-make-stream socket
                                                          :buffering :line
                                                          :input t
                                                          :output t))
          (loop
            (setf phase :read)
            (let ((obj (read stream nil 'eof)))
              (when (eq obj 'eof)
                (setf outcome :clean-eof)
                (return))
              (setf phase :write)
              (format stream "~s~%" obj)
              (force-output stream))))
      (error (e)
        (setf err e)
        (setf outcome (ecase phase
                        ((:open) :open-error)
                        ((:read) :read-error)
                        ((:write) :write-error)))))
    ;; %record acquires the clients-lock itself, so it is called OUTSIDE any
    ;; locked section (SBCL mutexes are not recursive).
    (%record server client outcome err)
    (%log server (format nil "client ~D exit" (getf client :id))
          (if err (format nil "~A (~A)" err outcome) (format nil "~A" outcome)))
    (close-socket-safe socket)))

;;;; --- accept loop --------------------------------------------------
;;;;
;;;; IMPORTANT (verified in probe3.lisp): in this SBCL, closing the
;;;; listen socket does NOT reliably wake up a thread blocked in
;;;; socket-accept — the accept thread may remain in the kernel
;;;; accepting on the closed fd indefinitely. socket-accept also
;;;; catches :interrupted conditions internally and returns nil, so
;;;; thread interrupts are invisible to our handler-case.
;;;;
;;;; Consequence: stop-server uses a two-phase shutdown — first close
;;;; all the sockets, then terminate-thread every thread unconditionally
;;;; with a brief grace period. This is not the preferred shutdown
;;;; path (per research) but is the ONLY reliable one given the SBCL
;;;; behavior; alternative approaches (interrupt-thread, waiting on
;;;; close) do not work here.

(defun accept-loop (server)
  "The thread body for the accept loop.

Blocks on socket-accept. For each accepted connection, allocate a
client record, spawn a client-handler thread, and record both in the
server's client list. Exits only on socket error (which in practice
only happens if the accept thread is force-terminated by stop-server).

Note: the socket-error catch is a formality -- in this SBCL the accept
loop is unwound via terminate-thread, not socket close. Both exits are
recorded and logged so a failed accept is visible in diagnostics."
  (let ((counter 0))
    (loop
      (handler-case
          (let ((client-socket (sb-bsd-sockets:socket-accept
                                 (push-server-listen-socket server))))
            (when client-socket
              ;; Build the client record ONCE and register it before spawning
              ;; the handler: the handler must mutate the same record the
              ;; server owns (its :closed flag), otherwise stop-server cannot
              ;; see that the client already unwound.
              (let ((client (make-client :socket client-socket :id (1+ counter))))
                (incf counter)
                (sb-thread:with-mutex ((push-server-clients-lock server))
                  (setf (push-server-clients server)
                        (cons client (push-server-clients server))))
                (%record server client :accepted nil)
                (%log server (format nil "accept client ~D" (getf client :id)) nil)
                (setf (getf client :thread)
                      (sb-thread:make-thread
                        (lambda () (client-handler-loop server client))
                        :name (format nil "push-server-client-~D" counter))))))
        (sb-bsd-sockets:socket-error (e)
          (%record server nil :accept-error e)
          (%log server "accept loop exit" (format nil "~A" e))
          (return))
        (error (e)
          (%record server nil :accept-error e)
          (%log server "accept loop exit" (format nil "~A" e))
          (return))))))

(defun make-client (&key socket thread (id 0))
  "Allocate a minimal per-client record. The queue slot arrives in T02."
  (list :id id
        :socket socket
        :thread thread
        :queue nil
        :queue-lock (sb-thread:make-mutex :name "push-server-client-queue")
        :closed nil
        :exited nil
        :error nil
        :agent-subscriptions nil))

;;;; --- public API ---------------------------------------------------

(defun start-server (&key (port 0) (host "127.0.0.1")
                       (queue-capacity 64))
  "Start a push-channel TCP server on HOST:PORT and return it.

Port 0 (the default) binds to an ephemeral port; the real port is
read back from the kernel via socket-name and stored on the returned
server (push-server-port). Always set :buffering :line on the client
stream (see research): :full would hold the client's data in the
output buffer and the client would block forever.

The returned server also becomes *push-server* so callers that do not
want to plumb a handle can rely on the global.

Signals an error if the bind or listen call fails (e.g. HOST is not a
valid IPv4 address, or a specific non-zero PORT is already in use)."
  (let* ((addr (%addr-from-host host))
         (listen-socket
          (make-instance 'sb-bsd-sockets:inet-socket
                         :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind listen-socket addr port)
    ;; LISTEN before the accept thread starts: a thread that calls
    ;; socket-accept on an un-listened socket signals immediately and the
    ;; accept loop would exit before any client could connect.
    (sb-bsd-sockets:socket-listen listen-socket 8)
    (let* ((real-port
            (multiple-value-bind (h p)
                (sb-bsd-sockets:socket-name listen-socket)
              (declare (ignore h))
              p))
           (server
            (make-instance 'push-server
                           :listen-socket listen-socket
                           :host addr
                           :port real-port
                           :clients nil
                           :clients-lock
                             (sb-thread:make-mutex :name "push-server-clients")
                           :queue-capacity queue-capacity
                           :accept-thread nil
                           :stopped nil
                           :stats (list :accepted 0
                                        :client-exits 0
                                        :accept-error 0
                                        :clean-eof 0
                                        :read-error 0
                                        :write-error 0
                                        :open-error 0
                                        :other-error 0
                                        :last-error nil)))
           (thread
            (sb-thread:make-thread (lambda () (accept-loop server))
                                    :name "push-server-accept")))
      (setf (push-server-accept-thread server) thread)
      (setf *push-server* server)
      (%log server (format nil "start :port ~D" real-port) nil)
      server)))
(export 'start-server)

(defun stop-server (server)
  "Stop SERVER: close its clients, then the listen socket, and unwind
the threads. Idempotent — a second call on an already-stopped server
is a safe no-op.

Shutdown order (verified in probe3.lisp — closing the listen socket
does NOT reliably wake socket-accept in this SBCL):
  1. For each connected client, close the client socket. This lets the
     client-handler thread's read return EOF (or error) so its
     `unwind-protect` cleans up.
  2. Close the LISTEN socket. This releases the fd; it does not
     reliably unblock a thread in the accept syscall in this SBCL,
     so step 3 does the actual unwinding.
  3. Unwind every thread via terminate-thread, then join with a
     short grace period. Terminate is the PRIMARY path here, not the
     last resort, because socket-close alone leaves accept blocked.
  4. Set `:stopped` so a second stop-server call is a no-op.
  5. If SERVER was *push-server*, clear the global, and log the shutdown when
     *push-server-log* is bound."
  (unless server
    (return-from stop-server nil))
  (when (push-server-stopped-p server)
    (return-from stop-server server))
  ;; Step 1: close every client socket. The handler thread will unwind
  ;; its handler-case with an EOF or socket error on the next read.
  (sb-thread:with-mutex ((push-server-clients-lock server))
    (dolist (client (push-server-clients server))
      (close-socket-safe (getf client :socket))))
  ;; Step 2: close the listen socket.
  (close-socket-safe (push-server-listen-socket server))
  ;; Step 3: unwind every thread. terminate-thread is the primary path
  ;; (see shutdown-order comment). Give each thread a brief grace period
  ;; to exit on its own via its own error handler; terminate if not.
  (dolist (client (push-server-clients server))
    (let ((thread (getf client :thread)))
      (when (and thread (sb-thread:thread-alive-p thread))
        (handler-case
            (sb-thread:terminate-thread thread)
          (error () nil)))
      (when thread
        (handler-case
            (sb-thread:join-thread thread :timeout 0.5)
          (error () nil)))))
  (let ((accept-thread (push-server-accept-thread server)))
    (when (and accept-thread (sb-thread:thread-alive-p accept-thread))
      (handler-case
          (sb-thread:terminate-thread accept-thread)
        (error () nil)))
    (when accept-thread
      (handler-case
          (sb-thread:join-thread accept-thread :timeout 0.5)
        (error () nil))))
  (setf (push-server-clients server) nil)
  (setf (push-server-stopped-p server) t)
  (setf (push-server-accept-thread server) nil)
  (when (eq server *push-server*)
    (setf *push-server* nil))
  (%log server "stop" (format nil "clients closed: ~D" (getf (push-server-stats server) :client-exits 0)))
  server)
(export 'stop-server)
