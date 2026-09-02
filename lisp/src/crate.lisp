(in-package #:rulisp)

;;; Crate loading, reload with generations, image dump/restore (DESIGN.md
;;; §6.1, §6.5). Every load dlopens a UNIQUE COPY of the artifact (defeats
;;; dlopen path caching), never dlcloses (old mappings stay valid so stale-
;;; generation handles can still be freed by their birth generation's shim).
;;;
;;; All load/reload/restore paths serialize on *registry-lock*. Wrapper CALLS
;;; never take it: they only touch their immutable gen-ctx and per-cell locks.
;;;
;;; Generation commit is two-phase (DESIGN.md §8 M2, no half-generation ban):
;;; PREPARE-BINDINGS does everything that can signal — symbol resolution,
;;; ownership checks, wrapper compilation — then COMMIT-BINDINGS publishes,
;;; with no signaling path. A bad manifest leaves the previous API fully
;;; intact.

(defclass crate ()
  ((name :initarg :name :reader crate-name)
   (package :initarg :package :reader crate-package)
   (generation :initform 0 :accessor crate-generation)
   (lib-handle :initform nil :accessor crate-lib-handle)
   (prefix :initform nil :accessor crate-prefix)
   (manifest :initform nil :accessor crate-manifest)
   (manifest-source :initform nil :accessor crate-manifest-source)
   (source-path :initform nil :accessor crate-source-path)
   (cache-path :initform nil :accessor crate-cache-path)
   (last-error-ptr :initform nil :accessor crate-last-error-ptr)
   (dealloc-ptr :initform nil :accessor crate-dealloc-ptr)
   (symbols :initform nil :accessor crate-symbols)
   (handle-frees :initform nil :accessor crate-handle-frees)
   (on-dump-ptr :initform nil :accessor crate-on-dump-ptr)))

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

(defvar *crate-load-order* '()
  "Crate names in first-load order — BOUNDARY §10 requires declared dump
hooks to run in load order.")

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
         ;; unique name per load: defeats dlopen path caching (macOS dyld
         ;; would otherwise hand back the old image) and sidesteps the
         ;; Windows lock on a loaded DLL
         (copy (merge-pathnames (format nil "~A-c~D-~D.~A"
                                        provisional
                                        (incf *copy-counter*)
                                        (get-universal-time)
                                        (shared-library-type))
                                (cache-directory))))
    (uiop:copy-file path copy)
    (multiple-value-bind (lib manifest raw)
        (%open-and-verify provisional copy prefix-guess)
      (let ((canonical (manifest-crate manifest)))
        (when (and crate-arg
                   (string/= (substitute #\_ #\- canonical)
                             (substitute #\_ #\- crate-arg)))
          (error 'manifest-error
                 :message (format nil "manifest says crate ~S, expected ~S"
                                  canonical crate-arg)))
        (let ((crate (or (gethash canonical *crates*)
                         (progn
                           (setf *crate-load-order*
                                 (append *crate-load-order* (list canonical)))
                           (setf (gethash canonical *crates*)
                                 (make-instance 'crate
                                                :name canonical
                                                :package (ensure-crate-package
                                                          (or package (string-upcase canonical)))))))))
          (%commit-generation crate path lib manifest raw copy)
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
    (multiple-value-bind (manifest raw) (%read-library-manifest lib prefix)
      (unless (= (manifest-abi manifest) abi)
        (error 'abi-mismatch-error :expected abi :actual (manifest-abi manifest)
                                   :message "manifest :abi disagrees with abi_version()"))
      (let ((target (manifest-target manifest)))
        (when target
          (multiple-value-bind (ok host) (target-compatible-p target)
            (unless ok
              (error 'abi-mismatch-error
                     :expected host :actual target
                     :message "artifact was built for a different target")))))
      (values lib manifest raw))))

(defun %read-library-manifest (lib prefix)
  "Returns (values parsed-manifest raw-string). The raw string is kept for
the golden-snapshot byte-identity gate (DESIGN.md §8 M3)."
  (let ((mptr (or (dlsym-ptr lib (concatenate 'string prefix "manifest"))
                  (error 'manifest-error
                         :message (format nil "no ~Amanifest symbol" prefix)))))
    (cffi:with-foreign-object (len 'uintptr)
      (let* ((sptr (cffi:foreign-funcall-pointer mptr () :pointer len :pointer))
             (raw (foreign-utf8 sptr (cffi:mem-ref len 'uintptr))))
        (values (parse-manifest raw) raw)))))

(defun %commit-generation (crate path lib manifest raw copy)
  "Commit LIB as CRATE's next generation. Phase 1 (everything that can
signal) runs first against an immutable snapshot; only then are the crate's
slots and the package mutated."
  (let* ((gen (1+ (crate-generation crate)))
         (prefix (manifest-prefix manifest))
         (resolve (lambda (short)
                    (let ((full (concatenate 'string prefix short)))
                      (or (dlsym-ptr lib full)
                          (error 'manifest-error
                                 :message (format nil "symbol ~A not found in crate ~A"
                                                  full (crate-name crate)))))))
         (last-error-ptr (funcall resolve "last_error"))
         (dealloc-ptr (funcall resolve "dealloc"))
         (on-dump-ptr (let ((sym (manifest-on-dump manifest)))
                        (and sym (funcall resolve sym))))
         (frees (loop for h in (manifest-handles manifest)
                      collect (cons (handle-spec-rust-name h)
                                    (funcall resolve (handle-spec-free h)))))
         (err-conds (loop for e in (manifest-errors manifest)
                          collect (cons e (intern (camel-to-kebab e)
                                                  (crate-package crate)))))
         (ctx (%make-gen-ctx gen *session* last-error-ptr dealloc-ptr frees
                             err-conds))
         (prepared (prepare-bindings crate manifest ctx resolve)))
    ;; Nothing below signals.
    (setf (crate-generation crate) gen
          (crate-lib-handle crate) lib
          (crate-prefix crate) prefix
          (crate-manifest crate) manifest
          (crate-manifest-source crate) raw
          (crate-source-path crate) path
          (crate-cache-path crate) copy
          (crate-last-error-ptr crate) last-error-ptr
          (crate-dealloc-ptr crate) dealloc-ptr
          (crate-handle-frees crate) frees
          (crate-on-dump-ptr crate) on-dump-ptr)
    (commit-bindings crate prepared)
    (%sweep-crate-cache (crate-name crate) copy)
    crate))

(defun prepare-bindings (crate manifest ctx resolve)
  "Phase 1 of binding generation: ownership checks, symbol resolution and
wrapper compilation — everything that can signal. Mutates nothing except
interning symbols (harmless). A failure leaves the crate's existing API
fully intact (half-generated packages are banned — DESIGN.md §8 M2)."
  (let* ((pkg (crate-package crate))
         (class-name-for
           (lambda (rust-name)
             (let ((h (find rust-name (manifest-handles manifest)
                            :key #'handle-spec-rust-name :test #'string=)))
               (unless h
                 (error 'manifest-error
                        :message (format nil "unknown handle type ~S" rust-name)))
               (intern (string-upcase (handle-spec-lisp-name h)) pkg))))
         (classes
           (loop for h in (manifest-handles manifest)
                 for class-sym = (intern (string-upcase (handle-spec-lisp-name h)) pkg)
                 ;; a shared :package must not let two crates silently share
                 ;; one class — the class IS the type gate between families
                 do (let ((owner (get class-sym '%rulisp-class-owner)))
                      (when (and owner (string/= owner (crate-name crate)))
                        (error 'manifest-error
                               :message (format nil "handle class ~S already belongs to crate ~S"
                                                class-sym owner))))
                 collect class-sym))
         (fns
           (loop for f in (manifest-functions manifest)
                 collect (let* ((sym (intern (string-upcase (fn-spec-lisp-name f)) pkg))
                                (qualified (format nil "~(~A~):~(~A~)"
                                                   (package-name pkg)
                                                   (fn-spec-lisp-name f)))
                                (fn-ptr (funcall resolve (fn-spec-symbol f)))
                                (form (wrapper-form f class-name-for qualified)))
                           ;; muffle forward-reference warnings: wrappers
                           ;; mention handle classes that COMMIT defines later
                           ;; (prepare must not mutate the package). Only
                           ;; muffle when the restart exists — some hosts
                           ;; signal warnings without it.
                           (cons sym (funcall (handler-bind
                                                  ((warning
                                                     (lambda (w)
                                                       (when (find-restart 'muffle-warning w)
                                                         (muffle-warning w)))))
                                                (let ((*compile-verbose* nil) (*compile-print* nil))
                                                  ;; ECL's compile prints
                                                  ;; per-function notes
                                                  ;; otherwise — a deployed
                                                  ;; program must stay quiet
                                                  (compile nil form)))
                                              crate ctx fn-ptr))))))
    (list classes fns (gen-ctx-error-conditions ctx))))

(defun commit-bindings (crate prepared)
  "Phase 2: publish a prepared binding set. No signaling path in here.
Wrappers of a previous generation are replaced; exports that vanished are
fmakunbound."
  (destructuring-bind (classes fns error-conditions) prepared
    (let ((pkg (crate-package crate)))
      ;; typed condition classes from the manifest's :errors (M3): additive,
      ;; each a subclass of rust-error so generic handlers keep working
      (loop for (nil . cond-sym) in error-conditions
            do (eval `(define-condition ,cond-sym (rust-error) ()))
               (export cond-sym pkg))
      (dolist (class-sym classes)
        (setf (get class-sym '%rulisp-class-owner) (crate-name crate))
        (eval `(defclass ,class-sym (handle) ()))
        (export class-sym pkg))
      (let ((new-symbols (mapcar #'car fns)))
        (loop for (sym . fn) in fns
              do (setf (symbol-function sym) fn)
                 (export sym pkg))
        (dolist (sym (set-difference (crate-symbols crate) new-symbols))
          (fmakunbound sym))
        (setf (crate-symbols crate) new-symbols)))))

(defun %sweep-crate-cache (name current-copy)
  "Delete this crate's older cache copies. Unlinking a still-mapped file is
safe on POSIX (the mapping keeps the inode alive); copies left by previous
OS processes reference no live mapping at all. On Windows a loaded DLL
cannot be deleted at all, so the delete simply fails and is ignored —
stale copies are swept on a later run once nothing has them open."
  (let ((prefix (format nil "~A-c" (substitute #\_ #\- name))))
    (dolist (f (uiop:directory-files (cache-directory)))
      (when (and (uiop:string-prefix-p prefix (file-namestring f))
                 (not (equal (namestring f) (namestring current-copy))))
        (ignore-errors (delete-file f))))))

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

(defun %run-crate-dump-hooks ()
  "BOUNDARY §10: immediately before an image dump, call every loaded
crate's declared :on-dump export, in load order. A failing hook — error
status, panic, or a Lisp-side condition — is warned and skipped: a dump
must never be wedged by its own cleanup."
  (dolist (name *crate-load-order*)
    (let ((crate (gethash name *crates*)))
      (when (and crate (crate-on-dump-ptr crate) (crate-lib-handle crate))
        (handler-case
            (let ((status (cffi:foreign-funcall-pointer
                           (crate-on-dump-ptr crate) () :int32)))
              (unless (zerop status)
                (multiple-value-bind (type msg)
                    (read-crate-last-error (crate-last-error-ptr crate))
                  (warn "rulisp: dump hook of ~A failed (status ~D, ~A: ~A); ~
                         the dump proceeds"
                        name status type msg))))
          (serious-condition (e)
            (warn "rulisp: dump hook of ~A signaled ~A; the dump proceeds"
                  name e)))))))

(uiop:register-image-dump-hook '%run-crate-dump-hooks nil)
(uiop:register-image-restore-hook '%restore-all-crates nil)
