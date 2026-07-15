;;; M2 gate: sbcl --non-interactive --load tests/run-m2.lisp
;;; Runs the full M1 suite plus the M2 fixture suite.

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

(let* ((r1 (fiveam:run :rulisp-m1))
       (r2 (fiveam:run :rulisp-m2))
       (all (append r1 r2)))
  (fiveam:explain! all)
  (uiop:quit (if (fiveam:results-status all) 0 1)))
