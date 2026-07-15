;;; M4 hardening suite (DESIGN.md §8 M4): (a) 8-thread race over shared
;;; handles, (b) nested callbacks, (c) random op sequence with reloads.
;;; ((d) — M1 items 6-7 on the macro pipeline — is the fact that run-m3/m4
;;; execute the unchanged M1 suite, incl. reload and dump/restore, against
;;; examples/wordbag.)

(in-package #:rulisp/test)

(def-suite* :rulisp-m4)

(defun make-lcg (seed)
  "Deterministic per-thread PRNG: tests must reproduce."
  (let ((s seed))
    (lambda (n)
      (setf s (mod (+ (* s 1103515245) 12345) (expt 2 31)))
      (mod s n))))

(test m4h.thread-race
  "8 threads x 10k ops over a shared handle pool, mixing methods, free and
GC: zero crashes, only the expected conditions (freed handles signal
FREED-HANDLE-ERROR; nothing else may escape)."
  (ensure-crate)
  (let* ((pool-size 16)
         (pool (make-array pool-size))
         (unexpected '())
         (ulock (bt:make-lock "m4-unexpected")))
    (dotimes (i pool-size)
      (setf (aref pool i) (make-bag "w")))
    (flet ((worker (tid)
             (lambda ()
               (let ((rnd (make-lcg (+ 1000 tid))))
                 (dotimes (i 10000)
                   (let ((bag (aref pool (funcall rnd pool-size))))
                     (handler-case
                         (ecase (funcall rnd 5)
                           (0 (wb-call "WORD-BAG-LEN" bag))
                           (1 (wb-call "WORD-BAG-ADD" bag "x"))
                           (2 (rulisp:free bag))
                           (3 (wb-call "WORD-BAG-SLOW-LEN" bag 0))
                           (4 (when (zerop (funcall rnd 200))
                                (tg:gc))))
                       (rulisp:freed-handle-error () nil)
                       (error (e)
                         (bt:with-lock-held (ulock)
                           (push e unexpected))))))))))
      (mapc #'bt:join-thread
            (loop for tid below 8
                  collect (bt:make-thread (worker tid)
                                          :name (format nil "m4-race-~D" tid)))))
    (is (null unexpected) "unexpected conditions: ~S" unexpected)
    ;; the image is alive and the crate still works
    (is (= 3 (wb-call "ADD" 1 2)))
    (loop for bag across pool do (rulisp:free bag))))

(test m4h.nested-callbacks
  "A callback body invoking another callback-taking export: both stash
bindings nest via dynamic binding, and a condition signaled at the deepest
level re-signals as the SAME object at the top."
  (ensure-crate)
  (let ((outer (make-bag "a" "b"))
        (inner (make-bag "x" "y" "z"))
        (seen '()))
    (is (= 2 (wb-call "FOR-EACH-WORD" outer
                      (lambda (ow)
                        (wb-call "FOR-EACH-WORD" inner
                                 (lambda (iw) (push (cons ow iw) seen)))))))
    (is (= 6 (length seen)))
    (let* ((c (make-condition 'simple-error :format-control "deep boom"))
           (caught (handler-case
                       (progn
                         (wb-call "FOR-EACH-WORD" outer
                                  (lambda (ow)
                                    (declare (ignore ow))
                                    (wb-call "FOR-EACH-WORD" inner
                                             (lambda (iw)
                                               (declare (ignore iw))
                                               (error c)))))
                         nil)
                     (error (e) e))))
      (is (eq c caught)))
    (rulisp:free outer)
    (rulisp:free inner)))

(test m4h.random-op-sequence
  "10k deterministic random ops mixing handle creation, use, free,
use-after-free, GC and live reloads: the image survives and only the named
conditions appear."
  (ensure-crate)
  (let ((rnd (make-lcg 42))
        (live '())
        (graveyard '())
        (unexpected '()))
    (dotimes (i 10000)
      (handler-case
          (progn
            (when (member i '(3333 6666))       ; sprinkle live reloads
              (rulisp:reload-crate "wordbag"))  ; older bags turn stale below
            (case (funcall rnd 10)
              ((0 1) (push (make-bag "w") live))
              ((2 3 4) (when live
                         (wb-call "WORD-BAG-LEN"
                                  (nth (funcall rnd (length live)) live))))
              ((5) (when live
                     (let ((bag (pop live)))
                       (rulisp:free bag)
                       (push bag graveyard))))
              ((6) (when graveyard
                     (wb-call "WORD-BAG-LEN"
                              (nth (funcall rnd (length graveyard)) graveyard))))
              ((7) (when (zerop (funcall rnd 200))
                     (tg:gc :full t)))
              (t nil)))
        (rulisp:freed-handle-error () nil)
        (rulisp:stale-handle-error () nil)
        (error (e) (push e unexpected))))
    (is (null unexpected) "unexpected conditions: ~S" unexpected)
    (is (= 3 (wb-call "ADD" 1 2)))
    (mapc #'rulisp:free live)))
