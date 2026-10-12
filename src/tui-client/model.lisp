;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui-client/model.lisp — the TEA model and its update loop (M004/S03 T04).
;;;;
;;;; THIS IS THE HALF OF S03 WHERE THE DEMO LIVES. The slice demo says "shows the
;;;; picked agent's transcript"; that sentence is realized only here, because this is
;;;; the one place a wire delta becomes a rendered line.
;;;;
;;;; TESTABLE HEADLESSLY. `tui:run` enters raw mode via sb-posix:tcgetattr on
;;;; *terminal-io*'s fd and fails on a pipe (MEM103), so it cannot be tested at all.
;;;; `init`/`update`/`view` are plain generic functions and `view` returns a string,
;;;; so a test constructs the model over string-stream connections and calls them
;;;; directly. No test in this project ever calls `tui:run`.
;;;;
;;;; PROJECTIONS ONLY (R023). The model holds strings, plists, numbers and message
;;;; objects that came off the wire — never a live agent, a live transcript, or a
;;;; kernel object. `model-agents` is a list of plists; `model-picked-agent` is a
;;;; name STRING, not an agent.
;;;;
;;;; TWO CONNECTIONS, ONE VOCABULARY. The push channel (tui-connection, wire.lisp)
;;;; carries deltas one way; the swank RPC channel (swank-connection, swank-rpc.lisp)
;;;; carries request/response. Both carry the same stats counter set (*client-stats-keys*),
;;;; so the status bar reads either with one accessor pair — `client-stats-get` and
;;;; `client-label` — and never needs to know which struct it holds.
;;;;
;;;; RPC FORMS ARE PACKET TEXT. `(sexpr.tui:agent-snapshot)` is a STRING the client
;;;; writes into a packet, never a form the client reads: :sexpr.tui does not exist in
;;;; this process, so reading the qualified name here would signal
;;;; "Package SEXPR.TUI does not exist" (MEM102/D020). String ARGUMENTS go through
;;;; swank-escape-string so a note containing a quote cannot break the form the image
;;;; reads.
;;;;
;;;; EVERY RPC AND EVERY WIRE WRITE CAN FAIL, AND NONE MAY CRASH THE LOOP. `update`
;;;; runs on the TEA thread; a condition there would take the whole UI down with no
;;;; operator-visible cause. So each remote call is wrapped: the condition is recorded
;;;; on the connection stats (`:last-error`), shown in the status bar, counted, and
;;;; the model keeps its last good state. An error that disappears from the status bar
;;;; is an error the operator cannot act on.

(in-package :sexpr-tui)

;;;; --- tuning ----------------------------------------------------------

