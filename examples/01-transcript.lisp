#| 01-transcript.lisp — The transcript: events as first-class objects.

The transcript is sexpr's core state object: a chronological log of typed
events (user, model, result). Events are plists that round-trip through
print/read, so the whole transcript is an s-expression.

Run:
  sbcl --load ~/.sbclinit --load examples/01-transcript.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))

(ql:quickload "sexpr")

(in-package :sexpr.transcript)

(format t "=== 01-transcript.lisp ===~%")
(format t "~%")

;; 1. Create an empty transcript
(format t "-- Create an empty transcript --~%")
(let ((tr (make-transcript)))
  (format t "empty-p: ~a~%" (empty-p tr))
  (format t "transcript-length: ~a~%" (transcript-length tr)))

;; 2. Append user, model, and result events
(format t "~%-- Append events --~%")
(let ((tr (make-transcript)))
  (append-event tr (make-user-event "Hello, agent!"))
  (append-event tr (make-model-event "Hello! How can I help?"
                                      :model "Qwythos-9B-v2"
                                      :finish :stop))
  (append-event tr (make-result-event 42))
  (format t "transcript-length: ~a~%" (transcript-length tr))
  (format t "empty-p: ~a~%" (empty-p tr)))

;; 3. Render events for human inspection
(format t "~%-- Render events --~%")
(let ((tr (make-transcript)))
  (append-event tr (make-user-event "What is 2+2?"))
  (append-event tr (make-model-event "2+2 = 4"
                                      :model "Qwythos-9B-v2"
                                      :finish :stop))
  (append-event tr (make-result-event
                    (list :stdout "4" :stderr "" :exit-code 0)))
  (format t "~a" (render-events tr)))

;; 4. Serialize and deserialize (the s-expression round trip)
(format t "~%-- Serialize / deserialize round trip --~%")
(let ((tr (make-transcript)))
  (append-event tr (make-user-event "Save this session"))
  (append-event tr (make-model-event "Done."
                                      :model "Qwythos-9B-v2"
                                      :finish :stop))
  (let ((s-expr (write-transcript tr)))
    (format t "Serialized:~%~a~%" s-expr)
    (let ((tr2 (read-transcript-from-string s-expr)))
      (format t "Deserialized length: ~a~%" (transcript-length tr2))
      (format t "~%Restored transcript:~%~a" (render-events tr2)))))

;; 5. Map over events
(format t "~%-- Map over events --~%")
(let ((tr (make-transcript)))
  (append-event tr (make-user-event "first"))
  (append-event tr (make-user-event "second"))
  (append-event tr (make-user-event "third"))
  (format t "Event types: ~a~%"
          (map-events #'event-type tr))
  (format t "Event contents: ~a~%"
          (map-events #'event-content tr)))

(format t "~%=== done ===~%")
