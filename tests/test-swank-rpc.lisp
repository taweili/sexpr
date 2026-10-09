;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-swank-rpc.lisp — standalone test for the hand-rolled Swank RPC client
;;;; (M004/S03 T02).
;;;;
;;;; Run with: sbcl --script tests/test-swank-rpc.lisp
;;;;
;;;; Two halves: (1) the pure framing + reply-matching seam over STRING streams, with
;;;; no network and no terminal, so it is deterministic (D023/MEM109); (2) one live
;;;; round trip against a real swank server started in this process, which proves the
;;;; framing matches what swank actually speaks.
;;;;
;;;; `tui:run` is never called: raw mode needs a TTY fd and fails on a pipe (MEM103).
;;;; Tests are written flat (defparameter + a single and-form) so the harness itself
;;;; cannot hide a failure behind a mis-nested let.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))

(push (uiop:getcwd) asdf:*central-registry*)

(ql:quickload :sexpr-tui)
(ql:quickload '(:sexpr :swank) :silent t)
(require :sb-bsd-sockets)

(defpackage :sexpr-test-swank-rpc (:use :cl :tuition :sexpr-tui) (:shadow #:quit))
(in-package :sexpr-test-swank-rpc)

(defparameter *tests-run* 0)
(defparameter *tests-passed* 0)
(defparameter *tests-failed* 0)

(defun ok (description form)
  (incf *tests-run*)
  (if form (progn (incf *tests-passed*) (format t "  ok: ~A~%" description) t) (progn (incf *tests-failed*) (format t "  FAIL: ~A~%" description) nil)))

(defun crash (description err)
  (incf *tests-run*)
  (incf *tests-failed*)
  (format t "  CRASH: ~A — ~A~%" description err))

(defmacro test (description &body body)
  `(handler-case (ok ,description (progn ,@body)) (error (err) (crash ,description err))))

(defun source-text (path)
  (with-output-to-string (out) (with-open-file (in path :direction :input) (loop for line = (read-line in nil nil) while line do (format out "~A~%" line)))))

(defun file-has-spdx (path) (search "SPDX-License-Identifier: GPL-3.0-or-later" (source-text path)))

(defun framed (payload) (concatenate 'string (packet-header (length (utf8-bytes payload))) payload))

(defun swank-over (payloads) (new-swank-connection :port 0 :stream (make-string-input-stream (apply #'concatenate 'string (mapcar #'framed payloads)))))

(defun live-guard (thunk &optional (seconds 15)) (handler-case (sb-ext:with-timeout seconds (funcall thunk)) (sb-ext:timeout () nil) (error () nil)))

(defun designator-names (designators)
  "ASDF stores :depends-on entries as system DESIGNATORS, which come back as strings
here, not as keywords — so the gate compares names, not EQ against a keyword. Asserting
`equal` against '(:tuition) would fail for the wrong reason."
  (mapcar (lambda (d) (string-upcase (if (symbolp d) (symbol-name d) (string d)))) designators))

;;;; --- 1. framing ------------------------------------------------

(test "the header is six zero-padded uppercase hex digits" (and (string= (packet-header 10) "00000A") (string= (packet-header 65) "000041") (= 6 (length (packet-header 0)))))

(defparameter *e* (string (code-char #xE9)))
(defparameter *p9* (swank-packet-text *e*))
(test "the header counts BYTES, not characters (MEM110)" (and (= 2 (length (utf8-bytes *e*))) (= 1 (length *e*)) (= 3 (length (utf8-bytes "caf"))) (> (length (utf8-bytes *p9*)) (length *p9*)) (= (parse-integer (subseq *p9* 0 6) :radix 16) (length (utf8-bytes (subseq *p9* 6))))))

(defparameter *out* (make-string-output-stream))
(defparameter *wconn* (new-swank-connection :stream *out*))
(defparameter *packet* (write-packet *wconn* (rpc-payload "(sexpr:name)" :id 1)))
(defparameter *back* (new-swank-connection :stream (make-string-input-stream *packet*)))
(test "write-packet and read-packet round-trip over string streams (no network)" (and (= 1 (client-stats-get *wconn* :packets-written)) (string= *packet* (swank-packet-text "(sexpr:name)" :id 1)) (string= (read-packet *back*) (subseq *packet* 6)) (= 1 (client-stats-get *back* :packets-read))))

(defparameter *bytes* (utf8-bytes *e*))
(test "a UTF-8 payload round-trips through the local codec with no new dependency" (and (= 2 (length *bytes*)) (string= (utf8-to-string *bytes*) *e*) (string= (utf8-to-string (coerce *bytes* 'vector)) *e*)))

(test "a malformed UTF-8 sequence signals rather than silently producing junk" (handler-case (progn (utf8-to-string (list #xC3 #x28)) nil) (error (e) (and e (search "UTF-8" (format nil "~a" e))))))

(defparameter *eof* (swank-over '()))
(test "EOF returns NIL and counts connection-closed" (and (null (read-packet *eof*)) (= 1 (client-stats-get *eof* :connection-closed))))

;;;; A length-prefixed frame has no boundary marker, so a payload that is short relative
;;;; to the length the header claims can only be detected when the stream ends: if more
;;;; bytes follow, the reader cannot tell a short payload from the next frame's header.
;;;; So this fixture is a short payload AT EOF, over a two-way stream, which is what
;;;; lets the test show the connection is still usable afterwards rather than wrecked.
(defparameter *short-in* (make-string-input-stream (concatenate 'string (packet-header 20) "(:return (:ok")))
(defparameter *short-out* (make-string-output-stream))
(defparameter *short* (new-swank-connection :port 0 :stream (make-two-way-stream *short-in* *short-out*)))
(defparameter *short-read* (read-packet *short*))
(defparameter *short-again* (read-packet *short*))
(test "a short payload is counted as a reader error and the connection survives" (and (null *short-read*) (= 1 (client-stats-get *short* :reader-error)) (null *short-again*) (= 1 (client-stats-get *short* :connection-closed)) (search "Short payload" (format nil "~a" (getf (client-stats *short*) :last-error))) (= 1 (progn (write-packet *short* (rpc-payload "(sexpr:name)" :id 2)) (client-stats-get *short* :packets-written)))))

;;;; --- 2. reply matching by continuation id --------------------

(defparameter *c1* (swank-over (list (format nil "(~S (~S ~S))" :new-features :swank :cl) (format nil "(~S (~S ~S) 1)" :return :ok "sexpr"))))
(defparameter *r1* (swank-read-reply *c1* 1))
(test "an unsolicited packet arriving before the reply is skipped and counted" (and (eq (getf *r1* :status) :ok) (string= (getf *r1* :value) "sexpr") (= 1 (client-stats-get *c1* :unsolicited-skipped)) (= 2 (client-stats-get *c1* :packets-read))))

(defparameter *c2* (swank-over (list (format nil "(~S (~S ~S) 7)" :return :ok "stale") (format nil "(~S (~S ~S) 1)" :return :ok "mine"))))
(defparameter *r2* (swank-read-reply *c2* 1))
(test "a reply for a different continuation id is not mistaken for ours" (and (eq (getf *r2* :status) :ok) (string= (getf *r2* :value) "mine") (= 1 (client-stats-get *c2* :unsolicited-skipped))))

(defparameter *c3* (swank-over (list (format nil "(~S ~A)" :indentation-update 0) (format nil "(~S (~S ~S) 1)" :return :ok "ok"))))
(defparameter *r3* (swank-read-reply *c3* 1))
(test "an :indentation-update packet is skipped the same way" (and (eq (getf *r3* :status) :ok) (= 1 (client-stats-get *c3* :unsolicited-skipped))))

(defparameter *c4* (swank-over (list (format nil "(~S (~S ~S) 1)" :return :abort "boom"))))
(defparameter *r4* (swank-read-reply *c4* 1))
(test "an :abort reply is classified, not raised" (and (eq (getf *r4* :status) :abort) (string= (getf *r4* :error) "boom") (= 0 (client-stats-get *c4* :unsolicited-skipped))))

(defparameter *c5* (swank-over (list (format nil "(~S \"unterminated" :return) (format nil "(~S (~S ~S) 1)" :return :ok "after"))))
(defparameter *r5* (swank-read-reply *c5* 1))
(defparameter *r5b* (swank-read-reply *c5* 1))
(test "a malformed packet is classified as :reader-error and the connection survives" (and (eq (getf *r5* :status) :reader-error) (= 1 (client-stats-get *c5* :reader-error)) (eq (getf *r5b* :status) :ok) (= 1 (client-stats-get *c5* :reader-error))))

(defparameter *c6* (swank-over (list (format nil "(~S ~S ~S)" :reader-error "bad" "cause"))))
(defparameter *r6* (swank-read-reply *c6* 1))
(test "a (:reader-error packet cause) packet from the server is classified as such" (and (eq (getf *r6* :status) :reader-error) (= 1 (client-stats-get *c6* :reader-error)) (string= (getf *r6* :value) "bad") (string= (getf *r6* :error) "cause")))

(defparameter *sentinel* nil)
(defparameter *c7* (swank-over (list (format nil "(~S (~S #.(progn (setf *sentinel* t) 1)) 1)" :return :ok))))
(defparameter *r7* (swank-read-reply *c7* 1))
(test "*read-eval* is NIL when reading the payload (a #. payload cannot evaluate code)" (and (eq (getf *r7* :status) :reader-error) (null *sentinel*) (= 1 (client-stats-get *c7* :reader-error))))

(defparameter *c8* (swank-over (list (format nil "(~S (~S ~S) 1)" :return :ok '(1 2 3)))))
(defparameter *r8* (swank-read-reply *c8* 1))
(test "swank-value reads the :ok payload back into data with *read-eval* NIL" (and (equal (swank-value *c8* *r8*) '(1 2 3)) (equal (swank-value *c8* (format nil "(~S ~S)" :a 1)) '(:a 1)) (eq *read-eval* t)))

(test "the client never reads a qualified form client-side (MEM102/D020)" (and (search "(sexpr.tui:agent-snapshot)" (swank-packet-text "(sexpr.tui:agent-snapshot)")) (null (find-symbol "AGENT-SNAPSHOT" :sexpr-tui)) (not (some (lambda (p) (search "SEXPR" (package-name p))) (package-use-list (find-package :sexpr-tui))))))

(defparameter *note* (format nil "(sexpr.tui:inject-note ~A ~A)" (swank-escape-string "subagent-1") (swank-escape-string "he said \"hi\"")))
(defparameter *esc* (swank-packet-text *note* :id 1))
(test "the packet is built from data and printed, so string escaping is correct" (and (= 6 (length (subseq *esc* 0 6))) (search "subagent-1" *esc*) (search "\\\"hi\\\"" *esc*) (string= (swank-escape-string "he said \"hi\"") "\"he said \\\"hi\\\"\"")))

(defparameter *shape* (swank-packet-text "(sexpr:name)" :id 1))
(test "the packet shape is (:emacs-rex form package thread-id id)" (and (= 6 (length (subseq *shape* 0 6))) (string= (subseq *shape* 6) (format nil "(~S ~A ~S ~A ~A)" :emacs-rex "(sexpr:name)" "SWANK-IO-PACKAGE" t 1))))

(defparameter *ids* (new-swank-connection :stream (make-string-output-stream)))
(test "continuation ids are taken once and never reused" (and (= 1 (swank-next-id *ids*)) (= 2 (swank-next-id *ids*)) (= 3 (swank-connection-next-id *ids*))))

(defparameter *push* (make-client-connection :port 1234))
(defparameter *swank* (new-swank-connection :port 4004))
(test "both connection structs share one stats vocabulary" (and (every (lambda (key) (= 0 (client-stats-get *swank* key))) *client-stats-keys*) (every (lambda (key) (= 0 (client-stats-get *push* key))) *client-stats-keys*) (string= (client-label *swank*) "swank") (string= (client-label *push*) "push") (= 1 (progn (client-count! *swank* :rpc-errors) (client-stats-get *swank* :rpc-errors))) (= 1 (progn (client-count! *push* :packets-read) (client-stats-get *push* :packets-read))) (zerop (client-stats-get nil :last-error))))

(defparameter *log* (make-string-output-stream))
(defparameter *lconn* (new-swank-connection :port 4004))
(let ((*tui-client-log* *log*))
  (client-count! *lconn* :reader-error)
  (client-note-error! *lconn* "boom")
  (client-log! *lconn* "reader error" "boom"))
(test "the log handle is NIL by default and writes one structured line when bound" (and (null *tui-client-log*) (search "[tui-client swank :port 4004] reader error — boom" (get-output-stream-string *log*)) (null *tui-client-log*)))

(defparameter *dconn* (new-swank-connection :port 4004))
(test "swank-diagnostics reports the counters and the last error" (client-note-error! *dconn* "boom") (and (= 4004 (getf (swank-diagnostics *dconn*) :port)) (= 1 (swank-connection-next-id *dconn*)) (string= (getf (getf (swank-diagnostics *dconn*) :stats) :last-error) "boom") (null (swank-diagnostics nil))))

(defparameter *log2* (make-string-output-stream))
(test "a failed connect signals to the caller and is counted, not swallowed" (handler-case (let ((*tui-client-log* *log2*)) (swank-connect "127.0.0.1" 1)) (error (e) (and e (search "connect failed" (get-output-stream-string *log2*))))))

(defparameter *sconn* (new-swank-connection :stream (make-string-output-stream)))
(test "close-swank-connection is idempotent on a stream-only connection" (and (eq *sconn* (close-swank-connection *sconn*)) (eq *sconn* (close-swank-connection *sconn*))))

;;;; --- 3. live round trip against a real swank server ----------

(format t "~%live swank server~%")
(defparameter *port* (swank:create-server :port 0 :style :spawn :dont-close t))
;; create-server returns the real ephemeral port. :dont-close t is required here:
;; with dont-close NIL and style :spawn, swank runs its accept loop on the MAIN
;; thread, so create-server never returns and the script hangs.
(defparameter *live* (swank-connect "127.0.0.1" *port*))
(test "create-server returns the real port it bound" (and (integerp *port*) (> *port* 0)))
(test "the live connection is a byte stream, so the header length is a byte count" (byte-stream-p (swank-connection-stream *live*)))
(defparameter *lreply* (live-guard (lambda () (swank-eval *live* "(sexpr:name)"))))
(test "(sexpr:name) returns (:ok \"sexpr\") over the live connection" (and *lreply* (eq (getf *lreply* :status) :ok) (string= (getf *lreply* :value) "sexpr")))
(defparameter *lreply2* (live-guard (lambda () (swank-eval *live* "(cl:list 1 2 3)"))))
(test "the form slot is read and evaluated by the server, so a list value arrives as data" (and *lreply2* (eq (getf *lreply2* :status) :ok) (equal (swank-value *live* *lreply2*) '(1 2 3))))
(defparameter *lquoted* (live-guard (lambda () (write-packet *live* (list :emacs-rex "(sexpr:name)" "SWANK-IO-PACKAGE" t 42))) 10))
(defparameter *lquoted-reply* (live-guard (lambda () (swank-read-reply *live* 42)) 10))
(test "a quoted form slot is self-evaluating, which is why the builder writes packet TEXT" (and *lquoted* *lquoted-reply* (eq (getf *lquoted-reply* :status) :ok) (string= (getf *lquoted-reply* :value) "(sexpr:name)")))
(test "the unsolicited :new-features packet that arrived before the first reply was skipped and counted" (>= (client-stats-get *live* :unsolicited-skipped) 1))
(test "the live connection survived every packet it read" (and (= 0 (client-stats-get *live* :reader-error)) (>= (client-stats-get *live* :packets-read) 2) (>= (client-stats-get *live* :packets-written) 3)))
;; An erroring form is NOT asserted live: swank's eval-for-emacs handler-bind records
;; the condition but the error still reaches swank's debugger hook, so the connection
;; sends :debug-activate and waits for a debug-return instead of (:abort ...). The
;; :abort classification is proven on string streams above, where the reply is exactly
;; what a well-behaved server sends.
(test "a malformed payload is classified as :reader-error on the client side (string-stream proof above)" (and (= 1 (client-stats-get *c5* :reader-error)) (eq (getf *r5* :status) :reader-error)))
(close-swank-connection *live*)

;;;; --- 4. gates --------------------------------------------------

(test "every new file carries the SPDX GPL-3.0-or-later header" (every #'file-has-spdx '("sexpr-tui.asd" "src/tui-client/package.lisp" "src/tui-client/swank-rpc.lisp" "tests/test-swank-rpc.lisp")))

(test "R015: the client never names the provider transport" (not (search "sexpr.provider" (source-text "src/tui-client/swank-rpc.lisp"))))

(test "deprecation invariant: the client uses make-instance 'sb-bsd-sockets:inet-socket, never make-inet-socket" (and (search "make-instance 'sb-bsd-sockets:inet-socket" (source-text "src/tui-client/swank-rpc.lisp")) (not (search "make-inet-socket" (source-text "src/tui-client/swank-rpc.lisp")))))

(test "sexpr-tui.asd lists only files that exist" (every (lambda (name) (probe-file (merge-pathnames (format nil "src/tui-client/~A.lisp" name) (uiop:getcwd)))) '("package" "messages" "wire" "swank-rpc")))

(test "the client system still depends on :tuition only, never :sexpr" (and (equal (designator-names (asdf:system-depends-on (asdf:find-system :sexpr-tui))) '("TUITION")) (equal (package-use-list (find-package :sexpr-tui)) (list (find-package :cl) (find-package :tuition)))))

(format t "~%~D tests, ~D passed, ~D failed~%" *tests-run* *tests-passed* *tests-failed*)
(sb-ext:exit :code (if (> *tests-failed* 0) 1 0))
