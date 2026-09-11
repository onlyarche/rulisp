;;; Quicklisp dist dry run — docs/stability.md §9. What the dist builder does
;;; with a source tarball of this repository: find every .asd, load every
;;; system each one defines, with no cargo reachable — off PATH, and
;;; RULISP_CARGO pointed at nothing. Run by `make dist-dryrun`
;;; (against a `git archive HEAD` export) and by the SBCL/Linux CI job.
;;; RULISP_DIST_ROOT is the export's root (default: the current directory).
;;; Prints DRYRUN-OK <system> per system and exits non-zero on any failure,
;;; or if cargo turns out to be reachable after all.

(require :asdf)
#-quicklisp
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defvar *root* (uiop:ensure-directory-pathname
                (or (uiop:getenv "RULISP_DIST_ROOT") (uiop:getcwd))))

;; the point: loading must need no toolchain
(let ((cargo (string-trim '(#\Newline #\Space)
                          (uiop:run-program "command -v cargo || true" :output :string)))
      (override (uiop:getenv "RULISP_CARGO")))
  (unless (string= cargo "")
    (format t "~&DRYRUN-FAIL cargo is reachable on PATH (~A) — the dry run proves nothing~%" cargo)
    (uiop:quit 2))
  ;; rulisp's own lookup also tries ~/.cargo/bin/cargo; the dist builder
  ;; has none, so RULISP_CARGO must point at nothing here
  (unless (and override (not (probe-file override)))
    (format t "~&DRYRUN-FAIL RULISP_CARGO must name a nonexistent program (got ~S) — ~
               rulisp would find ~~/.cargo/bin/cargo and the dry run proves nothing~%" override)
    (uiop:quit 2)))

(defun asd-files (root)
  "Every .asd below ROOT (a walk, not a ** glob: portable across hosts)."
  (let ((found '()))
    (uiop:collect-sub*directories
     root (constantly t) (constantly t)
     (lambda (dir)
       (dolist (f (uiop:directory-files dir "*.asd"))
         (push f found))))
    (sort found #'string< :key #'namestring)))

(defun system-names (asd)
  "The names the file's defsystem forms declare — read, not evaluated."
  (with-open-file (in asd)
    (let ((*package* (find-package :asdf-user)))
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            when (and (consp form)
                      (member (car form) '(asdf:defsystem) :test #'string-equal))
              collect (string-downcase (string (second form)))))))

(let ((asds (asd-files *root*)))
  (when (null asds)
    (format t "~&DRYRUN-FAIL no .asd under ~A~%" *root*)
    (uiop:quit 2))
  ;; registered the way a dist does: every directory that holds an .asd
  (dolist (asd asds)
    (pushnew (uiop:pathname-directory-pathname asd) asdf:*central-registry* :test #'equal))
  (dolist (asd asds)
    (dolist (name (system-names asd))
      (handler-case
          (progn (ql:quickload name :silent t)
                 (format t "~&DRYRUN-OK ~A (~A)~%" name (enough-namestring asd *root*)))
        (error (e)
          (format t "~&DRYRUN-FAIL ~A (~A): ~A~%" name (enough-namestring asd *root*) e)
          (uiop:quit 1))))))
(uiop:quit 0)
