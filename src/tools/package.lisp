;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.tools — the tool registry.
;;;;
;;;; DESIGN (notes/sexpr.md §1.3): a tool is a plain Lisp function wearing
;;;; metadata. The registry maps lowercase name strings to tool-record
;;;; plists; the model-visible schema is derived from the lambda list.
;;;;
;;;; BOUNDARY: no transport type is named here. Tool schemas are plain sexpr
;;;; data (plists of keywords, strings, and lists); conversion to the
;;;; transport's tool-definition happens in
;;;; sexpr.provider:translate-tool-schemas, the one function in the project
;;;; that names the transport type. This package :use:s :cl alone.
;;;;
;;;; NOTE: the transport library also exports DEFINE-TOOL — a different macro
;;;; that takes raw JSON schema plists, not a Lisp lambda list. The two are
;;;; not interchangeable and must never be :use'd together; this package
;;;; shadows nothing and imports nothing from the transport.

(defpackage :sexpr.tools
  (:nicknames :$.tools)
  (:use :cl)
  (:export
   #:define-tool
   #:derive-schema
   #:register-tool!
   #:find-tool
   #:all-tools
   #:tool-names
   #:apropos-tool
   #:tool-schema-list
   #:reset-tool-registry!
   #:*tool-registry*
   #:tool-error
   #:tool-error-tool
   #:tool-error-reason
   #:tool-error-detail
   #:check-capability
   #:validate-tool-arguments
   #:perform-tool))
