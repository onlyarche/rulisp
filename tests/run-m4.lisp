;;; M4 gate: <lisp> --load tests/run-m4.lisp
;;; All suites (M1..M4) against the macro-based examples/wordbag.
;;; Works on non-SBCL implementations too (quicklisp bootstrapped explicitly;
;;; SBCL-only tests guard themselves).

(require :asdf)

#-quicklisp
(let ((q (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file q) (load q)))

(let* ((here (uiop:pathname-directory-pathname *load-truename*)) ; tests/
       (root (uiop:pathname-parent-directory-pathname here)))
  (push (merge-pathnames "lisp/" root) asdf:*central-registry*))

(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads :fiveam)
              :silent t)
(asdf:load-system :rulisp/test)

(setf rulisp/test::*crate-dir*
      (asdf:system-relative-pathname :rulisp "../examples/wordbag/"))

(let* ((r1 (fiveam:run :rulisp-m1))
       (r2 (fiveam:run :rulisp-m2))
       (r3 (fiveam:run :rulisp-m3))
       (r4 (fiveam:run :rulisp-m4))
       (r5 (fiveam:run :rulisp-v02))
       (r6 (fiveam:run :rulisp-v03))
       (r7 (fiveam:run :rulisp-v04))
       (all (append r1 r2 r3 r4 r5 r6 r7)))
  (fiveam:explain! all)
  (uiop:quit (if (fiveam:results-status all) 0 1)))
