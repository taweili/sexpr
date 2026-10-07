;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tools/diagnostic-live-round.lisp — one-shot IN-PROCESS live-turn probe.
;;;;
;;;; WHY: the S06 slice text says the live turn records a result event
;;;; "carrying both a live object and printed text". The shipped-binary probe
;;;; (make test-live) can only see the SAVED transcript, and serialize-event
;;;; strips a result event's :value before /save (R023) — so :value is
;;;; invisible from the shell. This probe runs the same turn IN-PROCESS and
;;;; inspects the LIVE transcript before serialization, which is the only
;;;; place the live object can be observed. It also asserts the recorded
;;;; event STRUCTURE (a tool-use turn: :user, one or more :model/:result tool
;;;; rounds, then a final :model finishing :stop), not just that the
;;;; transcript is non-empty — that is the honesty gap the slice names. The
;;;; tool-call COUNT is deliberately not asserted: the minimal renderer
;;;; (kernel:event-to-message, marked DEFERRED) sends an assistant tool-call
;;;; reply as an EMPTY-content assistant message — the call itself is not in
;;;; the history — so the model cannot see that it already called read-file
;;;; and may call it again (observed live: 1 and 5 calls on the same prompt).
;;;; The honest invariant is the turn SHAPE; see %TOOL-TURN-SHAPE-P.
;;;;
;;;; WHEN: run against a live local server via `make diagnostic-live-round`.
;;;; Do NOT wire this into `make test`: the rove suite must stay green on a
;;;; machine with no model server running (R026).
;;;;
;;;; WHAT IT PROVES (R025 parity, source image): configuration flows through
;;;; SEXPR.PROVIDER:CONFIGURE-PROVIDER (the SEXPR_* env vars), a real model
;;;; emits a usable "read-file" call, sexpr validates + dispatches it, the
;;;; recorded result event carries a live string :value AND a :text
;;;; projection containing the fixture contents, the text folds back as a
;;;; model-visible message, and the model produces a final :stop answer —
;;;; the whole turn in one process.
;;;;
;;;; NOTE: this file names SEXPR.CLI / SEXPR.KERNEL / SEXPR.TRANSCRIPT /
;;;; SEXPR.PROVIDER by qualified name. It is a one-shot tool loaded by
;;;; `sbcl --load`, not shipped code, so it lives under tools/ and is outside
;;;; the R015 scan (`rg cl-llm-provider src/cli/`).

(in-package :cl-user)

;;; --- 1. configuration under test -------------------------------------
;;; Reading SEXPR_PROVIDER / SEXPR_MODEL / SEXPR_BASE_URL here (rather than
;;; hard-coding) is what proves the SEXPR_* env-var path is the one under
;;; test — the same path the shipped ./sexpr binary uses (R025 parity).
(sexpr.provider:configure-provider)

(format t "~&--- diagnostic-live-round: effective provider config ---~%")
(format t "~&PROVIDER=~s MODEL=~s BASE=~s~%"
        sexpr.provider:*provider-type*
        sexpr.provider:*default-model-name*
        sexpr.provider:*default-base-url*)
(force-output)

;;; --- 2. fixture ------------------------------------------------------
;;; A fixture with known contents, created under TMPDIR (or /tmp fallback,
;;; the MEM070 pattern from S05) and deleted under unwind-protect. TMPDIR is
;;; resolved via uiop:getenv because uiop:tmpdir is not exported in this
;;; SBCL's UIOP.
(defun %probe-tmp-path (suffix)
  "Return a fresh path string in the temp directory for the probe fixture."
  (concatenate 'string
               (or (uiop:getenv "TMPDIR") "/tmp")
               "/sexpr-live-round-"
               (string-downcase (string suffix))
               "-"
               (symbol-name (gensym))
               ".txt"))

(defparameter *probe-contents* "live round probe contents")
(defparameter *probe-path* (%probe-tmp-path "fixture"))

(defun %write-fixture (path contents)
  "Write CONTENTS to PATH, creating or truncating, and return PATH."
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string contents s))
  path)

