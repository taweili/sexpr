;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-tui.lisp — standalone test for the sexpr.tui RPC stubs.
;;;;
;;;; Run with: sbcl --script tests/test-tui.lisp
;;;;
;;;; T03 adds the package and the five RPC stubs but deliberately does NOT
;;;; wire them into sexpr.asd (that is T04). This test therefore quickloads
;;;; the base system, then loads the two tui source files by path before
;;;; exercising the package. Every call is expected to return a plain
;;;; sexpr — no live object — so we can round-trip through print/read.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

;; Load the tui module by path — T04 wires it into sexpr.asd.
(load "src/tui/package.lisp")
(load "src/tui/tui.lisp")

(defpackage :sexpr-test-tui
  (:use :cl :sb-thread :sexpr.transcript :sexpr.agents :sexpr.tui))
;; We :use both :sexpr.kernel (indirectly, through :sexpr.agents) and
;; :sexpr.tui, and both export `spawn`. :shadow #:spawn makes the local
;; `spawn` in this test package unambiguous — it resolves to
;; :sexpr.tui:spawn. Kernel is reached via agents' :use chain; kernel
;; internals that the tests need (agent-name, agent-transcript, etc.)
;; are reached by qualified name.
(in-package :sexpr-test-tui)

(defparameter *tests-run* 0)
(defparameter *tests-passed* 0)
(defparameter *tests-failed* 0)

(defun ok (description form)
  (incf *tests-run*)
  (if form
      (progn (incf *tests-passed*)
             (format t "  ok: ~A~%" description))
      (progn (incf *tests-failed*)
             (format t "  FAIL: ~A~%" description))))

(defun crash (description err)
  (incf *tests-run*)
  (incf *tests-failed*)
  (format t "  CRASH: ~A — ~A~%" description err))

