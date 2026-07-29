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
