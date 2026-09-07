;;; The previous release's loader loads the tree's crate — docs/stability.md
;;; §8 criterion 3, forward direction. Run by `make compat` with
;;;   RULISP_PREV      the previous release's tag (a label in the marker),
;;;   RULISP_PREV_LISP its archived lisp/ directory (git archive <tag> lisp),
;;;   RULISP_ARTIFACT  the wordbag artifact this tree just built.
;;; Any warning other than rulisp-version-skew — which an older loader may
;;; not export, hence find-symbol — is an error: a manifest key the old
;;; loader cannot ignore, a renamed wire symbol or a schema bump shows up
;;; here first, where fx.golden-manifest would only ask for a new golden.

(require :asdf)
#-quicklisp
(let ((q (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file q) (load q)))

(defvar *prev* (uiop:getenv "RULISP_PREV"))
(defvar *prev-lisp* (uiop:ensure-directory-pathname (uiop:getenv "RULISP_PREV_LISP")))
(push *prev-lisp* asdf:*central-registry*)
(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:load-system :rulisp)

;; the loader that answered must be the archived one, not the tree's
(let ((loaded (asdf:system-source-directory :rulisp)))
  (format t "~&loader: ~A (version ~A)~%"
          loaded (asdf:component-version (asdf:find-system :rulisp)))
  (unless (search (namestring (truename *prev-lisp*)) (namestring (truename loaded)))
    (error "the ~A loader was not the one loaded: ~A" *prev* loaded)))

(handler-bind ((warning (lambda (w)
                          (let ((skew (find-symbol "RULISP-VERSION-SKEW" "RULISP")))
                            (if (and skew (typep w skew))
                                (progn (format t "~&(skew warning, expected: ~A)~%" w)
                                       (muffle-warning w))
                                (error "unexpected warning from the ~A loader: ~A" *prev* w))))))
  (rulisp:load-crate (uiop:getenv "RULISP_ARTIFACT") :crate "wordbag"))

(defun wb (name) (symbol-function (find-symbol name "WORDBAG")))
;; the shapes a glue crate has: string, handle + Result error, panic, free
(let ((bag (funcall (wb "MAKE-WORD-BAG"))))
  (funcall (wb "WORD-BAG-ADD") bag "compat")
  (assert (= 1 (funcall (wb "WORD-BAG-LEN") bag)))
  (assert (handler-case (progn (funcall (wb "WORD-BAG-ADD") bag "") nil)
            (rulisp:rust-error () t)))
  (assert (eq t (rulisp:free bag))))
(assert (handler-case (progn (funcall (wb "ALWAYS-PANIC")) nil)
          (rulisp:rust-panic () t)))
(format t "~&OLD-LOADER-OK ~A~%" (funcall (wb "GREET") (format nil "~A loader" *prev*)))
(uiop:quit 0)
