;;; The ECL deployment story (docs/distribution.md): ECL has no image dump,
;;; so an application ships as an asdf:program-op executable. This is the
;;; smallest such consumer of rulisp, built and run by the ECL CI job.
(defsystem "rulisp-ecl-smoke"
  :description "program-op smoke consumer of rulisp for ECL"
  :class :program-system
  ;; Two facts decide this shape. (1) cffi's compiled code references ASDF
  ;; packages at object-load time (its lazy cffi-libffi loader), and rulisp
  ;; itself calls UIOP at runtime — so both must exist before any linked
  ;; module initializes. (2) Debian/Ubuntu's ECL ships asdf.fas but not
  ;; libasdf.a/libcmp.a, so ASDF's default of linking cmp+asdf statically
  ;; into the program (its image-op on ECL) fails at link time. Hence:
  ;; :no-uiop t turns that static link off, and the prologue requires
  ;; asdf.fas at startup instead. The executable already needs the ECL
  ;; runtime (libecl.so) from the same installation — ldd shows it — so
  ;; this adds no new deployment dependency.
  :no-uiop t
  :prologue-code (let ((*load-verbose* nil)) (require :asdf))
  ;; with :no-uiop ASDF also stops wiring the entry point, so the program
  ;; would fall through into ECL's REPL; call main from the epilogue
  ;; ourselves (interned at runtime: the package does not exist when this
  ;; .asd is read)
  :epilogue-code (funcall (intern "MAIN" "RULISP-ECL-SMOKE"))
  :depends-on ("rulisp")
  :build-operation "program-op"
  :build-pathname "rulisp-ecl-smoke"
  :entry-point "rulisp-ecl-smoke:main"
  :components ((:file "main")))
