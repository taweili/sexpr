;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui-client/view.lisp — pane rendering and layout composition (M004/S03 T04).
;;;;
;;;; This file is PURE STRING COMPOSITION. It takes data (line lists, agent plists,
;;;; a status line) and returns one display string. It holds no connection, no model
;;;; reference, and no live kernel object (R023). That is what makes the layout
;;;; provable headlessly: `view` returns a string, so a test asserts on the string.
;;;;
;;;; COMPONENTS BY QUALIFIED NICKNAME, never bare (MEM108). The TEA protocol and the
;;;; layout helpers live in :tuition (nickname :tui) — join-horizontal, join-vertical,
;;;; render-border, *border-rounded* — but every component is its own package:
;;;;   :tuition.components.viewport   -> tui.viewport
;;;;   :tuition.components.textarea   -> tui.textarea
;;;;   :tuition.render.table          -> tui.render.table
;;;; `tui.table` does NOT exist: src/components/table.lisp is not listed in the
;;;; tuition system, so only `tui.render.table:make-table` is reachable. Bare names
;;;; would resolve against :tuition and miss every component function.
;;;;
;;;; NEWLINES ARE BUILT, NEVER LITERALED. In this SBCL (2.6.8) `~%` inside a STRING
;;;; LITERAL is two literal characters (verified: (length "a~%b") is 4), so
;;;; `"a~%b"` is not a newline and `split-string-by-newline` would see one line.
;;;; Only FORMAT control strings interpret `~%`. Every multi-line string here is
;;;; therefore built through LINES-TO-STRING.
;;;;
;;;; THE AGENT PANE IS NOW LIVE (M004/S04). S03 shipped it as a plain table with no
;;;; status lights and no click handling; S04 replaced make-table with manual row
;;;; composition: a colored status light chosen by AGENT-LIGHT, a picked-row
;;;; highlight, and a (tui:zone-mark "agent-row:<name>" ...) click target per row,
;;;; plus an approval strip whose [grant-once]/[deny] affordances are zoned. The
;;;; zone markers are recorded and stripped by the ROOT zone-scan in tui:view, which
;;;; is also why the pane's viewport height is now *agent-pane-height* and not 0.

(in-package :sexpr-tui)

;;;; --- string helpers ----------------------------------------------------

(defun lines-to-string (lines)
  "Join LINES with REAL newlines. See the file header for why `~%` in a literal is
not acceptable: it is literal here, so a literal would collapse every pane to one
line and the viewport would stop scrolling."
  (format nil "~{~A~^~%~}" lines))
