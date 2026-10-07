;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; tools/check-saved-transcript.lisp — one-shot SAVED-transcript structural checker.
;;;;
;;;; WHY: `make test-live`'s shell greps cannot isolate the result event. The
;;;; model's final answer also contains the fixture contents, so
;;;; `grep -q 'contents' transcript` passes even when the result event's
;;;; :TEXT is empty — the grep cannot fail for the reason it claims to
;;;; check. This checker reads the binary-saved transcript with
;;;; sexpr.transcript:read-transcript (the same safe *READ-EVAL*-nil reader
;;;; the CLI --load uses) and asserts the event STRUCTURE:
;;;;
;;;;   1. the first event is :user;
;;;;   2. some :model event carries :tool-calls whose :name is "read-file"
;;;;      (compared with string=, MEM069);
;;;;   3. at least one :result event whose :TEXT contains the fixture
;;;;      contents, and every :result event's :VALUE is nil — the live
;;;;      object was dropped at serialize time (R023), so a faithfully-saved
;;;;      transcript never carries it;
;;;;   4. the last event is a :model event with :finish :stop and non-empty
;;;;      :content.
;;;;
;;;; Assertion 3 is "at least one", not the plan's "exactly one": the model
;;;; re-calls read-file non-deterministically (the DEFERRED minimal renderer
;;;; hides the assistant's own tool call — see tools/diagnostic-live-round.lisp),
;;;; so one saved transcript can carry 2-6 result events. "At least one" keeps
;;;; the R021/R023 assertion honest without the flakiness.
;;;;
;;;; WHEN: called by `make test-live` under SEXPR_TRANSCRIPT / SEXPR_FIXTURE.
;;;; Do NOT wire this into `make test`: it needs a live model server (R026).
;;;;
;;;; FAILURE MODES: an unset SEXPR_TRANSCRIPT / SEXPR_FIXTURE, a missing or
;;;; unreadable transcript file, or a file that is not a :transcript form all
;;;; exit 1 with a FAIL: line on *ERROR-OUTPUT* — never a raw backtrace.
;;;;
;;;; NOTE: this file names SEXPR.TRANSCRIPT by qualified name. It is a
;;;; one-shot tool loaded by `sbcl --load`, not shipped code, so it lives
;;;; under tools/ and is outside the R015 scan (`rg cl-llm-provider src/`).

(in-package :cl-user)

;;; --- 1. environment under test --------------------------------------
;;; SEXPR_TRANSCRIPT is the path of the binary-saved transcript; SEXPR_FIXTURE
;;; is the fixture's known contents — the string a result event's :TEXT must
;;; contain. Both come from the environment so `make test-live` is the only
;;; caller that sets them.
(defun %env (name)
  "Return the value of environment variable NAME, or NIL if unset."
  (uiop:getenv name))

(defparameter *transcript-path* (%env "SEXPR_TRANSCRIPT"))
(defparameter *fixture*        (%env "SEXPR_FIXTURE"))

;;; --- 2. assertion bookkeeping ----------------------------------------
(defparameter *failures* '())

(defun %fail (message)
  "Record MESSAGE as a checker failure."
  (push message *failures*))

(defun %bool (value)
  "Render VALUE as the checker's T/F evidence token."
  (if value "T" "F"))

;;; --- 3. read the saved transcript ------------------------------------
(defun %read-saved-transcript (path)
  "Read the saved transcript at PATH with sexpr.transcript:read-transcript —
the same safe *READ-EVAL*-nil reader the CLI --load uses. Any error (missing
file, unreadable, not a :transcript form) is recorded as a failure and
returns NIL: the checker exits 1 with a FAIL: line, never a raw backtrace."
  (handler-case
      (with-open-file (stream path :direction :input)
        (sexpr.transcript:read-transcript stream))
    (error (err)
      (%fail (format nil "cannot read transcript ~a: ~a" path err))
      nil)))

;;; --- 4. the structural assertions ------------------------------------
(let ((passed nil))
  (if (or (null *transcript-path*) (null *fixture*))
      (%fail (format nil
                     "SEXPR_TRANSCRIPT and SEXPR_FIXTURE must both be set (got ~s / ~s)"
                     *transcript-path* *fixture*))
      (let* ((transcript (%read-saved-transcript *transcript-path*))
             (events (and transcript
                          (sexpr.transcript:events-list transcript)))
             (types (and events
                         (mapcar #'sexpr.transcript:event-type events)))
             (first (and events (first events)))
             (last  (and events (car (last events))))
             ;; Every tool-call name the :model events carry.
             (call-names
              (and events
                   (loop :for e :in events
                         :when (eq (sexpr.transcript:event-type e) :model)
                           :append (mapcar (lambda (tc) (getf tc :name))
                                           (sexpr.transcript:event-tool-calls e)))))
             (read-file-called
              (and (member "read-file" call-names :test #'string=) t))
             ;; The :result events, and the subset whose :TEXT carries the
             ;; fixture contents. :TEXT is compared with SEARCH, not
             ;; STRINGP: a saved projection reads back as a base-char array
             ;; (print/read under with-standard-io-syntax), and SEARCH is
             ;; the sequence-generic contains check.
             (results (and events
                           (remove-if-not
                            (lambda (e)
                              (eq (sexpr.transcript:event-type e) :result))
                            events)))
             (matching
              (and results
                   (remove-if-not
                    (lambda (e)
                      (search *fixture* (sexpr.transcript:event-text e)))
                    results)))
             (all-values-nil
              (and results
                   (every (lambda (e)
                            (null (sexpr.transcript:event-value e)))
                          results)))
             (first-user
              (and first
                   (eq (sexpr.transcript:event-type first) :user)))
             (final-model
              (and last
                   (eq (sexpr.transcript:event-type last) :model)))
             (final-finish
              (and last (sexpr.transcript:event-finish last)))
             (final-stop
              (and (eq final-finish :stop) t))
             (final-content
              (and last (sexpr.transcript:event-content last)))
             (final-nonempty
              (and (stringp final-content)
                   (plusp (length final-content))
                   t)))
        (format t "~&--- check-saved-transcript: environment ---~%")
        (format t "~&TRANSCRIPT=~s FIXTURE=~s~%" *transcript-path* *fixture*)
        (format t "~&--- check-saved-transcript: recorded events ---~%")
        (format t "~&EVENTS=~d TYPES=~s~%" (length events) types)
        (format t "~&CALL-NAMES=~s READ-FILE-CALLED=~a~%"
                call-names (%bool read-file-called))
        (format t "~&RESULT-EVENTS=~d MATCHING-RESULTS=~d ALL-RESULT-VALUES-NIL=~a~%"
                (length results) (length matching) (%bool all-values-nil))
        (format t "~&FIRST-IS-USER=~a~%" (%bool first-user))
        (format t "~&FINAL-IS-MODEL=~a FINAL-FINISH=~s FINAL-CONTENT-NONEMPTY=~a~%"
                (%bool final-model) final-finish (%bool final-nonempty))
        (force-output)

        ;; Record a specific failure for each assertion that missed.
        (unless first-user
          (%fail (format nil "first event is ~s, not :USER"
                         (and first (sexpr.transcript:event-type first)))))
        (unless read-file-called
          (%fail (format nil
                         "no :model event carried a \"read-file\" tool call (saw ~s)"
                         call-names)))
        (unless matching
          (%fail (format nil
                         "no :result event :TEXT contains the fixture contents ~s"
                         *fixture*)))
        (unless all-values-nil
          (%fail "a :result event carries a non-nil :VALUE — the live object survived serialization (R023 violated)"))
        (unless final-model
          (%fail (format nil "last event is ~s, not :MODEL"
                         (and last (sexpr.transcript:event-type last)))))
        (unless final-stop
          (%fail (format nil
                         "final :model event :finish is ~s, not :STOP"
                         final-finish)))
        (unless final-nonempty
          (%fail "final :model event :content is empty"))
        (setf passed (null *failures*))))
  (finish-output)
  (if passed
      (progn
        (format t "~&CHECK-PASS~%")
        (finish-output)
        (sb-ext:quit :unix-status 0))
      (progn
        (format *error-output*
                "~&FAIL: ~{~a~^; ~}~%"
                (reverse *failures*))
        (finish-output *error-output*)
        ;; SBCL 2.6.8 spells the exit-status key :UNIX-STATUS, not :CODE.
        (sb-ext:quit :unix-status 1))))
