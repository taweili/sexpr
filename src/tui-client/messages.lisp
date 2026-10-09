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
   (content :initarg :content :initform nil :reader delta-msg-content))
  :documentation "A streamed fragment from the push channel: (delta :agent A :content S).")

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

;;;; --- constructors and predicates (tuition compat-name style) ----------

(defun make-delta-msg (&key agent content)
  "Construct a delta-msg carrying AGENT and CONTENT."
  (make-instance 'delta-msg :agent agent :content content))
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
