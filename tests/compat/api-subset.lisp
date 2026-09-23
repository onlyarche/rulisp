;;; The Lisp surface across releases — docs/stability.md §1. Every entry of
;;; the previous release's tests/golden/lisp-api.sexp must appear, EQUAL
;;; (name, kind, superclasses, lambda list), in this tree's golden: an
;;; addition passes, a removal or a changed signature is named and fails.
;;; Run by `make compat` with RULISP_PREV_API and RULISP_API naming the two
;;; golden files. Both are read in one scratch package that uses CL, so the
;;; symbols compare by name and the CL ones (error, &key, ...) by identity.

(require :asdf)
(defpackage #:rulisp-api-compare (:use #:cl))

(defun read-golden (path)
  (with-open-file (in path)
    (let ((*package* (find-package :rulisp-api-compare)))
      (read in))))

(let* ((prev (read-golden (uiop:getenv "RULISP_PREV_API")))
       (now (read-golden (uiop:getenv "RULISP_API")))
       (missing (remove-if (lambda (row) (member row now :test #'equal)) prev)))
  (cond
    (missing
     (format t "~&API-SUBSET-FAIL: ~D entr~:@P of the previous release's Lisp API ~
                ~:*~[~;is~:;are~] missing or changed in this tree; the first:~%  ~S~%  this tree has: ~S~%"
             (length missing) (first missing)
             (find (first (first missing)) now :key #'first))
     (uiop:quit 1))
    (t
     (format t "~&API-SUBSET-OK: all ~D entries of the previous release are present and unchanged (~D now)~%"
             (length prev) (length now))
     (uiop:quit 0))))
