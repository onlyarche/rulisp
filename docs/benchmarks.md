# Benchmarks

Numbers quoted in the user-facing pages trace to this page (DESIGN.md's
pre-M1 estimates are history, not claims). The rule
(docs/design/v03-async-plan.md §7): if a number ships, it comes from a
release build with a documented method — otherwise no number ships.

## Method

`make bench` runs `tests/bench.lisp` on SBCL; the other hosts run the
same file (`~/ccl/lx86cl64 --batch --load tests/bench.lisp`,
`ecl --norc --load tests/bench.lisp`). It builds `examples/wordbag` and
`examples/rx` with `(rulisp:use-crate … :profile :release)` and times
each boundary path with `get-internal-real-time` over enough iterations
to amortize the clock (ns/call = elapsed / N). The harness declares
nothing; the loader's typed ASCII loops carry `(optimize speed)` and
nothing else is tuned. Numbers vary by
machine and are **not a CI gate** — the shape is what should hold:
scalar calls in tens of nanoseconds on SBCL, byte and vector transfers
scaling linearly at memcpy speed, a borrowed callback a small multiple
of a call.

## Baseline — 2026-09-03, commit 43f3c9c

| | |
|---|---|
| Host | GitHub-hosted-class VM: Intel Xeon @ 2.20 GHz, 4 vCPU (2 threads/core), 15 GiB |
| Lisp | SBCL 2.1.11 (Debian); Clozure CL 1.13; ECL 21.2.1 (Debian) |
| Rust | cargo 1.97.0, wordbag and rx built with `--release` |
| OS | Linux 6.8 (x86-64, glibc) |

One host at a time, each run alone (the same `tests/bench.lisp`; the
SBCL column is `make bench`):

| Path | SBCL 2.1.11 | CCL 1.13 | ECL 21.2.1 |
|---|---|---|---|
| scalar call (add i64 i64) | 25 ns | 36 ns | 1.2 µs |
| scalar call, no args | 25 ns | 33 ns | 795 ns |
| handle method (gate + call) | 275 ns | 1.0 µs | 2.9 µs |
| handle create + free | 650 ns | 8.6 µs | 14.7 µs |
| string round trip (8 B ASCII) | 600 ns | 5.0 µs | 10.3 µs |
| string round trip (1024 B ASCII) | 11.1 µs | 36.8 µs | 74.0 µs |
| string round trip (65536 B ASCII) | 317.6 µs | 1.55 ms | 4.29 ms |
| string round trip (1 KiB non-ASCII) | 38.8 µs | 103.5 µs | 3.93 ms |
| rx count over 1 MiB (&str in, 1 match) | 2.31 ms | 11.83 ms | 32.28 ms |
| bytes in (sum, 8 B) | 200 ns | 1.9 µs | 2.8 µs |
| bytes round trip (rev, 8 B) | 500 ns | 9.1 µs | 7.9 µs |
| bytes in (sum, 1024 B) | 550 ns | 8.6 µs | 2.2 µs |
| bytes round trip (rev, 1024 B) | 1.1 µs | 15.3 µs | 8.6 µs |
| bytes in (sum, 65536 B) | 22.5 µs | 28.3 µs | 22.9 µs |
| bytes round trip (rev, 65536 B) | 44.1 µs | 63.4 µs | 70.5 µs |
| bytes in (sum, 1048576 B) | 319.5 µs | 504.8 µs | 365.0 µs |
| bytes round trip (rev, 1048576 B) | 702.0 µs | 873.1 µs | 1.67 ms |
| vec i64 round trip (8 elts) | 600 ns | 6.0 µs | 8.4 µs |
| vec i64 round trip (1024 elts) | 10.6 µs | 10.6 µs | 16.4 µs |
| vec i64 round trip (65536 elts) | 191.0 µs | 304.3 µs | 744.5 µs |
| borrowed callback (100 invocations) | 39.0 µs | 235.3 µs | 481.5 µs |
| stored callback (same thread) | 170 ns | 610 ns | 1.6 µs |

## Reading it

- **Scalars and handles** (SBCL): a boundary call costs about 25 ns;
  the handle gate (session and generation checks, in-flight counting)
  adds ~250 ns; create+free includes the Rust allocation and the
  finalizer registration. CCL is close on scalars; ECL pays ~1 µs per
  call in its CFFI backend, and its finalizer registration is the
  costliest of the three.
- **Host note (CCL).** On CCL the inbound side is
  a memcpy into a heap buffer rather than a zero-copy borrow, because
  CCL's vector pin is `without-gcing` and a whole-call pin would stop
  every other thread's collections (v0.5, `v05.pin-does-not-stop-the-
  world`); expect the inbound rows to cost roughly one extra memcpy.
- **Bytes and scalar vectors are memcpy-bound.** 1 MiB in at 320 µs is
  ~3.3 GB/s on SBCL (ECL is within 15%; CCL pays its extra memcpy), and the inbound side is a true zero-copy borrow (the Lisp
  vector is pinned; BOUNDARY §4). The 0.3.0 CHANGELOG's "24× on a 1 MiB
  byte transfer, 307× on a 65k-element i64 vector" compare these two rows
  (0.32 ms and 0.19 ms, SBCL) with the element-wise marshaller they replaced
  (7.67 ms and 57.3 ms, measured the same way on this host before the
  change — see the v0.3 groundwork commit).
- **Strings: ASCII takes a typed loop, the rest goes through babel.**
  A `:string` crosses as UTF-8 with a copy in each direction (BOUNDARY
  §4; zero-copy `:string` is refused-with-cause in the v0.3 plan). Since
  v0.5 the loader checks-and-stores ASCII text in a typed loop and hands
  the bytes to babel at the first char/byte ≥ 128, so on SBCL a 64 KiB
  ASCII round trip costs ~0.32 ms where the 2026-09-02 baseline (in git
  history) measured ~1 ms; the same bytes as `:bytes` cost 44 µs, so
  octet payloads still belong in `:bytes`. Non-ASCII text costs what it
  did (the 1 KiB row). The typed loop is faster than babel on every host
  (measured directly at 64 KiB: faster on all three, by far the most on
  ECL, whose babel path is the slow one — see its non-ASCII row). The rx
  row is a real `&str` consumer: 1 MiB into `regex-count` with the only
  digits at the very end, so the regex finds one match and the row is
  the boundary — ~2.3 ms on SBCL, in line with 16× the inbound half of
  the 64 KiB round trip.
- **Callbacks** (SBCL): a borrowed callback invocation is ~390 ns (100
  per export call); a stored callback from the same thread is ~170 ns.
  On ECL a borrowed callback goes through a natively compiled trampoline
  (BOUNDARY §7) at ~4.8 µs per invocation. The cross-thread stored path
  adds foreign-thread adoption, not measured here.

To refresh: run the bench on each host on an idle machine, replace the
table above, update the date and commit, and keep the previous baseline
in git history rather than in this file.
