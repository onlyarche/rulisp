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
(defun option-type-p (ty) (and (consp ty) (eq (car ty) :option)))

(defun option-inner (ty)
  "Inner type of (:option X), rejecting :bool: Lisp nil cannot distinguish
None from Some(false). The macro refuses to emit it; a hand-written
manifest must be refused here for the same reason."
  (let ((inner (second ty)))
    (when (eq inner :bool)
      (error 'manifest-error
             :message "(:option :bool) is not in the type vocabulary — nil is ambiguous between None and false; use (:option :i8)"))
    inner))
(defun vec-type-p (ty) (and (consp ty) (eq (car ty) :vec)))

(defparameter +vec-elt-types+
  ;; element token → (cffi-type byte-size lisp-element-type coercer-form)
  '((:i8 :int8 1 (signed-byte 8) #'identity)
    (:i16 :int16 2 (signed-byte 16) #'identity)
    (:i32 :int32 4 (signed-byte 32) #'identity)
    (:i64 :int64 8 (signed-byte 64) #'identity)
    (:u8 :uint8 1 (unsigned-byte 8) #'identity)
    (:u16 :uint16 2 (unsigned-byte 16) #'identity)
    (:u32 :uint32 4 (unsigned-byte 32) #'identity)
    (:u64 :uint64 8 (unsigned-byte 64) #'identity)
    (:f32 :float 4 single-float (lambda (x) (coerce x 'single-float)))
    (:f64 :double 8 double-float (lambda (x) (coerce x 'double-float)))))

(defun vec-elt-info (tok)
  "Returns (values cffi-type byte-size lisp-element-type coercer-form)."
  (let ((entry (assoc tok +vec-elt-types+)))
    (unless entry
      (error 'manifest-error
             :message (format nil "unsupported (:vec ~S) element type" tok)))
    (values (second entry) (third entry) (fourth entry) (fifth entry))))

;;; ---------------------------------------------------------------------------
;;; Callback trampolines: one cffi:defcallback per signature shape, shared
;;; across crates (they read *live-callback* dynamically). Only created under
;;; the registry lock (load paths), so the table needs no lock of its own.
;;; ---------------------------------------------------------------------------

(defvar *trampolines* (make-hash-table :test 'equal))

(defun %define-callback-trampoline (form)
  "Define a trampoline callback. EVAL suffices everywhere except ECL: a
bytecodes-compiled defcallback there rides si:make-dynamic-callback, whose
internal metadata the Boehm GC can collect out from under libffi (verified
upstream bug: the closure userdata lives in non-GC-scanned memory and the
:callback sysprop retains only the closure object) — the callback then
reads recycled memory after any GC. Natively compiling the form emits a
static C function instead: no libffi, no hazard."
  #-ecl (eval form)
  #+ecl
  (uiop:with-temporary-file (:pathname src :type "lisp")
    (with-open-file (out src :direction :output :if-exists :supersede)
      (let ((*package* (find-package '#:rulisp)))
        (format out "(in-package #:rulisp)~%~S~%" form)))
    (handler-case
        (multiple-value-bind (fasl warnings failure)
            ;; a deployed program must not print compiler chatter every
            ;; time it loads a crate with callbacks
            (let ((*compile-verbose* nil) (*compile-print* nil))
              (compile-file src))
          (declare (ignore warnings))
          (when (or failure (null fasl))
            (error "compile-file reported failure"))
          (let ((*load-verbose* nil)) (load fasl))
          (ignore-errors (delete-file fasl)))
      (error (e)
        (error 'manifest-error
               :message (format nil "callbacks on ECL require the native ~
                                     compiler (compile-file failed: ~A)" e))))))

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
       ;; ECL's defcallback drops declarations, so an unused-variable style
       ;; warning would print on every trampoline compile — the bare
       ;; reference is what silences it there; the declaration keeps
       ;; SBCL/CCL from noting the same thing about the reference
       (declare (ignorable %userdata))
       %userdata
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
            (%define-callback-trampoline (trampoline-form name params))
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
            (%define-callback-trampoline (stored-trampoline-form name params))
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
    ((option-type-p result)
     (let ((inner (option-inner result))
           (some (gensym "SOME")))
       (cond
         ((member inner '(:string :bytes))
          (let ((op (gensym "OUTP")) (ol (gensym "OUTL"))
                (taker (if (eq inner :string) '%take-string-result '%take-bytes-result)))
            (values (lambda (body)
                      `(cffi:with-foreign-objects
                           ((,some :uint8) (,op :pointer) (,ol 'uintptr))
                         ,body))
                    `(:pointer ,some :pointer ,op :pointer ,ol)
                    `(when (plusp (cffi:mem-ref ,some :uint8))
                       (,taker %ctx (cffi:mem-ref ,op :pointer)
                               (cffi:mem-ref ,ol 'uintptr))))))
         (t
          (let ((o (gensym "OUT")) (cty (scalar-cffi inner)))
            (values (lambda (body)
                      `(cffi:with-foreign-objects ((,some :uint8) (,o ,cty)) ,body))
                    `(:pointer ,some :pointer ,o)
                    `(when (plusp (cffi:mem-ref ,some :uint8))
                       (cffi:mem-ref ,o ,cty))))))))
    ((vec-type-p result)
     (multiple-value-bind (cty size lisp-ty coercer) (vec-elt-info (second result))
       (declare (ignore coercer))
       (let ((op (gensym "OUTP")) (ol (gensym "OUTL")))
         (values (lambda (body)
                   `(cffi:with-foreign-objects ((,op :pointer) (,ol 'uintptr)) ,body))
                 `(:pointer ,op :pointer ,ol)
                 `(%take-vec-result %ctx (cffi:mem-ref ,op :pointer)
                                    (cffi:mem-ref ,ol 'uintptr)
                                    ,cty ,size ',lisp-ty)))))
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

(defun %take-vec-result (ctx ptr len cffi-type elt-size lisp-type)
  "Copy a Rust-owned Vec<scalar> (LEN elements) into a specialized Lisp
vector, then release via dealloc(ptr, len*size, align=size). Bulk-copies
into a pinned vector where the host supports it."
  (unwind-protect
       (let ((v (make-array len :element-type lisp-type)))
         (when (plusp len)
           (if (pinned-vector-p v lisp-type)
               (cffi:with-pointer-to-vector-data (dst v)
                 (%memcpy dst ptr (* len elt-size)))
               (dotimes (i len)
                 (setf (aref v i) (cffi:mem-aref ptr cffi-type i)))))
         v)
    (call-dealloc-layout (gen-ctx-dealloc-ptr ctx) ptr
                         (* len elt-size) elt-size)))

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

;;; ---------------------------------------------------------------------------
;;; Docstrings (0.5). Every generated function and handle class gets one,
;;; synthesized from the manifest — the signature, the Rust name, the
;;; condition an Err becomes — with the crate's own `///` text (manifest
;;; :doc) first when it carries one. Zero wire cost for the synthesized
;;; part; :doc is an enhancement key (BOUNDARY §11).
;;; ---------------------------------------------------------------------------

(defun %doc-type (ty pkg)
  "Render a manifest type token the way a Lisp reader sees it."
  (cond ((handle-type-p ty)
         (format nil "~(~A~):~(~A~)" (package-name pkg)
                 (let ((h (second ty))) (camel-to-kebab-name h))))
        ((option-type-p ty) (format nil "(:option ~A)" (%doc-type (second ty) pkg)))
        ((vec-type-p ty) (format nil "(:vec ~(~A~))" (second ty)))
        ((callback-type-p ty)
         (format nil "(:callback ~{~A~^ ~})" (mapcar (lambda (x) (%doc-type x pkg))
                                                     (getf (cdr ty) :params))))
        ((stored-callback-type-p ty)
         (format nil "(:stored-callback ~{~A~^ ~})"
                 (mapcar (lambda (x) (%doc-type x pkg)) (getf (cdr ty) :params))))
        (t (format nil "~(~S~)" ty))))

(defun camel-to-kebab-name (rust-name)
  "\"WordBag\" -> \"word-bag\" (handle class naming, mirrors the macro)."
  (string-downcase (camel-to-kebab rust-name)))

(defun %call-shape (fspec pkg)
  "The Lisp call shape, e.g. \"(rx:make-regex pattern)\": the first
synthesized line of the docstring, and what DESCRIBE lists per export
(the ///-paragraph, when there is one, leads the docstring, not this)."
  (format nil "(~A:~A~{ ~A~})"
          (string-downcase (package-name pkg))
          (string-downcase (fn-spec-lisp-name fspec))
          (mapcar (lambda (p) (string-downcase (param-name p))) (fn-spec-params fspec))))

(defun synthesize-fn-doc (fspec pkg)
  (let* ((pkg-name (string-downcase (package-name pkg)))
         (params (fn-spec-params fspec))
         (err (fn-spec-error fspec))
         (lines
           (list (%call-shape fspec pkg)
                 (format nil "Rust: ~A(~{~A~^, ~}) -> ~A~@[, Err(~A)~]"
                         (fn-spec-rust-name fspec)
                         (mapcar (lambda (p) (format nil "~(~A~): ~A" (param-name p)
                                                     (%doc-type (param-type p) pkg)))
                                 params)
                         (%doc-type (fn-spec-result fspec) pkg)
                         err)
                 ;; a type NAMED Error (rulisp::Error, regex::Error, ...) has no
                 ;; class of its own: the manifest's :errors excludes it and the
                 ;; condition is rulisp:rust-error itself — <crate>:rust-error
                 ;; is not a symbol (the v0.5 docs audit caught the docstring
                 ;; naming one)
                 (cond ((null err)
                        "Signals: rulisp:rust-panic on a Rust panic; never a Rust error.")
                       ((string= err "Error")
                        "Signals: rulisp:rust-error on Err.")
                       (t (format nil "Signals: ~A:~(~A~) (a rulisp:rust-error) on Err."
                                  pkg-name (camel-to-kebab err)))))))
    (format nil "~@[~A~%~%~]~{~A~^~%~}" (fn-spec-doc fspec) lines)))

(defun synthesize-handle-doc (hspec pkg)
  (format nil "~@[~A~%~%~]Handle class for the Rust type ~A of crate ~S: an opaque ~
               object owned by Rust, released by rulisp:free or by the GC. ~
               A handle from a previous generation or image session signals ~
               rulisp:stale-handle-error; a freed one, rulisp:freed-handle-error."
          (handle-spec-doc hspec) (handle-spec-rust-name hspec)
          (string-downcase (package-name pkg))))

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
               ((option-type-p ty)
                (let ((inner-ty (option-inner ty)))
                  (cond
                    ((member inner-ty '(:string :bytes))
                     (let ((pres (gensym "PRES")) (ptr (gensym "PTR")) (len (gensym "LEN"))
                           (helper (if (eq inner-ty :string)
                                       'call-with-optional-utf8-arg
                                       'call-with-optional-bytes-arg)))
                       (push (let ((s sym) (h helper) (bp pres) (bq ptr) (bl len))
                               (lambda (inner)
                                 `(,h ,s (lambda (,bp ,bq ,bl) ,inner))))
                             wrappers)
                       (setf call-args
                             (append call-args
                                     `(:uint8 ,pres :pointer ,ptr uintptr ,len)))))
                    (t                  ; optional scalar: nil = None
                     (setf call-args
                           (append call-args
                                   (list :uint8 `(if (null ,sym) 0 1)
                                         (scalar-cffi inner-ty) `(if (null ,sym) 0 ,sym))))))))
               ((vec-type-p ty)
                (multiple-value-bind (cty size lisp-ty coercer) (vec-elt-info (second ty))
                  (declare (ignore size))
                  (let ((ptr (gensym "PTR")) (len (gensym "LEN")))
                    (push (let ((s sym) (bp ptr) (bl len))
                            (lambda (inner)
                              `(call-with-vec-arg ,s ,cty ',lisp-ty ,coercer
                                                  (lambda (,bp ,bl) ,inner))))
                          wrappers)
                    (setf call-args (append call-args `(:pointer ,ptr uintptr ,len))))))
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
