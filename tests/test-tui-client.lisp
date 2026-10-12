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

;;;; --- 3b. T03: status / approval-needed decode (S04) -------------------
;;;
;;; S04 extends the client's wire vocabulary with the two unsolicited forms the
;;; push server (S04/T02) now translates from the bus: (status :agent A :status S
;;; :pending-approval P) and (approval-needed :agent A :capability C :target T
;;; :description D :restarts R). These are pure decoder tests over string streams
;;; and direct decode-wire calls: no network, no TTY, no model. Assertions are on
;;; the message class and the readers, never on interned-symbol EQ, because the
;;; reader interns the wire's first token in whatever package the stream used
;;; (MEM101) — the same reason the decoder dispatches by SYMBOL-NAME.

(test "T03: a STATUS form decodes to a status-msg with all three fields"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(status :agent "Alpha" :status :running
                                   :pending-approval t))))
      (and (status-msg-p msg)
           (equal (status-msg-agent msg) "Alpha")
           (eq (status-msg-status msg) :running)
           (eq (status-msg-pending-approval msg) t)
           (= 0 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T03: an APPROVAL-NEEDED form decodes to an approval-needed-msg with all five fields"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(approval-needed :agent "Alpha"
                                   :capability :fs-write
                                   :target "/tmp/x"
                                   :description "write file"
                                   :restarts (:skip :abort)))))
      (and (approval-needed-msg-p msg)
           (equal (approval-needed-msg-agent msg) "Alpha")
           (eq (approval-needed-msg-capability msg) :fs-write)
           (equal (approval-needed-msg-target msg) "/tmp/x")
           (equal (approval-needed-msg-description msg) "write file")
           (equal (approval-needed-msg-restarts msg) '(:skip :abort))
           (= 0 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T03: a nil pending-approval decodes as NIL, not as a missing field"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(status :agent "A" :status :idle :pending-approval nil))))
      (and (status-msg-p msg)
           (null (status-msg-pending-approval msg))
           (eq (status-msg-status msg) :idle)))))

(test "T03: the new operators dispatch by SYMBOL-NAME, not EQ (foreign package, lowercase)"
  ;; A real socket read interns the operator in the reading package, so EQ against a
  ;; client-side symbol would fail for the wrong reason. The upcased-name dispatch
  ;; must resolve both new operators from a foreign, lowercase symbol.
  (let ((conn (test-connection)))
    (let ((s (decode-wire conn (list (intern "status" :cl-user)
                                     :agent "A" :status :idle :pending-approval nil)))
          (a (decode-wire conn (list (intern "approval-needed" :cl-user)
                                     :agent "A" :capability :c :target "t"
                                     :description "d" :restarts nil))))
      (and (status-msg-p s)
           (approval-needed-msg-p a)
           (= 0 (stats-get conn :malformed))))))

(test "T03: a server-shaped status frame round-trips through read-wire and decode-wire"
  ;; The exact bytes the S04/T02 listener enqueues (src/tui/server.lisp
  ;; %delta-listener): the frame is the prin1 of the whole list, so the decoder is
  ;; driven from a real string stream, not a hand-built form.
  (let ((conn (test-connection
               :stream (make-string-input-stream
                        (wire-line "status :agent \"A\" :status :running :pending-approval nil")))))
    (let ((msg (decode-wire conn (read-wire conn))))
      (and (status-msg-p msg)
           (equal (status-msg-agent msg) "A")
           (eq (status-msg-status msg) :running)
           (null (status-msg-pending-approval msg))))))

