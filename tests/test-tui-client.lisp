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

(format t "~%== sexpr-tui client (T01: system, messages, decoder) ==~%")

;;;; --- 1. system boundary (must-have #5, asserted not prose) --------------

(test "sexpr-tui :depends-on contains :tuition"
  (member :tuition (asdf:system-depends-on (asdf:find-system :sexpr-tui))))

(test "sexpr-tui :depends-on does not contain :sexpr"
  (not (member :sexpr (asdf:system-depends-on (asdf:find-system :sexpr-tui)))))

(test "sexpr.asd gained no :tuition — quickload :sexpr never pulls a TUI library into the image"
  (not (member :tuition (asdf:system-depends-on (asdf:find-system :sexpr)))))

(test ":sexpr-tui :use list is exactly (:cl :tuition)"
  (equal (sort (mapcar #'package-name (package-use-list (find-package :sexpr-tui))) #'string<)
         '("CL" "TUITION")))

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
  (test "lowercase wire operators dispatch (the wire is not case-normalized on the wire)")
    (let ((msg (decode-wire conn (list (intern "resync" :cl-user) :agent "A" :cursor 7))))
      (and (resync-msg-p msg) (= 7 (resync-msg-cursor msg)))))
  (test "subscribed dispatches and carries the race-closure cursor")
    (let ((msg (decode-wire conn (list (intern "subscribed" :cl-user) :agent "A" :cursor 3))))
      (and (subscribed-msg-p msg) (= 3 (subscribed-msg-cursor msg)))))

(test "getf on the WHOLE message signals 'malformed property list' in this SBCL — the CDR is required"
  (handler-case
      (progn (getf '(delta :agent "A" :content "hi") :agent) nil)
    (error (err)
      (search "malformed property list" (format nil "~a" err)))))

(test "decode reads fields from the CDR, not the whole message"
  (let ((conn (test-connection))
        (msg (decode-wire (test-connection) '(delta :agent "A" :content "frag"))))
    (and (equal (delta-msg-content msg) "frag")
         (= 0 (stats-get conn :malformed)))))

;;;; --- 3. negative surface: malformed and unknown ------------------------

(test "a non-list message is counted as malformed, not crashed"
  (let ((conn (test-connection))
        (msg (decode-wire (test-connection) 42)))
    (and (wire-ignored-msg-p msg)
         (null (wire-ignored-msg-op msg))
         (= 1 (stats-get conn :malformed)))))

(test "an improper plist is counted as malformed, not crashed"
  (let ((conn (test-connection))
        (msg (decode-wire conn '(delta :agent . 5))))
    (and (wire-ignored-msg-p msg) (= 1 (stats-get conn :malformed)))))

(test "a bare symbol (no plist) is malformed, not crashed"
  (let ((conn (test-connection))
        (msg (decode-wire conn 'delta)))
    (and (wire-ignored-msg-p msg) (= 1 (stats-get conn :malformed)))))

(test "an unknown operator is ignored, not rejected — forward compatibility with a newer server"
  (let ((conn (test-connection))
        (msg (decode-wire conn '(finalize :agent "A"))))
    (and (wire-ignored-msg-p msg)
         (equal (wire-ignored-msg-op msg) "FINALIZE")
         (= 1 (stats-get conn :decode-unknown))
         (= 0 (stats-get conn :malformed)))))

(test "a resync is counted as a handled resync"
  (let ((conn (test-connection)))
    (decode-wire conn '(resync :agent "A" :cursor 2))
    (= 1 (stats-get conn :resyncs-handled))))

;;;; --- 4. *read-eval* discipline -----------------------------------------

(test "#. in a wire payload is not evaluated (the sentinel stays unbound) and the connection survives"
  (and (not (boundp 'sexpr-test-tui-client::sentinel))
       (let ((conn (test-connection
                    :stream (make-string-input-stream
                             ;; #. must be OUTSIDE the string literal to be a read-time
                             ;; eval macro at all; inside a quoted string it is just
                             ;; characters and would prove nothing.
                             "delta :agent \"A\" :content #.sentinel\ndelta :agent \"A\" :content \"ok\"\n"))))
         (let ((first (read-wire conn)))
           (and (null first)
                (not (boundp 'sexpr-test-tui-client::sentinel))
                (= 1 (stats-get conn :reader-error))
                ;; the connection is still usable: the next line decodes normally
                (let ((second (decode-wire conn (read-wire conn))))
                  (and (delta-msg-p second)
                       (equal (delta-msg-content second) "ok")))))))))

(test "EOF returns NIL and counts a closed connection rather than signalling")
  (let ((conn (test-connection :stream (make-string-input-stream ""))))
    (and (null (read-wire conn)) (= 1 (stats-get conn :connection-closed)))))

;;;; --- 5. framing round trip over a string stream ------------------------

(test "write-wire emits one newline-delimited frame (prin1 + terpri + force-output)"
  (let ((conn (test-connection :stream (make-string-output-stream))))
    (write-wire conn '(subscribe :agent "A"))
    (let ((written (get-output-stream-string (tui-connection-stream conn))))
      (and (equal written "subscribe :agent \"A\"\n")
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
                                                     "resync :agent \"B\" :cursor 11\n"))))))
      (and (resync-msg-p msg)
           (equal (resync-msg-agent msg) "B")
           (= 11 (resync-msg-cursor msg))))))

;;;; --- 6. reader thread --------------------------------------------------

(test "start-wire-reader names the thread tui-wire-reader and decodes through it"
  (let ((collected nil)
        (conn (test-connection
               :stream (make-string-input-stream
                        "delta :agent \"A\" :content \"one\"\nresync :agent \"A\" :cursor 2\nping :agent \"A\"\n"))
               :on-message (lambda (m) (push m collected))))
    (let ((thread (start-wire-reader conn)))
      ;; join-thread returns the thread's return value (NIL here), so it is called
      ;; for its effect, not as a truthy step in the assertion chain.
      (unless (equal (sb-thread:thread-name thread) "tui-wire-reader")
        (return-from test-wire-reader nil))
      (sb-thread:join-thread thread)
      ;; three wire messages plus the connection-closed message the loop emits at EOF
      (and (= 4 (length collected))
           (let ((msgs (reverse collected)))
             (and (delta-msg-p (first msgs))
                  (resync-msg-p (second msgs))
                  (wire-ignored-msg-p (third msgs))
                  (connection-closed-msg-p (fourth msgs))))
           (= 3 (stats-get conn :packets-read))
           (= 1 (stats-get conn :decode-unknown))))))

(test "the reader thread does not crash when there is no program yet (send is guarded by program-running)"
  (let ((collected nil)
        (conn (test-connection
               :stream (make-string-input-stream "delta :agent \"A\" :content \"x\"\n")
               :on-message (lambda (m) (push m collected)))))
    (sb-thread:join-thread (start-wire-reader conn))
    (= 2 (length collected))))

(test "the reader thread records a condition on the stats instead of swallowing it"
  (let ((conn (test-connection
               :stream (make-string-input-stream "delta :agent \"A\" :content \"#.boom\"\n")
               :on-message nil)))
    (sb-thread:join-thread (start-wire-reader conn))
    (and (= 1 (stats-get conn :reader-error))
         (not (boundp 'sexpr-test-tui-client::boom))
         (not (null (stats-get conn :last-error))))))

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
           (= 1 (getf diag :stats :malformed))
           (null (getf diag :reader-alive))))))

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
               :stream (make-string-input-stream "delta :agent \"A\" :content \"x\"\n"))))
    (let ((thread (start-wire-reader conn)))
      ;; read the counter from the main thread while the reader is still running
      (let ((seen (stats-get conn :packets-read)))
        (sb-thread:join-thread thread)
        (and (integerp seen) (= 1 (stats-get conn :packets-read)))))))

;;;; --- 8. load profile: 10x burst ---------------------------------------

(test "a 1000-message burst decodes without loss or crash (10x the expected per-turn load)"
  (let ((conn (test-connection))
        (payload (make-string-output-stream)))
    (loop for i from 1 to 1000
          do (format payload "delta :agent \"A\" :content \"chunk-~D\"~%" i))
    (let ((in (make-string-input-stream (get-output-stream-string payload))))
      (let ((decoded 0))
        (loop
          (let ((form (read-wire (setf (tui-connection-stream conn) in))))
            (when (null form) (return nil))
            (when (delta-msg-p (decode-wire conn form)) (incf decoded)))
          (when (>= decoded 1000) (return nil)))
        (and (= decoded 1000)
             (= 1000 (stats-get conn :packets-read))
             (= 0 (stats-get conn :malformed)))))))

(test "the stats lock holds under concurrent writers (no lost increments at 10x load)"
  (let ((conn (test-connection)))
    (let ((threads (loop for i from 1 to 10
                         collect (sb-thread:make-thread
                                  (lambda ()
                                    (loop for j from 1 to 100
                                          do (%count! conn :packets-read)))))))
      (loop for th in threads do (sb-thread:join-thread th))
      (= 1000 (stats-get conn :packets-read)))))

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

;;;; --- summary -------------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%" *tests-run* *tests-passed* *tests-failed*)
(quit (if (> *tests-failed* 0) 1 0))
