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
break the layout. Prefer TRUNCATE-TEXT/WRAP-TEXT below for anything sized to a pane:
this clips by CHARACTER COUNT, which over-measures wide (CJK) text."
  (let ((flat (substitute #\Space #\Newline string)))
    (cond
      ((>= (length flat) limit) (subseq flat 0 limit))
      (t flat))))
(export 'one-line)

;;; --- display-width fitting -------------------------------------------
;;;
;;; WHY THESE EXIST: cl-tuition measures with VISIBLE-LENGTH but never fits.
;;; render-border sizes its box to the widest line, viewport-view prints a line
;;; whole when its x-offset is 0, and join-horizontal/join-vertical do not
;;; truncate. So ONE transcript line wider than its pane widens the section box
;;; past its allotment, the frame grows past the terminal, and the agent pane is
;;; pushed off screen. Fitting is therefore the client's job, and this is the
;;; one place that does it: wrapping preserves content, truncation is for
;;; fixed one-line cells (agent rows, the status bar).
;;;
;;; BOTH ARE ANSI-AWARE AND DISPLAY-WIDTH-AWARE. An escape sequence is zero
;;; columns and travels with the text that follows it, so a styled line (the
;;; grey reasoning block) wraps without corrupting its colour; a wide character
;;; counts two columns, so CJK does not silently overflow.

(defparameter *char-width-cache* (make-hash-table :test #'eql)
  "Display width of each character already measured. VISIBLE-LENGTH of a
one-character string answers the wide/combining question (2 / 1 / 0); caching
it keeps wrapping linear in the length of the line rather than quadratic.")
(export '*char-width-cache*)

(defun char-display-width (char)
  "The number of terminal columns CHAR occupies: 2 for a wide character (CJK),
1 for an ordinary one, 0 for a combining mark. Measured through
VISIBLE-LENGTH so the answer matches how cl-tuition pads and measures."
  (multiple-value-bind (width found) (gethash char *char-width-cache*)
    (if found
        width
        (let ((width (tui:visible-length (string char))))
          (setf (gethash char *char-width-cache*) width)
          width))))
(export 'char-display-width)

(defun %ansi-csi-length (string i)
  "When STRING[I] begins an ANSI CSI sequence (ESC [ ... final-byte), return its
length in characters; otherwise NIL. The final byte is 0x40..0x7E, the same rule
cl-tuition's own VISIBLE-LENGTH uses. A non-CSI ESC is not special-cased: it is
an ordinary (zero-width-ish) character and cannot occur in this UI's output,
which only ever emits CSI SGR sequences."
  (when (and (char= (char string i) #\Escape)
             (< (1+ i) (length string))
             (char= (char string (1+ i)) #\[))
    ;; Start AFTER the '[': '[' itself is 0x5B and would match the final-byte
    ;; range (0x40..0x7E) instantly, truncating every colour sequence. The value
    ;; is a LENGTH FROM I (callers subseq I..I+LEN), not an absolute end index.
    (let ((final (position-if (lambda (c) (<= #x40 (char-code c) #x7E))
                              string :start (+ i 2))))
      (if final
          (- (1+ final) i)
          (- (length string) i)))))

(defun %tokenize-wrapped (text)
  "Split TEXT into WRAP-TEXT tokens: (:space), (:word S W) where S carries any
ANSI escapes inside the word and W is its display width. Tokenizing by WORD is
what makes the wrap greedy per word (a word moves whole to the next line instead
of being torn in half), which a character-at-a-time wrap gets wrong when a line
happens to be exactly full."
  (let ((tokens nil)
        (word "")
        (wordw 0)
        (i 0)
        (n (length text)))
    (labels ((flush-word ()
               (when (plusp (length word))
                 (push (list :word word wordw) tokens)
                 (setf word "" wordw 0))))
      (loop while (< i n) do
        (let ((ch (char text i)))
          (cond
            ((%ansi-csi-length text i)
             (let ((len (%ansi-csi-length text i)))
               (setf word (concatenate 'string word (subseq text i (+ i len))))
               (incf i len)))
            ((char= ch #\Space)
             (flush-word)
             (push (list :space) tokens)
             (incf i))
            (t
             (setf word (concatenate 'string word (string ch)))
             (incf wordw (char-display-width ch))
             (incf i)))))
      (flush-word)
      (nreverse tokens))))
(export '%tokenize-wrapped)

(defun %split-wide-word (word width)
  "Split one WORD longer than WIDTH into chunks of at most WIDTH columns,
preserving ANSI escapes. A word that fits is returned as a one-element list."
  (let ((chunks nil)
        (cur "")
        (curw 0)
        (i 0)
        (n (length word)))
    (loop while (< i n) do
      (let ((ch (char word i)))
        (cond
          ((%ansi-csi-length word i)
           (let ((len (%ansi-csi-length word i)))
             (setf cur (concatenate 'string cur (subseq word i (+ i len))))
             (incf i len)))
          (t
           (let ((w (char-display-width ch)))
             (when (and (plusp curw) (> (+ curw w) width))
               (push cur chunks)
               (setf cur "" curw 0))
             (setf cur (concatenate 'string cur (string ch)))
             (incf curw w)
             (incf i))))))
    (push cur chunks)
    (nreverse chunks)))

(defun wrap-text (text width)
  "Split TEXT into display lines of at most WIDTH columns, breaking BETWEEN WORDS
when the next word does not fit and hard-breaking only a word that is wider than
the pane on its own. ANSI escapes are copied through verbatim and count zero
columns, so styled text keeps its colour across a break. Returns a list of lines;
empty or NIL TEXT yields (\"\"). PURE and total."
  (let ((width (max 1 width))
        (lines nil)
        (cur "")
        (curw 0)
        (pending-space nil))
    (labels ((flush (&optional force)
               (when (or force (plusp (length cur)))
                 (push cur lines)
                 (setf cur "" curw 0))
               (setf pending-space nil))
             (place (chunk)
               (setf cur chunk)
               (setf curw (tui:visible-length chunk))))
      (dolist (token (%tokenize-wrapped (or text "")))
        (case (first token)
          (:space
           ;; leading spaces on an empty line are dropped; otherwise one space is
           ;; pending and is emitted only if a following word still fits
           (when (plusp (length cur))
             (setf pending-space t)))
          (:word
           (let* ((word (second token))
                  (wordw (third token))
                  (sep (if pending-space 1 0)))
             (cond
               ((<= (+ curw sep wordw) width)
                (when pending-space
                  (setf cur (concatenate 'string cur " "))
                  (incf curw))
                (setf cur (concatenate 'string cur word))
                (incf curw wordw))
               (t
                (flush)
                (let ((chunks (%split-wide-word word width)))
                  (if (rest chunks)
                      (progn
                        (dolist (chunk (butlast chunks))
                          (push chunk lines))
                        (place (car (last chunks))))
                      (place (first chunks))))))
             (setf pending-space nil)))))
      (flush t)
      (nreverse lines))))
(export 'wrap-text)

(defun truncate-text (text width &optional (marker "…"))
  "Fit TEXT on ONE display line of at most WIDTH columns, appending MARKER when
content was dropped. ANSI escapes are preserved and never counted, and width is
measured in columns (wide characters count 2), so the result cannot overflow the
cell it is given. PURE and total: a NIL TEXT is an empty line."
  (let* ((width (max 0 width))
         (text (or text "")))
    (if (<= (tui:visible-length text) width)
        text
        (let ((budget (max 0 (- width (tui:visible-length marker)))))
          (with-output-to-string (out)
            (let ((w 0)
                  (i 0)
                  (n (length text)))
              (loop while (< i n) do
                (let ((ch (char text i)))
                  (cond
                    ((%ansi-csi-length text i)
                     (let ((len (%ansi-csi-length text i)))
                       (write-string (subseq text i (+ i len)) out)
                       (incf i len)))
                    (t
                     (let ((cw (char-display-width ch)))
                       (when (> (+ w cw) budget)
                         (write-string marker out)
                         (return))
                       (write-char ch out)
                       (incf w cw)
                       (incf i))))))))))))
(export 'truncate-text)

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

(defun agent-row-text (agent &key picked width)
  "The PLAIN, zone-free text of one agent row: a picked marker (\"*\" when
PICKED names this agent, else a space), the light glyph \"●\", the agent name, and
the display label of the status (agent-status-label) — e.g. \"* ● Alpha RUNNING\", and \"* ● Alpha IDLE\" for a finished agent.
PURE and total: a missing :name/:status degrades to \"?\"/\"UNKNOWN\" and nothing here
signals. WIDTH, when positive, truncates the row to that many columns so a long
agent name cannot widen the pane box past its allotment (render-border sizes to
the widest line). This is the string the headless tests assert on, so it carries
no escape codes; RENDER-AGENT-ROWS adds the color and the zone markers around it."
  (let ((name (or (getf agent :name) "?"))
        (status (agent-status-label (getf agent :status)))
        (marker (if (and picked (stringp (getf agent :name))
                          (string= picked (getf agent :name)))
                    "*"
                    " ")))
    (let ((text (format nil "~A ● ~A ~A" marker name status)))
      (if (and width (plusp width))
          (truncate-text text width)
          text))))
(export 'agent-row-text)

(defun agent-detail-lines (agent)
  "Up to two lines for the PICKED row's snapshot fields the pane never showed:
  line 1 — budget and capabilities;
  line 2 — endpoint, transcript length and handle.
The image already sends all of these in every agent-snapshot, so this costs no
RPC — it makes the projection worth its bytes and gives an operator a society
view htop cannot show. TWO lines rather than one because a single 80-column
label-crammed line truncated most of them away; each line is short enough to
survive the widest common pane, and the caller truncates either that does not.
PURE and total: a non-list AGENT is NIL; missing keys degrade to placeholders
and nothing signals."
  (unless (listp agent)
    (return-from agent-detail-lines nil))
  (let* ((budget-val (getf agent :budget))
         (budget (cond ((eq budget-val :unlimited) "unlimited")
                       ((listp budget-val)
                        (format nil "~A tok/~As"
                                (or (getf budget-val :tokens) "?")
                                (or (getf budget-val :seconds) "?")))
                       (t "?")))
         (caps (or (getf agent :capabilities) "-"))
         (endpoint (or (getf agent :endpoint) "default"))
         (length (or (getf agent :transcript-length) "?"))
         (handle (or (getf agent :handle) "-")))
    (list (format nil "  budget=~A caps=~A" budget caps)
          (format nil "  endpoint=~A len=~A handle=~A"
                  endpoint length handle))))
(export 'agent-detail-lines)

(defun render-agent-rows (agents &key picked width detail)
  "The agent pane body: a header line containing both `agent` and `status`, the
optional DETAIL lines for the picked agent (AGENT-DETAIL-LINES, a list), then
one line per snapshot entry.
MANUAL COMPOSITION, not make-table: the table component has no zone support, so a
row built through it cannot be clicked (research F5). Each row is rendered with a
foreground color chosen by AGENT-LIGHT (green/red/yellow) and wrapped in
(tui:zone-mark \"agent-row:<name>\" ...) so the row is a click target. The whole row,
including its closing marker, stays on ONE line and is truncated to WIDTH columns
when WIDTH is given, so the viewport never has to clip the end marker (research
risk 4) and the pane box never outgrows the layout.
An empty society renders the header alone — the pane must still be visible.
Calling it with no :picked is valid and renders every row unhighlighted."
  (let ((lines (list (format nil "  ~A  ~A" "agent" "status"))))
    (dolist (line (if (listp detail) detail (when detail (list detail))))
      (push (if (and width (plusp width))
                 (truncate-text line width)
                 line)
            lines))
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
             (text (tui:render-styled style
                                      (agent-row-text agent :picked picked :width width))))
        (push (tui:zone-mark (format nil "agent-row:~A" name) text) lines)))
    (lines-to-string (nreverse lines))))
(export 'render-agent-rows)

(defparameter *approval-decisions* '(:grant-once :grant-session :grant-always :deny)
  "The resolution decisions the image's sexpr.tui:resolve-approval accepts, in the
order the strip renders them. The set is the image's contract
(notes/tui.md §9); a request may offer any subset via :restarts.")
(export '*approval-decisions*)

(defun approval-decisions (pending)
  "The decisions to offer for PENDING: the canonical order intersected with the
request's :restarts when that is a list, else the two always-safe defaults
(:grant-once :deny). PURE and total — a non-list :restarts, NIL, or T degrades to
the defaults rather than signalling."
  (let* ((plist (if (listp pending) pending nil))
         (offered (getf plist :restarts)))
    (if (and (listp offered) offered)
        (let ((subset (remove-duplicates offered :test #'eq)))
          (or (remove-if-not (lambda (d) (member d subset)) *approval-decisions*)
              '(:grant-once :deny)))
        '(:grant-once :deny))))
(export 'approval-decisions)

(defun approval-zone-id (decision)
  "The zone id of one approval decision's button: \"approval:<decision>\". The
SYMBOL-NAME is used because ~A on a keyword would drop the colon and, worse,
print the name in the case the reader happened to intern it; zone ids are part
of the client's own click contract and are matched literally."
  (format nil "approval:~A" (string-downcase (symbol-name decision))))
(export 'approval-zone-id)

(defun render-approval-strip (pending &optional width)
  "The approval resolution strip: NIL when PENDING is NIL, else one line naming the
capability/target/description and carrying one zoned affordance per decision the
request offers (APPROVAL-DECISIONS) — e.g. (tui:zone-mark \"approval:grant-once\"
\"[grant-once]\"). Rendering every offered restart is what makes grant-session /
grant-always reachable: they were previously carried on the wire and never shown.
WIDTH, when positive, truncates the descriptive part so the whole strip stays
inside its row (the zone markers are ANSI and count zero columns).
PENDING is the model's pending-approval plist (or T when only a flag arrived); a
non-list PENDING degrades to placeholders rather than signalling. The strip is
composed as its own line OUTSIDE the chat scrollback, so stored transcript text is
never polluted with zone markers (research open question 2)."
  (when pending
    (let* ((plist (if (listp pending) pending nil))
           (decisions (approval-decisions pending))
           (buttons (mapcar (lambda (d)
                              (tui:zone-mark (approval-zone-id d)
                                             (format nil "[~A]"
                                                     (string-downcase (symbol-name d)))))
                            decisions))
           ;; buttons are joined by a single space, so the row costs the sum of
           ;; their widths plus one space between neighbours; that much of WIDTH
           ;; is reserved before the descriptive text is truncated.
           (reserve (+ (reduce #'+ buttons
                               :key (lambda (b) (tui:visible-length b)))
                       (max 0 (1- (length buttons)))))
           (info (format nil "approval: ~A ~A ~A"
                         (or (getf plist :capability) "?")
                         (or (getf plist :target) "")
                         (or (getf plist :description) "")))
           (info (if (and width (plusp width))
                     (truncate-text info (max 0 (- width reserve)))
                     info)))
      (format nil "~A  ~{~A~^ ~}" info buttons))))
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
FITTED to WIDTH display columns (ANSI- and wide-character-aware), so the bar
cannot outgrow the frame it sits in; an older caller's width is still respected."
  (let ((text (or text "")))
    (if (plusp width)
        (truncate-text text width)
        text)))
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
