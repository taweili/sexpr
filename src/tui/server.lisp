;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui/server.lisp — Push-channel TCP server for the remote TUI (M004/S02).
;;;;
;;;; BOUNDARY: this file is the in-image half of the push channel. It accepts
;;;; TCP clients on a socket SEPARATE from Swank, and pushes
;;;; newline-delimited sexprs (`(delta ...)` / `(resync ...)`) to each subscribed
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
;;;; connected clients. Each client record is a plist with the accepted
;;;; socket, its handler thread, the protocol state added in T02 (the
;;;; subscription list, the bounded queue, and the locks guarding them),
;;;; and the queue-capacity hint passed to start-server. T03 adds a
;;;; per-client writer thread that drains the queue and serializes items
;;;; to the socket.
;;;;
;;;; LOCK ORDER (deadlock discipline — SBCL mutexes are not recursive):
;;;;   clients-lock  >  client subscriptions-lock  >  client queue-lock
;;;;   clients-lock  >  client queue-lock
;;;; The clients-lock is the outermost: it is the only lock held while
;;;; diagnostics walks the client list. No client lock may ever be acquired
;;;; and then the clients-lock. The event-bus lock is a fourth lock: the
;;;; listener closure runs with the event-bus lock held (emit-event holds it
;;;; during the listener call), so inside a listener we may only take the
;;;; queue-lock — never the event-bus lock, never the clients-lock. The
;;;; subscribe/unsubscribe handlers therefore call the event-bus OUTSIDE any
;;;; client lock, then record the pair under the subscriptions-lock.
;;;;
;;;; The write-lock (T03) serializes socket writes from the handler (subscribed
;;;; reply) and the writer (delta items). Writer and handler never hold it while
;;;; acquiring any other lock. The one nesting that exists is diagnostics:
;;;;   clients-lock > write-lock   (push-server-diagnostics -> snapshot-delivered)
;;;; which is safe because no thread ever holds the write-lock and then takes the
;;;; clients-lock — the writer releases the queue-lock before taking the write-lock,
;;;; and neither writer nor handler acquires the clients-lock at all.
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
;;;;
;;;; T05 HARDENING — the leak this closes: terminate-thread UNWINDS a thread, it
;;;; does not let it finish. A handler blocked in `read` that is force-terminated
;;;; never reaches its own cleanup, so every listener it registered survives
;;;; stop-server, and the next emit-event for that agent enqueues into a dead
;;;; client and writes to a closed socket (the S01 research pitfall). The old
;;;; stop-server relied on the handler exiting on its own after the socket close —
;;;; that is a race, not a guarantee. stop-server now unsubscribes every listener
;;;; for every client ITSELF, before unwinding the thread, so the guarantee holds
;;;; whichever path wins. %cleanup-client is idempotent, so the handler's own
;;;; cleanup and stop-server's cleanup can never double-remove.

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
here — no silent swallow.

Protocol counters live in the same plist (T02): :subscribes, :unsubscribes,
:malformed (a message that could not be dispatched: not a list, an unknown
operator, or a subscribe/unsubscribe with a missing or non-string :agent),
and :ignored (a well-formed message this server does not act on yet).
:writer-errors (T03) counts writer-thread exits due to a socket/stream error.
Every protocol message lands in exactly one of these counters — nothing is
dropped silently.

T05 shutdown counters live in the same plist. :listeners-removed counts listeners
unsubscribed by a disconnect path OR by stop-server (a listener that is gone is
gone once, so this is the total, not a per-path count). :stopped counts clients
stop-server tore down without ever recording its own exit — a force-terminated
thread never runs its own %record, so without this the shutdown would be
invisible. :terminated counts threads stop-server had to force-terminate rather
than join cleanly: the difference between a clean unwind and a forced one."))
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

(defun %count (server key &optional (amount 1))
  "Increment one protocol counter on the server stats plist.

Acquires the clients-lock, so it must NOT be called while holding a client
lock (see the lock-order note at the top of this file). This is what makes an
ignored or malformed message observable: the handler does not reply to either,
so without a counter a dropped message would be indistinguishable from a bug.
Protocol counters are not exit outcomes — they do not mark the client
:closed/:exited, so use this rather than %record for them.

AMOUNT defaults to 1. %cleanup-client passes the number of listeners it removed so
:listeners-removed counts LISTENERS, not clients: a client with three subscriptions
must show three, otherwise a partial leak on a cleaned client would be invisible in
the counter that exists precisely to make leaks visible."
  (sb-thread:with-mutex ((push-server-clients-lock server))
    (incf (getf (push-server-stats server) key 0) amount))
  nil)

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
push-server-diagnostics.

