;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui-client/swank-rpc.lisp — hand-rolled Swank RPC client (M004/S03 T02).
;;;;
;;;; WHY HAND-ROLLED: no swank-client library exists in this environment (SLIME
;;;; 2.32 ships swank, the SERVER side, only — verified by grep across the whole
;;;; tree). So the client implements the protocol itself. The protocol is small
;;;; and stable:
;;;;   - a packet is a 6-hex-digit length header followed by the payload;
;;;;   - the header is a BYTE count, so the socket stream must be
;;;;     (unsigned-byte 8) and the payload must be decoded from UTF-8. A character
;;;;     stream gives the wrong length for any non-ASCII payload (MEM110);
;;;;   - a request is `(:emacs-rex <form-text> <package> <thread-id> <id>)`;
;;;;   - a reply is `(:return (:ok value) id)` or `(:return (:abort condition) id)`,
;;;;     and `(:reader-error packet cause)` for a packet the server could not read.
;;;;
;;;; PACKET TEXT, NOT A STRING (MEM102/D020): the client never `read`s a qualified
;;;; form client-side, because :sexpr.tui does not exist in the client process —
;;;; reading `sexpr.tui:agent-snapshot` here signals "Package SEXPR.TUI does not
;;;; exist". Packets are built as DATA lists and serialized with prin1. Swank's
;;;; eval on a string returns the string, so the form must arrive as readable text.
;;;;
;;;; REPLY MATCHING BY CONTINUATION ID, not by "the next message": swank emits
;;;; unsolicited packets (`:new-features` via *pre-reply-hook*,
;;;; `:indentation-update`) which can arrive before the reply to a request. The
;;;; first live probe showed exactly that: `(:new-features ...)` then
;;;; `(:return (:ok "sexpr") 1)`. A reader-error is counted, never fatal — the
;;;; connection survives so the next reply can still be read (R007).
;;;;
;;;; TESTABILITY (D023/MEM109): the stream slot is what makes tests work over
;;;; string streams with no network. Both byte streams and character streams are
;;;; accepted; the framing helpers branch on the stream element type.
;;;;
;;;; SBCL-only: sb-bsd-sockets. Never :use :sb-bsd-sockets (the package is huge) —
;;;; always reference by qualified name. Sockets are built with
;;;; make-instance 'sb-bsd-sockets:inet-socket; the deprecated single-letter
;;;; constructor form is not used anywhere in this package (project deprecation
;;;; invariant, asserted by the test suite — which greps this package for that
;;;; name, so this comment must not spell it out).

(in-package :sexpr-tui)

(require :sb-bsd-sockets)

;;;; --- connection ---------------------------------------------------

(defstruct swank-connection
  "A Swank RPC connection to a running sexpr image.
HOST/PORT name the server. SOCKET is the sb-bsd-sockets socket (NIL when the
connection was built over a stream). STREAM is the packet stream — a
(unsigned-byte 8) stream for a real socket, because the length header is a BYTE
count; a character stream is accepted for tests (D023). NEXT-ID is the continuation
id the next request will use: reply matching is by id, not by order, so ids must
never be reused. STATS is the shared counter vocabulary; STATS-LOCK guards it
because a reader thread writes while the main thread reads it for the status bar."
  (host nil :type (or null string))
  (port 0)
  (socket nil)
  (stream nil)
  (next-id 1)
  (stats nil)
  (stats-lock nil))

;;;; --- stats access shared by both client connections ----------------
;;;;
;;;; wire.lisp's tui-connection and this file's swank-connection carry the same
;;;; counter vocabulary (*client-stats-keys*), so the status bar in T04 needs one
;;;; accessor for either. These generics are that accessor: a status bar can read
;;;; any client's stats without knowing which struct it holds. The defmethods
;;;; below must come after both defstructs.

(defgeneric client-stats (client)
  (:documentation "The stats plist of any client connection."))
(defgeneric client-stats-lock (client)
  (:documentation "The mutex guarding CLIENT's stats plist."))