(defmacro test (description &body body)
  `(handler-case
       (progn (reset!) (ok ,description (progn ,@body)))
     (error (err)
       (crash ,description err))))

(defun test-signals (description thunk)
  "Assert that THUNK signals an ERROR."
  (incf *tests-run*)
  (handler-case
      (progn (funcall thunk)
             (incf *tests-failed*)
             (format t "  FAIL: ~A — no signal~%" description))
    (error ()
      (incf *tests-passed*)
      (format t "  ok: ~A~%" description))))

;;; --- reset the image state between tests -----------------------------

(defun reset! ()
  (clrhash sexpr.agents:*agent-table*)
  (sexpr.agents:clear-subagent-registry!))

;;; --- unlock sexpr.kernel for fdefinition redefinition --------------
;; SBCL's package-lock check refuses (SETF (FDEFINITION <sym>) <fn>)
;; when the symbol's home package is locked AND the current package is
;; different. :sexpr.kernel is locked (defpackage default); tests that
;; stub agent-loop (T03 tests 13/15/17) need to unlock it first.
;; test-streaming gets away with the same trick because
;; cl-llm-provider's package is unlocked (quickload behavior).

(sb-ext:unlock-package (find-package :sexpr.kernel))

(defmacro with-stubbed-agent-loop (&body body)
  "Run BODY with sexpr.kernel:agent-loop replaced by a no-op, so tests that
  call spawn do not start real worker threads. Same trick tests 13/15/17 use
  inline; :sexpr.kernel is unlocked above so fdefinition redefinition is legal."
  `(let ((real-agent-loop (fdefinition 'sexpr.kernel:agent-loop)))
     (setf (fdefinition 'sexpr.kernel:agent-loop)
           (lambda (agent) (declare (ignore agent))))
     (unwind-protect
         (progn ,@body)
       (setf (fdefinition 'sexpr.kernel:agent-loop) real-agent-loop))))

;;; --- helpers ---------------------------------------------------------

(defun make-agent! (name &key goal (capabilities '(:fs-read :spawn))
                        endpoint endpoint-set)
  "Register AGENT in the global table and return it. The agent has an
empty transcript by default. Pass :endpoint with :endpoint-set t to set
a non-NIL endpoint."
  (let ((agent (sexpr.kernel:spawn :name name
                                   :goal (or goal "test goal")
                                   :capabilities capabilities
                                   :endpoint (if endpoint-set endpoint nil))))
    (sexpr.agents:register-agent! agent)
    agent))

(defun append-model-line! (agent text)
  (sexpr.transcript:append-event (sexpr.kernel:agent-transcript agent)
                                 (sexpr.transcript:make-model-event text)))

(defun snapshot-of (name)
  "Return the agent-snapshot entry with :name == NAME, or NIL."
  (find name (agent-snapshot)
        :key (lambda (e) (getf e :name))
        :test #'string=))

(defun snapshot-of-handle (handle-id)
  "Return the agent-snapshot entry with :handle == HANDLE-ID, or NIL."
  (find handle-id (agent-snapshot)
        :key (lambda (e) (getf e :handle))
        :test #'string=))

(defun serialize-round-trip (obj)
  "Return OBJ after a print/read cycle. Live objects (class instances,
hash tables, function closures) are rejected by the reader — if the
object isn't data-only the round-trip raises."
  (let ((str (format nil "~s" obj)))
    (read-from-string str :eof)))

;;;; --- tests ----------------------------------------------------------

(format t "sexpr.tui tests:~%~%")

(reset!)

(test "1. agent-snapshot on an empty society returns an empty list"
  (eql (agent-snapshot) nil))

(test "2. agent-snapshot returns one plist per registered agent, each with all required keys"
  (make-agent! "root-1")
  (make-agent! "root-2")
  (let ((snap (agent-snapshot)))
    (and (= (length snap) 2)
         (every (lambda (entry)
                  (and (consp entry)
                       (eq (first entry) :name)
                       (stringp (second entry))
                       (eq (getf entry :name) (second entry))
                       (keywordp (getf entry :status))
                       (member (getf entry :status)
                               '(:running :finished :failed :killed))
                       (typep (getf entry :thread-alive-p) 'boolean)
                       (integerp (getf entry :transcript-length))
                       (listp (getf entry :capabilities))
                       (or (null (getf entry :endpoint))
                           (keywordp (getf entry :endpoint)))
                       (or (eq (getf entry :budget) :unlimited)
                           (and (listp (getf entry :budget))
                                (integerp (getf (getf entry :budget) :tokens))
                                (integerp (getf (getf entry :budget) :seconds))))))
                snap))))

(test "3. agent-snapshot is serializable — a round-trip through print/read preserves names"
  (make-agent! "root-1")
  (let ((snap (agent-snapshot))
        (copy (serialize-round-trip (agent-snapshot))))
    (and (consp snap)
         (= (length snap) (length copy))
         (equal (mapcar (lambda (e) (getf e :name)) snap)
                (mapcar (lambda (e) (getf e :name)) copy)))))

(test "4. agent-snapshot shows :unlimited budget for a default (max-fixnum) budget"
  (make-agent! "root-1")
  (eq (getf (snapshot-of "root-1") :budget) :unlimited))

(test "5. agent-snapshot shows :endpoint NIL when unset and a keyword when set"
  (make-agent! "root-1")
  (make-agent! "root-2" :endpoint :ollama :endpoint-set t)
  (and (null (getf (snapshot-of "root-1") :endpoint))
       (eq (getf (snapshot-of "root-2") :endpoint) :ollama)))

(test "6. agent-snapshot transcript-length reflects appended events"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "hello")
    (append-model-line! a "world")
    (= (getf (snapshot-of "root-1") :transcript-length) 2)))

(test "7. transcript-delta returns (all-events . count) at cursor 0"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "one")
    (append-model-line! a "two")
    (append-model-line! a "three")
    (let* ((pair (transcript-delta "root-1" 0))
           (events (car pair))
           (new-cursor (cdr pair)))
      (and (= (length events) 3)
           (= new-cursor 3)
           (string= (sexpr.transcript:event-content (car (last events)))
                    "three")))))

(test "8. transcript-delta at cursor N returns the events from N onward and the total count"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "one")
    (append-model-line! a "two")
    (append-model-line! a "three")
    (let ((pair (transcript-delta "root-1" 1)))
      (and (= (length (car pair)) 2)
           (= (cdr pair) 3)
           (string= (sexpr.transcript:event-content (first (car pair)))
                    "two")))))

(test "9. transcript-delta at the tail cursor returns NIL events but the total count"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "one")
    (append-model-line! a "two")
    (let ((pair (transcript-delta "root-1" 2)))
      (and (null (car pair))
           (= (cdr pair) 2)))))

(test "10. transcript-delta tracks new events appended after the cursor"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "one")
    (append-model-line! a "two")
    (append-model-line! a "three")
    (let ((pair2 (transcript-delta "root-1" 2)))
      (and (= (length (car pair2)) 1)
           (= (cdr pair2) 3)
           (string= (sexpr.transcript:event-content (first (car pair2)))
                    "three")))))

(test "11. transcript-delta with a cursor beyond the end returns an empty list, no error"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "one")
    (let ((pair (transcript-delta "root-1" 10)))
      (and (null (car pair))
           (= (cdr pair) 1)))))

(test-signals "12. transcript-delta on an unknown agent signals"
  (lambda () (transcript-delta "nope" 0)))

(test "13. inject-note delegates to subagent-note and appends a user event to the subagent's transcript"
  (let ((real-agent-loop (fdefinition 'sexpr.kernel:agent-loop)))
    (setf (fdefinition 'sexpr.kernel:agent-loop)
          (lambda (agent) (declare (ignore agent))))
    (unwind-protect
         (let* ((id (spawn-subagent "test goal"))
                (handle (sexpr.agents:find-handle id))
                (agent (sexpr.agents:handle-agent handle))
                (result (inject-note id "please hurry"))
                (expected (format nil "noted ~a: please hurry" id)))
           (and (string= result expected)
                (= (sexpr.transcript:transcript-length
                    (sexpr.kernel:agent-transcript agent)) 1)
                (eq (sexpr.transcript:event-type
                     (car (sexpr.transcript:events-list
                           (sexpr.kernel:agent-transcript agent))))
                    :user)))
      (setf (fdefinition 'sexpr.kernel:agent-loop) real-agent-loop))))

(test "14. inject-note signals on an unknown handle"
  (handler-case
      (progn (inject-note "nope" "hi") nil)
    (error () t)))

(test "15. kill delegates to subagent-kill and terminates a real thread"
  (let ((real-agent-loop (fdefinition 'sexpr.kernel:agent-loop)))
    (setf (fdefinition 'sexpr.kernel:agent-loop)
          (lambda (agent)
            (declare (ignore agent))
            ;; Block long enough to be killed before waking.
            (sleep 300)))
    (unwind-protect
         (let* ((id (spawn-subagent "test goal"))
                (handle (sexpr.agents:find-handle id))
                (agent (sexpr.agents:handle-agent handle))
                (thread (sexpr.agents:handle-thread handle))
                (alive-before (sb-thread:thread-alive-p thread))
                (result (kill id)))
           ;; SBCL's terminate-thread is asynchronous: thread-alive-p
           ;; still returns T for a brief moment after the call. Poll
           ;; briefly until the thread actually exits. A hard cap of
           ;; 1s keeps the test bounded if it ever hangs.
           (do ((i 0 1))
               ((or (not (sb-thread:thread-alive-p thread))
                    (> i 100)))
             (sleep 0.01))
           (and alive-before
                (not (sb-thread:thread-alive-p thread))
                (string= result (format nil "killed ~a" id))
                (eq (sexpr.kernel:agent-status agent) :killed)))
      (setf (fdefinition 'sexpr.kernel:agent-loop) real-agent-loop))))

(test "16. kill signals on an unknown handle"
  (handler-case
      (progn (kill "nope") nil)
    (error () t)))

(test "17. spawn returns a handle ID string and registers the agent in the global table"
  ;; We don't want a real agent-loop thread; stub agent-loop via fdefinition
  ;; redefinition (it is a plain defun, not generic) for the duration.
  (let ((real-agent-loop (fdefinition 'sexpr.kernel:agent-loop)))
    (setf (fdefinition 'sexpr.kernel:agent-loop)
          (lambda (agent) (declare (ignore agent))))
    (unwind-protect
         (let ((id (spawn "test goal" :capabilities '(:fs-read))))
           (and (stringp id)
                (string= id "subagent-1")
                (let ((handle (sexpr.agents:find-handle id)))
                  (and handle
                       (let ((agent (sexpr.agents:handle-agent handle)))
                         (gethash (sexpr.kernel:agent-name agent)
                                  sexpr.agents:*agent-table*))))))
      (setf (fdefinition 'sexpr.kernel:agent-loop) real-agent-loop))))

(test "18. agent-snapshot is entirely serializable — no live objects cross the boundary"
  (make-agent! "root-1")
  (append-model-line! (gethash "root-1" sexpr.agents:*agent-table*) "one")
  (append-model-line! (gethash "root-1" sexpr.agents:*agent-table*) "two")
  (let ((snap (agent-snapshot))
        (copy (serialize-round-trip (agent-snapshot))))
    (equal snap copy)))

(test "19. transcript-delta events are serializable"
  (let ((a (make-agent! "root-1")))
    (append-model-line! a "one")
    (append-model-line! a "two")
    (let ((pair (transcript-delta "root-1" 0))
          (copy (serialize-round-trip (transcript-delta "root-1" 0))))
      (equal pair copy))))

;;;; --- T03: the :handle field ---------------------------------------

(test "20. agent-snapshot includes :handle as a string for an agent registered through sexpr.tui:spawn"
  (with-stubbed-agent-loop
    (let* ((id (spawn "test goal"))
           (entry (snapshot-of-handle id)))
      (and (stringp id)
           entry
           (stringp (getf entry :handle))
           (string= (getf entry :handle) id)
           (string= id "subagent-1")))))

(test "21. agent-snapshot :handle is NIL for an agent created directly in *agent-table* with no handle"
  (make-agent! "root-1")
  (let ((entry (snapshot-of "root-1")))
    (and entry
         (consp entry)
         (null (getf entry :handle)))))

(test "22. mixed society: the spawned agent has a handle string, the table-only agent has NIL"
  (with-stubbed-agent-loop
    (let* ((id (spawn "worker"))
           (spawned (snapshot-of-handle id)))
      (make-agent! "root-1")
      (let ((plain (snapshot-of "root-1")))
        (and (= (length (agent-snapshot)) 2)
             (string= (getf spawned :handle) id)
             (null (getf plain :handle)))))))

(test "23. negative: :handle is resolved by agent identity, not by name — an agent NAMED like a handle ID still reads NIL"
  (with-stubbed-agent-loop
    (make-agent! "subagent-1")
    (let* ((id (spawn "worker"))
           (named (snapshot-of "subagent-1"))
           (spawned (snapshot-of-handle id)))
      (and (string= id "subagent-1")
           named
           (null (getf named :handle))
           (string= (getf spawned :handle) id)))))

(test "24. negative: a handle whose agent is not in the table adds no snapshot row and no false :handle"
  (with-stubbed-agent-loop
    (let* ((id (spawn "worker"))
           (handle (sexpr.agents:find-handle id))
           (agent (sexpr.agents:handle-agent handle)))
      (sexpr.agents:deregister-agent! agent)
      (and (= (length (agent-snapshot)) 0)
           (= (hash-table-count (sexpr.tui::%agent-handle-index)) 1)))))

(test "25. negative: an agent with no handle is absent from the index, so a non-empty registry does not leak a handle into its snapshot row"
  (let ((registry (make-hash-table :test #'equal)))
    (setf (gethash "ghost-1" registry)
          (make-instance 'sexpr.agents:subagent-handle
                         :id "ghost-1"
                         :agent (sexpr.kernel:spawn :goal "real")))
    (let ((index (sexpr.tui::%agent-handle-index registry)))
      (and (= (hash-table-count index) 1)
           ;; The table agent is not the ghost handle's agent, so it is absent
           ;; from the index and the snapshot field reads NIL.
           (null (gethash (make-agent! "root-1") index))))))

(test "26. boundary: the snapshot stays data-only with :handle present — print/read round-trip preserves the string"
  (with-stubbed-agent-loop
    (let* ((id (spawn "worker"))
           (snap (agent-snapshot))
           (copy (serialize-round-trip snap)))
      (and (equal snap copy)
           (= (length snap) 1)
           (stringp (getf (first snap) :handle))
           (string= (getf (first snap) :handle) id)))))

(test "27. 10x load: the index is built once per snapshot call and resolves all 10 handles by identity"
  (with-stubbed-agent-loop
    (let ((ids (loop for i from 1 to 10 collect (spawn (format nil "goal-~d" i)))))
      (and (= (length ids) 10)
           (= (hash-table-count sexpr.agents:*subagent-registry*) 10)
           ;; One pass: the index has exactly one entry per handle.
           (= (hash-table-count (sexpr.tui::%agent-handle-index)) 10)
           ;; Every index entry is the same agent object find-handle returns —
           ;; identity, not a name match.
           (every (lambda (id)
                    (let ((handle (sexpr.agents:find-handle id)))
                      (eq (gethash (sexpr.agents:handle-agent handle)
                                   (sexpr.tui::%agent-handle-index))
                          (sexpr.agents:handle-id handle))))
                  ids)
           ;; Every snapshot row that exists carries a string handle.
           (every (lambda (row) (stringp (getf row :handle))) (agent-snapshot))))))

;;; --- Summary --------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%"
        *tests-run* *tests-passed* *tests-failed*)

(if (= *tests-failed* 0)
    (format t "~%ALL PASSED~%")
    (progn
      (format *error-output* "~%FAILED~%")
      (sb-ext:exit :code 1)))
