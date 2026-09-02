;;; ecl --norc --load tests/ecl-program/build.lisp
;;; Builds tests/ecl-program/rulisp-ecl-smoke via asdf:program-op.
(require :asdf)
#-quicklisp
(let ((q (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file q) (load q)))
(let* ((here (uiop:pathname-directory-pathname *load-truename*))
       (root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-parent-directory-pathname here))))
  (push (merge-pathnames "lisp/" root) asdf:*central-registry*)
  (push here asdf:*central-registry*))
(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:make :rulisp-ecl-smoke)
(format t "BUILD-DONE~%")
(ext:quit 0)
