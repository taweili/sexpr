;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/transcript.lisp — the transcript data model and its serialization.
;;;;
;;;; Scope: events are typed plists, append preserves order, rendering is
;;;; readable, and the transcript round-trips through print/read with
;;;; *read-eval* nil. A result event carries the live object AND the printed
;;;; projection captured at record time (R023); serialization drops the live
;;;; object, so only the projection can be read back. Nothing here talks to a
;;;; model.

(in-package :sexpr-tests)

(rove:deftest transcript-is-empty-at-birth
  (let ((tr (make-transcript)))
    (ok (empty-p tr) "a fresh transcript holds no events")
    (ok (zerop (transcript-length tr)) "length is zero")
    (ok (null (transcript-anchors tr)) "compaction anchors are empty (deferred)")
    (ok (zerop (hash-table-count (transcript-objects tr)))
        "presentation registry is empty (deferred)")))

(rove:deftest append-event-preserves-order
  (let ((tr (make-transcript))
        (user-event (make-user-event "fix the bug in parser.lisp"))
        (model-event (make-model-event "ok" :model "gpt-4o-mini" :finish :stop))
        (result-event (make-result-event "patched")))
    (progn
      (append-event tr user-event)
      (append-event tr model-event)
      (append-event tr result-event))
    (ok (= (transcript-length tr) 3) "three events recorded")
    (ok (equalp (aref (transcript-events tr) 0) user-event) "oldest is first")
    (ok (equalp (aref (transcript-events tr) 2) result-event) "newest is last")
    (ok (= (length (events-list tr)) 3) "events-list agrees with the vector")
    (ok (eq (second (events-list tr)) model-event)
        "events-list returns the event objects, not copies")))

(rove:deftest events-are-typed-plists-not-strings
  (let ((user-event (make-user-event "hello"))
        (model-event (make-model-event
                       "hi"
                       :tool-calls '((:id "1" :name "edit-file" :arguments "x"))
                       :model "gpt-4o-mini"
                       :usage (list :input-tokens 3 :output-tokens 2)
                       :finish :stop)))
    (ok (listp user-event) "an event is a list, not a string")
    (ok (eq (event-type user-event) :user) "user event is typed :user")
    (ok (string= (event-content user-event) "hello") "user content is readable")
    (ok (eq (event-type model-event) :model) "model event is typed :model")
    (ok (eq (event-model model-event) "gpt-4o-mini") "model id round-trips")
    (ok (eq (event-finish model-event) :stop) "finish reason round-trips")
    (ok (evenp (length (event-usage model-event)))
        "a usage plist is an even-length list of pairs")
    (ok (= (length (event-tool-calls model-event)) 1)
        "model event carries :tool-calls from day one (shaped for the tools milestone)")))

