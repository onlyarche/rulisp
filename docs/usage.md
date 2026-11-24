# Two ways to run Rust from Lisp

rulisp has two entry points, one per situation:

| You have… | You need | Entry point |
|---|---|---|
| **A prebuilt glue library** (`libmylib.so` someone built for you) | Lisp + Quicklisp + rulisp. **No Rust toolchain.** | `rulisp:load-crate` |
| **Rust source you're writing** (your own glue crate) | the above **+ cargo** | `rulisp:use-crate` |

They connect: `use-crate` = `cargo build` + `load-crate`. The `.so` that
case B builds is exactly what you hand to a case-A user.

```
case B (author):  cargo build ──> target/debug/libmylib.so ──┐
                       │                                      │ ship this file
                       └─ use-crate = cargo build + ┐         ▼
case A (user):                          load-crate ◄┴── libmylib.so   (no Rust needed)
```

## Case A — running a prebuilt library

Someone built the glue crate for you — a teammate, a CI pipeline, blobs
committed in a library's repo (see [distribution.md](distribution.md)).

```lisp
(ql:quickload :rulisp)

;; dlopen → read the embedded manifest → generate bindings, all at load time
(rulisp:load-crate #p"/opt/libs/libmylib.so")
;; => #<RULISP:CRATE "mylib" gen 1 abi 1 :: 12 fns, 2 handles, package MYLIB>

(mylib:do-something "input")
```

`load-crate` takes the built file. Given a crate directory it signals
`rulisp:crate-not-loaded-error` pointing at `use-crate`, which builds one
(Case B).

When the artifacts follow the blob naming convention
(`lib<name>-<os>-<arch>.<ext>` — the four published names of `wordbag`
are `libwordbag-linux-x86_64.so`, `libwordbag-linux-arm64.so`,
`libwordbag-darwin-arm64.dylib` and, with no `lib` prefix on Windows,
`wordbag-windows-x86_64.dll`), one call picks the right file for the
host, with a clear condition when the platform isn't covered:

```lisp
(rulisp:load-blob-crate #p"/path/to/blobs/" "mylib")
```

Four of the examples ship this way (httpd ships as source): every release at
<https://github.com/onlyarche/rulisp/releases> carries `wordbag`, `rx`,
`wasm` and `fetch` for Linux x86-64 and aarch64, macOS arm64 and Windows
x86-64 (aarch64 from 0.7.0),
built by `.github/workflows/blobs.yml` and audited (docs/distribution.md,
"Audit your glue crate"). Download the ones for your host into a
directory and Case A needs no Rust toolchain at all — the SBCL/Linux CI
job does exactly that with the latest release's `wordbag` on every push.
`wordbag` is the suites' fixture — the README transcript's `greet` and
`WordBag` plus the tests' probes (`always-panic`, `make-grenade`,
`word-bag-poison`, …), 35 functions and 2 handles — shipped so this path
can be exercised without a toolchain; the examples meant to be read are
`rx`, `wasm`, `fetch` and `httpd` (README, "Start here").
(macOS: a dylib downloaded by a browser is quarantined by Gatekeeper —
see distribution.md, Pattern A.) A download or copy that stopped short is
refused, not loaded: before `dlopen` the loader checks the file's own
headers against its size and signals `crate-not-loaded-error` "artifact
is truncated or corrupt" naming the segment or section that overruns
(BOUNDARY.md §9).

Two things to know:

1. **Not any Rust `.so` works.** The library must be a rulisp glue crate —
   built with `#[rulisp::export]` + `rulisp::module!`, which embeds the
   manifest the loader reads. Anything else is refused with
   `rulisp:abi-mismatch-error` ("not a rulisp crate"). To use an arbitrary
   existing crate (say, an ML or compression library), *someone* writes the
   glue crate once — that's case B.
2. **The artifact is platform-specific.** A binary the OS cannot map (a
   Linux `.so` on macOS) fails at `dlopen`, and rulisp signals
   `rulisp:crate-not-loaded-error` carrying the loader's message; one that
   maps but was built for another target is refused by the manifest's
   `:target` check with `rulisp:abi-mismatch-error`.

## Case B — building your own

Full walkthrough: [quickstart.md](quickstart.md). The short version —
Rust side:

```toml
[lib]
crate-type = ["cdylib"]

[dependencies]
rulisp = "0.8"          # from crates.io
regex = "1"             # whatever you're wrapping
```

```rust
use rulisp::prelude::*;

#[rulisp::export]
pub fn greet(name: &str) -> String { format!("Hello, {name}!") }

rulisp::module! { name: "mylib", handles: [], fns: [greet] }
```