IDEMPOTENT for exit outcomes (T03): a client has two threads — the handler and
the writer — and when one exits and closes the socket the other soon follows.
Both call %record, but :client-exits and :exited are set only once (the first
caller). The outcome counter (:write-error / :read-error / :clean-eof ...) is
always incremented, so both outcomes are visible in the stats — a client whose
writer detected the hang-up shows :write-error, and the handler's subsequent
:read-error or :clean-eof is also counted, giving a fuller failure picture."
  (sb-thread:with-mutex ((push-server-clients-lock server))
    (let ((stats (push-server-stats server)))
      (incf (getf stats outcome 0))
      (unless (eq outcome :accepted)
        (when error (setf (getf stats :last-error) error))
        (when client
          (setf (getf client :closed) t)
          (unless (getf client :exited)
            (setf (getf client :exited) t)
            (incf (getf stats :client-exits 0))
            (when error (setf (getf client :error) error)))))))
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
                                          :error (getf c :error)
                                          :subscriptions (snapshot-subscriptions c)
                                          :queue-length (snapshot-queue-length c)
                                          :queue-capacity (getf c :queue-capacity)
                                          :queue (snapshot-queue c)
                                          :enqueued (getf c :enqueued)
                                          :delivered (snapshot-delivered c)
                                          :dropped (snapshot-counter c :dropped)
                                          :resyncs (snapshot-counter c :resyncs)
                                          :resync-pending (snapshot-counter c :resync-pending)
                                          :writer-alive
                                            (let ((wt (getf c :writer-thread)))
                                              (and wt (sb-thread:thread-alive-p wt))))))))