(defgeneric client-port (client)
  (:documentation "The port CLIENT is connected to (for the log line)."))
(defgeneric client-label (client)
  (:documentation "What KIND of connection this is, for the log line."))

(defmethod client-stats ((client tui-connection)) (tui-connection-stats client))
(defmethod client-stats-lock ((client tui-connection)) (tui-connection-stats-lock client))
(defmethod client-port ((client tui-connection)) (tui-connection-port client))
(defmethod client-label ((client tui-connection)) "push")

(defmethod client-stats ((client swank-connection)) (swank-connection-stats client))
(defmethod client-stats-lock ((client swank-connection)) (swank-connection-stats-lock client))
(defmethod client-port ((client swank-connection)) (swank-connection-port client))
(defmethod client-label ((client swank-connection)) "swank")

(defun client-stats-get (client key)
  "Read one counter from any client connection under the stats lock, so the status
bar can read while a reader thread writes. Returns 0 for a missing key — a counter
is always present and starts at 0, so the bar never has to guess whether a missing
key means zero or a bug."
  (when (null client)
    (return-from client-stats-get 0))
  (sb-thread:with-mutex ((client-stats-lock client))
    (getf (client-stats client) key 0)))
(export 'client-stats-get)

(defun client-count! (client key &optional (amount 1))
  "Increment one counter on any client connection. The increment and the lock are
one critical section, so a reader thread and the main thread cannot lose an update."
  (sb-thread:with-mutex ((client-stats-lock client))
    (let ((stats (client-stats client)))
    (incf (getf stats key 0) amount))))

(defun client-note-error! (client condition)
  "Record CONDITION as the last error on the stats plist (as text, so the stats stay
data and can be printed or sent over the wire)."
  (sb-thread:with-mutex ((client-stats-lock client))
    (let ((stats (client-stats client)))
    (setf (getf stats :last-error) (format nil "~a" condition)))))

(defun client-log! (client event &optional detail)
  "Write one structured lifecycle line for any client connection:
`[tui-client swank :port N] EVENT — DETAIL`. Never acquires the stats lock, so it
is safe inside a locked section."
  (unless *tui-client-log*
    (return-from client-log! nil))
  (let ((dest (if (eq *tui-client-log* t) *error-output* *tui-client-log*)))
    (format dest "~&[tui-client ~A :port ~D] ~A~@[ — ~A~]~%"
            (client-label client) (or (client-port client) 0) event detail))
  nil)

(defun new-swank-connection (&key host port socket stream stats (next-id 1))
  "Build a swank connection record. STATS is created zeroed when not supplied and
the stats lock is always created, so a connection built by hand in a test has the
same shape as one built by swank-connect. `make-swank-connection` is the defstruct
constructor; this is the builder that guarantees the stats shape."
  (make-swank-connection
   :host host
   :port (or port 0)
   :socket socket
   :stream stream
   :next-id (or next-id 1)
   :stats (or stats (%new-stats))
   :stats-lock (sb-thread:make-mutex :name "tui-client-swank-stats")))
