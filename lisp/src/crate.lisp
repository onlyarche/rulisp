(in-package #:rulisp)

;;; Crate loading, reload with generations, image dump/restore (DESIGN.md
;;; §6.1, §6.5). Every load dlopens a UNIQUE COPY of the artifact (defeats
;;; dlopen path caching), never dlcloses (old mappings stay valid so stale-
;;; generation handles can still be freed by their birth generation's shim).
;;;
;;; All load/reload/restore paths serialize on *registry-lock*. Wrapper CALLS
;;; never take it: they only touch their immutable gen-ctx and per-cell locks.

(defclass crate ()
  ((name :initarg :name :reader crate-name)
   (package :initarg :package :reader crate-package)
   (generation :initform 0 :accessor crate-generation)
   (lib-handle :initform nil :accessor crate-lib-handle)
   (prefix :initform nil :accessor crate-prefix)
   (manifest :initform nil :accessor crate-manifest)
   (source-path :initform nil :accessor crate-source-path)
   (cache-path :initform nil :accessor crate-cache-path)
   (last-error-ptr :initform nil :accessor crate-last-error-ptr)
   (dealloc-ptr :initform nil :accessor crate-dealloc-ptr)
   (symbols :initform nil :accessor crate-symbols)
   (handle-frees :initform nil :accessor crate-handle-frees)))

(defmethod print-object ((c crate) stream)
  (print-unreadable-object (c stream :type t)
    (let ((m (crate-manifest c)))
      (format stream "~S gen ~D abi ~A :: ~D fns, ~D handle~:P, package ~A"
              (crate-name c) (crate-generation c)
              (if m (manifest-abi m) "?")
              (if m (length (manifest-functions m)) 0)
              (if m (length (manifest-handles m)) 0)
              (package-name (crate-package c))))))

(defmethod print-object ((h handle) stream)
  (print-unreadable-object (h stream :type t :identity t)
    (let* ((cell (handle-cell h))
           (crate (cell-crate cell))
           (state (cond ((/= (cell-session cell) *session*) :stale)
                        ((and crate (/= (cell-generation cell)
                                        (crate-generation crate)))
                         :stale)
                        (t (cell-state cell)))))
      (format stream "~(~A~) gen ~D" state (cell-generation cell)))))

(defvar *registry-lock* (bt:make-lock "rulisp-registry"))

(defvar *crates* (make-hash-table :test 'equal)
  "crate name (string, as declared by the manifest) → crate object.
Guarded by *registry-lock*.")

(defvar *copy-counter* 0)

(defun cache-directory ()
  (let ((dir (uiop:xdg-cache-home "rulisp/")))
    (ensure-directories-exist dir)
    dir))

(defun derive-crate-name (path)
  (let ((base (pathname-name path)))
    (if (and (>= (length base) 4) (string= "lib" base :end2 3))
        (subseq base 3)
        base)))

(defun ensure-crate-package (name)
  (or (find-package name)
      (make-package name :use '())))

(defun load-crate (path &key crate package)
  "Load a built rulisp cdylib artifact as a Lisp package.
PATH: the .so/.dylib produced by cargo. Copies it under a unique name in the
rulisp cache, dlopens the copy, verifies the ABI, reads the embedded
manifest, and generates bindings into PACKAGE (default: the manifest's crate
name, upcased). The manifest's :crate is the canonical name; :CRATE, when
given, is checked against it. Loading an already-loaded crate bumps its
generation (= reload)."
  (bt:with-lock-held (*registry-lock*)
    (%load-crate-locked path crate package)))

(defun reload-crate (crate-or-name &key path)
  "Reload a crate from its (rebuilt) artifact: new unique copy, new dlopen,
regenerated wrappers, generation+1. Old handles signal STALE-HANDLE-ERROR on
use but can still be freed."
  (bt:with-lock-held (*registry-lock*)
    (let ((crate (resolve-crate crate-or-name)))
      (%load-crate-locked (or path (crate-source-path crate))
                          (crate-name crate) nil))))

(defun resolve-crate (crate-or-name)
  (etypecase crate-or-name
    (crate crate-or-name)
    ((or string symbol)
     (let ((name (string-downcase (string crate-or-name))))
       (or (gethash name *crates*)
           (error 'crate-not-loaded-error :name name
                                          :message "no such crate loaded"))))))

(defun %load-crate-locked (path crate-arg package)
  (let* ((path (or (probe-file path)
                   (error 'crate-not-loaded-error
                          :name (namestring path)
                          :message "artifact does not exist")))
         (provisional (substitute #\_ #\- (or crate-arg (derive-crate-name path))))
         (prefix-guess (format nil "~A_rulisp_" provisional))
         (copy (merge-pathnames (format nil "~A-c~D-~D.so"
                                        provisional
                                        (incf *copy-counter*)
                                        (get-universal-time))
                                (cache-directory))))
    (uiop:copy-file path copy)
    (multiple-value-bind (lib manifest)
        (%open-and-verify provisional copy prefix-guess)
      (let ((canonical (manifest-crate manifest)))
        (when (and crate-arg
                   (string/= (substitute #\_ #\- canonical)
                             (substitute #\_ #\- crate-arg)))
          (error 'manifest-error
                 :message (format nil "manifest says crate ~S, expected ~S"
                                  canonical crate-arg)))
        (let ((crate (or (gethash canonical *crates*)
                         (setf (gethash canonical *crates*)
                               (make-instance 'crate
                                              :name canonical
                                              :package (ensure-crate-package
                                                        (or package (string-upcase canonical))))))))
          (%commit-generation crate path lib manifest copy)
          crate)))))

(defun %open-and-verify (display-name copy prefix)
  (let* ((lib (dlopen* copy))
         (abi-ptr (or (dlsym-ptr lib (concatenate 'string prefix "abi_version"))
                      (error 'abi-mismatch-error
                             :expected +abi-version+ :actual nil
                             :message (format nil "~A is not a rulisp crate (no ~Aabi_version)"
                                              display-name prefix))))
         (abi (cffi:foreign-funcall-pointer abi-ptr () :uint32)))
    (unless (= abi +abi-version+)
      (error 'abi-mismatch-error :expected +abi-version+ :actual abi))
    (let ((manifest (%read-library-manifest lib prefix)))
      (unless (= (manifest-abi manifest) abi)
        (error 'abi-mismatch-error :expected abi :actual (manifest-abi manifest)
                                   :message "manifest :abi disagrees with abi_version()"))
      (values lib manifest))))

(defun %read-library-manifest (lib prefix)
  (let ((mptr (or (dlsym-ptr lib (concatenate 'string prefix "manifest"))
                  (error 'manifest-error
                         :message (format nil "no ~Amanifest symbol" prefix)))))
    (cffi:with-foreign-object (len 'uintptr)
      (let ((sptr (cffi:foreign-funcall-pointer mptr () :pointer len :pointer)))
        (parse-manifest (foreign-utf8 sptr (cffi:mem-ref len 'uintptr)))))))

(defun %commit-generation (crate path lib manifest copy)
  "Commit LIB as CRATE's next generation and regenerate all bindings from an
immutable snapshot of the new generation's pointers."
  (let ((gen (1+ (crate-generation crate))))
    (setf (crate-generation crate) gen
          (crate-lib-handle crate) lib
          (crate-prefix crate) (manifest-prefix manifest)
          (crate-manifest crate) manifest
          (crate-source-path crate) path
          (crate-cache-path crate) copy
          (crate-last-error-ptr crate) (crate-resolve-symbol crate "last_error")
          (crate-dealloc-ptr crate) (crate-resolve-symbol crate "dealloc")
          (crate-handle-frees crate)
          (loop for h in (manifest-handles manifest)
                collect (cons (handle-spec-rust-name h)
                              (crate-resolve-symbol crate (handle-spec-free h)))))
    (regenerate-bindings crate)
    (%sweep-crate-cache (crate-name crate) copy)
    crate))

(defun %sweep-crate-cache (name current-copy)
  "Delete this crate's older cache copies. Unlinking a still-mapped file is
safe on POSIX (the mapping keeps the inode alive); copies left by previous
OS processes reference no live mapping at all."
  (let ((prefix (format nil "~A-c" (substitute #\_ #\- name))))
    (dolist (f (uiop:directory-files (cache-directory)))
      (when (and (uiop:string-prefix-p prefix (file-namestring f))
                 (not (equal (namestring f) (namestring current-copy))))
        (ignore-errors (delete-file f))))))

(defun crate-resolve-symbol (crate short-name)
  "Resolve <prefix><short-name> against the crate's CURRENT dlopen handle
only — never the global namespace (two generations export identical names)."
  (let ((full (concatenate 'string (crate-prefix crate) short-name)))
    (or (dlsym-ptr (crate-lib-handle crate) full)
        (error 'manifest-error
               :message (format nil "symbol ~A not found in crate ~A"
                                full (crate-name crate))))))

(defun make-wrapper (crate ctx fspec class-name-for)
  "Compile FSPEC's wrapper and close it over CRATE, the immutable generation
context CTX, and the fn pointer resolved against the generation being
committed."
  (let* ((qualified (format nil "~(~A~):~(~A~)"
                            (package-name (crate-package crate))
                            (fn-spec-lisp-name fspec)))
         (fn-ptr (crate-resolve-symbol crate (fn-spec-symbol fspec)))
         (form (wrapper-form fspec class-name-for qualified)))
    (funcall (compile nil form) crate ctx fn-ptr)))

(defun regenerate-bindings (crate)
  "(Re)generate handle classes and wrapper functions from the crate's current
manifest into its package. Wrappers of a previous generation are replaced;
exports that vanished are fmakunbound."
  (let* ((pkg (crate-package crate))
         (manifest (crate-manifest crate))
         (ctx (%make-gen-ctx (crate-generation crate)
                             *session*
                             (crate-last-error-ptr crate)
                             (crate-dealloc-ptr crate)
                             (crate-handle-frees crate)))
         (class-name-for
           (lambda (rust-name)
             (let ((h (find rust-name (manifest-handles manifest)
                            :key #'handle-spec-rust-name :test #'string=)))
               (unless h
                 (error 'manifest-error
                        :message (format nil "unknown handle type ~S" rust-name)))
               (intern (string-upcase (handle-spec-lisp-name h)) pkg))))
         (old-symbols (crate-symbols crate))
         (new-symbols '()))
    (dolist (h (manifest-handles manifest))
      (let* ((class-sym (intern (string-upcase (handle-spec-lisp-name h)) pkg))
             (owner (get class-sym '%rulisp-class-owner)))
        ;; a shared :package must not let two crates silently share one class
        ;; — the class IS the type gate between handle families
        (when (and owner (string/= owner (crate-name crate)))
          (error 'manifest-error
                 :message (format nil "handle class ~S already belongs to crate ~S"
                                  class-sym owner)))
        (setf (get class-sym '%rulisp-class-owner) (crate-name crate))
        (eval `(defclass ,class-sym (handle) ()))
        (export class-sym pkg)))
    (dolist (f (manifest-functions manifest))
      (let ((sym (intern (string-upcase (fn-spec-lisp-name f)) pkg)))
        (setf (symbol-function sym) (make-wrapper crate ctx f class-name-for))
        (export sym pkg)
        (push sym new-symbols)))
    (dolist (sym (set-difference old-symbols new-symbols))
      (fmakunbound sym))
    (setf (crate-symbols crate) new-symbols)))

;;; ---------------------------------------------------------------------------
;;; Image dump / restore (DESIGN.md §6.5)
;;; ---------------------------------------------------------------------------

(defun %stub-crate (crate reason)
  (dolist (sym (crate-symbols crate))
    (let ((name (crate-name crate)))
      (setf (symbol-function sym)
            (lambda (&rest args)
              (declare (ignore args))
              (error 'crate-not-loaded-error :name name :message reason))))))

(defun %restore-all-crates ()
  ;; Session bump comes FIRST: even if reloading fails below, every pre-dump
  ;; handle and captured wrapper is already invalid and nothing can
  ;; dereference a dead pointer.
  (incf *session*)
  (bt:with-lock-held (*registry-lock*)
    (maphash
     (lambda (name crate)
       (handler-case
           (%load-crate-locked (crate-source-path crate) name nil)
         (error (e)
           (warn "rulisp: could not reload crate ~A on image restore: ~A" name e)
           (%stub-crate crate (format nil "reload failed on image restore: ~A" e)))))
     *crates*)))

(uiop:register-image-restore-hook '%restore-all-crates nil)
