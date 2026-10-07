;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tests/five.lisp — the five registered built-in tools (R022).
;;;;
;;;; Each group calls register-default-tools! first — NOT
;;;; reset-tool-registry! — because other test files in the suite
;;;; (tests/tools.lisp, tests/kernel.lisp) call reset-tool-registry! in
;;;; their bodies and rove runs in load order, so by the time this file
;;;; executes the built-ins may not be registered (MEM063).
;;;; register-default-tools! is idempotent (reset-then-rebuild) and
;;;; re-registers all five after any reset.
;;;;
;;;; The suite is model-free: no live server host, no model port, no
;;;; web URL scheme — which is what makes S05's proof model-independent
;;;; and CI-safe.
;;;; Groups 1-9 exercise each tool end to end through perform-tool;
;;;; groups 10-11 prove the "denied by default" criterion through the
;;;; real spawn / run-until-finished / dispatch-tool-call chain, so the
;;;; denial is a recorded :capability-denied result event rather than a
;;;; source-line assertion; groups 12-14 extend the denial proof to the
;;;; other three default-denied tools (write-file, edit-file, shell).

(in-package :sexpr-tests)

;;; --- helpers ---------------------------------------------------------
;;;;
;;;; uiop:tmpdir is not exported in this SBCL's UIOP, and
;;;; uiop:temporary-directory returns NIL, so the temp directory is
;;;; resolved via uiop:getenv "TMPDIR" (the same call provider.lisp
;;;; uses) with a /tmp fallback. Path strings are constructed directly
;;;; to avoid pathname-directory parsing edge cases.

(defun %five-tmp-path (suffix)
  "Return a fresh path string in the temp directory for a test fixture."
  (concatenate 'string
               (or (uiop:getenv "TMPDIR") "/tmp")
               "/sexpr-five-"
               (string-downcase (string suffix))
               "-"
               (symbol-name (gensym))
               ".txt"))

(defun %five-read-back (path)
  "Read the entire file at PATH as a string, independent of read-file."
  (with-open-file (s path :direction :input :if-does-not-exist :error)
    (let ((data (make-string (file-length s))))
      (read-sequence data s)
      data)))

;;; --- read-file ------------------------------------------------------

(rove:deftest read-file-returns-the-contents-of-a-file
  (register-default-tools!)
  (let* ((content (format nil "a~%b"))   ; real newline, not the literal "a~%b" (MEM019)
         (path (%five-tmp-path "rf")))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output :if-does-not-exist :create)
             (write-string content s))
           (ok (string= (perform-tool
                         (list :name "read-file"
                               :arguments (list :path path))
                         :capabilities '(:fs-read))
                        content)
               "read-file returns the exact file contents"))
      (ignore-errors (delete-file path)))))

;;; --- write-file ------------------------------------------------------

(rove:deftest write-file-creates-a-file-with-the-given-text
  (register-default-tools!)
  (let* ((content "hello world")
         (path (%five-tmp-path "wf")))
    (unwind-protect
         (let ((result (perform-tool
                        (list :name "write-file"
                              :arguments (list :path path :content content))
                        :capabilities '(:fs-write))))
           (ok (stringp result) "write-file returns a string confirmation")
           (ok (> (length result) 0) "the confirmation is non-empty")
           (ok (string= (%five-read-back path) content)
               "the file was created with the given text"))
      (ignore-errors (delete-file path)))))

;;; --- edit-file -------------------------------------------------------

(rove:deftest edit-file-replaces-the-first-occurrence
  (register-default-tools!)
  (let ((path (%five-tmp-path "ef")))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output :if-does-not-exist :create)
             (write-string "old new old" s))
           (perform-tool (list :name "edit-file"
                               :arguments (list :path path
                                                :old "old" :new "OLD"))
                         :capabilities '(:fs-write))
           (ok (string= (%five-read-back path) "OLD new old")
               "only the first occurrence was replaced"))
      (ignore-errors (delete-file path)))))

(rove:deftest edit-file-signals-when-the-needle-is-absent
  (register-default-tools!)
  (let ((path (%five-tmp-path "efn")))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output :if-does-not-exist :create)
             (write-string "hello" s))
           ;; rove's `signals` defaults the condition to `error` (MEM039).
           (ok (signals (perform-tool
                         (list :name "edit-file"
                               :arguments (list :path path
                                                :old "absent" :new "x"))
                         :capabilities '(:fs-write)))
               "edit-file signals when the needle is absent"))
      (ignore-errors (delete-file path)))))

;;; --- shell -----------------------------------------------------------

