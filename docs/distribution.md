# Distributing rulisp-based systems

(M4-(f): guide only — tooling lands in v0.2. Facts below were source-verified
against the ecosystem in July 2026; see DESIGN.md §9 risk 8.)

## The reality

- **Quicklisp cannot practically accept a cargo-requiring system.** The dist
  build machine compiles every candidate with ASDF; a `.asd` that shells out
  to cargo fails there. This is the same social contract as cffi-grovel
  needing `cc` — but cargo is a much rarer toolchain. Target
  **Ultralisp** or **ocicl** instead (both distribute source; your users
  build locally).
- Developers using `rulisp:use-crate` have cargo by definition — the
  problem is only *end users* of a library or application built on rulisp.

## Pattern A — committed per-platform blobs (libraries)

The Shirakumo pattern (cl-mixed et al.): build the cdylib in CI for each
platform, commit (or attach) the artifacts under names like

```
static/libmycrate-lin-amd64.so
static/libmycrate-lin-arm64.so
static/libmycrate-mac-amd64.dylib
static/libmycrate-mac-arm64.dylib
```

and load with `rulisp:load-crate` picking the file by
`(uiop:architecture)`/`(uiop:operating-system)`. This ships through any
source dist as plain data. Caveats:

- **macOS Gatekeeper quarantines downloaded dylibs** — blobs fetched over
  the network at load time will be refused. Committed-in-repo blobs
  installed via git/quicklisp-style tarballs are fine.
- musl hosts need separate artifacts built with
  `-C target-feature=-crt-static`.
- The manifest `:target` check will refuse a wrong-platform artifact with a
  clear condition instead of a confusing dlopen error.

## Pattern B — Deploy (applications)

For shipped executables, [Deploy](https://codeberg.org/shinmera/deploy)
automates the whole lifecycle: it discovers every open foreign library,
copies them next to the binary at `asdf:make` time, closes before the image
dump and reopens at boot.

rulisp needs one adjustment, because Deploy's model is "reopen the same
library" while rulisp's is "regenerate the bindings from whichever artifact
we load now" (its own restore hook bumps the session counter and re-runs
`load-crate`). Let rulisp own the reload and tell Deploy to leave the
artifact alone:

```lisp
;; my-app.asd
(defsystem "my-app"
  :defsystem-depends-on (:deploy)
  :build-operation "deploy-op"
  :build-pathname "my-app"
  :entry-point "my-app:main"
  :depends-on ("rulisp")
  :components ((:file "main")))
```

```lisp
;; main.lisp
(defvar *crate* nil)

;; Deploy copies libraries next to the binary; ship the glue artifact the
;; same way and load it from there at boot rather than from a build path
;; that will not exist on the user's machine.
(defun artifact-directory ()
  (if (uiop:argv0)
      (uiop:pathname-directory-pathname (uiop:argv0))
      #p"./"))

(defun start ()
  (setf *crate* (rulisp:load-blob-crate (artifact-directory) "mylib")))

(uiop:register-image-restore-hook 'start nil)

;; Crates that own threads (an async runtime, a watcher) MUST be quiesced
;; before the dump: save-lisp-and-die does not see foreign threads and will
;; happily dump with them running (BOUNDARY.md §10).
(uiop:register-image-dump-hook
 (lambda () (when *crate* (mylib:shutdown-everything))))
```

Two things to get right, both of which bite silently:

1. **Name the artifact for the platform** — `lib<name>-<os>-<arch>.<ext>`,
   which is what `load-blob-crate` looks for and what
   `.github/workflows/blobs.yml` produces.
2. **Quiesce foreign threads in a dump hook.** SBCL refuses to dump with
   several *Lisp* threads but cannot see the ones a glue crate spawned, so
   the dump succeeds and the threads are simply gone in the restored image
   — with whatever they were doing left half-done.

## Pattern C — build on the user's machine (developers)

`rulisp:use-crate` is the dev path: cargo build + load, with
`rulisp:build-error` carrying cargo's stderr and a `retry-build` restart.
Publish your glue crate to crates.io so `cargo` can fetch it, and your ASDF
system to Ultralisp/ocicl.

## Publishing rulisp itself

Order matters (dependencies first):

```sh
cargo publish -p rulisp-runtime
cargo publish -p rulisp-macros
cargo publish -p rulisp
```

The ASDF system (`lisp/rulisp.asd`) goes to Ultralisp (GitHub app or manual
project registration) and/or ocicl.