(export 'new-swank-connection)

(defun swank-next-id (connection)
  "Take the next continuation id and advance the counter. Ids are never reused, so
a late reply for an earlier request can still be recognised."
  (sb-thread:with-mutex ((client-stats-lock connection))
    (let ((id (swank-connection-next-id connection)))
      (setf (swank-connection-next-id connection) (1+ id))
      id)))
(export 'swank-next-id)

(defun swank-connect (host port)
  "Open a Swank RPC connection to HOST:PORT.
Uses make-instance 'sb-bsd-sockets:inet-socket + socket-connect +
socket-make-stream :element-type (unsigned-byte 8) — not the deprecated
single-letter constructor form (the project deprecation invariant; the test suite
greps this package for it, so this docstring does not spell it out).
The element type is the point: the length header counts BYTES, so a character
stream would mis-size any payload containing a non-ASCII character (MEM110).
Failure path: connection refused, an unresolvable host, or a stream-open failure
signals to the caller — nothing is swallowed. The condition is also counted and
logged so the status bar can show it."
  (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket
                                :type :stream
                                :protocol :tcp))
         (address (resolve-host-address host)))
    (handler-case
      (sb-bsd-sockets:socket-connect socket address port)
      (error (e)
        (handler-case (sb-bsd-sockets:socket-close socket) (error () nil))
        (let ((conn (new-swank-connection :host host :port port)))
          (client-note-error! conn e)
          (client-log! conn "connect failed" (format nil "~a" e))
          (client-count! conn :connection-closed)
          (error e))))
    (let ((conn (new-swank-connection
                 :host host
                 :port port
                 :socket socket
                 :stream (sb-bsd-sockets:socket-make-stream
                          socket :input t :output t
                          :element-type '(unsigned-byte 8)))))
      (client-log! conn "connected")
      conn)))
(export 'swank-connect)

(defun close-swank-connection (connection)
  "Close CONNECTION's socket. Idempotent and error-tolerant — closing an already
closed socket is not a failure worth signalling from a cleanup path."
  (let ((socket (swank-connection-socket connection)))
    (handler-case
      (when (and socket (sb-bsd-sockets:socket-open-p socket))
        (sb-bsd-sockets:socket-close socket))
      (error (e)
        (client-note-error! connection e)
        (client-log! connection "close failed" (format nil "~a" e)))))
  connection)
(export 'close-swank-connection)

;;;; --- UTF-8, no new dependency -----------------------------------

(defun utf8-bytes (string)
  "Encode STRING as a list of UTF-8 byte values. CL has no built-in UTF-8 codec,
and the header length must be counted in bytes, not characters (MEM110)."
  (labels ((bytes-for (code-point)
            (cond
              ((< code-point #x80) (list code-point))
              ((< code-point #x800)
               (list (+ #xC0 (ash code-point -6))
                     (+ #x80 (logand code-point #x3F))))
              ((< code-point #x10000)
               (list (+ #xE0 (ash code-point -12))
                     (+ #x80 (logand (ash code-point -6) #x3F))
                     (+ #x80 (logand code-point #x3F))))
              (t
               (list (+ #xF0 (ash code-point -18))
                     (+ #x80 (logand (ash code-point -12) #x3F))
                     (+ #x80 (logand (ash code-point -6) #x3F))
                     (+ #x80 (logand code-point #x3F)))))))
    (loop for ch across string append (bytes-for (char-code ch)))))

(defun utf8-to-string (bytes)
  "Decode a byte sequence (vector or list) of UTF-8 into a string. A malformed
sequence signals, which the caller counts rather than swallowing."
  (with-output-to-string (out)
    (loop with i = 0
          while (< i (length bytes))
          do (let ((b (elt bytes i)))
               (if (< b #x80)
                   (progn (write-char (code-char b) out) (incf i))
                   (let* ((extra (cond ((< b #xC0) (error "UTF-8 continuation lead: ~X" b))
                                       ((< b #xE0) 1)
                                       ((< b #xF0) 2)
                                       (t 3)))
                          (code-point (- b (ecase extra (#x1 #xC0) (#x2 #xE0) (#x3 #xF0)))))
                     (loop for k from 1 to extra
                           do (let ((c (+ i k)))
                                (when (>= c (length bytes))
                                  (error "Truncated UTF-8 sequence at ~D" i))
                                (unless (<= #x80 (elt bytes c) #xBF)
                                  (error "Malformed UTF-8 continuation byte at ~D" c))
                                (setf code-point (+ (ash code-point 6)
                                                     (- (elt bytes c) #x80)))))
                     (write-char (code-char code-point) out)
                     (incf i (1+ extra))))))))

(defun byte-stream-p (stream)
  "True when STREAM's element type is (unsigned-byte 8). Real socket streams are;
the string streams used by tests are not, and framing must branch on this."
  (subtypep (stream-element-type stream) '(unsigned-byte 8)))
(export 'byte-stream-p)

;;;; --- framing -----------------------------------------------------

(defun packet-header (byte-length)
  "The 6-hex-digit length header swank expects: six zero-padded uppercase hex
digits, no separator (MEM110). The length is a BYTE count."
  (format nil "~6,'0X" byte-length))
(export 'packet-header)

(defun %payload-text (form)
  "Print a packet payload with prin1. *print-pretty* must be NIL: pretty printing can
insert newlines, and a newline inside a length-prefixed frame changes the byte count
the header claims, so the peer would read the wrong number of bytes."
  (let ((*print-pretty* nil))
    (with-output-to-string (s) (prin1 form s))))

(defun swank-escape-string (value)
  "The packet text of a string ARGUMENT inside a form: prin1 escapes embedded quotes
and backslashes, so a note containing a quote cannot break the form the server reads.
T05 builds chat-note and REPL packets from user text, so this is the escaping seam."
  (%payload-text value))
(export 'swank-escape-string)

(defun rpc-payload (form-text &key (package "SWANK-IO-PACKAGE") (id 1) (thread t))
  "The payload text of one RPC request, WITHOUT the length header.

THE FORM SLOT IS TEXT, NOT A QUOTED STRING. swank's `eval-for-emacs` EVALS the slot it
read from the packet, so a quoted string slot is self-evaluating: it returns the form
text instead of running the RPC. Verified live against a real swank server — a quoted
slot returned `(:ok \"(sexpr:name)\")` and a text slot returned `(:ok \"sexpr\")`. A
packet built by prin1-ing a data list whose form slot is a string therefore never
executes, which is why this builder writes the slot raw while every other slot is
printed normally.

The client still never READS the form: it writes characters, so no sexpr.* package has
to exist in the client process (MEM102/D020). Argument escaping is the caller's job and
is done by SWANK-ESCAPE-STRING. The shape is `(:emacs-rex <form-text> <package> <thread>
<id>)` — under :style :spawn the reader destructures (FORM PACKAGE THREAD-ID ID), and
`t` means the connection's own thread."
  (let ((*print-pretty* nil))
    (format nil "(~S ~A ~S ~A ~A)" :emacs-rex form-text package thread id)))
(export 'rpc-payload)

(defun swank-packet-text (form-text &key (package "SWANK-IO-PACKAGE") (id 1) (thread t))
  "The exact text a packet for FORM-TEXT occupies on the wire: header + payload.
Exposed so a test can assert the packet text without a socket, and so T05 can assert
what a chat note or REPL form actually sends. The form slot is written as text for the
reason given in RPC-PAYLOAD."
  (let ((payload (rpc-payload form-text :package package :id id :thread thread)))
    (concatenate 'string (packet-header (length (utf8-bytes payload))) payload)))
(export 'swank-packet-text)

(defun write-packet (connection payload)
  "Write one packet: header then payload, then flush. The flush is not optional —
a length-prefixed protocol has no other frame boundary, so an unflushed packet
leaves the server blocked in read.
PAYLOAD is either payload TEXT (as built by RPC-PAYLOAD) or a DATA list, which is
printed with prin1. Both paths are needed: the RPC path must write the form slot as
text, while a caller that wants a literal packet builds it as data.
Works on a byte stream (the real path) and on a character stream (the test path).
Returns the full packet text. Counted as :packets-written so a write that never reached
the server is visible in the stats."
  (let* ((payload (if (stringp payload) payload (%payload-text payload)))
         (header (packet-header (length (utf8-bytes payload))))
         (stream (swank-connection-stream connection)))
    (if (byte-stream-p stream)
        (progn
          (loop for ch across header do (write-byte (char-code ch) stream))
          (loop for byte in (utf8-bytes payload) do (write-byte byte stream)))
        (progn
          (write-string header stream)
          (write-string payload stream)))
    (force-output stream)
    (client-count! connection :packets-written)
    (concatenate 'string header payload)))
(export 'write-packet)

(defun %read-payload (connection stream length)
  "Read exactly LENGTH units from STREAM: bytes on a byte stream, characters on a
character stream. A short read signals, which read-packet counts rather than
swallowing."
  (if (byte-stream-p stream)
      (let ((buf (make-array length :element-type '(unsigned-byte 8))))
        (let ((got (read-sequence buf stream)))
          (when (< got length)
            (error "Short payload: ~D of ~D bytes" got length))
          (utf8-to-string buf)))
      (let ((chars (loop for i from 0 below length collect (read-char stream nil nil))))
        (when (some #'null chars)
          (error "Short payload: ~D of ~D characters" (count-if #'identity chars) length))
        (coerce chars 'string))))

(defun read-packet (connection)
  "Read one packet payload from CONNECTION and return it as a string.
The header is read as 6 BYTES when the stream is a byte stream (the length is a
byte count), and as 6 characters on a character stream.
Failure paths, all counted and none fatal:
  - EOF returns NIL and counts :connection-closed;
  - a short header or a short payload counts :reader-error and records :last-error;
  - a malformed UTF-8 sequence counts :reader-error.
The connection survives every one of these, so the next packet can still be read.
Returns the payload string and counts :packets-read on success."
  (let ((stream (swank-connection-stream connection)))
    (handler-case
      (let ((header (if (byte-stream-p stream)
                        (let ((buf (make-array 6 :element-type '(unsigned-byte 8))))
                          (let ((got (read-sequence buf stream)))
                            (when (zerop got)
                              (client-count! connection :connection-closed)
                              (return-from read-packet nil))
                            (when (< got 6)
                              (error "Short header: ~D of 6 bytes" got))
                            (map 'string #'code-char buf)))
                        (let ((chars (loop for i from 0 below 6 collect (read-char stream nil nil))))
                          (when (some #'null chars)
                            (client-count! connection :connection-closed)
                            (return-from read-packet nil))
                          (coerce chars 'string)))))
        (let ((payload (%read-payload connection stream (parse-integer header :radix 16))))
          (client-count! connection :packets-read)
          payload))
    (error (e)
      (client-count! connection :reader-error)
      (client-note-error! connection e)
      (client-log! connection "reader error" (format nil "~a" e))
      nil))))
(export 'read-packet)

(defun parse-packet (connection payload)
  "Read a packet payload back into DATA with *read-eval* bound NIL, so a payload
containing `#.` cannot evaluate code in the client process.
A payload that cannot be read is classified as `(:reader-error packet cause)` — the
same shape swank itself sends for a packet it could not read — and counted. It is
data, not a condition: the caller decides what to do, and the connection survives.
Returns the parsed form on success."
  (handler-case
    (let ((*read-eval* nil))
      (read-from-string payload))
    (error (e)
      (client-note-error! connection e)
      (client-log! connection "packet parse error" (format nil "~a" e))
      (list :reader-error payload (format nil "~a" e)))))
(export 'parse-packet)

;;;; --- reply classification --------------------------------------

(defun packet-operator (packet)
  "The upcased SYMBOL-NAME of a packet's operator, or NIL when the packet is not a
proper list. Package-independent by construction: the payload's first token is
interned in whatever package the read happened to use, so name comparison is the
only sound test (the same rule as the wire decoder)."
  (when (and (listp packet) (consp packet) (symbolp (car packet)))
    (string-upcase (symbol-name (car packet)))))

(defun reply-continuation-id (packet)
  "The continuation id of a `(:return (:ok value) id)` or `(:return (:abort c) id)`
packet, or NIL when the packet is not a reply."
  (when (and (listp packet) (>= (length packet) 3))
    (third packet)))

(defun classify-packet (connection packet expected-id)
  "Classify one packet against EXPECTED-ID. Returns a plist:
  :status  — :ok, :abort, :reader-error, or :unsolicited
  :packet  — the parsed packet
  :id      — the continuation id it carries (NIL for unsolicited)
  :value   — the :ok payload
  :error   — the :abort condition text
Reply matching is by continuation id, never by order, because swank sends
unsolicited packets (`:new-features`, `:indentation-update`) that can arrive before
the reply. An unsolicited packet is counted as :unsolicited-skipped and the caller
keeps reading. A `(:reader-error packet cause)` is counted as :reader-error and is
not fatal."
  (let ((op (packet-operator packet)))
    (cond
      ((string= op "READER-ERROR")
       ;; This is the single counting point for :reader-error. parse-packet does NOT
       ;; count: it turns a payload it could not read into the same shape swank sends,
       ;; and classification is where the counter belongs, so a malformed payload is
       ;; counted exactly once.
       (client-count! connection :reader-error)
       (list :status :reader-error
             :packet packet
             :id nil
             :value (second packet)
             :error (third packet)))
      ((string= op "RETURN")
       (let ((id (reply-continuation-id packet))
             (status (second packet)))
         (unless (eql id expected-id)
           (client-count! connection :unsolicited-skipped)
           (client-log! connection "skipped unsolicited reply" (format nil "id ~A" id))
           (return-from classify-packet
             (list :status :unsolicited :packet packet :id id)))
         (let ((kind (cond ((listp status)
                             (and (symbolp (car status))
                                  (string-upcase (symbol-name (car status)))))
                           ;; Swank's ONLY abort shape is a STRING: eval-for-emacs
                           ;; sends `(:return (:abort ,(prin1-to-string condition)) id)`.
                           ;; A string status is therefore always an abort, never an
                           ;; unsolicited packet — misclassifying it as unsolicited made
                           ;; swank-read-reply skip the only reply that would ever arrive and
                           ;; block forever (the REPL freeze).
                           ((stringp status) "ABORT")
                           (t nil))))
           (cond
             ((string= kind "OK")
              (list :status :ok :packet packet :id id
                    :value (second status) :error nil))
             ((string= kind "ABORT")
              (list :status :abort :packet packet :id id
                    :value nil :error (second status)))
             (t
              (client-count! connection :decode-unknown)
              (client-log! connection "unknown reply status" kind)
              (list :status :unsolicited :packet packet :id id))))))
      (t
       (client-count! connection :unsolicited-skipped)
       (client-log! connection "skipped unsolicited packet" op)
       (list :status :unsolicited :packet packet :id nil)))))
(export 'classify-packet)

(defun swank-value (connection reply)
  "The value carried by an :ok reply, as DATA.
Parse-packet already read the packet into data with *read-eval* bound NIL, so the
value slot is data: a list value arrives as a list, a string value as a string. When
REPLY is a raw payload string rather than a classified reply, it is read here with
*read-eval* NIL as well — reading a payload with eval enabled would let a payload like
`#.` run code in the client process."
  (if (stringp reply)
      (let ((*read-eval* nil))
        (read-from-string reply))
      (getf reply :value)))
(export 'swank-value)

;;;; --- RPC ---------------------------------------------------------

(defun swank-eval (connection form-text &key (package "SWANK-IO-PACKAGE"))
  "Send one RPC request and return the classified reply.
FORM-TEXT is packet TEXT, never a client-side symbol or a form the client reads —
:sexpr.tui does not exist in this process (MEM102/D020). It is written into the packet
as text by RPC-PAYLOAD, which is also why string escaping matters: an argument built
with SWANK-ESCAPE-STRING cannot break the form the server reads.
The packet shape is `(:emacs-rex <form-text> <package> t <id>)` — under swank's
spawn style the reader destructures (FORM PACKAGE THREAD-ID ID), and `t` means the
connection's own thread. Verified against a live swank server: a 3-argument packet
is rejected with \"too few elements ... (FORM PACKAGE THREAD-ID ID)\".
Returns the classified reply plist; :status is :ok, :abort, :reader-error, or :eof."
  (let ((id (swank-next-id connection)))
    (write-packet connection (rpc-payload form-text :package package :id id))
    (swank-read-reply connection id)))
(export 'swank-eval)

(defun swank-read-reply (connection expected-id &key (max-attempts 100)
                          (readout 30))
  "Read packets until one carries EXPECTED-ID. Unsolicited packets
(`:new-features`, `:indentation-update`, a reply for a different id) are counted as
:unsolicited-skipped and skipped. A `(:reader-error ...)` is counted and returned as
a classification, not raised — the connection survives.
EOF returns a plist with :status :eof and counts :connection-closed.
MAX-ATTEMPTS bounds the number of packets read so a caller cannot loop forever on a
connection that will never answer; exhausting it returns :status :no-match rather
than hanging or raising. The bound must be greater than 1: the live probe showed
`:new-features` arriving BEFORE the first reply, so a single-read reply matcher
would report EOF for a perfectly healthy connection.

READOUT bounds EACH read in seconds. Without it a reply that never arrives — an
image whose swank thread died, a network partition, a misclassified abort —
blocks the caller FOREVER. sb-ext:with-timeout interrupts a blocking socket read
on this SBCL, so a stuck image gets :status :timeout after READOUT seconds and
the caller can show an error instead of freezing. A nil payload that is NOT a
timeout is EOF and returns :status :eof (the canned-stream case).

DEBUG PACKETS: when a form errors during RPC eval, swank enters its interactive
debugger and sends `(:debug ...)` instead of a :return. An unanswered :debug
blocks the image's worker thread FOREVER, so it is answered immediately by
invoking the ABORT restart over a fresh :emacs-rex, then reported as
:status :abort with the condition text."
  (let ((result nil))
    (loop for attempt from 1 to max-attempts
          do (let* ((timed-out nil)
                    (payload (handler-case
                                 (sb-ext:with-timeout readout
                                   (read-packet connection))
                               (sb-ext:timeout ()
                                 (setf timed-out t) nil)))
                    (parsed (and payload (parse-packet connection payload)))
                    (debug-p (and parsed
                                  (string= (packet-operator parsed) "DEBUG"))))
               (cond
                (debug-p
                 ;; Answer the image's interactive debugger before classifying:
                 ;; an unanswered :debug blocks the worker thread forever.
                 (let ((abort-id (swank-next-id connection)))
                   (write-packet connection
                     (rpc-payload "(swank::invoke-nth-restart-for-emacs 1)"
                                  :package "COMMON-LISP-USER" :id abort-id))
                   (swank-read-reply connection abort-id))
                 (setf result (list :status :abort
                                    :packet parsed
                                    :id (reply-continuation-id parsed)
                                    :value nil
                                    :error (format nil "~{~A~^ ~}"
                                                    (cdr (second (second parsed)))))))
                (timed-out
                 (setf result (list :status :timeout :packet nil :id nil :value nil
                                    :error (format nil "no reply within ~Ds" readout))))
                (t
                 (setf result (if (null payload)
                                  (list :status :eof :packet nil :id nil :value nil
                                        :error nil)
                                  (classify-packet connection parsed expected-id))))))
          until (and result (not (eq (getf result :status) :unsolicited))))
    (or result (list :status :no-match :packet nil :id nil :value nil :error nil))))
(export 'swank-read-reply)

;;;; --- health handle ---------------------------------------------

(defun swank-diagnostics (connection)
  "Health snapshot of a swank CONNECTION as a plist: host, port, next continuation
id, the counters, and the last condition any client thread caught. The stats are
copied under the lock, so this is safe to call from any thread — including the
status-bar render path — and not from inside a locked section. Returns NIL for a
NIL CONNECTION."
  (when (null connection)
    (return-from swank-diagnostics nil))
  (list :host (swank-connection-host connection)
        :port (swank-connection-port connection)
        :next-id (swank-connection-next-id connection)
        :stats (sb-thread:with-mutex ((client-stats-lock connection))
                 (copy-list (client-stats connection)))))
(export 'swank-diagnostics)
