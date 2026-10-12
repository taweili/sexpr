;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;; src/tui-client/messages.lisp — client message classes (M004/S03 T01).
;;;;
;;;; These are THIN DATA CARRIERS. Each one is the decoded form of one wire
;;;; packet (or one RPC reply) plus nothing else: no socket, no model reference,
;;;; no live agent object. The decoder in wire.lisp builds them, the TEA model
;;;; (T04) specializes update-message on them, and the view renders them.
;;;;
;;;; Keeping them thin is what makes the decoder provable with no network and no
;;;; terminal: a message is just data, so a test can build one from a string
;;;; stream and assert its fields.
;;;;
;;;; Slot readers are named <class>-<slot> to match tuition's own message
;;;; classes (key-msg-key, paste-msg-text), and each class gets a make-
;;;; constructor and a -p predicate in the same style as tuition's compat names.

(in-package :sexpr-tui)

(defmessage delta-msg
  ((agent :initarg :agent :initform nil :reader delta-msg-agent)
   (content :initarg :content :initform nil :reader delta-msg-content)
   ;; KIND separates model prose (:model) from a tool's streamed output (:tool) on the
   ;; same wire operator. It defaults to :model so a kind-less frame from an older
   ;; server (S04 or earlier) still decodes as model prose rather than an unknown kind.
   (kind :initarg :kind :initform :model :reader delta-msg-kind))
  :documentation "A streamed fragment from the push channel: (delta :agent A :content S :kind K). K is :model for model prose (the default) or :tool for a tool's streamed output.")

(defmessage resync-msg
  ((agent :initarg :agent :initform nil :reader resync-msg-agent)
   (cursor :initarg :cursor :initform 0 :reader resync-msg-cursor))
  :documentation "Backpressure signal: the server dropped fragments and the client must refetch from CURSOR (the PRE-STREAM cursor, since transcript-length does not advance mid-stream).")

(defmessage subscribed-msg
  ((agent :initarg :agent :initform nil :reader subscribed-msg-agent)
   (cursor :initarg :cursor :initform 0 :reader subscribed-msg-cursor))
  :documentation "The race-closure reply to a subscribe: everything before CURSOR is already on the terminal, so the client renders from CURSOR onward.")

(defmessage wire-ignored-msg
  ((op :initarg :op :initform nil :reader wire-ignored-msg-op)
   (form :initarg :form :initform nil :reader wire-ignored-msg-form))
  :documentation "A wire packet the decoder could not dispatch: an unknown operator, a non-list, or an improper plist. Carried as a message so the model can show it in the status bar instead of losing it silently.")

(defmessage connection-closed-msg
  ((reason :initarg :reason :initform nil :reader connection-closed-msg-reason))
  :documentation "The push connection ended (EOF or a fatal condition on the reader thread).")

(defmessage rpc-result-msg
  ((form :initarg :form :initform nil :reader rpc-result-msg-form)
   (value :initarg :value :initform nil :reader rpc-result-msg-value)
   (error :initarg :error :initform nil :reader rpc-result-msg-error))
  :documentation "One swank RPC reply: the form text that was sent, and either the returned value or the condition. Built by T02's swank client; carried here so the decoder surface is complete.")

(defmessage status-msg
  ((agent :initarg :agent :initform nil :reader status-msg-agent)
   (status :initarg :status :initform nil :reader status-msg-status)
   (pending-approval :initarg :pending-approval :initform nil
                     :reader status-msg-pending-approval))
  :documentation "A per-agent status update: (status :agent A :status S :pending-approval P). S is the agent's status keyword (e.g. :running, :idle) and P is truthy when an approval is outstanding for A. Thin data: the T04 model turns it into a green/red/yellow light.")

(defmessage approval-needed-msg
  ((agent :initarg :agent :initform nil :reader approval-needed-msg-agent)
   (capability :initarg :capability :initform nil :reader approval-needed-msg-capability)
   (target :initarg :target :initform nil :reader approval-needed-msg-target)
   (description :initarg :description :initform nil :reader approval-needed-msg-description)
   (restarts :initarg :restarts :initform nil :reader approval-needed-msg-restarts))
  :documentation "An agent is blocked on an approval: (approval-needed :agent A :capability C :target T :description D :restarts R). RESTARTS is the list of restarts the image offered (kept as data; the client never invokes them directly).")

(defmessage finalize-msg
  ((agent :initarg :agent :initform nil :reader finalize-msg-agent)
   (event-index :initarg :event-index :initform nil :reader finalize-msg-event-index))
  :documentation "A streaming turn ended: (finalize :agent A :event-index N). N is the transcript length at the moment the stream began, so the client can confirm every fragment landed before moving the turn to scrollback.")

(defmessage tool-start-msg
  ((agent :initarg :agent :initform nil :reader tool-start-msg-agent)
   (call-id :initarg :call-id :initform nil :reader tool-start-msg-call-id)
   (name :initarg :name :initform nil :reader tool-start-msg-name))
  :documentation "A tool call began: (tool-start :agent A :call-id C :name N). The viewport shows progress from the start until the matching tool-result.")

(defmessage tool-result-msg
  ((agent :initarg :agent :initform nil :reader tool-result-msg-agent)
   (call-id :initarg :call-id :initform nil :reader tool-result-msg-call-id)
   (value :initarg :value :initform nil :reader tool-result-msg-value)
   (text :initarg :text :initform nil :reader tool-result-msg-text))
  :documentation "A tool call finished: (tool-result :agent A :call-id C :value V :text T). VALUE is the tool's structured result and TEXT its rendered form (both kept as data; the client renders, never re-evaluates).")

