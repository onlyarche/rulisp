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
   ;; condition readers
   #:rust-error-message
   #:rust-error-type
   #:rust-error-function-name
   #:rust-panic-message
   #:stale-handle-generation
   #:stale-crate-generation
   #:build-error-stderr
   ;; restart names
   #:retry-build))