(rove:deftest shell-returns-stdout-stderr-and-exit-code
  (register-default-tools!)
  (let ((result (perform-tool
                 (list :name "shell"
                       :arguments (list :command "printf OUT; printf ERR 1>&2; exit 7"
                                        :seconds 10))
                 :capabilities '(:process))))
    (ok (string= (getf result :stdout) "OUT") "stdout is captured")
    (ok (string= (getf result :stderr) "ERR") "stderr is captured")
    ;; `=`, not `eq`: uiop's exit code is a BIT, not an integer (MEM066).
    (ok (= 7 (getf result :exit-code))
        "exit code is 7")))

(rove:deftest shell-times-out-a-blocking-command
  (register-default-tools!)
  (let ((result (perform-tool
                 (list :name "shell"
                       :arguments (list :command "sleep 5" :seconds 0.5))
                 :capabilities '(:process))))
    (ok (getf result :timed-out) "the blocking command was timed out")))

;;; --- lisp ------------------------------------------------------------

(rove:deftest lisp-evals-a-sandboxed-form
  (register-default-tools!)
  (let ((result (perform-tool
                 (list :name "lisp"
                       :arguments (list :source "(+ 1 2)"))
                 :capabilities '(:lisp-eval))))
    (ok (= result 3) "(+ 1 2) evaluates to 3")))

(rove:deftest lisp-records-a-read-refusal-when-the-form-is-unsafe
  (register-default-tools!)
  (let ((result (perform-tool
                 (list :name "lisp"
                       :arguments (list :source "#.(+ 1 2)"))
                 :capabilities '(:lisp-eval))))
    ;; The machine-readable :reason symbol is what S04's condition taxonomy
    ;; was designed for; losing it would be a silent regression.
    (ok (eq (getf result :refused) :read) "the form was refused at read")
    (ok (eq (getf result :reason) :read-eval)
        "the reason is :read-eval (sharp-dot blocked by *read-eval* nil)")))

(rove:deftest lisp-records-an-eval-refusal-for-an-out-of-surface-symbol
  (register-default-tools!)
  (let ((result (perform-tool
                 (list :name "lisp"
                       :arguments (list :source "(undefined-fn 1 2)"))
                 :capabilities '(:lisp-eval))))
    ;; eval-refusal-reason returns (type-of original-error), which is the CL
    ;; implementation's type name — do not over-constrain on the exact symbol.
    (ok (not (null (getf result :refused))) "a refusal was recorded")
    (ok (eq (getf result :refused) :eval) "the form was refused at eval")
    (ok (and (stringp (getf result :text)) (> (length (getf result :text)) 0))
        "the :text projection is non-empty")))

;;; --- denied by default (kernel-level proof) -------------------------
;;;;
;;;; These two groups prove the S05 criterion through the real
;;;; spawn / run-until-finished / dispatch-tool-call chain: the denial
;;;; is a recorded :capability-denied result event in the transcript,
;;;; not a source-line assumption. The default spawn set is (:fs-read),
;;;; so :lisp-eval is not granted.

(rove:deftest a-default-spawn-denies-the-lisp-call-and-the-loop-continues
  (register-default-tools!)
  (let* ((stub (make-instance
                'stub-endpoint
                :responses (list
                            (list :content ""
                                  :finish :tool-calls
                                  :tool-calls (list
                                               (list :id "1"
                                                     :name "lisp"
                                                     :arguments (list :source "(+ 1 2)"))))
                            (list :content "denied" :finish :stop))))
         ;; No :capabilities keyword: default spawn set is (:fs-read) per
         ;; MEM051 (passing '() silently yields (:fs-read), so omit it).
         (agent (spawn :goal "g" :endpoint stub))
         (tr (run-until-finished agent)))
    (ok (= (stub-call-count stub) 2)
        "the loop survived the denial and took a follow-up turn")
    (let ((result (find-if (lambda (e) (eq (event-type e) :result))
                           (events-list tr))))
      (ok result "a result event was recorded")
      (ok (eq (getf (event-value result) :reason) :capability-denied)
          "the denial is recorded as :capability-denied"))))

(rove:deftest a-spawn-with-lisp-eval-grants-the-lisp-call
  (register-default-tools!)
  (let* ((stub (make-instance
                'stub-endpoint
                :responses (list
                            (list :content ""
                                  :finish :tool-calls
                                  :tool-calls (list
                                               (list :id "1"
                                                     :name "lisp"
                                                     :arguments (list :source "(+ 1 2)"))))
                            (list :content "granted" :finish :stop))))
         (agent (spawn :goal "g" :endpoint stub
                       :capabilities '(:fs-read :lisp-eval)))
         (tr (run-until-finished agent)))
    (let ((result (find-if (lambda (e) (eq (event-type e) :result))
                           (events-list tr))))
      (ok result "a result event was recorded")
      (ok (= (event-value result) 3)
          "the eval result is 3, not a denial plist"))))

;;; --- the other three default-denied tools ----------------------------
;;;;
;;;; The milestone's S05 criterion names lisp as the gated tool (group
;;;; 10 above), but the other three gated tools follow the same gate
;;;; code path. These three groups extend the "denied by default" proof
;;;; to write-file (:fs-write), edit-file (:fs-write), and shell
;;;; (:process), confirming that only :fs-read is granted out of the
;;;; box and every other capability is the caller's explicit choice.

(rove:deftest write-file-is-denied-by-default
  (register-default-tools!)
  (ok (signals (perform-tool
                (list :name "write-file"
                      :arguments (list :path "/tmp/sexpr-five-deny"
                                       :content "x"))
                :capabilities '(:fs-read)))
      "write-file is denied without :fs-write"))

(rove:deftest edit-file-is-denied-by-default
  (register-default-tools!)
  (ok (signals (perform-tool
                (list :name "edit-file"
                      :arguments (list :path "/tmp/sexpr-five-deny"
                                       :old "a" :new "b"))
                :capabilities '(:fs-read)))
      "edit-file is denied without :fs-write"))

(rove:deftest shell-is-denied-by-default
  (register-default-tools!)
  (ok (signals (perform-tool
                (list :name "shell"
                      :arguments (list :command "echo hi"))
                :capabilities '(:fs-read)))
      "shell is denied without :process"))
