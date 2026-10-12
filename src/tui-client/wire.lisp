;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui-client/wire.lisp — push-channel client connection and wire decoder
;;;; (M004/S03 T01).
;;;;
;;;; BOUNDARY: this is the CLIENT half of the M004 push wire. It runs in a
;;;; separate process that does not quickload :sexpr, so nothing here can name a
;;;; sexpr.* package — the wire speaks plain data and the decoder turns that data
;;;; into message objects.
;;;;
;;;; WIRE CONTRACT, established by S02 in src/tui/server.lisp and mirrored here:
;;;;   - newline-delimited sexprs, written with prin1 + terpri + force-output
;;;;     (the server reads with `read`, so a bare write without a newline would
;;;;     leave the server blocked);
;;;;   - read with *read-eval* bound NIL, so `#.` in a payload cannot evaluate
;;;;     code in the client process;
;;;;   - operators compared by upcased SYMBOL-NAME, NEVER EQ: the reader interns
;;;;     the wire's first token in whatever package the reading stream happens to
;;;;     be in, so EQ against a client-side symbol fails for the wrong reason
;;;;     (MEM101);
;;;;   - plist fields read from the CDR, because the operator occupies the first
;;;;     slot — getf on the whole message signals "malformed property list"
;;;;     (verified in this SBCL: a five-element message is an odd-length plist);
;;;;   - unknown operators are IGNORED, not rejected, mirroring the server's
;;;;     forward-compatible dispatch (MEM090): a newer server may send finalize or
;;;;     inspect before this client understands them.
;;;;
;;;; SBCL-only: sb-bsd-sockets and sb-thread. Never :use :sb-bsd-sockets (the
;;;; package is huge) — always reference by qualified name. Sockets are built with
;;;; make-instance 'sb-bsd-sockets:inet-socket; the deprecated single-letter
;;;; constructor form is not used anywhere in this package (project deprecation
;;;; invariant, asserted by the test suite — which greps this package for that name,
;;;; so this comment must not spell it out).
;;;;
;;;; FAILURE VISIBILITY (R007): the reader runs on its own thread, so a condition
;;;; there cannot bubble to a caller. Every condition is counted on the connection
;;;; stats plist, recorded as :last-error, and written as one structured line to
;;;; *tui-client-log* when that is bound. tui-client-diagnostics is the health
;;;; handle. Nothing is swallowed silently.

(in-package :sexpr-tui)

(require :sb-bsd-sockets)

;;;; --- observability ------------------------------------------------

