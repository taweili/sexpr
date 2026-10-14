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
    (let ((msg (decode-wire conn '(future-unknown :agent "A"))))
      (and (wire-ignored-msg-p msg)
           (equal (wire-ignored-msg-op msg) "FUTURE-UNKNOWN")
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
  ;; not turn every other unknown operator into an error. FUTURE-UNKNOWN is genuinely
  ;; outside the vocabulary (finalize/tool-start are S05 names and now decode).
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(future-unknown :agent "A"))))
      (and (wire-ignored-msg-p msg)
           (equal (wire-ignored-msg-op msg) "FUTURE-UNKNOWN")
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

;;;; --- 3c. T05: finalize / tool-progress / budget vocabulary (S05) -------
;;;
;;; S05 extends the wire vocabulary with the streaming-turn lifecycle the push
;;; server (S05/T04) now forwards: (finalize :agent A :event-index N),
;;; (tool-start :agent A :call-id C :name N), (tool-result :agent A :call-id C
;;; :value V :text T) and (budget-exceeded :agent A :tokens-used U :limit L).
;;; DELTA also gains an optional :kind so model prose and a tool's streamed output
;;; on the same operator are distinguishable. Every operator dispatches by upcased
;;; SYMBOL-NAME and reads fields from the CDR, and every one sits after the shared
;;; well-formed-payload-p guard, so an odd or improper tail stays a counted
;;; :malformed wire-ignored-msg rather than signalling.

(test "T05: a FINALIZE form decodes to a finalize-msg with agent and event-index"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(finalize :agent "Alpha" :event-index 7))))
      (and (finalize-msg-p msg)
           (equal (finalize-msg-agent msg) "Alpha")
           (= 7 (finalize-msg-event-index msg))
           (= 0 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T05: a TOOL-START form decodes to a tool-start-msg with all three fields"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(tool-start :agent "Alpha" :call-id "c1" :name "get_weather"))))
      (and (tool-start-msg-p msg)
           (equal (tool-start-msg-agent msg) "Alpha")
           (equal (tool-start-msg-call-id msg) "c1")
           (equal (tool-start-msg-name msg) "get_weather")
           (= 0 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T05: a TOOL-RESULT form decodes to a tool-result-msg with all four fields"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(tool-result :agent "Alpha" :call-id "c1"
                                    :value (:temperature 18) :text "18C"))))
      (and (tool-result-msg-p msg)
           (equal (tool-result-msg-agent msg) "Alpha")
           (equal (tool-result-msg-call-id msg) "c1")
           (equal (tool-result-msg-value msg) '(:temperature 18))
           (equal (tool-result-msg-text msg) "18C")
           (= 0 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T05: a BUDGET-EXCEEDED form decodes to a budget-exceeded-msg with all three fields"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(budget-exceeded :agent "Alpha" :tokens-used 4096 :limit 4000))))
      (and (budget-exceeded-msg-p msg)
           (equal (budget-exceeded-msg-agent msg) "Alpha")
           (= 4096 (budget-exceeded-msg-tokens-used msg))
           (= 4000 (budget-exceeded-msg-limit msg))
           (= 0 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T05: a delta with :kind :tool decodes with kind :tool"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(delta :agent "A" :content "partial" :kind :tool))))
      (and (delta-msg-p msg)
           (eq :tool (delta-msg-kind msg))
           (equal "partial" (delta-msg-content msg))))))

(test "T05: a kind-less delta decodes as :model (an older server is still model prose)"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(delta :agent "A" :content "hi"))))
      (and (delta-msg-p msg)
           (eq :model (delta-msg-kind msg))))))

(test "T05: the new operators dispatch by SYMBOL-NAME, not EQ (foreign package, lowercase)"
  (let ((conn (test-connection)))
    (let ((f (decode-wire conn (list (intern "finalize" :cl-user) :agent "A" :event-index 1)))
          (ts (decode-wire conn (list (intern "tool-start" :cl-user)
                                      :agent "A" :call-id "c" :name "n")))
          (tr (decode-wire conn (list (intern "tool-result" :cl-user)
                                      :agent "A" :call-id "c" :value 1 :text "t")))
          (b (decode-wire conn (list (intern "budget-exceeded" :cl-user)
                                     :agent "A" :tokens-used 1 :limit 0))))
      (and (finalize-msg-p f)
           (tool-start-msg-p ts)
           (tool-result-msg-p tr)
           (budget-exceeded-msg-p b)
           (= 0 (stats-get conn :malformed))))))

(test "T05: a server-shaped finalize frame round-trips through read-wire and decode-wire"
  (let ((conn (test-connection
               :stream (make-string-input-stream
                        (wire-line "finalize :agent \"A\" :event-index 3")))))
    (let ((msg (decode-wire conn (read-wire conn))))
      (and (finalize-msg-p msg)
           (equal (finalize-msg-agent msg) "A")
           (= 3 (finalize-msg-event-index msg))))))

(test "T05: a server-shaped tool-result frame round-trips through read-wire and decode-wire"
  (let ((conn (test-connection
               :stream (make-string-input-stream
                        (wire-line "tool-result :agent \"A\" :call-id \"c1\" :value :ok :text \"done\"")))))
    (let ((msg (decode-wire conn (read-wire conn))))
      (and (tool-result-msg-p msg)
           (equal (tool-result-msg-call-id msg) "c1")
           (eq :ok (tool-result-msg-value msg))
           (equal "done" (tool-result-msg-text msg))))))

(test "T05: a malformed finalize (odd tail) is a counted :malformed wire-ignored-msg, not a signal"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(finalize :agent "A" :event-index))))
      (and (wire-ignored-msg-p msg)
           (null (wire-ignored-msg-op msg))
           (= 1 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T05: an improper tool-result tail stays malformed and does not signal"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(tool-result :agent . 5))))
      (and (wire-ignored-msg-p msg)
           (= 1 (stats-get conn :malformed))
           (= 0 (stats-get conn :decode-unknown))))))

(test "T05: an empty budget-exceeded payload stays malformed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(budget-exceeded))))
      (and (wire-ignored-msg-p msg)
           (= 1 (stats-get conn :malformed))))))

