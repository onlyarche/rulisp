;;; M3 gate: sbcl --non-interactive --load tests/run-m3.lisp
;;; Runs the UNCHANGED M1 + M2 suites plus the M3 suite against the
;;; MACRO-based examples/wordbag (the hand-written oracle in
;;; tests/m1-handwritten/ is preserved but not exercised here).

(require :asdf)

(let* ((here (uiop:pathname-directory-pathname *load-truename*)) ; tests/
       (root (uiop:pathname-parent-directory-pathname here)))
  (push (merge-pathnames "lisp/" root) asdf:*central-registry*))

(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads :fiveam)
              :silent t)
(asdf:load-system :rulisp/test)

;; point the whole suite at the macro-generated crate
(setf rulisp/test::*crate-dir*
      (asdf:system-relative-pathname :rulisp "../examples/wordbag/"))

(let* ((r1 (fiveam:run :rulisp-m1))
       (r2 (fiveam:run :rulisp-m2))
       (r3 (fiveam:run :rulisp-m3))
       (all (append r1 r2 r3)))
  (fiveam:explain! all)
  (uiop:quit (if (fiveam:results-status all) 0 1)))
