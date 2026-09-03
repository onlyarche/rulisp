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

## Baseline — 2026-09-03, commit 43f3c9c

| | |
|---|---|
| Host | GitHub-hosted-class VM: Intel Xeon @ 2.20 GHz, 4 vCPU (2 threads/core), 15 GiB |
| Lisp | SBCL 2.1.11 (Debian) |
| Rust | cargo 1.97.0, wordbag built with `--release` |
| OS | Linux 6.8 (x86-64, glibc) |

Raw output of `make bench`:

```
scalar call (add i64 i64)                      25.0 ns/call
scalar call, no args                           25.0 ns/call
handle method (gate + call)                   275.0 ns/call
handle create + free                          650.0 ns/call
string round trip (8 B ASCII)                 600.0 ns/call
string round trip (1024 B ASCII)            11100.7 ns/call
string round trip (65536 B ASCII)          317620.7 ns/call
string round trip (1 KiB non-ASCII)         38802.6 ns/call
rx count over 1 MiB (&str in, 1 match)    2305160.0 ns/call
bytes in (sum, 8 B)                           200.0 ns/call
bytes round trip (rev, 8 B)                   500.1 ns/call
bytes in (sum, 1024 B)                        550.0 ns/call
bytes round trip (rev, 1024 B)               1100.0 ns/call
bytes in (sum, 65536 B)                     22451.4 ns/call
bytes round trip (rev, 65536 B)             44102.9 ns/call
bytes in (sum, 1048576 B)                  319521.5 ns/call
bytes round trip (rev, 1048576 B)          702045.0 ns/call
vec i64 round trip (8 elts)                   600.0 ns/call
vec i64 round trip (1024 elts)              10550.7 ns/call
vec i64 round trip (65536 elts)            191012.5 ns/call
borrowed callback (100 invocations)         39002.5 ns/call
stored callback (same thread)                 170.0 ns/call
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
- **Strings: ASCII takes a typed loop, the rest goes through babel.**
  A `:string` crosses as UTF-8 with a copy in each direction (BOUNDARY
  §4; zero-copy `:string` is refused-with-cause in the v0.3 plan). Since
  v0.5 the loader checks-and-stores ASCII text in a typed loop and hands
  the bytes to babel at the first char/byte ≥ 128, so a 64 KiB ASCII
  round trip costs ~0.32 ms where the 2026-09-02 baseline (in git
  history) measured ~1 ms; the same bytes as `:bytes` cost 40 µs, so
  octet payloads still belong in `:bytes`. Non-ASCII text costs what it
  did (the 1 KiB row). The rx row is a real `&str` consumer: 1 MiB into
  `regex-count` with the digits placed once at the end, so the regex side
  is a memchr sweep and the row is the boundary — ~2.3 ms, in line with
  16× the 64 KiB row.
- **Callbacks**: a borrowed callback invocation is ~480 ns (100 per
  export call); a stored callback from the same thread is ~180 ns. The
  cross-thread stored path adds foreign-thread adoption, not measured
  here.

To refresh: run `make bench` on an idle machine, replace the block above,
update the date and commit, and keep the previous baseline in git
history rather than in this file.
