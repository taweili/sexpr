;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.transcript — the transcript as a first-class object.
;;;;
;;;; DESIGN (notes/sexpr.md §1.2): the transcript is a persistent,
;;;; first-class object holding *events, not strings:
;;;;   (user "fix the bug in parser.lisp")
;;;;   (model (:thought …) (:call (edit-file …)))
;;;;   (result #<file-buffer …>)
;;;; "Serialization = print/read" — so the whole transcript round-trips as an
;;;; s-expression. Compaction (GC over events) and the presentation registry are
;;;; slots the class carries today but does not yet use; they are the core
;;;; differentiator (notes/sbcl-libs.md §11 gap #5) and land in a later
;;;; milestone.
;;;;
;;;; BOUNDARY: this package owns the data model and human-facing rendering only.
;;;; It imports no external system — no alexandria, no alexandria in :use
;;;; (AGENT.md convention), no LLM provider. Serialization lives here too but
;;;; binds *read-eval* nil; the eventual safe reader for untrusted model output
;;;; is eclector (notes/sbcl-libs.md §5, gap #3), deliberately not depended on.

(in-package :sexpr.transcript)

;;;; --- event kinds ----------------------------------------------------

(defconstant +event-type-user+   :user
  "Event kind: the human (or a supervisor agent) said something.")
(defconstant +event-type-model+  :model
  "Event kind: the model responded.")
(defconstant +event-type-result+ :result
  "Event kind: a tool, or the world, returned a value.")

;;;; --- events ---------------------------------------------------------
;;;;
;;;; Events are plists, not defstructs and not raw strings. Two reasons: they
;;;; must round-trip through print/read unchanged, and a plist is the cheapest
;;;; structure that does so. Model events carry the :tool-calls key from the
;;;; first day even though tool execution is deferred — the seam already has the
;;;; room, so downstream milestones (tools §1.3, capabilities §5) extend it
;;;; instead of rewriting it.

(defun event-type (event)
  "Return the :type key of EVENT (:user, :model, or :result)."
  (getf event :type))
(export 'event-type)

(defun event-content (event)
  "Return the :content key of EVENT — user or model text — or NIL."
  (getf event :content))
(export 'event-content)

(defun event-tool-calls (event)
  "Return the :tool-calls key of a model event: a list of
(:id .. :name .. :arguments ..) plists, or NIL.

Recorded, not executed, in this milestone."
  (getf event :tool-calls))
(export 'event-tool-calls)

(defun event-model (event)
  "Return the :model key of a model event (the provider's model id), or NIL."
  (getf event :model))
(export 'event-model)

(defun event-usage (event)
  "Return the :usage key of a model event (a provider-shaped plist), or NIL."
  (getf event :usage))
(export 'event-usage)

(defun event-finish (event)
  "Return the :finish key of a model event (e.g. :stop, :length), or NIL."
  (getf event :finish))
(export 'event-finish)

(defun event-value (event)
  "Return the :value key of a result event — the live object, not its string —
or NIL."
  (getf event :value))
(export 'event-value)

(defun make-user-event (content)
  "Build a user event wrapping CONTENT (a string).

CONTENT is stored as data and never evaluated; see the file header for the
reader-safety boundary."
  (list :type +event-type-user+ :content content))
(export 'make-user-event)

(defun make-model-event (content &key tool-calls model usage finish)
  "Build a model event from the fields of a sexpr.provider:provider-call node.

KEYWORD arguments mirror the provider-call return shape
(:content / :tool-calls / :model / :usage / :finish) one-for-one, so the
kernel's conversion stays a straight copy with no knowledge of the transport."
  (list :type +event-type-model+
        :content content
        :tool-calls tool-calls
        :model model
        :usage usage
        :finish finish))
(export 'make-model-event)

(defun make-result-event (value)
  "Build a result event wrapping VALUE.

VALUE is the live object (a buffer, a hash table, an AST), not its printed
form — the transcript holds references, which is the whole point of §1.2."
  (list :type +event-type-result+ :value value))
(export 'make-result-event)

;;;; --- the transcript -------------------------------------------------

(defclass transcript ()
  ((events
    :initform (make-array 16 :adjustable t :element-type 'list :fill-pointer 0)
    :accessor transcript-events
    :type (vector list *)
    :documentation "The event log: an adjustable vector of event plists in
chronological order. This is the nursery — the recent, uncompressed window.")
   (anchors
    :initform '()
    :accessor transcript-anchors
    :type list
    :documentation "Compaction anchors, oldest first. Present but unused this
milestone: §1.2 makes compaction GC over events, and the compactor is a later
milestone. The slot exists now so the class shape is fixed before instances are
live.")
   (objects
    :initform (make-hash-table :test 'equal)
    :accessor transcript-objects
    :type hash-table
    :documentation "The presentation registry: object-id -> live object. Present
but unused this milestone — presentations (§4) land later, and a
trivial-garbage weak table is the intended backing so dead objects stop holding
the registry open."))
  (:documentation "A transcript: the chronological log of one agent's
conversation, holding typed events — not strings.

The image is the state (notes/sexpr.md §0); the transcript is its conversation
slice. Events are plists so the whole transcript round-trips through print/read."))
(export 'transcript)

(defun make-transcript ()
  "Return a fresh, empty transcript."
  (make-instance 'transcript))
(export 'make-transcript)

(defun transcript-length (transcript)
  "Return the number of events in TRANSCRIPT."
  (length (transcript-events transcript)))
(export 'transcript-length)

(defun empty-p (transcript)
  "Return T when TRANSCRIPT holds no events."
  (zerop (transcript-length transcript)))
(export 'empty-p)

;;;; --- operations -----------------------------------------------------

(defun append-event (transcript event)
  "Append EVENT to the end of TRANSCRIPT's log and return EVENT."
  (vector-push-extend event (transcript-events transcript))
  event)
(export 'append-event)

(defun events-list (transcript)
  "Return TRANSCRIPT's events as a list, oldest first."
  (let ((events (transcript-events transcript)))
    (loop for i below (length events) collect (aref events i))))
(export 'events-list)

(defun map-events (fn transcript)
  "Return a list of (FUNCALL FN event) over TRANSCRIPT's events, oldest first."
  (mapcar fn (events-list transcript)))
(export 'map-events)

;;;; --- human-facing rendering -----------------------------------------
;;;;
;;;; Inspection output only. The model-facing, token-budgeted renderer
;;;; (notes/sexpr.md §4, :view :model) is a later milestone.

(defun render-event (event)
  "Return a one-line rendering of EVENT for human inspection."
  (case (event-type event)
    (:user
     (format nil "~a" (event-content event)))
    (:model
     (let ((calls (event-tool-calls event)))
       (format nil "[~a] ~a~a"
               (or (event-model event) "?")
               (or (event-content event) "")
               (if calls
                   (format nil " (+~a tool-calls)" (length calls))
                   ""))))
    (:result
     (format nil "~a" (event-value event)))
    (otherwise
     (format nil "~a" event))))
(export 'render-event)

(defun render-events (transcript)
  "Return a readable string of TRANSCRIPT's whole log, numbered oldest first."
  (let ((events (transcript-events transcript)))
    (with-output-to-string (s)
      (dotimes (i (length events))
        (let ((event (aref events i)))
          (format s "#~a<~a> ~a~%" i
                  (string-downcase (symbol-name (event-type event)))
                  (render-event event)))))))
(export 'render-events)

;;;; --- serialization --------------------------------------------------
;;;
;;;; DESIGN (notes/sexpr.md §1.2): "Serialization = print/read." The whole
;;;; transcript round-trips through s-expressions, so sessions persist to disk
;;;; and resume exactly.
;;;
;;;; SAFETY: read-transcript binds *read-eval* nil, so a #. / #, / #P escape
;;;; cannot execute while the transcript is being read back. In practice the
;;;; threat surface is small today — user and model content is always a string,
;;;; and escapes inside a string literal are inert characters — but the binding
;;;; is the load-bearing guarantee for the day an event carries a non-string
;;;; payload. Untrusted *model-emitted forms* (not just event fields) need
;;;; eclector's safe, customizable reader (notes/sbcl-libs.md §5, gap #3);
;;;; that is deliberately not depended on here, and that is the milestone that
;;;; adds it.

(defun transcript-to-list (transcript)
  "Return an s-expression form for TRANSCRIPT: a :transcript tag followed by
its events, oldest first.

Only the event log is serialized. Anchors and the presentation registry are
excluded on purpose: anchors are empty in this milestone, and the registry
holds live objects that print/read cannot reconstruct — presentations
(notes/sexpr.md §4) supply the rehydration story later."
  (append (list :transcript) (events-list transcript)))
(export 'transcript-to-list)

(defun transcript-from-list (data)
  "Return a transcript rebuilt from DATA, a form as produced by
transcript-to-list. Errors when DATA is not a transcript form."
  (unless (and (listp data) (eq (car data) :transcript))
    (error "Not a transcript form: ~S" data))
  (let ((transcript (make-transcript)))
    (dolist (event (cdr data))
      (append-event transcript event))
    transcript))
(export 'transcript-from-list)

(defun print-transcript (transcript &optional (stream *standard-output*))
  "Write an s-expression form of TRANSCRIPT to STREAM and return STREAM.

Written under with-standard-io-syntax so the output is stable regardless of
the caller's *print-case / *print-base settings."
  (with-standard-io-syntax
    (write (transcript-to-list transcript) :stream stream)
    (terpri stream))
  stream)
(export 'print-transcript)

(defun read-transcript (stream)
  "Read one s-expression from STREAM with *read-eval* nil and return the
transcript it denotes.

*read-eval* nil is the safety boundary: a #. or #, escape in the form signals
an error rather than running code. Failing closed is deliberate — a transcript
that will not read back faithfully should be loud, not silently corrupted."
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (transcript-from-list (read stream)))))
(export 'read-transcript)

(defun write-transcript (transcript)
  "Return TRANSCRIPT's s-expression form as a string, the input that
read-transcript-from-string consumes."
  (with-standard-io-syntax
    (with-output-to-string (s)
      (write (transcript-to-list transcript) :stream s)
      (terpri s))))
(export 'write-transcript)

(defun read-transcript-from-string (string)
  "Read a transcript from STRING with *read-eval* nil.

Paired with write-transcript: (read-transcript-from-string (write-transcript tr))
is the round trip."
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (transcript-from-list (read-from-string string)))))
(export 'read-transcript-from-string)