(export 'lines-to-string)

(defun one-line (string &optional (limit 240))
  "Strip any newline out of STRING, clipping to LIMIT columns. A pane title and the
status bar are one line by contract; a delta fragment containing a newline must not
break the layout."
  (let ((flat (substitute #\Space #\Newline string)))
    (cond
      ((>= (length flat) limit) (subseq flat 0 limit))
      (t flat))))
(export 'one-line)

;;;; --- dimensions and border ---------------------------------------------

(defparameter *border* tui:*border-rounded*
  "The border style every pane uses, per notes/tui.md §4 (render-border with
*border-rounded*). One variable so the whole UI can be reskinned in one place.")
(export '*border*)

(defparameter *chat-width* 56
  "The chat column width. The agent pane sits beside it, so this plus *agent-width*
must stay under a common terminal width.")
(export '*chat-width*)

(defparameter *agent-width* 30
  "The agent pane width.")
(export '*agent-width*)

(defparameter *agent-pane-height* 12
  "The agent pane height in lines. Before S04 the viewport was height 0, so the pane
rendered NOTHING even with rows present (research F2). 12 rows fit a useful society
and leave room for the chat/repl column in a 24-line terminal.")
(export '*agent-pane-height*)

(defparameter *chat-viewport-height* 10
  "Chat viewport height in lines.")
(export '*chat-viewport-height*)

(defparameter *repl-viewport-height* 3
  "REPL viewport height in lines.")
(export '*repl-viewport-height*)

(defparameter *textarea-height* 1
  "Both textareas are one line: chat input and a REPL prompt, not editors.")
(export '*textarea-height*)

;;;; --- panes -------------------------------------------------------------

(defun make-chat-viewport (&optional (width *chat-width*))
  "The chat scrollback pane. Empty on construction; the model sets its content."
  (tui.viewport:make-viewport :width width :height *chat-viewport-height*))
(export 'make-chat-viewport)

(defun make-chat-textarea (&optional (width *chat-width*))
  "The chat input. Focused by default: the demo is a chat client, so the first key
press should land in chat and not in the REPL."
  (let ((ta (tui.textarea:make-textarea
             :width width
             :height *textarea-height*
             :placeholder "message...")))
    ;; Line numbers would eat four columns of a one-line input, and a single-line
    ;; textarea has nothing to number. Both settings go through exported accessors.
    (setf (tui.textarea:textarea-show-line-numbers ta) nil
          (tui.textarea:textarea-prompt ta) "> ")
    (tui.textarea:textarea-focus ta)
    ta))
(export 'make-chat-textarea)

(defun make-repl-viewport (&optional (width *chat-width*))
  "The REPL output pane."
  (tui.viewport:make-viewport :width width :height *repl-viewport-height*))
(export 'make-repl-viewport)

(defun make-repl-textarea (&optional (width *chat-width*))
  "The REPL input, unfocused (chat is focused first)."
  (let ((ta (tui.textarea:make-textarea
             :width width
             :height *textarea-height*
             :placeholder "eval...")))
    (setf (tui.textarea:textarea-show-line-numbers ta) nil
          (tui.textarea:textarea-prompt ta) "* ")
    ta))
(export 'make-repl-textarea)

(defun make-agent-viewport ()
  "The agent pane. A VIEWPORT, not a table component: `table-render` is a one-shot
string function with no TEA protocol, so composing it inside a viewport keeps the
pane scrollable when the society is larger than the pane. The rows themselves are
rendered by RENDER-AGENT-ROWS. The height is *agent-pane-height*, never 0: a
zero-height viewport clips every row away (research F2)."
  (tui.viewport:make-viewport :width *agent-width* :height *agent-pane-height*))
(export 'make-agent-viewport)

(defun agent-row (agent)
  "One table row from an agent-snapshot plist: (NAME STATUS).
`:name` and `:status` are the only two fields the plan asks for, so the row never
invents a third column. A missing field degrades to a placeholder rather than a
NIL cell, which `table-render` would pad as an empty string anyway."
  (list (or (getf agent :name) "?")
        (symbol-name (or (getf agent :status) :unknown))))
(export 'agent-row)

(defun agent-row-text (agent &key picked)
  "The PLAIN, ANSI-free, zone-free text of one agent row: a picked marker (\"*\" when
PICKED names this agent, else a space), the light glyph \"●\", the agent name, and
the UPPERCASED status symbol-name — e.g. \"* ● Alpha RUNNING\".
PURE and total: a missing :name/:status degrades to \"?\"/\"UNKNOWN\" and nothing here
signals. This is the string the headless tests assert on, so it carries no escape
codes; RENDER-AGENT-ROWS adds the color and the zone markers around it."
  (let ((name (or (getf agent :name) "?"))
        (status (symbol-name (or (getf agent :status) :unknown)))
        (marker (if (and picked (stringp (getf agent :name))
                          (string= picked (getf agent :name)))
                    "*"
                    " ")))
    (format nil "~A ● ~A ~A" marker name status)))
(export 'agent-row-text)

(defun render-agent-rows (agents &key picked)
  "The agent pane body: a header line containing both `agent` and `status`, then one
line per snapshot entry.
MANUAL COMPOSITION, not make-table: the table component has no zone support, so a
row built through it cannot be clicked (research F5). Each row is rendered with a
foreground color chosen by AGENT-LIGHT (green/red/yellow), a picked-row highlight
(blue background + bold) when PICKED names that agent, and wrapped in
(tui:zone-mark \"agent-row:<name>\" ...) so the row is a click target. The whole row,
including its closing marker, stays on ONE line and short enough for *agent-width*
so the viewport does not clip the end marker (research risk 4).
An empty society renders the header alone — the pane must still be visible.
Calling it with no :picked is valid and renders every row unhighlighted."
  (let ((lines (list (format nil "  ~A  ~A" "agent" "status"))))
    (dolist (agent agents)
      (let* ((name (or (getf agent :name) "?"))
             (color (ecase (agent-light agent)
                      (:green tui:*fg-green*)
                      (:red tui:*fg-red*)
                      (:yellow tui:*fg-yellow*)))
             (row-picked (and picked (stringp name) (string= picked name)))
             (style (if row-picked
                        (tui:make-style :foreground color
                                        :background tui:*bg-blue* :bold t)
                        (tui:make-style :foreground color)))
             (text (tui:render-styled style (agent-row-text agent :picked picked))))
        (push (tui:zone-mark (format nil "agent-row:~A" name) text) lines)))
    (lines-to-string (nreverse lines))))
(export 'render-agent-rows)

(defun render-approval-strip (pending)
  "The approval resolution strip: NIL when PENDING is NIL, else one line naming the
capability/target/description and carrying the two zoned affordances the mouse
dispatch hit-tests — (tui:zone-mark \"approval:grant-once\" \"[grant-once]\") and
(tui:zone-mark \"approval:deny\" \"[deny]\").
PENDING is the model's pending-approval plist (or T when only a flag arrived); a
non-list PENDING degrades to placeholders rather than signalling. The strip is
composed as its own line OUTSIDE the chat scrollback, so stored transcript text is
never polluted with zone markers (research open question 2)."
  (when pending
    (let ((plist (if (listp pending) pending nil)))
      (format nil "approval: ~A ~A ~A  ~A ~A"
              (or (getf plist :capability) "?")
              (or (getf plist :target) "")
              (or (getf plist :description) "")
              (tui:zone-mark "approval:grant-once" "[grant-once]")
              (tui:zone-mark "approval:deny" "[deny]")))))
(export 'render-approval-strip)

(defun render-section (title body)
  "A bordered block with a TITLE line above BODY, per notes/tui.md §4."
  (tui:render-border (lines-to-string (list title (or body ""))) *border*))
(export 'render-section)

(defun render-status-bar (text)
  "The one-line status bar: connection state and the last error. It is deliberately
plain — no border — so an error is never hidden behind layout decoration."
  (one-line (or text "")))
(export 'render-status-bar)

;;;; --- layout ------------------------------------------------------------

(defun compose-layout (chat-body repl-body agent-body status-line &optional approval-line)
  "The full frame, per notes/tui.md §4 master-detail:
  +-------------------------------------+--------------------+
  | chat viewport                       | agent rows         |
  | chat textarea                       |                    |
  | repl viewport                       |                    |
  | repl textarea                       |                    |
  +-------------------------------------+--------------------+
  status bar
The left column is chat over repl; the agent pane spans the right; the status bar is
the last line. APPROVAL-LINE, when non-NIL, is inserted between the joined body and
the status bar — its own line, so an approval affordance never lands inside stored
scrollback. Borderless strings are passed through unchanged. The 4-argument call is
still valid: APPROVAL-LINE is optional."
  (let* ((left (tui:join-vertical :left (render-section "chat" chat-body)
                                    (render-section "repl" repl-body)))
         (body (tui:join-horizontal :top left (or agent-body
                                                   (render-agent-rows nil))))
         (frame (if approval-line
                    (tui:join-vertical :left body approval-line
                                       (render-status-bar status-line))
                    (tui:join-vertical :left body (render-status-bar status-line)))))
    frame))
(export 'compose-layout)
