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
