(in-package #:rulisp)

;;; use-crate: thin cargo orchestration (DESIGN.md §6.6). load-crate stays
;;; the primitive; this shells out to cargo, finds the artifact, loads it.
;;; No mtime heuristics — cargo's own no-op check decides.

(defun find-cargo ()
  (or (uiop:getenv "RULISP_CARGO")
      (let ((home-cargo (merge-pathnames ".cargo/bin/cargo" (user-homedir-pathname))))
        (and (probe-file home-cargo) (uiop:native-namestring home-cargo)))
      "cargo"))

(defun scrape-cargo-name (crate-dir)
  "Read the [package] name out of Cargo.toml (line scan; no TOML dep)."
  (let ((toml (merge-pathnames "Cargo.toml" crate-dir)))
    (unless (probe-file toml)
      (error 'build-error :command nil
                          :stderr (format nil "no Cargo.toml in ~A" crate-dir)))
    (with-open-file (in toml)
      (let ((in-package-section nil))
        (loop for line = (read-line in nil)
              while line
              do (let ((trim (string-trim '(#\Space #\Tab) line)))
                   (cond ((string= trim "[package]")
                          (setf in-package-section t))
                         ((and (plusp (length trim)) (char= (char trim 0) #\[))
                          (setf in-package-section nil))
                         ((and in-package-section
                               (>= (length trim) 5)
                               (string= "name" trim :end2 4)
                               (find #\= trim))
                          (return (string-trim '(#\Space #\Tab #\")
                                               (subseq trim (1+ (position #\= trim))))))))
              finally (error 'build-error
                             :command nil
                             :stderr (format nil "no [package] name in ~A" toml)))))))

(defun %run-cargo-build (cargo crate-dir target-dir profile features)
  (let ((cmd (append (list cargo "build"
                           "--manifest-path"
                           (uiop:native-namestring (merge-pathnames "Cargo.toml" crate-dir))
                           "--target-dir" (uiop:native-namestring target-dir))
                     (when (eq profile :release) (list "--release"))
                     (when features
                       (list "--features" (format nil "~{~A~^,~}" features))))))
    (multiple-value-bind (out err code)
        (uiop:run-program cmd :output :string :error-output :string
                              :ignore-error-status t)
      (declare (ignore out))
      (unless (and (numberp code) (zerop code))
        (error 'build-error
               :command (format nil "~{~A~^ ~}" cmd)
               :stderr err)))))

(defun use-crate (crate-dir &key (profile :dev) package features)
  "cargo build CRATE-DIR (a rulisp glue crate), then LOAD-CRATE the artifact.
PROFILE: :dev (default) or :release. FEATURES: list of cargo feature name
strings. Signals BUILD-ERROR with cargo's stderr on failure, offering a
RETRY-BUILD restart."
  (let* ((crate-dir (uiop:ensure-directory-pathname crate-dir))
         (name (scrape-cargo-name crate-dir))
         (target-dir (merge-pathnames "target/" crate-dir))
         (cargo (find-cargo)))
    (loop
      (restart-case
          (progn
            (%run-cargo-build cargo crate-dir target-dir profile features)
            (return))
        (retry-build ()
          :report "Run cargo build again.")))
    (let* ((lib-file (format nil "lib~A.~A"
                             (substitute #\_ #\- name)
                             (if (uiop:os-macosx-p) "dylib" "so")))
           (artifact (merge-pathnames
                      (format nil "~A/~A"
                              (if (eq profile :release) "release" "debug")
                              lib-file)
                      target-dir)))
      (load-crate artifact :crate name :package package))))
