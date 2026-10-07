;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; builtins — the five registered tools.
;;;;
;;;; DESIGN (notes/sexpr.md §1.3, R025): a tool is a plain Lisp function
;;;; wearing metadata. The five built-ins — read-file, write-file, edit-file,
;;;; shell, lisp — are registered through the S02 registry (register-tool! +
;;;; derive-schema) so a model reply carrying a tool call dispatches against
;;;; a real filesystem, a real /bin/sh, or a real locked-package eval.
;;;;
;;;; THE FIVE BELONG HERE, NOT IN src/tools/: the ASDF orders tools before
;;;; sandbox, so a file in the tools module that names
;;;; sexpr.sandbox:make-sandbox would fail at READ time, not call time.
;;;; :module "builtins" :depends-on ("tools" "sandbox") is the ordering
;;;; that makes both names legal at read.
;;;;
;;;; REGISTRATION PATH: register-tool! + derive-schema, directly, not via
;;;; the define-tool macro. The macro's expansion runs once at file-load
;;;; time; a second call after reset-tool-registry! would not rebuild the
;;;; record. register-default-tools! is idempotent because reset-tool-registry!
;;;; drops the previous registrations and register-tool!'s collision guard
;;;; never fires on an empty registry.
;;;;
;;;; PACKAGE: :sexpr.tools. The built-ins are functions the registry knows
;;;; by name; they live in the same package as the registry so
;;;; register-tool! + derive-schema + find-tool resolve without qualification.
;;;; Do NOT put them in :sexpr.kernel — that package is locked process-wide
;;;; by S04, so a defun there would fail at load.
;;;;
;;;; BOUNDARY (R015): no transport type is named in this file. The five
;;;; return plain values (strings, plists); sexpr.provider owns the
;;;; translation to the transport's result shape.

(in-package :sexpr.tools)

;;;; --- read-file -----------------------------------------------------

(defun read-file (path)
  "Read the file at PATH and return its text contents.

A missing path signals an ordinary error (uiop:io-condition via
uiop:read-file-as-string); perform-tool lets it propagate and the kernel's
dispatch records a :body-error result event. Do NOT hand-roll the failure —
the error is the failure, and swallowing it here would make the model
unwilling to check that a file exists before it calls write-file or
edit-file."
  (with-open-file (s path :direction :input)
    (let ((data (make-string (file-length s))))
      (read-sequence data s)
      data)))

;;;; --- write-file ----------------------------------------------------

(defun write-file (path content)
  "Write the text CONTENT to the file at PATH, creating or truncating.

Returns a short confirmation string. Errors from the underlying
with-open-file (permission denied, read-only mount) propagate; the kernel
records them as :body-error events."
  (with-open-file (s path
                    :direction :output
                    :if-exists :supersede
                    :if-does-not-exist :create)
    (write-string content s)
    (format nil "wrote ~a bytes to ~a" (length content) path)))

;;;; --- edit-file -----------------------------------------------------

(defun edit-file (path old new)
  "Replace the FIRST occurrence of OLD in the file at PATH with NEW.

Signals an error when OLD is not present in the file. The first-occurrence
semantics are deliberate: silent multi-replace is worse than a signal for a
needle that was meant to be unique. Multi-occurrence replacement is a
caller's job, not the tool's."
  (let ((text (read-file path)))
    (multiple-value-bind (pos _) (search old text)
      (unless pos
        (error "needle not found in ~a" path))
      (let ((new-text (concatenate 'string
                                   (subseq text 0 pos)
                                   new
                                   (subseq text (+ pos (length old))))))
        (write-file path new-text)
        (format nil "edited ~a: ~a bytes -> ~a bytes"
                path (length text) (length new-text))))))

;;;; --- shell ---------------------------------------------------------

(defun shell (command &key (seconds 30.0))
  "Run COMMAND through /bin/sh with a wall-clock timeout of SECONDS seconds.

Uses uiop:run-program (NOT sb-ext:run-program — in SBCL 2.6.8 sb-ext is the
rewritten variant that rejects :output :string and :status, MEM065).
:ignore-error-status t is mandatory: without it a non-zero exit signals a
continuable uiop:subprocess-error. :status :code requests the exit code as
the third return value; the value is a BIT, not an integer — never
validate it against a type predicate here (MEM066), it is just a number.

Returns a plist:
  (:stdout STR-OR-NIL :stderr STR-OR-NIL :exit-code CODE-OR-NIL)

On timeout the plist adds :timed-out t and all three values are NIL — the
command was cut off by sb-ext:with-timeout before it produced output. The
:timed-out key is what lets the model distinguish "command finished with no
output" (stdout "", stderr "", exit-code 0) from "command was interrupted"
(stdout nil, stderr nil, exit-code nil, :timed-out t)."
  (handler-case
      (sb-ext:with-timeout seconds
        (multiple-value-bind (out err code)
            (uiop:run-program command
                              :output :string
                              :error-output :string
                              :status :code
                              :ignore-error-status t)
          (list :stdout out :stderr err :exit-code code)))
    (sb-ext:timeout ()
      (list :stdout nil :stderr nil :exit-code nil :timed-out t))))

;;;; --- lisp ----------------------------------------------------------

