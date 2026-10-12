;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; :sexpr-tui — the remote TUI client process (M004/S03).
;;;;
;;;; BOUNDARY: this package lives in the CLIENT process. That process does not
;;;; quickload :sexpr, so no sexpr.* package exists here — :use is exactly
;;;; (:cl :tuition) and must stay that way. The client reaches the image only
;;;; through the wire (the push channel) and through swank packet TEXT that
;;;; names sexpr.tui RPCs; it never calls a sexpr function directly.
;;;;
;;;; Everything the client holds is DATA: names, cursors, plists, strings and
;;;; message objects (R023). A picked agent is a string, not an agent object.
;;;;
;;;; R015 invariant: the provider transport is never named here, and the client
;;;; never reaches kernel internals — it names sexpr.tui RPCs by qualified name
;;;; inside the packet text it builds.

(defpackage :sexpr-tui
  (:use :cl :tuition)
  ;; :tuition exports #:quit (the TEA quit message sender) and CL exports #:quit.
  ;; A package that :use's both sees QUIT as AMBIGUOUS, so the client package
  ;; shadows it: unqualified `quit` is the client's own symbol, and both meanings
  ;; are reachable by qualified name. Without this the client cannot call either.
  (:shadow #:quit)
  (:export
   ;; --- connection (wire.lisp) ---
   #:tui-connection
   #:make-tui-connection
   #:tui-connection-host
   #:tui-connection-port
   #:tui-connection-socket
   #:tui-connection-stream
   #:tui-connection-program
   #:tui-connection-stats
   #:tui-connection-stats-lock
   #:tui-connection-reader-thread
   #:tui-connection-on-message
   #:make-client-connection
   #:connect-push
   #:write-wire
   #:read-wire
   #:decode-wire
   #:start-wire-reader
   #:close-connection
   #:tui-client-diagnostics
   #:stats-get
   #:wire-operator
   #:*tui-client-log*
   #:*client-stats-keys*
   #:*wire-reader-thread-name*

   ;; --- message classes (messages.lisp) ---
   #:delta-msg
   #:make-delta-msg
   #:delta-msg-agent
   #:delta-msg-content
   #:delta-msg-kind
   #:resync-msg
   #:make-resync-msg
   #:resync-msg-agent
   #:resync-msg-cursor
   #:subscribed-msg
   #:make-subscribed-msg
   #:subscribed-msg-agent
   #:subscribed-msg-cursor
   #:wire-ignored-msg
   #:make-wire-ignored-msg
   #:wire-ignored-msg-op
   #:wire-ignored-msg-form
   #:connection-closed-msg
   #:make-connection-closed-msg
   #:connection-closed-msg-reason
   #:rpc-result-msg
   #:make-rpc-result-msg
   #:rpc-result-msg-form
   #:rpc-result-msg-value
   #:rpc-result-msg-error
   #:status-msg
   #:make-status-msg
   #:status-msg-p
   #:status-msg-agent
   #:status-msg-status
   #:status-msg-pending-approval
   #:approval-needed-msg
   #:make-approval-needed-msg
   #:approval-needed-msg-p
   #:approval-needed-msg-agent
   #:approval-needed-msg-capability
   #:approval-needed-msg-target
   #:approval-needed-msg-description
   #:approval-needed-msg-restarts
   #:finalize-msg
   #:make-finalize-msg
   #:finalize-msg-p
   #:finalize-msg-agent
   #:finalize-msg-event-index
   #:tool-start-msg
   #:make-tool-start-msg
   #:tool-start-msg-p
   #:tool-start-msg-agent
   #:tool-start-msg-call-id
   #:tool-start-msg-name
   #:tool-result-msg
   #:make-tool-result-msg
   #:tool-result-msg-p
   #:tool-result-msg-agent
   #:tool-result-msg-call-id
   #:tool-result-msg-value
   #:tool-result-msg-text
   #:budget-exceeded-msg
   #:make-budget-exceeded-msg
   #:budget-exceeded-msg-p
   #:budget-exceeded-msg-agent
   #:budget-exceeded-msg-tokens-used
   #:budget-exceeded-msg-limit

   ;; --- swank RPC client (swank-rpc.lisp, T02) ---
   #:swank-connection
   #:make-swank-connection
   #:new-swank-connection
   #:swank-connection-host
   #:swank-connection-port
   #:swank-connection-socket
   #:swank-connection-stream
   #:swank-connection-next-id
   #:swank-connection-stats
   #:swank-connection-stats-lock
   #:swank-connect
   #:close-swank-connection
   #:swank-eval
   #:swank-read-reply
   #:swank-value
   #:swank-next-id
   #:swank-packet-text
   #:packet-header
   #:write-packet
   #:read-packet
   #:parse-packet
   #:classify-packet
   #:byte-stream-p
   #:utf8-bytes
   #:utf8-to-string
   #:swank-diagnostics
   ;; stats access shared by tui-connection and swank-connection (T04's status bar
   ;; reads either without knowing which struct it holds)
   #:client-stats
   #:client-stats-lock
   #:client-port
   #:client-label
   #:client-stats-get
   #:client-count!
   #:client-note-error!
   #:client-log!

   ;; --- panes and layout (view.lisp, T04) ---
   #:lines-to-string
   #:one-line
   #:make-chat-viewport
   #:make-chat-textarea
   #:make-repl-viewport
   #:make-repl-textarea
   #:make-agent-viewport
   #:agent-row
   #:agent-row-text
   #:render-agent-rows
   #:render-approval-strip
   #:render-section
   #:render-status-bar
   #:compose-layout
   #:border
   #:chat-width
   #:agent-width
   #:agent-pane-height
   #:chat-viewport-height
   #:repl-viewport-height
   #:textarea-height

   ;; --- the TEA model (model.lisp, T04) ---
   #:tui-model
   #:model-program
   #:model-push-connection
   #:model-swank-connection
   #:model-picked-agent
   #:model-pending-approval
   #:model-agents
   #:model-cursor
   #:model-scrollback
   #:model-scrollback-cap
   #:model-repl-lines
   #:model-repl-cap
   #:model-chat-viewport
   #:model-chat-textarea
   #:model-repl-viewport
   #:model-repl-textarea
   #:model-agent-viewport
   #:model-focused
   #:model-term-width
   #:model-term-height
   #:model-stats
   #:model-status-text
   #:model-readers-running
   #:model-note
   #:model-quitting
   #:tui-init-tick
   #:scrollback-cap
   #:repl-cap
   #:default-term-width
   #:default-term-height
   #:append-line
   #:event-to-line
   #:reply-error-text
   #:swank-rpc
   #:rpc-agent-snapshot
   #:rpc-transcript-delta
   #:rpc-resolve-approval
   #:agent-light
   #:resolve-pending-approval
   #:agent-at-mouse
   #:approval-action-at-mouse
   #:model-switch-agent
   #:handle-mouse
   #:program-running-p
   #:refresh-status
   #:last-error-of
   #:build-panes
   #:refresh-agent-viewport
   #:handle-key
   #:handle-enter
   #:send-chat-note
   #:send-repl-form
   #:resize-panes

   ;; --- entry point (main.lisp, T05) ---
   #:main
   #:parse-args
   #:print-usage
   #:*default-swank-port*))