(defparameter *tui-client-log* nil
  "When non-nil, the stream the client writes one structured line per significant
lifecycle event to (connect, decode failure, reader-thread exit). `t` means
*error-output*; a stream is written to directly. Default NIL so normal runs stay
quiet — bind it to a string stream in tests to prove that thread-side failures are
observable rather than swallowed.")
(export '*tui-client-log*)

(defparameter *wire-reader-thread-name* "tui-wire-reader"
  "The reader thread's name, so `sb-thread:list-all-threads` is a leak check:
one thread per connection, and none surviving cleanup.")
(export '*wire-reader-thread-name*)

(defparameter *client-stats-keys*
  '(;; push-channel counters (this file)
    :packets-read
    :malformed
    :decode-unknown
    :reader-error
    :resyncs-handled
    :connection-closed
    ;; swank counters (T02) — declared here so both connections share one
    ;; vocabulary and the status bar can read any client's stats uniformly
    :unsolicited-skipped
    :rpc-errors
    ;; write side
    :packets-written
    ;; the last condition any client thread caught
    :last-error)
  "The counters every client connection stats plist carries. A counter is always
present and starts at 0, so a status bar never has to guess whether a missing key
means zero or a bug.")
(export '*client-stats-keys*)

(defun %new-stats ()
  "A fresh stats plist with every counter in *client-stats-keys* present and zeroed."
  (loop for key in *client-stats-keys* append (list key 0)))

(defun stats-get (connection key)
  "Read one counter from CONNECTION's stats plist under the stats lock. Safe to
call from any thread (the status bar reads while the reader thread writes)."
  (sb-thread:with-mutex ((tui-connection-stats-lock connection))
    (getf (tui-connection-stats connection) key 0)))
(export 'stats-get)

(defun %count! (connection key &optional (amount 1))
  "Increment one counter. The increment and the lock are one critical section, so a
reader thread and the main thread cannot lose an update."
  (sb-thread:with-mutex ((tui-connection-stats-lock connection))
    (incf (getf (tui-connection-stats connection) key 0) amount)))

(defun %note-error! (connection condition)
  "Record CONDITION as the last error on the stats plist (as text, so the stats
stay data and can be printed or sent over the wire)."
  (sb-thread:with-mutex ((tui-connection-stats-lock connection))
    (setf (getf (tui-connection-stats connection) :last-error) (format nil "~a" condition))))

(defun %log (connection event &optional detail)
  "Write one structured lifecycle line to *tui-client-log* when logging is enabled:
`[tui-client :port N] EVENT — DETAIL`. Never acquires the stats lock, so it is safe
inside a locked section. DETAIL may be NIL."
  (unless *tui-client-log*
    (return-from %log nil))
  (let ((dest (if (eq *tui-client-log* t) *error-output* *tui-client-log*)))
    (format dest "~&[tui-client :port ~D] ~A~@[ — ~A~]%"
            (or (tui-connection-port connection) 0) event detail))
  nil)

;;;; --- connection ---------------------------------------------------

(defstruct tui-connection
  "A push-channel connection to a running sexpr image.
HOST/PORT name the server. SOCKET is the sb-bsd-sockets socket (NIL when the
connection was built over a stream, which is how the decoder is tested with no
network). STREAM is the line-buffered character stream the wire is read from and
written to — the slot that makes string-stream tests possible. PROGRAM is the
cl-tuition program the reader thread injects decoded messages into (NIL until the
model exists). STATS is the counters plist; STATS-LOCK guards it because the reader
thread writes while the main thread reads it for the status bar. ON-MESSAGE is an
optional observer called after each decoded message — the headless test hook, since
`tui:send` drops messages unless the program is running."
  (host nil :type (or null string))
  (port 0)
  (socket nil)
  (stream nil)
  (program nil)
  (stats nil)
  (stats-lock nil)
  (reader-thread nil)
  (on-message nil))

(defun make-client-connection (&key host port socket stream program stats on-message)
  "Build a connection record. STATS is created zeroed when not supplied, and the
stats lock is always created — a connection built by hand in a test still has the
same shape as one built by connect-push."
  (make-tui-connection
   :host host
   :port (or port 0)
   :socket socket
   :stream stream
   :program program
   :stats (or stats (%new-stats))
   :stats-lock (sb-thread:make-mutex :name "tui-client-stats")
   :on-message on-message))
(export 'make-client-connection)

(defun split-sequence-like (string delimiter)
  "Split STRING on DELIMITER (a tiny dependency-free split; CL has no built-in)."
  (labels ((rec (start end)
             (if (>= start end)
                 nil
                 (let ((pos (position delimiter string :start start)))
                   (if pos
                       (cons (subseq string start pos) (rec (1+ pos) end))
                       (list (subseq string start end)))))))
    (rec 0 (length string))))

(defun resolve-host-address (host)
  "Resolve HOST to the byte vector sb-bsd-sockets:socket-connect wants.
A dotted IPv4 literal is parsed directly (so a test can name 127.0.0.1 without a
DNS round trip); anything else goes through get-host-by-name, which signals on an
unknown name — that condition bubbles to the caller, which is the intended failure
path for a typo'd host."
  (let ((parts (split-sequence-like host ".")))
    (if (= 4 (length parts))
        (coerce (mapcar #'parse-integer parts) 'vector)
        (sb-bsd-sockets:host-ent-address (sb-bsd-sockets:get-host-by-name host)))))

(defun connect-push (host port &key program on-message)
  "Open the push-channel connection to HOST:PORT.
Uses make-instance 'sb-bsd-sockets:inet-socket + socket-connect +
socket-make-stream :buffering :line — not the deprecated single-letter constructor
form (the project deprecation invariant; the test suite greps this package for it,
so this docstring does not spell it out).
Line buffering is what makes the newline-delimited wire work: a payload is flushed
on the newline, so the server sees one message per write.
Failure path: connection refused, an unresolvable host, or a stream-open failure
signals to the caller. Nothing is swallowed — the caller (main, or a test) decides
whether a failed connect is fatal. The condition is also counted and logged so the
status bar can show it."
  (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket
                                :type :stream
                                :protocol :tcp))
         (address (resolve-host-address host)))
    (handler-case
      (sb-bsd-sockets:socket-connect socket address port)
      (error (e)
        (handler-case (sb-bsd-sockets:socket-close socket) (error () nil))
        (let ((conn (make-client-connection :host host :port port)))
          (%note-error! conn e)
          (%log conn "connect failed" (format nil "~a" e))
          (%count! conn :connection-closed)
          (error e))))
    (let ((conn (make-client-connection
                 :host host
                 :port port
                 :socket socket
                 :stream (sb-bsd-sockets:socket-make-stream
                          socket :input t :output t :buffering :line)
                 :program program
                 :on-message on-message)))
      (%log conn "connected")
      conn)))

(defun close-connection (connection)
  "Close CONNECTION's socket. Idempotent and error-tolerant — closing an already
closed socket is not a failure worth signalling from a cleanup path."
  (let ((socket (tui-connection-socket connection)))
    (handler-case
      (when (and socket (sb-bsd-sockets:socket-open-p socket))
        (sb-bsd-sockets:socket-close socket))
      (error (e)
        (%note-error! connection e)
        (%log connection "close failed" (format nil "~a" e)))))
  connection)
(export 'close-connection)

;;;; --- wire framing -------------------------------------------------

(defun write-wire (connection form)
  "Write one wire message: prin1 + terpri + force-output, with *print-pretty* bound
NIL so nothing is wrapped or paren-tightened. The newline is the frame — the server
reads with `read`, so an unflushed write leaves the server blocked. Counted as
:packets-written so a write that never reached the server can be seen in the stats."
  (let ((*print-pretty* nil))
    (prin1 form (tui-connection-stream connection))
    (terpri (tui-connection-stream connection))
    (force-output (tui-connection-stream connection)))
  (%count! connection :packets-written)
  form)
(export 'write-wire)

(defun read-wire (connection)
  "Read one newline-delimited wire form from CONNECTION with *read-eval* bound NIL,
so a payload containing `#.` cannot evaluate code in the client process.
Failure paths, both counted and never fatal:
  - EOF returns NIL and counts :connection-closed;
  - a malformed payload (a reader error, e.g. `#.` or an unterminated string)
    counts :reader-error, records :last-error, and returns NIL — the connection
    survives so the next message can still be read.
Returns the form on success and counts :packets-read."
  (let ((stream (tui-connection-stream connection)))
    (handler-case
      (let ((form (let ((*read-eval* nil))
                    (read stream nil nil))))
        (if (null form)
            (progn (%count! connection :connection-closed) nil)
            (progn (%count! connection :packets-read) form)))
      (error (e)
        (%count! connection :reader-error)
        (%note-error! connection e)
        (%log connection "reader error" (format nil "~a" e))
        nil))))
(export 'read-wire)

;;;; --- decoder ------------------------------------------------------

(defun proper-list-p (object)
  "True when OBJECT is a PROPER (dotted-tail-free) list. CL has no proper-listp, and
SBCL's LENGTH signals on a dotted tail, so this is the guard that lets a malformed
wire payload be counted instead of crashing the reader thread."
  (loop with cell = object
        while (consp cell)
        do (setf cell (cdr cell))
        finally (return (null cell))))

(defun well-formed-payload-p (form)
  "True when the tail after the operator is a proper, even-length property list.
An improper or odd-length tail makes getf signal \"malformed property list\", so it
is checked here and counted as malformed rather than raising inside the reader thread."
  (let ((payload (cdr form)))
    (and (proper-list-p payload)
         (not (null payload))
         (evenp (length payload)))))

(defun wire-operator (form)
  "The upcased SYMBOL-NAME of FORM's operator, or NIL when FORM is not a message.
Package-independent by construction: the wire's first token is interned in whatever
package the reader happened to use, so name comparison is the only sound test."
  (when (symbolp (car form))
    (string-upcase (symbol-name (car form)))))

(defun decode-wire (connection form)
  "Decode one wire form into a client message object.
Dispatch is by upcased SYMBOL-NAME (never EQ) and fields are read from the CDR
because the operator occupies the first slot. S02's vocabulary is
subscribe/subscribed/unsubscribe/delta/resync; S04 adds status/approval-needed.
This client understands the five that arrive unsolicited (delta, resync,
subscribed, status, approval-needed). Everything else — an unknown
operator, a non-list, an improper plist — becomes a wire-ignored-msg and is counted
(:decode-unknown or :malformed) rather than signalled, mirroring the server's
forward-compatible dispatch. A dropped message must stay observable: the status bar
shows the last error and the counters."
  (unless (and (listp form) (consp form))
    (%count! connection :malformed)
    (%log connection "malformed" (format nil "~S" form))
    (return-from decode-wire (make-wire-ignored-msg :op nil :form form)))
  ;; The payload after the operator must be a well-formed plist. An improper or
  ;; odd-length tail makes getf signal "malformed property list", so it is checked
  ;; here and counted instead of crashing the reader thread.
  (unless (well-formed-payload-p form)
    (%count! connection :malformed)
    (%log connection "malformed" (format nil "~S" form))
    (return-from decode-wire (make-wire-ignored-msg :op nil :form form)))
  (let ((op (wire-operator form)))
    (unless op
      (%count! connection :malformed)
      (%log connection "malformed" (format nil "~S" form))
      (return-from decode-wire (make-wire-ignored-msg :op nil :form form)))
    (cond
      ((string= op "DELTA")
       (make-delta-msg :agent (getf (cdr form) :agent)
                       :content (getf (cdr form) :content)))
      ((string= op "RESYNC")
       (%count! connection :resyncs-handled)
       (make-resync-msg :agent (getf (cdr form) :agent)
                        :cursor (getf (cdr form) :cursor 0)))
      ((string= op "SUBSCRIBED")
       (make-subscribed-msg :agent (getf (cdr form) :agent)
                            :cursor (getf (cdr form) :cursor 0)))
      ((string= op "STATUS")
       (make-status-msg :agent (getf (cdr form) :agent)
                        :status (getf (cdr form) :status)
                        :pending-approval (getf (cdr form) :pending-approval)))
      ((string= op "APPROVAL-NEEDED")
       (make-approval-needed-msg :agent (getf (cdr form) :agent)
                                 :capability (getf (cdr form) :capability)
                                 :target (getf (cdr form) :target)
                                 :description (getf (cdr form) :description)
                                 :restarts (getf (cdr form) :restarts)))
      (t
       (%count! connection :decode-unknown)
       (%log connection "unknown operator" op)
       (make-wire-ignored-msg :op op :form form)))))
(export 'decode-wire)

;;;; --- reader thread -----------------------------------------------

(defun deliver (connection message)
  "Hand one decoded message to the TEA loop. `tui:send` is the documented injection
point and is thread-safe (trivial-channels), but it DROPS messages unless the
program is running — run sets program-running before init, so a reader started
before run would silently lose everything. ON-MESSAGE is the observer hook called
after send; it is what lets a headless test see decoded messages without a TTY."
  (when (tui-connection-program connection)
    (tui:send (tui-connection-program connection) message))
  (when (tui-connection-on-message connection)
    (funcall (tui-connection-on-message connection) message)))

(defun %wire-reader-loop (connection)
  "The reader body: read, decode, deliver, until EOF or a condition. Every condition
is counted and logged, so a thread-side failure is visible in the stats instead of
appearing as a silent freeze."
  (loop
    (handler-case
      (let ((form (read-wire connection)))
        (when (null form)
          (return nil))
        (deliver connection (decode-wire connection form)))
      (error (e)
        (%count! connection :reader-error)
        (%note-error! connection e)
        (%log connection "reader thread condition" (format nil "~a" e))
        (return nil))))
  (%log connection "reader exited")
  (deliver connection (make-connection-closed-msg
                       :reason (or (stats-get connection :last-error) "eof")))
  nil)

(defun start-wire-reader (connection)
  "Start the wire reader thread named `tui-wire-reader` and record it on the
connection. Returns the thread. Starting the reader from init (not before run) is
the rule: send drops messages until program-running is T (MEM103)."
  (let ((thread (sb-thread:make-thread (lambda () (%wire-reader-loop connection))
                                       :name *wire-reader-thread-name*)))
    (setf (tui-connection-reader-thread connection) thread)
    (%log connection "reader started")
    thread))
(export 'start-wire-reader)

;;;; --- health handle -----------------------------------------------

(defun tui-client-diagnostics (connection)
  "Health snapshot of CONNECTION as a plist: host, port, whether the reader thread
is alive, the counters, and the last condition any client thread caught. The stats
are copied under the lock, so this is safe to call from any thread — including the
status-bar render path — and not from inside a locked section. Returns NIL for a
NIL CONNECTION."
  (when (null connection)
    (return-from tui-client-diagnostics nil))
  (let ((thread (tui-connection-reader-thread connection)))
    (list :host (tui-connection-host connection)
          :port (tui-connection-port connection)
          :reader-thread (and thread (tui-connection-reader-thread connection))
          :reader-alive (and thread (sb-thread:thread-alive-p thread))
          :stats (sb-thread:with-mutex ((tui-connection-stats-lock connection))
                   (copy-list (tui-connection-stats connection))))))
(export 'tui-client-diagnostics)
