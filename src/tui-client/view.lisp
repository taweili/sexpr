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
;;;;
;;;; THE IN-FLIGHT STREAM IS PART OF THE CHAT VIEWPORT (M004/S05 T06). The growing
;;;; streamed line is NOT a separate pane or layout state: MODEL-RENDER-CHAT (model.lisp)
;;;; writes the committed scrollback followed by the in-flight line into the chat
;;;; viewport's content, and tui:view already renders that viewport. So view.lisp needs
;;;; no new state — tool/budget progress lines are plain prefixed scrollback lines and
;;;; the in-flight line simply rides along as the viewport's last line.

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

(defparameter *focus-color* tui:*fg-cyan*
  "The border color of the section that owns key input.
A cl-tuition textarea draws its cursor only when it holds text: with the input
empty the placeholder branch of textarea-view returns before the cursor is
rendered, so an empty focused input looks identical to an empty unfocused one.
The colored border is therefore the operator's only cue about which of the two
inputs will take the next key.")
(export '*focus-color*)

;;;; --- responsive layout -------------------------------------------------
;;;
;;; Every pane size is DERIVED from the terminal size by LAYOUT-DIMENSIONS. The
;;; pane constructors below keep fixed first-paint defaults only so the panes are
;;; usable when built standalone in a headless test; tui:init and resize-panes
;;; overwrite them from layout-dimensions. *chat-width*, *agent-width* and the
;;; three *-height parameters are the 80x24 answers to the same question, so the
;;; first frame and the first reflow agree and the UI does not jump on start.

(defparameter *section-overhead* 4
  "Rows one bordered section costs beyond its viewport rows: the title line, the
border row above and below the content, and the one-line textarea with no border of
its own. render-section emits title, top border, content, textarea, bottom border,
so a section is viewport-rows + 4 rows tall. Getting this number right is what makes
the left column exactly as tall as the agent pane; at 2 the left column came out
four rows short and the frame showed two blank rows above the status bar.")
(export '*section-overhead*)

(defparameter *chrome-rows* 2
  "Rows the bottom chrome costs: the approval strip and the status bar, one row
each. The approval row is reserved whether or not an approval is pending, so the
frame height never changes when an approval arrives.")
(export '*chrome-rows*)

(defparameter *chat-min-width* 20
  "The narrowest chat column layout-dimensions will produce.")
(export '*chat-min-width*)

(defparameter *agent-min-width* 20
  "The narrowest agent pane. The rows render as \"* ● Name STATUS\", about 20
columns for a short name.")
(export '*agent-min-width*)

(defparameter *agent-max-width* 48
  "The widest agent pane. Without a cap a 250-column monitor would hand the agent
list 75 columns and leave the rows staring at an empty second half.")
(export '*agent-max-width*)

(defparameter *agent-width-share* 0.30
  "The fraction of the terminal width the agent pane takes, before the min and
max clamps. Everything left over goes to the chat column.")
(export '*agent-width-share*)

(defparameter *chat-min-height* 3
  "The shortest chat viewport; below this a transcript cannot be read at all.")
(export '*chat-min-height*)

(defparameter *repl-min-height* 1
  "The shortest REPL viewport.")
(export '*repl-min-height*)

(defparameter *agent-min-height* 3
  "The shortest agent pane.")
(export '*agent-min-height*)

(defparameter *layout-min-width* 42
  "Below this many columns the layout cannot hold both columns at their minimums.")
(export '*layout-min-width*)

(defparameter *layout-min-height* 14
  "The smallest height at which the frame fits exactly: *chat-min-height* +
*repl-min-height* + 2 * *section-overhead* + *chrome-rows*. Below it the section
minimums push the left column past the bottom of the terminal, which is unavoidable
— the panes have to show something.")
(export '*layout-min-height*)

(defun layout-dimensions (width height)
  "Every pane size for a terminal of WIDTH columns and HEIGHT rows.
Returns (VALUES chat-width agent-width chat-height repl-height agent-height) as
plain non-negative integers.

The frame is join-horizontal(chat section, agent pane) sitting over the chrome
rows, so it is chat-width + 2 (its border) + agent-width wide, and left-column +
chrome-rows tall, where the left column is chat-height + repl-height +
2 * section-overhead. Solving both equations instead of hardcoding either gives an
exact fit: a terminal of at least *layout-min-width* x *layout-min-height* is used
completely, no more and no less, with no blank rows anywhere in the frame.

The agent pane takes *agent-width-share* of the width, clamped to
[*agent-min-width*, *agent-max-width*]; the REPL viewport takes a quarter of the
rows left for the viewports, clamped to [*repl-min-height*, one third of them];
the chat viewport takes the remainder.

PURE and total: a zero, negative or non-integer window degrades to the smallest
usable layout rather than signalling, so a 1x1 resize event cannot take the UI
down or produce a zero-sized pane. Nothing here returns zero either: a
zero-height viewport renders NOTHING at all (research F2)."
  (let ((width (max *layout-min-width* (if (integerp width) width 0)))
        (height (max *layout-min-height* (if (integerp height) height 0))))
    (let* ((agent-width (min *agent-max-width*
                             (max *agent-min-width*
                                  (floor (* width *agent-width-share*)))))
           ;; join-horizontal adds no gap, so the left column is exactly what the
           ;; agent pane leaves behind.
           (chat-width (max *chat-min-width* (- width 2 agent-width)))
           ;; the viewports share what the chrome and the two section boxes leave.
           (rows (max 0 (- height *chrome-rows* (* 2 *section-overhead*))))
           (repl-height (max *repl-min-height*
                            (min (floor rows 4)
                                 (max *repl-min-height* (ceiling rows 3)))))
           (chat-height (max *chat-min-height* (- rows repl-height)))
           ;; the agent pane is unbordered, so it spans the whole body.
           (agent-height (max *agent-min-height* (+ rows (* 2 *section-overhead*)))))
      (values chat-width agent-width chat-height repl-height agent-height))))
(export 'layout-dimensions)

(defun block-width (text)
  "The widest visible line of the rendered block TEXT, in columns.
cl-tuition has the same helper but does not export it, so it is named here; the
status bar is clipped to the width it sits under rather than a fixed 240."
  (let ((lines (tui:split-string-by-newline text)))
    (if lines (apply #'max (mapcar #'tui:visible-length lines)) 0)))
(export 'block-width)

(defun pad-block (text width)
  "Every line of the rendered block TEXT padded with spaces to exactly WIDTH
columns, and no shorter block is widened below its own widest line.
cl-tuition's viewport-view, textarea-view and render-border all size themselves to
the content, never to a requested width: render-border measures its box from the
widest line and viewport-view prints each line bare. Without this the chat and REPL
sections render at the width of their longest transcript line, the frame comes out
29 columns wide on an 80-column terminal, and the agent pane hugs a 60-column gap
on the right. Padding here is what makes layout-dimensions actually reach the
screen. Padding is measured with visible-length, so ANSI escapes already in the
text are neither counted nor disturbed."
  (let ((lines (mapcar (lambda (line)
                         (let* ((n (tui:visible-length line))
                                (pad (max 0 (- width n))))
                           (if (plusp pad)
                               (concatenate 'string line
                                             (make-string pad :initial-element #\Space))
                               line)))
                       (tui:split-string-by-newline (or text "")))))
    (lines-to-string lines)))
(export 'pad-block)

(defun pad-block-rect (text width height)
  "Pad TEXT to exactly WIDTH columns and HEIGHT rows: every line is padded to
WIDTH, and blank WIDTH-wide lines are appended (or lines truncated) until the
row count is exactly HEIGHT. Measured with visible-length, so ANSI escapes
already in the text are neither counted nor disturbed.
This is the height-fixing companion to pad-block: pad-block fixes width only,
and join-horizontal pads the SHORTER side with bare spaces — so an agent pane
shorter than the left column gets unbordered blank rows below the border. A
rectangular pad BEFORE the border makes the border span the full body height."
  (let* ((lines (tui:split-string-by-newline (or text "")))
         (padded (mapcar (lambda (line)
                           (let* ((n (tui:visible-length line))
                                  (pad (max 0 (- width n))))
                             (if (plusp pad)
                                 (concatenate 'string line
                                               (make-string pad :initial-element #\Space))
                                 line)))
                         lines))
         (blank (make-string width :initial-element #\Space)))
    (loop while (< (length padded) height)
          do (setf padded (append padded (list blank))))
    (setf padded (subseq padded 0 (min height (length padded))))
    (lines-to-string padded)))
(export 'pad-block-rect)

;;;; --- panes -------------------------------------------------------------
;;;
;;; The five fixed numbers below are layout-dimensions of an 80x24 terminal: the
;;; constructor defaults. They exist so the first frame (drawn before the first
;;; window-size-msg is drained) and the first reflow agree. A test pins them to
;;; (layout-dimensions 80 24) so the two cannot drift apart.

(defparameter *chat-width* 54
  "First-paint chat column width: (layout-dimensions 80 24).")
(export '*chat-width*)

(defparameter *agent-width* 24
  "First-paint agent pane width: (layout-dimensions 80 24).")
(export '*agent-width*)

(defparameter *agent-pane-height* 22
  "First-paint agent pane height: (layout-dimensions 80 24). It has to be
positive, not 0 — a zero-height viewport renders NOTHING even with rows present
(research F2).")
(export '*agent-pane-height*)

(defparameter *chat-viewport-height* 11
  "First-paint chat viewport height: (layout-dimensions 80 24).")
(export '*chat-viewport-height*)

(defparameter *repl-viewport-height* 3
  "First-paint REPL viewport height: (layout-dimensions 80 24).")
(export '*repl-viewport-height*)

(defparameter *textarea-height* 1
  "Both textareas are one line: chat input and a REPL prompt, not editors.")
(export '*textarea-height*)

(defun make-chat-viewport (&optional (width *chat-width*) (height *chat-viewport-height*))
  "The chat scrollback pane. Empty on construction; the model sets its content."
  (tui.viewport:make-viewport :width width :height height))
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

(defun make-repl-viewport (&optional (width *chat-width*) (height *repl-viewport-height*))
  "The REPL output pane."
  (tui.viewport:make-viewport :width width :height height))
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

(defun make-agent-viewport (&optional (width *agent-width*) (height *agent-pane-height*))
  "The agent pane. A VIEWPORT, not a table component: `table-render` is a one-shot
string function with no TEA protocol, so composing it inside a viewport keeps the
pane scrollable when the society is larger than the pane. The rows themselves are
rendered by RENDER-AGENT-ROWS. The height is positive, never 0: a zero-height
viewport clips every row away (research F2)."
  (tui.viewport:make-viewport :width width :height height))
(export 'make-agent-viewport)

(defun agent-row (agent)
  "One table row from an agent-snapshot plist: (NAME STATUS).
`:name` and `:status` are the only two fields the plan asks for, so the row never
invents a third column. A missing field degrades to a placeholder rather than a
NIL cell, which `table-render` would pad as an empty string anyway."
  (list (or (getf agent :name) "?")
        (symbol-name (or (getf agent :status) :unknown))))
(export 'agent-row)

(defun agent-status-label (status)
  "The display label for one agent status value.

The kernel's terminal states collapse to the operator-facing vocabulary:
:finished reads IDLE — the turn is done and the agent is available again,
the green-light state — so a finished agent is never mistaken for a busy
one (the bug this fixes: a pane that kept the initform :running forever).
:failed and :killed keep their names, so a dead agent is never mistaken
for an idle one. Any other value — including the :idle of the test
vocabulary and a non-symbol — degrades to the upcased name, and NIL to
UNKNOWN. PURE and total: nothing here signals."
  ;; The label helper guards against NIL (a symbol whose name would be
  ;; "NIL") and non-symbols: both degrade to UNKNOWN.
  (flet ((label (s) (if (and s (symbolp s)) s :unknown)))
    (case (label status)
      (:running "RUNNING")
      (:finished "IDLE")
      (:failed "FAILED")
      (:killed "KILLED")
      (otherwise (string-upcase
                  (symbol-name (label status)))))))
(export 'agent-status-label)

(defun agent-row-text (agent &key picked)
  "The PLAIN, ANSI-free, zone-free text of one agent row: a picked marker (\"*\" when
PICKED names this agent, else a space), the light glyph \"●\", the agent name, and
the display label of the status (agent-status-label) — e.g. \"* ● Alpha RUNNING\", and \"* ● Alpha IDLE\" for a finished agent.
PURE and total: a missing :name/:status degrades to \"?\"/\"UNKNOWN\" and nothing here
signals. This is the string the headless tests assert on, so it carries no escape
codes; RENDER-AGENT-ROWS adds the color and the zone markers around it."
  (let ((name (or (getf agent :name) "?"))
        (status (agent-status-label (getf agent :status)))
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
             ;; All rows use the same style (foreground color only). The
             ;; picked agent is still marked by the "*" text marker in
             ;; agent-row-text, but no longer gets a blue background +
             ;; bold highlight.
             (style (tui:make-style :foreground color))
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

(defun render-section (title body &key focused (width nil width-p))
  "A bordered block with a TITLE line above BODY, per notes/tui.md §4.
When FOCUSED is true the border is drawn in *focus-color*. That is the operator's
only cue about which input owns the next key: a textarea holding no text renders
its placeholder without a cursor, so an empty focused input would otherwise look
identical to an empty unfocused one.
WIDTH, when given, is the OUTER width in columns including both border columns:
the title and body are padded to WIDTH minus 2 so render-border draws a box that
exactly fills it. Without it the box sizes to its widest line, which is what the
standalone callers want."
  (let ((inner (if width-p
                   (pad-block (lines-to-string (list title (or body ""))) (- width 2))
                   (lines-to-string (list title (or body ""))))))
    (tui:render-border inner *border* :fg-color (when focused *focus-color*))))
(export 'render-section)

(defun render-status-bar (text &optional (width 240))
  "The one-line status bar: connection state and the last error. It is deliberately
plain — no border — so an error is never hidden behind layout decoration.
CLIPPED to WIDTH columns so the bar cannot outgrow the frame it sits in."
  (one-line (or text "") width))
(export 'render-status-bar)

(defun %textarea-slot (textarea slot-name)
  "Read one of the textarea's NON-EXPORTED slots (LINES / ROW / COL) by name.
cl-tuition exports the cursor position and the value but not the per-line
content or the row/col separately. The project's established pattern for a
non-exported slot is slot-value + intern (see program-running-p), so the
renderer reads them the same way. Returns NIL when the slot cannot be read,
so the renderer degrades rather than signalling."
  (handler-case
      (slot-value textarea (intern (string-upcase slot-name)
                                   (find-package "TUITION.COMPONENTS.TEXTAREA")))
    (error () nil)))
(export '%textarea-slot)

(defun render-textarea (textarea)
  "Render one textarea line for the frame: PROMPT + content, with the cursor
as a REVERSE-VIDEO character on the focused line.

WHY NOT cl-tuition's textarea-view: it wraps the character under the cursor in
[..] — while typing, an input reading "hello" renders as "hello[ ]"
(bracket-space-bracket once the cursor passes the last character), the "extra []"
the operator sees. Its cursor-blink slot is dead (never read by the view), so
there is no accessor to change the cursor style. The project already treats the
section border (*focus-color*) as the focus cue, so the cursor only needs to mark
the insert position — reverse video is the terminal-standard way to do that.

MIRRORS cl-tuition's contract: the placeholder branch fires when the value is
empty (and shows no cursor — a placeholder is not a cursor position); the cursor
appears only on the focused line at the insert column. PURE and total: anything
unreadable degrades to an empty string rather than signalling, so a half-built
pane cannot take the frame down."
  (handler-case
      (let* ((lines (%textarea-slot textarea "LINES"))
             (row (%textarea-slot textarea "ROW"))
             (col (%textarea-slot textarea "COL"))
             (focused (tui.textarea:textarea-focused textarea))
             (prompt (tui.textarea:textarea-prompt textarea))
             (placeholder (tui.textarea:textarea-placeholder textarea))
             (value (tui.textarea:textarea-value textarea)))
        (cond
          ((string= value "")
           ;; empty: the placeholder, and no cursor — cl-tuition's own rule (a
           ;; placeholder is not a cursor position). A NIL placeholder renders
           ;; as nothing after the prompt.
           (format nil "~A~A" prompt placeholder))
          ((and lines (integerp row) (integerp col))
           (let* ((line-text (if (< row (length lines)) (aref lines row) ""))
                  (before (subseq line-text 0 (min col (length line-text))))
                  (at-cursor (if (< col (length line-text))
                                (string (char line-text col))
                                " "))
                  (after (if (< col (length line-text))
                             (subseq line-text (min (1+ col) (length line-text)))
                             ""))
                  ;; REVERSE video, never brackets — the focus cue is the section
                  ;; border (*focus-color*), the cursor only marks the insert spot.
                  (cursor (if focused
                              (tui:render-styled (tui:make-style :reverse t)
                                                at-cursor)
                              at-cursor)))
             (format nil "~A~A~A~A" prompt before cursor after)))
          (t "")))
      ;; PURE and total: a NIL textarea (or an unreadable slot) degrades to an
      ;; empty string rather than signalling — a half-built pane cannot take
      ;; the frame down.
      (error () "")))
(export 'render-textarea)

;;;; --- layout ------------------------------------------------------------

(defun compose-layout (chat-body repl-body agent-body status-line
                       &optional approval-line
                       &key chat-focused repl-focused (width 80) (height 24))
  "The full frame, per notes/tui.md §4 master-detail:
  +-------------------------------------+--------------------+
  | chat viewport                       | agent rows         |
  | chat textarea                       |                    |
  | repl viewport                       |                    |
  | repl textarea                       |                    |
  +-------------------------------------+--------------------+
  approval strip
  status bar
The left column is chat over repl; the agent pane spans the right; the approval
strip and the status bar are the last two lines. APPROVAL-LINE, when non-NIL,
occupies the strip; when nil the strip still takes its row (see *chrome-rows*), so
the frame height does not move when an approval arrives or clears.
CHAT-FOCUSED and REPL-FOCUSED color the matching section's border in *focus-color,
so the operator can see which input takes the next key even with both inputs
empty. Both false is valid: nothing is highlighted. The agent pane is always
bordered but never colored — it is read-only, so its plain border is the
contrast that makes the focused pane's cyan border stand out.
WIDTH and HEIGHT are the terminal size in columns and rows. Every pane size is
derived from them by layout-dimensions, and every block is padded to its allotted
width with pad-block, so the frame comes out exactly WIDTH by HEIGHT. This is the
whole point of the section: cl-tuition sizes every block to its content, so a frame
left to its own devices renders as a 29-column strip on an 80-column screen.
Borderless strings are passed through unchanged. The 4-argument call is still
valid: APPROVAL-LINE, both focus flags and both sizes are optional."
  (multiple-value-bind (chat-w agent-w chat-h repl-h agent-h)
      (layout-dimensions width height)
    (declare (ignore agent-h))
    (let* ((left-width (+ chat-w 2))
           ;; the body height is the left column height: two sections, each
           ;; viewport-height + *section-overhead*. The agent pane's border
           ;; must span this height so it visually encloses the same rows.
           (body-height (+ chat-h repl-h (* 2 *section-overhead*)))
           (left (tui:join-vertical :left
                                     (render-section "chat" chat-body :focused chat-focused
                                                     :width left-width)
                                     (render-section "repl" repl-body :focused repl-focused
                                                     :width left-width)))
           ;; The agent pane gets a border (same *border* style as the
           ;; sections) so all three panes have visible frames. The agent is
           ;; read-only — never focused — so its border is always plain (no
           ;; *focus-color*). The content is padded to a rectangle of
           ;; (agent-w - 2) x (body-height - 2) BEFORE the border is applied,
           ;; so the border's top and bottom rows reach the full body height.
           (agent-pane (tui:render-border
                        (pad-block-rect (or agent-body
                                            (render-agent-rows nil))
                                        (- agent-w 2)
                                        (- body-height 2))
                        *border*))
           (body (tui:join-horizontal :top left
                                      agent-pane))
           (frame (tui:join-vertical :left body
                                     (pad-block (or approval-line " ")
                                                left-width)
                                     (render-status-bar status-line
                                                        (block-width body)))))
      frame)))
(export 'compose-layout)
