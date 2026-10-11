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
;;;; THE AGENT PANE IS ROWS ONLY. No status lights and no click handling: S04
;;;; specializes this host with zones and colors. The plan names this explicitly, so
;;;; the pane is deliberately a plain table the next slice can decorate.

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
  (let ((flat (replace #\Space (string #\Newline) string)))
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
rendered by RENDER-AGENT-ROWS."
  (tui.viewport:make-viewport :width *agent-width* :height 0))
(export 'make-agent-viewport)

(defun agent-row (agent)
  "One table row from an agent-snapshot plist: (NAME STATUS).
`:name` and `:status` are the only two fields the plan asks for, so the row never
invents a third column. A missing field degrades to a placeholder rather than a
NIL cell, which `table-render` would pad as an empty string anyway."
  (list (or (getf agent :name) "?")
        (symbol-name (or (getf agent :status) :unknown))))
(export 'agent-row)

(defun render-agent-rows (agents)
  "The agent pane body: headers `agent`/`status` and one row per snapshot entry.
No status lights and no click handling (S04 specializes this host).
An empty society renders the headers alone — the pane must still be visible, so an
empty table is a real layout element, not a gap."
  (let ((tbl (tui.render.table:make-table
              :headers (list "agent" "status")
              :rows (mapcar #'agent-row agents)
              :border *border*)))
    (tui.render.table:table-render tbl)))
(export 'render-agent-rows)

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

(defun compose-layout (chat-body repl-body agent-body status-line)
  "The full frame, per notes/tui.md §4 master-detail:
  +-------------------------------------+--------------------+
  | chat viewport                       | agent rows         |
  | chat textarea                       |                    |
  | repl viewport                       |                    |
  | repl textarea                       |                    |
  +-------------------------------------+--------------------+
  status bar
The left column is chat over repl; the agent pane spans the right; the status bar is
the last line. Borderless strings are passed through unchanged."
  (let* ((left (tui:join-vertical :left (render-section "chat" chat-body)
                                    (render-section "repl" repl-body)))
         (body (tui:join-horizontal :top left (or agent-body
                                                   (render-agent-rows nil))))
         (frame (tui:join-vertical :left body (render-status-bar status-line))))
    frame))
(export 'compose-layout)
