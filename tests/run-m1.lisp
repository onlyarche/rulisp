;;; M1 gate: sbcl --non-interactive --load tests/run-m1.lisp

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

(let ((result (fiveam:run :rulisp-m1)))
  (fiveam:explain! result)
  (uiop:quit (if (fiveam:results-status result) 0 1)))
