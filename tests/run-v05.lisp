;;; v0.5 suite only: <lisp> --load tests/run-v05.lisp
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

(let* ((r1 (fiveam:run :rulisp-v05))
       (all r1))
  (fiveam:explain! all)
  (uiop:quit (if (fiveam:results-status all) 0 1)))
