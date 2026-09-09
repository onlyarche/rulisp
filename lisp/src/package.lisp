(defpackage #:rulisp
  (:use #:cl)
  (:export
   ;; API (DESIGN.md §6.7)
   #:load-crate
   #:use-crate
   #:reload-crate
   #:load-blob-crate
   #:free
   #:crate
   #:handle
   ;; stored callbacks (v0.2)
   #:callback
   #:unregister-callback
   #:callback-token
   ;; crate readers
   #:crate-name
   #:crate-generation
   #:crate-package
   ;; conditions (DESIGN.md §6.3)
   #:rulisp-error
   #:rust-error
   #:rust-panic
   #:invalid-argument
   #:invalid-handle-error
   #:freed-handle-error
   #:stale-handle-error
   #:crate-not-loaded-error
   #:build-error
   #:manifest-error
   #:abi-mismatch-error
   #:rulisp-version-skew                ; a style-warning (docs/stability.md §7)
   ;; condition readers — every slot a handler can read (v0.6: all of them)
   #:rust-error-message
   #:rust-error-type
   #:rust-error-function-name
   #:rust-panic-message
   #:rust-panic-function-name
   #:invalid-argument-message
   #:invalid-argument-function-name
   #:invalid-handle-function-name
   #:stale-handle-generation
   #:stale-crate-generation
   #:crate-not-loaded-name
   #:crate-not-loaded-message
   #:build-error-command
   #:build-error-stderr
   #:manifest-error-message
   #:abi-mismatch-expected
   #:abi-mismatch-actual
   #:abi-mismatch-message
   #:rulisp-version-skew-crate
   #:rulisp-version-skew-built-with
   #:rulisp-version-skew-loader
   ;; restart names
   #:retry-build))
