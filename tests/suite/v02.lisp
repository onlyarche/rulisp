;;; v0.2 feature suite: the :bytes type (ROADMAP.md §1).
;;; Wire-additive on ABI 1 — same (ptr,len) + universal-dealloc convention
;;; as :string, no UTF-8 validation. Runs against whatever crate the run
;;; script selected (oracle or macro twin — both export sum/rev).

(in-package #:rulisp/test)

(def-suite* :rulisp-v02)

(test v02.bytes-in
  (ensure-crate)
  (is (= 6 (wb-call "SUM" #(1 2 3))))
  (is (= 0 (wb-call "SUM" #())))
  (is (= 510 (wb-call "SUM" #(255 255))))
  ;; any octet sequence is accepted (coerced)
  (is (= 6 (wb-call "SUM" '(1 2 3))))
  (is (= 6 (wb-call "SUM" (make-array 3 :element-type '(unsigned-byte 8)
                                        :initial-contents '(1 2 3))))))

(test v02.bytes-roundtrip
  (ensure-crate)
  (let ((r (wb-call "REV" #(1 2 3))))
    (is (typep r '(simple-array (unsigned-byte 8) (*))))
    (is (equalp #(3 2 1) r)))
  ;; extremes and emptiness (the no-allocation transfer path)
  (is (equalp #(255 0) (wb-call "REV" #(0 255))))
  (is (equalp #() (wb-call "REV" #())))
  ;; a larger buffer survives the double round trip bit-exactly
  (let ((big (make-array 65536 :element-type '(unsigned-byte 8))))
    (dotimes (i 65536) (setf (aref big i) (mod i 256)))
    (is (equalp big (wb-call "REV" (wb-call "REV" big))))))

(test v02.bytes-alloc-pairing
  (ensure-crate)
  (let ((before (live-allocs)))
    (dotimes (i 100)
      (wb-call "REV" #(1 2 3))
      (wb-call "REV" #()))
    (is (= before (live-allocs)))))

(test v02.bytes-bad-input
  (ensure-crate)
  (signals rulisp:invalid-argument (wb-call "SUM" '(1 300)))
  (signals rulisp:invalid-argument (wb-call "SUM" "abc"))
  (signals rulisp:invalid-argument (wb-call "SUM" '(:a :b))))

;;; ---------------------------------------------------------------------------
;;; Stored callbacks (ROADMAP.md §2): Rust keeps a registered closure and
;;; invokes it after the registering call returned — same thread or a fresh
;;; Rust thread. Dead ids fail safely; conditions are warned, not crashed.
;;; ---------------------------------------------------------------------------

(test v02.stored-callback-basic
  (ensure-crate)
  (let* ((seen '())
         (token (rulisp:callback (lambda (x) (push x seen)))))
    (wb-call "SET-NOTIFIER" token)
    ;; the registering call has RETURNED; Rust still owns the callback
    (wb-call "NOTIFY" 7)
    (wb-call "NOTIFY" 42)
    (is (equal '(42 7) seen))
    (wb-call "CLEAR-NOTIFIER")
    (is (eq t (rulisp:unregister-callback token)))
    (is (eq nil (rulisp:unregister-callback token)))))

(test v02.stored-callback-cross-thread
  "The callback runs on a fresh Rust-spawned thread (adopted by the Lisp on
entry); the shim joins it, so the effect is visible on return."
  (ensure-crate)
  (let* ((seen '())
         (lock (bt:make-lock))
         (token (rulisp:callback
                 (lambda (x) (bt:with-lock-held (lock) (push x seen))))))
    (wb-call "SET-NOTIFIER" token)
    (dotimes (i 5)
      (wb-call "NOTIFY-FROM-THREAD" (* i 11)))
    (is (equal '(44 33 22 11 0) seen))
    (wb-call "CLEAR-NOTIFIER")
    (rulisp:unregister-callback token)))

(test v02.stored-callback-dead-id
  "Unregistering while Rust still holds the callback is SAFE: invocation
warns and surfaces as a plain rust-error — never UB, never a crash."
  (ensure-crate)
  (let ((token (rulisp:callback (lambda (x) (declare (ignore x))))))
    (wb-call "SET-NOTIFIER" token)
    (rulisp:unregister-callback token)
    (let ((warned nil))
      (handler-bind ((warning (lambda (w)
                                (setf warned (princ-to-string w))
                                (muffle-warning w))))
        (signals rulisp:rust-error (wb-call "NOTIFY" 1)))
      (is (search "no longer registered" warned)))
    (wb-call "CLEAR-NOTIFIER")))

(test v02.stored-callback-condition
  "A condition inside a stored callback is warned and reported as an error
status — there may be no Lisp frame to re-signal into."
  (ensure-crate)
  (let ((token (rulisp:callback (lambda (x) (declare (ignore x))
                                  (error "stored boom")))))
    (wb-call "SET-NOTIFIER" token)
    (let ((warned nil))
      (handler-bind ((warning (lambda (w)
                                (setf warned (princ-to-string w))
                                (muffle-warning w))))
        (let ((c (handler-case (progn (wb-call "NOTIFY" 1) nil)
                   (rulisp:rust-error (e) e))))
          (is (search "stored callback failed" (rulisp:rust-error-message c)))))
      (is (search "stored boom" warned)))
    (wb-call "CLEAR-NOTIFIER")
    (rulisp:unregister-callback token)))

(test v02.stored-callback-no-notifier
  (ensure-crate)
  (wb-call "CLEAR-NOTIFIER")
  (let ((c (handler-case (progn (wb-call "NOTIFY" 1) nil)
             (rulisp:rust-error (e) e))))
    (is (search "no notifier registered" (rulisp:rust-error-message c)))))

(test v02.stored-callback-token-type-check
  (ensure-crate)
  (signals rulisp:invalid-argument
    (wb-call "SET-NOTIFIER" (lambda (x) x))))
