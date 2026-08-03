;;; v0.3 suite: bulk marshalling correctness (the pinned fast paths must be
;;; byte-identical to the element-wise ones they replaced) and the manifest
;;; invariants that keep generated bindings honest.

(in-package #:rulisp/test)

(def-suite* :rulisp-v03)

;;; ---------------------------------------------------------------------------
;;; Bulk :bytes / :vec marshalling — pinned vector + memcpy, with the
;;; element-wise path kept for inputs that cannot be pinned.
;;; ---------------------------------------------------------------------------

(test v03.pinning-probe
  "Whatever this host can pin, the probe must answer consistently and
without signalling (unsupported types simply fall back)."
  (dolist (ty '((unsigned-byte 8) (signed-byte 64) double-float single-float))
    (let ((a (rulisp::pinnable-p ty)))
      (is (eq a (rulisp::pinnable-p ty)) "probe is not stable for ~S" ty)
      (is (typep a 'boolean)))))

(test v03.bulk-bytes-identity
  "Large payloads must survive the memcpy path bit-exactly, including the
size classes that cross page boundaries."
  (ensure-crate)
  (dolist (size '(0 1 7 4096 65537 1048576))
    (let ((v (make-array size :element-type '(unsigned-byte 8))))
      (dotimes (i size) (setf (aref v i) (mod (* i 31) 256)))
      (is (equalp v (wb-call "REV" (wb-call "REV" v)))
          "byte round trip differs at size ~D" size)
      (is (= (reduce #'+ v) (wb-call "SUM" v))
          "sum differs at size ~D" size))))

(test v03.bulk-bytes-non-simple-input
  "A displaced or adjustable vector cannot be pinned; the fallback must
still produce the same answer."
  (ensure-crate)
  (let* ((backing (make-array 10 :element-type '(unsigned-byte 8)
                                 :initial-contents '(0 1 2 3 4 5 6 7 8 9)))
         (displaced (make-array 4 :element-type '(unsigned-byte 8)
                                  :displaced-to backing
                                  :displaced-index-offset 3))
         (adjustable (make-array 3 :element-type '(unsigned-byte 8)
                                   :adjustable t
                                   :initial-contents '(10 20 30))))
    (is (= (+ 3 4 5 6) (wb-call "SUM" displaced)))
    (is (equalp #(6 5 4 3) (wb-call "REV" displaced)))
    (is (= 60 (wb-call "SUM" adjustable)))
    (is (= 60 (wb-call "SUM" '(10 20 30))))))

(test v03.bulk-vec-identity
  (ensure-crate)
  (dolist (n '(0 1 2 1024 65537))
    (let ((v (make-array n :element-type '(signed-byte 64))))
      (dotimes (i n) (setf (aref v i) (- (* i 7) 100000)))
      (let ((d (wb-call "DELTAS" v)))
        (is (= (max 0 (1- n)) (length d)) "delta length wrong at ~D" n)
        (when (> n 1)
          (is (every (lambda (x) (= x 7)) d) "delta values wrong at ~D" n))))))

(test v03.bulk-vec-floats
  "The float (:vec ...) path had no end-to-end coverage before v0.3."
  (ensure-crate)
  (let ((v (make-array 5 :element-type 'double-float
                         :initial-contents '(0d0 1d0 -2.5d0 1d10 0.125d0))))
    (is (equalp (map '(simple-array double-float (*)) (lambda (x) (* x 2d0)) v)
                (wb-call "SCALE" v 2d0)))
    (is (equalp #() (wb-call "SCALE" (make-array 0 :element-type 'double-float) 3d0)))
    ;; non-specialized input takes the coercing fallback
    (is (equalp #(2d0 4d0) (wb-call "SCALE" '(1 2) 2d0)))))

(test v03.bulk-alloc-pairing
  "Bulk paths must still free exactly once."
  (ensure-crate)
  (let ((before (live-allocs))
        (v (make-array 4096 :element-type '(unsigned-byte 8))))
    (dotimes (i 20)
      (wb-call "REV" v)
      (wb-call "DELTAS" (make-array 512 :element-type '(signed-byte 64)))
      (wb-call "SCALE" (make-array 512 :element-type 'double-float) 1d0))
    (is (= before (live-allocs)))))

;;; ---------------------------------------------------------------------------
;;; Manifest invariants
;;; ---------------------------------------------------------------------------

(test v03.duplicate-lisp-name-rejected
  "Two exports mapping to one Lisp name would silently shadow each other in
COMMIT-BINDINGS — the manifest must refuse them. (The macro can emit this:
constructor names derive from the impl type, so two constructors on one
type both compute make-<type>.)"
  (signals rulisp:manifest-error
    (rulisp::parse-manifest
     "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"x_rulisp_\"
       :functions ((:fn :rust-name \"A::new\" :lisp-name \"make-a\" :symbol \"a_new\"
                    :params () :result :i64 :error nil)
                   (:fn :rust-name \"A::with_capacity\" :lisp-name \"make-a\" :symbol \"a_wc\"
                    :params () :result :i64 :error nil)))"))
  (signals rulisp:manifest-error
    (rulisp::parse-manifest
     "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"x_rulisp_\"
       :handles ((:handle :rust-name \"A\" :lisp-name \"thing\" :free \"a_free\")
                 (:handle :rust-name \"B\" :lisp-name \"thing\" :free \"b_free\")))"))
  ;; distinct names still parse
  (is (rulisp::parse-manifest
       "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"x_rulisp_\"
         :functions ((:fn :rust-name \"a\" :lisp-name \"a\" :symbol \"a\"
                      :params () :result :i64 :error nil)
                     (:fn :rust-name \"b\" :lisp-name \"b\" :symbol \"b\"
                      :params () :result :i64 :error nil)))")))
