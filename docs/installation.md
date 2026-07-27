# Installation

Setting up rulisp on Linux and macOS: toolchains, Lisp-side dependencies,
and how to verify the install. (Windows is not supported in v1.)

## What you need and why

| Dependency | Why | Verified with |
|---|---|---|
| Rust toolchain (`cargo`, `rustc`) | builds glue crates; invoked by `rulisp:use-crate` at development time only — loading the `rulisp` system itself needs no Rust | Rust 1.97 (anything recent works; `catch_unwind`, edition 2021) |
| A Common Lisp | the host | SBCL 2.1.11+ (primary), Clozure CL 1.13 (Linux) |
| Quicklisp | pulls the CL dependencies | current dist |
| CL libraries: `cffi`, `babel`, `trivial-garbage`, `bordeaux-threads` (+ `fiveam` for the test suites) | FFI, UTF-8, finalizers, locks | Quicklisp dist versions |
| C toolchain (linker) | Rust needs a system linker | gcc / Xcode CLT |

## Linux (Debian/Ubuntu shown; adjust the package manager elsewhere)

```sh
# 1. system pieces: Lisp + linker for Rust
sudo apt update
sudo apt install -y sbcl build-essential curl

# 2. Rust (user-local, ~/.cargo)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 3. Quicklisp (skip if you already have ~/quicklisp/)
curl -sO https://beta.quicklisp.org/quicklisp.lisp
sbcl --non-interactive --load quicklisp.lisp \
     --eval '(quicklisp-quickstart:install)' \
     --eval '(ql:add-to-init-file)'
rm quicklisp.lisp
```

Optional second implementation, Clozure CL:

```sh
curl -sL https://github.com/Clozure/ccl/releases/download/v1.13/ccl-1.13-linuxx86.tar.gz | tar xz -C "$HOME"
# binary: ~/ccl/lx86cl64
```

musl-based distros (Alpine): glibc-built artifacts won't load; build glue
crates with the musl target and `-C target-feature=-crt-static`. Not part
of the tested matrix.

## macOS

> Status: expected to work (dylib naming, `:target` checks and the ad-hoc
> code-signing done by Apple's linker are all accounted for), but not yet
> CI-verified — reports welcome. On Apple Silicon use SBCL; Clozure CL has
> no native arm64 macOS build.

```sh
# 1. linker (if you don't have Xcode CLT yet)
xcode-select --install

# 2. Lisp + Rust
brew install sbcl
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 3. Quicklisp — same as Linux
curl -sO https://beta.quicklisp.org/quicklisp.lisp
sbcl --non-interactive --load quicklisp.lisp \
     --eval '(quicklisp-quickstart:install)' \
     --eval '(ql:add-to-init-file)'
rm quicklisp.lisp
```

macOS notes:
- Locally built dylibs are ad-hoc signed by the linker automatically —
  nothing to do. Only dylibs *downloaded from the network* get quarantined
  by Gatekeeper (see docs/distribution.md); `use-crate` builds locally, so
  this doesn't affect development.
- rulisp loads libraries by absolute path, so SIP's stripping of
  `DYLD_LIBRARY_PATH` is irrelevant.

## Getting rulisp

Until the Quicklisp/Ultralisp registration lands, clone into Quicklisp's
`local-projects` (ASDF finds `lisp/rulisp.asd` there automatically):

```sh
git clone <repository-url> ~/quicklisp/local-projects/rulisp
```

then:

```lisp
(ql:quickload :rulisp)   ; pulls cffi/babel/trivial-garbage/bordeaux-threads
```

Alternative without `local-projects` — point ASDF at the checkout
(e.g. in `~/.sbclrc`):

```lisp
(push #p"/path/to/rulisp/lisp/" asdf:*central-registry*)
```

## Verify the installation

Smoke test (builds and loads the bundled `regex` example — first build
downloads crates.io deps):

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/rx/"))
(rx:regex-count (rx:make-regex "[0-9]+") "1 22 333")   ; => 3
```

Full test gates, from the repository root:

```sh
make test-m4                          # everything, on SBCL (101 checks)
make test-ccl CCL=~/ccl/lx86cl64      # same suites on Clozure CL (Linux)
cargo test --workspace                # manifest golden + compile-fail tests
```

## Runtime facts worth knowing

- **cargo discovery**: `use-crate` looks at `$RULISP_CARGO`, then
  `~/.cargo/bin/cargo`, then `cargo` on PATH. A build failure signals
  `rulisp:build-error` carrying cargo's stderr, with a `retry-build`
  restart.
- **Release builds**: `(rulisp:use-crate dir :profile :release)`.
- **Library cache**: every load dlopens a unique copy under
  `~/.cache/rulisp/` (`$XDG_CACHE_HOME` respected); older copies are swept
  automatically.
- **Loading rulisp itself never runs cargo** and opens no foreign
  libraries — cargo is needed only when you `use-crate` a glue crate.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `rulisp:build-error` "cargo: command not found" | Rust not installed / not on PATH | install rustup, or set `RULISP_CARGO=/path/to/cargo` |
| `rulisp:crate-not-loaded-error` with a dlopen message | artifact for the wrong platform, or missing system libs | rebuild on this machine (`use-crate`), check the message |
| `rulisp:abi-mismatch-error` "not a rulisp crate" | the cdylib wasn't built with `rulisp::module!` | add the `module!` block; check the crate name matches |
| `rulisp:abi-mismatch-error` "different target" | artifact built for another arch/OS | rebuild locally |
| Rust compile error `rulisp requires panic = "unwind"` | `panic = "abort"` in a Cargo profile | remove it — it would let a panic kill the Lisp image |
| A `; note: ... unknown type` on first use (SBCL) | harmless forward-reference note from the compiler | ignore |