(defparameter *tui-init-tick* 0.5
  "The initial command's tick interval. The reader thread is the real push source; the
tick exists for the cursor blink and as the fallback poll.")
(export '*tui-init-tick*)

(defparameter *scrollback-cap* 2000
  "The chat scrollback cap, in lines. Oldest first (Q6): at 10x load a streaming turn
can emit thousands of fragments, so the cap is the only thing that keeps a long
session from growing without bound. 2000 is well past one screen of history and is
cheap to cap.")
(export '*scrollback-cap*)

(defparameter *repl-cap* 200
  "The REPL pane cap, in lines. REPL output is sparse compared to deltas, so the cap
is smaller, but it must exist for the same reason.")
(export '*repl-cap*)

(defparameter *default-term-width* 80
  "The pane widths before the first window-size-msg arrives.")
(export '*default-term-width*)

(defparameter *default-term-height* 24
  "The pane heights before the first window-size-msg arrives.")
(export '*default-term-height*)

;;;; --- the model -------------------------------------------------------

(defclass tui-model ()
  ((program :initarg :program :initform nil :accessor model-program
            :documentation "The cl-tuition program, or NIL in a headless test. The
reader thread is only started when this is non-nil AND program-running is T.")
   (push-connection :initarg :push-connection :initform nil :accessor model-push-connection
                    :documentation "The push-channel connection (wire.lisp), or NIL.")
   (swank-connection :initarg :swank-connection :initform nil :accessor model-swank-connection
                     :documentation "The swank RPC connection (swank-rpc.lisp), or NIL.")
   (picked-agent :initarg :picked-agent :initform nil :accessor model-picked-agent
                 :documentation "The picked agent's NAME, a string. Never an agent object.")
   (pending-approval :initform nil :accessor model-pending-approval
                     :documentation "The PICKED agent's pending-approval plist (or T
when only a flag arrived), or NIL. Data only (R023): a projection of the image's
registry, never a live condition or restart object. Cleared optimistically when a
resolution RPC succeeds; the confirming :status push corrects it if the image
disagrees (research risk 9).")
   (agents :initform nil :accessor model-agents
           :documentation "The agent-snapshot: a list of agent plists, or nil while
unfetched. Data, never live agents.")
   (cursor :initform 0 :accessor model-cursor
           :documentation "The transcript cursor. transcript-delta returns a new one;
the client persists it so each event is fetched exactly once.")
   (scrollback :initform nil :accessor model-scrollback
               :documentation "The chat lines, NEWEST FIRST, bounded by scrollback-cap.
This is the bounded copy: the viewport content is derived from it, so the cap is
enforced in the data and the pane cannot overflow it.")
   (scrollback-cap :initarg :scrollback-cap :initform *scrollback-cap* :accessor model-scrollback-cap)
   (repl-lines :initform nil :accessor model-repl-lines
               :documentation "The REPL output lines, newest first, bounded by repl-cap.")
   (repl-cap :initarg :repl-cap :initform *repl-cap* :accessor model-repl-cap)
   (chat-viewport :initform nil :accessor model-chat-viewport)
   (chat-textarea :initform nil :accessor model-chat-textarea)
   (repl-viewport :initform nil :accessor model-repl-viewport)
   (repl-textarea :initform nil :accessor model-repl-textarea)
   (agent-viewport :initform nil :accessor model-agent-viewport)
   (focused :initform :chat :accessor model-focused
            :documentation "Which textarea owns key input: :chat or :repl. Tab cycles.")
   (term-width :initarg :term-width :initform *default-term-width* :accessor model-term-width)
   (term-height :initarg :term-height :initform *default-term-height* :accessor model-term-height)
   (stats :initform nil :accessor model-stats
          :documentation "The combined connection stats plist: one entry per connection
label, for the status bar. Kept in the model so `view` is a pure render of model state
rather than a live read during render.")
   (status-text :initform "" :accessor model-status-text
                :documentation "The last status line: connection state plus the most
recent error, if any.")
   (readers-running :initform nil :accessor model-readers-running
                    :documentation "Whether the wire reader thread was started. When
NIL on a connected model, the status bar says readers are off — a silent freeze is the
one failure this UI must never produce.")
   (note :initform nil :accessor model-note
         :documentation "The last operator-facing note (an input-path error such as a
NIL handle), or NIL. `note-error` writes here rather than straight to status-text
because `refresh-status` rebuilds status-text from connection stats at the end of
every update and would otherwise drop the note before the operator could see it.")
   (quitting :initform nil :accessor model-quitting)))

;;;; --- bounded scrollback ----------------------------------------------

(defun %cap (list cap)
  "Keep the newest CAP entries of LIST, dropping the oldest. The drop is on the tail
because entries are stored newest-first."
  (if (<= (length list) cap) list (subseq list 0 cap)))

(defun append-line (list cap line)
  "Append LINE to the bounded scrollback LIST. Returns the new list."
  (%cap (cons (one-line line) list) cap))
(export 'append-line)

(defun model-append-chat-line (model line)
  "Append LINE to the chat scrollback, re-cap it, and push the new content into the
chat viewport scrolled to the bottom. The viewport follows the newest line, which is
what makes a streamed turn readable without scrolling."
  (setf (model-scrollback model)
        (append-line (model-scrollback model)
                     (model-scrollback-cap model) line))
  (let ((vp (model-chat-viewport model)))
    (when vp
      (tui.viewport:viewport-set-content vp
                                         (lines-to-string
                                          (nreverse (model-scrollback model))))
      (tui.viewport:viewport-goto-bottom vp)))
  model)

(defun model-append-repl-line (model line)
  "Append LINE to the REPL output, bounded by repl-cap."
  (setf (model-repl-lines model)
        (append-line (model-repl-lines model) (model-repl-cap model) line))
  (let ((vp (model-repl-viewport model)))
    (when vp
      (tui.viewport:viewport-set-content vp
                                         (lines-to-string
                                          (nreverse (model-repl-lines model))))
      (tui.viewport:viewport-goto-bottom vp)))
  model)

;;;; --- transcript rendering -------------------------------------------

(defun event-to-line (event)
  "Render one transcript event PLIST as one chat line.
Transcript events are plists (`:type` :user/:model/:result), not strings, so this is
the one projection that turns them into text. It prints the TYPE and then the event's
own text, which is the least-lossy rendering available client-side without knowing the
in-image event vocabulary:
  user   -> (getf event :content)
  model  -> (getf event :content)
  result -> (getf event :text)   (the printed projection, R023)
A missing or malformed event degrades to a line, never a condition: a single bad event
in a 10x burst must not blank the transcript."
  (let ((text (or (getf event :content)
                  (getf event :text)
                  (when (stringp event) event))))
    (format nil "~A: ~A" (getf event :type :event) (or text ""))))
(export 'event-to-line)

;;;; --- RPC -------------------------------------------------------------

(defun reply-error-text (reply)
  "A human-readable error for a classified reply that is not :ok, or NIL when there is
nothing to say. The condition object swank returns for an :abort is printed as text so
the status bar stays data."
  (cond
    ((null reply) "no reply")
    (t (let ((status (getf reply :status))
             (packet (getf reply :packet)))
         (if (and (listp packet) (listp (second packet)))
             (format nil "~A: ~A" status (second (second packet)))
             (format nil "~A" status))))))
(export 'reply-error-text)

(defun swank-rpc (connection form-text)
  "Run one sexpr.tui RPC over SWANK-CONNECTION. Returns (VALUES value error).
FORM-TEXT is packet TEXT (see the file header). ERROR is NIL on success, otherwise a
string that belongs in the status bar: :abort, :reader-error, :eof, :no-match, or the
text of a condition the connection raised. Nothing is ever signalled out of here — the
caller decides what to do with the last error."
  (when (null connection)
    (return-from swank-rpc (values nil "no swank connection")))
  (handler-case
      (let ((reply (swank-eval connection form-text)))
        (cond
          ((eq (getf reply :status) :ok)
           (values (swank-value connection reply) nil))
          (t (values nil (reply-error-text reply)))))
    (error (e)
      (handler-case (client-note-error! connection e) (error () nil))
      (values nil (format nil "rpc error: ~A" e)))))
(export 'swank-rpc)

(defun rpc-agent-snapshot (connection)
  "Fetch `sexpr.tui:agent-snapshot`. Returns (VALUES agents error).
The image returns a LIST of agent plists; anything else is treated as an error rather
than silently rendering an empty society, which would look identical to a genuinely
empty image."
  (multiple-value-bind (value error)
      (swank-rpc connection "(sexpr.tui:agent-snapshot)")
    (cond
      (error (values nil error))
      ((listp value) (values value nil))
      (t (values nil (format nil "agent-snapshot: unexpected reply ~S" value))))))
(export 'rpc-agent-snapshot)

(defun rpc-transcript-delta (connection agent-name cursor)
  "Fetch `sexpr.tui:transcript-delta` from CURSOR for AGENT-NAME.
Returns (VALUES events new-cursor error). The image returns a dotted pair
(EVENTS . NEW-CURSOR), and EVENTS is a LIST, so the shape test is
`(consp value) (integerp (cdr value))` — `(cddr value)` would be non-nil because the
cdr is a list, not the cursor.
An EMPTY refetch (no events) is a success with NIL events: the server sends resync
mid-stream, where transcript-length has not advanced yet, so the client must accept
nothing-new rather than treating it as an error. The cursor is still adopted."
  (let ((form-text (format nil "(sexpr.tui:transcript-delta ~A ~D)"
                            (swank-escape-string (or agent-name "")) cursor)))
    (multiple-value-bind (value error)
        (swank-rpc connection form-text)
      (cond
        (error (values nil cursor error))
        ((and (consp value) (integerp (cdr value)))
         (values (car value) (cdr value) nil))
        (t (values nil cursor
                   (format nil "transcript-delta: unexpected reply ~S" value)))))))
(export 'rpc-transcript-delta)

(defun rpc-resolve-approval (connection agent-name decision)
  "Resolve a pending approval for AGENT-NAME with DECISION via
`sexpr.tui:resolve-approval`. Returns (VALUES value error) like the other RPCs.
DECISION is a keyword such as :grant-once; `~S` prints it as :GRANT-ONCE, which the
image's reader interns back as the same keyword. AGENT-NAME goes through
swank-escape-string so a name containing a quote cannot break the form."
  (let ((form-text (format nil "(sexpr.tui:resolve-approval ~A ~S)"
                            (swank-escape-string (or agent-name ""))
                            decision)))
    (swank-rpc connection form-text)))
(export 'rpc-resolve-approval)

;;;; --- program-running -----------------------------------------------

(defun program-running-p (program)
  "Whether PROGRAM's update loop is currently draining its message channel.
`tui:program-running` is a slot accessor that cl-tuition does NOT export from the
:tuition package (verified: (find-symbol \"PROGRAM-RUNNING\" :tuition) is NIL), so it
cannot be named by a qualified nickname — the slot name is looked up in the package by
name instead. Handled rather than signalled: if cl-tuition renames the slot, a NIL
program or a failed lookup falls back to the weaker but still safe test (a program
object exists at all) rather than crashing init."
  (when (null program)
    (return-from program-running-p nil))
  (handler-case
      (slot-value program (intern "RUNNING" (find-package "TUITION")))
    (error () (not (null program)))))
(export 'program-running-p)

;;;; --- status bar ------------------------------------------------------

(defun connection-error-text (connection)
  "The last error TEXT recorded on CONNECTION, or NIL when there is none.
`:last-error` shares the stats plist with the counters but is not one: it starts at
0 (see *client-stats-keys* / %new-stats) and becomes a string only when
client-note-error! records a condition. So only a non-empty STRING is an error —
the initial 0 and a NIL connection both mean \"no error\". Without this, the status
bar appends a bogus \"| 0\" to every healthy frame."
  (let ((e (client-stats-get connection :last-error)))
    (when (and (stringp e) (plusp (length e))) e)))
(export 'connection-error-text)

(defun refresh-status (model)
  "Rebuild the combined stats plist and the status line from both connections.
Called from update, so the status line is model STATE and `view` never reads a live
connection during render. An error is retained across successful refreshes until a new
one supersedes it — clearing it on the next healthy tick would hide the failure."
  (let ((push (model-push-connection model))
        (swank (model-swank-connection model)))
    (setf (model-stats model)
          (append (when push (list (client-stats-get push :last-error)
                                   (client-stats-get push :packets-read)
                                   (client-stats-get push :connection-closed)))
                  (when swank (list (client-stats-get swank :last-error)
                                     (client-stats-get swank :packets-read)
                                     (client-stats-get swank :connection-closed)))))
    (let* ((errors (loop for c in (remove nil (list push swank))
                         for err = (connection-error-text c)
                         when err collect err))
          (push-state (cond
                        ((null push) "push: none")
                        ((eq 0 (client-stats-get push :connection-closed)) "push: connected")
                        (t "push: closed")))
          (swank-state (cond
                         ((null swank) "swank: none")
                         ((eq 0 (client-stats-get swank :connection-closed)) "swank: connected")
                         (t "swank: closed")))
          (readers (if (model-readers-running model) "readers: on" "readers: off"))
          (picked (or (model-picked-agent model) "no agent"))
          (notes (append (remove nil (list (model-note model)))
                         errors)))
      (setf (model-status-text model)
            (one-line
             (format nil "~A | ~A | ~A | agent: ~A~@[ | ~A~]"
                     swank-state push-state readers picked
                     (when notes (last-error-of notes)))))))
  model)

(defun last-error-of (errors)
  "The most recent error text of ERRORS (newest is last)."
  (or (car (last errors)) ""))
(export 'last-error-of)

(defun note-error (model error)
  "Record ERROR as the operator-facing note, without dropping the previous one if
ERROR is empty. The note is stored on the model so `refresh-status` (which runs at
the end of every update and rebuilds status-text from connection stats) still shows
it — writing status-text directly here would be overwritten before the next render."
  (when (and error (not (string= error "")))
    (setf (model-note model) (one-line error)))
  model)

;;;; --- panes -----------------------------------------------------------

(defun build-panes (model)
  "Build the five pane components. Idempotent: rebuilding is cheap and lets init be
re-entered after a resize."
  (setf (model-chat-viewport model) (make-chat-viewport)
        (model-chat-textarea model) (make-chat-textarea)
        (model-repl-viewport model) (make-repl-viewport)
        (model-repl-textarea model) (make-repl-textarea)
        (model-agent-viewport model) (make-agent-viewport))
  model)
(export 'build-panes)

(defun refresh-agent-viewport (model)
  "Push the current agent snapshot into the agent pane viewport."
  (let ((vp (model-agent-viewport model)))
    (when vp (tui.viewport:viewport-set-content vp (render-agent-rows (model-agents model)))))
  model)

;;;; --- agent lights and per-agent state (M004/S04 T04) ----------------

(defun agent-light (agent)
  "The v1 green/red/yellow light for an agent-snapshot plist (D028):
  :yellow  when :pending-approval is non-NIL (the agent is blocked on an approval)
  :red     when :status is :running AND :thread-alive-p is true (busy)
  :green   otherwise (idle/finished/failed/killed, or running with no live thread)
PURE and total: a missing key or a NIL AGENT degrades to :green, and nothing here
signals. There is no true \"busy\" status yet (agent-status has only
running/finished/failed/killed), so red is approximated by running+live-thread and
documented as v1; S05's streaming/budget slice replaces the heuristic."
  (cond
    ((getf agent :pending-approval) :yellow)
    ((and (eq (getf agent :status) :running)
          (getf agent :thread-alive-p))
     :red)
    (t :green)))
(export 'agent-light)

(defun %map-agent-row (model name fn)
  "Return MODEL's agent snapshot with the row named NAME replaced by (FUNCALL FN row).
A NAME that matches no row returns the snapshot unchanged: a status for an agent the
client has not snapshotted is not fatal. The row is copied before FN mutates it, so
the snapshot list stays the source of truth rather than a partially-shared structure."
  (setf (model-agents model)
        (mapcar (lambda (a)
                  (if (and (stringp name) (stringp (getf a :name))
                           (string= (getf a :name) name))
                      (funcall fn a)
                      a))
                (model-agents model)))
  (model-agents model))
(export '%map-agent-row)

(defun %set-agent-status (model name status pending)
  "Set :status to STATUS and :pending-approval to PENDING on the row named NAME.
Returns the updated model-agents list. Used by the status-msg branch; the
approval-needed branch updates only :pending-approval so a richer approval plist
cannot clobber a status."
  (%map-agent-row model name
                  (lambda (a)
                    (let ((copy (copy-list a)))
                      (setf (getf copy :status) status
                            (getf copy :pending-approval) pending)
                      copy))))
(export '%set-agent-status)

(defun %set-agent-pending (model name pending)
  "Set only :pending-approval to PENDING on the row named NAME, preserving :status.
Returns the updated model-agents list."
  (%map-agent-row model name
                  (lambda (a)
                    (let ((copy (copy-list a)))
                      (setf (getf copy :pending-approval) pending)
                      copy))))
(export '%set-agent-pending)

(defun resolve-pending-approval (model decision)
  "Resolve the picked agent's pending approval with DECISION (a keyword such as
:grant-once). Returns MODEL.
On success the local pending state is cleared OPTIMISTICALLY (research risk 9: the
confirming :status push corrects it if the image disagrees), a local confirmation
line is appended to the chat pane, and the agent pane is refreshed. With no picked
agent or no pending approval it records a status-bar error and changes nothing. On
an RPC error it KEEPS the pending state and records the error, so the operator can
retry."
  (let ((picked (model-picked-agent model))
        (pending (model-pending-approval model)))
    (cond
      ((null picked)
       (note-error model "no agent picked — cannot resolve approval")
       model)
      ((null pending)
       (note-error model "no pending approval to resolve")
       model)
      (t
       (multiple-value-bind (value error)
           (rpc-resolve-approval (model-swank-connection model) picked decision)
         (declare (ignore value))
         (if error
             (note-error model (format nil "resolve failed: ~A" error))
             (progn
               (setf (model-pending-approval model) nil)
               (%set-agent-pending model picked nil)
               (refresh-agent-viewport model)
               (model-append-chat-line model
                                       (format nil "resolved ~A: ~A" picked decision))))
         ;; refresh-status folds the note (on error) into the status line; on success
         ;; it is a no-op rebuild. Doing it here keeps the function self-contained for
         ;; the headless test, which calls it directly rather than through update.
         (refresh-status model)
         model)))))
(export 'resolve-pending-approval)

;;;; --- init ------------------------------------------------------------

(defmethod tui:init ((model tui-model))
  "Build the panes, take the initial projections, subscribe, and start the readers.
Returns the initial tick command.
ORDER MATTERS: the panes are built first so the view is valid even if every RPC
fails; the RPCs run second; the subscribe third; and the reader thread LAST, only when
the program is running. Starting the reader earlier would have `tui:send` drop every
message it decoded, because `send` returns without enqueuing unless program-running is
T — a silently dead reader is the worst failure this UI can have.
Nothing here signals: every failure is recorded and the last good state is kept."
  (build-panes model)
  (refresh-status model)
  ;; agent snapshot
  (multiple-value-bind (agents error)
      (rpc-agent-snapshot (model-swank-connection model))
    (when agents
      (setf (model-agents model) agents)
      (refresh-agent-viewport model))
    (note-error model error))
  ;; default the picked agent to the first snapshot row (sorted by name for a stable
  ;; choice) so a client started without --agent still has a society view and a
  ;; target; --agent overrides it by being set before init runs.
  (when (and (null (model-picked-agent model)) (model-agents model))
    (let ((names (sort (remove nil (mapcar (lambda (a) (getf a :name)) (model-agents model)))
                       #'string<)))
      (when names (setf (model-picked-agent model) (first names)))))
  ;; initial transcript
  (when (model-picked-agent model)
    (multiple-value-bind (events cursor error)
        (rpc-transcript-delta (model-swank-connection model)
                               (model-picked-agent model) (model-cursor model))
      (dolist (line (mapcar #'event-to-line (or events '())))
        (model-append-chat-line model line))
      (when (integerp cursor) (setf (model-cursor model) cursor))
      (note-error model error)))
  ;; subscribe on the push channel to EVERY agent (D028): each row's light is live,
  ;; not just the picked one. When the snapshot is empty the picked name is still
  ;; subscribed so a later --agent run has a channel. A failed subscribe is noted,
  ;; never signalled.
  (let ((push (model-push-connection model)))
    (when push
      (let ((names (remove-duplicates
                    (or (remove nil (mapcar (lambda (a) (getf a :name)) (model-agents model)))
                        (list (model-picked-agent model)))
                    :test #'string=)))
        (dolist (agent names)
          (when agent
            (handler-case
                (progn
                  (write-wire push (list 'subscribe :agent agent))
                  nil)
              (error (e)
                (handler-case (client-note-error! push e) (error () nil))
                (note-error model (format nil "subscribe failed: ~A" e)))))))))
  (refresh-agent-viewport model)
  ;; the reader thread, last
  (let ((push (model-push-connection model)))
    (when (and push (program-running-p (model-program model)))
      (handler-case
          (progn (start-wire-reader push)
                 (setf (model-readers-running model) t))
        (error (e)
          (handler-case (client-note-error! push e) (error () nil))
          (note-error model (format nil "reader failed to start: ~A" e))))))
  (refresh-status model)
  (tui:tick *tui-init-tick*))
(export 'tui:init)

;;;; --- update ----------------------------------------------------------

(defun %quit-cmd ()
  "The command that tears the program down."
  (lambda () (tui:make-quit-msg)))
(export '%quit-cmd)

(defun handle-key (model msg)
  "Route one key message.
Enter in the chat textarea sends `inject-note` with the picked agent's handle;
Enter in the REPL textarea evals the form with `sexpr.repl:*agent*` bound.
Ctrl+C and Escape quit; Tab cycles focus between chat and repl."
  (let ((key (tui:key-msg-key msg))
        (ctrl (tui:key-msg-ctrl msg)))
    (cond
      ((and ctrl (characterp key) (char= key #\c))
       (setf (model-quitting model) t)
       (values model (%quit-cmd)))
      ((eq key :escape)
       (setf (model-quitting model) t)
       (values model (%quit-cmd)))
      ((eq key :tab)
       (setf (model-focused model) (if (eq (model-focused model) :chat) :repl :chat))
       (let ((ta (if (eq (model-focused model) :chat)
                     (model-chat-textarea model)
                     (model-repl-textarea model))))
         (when ta (tui.textarea:textarea-focus ta)))
       (values model nil))
      ((eq key :enter)
       (handle-enter model))
      (t
       (let* ((ta (if (eq (model-focused model) :chat)
                      (model-chat-textarea model)
                      (model-repl-textarea model)))
              (other (if (eq (model-focused model) :chat)
                         (model-repl-textarea model)
                         (model-chat-textarea model)))
              (cmd nil))
         (when ta
           (multiple-value-setq (ta cmd)
             (tui.textarea:textarea-update ta msg))
           (setf (model-chat-textarea model) ta
                 (model-repl-textarea model)
                 (if (eq (model-focused model) :chat) ta other))))
         (values model cmd)))))

(defun handle-enter (model)
  "Handle Enter in the focused textarea.
Chat Enter sends `inject-note` with the picked agent's handle and renders a
local confirmation. REPL Enter evals the form with `sexpr.repl:*agent*` bound
to the picked agent and renders the result. The textarea is reset after
either. A NIL handle produces a status-bar error, not a crash."
  (if (eq (model-focused model) :chat)
      (send-chat-note model)
      (send-repl-form model)))
(export 'handle-enter)

(defun send-chat-note (model)
  "Send a chat note to the picked agent via `sexpr.tui:inject-note`.
Uses the agent's :handle (never its name). Fire-and-forget: the confirmation
is rendered locally; a reply only appears if the agent is actually running.
`subagent-note` appends a user event and does not drive a model turn."
  (let* ((ta (model-chat-textarea model))
         (text (and ta (tui.textarea:textarea-value ta))))
    (cond
      ((or (null text) (string= text ""))
       (values model nil))
      (t
       (let ((conn (model-swank-connection model))
             (picked (model-picked-agent model)))
         (cond
           ((null conn)
            (note-error model "no swank connection — cannot send note")
            (values model nil))
           ((null picked)
            (note-error model "no agent picked — cannot send note")
            (values model nil))
           (t
            (let* ((agent (find picked (model-agents model)
                                 :key (lambda (a) (getf a :name))
                                 :test #'string=))
                   (handle (and agent (getf agent :handle))))
              (cond
                ((null handle)
                 (note-error model
                             (format nil "no handle for agent ~A — cannot send note" picked))
                 (values model nil))
                (t
                 (let* ((form-text (format nil "(sexpr.tui:inject-note ~A ~A)"
                                           (swank-escape-string handle)
                                           (swank-escape-string text)))
                        (id (swank-next-id conn)))
                   (handler-case
                       (write-packet conn (rpc-payload form-text :id id))
                     (error (e)
                       (handler-case (client-note-error! conn e) (error () nil))
                       (note-error model (format nil "note failed: ~A" e))))
                   (model-append-chat-line model
                                           (format nil "noted ~A: ~A" handle text))
                   (when ta (tui.textarea:textarea-reset ta))
                   (values model nil))))))))))))
(export 'send-chat-note)

(defun send-repl-form (model)
  "Send a REPL form to the image, wrapped in a let that binds
`sexpr.repl:*agent*` to the picked agent. The form is eval'd synchronously
and the result is rendered into the REPL pane."
  (let* ((ta (model-repl-textarea model))
         (text (and ta (tui.textarea:textarea-value ta))))
    (cond
      ((or (null text) (string= text ""))
       (values model nil))
      (t
       (let ((conn (model-swank-connection model))
             (name (model-picked-agent model)))
         (cond
           ((null conn)
            (note-error model "no swank connection — cannot eval")
            (values model nil))
           (t
            (let ((form-text (format nil "(let ((sexpr.repl:*agent* (gethash ~A sexpr.agents:*agent-table*))) ~A)"
                                    (swank-escape-string (or name ""))
                                    text)))
              (multiple-value-bind (value error)
                  (swank-rpc conn form-text)
                (model-append-repl-line model
                                        (format nil "~A=> ~A" text
                                                (if error
                                                    (format nil "ERR: ~A" error)
                                                    (format nil "~A" value))))
                (note-error model (when error (format nil "eval: ~A" error))))
              (when ta (tui.textarea:textarea-reset ta))
              (values model nil)))))))))
(export 'send-repl-form)

(defun resize-panes (model)
  "Re-derive the pane dimensions from the new window size. The chat and REPL columns
share one width, leaving *agent-width* plus padding for the right column."
  (setf (model-term-width model) (max 20 (model-term-width model))
        (model-term-height model) (max 8 (model-term-height model)))
  (let ((w (min *chat-width*
                (max 20 (- (model-term-width model) *agent-width* 8)))))
    (when (model-chat-viewport model)
      (setf (tui.viewport:viewport-width (model-chat-viewport model)) w))
    (when (model-chat-textarea model)
      (setf (tui.textarea:textarea-width (model-chat-textarea model)) w))
    (when (model-repl-viewport model)
      (setf (tui.viewport:viewport-width (model-repl-viewport model)) w))
    (when (model-repl-textarea model)
      (setf (tui.textarea:textarea-width (model-repl-textarea model)) w))
    (when (model-agent-viewport model)
      (setf (tui.viewport:viewport-width (model-agent-viewport model)) *agent-width*)))
  model)
(export 'resize-panes)

(defmethod tui:update ((model tui-model) msg)
  "Handle one message and return (VALUES model cmd).
Dispatch order: wire push messages first (they carry content), then RPC results, then
window size, then keys, then quit. `update-message` is the TUITION convention, but this
model needs to sequence two effects per message (apply state, then refresh status), so
the single `update` method owns the dispatch."
  (multiple-value-bind (next-model cmd)
      (cond
    ;; push channel: a streamed fragment
    ((delta-msg-p msg)
     (let ((agent (delta-msg-agent msg))
           (content (delta-msg-content msg)))
       (when (or (null agent)
                 (null (model-picked-agent model))
                 (string= agent (model-picked-agent model)))
         (model-append-chat-line model (or content ""))))
     (values model nil))
    ;; push channel: backpressure — the server dropped fragments
    ((resync-msg-p msg)
     (let* ((cursor (or (resync-msg-cursor msg) (model-cursor model)))
            (agent (model-picked-agent model))
            (events nil) (new-cursor cursor) (error nil))
       (when agent
         (multiple-value-setq (events new-cursor error)
           (rpc-transcript-delta (model-swank-connection model) agent cursor))
         (dolist (line (mapcar #'event-to-line (or events '())))
           (model-append-chat-line model line))
         (when (integerp new-cursor) (setf (model-cursor model) new-cursor)))
       ;; an empty refetch is tolerated: transcript-length does not advance mid-stream,
       ;; so nothing-new is the expected outcome of a mid-stream resync.
       (note-error model error)
       (setf (model-status-text model)
             (one-line (format nil "resync: refetched from cursor ~D~@[ (~A)~]"
                               cursor (or error "")))))
     (values model nil))
    ;; push channel: the subscribe race-closure
    ((subscribed-msg-p msg)
     (let* ((cursor (subscribed-msg-cursor msg))
            (agent (or (subscribed-msg-agent msg) (model-picked-agent model)))
            (picked (model-picked-agent model))
            (events nil) (new-cursor cursor) (error nil))
       (cond
         ;; a reply for an agent we are not showing: adopt only when nothing is
         ;; picked, otherwise do NOT refetch — this is the gate that stops N
         ;; subscribe replies firing N swank RPCs at init (research risk 5).
         ((null agent) nil)
         ((null picked)
          (setf (model-picked-agent model) agent)
          (multiple-value-setq (events new-cursor error)
            (rpc-transcript-delta (model-swank-connection model) agent cursor))
          (dolist (line (mapcar #'event-to-line (or events '())))
            (model-append-chat-line model line))
          (when (integerp new-cursor) (setf (model-cursor model) new-cursor))
          (note-error model error))
         ((string= agent picked)
          (multiple-value-setq (events new-cursor error)
            (rpc-transcript-delta (model-swank-connection model) agent cursor))
          (dolist (line (mapcar #'event-to-line (or events '())))
            (model-append-chat-line model line))
          (when (integerp new-cursor) (setf (model-cursor model) new-cursor))
          (note-error model error))
         (t nil)))
     (values model nil))
    ;; push channel: a per-agent status update (S04)
    ((status-msg-p msg)
     (let ((agent (status-msg-agent msg))
           (status (status-msg-status msg))
           (pending (status-msg-pending-approval msg)))
       (when agent
         (%set-agent-status model agent status pending)
         (when (and (model-picked-agent model)
                    (string= agent (model-picked-agent model)))
           (setf (model-pending-approval model) pending))
         (refresh-agent-viewport model)))
     (values model nil))
    ;; push channel: an agent blocked on an approval (S04)
    ((approval-needed-msg-p msg)
     (let* ((agent (approval-needed-msg-agent msg))
            (pending (list :agent agent
                           :capability (approval-needed-msg-capability msg)
                           :target (approval-needed-msg-target msg)
                           :description (approval-needed-msg-description msg)
                           :restarts (approval-needed-msg-restarts msg))))
       (when agent
         ;; update only :pending-approval, so the richer plist cannot clobber the
         ;; status the last status-msg set.
         (%set-agent-pending model agent pending)
         (when (and (model-picked-agent model)
                    (string= agent (model-picked-agent model)))
           (setf (model-pending-approval model) pending))
         (refresh-agent-viewport model)))
     (values model nil))
    ;; swank: a REPL or RPC reply rendered into the REPL pane
    ((rpc-result-msg-p msg)
     (let ((form (rpc-result-msg-form msg))
           (value (rpc-result-msg-value msg))
           (err (rpc-result-msg-error msg)))
       (model-append-repl-line model
                               (format nil "~A=> ~A" (or form "?")
                                       (if err
                                           (format nil "ERR: ~A" err)
                                           (format nil "~A" value))))
       (note-error model (when err (format nil "eval: ~A" err))))
     (values model nil))
    ;; a wire packet we could not dispatch: show it, never drop it
    ((wire-ignored-msg-p msg)
     (note-error model
                 (format nil "ignored: ~A"
                         (or (wire-ignored-msg-op msg)
                             (format nil "~S" (wire-ignored-msg-form msg)))))
     (values model nil))
    ((connection-closed-msg-p msg)
     (note-error model
                 (format nil "push closed: ~A" (or (connection-closed-msg-reason msg) "eof")))
     (values model nil))
    ;; window resize: reflow every pane
    ((tui:window-size-msg-p msg)
     (setf (model-term-width model) (tui:window-size-msg-width msg)
           (model-term-height model) (tui:window-size-msg-height msg))
     (resize-panes model)
     (values model nil))
    ;; cursor blink and the fallback poll
    ((tui:tick-msg-p msg) (values model (tui:tick *tui-init-tick*)))
    ;; quit
    ((tui:quit-msg-p msg)
     (setf (model-quitting model) t)
     (values model (%quit-cmd)))
    ;; keyboard
    ((tui:key-msg-p msg) (handle-key model msg))
      (t (values model nil)))
    (refresh-status next-model)
    (values next-model cmd)))

;;;; --- view ------------------------------------------------------------

(defmethod tui:view ((model tui-model))
  "Render the full frame as one string. Pure: reads only model state, never a live
connection. This is the assertion surface for the headless tests."
  (compose-layout
   (when (model-chat-viewport model)
     (tui:join-vertical :left
                        (tui.viewport:viewport-view (model-chat-viewport model))
                        (when (model-chat-textarea model)
                          (tui.textarea:textarea-view (model-chat-textarea model)))))
   (when (model-repl-viewport model)
     (tui:join-vertical :left
                        (tui.viewport:viewport-view (model-repl-viewport model))
                        (when (model-repl-textarea model)
                          (tui.textarea:textarea-view (model-repl-textarea model)))))
   (when (model-agent-viewport model)
     (tui.viewport:viewport-view (model-agent-viewport model)))
   (model-status-text model)))
(export 'tui:view)
