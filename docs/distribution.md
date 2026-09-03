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
```

Since 0.4 the glue crate can do this declaratively: mark a zero-arg export
as the crate's dump hook and the loader wires it up —

```rust
#[rulisp::export]
pub fn shutdown_all() { /* quiesce every runtime this crate owns */ }

rulisp::module! {
    name: "mylib",
    handles: [...],
    fns: [..., shutdown_all],
    on_dump: shutdown_all,
}
```

The loader calls every loaded crate's declared hook in load order,
immediately before any `uiop:dump-image`-driven dump; a failing hook is
warned and skipped. `examples/fetch` is the worked example (its hook stops
every live tokio runtime; the suite dumps an image with a request in
flight and restores it). For a crate WITHOUT the declaration, keep the
manual pattern:

```lisp
(uiop:register-image-dump-hook
 (lambda () (when *crate* (mylib:shutdown-everything))))
```

Two things to get right, both of which bite silently:

1. **Name the artifact for the platform** — `lib<name>-<os>-<arch>.<ext>`
   (`<name>-windows-x86_64.dll` on Windows), which is what
   `load-blob-crate` looks for and what `.github/workflows/blobs.yml`
   attaches to each GitHub Release for the four examples.
2. **Quiesce foreign threads in a dump hook.** SBCL refuses to dump with
   several *Lisp* threads but cannot see the ones a glue crate spawned, so
   the dump succeeds and the threads are simply gone in the restored image
   — with whatever they were doing left half-done.

## Pattern B′ — ECL: `program-op` is the dump

ECL has no image dump: `(uiop:dump-image … :executable t)` signals
"Dumping an executable is not supported on this implementation!
Aborting." An ECL application ships as an `asdf:program-op` executable
instead, and rulisp works unchanged inside one. `tests/ecl-program/` is
the smallest such consumer, built and run by the ECL CI job
(`make test-ecl-program`); build yours the way its `build.lisp` does —
`ecl --norc --load build.lisp`, where the script loads Quicklisp (rulisp's
dependencies come from there), pushes rulisp's `lisp/` directory and the
application's own directory onto `asdf:*central-registry*`, loads the
dependencies (fact 4 below), and calls `(asdf:make "my-app")`. The
executable lands next to the `.asd`. Four facts shape the system
definition and that build script, all verified against ECL 21.2.1 as
packaged by Debian/Ubuntu (bundled ASDF 3.1.8.8):

```lisp
(defsystem "my-app"
  :class :program-system
  :no-uiop t
  :prologue-code (let ((*load-verbose* nil)) (require :asdf))
  :epilogue-code (funcall (intern "MAIN" "MY-APP"))
  :build-operation "program-op"
  :build-pathname "my-app"
  :depends-on ("rulisp")
  :components ((:file "main")))
```

1. **ASDF must exist at startup, and cannot be linked in.** cffi's
   compiled code references ASDF packages at object-load time (its lazy
   `cffi-libffi` loader), and rulisp calls UIOP at runtime. ASDF's default
   on ECL is to link `cmp` — and `uiop`/`asdf` when it finds a prebuilt
   one — statically into the program. The distro package ships only the
   `.fas` files, neither `libcmp.a` nor `libasdf.a`, yet its `cmp.asd`
   still declares `:lib #P"SYS:LIBCMP.A"`, so the link fails with
   `ld: cannot find …/ecl-21.2.1/libcmp.a`. `:no-uiop t` turns the static
   link off and the prologue `require`s `asdf.fas` before any linked
   module initializes. The executable already needs the ECL runtime
   (`libecl.so`, per `ldd`) from the same installation, so this adds no
   new deployment dependency.
2. **With `:no-uiop`, ASDF stops wiring the entry point too** — the
   program would fall through into ECL's REPL (with `main` defined and
   never called). Call `main` from the epilogue (interned at runtime; the
   package does not exist when the `.asd` is read) and end it with
   `uiop:quit`. `:entry-point` does nothing under `:no-uiop`.
3. **Loading a crate compiles at runtime.** Bindings are generated at load
   time by design, and on ECL `compile` goes through the C compiler; a
   crate with callbacks additionally native-compiles its trampolines
   (BOUNDARY §7) — `strace` shows a `gcc` invocation per generated
   wrapper. The deployed machine therefore needs `gcc`, exactly as the
   REPL does, and a writable crate cache: `load-crate` copies the artifact
   under `$XDG_CACHE_HOME/rulisp/` (default `~/.cache/rulisp/`). With
   `HOME` unset, as under many service managers and containers, that
   resolves to `/.cache` and the program fails with
   `Could not create directory "/.cache" … Permission denied`; setting
   `XDG_CACHE_HOME` alone is enough. rulisp keeps a successful run quiet
   (`*compile-verbose*` is bound off around its own compiles); when `gcc`
   is missing, ECL itself prints `;;; Internal error: ** Error code 1 when
   executing (EXT:RUN-PROGRAM "gcc" …)` before `load-crate` signals — that
   line is the tell.
4. **Load the dependencies before `program-op`.** With the bundled ASDF
   3.1.8.8, `(asdf:make "my-app")` from a cold output cache dies about two
   minutes in with `COMPILE-FILE-ERROR while compiling #<cl-source-file
   "cffi" "src" "early-types">` / `The function WARN-IF-KW-OR-BELONGS-TO-CL
   is undefined`: `program-op` compiles a dependency's files without
   loading the earlier ones, so cffi's macro-time helpers are missing. A
   rerun on that half-built cache fails faster (`There exists no package
   with name "CFFI"`). `(ql:quickload '(:cffi :babel :trivial-garbage
   :bordeaux-threads))` — or `(asdf:load-system "rulisp")` — before
   `asdf:make` sidesteps it; a warm cache hides the problem, which is why
   it is easy to miss.

Load the glue artifact from `main` with `rulisp:load-crate` /
`rulisp:load-blob-crate`. The crate's package (`WORDBAG` — the manifest
crate name, upcased) exists only after that call, so `main.lisp` cannot
name `wordbag:greet` literally; reach the bindings late-bound, as
`tests/ecl-program/main.lisp` does with `find-symbol` (or
`uiop:symbol-call`). There is no pre-dump state, so rulisp's image-restore
hook has nothing to invalidate. Several instances may share one cache:
each copy is named with a per-process tag, and the sweep leaves other
processes' fresh copies alone. One more ECL habit: an error that reaches
its debugger with stdin at EOF exits 0 (a memory fault instead aborts
with exit 134 and a core dump), so a wrapper script or CI step must gate
on a printed marker, never on the exit code alone.

## Audit your glue crate

BOUNDARY.md §7 asks every glue author to keep signal handlers out of the
dependency graph. `tools/rulisp-audit.sh ARTIFACT [CRATE_DIR]` makes that
a command: it fails if the built artifact imports a signal-disposition
symbol (`sigaction`, `signal`, `sigprocmask`, …), if tokio's `signal` or
`process` features are on, or if `block_on` appears in the glue sources.
`make audit` runs it over every example in CI, after a self-test that
builds a library which deliberately imports `signal()` and requires the
audit to reject it — the check that keeps the gate from going inert (an
anchored regex once made it so). Linux and macOS; on Windows it prints a
SKIP line (`dumpbin /imports` is the manual equivalent).

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