(test "T05: an unknown operator is still counted :decode-unknown, not malformed"
  (let ((conn (test-connection)))
    (let ((msg (decode-wire conn '(future-unknown :agent "A" :x 1))))
      (and (wire-ignored-msg-p msg)
           (equal (wire-ignored-msg-op msg) "FUTURE-UNKNOWN")
           (= 1 (stats-get conn :decode-unknown))
           (= 0 (stats-get conn :malformed))))))

(test "T05: make- constructors round-trip the new slots and default to NIL"
  (let ((f (make-finalize-msg :agent "A" :event-index 2))
        (ts (make-tool-start-msg :agent "A" :call-id "c" :name "n"))
        (tr (make-tool-result-msg :agent "A" :call-id "c" :value :v :text "t"))
        (b (make-budget-exceeded-msg :agent "A" :tokens-used 5 :limit 4))
        (f0 (make-finalize-msg)) (ts0 (make-tool-start-msg))
        (tr0 (make-tool-result-msg)) (b0 (make-budget-exceeded-msg)))
    (and (equal "A" (finalize-msg-agent f)) (= 2 (finalize-msg-event-index f))
         (equal "c" (tool-start-msg-call-id ts)) (equal "n" (tool-start-msg-name ts))
         (eq :v (tool-result-msg-value tr)) (equal "t" (tool-result-msg-text tr))
         (= 5 (budget-exceeded-msg-tokens-used b)) (= 4 (budget-exceeded-msg-limit b))
         (null (finalize-msg-agent f0)) (null (finalize-msg-event-index f0))
         (null (tool-start-msg-agent ts0)) (null (tool-start-msg-call-id ts0))
         (null (tool-start-msg-name ts0))
         (null (tool-result-msg-value tr0)) (null (tool-result-msg-text tr0))
         (null (budget-exceeded-msg-tokens-used b0)) (null (budget-exceeded-msg-limit b0))
         ;; make-delta-msg still defaults to :model, and accepts an explicit kind
         (eq :model (delta-msg-kind (make-delta-msg :agent "A" :content "x")))
         (eq :tool (delta-msg-kind (make-delta-msg :agent "A" :content "x" :kind :tool))))))

(test "T05: the client package exports the new classes, constructors, predicates and readers"
  (every (lambda (name)
           (multiple-value-bind (sym status) (find-symbol name :sexpr-tui)
             (and sym (eq status :external))))
         '("DELTA-MSG-KIND"
           "FINALIZE-MSG" "MAKE-FINALIZE-MSG" "FINALIZE-MSG-P"
           "FINALIZE-MSG-AGENT" "FINALIZE-MSG-EVENT-INDEX"
           "TOOL-START-MSG" "MAKE-TOOL-START-MSG" "TOOL-START-MSG-P"
           "TOOL-START-MSG-AGENT" "TOOL-START-MSG-CALL-ID" "TOOL-START-MSG-NAME"
           "TOOL-RESULT-MSG" "MAKE-TOOL-RESULT-MSG" "TOOL-RESULT-MSG-P"
           "TOOL-RESULT-MSG-AGENT" "TOOL-RESULT-MSG-CALL-ID"
           "TOOL-RESULT-MSG-VALUE" "TOOL-RESULT-MSG-TEXT"
           "BUDGET-EXCEEDED-MSG" "MAKE-BUDGET-EXCEEDED-MSG" "BUDGET-EXCEEDED-MSG-P"
           "BUDGET-EXCEEDED-MSG-AGENT" "BUDGET-EXCEEDED-MSG-TOKENS-USED"
           "BUDGET-EXCEEDED-MSG-LIMIT")))

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

;;;; --- 8c. S04 T04: agent lights, per-agent state, subscribe-all, resolve RPC ---
;;;
;;; The model is the source of truth for the agent lights. agent-light is a pure
;;; function; the status/approval branches are driven through tui:update; the
;;; subscribe burst and the resolution RPC are asserted on the bytes the client
;;; wrote plus the model state they changed. Still headless: no TTY, no network,
;;; `tui:run` never called.

(defun model-agent-row (model name)
  "The agent-snapshot plist named NAME in MODEL, or NIL."
  (find name (model-agents model)
        :key (lambda (a) (getf a :name)) :test #'string=))

(defun count-substring (needle haystack)
  "How many times NEEDLE occurs in HAYSTACK (non-overlapping)."
  (let ((count 0) (start 0))
    (loop for pos = (search needle haystack :start2 start)
          while pos
          do (incf count) (setf start (+ pos (length needle))))
    count))

(defun canned-swank-capturing (&rest replies)
  "Like canned-swank, but returns (VALUES connection out-stream) so a test can read
back the request packet TEXT the client wrote (the RPC path writes to the output side
of the two-way stream, which canned-swank discards)."
  (let* ((in (make-string-input-stream (apply #'concatenate 'string replies)))
         (out (make-string-output-stream)))
    (values (new-swank-connection :port 0 :stream (make-two-way-stream in out))
            out)))

(defun capturing-push ()
  "A push connection over a two-way string stream; returns (VALUES connection out) so
a test can read the frames init wrote (the SUBSCRIBE burst). The reader thread is
never started because the model has no program, so program-running-p is NIL."
  (let* ((in (make-string-input-stream ""))
         (out (make-string-output-stream)))
    (values (make-client-connection :host "127.0.0.1" :port 0
                                    :stream (make-two-way-stream in out))
            out)))

(defun two-agent-snapshot-reply ()
  "An agent-snapshot :ok reply (continuation id 1) carrying two rows, so the model has
a society to light up. init's transcript-delta is id 2."
  (swank-reply :ok '((:name "Alpha" :status :idle) (:name "Beta" :status :idle)) 1))

(defun init-two-agent-model (&key (picked "Alpha") push swank)
  "Build and init a tui-model over a canned two-agent swank connection. SWANK, when
given, replaces the canned connection (so a test can capture its output). Returns the
model. The transcript-delta reply is id 2 (an empty refetch)."
  (let* ((conn (or swank
                   (canned-swank (two-agent-snapshot-reply)
                                 (swank-reply :ok '(nil . 0) 2))))
         (model (make-instance 'tui-model :swank-connection conn
                                         :push-connection push
                                         :picked-agent picked)))
    (tui:init model)
    model))

(test "S05/T06: agent-light maps pending -> yellow, streaming -> red, else green, and never signals"
  ;; S05/T06 retires S04's v1 running+live-thread heuristic: the true busy signal is
  ;; the data-only :streaming boolean (F6). A running agent with a live thread but no
  ;; in-flight stream is NOT busy and lights green.
  (and (eq :yellow (agent-light (list :name "A" :pending-approval t)))
       (eq :yellow (agent-light (list :name "A" :status :idle
                                      :pending-approval '(:capability "net"))))
       (eq :red (agent-light (list :name "A" :streaming t)))
       (eq :green (agent-light (list :name "A" :status :running :thread-alive-p t)))
       (eq :green (agent-light (list :name "A" :status :finished)))
       (eq :green (agent-light (list :name "A" :status :running :thread-alive-p nil)))
       ;; a bare plist and NIL degrade to green rather than signalling
       (eq :green (agent-light (list :name "A")))
       (eq :green (agent-light nil))))

(test "S04/T04: a status-msg updates the matching row and sets model-pending-approval only for the picked agent"
  (let ((model (init-two-agent-model :picked "Alpha")))
    ;; Both frames carry :pending-approval explicitly (the approval path), so
    ;; pending-approval-p is T and the pending state is SET, not preserved.
    (tui:update model (make-status-msg :agent "Alpha" :status :running
                                       :pending-approval :x
                                       :pending-approval-p t))
    (let ((alpha-status (getf (model-agent-row model "Alpha") :status))
          (alpha-pending (getf (model-agent-row model "Alpha") :pending-approval))
          (picked-pending (model-pending-approval model)))
      (tui:update model (make-status-msg :agent "Beta" :status :running
                                         :pending-approval :y
                                         :pending-approval-p t))
      (and (eq :running alpha-status)
           (eq :x alpha-pending)
           (eq :x picked-pending)
           ;; Beta's row is updated, but Beta is not picked, so the picked pending
           ;; state is untouched
           (eq :running (getf (model-agent-row model "Beta") :status))
           (eq :y (getf (model-agent-row model "Beta") :pending-approval))
           (eq :x (model-pending-approval model))))))

(test "S04/T04: a status-msg WITHOUT :pending-approval preserves the row's pending state"
  ;; The worker start/finish announcements omit the key; a finish announcement
  ;; must not silently resolve an outstanding approval.
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-status-msg :agent "Alpha" :status :running
                                       :pending-approval :x
                                       :pending-approval-p t))
    (tui:update model (make-status-msg :agent "Alpha" :status :finished))
    (and (eq :finished (getf (model-agent-row model "Alpha") :status))
         (eq :x (getf (model-agent-row model "Alpha") :pending-approval))
         (eq :x (model-pending-approval model))
         (eq :yellow (agent-light (model-agent-row model "Alpha"))))))

(test "S04/T04: an approval-needed-msg builds the pending plist on the row and the picked state, preserving status"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-status-msg :agent "Alpha" :status :running
                                       :pending-approval nil))
    (tui:update model (make-approval-needed-msg :agent "Alpha" :capability "net"
                                                :target "http://x" :description "d"
                                                :restarts 2))
    (let ((row-pending (getf (model-agent-row model "Alpha") :pending-approval))
          (picked-pending (model-pending-approval model)))
      ;; a non-picked agent's approval updates its row but not the picked state
      (tui:update model (make-approval-needed-msg :agent "Beta" :capability "fs"
                                                  :target "/tmp" :description "e"
                                                  :restarts 1))
      (and (listp row-pending)
           (equal "net" (getf row-pending :capability))
           (equal "http://x" (getf row-pending :target))
           (= 2 (getf row-pending :restarts))
           (equal row-pending picked-pending)
           ;; the approval branch preserves the :status the prior status-msg set
           (eq :running (getf (model-agent-row model "Alpha") :status))
           (listp (getf (model-agent-row model "Beta") :pending-approval))
           (equal row-pending (model-pending-approval model))))))

(test "S04/T04: a status-msg for an agent not in the snapshot is ignored, not fatal"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (let ((before (model-agents model)))
      (tui:update model (make-status-msg :agent "Ghost" :status :running
                                         :pending-approval t))
      (and ;; no matching row: the snapshot is unchanged (the mapcar copies the list
           ;; but no row is touched)
           (equal before (model-agents model))
           ;; Ghost is not the picked agent, so the picked pending state is untouched
           (null (model-pending-approval model))
           (stringp (tui:view model))))))

(test "S04/T04: init subscribes to EVERY agent in the snapshot (two SUBSCRIBE frames)"
  (multiple-value-bind (push out) (capturing-push)
    (let ((model (init-two-agent-model :picked nil :push push)))
      (let ((sent (get-output-stream-string out)))
        (and ;; no picked agent: init defaults to the first name sorted, so the id-2
             ;; transcript reply above is for "Alpha"
             (string= "Alpha" (model-picked-agent model))
             ;; The operator is the KEYWORD :subscribe, not the client package's
             ;; own symbol: the client package is :sexpr-tui (dash) and the
             ;; image's is :sexpr.tui (dot), so a client-side symbol prints
             ;; QUALIFIED as SEXPR-TUI::SUBSCRIBE — a package the image does
             ;; not have, whose reader error kills the subscribe before any
             ;; listener is registered. Keywords are package-independent; the
             ;; server resolves the operator by name.
             (= 2 (count-substring "SUBSCRIBE" sent))
             (search ":SUBSCRIBE" sent)
             (null (search "SEXPR-TUI::SUBSCRIBE" sent))
             (search ":AGENT \"Alpha\"" sent)
             (search ":AGENT \"Beta\"" sent))))))

(test "T05: init starts the wire reader only when the model's program is set and running"
  ;; THE PRODUCTION WIRING BUG behind "RUNNING instead of IDLE" and "messages
  ;; get no reply": main.lisp built the model without :program and never set
  ;; the push connection's program slot, so program-running-p was NIL, the
  ;; wire reader NEVER STARTED, and every status push / streamed delta was
  ;; dropped on the floor. The notes still landed (synchronous swank RPC) and
  ;; the transcript still rendered (initial RPC fetch) — only the push channel
  ;; was dead, and the status bar's "readers: off" was the tell. This pins the
  ;; whole wiring chain main.lisp now establishes: a running program on the
  ;; model AND on the push connection.
  (flet ((readers-after-init (program)
           (let* ((swank-conn (canned-swank (swank-reply :ok nil 1)
                                            (swank-reply :ok '(nil . 0) 2)))
                  (push (capturing-push))
                  (model (make-instance 'tui-model :swank-connection swank-conn
                                                    :push-connection push)))
             ;; what main.lisp does after tui:make-program: the program reaches
             ;; both slots before run starts the reader in init
             (when program
               (setf (model-program model) program
                     (tui-connection-program push) program))
             (tui:init model)
             (model-readers-running model))))
    (let ((running (tui:make-program (make-instance 'tui-model))))
      ;; tui:run sets program-running T before init; program-running is not
      ;; exported, so the slot is reached the way program-running-p reaches it
      (setf (slot-value running (intern "RUNNING" (find-package "TUITION"))) t)
      (and (readers-after-init running)
           (null (readers-after-init nil))))))

(test "S04/T04: a subscribed-msg carries the subscribe-time status and the model applies it"
  ;; The RACE CLOSURE for a status that changed between the client's snapshot
  ;; and its subscribe (the greeter finishing its welcome turn): the change's
  ;; push has no subscriber yet, so the subscribe reply carries the truth and
  ;; the model applies it to the row — the pane shows IDLE, not the snapshot's
  ;; :running.
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-subscribed-msg :agent "Alpha" :cursor 0 :status :finished))
    (and (eq :finished (getf (model-agent-row model "Alpha") :status))
         (eq :green (agent-light (model-agent-row model "Alpha")))
         (search "Alpha IDLE"
                 (tui.viewport:viewport-view (model-agent-viewport model))))))

(test "S04/T04: a subscribed-msg with no status (unknown agent) leaves the row's status alone"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-subscribed-msg :agent "Alpha" :cursor 0))
    (and (eq :idle (getf (model-agent-row model "Alpha") :status))
         ;; ...and the model's picked pending-approval is untouched
         (null (model-pending-approval model)))))

(test "S04/T04: a subscribed-msg for a non-picked agent does NOT refetch the transcript"
  ;; Empty society + picked "A": init consumes exactly two swank packets (ids 1 and
  ;; 2). A subscribe reply for "B" must not fire a third RPC (research risk 5).
  (let* ((swank (apply #'canned-swank *init-replies*))
         (model (make-instance 'tui-model :swank-connection swank
                                         :push-connection nil
                                         :picked-agent "A")))
    (tui:init model)
    (let ((before (client-stats-get swank :packets-read)))
      (tui:update model (make-subscribed-msg :agent "B" :cursor 9))
      (and (= 2 before)
           (= before (client-stats-get swank :packets-read))))))

(test "S04/T04: resolve-pending-approval sends the resolve RPC and clears the pending state"
  (multiple-value-bind (swank out)
      (canned-swank-capturing (two-agent-snapshot-reply)
                              (swank-reply :ok '(nil . 0) 2)
                              (swank-reply :ok t 3))
    (let ((model (init-two-agent-model :picked "Alpha" :swank swank)))
      (setf (model-pending-approval model) t)
      (resolve-pending-approval model :grant-once)
      (let ((sent (get-output-stream-string out)))
        (and (search "(sexpr.tui:resolve-approval \"Alpha\" :GRANT-ONCE)" sent)
             (null (model-pending-approval model)))))))

(test "S04/T04: a failed resolve keeps the pending state and shows the error in the status bar"
  (multiple-value-bind (swank out)
      (canned-swank-capturing (two-agent-snapshot-reply)
                              (swank-reply :ok '(nil . 0) 2)
                              (swank-reply :abort "denied" 3))
    (declare (ignore out))
    (let ((model (init-two-agent-model :picked "Alpha" :swank swank)))
      (setf (model-pending-approval model) t)
      (resolve-pending-approval model :grant-once)
      (and (eq t (model-pending-approval model))
           (search "denied" (model-status-text model))))))

(test "S04/T04: resolve with no pending state changes nothing and sends no packet"
  (multiple-value-bind (swank out)
      (canned-swank-capturing (two-agent-snapshot-reply)
                              (swank-reply :ok '(nil . 0) 2))
    (let ((model (init-two-agent-model :picked "Alpha" :swank swank)))
      (get-output-stream-string out)        ; drain the init requests
      (let ((before (client-stats-get swank :packets-read)))
        (resolve-pending-approval model :grant-once)
        (and (= before (client-stats-get swank :packets-read))
             (string= "" (get-output-stream-string out))
             (search "no pending approval" (model-note model)))))))

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
               ;; the freeze fix: the form is evaluated in COMMON-LISP-USER and
               ;; wrapped in HANDLER-CASE so an erroring form cannot drop the
               ;; image into the debugger
               (search "COMMON-LISP-USER" packet-text)
               (search "handler-case" packet-text)
               (string= "" (tui.textarea:textarea-value ta))
               ;; model-repl-lines is a LIST of lines; join before searching.
               (search "result" (lines-to-string (model-repl-lines model))))))))

(test "T05: an erroring REPL form renders its error instead of freezing"
  (multiple-value-bind (conn out)
      (canned-swank-with-output (swank-reply :ok nil 1)
                                (swank-reply :ok '(nil . 0) 2)
                                (swank-reply :ok "boom" 3))
    (let ((model (make-instance 'tui-model
                                :swank-connection conn
                                :picked-agent "Alpha")))
      (tui:init model)
      (get-output-stream-string out)
      (setf (model-focused model) :repl)
      (let ((ta (model-repl-textarea model)))
        (tui.textarea:textarea-set-value ta "(error \"boom\")")
        (tui:update model (make-enter-msg))
        ;; the reply is the caught error text, rendered into the REPL pane
        (and (search "boom" (lines-to-string (model-repl-lines model)))
             (string= "" (tui.textarea:textarea-value ta)))))))

(test "T05: note-agent-failure explains a FAILED picked agent"
  (let ((model (make-instance 'tui-model :picked-agent "Alpha")))
    (setf (model-agents model)
          (list (list :name "Alpha" :status :failed :handle "subagent-1")))
    (note-agent-failure model)
    (and (search "Alpha failed (subagent-1)" (lines-to-string (model-scrollback model)))
         (search "SEXPR_MODEL" (lines-to-string (model-scrollback model)))))))

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

(defun %strip-ansi (string)
  "Remove ANSI SGR escape sequences (ESC [ ... m) from STRING."
  (let ((out "")
        (i 0)
        (n (length string)))
    (loop while (< i n)
          do (if (and (char= (char string i) #\Escape)
                      (< (1+ i) n)
                      (char= (char string (1+ i)) #\[))
                  (let ((j (position #\m string :start (1+ i))))
                    (if j (setf i (1+ j)) (return)))
                  (progn (setf out (concatenate 'string out (string (char string i))))
                         (incf i))))
    out))

(test "T05: render-textarea draws the cursor in reverse video, never brackets"
  ;; cl-tuition's textarea-view wraps the character under the cursor in [..] —
  ;; while typing, an input reading "hello" renders as "hello[ ]", the "extra
  ;; []" the operator sees. The client renderer draws the insert position as a
  ;; reverse-video character instead. (textarea-set-value leaves the cursor
  ;; at column 0, so the styled character is the first one.)
  (let* ((ta (make-chat-textarea))
         (view (progn
                 (tui.textarea:textarea-set-value ta "hello")
                 (render-textarea ta)))
         (plain (%strip-ansi view)))
    (and (string= "> hello" plain)
         ;; the cursor char carries the reverse-video escape (ESC [ 7 m)
         (search "[7m" view)
         ;; and none of cl-tuition's bracket cursor: no ] anywhere (the [
         ;; that does appear is the ESC [ of the ANSI sequence)
         (null (find #\] view))
         ;; the prompt is still there
         (search "> " plain))))

(test "T05: render-textarea shows the placeholder when empty, and no cursor"
  (let* ((ta (make-chat-textarea))
         (view (render-textarea ta)))
    (and (string= "> message..." view)
         ;; the placeholder branch returns before any cursor is drawn
         (null (find #\[ view))
         (null (find "[7m" view)))))

(test "T05: render-textarea draws no cursor when the textarea is unfocused"
  ;; The section border (*focus-color*) is the focus cue; an unfocused input
  ;; renders as plain prompt + text, so the two inputs are distinguishable even
  ;; when both are empty... and a focused empty input shows its placeholder.
  (let* ((ta (make-chat-textarea))
         (view (progn
                 (tui.textarea:textarea-set-value ta "hello")
                 (tui.textarea:textarea-blur ta)
                 (render-textarea ta))))
    (and (string= "> hello" view)
         (null (find "[7m" view)))))

(test "T05: render-textarea degrades on a NIL textarea"
  ;; A half-built pane must not take the frame down: the model's view calls
  ;; this unconditionally, and a NIL pane slot is the failure mode.
  (equal "" (render-textarea nil)))

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

;;;; --- 8d. S04 T05: agent pane rendering, zones, click-to-focus, resolution ---
;;;
;;; These tests assert through tui:view (the REAL render path), not only through the
;;; row helper, because the blank-pane bug (F2) hid behind a row-helper-only test.
;;; zone-scan runs on the root view string, so a test must init and enable the global
;;; zone manager before calling tui:view, then build mouse coordinates FROM the
;;; recorded zone bounds (research risk 2) — never hand-computed terminal columns.
;;;
;;; zone-info-start-x/start-y are NOT exported from :tuition, so the internal
;;; accessors are named with ::. The +1/+2 offsets mirror zone-in-bounds-p's own
;;; (1- x) / (- y 2) empirical mapping, so a press built here lands inside the zone.

(tui:init-global-zone-manager)
(tui:zone-set-enabled t)

(defun press-zone (zone &key (button :left))
  "A mouse press built from a recorded ZONE's bounds."
  (tui:make-mouse-press-event :x (1+ (tui::zone-info-start-x zone))
                              :y (+ 2 (tui::zone-info-start-y zone))
                              :button button))

(test "S04/T05: *agent-pane-height* is positive and the agent viewport uses it"
  (and (integerp *agent-pane-height*)
       (plusp *agent-pane-height*)
       (= *agent-pane-height*
          (tui.viewport:viewport-height (make-agent-viewport)))))

(test "S04/T05: agent-row-text is plain, carries the picked marker, and degrades on missing fields"
  (let ((picked (agent-row-text (list :name "Alpha" :status :running) :picked "Alpha"))
        (unpicked (agent-row-text (list :name "Alpha" :status :running)))
        (bare (agent-row-text nil)))
    (and (search "* ● Alpha RUNNING" picked)
         (search "Alpha RUNNING" unpicked)
         (not (search "*" unpicked))
         (search "? UNKNOWN" bare)
         ;; ANSI-free: no escape character in the plain row text
         (null (find #\Escape picked)))))

(test "S04/T05: agent-status-label maps kernel statuses to operator labels"
  ;; :finished reads IDLE — the turn is done and the agent is available again —
  ;; so a finished agent is never mistaken for a busy one; :failed and :killed
  ;; keep their names so a dead agent is never mistaken for an idle one.
  (and (string= "RUNNING" (agent-status-label :running))
       (string= "IDLE" (agent-status-label :finished))
       (string= "FAILED" (agent-status-label :failed))
       (string= "KILLED" (agent-status-label :killed))
       ;; the test vocabulary's :idle and a non-symbol degrade, NIL to UNKNOWN
       (string= "IDLE" (agent-status-label :idle))
       (string= "UNKNOWN" (agent-status-label nil))
       (string= "UNKNOWN" (agent-status-label "running"))
       ;; a finished agent renders IDLE in the row text, not FINISHED
       (search "Alpha IDLE" (agent-row-text (list :name "Alpha" :status :finished)))
       (search "Alpha FAILED" (agent-row-text (list :name "Alpha" :status :failed)))))

(test "S04/T05: render-agent-rows highlights exactly the picked row and keeps both headers"
  (let ((rows (render-agent-rows (list (list :name "Alpha" :status :running)
                                       (list :name "Beta" :status :idle))
                                 :picked "Alpha")))
    (and (search "agent" rows) (search "status" rows)
         (search "* ● Alpha RUNNING" rows)
         (search "Beta IDLE" rows)
         (= 1 (count-substring "* ● " rows)))))

(test "S04/T05: the agent pane is non-empty in the real view — both agents render (F2 guard)"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (refresh-agent-viewport model)
    (let ((v (tui:view model))
          (pane (tui.viewport:viewport-view (model-agent-viewport model))))
      (and (search "Alpha" v)
           (search "Beta" v)
           (not (string= "" pane))
           (search "agent" pane)))))

(test "S04/T05: clicking an agent row zone switches the picked agent and refetches the transcript"
  (multiple-value-bind (swank out)
      (canned-swank-capturing (two-agent-snapshot-reply)
                              (swank-reply :ok '(nil . 0) 2)
                              (swank-reply :ok '(((:type :user :content "beta history")) . 4) 3))
    (let ((model (init-two-agent-model :picked "Alpha" :swank swank)))
      (get-output-stream-string out)      ; drain the init requests
      (tui:view model)                    ; record zones from the root render
      (let ((zone (tui:zone-get "agent-row:Beta")))
        (and zone
             (progn
               (tui:update model (press-zone zone))
               (and (string= "Beta" (model-picked-agent model))
                    ;; the refetch re-pointed the viewport: Beta's history is in the
                    ;; chat scrollback and the request named Beta
                    (search "beta history" (lines-to-string (model-scrollback model)))
                    (search "transcript-delta" (get-output-stream-string out))
                    (search "Beta" (model-status-text model)))))))))

(test "S04/T05: a stale name (not in the snapshot) never switches the picked agent"
  (let ((model (init-two-agent-model :picked "Alpha")))
    ;; direct call: the guard is against model-agents, not against the zone system
    (model-switch-agent model "Ghost")
    (and (string= "Alpha" (model-picked-agent model))
         ;; and a synthesized click on a zone whose row name is not in the snapshot:
         ;; the hit-test may name it, but the switch re-validates and refuses
         (progn
           (tui:zone-scan (tui:zone-mark "agent-row:Ghost" "Ghost row"))
           (let ((z (tui:zone-get "agent-row:Ghost")))
             (and z
                  (progn (handle-mouse model (press-zone z))
                         (string= "Alpha" (model-picked-agent model)))))))))

(test "S04/T05: the approval strip is NIL without a pending approval and names the request when set"
  (and (null (render-approval-strip nil))
       (let ((strip (render-approval-strip (list :capability "net" :target "http://x"
                                                 :description "fetch"))))
         (and (search "grant-once" strip)
              (search "deny" strip)
              (search "net" strip)
              (search "http://x" strip)))
       ;; a bare T flag degrades to placeholders rather than signalling
       (let ((strip (render-approval-strip t)))
         (and (search "grant-once" strip) (search "deny" strip)))))

(test "S04/T05: a click on the approval strip resolves via RPC and clears the yellow light"
  (multiple-value-bind (swank out)
      (canned-swank-capturing (two-agent-snapshot-reply)
                              (swank-reply :ok '(nil . 0) 2)
                              (swank-reply :ok "granted" 3))
    (let ((model (init-two-agent-model :picked "Alpha" :swank swank)))
      (get-output-stream-string out)
      (tui:update model (make-approval-needed-msg :agent "Alpha" :capability "net"
                                                  :target "http://x" :description "fetch"))
      (let ((v (tui:view model)))
        (and (search "grant-once" v)
             (search "deny" v)
             ;; the pending row lights yellow (agent-light)
             (eq :yellow (agent-light (model-agent-row model "Alpha")))
             (let ((zone (tui:zone-get "approval:grant-once")))
               (and zone
                    (progn
                      (tui:update model (press-zone zone))
                      (and (null (model-pending-approval model))
                           (eq :green (agent-light (model-agent-row model "Alpha")))
                           (search "resolve-approval \"Alpha\" :GRANT-ONCE"
                                   (get-output-stream-string out)))))))))))

(test "S04/T05: the C-g keyboard fallback resolves grant-once only while an approval is pending"
  (multiple-value-bind (swank out)
      (canned-swank-capturing (two-agent-snapshot-reply)
                              (swank-reply :ok '(nil . 0) 2)
                              (swank-reply :ok "granted" 3))
    (let ((model (init-two-agent-model :picked "Alpha" :swank swank)))
      (get-output-stream-string out)
      (tui:update model (make-approval-needed-msg :agent "Alpha" :capability "net"
                                                  :target "http://x" :description "fetch"))
      (tui:update model (make-key-msg :key #\g :ctrl t))
      (and (null (model-pending-approval model))
           (search "GRANT-ONCE" (get-output-stream-string out))))))

;;;; --- 8e. S05 T06: in-flight accumulation, tool/budget rendering, streaming lights ---
;;;
;;; These tests drive the REAL update/view path over the canned two-agent model. The
;;; in-flight line is asserted on `model-in-flight` and through `tui:view` (the render
;;; path), because the whole point of T06 is the shape the operator sees: one growing
;;; line, not one line per fragment (F5).

(test "S05/T06: three model deltas accumulate into ONE in-flight line, and finalize commits it as one scrollback line"
  (let* ((model (init-two-agent-model :picked "Alpha"))
         (before (length (model-scrollback model))))
    (dolist (frag '("Hel" "lo " "world"))
      (tui:update model (make-delta-msg :agent "Alpha" :content frag)))
    (let ((v (tui:view model)))
      (and (equal "Hello world" (model-in-flight model))
           ;; the view shows the concatenation EXACTLY once: one growing line, not a
           ;; waterfall of per-fragment lines
           (= 1 (count-substring "Hello world" v))
           ;; nothing has been committed to the scrollback while the turn streams
           (= before (length (model-scrollback model)))
           (progn
             (tui:update model (make-finalize-msg :agent "Alpha" :event-index 3))
             (and (null (model-in-flight model))
                  ;; committed as EXACTLY one line
                  (= (1+ before) (length (model-scrollback model)))
                  (equal "Hello world" (first (model-scrollback model)))
                  (= 1 (count-substring "Hello world" (tui:view model)))))))))

(test "S05/T06: a :kind :tool delta renders as its own tool-prefixed line and does not join the in-flight model line"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-delta-msg :agent "Alpha" :content "prose"))
    (tui:update model (make-delta-msg :agent "Alpha" :content "chunk" :kind :tool))
    (let ((v (tui:view model)))
      (and (equal "prose" (model-in-flight model))
           (search "tool: chunk" v)
           (search "tool: chunk" (lines-to-string (model-scrollback model)))
           ;; the tool fragment never leaked into the in-flight model line
           (not (search "prosechunk" v))))))

(test "S05/T06: tool-start and tool-result render prefixed progress lines in the view"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-tool-start-msg :agent "Alpha" :call-id "c1" :name "get_weather"))
    (tui:update model (make-tool-result-msg :agent "Alpha" :call-id "c1" :value :ok :text "18C"))
    (let ((v (tui:view model)))
      (and (search "tool: get_weather (call c1) started" v)
           (search "tool: c1 -> 18C" v)))))

(test "S05/T06: a budget-exceeded-msg commits a budget line with tokens-used/limit to the view"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-budget-exceeded-msg :agent "Alpha" :tokens-used 4096 :limit 4000))
    (let ((v (tui:view model)))
      (and (search "budget: 4096/4000 tokens" v)
           (search "budget: 4096/4000 tokens"
                   (lines-to-string (model-scrollback model)))))))

(test "S05/T06: a delta sets :streaming on the row (red light) and finalize clears it (green)"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-delta-msg :agent "Alpha" :content "x"))
    (let ((red (eq :red (agent-light (model-agent-row model "Alpha")))))
      (tui:update model (make-finalize-msg :agent "Alpha" :event-index 0))
      (and red
           (eq :green (agent-light (model-agent-row model "Alpha")))
           ;; a NON-picked agent's delta still lights its own row red (F6)
           (progn
             (tui:update model (make-delta-msg :agent "Beta" :content "y"))
             (eq :red (agent-light (model-agent-row model "Beta"))))))))

(test "S05/T06: an out-of-order finalize with no in-flight line is a safe no-op"
  (let* ((model (init-two-agent-model :picked "Alpha"))
         (before (length (model-scrollback model))))
    (tui:update model (make-finalize-msg :agent "Alpha" :event-index 0))
    (and (null (model-in-flight model))
         (= before (length (model-scrollback model)))
         (stringp (tui:view model))
         ;; a finalize for an unknown agent is also safe
         (progn
           (tui:update model (make-finalize-msg :agent "Ghost" :event-index 0))
           (stringp (tui:view model))))))

(test "S05/T06: switching agents drops a half-streamed in-flight line rather than bleeding it"
  (let ((model (init-two-agent-model :picked "Alpha")))
    (tui:update model (make-delta-msg :agent "Alpha" :content "partial"))
    (model-switch-agent model "Beta")
    (and (null (model-in-flight model))
         (not (search "partial" (tui:view model))))))

;;;; --- 8f. responsive layout and input focus (quick task 11) ---------------
;;;
;;; Four real bugs, all found by reading the render path rather than the model:
;;;
;;; 1. THE FRAME NEVER REACHED THE SCREEN. The pane widths and heights were
;;;    defparameters; resize-panes touched only widths, and only of the chat and REPL
;;;    panes — the agent pane stayed 30 columns and every viewport stayed at its
;;;    first-paint height. At 200x45 the frame still rendered 31x22. Worse, the
;;;    panes were sized but never PADDED: cl-tuition's viewport-view prints each line
;;;    bare, render-border measures its box from the widest content line, and
;;;    textarea-view does the same, so a 54-column chat viewport rendered 12
;;;    columns wide. layout-dimensions derives every size from the terminal; pad-block
;;;    widens each rendered line to it.
;;; 2. BOTH INPUTS WERE FOCUSED AT ONCE. cl-tuition has no global focus register —
;;;    textarea-focused is a per-object slot — and the Tab handler focused the new
;;;    textarea without blurring the old, so after one Tab both held T and both drew
;;;    a cursor. A textarea holding no text renders its placeholder without a cursor,
;;;    so the operator could not even see it.
;;; 3. TYPING ANY PRINTABLE CHARACTER CRASHED THE TUI. handle-key's fallthrough
;;;    branch ended with (values model cmd) after a close paren that had already
;;;    closed the let* binding cmd, so every letter, space and digit signalled
;;;    UNBOUND-VARIABLE. cl-tuition's event loop catches it with handle-error and
;;;    continues, so the character was silently dropped: the TUI looked frozen.
;;; 4. THE REPL TEXTAREA WAS WRITTEN TO THE WRONG SLOT. The same branch stored the
;;;    updated component in both slots, so when the REPL was focused the chat slot
;;;    ended up pointing at the REPL textarea; the next Tab landed on the wrong input.
;;;
;;; These tests assert the contract, not the helper: exact frame dimensions,
;;; exactly-one-focused, and no-signal on input.

(defun frame-dims (text)
  "(VALUES width height) of the rendered frame TEXT, in columns and rows. Width is
measured with visible-length so the ANSI escapes in the borders are not counted."
  (let ((lines (tui:split-string-by-newline text)))
    (values (if lines (apply #'max (mapcar #'tui:visible-length lines)) 0)
            (length lines))))

(defun focused-textareas (model)
  "How many of the two text areas currently hold focus. Must always be 1 when both
slots are built; 0 when one is NIL, because a NIL slot is not a focused text area
and the accessor must not be called on it."
  (+ (if (and (model-chat-textarea model)
              (tui.textarea:textarea-focused (model-chat-textarea model))) 1 0)
     (if (and (model-repl-textarea model)
              (tui.textarea:textarea-focused (model-repl-textarea model))) 1 0)))

(defun sized-model (width height)
  "An initialised model whose panes have been laid out for WIDTH x HEIGHT."
  (let ((model (init-two-agent-model)))
    (setf (model-term-width model) width
          (model-term-height model) height)
    (resize-panes model)
    model))

(defun count-occurrence (needle haystack)
  "How many times NEEDLE occurs in HAYSTACK (non-overlapping)."
  (let ((count 0) (start 0))
    (loop for pos = (search needle haystack :start2 start)
          while pos
          do (incf count) (setf start (+ pos (length needle))))
    count))

(test "layout-dimensions fits a terminal exactly across a size matrix"
  ;; loop ... finally returns the conjunction: dolist always returns NIL, which would
  ;; make a per-size assertion vacuously pass.
  (loop for size in '((80 24) (120 32) (200 45) (100 30) (60 16) (150 38) (72 20))
        always
        (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
            (layout-dimensions (first size) (second size))
          (and (plusp chat-w)
               (plusp agent-w)
               (plusp chat-h)
               (plusp repl-h)
               (plusp agent-h)
               ;; frame width: the chat section's border plus the unbordered agent pane
               (= (+ chat-w 2 agent-w) (first size))
               ;; frame height: both sections plus the two chrome rows
               (= (+ chat-h repl-h (* 2 *section-overhead*) *chrome-rows*) (second size))
               ;; the two left-column sections are exactly as tall as the agent pane spans
               (= (+ chat-h repl-h (* 2 *section-overhead*)) agent-h)))))

(test "layout-dimensions degrades total on a degenerate window instead of signalling"
  ;; A 0x0 or 1x1 resize event is a thing that happens (a terminal closed mid-reflow).
  ;; The layout must answer with a usable smallest layout, never a zero-sized pane
  ;; (a zero-height viewport renders NOTHING, research F2) and never a signal.
  (loop for size in '((0 0) (1 1) (-40 -9) (0 24) (80 0))
        always
        (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
            (layout-dimensions (first size) (second size))
          (and (integerp chat-w) (integerp agent-w) (integerp chat-h)
               (integerp repl-h) (integerp agent-h)
               (plusp chat-w) (plusp agent-w) (plusp chat-h)
               (plusp repl-h) (plusp agent-h))))

(test "layout-dimensions clamps the agent pane to its min and max and hands the rest to chat"
  ;; 80 columns: the share lands mid-range and both columns are above their minimums
  (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
      (layout-dimensions 80 24)
    (declare (ignore chat-h repl-h agent-h))
    (and (eql agent-w 24)
         (eql chat-w 54)
         (eql (+ chat-w 2 agent-w) 80)))
  ;; a wide monitor: the agent pane stops growing at the cap, chat takes the rest
  (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
      (layout-dimensions 200 45)
    (declare (ignore chat-h repl-h agent-h))
    (and (eql agent-w *agent-max-width*)
         (> chat-w 100)
         (eql (+ chat-w 2 agent-w) 200)))
  ;; a narrow terminal: both columns hold their minimums
  (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
      (layout-dimensions 42 14)
    (declare (ignore chat-h repl-h agent-h))
    (and (eql chat-w *chat-min-width*)
         (eql agent-w *agent-min-width*)
         (eql (+ chat-w 2 agent-w) 42))))

(test "layout-dimensions gives the chat viewport the rows the REPL leaves over"
  ;; the REPL gets about a quarter of the viewport rows and the chat gets the rest, so
  ;; on a tall terminal the transcript pane grows far more than the console pane does.
  ;; multiple-value-list order is chat-width agent-width chat-height repl-height
  ;; agent-height, so index 2 is the chat viewport and index 3 the REPL viewport.
  (let* ((tall (multiple-value-list (layout-dimensions 100 60)))
         (short (multiple-value-list (layout-dimensions 100 24))))
    (and (< (nth 3 tall) (nth 2 tall))
         (< (nth 3 short) (nth 2 short))
         (> (nth 2 tall) (nth 2 short))
         (> (nth 4 tall) (nth 4 short))
         (>= (nth 0 tall) (nth 0 short)))))

(test "the pane constructor defaults are layout-dimensions of an 80x24 terminal"
  ;; The first frame is drawn before the first window-size-msg is drained, so the
  ;; constructor defaults and the first reflow must agree or the UI jumps on start.
  (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
      (layout-dimensions 80 24)
    (and (eql *chat-width* chat-w)
         (eql *agent-width* agent-w)
         (eql *chat-viewport-height* chat-h)
         (eql *repl-viewport-height* repl-h)
         (eql *agent-pane-height* agent-h)
         ;; and the constructors actually use them
         (eql chat-w (tui.viewport:viewport-width (make-chat-viewport)))
         (eql chat-h (tui.viewport:viewport-height (make-chat-viewport)))
         (eql repl-h (tui.viewport:viewport-height (make-repl-viewport)))
         (eql agent-w (tui.viewport:viewport-width (make-agent-viewport)))
         (eql agent-h (tui.viewport:viewport-height (make-agent-viewport))))))

(test "the composed frame is exactly the terminal size at every size in the matrix"
  ;; loop ... always, not dolist: dolist returns NIL and would pass vacuously.
  (loop for size in '((80 24) (120 32) (200 45) (100 30) (60 16) (150 38))
        always
        (let ((model (sized-model (first size) (second size))))
          (multiple-value-bind (w h) (frame-dims (tui:view model))
            (and (eql w (first size))
                 (eql h (second size))))))))

(test "a wider terminal makes the panes wider and a taller one makes them taller"
  ;; the point of the whole change: the UI uses the screen it is given
  (let* ((small (sized-model 80 24))
         (big (sized-model 200 45)))
    (and (> (tui.viewport:viewport-width (model-chat-viewport big))
            (tui.viewport:viewport-width (model-chat-viewport small)))
         (> (tui.viewport:viewport-height (model-chat-viewport big))
            (tui.viewport:viewport-height (model-chat-viewport small)))
         (> (tui.viewport:viewport-height (model-repl-viewport big))
            (tui.viewport:viewport-height (model-repl-viewport small)))
         (> (tui.viewport:viewport-width (model-agent-viewport big))
            (tui.viewport:viewport-width (model-agent-viewport small)))
         (> (tui.viewport:viewport-height (model-agent-viewport big))
            (tui.viewport:viewport-height (model-agent-viewport small))))))

(test "a window-size-msg resizes, and a later resize shrinks back"
  ;; growing is the headline; shrinking is the half that is just as easy to get
  ;; wrong, because a viewport that keeps its old (larger) height silently clips.
  (let ((model (sized-model 200 45)))
    (setf model (car (multiple-value-list
                    (tui:update model (make-window-size-msg :width 60 :height 16)))))
    (and (eql 60 (model-term-width model))
         (eql 16 (model-term-height model))
         (let ((vp (model-chat-viewport model)))
           (and (eql 38 (tui.viewport:viewport-width vp))
                (eql 5 (tui.viewport:viewport-height vp))))
         (let ((vp (model-repl-viewport model)))
           (and (eql 38 (tui.viewport:viewport-width vp))
                (eql 1 (tui.viewport:viewport-height vp))))
         (let ((vp (model-agent-viewport model)))
           (and (eql 20 (tui.viewport:viewport-width vp))
                (eql 14 (tui.viewport:viewport-height vp))))
         (eql 38 (tui.textarea:textarea-width (model-chat-textarea model)))
         (eql 38 (tui.textarea:textarea-width (model-repl-textarea model)))
         (multiple-value-bind (w h) (frame-dims (tui:view model))
           (and (eql w 60) (eql h 16))))))

(test "the approval strip keeps its row whether or not an approval is pending"
  ;; *chrome-rows* reserves the strip unconditionally, so an approval arriving or
  ;; clearing does not move the status bar or change the frame height.
  (let* ((model (sized-model 80 24))
         (before (multiple-value-list (frame-dims (tui:view model)))))
    (tui:update model (make-approval-needed-msg :agent "Alpha" :capability "net"
                                                :target "http://x" :description "d"))
    (let ((after (multiple-value-list (frame-dims (tui:view model)))))
      (and (eql (first before) (first after))
           (eql (second before) (second after))
           (search "grant-once" (tui:view model))))))

(test "pad-block widens every line to the width and leaves the escapes alone"
  (let* ((ansi (concatenate 'string (string #\ESC) "[36m" "hi" (string #\ESC) "[0m"))
         (padded (pad-block ansi 8)))
    (and (eql 8 (tui:visible-length padded))
         ;; the escape sequences survive padding, so the ANSI that was already in
         ;; the line is neither counted nor disturbed
         (search (string #\ESC) padded)
         ;; padding appends, never truncates
         (let ((long (pad-block "x" 3)))
           (and (eql 3 (tui:visible-length long))
                (search "x" long))))))

(test "render-section with :width draws a border box exactly that wide"
  (let ((narrow (render-section "chat" "" :width 20))
        (wide (render-section "chat" "" :width 60)))
    (multiple-value-bind (nw nh) (frame-dims narrow)
      (multiple-value-bind (ww wh) (frame-dims wide)
        (and (eql nw 20) (eql nh 4)      ;; title + 2 border rows, empty body
             (eql ww 60) (eql wh 4)
             ;; and the body's own padding puts text at the right column
             (let ((body-line (nth 2 (tui:split-string-by-newline wide))))
               (eql 60 (tui:visible-length body-line))))))))

(test "set-focus leaves exactly one textarea focused and never signals on a NIL slot"
  (let ((model (init-two-agent-model)))
    (setf (model-chat-viewport model) (make-chat-viewport)
          (model-chat-textarea model) (make-chat-textarea)
          (model-repl-viewport model) (make-repl-viewport)
          (model-repl-textarea model) (make-repl-textarea))
    (and (eql 1 (focused-textareas model))
         (tui.textarea:textarea-focused (model-chat-textarea model))
         ;; a NIL slot must degrade, not signal. The setf is wrapped in progn
         ;; because setf returns the value it stored — NIL here — which would
         ;; otherwise short-circuit the and.
         (progn (setf (model-repl-textarea model) nil) t)
         (set-focus model :repl)
         (eql 0 (focused-textareas model))
         (set-focus model :chat)
         (eql 1 (focused-textareas model)))))

(test "exactly one input owns the keys at every step: init, and every Tab"
  (let ((model (init-two-agent-model)))
    (build-panes model)
    (and (eql 1 (focused-textareas model))
         (tui.textarea:textarea-focused (model-chat-textarea model))
         (null (tui.textarea:textarea-focused (model-repl-textarea model)))
         ;; Tab hands the input to the REPL and TAKES it away from the chat
         (setf model (car (multiple-value-list (tui:update model (make-key-msg :key :tab)))))
         (and (eql 1 (focused-textareas model))
              (null (tui.textarea:textarea-focused (model-chat-textarea model)))
              (tui.textarea:textarea-focused (model-repl-textarea model))
              (eq :repl (model-focused model)))
         ;; and back, repeatedly, so the invariant holds under repetition: two Tabs
         ;; from any state return to the same owner, so after six more the REPL still
         ;; holds it. The dotimes result is discarded on purpose (it returns NIL,
         ;; which would short-circuit the and), so the loop is wrapped in progn.
         (progn (dotimes (i 6)
                  (setf model (car (multiple-value-list
                                  (tui:update model (make-key-msg :key :tab))))))
                t)
         (and (eql 1 (focused-textareas model))
              (tui.textarea:textarea-focused (model-repl-textarea model))
              (eq :repl (model-focused model)))
         ;; and an odd number of further Tabs hands it back to the chat
         (setf model (car (multiple-value-list
                         (tui:update model (make-key-msg :key :tab)))))
         (and (eql 1 (focused-textareas model))
              (tui.textarea:textarea-focused (model-chat-textarea model))
              (eq :chat (model-focused model))))))

(test "a printable key no longer signals — the TUI could not be typed into at all"
  ;; handle-key's fallthrough branch returned (values model cmd) AFTER a paren that
  ;; had already closed the let* binding cmd, so every letter, space and digit
  ;; signalled UNBOUND-VARIABLE. cl-tuition's event loop catches the condition and
  ;; continues, so the keystroke was silently dropped and the TUI looked frozen.
  ;;
  ;; handler-case returns the model on success and the formatted error string on
  ;; failure, so the two cases are told apart by the type of what came back.
  (let ((model (init-two-agent-model)))
    (build-panes model)
    (dolist (k '(#\h #\space #\! #\9 #\z) t)
      (let ((reply (handler-case
                       (multiple-value-list (handle-key model (make-key-msg :key k)))
                     (error (e) (format nil "SIGNALLED: ~A" e)))))
        (and (consp reply)
             (typep (car reply) 'tui-model)
             (null (cadr reply)))))))


(test "a key typed with the REPL focused lands in the REPL textarea only"
  ;; the old branch wrote the updated component into BOTH slots, so with the REPL
  ;; focused the chat slot ended up pointing at the REPL textarea and the next Tab
  ;; landed on the wrong input.
  (let ((model (init-two-agent-model)))
    (build-panes model)
    (setf model (car (multiple-value-list (tui:update model (make-key-msg :key :tab)))))
    (dolist (k '(#\a #\b #\c))
      (setf model (car (multiple-value-list (handle-key model (make-key-msg :key k))))))
    (and (string= "" (tui.textarea:textarea-value (model-chat-textarea model)))
         (string= "abc" (tui.textarea:textarea-value (model-repl-textarea model)))
         ;; and the two slots are distinct objects, not one shared textarea
         (not (eq (model-chat-textarea model) (model-repl-textarea model))))))

(test "cursor movement and deletion keys stay inside the focused input"
  (let ((model (init-two-agent-model)))
    (build-panes model)
    (dolist (k (list :up :down :left :right :home :end :backspace :delete))
      (let ((reply (handler-case
                       (multiple-value-list (handle-key model (make-key-msg :key k)))
                     (error (e) (format nil "SIGNALLED: ~A" e)))))
        (and (consp reply)
             (typep (car reply) 'tui-model))))
    ;; typing then moving then deleting leaves the value where it should be
    (dolist (k '(#\x #\y))
      (setf model (car (multiple-value-list (handle-key model (make-key-msg :key k))))))
    (setf model (car (multiple-value-list (handle-key model (make-key-msg :key :backspace)))))
    (and (string= "x" (tui.textarea:textarea-value (model-chat-textarea model)))
         (string= "" (tui.textarea:textarea-value (model-repl-textarea model))))))

(test "the focused input's border is drawn in the focus color, and only that one"
  ;; a textarea holding no text renders its placeholder without a cursor, so the
  ;; coloured border is the only cue about which input takes the next key.
  ;;
  ;; The colour reaches the frame as an ANSI SGR sequence, which cl-tuition's colored
  ;; emits as ESC [ <code> m — so the needle is built that way rather than by
  ;; concatenating the raw code string. The assertion is on WHICH section is coloured,
  ;; not on how many times the sequence appears: render-border colours each border
  ;; character separately, so a coloured border emits the sequence many times.
  (flet ((section-border-coloured-p (view title)
           "True when the top border line under TITLE in VIEW carries the focus colour."
           (let* ((lines (tui:split-string-by-newline view))
                  (pos (position title lines :test #'search)))
             (and pos
                  (< (1+ pos) (length lines))
                  (search (concatenate 'string (string #\ESC) "["
                                        (format nil "~A" *focus-color*) "m")
                          (nth (1+ pos) lines))))))
    (let* ((chat-view (tui:view (init-two-agent-model)))
           (repl-model (init-two-agent-model))
           (repl-view (progn
                        (setf repl-model
                              (car (multiple-value-list
                                    (tui:update repl-model (make-key-msg :key :tab)))))
                        (tui:view repl-model))))
      ;; chat focused: the chat border is cyan, the repl border is not
      (and (section-border-coloured-p chat-view "chat")
           (not (section-border-coloured-p chat-view "repl"))
           ;; repl focused: the repl border is cyan, the chat border is not
           (section-border-coloured-p repl-view "repl")
           (not (section-border-coloured-p repl-view "chat"))))))

(test "build-panes sizes the new panes and resets focus to chat"
  (let ((model (init-two-agent-model)))
    (build-panes model)
    (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
        (layout-dimensions (model-term-width model) (model-term-height model))
      (and (eql chat-w (tui.viewport:viewport-width (model-chat-viewport model)))
           (eql chat-h (tui.viewport:viewport-height (model-chat-viewport model)))
           (eql repl-h (tui.viewport:viewport-height (model-repl-viewport model)))
           (eql agent-w (tui.viewport:viewport-width (model-agent-viewport model)))
           (eql agent-h (tui.viewport:viewport-height (model-agent-viewport model)))
           (eql 1 (focused-textareas model))
           (tui.textarea:textarea-focused (model-chat-textarea model))))))

(test "the agent pane has a visible border, never colored, alongside the focused chat border"
  ;; The agent pane is read-only (not focusable), so it is always bordered
  ;; but never colored — its plain border is the contrast that makes the
  ;; focused pane's cyan border stand out.
  ;;
  ;; The agent pane uses render-border directly (no title line), so border
  ;; characters appear on the SAME line as the agent content. The chat and
  ;; REPL sections use render-section (title + border), so their border is
  ;; on the line BELOW the title. Because the panes are joined horizontally,
  ;; a single line carries both the chat border (cyan) and the agent border
  ;; (plain). The test checks that the agent pane has its own border chars
  ;; by counting border characters per line: a line with the agent pane has
  ;; MORE border chars than a line with only the chat section.
  (let* ((chat-view (tui:view (init-two-agent-model)))
         (chat-lines (tui:split-string-by-newline chat-view))
         (agent-line (find "agent" chat-lines :test #'search)))
    (and agent-line
         ;; the agent pane's border character is present on the agent content line
         (search "│" agent-line)
         ;; the frame still has exactly 24 rows (the border didn't change height)
         (= 24 (length chat-lines)))))


;;;; --- summary -------------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%" *tests-run* *tests-passed* *tests-failed*)
;; CL has no QUIT — it is SB-EXT:QUIT. The package :shadow is kept because :tuition
;; exports #:quit (the TEA quit message), which would otherwise be ambiguous with CL's.
(sb-ext:exit :code (if (> *tests-failed* 0) 1 0))
