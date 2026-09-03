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

(defun fuzz-seed ()
  "RULISP_FUZZ_SEED overrides the default. Every fuzzer failure message
carries the seed in use, so a CI failure reproduces locally; the CI
workflow exposes it as a workflow_dispatch input."
  (let ((env (uiop:getenv "RULISP_FUZZ_SEED")))
    (or (and env (plusp (length env)) (parse-integer env :junk-allowed t)) 42)))

(defstruct (gen-counters (:constructor %make-gen-counters (bags allocs bags0 allocs0)))
  "The current generation's live-object counters, CAPTURED as wrapper
closures: after a reload the symbol names point at a fresh library copy
whose statics start at zero, but a captured wrapper keeps calling into
its own generation (BOUNDARY §9), so each generation reconciles against
itself."
  bags allocs bags0 allocs0)

(defun capture-gen-counters (&key fresh)
  "FRESH: the generation was just loaded — a new library copy whose
statics start at zero by construction — so the baseline is 0/0 rather
than a snapshot, which could include other threads' in-flight work."
  (let ((bags (symbol-function (wb "TEST-LIVE-WORD-BAGS")))
        (allocs (symbol-function (wb "TEST-LIVE-ALLOCATIONS"))))
    (if fresh
        (%make-gen-counters bags allocs 0 0)
        (%make-gen-counters bags allocs (funcall bags) (funcall allocs)))))

(defun reconcile-generations (gens seed)
  "Bounded GC loop, then every generation must be back at its starting
live-bag count (CCL's conservative stack may pin a straggler: slack) and
EXACTLY its starting allocation count — a leaked in-flight count, a free
that never reached Rust, or a buffer released through the wrong
generation's dealloc all fail here."
  (let ((slack #+sbcl 0 #-sbcl 2))
    (loop repeat 100
          until (every (lambda (g) (<= (funcall (gen-counters-bags g))
                                       (+ (gen-counters-bags0 g) slack)))
                       gens)
          do (tg:gc :full t) (sleep 0.05))
    (loop for g in gens for i from 0
          do (is (<= (funcall (gen-counters-bags g)) (+ (gen-counters-bags0 g) slack))
                 "generation ~D: ~D live bags remain above the ~D at start (seed ~D)"
                 i (funcall (gen-counters-bags g)) (gen-counters-bags0 g) seed)
             (is (= (funcall (gen-counters-allocs g)) (gen-counters-allocs0 g))
                 "generation ~D: ~D live Rust allocations, expected ~D (seed ~D)"
                 i (funcall (gen-counters-allocs g)) (gen-counters-allocs0 g) seed))))

(test m4h.thread-race
  "8 threads x 10k ops over a shared handle pool, mixing methods, free and
GC: zero crashes, only the expected conditions (freed handles signal
FREED-HANDLE-ERROR; nothing else may escape)."
  (ensure-crate)
  (let* ((seed (fuzz-seed))
         (gen (capture-gen-counters))
         (pool-size 16)
         (pool (make-array pool-size))
         (unexpected '())
         (ulock (bt:make-lock "m4-unexpected")))
    (dotimes (i pool-size)
      (setf (aref pool i) (make-bag "w")))
    (flet ((worker (tid)
             (lambda ()
               (let ((rnd (make-lcg (+ seed 1000 tid))))
                 (dotimes (i 10000)
                   (let ((bag (aref pool (funcall rnd pool-size))))
                     (handler-case
                         (ecase (funcall rnd 6)
                           (0 (wb-call "WORD-BAG-LEN" bag))
                           (1 (wb-call "WORD-BAG-ADD" bag "x"))
                           (2 (rulisp:free bag))
                           (3 (wb-call "WORD-BAG-SLOW-LEN" bag 0))
                           (4 (when (zerop (funcall rnd 200))
                                (tg:gc)))
                           ;; a Rust->Lisp allocation under contention: its
                           ;; dealloc must pair exactly (reconciled below)
                           (5 (wb-call "GREET" "x")))
                       (rulisp:freed-handle-error () nil)
                       (error (e)
                         (bt:with-lock-held (ulock)
                           (push e unexpected))))))))))
      (mapc #'bt:join-thread
            (loop for tid below 8
                  collect (bt:make-thread (worker tid)
                                          :name (format nil "m4-race-~D" tid)))))
    (is (null unexpected) "unexpected conditions (seed ~D): ~S" seed unexpected)
    ;; the image is alive and the crate still works
    (is (= 3 (wb-call "ADD" 1 2)))
    (loop for bag across pool do (rulisp:free bag))
    (reconcile-generations (list gen) seed)))

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
  (let* ((seed (fuzz-seed))
         (rnd (make-lcg seed))
         (gens (list (capture-gen-counters)))
         (live '())
         (graveyard '())
         (unexpected '()))
    (dotimes (i 10000)
      (handler-case
          (progn
            (when (member i '(3333 6666))       ; sprinkle live reloads
              (rulisp:reload-crate "wordbag")   ; older bags turn stale below
              (push (capture-gen-counters :fresh t) gens))
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
    (is (null unexpected) "unexpected conditions (seed ~D): ~S" seed unexpected)
    (is (= 3 (wb-call "ADD" 1 2)))
    ;; stale bags are still freed — through their birth generation's shim
    (mapc #'rulisp:free live)
    (reconcile-generations (reverse gens) seed)))

(test m4h.reload-under-load
  "Threads round-tripping strings while the crate reloads underneath them:
a call that began in generation N finishes with generation N's immutable
context, so its buffer is released through generation N's dealloc even
though the symbol now names generation N+1 (BOUNDARY §4). Every
generation's allocation counter must return to zero."
  (ensure-crate)
  (let* ((seed (fuzz-seed))
         (gens (list (capture-gen-counters)))
         (stop nil)
         (calls 0)
         (clock (bt:make-lock "m4-reload-calls"))
         (unexpected '())
         (ulock (bt:make-lock "m4-reload-unexpected"))
         (threads
           (loop for tid below 4
                 collect (bt:make-thread
                          (let ((tid tid))
                            (lambda ()
                              (let ((rnd (make-lcg (+ seed 7 tid))) (n 0))
                                (loop until stop
                                      do (handler-case
                                             (progn
                                               (if (zerop (funcall rnd 2))
                                                   (wb-call "GREET" "load")
                                                   (wb-call "ECHO" "round trip"))
                                               (incf n))
                                           (error (e)
                                             (bt:with-lock-held (ulock)
                                               (push e unexpected)))))
                                (bt:with-lock-held (clock) (incf calls n)))))
                          :name (format nil "m4-reload-load-~D" tid)))))
    (dotimes (k 3)
      (sleep 0.15)
      (rulisp:reload-crate "wordbag")
      (push (capture-gen-counters :fresh t) gens))
    (sleep 0.15)
    (setf stop t)
    (mapc #'bt:join-thread threads)
    (is (null unexpected) "unexpected conditions (seed ~D): ~S" seed unexpected)
    (is (> calls 100) "only ~D calls completed during the reloads" calls)
    (is (= 4 (length gens)))
    (reconcile-generations (reverse gens) seed)))
