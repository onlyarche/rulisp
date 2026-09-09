;;; v0.6 suite: "the no-break cycle, measured" — the loader defects the v0.6
;;; panel reproduced, and the gates that make a surface break a CI fact.

(in-package #:rulisp/test)

(def-suite* :rulisp-v06)

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §10: a crate whose reload failed on image restore must be inert.
;;; Before v0.6, %stub-crate replaced only the symbol-functions; the crate
;;; object kept the dumped image's library handle and dump-hook pointer, and
;;; the next dump's hook run (%run-crate-dump-hooks) called straight into the
;;; dead mapping — SBCL: "CORRUPTION WARNING ... Memory fault". Reproduced in
;;; a subprocess: load a per-process copy of the artifact, dump an
;;; executable, delete the copy, run the executable and have it run the dump
;;; hooks exactly as the next uiop:dump-image would.
;;; ---------------------------------------------------------------------------

(test v06.restore-failure-leaves-no-live-foreign-pointer
  #-(or sbcl ccl)
  (pass "skipped: no uiop:dump-image on this host (ECL ships program-op executables, docs/distribution.md Pattern B′)")
  #+(or sbcl ccl)
  (let* ((tmp (uiop:temporary-directory))
         (tag rulisp::*process-tag*)
         (exe (merge-pathnames (format nil "rulisp-v06-restore-stub-~A" tag) tmp))
         (script (merge-pathnames (format nil "rulisp-v06-dump-phase-~A.lisp" tag) tmp))
         (lisp-dir (asdf:system-relative-pathname :rulisp "")))
    (ensure-crate)
    (let* ((artifact (merge-pathnames
                      (format nil "rulisp-v06-wordbag-~A.~A" tag
                              (pathname-type (rulisp::crate-source-path *crate*)))
                      tmp))
           (backup (merge-pathnames
                    (format nil "rulisp-v06-wordbag-backup-~A.~A" tag
                            (pathname-type (rulisp::crate-source-path *crate*)))
                    tmp)))
      (unwind-protect
           (progn
             (uiop:delete-file-if-exists exe)
             (uiop:copy-file (rulisp::crate-source-path *crate*) artifact)
             (uiop:copy-file (rulisp::crate-source-path *crate*) backup)
             (with-open-file (out script :direction :output :if-exists :supersede)
               (format out "~
(require :asdf)
#-quicklisp
(let ((q (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname))))
  (when (probe-file q) (load q)))
(push ~S asdf:*central-registry*)
(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:load-system :rulisp)
(rulisp:load-crate ~S :crate \"wordbag\")
(defvar *artifact* ~S)
(defvar *backup* ~S)
(setf uiop:*image-entry-point*
      (lambda ()
        (handler-case
            (let ((crate (gethash \"wordbag\" rulisp::*crates*)))
              ;; the restore warned and stubbed: every export refuses
              (handler-case
                  (progn (funcall (find-symbol \"GREET\" \"WORDBAG\") \"x\")
                         (format t \"FAIL: stubbed export did not signal~~%\")
                         (uiop:quit 1))
                (rulisp:crate-not-loaded-error () (format t \"STUB-SIGNALS-OK~~%\")))
              (when (search \"stubbed\" (with-output-to-string (s) (describe crate s)))
                (format t \"DESCRIBE-STUB-OK~~%\"))
              ;; the claim itself: no pointer into the dead mapping is left
              (when (and (null (rulisp::crate-lib-handle crate))
                         (null (rulisp::crate-on-dump-ptr crate))
                         (null (rulisp::crate-last-error-ptr crate))
                         (null (rulisp::crate-dealloc-ptr crate))
                         (null (rulisp::crate-handle-frees crate))
                         (null (rulisp::crate-cache-path crate)))
                (format t \"SLOTS-NIL-OK~~%\"))
              ;; the hook run below is only a test of anything if the
              ;; fixture declares a hook
              (when (rulisp::manifest-on-dump (rulisp::crate-manifest crate))
                (format t \"HAS-ON-DUMP-OK~~%\"))
              ;; what the next uiop:dump-image runs first
              (rulisp::%run-crate-dump-hooks)
              (format t \"RESTORE-STUB-OK~~%\")
              ;; recovery: the artifact comes back, reload-crate un-stubs the
              ;; crate, exports work again, and the next hook run goes to the
              ;; NEW library
              (uiop:copy-file *backup* *artifact*)
              (rulisp:reload-crate \"wordbag\")
              (when (and (string= \"Hello, back!\" (funcall (find-symbol \"GREET\" \"WORDBAG\") \"back\"))
                         (not (search \"stubbed\" (with-output-to-string (s) (describe crate s))))
                         (rulisp::crate-lib-handle crate))
                (format t \"RELOAD-AFTER-STUB-OK~~%\"))
              (rulisp::%run-crate-dump-hooks)
              (format t \"HOOKS-AFTER-RELOAD-OK~~%\")
              (finish-output)
              (uiop:quit 0))
          (error (e)
            (format t \"FAIL: ~~A~~%\" e)
            (uiop:quit 1)))))
(uiop:dump-image ~S :executable t)~%"
                       (namestring lisp-dir) (namestring artifact)
                       (namestring artifact) (namestring backup) (namestring exe)))
             (multiple-value-bind (out err code)
                 (uiop:run-program
                  (append #+sbcl (list "sbcl" "--non-interactive")
                          #+ccl (list (first ccl:*command-line-argument-list*) "--batch")
                          (list "--load" (uiop:native-namestring script)))
                  :output :string :error-output :string
                  :ignore-error-status t)
               (declare (ignore out))
               (is (zerop code) "dump phase failed:~%~A" err))
             ;; the artifact is gone when the image restores: the reload
             ;; fails, the crate is stubbed, and the hooks must not touch it
             (uiop:delete-file-if-exists artifact)
             (multiple-value-bind (out err code)
                 (uiop:run-program (list (uiop:native-namestring exe))
                                   :output :string :error-output :string
                                   :ignore-error-status t)
               (let ((log (concatenate 'string out err)))
                 (is (zerop code) "restore phase failed:~%~A" log)
                 (is (search "STUB-SIGNALS-OK" log) "stubbed export did not signal:~%~A" log)
                 (is (search "DESCRIBE-STUB-OK" log) "describe does not say the crate is stubbed:~%~A" log)
                 (is (search "SLOTS-NIL-OK" log) "a foreign pointer survived the stub:~%~A" log)
                 (is (search "HAS-ON-DUMP-OK" log) "the fixture declares no dump hook — the test would be vacuous:~%~A" log)
                 (is (search "RESTORE-STUB-OK" log) "the dump hooks did not return:~%~A" log)
                 (is (search "RELOAD-AFTER-STUB-OK" log) "reload-crate did not recover the stubbed crate:~%~A" log)
                 (is (search "HOOKS-AFTER-RELOAD-OK" log) "the hook run after the reload did not return:~%~A" log)
                 (dolist (needle '("Memory fault" "CORRUPTION WARNING" "Unhandled exception"))
                   (is (not (search needle log))
                       "the dump hook run reached the dead library (~A):~%~A" needle log)))))
        (uiop:delete-file-if-exists exe)
        (uiop:delete-file-if-exists script)
        (uiop:delete-file-if-exists artifact)
        (uiop:delete-file-if-exists backup)))))

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §1: abi_version() is checked first, before a byte of manifest is
;;; read, and must equal 1. Until v0.6 no test simulated a mismatch (§12 said
;;; so). tests/abi-fixture is a cdylib whose only export answers 2.
;;; ---------------------------------------------------------------------------

(test v06.abi-mismatch-refused
  (let ((dir (asdf:system-relative-pathname :rulisp "../tests/abi-fixture/")))
    (handler-case
        (progn (rulisp:use-crate dir)
               (fail "an artifact whose abi_version() answers 2 was loaded"))
      (rulisp:abi-mismatch-error (e)
        (is (eql 1 (rulisp:abi-mismatch-expected e)))
        (is (eql 2 (rulisp:abi-mismatch-actual e)))
        ;; refused before anything was registered or interned
        (is (null (gethash "abifix" rulisp::*crates*)) "a refused artifact left a crate object")
        (is (null (find-package "ABIFIX")) "a refused artifact left a package")))))

;;; ---------------------------------------------------------------------------
;;; docs/stability.md §1: the exported Lisp API is a surface 1.x freezes.
;;; tests/golden/lisp-api.sexp pins it — one entry per external symbol of
;;; RULISP: name, kind, the direct superclasses (classes and conditions) or
;;; the lambda list (plain functions). The symbol set, kinds and
;;; superclasses are exact on every host; lambda lists are exact on SBCL
;;; (sb-introspect) and compared by parameter names and &-markers on CCL
;;; and ECL, whose arglists render keywords and defaults differently. An
;;; additive change regenerates the golden in the same commit — from SBCL,
;;; (rulisp/test::write-lisp-api-golden) — with a CHANGELOG line; a removal
;;; or a changed signature fails here and does not land in a minor.
;;; ---------------------------------------------------------------------------

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-introspect))

(defun %api-kind (s)
  (cond ((macro-function s) :macro)
        ((and (fboundp s) (typep (fdefinition s) 'generic-function)) :generic-function)
        ((fboundp s) :function)
        ((find-class s nil) (if (subtypep s 'condition) :condition :class))
        (t :symbol)))   ; exported for its name alone — today the restart RETRY-BUILD

(defun %api-supers (s)
  (mapcar #'class-name
          (#+sbcl sb-mop:class-direct-superclasses
           #+ccl ccl:class-direct-superclasses
           #+ecl clos:class-direct-superclasses
           (find-class s))))

(defun %api-lambda-list (s)
  #+sbcl (sb-introspect:function-lambda-list s)
  #+ccl (values (ccl:arglist s))
  #+ecl (ext:function-lambda-list s))

(defun %api-entry (s)
  (let ((k (%api-kind s)))
    (case k
      (:function (list s k (%api-lambda-list s)))
      ((:condition :class) (list s k (%api-supers s)))
      (t (list s k)))))

(defun current-lisp-api ()
  (let ((syms (loop for s being the external-symbols of :rulisp collect s)))
    (mapcar #'%api-entry (sort syms #'string< :key #'symbol-name))))

(defparameter *lisp-api-golden*
  (asdf:system-relative-pathname :rulisp "../tests/golden/lisp-api.sexp"))

(defun read-lisp-api-golden ()
  (with-open-file (in *lisp-api-golden*)
    (let ((*package* (find-package :rulisp)))
      (read in))))

(defun write-lisp-api-golden ()
  "Regenerate tests/golden/lisp-api.sexp from the running image — SBCL only,
whose lambda lists are the exact ones the golden pins."
  #-sbcl (error "regenerate the Lisp API golden from SBCL")
  (with-open-file (out *lisp-api-golden* :direction :output :if-exists :supersede)
    (let ((*package* (find-package :rulisp))
          (*print-case* :downcase)
          (*print-pretty* nil))
      (format out ";;; The exported Lisp API of the RULISP package, pinned (docs/stability.md §1).~%")
      (format out ";;; One entry per external symbol: name, kind, then the direct superclasses~%")
      (format out ";;; (classes and conditions) or the lambda list (plain functions), as SBCL~%")
      (format out ";;; prints them with *package* = RULISP. Regenerate only for an ADDITIVE~%")
      (format out ";;; change, in the same commit, with a CHANGELOG line:~%")
      (format out ";;;   (rulisp/test::write-lisp-api-golden)   ; from SBCL~%")
      (format out ";;; v06.exported-api-golden compares this file on every host.~%(~%")
      (dolist (e (current-lisp-api))
        (format out " ~S~%" e))
      (format out ")~%"))
    *lisp-api-golden*))

(defun %api-names (lambda-list)
  "Parameter names and &-markers only — what CCL and ECL can be held to."
  (mapcar (lambda (x)
            (cond ((and (consp x) (consp (car x))) (symbol-name (second (car x)))) ; ((:key var) default)
                  ((consp x) (symbol-name (car x)))
                  (t (symbol-name x))))
          lambda-list))

(test v06.exported-api-golden
  (let* ((golden (read-lisp-api-golden))
         (current (current-lisp-api))
         (gnames (mapcar #'first golden))
         (cnames (mapcar #'first current)))
    (is (null (set-difference gnames cnames))
        "exported symbols missing from the package: ~S" (set-difference gnames cnames))
    (is (null (set-difference cnames gnames))
        "exported symbols not in the golden — an additive change regenerates it: ~S"
        (set-difference cnames gnames))
    (dolist (g golden)
      (let ((c (find (first g) current :key #'first)))
        (when c
          (is (eq (second g) (second c))
              "~S: kind ~S in the golden, ~S now" (first g) (second g) (second c))
          (case (second g)
            ((:condition :class)
             (is (equal (third g) (third c))
                 "~S: superclasses ~S in the golden, ~S now" (first g) (third g) (third c)))
            (:function
             #+sbcl (is (equal (third g) (third c))
                        "~S: lambda list ~S in the golden, ~S now" (first g) (third g) (third c))
             #-sbcl (is (equal (%api-names (third g)) (%api-names (third c)))
                        "~S: parameters ~S in the golden, ~S now" (first g) (third g) (third c)))))))))

;;; ---------------------------------------------------------------------------
;;; The loader's own API describes itself, as every generated function and
;;; class has since 0.5: each exported function has a docstring, each
;;; exported class and condition a class documentation.
;;; ---------------------------------------------------------------------------

(test v06.exports-are-documented
  (let ((undocumented '()))
    (do-external-symbols (s :rulisp)
      (when (and (fboundp s)
                 (zerop (length (or (documentation s 'function) ""))))
        (push (list s :function) undocumented))
      (let ((c (find-class s nil)))
        (when (and c (zerop (length (or (documentation c t) ""))))
          (push (list s :class) undocumented))))
    (is (null undocumented) "exports without documentation: ~S"
        (sort undocumented #'string< :key #'first))))

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §5: a handle is accepted only by wrappers of its birth
;;; generation. The counter that gate compares against must not be writable
;;; through the exported API — an exported (setf crate-generation) let a
;;; stale handle into a NEW library (reset the counter to 0, reload: the
;;; gen-1 handle passed into generation 1 again; the v0.6 panel reproduced
;;; it). No exported symbol names a writer.
;;; ---------------------------------------------------------------------------

(test v06.crate-generation-is-read-only
  (is (null (fboundp '(setf rulisp:crate-generation))))
  (let ((writers '()))
    (do-external-symbols (s :rulisp)
      (when (fboundp `(setf ,s)) (push s writers)))
    (is (null writers) "exported symbols with a setf function: ~S" writers))
  ;; and the reader still answers
  (ensure-crate)
  (is (integerp (rulisp:crate-generation *crate*))))

;;; ---------------------------------------------------------------------------
;;; use-crate's contract (its docstring, docs/installation.md): a build
;;; failure is a BUILD-ERROR with a RETRY-BUILD restart. A cargo that cannot
;;; be RUN at all was the exception on every host in a different way —
;;; SBCL let the host's own error escape, CCL signaled build-error with an
;;; empty stderr, ECL with "exec: No such file" — and the restart was inert
;;; for it, since cargo was looked up once outside the restart loop. The
;;; internal rulisp::*cargo* override names a nonexistent program without
;;; touching the environment, so this runs on Windows too.
;;; ---------------------------------------------------------------------------

(test v06.missing-cargo-is-a-build-error
  ;; the class, a non-empty stderr, the restart — never the text
  (let ((rulisp::*cargo* "/nonexistent/rulisp-no-such-cargo")
        (seen nil))
    (handler-case
        (handler-bind ((rulisp:build-error
                         (lambda (e)
                           (setf seen (list (plusp (length (rulisp:build-error-stderr e)))
                                            (not (null (find-restart 'rulisp:retry-build e))))))))
          (rulisp:use-crate *crate-dir*))
      (rulisp:build-error () nil))
    (is (equal '(t t) seen)
        "expected build-error with a non-empty stderr and a retry-build restart, got ~S" seen))
  ;; retry-build looks cargo up again: point it back at the real one from
  ;; the handler and the same use-crate returns a crate
  (let ((rulisp::*cargo* "/nonexistent/rulisp-no-such-cargo")
        (retried nil))
    (let ((crate (handler-case
                     (handler-bind ((rulisp:build-error
                                      (lambda (e)
                                        (declare (ignore e))
                                        ;; once: a retry that does not look
                                        ;; cargo up again would loop forever
                                        (unless retried
                                          (setf retried t
                                                rulisp::*cargo* nil)
                                          (invoke-restart 'rulisp:retry-build)))))
                       (rulisp:use-crate *crate-dir*))
                   (rulisp:build-error (e) e))))
      (is (typep crate 'rulisp:crate)
          "retry-build did not look cargo up again: ~A" crate))))

;;; ---------------------------------------------------------------------------
;;; README and quickstart promise NIL <-> None for Option<T>. For an optional
;;; FLOAT parameter the wrapper passed the literal integer 0 in the value
;;; slot when the argument was NIL, and SBCL's and CCL's foreign-call type
;;; check refused a fixnum for :double/:float — a host TYPE-ERROR where None
;;; was promised (ECL coerced). Invisible until v0.6 because no example took
;;; an Option<float>: opt_scale and opt_scale32 do now.
;;; ---------------------------------------------------------------------------

(test v06.option-float-nil-is-none
  (ensure-crate)
  (is (= -1d0 (wb-call "OPT-SCALE" nil)))
  (is (= 2.5d0 (wb-call "OPT-SCALE" 2.5d0)))
  (is (= -1f0 (wb-call "OPT-SCALE32" nil)))
  (is (= 2.5f0 (wb-call "OPT-SCALE32" 2.5f0))))