(test "T03: a server-shaped approval-needed frame round-trips through read-wire and decode-wire"
  (let ((conn (test-connection
               :stream (make-string-input-stream
                        (wire-line "approval-needed :agent \"A\" :capability :fs-write :target \"/tmp/x\" :description \"write\" :restarts (:skip)")))))
    (let ((msg (decode-wire conn (read-wire conn))))
      (and (approval-needed-msg-p msg)
           (equal (approval-needed-msg-agent msg) "A")
           (eq (approval-needed-msg-capability msg) :fs-write)
           (equal (approval-needed-msg-target msg) "/tmp/x")
           (equal (approval-needed-msg-description msg) "write")
           (equal (approval-needed-msg-restarts msg) '(:skip))))))

(test "T03: an operator outside the extended vocabulary is still a wire-ignored-msg"
  ;; Forward compatibility is preserved: extending the vocabulary with two names must
  ;; not turn every other unknown operator into an error. tool-start is S05's name.
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(tool-start :agent "A"))))
      (and (wire-ignored-msg-p msg)
           (equal (wire-ignored-msg-op msg) "TOOL-START")
           (= 1 (stats-get conn :decode-unknown))
           (= 0 (stats-get conn :malformed))))))

(test "T03: a status with an odd-length tail stays a counted malformed wire-ignored-msg"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(status :agent "A" :status))))
      (and (wire-ignored-msg-p msg)
           (null (wire-ignored-msg-op msg))
           (= 1 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T03: a status with an improper tail stays malformed and does not signal"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(status :agent . 5))))
      (and (wire-ignored-msg-p msg)
           (= 1 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T03: an approval-needed with an empty payload stays malformed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(approval-needed))))
      (and (wire-ignored-msg-p msg)
           (= 1 (stats-get conn :malformed))))))

