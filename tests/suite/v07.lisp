;;; v0.7 suite: "the freeze rehearsal" — hazards found in v0.6 that a 1.0
;;; candidate must refuse, not fault on.

(in-package #:rulisp/test)

(def-suite* :rulisp-v07)

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §9: a truncated or corrupt artifact is refused before dlopen.
;;; Found during v0.6 item 1: dlopen of a cut file faults (SBCL: "Signal 7 …
;;; Continuing with fingers crossed"; ld.so's load lock is left held, so the
;;; next load from another thread hangs), and a cut that keeps every PT_LOAD
;;; — 60 % of wordbag's ELF, where only .debug_* and the section table are
;;; missing — LOADED AND RAN until the first call into the missing bytes.
;;; The loader now checks each format's headers against the file size,
;;; before the cache copy is made.
;;; ---------------------------------------------------------------------------

(defun %cut-wordbag (keep)
  "A copy of the wordbag artifact cut short, in the temporary directory
under a per-process name. KEEP is a byte count, or a fraction of the size
when below 1."
  (ensure-crate)
  (with-open-file (in (rulisp::crate-source-path *crate*) :element-type '(unsigned-byte 8))
    (let* ((size (file-length in))
           (bytes (if (< keep 1) (floor (* size keep)) keep))
           (buf (make-array bytes :element-type '(unsigned-byte 8)))
           (cut (merge-pathnames
                 (format nil "rulisp-v07-cut-~D-wordbag-~A.~A"
                         bytes rulisp::*process-tag* (pathname-type (pathname in)))
                 (uiop:temporary-directory))))
      (read-sequence buf in)
      (with-open-file (out cut :direction :output :if-exists :supersede
                               :element-type '(unsigned-byte 8))
        (write-sequence buf out))
      cut)))

(test v07.truncated-artifact-is-refused
  (let* ((crate (ensure-crate))
         (real (rulisp::crate-source-path crate))
         (gen (rulisp:crate-generation crate))
         (cut (%cut-wordbag 6/10)))
    (unwind-protect
         (let ((before (length (uiop:directory-files (rulisp::cache-directory)))))
           (handler-case
               (progn (rulisp:load-crate cut :crate "wordbag")
                      (fail "a 60 % cut of the artifact loaded"))
             (rulisp:crate-not-loaded-error (e)
               (is (search "truncated" (rulisp:crate-not-loaded-message e))
                   "refused, but not as truncated: ~A" e)))
           ;; the registered crate is untouched: same artifact, same generation
           (is (= gen (rulisp:crate-generation crate))
               "the refused load bumped the generation")
           (is (equal (namestring real) (namestring (rulisp::crate-source-path crate)))
               "the refused load replaced the crate's artifact")
           ;; refused before the copy, so nothing is left behind — on Windows too
           (is (= before (length (uiop:directory-files (rulisp::cache-directory))))
               "the refused load left a cache copy behind")
           ;; and the real artifact still loads in this image
           (rulisp:load-crate real :crate "wordbag")
           (is (string= "Hello, after!" (wb-call "GREET" "after"))))
      (uiop:delete-file-if-exists cut))))

(test v07.header-only-artifact-is-refused-without-a-fault
  #-(or sbcl ccl)
  (pass "skipped: the subprocess shape needs sbcl or ccl on PATH")
  #+(or sbcl ccl)
  (let* ((cut (%cut-wordbag 4096))
         (script (merge-pathnames
                  (format nil "rulisp-v07-head-~A.lisp" rulisp::*process-tag*)
                  (uiop:temporary-directory)))
         (lisp-dir (asdf:system-relative-pathname :rulisp "")))
    (unwind-protect
         (progn
           (with-open-file (out script :direction :output :if-exists :supersede)
             (format out "~
(require :asdf)
#-quicklisp
(let ((q (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname))))
  (when (probe-file q) (load q)))
(push ~S asdf:*central-registry*)
(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:load-system :rulisp)
(handler-case
    (progn (rulisp:load-crate ~S :crate \"wordbag\")
           (format t \"FAIL: a 4096-byte head loaded~~%\")
           (uiop:quit 1))
  (rulisp:crate-not-loaded-error (e)
    (format t \"REFUSED-OK: ~~A~~%\" e)
    (finish-output)
    (uiop:quit 0))
  (serious-condition (e)
    (format t \"FAIL: ~~A~~%\" e)
    (uiop:quit 1)))~%"
                     (namestring lisp-dir) (namestring cut)))
           (multiple-value-bind (out err code)
               (uiop:run-program
                (append #+sbcl (list "sbcl" "--non-interactive")
                        #+ccl (list (first ccl:*command-line-argument-list*) "--batch")
                        (list "--load" (uiop:native-namestring script)))
                :output :string :error-output :string
                :ignore-error-status t)
             (let ((log (concatenate 'string out err)))
               (is (zerop code) "the subprocess did not refuse the head cleanly:~%~A" log)
               (is (search "REFUSED-OK" log) "no crate-not-loaded-error for the head:~%~A" log)
               (dolist (needle '("Signal 7" "CORRUPTION WARNING" "Memory fault"
                                 "Bus error" "bus error" "Unhandled exception"))
                 (is (not (search needle log))
                     "dlopen faulted on the head (~A):~%~A" needle log)))))
      (uiop:delete-file-if-exists script)
      (uiop:delete-file-if-exists cut))))
