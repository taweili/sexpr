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
               :documentation "Canned cl-llm-provider:tool-call instances.")))

(defmethod cl-llm-provider:read-stream-chunk ((stream fake-stream) &key timeout)
  (declare (ignore timeout))
  (if (fake-chunks stream)
      (pop (fake-chunks stream))
      nil))

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
           (let ((event (model-step-streaming
                         (spawn :goal "g" :name "streamer" :endpoint :ollama))))
             (declare (ignore event))
             (and (= (length received) 3)
                  (every (lambda (e) (eq (getf e :type) :delta)) received)
                  (equal (mapcar (lambda (e) (getf e :chunk-delta))
                                 (nreverse received))
                         '("Hello" " world" ""))
                  (every (lambda (e) (string= (getf e :agent-id) "streamer"))
                         received)))))

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

  (restore-streaming-api))

;;; --- Summary --------------------------------------------------------

(format t "~%~D tests, ~D passed, ~D failed~%"
        *tests-run* *tests-passed* *tests-failed*)

(if (= *tests-failed* 0)
    (format t "~%ALL PASSED~%")
    (progn
      (format *error-output* "~%FAILED~%")
      (sb-ext:exit :code 1)))
