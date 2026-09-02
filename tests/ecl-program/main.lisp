(defpackage #:rulisp-ecl-smoke
  (:use #:cl)
  (:export #:main))

(in-package #:rulisp-ecl-smoke)

(defun main ()
  "Load a prebuilt glue artifact at startup and call into it. The artifact
path arrives via RULISP_SMOKE_CRATE so the test can point at whatever
wordbag build exists; a deployed application would use load-blob-crate
next to its own binary (the artifact-directory snippet in distribution.md
Pattern B; ECL specifics are Pattern B′)."
  (let ((artifact (uiop:getenv "RULISP_SMOKE_CRATE")))
    (unless artifact
      (format t "FAIL: RULISP_SMOKE_CRATE is not set~%")
      (uiop:quit 2))
    (handler-case
        (progn
          (rulisp:load-crate artifact :crate "wordbag")
          ;; find-symbol, not wordbag:greet: the WORDBAG package exists only
          ;; after load-crate, so it cannot be read when this file is compiled
          (let* ((greet (find-symbol "GREET" "WORDBAG"))
                 (got (funcall greet "program-op")))
            (format t "~A~%" got)
            (unless (string= "Hello, program-op!" got)
              (format t "FAIL: unexpected greeting~%")
              (uiop:quit 1)))
          ;; a handle round trip, so the finalizer machinery is linked in too
          (let ((bag (funcall (find-symbol "MAKE-WORD-BAG" "WORDBAG"))))
            (funcall (find-symbol "WORD-BAG-ADD" "WORDBAG") bag "static")
            (unless (= 1 (funcall (find-symbol "WORD-BAG-LEN" "WORDBAG") bag))
              (format t "FAIL: handle round trip~%")
              (uiop:quit 1))
            (rulisp:free bag))
          (format t "ECL-PROGRAM-OK~%")
          (uiop:quit 0))
      (error (e)
        (format t "FAIL: ~A~%" e)
        (uiop:quit 1)))))
