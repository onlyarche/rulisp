# Benchmarks

Numbers quoted anywhere in this repository trace to this page. The rule
(docs/design/v03-async-plan.md §7): if a number ships, it comes from a
release build with a documented method — otherwise no number ships.

## Method

`make bench` runs `tests/bench.lisp`: it builds `examples/wordbag` with
`(rulisp:use-crate … :profile :release)` and times each boundary path
with `get-internal-real-time` over enough iterations to amortize the
clock (ns/call = elapsed / N). The Lisp side is the host's default
compilation policy; nothing is tuned. Numbers vary by machine and are
**not a CI gate** — the shape is what should hold: scalar calls in tens of
nanoseconds, byte and vector transfers scaling linearly at memcpy speed,
a borrowed callback a small multiple of a call.

## Baseline — 2026-09-02, commit 5241783

| | |
|---|---|
| Host | GitHub-hosted-class VM: Intel Xeon @ 2.20 GHz, 4 vCPU (2 threads/core), 15 GiB |
| Lisp | SBCL 2.1.11 (Debian) |
| Rust | cargo 1.97.0, wordbag built with `--release` |
| OS | Linux 6.8 (x86-64, glibc) |

Raw output of `make bench`:

```
scalar call (add i64 i64)                      20.0 ns/call
scalar call, no args                           25.0 ns/call
handle method (gate + call)                   240.0 ns/call
handle create + free                          650.0 ns/call
string round trip (8 B ASCII)                 950.0 ns/call
string round trip (1024 B ASCII)            22701.5 ns/call
string round trip (65536 B ASCII)         1015066.3 ns/call
string round trip (1 KiB non-ASCII)         39452.6 ns/call
bytes in (sum, 8 B)                           200.0 ns/call
bytes round trip (rev, 8 B)                   500.1 ns/call
bytes in (sum, 1024 B)                        500.1 ns/call
bytes round trip (rev, 1024 B)               1200.0 ns/call
bytes in (sum, 65536 B)                     21251.3 ns/call
bytes round trip (rev, 65536 B)             39952.6 ns/call
bytes in (sum, 1048576 B)                  323521.0 ns/call
bytes round trip (rev, 1048576 B)          731048.0 ns/call
vec i64 round trip (8 elts)                   650.0 ns/call
vec i64 round trip (1024 elts)               6600.4 ns/call
vec i64 round trip (65536 elts)            192512.5 ns/call
borrowed callback (100 invocations)         48003.0 ns/call
stored callback (same thread)                 180.0 ns/call
```

## Reading it

- **Scalars and handles**: a boundary call costs about 20 ns; the handle
  gate (session and generation checks, in-flight counting) adds ~200 ns;
  create+free is dominated by the Rust allocation and the finalizer
  registration.
- **Host note (CCL).** These are SBCL numbers. On CCL the inbound side is
  a memcpy into a heap buffer rather than a zero-copy borrow, because
  CCL's vector pin is `without-gcing` and a whole-call pin would stop
  every other thread's collections (v0.5, `v05.pin-does-not-stop-the-
  world`); expect the inbound rows to cost roughly one extra memcpy.
- **Bytes and scalar vectors are memcpy-bound.** 1 MiB in at 324 µs is
  ~3.2 GB/s, and the inbound side is a true zero-copy borrow (the Lisp
  vector is pinned; BOUNDARY §4). The 0.3.0 CHANGELOG's "24× on a 1 MiB
  byte transfer, 307× on a 65k-element i64 vector" compare these two rows
  (0.32 ms and 0.19 ms) with the element-wise marshaller they replaced
  (7.67 ms and 57.3 ms, measured the same way on this host before the
  change — see the v0.3 groundwork commit).
- **Strings are the slow path**, and deliberately so for now: a
  `:string` round trip goes through UTF-8 encode/decode on the Lisp
  side, so 64 KiB costs ~1 ms where the same bytes as `:bytes` cost 40 µs.
  Zero-copy `:string` is refused-with-cause in the v0.3 plan (bodies are
  octets; no demand case); pass large payloads as `:bytes` and decode
  what you need.
- **Callbacks**: a borrowed callback invocation is ~480 ns (100 per
  export call); a stored callback from the same thread is ~180 ns. The
  cross-thread stored path adds foreign-thread adoption, not measured
  here.

To refresh: run `make bench` on an idle machine, replace the block above,
update the date and commit, and keep the previous baseline in git
history rather than in this file.
