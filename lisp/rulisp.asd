(asdf:defsystem #:rulisp
  :description "Use Rust from Common Lisp: load rulisp glue crates as idiomatic Lisp packages"
  :author "arche"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:cffi #:babel #:trivial-garbage #:bordeaux-threads #:uiop)
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "conditions")
               (:file "ffi")
               (:file "manifest")
               (:file "handle")
               (:file "codegen")
               (:file "crate")
               (:file "build")))

(asdf:defsystem #:rulisp/test
  :depends-on (#:rulisp #:fiveam)
  :pathname "../tests/suite/"
  :serial t
  :components ((:file "m1")
               (:file "m2")))
