;;; Benchmark suite: <lisp> --load tests/bench.lisp
;;;
;;; Prints ns/call for the boundary paths that matter, so performance
;;; regressions are visible as features accumulate. Not a gate — numbers
;;; vary by machine — but the SHAPE should hold: scalars ~tens of ns,
;;; strings/bytes scaling with size, callbacks a small multiple of a call.

(require :asdf)

#-quicklisp
(let ((q (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file q) (load q)))

(let* ((here (uiop:pathname-directory-pathname *load-truename*))
       (root (uiop:pathname-parent-directory-pathname here)))
  (push (merge-pathnames "lisp/" root) asdf:*central-registry*))

(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:load-system :rulisp)

(defvar *crate*
  (rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/wordbag/")
                    :profile :release))

(defun wb (name) (symbol-function (or (find-symbol name "WORDBAG")
                                      (error "no ~A" name))))

(defmacro timed (label n &body body)
  "Run BODY N times, print ns/call."
  `(let ((start (get-internal-real-time)))
     (dotimes (i ,n) ,@body)
     (let* ((elapsed (/ (- (get-internal-real-time) start)
                        internal-time-units-per-second))
            (ns (/ (* elapsed 1d9) ,n)))
       (format t "~&~40A ~10,1F ns/call~%" ,label ns)
       ns)))

(defun bench-octets (n)
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n) (setf (aref v i) (mod i 256)))
    v))

(format t "~&;;; rulisp benchmarks — ~A ~A, release profile~%~%"
        (lisp-implementation-type) (lisp-implementation-version))

;; --- call overhead ---------------------------------------------------------
(let ((add (wb "ADD")))
  (timed "scalar call (add i64 i64)" 200000 (funcall add 1 2)))

(let ((f (wb "TEST-LIVE-WORD-BAGS")))
  (timed "scalar call, no args" 200000 (funcall f)))

;; --- handles ---------------------------------------------------------------
(let ((make (wb "MAKE-WORD-BAG")) (len (wb "WORD-BAG-LEN")))
  (let ((bag (funcall make)))
    (timed "handle method (gate + call)" 200000 (funcall len bag))
    (rulisp:free bag))
  (timed "handle create + free" 20000
         (rulisp:free (funcall make))))

;; --- strings ---------------------------------------------------------------
(let ((echo (wb "ECHO")))
  (dolist (size '(8 1024 65536))
    (let ((s (make-string size :initial-element #\a)))
      (timed (format nil "string round trip (~D B ASCII)" size) 20000
             (funcall echo s))))
  (let ((s (make-string 1024 :initial-element #\한)))
    (timed "string round trip (1 KiB non-ASCII)" 20000 (funcall echo s))))

;; --- rx: a real &str consumer (the quickstart crate) over 1 MiB ----------
;; Digits occur once, at the end: the regex side is a memchr sweep, so the
;; row is the :string boundary cost on a 1 MiB argument, not regex work.
(defvar *rx*
  (rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/rx/")
                    :profile :release))
(let* ((make (symbol-function (find-symbol "MAKE-REGEX" "RX")))
       (count (symbol-function (find-symbol "REGEX-COUNT" "RX")))
       (re (funcall make "[0-9]+"))
       (text (with-output-to-string (o)
               (dotimes (i 131071) (write-string "abc def " o))    ; 8 B x 131071
               (write-string "abc 123 " o))))                       ; = 1 MiB, one match
  (timed "rx count over 1 MiB (&str in, 1 match)" 200 (funcall count re text))
  (rulisp:free re))

;; --- bytes -----------------------------------------------------------------
(let ((rev (wb "REV")) (sum (wb "SUM")))
  (dolist (size '(8 1024 65536 1048576))
    (let ((v (bench-octets size)))
      (timed (format nil "bytes in (sum, ~D B)" size)
             (if (> size 65536) 2000 20000)
             (funcall sum v))
      (timed (format nil "bytes round trip (rev, ~D B)" size)
             (if (> size 65536) 2000 20000)
             (funcall rev v)))))

;; --- vectors ---------------------------------------------------------------
(let ((deltas (wb "DELTAS")))
  (dolist (size '(8 1024 65536))
    (let ((v (make-array size :element-type '(signed-byte 64))))
      (dotimes (i size) (setf (aref v i) i))
      (timed (format nil "vec i64 round trip (~D elts)" size)
             (if (> size 1024) 2000 20000)
             (funcall deltas v)))))

;; --- callbacks -------------------------------------------------------------
(let ((make (wb "MAKE-WORD-BAG")) (add (wb "WORD-BAG-ADD"))
      (each (wb "FOR-EACH-WORD")))
  (let ((bag (funcall make)))
    (dotimes (i 100) (funcall add bag "word"))
    (let ((n 2000))
      (let ((total (timed "borrowed callback (100 invocations)" n
                          (funcall each bag (lambda (w) (declare (ignore w)) nil)))))
        (format t "~40A ~10,1F ns/invocation~%" "  -> per callback invocation"
                (/ total 100))))
    (rulisp:free bag)))

(let ((set (wb "SET-NOTIFIER")) (notify (wb "NOTIFY")) (clear (wb "CLEAR-NOTIFIER"))
      (token (rulisp:callback (lambda (x) (declare (ignore x)) nil))))
  (funcall set token)
  (timed "stored callback (same thread)" 100000 (funcall notify 1))
  (funcall clear)
  (rulisp:unregister-callback token))

(format t "~%;;; done~%")
(uiop:quit 0)