(defun lisp (source &key (seconds 5.0))
  "Eval SOURCE inside a fresh locked sandbox with a wall-clock timeout of
SECONDS seconds, returning the eval value on success or a structured
refusal plist on refusal.

The sandbox is fresh per call so state never leaks across tool calls — a
form that defines a variable or function does not affect the next lisp
call. The read happens with *package* bound to the unlocked sandbox so
junk symbols intern into the sandbox rather than the caller's :sexpr.tools
package; the sandbox is then locked and eval happens under that lock.

S04's condition taxonomy carries a machine-readable :reason symbol on
every refusal, preserved here so the kernel's dispatch records a
capability-denial or eval-refusal result event with the reason, not just
a string. The taxonomies are:
  read-refusal   — the input did not parse under the restricted readtable
                   (sharp-dot, sharp-S, sharp-C, package-locked,
                   end-of-file, reader-error)
  eval-refusal   — the form was refused at eval (undefined-function,
                   unbound-variable, package-locked-error, and so on)
  timeout-refusal — the form exceeded SECONDS seconds

On success the raw value is returned. The kernel's loop folds it back as
a :user event after formatting it with ~(format nil "~A" value), which is
the same shape the model expects to see."
  (handler-case
      (let* ((sb (sexpr.sandbox:make-sandbox))
             (form (let ((*package* sb))
                      (sexpr.sandbox:read-sandboxed-form source)))
             (sb (sexpr.sandbox:lock-sandbox sb)))
        (sexpr.sandbox:eval-in-sandbox form sb :seconds seconds))
    (sexpr.sandbox:read-refusal (cond)
      (list :refused :read
            :reason (sexpr.sandbox:read-refusal-reason cond)
            :text (sexpr.sandbox:read-refusal-text cond)))
    (sexpr.sandbox:eval-refusal (cond)
      (list :refused :eval
            :reason (sexpr.sandbox:eval-refusal-reason cond)
            :text (format nil "~a" (sexpr.sandbox:eval-refusal-error cond))))
    (sexpr.sandbox:timeout-refusal (cond)
      (list :refused :timeout
            :seconds (sexpr.sandbox:timeout-seconds cond)))))

;;;; --- register-default-tools! ---------------------------------------

(defun %register-tool-directly! (name symbol description lambda-list
                                capability &optional types)
  "Register a tool record built directly from REGISTER-TOOL! + DERIVE-SCHEMA,
bypassing the define-tool macro. The macro expansion runs once at file-load
time; this helper rebuilds the record on demand so register-default-tools!
can be called after reset-tool-registry! in tests without a reload."
  (register-tool!
   (list :name (string-downcase (string name))
         :symbol symbol
         :description description
         :schema (multiple-value-call
                  #'(lambda (params required)
                      (list :parameters params :required required))
                  (derive-schema lambda-list types))
         :capability capability)))

(defun register-default-tools! ()
  "Reset the tool registry and register the five built-in tools.

Idempotent: reset-tool-registry! empties the registry first, so a second
call is safe — the collision guard on register-tool! never fires because
the registry is empty at the moment of registration.

Capacities per the S05 design notes: read-file :fs-read, write-file and
edit-file :fs-write, shell :process, lisp :lisp-eval. The default spawn
capability set is '(:fs-read), which means read-file works out of the box
and the other four are denied by default — the S05 criterion asks to prove
that denial is a recorded result event, not an assumption."
  (reset-tool-registry!)
  (%register-tool-directly!
   :read-file #'read-file
   "Read the file at PATH and return its text contents. Returns an error
result when PATH does not exist."
   '(path) :fs-read)
  (%register-tool-directly!
   :write-file #'write-file
   "Write the text CONTENT to the file at PATH, creating or truncating.
Returns a short confirmation string."
   '(path content) :fs-write)
  (%register-tool-directly!
   :edit-file #'edit-file
   "Replace the first occurrence of OLD in the file at PATH with NEW.
Returns a short confirmation string. Signals an error (recorded as a
:body-error result) when OLD is not found."
   '(path old new) :fs-write)
  (%register-tool-directly!
   :shell #'shell
   "Run COMMAND through /bin/sh with a wall-clock timeout of SECONDS
seconds. Returns a plist (:stdout ... :stderr ... :exit-code ...) or
(:stdout nil :stderr nil :exit-code nil :timed-out t) on timeout."
   '(command &key (seconds 30.0)) :process
   '((seconds . :number)))
  (%register-tool-directly!
   :lisp #'lisp
   "Eval SOURCE inside a fresh locked sandbox with a wall-clock timeout of
SECONDS seconds. Returns the eval value on success, or a structured
refusal plist on read-refusal / eval-refusal / timeout-refusal."
   '(source &key (seconds 5.0)) :lisp-eval
   '((seconds . :number))))

;;;; Auto-register at file load: the system defines no explicit :depends-on
;;;; or :initialize-function, so the file-level call is the only hook we
;;;; have. The sexpr.asd puts "builtins" in the trailing :file "sexpr"
;;;; :depends-on list so this line runs when the system loads; without it
;;;; ql:quickload "sexpr" would load the module but leave the registry
;;;; empty, and the frozen ./sexpr image would not contain the five
;;;; built-ins either.

(register-default-tools!)