(test "T03: make-status-msg / make-approval-needed-msg round-trip their slots"
  (let ((s (make-status-msg :agent "A" :status :idle :pending-approval :x))
        (a (make-approval-needed-msg :agent "A" :capability :c :target "t"
                                     :description "d" :restarts '(:r))))
    (and (equal "A" (status-msg-agent s))
         (eq :idle (status-msg-status s))
         (eq :x (status-msg-pending-approval s))
         (equal "A" (approval-needed-msg-agent a))
         (eq :c (approval-needed-msg-capability a))
         (equal "t" (approval-needed-msg-target a))
         (equal "d" (approval-needed-msg-description a))
         (equal '(:r) (approval-needed-msg-restarts a)))))

(test "T03: the new message classes default every slot to NIL"
  (let ((s (make-status-msg)) (a (make-approval-needed-msg)))
    (and (null (status-msg-agent s)) (null (status-msg-status s))
         (null (status-msg-pending-approval s))
         (null (approval-needed-msg-agent a)) (null (approval-needed-msg-capability a))
         (null (approval-needed-msg-target a)) (null (approval-needed-msg-description a))
         (null (approval-needed-msg-restarts a)))))

(test "T03: the client package exports the new classes, constructors, predicates and readers"
  (every (lambda (name) (find-symbol name :sexpr-tui))
         '("STATUS-MSG" "MAKE-STATUS-MSG" "STATUS-MSG-P"
           "STATUS-MSG-AGENT" "STATUS-MSG-STATUS" "STATUS-MSG-PENDING-APPROVAL"
           "APPROVAL-NEEDED-MSG" "MAKE-APPROVAL-NEEDED-MSG" "APPROVAL-NEEDED-MSG-P"
           "APPROVAL-NEEDED-MSG-AGENT" "APPROVAL-NEEDED-MSG-CAPABILITY"
           "APPROVAL-NEEDED-MSG-TARGET" "APPROVAL-NEEDED-MSG-DESCRIPTION"
           "APPROVAL-NEEDED-MSG-RESTARTS")))

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

;;;; --- 8b. T04: the TEA model and the three panes ---------------------
;;;
;;; Headless model tests: every connection is a string stream, no TTY, no
;;; network. `tui:run` is never called. The model is driven through the
;;; TUITION seam `init`/`update`/`view` directly. The reader thread is never
;;; started: there is no program, so program-running-p is NIL and init skips it
;;; (MEM103). `tui:init` always runs one agent-snapshot RPC (continuation id 1)
;;; and, when a picked agent is set, one transcript-delta RPC (id 2); a resync in
;;; `update` runs a second transcript-delta (id 3). The canned swank stream
;;; below carries exactly those framed replies in id order.

(defun swank-reply (status value id)
  "One framed swank reply packet: `(:return (STATUS VALUE) ID)`.
The header is a BYTE count (MEM110) and the payload is prin1'd data, so the
model's `swank-value` reads it back with *read-eval* NIL. STATUS is :ok or
:abort; VALUE is the reply payload as Lisp data (a dotted pair for
transcript-delta, so (consp value) and (integerp (cdr value)) both hold)."
  (let* ((payload (let ((*print-pretty* nil))
                    (with-output-to-string (s)
                      (prin1 (list :return (list status value) id) s)))))
    (concatenate 'string (packet-header (length (utf8-bytes payload))) payload)))

(defun canned-swank (&rest replies)
  "A swank connection over a TWO-WAY string stream carrying REPLIES (framed packet
strings). The model's `swank-rpc` writes its request to the output side
(discarded) and reads the next matching reply from the input side, so the
connection must be bidirectional — a plain input stream cannot accept the request
write. Replies are placed in continuation-id order; swank-read-reply matches by id."
  (let ((in (make-string-input-stream (apply #'concatenate 'string replies)))
        (out (make-string-output-stream)))
    (new-swank-connection :port 0 :stream (make-two-way-stream in out))))

;; The two replies tui:init always consumes for a picked agent: agent-snapshot
;; (id 1, empty agent list) and the initial transcript-delta (id 2, empty events,
;; cursor 0). Tests that drive a resync append a third reply (id 3) to this list.
(defparameter *init-replies*
  (list (swank-reply :ok nil 1) (swank-reply :ok '(nil . 0) 2)))

(defun init-model (replies &key (picked "A") (push nil) (cap nil))
  "Build a tui-model over a canned swank connection carrying REPLIES and run
`tui:init` so the panes exist (the chat viewport is nil until init builds it, and
`view` renders nothing without it). CAP, when given, bounds the scrollback."
  (let ((model (if cap
                   (make-instance 'tui-model
                                   :swank-connection (apply #'canned-swank replies)
                                   :push-connection push
                                   :picked-agent picked
                                   :scrollback-cap cap)
                   (make-instance 'tui-model
                                   :swank-connection (apply #'canned-swank replies)
                                   :push-connection push
                                   :picked-agent picked))))
    (tui:init model)
    model))

(test "T04: a delta-msg puts the fragment text in the view string"
  (let ((model (init-model *init-replies*)))
    (tui:update model (make-delta-msg :agent "A" :content "frag"))
    (search "frag" (tui:view model))))

(test "T04: render-agent-rows shows the picked agent's name and status columns"
  (let ((rows (render-agent-rows (list (list :name "Alpha" :status :running)
                                       (list :name "Beta" :status :idle)))))
    (and (search "agent" rows)
         (search "status" rows)
         (search "Alpha" rows)
         (search "RUNNING" rows)
         (search "Beta" rows)
         (search "IDLE" rows))))

(test "T04: a resync-msg refetches; an empty (nil . cursor) reply is tolerated and the cursor is adopted"
  (let ((model (init-model (append *init-replies*
                                   (list (swank-reply :ok '(nil . 7) 3))))))
    (tui:update model (make-resync-msg :agent "A" :cursor 5))
    (and (= 7 (model-cursor model))
         ;; no error: the empty refetch is a success, and the ok reply never calls
         ;; client-note-error!, so :last-error keeps its zeroed initial value and
         ;; refresh-status's error suffix does not fire
         (eql 0 (client-stats-get (model-swank-connection model) :last-error))
         (search "agent: A" (model-status-text model))
         (stringp (tui:view model)))))

(test "T04: the scrollback cap holds across a 1000-delta burst"
  (let ((model (init-model *init-replies* :cap 50)))
    (loop for i from 1 to 1000
          do (tui:update model (make-delta-msg :agent "A" :content (format nil "c~D" i))))
    (and (<= (length (model-scrollback model)) 50)
         (stringp (tui:view model)))))

(test "T04: a wire-ignored-msg adds no chat line and does not corrupt the view"
  ;; The branch calls note-error with "ignored: <op>", but refresh-status rewrites
  ;; model-status-text from connection stats at the end of every update, so that
  ;; transient label is not durable. The durable contract is that an ignored wire
  ;; frame leaves the chat pane and the render path untouched. (The op is also
  ;; counted as :decode-unknown when it arrives through the decoder, not here.)
  (let ((model (init-model *init-replies*)))
    (let ((before (length (model-scrollback model))))
      (tui:update model (make-wire-ignored-msg :op "frob" :form '(frob)))
      (and (= before (length (model-scrollback model)))
           (stringp (tui:view model))))))

(test "T04: the status bar shows the last error after a failed RPC"
  ;; refresh-status derives the error line from each connection's :last-error
  ;; (note-error's label is transient and overwritten). client-note-error! is the
  ;; durable seam: a prior RPC that left :last-error set surfaces in the status
  ;; bar across the next refresh. init's agent-snapshot (id 1) is given an :ok
  ;; reply so it does not overwrite the prior error.
  (let* ((swank (canned-swank (swank-reply :ok nil 1)))
         (model (make-instance 'tui-model
                                :swank-connection swank
                                :push-connection nil
                                :picked-agent nil)))
    (client-note-error! swank "boom")
    (tui:init model)
    (search "boom" (model-status-text model))))

;;;; --- 9. gates: SPDX headers and the R015 / deprecation invariants ------

(test "every new file carries the SPDX GPL-3.0-or-later header"
  (every #'file-has-spdx
         '("sexpr-tui.asd"
           "src/tui-client/package.lisp"
           "src/tui-client/messages.lisp"
           "src/tui-client/wire.lisp"
           "src/tui-client/swank-rpc.lisp"
           "src/tui-client/view.lisp"
           "src/tui-client/model.lisp"
           "src/tui-client/main.lisp"
           "tests/test-tui-client.lisp")))

(defparameter *client-source-files*
  '("src/tui-client/package.lisp"
    "src/tui-client/messages.lisp"
    "src/tui-client/wire.lisp"
    "src/tui-client/swank-rpc.lisp"
    "src/tui-client/view.lisp"
    "src/tui-client/model.lisp"
    "src/tui-client/main.lisp")
  "Every source file of the :sexpr-tui system, for the package-wide absence gates.")

(defun sexpr-package-tokens (text)
  "Every `sexpr.<name>` package token in TEXT, downcased and de-duplicated.
A tiny scanner (CL has no regex): find each `sexpr.` case-insensitively and take
the following name characters. `sexpr.*` (a docstring's wildcard) yields no token."
  (let ((tokens '())
        (start 0))
    (loop
      (let ((pos (search "sexpr." text :start2 start :test #'char-equal)))
        (when (null pos) (return))
        (let* ((from (+ pos 6))
               (to (or (position-if-not
                        (lambda (c) (or (alphanumericp c) (char= c #\-)))
                        text :start from)
                       (length text))))
          (when (> to from)
            (push (string-downcase (subseq text from to)) tokens)))
        (setf start (+ pos 6))))
    (remove-duplicates tokens :test #'string=)))

(test "R015: no client source names the provider transport"
  (notany (lambda (f)
            (let ((s (source-text f)))
              (or (search "sexpr.provider" s :test #'char-equal)
                  (search "cl-llm-provider" s :test #'char-equal))))
          *client-source-files*))

(test "R015: the client names only sexpr.tui/sexpr.repl/sexpr.agents — never a provider package"
  ;; The client process has no sexpr.* package at all (MEM102/D020): every sexpr.*
  ;; name it uses is either the sexpr.tui RPC inside packet text or the
  ;; sexpr.repl/sexpr.agents names inside the REPL let-wrapper text. Any other
  ;; package name (e.g. sexpr.provider) would be a boundary violation.
  (every (lambda (f)
           (every (lambda (tok)
                    (member tok '("tui" "repl" "agents") :test #'string=))
                  (sexpr-package-tokens (source-text f))))
         *client-source-files*))

(test "R015: the client's RPCs are sexpr.tui qualified names inside packet text"
  ;; The three RPC forms the client builds are STRING literals it writes into a
  ;; swank packet (never forms the client reads). Asserting the exact literals keeps
  ;; a future edit from turning one into a live symbol read.
  (let ((model (source-text "src/tui-client/model.lisp")))
    (and (search "\"(sexpr.tui:agent-snapshot)\"" model)
         (search "\"(sexpr.tui:transcript-delta ~A ~D)\"" model)
         (search "\"(sexpr.tui:inject-note ~A ~A)\"" model))))

(test "deprecation invariant: every client socket uses make-instance 'sb-bsd-sockets:inet-socket, never make-inet-socket"
  (and (notany (lambda (f) (search "make-inet-socket" (source-text f)))
               *client-source-files*)
       ;; the two socket-owning files both build the socket with the sanctioned form
       (every (lambda (f)
                (search "make-instance 'sb-bsd-sockets:inet-socket" (source-text f)))
              '("src/tui-client/wire.lisp" "src/tui-client/swank-rpc.lisp"))))

(test "cl-tuition is declared in qlfile"
  (search "cl-tuition" (source-text "qlfile")))

(test "sexpr-tui.asd lists only files that exist"
  (every (lambda (name)
           (probe-file (merge-pathnames (format nil "src/tui-client/~A.lisp" name)
                                        (uiop:getcwd))))
         '("package" "messages" "wire" "swank-rpc" "view" "model" "main")))

;;;; --- 8c. T05: input paths, entry point, and make tui -------------------
;;;
;;; Chat note and REPL eval tests. Each test creates a model over a canned
;;; swank connection with a visible output stream, types text into the
;;; textarea, presses Enter, and asserts on the packet text, the scrollback,
;;; and the textarea state.

(defun canned-swank-with-output (&rest replies)
  "Like canned-swank, but returns (values connection output-stream) so a test
can assert on the packet text the model wrote."
  (let ((in (make-string-input-stream (apply #'concatenate 'string replies)))
        (out (make-string-output-stream)))
    (values (new-swank-connection :port 0 :stream (make-two-way-stream in out))
            out)))

(defun make-enter-msg ()
  "An :enter key message."
  (make-key-msg :key :enter))

(test "T05: chat note packet contains the handle id and not the agent name"
  (multiple-value-bind (conn out)
      (canned-swank-with-output (swank-reply :ok nil 1)
                                (swank-reply :ok '(nil . 0) 2))
    (let ((model (make-instance 'tui-model
                                :swank-connection conn
                                :picked-agent "Alpha")))
      (tui:init model)
      ;; drain the two init request packets (agent-snapshot, transcript-delta) so
      ;; the assertion below sees ONLY the note packet (the transcript-delta packet
      ;; contains "Alpha", which would otherwise defeat the not-search check)
      (get-output-stream-string out)
      (setf (model-agents model)
            (list (list :name "Alpha" :status :running :handle "subagent-1")))
      (let ((ta (model-chat-textarea model)))
        (tui.textarea:textarea-set-value ta "hello agent")
        (tui:update model (make-enter-msg))
        (let ((packet-text (get-output-stream-string out)))
          (and (search "subagent-1" packet-text)
               (not (search "Alpha" packet-text))
               (search "inject-note" packet-text)
               (search "hello agent" packet-text)
               (string= "" (tui.textarea:textarea-value ta))
               ;; model-scrollback is a LIST of lines; `search` on a list compares
               ;; elements by EQL, not substrings, so join first.
               (search "noted" (lines-to-string (model-scrollback model)))))))))

(test "T05: REPL packet contains the let wrapper with the picked name"
  (multiple-value-bind (conn out)
      (canned-swank-with-output (swank-reply :ok nil 1)
                                (swank-reply :ok '(nil . 0) 2)
                                (swank-reply :ok "result" 3))
    (let ((model (make-instance 'tui-model
                                :swank-connection conn
                                :picked-agent "Alpha")))
      (tui:init model)
      ;; drain the two init request packets so packet-text is ONLY the REPL request
      (get-output-stream-string out)
      (setf (model-focused model) :repl)
      (let ((ta (model-repl-textarea model)))
        (tui.textarea:textarea-set-value ta "(+ 1 2)")
        (tui:update model (make-enter-msg))
        (let ((packet-text (get-output-stream-string out)))
          (and (search "let" packet-text)
               (search "sexpr.repl:*agent*" packet-text)
               (search "Alpha" packet-text)
               (search "sexpr.agents:*agent-table*" packet-text)
               (search "(+ 1 2)" packet-text)
               (string= "" (tui.textarea:textarea-value ta))
               ;; model-repl-lines is a LIST of lines; join before searching.
               (search "result" (lines-to-string (model-repl-lines model)))))))))

(test "T05: a NIL handle yields a status-bar error, not a crash"
  (multiple-value-bind (conn out)
      (canned-swank-with-output (swank-reply :ok nil 1)
                                (swank-reply :ok '(nil . 0) 2))
    (let ((model (make-instance 'tui-model
                                :swank-connection conn
                                :picked-agent "Alpha")))
      (tui:init model)
      ;; drain the init request packets so the no-packet assertion is meaningful
      (get-output-stream-string out)
      (setf (model-agents model)
            (list (list :name "Alpha" :status :running :handle nil)))
      (let ((ta (model-chat-textarea model)))
        (tui.textarea:textarea-set-value ta "hello")
        (tui:update model (make-enter-msg))
        (and (search "no handle" (model-status-text model))
             (string= "" (get-output-stream-string out))
             (string= "hello" (tui.textarea:textarea-value ta)))))))

(test "T05: parse-args defaults resolve correctly"
  (multiple-value-bind (options help-p)
      (parse-args '())
    (and (null help-p)
         (string= "127.0.0.1" (getf options :host))
         (= 4004 (getf options :swank-port))
         (null (getf options :push-port))
         (null (getf options :agent)))))

(test "T05: parse-args overrides resolve correctly"
  (multiple-value-bind (options help-p)
      (parse-args '("--host" "192.168.1.1"
                   "--swank-port" "5000"
                   "--push-port" "6000"
                   "--agent" "Beta"))
    (and (null help-p)
         (string= "192.168.1.1" (getf options :host))
         (= 5000 (getf options :swank-port))
         (= 6000 (getf options :push-port))
         (string= "Beta" (getf options :agent)))))

(test "T05: parse-args --help returns help-p"
  (multiple-value-bind (options help-p)
      (parse-args '("--help"))
    (and help-p
         (string= "127.0.0.1" (getf options :host)))))

(test "T05: the make tui target registers the project and propagates main's exit code"
  ;; `ql:quickload :sexpr-tui` on its own fails with SYSTEM-NOT-FOUND: quicklisp caches
  ;; its local-projects scan in ~/quicklisp/local-projects/system-index.txt, which does
  ;; not learn about sexpr-tui.asd when it lands after the project was symlinked. The
  ;; target must put the repo root on asdf:*central-registry* first (the same pattern
  ;; tests/test-tui-client.lisp uses), and must exit with main's own code so a refused
  ;; connection is a non-zero `make tui`.
  (let ((mk (source-text "Makefile")))
    (and (search "tui:" mk)
         (search "asdf:*central-registry*" mk)
         (search ":sexpr-tui" mk)
         (search "sb-ext:exit :code (sexpr-tui:main" mk)
         (search "TUI_ARGS" mk))))

;;;; --- summary -------------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%" *tests-run* *tests-passed* *tests-failed*)
;; CL has no QUIT — it is SB-EXT:QUIT. The package :shadow is kept because :tuition
;; exports #:quit (the TEA quit message), which would otherwise be ambiguous with CL's.
(sb-ext:exit :code (if (> *tests-failed* 0) 1 0))
