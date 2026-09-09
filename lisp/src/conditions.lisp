(in-package #:rulisp)

(define-condition rulisp-error (error) ()
  (:documentation "Root of every error rulisp signals — handle it to catch any
failure at the boundary: a Rust Err or panic, a refused argument or handle,
a crate that is not loaded, a failed build, a bad manifest or artifact.
Never signaled itself."))

(define-condition rust-error (rulisp-error)
  ((message :initarg :message :initform "" :reader rust-error-message)
   (rust-type :initarg :rust-type :initform nil :reader rust-error-type)
   (function-name :initarg :function-name :initform nil :reader rust-error-function-name))
  (:report (lambda (c s)
             (format s "Rust error~@[ ~A~]~@[ in ~A~]: ~A"
                     (rust-error-type c) (rust-error-function-name c)
                     (rust-error-message c))))
  (:documentation "A Rust export returned Err. RUST-ERROR-TYPE is the Rust
error type's name, RUST-ERROR-MESSAGE its Display text,
RUST-ERROR-FUNCTION-NAME the Lisp function that made the call. An error
type not named Error gets its own subclass in the crate's package (a
ParseError becomes crate:parse-error). Signaled with a USE-VALUE restart:
the value to return in place of the call's result."))

(define-condition rust-panic (rulisp-error)
  ((message :initarg :message :initform "" :reader rust-panic-message)
   (function-name :initarg :function-name :initform nil :reader rust-panic-function-name))
  (:report (lambda (c s)
             (format s "Rust panic~@[ in ~A~]: ~A"
                     (rust-panic-function-name c) (rust-panic-message c))))
  (:documentation "A Rust export panicked. The panic was caught at the
boundary — the image is intact and the call returned nothing —
RUST-PANIC-MESSAGE is its payload text and RUST-PANIC-FUNCTION-NAME the
Lisp function that made the call. A poisoned Mutex reports as this on the
next lock."))

(define-condition invalid-argument (rulisp-error)
  ((message :initarg :message :initform "" :reader invalid-argument-message)
   (function-name :initarg :function-name :initform nil :reader invalid-argument-function-name))
  (:report (lambda (c s)
             (format s "Invalid argument~@[ in ~A~]: ~A"
                     (invalid-argument-function-name c) (invalid-argument-message c))))
  (:documentation "A Lisp value could not cross the boundary as the export's
parameter type — not an octet sequence for :bytes, a wrong element type
for a :vec, a string Rust rejects as UTF-8, a callback token where a
token was expected. INVALID-ARGUMENT-MESSAGE says which,
INVALID-ARGUMENT-FUNCTION-NAME which call. Nothing was passed to Rust."))

(define-condition invalid-handle-error (rulisp-error)
  ((function-name :initarg :function-name :initform nil
                  :reader invalid-handle-function-name))
  (:documentation "Superclass of FREED-HANDLE-ERROR and STALE-HANDLE-ERROR:
a handle the gate refused to pass into Rust, before any foreign call.
INVALID-HANDLE-FUNCTION-NAME is the Lisp function that was called."))

(define-condition freed-handle-error (invalid-handle-error) ()
  (:report (lambda (c s)
             (format s "Handle already freed~@[ (in ~A)~]"
                     (invalid-handle-function-name c))))
  (:documentation "A handle used after rulisp:free (or after its GC finalizer
ran). Memory is intact: the gate refused before any foreign call."))

(define-condition stale-handle-error (invalid-handle-error)
  ((handle-generation :initarg :handle-generation :initform nil
                      :reader stale-handle-generation)
   (crate-generation :initarg :crate-generation :initform nil
                     :reader stale-crate-generation))
  (:report (lambda (c s)
             (format s "Stale handle~@[ (in ~A)~]: handle gen ~A, crate gen ~A"
                     (invalid-handle-function-name c)
                     (stale-handle-generation c) (stale-crate-generation c))))
  (:documentation "A handle from an earlier generation of its crate (the crate
was reloaded since) or from a previous image session (dumped and restored
since). STALE-HANDLE-GENERATION and STALE-CRATE-GENERATION are the two
generations. The handle cannot be used, but it can still be freed."))

(define-condition crate-not-loaded-error (rulisp-error)
  ((name :initarg :name :initform nil :reader crate-not-loaded-name)
   (message :initarg :message :initform "" :reader crate-not-loaded-message))
  (:report (lambda (c s)
             (format s "Crate ~A is not loaded~@[: ~A~]"
                     (crate-not-loaded-name c)
                     (let ((m (crate-not-loaded-message c)))
                       (and (plusp (length m)) m)))))
  (:documentation "No crate to act on: the name given to reload-crate is not
loaded, the artifact path does not exist, dlopen refused the file
(CRATE-NOT-LOADED-MESSAGE carries the loader's message), or a generated
function of a crate stubbed after a failed image restore was called.
CRATE-NOT-LOADED-NAME is the crate or path."))

(define-condition build-error (rulisp-error)
  ((command :initarg :command :initform nil :reader build-error-command)
   (stderr :initarg :stderr :initform "" :reader build-error-stderr))
  (:report (lambda (c s)
             (format s "cargo build failed~@[ (~A)~]:~%~A"
                     (build-error-command c) (build-error-stderr c))))
  (:documentation "cargo build failed inside use-crate. BUILD-ERROR-COMMAND is
the command line, BUILD-ERROR-STDERR cargo's stderr. Signaled with the
RETRY-BUILD restart, which runs the build again."))

(define-condition manifest-error (rulisp-error)
  ((message :initarg :message :initform "" :reader manifest-error-message))
  (:report (lambda (c s)
             (format s "Manifest error: ~A" (manifest-error-message c))))
  (:documentation "The artifact's embedded manifest was refused: unreadable,
not a rulisp manifest, a schema newer than this loader's, a load-bearing
key missing or malformed, a type token outside the vocabulary, a
duplicate Lisp name, or an :on-dump that does not name a zero-parameter
:unit export. MANIFEST-ERROR-MESSAGE says which. Signaled before anything
is interned or bound, so a previous generation stays intact."))

(define-condition abi-mismatch-error (rulisp-error)
  ((expected :initarg :expected :initform nil :reader abi-mismatch-expected)
   (actual :initarg :actual :initform nil :reader abi-mismatch-actual)
   (message :initarg :message :initform nil :reader abi-mismatch-message))
  (:report (lambda (c s)
             (format s "ABI mismatch: ~@[~A; ~]expected ~A, got ~A"
                     (abi-mismatch-message c)
                     (abi-mismatch-expected c) (abi-mismatch-actual c))))
  (:documentation "The artifact cannot be loaded by this loader: it is not a
rulisp crate (no <prefix>abi_version export), its abi_version() is not
this loader's, its manifest :abi disagrees with abi_version(), or it was
built for another target. ABI-MISMATCH-EXPECTED and ABI-MISMATCH-ACTUAL
carry the two values, ABI-MISMATCH-MESSAGE the detail. Refused before a
byte of manifest is read (the target check excepted)."))


(define-condition rulisp-version-skew (style-warning)
  ((crate :initarg :crate :reader rulisp-version-skew-crate)
   (built-with :initarg :built-with :reader rulisp-version-skew-built-with)
   (loader :initarg :loader :reader rulisp-version-skew-loader))
  (:report (lambda (c s)
             (format s "crate ~A was built with rulisp ~A but this loader is ~A: ~
                        manifest keys it relies on may be ignored here ~
                        (docs/stability.md §7)"
                     (rulisp-version-skew-crate c)
                     (rulisp-version-skew-built-with c)
                     (rulisp-version-skew-loader c))))
  (:documentation "Signaled (as a style-warning) when a crate's manifest
declares a newer rulisp major.minor than the loader's. Informational: an
older loader still loads the crate; only enhancement keys it does not know
are ignored, and a load-bearing key would have raised :schema instead."))
