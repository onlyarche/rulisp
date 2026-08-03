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
supported approach: a WebAssembly sandbox with a fuel-metered CPU budget
and bounds-checked memory.

## Supported versions

The latest release only, while the project is pre-1.0.
