;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; sexpr.sandbox — the restricted-read eval sandbox (read path).
;;;;
;;;; This file implements the sandbox: a restricted eclector readtable
;;;; (sharp-S / sharp-C disabled, sharp-dot blocked by *read-eval* nil),
;;;; a locked scratch package for eval, a wall-clock timeout around the
;;;; eval, and a process-wide lock on :sexpr.kernel at load time. It
;;;; owns the condition taxonomy the sandbox reports through.
;;;;
;;;; BOUNDARY / HONESTY LIMIT (R021 — "soft-but-honest"):
;;;;   what the sandbox DOES stop:
;;;;     * reader-escape macros: #. (via *read-eval* nil), #S, #C;
;;;;     * read-time intern into a locked package (sandbox or
;;;;       :sexpr.kernel); both signal cl/sb-ext:package-locked-error,
;;;;       which read-sandboxed-form wraps as read-refusal;
;;;;     * eval-time intern into a locked package (a form like
;;;;       (defun foo ...) that would create a new symbol is refused at
;;;;       eval via eval-refusal; the class is preserved in :error);
;;;;     * writes into :sexpr.kernel (locked at load time; the lock is
;;;;       process-wide, so nothing — test fixtures, dispatch, model
;;;;       code, or the sandbox itself — can intern into it or write
;;;;       definitions into it).
;;;;   what the sandbox does NOT stop:
;;;;     * sb-ext, run-program, UIOP/filesystem access — those packages
;;;;       are not locked and the sandbox does not lock them. A form
;;;;       like (sb-ext:invoke-function (sb-ext:make-fun-lock nil))
;;;;       would run with full privileges inside eval-in-sandbox.
;;;;   v1 does not overclaim "no code can escape", only
;;;;   "no reader escapes, no new symbols in locked packages, no writes
;;;;   into :sexpr.kernel". This is a documented v1 trade-off, not a
;;;;   bug. The BOUNDARY note in package.lisp restates the R015 seam
;;;;   rule (this directory never names the provider transport).

(in-package :sexpr.sandbox)

