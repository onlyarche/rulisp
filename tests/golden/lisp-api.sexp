;;; The exported Lisp API of the RULISP package, pinned (docs/stability.md §1).
;;; One entry per external symbol: name, kind, then the direct superclasses
;;; (classes and conditions) or the lambda list (plain functions), as SBCL
;;; prints them with *package* = RULISP. Regenerate only for an ADDITIVE
;;; change, in the same commit, with a CHANGELOG line:
;;;   (rulisp/test::write-lisp-api-golden)   ; from SBCL
;;; v06.exported-api-golden compares this file on every host.
(
 (abi-mismatch-error :condition (rulisp-error))
 (build-error :condition (rulisp-error))
 (build-error-stderr :generic-function)
 (callback :function (function))
 (callback-token :class (standard-object))
 (crate :class (standard-object))
 (crate-generation :generic-function)
 (crate-name :generic-function)
 (crate-not-loaded-error :condition (rulisp-error))
 (crate-package :generic-function)
 (free :function (handle))
 (freed-handle-error :condition (invalid-handle-error))
 (handle :class (standard-object))
 (invalid-argument :condition (rulisp-error))
 (invalid-handle-error :condition (rulisp-error))
 (load-blob-crate :function (directory name &key package))
 (load-crate :function (path &key crate package))
 (manifest-error :condition (rulisp-error))
 (reload-crate :function (crate-or-name &key path))
 (retry-build :symbol)
 (rulisp-error :condition (error))
 (rust-error :condition (rulisp-error))
 (rust-error-function-name :generic-function)
 (rust-error-message :generic-function)
 (rust-error-type :generic-function)
 (rust-panic :condition (rulisp-error))
 (rust-panic-message :generic-function)
 (stale-crate-generation :generic-function)
 (stale-handle-error :condition (invalid-handle-error))
 (stale-handle-generation :generic-function)
 (unregister-callback :function (token))
 (use-crate :function (crate-dir &key (profile :dev) package features))
)
