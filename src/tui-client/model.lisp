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

(defparameter *tui-poll-interval* 5
  "Ticks between fallback polls when the push channel is absent or closed. At the
default 0.5s tick that is a 2.5s poll — slow enough not to hammer swank, fast
enough for an operator to see a status change without the push channel. The poll
is the documented recovery path for an image that came up without one
(docs/sexpr-tui.md §11); without it the agent pane simply froze after init.")
(export '*tui-poll-interval*)

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
   (in-flight :initform nil :accessor model-in-flight
              :documentation "The growing line of the PICKED agent's in-flight stream,
or NIL when no turn is streaming. Deltas accumulate here instead of each becoming its
own scrollback line, so a streamed sentence renders as ONE growing line rather than
one word per line (research F5). The value is committed to the scrollback as a single
line by finalize-msg and cleared; model-switch-agent clears it too, because a
half-streamed line for the old agent must never bleed into the new transcript.")
   (in-flight-reasoning :initform nil :accessor model-in-flight-reasoning
              :documentation "The growing reasoning/thinking line, separate from
the model's actual reply. :reasoning deltas accumulate here instead of in
model-in-flight, so the TUI can render the thinking block in grey and keep it
visually distinct from the reply. Committed as a separate scrollback line by
finalize-msg, before the reply line.")
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
   (follow-p :initform t :accessor model-follow-p
             :documentation "Whether the chat viewport follows the newest line. T at
the bottom; the user scrolling up holds position so history stays put while a turn
streams (cl-tuition's viewport supports scrolling but nothing in the client used it
until the wheel/page keys were wired).")
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
   (subscriptions :initform nil :accessor model-subscriptions
                  :documentation "Agent names this client has subscribed on the push
channel. Tracked so a poll/reconcile never subscribes twice: the server registers
one listener per subscribe, and a duplicate would double-deliver every delta.")
   (poll-interval :initarg :poll-interval :initform *tui-poll-interval*
                  :accessor model-poll-interval
                  :documentation "How many ticks between fallback polls when the push
channel is absent or closed. See *TUI-POLL-INTERVAL*.")
   (poll-tick :initform 0 :accessor model-poll-tick
              :documentation "Ticks since the last fallback poll.")
   (reconnect-cooldown :initarg :reconnect-cooldown :initform 0
                       :accessor model-reconnect-cooldown
                       :documentation "Ticks before another reconnect attempt. A
closed channel is retried on a throttle so a dead image cannot turn the TUI
into a hot loop of connect failures.")
   (pending-repl-p :initform nil :accessor model-pending-repl-p
                   :documentation "T while a REPL eval runs off the TEA thread.
The status bar says so and Ctrl+X abandons the wait.")
   (repl-generation :initform 0 :accessor model-repl-generation
                    :documentation "Bumped by CANCEL-REPL so an in-flight worker's
result is recognized as stale and dropped instead of rendered.")
   (last-async-result :initform nil :accessor model-last-async-result
                      :documentation "Headless-test hook: with no tuition program,
the REPL worker stores its result message here instead of calling tui:send.")
   (quitting :initform nil :accessor model-quitting)
   ;; --- P2 input UX ---------------------------------------------------
   (input-history :initform nil :accessor model-input-history
                  :documentation "Submitted inputs, NEWEST FIRST, shared by both
panes. Up/Down recalls them; the focused textarea's current draft is preserved
while browsing.")
   (history-index :initform nil :accessor model-history-index
                  :documentation "Index into INPUT-HISTORY while browsing, or NIL
when the operator is typing a fresh line.")
   (history-draft :initform nil :accessor model-history-draft
                  :documentation "The in-progress text saved when history
browsing began, restored when the browse ends.")
   (overlay :initform nil :accessor model-overlay
             :documentation "NIL, :HELP, :PALETTE, or :SEARCH. While non-NIL the
chat column renders the overlay instead of the transcript and the input line
becomes the overlay's query/selection.")
   (overlay-input :initform "" :accessor model-overlay-input
                  :documentation "The palette filter or search query.")
   (search-matches :initform nil :accessor model-search-matches
                   :documentation "Chat scrollback lines matching the current
search query, newest first.")
   ;; --- P2 render batching --------------------------------------------
   (fragments-since-render :initform 0 :accessor model-fragments-since-render
                           :documentation "Streamed fragments applied since the
last chat re-render. Rendering every fragment is correct but wasteful; the
model prose branch renders at most every *TUI-RENDER-BATCH* fragments and the
finalize branch always commits through model-append-chat-line, which renders.")
   (fit-cache :initform nil :accessor model-fit-cache
              :documentation "Alist of (LINE . WIDTH) -> fitted display lines,
so a streamed turn re-fits only the growing in-flight line rather than the
whole scrollback. Cleared by /clear and on a width change.")
   ;; --- P2 layout/theme -----------------------------------------------
   (compact-p :initarg :compact-p :initform nil :accessor model-compact-p
              :documentation "Whether SEXPR_TUI_COMPACT dropped the pane borders
and widened the transcript column.")))

;;;; --- bounded scrollback ----------------------------------------------

(defun %cap (list cap)
  "Keep the newest CAP entries of LIST, dropping the oldest. The drop is on the tail
because entries are stored newest-first."
  (if (<= (length list) cap) list (subseq list 0 cap)))

(defun append-line (list cap line)
  "Append LINE to the bounded LIST, newest first. LINE must already be ONE logical
display line (flat, unfitted): the chat and REPL renderers fit lines to the pane
width, so the stored value keeps its whole content and a resize can re-fit it.
Returns the new list."
  (%cap (cons line list) cap))
(export 'append-line)

(defun flatten-line (line)
  "Replace every newline in LINE with a space, so one transcript event is one
logical line. Fitting to the pane is WRAP-TEXT's job, never a character-count
clip: a clip would silently drop content and over-measure wide characters."
  (substitute #\Space #\Newline (or line "")))
(export 'flatten-line)

(defun %fit-for-pane (logical-lines width)
  "Wrap each entry of LOGICAL-LINES to WIDTH columns, preserving order. Delegates
to view.lisp's WRAP-TEXT, so styled text (the grey reasoning block) and wide
characters are fitted without corruption or overflow."
  (mapcan (lambda (line) (wrap-text line width)) logical-lines))
(export '%fit-for-pane)

(defun model-render-chat (model)
  "Set the chat viewport content to the committed scrollback followed by the in-flight
line (when any), then scroll to the bottom. This is the ONE place the chat pane content
is written, so a committed line and a growing in-flight line always render together and
a streamed turn re-renders once per fragment instead of once per fragment-plus-whole-
scrollback (research F5: the O(n^2) shape). The in-flight line is NOT in the scrollback:
it is appended at render time, so it can grow without touching the bounded scrollback
cap and is committed exactly once by finalize-msg."
  (let ((vp (model-chat-viewport model)))
    (when vp
      (let* ((width (chat-pane-width model))
             ;; NON-DESTRUCTIVE reverse: the scrollback slot is stored NEWEST FIRST,
             ;; so the view needs it oldest-first. NRVERSE would mutate the slot's cons
             ;; cells in place and silently truncate the bounded scrollback.
             (display (nreverse (loop for line in (model-scrollback model)
                                      append (model-fit-line model line width)))))
        (when (model-in-flight-reasoning model)
          (setf display
                (append display
                        (wrap-text (tui:render-styled
                                    (tui:make-style :foreground tui:*fg-bright-black*)
                                    (format nil "~A: ~A"
                                            :reasoning (model-in-flight-reasoning model)))
                                   width))))
        (when (model-in-flight model)
          (setf display (append display (wrap-text (model-in-flight model) width))))
        (tui.viewport:viewport-set-content vp (lines-to-string display))
        ;; FOLLOW MODE: at the bottom the transcript tracks new output; scrolled
        ;; away it holds its position so a streaming turn does not yank the
        ;; operator back down mid-read.
        (when (model-follow-p model)
          (tui.viewport:viewport-goto-bottom vp)))))
  model)
(export 'model-render-chat)

(defun model-append-chat-line (model line)
  "Append LINE to the chat scrollback, re-cap it, and re-render the chat pane via
model-render-chat so any in-flight streamed line stays visible below it. The viewport
follows the newest line, which is what makes a streamed turn readable without
scrolling."
  (let ((flat (flatten-line line)))
    ;; Opt-in timestamps/role colour are applied at this ONE choke point, so every
    ;; chat line (event, tool, budget, note) is treated alike and no caller can
    ;; forget the decoration. With both knobs off FLAT is stored unchanged.
    (when (or *tui-timestamps-p* *tui-role-styles-p*)
      (setf flat (decorate-chat-line flat (line-role flat))))
    (setf (model-scrollback model)
          (append-line (model-scrollback model)
                       (model-scrollback-cap model)
                       flat)))
  (model-render-chat model)
  model)

(defun model-append-repl-line (model line)
  "Append LINE to the REPL output as one logical line, bounded by repl-cap, then
re-render wrapped to the pane width. A REPL result can be arbitrarily long (a
printed structure, a file listing), so it gets the same fitting as chat."
  (setf (model-repl-lines model)
        (append-line (model-repl-lines model) (model-repl-cap model)
                     (flatten-line line)))
  (let ((vp (model-repl-viewport model)))
    (when vp
      ;; NON-DESTRUCTIVE reverse for the same reason as MODEL-RENDER-CHAT: the
      ;; repl-lines slot is stored newest-first and NRVERSE would truncate it.
      (tui.viewport:viewport-set-content
       vp (lines-to-string
           (nreverse (copy-list
                      (%fit-for-pane (model-repl-lines model)
                                     (chat-pane-width model))))))
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
  model  -> (getf event :content), with reasoning (if present) in grey above
  result -> (getf event :text)   (the printed projection, R023)
A missing or malformed event degrades to a line, never a condition: a single bad event
in a 10x burst must not blank the transcript."
  (let* ((text (or (getf event :content)
                   (getf event :text)
                   (when (stringp event) event)))
         (reasoning (getf event :reasoning)))
    ;; If the model event carries a reasoning (thinking) block, render it
    ;; in grey (bright-black) as a separate line BEFORE the actual reply.
    ;; The two are separate fields in the provider's response, so the
    ;; thinking block is never mixed into the reply text.
    (if (and reasoning (stringp reasoning) (string/= reasoning ""))
        (format nil "~A: ~A~%~A: ~A"
                :reasoning (tui:render-styled
                             (tui:make-style :foreground tui:*fg-bright-black*)
                             reasoning)
                (getf event :type :event) (or text ""))
        (format nil "~A: ~A" (getf event :type :event) (or text "")))))
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

(defvar *swank-rpc-lock* (sb-thread:make-mutex :name "tui-swank-rpc")
  "Serializes the full request/response cycle of every swank RPC. The async REPL
worker and any synchronous caller (poll, resync, note) share one connection, so
the write of a packet and the read of its reply must be one critical section or
two threads interleave half a frame each.")
(export '*swank-rpc-lock*)

(defun swank-rpc (connection form-text &key (package "SWANK-IO-PACKAGE"))
  "Run one sexpr.tui RPC over SWANK-CONNECTION. Returns (VALUES value error).
FORM-TEXT is packet TEXT (see the file header). ERROR is NIL on success, otherwise a
string that belongs in the status bar: :abort, :reader-error, :eof, :no-match, or the
text of a condition the connection raised. Nothing is ever signalled out of here — the
caller decides what to do with the last error. THE WHOLE CYCLE IS SERIALIZED under
*SWANK-RPC-LOCK* (an async worker may share this connection).
PACKAGE is the buffer package the image reads the form in (default
SWANK-IO-PACKAGE, which works for fully-qualified forms only — see
send-repl-form for why the REPL form needs COMMON-LISP-USER)."
  (when (null connection)
    (return-from swank-rpc (values nil "no swank connection")))
  (handler-case
      (sb-thread:with-mutex (*swank-rpc-lock*)
        (let ((reply (swank-eval connection form-text :package package)))
          (cond
            ((eq (getf reply :status) :ok)
             (values (swank-value connection reply) nil))
            (t (values nil (reply-error-text reply))))))
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

;;; --- async REPL ------------------------------------------------------
;;;
;;; Every other RPC was synchronous, so a REPL form that called the model froze
;;; the whole UI for the length of the turn (up to the 30s readout timeout). The
;;; REPL is where that hurts most — it is the operator's live console — so its
;;; eval runs on a background thread and delivers an ordinary rpc-result-msg.
;;; SWANK-RPC serializes the wire under *SWANK-RPC-LOCK*, so a worker and the
;;; poller cannot interleave packets; a cancel bumps MODEL-REPL-GENERATION and
;;; the stale result is dropped rather than rendered.

(defparameter *tui-async-repl* t
  "When T (the production default), a REPL eval runs on a background thread and
delivers an rpc-result-msg, so a slow form cannot freeze typing. NIL keeps the
synchronous path; the headless suite binds it so canned replies are consumed
deterministically.")
(export '*tui-async-repl*)

(defun queue-async-repl (model connection form-text text)
  "Run one REPL RPC off the TEA thread and deliver the result as a message.
Returns MODEL immediately. The worker captures CONNECTION and its GENERATION at
queue time: a reconnect replaces the slot, and a cancel bumps the generation, so
the two races resolve without a lock (a stale result is dropped). With no
tuition program the message lands in MODEL-LAST-ASYNC-RESULT for the headless
tests. Never signals."
  (let ((program (model-program model))
        (generation (incf (model-repl-generation model))))
    (setf (model-pending-repl-p model) t
          (model-last-async-result model) nil)
    (refresh-status model)
    (sb-thread:make-thread
     (lambda ()
       (let (value error)
         (multiple-value-setq (value error) (swank-rpc connection form-text))
         (let* ((live (eql generation (model-repl-generation model)))
                (message (if live
                             (make-rpc-result-msg :form text :value value
                                                 :error error)
                             (make-async-done-msg :cancelled t))))
           (if program
               (tui:send program message)
               (setf (model-last-async-result model) message))))
       nil)
     :name "tui-repl")
  model))
(export 'queue-async-repl)

(defun cancel-repl (model)
  "Abandon the in-flight REPL eval: bump the generation so the worker's result
is dropped, clear the pending flag and say so. The blocking read itself cannot
be killed, but the UI has been responsive the whole time; only the stale render
is prevented. Returns MODEL."
  (when (model-pending-repl-p model)
    (incf (model-repl-generation model))
    (setf (model-pending-repl-p model) nil)
    (note-error model "repl cancelled")
    (refresh-status model))
  model)
(export 'cancel-repl)

;;; --- fallback poll ---------------------------------------------------
;;;
;;; The push channel is the normal path, but it is OPTIONAL: an image may come up
;;; without one (the wrapper omits --push-port when nothing listens). The
;;; documented recovery is a poll (docs/sexpr-tui.md §11), not a frozen UI: tick
;;; re-arms itself forever, and this turns some of those ticks into a swank
;;; reconcile. It also closes the membership gap until agent-added/agent-removed
;;; exist on the bus: a society that grows during a session becomes visible.

(defun push-connection-live-p (model)
  "Whether MODEL's push channel exists and has not recorded a close. A NIL
connection and a closed one are both 'no deltas' and both fall back to polling."
  (let ((push (model-push-connection model)))
    (and push (eql 0 (client-stats-get push :connection-closed)))))

(defun reconcile-subscriptions (model agents)
  "Subscribe the live push channel to every agent in AGENTS not already covered,
and record the new set on MODEL. Membership changes are not pushed yet, so the
poller is what keeps a growing society visible; subscribing twice would register
two listeners and double-deliver every delta, hence the MODEL-SUBSCRIPTIONS set.
A failed write is noted, never signalled."
  (let ((push (model-push-connection model)))
    (when (and push (push-connection-live-p model))
      (let ((known (model-subscriptions model)))
        (dolist (name (sort (remove nil (mapcar (lambda (a) (getf a :name)) agents))
                            #'string<))
          (unless (member name known :test #'string=)
            (handler-case
                (progn
                  (write-wire push (list :subscribe :agent name))
                  (push name known)
                  (setf (model-subscriptions model) known))
              (error (e)
                (handler-case (client-note-error! push e) (error () nil))
                (note-error model (format nil "subscribe failed: ~A" e)))))))))
  model)
(export 'reconcile-subscriptions)

(defun poll-image (model)
  "Reconcile the society and the picked transcript over swank. This is the image
speaking as the truth when deltas cannot arrive: refresh agent-snapshot (rows,
statuses, handles, lights), subscribe to any newcomer, then fetch the picked
transcript from the cursor and append what is new. Every failure is noted, never
signalled; a partial success keeps its last good state."
  (let ((conn (model-swank-connection model)))
    (when conn
      (multiple-value-bind (agents error)
          (rpc-agent-snapshot conn)
        (when agents
          (setf (model-agents model) agents)
          (reconcile-subscriptions model agents)
          (refresh-agent-viewport model))
        (note-error model error))
      (when (model-picked-agent model)
        (multiple-value-bind (events cursor error)
            (rpc-transcript-delta conn (model-picked-agent model) (model-cursor model))
          (dolist (line (mapcar #'event-to-line (or events '())))
            (model-append-chat-line model line))
          (when (integerp cursor) (setf (model-cursor model) cursor))
          (note-error model error)))))
  model)
(export 'poll-image)

(defun tick-fallback-poll (model)
  "Run POLL-IMAGE on a throttle when the push channel cannot be carrying deltas.
A live push channel makes polling unnecessary (and undesirable: the deltas are the
truth). The counter saturates at MODEL-POLL-INTERVAL and resets on a poll, so the
cadence is one poll per interval regardless of how ticks are paced."
  (if (push-connection-live-p model)
      model
      (let ((tick (1+ (model-poll-tick model))))
        (if (>= tick (max 1 (model-poll-interval model)))
            (progn
              (setf (model-poll-tick model) 0)
              (poll-image model))
            (setf (model-poll-tick model) tick))))
  model)
(export 'tick-fallback-poll)

;;; --- reconnect -------------------------------------------------------
;;;
;;; The wrapper can leave a channel down (--no-server, an image that died, a
;;; network partition) and the image can outlive either socket. The Genera
;;; posture is attach/detach, so a closed channel is RETRIED on a throttle
;;; rather than leaving a zombie UI: a configured-but-closed push or swank
;;; connection is rebuilt, re-subscribed, re-read and reconciled. A channel that
;;; was never configured (NIL — e.g. --push-port omitted) has nothing to retry
;;; and stays on the poll path instead.

(defparameter *tui-reconnect-cooldown* 6
  "Ticks between reconnect attempts once a configured channel is closed. Six
ticks at the default 0.5s tick is three seconds: slow enough not to hammer a
dead host, fast enough for an operator to see the TUI come back after restarting
an image. Only failures are rate-limited; a successful reconnect resets the
cooldown immediately.")
(export '*tui-reconnect-cooldown*)

(defun swank-connection-live-p (model)
  "Whether MODEL's swank channel exists and has not recorded a close."
  (let ((conn (model-swank-connection model)))
    (and conn (eql 0 (client-stats-get conn :connection-closed)))))

(defun reconnect-channels (model)
  "Rebuild whichever CONFIGURED channel is closed. Swank first (every other RPC
needs it), then push (its reader, subscriptions and program slot). Each success
reconciles state; each failure is noted and retried later by the cooldown. A NIL
channel is skipped: it was never configured, so there is nothing to reattach.
Nothing here signals."
  ;; swank
  (let ((old (model-swank-connection model)))
    (when (and old (not (swank-connection-live-p model)))
      (handler-case
          (let ((conn (swank-connect (swank-connection-host old)
                                     (swank-connection-port old))))
            (setf (model-swank-connection model) conn)
            (setf (model-reconnect-cooldown model) 0)
            (note-error model (format nil "swank reconnected ~A:~A"
                                      (swank-connection-host conn)
                                      (swank-connection-port conn)))
            ;; the new channel must carry the society before anything else asks
            (poll-image model))
        (error (e)
          (handler-case (client-note-error! old e) (error () nil))
          (note-error model (format nil "swank reconnect failed: ~A" e))))))
  ;; push
  (let ((old (model-push-connection model)))
    (when (and old (not (push-connection-live-p model)))
      (handler-case
          (let ((conn (connect-push (tui-connection-host old)
                                    (tui-connection-port old)
                                    :program (model-program model))))
            (setf (model-push-connection model) conn)
            (setf (tui-connection-program conn) (model-program model))
            (when (model-program model)
              (start-wire-reader conn)
              (setf (model-readers-running model) t))
            (reconcile-subscriptions model (model-agents model))
            (setf (model-reconnect-cooldown model) 0)
            (note-error model (format nil "push reconnected ~A:~A"
                                      (tui-connection-host conn)
                                      (tui-connection-port conn))))
        (error (e)
          (handler-case (client-note-error! old e) (error () nil))
          (note-error model (format nil "push reconnect failed: ~A" e))))))
  (refresh-status model)
  model)
(export 'reconnect-channels)

(defun maybe-reconnect (model)
  "Throttle reconnect attempts while a CONFIGURED channel is closed. A NIL
channel (e.g. --push-port omitted) is not a failure to retry — it was never
configured, so the client stays on the poll path; only a channel that EXISTS and
has recorded a close is rebuilt. When everything is healthy this costs one
comparison per tick. Returns MODEL."
  (let ((push-closed (let ((c (model-push-connection model)))
                       (and c (not (push-connection-live-p model)))))
        (swank-closed (let ((c (model-swank-connection model)))
                        (and c (not (swank-connection-live-p model))))))
    (when (or push-closed swank-closed)
      (cond
        ((plusp (model-reconnect-cooldown model))
         (decf (model-reconnect-cooldown model)))
        (t
         (setf (model-reconnect-cooldown model) *tui-reconnect-cooldown*)
         (reconnect-channels model)))))
  model)
(export 'maybe-reconnect)

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
    ;; ONE ENTRY PER CONNECTION, keyed by label: an earlier version appended two
    ;; anonymous three-element lists, producing a plist with duplicate keys that
    ;; nothing could read unambiguously.
    (setf (model-stats model)
          (list :push (when push
                        (list :last-error (client-stats-get push :last-error)
                              :packets-read (client-stats-get push :packets-read)
                              :connection-closed (client-stats-get push :connection-closed)))
                :swank (when swank
                         (list :last-error (client-stats-get swank :last-error)
                               :packets-read (client-stats-get swank :packets-read)
                               :connection-closed (client-stats-get swank :connection-closed)))))
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
          ;; an async REPL eval in flight is operator-visible state, not noise:
          ;; it says why a result has not appeared yet.
          (repl (if (model-pending-repl-p model) "repl: busy" "repl: idle"))
          (picked (or (model-picked-agent model) "no agent"))
          (notes (append (remove nil (list (model-note model)))
                         errors)))
      (setf (model-status-text model)
            (one-line
             (format nil "~A | ~A | ~A | ~A | agent: ~A~@[ | ~A~]"
                     swank-state push-state readers repl picked
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

(defun set-focus (model where)
  "Give key input to the text area named WHERE (:chat or :repl) and take it away
from the other one. Returns MODEL.
cl-tuition has no global focus register: textarea-focused is a per-object slot
that textarea-focus sets and textarea-blur clears, so both text areas can hold T
at once and both draw a cursor. Nothing but this function touches either slot, so
the invariant that exactly one text area is focused holds by construction rather
than by convention. Any value other than :repl is treated as :chat."
  (setf (model-focused model) (if (eq where :repl) :repl :chat))
  (when (model-chat-textarea model)
    (if (eq where :repl)
        (tui.textarea:textarea-blur (model-chat-textarea model))
        (tui.textarea:textarea-focus (model-chat-textarea model))))
  (when (model-repl-textarea model)
    (if (eq where :repl)
        (tui.textarea:textarea-focus (model-repl-textarea model))
        (tui.textarea:textarea-blur (model-repl-textarea model))))
  model)
(export 'set-focus)

(defun focused-textarea (model)
  "The text area that owns key input, as (VALUES textarea key). KEY is :chat or
:repl. Returns NIL for the textarea when the slot has never been built, so a
caller can degrade instead of signalling."
  (if (eq (model-focused model) :repl)
      (values (model-repl-textarea model) :repl)
      (values (model-chat-textarea model) :chat)))
(export 'focused-textarea)

(defun update-focused-textarea (model msg)
  "Feed MSG to whichever text area owns key input and store the result back in that
same slot. Returns (VALUES model nil).
Returning the updated component to the slot it came from is the whole point: the
old form wrote both slots at once and, when the REPL was focused, left the chat
slot pointing at the REPL text area, so the next Tab landed on the wrong input.
Nothing here signals: a NIL focused textarea is a no-op that still returns the
model, and textarea-update's command value is always NIL for a key message so it
is discarded by binding only the first return value."
  (if (eq (model-focused model) :repl)
      (when (model-repl-textarea model)
        (multiple-value-bind (next)
            (tui.textarea:textarea-update (model-repl-textarea model) msg)
          (setf (model-repl-textarea model) next)))
      (when (model-chat-textarea model)
        (multiple-value-bind (next)
            (tui.textarea:textarea-update (model-chat-textarea model) msg)
          (setf (model-chat-textarea model) next))))
  (values model nil))
(export 'update-focused-textarea)

(defun build-panes (model)
  "Build the five pane components and size them for the current terminal. Idempotent:
rebuilding is cheap and lets init be re-entered after a resize. Focus is reset to
chat — the demo is a chat client, so the first key press should land in chat and
not in the REPL."
  (setf (model-chat-viewport model) (make-chat-viewport)
        (model-chat-textarea model) (make-chat-textarea)
        (model-repl-viewport model) (make-repl-viewport)
        (model-repl-textarea model) (make-repl-textarea)
        (model-agent-viewport model) (make-agent-viewport))
  (set-pane-dimensions model)
  (set-focus model :chat)
  model)
(export 'build-panes)

(defun refresh-agent-viewport (model)
  "Push the current agent snapshot into the agent pane viewport, highlighting the
picked agent. The picked name is threaded through so the pane's row highlight follows
the model's picked state (S04/T05)."
  (let ((vp (model-agent-viewport model)))
    (when vp
      (let* ((picked-row (find (model-picked-agent model) (model-agents model)
                               :key (lambda (a) (getf a :name)) :test #'string=)))
        (tui.viewport:viewport-set-content
         vp (render-agent-rows (sorted-agents (model-agents model))
                               :picked (model-picked-agent model)
                               :width (agent-pane-inner-width model)
                               :detail (and picked-row
                                           (agent-detail-lines picked-row)))))))
  model)

;;;; --- agent lights and per-agent state (M004/S04 T04) ----------------

(defun agent-light (agent)
  "The green/red/yellow light for an agent-snapshot plist:
  :yellow  when :pending-approval is non-NIL (the agent is blocked on an approval)
  :red     when :streaming is true (a stream is in flight) OR when :status is
           :failed/:killed (a dead agent must be visually distinct from a live one)
  :green   otherwise (idle/finished, or running with no in-flight stream)
PURE and total: a missing key or a NIL AGENT degrades to :green, and nothing here
signals. :streaming is the data-only boolean the image sets while model-step-streaming
runs for that agent; :status is the worker's last announced state."
  (let ((status (getf agent :status)))
    (cond
      ((getf agent :pending-approval) :yellow)
      ((getf agent :streaming) :red)
      ((or (eq status :failed) (eq status :killed)) :red)
      (t :green))))
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

(defun %set-agent-status-keeping-pending (model name status)
  "Set only :status to STATUS on the row named NAME, preserving any
:pending-approval the row already carries. Returns the updated model-agents
list. Used by the status-msg branch for frames that do NOT carry
:pending-approval (the worker start/finish announcements): a finish
announcement must not silently resolve an outstanding approval."
  (%map-agent-row model name
                  (lambda (a)
                    (let ((copy (copy-list a)))
                      (setf (getf copy :status) status)
                      copy))))
(export '%set-agent-status-keeping-pending)

(defun %set-agent-pending (model name pending)
  "Set only :pending-approval to PENDING on the row named NAME, preserving :status.
Returns the updated model-agents list."
  (%map-agent-row model name
                  (lambda (a)
                    (let ((copy (copy-list a)))
                      (setf (getf copy :pending-approval) pending)
                      copy))))
(export '%set-agent-pending)

(defun %set-agent-streaming (model name streaming)
  "Set the data-only :streaming boolean on the row named NAME. Returns the updated
model-agents list. STREAMING is T while a stream is in flight for that agent and NIL
once finalize arrives; AGENT-LIGHT reads it for the red busy light (F6). A NAME that
matches no row is a no-op (the snapshot is unchanged)."
  (%map-agent-row model name
                  (lambda (a)
                    (let ((copy (copy-list a)))
                      (setf (getf copy :streaming) streaming)
                      copy))))
(export '%set-agent-streaming)

;;; --- per-agent content scoping ---------------------------------------
;;;
;;; A society is multi-agent but the chat pane shows ONE transcript, so every
;;; content-bearing wire frame must be scoped to the picked agent. DELTA always
;;; honoured that; FINALIZE, TOOL-START, TOOL-RESULT, BUDGET-EXCEEDED and RESYNC
;;; did not. An out-of-order FINALIZE for a neighbouring agent committed the
;;; picked agent's half-streamed reply; a neighbour's tool output landed in the
;;; picked transcript; a neighbour's resync refetched the picked transcript from
;;; the wrong cursor. One predicate now answers the question everywhere.

(defun agent-is-picked-p (model agent)
  "Whether AGENT names the picked agent whose content belongs in the picked chat
pane. NIL AGENT is treated as the picked agent: the server always sends one, so a
missing field means the frame predates the convention, not a different agent.
PURE: compares against model-picked-agent only."
  (or (null agent)
      (null (model-picked-agent model))
      (and (stringp agent)
           (string= agent (model-picked-agent model)))))
(export 'agent-is-picked-p)

;;; --- pane widths ------------------------------------------------------

(defun chat-pane-width (model)
  "The chat/REPL column width in columns, derived from the current terminal size.
This is the width every chat and REPL line is fitted to (view.lisp's
WRAP-TEXT/TRUNCATE-TEXT), so a long transcript line cannot widen its section box
past the layout."
  (nth 0 (multiple-value-list
         (layout-dimensions (model-term-width model) (model-term-height model)))))
(export 'chat-pane-width)

(defun left-column-width (model)
  "The full width of the left column INCLUDING its border: the strip and the status
bar are padded to this, and the agent pane takes the rest."
  (+ 2 (chat-pane-width model)))
(export 'left-column-width)

(defun agent-pane-inner-width (model)
  "The agent pane's content width: its outer width minus the two border columns.
Rows are truncated to this so a long agent name cannot widen the pane box."
  (max 0 (- (nth 1 (multiple-value-list
                   (layout-dimensions (model-term-width model)
                                      (model-term-height model))))
            2)))
(export 'agent-pane-inner-width)

(defun sorted-agents (agents)
  "AGENTS ordered by :name, with a missing name sorting first. The snapshot's own
order is hash-table iteration order and changes between calls, so the pane is only
predictable if the client sorts it — which sexpr.tui:agent-snapshot says it should.
PURE: returns a new list."
  (sort (copy-list agents)
        (lambda (a b)
          (string< (or (getf a :name) "") (or (getf b :name) "")))))
(export 'sorted-agents)

(defun agent-row-name= (row name)
  "Whether ROW's :name is the string NAME. Missing names never match."
  (and (stringp name)
       (stringp (getf row :name))
       (string= (getf row :name) name)))

(defun %merge-agent-row (model row)
  "Insert ROW into MODEL's snapshot, replacing any row of the same name. ROW is a
data-only projection from the image (agent-added); PURE of I/O. A malformed row
without a name is dropped rather than inserted, so a bad frame cannot poison the
pane."
  (let ((name (getf row :name)))
    (when (stringp name)
      (let ((rows (model-agents model)))
        (setf (model-agents model)
              (if (find name rows :key (lambda (a) (getf a :name)) :test #'string=)
                  (mapcar (lambda (a) (if (agent-row-name= a name) row a)) rows)
                  (cons row rows))))))
  model)
(export '%merge-agent-row)

(defun %drop-agent-row (model name)
  "Remove the snapshot row named NAME and forget its local subscription. Returns
MODEL. Data-only; the caller decides whether to tell the server."
  (when (stringp name)
    (setf (model-agents model)
          (remove name (model-agents model)
                  :key (lambda (a) (getf a :name)) :test #'string=))
    (setf (model-subscriptions model)
          (remove name (model-subscriptions model) :test #'string=)))
  model)
(export '%drop-agent-row)

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

;;;; --- click-to-focus and approval resolution (M004/S04 T05) ----------
;;;
;;; The mouse path is PURE at the hit-test seam: agent-at-mouse and
;;; approval-action-at-mouse read the global zone manager's recorded bounds and a
;;; mouse event, and return a decision — no model, no I/O. That is what makes the
;;; click contract testable from the recorded zone bounds (research risk 2) instead
;;; of hand-computed terminal coordinates. The zone bounds are recorded by the
;;; ROOT zone-scan in tui:view; zone-scan never clears stale zones, so the decision
;;; is validated again against model-agents before any state changes (risk 3).

(defun agent-at-mouse (agents msg)
  "The name of the agent whose \"agent-row:<name>\" zone contains MSG, or NIL.
PURE: it reads the zone manager and the event only. A stale zone (a name no longer in
AGENTS) can still be returned here — MODEL-SWITCH-AGENT re-validates it — but a
stale zone whose bounds are not hit is never returned."
  (loop for a in agents
        for name = (getf a :name)
        for id = (and (stringp name) (format nil "agent-row:~A" name))
        for zone = (and id (tui:zone-get id))
        when (and zone (tui:zone-in-bounds-p zone msg))
          do (return name)))
(export 'agent-at-mouse)

(defun approval-action-at-mouse (msg &optional (decisions *approval-decisions*))
  "The approval decision a click at MSG selects: the DECISIONS member whose zone
(\"approval:<decision>\") contains MSG, or NIL. Every button the strip renders is
hit-testable, so grant-session / grant-always are reachable by mouse and not just
by the two hardcoded keys. PURE."
  (loop for decision in decisions
        for zone = (tui:zone-get (approval-zone-id decision))
        when (and zone (tui:zone-in-bounds-p zone msg))
          do (return decision)))
(export 'approval-action-at-mouse)

(defun model-switch-agent (model name)
  "Re-point the viewport at agent NAME. Returns MODEL.
NAME is validated against the current snapshot first: a click on a stale zone whose
name is no longer in model-agents changes nothing (research risk 3). On a real switch
it sets the picked name, resets the transcript cursor to 0, clears the chat scrollback
and the chat viewport, refetches transcript-delta for the new agent, and refreshes the
agent pane so the highlight moves. An RPC error is recorded on the status bar, never
signalled."
  (when (and (stringp name)
             (find name (model-agents model)
                   :key (lambda (a) (getf a :name)) :test #'string=))
    (setf (model-picked-agent model) name
          (model-cursor model) 0
          (model-scrollback model) nil
          ;; a half-streamed line for the OLD agent must never bleed into the new
          ;; transcript; drop it rather than commit a partial line under the wrong agent.
          (model-in-flight model) nil
          (model-in-flight-reasoning model) nil)
    (let ((vp (model-chat-viewport model)))
      (when vp (tui.viewport:viewport-set-content vp "")))
    (multiple-value-bind (events cursor error)
        (rpc-transcript-delta (model-swank-connection model) name 0)
      (dolist (line (mapcar #'event-to-line (or events '())))
        (model-append-chat-line model line))
      (when (integerp cursor) (setf (model-cursor model) cursor))
      (note-error model error))
    ;; the strip shows the NEW picked agent's pending request, not the old one's.
    ;; Without this, switching to a second waiting agent kept the first one's
    ;; approval on screen and C-g/C-d would resolve the wrong row.
    (let ((row (find name (model-agents model)
                     :key (lambda (a) (getf a :name)) :test #'string=)))
      (setf (model-pending-approval model) (and row (getf row :pending-approval))))
    (refresh-agent-viewport model))
  model)
(export 'model-switch-agent)

(defun handle-mouse (model msg)
  "Handle one mouse event and return (VALUES MODEL NIL).
Only a LEFT mouse PRESS does anything. A click on an approval affordance resolves
the picked agent's pending approval (whichever decision was hit). ANY OTHER CLICK
FALLS THROUGH to the agent rows: while an approval is pending the strip used to own
every click, which made a second waiting agent unreachable — but notes/tui.md §9
wants simultaneous approvals resolved one by one, and that requires being able to
select the other yellow row. Every other event is a no-op."
  (when (and (tui:mouse-press-event-p msg)
             (eq (tui:mouse-event-button msg) :left))
    (let ((action (and (model-pending-approval model)
                       (approval-action-at-mouse
                        msg (approval-decisions (model-pending-approval model))))))
      (if action
          (resolve-pending-approval model action)
          (let ((name (agent-at-mouse (model-agents model) msg)))
            (when name (model-switch-agent model name))))))
  (values model nil))
(export 'handle-mouse)

;;; --- scrolling -------------------------------------------------------
;;;
;;; cl-tuition's viewport already implements wheel/page scrolling, but the client
;;; never called it: unhandled keys went to the focused textarea and only
;;; left-press mouse events were read, so history and long agent lists were
;;; unreachable. The wheel is routed by LAYOUT GEOMETRY (not by a zone mark):
;;; a zone around a whole multi-line pane only records its first line, so a
;;; geometric hit-test is both simpler and total. Coordinates are 1-based, the
;;; convention zone-info-start-x/y already established.

(defun pane-at-mouse (model msg)
  "The pane (:chat, :repl or :agents) under MSG's terminal coordinates, derived
from layout-dimensions; NIL over the chrome rows. The left column is split into
the chat section (its viewport plus the *section-overhead* rows) and the REPL
section below it; anything right of the left column's border is the agent pane.
PURE."
  (let ((x (tui:mouse-event-x msg))
        (y (tui:mouse-event-y msg)))
    (when (and (plusp x) (plusp y))
      (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
          (layout-dimensions (model-term-width model) (model-term-height model))
        (declare (ignore agent-w repl-h agent-h))
        (let ((left-width (+ chat-w 2))
              (chat-rows (+ chat-h *section-overhead*))
              (body-rows (+ chat-h repl-h (* 2 *section-overhead*))))
          (cond
            ((> x left-width) (if (<= y body-rows) :agents nil))
            ((<= y chat-rows) :chat)
            ((<= y body-rows) :repl)
            (t nil)))))))
(export 'pane-at-mouse)

(defun %scroll-viewport (model viewport delta &optional (track-follow nil))
  "Scroll VIEWPORT by DELTA lines (negative up), or to an edge when DELTA is :top
or :bottom. When TRACK-FOLLOW is T, re-derive follow mode from the resulting
position: at the bottom the chat follows new output, scrolled away it holds its
position. A NIL viewport is a no-op. Returns MODEL."
  (when viewport
    (cond
      ((eq delta :top) (tui.viewport:viewport-goto-top viewport))
      ((eq delta :bottom) (tui.viewport:viewport-goto-bottom viewport))
      ((plusp delta) (tui.viewport:viewport-scroll-down viewport delta))
      ((minusp delta) (tui.viewport:viewport-scroll-up viewport (- delta))))
    (when track-follow
      (setf (model-follow-p model)
            (tui.viewport:viewport-at-bottom-p viewport))))
  model)
(export '%scroll-viewport)

(defun scroll-key-delta (model key ctrl)
  "The scroll amount for KEY in the focused pane, or NIL when KEY is not a scroll
key. Page keys move a page, Home/End jump to an edge, Ctrl+B/Ctrl+F are the
emacs-shaped page back/forward. The page size comes from the FOCUSED pane, so the
same key behaves correctly with either input focused."
  (let ((page (if (eq (model-focused model) :repl)
                  (tui.viewport:viewport-height (model-repl-viewport model))
                  (tui.viewport:viewport-height (model-chat-viewport model)))))
    (cond
      ((eq key :page-up) (- page))
      ((eq key :page-down) page)
      ((or (eq key :home) (and ctrl (characterp key) (char= key #\b))) :top)
      ((or (eq key :end) (and ctrl (characterp key) (char= key #\f))) :bottom)
      (t nil))))
(export 'scroll-key-delta)

(defun handle-scroll (model msg)
  "Handle one mouse SCROLL event and return (VALUES MODEL NIL). The wheel scrolls
the pane it is over by three lines; a direction that is not :up/:down is a no-op.
Every other mouse message falls through to the caller's dispatch."
  (let ((pane (pane-at-mouse model msg))
        (direction (tui:mouse-scroll-direction msg)))
    (when (and pane direction)
      (let ((delta (ecase direction
                     (:up -3)
                     (:down 3)
                     (:left 0)
                     (:right 0))))
        (unless (zerop delta)
          (case pane
            (:chat (%scroll-viewport model (model-chat-viewport model) delta t))
            (:repl (%scroll-viewport model (model-repl-viewport model) delta))
            (:agents (%scroll-viewport model (model-agent-viewport model) delta)))))))
  (values model nil))
(export 'handle-scroll)

;;;; --- P2: history, overlays, palette, search, render batching ----------

(defparameter *tui-render-batch* 8
  "Streamed fragments between chat re-renders. A streamed turn arrives as many
small deltas; fitting the whole scrollback for each one is correct but wasteful.
The first fragment renders immediately (so a one-fragment turn looks instant),
then at most every Nth; finalize always commits through model-append-chat-line,
which renders.")
(export '*tui-render-batch*)

(defparameter *tui-history-cap* 100
  "Most recent submitted inputs kept for Up/Down recall.")
(export '*tui-history-cap*)

(defparameter *palette-entries*
  '("/help" "/spawn" "/kill" "/approvals" "/clear")
  "Client-side verbs the palette lists. Enter fills the chat input with the
selected verb rather than running it blind, so an argument-taking verb is not
executed without its argument.")
(export '*palette-entries*)

(defun palette-matches (query)
  "The palette entries containing QUERY, case-insensitively, in order. An empty
QUERY lists every entry. PURE."
  (let ((q (string-downcase (or query ""))))
    (if (string= q "")
        (copy-list *palette-entries*)
        (remove-if-not (lambda (entry) (search q (string-downcase entry)))
                       *palette-entries*))))
(export 'palette-matches)

(defun help-lines ()
  "The `?` overlay body: the key map and the client-side verbs. Derived from
*CHAT-COMMANDS* so the two cannot drift."
  (cons "keys:  Tab input  Enter send  Ctrl+J newline/send  Up/Down history"
        (cons "       ? help  Ctrl+P palette  Ctrl+F search  Esc clear/close  Ctrl+C quit"
              (cons "" (cons "verbs:" (copy-list (chat-command-help-lines)))))))
(export 'help-lines)

(defun open-overlay (model kind &optional query)
  "Show the OVERLAY of KIND (:help, :palette, :search) with QUERY as its initial
input. Reopening resets the query. Returns MODEL."
  (setf (model-overlay model) kind
        (model-overlay-input model) (or query ""))
  (when (eq kind :search) (recompute-search model))
  model)
(export 'open-overlay)

(defun close-overlay (model)
  "Hide any overlay and clear its query. Returns MODEL."
  (setf (model-overlay model) nil
        (model-overlay-input model) ""
        (model-search-matches model) nil)
  model)
(export 'close-overlay)

(defun recompute-search (model)
  "Rebuild MODEL's search matches from OVERLAY-INPUT over the chat scrollback.
Newest first, duplicates removed, case-insensitive substring. An empty query has
no matches. The overlay shows the matches; it does not move the transcript
viewport, which would need a wrapped-line offset this data layer cannot know."
  (let* ((q (string-downcase (model-overlay-input model)))
         (lines (if (string= q "")
                    nil
                    (remove-if-not
                     (lambda (line)
                       (and (stringp line)
                            (search q (string-downcase line))))
                     (model-scrollback model)))))
    (setf (model-search-matches model)
          (remove-duplicates lines :test #'string= :from-end t)))
  model)
(export 'recompute-search)

(defun push-input-history (model text)
  "Remember TEXT as the most recent input, dropping an immediate repeat and
trimming to *TUI-HISTORY-CAP*. The browse position and draft are reset because a
submission ends any history walk. Returns MODEL."
  (when (and (stringp text) (plusp (length text)))
    (setf (model-input-history model)
          (cons text (remove text (model-input-history model)
                             :test #'string= :count 1)))
    (when (> (length (model-input-history model)) *tui-history-cap*)
      (setf (model-input-history model)
            (subseq (model-input-history model) 0 *tui-history-cap*))))
  (setf (model-history-index model) nil
        (model-history-draft model) nil)
  model)
(export 'push-input-history)

(defun history-step (model delta)
  "Move the history cursor by DELTA (+1 older, -1 newer) in the focused input.
Up saves the current draft first and clamps at the oldest entry; Down from the
newest entry restores the draft. With no history, a no-op. Returns MODEL."
  (let* ((ta (focused-textarea model))
         (history (model-input-history model)))
    (when (and ta history)
      (let ((index (model-history-index model)))
        (when (null index)
          (setf (model-history-draft model)
                (tui.textarea:textarea-value ta)))
        (let ((next (+ (or index -1) delta)))
          (cond
            ((>= next (length history))
             (let ((oldest (1- (length history))))
               (setf (model-history-index model) oldest)
               (tui.textarea:textarea-set-value ta (nth oldest history))))
            ((<= next 0)
             (if (and (< delta 0) (= next 0) (model-history-index model))
                 (history-restore-draft model)
                 (progn
                   (setf (model-history-index model) 0)
                   (tui.textarea:textarea-set-value ta (nth 0 history)))))
            (t
             (setf (model-history-index model) next)
             (tui.textarea:textarea-set-value ta (nth next history))))))))
  model)
(export 'history-step)

(defun history-restore-draft (model)
  "End a history walk: show the saved draft again. Returns MODEL."
  (let ((ta (focused-textarea model)))
    (when (and ta (model-history-index model))
      (when (model-history-draft model)
        (tui.textarea:textarea-set-value ta (model-history-draft model)))
      (setf (model-history-index model) nil
            (model-history-draft model) nil)))
  model)
(export 'history-restore-draft)

(defun handle-overlay-key (model msg)
  "One key while an overlay is open. Escape closes; Enter fills the chat input
with the selected palette verb (search just closes, its results already visible);
Backspace and printable characters edit the query; Ctrl+C quits. Returns
(VALUES model cmd)."
  (let ((key (tui:key-msg-key msg))
        (ctrl (tui:key-msg-ctrl msg)))
    (cond
      ((and ctrl (characterp key) (char= key #\c))
       (setf (model-quitting model) t)
       (values model (%quit-cmd)))
      ((eq key :escape)
       (close-overlay model)
       (values model nil))
      ((eq key :enter)
       (when (eq (model-overlay model) :palette)
         (let ((entry (first (palette-matches (model-overlay-input model)))))
           (when entry
             (let ((ta (model-chat-textarea model)))
               (close-overlay model)
               (set-focus model :chat)
               (when ta
                 (tui.textarea:textarea-set-value
                  ta (concatenate 'string entry " ")))))))
       (values model nil))
      ((eq key :backspace)
       (setf (model-overlay-input model)
             (subseq (model-overlay-input model)
                     0 (max 0 (1- (length (model-overlay-input model))))))
       (when (eq (model-overlay model) :search) (recompute-search model))
       (values model nil))
      ((characterp key)
       (setf (model-overlay-input model)
             (concatenate 'string (model-overlay-input model) (string key)))
       (when (eq (model-overlay model) :search) (recompute-search model))
       (values model nil))
      (t (values model nil))))
(export 'handle-overlay-key))

(defun %stream-render-p (model)
  "Whether this streamed fragment should re-render the chat pane. The FIRST
fragment after a quiet period always renders (a one-fragment turn must appear
instantly); later ones render at most every *TUI-RENDER-BATCH*. Finalize commits
through model-append-chat-line, which renders regardless. Returns T or NIL."
  (let ((n (incf (model-fragments-since-render model))))
    (when (or (= n 1) (>= n *tui-render-batch*))
      (setf (model-fragments-since-render model) 0)
      t)))
(export '%stream-render-p)

(defun model-fit-line (model line width)
  "Fit one logical LINE to WIDTH columns, memoizing on (LINE . WIDTH).
A streamed turn re-fits only its growing in-flight line; the committed scrollback
is fitted once. The cache is invalidated by /clear and by a width change.
PURE with respect to the model: mutates only the cache slot."
  (let* ((key (cons line width))
         (cache (model-fit-cache model))
         (pair (assoc key cache :test #'equal)))
    (if pair
        (cdr pair)
        (let ((fitted (wrap-text line width)))
          (push (cons key fitted) (model-fit-cache model))
          fitted))))
(export 'model-fit-line)

(defparameter *tui-timestamps-p* nil
  "Whether chat lines are prefixed with their local wall-clock time. Off by
default so stored transcripts stay comparable with the image's event stream;
enable with SEXPR_TUI_TIMESTAMPS.")
(export '*tui-timestamps-p*)

(defparameter *tui-role-styles-p* nil
  "Whether the leading role token (user:/model:/result:/tool:/budget:) is
coloured. Off by default because ANSI in the scrollback makes string
comparisons brittle; enable with SEXPR_TUI_ROLE_STYLES.")
(export '*tui-role-styles-p*)

(defun timestamp-prefix ()
  "The local-time [HH:MM] prefix for a chat line, in the client's timezone.
Decodes universal time with the host default zone, so no extra dependency is
needed. PURE enough for a UI stamp."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time))
    (declare (ignore second day month year))
    (format nil "[~2,'0D:~2,'0D] " hour minute)))
(export 'timestamp-prefix)

(defun role-color (kind)
  "The accent colour for one chat role, or NIL for no styling. PURE."
  (case kind
    (:user tui:*fg-green*)
    (:model tui:*fg-cyan*)
    (:result tui:*fg-yellow*)
    ((:tool :tool-start :tool-result) tui:*fg-magenta*)
    ((:budget :budget-exceeded) tui:*fg-red*)
    (:reasoning tui:*fg-bright-black*)
    (otherwise nil)))
(export 'role-color)
(defun line-role (line)
  "The role keyword named by LINE's leading token ("user", "tool", ...), or
NIL when the line has no known role prefix. A line already carrying ANSI styling
has no role to recolour. PURE."
  (if (and (stringp line) (plusp (length line))
           (char/= (char line 0) #\Escape))
      (let ((colon (position #\: line)))
        (when colon
          (let ((name (subseq line 0 colon)))
            (cond ((string-equal name "user") :user)
                  ((string-equal name "model") :model)
                  ((string-equal name "result") :result)
                  ((string-equal name "tool") :tool)
                  ((string-equal name "budget") :budget)
                  ((string-equal name "reasoning") :reasoning)
                  (t nil)))))
      nil))
(export 'line-role)

(defun decorate-chat-line (line &optional kind)
  "Apply the opt-in timestamp prefix and role-token colour to one chat line.
With both knobs off this returns LINE unchanged, which is why the default
scrollback stays plain and comparable. PURE."
  (let ((prefix (if *tui-timestamps-p* (timestamp-prefix) "")))
    (when *tui-role-styles-p*
      (let ((colon (and kind (position #\: line))))
        (when (and colon (role-color kind))
          (let* ((token (subseq line 0 (1+ colon)))
                 (rest (subseq line colon))
                 (style (tui:make-style :foreground (role-color kind))))
            (setf line (concatenate 'string
                                    (tui:render-styled style token)
                                    rest))))))
    (concatenate 'string prefix line)))
(export 'decorate-chat-line)

(defun configure-tui-knobs ()
  "Apply the SEXPR_TUI_* startup knobs once, before the first layout:
  SEXPR_TUI_MULTILINE     chat input grows to three rows; Enter=newline, Ctrl+J=send
  SEXPR_TUI_COMPACT       drop pane borders and give the columns to the transcript
  SEXPR_TUI_FOCUS_COLOR   border/cursor accent colour (see FOCUS-COLOR-FROM-NAME)
  SEXPR_TUI_TIMESTAMPS    prefix chat lines with local [HH:MM]
  SEXPR_TUI_ROLE_STYLES   colour the leading role token
Set at startup only; returns nothing useful."
  (setf *tui-multiline-p* (env-true-p "SEXPR_TUI_MULTILINE")
        *chat-input-lines* (if *tui-multiline-p* 3 1)
        *repl-input-lines* 1
        *compact-p* (env-true-p "SEXPR_TUI_COMPACT")
        *tui-timestamps-p* (env-true-p "SEXPR_TUI_TIMESTAMPS")
        *tui-role-styles-p* (env-true-p "SEXPR_TUI_ROLE_STYLES"))
  (let ((focus (uiop:getenv "SEXPR_TUI_FOCUS_COLOR")))
    (when (and focus (plusp (length focus)))
      (let ((color (focus-color-from-name focus)))
        (when color (setf *focus-color* color))))))
(export 'configure-tui-knobs)



(defun clear-fit-cache (model)
  "Drop every memoized fit (a width change or /clear makes them stale)."
  (setf (model-fit-cache model) nil)
  model)
(export 'clear-fit-cache)

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
  ;; a FAILED greeter is the common first sight of a fresh image without
  ;; a provider: explain it before the operator concludes the TUI is broken
  (note-agent-failure model)
  ;; validate a caller-supplied --agent against the snapshot BEFORE trusting it:
  ;; an unknown name would leave the pane on a phantom agent, the chat empty, and
  ;; the only explanation buried in the status bar.
  (when (and (model-picked-agent model) (model-agents model)
             (not (find (model-picked-agent model) (model-agents model)
                        :key (lambda (a) (getf a :name)) :test #'string=)))
    (note-error model (format nil "unknown agent ~A — picked the first snapshot row instead"
                              (model-picked-agent model)))
    (setf (model-picked-agent model) nil))
  ;; default the picked agent to the first snapshot row (sorted by name for a stable
  ;; choice) so a client started without --agent still has a society view and a
  ;; target; a validated --agent overrides it by being set before init runs.
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
                  ;; :subscribe is a KEYWORD, not the client package's own symbol: the client
                  ;; package is :sexpr-tui (dash) and the image's is :sexpr.tui
                  ;; (dot), so a client-side symbol prints QUALIFIED as
                  ;; SEXPR-TUI::SUBSCRIBE — a package the image does not have, and
                  ;; its reader signals 'Package does not exist', killing the
                  ;; subscribe before any listener is registered. Keywords are
                  ;; package-independent; the server resolves the operator by name.
                  (write-wire push (list :subscribe :agent agent))
                  ;; remember it, so the fallback poll never subscribes twice
                  (push agent (model-subscriptions model))
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
  "Route one key message. Returns (VALUES model cmd).
Ctrl+C and Escape quit. Tab moves key input between the chat and REPL text areas
through set-focus, so exactly one of them owns the next key. Enter submits the
focused input: chat sends `inject-note` with the picked agent's handle, REPL evals
the form with `sexpr.repl:*agent*` bound. Everything else goes to the focused text
area through update-focused-textarea.
The cmd is NIL except for the two quit keys. Nothing here signals."
  (let ((key (tui:key-msg-key msg))
        (ctrl (tui:key-msg-ctrl msg)))
    (cond
      ((and ctrl (characterp key) (char= key #\c))
       (setf (model-quitting model) t)
       (values model (%quit-cmd)))
      ((eq key :escape)
       ;; Clear before quitting. An Escape with a draft in the focused input
       ;; discards the draft and keeps the session; an empty input quits. The
       ;; two-step is deliberate: Escape is one keypress from the typing hand,
       ;; and losing a long note to a slip is worse than a second keypress.
       (let ((ta (focused-textarea model)))
         (when (and ta (plusp (length (tui.textarea:textarea-value ta))))
           (tui.textarea:textarea-reset ta)
           (values model nil)))
       (setf (model-quitting model) t)
       (values model (%quit-cmd)))
      ;; An open overlay consumes Escape first (close, not quit) and every other
      ;; key after that; the transcript stays untouched while it is up.
      ((and (eq key :escape) (model-overlay model))
       (close-overlay model)
       (values model nil))
      ((model-overlay model)
       (handle-overlay-key model msg))
      ;; Abandon an in-flight REPL eval. The blocking read cannot be killed, but
      ;; the UI has stayed responsive; this prevents the stale render.
      ((and ctrl (characterp key) (char-equal key #\x))
       (cancel-repl model)
       (values model nil))
      ;; Palette, search, and help overlays (P2). `?` opens help only when the
      ;; chat draft is empty, so a literal question mark can still be typed.
      ((and ctrl (characterp key) (char-equal key #\p))
       (open-overlay model :palette)
       (values model nil))
      ((and ctrl (characterp key) (char-equal key #\f))
       (open-overlay model :search)
       (values model nil))
      ((and (characterp key) (char= key #\?)
            (eq (model-focused model) :chat)
            (let ((ta (model-chat-textarea model)))
              (or (null ta) (string= "" (tui.textarea:textarea-value ta)))))
       (open-overlay model :help)
       (values model nil))
      ;; Ctrl+J: SEND in multi-line mode (where Enter is a newline), INSERT a
      ;; newline in single-line mode (harmless; keeps one chord documented).
      ((and ctrl (characterp key) (char-equal key #\j))
       (if *tui-multiline-p*
           (handle-enter model)
           (let ((ta (focused-textarea model)))
             (when ta
               (tui.textarea:textarea-insert-string ta (string #\Newline)))
             (values model nil))))
      ((eq key :tab)
       ;; Leaving an input ends any history walk, so the draft is not stale when
       ;; the operator comes back to this pane.
       (history-restore-draft model)
       (set-focus model (if (eq (model-focused model) :chat) :repl :chat))
       (values model nil))
      ((eq key :enter)
       ;; Multi-line chat input: Enter is a NEWLINE and Ctrl+J sends. The
       ;; single-line default keeps Enter = send.
       (if (and *tui-multiline-p* (eq (model-focused model) :chat))
           (update-focused-textarea model msg)
           (handle-enter model)))
      ;; History recall on Up/Down. In a multi-line chat draft the arrows keep
      ;; their cursor meaning; everywhere else they walk submitted inputs.
      ((member key '(:up :down))
       (if (and *tui-multiline-p* (eq (model-focused model) :chat))
           (update-focused-textarea model msg)
           (progn
             (history-step model (if (eq key :up) 1 -1))
             (values model nil))))
      ;; Viewport scrolling: page keys and Ctrl+B/F scroll the FOCUSED pane. These
      ;; are intercepted before the textarea branch, so they can never corrupt the
      ;; input; the arrows stay with the textarea cursor.
      ((scroll-key-delta model key ctrl)
       (let ((delta (scroll-key-delta model key ctrl)))
         (if (eq (model-focused model) :repl)
             (%scroll-viewport model (model-repl-viewport model) delta)
             (%scroll-viewport model (model-chat-viewport model) delta t)))
       (values model nil))
      ;; Approval keyboard fallback, intercepted ONLY while an approval is pending and
      ;; placed BEFORE the textarea branch so it cannot steal printable keys (D027).
      ;; C-g grants once, C-d denies; with no pending approval both fall through to
      ;; the focused textarea unchanged.
      ((and (model-pending-approval model)
            ctrl (characterp key)
            (or (char-equal key #\g) (char-equal key #\d)))
       (resolve-pending-approval model (if (char-equal key #\g) :grant-once :deny))
       (values model nil))
      (t (update-focused-textarea model msg)))))
(export 'handle-key)

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

(defparameter *chat-commands*
  '("/help" "/spawn" "/kill" "/approvals" "/clear")
  "The client-side slash verbs the chat input understands. They act on the
projection (or through ordinary RPCs); they are never sent to the model as
notes.")
(export '*chat-commands*)

(defun chat-command-help-lines ()
  "The /help text: one REPL line per verb."
  (list "/help        show this help"
        "/spawn GOAL  spawn a worker subagent and return its handle"
        "/kill [NAME] terminate an agent (default: picked)"
        "/approvals   list every agent waiting on an approval"
        "/clear       clear the chat transcript"))
(export 'chat-command-help-lines)

(defun %command-parts (text)
  "Split a slash command TEXT into (VALUES name args): NAME without the leading
slash, ARGS trimmed. PURE."
  (let* ((space (position #\Space text :start 1))
         (name (subseq text 1 (or space (length text))))
         (args (if space
                   (string-trim '(#\Space #\Tab) (subseq text space))
                   "")))
    (values name args)))

(defun handle-chat-command (model text &optional ta)
  "Execute one slash command from the chat input and return MODEL.
The verbs are CLIENT-SIDE: they operate on the projection (R023) and reach the
image only through the ordinary typed RPCs, so they inherit the same boundary
rules and failure handling. The textarea is reset either way (a command is not
an unfinished note). Nothing here signals."
  (multiple-value-bind (name args) (%command-parts (or text ""))
    (let ((args (or args "")))
      (cond
        ((string-equal name "help")
         (dolist (line (chat-command-help-lines))
           (model-append-repl-line model line)))
        ((string-equal name "clear")
         (setf (model-scrollback model) nil
               (model-in-flight model) nil
               (model-in-flight-reasoning model) nil)
         (clear-fit-cache model)
         (let ((vp (model-chat-viewport model)))
           (when vp (tui.viewport:viewport-set-content vp ""))))
        ((string-equal name "approvals")
         (let ((rows (remove-if-not (lambda (a) (getf a :pending-approval))
                                    (model-agents model))))
           (if (null rows)
               (model-append-repl-line model "approvals: none pending")
               (dolist (row rows)
                 (let ((p (getf row :pending-approval)))
                   (model-append-repl-line
                    model
                    (format nil "approval: ~A ~A ~A"
                            (or (getf row :name) "?")
                            (or (getf p :capability) "?")
                            (or (getf p :target) ""))))))))
        ((string-equal name "spawn")
         (cond
           ((string= args "")
            (note-error model "usage: /spawn GOAL"))
           ((null (model-swank-connection model))
            (note-error model "no swank connection — cannot spawn"))
           (t
            (let ((form-text (format nil "(sexpr.tui:spawn ~A)"
                                     (swank-escape-string args))))
              (multiple-value-bind (value error)
                  (swank-rpc (model-swank-connection model) form-text)
                (declare (ignore value))
                (if error
                    (note-error model (format nil "spawn failed: ~A" error))
                    (progn
                      (model-append-chat-line
                       model (format nil "spawned: ~A" value))
                      ;; refresh so the newcomer's row appears even if no push
                      ;; channel announced it
                      (poll-image model))))))))
        ((string-equal name "kill")
         (let* ((target-name (if (string= args "")
                                 (model-picked-agent model)
                                 args))
                (row (and (stringp target-name)
                          (find target-name (model-agents model)
                                :key (lambda (a) (getf a :name)) :test #'string=)))
                (handle (and row (getf row :handle))))
           (cond
             ((null handle)
              (note-error model
                          (format nil "no handle for agent ~A — cannot kill"
                                  (or target-name "?"))))
             ((null (model-swank-connection model))
              (note-error model "no swank connection — cannot kill"))
             (t
              (let ((form-text (format nil "(sexpr.tui:kill ~A)"
                                       (swank-escape-string handle))))
                (multiple-value-bind (value error)
                    (swank-rpc (model-swank-connection model) form-text)
                  (declare (ignore value))
                  (if error
                      (note-error model (format nil "kill failed: ~A" error))
                      (model-append-chat-line
                       model (format nil "killed: ~A (~A)" handle target-name)))))))))
        (t
         (note-error model (format nil "unknown command /~A — try /help" name)))))
    (when ta (tui.textarea:textarea-reset ta))
    (refresh-status model)
    model))
(export 'handle-chat-command)

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
       (push-input-history model text)
       ;; A slash command is a client-side verb, never a note to the model.
       (when (and (plusp (length text)) (char= (char text 0) #\/))
         (handle-chat-command model text ta)
         (return-from send-chat-note (values model nil)))
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
                 ;; Synchronous inject-note: the reply says whether the note was
                 ;; appended, and reading it keeps one request/one reply on the
                 ;; swank channel (a fire-and-forget packet leaves an unanswered
                 ;; reply that a later RPC must skip as unsolicited).
                 (let ((form-text (format nil "(sexpr.tui:inject-note ~A ~A)"
                                          (swank-escape-string handle)
                                          (swank-escape-string text)))
                       value error)
                   (declare (ignore value))
                   (multiple-value-setq (value error)
                     (swank-rpc conn form-text))
                   (if error
                       ;; Nothing was appended in the image, so keep the draft (the
                       ;; operator can retry) and add no local echo.
                       (progn
                         (handler-case (client-note-error! conn error) (error () nil))
                         (note-error model (format nil "note failed: ~A" error)))
                       ;; Render the SAME user event the transcript carries and advance
                       ;; the cursor past it, so a resync/refetch cannot duplicate the
                       ;; line or drift from the image's event count. The old synthetic
                       ;; "noted <handle>: ..." was invisible to the cursor: it
                       ;; duplicated on refetch and vanished on switch.
                       (progn
                         (model-append-chat-line
                          model
                          (event-to-line (list :type :user :content text)))
                         (incf (model-cursor model))
                         (when ta (tui.textarea:textarea-reset ta))))
                   (values model nil))))))))))))
(export 'send-chat-note)

(defun send-repl-form (model)
  "Send a REPL form to the image, wrapped so it evaluates in COMMON-LISP-USER.
The result is rendered into the REPL pane.

SWANK READS THE :emacs-rex PACKET IN SWANK-IO-PACKAGE (a package with
:use '() — no CL symbols at all). The :package argument only sets
*buffer-package*, NOT *package*, so eval-for-emacs evaluates the form in
SWANK-IO-PACKAGE where LET, +, FORMAT etc. are all undefined. The existing
RPCs survive because they use fully-qualified symbols (sexpr.tui:...),
but the REPL form uses unqualified CL symbols.

The fix: every CL symbol in the wrapper is fully qualified (cl:let,
cl:find-package, cl:eval, cl:read-from-string, cl:handler-case, etc.).
The user's form is sent as a STRING and read by cl:read-from-string AFTER
*package* is bound to COMMON-LISP-USER, so its unqualified symbols resolve
in CL-USER. The agent binding (sexpr.repl:*agent*) is a special variable,
visible to cl:eval.

HANDLER-CASE: an erroring form must show its error in the REPL pane, not
drop the image into the interactive debugger. Without the wrapper, a form
like (car 5) signals an error during eval, swank enters the debugger and
blocks the connection thread, and the TUI freezes forever."
  (let* ((ta (model-repl-textarea model))
         (text (and ta (tui.textarea:textarea-value ta))))
    (cond
      ((or (null text) (string= text ""))
       (values model nil))
      (t
       (push-input-history model text)
       (let ((conn (model-swank-connection model))
             (name (model-picked-agent model)))
         (cond
           ((null conn)
            (note-error model "no swank connection — cannot eval")
            (values model nil))
           (t
            ;; Every CL symbol is qualified because the packet is read in
            ;; SWANK-IO-PACKAGE (no CL use). The user's form is a STRING,
            ;; read by cl:read-from-string after *package* is bound to
            ;; COMMON-LISP-USER, so unqualified symbols resolve correctly.
            (let ((form-text
                    (format nil
                            "(cl:let ((*package* (cl:find-package \"COMMON-LISP-USER\"))~@
                             (sexpr.repl:*agent* (cl:gethash ~A sexpr.agents:*agent-table*)))~@
                             (cl:handler-case (cl:eval (cl:read-from-string ~A))~@
                             (cl:error (e) (cl:format nil \"ERR: ~~A\" e))))"
                            (swank-escape-string (or name ""))
                            (swank-escape-string text))))
              ;; Production default: run off the TEA thread so a slow form
              ;; cannot freeze input. The result comes back as rpc-result-msg.
              (when *tui-async-repl*
                (queue-async-repl model conn form-text text)
                (when ta (tui.textarea:textarea-reset ta))
                (return-from send-repl-form (values model nil)))
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

(defun model-agent-row (model name)
  "The agent-snapshot plist named NAME in MODEL, or NIL. PURE: a plain
find over the snapshot rows."
  (find name (model-agents model)
        :key (lambda (a) (getf a :name)) :test #'string=))
(export 'model-agent-row)

(defun note-agent-failure (model)
  "Explain a FAILED picked agent in the chat pane, with the reason.

A failed agent cannot answer notes, and a bare FAILED row does not say
whether the model is unreachable (a provider misconfiguration) or the
agent hit a real error — the operator cannot tell a TUI bug from a config
problem, which is exactly how 'the agent failed' reads. Fetches the
handle's error text over swank and appends ONE actionable line. PURE of
signalling: a failed fetch leaves the FAILED row as the only signal,
and a NIL error (the agent was not actually failed) changes nothing."
  (let* ((picked (model-picked-agent model))
         (row (and picked (model-agent-row model picked)))
         (handle (and row (getf row :handle))))
    (when (and row (eq (getf row :status) :failed) handle)
      (multiple-value-bind (reason error)
          (swank-rpc (model-swank-connection model)
                     (format nil "(sexpr.agents:subagent-error ~A)"
                             (swank-escape-string handle)))
        (declare (ignore error))
        (model-append-chat-line
         model
         (one-line (format nil "agent ~A failed (~A): ~A — set SEXPR_MODEL and SEXPR_BASE_URL (or ANTHROPIC_API_KEY) and restart the image"
                          picked handle
                          (or reason "reason unavailable")))))))
  model)
(export 'note-agent-failure)

(defun set-pane-dimensions (model)
  "Size every pane from (layout-dimensions term-width term-height). Returns MODEL.
This is the ONLY place pane sizes change after construction, and it sets widths
AND heights: the agent pane is unbordered so it takes its width outright, while
the chat and REPL viewports and their text areas share one width. A NIL pane is
skipped rather than signalled, so calling this before build-panes is a no-op."
  (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
      (layout-dimensions (model-term-width model)
                         (model-term-height model))
    (when (model-chat-viewport model)
      (setf (tui.viewport:viewport-width (model-chat-viewport model)) chat-w
            (tui.viewport:viewport-height (model-chat-viewport model)) chat-h))
    (when (model-chat-textarea model)
      (setf (tui.textarea:textarea-width (model-chat-textarea model)) chat-w
            (tui.textarea:textarea-height (model-chat-textarea model))
            (max 1 *chat-input-lines*)))
    (when (model-repl-viewport model)
      (setf (tui.viewport:viewport-width (model-repl-viewport model)) chat-w
            (tui.viewport:viewport-height (model-repl-viewport model)) repl-h))
    (when (model-repl-textarea model)
      (setf (tui.textarea:textarea-width (model-repl-textarea model)) chat-w
            (tui.textarea:textarea-height (model-repl-textarea model))
            (max 1 *repl-input-lines*)))
    (when (model-agent-viewport model)
      (setf (tui.viewport:viewport-width (model-agent-viewport model)) agent-w
            (tui.viewport:viewport-height (model-agent-viewport model)) agent-h)))
  ;; Content fitted to a WIDTH must be re-fitted when the width changes: agent
  ;; rows/detail are truncated at render time, and cl-tuition's pad-block-rect
  ;; pads but never truncates, so a stale wider line would widen the pane box
  ;; past the frame on a shrink (a 60-column terminal rendered 64).
  ;; Content fitted to a WIDTH must be re-fitted when the width changes: agent
  ;; rows/detail are truncated at render time, and cl-tuition's pad-block-rect
  ;; pads but never truncates, so a stale wider line would widen the pane box
  ;; past the frame on a shrink (a 60-column terminal rendered 64). The chat fit
  ;; cache is dropped for the same reason.
  (refresh-agent-viewport model)
  (clear-fit-cache model)
  model)
(export 'set-pane-dimensions)

(defun resize-panes (model)
  "Re-derive the pane dimensions from the window size in MODEL. Delegates to
set-pane-dimensions; kept as the name the window-size branch and the tests call."
  (set-pane-dimensions model))
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
           (content (delta-msg-content msg))
           (kind (delta-msg-kind msg)))
       ;; ANY agent's stream lights its row red (F6): set the data-only :streaming
       ;; boolean and refresh the agent pane even when the fragment is for an agent
       ;; that is not the picked one. %map-agent-row is a no-op for an unknown name.
       (when agent
         (%set-agent-streaming model agent t)
         (refresh-agent-viewport model))
       (when (agent-is-picked-p model agent)
         (cond
           ((eq kind :tool)
            ;; a tool's streamed output is its own committed line, never joined into
            ;; the model's in-flight prose line.
            (model-append-chat-line model (format nil "tool: ~A" (or content ""))))
           ((eq kind :reasoning)
            ;; Reasoning/thinking blocks accumulate into a SEPARATE buffer and
            ;; render in grey, distinct from the model's actual reply.
            (setf (model-in-flight-reasoning model)
                  (concatenate 'string (or (model-in-flight-reasoning model) "")
                               (or content "")))
            (when (%stream-render-p model) (model-render-chat model)))
           (t
            ;; model prose ACCUMULATES into one growing line and re-renders ONCE,
            ;; so a streamed sentence is one line, not one word per line (F5).
            (setf (model-in-flight model)
                  (concatenate 'string (or (model-in-flight model) "")
                               (or content "")))
            (when (%stream-render-p model) (model-render-chat model)))))
       (values model nil)))
    ;; push channel: the streaming turn ended — commit the in-flight line (S05)
    ((finalize-msg-p msg)
     (let* ((agent (finalize-msg-agent msg))
            (line (model-in-flight model))
            (reasoning (model-in-flight-reasoning model))
            (matches (agent-is-picked-p model agent)))
       ;; COMMIT ONLY THE PICKED AGENT'S STREAM. A stale or out-of-order finalize for
       ;; a neighbouring agent must not commit (or clear) the picked in-flight line.
       (when matches
         ;; commit the reasoning line FIRST (if any), then the reply line, so
         ;; the thinking block appears above the reply in the scrollback.
         (when reasoning
           (setf (model-in-flight-reasoning model) nil)
           (model-append-chat-line model
                                    (tui:render-styled
                                     (tui:make-style :foreground tui:*fg-bright-black*)
                                     (format nil "~A: ~A" :reasoning reasoning))))
         ;; commit the accumulated reply line as ONE logical line and clear the
         ;; buffer BEFORE re-rendering, so it is not also shown as in-flight.
         (when line
           (setf (model-in-flight model) nil)
           (model-append-chat-line model line)
           (setf (model-status-text model) "turn done")))
       ;; clear the red light for the finished agent (an out-of-order finalize with
       ;; no in-flight line is still a safe no-op beyond this).
       (when agent
         (%set-agent-streaming model agent nil)
         (refresh-agent-viewport model)))
     (values model nil))
    ;; push channel: a tool call began (S05) — a plain prefixed progress line
    ((tool-start-msg-p msg)
     (when (agent-is-picked-p model (tool-start-msg-agent msg))
       (model-append-chat-line
        model
        (format nil "tool: ~A (call ~A) started"
                (or (tool-start-msg-name msg) "?")
                (or (tool-start-msg-call-id msg) "?"))))
     (values model nil))
    ;; push channel: a tool call finished (S05)
    ((tool-result-msg-p msg)
     (when (agent-is-picked-p model (tool-result-msg-agent msg))
       (model-append-chat-line
        model
        (format nil "tool: ~A -> ~A"
                (or (tool-result-msg-call-id msg) "?")
                (or (tool-result-msg-text msg) ""))))
     (values model nil))
    ;; push channel: the token budget was hit and the stream aborted mid-turn (S05)
    ((budget-exceeded-msg-p msg)
     (let ((used (budget-exceeded-msg-tokens-used msg))
           (limit (budget-exceeded-msg-limit msg)))
       ;; ONLY THE PICKED AGENT'S budget belongs in the picked transcript; another
       ;; agent's abort is visible on its own row.
       (when (agent-is-picked-p model (budget-exceeded-msg-agent msg))
         ;; the durable signal is the committed budget line; the status text is set too
         ;; (refresh-status rebuilds it each update, matching the resync branch).
         (setf (model-status-text model)
               (one-line (format nil "budget: ~A/~A tokens"
                                 (or used "?") (or limit "?"))))
         (model-append-chat-line
          model
          (format nil "budget: ~A/~A tokens" (or used "?") (or limit "?")))))
     (values model nil))
    ;; push channel: backpressure — the server dropped fragments
    ((resync-msg-p msg)
     (let* ((cursor (or (resync-msg-cursor msg) (model-cursor model)))
            (target (or (resync-msg-agent msg) (model-picked-agent model)))
            (picked (model-picked-agent model))
            (events nil) (new-cursor cursor) (error nil))
       ;; ONLY THE PICKED TRANSCRIPT CAN HAVE LOST FRAGMENTS. The client discards
       ;; every other agent's deltas, so a resync naming another agent is not its
       ;; concern — refetching anyway would read the wrong agent at the wrong cursor.
       (when (and target picked (string= target picked))
         (multiple-value-setq (events new-cursor error)
           (rpc-transcript-delta (model-swank-connection model) target cursor))
         (dolist (line (mapcar #'event-to-line (or events '())))
           (model-append-chat-line model line))
         (when (integerp new-cursor) (setf (model-cursor model) new-cursor)))
       ;; an empty refetch is tolerated: transcript-length does not advance mid-stream,
       ;; so nothing-new is the expected outcome of a mid-stream resync.
       (note-error model error)
       (setf (model-status-text model)
             (one-line (format nil (if (and target picked (string= target picked))
                                       "resync: refetched ~A from cursor ~D~@[ (~A)~]"
                                       "resync: ~A is not the picked agent — ignored")
                               target cursor (or error "")))))
     (values model nil))
    ;; push channel: the subscribe race-closure
    ((subscribed-msg-p msg)
     (let* ((cursor (subscribed-msg-cursor msg))
            (agent (or (subscribed-msg-agent msg) (model-picked-agent model)))
            ;; The RACE CLOSURE for a status that changed between the snapshot
            ;; and this subscribe reply (the greeter finishing its welcome
            ;; turn): the change's push has no subscriber yet, so the reply
            ;; carries the truth. Applied to the row BEFORE the transcript gate
            ;; below, and kept-pending so it cannot resolve an approval.
            (status (subscribed-msg-status msg))
            (picked (model-picked-agent model))
            (events nil) (new-cursor cursor) (error nil))
       (when (and agent status)
         (%set-agent-status-keeping-pending model agent status))
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
           (pending (status-msg-pending-approval msg))
           ;; the row's status BEFORE this update, for the flip detection below
           (before (let ((row (and (status-msg-agent msg)
                                  (model-agent-row model (status-msg-agent msg)))))
                     (and row (getf row :status)))))
       (when agent
         ;; A frame that carries :pending-approval explicitly (the approval
         ;; path) sets it; a frame WITHOUT the key (the worker start/finish
         ;; announcements) preserves the row's pending-approval.
         (if (status-msg-pending-approval-p msg)
             (%set-agent-status model agent status pending)
             (%set-agent-status-keeping-pending model agent status))
         ;; a turn that FAILED mid-session: the pane flips to FAILED but the
         ;; operator still cannot tell why — fetch the reason (only on the
         ;; flip, not on every :failed update, so a re-run does not repeat it)
         (when (and (model-picked-agent model)
                    (string= agent (model-picked-agent model))
                    (eq status :failed)
                    (not (eq before :failed)))
           (note-agent-failure model))
         ;; The model's pending-approval slot mirrors the PICKED row, so it is
         ;; re-synced from the row after either update.
         (when (and (model-picked-agent model)
                    (string= agent (model-picked-agent model)))
           (let ((row (find agent (model-agents model)
                              :key (lambda (a) (getf a :name)) :test #'string=)))
             (when row
               (setf (model-pending-approval model)
                     (getf row :pending-approval)))))
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
    ;; push channel: a newcomer joined the society (registry announcement)
    ((agent-added-msg-p msg)
     (let ((name (agent-added-msg-agent msg))
           (row (agent-added-msg-row msg)))
       (when (and (stringp name) (listp row))
         (%merge-agent-row model row)
         ;; its lights are live only if the channel is subscribed to it
         (reconcile-subscriptions model (model-agents model))
         (when (null (model-picked-agent model))
           (let ((names (mapcar (lambda (a) (getf a :name))
                                (sorted-agents (model-agents model)))))
             (setf (model-picked-agent model) (first names))))
         (refresh-agent-viewport model)))
     (values model nil))
    ;; push channel: an agent left the society
    ((agent-removed-msg-p msg)
     (let ((name (agent-removed-msg-agent msg)))
       (when (stringp name)
         (%drop-agent-row model name)
         ;; drop the server-side listener now rather than at disconnect
         (let ((push (model-push-connection model)))
           (when (and push (push-connection-live-p model))
             (handler-case
                 (write-wire push (list :unsubscribe :agent name))
               (error (e)
                 (handler-case (client-note-error! push e) (error () nil))
                 (note-error model (format nil "unsubscribe failed: ~A" e))))))
         (when (equal (model-picked-agent model) name)
           ;; the shown transcript vanished with the agent: clear it and land on
           ;; another row rather than keeping a ghost picked
           (setf (model-picked-agent model) nil
                 (model-pending-approval model) nil
                 (model-scrollback model) nil
                 (model-in-flight model) nil
                 (model-in-flight-reasoning model) nil)
           (let ((vp (model-chat-viewport model)))
             (when vp (tui.viewport:viewport-set-content vp "")))
           (let ((names (remove nil (mapcar (lambda (a) (getf a :name))
                                            (sorted-agents (model-agents model))))))
             (when names (setf (model-picked-agent model) (first names)))))
         (refresh-agent-viewport model)))
     (values model nil))
    ;; swank: a REPL or RPC reply rendered into the REPL pane
    ((rpc-result-msg-p msg)
     (let ((form (rpc-result-msg-form msg))
           (value (rpc-result-msg-value msg))
           (err (rpc-result-msg-error msg)))
       (setf (model-pending-repl-p model) nil)
       (model-append-repl-line model
                               (format nil "~A=> ~A" (or form "?")
                                       (if err
                                           (format nil "ERR: ~A" err)
                                           (format nil "~A" value))))
       (note-error model (when err (format nil "eval: ~A" err))))
     (values model nil))
    ;; the worker finished after a cancel: clear the pending flag, say nothing
    ;; (cancel-repl already explained itself)
    ((async-done-msg-p msg)
     (setf (model-pending-repl-p model) nil)
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
    ;; bracketed paste: insert verbatim into the focused input (multi-line text
    ;; arrives as one paste), or append to an open overlay's query.
    ((tui:paste-msg-p msg)
     (let ((text (tui:paste-msg-text msg)))
       (if (model-overlay model)
           (progn
             (setf (model-overlay-input model)
                   (concatenate 'string (model-overlay-input model) text))
             (when (eq (model-overlay model) :search) (recompute-search model)))
           (let ((ta (focused-textarea model)))
             (when ta (tui.textarea:textarea-insert-string ta text)))))
     (values model nil))
    ;; window resize: reflow every pane
    ((tui:window-size-msg-p msg)     (setf (model-term-width model) (tui:window-size-msg-width msg)
           (model-term-height model) (tui:window-size-msg-height msg))
     (resize-panes model)
     (values model nil))
    ;; cursor blink, fallback poll, and a throttled reattach when a configured
    ;; channel has closed (docs/sexpr-tui.md §11; notes/tui.md §7).
    ((tui:tick-msg-p msg)
     (tick-fallback-poll model)
     (maybe-reconnect model)
     (values model (tui:tick *tui-init-tick*)))
    ;; quit
    ((tui:quit-msg-p msg)
     (setf (model-quitting model) t)
     (values model (%quit-cmd)))
    ;; mouse wheel: scroll the pane under the cursor (cl-tuition viewport keys)
    ((tui:mouse-scroll-event-p msg) (handle-scroll model msg))
    ;; mouse: click-to-focus or approval resolution (S04)
    ((tui:mouse-press-event-p msg) (handle-mouse model msg))
    ;; keyboard
    ((tui:key-msg-p msg) (handle-key model msg))
      (t (values model nil)))
    (refresh-status next-model)
    (values next-model cmd)))

;;;; --- view ------------------------------------------------------------

(defmethod tui:view ((model tui-model))
  "Render the full frame as one string. Pure: reads only model state, never a live
connection. This is the assertion surface for the headless tests.
The frame is wrapped in TUI:ZONE-SCAN — the ROOT-only call that records every zone
mark's position in the global manager and strips the markers from the returned text.
Without it the agent-row and approval zones are never registered and nothing is
clickable (the zone-mark call is a no-op for recording). The approval strip is passed
as its own line between the body and the status bar."
  (tui:zone-scan
   (compose-layout
    (if (model-overlay model)
        ;; The overlay replaces the transcript AND the input; the layout still
        ;; reserves the input rows, so the panel fills those too.
        (render-overlay model (chat-pane-width model)
                        (+ (chat-pane-height model)
                           (max 0 (1- *chat-input-lines*))))
        (when (model-chat-viewport model)
          (tui:join-vertical :left
                             (tui.viewport:viewport-view (model-chat-viewport model))
                             (when (model-chat-textarea model)
                               (render-textarea (model-chat-textarea model))))))
    (when (model-repl-viewport model)
      (tui:join-vertical :left
                         (tui.viewport:viewport-view (model-repl-viewport model))
                         (when (model-repl-textarea model)
                           (render-textarea (model-repl-textarea model)))))
    (when (model-agent-viewport model)
      (tui.viewport:viewport-view (model-agent-viewport model)))
    (model-status-text model)
    (render-approval-strip (model-pending-approval model)
                           (left-column-width model))
    :chat-focused (eq (model-focused model) :chat)
    :repl-focused (eq (model-focused model) :repl)
    ;; The frame is sized from the terminal, not from the content: without these two
    ;; compose-layout pads nothing and the pane would render at the width of its
    ;; longest transcript line instead of the width of the screen.
    :width (model-term-width model)
    :height (model-term-height model))))
(export 'tui:view)