(defmessage budget-exceeded-msg
  ((agent :initarg :agent :initform nil :reader budget-exceeded-msg-agent)
   (tokens-used :initarg :tokens-used :initform nil :reader budget-exceeded-msg-tokens-used)
   (limit :initarg :limit :initform nil :reader budget-exceeded-msg-limit))
  :documentation "The agent's token budget was hit and the stream was aborted mid-turn: (budget-exceeded :agent A :tokens-used U :limit L). The viewport shows it so a truncated turn is never mistaken for a finished one.")

;;;; --- constructors and predicates (tuition compat-name style) ----------

(defun make-delta-msg (&key agent content (kind :model))
  "Construct a delta-msg carrying AGENT, CONTENT and KIND (default :model, so an older
kind-less server decodes as model prose)."
  (make-instance 'delta-msg :agent agent :content content :kind kind))
(export 'make-delta-msg)

(defun delta-msg-p (obj)
  "Return true if OBJ is a delta-msg."
  (typep obj 'delta-msg))
(export 'delta-msg-p)

(defun make-resync-msg (&key agent (cursor 0))
  "Construct a resync-msg carrying AGENT and CURSOR."
  (make-instance 'resync-msg :agent agent :cursor cursor))
(export 'make-resync-msg)

(defun resync-msg-p (obj)
  "Return true if OBJ is a resync-msg."
  (typep obj 'resync-msg))
(export 'resync-msg-p)

(defun make-subscribed-msg (&key agent (cursor 0))
  "Construct a subscribed-msg carrying AGENT and CURSOR."
  (make-instance 'subscribed-msg :agent agent :cursor cursor))
(export 'make-subscribed-msg)

(defun subscribed-msg-p (obj)
  "Return true if OBJ is a subscribed-msg."
  (typep obj 'subscribed-msg))
(export 'subscribed-msg-p)

(defun make-wire-ignored-msg (&key op form)
  "Construct a wire-ignored-msg recording the OP name and the original FORM."
  (make-instance 'wire-ignored-msg :op op :form form))
(export 'make-wire-ignored-msg)

(defun wire-ignored-msg-p (obj)
  "Return true if OBJ is a wire-ignored-msg."
  (typep obj 'wire-ignored-msg))
(export 'wire-ignored-msg-p)

(defun make-connection-closed-msg (&key reason)
  "Construct a connection-closed-msg carrying REASON."
  (make-instance 'connection-closed-msg :reason reason))
(export 'make-connection-closed-msg)

(defun connection-closed-msg-p (obj)
  "Return true if OBJ is a connection-closed-msg."
  (typep obj 'connection-closed-msg))
(export 'connection-closed-msg-p)

(defun make-rpc-result-msg (&key form value error)
  "Construct an rpc-result-msg for one swank reply."
  (make-instance 'rpc-result-msg :form form :value value :error error))
(export 'make-rpc-result-msg)

(defun rpc-result-msg-p (obj)
  "Return true if OBJ is an rpc-result-msg."
  (typep obj 'rpc-result-msg))
(export 'rpc-result-msg-p)

(defun make-status-msg (&key agent status pending-approval)
  "Construct a status-msg carrying AGENT, STATUS and PENDING-APPROVAL."
  (make-instance 'status-msg :agent agent :status status
                             :pending-approval pending-approval))
(export 'make-status-msg)

(defun status-msg-p (obj)
  "Return true if OBJ is a status-msg."
  (typep obj 'status-msg))
(export 'status-msg-p)

(defun make-approval-needed-msg (&key agent capability target description restarts)
  "Construct an approval-needed-msg carrying the blocked agent's request data."
  (make-instance 'approval-needed-msg :agent agent :capability capability
                                      :target target :description description
                                      :restarts restarts))
(export 'make-approval-needed-msg)

(defun approval-needed-msg-p (obj)
  "Return true if OBJ is an approval-needed-msg."
  (typep obj 'approval-needed-msg))
(export 'approval-needed-msg-p)

(defun make-finalize-msg (&key agent event-index)
  "Construct a finalize-msg carrying AGENT and EVENT-INDEX."
  (make-instance 'finalize-msg :agent agent :event-index event-index))
(export 'make-finalize-msg)

(defun finalize-msg-p (obj)
  "Return true if OBJ is a finalize-msg."
  (typep obj 'finalize-msg))
(export 'finalize-msg-p)

(defun make-tool-start-msg (&key agent call-id name)
  "Construct a tool-start-msg carrying AGENT, CALL-ID and NAME."
  (make-instance 'tool-start-msg :agent agent :call-id call-id :name name))
(export 'make-tool-start-msg)

(defun tool-start-msg-p (obj)
  "Return true if OBJ is a tool-start-msg."
  (typep obj 'tool-start-msg))
(export 'tool-start-msg-p)

(defun make-tool-result-msg (&key agent call-id value text)
  "Construct a tool-result-msg carrying AGENT, CALL-ID, VALUE and TEXT."
  (make-instance 'tool-result-msg :agent agent :call-id call-id
                                  :value value :text text))
(export 'make-tool-result-msg)

(defun tool-result-msg-p (obj)
  "Return true if OBJ is a tool-result-msg."
  (typep obj 'tool-result-msg))
(export 'tool-result-msg-p)

(defun make-budget-exceeded-msg (&key agent tokens-used limit)
  "Construct a budget-exceeded-msg carrying AGENT, TOKENS-USED and LIMIT."
  (make-instance 'budget-exceeded-msg :agent agent :tokens-used tokens-used
                                      :limit limit))
(export 'make-budget-exceeded-msg)

(defun budget-exceeded-msg-p (obj)
  "Return true if OBJ is a budget-exceeded-msg."
  (typep obj 'budget-exceeded-msg))
(export 'budget-exceeded-msg-p)
