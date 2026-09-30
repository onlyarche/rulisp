;;; examples/wasm suite: the WebAssembly runtime README.md describes and
;;; every release attaches as a blob — pinned here as it ships, before the
;;; WASI sandbox is built on it (v0.7 item 7).
;;;
;;; Every test states what a failure would mean. The guests are the two
;;; committed .wat files; nothing here needs a wasm-targeting toolchain.

(in-package #:rulisp/test)

(def-suite* :rulisp-wasm)

(defvar *wasm-crate* nil)

(defun ensure-wasm ()
  "Lazily, never at load time: the dist dry run loads this file with cargo
out of reach."
  (or *wasm-crate*
      (setf *wasm-crate*
            (rulisp:use-crate (asdf:system-relative-pathname
                               :rulisp "../examples/wasm/")))))

(defun wasm-sym (name)
  (or (find-symbol name "WASM") (error "WASM:~A missing" name)))

(defun wf (name &rest args) (apply (wasm-sym name) args))

(defun wat (file)
  (uiop:native-namestring
   (asdf:system-relative-pathname :rulisp (format nil "../examples/wasm/~A" file))))

(defmacro with-wasm ((var file &optional (fuel 0)) &body body)
  "VAR is a fresh instance of the guest FILE, freed on the way out."
  `(progn
     (ensure-wasm)
     (let ((,var (wf "MAKE-WASM" (wat ,file) ,fuel)))
       (unwind-protect (progn ,@body)
         (rulisp:free ,var)))))

(defmacro trap-message (&body body)
  "The message of the wasm:wasm-error BODY signals. NIL when BODY returns,
or signals a rust-error of any other class — so a lost condition type fails
the same assertion a lost trap does."
  `(handler-case (progn ,@body nil)
     (rulisp:rust-error (e)
       (and (typep e (wasm-sym "WASM-ERROR"))
            (rulisp:rust-error-message e)))))

(defun octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(defmacro with-warnings-collected ((var) &body body)
  "Run BODY with every warning muffled and its text pushed onto VAR."
  `(handler-bind ((warning (lambda (w)
                             (push (princ-to-string w) ,var)
                             (muffle-warning w))))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Contract: what the crate declares
;;; ---------------------------------------------------------------------------

(test wasm.manifest-declares-one-stored-callback
  "The mirror of fetch.manifest-has-no-stored-callbacks: host.notify is the
one stored callback, which is why ECL compiles a trampoline to load this
crate. A failure means a callback was added or removed without anyone
deciding what it costs on ECL."
  (ensure-wasm)
  (let ((raw (rulisp::crate-manifest-source *wasm-crate*)))
    (is (= 1 (loop with at = 0
                   for hit = (search ":stored-callback" raw :start2 at)
                   while hit
                   count hit
                   do (setf at (1+ hit)))))))

(test wasm.exports-lists-functions
  "README: load a .wat module from the REPL. A failure means the text
format no longer parses, or the export list changed its shape."
  (with-wasm (w "fib.wat")
    (is (string= "add,boom,fib,sum_mem" (wf "WASM-EXPORTS" w))))
  (with-wasm (g "guest.wat")
    (is (string= "emit_squares" (wf "WASM-EXPORTS" g)))))

(test wasm.binary-module-loads
  "README: .wasm as well as .wat. The guests are committed as text, so the
binary path gets a module written here byte by byte: one function, answer,
returning i32 42. A failure means only the text format loads."
  (ensure-wasm)
  (let ((path (merge-pathnames (format nil "rulisp-wasm-answer-~A.wasm"
                                       rulisp::*process-tag*)
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :supersede
                                     :element-type '(unsigned-byte 8))
             (write-sequence
              (octets #x00 #x61 #x73 #x6d  #x01 #x00 #x00 #x00 ; \0asm, version 1
                      #x01 #x05 #x01 #x60 #x00 #x01 #x7f       ; type: () -> i32
                      #x03 #x02 #x01 #x00                      ; function 0 has type 0
                      #x07 #x0a #x01 #x06 #x61 #x6e #x73 #x77 #x65 #x72 #x00 #x00 ; export "answer"
                      #x0a #x06 #x01 #x04 #x00 #x41 #x2a #x0b) ; body: i32.const 42
              out))
           (let ((w (wf "MAKE-WASM" (uiop:native-namestring path) 0)))
             (unwind-protect
                  (progn
                    (is (string= "answer" (wf "WASM-EXPORTS" w)))
                    (is (= 42 (wf "WASM-CALL0" w "answer"))))
               (rulisp:free w))))
      (uiop:delete-file-if-exists path))))

;;; ---------------------------------------------------------------------------
;;; Calls
;;; ---------------------------------------------------------------------------

(test wasm.calls-coerce-i32
  "Lisp speaks i64; an i32 parameter takes the low 32 bits and an i32
result is sign-extended. The wrap at 2^31 is pinned as BEHAVIOUR: a later
range check is a knowing change to this test, not a silent one."
  (with-wasm (w "fib.wat")
    (is (= 5 (wf "WASM-CALL2" w "add" 2 3)))
    (is (= 6765 (wf "WASM-CALL1" w "fib" 20)))
    (is (= -2147483648 (wf "WASM-CALL2" w "add" 2147483647 1)))))

(test wasm.bad-call-is-a-condition
  "A wrong argument count or an unknown export is refused by name before
anything runs. A failure means a guest function was entered with the wrong
number of values."
  (with-wasm (w "fib.wat")
    (is (search "takes 2 argument(s), got 1"
                (trap-message (wf "WASM-CALL1" w "add" 1))))
    (is (search "no exported function"
                (trap-message (wf "WASM-CALL0" w "nope"))))))

(test wasm.trap-is-a-condition
  "README: wasm traps arrive as Lisp conditions. A failure means a trap was
swallowed, arrived untyped, or left the instance unusable."
  (with-wasm (w "fib.wat")
    (is (search "unreachable" (trap-message (wf "WASM-CALL0" w "boom"))))
    ;; the same instance answers afterwards
    (is (= 42 (wf "WASM-CALL2" w "add" 40 2)))))

;;; ---------------------------------------------------------------------------
;;; Fuel
;;; ---------------------------------------------------------------------------

(test wasm.fuel-exhaustion-traps-and-refuels
  "README and SECURITY.md: a runaway guest traps instead of hanging the
image. A failure here is a hang (fib 30 unmetered is seconds of
interpretation; a loop would be forever), or an instance that cannot be
topped up."
  (with-wasm (w "fib.wat" 1000)
    (is (= 1000 (wf "WASM-FUEL-LEFT" w)))
    (is (search "all fuel consumed"
                (trap-message (wf "WASM-CALL1" w "fib" 30))))
    (is (= 0 (wf "WASM-FUEL-LEFT" w)))
    (wf "WASM-REFUEL" w 100000000)
    (is (= 610 (wf "WASM-CALL1" w "fib" 15)))
    (is (< 0 (wf "WASM-FUEL-LEFT" w) 100000000))))

(test wasm.unmetered-fuel-api-is-a-condition
  "FUEL 0 runs unmetered, and says so when asked. A failure means the fuel
API answered a number for an instance that has no budget."
  (with-wasm (w "fib.wat" 0)
    (is (search "fuel metering is disabled" (trap-message (wf "WASM-FUEL-LEFT" w))))
    (is (search "fuel metering is disabled" (trap-message (wf "WASM-REFUEL" w 10))))))

;;; ---------------------------------------------------------------------------
;;; Linear memory
;;; ---------------------------------------------------------------------------

(test wasm.memory-roundtrip-and-bounds
  "README and SECURITY.md: bytes move in and out of the guest's memory,
bounds-checked. A failure of the first half means the guest and the host
disagree about what was written; of the second, that the host read or wrote
outside the guest's one page."
  (with-wasm (w "fib.wat")
    (wf "WASM-MEMORY-WRITE" w 0 (octets 1 2 3 4))
    (is (= 10 (wf "WASM-CALL2" w "sum_mem" 0 4)))
    (is (equalp (octets 1 2 3 4) (wf "WASM-MEMORY-READ" w 0 4)))
    (is (search "exceeds memory size 65536"
                (trap-message (wf "WASM-MEMORY-READ" w 65530 100))))
    (is (search "exceeds memory size 65536"
                (trap-message (wf "WASM-MEMORY-WRITE" w 65535 (octets 0 0)))))
    ;; offset + length overflows a machine word: refused, not wrapped
    (is (search "exceeds memory size 65536"
                (trap-message (wf "WASM-MEMORY-WRITE" w (1- (expt 2 64)) (octets 0)))))
    (is (search "exceeds memory size 65536"
                (trap-message (wf "WASM-MEMORY-READ" w (1- (expt 2 64)) 1))))
    ;; the refused writes changed nothing
    (is (equalp (octets 1 2 3 4) (wf "WASM-MEMORY-READ" w 0 4)))))

;;; ---------------------------------------------------------------------------
;;; Host functions: the guest calls into Lisp
;;; ---------------------------------------------------------------------------

(test wasm.host-callback-into-lisp
  "README: guest code calls straight into a Lisp closure. The closure runs
on the CALLING thread, inside the export call — which is why this needs no
foreign-thread support and runs on ECL. A failure means values were lost
or reordered, or the call left the thread."
  (with-wasm (g "guest.wat")
    (let* ((seen '())
           (threads '())
           (token (rulisp:callback
                   (lambda (x)
                     (push x seen)
                     (pushnew (bt:current-thread) threads)))))
      (unwind-protect
           (progn
             (wf "WASM-ON-NOTIFY" g token)
             (wf "WASM-CALL1" g "emit_squares" 5)
             (is (equal '(0 1 4 9 16) (reverse seen)))
             (is (equal (list (bt:current-thread)) threads)))
        (rulisp:unregister-callback token)))))

(test wasm.callback-condition-becomes-trap
  "README: a condition in the closure becomes a guest trap. The condition
is warned about, the guest stops at the first failing call, and the image
and the instance continue. A failure means the guest kept running after
its host function failed."
  (with-wasm (g "guest.wat")
    (let* ((calls 0)
           (warned '())
           (failing (rulisp:callback
                     (lambda (x) (incf calls) (error "closure refused ~D" x))))
           (working (rulisp:callback (lambda (x) (declare (ignore x)) (incf calls)))))
      (unwind-protect
           (progn
             (wf "WASM-ON-NOTIFY" g failing)
             (with-warnings-collected (warned)
               (is (search "lisp callback failed"
                           (trap-message (wf "WASM-CALL1" g "emit_squares" 3)))))
             (is (= 1 calls))
             (is (= 1 (length warned)))
             (is (search "closure refused 0" (first warned)))
             ;; the instance takes another callback and runs to the end
             (wf "WASM-ON-NOTIFY" g working)
             (wf "WASM-CALL1" g "emit_squares" 3)
             (is (= 4 calls)))
        (rulisp:unregister-callback failing)
        (rulisp:unregister-callback working)))))

(test wasm.no-callback-set-traps
  "host.notify is importable before any closure is set; calling it then is
a trap that names the fix. A failure means a guest reached a host function
with nothing behind it."
  (with-wasm (g "guest.wat")
    (is (search "call wasm-on-notify first"
                (trap-message (wf "WASM-CALL1" g "emit_squares" 3))))))

(test wasm.dead-token-traps
  "The instance holds two numbers, not the closure: unregistering the token
while the instance still has it is safe. A failure means a dead callback id
was called through."
  (with-wasm (g "guest.wat")
    (let* ((calls 0)
           (warned '())
           (token (rulisp:callback (lambda (x) (declare (ignore x)) (incf calls)))))
      (wf "WASM-ON-NOTIFY" g token)
      (is (eq t (rulisp:unregister-callback token)))
      (with-warnings-collected (warned)
        (is (search "lisp callback failed"
                    (trap-message (wf "WASM-CALL1" g "emit_squares" 2)))))
      (is (= 0 calls))
      (is (= 1 (length warned)))
      (is (search "no longer registered" (first warned))))))

;;; ---------------------------------------------------------------------------
;;; Lifetime and loading
;;; ---------------------------------------------------------------------------

(test wasm.freed-handle-is-refused
  "A freed instance is refused by the wrapper, before Rust is entered. A
failure means a call reached a dropped Store."
  (ensure-wasm)
  (let ((w (wf "MAKE-WASM" (wat "fib.wat") 0)))
    (is (= 5 (wf "WASM-CALL2" w "add" 2 3)))
    (is (eq t (rulisp:free w)))
    (signals rulisp:freed-handle-error (wf "WASM-CALL2" w "add" 2 3))
    (signals rulisp:freed-handle-error (wf "WASM-EXPORTS" w))))

(test wasm.missing-file-is-a-condition
  "A module that is not there is a condition from the constructor, in both
formats, and the next load works. A failure means a path error crossed the
boundary as anything but wasm:wasm-error."
  (ensure-wasm)
  (flet ((missing (type)
           (uiop:native-namestring
            (merge-pathnames (format nil "rulisp-wasm-missing-~A.~A"
                                     rulisp::*process-tag* type)
                             (uiop:temporary-directory)))))
    (is (search "rulisp-wasm-missing"
                (trap-message (wf "MAKE-WASM" (missing "wat") 0))))
    (is (search "os error"
                (trap-message (wf "MAKE-WASM" (missing "wasm") 0)))))
  (with-wasm (w "fib.wat")
    (is (= 5 (wf "WASM-CALL2" w "add" 2 3)))))

;;; ===========================================================================
;;; The WASI sandbox (v0.7 item 7): a command module runs once under a fuel
;;; budget and one memory number, with stdio as bytes and the preopened
;;; directories as its whole filesystem. The guests are hand-written .wat
;;; (examples/wasm/wasi-*.wat, tests/wasm-guests/wasi-*.wat); each test
;;; states what a failure would mean, because the failure modes are a
;;; wedged image, an escaped sandbox, or unbounded host memory — not wrong
;;; return values.
;;;
;;; WASI preview1 errno numbers the guests hand back as exit codes:
;;;   8 EBADF, 44 ENOENT, 51 ENOSPC, 58 ENOTSUP, 63 EPERM.
;;; ===========================================================================

(defun wasi-guest (file)
  "The native path of a committed guest: the documented ones live next to
the example, the test-only ones under tests/wasm-guests/."
  (let ((example (asdf:system-relative-pathname
                  :rulisp (format nil "../examples/wasm/~A" file)))
        (fixture (asdf:system-relative-pathname
                  :rulisp (format nil "../tests/wasm-guests/~A" file))))
    (uiop:native-namestring (if (probe-file example) example fixture))))

(defmacro with-wasi ((var file &key (fuel 1000000) (limit 1048576)) &body body)
  "VAR is a fresh sandbox around the guest FILE, freed on the way out."
  `(progn
     (ensure-wasm)
     (let ((,var (wf "MAKE-WASI" (wasi-guest ,file) ,fuel ,limit)))
       (unwind-protect (progn ,@body)
         (rulisp:free ,var)))))

(defun host-dir (dir)
  "What the Rust side opens: the native namestring without its trailing
separator (the one shape cap-std warns about on Windows)."
  (string-right-trim "/\\" (uiop:native-namestring dir)))

(defun write-text-file (path string)
  "STRING as ASCII octets, LF and all: a character stream on Windows could
write CRLF, and the guests compare bytes."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :element-type '(unsigned-byte 8))
    (write-sequence (map '(vector (unsigned-byte 8)) #'char-code string) out)))

(defun ascii (octets)
  (map 'string #'code-char octets))

(defmacro with-wasi-world ((sandbox root) &body body)
  "A per-process scratch tree under the temporary directory:
ROOT/sandbox/secret.txt (\"inside\"), ROOT/sandbox/sub/ and, OUTSIDE the
sandbox, ROOT/outside.txt (\"OUTSIDE\"). Deleted afterwards — through
UIOP's validated tree delete, which never follows a symlink."
  `(let* ((,root (uiop:subpathname (uiop:temporary-directory)
                                   (format nil "rulisp-wasi-~A/" rulisp::*process-tag*)))
          (,sandbox (uiop:subpathname ,root "sandbox/")))
     (declare (ignorable ,root ,sandbox))
     (ensure-directories-exist (uiop:subpathname ,sandbox "sub/"))
     (write-text-file (uiop:subpathname ,sandbox "secret.txt") (format nil "inside~%"))
     (write-text-file (uiop:subpathname ,root "outside.txt") (format nil "OUTSIDE~%"))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree
        ,root
        :validate (lambda (p) (uiop:subpathp p (uiop:temporary-directory)))
        :if-does-not-exist :ignore))))

(defun read-through-sandbox (sandbox guest-path &key (preopen-dir sandbox))
  "Run the readlink guest: open GUEST-PATH under the preopen and copy it to
stdout. Returns (values exit-code stdout-string)."
  (with-wasi (w "wasi-readlink.wat")
    (wf "WASI-PREOPEN" w (host-dir preopen-dir) "/")
    (wf "WASI-ARG" w "guest")
    (wf "WASI-ARG" w guest-path)
    (values (wf "WASI-RUN" w) (ascii (wf "WASI-STDOUT" w)))))

(defun symlink (target link)
  "ln -s TARGET LINK, TARGET verbatim (a relative target stays relative).
No portable CL API exists; the callers skip themselves on Windows."
  (uiop:run-program (list "ln" "-s" target (host-dir link))))

(defun seconds-of (thunk)
  (let ((t0 (get-internal-real-time)))
    (funcall thunk)
    (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))

(test wasm.wasi-stdout-args-exit
  "The documented run: arguments arrive, stdout is captured, a file inside
the preopen is read, the escape attempt fails with one errno byte on
stderr, and proc_exit(7) is a VALUE. A failure means the sandbox lost one
of the five things it hands a guest."
  (with-wasi-world (sandbox root)
    (with-wasi (w "wasi-hello.wat")
      (wf "WASI-ARG" w "guest")
      (wf "WASI-ARG" w "alpha")
      (wf "WASI-ARG" w "beta")
      (wf "WASI-PREOPEN" w (host-dir sandbox) "/")
      (is (= 7 (wf "WASI-RUN" w)))
      (is (string= (format nil "hello from wasi~%guest~Calpha~Cbeta~Cinside~%"
                           (code-char 0) (code-char 0) (code-char 0))
                   (ascii (wf "WASI-STDOUT" w))))
      (let ((err (wf "WASI-STDERR" w)))
        (is (= 1 (length err)) "stderr is not the one errno byte: ~S" err)
        (is (= 63 (aref err 0)) "the escape was not refused with EPERM: ~S" err))
      (is (< (wf "WASI-FUEL-LEFT" w) 1000000)))))

(test wasm.wasi-env
  "The environment is what wasi-env gave and nothing else. A failure means
the process environment leaked in, or a variable was lost."
  (with-wasi (w "wasi-env.wat")
    (wf "WASI-ENV" w "HOME" "/nowhere")
    (wf "WASI-ENV" w "EMPTY" "")
    (wf "WASI-ENV" w "K" "a=b")
    (is (= 0 (wf "WASI-RUN" w)))
    (is (string= (format nil "HOME=/nowhere~CEMPTY=~CK=a=b~C"
                         (code-char 0) (code-char 0) (code-char 0))
                 (ascii (wf "WASI-STDOUT" w)))))
  (with-wasi (w "wasi-env.wat")
    (is (= 0 (wf "WASI-RUN" w)))
    (is (= 0 (length (wf "WASI-STDOUT" w))) "an environment the caller never set")))

(test wasm.wasi-stdin-roundtrip
  "stdin is exactly the bytes given, then EOF; the cat guest copies it in
4 KiB reads. A failure means bytes were altered, lost, or the guest never
saw EOF (which would be a fuel trap, not a hang)."
  (flet ((cat (bytes)
           (with-wasi (w "wasi-cat.wat")
             (wf "WASI-STDIN" w bytes)
             (is (= 0 (wf "WASI-RUN" w)))
             (is (equalp bytes (wf "WASI-STDOUT" w))
                 "~D bytes in, ~D out" (length bytes) (length (wf "WASI-STDOUT" w))))))
    (cat (octets))
    (cat (octets 97 98 0 255 99))
    (let ((big (make-array 10000 :element-type '(unsigned-byte 8))))
      (dotimes (i 10000) (setf (aref big i) (mod (* i 7) 256)))
      (cat big))))

(test wasm.wasi-preopen-reads-inside
  "A file inside the preopen is readable, through `..` that stays inside
too, and a missing one is ENOENT. A failure means the capability is not
usable — the escape tests would then pass for the wrong reason."
  (with-wasi-world (sandbox root)
    (multiple-value-bind (code out) (read-through-sandbox sandbox "secret.txt")
      (is (= 0 code)) (is (string= (format nil "inside~%") out)))
    (multiple-value-bind (code out) (read-through-sandbox sandbox "sub/../secret.txt")
      (is (= 0 code)) (is (string= (format nil "inside~%") out)))
    (multiple-value-bind (code out) (read-through-sandbox sandbox "missing.txt")
      (is (= 44 code) "a missing file was not ENOENT but ~D" code)
      (is (string= "" out)))))

(test wasm.wasi-escape-is-refused
  "The preopen is the guest's whole filesystem: `..` past its root, an
absolute host path, and `..` through a subdirectory all fail with EPERM
and read nothing. A failure means the sandbox is a suggestion."
  (with-wasi-world (sandbox root)
    (dolist (path (list "../outside.txt"
                        (uiop:native-namestring (uiop:subpathname root "outside.txt"))
                        "sub/../../outside.txt"))
      (multiple-value-bind (code out) (read-through-sandbox sandbox path)
        (is (= 63 code) "~S was not refused with EPERM but ~D" path code)
        (is (string= "" out) "~S leaked ~S" path out)))))

(test wasm.wasi-symlink-out-of-the-preopen-is-refused
  "Symlinks inside the preopen that point outside it — to a file, to a
directory, or by an absolute path even when that path lands inside — are
refused with EPERM; a relative link that stays inside works; and a preopen
that is itself a symlink to a directory behaves like the directory. A
failure means a guest can read the host through a link it did not make."
  (if (uiop:os-windows-p)
      (pass "skipped: symlinks need privileges on Windows; the `..` escape is tested above")
      (with-wasi-world (sandbox root)
        (symlink "../outside.txt" (uiop:subpathname sandbox "escape-file"))
        (symlink "../" (uiop:subpathname sandbox "escape-dir"))
        (symlink "secret.txt" (uiop:subpathname sandbox "link-in"))
        (symlink (uiop:native-namestring (uiop:subpathname sandbox "secret.txt"))
                 (uiop:subpathname sandbox "abs-in"))
        (symlink "sandbox" (uiop:subpathname root "link-to-sandbox"))
        (flet ((refused (path)
                 (multiple-value-bind (code out) (read-through-sandbox sandbox path)
                   (is (= 63 code) "~S was not refused with EPERM but ~D" path code)
                   (is (string= "" out) "~S leaked ~S" path out))))
          (refused "escape-file")
          (refused "escape-dir/outside.txt")
          (refused "abs-in")
          (multiple-value-bind (code out) (read-through-sandbox sandbox "link-in")
            (is (= 0 code)) (is (string= (format nil "inside~%") out)))
          (let ((via-link (uiop:subpathname root "link-to-sandbox/")))
            (multiple-value-bind (code out)
                (read-through-sandbox sandbox "secret.txt" :preopen-dir via-link)
              (is (= 0 code)) (is (string= (format nil "inside~%") out)))
            (multiple-value-bind (code out)
                (read-through-sandbox sandbox "../outside.txt" :preopen-dir via-link)
              (is (= 63 code)) (is (string= "" out))))))))

(test wasm.wasi-no-preopen-is-ebadf
  "With nothing preopened, fd 3 does not exist: EBADF, not a host
directory. A failure means a guest gets a filesystem it was not given."
  (with-wasi (w "wasi-nofs.wat")
    (is (= 8 (wf "WASI-RUN" w)))))

(test wasm.wasi-memory-limit-refuses-and-grow-answers-minus-one
  "The memory number is enforced three times: a module whose initial
memory exceeds it is refused at make-wasi, so is one whose table would
(200,000 funcrefs are 1.6 MB of host memory; the table is bounded by the
number / 8), and memory.grow past it answers -1 (no trap) — 16 pages
under 1 MiB, 32 under 2 MiB. A failure means the guest can take host
memory beyond the number."
  (ensure-wasm)
  (is (search "resource limiter"
              (trap-message (wf "MAKE-WASI" (wasi-guest "wasi-bigmem.wat") 1000000 1048576))))
  (with-wasi (w "wasi-bigmem.wat" :limit (* 100 65536))
    (is (= 0 (wf "WASI-RUN" w))))
  (is (search "table"
              (trap-message (wf "MAKE-WASI" (wasi-guest "wasi-bigtable.wat") 1000000 1048576))))
  (with-wasi (w "wasi-bigtable.wat" :limit 2097152)
    (is (= 0 (wf "WASI-RUN" w))))
  (with-wasi (w "wasi-grow.wat" :limit 1048576)
    (is (= 0 (wf "WASI-RUN" w)))
    (is (string= (format nil "16~%") (ascii (wf "WASI-STDOUT" w)))))
  (with-wasi (w "wasi-grow.wat" :limit 2097152)
    (is (= 0 (wf "WASI-RUN" w)))
    (is (string= (format nil "32~%") (ascii (wf "WASI-STDOUT" w))))))

(test wasm.wasi-output-past-the-cap-fails-in-the-guest
  "Output shares the memory number: a guest flooding stdout gets ENOSPC
from fd_write once the cap is reached, with exactly the cap kept, and its
fuel is not what ended it. Measured without the cap: 5 M fuel bought
101 GiB of output. A failure means a guest can take host memory through
its output."
  (with-wasi (w "wasi-flood.wat" :fuel 10000000 :limit 1048576)
    (is (= 51 (wf "WASI-RUN" w)))
    (is (= 1048576 (length (wf "WASI-STDOUT" w))))
    (is (= 0 (length (wf "WASI-STDERR" w))))
    (is (< 0 (wf "WASI-FUEL-LEFT" w)))))

(test wasm.wasi-unmetered-is-refused
  "make-wasi refuses what it cannot bound or run: fuel 0 (the run is
synchronous; only fuel makes it finite), a module without _start, and a
missing file. A failure means an unbounded sandbox can be made."
  (ensure-wasm)
  (is (search "fuel" (trap-message (wf "MAKE-WASI" (wasi-guest "wasi-spin.wat") 0 1048576))))
  (is (search "_start" (trap-message (wf "MAKE-WASI" (wat "fib.wat") 1000000 1048576))))
  (is (search "no-such-guest"
              (trap-message (wf "MAKE-WASI" (wasi-guest "no-such-guest.wat") 1000000 1048576)))))

(test wasm.wasi-fuel-exhaustion-is-a-condition
  "A guest that never returns ends when its fuel does: a condition, fuel
0, promptly. A failure here is a hang of the calling thread."
  (with-wasi (w "wasi-spin.wat" :fuel 1000000)
    (let (message)
      (is (< (seconds-of (lambda () (setf message (trap-message (wf "WASI-RUN" w))))) 10)
          "1 M fuel of a tight loop took more than ten seconds")
      (is (search "all fuel consumed" message)))
    ;; wasmi charges fuel per basic block: what is left is less than one
    (is (< (wf "WASI-FUEL-LEFT" w) 16) "fuel was not what ended the run")))

(test wasm.wasi-waiting-is-refused
  "poll_oneoff with a 2-second clock subscription — what WASI's sleep is —
answers ENOTSUP at once instead of blocking the calling thread for a
guest-chosen time at zero fuel. A failure is a thread the image cannot
interrupt, for as long as the guest likes."
  (with-wasi (w "wasi-sleep.wat")
    (let (code)
      (is (< (seconds-of (lambda () (setf code (wf "WASI-RUN" w)))) 1)
          "the guest's 2-second sleep was honoured")
      (is (= 58 code) "poll_oneoff did not answer ENOTSUP but ~D" code))))

(test wasm.wasi-run-is-once
  "An instance runs _start once: a second run, and configuring after the
run, are conditions. A failure means a spent instance — its globals and
memory as the first run left them — can be re-entered."
  (with-wasi (w "wasi-hello.wat")
    (is (= 7 (wf "WASI-RUN" w)))
    (is (search "once" (trap-message (wf "WASI-RUN" w))))
    (is (search "already run" (trap-message (wf "WASI-ARG" w "late"))))
    (is (search "already run" (trap-message (wf "WASI-STDIN" w (octets 1)))))
    ;; what the first run produced is still readable
    (is (search "hello from wasi" (ascii (wf "WASI-STDOUT" w))))))

(test wasm.wasi-exit-code-range
  "proc_exit(N) is a value for 0..125; WASI refuses larger codes as a
trap, which arrives as a condition. A failure means an exit code was
lost, or an invalid one was invented."
  (with-wasi (w "wasi-exit125.wat")
    (is (= 125 (wf "WASI-RUN" w))))
  (with-wasi (w "wasi-exit126.wat")
    (is (search "invalid exit status" (trap-message (wf "WASI-RUN" w))))))

(test wasm.wasi-load-refusals
  "What is refused before a guest runs: an import the sandbox does not
provide (at make-wasi), a (start) section that spins — it runs at
instantiation, inside make-wasi, under the fuel — and a preopen that is
not a directory. A failure means a guest got past the door with something
the sandbox never gave it, or the (start) section is a way around fuel."
  (ensure-wasm)
  (is (search "cannot find definition for import"
              (trap-message (wf "MAKE-WASI" (wasi-guest "wasi-unknown-import.wat") 1000000 1048576))))
  (is (search "all fuel consumed"
              (trap-message (wf "MAKE-WASI" (wasi-guest "wasi-start-spins.wat") 10000 1048576))))
  (with-wasi-world (sandbox root)
    (with-wasi (w "wasi-hello.wat")
      (is (search "cannot open"
                  (trap-message (wf "WASI-PREOPEN" w
                                    (uiop:native-namestring (uiop:subpathname sandbox "secret.txt"))
                                    "/"))))
      (is (search "cannot open"
                  (trap-message (wf "WASI-PREOPEN" w (host-dir (uiop:subpathname root "missing/")) "/")))))))

(test wasm.wasi-handle-is-typed
  "A wasm:wasm instance is not a wasm:wasi: the generated wrapper refuses
it before Rust is entered. A failure means a pointer of one handle class
reached the other's shims."
  (with-wasm (m "fib.wat")
    (signals rulisp:invalid-argument (wf "WASI-RUN" m))
    (signals rulisp:invalid-argument (wf "WASI-STDOUT" m))))
