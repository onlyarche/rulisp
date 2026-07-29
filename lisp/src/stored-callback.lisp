(in-package #:rulisp)

;;; Stored callbacks (v0.2): a Lisp closure registered under a numeric id
;;; that Rust may keep and invoke later, from any thread. The id travels in
;;; the ABI slot v1 reserved (the trampoline's leading uint64), so the wire
;;; is unchanged — ABI 1.
;;;
;;; Lifetime model mirrors handles, inverted: the CALLBACK-TOKEN keeps the
;;; closure registered; unregistering (explicitly or via the token's GC
;;; finalizer) makes later Rust invocations fail SAFELY — a warning plus an
;;; error status, never a dangling dereference. Keep the token reachable
;;; for as long as Rust may call.
;;;
;;; Error protocol: there may be no rulisp call frame on the invoking
;;; thread to re-signal into (a Rust worker, a wasm host function), so a
;;; condition signaled by the closure is WARNED here and reported to Rust
;;; as a nonzero status (`CallbackError`). Rust decides what that means
;;; (e.g. the wasm example turns it into a guest trap).

(defvar *stored-callbacks* (make-hash-table)
  "id → closure. Guarded by *stored-callbacks-lock*; invocations may
arrive on foreign threads (adopted by the Lisp on entry).")

(defvar *stored-callbacks-lock* (bt:make-lock "rulisp-stored-callbacks"))

(defvar *next-callback-id* 0)

(defclass callback-token ()
  ((id :initarg :id :reader callback-token-id)
   (registered :initform t :accessor %token-registered)))

(defmethod print-object ((token callback-token) stream)
  (print-unreadable-object (token stream :type t :identity t)
    (format stream "id ~D~:[ (unregistered)~;~]"
            (callback-token-id token) (%token-registered token))))

(defun callback (function)
  "Register FUNCTION for storage on the Rust side; returns a CALLBACK-TOKEN
to pass to any wrapper parameter declared as a stored callback. The token
keeps FUNCTION alive: hold on to it while Rust may invoke, then
UNREGISTER-CALLBACK it (or let the GC finalize it — a later invocation
fails safely either way)."
  (check-type function function)
  (let (id)
    (bt:with-lock-held (*stored-callbacks-lock*)
      (setf id (incf *next-callback-id*)
            (gethash id *stored-callbacks*) function))
    (let ((token (make-instance 'callback-token :id id)))
      (tg:finalize token
                   (lambda ()
                     (bt:with-lock-held (*stored-callbacks-lock*)
                       (remhash id *stored-callbacks*))))
      token)))

(defun unregister-callback (token)
  "Remove TOKEN's closure from the registry. Idempotent; returns T when
this call removed it. Rust invocations after this fail safely."
  (check-type token callback-token)
  (bt:with-lock-held (*stored-callbacks-lock*)
    (prog1 (remhash (callback-token-id token) *stored-callbacks*)
      (setf (%token-registered token) nil))))

(defun %stored-callback-lookup (id)
  (bt:with-lock-held (*stored-callbacks-lock*)
    (gethash id *stored-callbacks*)))
