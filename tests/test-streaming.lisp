;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/test-streaming.lisp — standalone test for model-step-streaming.
;;;;
;;;; Run with: sbcl --script tests/test-streaming.lisp
;;;;
;;;; model-step-streaming (D017) lives in the kernel and calls
;;;; cl-llm-provider:complete-stream directly. complete-stream and
;;;; stream-tool-calls are cl-llm-provider PLAIN functions (not generic), so
;;;; they are stubbed via FDEFINITION redefinition for the duration of the
;;;; suite and restored in an UNWIND-PROTECT. read-stream-chunk and
;;;; stream-accumulated-content ARE generic, so a fake-stream class adds
;;;; methods specialized on it. Real cl-llm-provider:stream-chunk and
;;;; cl-llm-provider:tool-call instances exercise the production accessors
;;;; (chunk-delta, tool-call-id/name/arguments) natively — no stubs needed
;;;; for those, so the test proves the kernel reads the real chunk/tool-call
;;;; shapes the transport produces.

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(defpackage :sexpr-test-streaming
  (:use :cl :sexpr.kernel :sexpr.transcript :sexpr.tools))
(in-package :sexpr-test-streaming)

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
       (ok ,description (progn ,@body))
     (error (err)
       (crash ,description err))))

;;; --- the fake stream ------------------------------------------------
;;;;
;;;; A stand-in for cl-llm-provider:completion-stream. read-stream-chunk and
;;;; stream-accumulated-content are generic, so methods on fake-stream drive
;;;; the loop. complete-stream and stream-tool-calls are plain defuns and are
;;;; redefined via FDEFINITION below.