Lisp side — build and load in one call, rebuild-and-reload the same way
without restarting the REPL:

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate #p"~/src/mylib/")    ; cargo build + load-crate
(mylib:greet "world")                  ; => "Hello, world!"
;; edit Rust, then again:
(rulisp:use-crate #p"~/src/mylib/")    ; generation 2, old handles refuse politely
```

A failed build signals `rulisp:build-error` carrying cargo's stderr, with
a `retry-build` restart.

## A web server from the REPL, six lines

`examples/httpd` is an HTTP server whose handlers are Lisp functions. From
a checkout:

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/httpd/"))
(load (asdf:system-relative-pathname :rulisp "../examples/httpd/web.lisp"))

(web:with-server (s :port 8080)
  (web:serve s (lambda (r) (web:respond r 200 "Hello from Lisp!"))))
```

`curl http://127.0.0.1:8080/` answers `Hello from Lisp!`. Ctrl-C stops the
loop, and `with-server` stops and frees the server. To keep the REPL,
start the pullers in their own threads instead:

```lisp
(defvar *s* (web:server :port 8080))
(web:start *s* (lambda (r) (web:respond r 200 "Hello from Lisp!")))
(web:stop *s*)
```

Stop before you dump an image: `web:stop`, then `uiop:dump-image`.
[docs/httpd.md](httpd.md) has the handler contract, the limits and
deployment.

## An HTTPS client from the REPL

`examples/fetch` is an async HTTPS client on tokio and rustls: Rust owns
the threads, and Lisp polls them with capped waits. Its veneer,
`examples/fetch/http.lisp`, is what you type — `http:with-client`,
`http:get`, `http:download`, and an `http:http-error` condition with the
error's kind in a slot. A release's `fetch` blob carries the generated
`FETCH` package only; the veneer is a source file to `load` after it.
[docs/fetch.md](fetch.md) has the loading, the calls, the error kinds
and the limits.

## WebAssembly from the REPL

`examples/wasm` runs WebAssembly modules — `.wat` text or `.wasm` binary
— on the `wasmi` interpreter. From a checkout:

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/wasm/"))
;; => #<RULISP:CRATE "wasm" gen 1 abi 1 :: 19 fns, 2 handles, package WASM>

;; or, from a release's blobs in a directory (Case A), without cargo:
(rulisp:load-blob-crate #p"/path/to/blobs/" "wasm")
```

`wasm:make-wasm` is the plain runner, for modules you trust. It takes
the module's path — a string, not a pathname — and a fuel budget: every
guest instruction consumes fuel, and 0 runs unmetered. `rulisp:free`
under `unwind-protect` releases the instance at once rather than at some
later GC:

```lisp
(defun guest (name)                 ; examples/wasm/NAME, as a string
  (uiop:native-namestring
   (asdf:system-relative-pathname
    :rulisp (uiop:strcat "../examples/wasm/" name))))
```

```lisp
CL-USER> (let ((w (wasm:make-wasm (guest "fib.wat") 1000000)))
           (unwind-protect
                (values (wasm:wasm-exports w)
                        (wasm:wasm-call1 w "fib" 20))
             (rulisp:free w)))
"add,boom,fib,sum_mem"
6765
```

`wasm:make-wasi` is the sandbox, for the rest: a WASI command module
(what a `wasm32-wasip1` toolchain produces), a fuel budget that must be
positive, and a memory limit in bytes. `wasi-run` runs the module once
and returns its exit code as a value; `wasi-stdout` and `wasi-stderr`
return octets, so decode them (babel is loaded with rulisp).
`wasi-preopen` takes the sandbox and two more arguments, a host
directory and the path the guest sees it under: read-only, and with the
other preopens the guest's whole filesystem.

```lisp
CL-USER> (let ((s (wasm:make-wasi (guest "wasi-hello.wat") 1000000 1048576)))
           (unwind-protect
                (progn
                  (wasm:wasi-preopen s (guest "") "/")   ; examples/wasm/ as /
                  (values (wasm:wasi-run s)
                          (babel:octets-to-string (wasm:wasi-stdout s))))
             (rulisp:free s)))
7
"hello from wasi
"
```

A trap, running out of fuel and a refused call each signal
`wasm:wasm-error`, a subclass of `rulisp:rust-error`
([Handling conditions](#handling-conditions)):

```lisp
CL-USER> (let ((w (wasm:make-wasm (guest "fib.wat") 1000)))
           (unwind-protect
                (values
                 (handler-case (wasm:wasm-call0 w "boom")     ; unreachable
                   (wasm:wasm-error (e) (rulisp:rust-error-message e)))
                 (handler-case (wasm:wasm-call1 w "fib" 20)   ; 1000 fuel
                   (wasm:wasm-error (e) (rulisp:rust-error-message e))))
             (rulisp:free w)))
"wasm `unreachable` instruction executed"
"all fuel consumed by WebAssembly"
```

The other functions carry docstrings, and `describe` on the crate lists
all 19 ([Reading a crate at the REPL](#reading-a-crate-at-the-repl)):
a two-argument call (`wasm-call2`), bytes in and out of the guest's
memory (`wasm-memory-write`, `wasm-memory-read`), a Lisp closure the
guest calls (`wasm-on-notify`), the fuel left (`wasm-fuel-left`,
`wasi-fuel-left`) and a top-up for the runner (`wasm-refuel`), and the
sandbox's arguments, environment and stdin (`wasi-arg`, `wasi-env`,
`wasi-stdin`). SECURITY.md lists what the sandbox bounds and what it
does not. On ECL, loading this crate needs a C toolchain: its one stored
callback gets a natively compiled trampoline (README, "Status").

`examples/wasm`, like the other examples, their packages and Lisp
veneers — the `web:`, `http:` and `rx:` names on this page — is a
pattern to copy, not a frozen surface (docs/stability.md §8).

## Events from Rust threads: `rulisp::Inbox`

When Rust produces events on its own threads — a tokio task, a file
watcher, a C library's callback — let Rust put them in a `rulisp::Inbox`
and let Lisp pull them out. The producer never runs Lisp code, so no
thread is adopted, and the garbage collector and the debugger only ever
meet threads Lisp made.

```rust
#[rulisp::handle]
pub struct Events { inbox: rulisp::Inbox<u64> }

#[rulisp::export]
impl Events {
    /// The next event, or NIL after WAIT-MS (capped at 100 ms).
    pub fn next(&self, wait_ms: u64) -> Result<Option<u64>, rulisp::Error> {
        Ok(self.inbox.recv(wait_ms)?)
    }
}
// producers hold clones: inbox.try_send(v) never blocks, and hands the
// value back when the inbox is full or closed
rulisp::module! { name: "mylib", handles: [Events], fns: [Events::next] }
```

```lisp
(loop (let ((e (mylib:events-next src 100)))   ; NIL on an idle tick
        (when e (handle-event e))))            ; signals "closed" at the end
```

The inbox is bounded: a consumer that falls behind costs the producer a
refusal it can count, not memory. Each pull waits at most 100 ms, so the
loop stays in Lisp and Ctrl-C lands within a tick. When the producer is
done it closes the inbox, and the pull signals `rulisp:rust-error`
"closed: …" once every event was taken. Only `close` ends the stream, so
a producer must call it on every exit path; a guard whose `Drop` closes
the inbox does that. `Ticker` in tests/inbox-fixture is
the tested example (tests/suite/v09.lisp).

A stored callback (`rulisp:callback`) still works when you want Rust to
call a Lisp closure directly; on SBCL and CCL the Lisp adopts the calling
thread. Keep such a callback short — pushing into a Lisp queue is enough
— because the closure runs on a thread Rust chose.

## Why rulisp lives in two package registries

This mirrors how PyO3 works (PyO3 is on crates.io, not PyPI):

- **crates.io** (`rulisp`, `rulisp-macros`, `rulisp-runtime`) serves
  **case-B authors** at *compile time*: cargo fetches them to expand the
  macros and statically link the runtime into your `.so`.
- **Ultralisp** (the `rulisp` ASDF system; Quicklisp at 1.0) serves **Lisp users**
  at *load/run time*: the loader that dlopens artifacts and generates
  bindings.
- The glue `.so` itself plays the role of Python's wheel: once built, it
  carries everything Rust-side inside it, which is why case A needs no
  Rust toolchain at all.

## Reading a crate at the REPL

Every generated function and handle class carries a docstring, and a
crate answers `describe`:

```lisp
CL-USER> (documentation 'rx:make-regex 'function)
"(rx:make-regex \"[0-9]+\") — a bad pattern signals rulisp:rust-error
carrying regex's excellent multi-line parse error message.

(rx:make-regex pattern)
Rust: Regex::new(pattern: :string) -> rx:regex, Err(Error)
Signals: rulisp:rust-error on Err."

CL-USER> (describe (rulisp:use-crate #p"examples/rx/"))
#<RULISP:CRATE "rx" gen 1 abi 1 :: 7 fns, 1 handle, package RX> is a rulisp crate.
  Package:        RX
  Generation:     1 (session 0)
  Artifact:       .../examples/rx/target/debug/librx.so
  ...
  Built with:     rulisp 0.8.1 (this loader: 0.8.1)
  ...
  Exports (7):
    (rx:make-regex pattern)
    (rx:regex-is-match self text)
    ...
```

A `///` comment on an exported Rust fn or a `#[rulisp::handle]` struct
leads its docstring — the macros carry it in the manifest as `:doc`.

## Handling conditions

The error classes rulisp exports form one tree. Its root,
`rulisp:rulisp-error`, is never signaled itself: handle it to catch all
of them.

```
rulisp-error
├── rust-error              a Rust export returned Err
├── rust-panic              a Rust export panicked; the image is intact
├── invalid-argument        an argument could not cross to Rust
├── invalid-handle-error    a handle refused before any foreign call
│   ├── freed-handle-error  used after rulisp:free
│   └── stale-handle-error  from before a reload or an image dump
├── crate-not-loaded-error  no such crate or file, or dlopen refused it
├── build-error             cargo build failed inside use-crate
├── manifest-error          the artifact's manifest was refused
└── abi-mismatch-error      not a rulisp crate, or another ABI or target
```

An error type not named `Error` gets its own subclass of `rust-error` in
the crate's package, as `wasm:wasm-error` above. Every slot has an
exported reader:

| Condition | Readers |
|---|---|
| `rust-error` | `rust-error-type`, `rust-error-message`, `rust-error-function-name` |
| `rust-panic` | `rust-panic-message`, `rust-panic-function-name` |
| `invalid-argument` | `invalid-argument-message`, `invalid-argument-function-name` |
| `invalid-handle-error` | `invalid-handle-function-name` |
| `stale-handle-error` | `stale-handle-generation`, `stale-crate-generation` |
| `crate-not-loaded-error` | `crate-not-loaded-name`, `crate-not-loaded-message` |
| `build-error` | `build-error-command`, `build-error-stderr` |
| `manifest-error` | `manifest-error-message` |
| `abi-mismatch-error` | `abi-mismatch-expected`, `abi-mismatch-actual`, `abi-mismatch-message` |

`rust-error-type` is the Rust error type's name, `rust-error-message`
its `Display` text and `rust-error-function-name` the Lisp function that
made the call — here with the `rx` crate loaded in the section above:

```lisp
CL-USER> (handler-case (rx:make-regex "(unclosed")
           (rulisp:rust-error (e)
             (list (rulisp:rust-error-type e)
                   (rulisp:rust-error-function-name e)
                   (rulisp:rust-error-message e))))
("Error" "rx:make-regex" "regex parse error:
    (unclosed
    ^
error: unclosed group")
```

`rust-error` and `rust-panic` are signaled with a `use-value` restart:
the value it is given is returned in place of the call's result.

```lisp
CL-USER> (handler-bind ((rulisp:rust-error (lambda (e) (use-value nil e))))
           (rx:make-regex "(unclosed"))
NIL
```

After a failed `cargo build`, `build-error-command` is the command line
and `build-error-stderr` what cargo printed — here with Case B's
`format!` mistyped as `fromat!`:

```lisp
CL-USER> (handler-case (rulisp:use-crate #p"~/src/mylib/")
           (rulisp:build-error (e)
             (format t "~A~%~A" (rulisp:build-error-command e)
                                (rulisp:build-error-stderr e))))
.../cargo build --manifest-path .../mylib/Cargo.toml --target-dir .../mylib/target/
   Compiling mylib v0.1.0 (.../mylib)
error: cannot find macro `fromat` in this scope
 --> src/lib.rs:4:38
  ...
error: could not compile `mylib` (lib) due to 1 previous error; 1 warning emitted
NIL
```

A failed `cargo build` is signaled with a `rulisp:retry-build` restart,
which looks cargo up again and runs the build again: fix the source (or
install cargo, or set `RULISP_CARGO`), then pick it in the debugger or
call `(invoke-restart 'rulisp:retry-build)` from a handler. A directory
with no `Cargo.toml`, or a `Cargo.toml` with no `[package]` name, is a
`build-error` too, but with `build-error-command` `NIL`, the loader's
own message in `build-error-stderr`, and no restart.

`rulisp:rulisp-version-skew` is not in the tree: it is a
`style-warning`, signaled while loading a crate built with a newer
rulisp major.minor than the loader's, and the crate loads anyway. Its
readers are `rulisp-version-skew-crate` (the crate's name),
`rulisp-version-skew-built-with` and `rulisp-version-skew-loader` (the
two version strings); docs/stability.md §7 says which manifest keys such
a loader ignores.
