;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-tui-client.lisp — standalone headless test for the sexpr-tui client
;;;; (M004/S03 T01).
;;;;
;;;; Run with: sbcl --script tests/test-tui-client.lisp
;;;;
;;;; No network and no terminal. Every connection here is built over a string
;;;; stream, so the framing, the decoder, and the reader thread can be exercised
;;;; without a TTY and without a server. `tui:run` is never called: raw mode needs a
;;;; TTY fd and fails on a pipe (MEM103).
;;;;
;;;; T01 covers the pure-data seam only — the ASDF system boundary, the message
;;;; classes, wire framing, the decoder, and the reader thread. The swank RPC client
;;;; (T02), the TEA model and panes (T04), the input paths (T05), and the live
;;;; round trip against the real S02 push server (T06) are separate tasks.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))

;; Make the repo root searchable so ASDF finds sexpr-tui.asd. The task plan named
;; (ui:cwd); the :UI package does not exist in this SBCL (2.6.8), so uiop:getcwd is
;; the equivalent.
(push (uiop:getcwd) asdf:*central-registry*)

(ql:quickload :sexpr-tui)
(require :sb-bsd-sockets)

(defpackage :sexpr-test-tui-client
  (:use :cl :tuition :sexpr-tui)
  ;; :tuition exports #:quit and CL exports #:quit, so QUIT is ambiguous in a
  ;; package that :use's both. The harness needs CL's quit to set the exit status,
  ;; so it shadows and calls cl:quit explicitly.
  (:shadow #:quit))
(in-package :sexpr-test-tui-client)

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

(defun starts-with (string prefix)
  "True when STRING begins with PREFIX (CL has no string-prefixp)."
  (and (>= (length string) (length prefix))
       (string= string prefix :end1 (length prefix))))

(defun test-connection (&key (stream (make-string-input-stream "")) program on-message)
  "A connection over a string stream — the shape that makes the decoder provable
with no network. It is built through make-client-connection, so it carries the same
stats plist and the same lock as a real socket connection."
  (make-client-connection :host "127.0.0.1" :port 0 :stream stream
                          :program program :on-message on-message))

(defun wire-line (body)
  "Build one wire frame with REAL newlines. MEM019: a literal \"a~%b\" is ONE line to
read-line because ~% is a FORMAT directive, so frames are built through format.
BODY is wrapped in parentheses because the server's %write-sexpr prin1s a LIST: the
frame the client reads is the whole sexpr, parens included, plus the newline."
  (format nil "(~A)~%" body))

(defun read-file-line (path)
  "First line of PATH, or an empty string when it cannot be read."
  (handler-case
      (with-open-file (s path :direction :input) (read-line s nil ""))
    (error () "")))

(defun file-has-spdx (path)
  (search "SPDX-License-Identifier: GPL-3.0-or-later" (read-file-line path)))

(defun source-text (path)
  "Whole file as a string, for the absence gates (R015, deprecation)."
  (handler-case
      (with-open-file (s path :direction :input)
        (let ((out (make-array 0 :element-type 'character :fill-pointer t :adjustable t)))
          (loop for c = (read-char s nil nil) while c do (vector-push-extend c out))
          out))
    (error () "")))

(defun system-dependency-names (system)
  "Dependency names as strings. asdf:system-depends-on returns STRINGS in this
SBCL/ASDF, not keywords, so a `member :tuition` test fails for the wrong reason.
Normalizing to names is what makes the boundary assertion testable."
  ;; asdf:system-name is not exported from ASDF/INTERFACE in this ASDF, so the name is
  ;; taken from the value itself: strings as-is, symbols by symbol-name, system objects
  ;; by their printed name.
  (mapcar (lambda (d)
            (typecase d
              (string d)
              (symbol (symbol-name d))
              (t (format nil "~A" d))))
          (asdf:system-depends-on system)))

(format t "~%== sexpr-tui client (T01: system, messages, decoder) ==~%")

;;;; --- 1. system boundary (must-have #5, asserted not prose) --------------

;; member defaults to EQ, and two distinct strings are not EQ — the dependency names
;; are strings in this ASDF, so the membership test must compare with EQUAL.
(test "sexpr-tui :depends-on contains :tuition"
  (member "tuition" (system-dependency-names (asdf:find-system :sexpr-tui)) :test #'equal))

(test "sexpr-tui :depends-on does not contain :sexpr"
  (not (member "sexpr" (system-dependency-names (asdf:find-system :sexpr-tui)) :test #'equal)))

(test "sexpr.asd gained no :tuition — quickload :sexpr never pulls a TUI library into the image"
  (not (member "tuition" (system-dependency-names (asdf:find-system :sexpr)) :test #'equal)))

(test ":sexpr-tui :use list is exactly (:cl :tuition)"
  ;; package-use-list returns the packages USED BY the package, and CL's package-name
  ;; is "COMMON-LISP", not "CL", so the expected set is the resolved names.
  (equal (sort (mapcar #'package-name (package-use-list (find-package :sexpr-tui)))
               #'string<)
         '("COMMON-LISP" "TUITION")))

(test ":sexpr-tui uses no sexpr.* package — the client process has no such packages"
  (notany (lambda (n) (starts-with n "SEXPR"))
          (mapcar #'package-name (package-use-list (find-package :sexpr-tui)))))

(test "the client package exports the connection, the decoder, and the message classes"
  (every (lambda (name) (find-symbol name :sexpr-tui))
         '("TUI-CONNECTION" "CONNECT-PUSH" "WRITE-WIRE" "READ-WIRE" "DECODE-WIRE"
           "START-WIRE-READER" "DELTA-MSG" "RESYNC-MSG" "SUBSCRIBED-MSG"
           "WIRE-IGNORED-MSG" "CONNECTION-CLOSED-MSG" "RPC-RESULT-MSG"
           "*TUI-CLIENT-LOG*")))

;;;; --- 2. decoder: package-independent dispatch ---------------------------

(let ((conn (test-connection))
      ;; The wire's first token is interned in whatever package the reader happened
      ;; to use. Interning it in a foreign package is exactly what a real socket read
      ;; does, so this is the shape the contract has to survive.
      (foreign (intern "delta" :sexpr-test-tui-client)))
  (test "SYMBOL-NAME dispatch works on a foreign-package operator symbol"
    (let ((msg (decode-wire conn (list foreign :agent "A" :content "hi"))))
      (and (delta-msg-p msg)
           (equal (delta-msg-agent msg) "A")
           (equal (delta-msg-content msg) "hi"))))
  (test "the foreign symbol is not EQ to any client-side DELTA symbol (EQ dispatch would fail)"
    (and (not (eq foreign (find-symbol "DELTA" :sexpr-tui)))
         (null (find-symbol "DELTA" :sexpr-tui))))
  (test "wire-operator resolves a foreign-package subscribe symbol by name"
    (equal (wire-operator (list (intern "subscribe" :cl-user) :agent "A")) "SUBSCRIBE"))
  (test "lowercase wire operators dispatch (the wire is not case-normalized on the wire)"
    (let ((msg (decode-wire conn (list (intern "resync" :cl-user) :agent "A" :cursor 7))))
      (and (resync-msg-p msg) (= 7 (resync-msg-cursor msg)))))
  (test "subscribed dispatches and carries the race-closure cursor"
    (let ((msg (decode-wire conn (list (intern "subscribed" :cl-user) :agent "A" :cursor 3))))
      (and (subscribed-msg-p msg) (= 3 (subscribed-msg-cursor msg))))))

(test "getf on the WHOLE message cannot be relied on — the CDR is required"
  ;; In this SBCL a five-element message is an odd-length plist: getf signals
  ;; "malformed property list" when interpreted but folds to NIL when compiled, so the
  ;; robust statement is that whole-message getf never yields the value while CDR-getf
  ;; does. That is the contract the decoder depends on.
  (let ((whole (handler-case (getf '(delta :agent "A" :content "hi") :agent)
                (error (err) :signaled)))
        (cdr-value (getf (cdr '(delta :agent "A" :content "hi")) :agent)))
    (and (not (equal whole "A"))
         (equal cdr-value "A")
         (or (eq whole :signaled) (null whole)))))

(test "decode reads fields from the CDR, not the whole message"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(delta :agent "A" :content "frag"))))
      (and (equal (delta-msg-content msg) "frag")
           (= 0 (stats-get conn :malformed))))))

;;;; --- 3. negative surface: malformed and unknown ------------------------

(test "a non-list message is counted as malformed, not crashed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn 42)))
      (and (wire-ignored-msg-p msg)
           (null (wire-ignored-msg-op msg))
           (= 1 (stats-get conn :malformed))))))

(test "an improper plist is counted as malformed, not crashed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(delta :agent . 5))))
      (and (wire-ignored-msg-p msg)
           (= 1 (stats-get conn :malformed))
           ;; length signals on a dotted tail, so the guard must run before it —
           ;; the wording of the signal is implementation-dependent, so the assertion
           ;; is that it signals at all.
           (handler-case (progn (length '(delta :agent . 5)) nil)
             (error (err) (not (null (format nil "~a" err)))))))))

(test "a bare symbol (no plist) is malformed, not crashed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn 'delta)))
      (and (wire-ignored-msg-p msg) (= 1 (stats-get conn :malformed))))))

(test "an empty payload is malformed, not crashed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(delta))))
      (and (wire-ignored-msg-p msg) (= 1 (stats-get conn :malformed))))))

(test "an odd-length payload is malformed, not silently wrong"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(delta :agent "A" :content))))
      (and (wire-ignored-msg-p msg) (= 1 (stats-get conn :malformed))))))

(test "an unknown operator is ignored, not rejected — forward compatibility with a newer server"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(finalize :agent "A"))))
      (and (wire-ignored-msg-p msg)
           (equal (wire-ignored-msg-op msg) "FINALIZE")
           (= 1 (stats-get conn :decode-unknown))
           (= 0 (stats-get conn :malformed))))))

(test "a resync is counted as a handled resync"
  (let ((conn (test-connection)))
    (decode-wire conn '(resync :agent "A" :cursor 2))
    (= 1 (stats-get conn :resyncs-handled))))

;;;; --- 4. *read-eval* discipline -----------------------------------------

(test "#. in a wire payload is not evaluated (the sentinel stays unbound) and is counted, not fatal"
  (and (not (boundp 'sexpr-test-tui-client::sentinel))
       (let ((conn (test-connection
                    :stream (make-string-input-stream
                             (wire-line "delta :agent \"A\" :content #.sentinel")))))
         (let ((first (read-wire conn)))
           ;; #. must be OUTSIDE the string literal to be a read-time eval macro at all;
           ;; inside a quoted string it is just characters and proves nothing.
           (and (null first)
                (not (boundp 'sexpr-test-tui-client::sentinel))
                (= 1 (stats-get conn :reader-error))
                ;; read-wire returns NIL rather than signalling: the connection survives
                (null (read-wire conn)))))))

(test "a mid-frame reader error desynchronizes that frame but the connection keeps reading"
  ;; Observed behaviour, not assumed: `read` consumes tokens up to the error, so the tail
  ;; of the bad frame (the leftover form and the stray close paren) is read as further
  ;; counted errors. The reader never crashes and the stream realigns at the next frame,
  ;; so a malformed frame costs a bounded number of extra misreads, not the connection.
  (let ((conn (test-connection
               :stream (make-string-input-stream
                        (concatenate 'string
                                     (wire-line "delta :agent \"A\" :content #.sentinel")
                                     (wire-line "delta :agent \"A\" :content \"ok\""))))))
    (and (null (read-wire conn))
         (not (boundp 'sexpr-test-tui-client::sentinel))
         (let ((recovered nil))
           (loop for i from 1 to 6
                 do (let ((form (read-wire conn)))
                      (when (and form (delta-msg-p (decode-wire conn form)))
                        (setf recovered form) (return nil))))
           (and recovered
                (equal (delta-msg-content (decode-wire conn recovered)) "ok")
                ;; the desync is counted, never swallowed
                (>= (+ (stats-get conn :reader-error) (stats-get conn :malformed)) 2))))))

(test "EOF returns NIL and counts a closed connection rather than signalling"
  (let ((conn (test-connection :stream (make-string-input-stream ""))))
    (and (null (read-wire conn)) (= 1 (stats-get conn :connection-closed)))))

(test "an unterminated frame is a reader error, not a hang or a crash"
  (let ((conn (test-connection :stream (make-string-input-stream
                                        "(delta :agent \"A\" :content \"unterminated"))))
    (let ((form (read-wire conn)))
      (and (null form)
           (= 1 (stats-get conn :reader-error))
           (not (null (stats-get conn :last-error)))))))

;;;; --- 5. framing round trip over a string stream ------------------------

(test "write-wire emits one newline-delimited frame (prin1 + terpri + force-output)"
  (let ((conn (test-connection :stream (make-string-output-stream))))
    (write-wire conn '(subscribe :agent "A"))
    (let ((written (get-output-stream-string (tui-connection-stream conn))))
      ;; prin1 with *print-readably* t prints symbols UPPERCASE and quotes strings, so
      ;; the frame the server's `read` receives is "(SUBSCRIBE :AGENT \"A\")" plus the
      ;; newline. Expecting lowercase here would test the wrong contract.
      (and (equal written (format nil "(SUBSCRIBE :AGENT \"A\")~%"))
           (= 1 (stats-get conn :packets-written))))))

(test "a connection over a string stream round-trips write-wire/read-wire"
  (let ((out (make-string-output-stream)))
    (let ((conn (test-connection :stream out)))
      (write-wire conn '(delta :agent "A" :content "hi there"))
      (let ((back (test-connection :stream (make-string-input-stream
                                            (get-output-stream-string out)))))
        (let ((form (read-wire back)))
          (and (equal form '(delta :agent "A" :content "hi there"))
               (= 1 (stats-get back :packets-read))))))))

(test "decode-wire produces the right message class for a round-tripped frame"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn (read-wire (test-connection
                                             :stream (make-string-input-stream
                                                     (wire-line "resync :agent \"B\" :cursor 11")))))))
      (and (resync-msg-p msg)
           (equal (resync-msg-agent msg) "B")
           (= 11 (resync-msg-cursor msg))))))

;;;; --- 6. reader thread --------------------------------------------------

(test "start-wire-reader names the thread tui-wire-reader and decodes through it"
  (let* ((collected nil)
         (conn (test-connection
                :stream (make-string-input-stream
                         (concatenate 'string
                                      (wire-line "delta :agent \"A\" :content \"one\"")
                                      (wire-line "resync :agent \"A\" :cursor 2")
                                      (wire-line "ping :agent \"A\"")))
                :on-message (lambda (m) (push m collected))))
         (thread (start-wire-reader conn)))
    ;; join-thread returns the thread's return value (NIL here), so it is called for
    ;; its effect, not as a truthy step in the assertion chain.
    (sb-thread:join-thread thread)
    (and (equal (sb-thread:thread-name thread) "tui-wire-reader")
         ;; three wire frames plus the connection-closed message the loop emits at EOF
         (= 4 (length collected))
         (let ((msgs (reverse collected)))
           (and (delta-msg-p (first msgs))
                (resync-msg-p (second msgs))
                (wire-ignored-msg-p (third msgs))
                (connection-closed-msg-p (fourth msgs))))
         (= 3 (stats-get conn :packets-read))
         (= 1 (stats-get conn :decode-unknown)))))

(test "the reader thread does not crash when there is no program yet (send is guarded by program-running)"
  (let* ((collected nil)
         (conn (test-connection
                :stream (make-string-input-stream (wire-line "delta :agent \"A\" :content \"x\""))
                :on-message (lambda (m) (push m collected))))
         (thread (start-wire-reader conn)))
    (sb-thread:join-thread thread)
    (= 2 (length collected))))

(test "the reader thread records a condition on the stats instead of swallowing it"
  (let* ((conn (test-connection
                :stream (make-string-input-stream
                         (wire-line "delta :agent \"A\" :content #.boom"))))
         (thread (start-wire-reader conn)))
    (sb-thread:join-thread thread)
    (and (= 1 (stats-get conn :reader-error))
         (not (boundp 'sexpr-test-tui-client::boom))
         (not (null (stats-get conn :last-error)))
         ;; the failure is observable through the log, not only through the counter
         (let ((log (make-string-output-stream)))
           (let ((*tui-client-log* log))
             (let ((c2 (test-connection
                        :stream (make-string-input-stream
                                 (wire-line "delta :agent \"A\" :content #.zap")))))
               (read-wire c2)
               (search "reader error" (get-output-stream-string log))))))))

(test "no tui-wire-reader thread survives cleanup"
  (null (remove-if-not (lambda (th)
                         (and (sb-thread:thread-name th)
                              (equal (sb-thread:thread-name th) "tui-wire-reader")))
                        (sb-thread:list-all-threads))))

;;;; --- 7. observability --------------------------------------------------

(test "every connection carries the full counter set, zeroed"
  (let ((conn (test-connection)))
    (every (lambda (key) (and (getf (tui-connection-stats conn) key)
                              (= 0 (getf (tui-connection-stats conn) key))))
           '(:packets-read :unsolicited-skipped :reader-error :malformed
             :decode-unknown :rpc-errors :resyncs-handled :connection-closed
             :packets-written :last-error))))

(test "tui-client-diagnostics is the health handle: host, port, reader state, stats copy"
  (let ((conn (test-connection)))
    (decode-wire conn 42)
    (let ((diag (tui-client-diagnostics conn)))
      (and (equal (getf diag :host) "127.0.0.1")
           ;; getf takes ONE key, so the nested stats plist must be fetched first
           (= 1 (getf (getf diag :stats) :malformed))
           (null (getf diag :reader-alive))))))

(test "the health handle reports the reader thread and its state, before and after join"
  ;; A string stream EOFs immediately, so "alive at snapshot time" is a race. The
  ;; robust assertion is that the handle reports the SAME state as a direct
  ;; thread-alive-p check at the same instant, and NIL after the thread has joined.
  (let* ((conn (test-connection
                :stream (make-string-input-stream (wire-line "delta :agent \"A\" :content \"x\""))))
         (thread (start-wire-reader conn))
         (diag (tui-client-diagnostics conn)))
    ;; join-thread returns the thread's value (NIL here), so it must not sit inside the
    ;; assertion chain — it would short-circuit the and and fail for the wrong reason.
    (sb-thread:join-thread thread)
    (and (eq (getf diag :reader-thread) thread)
         (not (getf (tui-client-diagnostics conn) :reader-alive))
         (= 1 (getf (getf (tui-client-diagnostics conn) :stats) :packets-read))
         ;; the closed-connection message the loop emits at EOF is counted
         (= 1 (getf (getf (tui-client-diagnostics conn) :stats) :connection-closed))
         ;; the handle is safe on a NIL connection (the status bar may render before connect)
         (null (tui-client-diagnostics nil)))))

(test "*tui-client-log* defaults to NIL and writes one structured line per event when bound"
  (and (null *tui-client-log*)
       (let ((log (make-string-output-stream)))
         (let ((*tui-client-log* log))
           (let ((conn (test-connection)))
             (decode-wire conn 42)
             (decode-wire conn '(ping :agent "A"))
             (let ((out (get-output-stream-string log)))
               (and (search "[tui-client :port 0] malformed" out)
                    (search "[tui-client :port 0] unknown operator" out))))))))

(test "stats-get is safe from the render path while the reader thread writes"
  (let ((conn (test-connection
               :stream (make-string-input-stream (wire-line "delta :agent \"A\" :content \"x\"")))))
    (let ((thread (start-wire-reader conn)))
      ;; read the counter from the main thread while the reader is still running
      (let ((seen (stats-get conn :packets-read)))
        (sb-thread:join-thread thread)
        (and (integerp seen) (= 1 (stats-get conn :packets-read)))))))

;;;; --- 8. load profile: 10x burst ---------------------------------------

(test "a 1000-message burst decodes without loss or crash (10x the expected per-turn load)"
  (let ((payload (make-string-output-stream)))
    (loop for i from 1 to 1000
          do (format payload "(delta :agent \"A\" :content \"chunk-~D\")~%" i))
    (let ((conn (test-connection :stream (make-string-input-stream
                                          (get-output-stream-string payload)))))
      (let ((decoded 0))
        (loop
          (let ((form (read-wire conn)))
            (when (null form) (return nil))
            (when (delta-msg-p (decode-wire conn form)) (incf decoded)))
          (when (>= decoded 1000) (return nil)))
        (and (= decoded 1000)
             (= 1000 (stats-get conn :packets-read))
             (= 0 (stats-get conn :malformed)))))))

(test "the stats lock holds under concurrent writers (no lost increments at 10x load)"
  ;; Counters are driven through the public decoder surface, not an internal helper,
  ;; so this proves the lock on the path the reader thread actually uses.
  (let ((conn (test-connection)))
    (let ((threads (loop for i from 1 to 10
                         collect (sb-thread:make-thread
                                  (lambda ()
                                    (loop for j from 1 to 100
                                          do (decode-wire conn 42)))))))
      (loop for th in threads do (sb-thread:join-thread th))
      (= 1000 (stats-get conn :malformed)))))

(test "the stats plist is fixed-size under a malformed burst (no accumulating memory)"
  (let ((conn (test-connection)))
    (loop for i from 1 to 1000 do (decode-wire conn i))
    (and (= 1000 (stats-get conn :malformed))
         ;; the stats plist is one cell per counter (key + value), never an
         ;; accumulating list — a 1000-frame malformed burst cannot grow it
         (= (* 2 (length *client-stats-keys*)) (length (tui-connection-stats conn)))
         (null *tui-client-log*))))

;;;; --- 9. gates: SPDX headers and the R015 / deprecation invariants ------

(test "every new file carries the SPDX GPL-3.0-or-later header"
  (every #'file-has-spdx
         '("sexpr-tui.asd"
           "src/tui-client/package.lisp"
           "src/tui-client/messages.lisp"
           "src/tui-client/wire.lisp"
           "tests/test-tui-client.lisp")))

(test "R015: the client never names the provider transport"
  (not (search "sexpr.provider" (source-text "src/tui-client/wire.lisp"))))

(test "deprecation invariant: the client uses make-instance 'sb-bsd-sockets:inet-socket, never make-inet-socket"
  (and (search "make-instance 'sb-bsd-sockets:inet-socket" (source-text "src/tui-client/wire.lisp"))
       (not (search "make-inet-socket" (source-text "src/tui-client/wire.lisp")))))

(test "cl-tuition is declared in qlfile"
  (search "cl-tuition" (source-text "qlfile")))

(test "sexpr-tui.asd lists only files that exist"
  (every (lambda (name)
           (probe-file (merge-pathnames (format nil "src/tui-client/~A.lisp" name)
                                        (uiop:getcwd))))
         '("package" "messages" "wire")))

;;;; --- summary -------------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%" *tests-run* *tests-passed* *tests-failed*)
;; CL has no QUIT — it is SB-EXT:QUIT. The package :shadow is kept because :tuition
;; exports #:quit (the TEA quit message), which would otherwise be ambiguous with CL's.
(sb-ext:exit :code (if (> *tests-failed* 0) 1 0))
