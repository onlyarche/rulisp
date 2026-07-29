(in-package #:rulisp)

;;; Low-level plumbing: raw dlopen/dlsym (per-library symbol resolution is
;;; mandatory — after a reload two generations export identical symbol names,
;;; so global-namespace dlsym would silently pick the old one), (ptr,len)
;;; UTF-8 marshaling, status decoding. DESIGN.md §4.

(defconstant +abi-version+ 1)

;; v1 targets 64-bit Linux/macOS (LP64): uintptr_t == unsigned long.
(cffi:defctype uintptr :unsigned-long)

(cffi:defcfun ("dlopen" %dlopen) :pointer
  (path :string)
  (flags :int))

(cffi:defcfun ("dlsym" %dlsym) :pointer
  (handle :pointer)
  (name :string))

(cffi:defcfun ("dlerror" %dlerror) :pointer)

(defconstant +rtld-now+ 2)

(defun %dlerror-string ()
  (let ((p (%dlerror)))
    (if (cffi:null-pointer-p p)
        "unknown dlerror"
        (cffi:foreign-string-to-lisp p))))

(defun dlopen* (path)
  "dlopen PATH with RTLD_NOW | RTLD_LOCAL; error with dlerror text on failure."
  (%dlerror)                            ; clear any stale error
  (let ((h (%dlopen (uiop:native-namestring path) +rtld-now+)))
    (when (cffi:null-pointer-p h)
      (error 'crate-not-loaded-error
             :name (namestring path)
             :message (%dlerror-string)))
    h))

(defun dlsym-ptr (lib-handle name)
  "Resolve NAME against LIB-HANDLE only. Returns NIL when absent."
  (let ((p (%dlsym lib-handle name)))
    (if (cffi:null-pointer-p p) nil p)))

;;; ---------------------------------------------------------------------------
;;; UTF-8 marshaling (DESIGN.md §4.5)
;;; ---------------------------------------------------------------------------

(defun foreign-octets (ptr len)
  "Copy LEN bytes at PTR into a fresh (unsigned-byte 8) vector.
LEN = 0 never touches PTR (empty-transfer convention)."
  (let ((octets (make-array len :element-type '(unsigned-byte 8))))
    (dotimes (i len)
      (setf (aref octets i) (cffi:mem-aref ptr :uint8 i)))
    octets))

(defun foreign-utf8 (ptr len)
  "Copy LEN bytes at PTR into a fresh Lisp string (UTF-8 decode)."
  (if (zerop len)
      ""
      (babel:octets-to-string (foreign-octets ptr len) :encoding :utf-8)))

(defun call-with-bytes-arg (data fn)
  "Copy DATA — an octet vector, or any sequence coercible to one — into
foreign memory borrowed for the duration of FN, called as (FN ptr len)."
  (let* ((octets (if (typep data '(vector (unsigned-byte 8)))
                     data
                     (handler-case
                         (coerce data '(simple-array (unsigned-byte 8) (*)))
                       (error ()
                         (error 'invalid-argument
                                :message (format nil "not an octet sequence: ~S"
                                                 data))))))
         (len (length octets)))
    (cffi:with-foreign-object (buf :uint8 (max len 1))
      (dotimes (i len)
        (setf (cffi:mem-aref buf :uint8 i) (aref octets i)))
      (funcall fn buf len))))

(defun call-with-utf8-arg (string fn)
  "Encode STRING as UTF-8 into foreign memory borrowed for the duration of
FN, called as (FN ptr len). No NUL terminator; interior NULs are legal."
  (call-with-bytes-arg (babel:string-to-octets string :encoding :utf-8) fn))

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

(defun call-dealloc (dealloc-ptr ptr len)
  "Release a Rust-owned buffer via the owning library's universal
deallocator. LEN = 0 transfers no allocation and is a no-op."
  (when (plusp len)
    (cffi:foreign-funcall-pointer dealloc-ptr ()
                                  :pointer ptr uintptr len uintptr 1
                                  :void)))

(defun %call-free (free-ptr obj-ptr)
  (cffi:foreign-funcall-pointer free-ptr () :pointer obj-ptr :void))