;;; --- 3. assertion bookkeeping ----------------------------------------
(defparameter *probe-failures* '())

(defun %fail (message)
  "Record MESSAGE as a probe failure."
  (push message *probe-failures*))

(defun %bool (value)
  "Render VALUE as the probe's T/F evidence token."
  (if value "T" "F"))

(defun %tool-turn-shape-p (types)
  "Return T when TYPES is the shape of a tool-use turn.

TYPES must be :USER, then one or more tool rounds (a :MODEL immediately
followed by one or more :RESULT), then a final :MODEL. This accepts any number
of rounds — the model may re-call read-file because the DEFERRED minimal
renderer hides the assistant's own tool call (see the file header) — while
still rejecting a turn that never called a tool, never recorded a result, or
never produced a final model event."
  (and (>= (length types) 4)
       (eq (first types) :user)
       (eq (car (last types)) :model)
       (let ((state :need-model)
             (ok t))
         ;; Walk the middle (everything between the opening :user and the
         ;; closing :model). A :model starts a round that must produce >=1
         ;; :result before the next :model or the end.
         (dolist (type (subseq types 1 (1- (length types))))
           (case state
             (:need-model
              (if (eq type :model)
                  (setf state :need-result)
                  (setf ok nil)))
             (:need-result
              (if (eq type :result)
                  (setf state :have-result)
                  (setf ok nil)))
             (:have-result
              (cond ((eq type :result) nil)
                    ((eq type :model) (setf state :need-result))
                    (t (setf ok nil)))))
           (unless ok (return)))
         (and ok (eq state :have-result)))))

;;; --- 4. run the real turn in-process, inspect the live transcript ----
(let ((passed nil))
  (unwind-protect
       (progn
         (%write-fixture *probe-path* *probe-contents*)
         (let* ((prompt
                  ;; MEM019: build the stream with format nil and ~% for real
                  ;; newlines; a literal "~%" would be ONE line to read-line.
                  ;; MEM072: a real user line must precede /exit or no turn runs.
                  (format nil
                          "Use the read-file tool to read ~a, then tell me exactly what it contains.~%/exit~%"
                          *probe-path*))
                (input  (make-string-input-stream prompt))
                (output (make-string-output-stream))
                (session (sexpr.cli:chat
                          :goal "You are a terse assistant. Use tools when asked."
                          :input input
                          :output output))
                (events (sexpr.transcript:events-list
                         (sexpr.kernel:agent-transcript
                          (sexpr.cli:chat-session-agent session))))
                (types  (mapcar #'sexpr.transcript:event-type events)))
           (format t "~&--- diagnostic-live-round: recorded events ---~%")
           (format t "~&EVENTS=~d TYPES=~s~%" (length events) types)
           (format t "~&TOOL-ROUNDS=~d RESULT-EVENTS=~d~%"
                   (count :model types) (count :result types))

           ;; The model events and the names of every tool call they carry.
           (let* ((call-names
                    (loop :for e :in events
                          :when (eq (sexpr.transcript:event-type e) :model)
                            :append (mapcar (lambda (tc) (getf tc :name))
                                            (sexpr.transcript:event-tool-calls e))))
                  (read-file-called
                    (and (member "read-file" call-names :test #'string=) t))
                  (result (find :result events
                                :key #'sexpr.transcript:event-type))
                  (value  (and result (sexpr.transcript:event-value result)))
                  (text   (and result (sexpr.transcript:event-text result)))
                  (value-nonnil (and value t))
                  (value-string (and (stringp value) t))
                  (text-has-contents
                    (and (stringp text)
                         (not (null (search *probe-contents* text)))
                         t))
                  (final (car (last events)))
                  (final-finish (and final
                                     (sexpr.transcript:event-finish final)))
                  (final-content (and final
                                      (sexpr.transcript:event-content final)))
                  (final-stop (and (eq final-finish :stop) t))
                  (final-nonempty
                    (and (stringp final-content)
                         (plusp (length final-content))
                         t))
                  (types-ok (%tool-turn-shape-p types)))
             ;; Print each assertion as named evidence.
             (format t "~&CALL-NAMES=~s READ-FILE-CALLED=~a~%"
                     call-names (%bool read-file-called))
             (format t "~&EVENT-STRUCTURE=~a~%" (%bool types-ok))
             (format t "~&RESULT-VALUE-NONNIL=~a~%" (%bool value-nonnil))
             (format t "~&RESULT-VALUE-TYPE=~s~%" (and value (type-of value)))
             (format t "~&RESULT-VALUE-IS-STRING=~a~%" (%bool value-string))
             (format t "~&RESULT-TEXT=~s~%" text)
             (format t "~&TEXT-HAS-CONTENTS=~a~%" (%bool text-has-contents))
             (format t "~&FINAL-FINISH=~s FINAL-CONTENT-NONEMPTY=~a~%"
                     final-finish (%bool final-nonempty))
             (force-output)

             ;; Record a specific failure for each assertion that missed.
             (unless types-ok
               (%fail (format nil
                              "event structure ~s (want :USER, then >=1 (:MODEL :RESULT) rounds, then a final :MODEL)"
                              types)))
             (unless read-file-called
               (%fail (format nil "no :model event carried a \"read-file\" tool call (saw ~s)"
                              call-names)))
             (unless value-nonnil
               (%fail "result event :value is NIL (live object missing)"))
             (unless value-string
               (%fail (format nil "result event :value is not a string: ~s"
                              (and value (type-of value)))))
             (unless text-has-contents
               (%fail (format nil "result event :text does not contain ~s"
                              *probe-contents*)))
             (unless final-stop
               (%fail (format nil "final :model event :finish is ~s, not :STOP"
                              final-finish)))
             (unless final-nonempty
               (%fail "final :model event :content is empty"))
             (setf passed (null *probe-failures*)))))
    ;; Always remove the fixture, pass or fail.
    (ignore-errors (delete-file *probe-path*)))
  (finish-output)
  (if passed
      (progn
        (format t "~&PROBE-PASS~%")
        (finish-output)
        (sb-ext:quit :unix-status 0))
      (progn
        (format *error-output*
                "~&FAIL: ~{~a~^; ~}~%"
                (reverse *probe-failures*))
        (finish-output *error-output*)
        ;; SBCL 2.6.8 spells the exit-status key :UNIX-STATUS, not :CODE.
        (sb-ext:quit :unix-status 1))))
