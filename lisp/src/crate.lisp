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
   ;; a READER in the exported API: the counter is what the generation
   ;; gate compares handles against, and an exported setf let a stale
   ;; handle into a new library (v0.6 item 9, a §4 soundness fix)
   (generation :initform 0 :reader crate-generation :accessor %crate-generation)
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
   (on-dump-ptr :initform nil :accessor crate-on-dump-ptr)
   ;; set by %stub-crate when a reload failed on image restore; cleared by
   ;; the next successful generation commit
   (stub-reason :initform nil :accessor crate-stub-reason))
  (:documentation "A loaded glue crate: its name, the package its exports were
interned into, its generation (bumped by every reload) and the artifact it
came from. Returned by load-crate, use-crate, load-blob-crate and
reload-crate, which also accepts the name; (describe crate) prints where
it came from and every export's call shape."))

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

(defun %compute-process-tag ()
  "A per-process component for cache copy names. The pid where the host
exposes one; a random tag otherwise (SBCL seeds MAKE-RANDOM-STATE from the
OS, so two processes started in the same second still differ there)."
  (let ((pid (ignore-errors
              #+sbcl (let ((f (find-symbol "UNIX-GETPID" "SB-UNIX")))
                       (and f (fboundp f) (funcall f)))
              #+ccl (funcall (find-symbol "GETPID" "CCL"))
              #+ecl (ext:getpid)
              #-(or sbcl ccl ecl) nil)))
    (if (integerp pid)
        (format nil "p~D" pid)
        (format nil "r~36R" (random (expt 36 10) (make-random-state t))))))

(defvar *process-tag* (%compute-process-tag)
  "Recomputed on image restore: a dumped image inherits the dumper's tag,
and two restored instances of it would otherwise collide in the cache.")

(defun %cache-copy-name (provisional)
  "Cache copy name for a load of crate PROVISIONAL. Unique across processes
sharing one cache (the process tag), across loads within a process (the
counter), and across restarts of a pid-recycling host (the time). Before
the tag, two instances started in the same second wrote the same file —
copy-file rewrote a library the other process had already mapped, and
that process died with a segmentation fault."
  (format nil "~A-~A-c~D-~D.~A"
          provisional *process-tag* (incf *copy-counter*)
          (get-universal-time) (shared-library-type)))

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

;;; v0.7 item 2: a truncated or corrupt artifact is refused BEFORE dlopen.
;;; The host loader faults on one rather than failing (SIGBUS inside glibc's
;;; dlopen, ld.so's load lock left held — the next load from another thread
;;; hangs), and a cut that keeps every PT_LOAD loads and runs until the first
;;; call into the missing bytes. Only the headers are read: every region the
;;; file's own headers place must end within the file. Formats not recognized
;;; here (and FAT Mach-O, which no cargo target emits) pass through to
;;; dlopen as before.

(defun %octets-at (stream start count)
  "COUNT octets of STREAM from START, or NIL when the file ends first."
  (let ((v (make-array count :element-type '(unsigned-byte 8))))
    (file-position stream start)
    (and (= (read-sequence v stream) count) v)))

(defun %le (octets offset width)
  "The little-endian unsigned integer of WIDTH bytes at OFFSET."
  (loop for i below width sum (ash (aref octets (+ offset i)) (* 8 i))))

(defun %c-name (octets start count)
  "A NUL-padded ASCII name field, as a string."
  (map 'string #'code-char (remove 0 (subseq octets start (+ start count)))))

(defun %check-artifact-shape (path)
  "Signal crate-not-loaded-error if the object file at PATH is truncated or
corrupt by its own headers: ELF (64-bit LE) — the section header table and
every PT_LOAD end within the file; Mach-O 64 — every LC_SEGMENT_64 does;
PE — every section's raw data does."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((size (file-length in)))
      (labels ((refuse (detail)
                 (error 'crate-not-loaded-error
                        :name (namestring path)
                        :message (format nil "artifact is truncated or corrupt: ~A (~D bytes)"
                                         detail size)))
               (fits (end what)
                 (when (> end size)
                   (refuse (format nil "~A ends at byte ~D" what end))))
               (octets (start count what)
                 ;; bounds first: a corrupt count must not become a huge array
                 (fits (+ start count) what)
                 (or (%octets-at in start count)
                     (refuse (format nil "~A could not be read" what))))
               (elf ()
                 (let ((h (octets 0 64 "the ELF header")))
                   ;; class 2, little-endian: every supported target; anything
                   ;; else is dlopen's to refuse
                   (when (and (= (aref h 4) 2) (= (aref h 5) 1))
                     (let ((phoff (%le h 32 8)) (shoff (%le h 40 8))
                           (phentsize (%le h 54 2)) (phnum (%le h 56 2))
                           (shentsize (%le h 58 2)) (shnum (%le h 60 2)))
                       (when (plusp shnum)
                         (fits (+ shoff (* shnum shentsize)) "the section header table"))
                       (when (and (plusp phnum) (< phentsize 56))
                         (refuse (format nil "e_phentsize is ~D, below a 64-bit entry" phentsize)))
                       (let ((ph (octets phoff (* phnum phentsize) "the program header table")))
                         (dotimes (i phnum)
                           (let ((p (* i phentsize)))
                             (when (= (%le ph p 4) 1) ; PT_LOAD
                               (fits (+ (%le ph (+ p 8) 8) (%le ph (+ p 32) 8))
                                     (format nil "PT_LOAD segment ~D" i))))))))))
               (macho ()
                 (let* ((h (octets 0 32 "the Mach-O header"))
                        (ncmds (%le h 16 4))
                        (cmds (octets 32 (%le h 20 4) "the load command table")))
                   (loop with pos = 0
                         repeat ncmds
                         do (when (> (+ pos 8) (length cmds))
                              (refuse "a load command lies past sizeofcmds"))
                            (let ((cmd (%le cmds pos 4)) (cmdsize (%le cmds (+ pos 4) 4)))
                              (when (< cmdsize 8)
                                (refuse "a load command has cmdsize below 8"))
                              (when (= cmd #x19) ; LC_SEGMENT_64
                                (when (> (+ pos 56) (length cmds))
                                  (refuse "an LC_SEGMENT_64 lies past sizeofcmds"))
                                (fits (+ (%le cmds (+ pos 40) 8) (%le cmds (+ pos 48) 8))
                                      (format nil "segment ~A" (%c-name cmds (+ pos 8) 16))))
                              (incf pos cmdsize)))))
               (pe ()
                 (let* ((dos (octets 0 64 "the DOS header"))
                        (lfanew (%le dos 60 4))
                        (coff (octets lfanew 24 "the PE header")))
                   (unless (equalp (subseq coff 0 4) #(80 69 0 0))
                     (refuse "no PE signature where e_lfanew points"))
                   (let* ((nsections (%le coff 6 2))
                          (table (octets (+ lfanew 24 (%le coff 20 2)) (* nsections 40)
                                         "the section table")))
                     (dotimes (i nsections)
                       (let* ((s (* i 40)) (raw (%le table (+ s 16) 4)))
                         (when (plusp raw)
                           (fits (+ (%le table (+ s 20) 4) raw)
                                 (format nil "section ~A" (%c-name table s 8))))))))))
        (let ((magic (%octets-at in 0 4)))
          (when magic
            (cond ((equalp magic #(#x7f #x45 #x4c #x46)) (elf))
                  ((equalp magic #(#xcf #xfa #xed #xfe)) (macho))
                  ((and (= (aref magic 0) #x4d) (= (aref magic 1) #x5a)) (pe))))))))
  path)

(defun %load-crate-locked (path crate-arg package)
  ;; a crate directory, with or without its trailing slash, is the first
  ;; mistake a new user makes; the shape check would open it and fail with
  ;; the host's stream error (SBCL: SIMPLE-STREAM-ERROR "Is a directory")
  (when (uiop:directory-exists-p path)
    (error 'crate-not-loaded-error
           :name (namestring path)
           :message (format nil "~A is a directory — load-crate takes a built artifact (lib<name>.so/.dylib/.dll); use-crate builds a crate directory"
                            path)))
  (let* ((path (or (probe-file path)
                   (error 'crate-not-loaded-error
                          :name (namestring path)
                          :message "artifact does not exist")))
         (provisional (substitute #\_ #\- (or crate-arg (derive-crate-name path))))
         (prefix-guess (format nil "~A_rulisp_" provisional))
         ;; unique name per load AND per process: defeats dlopen path
         ;; caching (macOS dyld would otherwise hand back the old image),
         ;; sidesteps the Windows lock on a loaded DLL, and keeps two
         ;; processes sharing a cache from rewriting each other's mapping
         (copy (merge-pathnames (%cache-copy-name provisional) (cache-directory))))
    ;; before the copy: the check reads a few KB, the copy moves megabytes,
    ;; and a refused file must leave nothing behind (v0.7 item 2)
    (%check-artifact-shape path)
    (uiop:copy-file path copy)
    ;; the copy is made before the artifact is verified; a load that does
    ;; not commit must not leave it behind — its name carries the guessed
    ;; prefix, so the sweep could never match it (v0.6 item 12). POSIX:
    ;; unlinking a mapped copy is safe (the mapping keeps the inode);
    ;; Windows: a mapped DLL cannot be unlinked, so best-effort and ignored
    (let ((committed nil))
      (unwind-protect
           (multiple-value-bind (lib manifest raw)
               (%open-and-verify provisional copy prefix-guess path)
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
                 (setf committed t)
                 crate)))
        (unless committed
          (ignore-errors (delete-file copy)))))))

(defun %open-and-verify (display-name copy prefix &optional origin)
  (let* ((lib (dlopen* copy :origin origin))
         (abi-ptr (or (dlsym-ptr lib (concatenate 'string prefix "abi_version"))
                      (error 'abi-mismatch-error
                             :expected +abi-version+ :actual nil
                             :message (format nil "~A is not a rulisp crate (no ~Aabi_version) ~
                                                   — if the artifact was renamed, pass ~
                                                   :crate with the crate's name"
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
    (setf (crate-stub-reason crate) nil   ; a successful commit un-stubs
          (%crate-generation crate) gen
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
                 collect (cons class-sym (synthesize-handle-doc h pkg))))
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
                           (list sym (synthesize-fn-doc f pkg)
                                 (funcall (handler-bind
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
      (loop for (class-sym . doc) in classes
            do (setf (get class-sym '%rulisp-class-owner) (crate-name crate))
               (eval `(defclass ,class-sym (handle) () (:documentation ,doc)))
               (export class-sym pkg))
      (let ((new-symbols (mapcar #'first fns)))
        (loop for (sym doc fn) in fns
              do (setf (symbol-function sym) fn)
                 (%set-function-doc sym doc)
                 (export sym pkg))
        (dolist (sym (set-difference (crate-symbols crate) new-symbols))
          (fmakunbound sym)
          (%set-function-doc sym nil))
        (setf (crate-symbols crate) new-symbols)))))

(defun %set-function-doc (sym doc)
  "ECL ignores (setf documentation) for a compiled closure installed with
(setf symbol-function) — its documentation lives in a database keyed by
the symbol, written only by si::set-documentation."
  #+ecl (si::set-documentation sym 'function doc)
  #-ecl (setf (documentation sym 'function) doc))

;;; v0.6: the loader's own exported readers describe themselves, as every
;;; generated function has since 0.5 (the classes carry :documentation).
(dolist (entry
         '((crate-name . "The crate's name: the manifest's :crate, also its package's name downcased.")
           (crate-generation . "The crate's current generation: 1 at first load, +1 per reload. A handle carries the generation it was made in.")
           (crate-package . "The package the crate's exports are interned into.")
           (rust-error-message . "The Rust error's Display text.")
           (rust-error-type . "The Rust error type's name, as the manifest declares it (\"Error\" for the generic one).")
           (rust-error-function-name . "The Lisp function whose call returned the Err.")
           (rust-panic-message . "The panic payload as text (a non-string payload reads as its type).")
           (rust-panic-function-name . "The Lisp function whose call panicked.")
           (invalid-argument-message . "Which argument was refused, and why.")
           (invalid-argument-function-name . "The Lisp function whose argument was refused.")
           (invalid-handle-function-name . "The Lisp function that was given the freed or stale handle.")
           (stale-handle-generation . "The generation the stale handle was made in.")
           (stale-crate-generation . "The crate's generation at the time of the refused call.")
           (crate-not-loaded-name . "The crate name or artifact path that could not be resolved or loaded.")
           (crate-not-loaded-message . "Why: the loader's message, or the reason the crate was stubbed.")
           (build-error-command . "The cargo command line that failed, as one string.")
           (build-error-stderr . "cargo's standard error output, verbatim.")
           (manifest-error-message . "Which rule of the manifest grammar was broken.")
           (abi-mismatch-expected . "What this loader requires: its ABI version, or the host's target.")
           (abi-mismatch-actual . "What the artifact answered: its abi_version(), or NIL when it exports none.")
           (abi-mismatch-message . "The detail, when there is one beyond the two values.")
           (rulisp-version-skew-crate . "The crate whose manifest declares the newer rulisp.")
           (rulisp-version-skew-built-with . "The rulisp version the crate was built with.")
           (rulisp-version-skew-loader . "This loader's rulisp version.")))
  (%set-function-doc (car entry) (cdr entry)))

(defmethod describe-object ((c crate) stream)
  "(describe crate): everything the REPL user asks first — where it came
from, which generation, what it exports and with which signatures."
  (let ((m (crate-manifest c))
        (pkg (crate-package c)))
    (format stream "~&~S is a rulisp crate.~%" c)
    (format stream "  Package:        ~A~%" (package-name pkg))
    (format stream "  Generation:     ~D (session ~D)~%" (crate-generation c) *session*)
    (format stream "  Artifact:       ~A~%" (crate-source-path c))
    (format stream "  Loaded copy:    ~A~%" (or (crate-cache-path c) "none"))
    (when (crate-stub-reason c)
      (format stream "  State:          stubbed (~A); every export signals ~
                      crate-not-loaded-error until reload-crate succeeds~%"
              (crate-stub-reason c)))
    (when m
      (format stream "  Crate version:  ~A~%" (or (manifest-crate-version m) "?"))
      (format stream "  Built with:     rulisp ~A (this loader: ~A)~%"
              (or (manifest-rulisp-version m) "unknown (pre-0.5)") *rulisp-version*)
      (format stream "  Target:         ~A~%" (or (manifest-target m) "?"))
      (format stream "  ABI:            ~D, manifest schema ~D~%" (manifest-abi m) (manifest-schema m))
      (format stream "  Dump hook:      ~A~%" (or (manifest-on-dump m) "none declared"))
      (format stream "  Handle classes:~{ ~(~A~):~(~A~)~}~%"
              (loop for h in (manifest-handles m)
                    append (list (package-name pkg) (handle-spec-lisp-name h))))
      (format stream "  Exports (~D):~%" (length (manifest-functions m)))
      ;; the call shape, not the docstring's first line — for a ///-documented
      ;; export that line is prose (the v0.5 docs audit caught it)
      (dolist (f (manifest-functions m))
        (format stream "    ~A~%" (%call-shape f pkg))))))

(defun %sweep-crate-cache (name current-copy)
  "Delete this crate's older cache copies: this process's own previous
generations right away, and other processes' copies only once they are an
hour old. The age rule closes the window between another process copying
its artifact and dlopening it — unlinking a still-MAPPED file is safe on
POSIX (the mapping keeps the inode alive), but an unlinked not-yet-mapped
copy makes that process's dlopen fail. On Windows a loaded DLL cannot be
deleted at all, so the delete simply fails and is ignored."
  (let* ((base (substitute #\_ #\- name))
         (any (format nil "~A-" base))
         (own (format nil "~A-~A-c" base *process-tag*))
         (now (get-universal-time)))
    (dolist (f (uiop:directory-files (cache-directory)))
      (let ((fname (file-namestring f)))
        (when (and (uiop:string-prefix-p any fname)
                   (not (equal (namestring f) (namestring current-copy)))
                   (or (uiop:string-prefix-p own fname)
                       (let ((written (ignore-errors (file-write-date f))))
                         (and written (> (- now written) 3600)))))
          (ignore-errors (delete-file f)))))))

;;; ---------------------------------------------------------------------------
;;; Image dump / restore (DESIGN.md §6.5)
;;; ---------------------------------------------------------------------------

(defun %stub-crate (crate reason)
  "A crate whose reload failed on image restore is inert until RELOAD-CRATE
succeeds: every generated function signals CRATE-NOT-LOADED-ERROR, and
every foreign pointer the crate object still carries from the dumped
image — the library handle, the dump hook, last-error, dealloc, the free
shims, the cache copy — is dropped, so nothing on the crate (the dump
hook runner in particular) can call into the dead mapping. Found by the
v0.6 panel: the next dump's hook run jumped into unmapped memory.
The artifact path stays, so a later RELOAD-CRATE knows where to look."
  (dolist (sym (crate-symbols crate))
    (let ((name (crate-name crate)))
      (setf (symbol-function sym)
            (lambda (&rest args)
              (declare (ignore args))
              (error 'crate-not-loaded-error :name name :message reason)))))
  (setf (crate-lib-handle crate) nil
        (crate-on-dump-ptr crate) nil
        (crate-last-error-ptr crate) nil
        (crate-dealloc-ptr crate) nil
        (crate-handle-frees crate) nil
        (crate-cache-path crate) nil
        (crate-stub-reason crate) reason))

(defun %restore-all-crates ()
  ;; Session bump comes FIRST: even if reloading fails below, every pre-dump
  ;; handle and captured wrapper is already invalid and nothing can
  ;; dereference a dead pointer.
  ;; a dumped image carries the dumper's tag; every restored instance needs
  ;; its own before it reloads anything into the shared cache
  (setf *process-tag* (%compute-process-tag))
  (incf *session*)
  (bt:with-lock-held (*registry-lock*)
    (maphash
     (lambda (name crate)
       ;; serious-condition, not error: a host fault inside dlopen arrives
       ;; as a storage-condition on ECL (segmentation-violation), and a
       ;; crate that failed to reload must be stubbed whatever the class
       (handler-case
           (%load-crate-locked (crate-source-path crate) name nil)
         (serious-condition (e)
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
