;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr.sandbox — the restricted-read eval sandbox.
;;;;
;;;; DESIGN (notes/sexpr.md §6, R021): the sandbox turns untrusted
;;;; model-emitted text into a read form under a restricted readtable
;;;; (sharp-dot / sharp-S / sharp-C refused) and evaluates it inside a
;;;; locked scratch package under a wall-clock timeout. It owns its own
;;;; condition taxonomy (read-refusal / eval-refusal / timeout-refusal)
;;;; so a later caller can record a refusal as a machine-readable reason.
;;;;
;;;; BOUNDARY: this package never names the provider transport. The
;;;; sandbox is read/eval infrastructure only — it has no :use of
;;;; :sexpr.provider and reaches nothing on the network. There is
;;;; exactly zero seam to the world here: the model's text arrives as a
;;;; string, the form leaves as a value or a refusal condition, and no
;;;; transport type is mentioned in this directory (invariant R015 — the
;;;; seam is a literal-token scan, and src/sandbox/ is absence-checked).

(defpackage :sexpr.sandbox
  (:nicknames :$.sandbox)
  (:use :cl)
  ;; read-from-string, copy-readtable, and set-dispatch-macro-character
  ;; all have CL namesakes inherited via (:use :cl); eclector's are
  ;; distinct symbols, so they must be SHADOWING-imported or defpackage
  ;; signals a NAME-CONFLICT. call-with-state-value and *client* have no
  ;; CL counterpart, so a plain :import-from suffices for them.
  (:shadowing-import-from :eclector.reader
                          #:read-from-string)
  (:import-from :eclector.reader
                #:call-with-state-value
                #:*client*)
  (:shadowing-import-from :eclector.readtable
                          #:copy-readtable
                          #:set-dispatch-macro-character)
  (:export
   ;; condition taxonomy
   #:read-refusal
   #:read-refusal-text
   #:read-refusal-reason
   #:eval-refusal
   #:eval-refusal-form
   #:eval-refusal-reason
   #:eval-refusal-error
   #:timeout-refusal
   #:timeout-seconds
   ;; public API
   #:make-sandbox
   #:lock-sandbox
   #:read-sandboxed-form
   ;; eval-in-sandbox is defined in S04-T02; exporting it now keeps the
   ;; package stable across tasks (exporting an unbound symbol is valid CL).
   #:eval-in-sandbox))