(rove:deftest map-events-yields-oldest-first
  (let ((tr (make-transcript)))
    (progn
      (append-event tr (make-user-event "a"))
      (append-event tr (make-model-event "b" :finish :stop))
      (append-event tr (make-user-event "c")))
    (ok (equal (map-events #'event-content tr) '("a" "b" "c"))
        "map-events walks the log oldest first")))

(rove:deftest render-events-produces-a-readable-log
  (let ((tr (make-transcript)))
    (progn
      (append-event tr (make-user-event "fix the bug"))
      (append-event tr (make-model-event
                          "done"
                          :model "gpt-4o-mini"
                          :tool-calls '((:id "1" :name "edit-file" :arguments "x"))
                          :finish :stop)))
    (let ((rendered (render-events tr)))
      (ok (stringp rendered) "render-events returns a string")
      (ok (search "#0<user>" rendered) "the first line is numbered and typed")
      (ok (search "#1<model>" rendered) "the second line is numbered and typed")
      (ok (search "fix the bug" rendered) "user content appears")
      (ok (search "[gpt-4o-mini]" rendered) "the model id appears")
      (ok (search "(+1 tool-calls)" rendered) "the tool-call count is noted"))))

(rove:deftest render-event-omits-absent-tool-calls
  (let ((rendered (render-event (make-model-event "done" :model "m" :finish :stop))))
    (ok (search "[m] done" rendered) "model id and content render")
    (ok (not (search "NIL" rendered))
        "a model event with no tool calls renders no NIL placeholder")))

(rove:deftest render-event-shows-a-result-value
  (ok (string= (render-event (make-result-event (list 1 2 3))) "(1 2 3)")
      "a result renders its live value"))

(rove:deftest make-result-event-keeps-the-object-and-its-text
  "R023: a result event holds the live object and the printed projection, and
the projection is captured at record time, not re-derived at render time."
  (let ((table (make-hash-table :test 'eql)))
    (let ((event (make-result-event table)))
      (ok (eq (event-value event) table) "the live object is held, not copied")
      (ok (stringp (event-text event)) "the projection is a string")
      (ok (string= (event-text event) (format nil "~A" table))
          "the default projection is the printed value"))
    (ok (string= (event-text (make-result-event "patched")) "patched")
        "a string value prints bare — the projection is not a read form")
    (ok (string= (event-text (make-result-event (list 1 2 3))) "(1 2 3)")
        "a list value prints in readable form")
    (ok (string= (event-text (make-result-event "42" :text "explicit")) "explicit")
        "an explicit :text wins over the default")))

(rove:deftest render-event-uses-text-for-results
  "Human rendering reads the projection recorded at record time, so a result
still renders after its live object has been dropped by serialization."
  (ok (string= (render-event (make-result-event (list 1 2 3))) "(1 2 3)")
      "the default projection renders, agreeing with the existing rendering")
  (ok (string= (render-event (make-result-event "patched" :text "patched by tool"))
               "patched by tool")
      "render-event shows the recorded text, not a re-derived print")
  (ok (string= (render-event (list :type :result :text "the printed form"))
               "the printed form")
      "a result event read back with no live :value still renders"))

;;;; --- serialization --------------------------------------------------

(rove:deftest transcript-round-trips-through-print-and-read
  (let ((tr (make-transcript)))
    (progn
      (append-event tr (make-user-event "fix the bug in parser.lisp"))
      (append-event tr (make-model-event
                          "ok"
                          :model "gpt-4o-mini"
                          :tool-calls '((:id "1" :name "edit-file" :arguments "x"))
                          :usage (list :input-tokens 42 :output-tokens 7)
                          :finish :stop))
      (append-event tr (make-result-event (list :patched t))))
    (let* ((form (write-transcript tr))
           (back (read-transcript-from-string form)))
      (ok (= (transcript-length back) 3) "all events survive the round trip")
      (ok (equalp (event-content (aref (transcript-events back) 0))
                  "fix the bug in parser.lisp")
          "content round-trips as a string")
      (ok (eq (event-type (aref (transcript-events back) 0)) :user)
          "event types round-trip as keywords, not strings")
      (ok (eq (event-finish (aref (transcript-events back) 1)) :stop)
          "the finish reason round-trips as a keyword")
      (ok (equal (event-usage (aref (transcript-events back) 1))
                 (list :input-tokens 42 :output-tokens 7))
          "the usage plist round-trips with its numbers")
      (ok (null (transcript-anchors back)) "anchors are not serialized yet")
      (ok (zerop (hash-table-count (transcript-objects back)))
          "the presentation registry is not serialized yet"))))

(rove:deftest result-event-round-trips-with-the-live-object-dropped
  "R023 serialization half: the projection survives, the live object does not.
A hash table has no readable print form (SBCL writes it as #.(MAKE-HASH-TABLE)
or #<HASH-TABLE ...>), so the live object must be dropped at serialize time
instead of emitted as a token the reader would refuse under *read-eval* nil.
This group is red before the strip: the pre-fix form carries that token and
cannot be read back."
  (let ((tr (make-transcript))
        (table (make-hash-table :test 'eql)))
    (append-event tr (make-user-event "hello"))
    (append-event tr (make-result-event table))
    (let* ((live-event (aref (transcript-events tr) 1))
           (form (write-transcript tr))
           (back (handler-case (read-transcript-from-string form) (error () nil))))
      (ok back "the form reads back — no unreadable object print token")
      (ok (not (search "#." form))
          "no read-time eval escape is emitted for the live object")
      (ok (not (search ":VALUE" form)) "the live-object key is dropped from the form")
      (ok (search ":TEXT" form) "the projection is what the form carries")
      (when back
        (let ((back-event (aref (transcript-events back) 1)))
          (ok (eq (event-type back-event) :result) "the event type survives")
          (ok (null (event-value back-event)) "the live object is dropped")
          (ok (string= (event-text back-event) (event-text live-event))
              "the printed projection survives the round trip")))
      (ok (eq (event-value live-event) table)
          "the live event still holds the object — serialization never mutates it"))))

(rove:deftest read-transcript-keeps-escapes-in-strings-inert
  "The realistic case: content is always a string, so a #. or #, inside it is
inert data. It must survive verbatim and never execute."
  (let ((tr (make-transcript)))
    (progn
      (append-event tr (make-user-event "#.(format t \"hello\")"))
      (append-event tr (make-model-event "#, (setf x 1)" :finish :stop))
      (append-event tr (make-user-event "#P user")))
    (let ((back (read-transcript-from-string (write-transcript tr))))
      (ok (string= (event-content (aref (transcript-events back) 0))
                   "#.(format t \"hello\")")
          "a #. inside a string is data, not a form")
      (ok (string= (event-content (aref (transcript-events back) 1))
                   "#, (setf x 1)")
          "a #, inside a string is data, not a form")
      (ok (equalp (events-list back)
                  (list (make-user-event "#.(format t \"hello\")")
                        (make-model-event "#, (setf x 1)" :finish :stop)
                        (make-user-event "#P user")))
          "all escape-looking strings survive verbatim"))))

(defvar *t03-flag* nil
  "Sentinel flipped only if an embedded reader escape is ever evaluated.")

(defun t03-flip-flag ()
  "A read-time payload: sets *t03-flag*. Must never be called during a read."
  (setf *t03-flag* t))

(rove:deftest read-transcript-refuses-embedded-reader-escapes
  "Defense in depth: when an event field is itself a *form* containing a #.
escape it must be refused, not executed — even though today every event field
is a string."
  (setf *t03-flag* nil)
  (let ((form "(#.(t03-flip-flag) :x)"))
    (ok (search "#." form) "the fixture really does contain a #. escape")
    (handler-case
        (read-transcript-from-string form)
      (error ()
        (ok t "an embedded #. escape is refused rather than run")))
    (ok (null *t03-flag*) "the embedded form never executed")))

(rove:deftest transcript-from-list-rejects-wrong-forms
  (ok (signals (transcript-from-list '(1 2 3))) "a bare list is refused")
  (ok (signals (transcript-from-list nil)) "nil is refused")
  (ok (signals (transcript-from-list '(:other ()))) "a wrong tag is refused")
  (ok (signals (transcript-from-list "not a list")) "a string is refused"))

(rove:deftest print-and-read-transcript-agree-over-a-stream
  "print-transcript writes to a stream, read-transcript reads a stream back.
The pair is what makes a transcript persist to disk and resume exactly."
  (let ((tr (make-transcript)))
    (progn
      (append-event tr (make-user-event "hello"))
      (append-event tr (make-model-event "hi" :model "m1" :finish :stop)))
    (let ((out (make-string-output-stream))
          back)
      (progn
        (print-transcript tr out)
        (setf back (read-transcript
                     (make-string-input-stream
                       (get-output-stream-string out)))))
      (ok (= (transcript-length back) 2) "both events read back from the stream")
      (ok (string= (event-content (aref (transcript-events back) 0)) "hello")
          "the first event's content survives")
      (ok (eq (event-finish (aref (transcript-events back) 1)) :stop)
          "the second event's finish reason survives"))))
