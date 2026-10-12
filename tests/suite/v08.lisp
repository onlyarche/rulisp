;;; v0.8 suite: what a new user's first mistake should say.

(in-package #:rulisp/test)

(def-suite* :rulisp-v08)

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §9: load-crate takes a built artifact; given a crate directory it
;;; used to fail inside the shape check with the host's stream error (SBCL
;;; 2.1.11: SIMPLE-STREAM-ERROR "couldn't read from #<SB-SYS:FD-STREAM ...>:
;;; Is a directory"), naming neither load-crate nor use-crate. It is refused
;;; as CRATE-NOT-LOADED-ERROR before anything is copied.
;;; ---------------------------------------------------------------------------

(test v08.load-crate-on-a-directory-is-refused
  (let* ((dir (asdf:system-relative-pathname :rulisp "../examples/rx/"))
         (slashless (uiop:native-namestring (string-right-trim "/\\" (uiop:native-namestring dir))))
         (before-crates (hash-table-count rulisp::*crates*))
         (before-cache (length (uiop:directory-files (rulisp::cache-directory)))))
    (dolist (spelling (list dir (pathname slashless)))
      (let ((c (handler-case (progn (rulisp:load-crate spelling) nil)
                 (error (e) e))))
        (is (typep c 'rulisp:crate-not-loaded-error)
            "load-crate on ~A signalled ~S, not crate-not-loaded-error" spelling (and c (type-of c)))
        (when c
          (let ((text (princ-to-string c)))
            (is (search "is a directory" text) "message: ~A" text)
            (is (search "use-crate" text) "message: ~A" text)))))
    (is (= before-crates (hash-table-count rulisp::*crates*)) "a refused directory was registered as a crate")
    (is (= before-cache (length (uiop:directory-files (rulisp::cache-directory))))
        "a refused directory left a cache copy")))

;;; ---------------------------------------------------------------------------
;;; The cache sweep removed other processes' copies only for the crate being
;;; loaded and only after an hour, so copies of crates a later process did
;;; not load again stayed for good: one development week left 180 of them,
;;; 3.4 GB in ~/.cache/rulisp. A copy whose process is gone is now removed
;;; for any crate once it is a minute old (POSIX; Windows keeps the old
;;; rule, since a loaded DLL cannot be deleted there anyway).
;;; ---------------------------------------------------------------------------

(defun %dead-pid ()
  "The pid of a process that has exited."
  (let* ((p (uiop:launch-program '("true")))
         ;; read before waiting: ECL's uiop forgets the pid once it has exited
         (pid (uiop:process-info-pid p)))
    (uiop:wait-process p)
    pid))

(defun %age-file (path seconds)
  "Set PATH's modification time SECONDS into the past (touch -t, POSIX)."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time (- (get-universal-time) seconds))
    (uiop:run-program (list "touch" "-t" (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D.~2,'0D" y mo d h mi s)
                            (uiop:native-namestring path)))))

(test v08.cache-sweep-removes-copies-of-exited-processes
  (if (uiop:os-windows-p)
      (pass "skipped: a loaded DLL cannot be deleted on Windows; the hour rule stands")
      (let* ((dir (rulisp::cache-directory))
             (dead (%dead-pid))
             (ext (rulisp::shared-library-type))
             (dead-old (merge-pathnames (format nil "sweepdead-p~D-c1-1.~A" dead ext) dir))
             (dead-fresh (merge-pathnames (format nil "sweepfresh-p~D-c1-1.~A" dead ext) dir))
             (live-old (merge-pathnames (format nil "sweeplive-~A-c1-1.~A" rulisp::*process-tag* ext) dir))
             (current (merge-pathnames (format nil "sweepother-~A-c1-1.~A" rulisp::*process-tag* ext) dir))
             (files (list dead-old dead-fresh live-old current)))
        (unwind-protect
             (progn
               (dolist (f files)
                 (with-open-file (s f :direction :output :if-exists :supersede)
                   (write-string "x" s)))
               (%age-file dead-old 300)
               (%age-file live-old 300)
               ;; a load of an unrelated crate sweeps the whole cache
               (rulisp::%sweep-crate-cache "sweepother" current)
               (is (null (probe-file dead-old))
                   "a copy whose process (pid ~D) exited 5 minutes ago was kept" dead)
               (is (probe-file dead-fresh)
                   "a fresh copy was deleted: its process may be one this one cannot see")
               (is (probe-file live-old) "a copy of a live process (this one) was deleted")
               (is (probe-file current) "the current copy was swept"))
          (dolist (f files) (ignore-errors (delete-file f)))))))
