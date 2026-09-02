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
;; Load-bearing, not a convenience: ECL 21.2.1's bundled ASDF 3.1.8.8
;; compiles a dependency's files under program-op without loading the
;; earlier ones, so from a cold cache cffi's early-types.lisp fails
;; (WARN-IF-KW-OR-BELONGS-TO-CL undefined at macroexpansion). Loading the
;; dependencies first sidesteps it (distribution.md Pattern B′, fact 4).
(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:make :rulisp-ecl-smoke)
(format t "BUILD-DONE~%")
(ext:quit 0)
