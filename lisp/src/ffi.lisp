(in-package #:rulisp)

;;; Low-level plumbing: raw dlopen/dlsym (per-library symbol resolution is
;;; mandatory — after a reload two generations export identical symbol names,
;;; so global-namespace dlsym would silently pick the old one), (ptr,len)
;;; UTF-8 marshaling, status decoding. DESIGN.md §4.

(defconstant +abi-version+ 1)

(defparameter *rulisp-version*
  #.(or (ignore-errors (asdf:component-version (asdf:find-system :rulisp)))
        "0.0.0")
  "This loader's release, read from rulisp.asd when this file is compiled
(so a program-op executable carries it without ASDF at runtime). Compared
with a crate's :rulisp-version for the skew warning (docs/stability.md §7).")

(defun %version-major-minor (string)
  "\"0.5.2\" -> (0 5); anything unparsable -> NIL."
  (ignore-errors
    (let* ((dot1 (position #\. string))
           (dot2 (and dot1 (position #\. string :start (1+ dot1)))))
      (list (parse-integer string :end dot1)
            (parse-integer string :start (1+ dot1) :end dot2)))))

;; uintptr_t / size_t is pointer-sized on every target: LP64 (Linux, macOS),
;; LLP64 (Windows — where `unsigned long` is only 32 bits, which is why
;; deriving this from the pointer size rather than naming a C type is the
;; only portable choice) and ILP32.
(cffi:defctype uintptr
    #.(if (= 8 (cffi:foreign-type-size :pointer)) :uint64 :uint32))

;;; Library loading. Symbols MUST be resolved against a specific library
;;; handle: after a reload two generations export identical names, and a
;;; global-namespace lookup would silently pick the older one.

#-(or windows win32)
(progn
  (cffi:defcfun ("dlopen" %dlopen) :pointer
    (path :string)
    (flags :int))
  (cffi:defcfun ("dlsym" %dlsym) :pointer
    (handle :pointer)
    (name :string))
  (cffi:defcfun ("dlerror" %dlerror) :pointer)

  (defconstant +rtld-now+ 2)

  (defun %open-library (native-path)
    (%dlerror)                          ; clear any stale error
    (%dlopen native-path +rtld-now+))

  (defun %library-error ()
    (let ((p (%dlerror)))
      (if (cffi:null-pointer-p p)
          "unknown dlerror"
          (cffi:foreign-string-to-lisp p))))

  (defun %find-symbol-in (handle name)
    (%dlsym handle name)))

#+(or windows win32)
(progn
  ;; The unique-copy loading policy (crate.lisp) matters twice as much
  ;; here: Windows locks a DLL while it is loaded, so overwriting the
  ;; artifact in place would fail outright.
  (cffi:defcfun ("LoadLibraryA" %load-library) :pointer
    (path :string))
  (cffi:defcfun ("GetProcAddress" %get-proc-address) :pointer
    (handle :pointer)
    (name :string))
  (cffi:defcfun ("GetLastError" %get-last-error) :unsigned-int)

  (defun %open-library (native-path)
    (%load-library native-path))

  (defun %library-error ()
    (format nil "LoadLibrary failed (GetLastError=~D)" (%get-last-error)))

  (defun %find-symbol-in (handle name)
    (%get-proc-address handle name)))

(defun dlopen* (path &key origin)
  "Load the shared library at PATH; signal with the OS error text on
failure. ORIGIN is the artifact PATH was copied from — the name the user
actually typed, so the error can say so. Never unloaded — see BOUNDARY.md
§9."
  (let ((h (%open-library (uiop:native-namestring path))))
    (when (cffi:null-pointer-p h)
      (error 'crate-not-loaded-error
             :name (namestring (or origin path))
             :message (format nil "~A~@[ (cache copy ~A)~]"
                              (%library-error) (and origin (namestring path)))))
    h))

(defun dlsym-ptr (lib-handle name)
  "Resolve NAME against LIB-HANDLE only. Returns NIL when absent."
  (let ((p (%find-symbol-in lib-handle name)))
    (if (cffi:null-pointer-p p) nil p)))

;;; ---------------------------------------------------------------------------
;;; Artifact naming. cargo emits lib<name>.so / lib<name>.dylib / <name>.dll —
;;; note Windows drops the "lib" prefix.
;;; ---------------------------------------------------------------------------

(defun shared-library-type ()
  (cond ((uiop:os-macosx-p) "dylib")
        ((uiop:os-windows-p) "dll")
        (t "so")))

(defun artifact-file-name (crate-name)
  (let ((base (substitute #\_ #\- crate-name)))
    (if (uiop:os-windows-p)
        (format nil "~A.dll" base)
        (format nil "lib~A.~A" base (shared-library-type)))))

;;; ---------------------------------------------------------------------------
;;; UTF-8 marshaling (DESIGN.md §4.5)
;;; ---------------------------------------------------------------------------

;;; Bulk transfer. Element-at-a-time CFFI loops cost ~7-10 ns per BYTE
;;; (measured, tests/bench.lisp) — a megabyte took milliseconds. Pinning a
;;; specialized Lisp vector and memcpy'ing is ~100x faster, and on the
;;; INBOUND side the pin lets Rust borrow the Lisp array directly: no copy
;;; at all. Pinning is dynamic-extent and Rust may not retain the pointer
;;; (BOUNDARY.md §4), so this stays inside the frozen contract.
;;;
;;; Not every implementation can pin every specialized array type, so the
;;; capability is probed once per element type and the element-wise path
;;; remains as the fallback.

(defvar *pinnable* (make-hash-table :test 'equal))

(defun pinnable-p (lisp-type)
  (multiple-value-bind (val found) (gethash lisp-type *pinnable*)
    (if found
        val
        (setf (gethash lisp-type *pinnable*)
              (handler-case
                  (let ((probe (make-array 1 :element-type lisp-type)))
                    (and (typep probe `(simple-array ,lisp-type (*)))
                         (cffi:with-pointer-to-vector-data (p probe)
                           (not (cffi:null-pointer-p p)))))
                (error () nil))))))

(defun pinned-vector-p (v lisp-type)
  (and (typep v `(simple-array ,lisp-type (*)))
       (pinnable-p lisp-type)))

(defun %memcpy (dst src nbytes)
  (cffi:foreign-funcall "memcpy" :pointer dst :pointer src uintptr nbytes :pointer))

#+ccl
(defun %call-with-copied-buffer (vector nbytes fn len)
  "CCL only. CFFI's with-pointer-to-vector-data is ccl:with-pointer-to-ivector
there, whose body runs under WITHOUT-GCING: a buffer pinned for the whole
export would stop every other thread's collections for the duration of
the call, callbacks included (measured: 0 collections in 600 ms; see
v05.pin-does-not-stop-the-world). So pin only for a memcpy into a heap
foreign buffer — not with-foreign-object, which is stack allocation on
CCL — and lend that copy to FN. Same contract for Rust (BOUNDARY §4: the
pointer is valid for the call and must not be retained)."
  (let ((buf (cffi:foreign-alloc :uint8 :count (max nbytes 1))))
    (unwind-protect
         (progn
           (when (plusp nbytes)
             (cffi:with-pointer-to-vector-data (src vector)
               (%memcpy buf src nbytes)))
           (funcall fn buf len))
      (cffi:foreign-free buf))))

(defun foreign-octets (ptr len)
  "Copy LEN bytes at PTR into a fresh (unsigned-byte 8) vector.
LEN = 0 never touches PTR (empty-transfer convention)."
  (let ((octets (make-array len :element-type '(unsigned-byte 8))))
    (when (plusp len)
      (if (pinned-vector-p octets '(unsigned-byte 8))
          (cffi:with-pointer-to-vector-data (dst octets)
            (%memcpy dst ptr len))
          (dotimes (i len)
            (setf (aref octets i) (cffi:mem-aref ptr :uint8 i)))))
    octets))

(defun %octets-to-ascii-string (octets)
  "OCTETS as a fresh string if every byte is ASCII, else NIL. v0.5: a typed
check-and-store loop is a fraction of a UTF-8 decode, and ASCII is the
common case (docs/benchmarks.md); the result is the same (simple-array
character) babel would return."
  (declare (type (simple-array (unsigned-byte 8) (*)) octets)
           (optimize speed))
  ;; peek before allocating: text that is non-ASCII from its first byte
  ;; (CJK, say) must not pay for a string it will not use
  (when (and (plusp (length octets)) (>= (aref octets 0) 128))
    (return-from %octets-to-ascii-string nil))
  (let* ((n (length octets))
         (s (make-string n :element-type 'character)))
    (declare (type (simple-array character (*)) s))
    (dotimes (i n s)
      (let ((b (aref octets i)))
        (if (< b 128)
            (setf (schar s i) (code-char b))
            (return nil))))))

(defun foreign-utf8 (ptr len)
  "Copy LEN bytes at PTR into a fresh Lisp string (UTF-8 decode). All-ASCII
input takes the typed loop; the first byte >= 128 hands the same octets
to babel."
  (if (zerop len)
      ""
      (let ((octets (foreign-octets ptr len)))
        (or (%octets-to-ascii-string octets)
            (babel:octets-to-string octets :encoding :utf-8)))))

(defun call-with-bytes-arg (data fn)
  "Lend DATA — an octet vector, or any sequence coercible to one — to FN as
(FN ptr len) for the dynamic extent of the call. A simple octet vector is
pinned and borrowed in place (no copy); anything else is coerced first."
  (let ((octets (if (typep data '(simple-array (unsigned-byte 8) (*)))
                    data
                    (handler-case
                        (coerce data '(simple-array (unsigned-byte 8) (*)))
                      (error ()
                        (error 'invalid-argument
                               :message (format nil "not an octet sequence: ~S"
                                                data)))))))
    (let ((len (length octets)))
      (cond
        ((zerop len)
         (cffi:with-foreign-object (buf :uint8 1)
           (funcall fn buf 0)))
        ((pinned-vector-p octets '(unsigned-byte 8))
         #-ccl (cffi:with-pointer-to-vector-data (ptr octets)
                 (funcall fn ptr len))
         #+ccl (%call-with-copied-buffer octets len fn len))
        (t
         (cffi:with-foreign-object (buf :uint8 len)
           (dotimes (i len)
             (setf (cffi:mem-aref buf :uint8 i) (aref octets i)))
           (funcall fn buf len)))))))

(defun %ascii-octets (string)
  "STRING's characters as a fresh octet vector if every one is ASCII, else
NIL (the UTF-8 encoding of an ASCII string is its char codes). Typed per
string representation so the loop compiles tight; a non-string falls
through to babel and its diagnostics."
  (declare (optimize speed))
  (unless (and (stringp string)
               ;; same peek as the decoder: no octet vector for text that
               ;; is non-ASCII from its first character
               (or (zerop (length string)) (< (char-code (char string 0)) 128)))
    (return-from %ascii-octets nil))
  (let* ((n (length string))
         (out (make-array n :element-type '(unsigned-byte 8))))
    (macrolet ((scan (stype accessor)
                 `(let ((s string))
                    (declare (type ,stype s))
                    (dotimes (i n out)
                      (let ((c (char-code (,accessor s i))))
                        (if (< c 128)
                            (setf (aref out i) c)
                            (return nil)))))))
      (typecase string
        ((simple-array character (*)) (scan (simple-array character (*)) schar))
        (simple-base-string (scan simple-base-string schar))
        (string (scan string char))
        (t nil)))))

(defun call-with-utf8-arg (string fn)
  "Encode STRING as UTF-8 into foreign memory borrowed for the duration of
FN, called as (FN ptr len). No NUL terminator; interior NULs are legal.
All-ASCII strings skip babel (v0.5); the copy contract is unchanged."
  (call-with-bytes-arg (or (%ascii-octets string)
                           (babel:string-to-octets string :encoding :utf-8))
                       fn))

(defun call-with-optional-utf8-arg (s fn)
  "(:option :string) parameter: NIL → (FN 0 null 0), else (FN 1 ptr len)."
  (if (null s)
      (funcall fn 0 (cffi:null-pointer) 0)
      (call-with-utf8-arg s (lambda (p l) (funcall fn 1 p l)))))

(defun call-with-optional-bytes-arg (s fn)
  "(:option :bytes) parameter: NIL → (FN 0 null 0), else (FN 1 ptr len)."
  (if (null s)
      (funcall fn 0 (cffi:null-pointer) 0)
      (call-with-bytes-arg s (lambda (p l) (funcall fn 1 p l)))))

(defun call-with-vec-arg (data cffi-type lisp-type coercer fn)
  "(:vec ...) parameter: lend DATA (a sequence of numbers) to FN as
(FN ptr len-in-elements). A matching simple specialized vector is pinned
and borrowed in place; anything else is copied into a foreign array."
  (let ((len (length data)))
    (cond
      ((and (plusp len) (pinned-vector-p data lisp-type))
       #-ccl (cffi:with-pointer-to-vector-data (ptr data)
               (funcall fn ptr len))
       #+ccl (%call-with-copied-buffer
              data (* len (cffi:foreign-type-size cffi-type)) fn len))
      (t
       (cffi:with-foreign-object (buf cffi-type (max len 1))
         (handler-case
             (let ((i 0))
               (map nil (lambda (x)
                          (setf (cffi:mem-aref buf cffi-type i) (funcall coercer x))
                          (incf i))
                    data))
           (error (e)
             (error 'invalid-argument
                    :message (format nil "bad vector element: ~A" e))))
         (funcall fn buf len))))))

;;; ---------------------------------------------------------------------------
;;; last-error / dealloc / free calls through resolved pointers
;;; ---------------------------------------------------------------------------

(defun read-crate-last-error (last-error-ptr)
  "Returns (values type-string message-string), copied immediately: the
foreign strings are borrowed only until the next call into the library on
this thread."
  (cffi:with-foreign-objects ((tp :pointer) (tl 'uintptr)
                              (mp :pointer) (ml 'uintptr))
    (cffi:foreign-funcall-pointer last-error-ptr ()
                                  :pointer tp :pointer tl
                                  :pointer mp :pointer ml
                                  :void)
    (values (foreign-utf8 (cffi:mem-ref tp :pointer) (cffi:mem-ref tl 'uintptr))
            (foreign-utf8 (cffi:mem-ref mp :pointer) (cffi:mem-ref ml 'uintptr)))))

(defun call-dealloc-layout (dealloc-ptr ptr size align)
  "Release a Rust-owned allocation of SIZE bytes / ALIGN alignment via the
owning library's universal deallocator. SIZE = 0 transferred no allocation
and is a no-op."
  (when (plusp size)
    (cffi:foreign-funcall-pointer dealloc-ptr ()
                                  :pointer ptr uintptr size uintptr align
                                  :void)))

(defun call-dealloc (dealloc-ptr ptr len)
  "Byte-buffer/string variant of CALL-DEALLOC-LAYOUT (align 1)."
  (call-dealloc-layout dealloc-ptr ptr len 1))

(defun %call-free (free-ptr obj-ptr)
  (cffi:foreign-funcall-pointer free-ptr () :pointer obj-ptr :void))
