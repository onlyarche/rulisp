;;; M1 gate: sbcl --non-interactive --load tests/run-m1.lisp
;;; (quicklisp comes from the user init file)

(require :asdf)

(let* ((here (uiop:pathname-directory-pathname *load-truename*)) ; tests/
       (root (uiop:pathname-parent-directory-pathname here)))
  (push (merge-pathnames "lisp/" root) asdf:*central-registry*))

(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads :fiveam)
              :silent t)
(asdf:load-system :rulisp/test)

(let ((result (fiveam:run :rulisp-m1)))
  (fiveam:explain! result)
  (uiop:quit (if (fiveam:results-status result) 0 1)))
