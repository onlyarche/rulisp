(in-package #:rulisp)

;;; Hardened s-expression manifest reader (DESIGN.md §5): keywords, strings,
;;; integers, lists, and the literal symbol NIL only. *read-eval* is nil and
;;; symbols land in a scratch package so nothing gets interned into user
;;; packages. Unknown plist keys are ignored (additive evolution is free).

(defvar *manifest-scratch-package*
  (or (find-package "RULISP.MANIFEST.SCRATCH")
      (make-package "RULISP.MANIFEST.SCRATCH" :use '())))

(defstruct (param (:constructor %make-param (name type)))
  name type)

(defstruct (fn-spec (:constructor %make-fn-spec))
  rust-name lisp-name symbol params result error)

(defstruct (handle-spec (:constructor %make-handle-spec))
  rust-name lisp-name free)

(defstruct (manifest (:constructor %make-manifest))
  schema abi crate crate-version target prefix errors handles functions)

(defun %safe-read (string)
  (with-standard-io-syntax
    ;; with-standard-io-syntax rebinds *read-eval* to T — turn it back off.
    (let ((*read-eval* nil)
          (*package* *manifest-scratch-package*))
      (handler-case
          (values (read-from-string string))
        (error (e)
          (error 'manifest-error
                 :message (format nil "unreadable manifest: ~A" e)))))))

(defun %sanitize (x)
  "Restrict the read form to the manifest grammar; map scratch::NIL to NIL."
  (typecase x
    (null nil)
    (cons (cons (%sanitize (car x)) (%sanitize (cdr x))))
    (keyword x)
    (symbol (if (string= (symbol-name x) "NIL")
                nil
                (error 'manifest-error
                       :message (format nil "unexpected symbol ~A in manifest"
                                        (symbol-name x)))))
    (string x)
    (integer x)
    (t (error 'manifest-error
              :message (format nil "unexpected object ~S in manifest" x)))))

(defun %getf-string (plist key &key optional)
  (let ((v (getf plist key)))
    (unless (or (stringp v) (and optional (null v)))
      (error 'manifest-error :message (format nil "~S must be a string, got ~S" key v)))
    v))

(defun %getf-int (plist key)
  (let ((v (getf plist key)))
    (unless (integerp v)
      (error 'manifest-error :message (format nil "~S must be an integer, got ~S" key v)))
    v))

(defun %parse-param (form)
  (unless (and (consp form) (stringp (getf form :name)))
    (error 'manifest-error :message (format nil "bad param form: ~S" form)))
  (let ((type (getf form :type)))
    (unless type
      (error 'manifest-error :message (format nil "param ~S has no :type" (getf form :name))))
    (%make-param (getf form :name) type)))

(defun %parse-fn (form)
  (unless (and (consp form) (eq (car form) :fn))
    (error 'manifest-error :message (format nil "bad :fn form: ~S" form)))
  (let ((p (cdr form)))
    (%make-fn-spec
     :rust-name (%getf-string p :rust-name)
     :lisp-name (%getf-string p :lisp-name)
     :symbol (%getf-string p :symbol)
     :params (mapcar #'%parse-param (getf p :params))
     :result (or (getf p :result)
                 (error 'manifest-error
                        :message (format nil "fn ~S has no :result" (getf p :lisp-name))))
     :error (%getf-string p :error :optional t))))

(defun %parse-handle (form)
  (unless (and (consp form) (eq (car form) :handle))
    (error 'manifest-error :message (format nil "bad :handle form: ~S" form)))
  (let ((p (cdr form)))
    (%make-handle-spec
     :rust-name (%getf-string p :rust-name)
     :lisp-name (%getf-string p :lisp-name)
     :free (%getf-string p :free))))

(defun target-compatible-p (triple)
  "Loose compatibility check between a Rust target TRIPLE and the running
Lisp host: architecture and OS tokens must match; unknown tokens pass (we
refuse only what we can positively identify as wrong). Returns
(values ok-p host-description)."
  (let* ((arch (subseq triple 0 (or (position #\- triple) (length triple))))
         (arch-ok (cond ((string= arch "x86_64") (member :x86-64 *features*))
                        ((string= arch "aarch64") (or (member :arm64 *features*)
                                                      (member :aarch64 *features*)))
                        (t t)))
         (os-ok (cond ((search "linux" triple) (member :linux *features*))
                      ((search "darwin" triple) (uiop:os-macosx-p))
                      ((search "windows" triple) (uiop:os-windows-p))
                      (t t))))
    (values (and arch-ok os-ok t)
            (format nil "~(~A ~A~)" (uiop:architecture) (uiop:operating-system)))))

(defun parse-manifest (string)
  (let ((form (%sanitize (%safe-read string))))
    (unless (and (consp form) (eq (car form) :rulisp-manifest))
      (error 'manifest-error :message "not a rulisp manifest"))
    (let* ((p (cdr form))
           (schema (%getf-int p :schema)))
      (unless (<= schema 1)
        (error 'manifest-error
               :message (format nil "manifest schema ~D is newer than supported (1)" schema)))
      (%make-manifest
       :schema schema
       :abi (%getf-int p :abi)
       :crate (%getf-string p :crate)
       :crate-version (%getf-string p :crate-version :optional t)
       :target (%getf-string p :target :optional t)
       :prefix (%getf-string p :prefix)
       :errors (let ((errs (getf p :errors)))
                 (unless (every #'stringp errs)
                   (error 'manifest-error :message ":errors must be a list of strings"))
                 errs)
       :handles (mapcar #'%parse-handle (getf p :handles))
       :functions (mapcar #'%parse-fn (getf p :functions))))))