;;;; --- per-client protocol state (T02 + T03) ------------------------
;;;;
;;;; The client record carries the protocol state added here:
;;;;   :subscriptions        list of (agent-id . listener) pairs
;;;;   :subscriptions-lock   guards that list
;;;;   :queue-head/:queue-tail  FIFO of already-translated wire messages
;;;;   :queue-length         current depth
;;;;   :queue-capacity       the bound (start-server's queue-capacity)
;;;;   :queue-lock           guards the queue
;;;;   :enqueued             lifetime enqueue count (queue-lock)
;;;;   :writer-thread        the sb-thread for push-writer-<n> (T03, set by handler)
;;;;   :writer-stop          flag the handler/stop-server sets to ask writer to exit
;;;;   :write-lock           serializes handler (subscribed) and writer (delta) writes
;;;;   :stream               the socket-make-stream result (for diagnostics/cleanup)
;;;;   :delivered            lifetime messages written to the socket (write-lock);
;;;;                         enqueued == delivered + queue-length is the drain invariant
;;;;
;;;; THE DECOUPLING IS THE POINT (S01/MEM084): emit-event calls listeners
;;;; synchronously in the emitting thread — the kernel's agent loop. So the
;;;; listener must be a CHEAP enqueue under the queue-lock and must NEVER touch
;;;; the socket; blocking there would stall the agent. The writer thread (T03)
;;;; drains the queue and writes to the socket — that is the decoupling that
;;;; protects the kernel.
;;;;
;;;; Capacity is stored per-client and ENFORCED by T04 (%enqueue-backpressured):
;;;; at/over capacity the pending fragment is dropped and a single (resync ...) is
;;;; queued per burst. The queue can therefore hold at most capacity + 1 cells
;;;; (capacity fragments + the one marker). The queue is still the first resource
;;;; to saturate under load — T04 is what bounds it.

(defun %enqueue (client item)
  "Append ITEM to CLIENT's FIFO queue under the queue-lock. O(1), no I/O.

Only the queue-lock is taken here (see the lock-order note at the top of this
file): this runs from a bus listener, which is called with the event-bus lock
held, so taking any other lock from here could deadlock against a handler that
holds a client lock and then the event-bus lock. Returns ITEM."
  (sb-thread:with-mutex ((getf client :queue-lock))
    (%append-queue client item))
  item)

(defun %dequeue (client)
  "Remove and return the head item from CLIENT's FIFO queue under the
queue-lock. O(1), no I/O. Returns NIL when the queue is empty.

Only the queue-lock is taken (same constraint as %enqueue). The writer thread
calls this in its drain loop; it never holds the write-lock while dequeuing."
  (sb-thread:with-mutex ((getf client :queue-lock))
    (let ((head (getf client :queue-head)))
      (when head
        (let ((item (car head)))
          (setf (getf client :queue-head) (cdr head))
          (when (null (getf client :queue-head))
            (setf (getf client :queue-tail) nil))
          (decf (getf client :queue-length))
          ;; T04: the burst flag is cleared as the marker leaves the queue, so
          ;; a later overflow burst can signal again.
          (when (eq (car item) 'resync)
            (setf (getf client :resync-pending) nil))
          item)))))

(defun %append-queue (client item)
  "Append ITEM to CLIENT's queue. THE CALLER MUST ALREADY HOLD the queue-lock.
  Split out of %enqueue so the T04 capacity check and the append form one atomic
  critical section (checking length and then appending outside the lock would
  let two listeners both see room and both append). %count is deliberately NOT
  called here: the clients-lock must never be taken inside the queue-lock."
  (let ((cell (list item)))
    (if (getf client :queue-tail)
        (setf (cdr (getf client :queue-tail)) cell)
        (setf (getf client :queue-head) cell))
    (setf (getf client :queue-tail) cell)
    (incf (getf client :queue-length))
    (incf (getf client :enqueued))))

(defun %enqueue-backpressured (client agent-id item)
  "Bounded-queue enqueue with backpressure (T04). Runs from the bus listener, so
  the event-bus lock is held and the queue-lock is the only lock this may take.

  Below capacity, ITEM is appended as usual. At or over capacity, ITEM (a pending
  fragment) is DROPPED and the client is told to refetch: exactly one
  (resync :agent A :cursor N) marker is queued per overflow burst. :resync-pending
  guards the burst — while a marker is still in the queue, further overflow drops
  silently instead of emitting a resync storm, so a client that never reads gets
  one signal rather than one per dropped fragment. The flag is cleared when the
  marker is dequeued, so a later burst can signal again.

  The marker is appended even though the queue is at capacity, so a queue can hold
  at most capacity + 1 cells (capacity fragments + the single marker). That bound
  is what keeps memory bounded under a stalled client — without it a slow client
  would grow the queue until the image ran out of memory.

  CURSOR SEMANTICS — IMPORTANT: transcript-length does NOT advance mid-stream.
  model-step-streaming emits :delta events during the stream and only RETURNS the
  final model event, which the caller appends to the transcript afterwards
  (src/kernel/kernel.lisp:299). A resync sent mid-stream therefore carries the
  PRE-STREAM cursor, not the cursor at the moment of overflow. The client refetches
  transcript-delta (over Swank, S03's job), sees nothing new yet, and the finalized
  event lands later. S02 only SENDS resync; it does not implement the refetch.

  Returns T when ITEM was enqueued, NIL when it was dropped."
  (sb-thread:with-mutex ((getf client :queue-lock))
    (if (< (getf client :queue-length) (getf client :queue-capacity))
        (progn (%append-queue client item) t)
        (progn
          (incf (getf client :dropped))
          (unless (getf client :resync-pending)
            (setf (getf client :resync-pending) t)
            (%append-queue client (list 'resync
                                        :agent agent-id
                                        :cursor (%cursor-for agent-id)))
            (incf (getf client :resyncs)))
          nil))))

(defun snapshot-queue (client)
  "The queue contents in FIFO order, under the queue-lock. Safe from any thread
  as long as the caller does not already hold the queue-lock; the diagnostics
  path holds the clients-lock first, which is the outer lock."
  (sb-thread:with-mutex ((getf client :queue-lock))
    (loop for cell = (getf client :queue-head) then (cdr cell)
          while cell collect (car cell))))

(defun snapshot-queue-length (client)
  "Queue depth under the queue-lock."
  (sb-thread:with-mutex ((getf client :queue-lock))
    (getf client :queue-length)))

(defun snapshot-counter (client key)
  "Read one queue-lock-guarded counter (T04: :dropped, :resyncs, :resync-pending)
  from CLIENT under the queue-lock. Safe from any thread as long as the caller
  does not already hold the queue-lock."
  (sb-thread:with-mutex ((getf client :queue-lock))
    (getf client key)))

(defun snapshot-delivered (client)
  "Lifetime count of messages written to this client's socket, under the
  write-lock. enqueued == delivered + queue-length is the drain invariant."
  (sb-thread:with-mutex ((getf client :write-lock))
    (getf client :delivered)))

(defun snapshot-subscriptions (client)
  "The agent-ids CLIENT is subscribed to, under the subscriptions-lock."
  (sb-thread:with-mutex ((getf client :subscriptions-lock))
    (loop for pair in (getf client :subscriptions) collect (car pair))))

(defun %delta-listener (client agent-id)
  "Build the event-bus listener for one (CLIENT, AGENT-ID) subscription.

Translation: a bus event (:type :delta :agent-id A :chunk-delta X) becomes the
wire item (delta :agent A :content X). A (:type :status :agent-id A :status S
:pending-approval P) event becomes (status :agent A :status S :pending-approval
P). A (:type :approval-needed :agent-id A :capability C :target T :description D
:restarts R) event becomes (approval-needed :agent A :capability C :target T
:description D :restarts R). Any other :type is ignored — that is
forward-compatibility, not an error: S05 may add tool-start and an S04 server
should simply not act on them.

CHEAP BY CONTRACT: the body is a translate plus an enqueue under the queue-lock
only. It never writes to the socket, because emit-event runs listeners
synchronously in the kernel's agent thread (S01/MEM084). It also never reads the
transcript on the happy path — the cursor lookup happens only when the queue is
already full and a resync is being formed, so a normal delta burst costs one
cons per event.

T04: the enqueue is capacity-checked (%enqueue-backpressured), so a client that
stops reading gets bounded memory and one (resync ...) instead of an unbounded
queue. The listener still never blocks: dropping is cheaper than buffering.

The event-bus lock is held while this runs, so the queue-lock is the only lock
this closure may take."
  (lambda (event)
    (when (consp event)
      (case (getf event :type)
        (:delta
         (%enqueue-backpressured client agent-id
                                 (list 'delta
                                       :agent (or (getf event :agent-id) agent-id)
                                       :content (getf event :chunk-delta))))
        (:status
         (%enqueue-backpressured client agent-id
                                 (list 'status
                                       :agent (or (getf event :agent-id) agent-id)
                                       :status (getf event :status)
                                       :pending-approval (getf event :pending-approval))))
        (:approval-needed
         (%enqueue-backpressured client agent-id
                                 (list 'approval-needed
                                       :agent (or (getf event :agent-id) agent-id)
                                       :capability (getf event :capability)
                                       :target (getf event :target)
                                       :description (getf event :description)
                                       :restarts (getf event :restarts))))
        (otherwise nil)))))

(defun %cursor-for (agent-id)
  "Resync cursor for AGENT-ID: its current transcript length, or 0 when the
agent is not registered yet (a client may subscribe to an agent that does not
exist yet, and the cursor is still a useful baseline for it).

For T04: transcript-length does NOT advance mid-stream (MEM089) — :delta events
are emitted during model-step-streaming before the final model event is
integrated into the transcript."
  (or (let ((a (%lookup-agent agent-id)))
        (and a (sexpr.transcript:transcript-length (sexpr.kernel:agent-transcript a))))
      0))

(defun %write-sexpr (stream object)
  "Serialize one wire message as newline-delimited text.

*print-readably* t so the client's READ reconstructs the structure exactly —
princ would drop the quotes around a string and the client would read a symbol.
*print-pretty* nil so nothing is wrapped or paren-tightened. force-output
guarantees delivery: :buffering :line flushes on newline, but an explicit flush
is what makes a push channel push."
  (let ((*print-readably* t) (*print-pretty* nil))
    (prin1 object stream)
    (terpri stream)
    (force-output stream)))

(defun %write-to-client (client stream object)
  "Serialize one wire message to the client stream under the write-lock.

Both the handler (for the (subscribed ...) reply) and the writer thread (for
(delta ...) items from the queue) write to the same two-way socket stream. The
write-lock serializes their output so two concurrent prin1+terpri+force-output
calls never interleave a message. The lock is held only for the duration of one
prin1/terpri/force-output — a few microseconds — so it never blocks the kernel's
emit-event path (the handler and writer are server-side threads, not the kernel's
agent thread).

The write-lock is INDEPENDENT of the lock-order chain (clients-lock >
subscriptions-lock > queue-lock): it is never held while acquiring any of those,
and none of those are held while acquiring it."
  (sb-thread:with-mutex ((getf client :write-lock))
    (%write-sexpr stream object)
    ;; T03: count what actually left the process. enqueued == delivered + queue-length
    ;; is the no-loss invariant of the drain path — a test can tell "the writer drained
    ;; it" from "the listener dropped it". Guarded by the write-lock (both the handler
    ;; and the writer write), read via snapshot-delivered.
    (incf (getf client :delivered))))

(defun %cleanup-client (server client)
  "Unsubscribe every listener CLIENT registered. Called on disconnect (EOF or a
socket error in the handler) and by stop-server.

A leaked listener is the research pitfall: it keeps enqueuing into a dead
client's queue forever, and the next emit-event for that agent would write to a
socket that no longer exists. Called OUTSIDE the clients-lock — it takes the
subscriptions-lock and the event-bus lock. Returns the number removed."
  (let ((pairs (sb-thread:with-mutex ((getf client :subscriptions-lock))
                (copy-list (getf client :subscriptions)))))
    (dolist (pair pairs)
      (sexpr.kernel:unsubscribe-event-bus (car pair) (cdr pair)))
    (sb-thread:with-mutex ((getf client :subscriptions-lock))
      (setf (getf client :subscriptions) nil))
    (when (plusp (length pairs))
      ;; count LISTENERS removed, not clients cleaned — see %count
      (%count server :listeners-removed (length pairs)))
    (length pairs)))

(defun %op (symbol)
  "Resolve the wire operator by SYMBOL-NAME, not by EQ.

The reader interns the client's first token in whatever package the handler
thread happens to be in, so a socket `subscribe` is NOT EQ to sexpr.tui:subscribe
— the dispatch silently fell through to :ignored until this was fixed. A wire
protocol cannot depend on interning into its own package: the client has no way
to name it. Comparing by name is the package-independent contract."
  (when (symbolp symbol)
    (let ((name (string-upcase (symbol-name symbol))))
      (cond
        ((string= name "SUBSCRIBE") :subscribe)
        ((string= name "UNSUBSCRIBE") :unsubscribe)
        (t nil)))))

(defun %handle-message (server client stream message)
  "Dispatch one client message. Returns T when it produced a reply, NIL when it
was ignored or malformed — both counted on the server stats, so a dropped
message is never silent.

S02's vocabulary is subscribe / subscribed / unsubscribe. Unknown operators are
IGNORED rather than rejected: a newer client (S04/S05) may send finalize or
approval-needed to an older server, and the server should not tear down the
connection over a message it does not understand yet. A malformed message is not
fatal to the connection either — it is counted and logged.

The subscribe reply is written AFTER subscribe-event-bus returns. That ordering
is the race-closure signal: a client that has read (subscribed ...) knows the
listener is already registered, so any event it emits afterwards cannot be lost.

No client lock is held while the event-bus is called (lock order), so the
subscribe/unsubscribe paths take the bus lock, then the subscriptions-lock —
never the reverse."
  (unless (consp message)
    (%count server :malformed)
    (%log server (format nil "client ~D malformed" (getf client :id))
          (format nil "not a list: ~S" message))
    (return-from %handle-message nil))
  (let ((op (and (consp message) (car message))))
    (case (%op op)
      ((:subscribe)
       (let ((agent-id (getf (cdr message) :agent)))
         (unless (stringp agent-id)
           (%count server :malformed)
           (%log server (format nil "client ~D malformed subscribe" (getf client :id))
                 (format nil ":agent must be a string: ~S" message))
           (return-from %handle-message nil))
         (let ((listener (%delta-listener client agent-id)))
           ;; subscribe, THEN record, THEN reply — see the docstring. The reply
           ;; is what tells the client the listener is live.
           (sexpr.kernel:subscribe-event-bus agent-id listener)
           (sb-thread:with-mutex ((getf client :subscriptions-lock))
             (push (cons agent-id listener) (getf client :subscriptions)))
           (%count server :subscribes)
           (let ((cursor (%cursor-for agent-id)))
             (%log server (format nil "client ~D subscribe" (getf client :id))
                   (format nil ":agent ~S :cursor ~D" agent-id cursor))
             (%write-to-client client stream
               (list 'subscribed :agent agent-id :cursor cursor)))
           t)))
      ((:unsubscribe)
       (let ((agent-id (getf (cdr message) :agent)))
         (unless (stringp agent-id)
           (%count server :malformed)
           (%log server (format nil "client ~D malformed unsubscribe" (getf client :id))
                 (format nil ":agent must be a string: ~S" message))
           (return-from %handle-message nil))
         (let ((pair (sb-thread:with-mutex ((getf client :subscriptions-lock))
                       (find agent-id (getf client :subscriptions)
                             :key #'car :test #'string=))))
           (unless pair
             ;; Unsubscribing something we never subscribed to is not something
             ;; the client can act on, but it is not silently dropped either.
             (%count server :unknown-unsubscribe)
             (%log server (format nil "client ~D unknown unsubscribe" (getf client :id))
                   (format nil ":agent ~S" agent-id))
             (return-from %handle-message nil))
           (sexpr.kernel:unsubscribe-event-bus agent-id (cdr pair))
           (sb-thread:with-mutex ((getf client :subscriptions-lock))
             (setf (getf client :subscriptions)
                   (remove pair (getf client :subscriptions))))
           (%count server :unsubscribes)
           (%log server (format nil "client ~D unsubscribe" (getf client :id))
                 (format nil ":agent ~S" agent-id))
           nil)))
      (t
       (%count server :ignored)
       (%log server (format nil "client ~D ignored" (getf client :id))
             (format nil "~S" message))
       nil))))

;;;; --- per-client threads (T02: protocol handler + T03: writer thread) -
;;;
;;;; Two threads per client:
;;;;   - the HANDLER (client-handler-loop) reads newline-delimited sexprs and
;;;;     dispatches them (subscribe / unsubscribe / ignore). It writes the
;;;;     (subscribed ...) reply directly under the write-lock.
;;;;   - the WRITER (writer-loop, T03) drains the per-client queue and writes
;;;;     (delta ...) items to the socket under the write-lock.
;;;; Both use %write-to-client so their output never interleaves.
;;;
;;;; On any error (client gone, socket closed by stop-server) we clean up the
;;;; client's listeners, close our end, and return; the handler is expected to be
;;;; joined by stop-server, and if still alive at stop-time we fall back to
;;;; sb-thread:terminate-thread.
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

(defun writer-loop (server client stream)
  "The writer thread body for one client (T03).

Drains CLIENT's queue and serializes each item to STREAM as newline-delimited
text. This is the decoupling point: the bus listener enqueues cheaply under the
queue-lock (never touching the socket), and this thread is the sole writer of
(delta ...) items to the socket. The handler thread writes (subscribed ...)
replies directly under the write-lock; the writer uses the same lock so the two
writers never interleave a message.

Exit conditions:
  - :writer-stop is set (by the handler on its own exit, or by stop-server).
    The writer returns cleanly — the handler does the %record and socket close.
  - A socket/stream error on write (the client hung up, or stop-server closed
    the socket). The writer calls %cleanup-client (idempotent — if the handler
    already cleaned up, this is a no-op), records a :write-error outcome via
    %record (idempotent — only the first exit bumps :client-exits), and closes
    the socket so the handler's blocked read unblocks next.

The writer polls with a 5ms sleep when the queue is empty rather than blocking:
a short poll is simpler and 5ms is well under the latency a human-perceptible
delta stream needs. The poll is also what makes :writer-stop observable without
a condition.

The writer never takes the clients-lock or the subscriptions-lock. It takes the
queue-lock (in %dequeue) and the write-lock (in %write-to-client), never nested."
  (let ((err nil)
        (errored nil))
    (handler-case
        (loop
          (when (getf client :writer-stop)
            (return))
          (let ((item (%dequeue client)))
            (cond
              (item
               (%write-to-client client stream item))
              (t
               ;; Queue empty: poll. 5ms is short enough that a delta reaches
               ;; the client within one writer tick, long enough that an idle
               ;; writer does not spin.
               (sleep 0.005)))))
      (error (e)
        (setf err e
              errored t)))
    (when errored
      ;; The writer hit a socket/stream error. Clean up listeners (idempotent)
      ;; and record the outcome. The handler will also call %record, but
      ;; %record is idempotent for :client-exits — only the first exit outcome
      ;; increments it. Closing the socket unblocks the handler's read next.
      (%count server :writer-errors)
      (let ((removed (%cleanup-client server client)))
        (when (plusp removed)
          (%log server (format nil "writer ~D cleanup" (getf client :id))
                (format nil "unsubscribed ~D listener(s)" removed))))
      (%record server client :write-error err)
      (%log server (format nil "writer ~D exit" (getf client :id))
            (if err (format nil "~A (~A)" err :write-error)
                (format nil "~A" :write-error)))
      (close-socket-safe (getf client :socket)))
    nil))

(defun client-handler-loop (server client)
  "Run the client handler for one accepted connection.

Reads newline-delimited sexprs with *read-eval* NIL until the connection
closes, dispatching each one through %handle-message.

On exit — clean EOF or any socket/stream error — every listener this client
registered is unsubscribed BEFORE the socket is closed, so a client that hangs
up without saying (unsubscribe ...) cannot leak a listener that would enqueue
into a dead client forever. Always closes the server side of the socket so a
client that hung up mid-stream does not leak an fd, and marks the client record
:closed so a concurrent stop-server iteration can skip it. The exit reason and
the cleanup count are recorded on the server stats and logged when
*push-server-log* is bound.

T03: after creating the stream, the handler stores it on the client record and
spawns a per-client writer thread (push-writer-<n>) that drains the queue. On
exit the handler sets :writer-stop and joins/terminates the writer before
running its own cleanup."
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
          ;; Store the stream on the client record for diagnostics/cleanup, and
          ;; spawn the writer thread (T03). The writer is the sole drainer of the
          ;; queue and the sole writer of (delta ...) to the socket; the handler
          ;; writes (subscribed ...) under the same write-lock.
          (setf (getf client :stream) stream)
          (setf (getf client :writer-thread)
                (sb-thread:make-thread
                  (lambda () (writer-loop server client stream))
                  :name (format nil "push-writer-~D" (getf client :id))))
          (loop
            (setf phase :read)
            (let ((obj (read stream nil 'eof)))
              (when (eq obj 'eof)
                (setf outcome :clean-eof)
                (return))
              (setf phase :write)
              (%handle-message server client stream obj))))
      (error (e)
        (setf err e)
        (setf outcome (ecase phase
                        ((:open) :open-error)
                        ((:read) :read-error)
                        ((:write) :write-error)))))
    ;; Signal the writer to stop, then join it with a brief grace period.
    ;; If the writer already exited (socket error), the join returns immediately.
    ;; If it is blocked in a write to a dead socket, terminate-thread is the
    ;; fallback (same pattern as the accept thread — see the shutdown comment).
    (setf (getf client :writer-stop) t)
    (let ((wt (getf client :writer-thread)))
      (when (and wt (sb-thread:thread-alive-p wt))
        (handler-case (sb-thread:join-thread wt :timeout 0.5) (error () nil)))
      (when (and wt (sb-thread:thread-alive-p wt))
        (handler-case (sb-thread:terminate-thread wt) (error () nil))
        (handler-case (sb-thread:join-thread wt :timeout 0.5) (error () nil))))
    ;; Cleanup runs OUTSIDE any locked section: %cleanup-client takes the
    ;; subscriptions-lock and the event-bus lock, and %record takes the
    ;; clients-lock (SBCL mutexes are not recursive).
    (let ((removed (%cleanup-client server client)))
      (when (plusp removed)
        (%log server (format nil "client ~D cleanup" (getf client :id))
              (format nil "unsubscribed ~D listener(s)" removed))))
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
              (let ((client (make-client :socket client-socket :id (1+ counter)
                                         :queue-capacity
                                           (push-server-queue-capacity server))))
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

(defun make-client (&key socket thread (id 0) (queue-capacity 64))
  "Allocate a per-client record.

T02 adds the protocol state: the subscription list (agent-id . listener pairs),
the FIFO queue of already-translated wire messages (head/tail so enqueue is O(1)
under the queue-lock), and the locks guarding each. QUEUE-CAPACITY is copied from
the server so the per-client bound is visible on the record itself; T04 enforces
it and emits (resync ...).

T03 adds the writer thread and its lifecycle state:
  :writer-thread   the sb-thread for push-writer-<n> (set by the handler)
  :writer-stop     a flag the handler/stop-server sets to ask the writer to exit
  :write-lock      serializes handler (subscribed) and writer (delta) writes
  :stream          the socket-make-stream result (for diagnostics/cleanup)"
  (list :id id
        :socket socket
        :thread thread
        :queue-head nil
        :queue-tail nil
        :queue-length 0
        :queue-capacity queue-capacity
        :queue-lock (sb-thread:make-mutex :name "push-server-client-queue")
        :enqueued 0
        :delivered 0
        ;; T04 backpressure state — all guarded by the queue-lock, so they are
        ;; safe to read from the listener and from push-server-diagnostics.
        :dropped 0
        :resyncs 0
        :resync-pending nil
        :subscriptions nil
        :subscriptions-lock (sb-thread:make-mutex :name "push-server-client-subs")
        :writer-thread nil
        :writer-stop nil
        :write-lock (sb-thread:make-mutex :name "push-server-client-write")
        :stream nil
        :closed nil
        :exited nil
        :error nil))

;;;; --- shutdown (T05 hardening) ------------------------------------

(defun %unwind-thread (thread grace)
  "Unwind THREAD: join with a GRACE-second timeout, and if it is still alive
  afterwards terminate-thread it and join again. Returns T when the thread had to
  be FORCE-TERMINATED (it never ran its own cleanup), NIL when it exited on its own
  or was already dead. Never signals.

  Join-first is what gives a client thread the chance to run its own cleanup: the
  caller has already closed the client socket, so a blocked read returns EOF or an
  error and the handler can unsubscribe its listeners before returning. For the
  accept thread join-first is a formality — in this SBCL closing the listen socket
  does not reliably wake a blocked accept (see the shutdown note at the top of this
  file), so the grace period expires and terminate-thread is what actually unwinds
  it. Counting force-terminations is what makes that distinction observable: an
  operator can tell a clean unwind from a forced one through
  push-server-diagnostics."
  (unless thread
    (return-from %unwind-thread nil))
  (when (sb-thread:thread-alive-p thread)
    (handler-case (sb-thread:join-thread thread :timeout grace) (error () nil)))
  (when (sb-thread:thread-alive-p thread)
    (handler-case (sb-thread:terminate-thread thread) (error () nil))
    (handler-case (sb-thread:join-thread thread :timeout grace) (error () nil))
    (return-from %unwind-thread t))
  nil)

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
                                        :writer-errors 0
                                        :open-error 0
                                        :other-error 0
                                        :subscribes 0
                                        :unsubscribes 0
                                        :malformed 0
                                        :ignored 0
                                        :unknown-unsubscribe 0
                                        :listeners-removed 0
                                        ;; T05 shutdown counters
                                        :stopped 0
                                        :terminated 0
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

Shutdown order (T05 hardening; probe3.lisp showed closing the listen socket
alone does NOT reliably wake socket-accept in this SBCL):
  1. Close the LISTEN socket first — releases the fd and stops new accepts, but
     still does not reliably unblock a thread already in the accept syscall, so
     step 4 has to unwind the accept thread.
  2. Snapshot the client list under the clients-lock and RELEASE it. Per-client
     cleanup takes the subscriptions-lock and the event-bus lock, and %count and
     %record take the clients-lock — SBCL mutexes are not recursive, so the
     clients-lock must not be held while cleaning up one client.
  3. For EACH client, in order: unsubscribe every registered listener, signal the
     writer to exit, close the client socket, then join each thread with a short
     grace period (terminate-thread as the fallback). Unsubscribing BEFORE the
     thread is unwound is the whole point of the hardening: a force-terminated
     handler never runs its own cleanup, so a listener would survive the shutdown
     and the next emit-event would write to a dead socket. %cleanup-client is
     idempotent, so it is safe when the handler already cleaned up on its own.
  4. Unwind the accept thread.
  5. Record a :stopped outcome for any client that never recorded its own exit, and
     count force-terminations in :terminated, so the shutdown is observable rather
     than silent.
  6. Set `:stopped` so a second stop-server call is a no-op, clear the client list,
     clear *push-server* if this was the default server, and log the shutdown when
     *push-server-log* is bound.

Grace periods: 0.25s per client thread, 0.1s for the accept thread. A client whose
socket close unblocks its read exits well inside the grace period; the accept thread
usually does not (see above), so stop-server costs roughly 0.1s per call plus one
grace period per thread that cannot be unwound cleanly. That is the price of a
guaranteed no-leak shutdown rather than a racy one."
  (unless server
    (return-from stop-server nil))
  (when (push-server-stopped-p server)
    (return-from stop-server server))
  ;; Step 1: close the listen socket first — releases the fd and stops new accepts.
  (close-socket-safe (push-server-listen-socket server))
  ;; Step 2: snapshot the client list, then RELEASE the clients-lock. %cleanup-client
  ;; and %record take it (directly or through %count), so it must not be held here.
  (let ((clients (sb-thread:with-mutex ((push-server-clients-lock server))
                   (copy-list (push-server-clients server))))
        (unwound 0)
        (forced 0))
    (dolist (client clients)
      ;; Step 3a: unsubscribe every listener this client registered, BEFORE the
      ;; thread is unwound. Idempotent — safe when the handler already cleaned up.
      (let ((removed (%cleanup-client server client))
            (already-exited (getf client :exited)))
        (when (plusp removed)
          (%log server (format nil "stop client ~D" (getf client :id))
                (format nil "unsubscribed ~D listener(s)" removed)))
        ;; Step 3b: signal the writer, close the socket (this is what unblocks a
        ;; blocked read or write so the thread can exit on its own), then unwind.
        (setf (getf client :writer-stop) t)
        (close-socket-safe (getf client :socket))
        (incf unwound)
        (when (%unwind-thread (getf client :writer-thread) 0.25)
          (incf forced)
          (%count server :terminated))
        (when (%unwind-thread (getf client :thread) 0.25)
          (incf forced)
          (%count server :terminated))
        ;; Step 5: a force-terminated thread never ran its own %record, so without
        ;; this the shutdown would be invisible. %record is idempotent for
        ;; :client-exits, so a client that exited cleanly is not double counted.
        (unless already-exited
          (%record server client :stopped nil))))
    ;; Step 4: unwind the accept thread. Join-first is a formality here — closing
    ;; the listen socket does not reliably wake a blocked accept in this SBCL.
    (when (%unwind-thread (push-server-accept-thread server) 0.1)
      (incf forced)
      (%count server :terminated))
    (setf (push-server-clients server) nil)
    (setf (push-server-stopped-p server) t)
    (setf (push-server-accept-thread server) nil)
    (when (eq server *push-server*)
      (setf *push-server* nil))
    (%log server "stop"
          (format nil "clients: ~D, listeners removed: ~D, force-terminated: ~D"
                  unwound
                  (getf (push-server-stats server) :listeners-removed 0)
                  forced)))
  server)
(export 'stop-server)