;;;; --- condition taxonomy -------------------------------------------
;;;;
;;;; Three refusal conditions, each carrying a machine-readable :reason
;;;; (and eval-refusal carrying the original :error), so a later caller
;;;; (S05's lisp tool) can record a refusal result event with a reason
;;;; symbol rather than only a string. Nothing observes these yet in
;;;; this slice — the sandbox owns its own condition taxonomy and no
;;;; dispatch wires it up until S05.

(define-condition read-refusal (error)
  ((text
    :initarg :text
    :reader read-refusal-text
    :documentation "The input string that read refused.")
   (reason
    :initarg :reason
    :reader read-refusal-reason
    :documentation "A symbol naming why the read was refused:
:read-eval (#. blocked by *read-eval* nil), :sharp-s, :sharp-c,
:package-locked (intern into a locked package at read time),
:end-of-file, or :reader-error (anything else)."))
  (:report (lambda (condition stream)
             (format stream "read refused (~a): ~a"
                     (read-refusal-reason condition)
                     (read-refusal-text condition))))
  (:documentation
   "Signalled when read-sandboxed-form refuses an input. The :reason
slot is a symbol so a caller can switch on it rather than parsing a
string."))

(define-condition eval-refusal (error)
  ((form
    :initarg :form
    :reader eval-refusal-form
    :documentation "The form that eval refused.")
   (reason
    :initarg :reason
    :reader eval-refusal-reason
    :documentation "A symbol naming why eval refused; by convention the
TYPE-OF of the original error (e.g. UNBOUND-SYMBOL,
PACKAGE-LOCKED-ERROR).")
   (error
    :initarg :error
    :reader eval-refusal-error
    :documentation "The original error condition that eval-in-sandbox
caught, preserved for callers that want to inspect it."))
  (:report (lambda (condition stream)
             (format stream "eval refused (~a): ~s"
                     (eval-refusal-reason condition)
                     (eval-refusal-form condition))))
  (:documentation
   "Signalled when eval-in-sandbox refuses a form. Defined here so the
taxonomy is complete; signalled by eval-in-sandbox (S04-T02)."))

(define-condition timeout-refusal (error)
  ((seconds
    :initarg :seconds
    :reader timeout-seconds
    :documentation "The wall-clock seconds budget that elapsed before
sb-ext:with-timeout cut the form off."))
  (:report (lambda (condition stream)
             (format stream "eval timed out after ~a second~:p"
                     (timeout-seconds condition))))
  (:documentation
   "Signalled when sb-ext:with-timeout fires inside eval-in-sandbox.
Defined here so the taxonomy is complete; signalled by eval-in-sandbox
(S04-T02). The underlying condition is sb-ext:timeout."))

;;;; --- restricted readtable -----------------------------------------
;;;;
;;;; eclector.reader:*readtable* is the standard readtable in effect.
;;;; We copy it and rebind the #S and #C dispatch macros to signalers.
;;;; #. (sharp-dot) needs no readtable entry: eclector's sharpsign-dot
;;;; checks the *read-eval* state value and signals
;;;; read-time-evaluation-inhibited when it is nil (verified live in
;;;; SBCL 2.6.8, eclector 20260101-git).

(defun make-restricted-readtable ()
  "Return a fresh eclector readtable copy with the #S and #C dispatch
macros rebound to error signalers. #. is handled by *read-eval* nil,
not by a readtable entry, so it is not rebound here."
  (let ((rt (copy-readtable eclector.reader:*readtable*)))
    (set-dispatch-macro-character
     rt #\# #\s
     (lambda (stream char parameter)
       (declare (ignore stream char parameter))
       (error "sharp-S reader macro is disabled")))
    (set-dispatch-macro-character
     rt #\# #\c
     (lambda (stream char parameter)
       (declare (ignore stream char parameter))
       (error "sharp-C reader macro is disabled")))
    rt))

;;;; --- read-sandboxed-form ------------------------------------------
;;;;
;;;; eclector.reader:*read-eval* is NOT exported from :eclector.reader,
;;;; so a plain (let ((eclector.reader:*read-eval* nil)) …) does not
;;;; compile (the reader rejects the unqualified reference). The state
;;;; is bound instead through eclector's call-with-state-value protocol:
;;;; each call-with-state-value rebinds one reader aspect for the
;;;; dynamic extent of its thunk. The aspect symbols (*read-eval*,
;;;; *readtable*, *read-suppress*) are COMMON-LISP symbols — eclector
;;;; registers its aspects under exactly those, so writing them in a
;;;; package that :use :cl is correct (verified live). The *readtable*
;;;; aspect binds eclector.reader:*readtable* (eclector's own readtable
;;;; variable), distinct from the common-lisp:*readtable* key.

(defun read-sandboxed-form (text &optional readtable)
  "Read one s-expression from TEXT under a restricted readtable with
*read-eval* nil, returning the form, or signal READ-REFUSAL.

Refuses, with a machine-readable :reason slot:
  * #. read-time evaluation   — :read-eval
  * #S structure literals     — :sharp-s
  * #C complex constructors   — :sharp-c
  * intern into a locked      — :package-locked
    package (the reader interns while *package* is a locked sandbox)
  * end of input              — :end-of-file
  * anything else             — :reader-error

READTABLE, when supplied, replaces the default restricted readtable
(one caller may compose its own). The *read-eval* nil and
*read-suppress* nil bindings are always applied regardless of
READTABLE."
  (handler-case
      (call-with-state-value
       *client*
       (lambda ()
         (call-with-state-value
          *client*
          (lambda ()
            (call-with-state-value
             *client*
             (lambda ()
               (read-from-string text))
             '*read-eval* nil))
          '*readtable* (or readtable (make-restricted-readtable))))
       '*read-suppress* nil)
    ;; Order matters: eclector and CL specific conditions first, then
    ;; simple-error (the disabled-macro signalers), then a catch-all.
    ;; package-locked-error is sb-ext:package-locked-error in this SBCL
    ;; (NOT a common-lisp symbol — package locks are an SBCL extension).
    (eclector.reader:read-time-evaluation-inhibited ()
      (error 'read-refusal :text text :reason :read-eval))
    (sb-ext:package-locked-error ()
      (error 'read-refusal :text text :reason :package-locked))
    (end-of-file ()
      (error 'read-refusal :text text :reason :end-of-file))
    (simple-error (e)
      ;; The disabled #S / #C macros signal a simple-error whose
      ;; format-control names the macro; distinguish them so a caller
      ;; can read :reason. Any other simple-error falls back to
      ;; :reader-error — still a refusal, still machine-readable.
      (let ((control (simple-condition-format-control e)))
        (error 'read-refusal
               :text text
               :reason (cond
                         ((and (stringp control)
                               (search "sharp-S" control))
                          :sharp-s)
                         ((and (stringp control)
                               (search "sharp-C" control))
                          :sharp-c)
                         (t
                          :reader-error)))))
    (error ()
      (error 'read-refusal :text text :reason :reader-error))))

;;;; --- sandbox packages ---------------------------------------------
;;;;
;;;; A sandbox is a fresh package that :use :cl. The caller locks it
;;;; before eval so a form referencing an unknown symbol interns into
;;;; the locked package and is refused at read time (package-locked-error
;;;; → read-refusal). make-sandbox returns an UNLOCKED package; lock it
;;;; with lock-sandbox when the curated surface is ready.

(defun make-sandbox (&optional (name (gensym "SANDBOX-")))
  "Return a fresh, unlocked package named NAME that (:use :cl).
CL's exports are the only surface the model may reach by default;
additional symbols would be interned-and-exported by the caller before
locking. The caller MUST call lock-sandbox before eval."
  (make-package name :use '(:cl)))

(defun lock-sandbox (package)
  "Lock PACKAGE via sb-ext:lock-package and return PACKAGE. Re-locking
is idempotent in SBCL, so reloads and double-locks are safe."
  (sb-ext:lock-package package)
  package)

;;;; --- eval-in-sandbox ----------------------------------------------
;;;;
;;;; The eval half of the sandbox: bind *package* to the caller's
;;;; locked sandbox, evaluate FORM inside a wall-clock timeout, and
;;;; translate the resulting condition into the sandbox's own taxonomy.
;;;;
;;;; SANDBOXING TRADE-OFF (R021, honest): CL's EVAL compiles the form
;;;; into a scratch lexenv at eval time — the form gets a real compiled
;;;; function, so it can reach anything the calling image's reader can
;;;; reach (sb-ext, run-program, filesystem, network). Package locks
;;;; stop intern into :sexpr.kernel and the sandbox package, but they
;;;; do not stop code from *calling* arbitrary global functions. This
;;;; is documented as a v1 trade-off, not a bug. The BOUNDARY comment
;;;; at the top of this file names the limits.

(defun eval-in-sandbox (form sandbox &key (seconds 5.0))
  "Evaluate FORM inside the SANDBOX package under a wall-clock timeout
of SECONDS seconds, returning the value on success.

Signalled conditions:
  * TIMEOUT-REFUSAL    — sb-ext:with-timeout fired; the form was
                         cut off at SECONDS seconds.
  * EVAL-REFUSAL       — the form signalled any other error; :form is
                         FORM, :reason is (TYPE-OF e) (e.g.
                         UNDEFINED-FUNCTION, PACKAGE-LOCKED-ERROR),
                         and :error is the original condition.

SANDBOX is the caller's sandbox package — the caller is responsible
for calling lock-sandbox first if they want read-time intern refusal.

Note: EVAL compiles FORM into a scratch lexenv, so the form can call
any function the calling image can reach. Package locks only stop
new symbol interning into the sandbox / :sexpr.kernel — they do not
stop calls into sb-ext or the filesystem. This is the documented v1
trade-off (see R021 above)."
  (let ((*package* sandbox))
    (handler-case
        (sb-ext:with-timeout seconds (eval form))
      (sb-ext:timeout ()
         (error 'timeout-refusal :seconds seconds))
      (error (e)
         (error 'eval-refusal
                :form form
                :reason (type-of e)
                :error e)))))

;;;; --- :sexpr.kernel load-time lock --------------------------------
;;;;
;;;; The milestone criterion "after loading, :sexpr.kernel is locked"
;;;; (and "(defun sexpr.kernel:foo) from a fixture fails") needs a
;;;; process-wide lock on :sexpr.kernel that takes effect as soon as
;;;; the sandbox module is loaded. :sexpr.kernel exists by then
;;;; (asd: :module "sandbox" :depends-on ("package" "kernel")), but
;;;; the guard is cheap robustness — some test harnesses may load in a
;;;; different order.
;;;
;;;; Package locks are PROCESS-WIDE: once :sexpr.kernel is locked,
;;;; nothing in this image can intern a new symbol into it. Reloads
;;;; are safe: sb-ext:lock-package is idempotent in SBCL (re-locking
;;;; a locked package is a no-op).
;;;
;;;; This is a HARD limit — the whole image is affected. T03's tests
;;;; must not write `'(defun sexpr.kernel:foo () 42)` as a literal
;;;; (reading it interns FOO into the now-locked :sexpr.kernel and
;;;; breaks test-file compilation). T03 asserts the lock via direct
;;;; (intern ...) and via eval-ing a defun that redefines an EXISTING
;;;; kernel export (e.g. budget).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :sexpr.kernel)
    (sb-ext:lock-package :sexpr.kernel)))
