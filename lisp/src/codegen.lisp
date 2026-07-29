(in-package #:rulisp)

;;; Manifest → compiled wrapper closures (DESIGN.md §6.1: load-time function,
;;; no compile-time macro — bindings are derived, by construction, from the
;;; library that was just dlopened).
;;;
;;; Every wrapper closes over an immutable per-generation context (GEN-CTX)
;;; snapshotted when the generation was committed. A wrapper NEVER reads the
;;; mutable crate slots on the call path: its fn-ptr, last-error, dealloc and
;;; free pointers all belong to one generation, so a concurrent reload can
;;; never mix generations inside a single call (confirmed-UB otherwise).

(defstruct (gen-ctx (:constructor %make-gen-ctx
                        (generation session last-error-ptr dealloc-ptr free-table
                         error-conditions)))
  generation                 ; the generation this wrapper/ctx was born in
  session                    ; *session* at birth; gates dead-image closures
  last-error-ptr
  dealloc-ptr
  free-table                 ; alist rust-name → birth generation's free shim
  error-conditions)          ; alist rust error type string → condition class symbol

(defvar *live-callback* nil
  "Bound around a foreign call that passes a callback: the trampoline reads
the live Lisp closure from here. Dynamic binding handles nesting; the v1
contract (same thread, within the call) makes it sound.")

(defvar *callback-stash* nil
  "Bound to NIL around a callback-passing foreign call; the trampoline stores
a signaled condition here (status 1 to Rust). On STATUS_CB_ERR the wrapper
re-signals the very same object; the binding's scope ending is the clear-on-
every-other-status discipline.")

(defparameter +scalar-types+
  '((:bool . :uint8)
    (:i8 . :int8) (:i16 . :int16) (:i32 . :int32) (:i64 . :int64)
    (:u8 . :uint8) (:u16 . :uint16) (:u32 . :uint32) (:u64 . :uint64)
    (:f32 . :float) (:f64 . :double)))

(defun scalar-cffi (ty)
  (or (cdr (assoc ty +scalar-types+))
      (error 'manifest-error :message (format nil "unsupported type ~S" ty))))

(defun handle-type-p (ty) (and (consp ty) (eq (car ty) :handle)))
(defun callback-type-p (ty) (and (consp ty) (eq (car ty) :callback)))
(defun stored-callback-type-p (ty) (and (consp ty) (eq (car ty) :stored-callback)))

;;; ---------------------------------------------------------------------------
;;; Callback trampolines: one cffi:defcallback per signature shape, shared
;;; across crates (they read *live-callback* dynamically). Only created under
;;; the registry lock (load paths), so the table needs no lock of its own.
;;; ---------------------------------------------------------------------------

(defvar *trampolines* (make-hash-table :test 'equal))

(defun trampoline-form (name param-types)
  (let ((specs (loop for ty in param-types
                     for i from 0
                     collect (list ty
                                   (intern (format nil "%P~D" i) '#:rulisp)
                                   (intern (format nil "%L~D" i) '#:rulisp)))))
    `(cffi:defcallback ,name :int32
         ((%userdata :uint64)
          ,@(loop for (ty p l) in specs
                  append (cond ((eq ty :string) `((,p :pointer) (,l uintptr)))
                               (t `((,p ,(scalar-cffi ty)))))))
       (declare (ignore %userdata))
       (let ((%done nil))
         (unwind-protect
              (handler-case
                  (progn
                    (funcall *live-callback*
                             ,@(loop for (ty p l) in specs
                                     collect (cond ((eq ty :string) `(foreign-utf8 ,p ,l))
                                                   ((eq ty :bool) `(plusp ,p))
                                                   (t p))))
                    (setf %done t)
                    0)
                ;; serious-condition, not just error: storage-condition and
                ;; friends must not unwind Lisp-style through Rust frames.
                (serious-condition (%c)
                  (setf *callback-stash* %c
                        %done t)
                  1))
           (unless %done
             ;; throw / return-from / restart transfer is about to unwind
             ;; through live Rust frames: documented UB (DESIGN.md §4.7-4).
             ;; Best-effort detection — we can warn, not prevent.
             (warn "rulisp: non-local exit is unwinding through Rust frames ~
                    — this is documented UB (DESIGN.md §4.7)")))))))

(defun %check-callback-shape (cb-type)
  (destructuring-bind (&key params result) (cdr cb-type)
    (unless (eq result :unit)
      (error 'manifest-error :message "callbacks must have :result :unit"))
    (dolist (p params)
      (unless (or (eq p :string) (assoc p +scalar-types+))
        (error 'manifest-error
               :message (format nil "unsupported callback param type ~S" p))))
    (values params result)))

(defun ensure-trampoline (cb-type)
  "CB-TYPE: (:callback :params (...) :result :unit). Returns the trampoline
callback name, defining it on first use for this signature shape."
  (multiple-value-bind (params result) (%check-callback-shape cb-type)
    (let ((key (list :borrowed params result)))
      (or (gethash key *trampolines*)
          (let ((name (intern (format nil "%TRAMPOLINE-~D" (hash-table-count *trampolines*))
                              '#:rulisp)))
            (eval (trampoline-form name params))
            (setf (gethash key *trampolines*) name))))))

(defun stored-trampoline-form (name param-types)
  "Trampoline for STORED callbacks: the leading uint64 is the registry id,
and there may be no rulisp call frame on this thread to re-signal into —
conditions are warned and reported as status 1; a dead id is status 2."
  (let ((specs (loop for ty in param-types
                     for i from 0
                     collect (list ty
                                   (intern (format nil "%P~D" i) '#:rulisp)
                                   (intern (format nil "%L~D" i) '#:rulisp)))))
    `(cffi:defcallback ,name :int32
         ((%id :uint64)
          ,@(loop for (ty p l) in specs
                  append (cond ((eq ty :string) `((,p :pointer) (,l uintptr)))
                               (t `((,p ,(scalar-cffi ty)))))))
       (let ((%done nil))
         (unwind-protect
              (handler-case
                  (let ((%fn (%stored-callback-lookup %id)))
                    (cond
                      ((null %fn)
                       (warn "rulisp: stored callback ~D is no longer registered ~
                              (token unregistered or garbage-collected)" %id)
                       (setf %done t)
                       2)
                      (t
                       (funcall %fn
                                ,@(loop for (ty p l) in specs
                                        collect (cond ((eq ty :string) `(foreign-utf8 ,p ,l))
                                                      ((eq ty :bool) `(plusp ,p))
                                                      (t p))))
                       (setf %done t)
                       0)))
                (serious-condition (%c)
                  (warn "rulisp: condition in stored callback ~D: ~A" %id %c)
                  (setf %done t)
                  1))
           (unless %done
             (warn "rulisp: non-local exit is unwinding through Rust frames ~
                    — this is documented UB (BOUNDARY.md §6)")))))))

(defun ensure-stored-trampoline (cb-type)
  (multiple-value-bind (params result) (%check-callback-shape cb-type)
    (let ((key (list :stored params result)))
      (or (gethash key *trampolines*)
          (let ((name (intern (format nil "%STORED-TRAMPOLINE-~D"
                                      (hash-table-count *trampolines*))
                              '#:rulisp)))
            (eval (stored-trampoline-form name params))
            (setf (gethash key *trampolines*) name))))))

;;; ---------------------------------------------------------------------------
;;; Result plumbing: out-params + success form per result type
;;; ---------------------------------------------------------------------------

(defun result-plumbing (result class-name-for)
  "Returns (values body-wrapper out-arg-forms ok-form) for RESULT."
  (cond
    ((eq result :unit)
     (values #'identity '() '(values)))
    ((eq result :string)
     (let ((op (gensym "OUTP")) (ol (gensym "OUTL")))
       (values (lambda (body)
                 `(cffi:with-foreign-objects ((,op :pointer) (,ol 'uintptr)) ,body))
               `(:pointer ,op :pointer ,ol)
               `(%take-string-result %ctx (cffi:mem-ref ,op :pointer)
                                     (cffi:mem-ref ,ol 'uintptr)))))
    ((eq result :bytes)
     (let ((op (gensym "OUTP")) (ol (gensym "OUTL")))
       (values (lambda (body)
                 `(cffi:with-foreign-objects ((,op :pointer) (,ol 'uintptr)) ,body))
               `(:pointer ,op :pointer ,ol)
               `(%take-bytes-result %ctx (cffi:mem-ref ,op :pointer)
                                    (cffi:mem-ref ,ol 'uintptr)))))
    ((handle-type-p result)
     (let ((oh (gensym "OUTH"))
           (class (funcall class-name-for (second result)))
           (rust (second result)))
       (values (lambda (body) `(cffi:with-foreign-object (,oh :pointer) ,body))
               `(:pointer ,oh)
               `(%make-crate-handle %crate %ctx ',class ,rust
                                    (cffi:mem-ref ,oh :pointer)))))
    ((eq result :bool)
     (let ((o (gensym "OUT")))
       (values (lambda (body) `(cffi:with-foreign-object (,o :uint8) ,body))
               `(:pointer ,o)
               `(plusp (cffi:mem-ref ,o :uint8)))))
    (t
     (let ((o (gensym "OUT")) (cty (scalar-cffi result)))
       (values (lambda (body) `(cffi:with-foreign-object (,o ,cty) ,body))
               `(:pointer ,o)
               `(cffi:mem-ref ,o ,cty))))))

(defun %take-string-result (ctx ptr len)
  "Copy a Rust-owned string then release it exactly once via the ALLOCATING
generation's dealloc (unwind-protect: released even if decoding signals)."
  (unwind-protect
       (foreign-utf8 ptr len)
    (call-dealloc (gen-ctx-dealloc-ptr ctx) ptr len)))

(defun %take-bytes-result (ctx ptr len)
  "Copy a Rust-owned byte buffer then release it exactly once via the
ALLOCATING generation's dealloc."
  (unwind-protect
       (foreign-octets ptr len)
    (call-dealloc (gen-ctx-dealloc-ptr ctx) ptr len)))

(defun %make-crate-handle (crate ctx class rust-name ptr)
  "Stamp the new cell with the wrapper's BIRTH generation and the birth
generation's free shim — never the crate's current slots, which a concurrent
reload may have moved to a different generation than the one that allocated
PTR."
  (let ((free-ptr (or (cdr (assoc rust-name (gen-ctx-free-table ctx) :test #'string=))
                      (error 'manifest-error
                             :message (format nil "no free shim recorded for handle ~S" rust-name)))))
    (make-handle-instance
     class
     (%make-cell ptr (gen-ctx-generation ctx) (gen-ctx-session ctx) free-ptr crate))))

;;; ---------------------------------------------------------------------------
;;; Wrapper generation
;;; ---------------------------------------------------------------------------

(defun wrapper-form (fspec class-name-for qualified)
  "Builds (lambda (%crate %ctx %fn-ptr) (lambda (args...) ...)) implementing
FSPEC against one immutable generation context."
  (let* ((params (fn-spec-params fspec))
         (result (fn-spec-result fspec))
         (arg-syms (loop for p in params
                         collect (make-symbol (string-upcase (param-name p)))))
         (call-args '())                ; flat (cffi-type form ...) in order
         (wrappers '())                 ; body transformers, innermost pushed last
         (n-callbacks 0))
    (loop for p in params
          for sym in arg-syms
          for ty = (param-type p)
          do (cond
               ((eq ty :string)
                (let ((ptr (gensym "PTR")) (len (gensym "LEN")))
                  (push (let ((s sym) (bp ptr) (bl len))
                          (lambda (inner)
                            `(call-with-utf8-arg ,s (lambda (,bp ,bl) ,inner))))
                        wrappers)
                  (setf call-args (append call-args `(:pointer ,ptr uintptr ,len)))))
               ((eq ty :bytes)
                (let ((ptr (gensym "PTR")) (len (gensym "LEN")))
                  (push (let ((s sym) (bp ptr) (bl len))
                          (lambda (inner)
                            `(call-with-bytes-arg ,s (lambda (,bp ,bl) ,inner))))
                        wrappers)
                  (setf call-args (append call-args `(:pointer ,ptr uintptr ,len)))))
               ((handle-type-p ty)
                (let ((cell (gensym "CELL"))
                      (class (funcall class-name-for (second ty))))
                  (push (let ((s sym) (c cell) (cls class))
                          (lambda (inner)
                            `(let ((,c (progn
                                         (unless (typep ,s ',cls)
                                           (error 'invalid-argument
                                                  :message (format nil "expected a ~S" ',cls)
                                                  :function-name ,qualified))
                                         (handle-cell ,s))))
                               ;; The gate: the cell must belong to THIS
                               ;; wrapper's birth generation — the generation
                               ;; %fn-ptr was resolved against.
                               (cell-begin-call ,c (gen-ctx-generation %ctx) ,qualified)
                               (unwind-protect ,inner
                                 (cell-end-call ,c)))))
                        wrappers)
                  (setf call-args (append call-args `(:pointer (cell-ptr ,cell))))))
               ((callback-type-p ty)
                (incf n-callbacks)
                (let ((tramp (ensure-trampoline ty)))
                  (push (let ((s sym))
                          (lambda (inner)
                            `(let ((*live-callback* ,s)
                                   (*callback-stash* nil))
                               ,inner)))
                        wrappers)
                  (setf call-args
                        (append call-args
                                `(:pointer (cffi:callback ,tramp) :uint64 0)))))
               ((stored-callback-type-p ty)
                (let ((tramp (ensure-stored-trampoline ty)))
                  (push (let ((s sym))
                          (lambda (inner)
                            `(progn
                               (unless (typep ,s 'callback-token)
                                 (error 'invalid-argument
                                        :message "expected a callback token (rulisp:callback fn)"
                                        :function-name ,qualified))
                               ,inner)))
                        wrappers)
                  (setf call-args
                        (append call-args
                                `(:pointer (cffi:callback ,tramp)
                                  :uint64 (callback-token-id ,sym))))))
               (t
                (setf call-args
                      (append call-args
                              (list (scalar-cffi ty)
                                    (if (eq ty :bool) `(if ,sym 1 0) sym)))))))
    (when (> n-callbacks 1)
      (error 'manifest-error
             :message (format nil "~A: at most one callback parameter (v1)" qualified)))
    (multiple-value-bind (out-wrap out-args ok-form)
        (result-plumbing result class-name-for)
      (let* ((call `(cffi:foreign-funcall-pointer %fn-ptr ()
                                                  ,@call-args ,@out-args :int32))
             (body `(let ((%status ,call))
                      (if (zerop %status)
                          ,ok-form
                          (restart-case
                              (signal-crate-status %status %ctx ,qualified
                                                   ,(if (plusp n-callbacks)
                                                        '*callback-stash*
                                                        nil))
                            (use-value (%v)
                              :report "Return a value from the call instead."
                              :interactive (lambda ()
                                             (format *query-io* "~&Value to return: ")
                                             (finish-output *query-io*)
                                             (list (read *query-io*)))
                              %v)))))
             (body (funcall out-wrap body))
             (body (reduce (lambda (inner w) (funcall w inner))
                           wrappers :initial-value body)))
        `(lambda (%crate %ctx %fn-ptr)
           (declare (ignorable %crate))
           (lambda ,arg-syms
             ;; Session gate: a wrapper closure captured before an image dump
             ;; holds foreign pointers of a dead process — refuse, never jump.
             (unless (= (gen-ctx-session %ctx) *session*)
               (error 'crate-not-loaded-error
                      :name (crate-name %crate)
                      :message "this wrapper function object belongs to a previous image session; call the current symbol-function instead"))
             ,body))))))

(defun signal-crate-status (status ctx fn-name stash)
  (case status
    (1 (multiple-value-bind (type msg)
           (read-crate-last-error (gen-ctx-last-error-ptr ctx))
         ;; typed conditions: a rust error type listed in the manifest's
         ;; :errors signals its generated condition class (subclass of
         ;; rust-error), so handlers can discriminate without string checks
         (let ((class (or (cdr (assoc type (gen-ctx-error-conditions ctx)
                                      :test #'string=))
                          'rust-error)))
           (error class :rust-type type :message msg :function-name fn-name))))
    (2 (multiple-value-bind (type msg)
           (read-crate-last-error (gen-ctx-last-error-ptr ctx))
         (declare (ignore type))
         (error 'rust-panic :message msg :function-name fn-name)))
    (3 (multiple-value-bind (type msg)
           (read-crate-last-error (gen-ctx-last-error-ptr ctx))
         (error 'invalid-argument
                :message (format nil "~A: ~A" type msg)
                :function-name fn-name)))
    (4 (if stash
           (error stash)                ; re-signal the SAME condition object
           (error 'rust-error :rust-type "CallbackError"
                              :message "callback error status without a stashed condition"
                              :function-name fn-name)))
    (t (error 'rust-error :rust-type "UnknownStatus"
                          :message (format nil "unknown status code ~D" status)
                          :function-name fn-name))))
