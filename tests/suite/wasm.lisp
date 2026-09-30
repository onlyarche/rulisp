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
