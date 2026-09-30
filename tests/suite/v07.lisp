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

(test v07.section-stripped-artifact-still-loads
  "The shape check refuses a file its own headers overrun, not a file a
tool stripped: an ELF without its section header table — the header's
fields cleared with it, as llvm-objcopy --strip-sections leaves it —
loads and runs. A failure means the check refuses a valid artifact, which
for a loader is a break."
  (let* ((crate (ensure-crate))
         (real (rulisp::crate-source-path crate))
         (bytes (with-open-file (in real :element-type '(unsigned-byte 8))
                  (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
                    (read-sequence v in)
                    v))))
    (if (not (and (> (length bytes) 64)
                  (equalp (subseq bytes 0 4) #(#x7f #x45 #x4c #x46))
                  (= 2 (aref bytes 4)) (= 1 (aref bytes 5))))
        (pass "skipped: the artifact is not a 64-bit little-endian ELF on this host")
        (let* ((phoff (rulisp::%le bytes 32 8))
               (phentsize (rulisp::%le bytes 54 2))
               (phnum (rulisp::%le bytes 56 2))
               ;; the file ends where its last loadable segment does
               (end (loop for i below phnum
                          for p = (+ phoff (* i phentsize))
                          when (= 1 (rulisp::%le bytes p 4))
                            maximize (+ (rulisp::%le bytes (+ p 8) 8)
                                        (rulisp::%le bytes (+ p 32) 8))))
               (stripped (merge-pathnames
                          (format nil "rulisp-v07-stripped-wordbag-~A.~A"
                                  rulisp::*process-tag* (pathname-type real))
                          (uiop:temporary-directory))))
          ;; e_shoff (8 bytes at 40), e_shnum (2 at 60), e_shstrndx (2 at 62)
          (fill bytes 0 :start 40 :end 48)
          (fill bytes 0 :start 60 :end 64)
          (with-open-file (out stripped :direction :output :if-exists :supersede
                                        :element-type '(unsigned-byte 8))
            (write-sequence bytes out :end end))
          (unwind-protect
               (progn
                 (is (< end (length bytes)) "nothing was cut: the fixture has no section table")
                 (rulisp:load-crate stripped :crate "wordbag")
                 (is (string= "Hello, stripped!" (wb-call "GREET" "stripped")))
                 (rulisp:load-crate real :crate "wordbag")
                 (is (string= "Hello, again!" (wb-call "GREET" "again"))))
            (uiop:delete-file-if-exists stripped))))))
