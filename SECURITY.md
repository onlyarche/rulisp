# Security policy

## Reporting a vulnerability

Please report security issues privately via GitHub's **Report a
vulnerability** button on
<https://github.com/onlyarche/rulisp/security/advisories> rather than in a
public issue. Include the affected version, the Lisp implementation and OS,
and a reproduction if you have one. Expect an acknowledgement within a few
days; fixes ship as a patch release, and a bad version is yanked from
crates.io.

## Threat model — what counts as a vulnerability here

rulisp is an **in-process FFI bridge**. Rust code loaded through it runs
with the full privileges of the Lisp image and shares its address space:
there is no sandbox between a glue crate and your program, by design. So:

**In scope** — bugs where Lisp code that uses only generated wrappers and
the documented API can reach memory unsafety:

- use-after-free, double-free or type confusion through handles (the cell
  state machine, generation gates, or reload/image-restore paths)
- dangling or mismatched allocator frees for strings, byte buffers or
  vectors crossing the boundary
- a dead stored-callback id causing a dangling call instead of failing safe
- a manifest that makes the loader generate unsound bindings, or that gets
  half-applied
- panics or Lisp conditions escaping their documented containment

**Out of scope** — documented, contract-level properties:

- a glue crate's own `unsafe` code, or a crate you chose to wrap
- non-local Lisp exits (`throw`, `return-from`, restart transfers) out of a
  callback: documented UB, see BOUNDARY.md §6
- crash isolation: a Rust segfault or abort takes the image down; if you
  need isolation, run the Rust side out of process
- dependencies that install signal handlers (BOUNDARY.md §7 tells you to
  audit for these)
- loading an untrusted `.so`, which is equivalent to running untrusted code

If you want to run untrusted logic in-process, `examples/wasm` shows the
supported approach: the WASI sandbox, `wasm:make-wasi` (since 0.7).
`wasm:make-wasm`, the plain module runner, is for modules you trust: it
may run unmetered and bounds no memory.

### What the WASI sandbox bounds, and what it does not

Each line of the first list is a test in `tests/suite/wasm.lisp`
(`wasm.wasi-*`), found or confirmed by attacking the finished sandbox.

It bounds:

- **instructions** — fuel is mandatory; out of fuel is a condition, also
  for a `(start)` section, and unbounded recursion stops at the
  interpreter's depth limit (guest frames are on the heap)
- **time inside host calls** — fuel does not meter what the host does for
  a WASI call, so that time has its own budget: one second plus a
  microsecond per unit of fuel (before it, 100,000 fuel of `random_get`
  ran 103 seconds)
- **memory** — one number for the linear memory, the table and the bytes
  kept from stdout and stderr together; one memory, one table
- **waiting** — `poll_oneoff` and sleep answer ENOTSUP at once
- **the filesystem** — only the directories you preopen, read-only,
  regular files and directories only (a FIFO, a device or a socket is
  EACCES); `..`, absolute paths and symlinks that lead outside are EPERM,
  for open and for stat alike
- **descriptors** — 256 open at once, all released when the run ends
- **the process** — no arguments, environment, stdio or directory is
  inherited; the exit code is a value

It does not bound:

- a bug in wasmi, wasi-common, cap-std or the glue: the sandbox is a
  budget for a guest, **not isolation from the host** — the crash-
  isolation bullet above applies to it as to every crate
- host memory beyond the number: about three times the memory limit is
  resident per live instance (memory, table, captured output) — and the
  number has to admit the module at all: one built by Rust asks for
  1.1 MiB of memory before it runs
- one host call in flight: it may touch the whole guest memory, or list a
  directory as large as you made it, before the time budget is checked
- the module file: reading and validating it is linear in its size, and
  you chose the file
- what the guest can learn: the real clocks, real entropy, the names and
  sizes of everything under a preopen, and the text of its symlinks
  (never the file a link outside points at)
- a filesystem that is itself slow, and a directory that changes under
  the guest while it runs

## Supported versions

The latest release only, while the project is pre-1.0 (docs/stability.md §4 has the full support and deprecation policy).
