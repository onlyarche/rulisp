(in-package #:rulisp)

;;; Handle cell state machine with in-flight counting + deferred free
;;; (DESIGN.md §6.2). Lock discipline: the lock protects state transitions
;;; only and is NEVER held across a foreign call — and never held while
;;; signaling either (handlers run in the signaling frame BEFORE unwinding,
;;; so signaling under the lock would let arbitrary handler code deadlock
;;; against it). Reentrant callbacks and concurrent method calls on the same
;;; handle stay deadlock-free, and the free-vs-in-flight-call use-after-free
;;; race is structurally unreachable.

(defvar *session* 0
  "Bumped first thing in the image-restore hook: every cell created before a
dump belongs to a dead session and is refused without any foreign call.")

(defstruct (cell (:constructor %make-cell (ptr generation session free-fn crate)))
  ptr
  (state :live :type (member :live :free-pending :freed))
  generation                            ; birth generation of the allocation
  session
  (in-flight 0 :type (integer 0))
  free-fn                               ; birth generation's free shim pointer
  crate                                 ; owning crate (for staleness display)
  (lock (bt:make-lock "rulisp-handle-cell")))

(defclass handle ()
  ((cell :initarg :cell :reader handle-cell))
  (:documentation "Abstract superclass of all generated crate handle classes."))

(defun cell-begin-call (cell birth-generation fn-name)
  "Gate + in-flight++ under the lock; the verdict is signaled AFTER the lock
is released. The gate requires the cell's generation to equal the calling
wrapper's BIRTH generation — the generation its fn-ptr was resolved against —
never the crate's mutable current generation (a captured stale wrapper must
not accept a new generation's handle, and vice versa)."
  (let ((problem nil))
    (bt:with-lock-held ((cell-lock cell))
      (cond ((member (cell-state cell) '(:freed :free-pending))
             (setf problem :freed))
            ((/= (cell-session cell) *session*)
             (setf problem :stale))
            ((/= (cell-generation cell) birth-generation)
             (setf problem :stale))
            (t
             (incf (cell-in-flight cell)))))
    (ecase problem
      ((nil) nil)
      (:freed (error 'freed-handle-error :function-name fn-name))
      (:stale (error 'stale-handle-error
                     :function-name fn-name
                     :handle-generation (cell-generation cell)
                     :crate-generation birth-generation)))))

(defun cell-end-call (cell)
  "in-flight-- under the lock; performs the deferred free (outside the lock)
when this was the last in-flight call on a FREE-PENDING cell."
  (let (free-now ptr free-fn)
    (bt:with-lock-held ((cell-lock cell))
      (decf (cell-in-flight cell))
      (when (and (eq (cell-state cell) :free-pending)
                 (zerop (cell-in-flight cell)))
        (setf (cell-state cell) :freed
              free-now t
              ptr (cell-ptr cell)
              free-fn (cell-free-fn cell))))
    (when free-now
      (%maybe-foreign-free cell ptr free-fn))))

(defun %maybe-foreign-free (cell ptr free-fn)
  "Call the birth generation's free shim — unless the cell belongs to a dead
session (previous process image): then the pointer means nothing here and no
foreign call is made. A stale *generation* is fine: the old library mapping
is kept forever (no dlclose), so its own allocator frees its own Box."
  (when (= (cell-session cell) *session*)
    (%call-free free-fn ptr)))

(defun %cell-free (cell)
  "Free protocol. Returns T when this call caused (or scheduled) the free,
NIL when the cell was already freed or already scheduled — so repeated frees
are idempotent and report NIL."
  (let (do-free ptr free-fn (ret nil))
    (bt:with-lock-held ((cell-lock cell))
      (ecase (cell-state cell)
        ((:freed :free-pending) nil)
        (:live
         (setf ret t)
         (cond ((zerop (cell-in-flight cell))
                (setf (cell-state cell) :freed
                      do-free t
                      ptr (cell-ptr cell)
                      free-fn (cell-free-fn cell)))
               (t
                ;; calls in flight: defer; the last cell-end-call frees
                (setf (cell-state cell) :free-pending))))))
    (when do-free
      (%maybe-foreign-free cell ptr free-fn))
    ret))

(defun free (handle)
  "Explicitly release HANDLE's Rust object now (or as soon as in-flight calls
on it finish). Optional: the GC finalizer frees unreachable handles too.
Returns T if this call freed/scheduled the release, NIL if already freed."
  (check-type handle handle)
  (%cell-free (handle-cell handle)))

(defun make-handle-instance (class cell)
  "Wrap CELL in a fresh instance of CLASS and register the GC finalizer.
The finalizer captures the CELL only — capturing the wrapper would make it
immortal."
  (let ((h (make-instance class :cell cell)))
    (tg:finalize h (lambda () (%cell-free cell)))
    h))
