;;; examples/fetch gate: <lisp> --load tests/run-fetch.lisp
;;; Hermetic — the crate starts its own loopback server, so no network.

(require :asdf)

#-quicklisp
(let ((q (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file q) (load q)))

(let* ((here (uiop:pathname-directory-pathname *load-truename*))
       (root (uiop:pathname-parent-directory-pathname here)))
  (push (merge-pathnames "lisp/" root) asdf:*central-registry*))

(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads :fiveam)
              :silent t)
(asdf:load-system :rulisp/test)

(let ((r (fiveam:run :rulisp-fetch)))
  (fiveam:explain! r)
  (uiop:quit (if (fiveam:results-status r) 0 1)))
