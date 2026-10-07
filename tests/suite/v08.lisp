;;; v0.8 suite: what a new user's first mistake should say.

(in-package #:rulisp/test)

(def-suite* :rulisp-v08)

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §9: load-crate takes a built artifact; given a crate directory it
;;; used to fail inside the shape check with the host's stream error (SBCL
;;; 2.1.11: SIMPLE-STREAM-ERROR "couldn't read from #<SB-SYS:FD-STREAM ...>:
;;; Is a directory"), naming neither load-crate nor use-crate. It is refused
;;; as CRATE-NOT-LOADED-ERROR before anything is copied.
;;; ---------------------------------------------------------------------------

(test v08.load-crate-on-a-directory-is-refused
  (let* ((dir (asdf:system-relative-pathname :rulisp "../examples/rx/"))
         (slashless (uiop:native-namestring (string-right-trim "/\\" (uiop:native-namestring dir))))
         (before-crates (hash-table-count rulisp::*crates*))
         (before-cache (length (uiop:directory-files (rulisp::cache-directory)))))
    (dolist (spelling (list dir (pathname slashless)))
      (let ((c (handler-case (progn (rulisp:load-crate spelling) nil)
                 (error (e) e))))
        (is (typep c 'rulisp:crate-not-loaded-error)
            "load-crate on ~A signalled ~S, not crate-not-loaded-error" spelling (and c (type-of c)))
        (when c
          (let ((text (princ-to-string c)))
            (is (search "is a directory" text) "message: ~A" text)
            (is (search "use-crate" text) "message: ~A" text)))))
    (is (= before-crates (hash-table-count rulisp::*crates*)) "a refused directory was registered as a crate")
    (is (= before-cache (length (uiop:directory-files (rulisp::cache-directory))))
        "a refused directory left a cache copy")))