(defclass fake-stream ()
  ((chunks :initarg :chunks :accessor fake-chunks
           :documentation "Canned stream-chunk instances, consumed in order.")
   (content :initarg :content :accessor fake-content
            :documentation "The string stream-accumulated-content returns.")
   (tool-calls :initarg :tool-calls :initform nil :accessor fake-tool-calls
               :documentation "Canned cl-llm-provider:tool-call instances.")
   (state :initarg :state :initform :open :accessor fake-state
          :documentation "Mirrors cl-llm-provider:stream-state so the kernel's
budget abort (setf stream-state :closed) and stream-closed-p are observable.")))

;; stream-state is an accessor generic on cl-llm-provider:completion-stream; we
;; add methods specialized on fake-stream rather than subclassing completion-
;; stream, so the fake keeps its own slot layout and no initargs need plumbing.
(defmethod cl-llm-provider:stream-state ((stream fake-stream))
  (fake-state stream))

(defmethod (setf cl-llm-provider:stream-state) (value (stream fake-stream))
  (setf (fake-state stream) value))

(defmethod cl-llm-provider:read-stream-chunk ((stream fake-stream) &key timeout)
  (declare (ignore timeout))
  (when (cl-llm-provider:stream-closed-p stream)
    (return-from cl-llm-provider:read-stream-chunk nil))
  (if (fake-chunks stream)
      (pop (fake-chunks stream))
      nil))

(defclass interrupting-fake-stream (fake-stream)
  ((signaled :initform nil :accessor interrupting-signaled))
  (:documentation "A fake whose first pull signals cl-llm-provider:stream-
interrupted-error inside a restart-case named cl-llm-provider:abort-stream,
the same shape the provider's real readers establish."))

(defmethod cl-llm-provider:read-stream-chunk ((stream interrupting-fake-stream)
                                               &key timeout)
  (declare (ignore timeout))
  (when (cl-llm-provider:stream-closed-p stream)
    (return-from cl-llm-provider:read-stream-chunk nil))
  (if (interrupting-signaled stream)
      nil
      (progn
        (setf (interrupting-signaled stream) t)
        (restart-case
            (error 'cl-llm-provider:stream-interrupted-error)
          (cl-llm-provider:abort-stream ()
            (setf (cl-llm-provider:stream-state stream) :closed)
            nil)))))

(defmethod cl-llm-provider:stream-accumulated-content ((stream fake-stream))
  (fake-content stream))

(defun make-fake-chunk (delta &key (finish-reason nil) (usage nil))
  "A real cl-llm-provider:stream-chunk so chunk-delta is read natively."
  (make-instance 'cl-llm-provider:stream-chunk
                 :delta delta
                 :content delta
                 :finish-reason finish-reason
                 :usage usage
                 :index 0))

(defun make-fake-tool-call (id name arguments)
  "A real cl-llm-provider:tool-call so tool-call-id/name/arguments read natively."
  (make-instance 'cl-llm-provider:tool-call
                 :id id :name name :arguments arguments))

(defvar *fake-stream* nil
  "Bound by each test to the fake-stream the stubbed complete-stream returns.")

(defvar *last-system* nil
  "The :system argument the stubbed complete-stream most recently received.")
(defvar *last-tools* nil
  "The :tools argument the stubbed complete-stream most recently received.")

;;; --- the non-streaming provider stub --------------------------------
;;;;
;;;; Test 14 needs the NON-streaming loop to run, and that path goes
;;;; model-step -> sexpr.provider:provider-call, not complete-stream. A stub
;;;; endpoint class with a canned node list is the same seam tests/kernel.lisp
;;;; uses, so no fdefinition surgery on model-step is needed.

(defclass tool-stub-endpoint ()
  ((responses
    :initarg :responses
    :initform nil
    :accessor tool-stub-responses
    :documentation "Canned provider nodes, consumed in order.")))

(defmethod sexpr.provider:provider-call ((endpoint tool-stub-endpoint) messages
                                         &key system tools temperature max-tokens)
  (declare (ignore messages system tools temperature max-tokens))
  (let ((next (pop (tool-stub-responses endpoint))))
    (or next (error "tool-stub-endpoint exhausted"))))

;;; --- stub + restore -------------------------------------------------

(defparameter *real-complete-stream* nil)
(defparameter *real-stream-tool-calls* nil)

(defun stub-streaming-api ()
  "Replace complete-stream and stream-tool-calls with stubs that drive
fake-stream. Real providers are untouched for everything else."
  (setf *real-complete-stream* (fdefinition 'cl-llm-provider:complete-stream))
  (setf *real-stream-tool-calls* (fdefinition 'cl-llm-provider:stream-tool-calls))
  (setf (fdefinition 'cl-llm-provider:complete-stream)
        (lambda (messages &key provider model max-tokens temperature
                          system tools tool-choice stop
                          on-chunk on-complete on-error
                    &allow-other-keys)
          (declare (ignore messages provider model max-tokens temperature
                           tool-choice stop on-chunk on-complete on-error))
          (setf *last-system* system
                *last-tools* tools)
          (or *fake-stream*
              (error "no fake-stream bound for stubbed complete-stream"))))
  (setf (fdefinition 'cl-llm-provider:stream-tool-calls)
        (lambda (stream)
          (if (typep stream 'fake-stream)
              (fake-tool-calls stream)
              (funcall *real-stream-tool-calls* stream)))))

(defun restore-streaming-api ()
  (when *real-complete-stream*
    (setf (fdefinition 'cl-llm-provider:complete-stream)
          *real-complete-stream*))
  (when *real-stream-tool-calls*
    (setf (fdefinition 'cl-llm-provider:stream-tool-calls)
          *real-stream-tool-calls*)))

;;; --- tests ----------------------------------------------------------

(format t "model-step-streaming tests:~%~%")

(unwind-protect
     (progn
       (stub-streaming-api)
       (clrhash *event-bus*)

       (test "1. each chunk is emitted to the event bus as a :delta event"
         (let ((received nil))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                :chunks (list (make-fake-chunk "Hello")
                                              (make-fake-chunk " world")
                                              (make-fake-chunk "" :finish-reason :stop))
                                :content "Hello world"
                                :tool-calls nil))
           (let* ((event (model-step-streaming
                          (spawn :goal "g" :name "streamer" :endpoint :ollama)))
                  ;; model-step-streaming now also emits one :finalize, so count
                  ;; only the deltas here.
                  (deltas (remove-if-not (lambda (e) (eq (getf e :type) :delta))
                                         (nreverse received))))
             (declare (ignore event))
             (and (= (length deltas) 3)
                  (equal (mapcar (lambda (e) (getf e :chunk-delta)) deltas)
                         '("Hello" " world" ""))
                  (every (lambda (e) (eq (getf e :kind) :model)) deltas)
                  (every (lambda (e) (string= (getf e :agent-id) "streamer"))
                         deltas)))))

       (test "2. the final event carries accumulated content, finish and usage"
         (setf *fake-stream*
               (make-instance 'fake-stream
                              :chunks (list (make-fake-chunk "Hi")
                                            (make-fake-chunk "!" :finish-reason :stop
                                                             :usage (list :total-tokens 7)))
                              :content "Hi!"
                              :tool-calls nil))
         (let ((event (model-step-streaming
                       (spawn :goal "g" :name "streamer" :endpoint :ollama))))
           (and (eq (event-type event) :model)
                (string= (event-content event) "Hi!")
                (eq (event-finish event) :stop)
                (equal (event-usage event) (list :total-tokens 7))
                (null (event-tool-calls event)))))

       (test "3. streamed tool-calls are translated to the model-step plist shape"
         (setf *fake-stream*
               (make-instance 'fake-stream
                              :chunks (list (make-fake-chunk ""
                                                            :finish-reason :tool-calls))
                              :content ""
                              :tool-calls (list (make-fake-tool-call
                                                 "1" "get-weather"
                                                 '(:city "Paris")))))
         (let ((event (model-step-streaming
                       (spawn :goal "g" :name "streamer" :endpoint :ollama))))
           (and (equal (event-tool-calls event)
                       (list (list :id "1"
                                   :name "get-weather"
                                   :arguments '(:city "Paris"))))
                (eq (event-finish event) :tool-calls))))

       (test "4. a stream with no chunks returns an empty content event"
         (setf *fake-stream*
               (make-instance 'fake-stream
                               :chunks nil :content "" :tool-calls nil))
         (let ((event (model-step-streaming
                       (spawn :goal "g" :name "streamer" :endpoint :ollama))))
           (and (string= (event-content event) "")
                (null (event-finish event))
                (null (event-tool-calls event)))))

       (test "5. the system prompt is the goal when no persona is set"
         (setf *fake-stream*
               (make-instance 'fake-stream
                              :chunks (list (make-fake-chunk "ok" :finish-reason :stop))
                              :content "ok"
                              :tool-calls nil))
         (model-step-streaming
          (spawn :goal "do the thing" :name "streamer" :endpoint :ollama))
         (string= *last-system* "do the thing"))

       (test "6. tool schemas are translated to tool-definition objects before streaming"
         (reset-tool-registry!)
         (define-tool stream-probe (x)
           "A probe tool for the streaming test."
           x)
         (setf *fake-stream*
               (make-instance 'fake-stream
                              :chunks (list (make-fake-chunk "ok" :finish-reason :stop))
                              :content "ok"
                              :tool-calls nil))
         (model-step-streaming
          (spawn :goal "g" :name "streamer" :endpoint :ollama))
         (and (consp *last-tools*)
              (typep (first *last-tools*) 'cl-llm-provider:tool-definition))))

       (test "7. a :total-tokens budget trip closes the stream and marks the event"
         (clrhash *event-bus*)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama
                             :budget (make-budget :tokens 5))))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                :chunks (list (make-fake-chunk "aaaa" :usage (list :total-tokens 3))
                                              (make-fake-chunk "bbbb" :usage (list :total-tokens 6))
                                              (make-fake-chunk "cccc" :usage (list :total-tokens 9))
                                              (make-fake-chunk "" :finish-reason :stop))
                                :content "aaaabbbb"
                                :tool-calls nil))
           (let* ((event (model-step-streaming agent))
                  (bus (find :budget-exceeded received
                             :key (lambda (e) (getf e :type)))))
             (and (getf event :budget-exceeded)
                  (cl-llm-provider:stream-closed-p *fake-stream*)
                  bus
                  (= (getf bus :tokens-used) 6)
                  (= (getf bus :limit) 5)
                  (string= (getf bus :agent-id) "streamer")
                  ;; the budget-abort path still ends the stream with :finalize
                  (find :finalize received :key (lambda (e) (getf e :type)))
                  ;; the loop stopped at the ceiling: the last two chunks are unread
                  (= (length (fake-chunks *fake-stream*)) 2)))))

       (test "8. an unlimited budget runs every chunk with no abort or bus event"
         (clrhash *event-bus*)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama
                             :budget (make-budget))))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                :chunks (list (make-fake-chunk "aaaa" :usage (list :total-tokens 1000))
                                              (make-fake-chunk "bbbb" :usage (list :total-tokens 2000))
                                              (make-fake-chunk "" :finish-reason :stop))
                                :content "aaaabbbb"
                                :tool-calls nil))
           (let ((event (model-step-streaming agent)))
             (and (null (getf event :budget-exceeded))
                  (null (find :budget-exceeded received
                              :key (lambda (e) (getf e :type))))
                  ;; deltas only: the stream also emits one :finalize
                  (= (length (remove-if-not
                              (lambda (e) (eq (getf e :type) :delta))
                              received))
                     3)
                  (not (cl-llm-provider:stream-closed-p *fake-stream*))))))

       (test "9. the delta-character proxy trips a budget with no usage reported"
         (clrhash *event-bus*)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama
                             :budget (make-budget :tokens 3))))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                ;; 8 chars -> 2 tokens per chunk by the proxy
                                :chunks (list (make-fake-chunk "aaaaaaaa")
                                              (make-fake-chunk "bbbbbbbb")
                                              (make-fake-chunk "" :finish-reason :stop))
                                :content "aaaaaaaabbbbbbbb"
                                :tool-calls nil))
           (let* ((event (model-step-streaming agent))
                  (bus (find :budget-exceeded received
                             :key (lambda (e) (getf e :type)))))
             (and (getf event :budget-exceeded)
                  bus
                  (= (getf bus :tokens-used) 4)
                  (= (length (fake-chunks *fake-stream*)) 1)))))

       (test "10. a provider interruption is converted to a clean abort via the restart"
         (clrhash *event-bus*)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama)))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'interrupting-fake-stream
                                :chunks nil :content "partial" :tool-calls nil))
           (let ((event (model-step-streaming agent)))
             ;; if the condition escaped, the TEST macro records a CRASH
             (and (getf event :interrupted)
                  (cl-llm-provider:stream-closed-p *fake-stream*)
                  (string= (event-content event) "partial")
                  (null (getf event :budget-exceeded))
                  ;; the interruption path also ends the stream with :finalize
                  (find :finalize received :key (lambda (e) (getf e :type)))))))

       (test "11. a clean stream emits exactly one :finalize with the pre-integration index"
         (clrhash *event-bus*)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama)))
           ;; two pre-existing events so the cursor is a non-trivial number
           (integrate agent (make-user-event "one"))
           (integrate agent (make-user-event "two"))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                :chunks (list (make-fake-chunk "Hello")
                                              (make-fake-chunk " world" :finish-reason :stop))
                                :content "Hello world"
                                :tool-calls nil))
           (let* ((event (model-step-streaming agent))
                  (finalizes (remove-if-not (lambda (e) (eq (getf e :type) :finalize))
                                            (nreverse received))))
             (declare (ignore event))
             (and (= (length finalizes) 1)
                  (= (getf (first finalizes) :event-index) 2)
                  (string= (getf (first finalizes) :agent-id) "streamer")))))

       (test "12. agent-streaming-p is T while a stream is in flight and NIL after"
         (clrhash *event-bus*)
         (let ((streaming-during nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama)))
           (subscribe-event-bus "streamer"
                                (lambda (e)
                                  (when (eq (getf e :type) :delta)
                                    (setf streaming-during (agent-streaming-p agent)))))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                :chunks (list (make-fake-chunk "x" :finish-reason :stop))
                                :content "x"
                                :tool-calls nil))
           (let ((before (agent-streaming-p agent)))
             (model-step-streaming agent)
             (and (null before)
                  streaming-during
                  (null (agent-streaming-p agent))))))

       (test "13. run-until-finished :streaming t emits tool progress and stops on budget"
         (clrhash *event-bus*)
         (reset-tool-registry!)
         (define-tool stream-echo (x)
           "Echo a value for the streaming tool-progress test."
           x)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama
                             :budget (make-budget :tokens 1))))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                ;; 4 chars -> 1 token per chunk by the proxy; the
                                ;; second chunk takes the total to 2 > 1 and trips.
                                :chunks (list (make-fake-chunk "aaaa")
                                              (make-fake-chunk "bbbb"))
                                :content "aaaabbbb"
                                :tool-calls (list (make-fake-tool-call
                                                   "c1" "stream-echo" '(:x 42)))))
           (run-until-finished agent :streaming t)
           (let* ((events (nreverse received))
                  (types (mapcar (lambda (e) (getf e :type)) events))
                  (start (find :tool-start events :key (lambda (e) (getf e :type))))
                  (result (find :tool-result events :key (lambda (e) (getf e :type)))))
             (and (member :budget-exceeded types)
                  ;; the truncated turn still ends the stream with :finalize
                  (member :finalize types)
                  start
                  result
                  (< (position :tool-start types) (position :tool-result types))
                  (string= (getf start :call-id) "c1")
                  (string= (getf start :name) "stream-echo")
                  (string= (getf result :call-id) "c1")
                  (stringp (getf result :value))
                  (string= (getf result :value) (getf result :text))
                  ;; the budget abort stopped the loop after one model turn
                  (= (length (remove-if-not (lambda (e) (eq (getf e :type) :delta))
                                            events))
                     2)))))

       (test "14. the non-streaming loop emits no tool events for the same round"
         (clrhash *event-bus*)
         (reset-tool-registry!)
         (define-tool stream-echo (x)
           "Echo a value for the non-streaming tool-progress control."
           x)
         (let* ((received nil)
                (endpoint (make-instance 'tool-stub-endpoint
                                         :responses
                                         (list (list :content ""
                                                     :tool-calls (list (list :id "c1"
                                                                             :name "stream-echo"
                                                                             :arguments '(:x 42)))
                                                     :finish :tool-calls)
                                               (list :content "done" :finish :stop))))
                (agent (spawn :goal "g" :name "streamer" :endpoint endpoint)))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (run-until-finished agent)
           (and (null received)
                ;; the tool round really dispatched: model, result, model
                (= (transcript-length (agent-transcript agent)) 3))))

       (test "15. agent-loop-streaming is fbound and drives the streaming path"
         (clrhash *event-bus*)
         (let ((received nil)
               (agent (spawn :goal "g" :name "streamer" :endpoint :ollama)))
           (subscribe-event-bus "streamer" (lambda (e) (push e received)))
           (setf *fake-stream*
                 (make-instance 'fake-stream
                                :chunks (list (make-fake-chunk "hi" :finish-reason :stop))
                                :content "hi"
                                :tool-calls nil))
           (and (fboundp 'agent-loop-streaming)
                (progn (agent-loop-streaming agent) t)
                ;; the streaming path emits a :finalize the non-streaming
                ;; model-step never does
                (find :finalize received :key (lambda (e) (getf e :type))))))

  (restore-streaming-api))

;;; --- Summary --------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%"
        *tests-run* *tests-passed* *tests-failed*)

(if (= *tests-failed* 0)
    (format t "~%ALL PASSED~%")
    (progn
      (format *error-output* "~%FAILED~%")
      (sb-ext:exit :code 1)))
