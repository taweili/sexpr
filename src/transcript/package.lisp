;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.transcript — the transcript as a first-class object.
;;;;
;;;; DESIGN (notes/sexpr.md §1.2): "The transcript is a first-class persistent
;;;; object... Events are not strings: (user "fix the bug in parser.lisp"),
;;;; (model (:thought …) (:call (edit-file …))), (result #<file-buffer …>)."
;;;;
;;;; BOUNDARY: this package owns the transcript data model and its human-facing
;;;; rendering only. It imports no external system — the transcript is an
;;;; ordinary CL structure. Serialization (print/read with *read-eval* nil) and
;;;; the model-facing token-budgeted renderer (notes/sexpr.md §4, :view :model)
;;;; are not mixed in here.

(defpackage :sexpr.transcript
  (:nicknames :$.transcript)
  (:use :cl)
  (:export
   #:transcript
   #:transcript-events
   #:transcript-anchors
   #:transcript-objects
   #:make-transcript
   #:transcript-length
   #:empty-p
   #:append-event
   #:events-list
   #:map-events
   #:render-event
   #:render-events
   #:transcript-to-list
   #:transcript-from-list
   #:print-transcript
   #:read-transcript
   #:write-transcript
   #:read-transcript-from-string
   #:make-user-event
   #:make-model-event
   #:make-result-event
   #:event-type
   #:event-content
   #:event-tool-calls
   #:event-model
   #:event-usage
   #:event-finish
   #:event-value
   #:+event-type-user+
   #:+event-type-model+
   #:+event-type-result+))
