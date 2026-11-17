# Changelog

Notable changes per release. Versions are shared by the Rust crates
(`rulisp`, `rulisp-macros`, `rulisp-runtime` on crates.io) and the ASDF
system. The C ABI has its own version, checked at load time: **ABI 1 since
0.1.0, unbroken** — every type added since is wire-additive.

## Unreleased (0.8.1 development)

**Surfaces this cycle.** A patch: none moved. *Lisp API*: the golden's
47 rows and `lisp/src/package.lisp` are byte-identical to v0.8.0
(`git diff --quiet v0.8.0 HEAD --` both; `make compat PREV=v0.8.0`:
API-SUBSET-OK); three loader docstrings are reworded. *Rust API*:
unchanged — the crates' sources differ from 0.8.0 in ten doc-comment
lines, and three compile-fail expectations follow Rust 1.100.0's
wording; the gate (`cargo-semver-checks` against crates.io 0.8.0) is
set to `patch` from the cycle's first commit and passes as one.
*Manifest schema*: unchanged; apart from the `:rulisp-version` value,
which a release changes in every blob, the published blobs' manifests
differ from 0.8.0's in `:doc` strings only — one in `wordbag` (the
golden's diff), one in `rx`, four in `fetch`, none in `wasm`. *ABI*: 1.
*The examples*: docstring and message text only — no function added,
renamed or removed.

### Added

- **docs/fetch.md.** The HTTPS client example has a page, on the
  docs/httpd.md model: loading (`use-crate`, then `http.lisp`; a
  release's `fetch` blob carries the `FETCH` package only),
  `http:with-client`, `http:get` and `http:download`, the `http-error`
  readers and its twelve kind tokens, the `retry-request` restart, a
  limits table (the 100 ms wait cap, `http:client`'s four keywords with
  their defaults and clamps, `*max-bytes*`, `:timeout-ms`, the ready
  queue, the shutdown grace, the dump hook) and the generated `FETCH`
  functions a veneer author drives. Every form on it was run on SBCL
  against the crate's loopback server.
- **docs/usage.md: "WebAssembly from the REPL"** — loading
  `examples/wasm` from a checkout or a release's blobs, `wasm:make-wasm`
  and `wasm:make-wasi` with their printed results, `wasm:wasm-error` for
  a trap or an empty fuel budget, and all 19 functions by name; no page
  showed the example before. **"Handling conditions"** — the condition
  tree under `rulisp:rulisp-error`, the 21 exported readers by class, a
  `handler-case` on `rust-error` and one on `build-error`, the
  `use-value` and `retry-build` restarts, and the `rulisp-version-skew`
  warning; no user page named a reader before. **"An HTTPS client from
  the REPL"** points at docs/fetch.md.
- **SECURITY.md: "What the HTTP client bounds, and what it does not"**,
  beside the sandbox's and the server's lists: each bound names the
  `fetch.*` test or the audit that holds it, or says there is none; the
  other list names what reqwest's defaults leave open — redirects, the
  proxy environment variables, the compiled-in roots, a download's path
  and size, `:timeout-ms 0`, a header block built by hand.
- **Test `fetch.progress-accessors`**: the six `FETCH` exports no test
  or veneer called (`req-id`, `req-settled`, `req-failed`,
  `req-head-done`, `req-header`, `req-buffered`), against the crate's
  loopback server. The fetch suite is 24 tests.

### Changed

- **The examples' docstrings and messages say what the code does.**
  These are what `(documentation 'rx:regex-first-match 'function)`
  prints and what a condition reports. `rx:regex-first-match`: "First
  match, or NIL when there is none", where it said "no more sentinel
  values (v0.2)". `wordbag:opt-scale` loses its "(v0.6 — the value slot
  carried a fixnum 0 …)" remark — the one change in the `wordbag` blob's
  manifest. `fetch:client-shutdown`: the grace is bounded at 5 s, a
  deliberate exception to the 100 ms cap, not "capped like every other
  wait"; `fetch:make-client` names its clamps and that a stall timeout
  of 0 means 30 s; `fetch:make-req` and `http:request` say a timeout of
  0 means none. `fetch:req-headers` calls the header block re-encoded,
  not verbatim, and `http:request` says one name's values are adjacent
  and in wire order, where it said "an alist in wire order": the names
  come lower-cased and in reqwest's order. `httpd:make-server` states
  that out-of-range limits are clamped, not refused, with each range;
  `httpd:server-wait` names the "usage" condition of a stopped server;
  `httpd:server-shutdown` calls its grace a bounded exception to the
  100 ms wait cap. The two `wasm:wasm-error` messages for a type that
  does not cross end "(only i32 and i64 cross)", where they said "(v1
  speaks i32/i64)". No export, lambda list or behaviour changed.
- **Loader docstrings and the crates' rustdoc.** `rulisp:load-blob-crate`
  and `rulisp:load-crate` name the Windows artifact
  (`<name>-<os>-<arch>.dll`; `.so/.dylib/.dll`); `rulisp:build-error`'s
  says which signals carry the `retry-build` restart (a missing or
  nameless `Cargo.toml` has neither a command nor the restart). The
  rustdoc of `rulisp` and `rulisp-runtime` — the docs.rs pages — loses
  "(v0.2)", "v1 shapes only" and "v0.2:" on ten lines. Comments and
  docstrings only.
- **The examples are patterns, not a frozen surface, and the pages say
  so.** docs/stability.md §8: the examples, their packages and Lisp
  veneers (`web:`, `http:`, `wasm:`, `rx:`) are not among the four
  surfaces 1.0 freezes. docs/httpd.md, docs/fetch.md, docs/usage.md,
  docs/quickstart.md, docs/installation.md and SECURITY.md each carry
  the sentence where they show one.
- **docs/httpd.md says what Deploying left out.** `web:server` listens
  on 127.0.0.1 unless `:address` names a literal IP (IPv6 in brackets; a
  hostname is `web:http-error` kind "usage"), and the per-platform
  builds for `load-blob-crate` are your own: the GitHub Release attaches
  no httpd asset. The limits' ranges are stated (out-of-range values are
  clamped), with the dump hook's bound, `web:http-error-kind` and
  `web:http-error-detail`, the kinds a handler meets, `start`'s four
  pullers and `web:shutdown`.
- **docs/installation.md covers ECL and says what Windows runs.** An ECL
  install block and the two ECL gates CI runs; `make test-fetch` and
  `make test-httpd` are best-effort on Windows; `use-crate`'s
  `:features` and `:package` keywords and what `reload-crate` does are
  under Runtime facts — no user page named them. docs/usage.md names the
  four published blob files and says what the `wordbag` blob is: the
  suites' fixture.
- **The registers were re-read against the tree, citation by citation.**
  docs/claims.md: 128 rows re-anchored (the test-name citations into
  `tests/suite/m1.lisp` and `m2.lisp` sat 11 lines low, 25 rows cited
  `lisp/src/build.lisp` at the v0.5.0 tree's lines, the ci.yml line
  citations name the job and step now), 160 rows added for this cycle's
  sentences, then every citation audited again and 38 more rows
  corrected; the register is 589 rows, 0 unverified. Four rows cited a
  test for a bound that test cannot fail on (the ready queue's 4096-id
  cap, the exit of a client's threads at the dump hook); they cite the
  code and a hand evaluation now, and SECURITY.md says no test holds
  either. BOUNDARY §12:
  sixteen ranges in fourteen rows. No normative sentence of BOUNDARY.md
  changed.
- **docs/releasing.md is a patch's checklist too.** Step 1 names every
  site `make check-versions` checks; step 3 has the patch rule — the
  Lisp API golden and `lisp/src/package.lisp` byte-identical to the
  previous tag, the wordbag manifest golden's diff confined to `:doc`
  strings — because an added export is caught by the golden alone, and
  regenerating it turns every gate green; step 9 sets the Rust API
  gate's `release-type` for the cycle being opened, and step 1 names
  docs/stability.md §8's "Status as of" sentence as a site re-dated by
  hand. The gate is `patch` this cycle (an added item fails too, except
  a free fn or a module, which has no lint — the diff is read), and
  docs/stability.md §2 says a patch neither breaks nor adds.
- **Records.** ROADMAP: the 0.8.0 paragraph counts the nine items its
  list marks ✅, v0.7 items 6 and 7 carry their mark, the blob sentence
  dates its four legs, the v0.2 wish list says what became of each
  bullet, and "Later / exploratory" gains the 0.8 flagship's 1.x
  findings and the httpd adversarial pass — not scheduled; httpd ships
  source-only until it runs. docs/design/v10-plan.md is corrected where
  the tree already contradicted it (the trybuild diff rule, the
  exact-pin pattern, the pages whose words flip, `uiop` in the Quicklisp
  text), reads "after 0.8.1", and writes its example pin without a
  version (`"X.Y.Z"`). This file's 0.6.0 section has one
  heading per kind. DESIGN.md opens by saying it is the v0.1 plan of
  2026-07 and that BOUNDARY.md and docs/stability.md are the normative
  text.
- **Example sources.** examples/wordbag's header says what the crate is
  (README's snippet is its greet/WordBag corner; the rest is the suites'
  fixture); version-era tags are gone from the examples' comments and
  the oracle's; examples/httpd/Cargo.toml lists tokio's `io-util`, which
  `lib.rs` imports (`Cargo.lock` unchanged).
- **The compile-fail expectations follow Rust 1.100.0.** `module_typo`,
  `non_send_handle` and `stored_callback` under
  `crates/rulisp/tests/ui/` record rustc 1.100.0's wording — CI builds
  with the current stable, and docs/installation.md says so beside
  `cargo test --workspace`. None of rulisp's own messages changed. On an
  older stable (1.97 measured) `cargo test --workspace`, the first step
  of `make test-m4`, mismatches these three cases.

### Fixed

- **`make test-m4` was described as "every suite but fetch"** in the
  README and "everything" in docs/installation.md; it runs every suite
  but fetch and httpd, and both pages list `make test-httpd`.
- **The README and quickstart transcripts load rulisp with
  `(ql:quickload :rulisp)`**, as every other page does —
  `asdf:load-system` does not fetch cffi, babel, trivial-garbage and
  bordeaux-threads on an image that never loaded them. The quickstart's
  prerequisites name the three supported Lisps and say the system loads
  from Ultralisp or a checkout.
- **Counts and pointers that had aged.** "all twelve assets" in
  docs/distribution.md and tools/rulisp-audit.sh (sixteen since 0.7.0;
  both say "every asset it attaches"); docs/stability.md's "(§11's …
  rule)" names BOUNDARY §11, and its appendix no longer sizes the
  register at "some three hundred rows"; SECURITY.md pointed at
  stability §4 for the deprecation policy (§3) and at the closed v0.8
  item 2 for the httpd adversarial pass (ROADMAP "Later / exploratory");
  docs/installation.md's smoke test named a `regex` example (it is
  `rx`).
- **Transcripts.** docs/usage.md's Case A prints `#<RULISP:CRATE …>`, as
  the loader does, and its `describe` transcript marks the lines it
  leaves out. docs/httpd.md's JSON block loads alexandria, which it
  calls.
- **The hand-written oracle's `grenade_free`** prints the line the macro
  generates, `rulisp[wordbag]: panic in grenade_free (swallowed)` — the
  one place the oracle and examples/wordbag differed on stderr.
- **`make`'s `.PHONY`** lists `test-httpd` and `test-httpd-ccl`.
- **`make` finds cargo on PATH** when `~/.cargo/bin/cargo` is absent, as
  the loader and the audit scripts already did: the macOS runner image
  of 2026-11-12 has none there, and `make test-m4` stopped at its first
  line. `CARGO=…` still wins.
- **What the cycle's own review found on the new pages.** docs/fetch.md:
  the response headers are an alist whose names come in reqwest's order
  — only one name's values keep the wire's; `make-req` trims the
  whitespace around a header name before it checks it; two waits exceed
  the 100 ms cap, shutdown's grace and the dump hook's 2 s per client
  (SECURITY.md said "the one exception"). SECURITY.md and docs/usage.md
  no longer call `wasm:` and `rx:` Lisp veneers — they are the crates'
  packages. docs/usage.md: `wasi-preopen` takes the sandbox and two
  more arguments, and "Handling conditions" says which crate its `rx:`
  forms need. docs/installation.md: Quicklisp's init-file step wrote
  SBCL's only, so an ECL or Clozure CL REPL loads
  `~/quicklisp/setup.lisp` first. `rulisp:build-error`'s docstring: an
  attempted build has the `retry-build` restart, a cargo that cannot be
  run included.

## 0.8.0 — 2026-10-14

**Surfaces this cycle.** *Lisp API*: no export added or removed — the
golden's 47 rows are unchanged (`make compat PREV=v0.7.0`:
API-SUBSET-OK); `load-crate` on a directory now signals the documented
`crate-not-loaded-error` where a host stream error was. *Rust API*:
additive — `rulisp::Inbox`, `SendError`, `Closed`, `rulisp::inbox` and
its `WAIT_CAP_MS`; two diagnostics reworded; no crate that compiled stops
compiling (an `on_dump` hook with parameters never compiled; one with a
result still compiles and is refused by the loader as before).
*Manifest schema*: unchanged. *ABI*: 1. *Loader behaviour*: the cache
sweep now also removes copies of exited processes (POSIX), so the crate
cache must be host-local.

### Fixed

- **The cache no longer grows without bound.** The sweep removed other
  processes' copies only for the crate being loaded and only after an
  hour, so copies of crates no later process loaded again stayed for
  good: one development week left 180 of them, 3.4 GB in
  `~/.cache/rulisp`. On POSIX a copy whose process has exited
  (`kill(pid, 0)` fails) is now removed for any crate once it is a minute
  old; the minute covers a process in another pid namespace sharing the
  cache. Windows keeps the hour rule. Test
  `v08.cache-sweep-removes-copies-of-exited-processes`, failing first on
  the 0.7 sweep.
- **`load-crate` on a crate directory** signals `crate-not-loaded-error`
  saying "is a directory" and naming `use-crate`, before anything is
  copied. It used to fail inside the artifact check with the host's
  stream error (SBCL: `SIMPLE-STREAM-ERROR … Is a directory`), naming
  neither function. Test `v08.load-crate-on-a-directory-is-refused`, on
  every host through run-m4.

### Changed

- **Host tiers (docs/stability.md §5).** SBCL is tier 1:
  every feature and example. CCL is tier 2: what CFFI, bordeaux-threads,
  trivial-garbage, UIOP and standard Common Lisp can express; a feature
  that needs CCL-specific code ships for SBCL only and says so. ECL is
  tier 3: the core (loading, calls, handles, conditions, reload,
  `program-op`). Every required CI job is unchanged; the tiers decide
  what a new feature must reach.
- **Two macro diagnostics name their real rule.** `Option<Handle>` as a
  result, on a method or a constructor, used to say "handle-returning
  functions must be constructors", which is wrong on a constructor; it now
  says `Option<Handle>` is not a result type and points at the bool-wait
  plus constructor shape. `module!`'s `on_dump:` naming a function with
  parameters used to fail as a bare E0308 from a hidden fn-pointer
  coercion; a const assertion on the export's own metadata now fails with
  rulisp's sentence (BOUNDARY §10). A hook with a non-unit result still
  compiles and is refused by the loader, as in 0.7, so no crate that
  compiled stops compiling. `#[diagnostic::on_unimplemented]`
  was probed first and is not used for an arity mismatch on MSRV 1.78. No
  Rust API item comes with this change; the manifest and the shims are
  unchanged. Two
  trybuild cases, `option_handle_result` and `on_dump_with_params`.

### Added

- **`rulisp::Inbox<T>`**: the queue direction of the boundary as a
  library type. Producers on any Rust thread `try_send` (never blocks;
  the value comes back when the inbox is full or closed) or
  `send_timeout`; the export Lisp loops on calls `recv(wait_ms)`, capped
  at `WAIT_CAP_MS` = 100 ms; `close` lets the remaining values drain and
  then reports `Closed`, which converts into `rulisp::Error`. No thread is
  adopted and no Lisp code runs on the producer, so it works on every
  tier. *Rust API*: additive (`rulisp::inbox`, `Inbox`, `SendError`,
  `Closed`, `WAIT_CAP_MS`). *Lisp API*, manifest schema, ABI: unchanged.
  `Ticker` in a new fixture crate, tests/inbox-fixture, is the tested
  example (wordbag stays byte-identical to the hand-written oracle), and
  tests/suite/v09.lisp pins order, the
  cap, backpressure, no adoption and free mid-stream on SBCL, CCL and
  ECL; a mutation of the cap and one of the capacity check each fail
  exactly their test. docs/usage.md's event section now leads with the
  inbox.
- **`examples/httpd` — an HTTP server with Lisp handlers**, the 0.8
  flagship: HTTP/1.1 and h2c on axum/hyper/tokio in front of a Lisp pull
  loop (`server-wait`, `take-request`, `request-respond`,
  `request-respond-file`), with every bound in the first feature commit —
  a timer on every connection from its first byte, a body size and time,
  a connection cap, a bounded queue that waits before 503, bodies in
  memory bounded by the queue whatever the protocol, a handler timeout,
  a graceful stop, a bounded dump hook — and the checks on what Lisp puts
  on the wire. `web.lisp`, the veneer: `web:server` with keyword
  defaults, `web:with-server`, `web:serve` (the debugger in the handler's
  frame with `respond-500`, `retry-handler`, `skip-request`), `web:start`
  / `web:stop` for background pullers, request accessors, `query-params`,
  `match-path`, `web:respond` and `web:respond-file`. A hermetic suite of
  41 tests on the crate's own `Probe` client; a five-lens review before
  the merge found and closed three bounds the first cut lacked. SECURITY.md
  lists what the server bounds and what it does not. Not in 0.8: TLS (a
  proxy), streaming responses. The planned adversarial pass against the
  finished server was not run; SECURITY.md lists what stays unattacked.
  httpd ships as source (`use-crate`): the
  release still carries sixteen assets, for wordbag, rx, wasm and fetch.
- **docs/httpd.md, the web developer's page**: the hello, JSON and files,
  the loop's contract (which status on which path), errors in a handler,
  the limits table with the memory bound, testing, deploying, and when to
  stay on Hunchentoot. docs/usage.md gains "A web server from the REPL,
  six lines"; the suite's hello test reads that form from the page.

## 0.7.0 — 2026-09-30

**Surfaces this cycle** (docs/stability.md §8 criterion 3: a second
cycle without a break). *Lisp API*: no export added or removed —
`lisp/src/package.lisp` and its golden are as 0.6.0 left them; one
behaviour tightened, additively: a truncated or corrupt artifact is
refused with the documented `crate-not-loaded-error` where a fault or a
false success was. *Rust API*: none — `crates/` is unchanged since
0.6.0, and `cargo-semver-checks` is green against 0.6.0 as a minor.
*Manifest*: none; the goldens are untouched. *C ABI*: 1, unchanged
since 0.1.0. The flagship, the WASI sandbox, is an example: it moved no
surface and needed no boundary feature.

### Added
- **`examples/wasm` has a suite.** README made six claims about it,
  SECURITY.md called it the supported approach for untrusted logic, and
  every release attached three `wasm` blobs — with no test and no job
  that had ever loaded one. `tests/suite/wasm.lisp` (`:rulisp-wasm`, 15
  tests, in `run-m4` on every job) pins what ships: the `.wat` guests load
  and list their exports, a binary `.wasm` module loads, i32 coercion
  including the wrap at 2^31, traps and bad calls as `wasm:wasm-error`,
  fuel exhaustion and refuel, the
  unmetered fuel API, memory round trip and bounds (an offset of 2^64−1
  is refused, not wrapped), host callbacks into Lisp on the calling
  thread, a closure's condition becoming a guest trap, the unset and the
  dead callback, a freed instance, a missing file. These tests pin
  `wasm:make-wasm` as 0.6.0 shipped it; the sandbox below was built
  beside it.
- **`examples/wasm` runs WASI command modules in a sandbox** — the
  flagship of 0.7. A second handle, `wasm:make-wasi`, loads a WASI
  preview1 command module — what a `wasm32-wasip1` toolchain produces, or
  a hand-written `.wat` — with a fuel budget
  that must be set (the run is synchronous on the calling thread; only
  fuel makes it finite) and one memory number that bounds the guest's
  linear memory, its table and the bytes kept from stdout + stderr (a
  flooding guest gets ENOSPC inside the sandbox — measured before the
  cap: 5 M fuel bought 101 GiB of output). `wasi-arg`, `wasi-env`,
  `wasi-preopen`, `wasi-stdin` configure it; `wasi-run` calls `_start`
  once and returns the exit code as a value; `wasi-stdout`, `wasi-stderr`
  and `wasi-fuel-left` read the result. Nothing of the process is
  inherited, and the guest cannot wait through WASI: `poll_oneoff`/sleep
  — a guest-chosen `std::thread::sleep` at zero fuel in the stock
  scheduler, measured 3.0 s — answer ENOTSUP at once. The preopens are
  read-only and the guest holds at most 256 open descriptors, released
  when the run ends (the commit's adversarial review found a guest
  writing 8 MiB to the host disk for 5,000 fuel and another exhausting
  the image's file descriptors and keeping them until the handle was
  freed). An adversarial pass over the finished sandbox then found that
  fuel does not meter what the host does for a call — `random_get` of
  1 MiB in a loop ran 103 seconds on 100,000 fuel, and 1e9 would have
  been days — so the time spent inside host calls now has its own
  budget, a second plus a microsecond per unit of fuel; and that a FIFO
  inside a preopen blocked the run forever, so a preopen now offers
  regular files and directories only. SECURITY.md lists what the sandbox
  bounds (each line a test) and what it does not. Twenty-six
  `wasm.wasi-*` tests run on every host: hand-written guests
  (`examples/wasm/wasi-hello.wat`, `wasi-cat.wat`; `tests/wasm-guests/`)
  and one a toolchain built — a std-only Rust program compiled for
  `wasm32-wasip1`, committed as `tests/wasm-guests/rust-guest.wasm` with
  its source — which gets its arguments, environment, stdin and files,
  is refused an escape and a write, and exits with a code; its
  `thread::sleep` panics into a trap, since the sandbox refuses to wait.
  (A Rust-built module asks for 17 pages of memory before it runs: give
  `make-wasi` more than 1.1 MiB.) Dependencies: wasmi_wasi 0.50, cap-std 3 and
  cap-rand 3 (entropy from the OS; the crate's default RNG registers a
  fork handler) — no tokio, no C, and the §7 audit still passes. The
  existing `wasm:make-wasm` API is unchanged.

### Changed
- **`make clean` cleans the checkout.** It removed the root `target/`
  and the oracle's, while `use-crate` builds every crate into its own
  `<crate>/target/` and the other gates leave theirs: a 40 MB checkout
  grew to several GB with `git status` clean. It now removes every
  regenerable artifact `.gitignore` hides, by name; the loader's cache
  under `~/.cache/rulisp/`, shared with other checkouts and running
  images, goes only with the new `make clean-cache`.
- **The release gate also counts the `cargo tests` job.** The Rust API
  gate, the manifest golden, the trybuild cases and the signal audit run
  there; a tag on a commit where any of them was red is now refused, as
  it already was for a red host or MSRV (eight jobs).
- **Linux aarch64 is a supported host.** The SBCL job on
  `ubuntu-24.04-arm` is required: 26 consecutive green runs on main
  since its clock restarted on 2026-09-08, and the deployment path
  rehearsed first (the four examples built and audited on the arm host,
  sixteen assets re-audited, nothing published). From this release every
  GitHub Release carries `lib<crate>-linux-arm64.so` too — sixteen
  assets, four hosts — and the release gate counts the arm job.
- **The repository ships one `.asd`.** `rulisp-ecl-smoke`, the ECL
  `program-op` test consumer, was a committed system file, so a dist
  that indexes every `.asd` it finds published it: Ultralisp lists
  `rulisp-ecl-smoke` next to `rulisp`, and the Quicklisp submission at
  1.0 would have frozen that. Its system file is now a template
  (`tests/ecl-program/rulisp-ecl-smoke.asd.in`) that the build script
  writes out at test time. If you quickloaded `rulisp-ecl-smoke` from
  Ultralisp — it was never a documented entry point — it goes away with
  the dist's next poll.
- **The macOS fetch step is required** — 37 consecutive green runs since
  it was added, never a failure of its own; promoted by the written
  procedure. **fetch runs on Windows**, best-effort to start: the
  example's audit wrapper now finds `fetch.dll`, which every release
  attaches and no job had ever loaded.
- **`make compat` tells an additive change from a break.** The previous
  release's suite carried its own Lisp API golden, so one documented new
  export turned the cross-version gate red — and its `rulisp.asd` named
  the loader's files by hand, so a loader file this tree added never
  loaded there. The gate now assembles the old tree's `rulisp.asd` from
  this tree's `rulisp` defsystem and the previous release's `rulisp/test`,
  compares the two Lisp API goldens with `tests/compat/api-subset.lisp`
  (every previous entry present and unchanged; additions pass), and runs
  the old suite against this tree's golden. Every 1.x minor will add
  exports; the gate permits what stability §1 permits. And the rule that
  section already stated is now implemented: a test of the previous
  release's suite that reaches `rulisp::` internals is recorded by name
  with its reason (`tests/compat/skipped-internal.txt`) and not counted —
  one today, found at this release's version bump, where it would have
  turned the gate red on the release commit itself.

### Fixed
- **A truncated or corrupt artifact is refused before `dlopen`.** A
  partial download or copy used to reach the host loader: a cut that
  kept every loadable segment *loaded and ran* until the first call into
  the missing bytes, and a header-only file faulted inside `dlopen`
  (SBCL `Signal 7 … Continuing with fingers crossed`, with ld.so's load
  lock left held so the next load from another thread hung). The loader
  now checks each format's headers against the file size — ELF section
  table and `PT_LOAD`s, Mach-O `LC_SEGMENT_64`s, PE section raw data —
  before the cache copy is made, on the load and the image-restore path,
  and signals `crate-not-loaded-error` "artifact is truncated or corrupt:
  segment __TEXT ends at byte N (M bytes)". Formats it does not recognize
  pass through as before.

## 0.6.0 — 2026-09-14

**Surfaces this cycle** (docs/stability.md §8 criterion 3, the no-break
cycle). *Lisp API*: fifteen additive exports (`rulisp-version-skew`, its
readers, the eleven condition readers), documentation on every export,
`build-error` where a host error was, `Option<float>` NIL as None — and
one tightening, the undocumented `(setf crate-generation)` removed as a
§4 soundness fix; no rename, no removal of a documented call. *Rust
API*: doc text only; `cargo-semver-checks` green against 0.5.0 as a
minor. *Manifest*: no new key; the golden regenerated for two new
wordbag exports. *C ABI*: 1, unchanged since 0.1.0.

### Added
- **Quicklisp dist dry run in CI.** A dist builder loads every system of
  every `.asd` in the tarball; `make dist-dryrun` exports HEAD with
  `git archive` and does exactly that with cargo off PATH — `rulisp`,
  `rulisp/test` and `rulisp-ecl-smoke` all load. stability.md §9 said
  `rulisp/test` was "excluded from what a dist user loads"; it is not,
  and need not be: only running it needs cargo.
- **The loader's API describes itself, and exports what the docs already
  name.** Fifteen additive exports: `rulisp-version-skew` — the
  style-warning stability.md §7 tells users they may muffle — with its
  three readers, and the eleven condition readers that were internal
  while their siblings were exported (`rust-panic-function-name`,
  `invalid-argument-message`/`-function-name`,
  `invalid-handle-function-name`, `crate-not-loaded-name`/`-message`,
  `build-error-command`, `manifest-error-message`,
  `abi-mismatch-expected`/`-actual`/`-message`): 32 → 47. Every exported
  condition class, `crate` and `callback-token` carry a class
  documentation saying when they are signaled and which restart is
  offered; every exported reader has a docstring;
  `v06.exports-are-documented` keeps it so. `Error::msg`'s Rust doc no
  longer names the nonexistent `<crate>:rust-error`.
- **Lisp API gate.** `tests/golden/lisp-api.sexp` pins every exported
  symbol of `rulisp` with its kind, its superclasses (classes and
  conditions) or its lambda list (functions); `v06.exported-api-golden`
  compares it on every host — lambda lists exactly on SBCL, by parameter
  names on CCL and ECL. An additive export regenerates the golden in the
  same commit; a removal or a changed signature fails.
- **Rust API gate.** Every push runs `cargo-semver-checks` over
  `rulisp`, `rulisp-macros` and `rulisp-runtime` against the latest
  crates.io release with `--release-type minor` — the criterion-3
  question, "does this tree break a consumer of the release", asked
  mechanically. `rulisp::runtime` stays public and is checked with the
  rest; hiding it waits for the 1.0 major.
- **"Required" is a release gate.** The release job refuses to attach
  assets to a tag whose commit's CI run does not have every `(required)`
  job and `MSRV` concluded success — no run, or a run still in progress,
  refuses too, naming the job (`tools/required-ci-green.sh`, self-testable
  with an injected job listing). `skip-ci-gate` is the documented
  override for a re-run and prints a warning. Until now a tag on a red
  commit produced a release with twelve audited assets.
- **The audit reads every format from every host — the last BOUNDARY
  §12 gap closes.** `tools/rulisp-audit.sh` dispatches on the artifact's
  magic, not on `uname`: ELF through `nm`, Mach-O through Apple's `nm` or
  rustup's `llvm-nm`, PE through rustup's `llvm-readobj --coff-imports`
  (`rustup component add llvm-tools`), sweeping Windows' analogues of a
  signal handler (ucrt `signal`/`raise`, `SetConsoleCtrlHandler`, the
  exception-filter and vectored-handler installers). A format it cannot
  read fails instead of printing SKIP. The Windows CI job runs `make
  audit` with the self-test (the fixture DLL must be rejected), and the
  release job re-audits all twelve assets as downloaded, on Linux, before
  attaching them; `workflow_dispatch` gained `publish: false` for a
  build-and-audit-only run.
- **Cross-version gates, pinned to the previous release.** `make compat`
  loads this tree's `wordbag` with the v0.5.0 loader (any warning but
  `rulisp-version-skew` is an error) and runs the v0.5.0 test suite
  against this tree's loader, on every push; the release-asset step is
  pinned to v0.5.0 so it stays old-crate/new-loader after the next
  release. `v06.abi-mismatch-refused` loads `tests/abi-fixture`, whose
  `abi_version()` answers 2, and expects the refusal before a byte of
  manifest is read — the §12 row that said "no suite test simulates a
  mismatch" now cites it.

### Changed
- **`crate-generation` is a reader.** The slot was declared with an
  accessor, so `(setf (rulisp:crate-generation crate) 0)` was an exported
  function that no doc, test or example used — and it defeated the
  generation gate: reset the counter and reload, and a handle from the
  old library passed into the new one (a Box from one library copy
  dereferenced by another's shim). The writer is gone; the reader is
  unchanged, and `v06.crate-generation-is-read-only` checks that no
  exported symbol names a setf function. Classified under stability.md
  §4 (a soundness fix, forward), not §3: a style-warning stage would keep
  the hole open one more minor. The v0.5.0 suite, run against this
  loader by `make compat`, only ever read the generation.
- **`m4.gc-finalization` no longer assumes no collection runs inside its
  constructor loop.** It dropped each of 1000 handles as it made them and
  then asserted all 1000 live; a nursery GC inside the loop finalizes
  some first — the Linux aarch64 job's one failure, reproduced on x86-64
  with a small nursery. The test now holds the handles while it counts
  them, then releases every reference and collects. The arm job's
  promotion streak restarts here.

### Fixed
- **A renamed artifact is refused with the fix in the message, and a
  failed load leaves no cache copy.** `load-crate` guesses the export
  prefix from the file name, so an artifact committed under a
  Pattern-A name (`libmycrate-lin-amd64.so`, as docs/distribution.md
  suggests) was refused as "not a rulisp crate" with no hint that
  `:crate "mycrate"` is the answer; the message says so now, and the
  page shows the call. And the artifact was copied into the cache before
  it was verified, so every failed load left an artifact-sized copy the
  sweep could never match (its name carries the guessed prefix); a load
  that does not commit now deletes its copy (best-effort on Windows,
  where a mapped DLL cannot be unlinked).
- **`Option<f32>` / `Option<f64>` NIL is None, not a host type error.**
  For an optional float parameter the wrapper put the integer 0 in the
  value slot when the argument was NIL, and SBCL's and CCL's foreign-call
  checks refused a fixnum for `:double`/`:float`; README and quickstart
  promised NIL ↔ None. The placeholder is typed now; `wordbag` gained
  `opt_scale`/`opt_scale32` (manifest golden co-updated) and
  `v06.option-float-nil-is-none` pins it on every host.
- **A cargo that cannot be run is a `build-error`, on every host, with a
  `retry-build` that looks cargo up again.** `use-crate` promised
  `build-error` with a `retry-build` restart, but a cargo that could not
  be executed at all escaped as the host's own error on SBCL, arrived as
  a `build-error` with an empty stderr on CCL, and the restart was inert
  everywhere: cargo was looked up once, outside the restart loop, so
  setting `RULISP_CARGO` from the debugger and retrying re-ran the old
  path. Now the exec failure is a `build-error` carrying the host's
  message, an empty stderr is replaced by the exit status and the
  program name, and each retry looks cargo up again. Migration: code
  that handled the host's error class around `use-crate` handles
  `rulisp:build-error`.
- **A crate whose reload failed on image restore could crash the next
  dump.** `%stub-crate` replaced the generated functions but left the
  dumped image's library handle and dump-hook pointer on the crate
  object, so `%run-crate-dump-hooks` — what the next `uiop:dump-image`
  runs first — called into the dead mapping (SBCL: `CORRUPTION WARNING
  … Memory fault`; found by the v0.6 panel, docs/design/v06-plan.md item
  1). Every foreign pointer is dropped with the functions now; the crate
  is inert until `reload-crate` succeeds (which un-stubs it), `describe`
  says so with the reason, and BOUNDARY §10 states the rule. The restore
  hook also catches any `serious-condition` from the reload, not only
  `error` — on ECL a host fault inside `dlopen` is a storage-condition
  and used to escape the hook with the crate left half-alive.

## 0.5.0 — 2026-09-04

### Added
- **`:string` ASCII fast path** — both directions of a `:string` now take
  a typed check-and-store loop while the text is ASCII and hand the same
  bytes to babel at the first char/byte ≥ 128, after a peek at the first
  one so text that is non-ASCII from the start (CJK, say) allocates
  nothing extra. Host-neutral, no wire change, the copy contract of
  BOUNDARY §4 untouched — zero-copy `:string` stays refused. A 64 KiB
  ASCII round trip drops from ~1 ms to ~0.32 ms on the benchmark host
  (docs/benchmarks.md); non-ASCII text costs what it did. New
  `v05.utf8-fastpath-boundary` walks the seam (empty, DEL, code 128,
  interior NUL, Latin-1 range, 4-byte chars first/last, fill-pointer and
  base strings) through wordbag's echo on all three hosts, and the bench
  gains an rx "count over 1 MiB" row: a real `&str` consumer.
- **Releases with audited assets** — every `v*` tag builds the four
  examples in the release profile on each required host (Linux x86-64,
  macOS arm64, Windows x86-64), runs `tools/rulisp-audit.sh` over each
  (Windows: the script prints SKIP, recorded as a gap in BOUNDARY §12),
  and attaches the twelve blobs, named for `load-blob-crate`, to a
  GitHub Release whose body is that version's CHANGELOG section.
  `make check-versions` holds every site that repeats the version to
  one string; docs/releasing.md is the checklist around it.
- **MSRV** — `rust-version = "1.78"` in the three crates, checked in CI
  on exactly that toolchain over the macros, the runtime, `rulisp` and
  the code the macros generate for `wordbag`.
- **Linux aarch64** — `SBCL / Linux aarch64 (best-effort)` on GitHub's
  arm runners: the loader's aarch64 paths (the target check, the blob
  suffix) execute for the first time. Promotion follows the written
  procedure; the `linux-arm64` release asset comes with it.
- **docs.rs front door** — the three macros document the full attribute
  grammar and the closed type vocabulary, every public item in `rulisp`
  has a doc, the crate-level example is a compiled doctest, and CI builds
  the docs with `missing_docs` and broken links as errors.
- **Docstrings, `describe`, and `:doc`** — the REPL front door. Every
  generated function and handle class now has a docstring synthesized
  from the manifest (the Lisp call shape, the Rust signature, and which
  condition an `Err` becomes); `(describe crate)` prints where the crate
  came from, its generation, versions, dump hook, handle classes and every
  export's signature. A glue crate's `///` comments travel too: the macros
  put them in the manifest as `:doc` (an enhancement key — older loaders
  ignore it) and they lead the docstring. `#.` inside a `:doc` is text,
  never code: the loader's reader runs with `*read-eval*` off.
- **`:rulisp-version` in the manifest, and the key-class rule** (BOUNDARY
  §11): a load-bearing manifest key raises `:schema`; an enhancement key
  rides the ignore-unknown-keys rule. Every crate now records the rulisp
  it was built with, and a loader whose major.minor is older signals
  `rulisp-version-skew` (a `style-warning`) and loads anyway. Stated
  plainly, because this rule is new: a crate built with 0.4 or later that
  declares `on_dump` loads cleanly on a **0.3** loader with its dump hook
  silently dropped — `:on-dump` predates the rule and stays at `:schema` 1,
  since a retroactive bump would refuse every newer crate on the 0.4.0
  loaders that support it fully. Upgrade the loader.
- **docs/stability.md** — what is stable and what 1.0 will promise: the
  four versioned surfaces (Rust API, the 32-symbol Lisp API, the manifest
  schema, the C ABI) and what breaks each; semver and deprecation policy;
  host support defined as the required CI matrix with a written
  promotion/demotion procedure; the manifest key-class rule; the 1.0 exit
  criteria; the Quicklisp prerequisites. CI now proves the system loads
  with no cargo on PATH.

### Fixed
- **Docstrings named a symbol that does not exist** — for a
  `Result<_, Error>` export the synthesized "Signals:" line said
  `<crate>:rust-error`; the condition is `rulisp:rust-error` itself.
  `describe` listed a `///`-documented export by its first doc line
  instead of its call shape; it now prints the call shape for every
  export. Both surfaced when the docs audit compared usage.md's
  transcript with the loader's real output.
- **Audit false positive on macOS** — `tools/rulisp-audit.sh` matched an
  inner `_signal` (`_dispatch_semaphore_signal`, imported by every macOS
  artifact) as a signal import; only a leading underscore is Mach-O's now,
  and the self-test checks the pattern both ways.
- **On CCL, lending a buffer to Rust stopped the world.** CFFI's
  `with-pointer-to-vector-data` is `ccl:with-pointer-to-ivector` there,
  whose body runs under `without-gcing` — so every `:string`, `:bytes`
  and `:vec` argument suspended garbage collection for every thread for
  the whole export, callbacks included (measured: 0 collections
  completed on another thread during a 600 ms borrow; ~30 unpinned). The
  loader now pins only long enough to memcpy into a heap buffer on CCL
  and lends the copy. SBCL keeps the zero-copy borrow; ECL's pin never
  inhibited GC. `v05.pin-does-not-stop-the-world` proves it on all three.

### Changed
- **Docs claim audit** — every capability, host and performance claim in
  README and the docs pages (371 of them) now has a citation in
  docs/claims.md or was corrected: the handle bullet (a second free is
  refused, a racing free is deferred), "Scope (v0.1)" and the stale
  "non-SBCL image dump" out-list, the quickstart's error-class rule and
  its ~50 ns figure, usage.md's `:target`-check story and its Quicklisp
  mention, benchmarks.md's 16× comparison, installation.md's
  cargo-not-found and Windows cache-path rows. One support table (README
  §Status) equals the required CI matrix; benchmarks.md carries SBCL,
  CCL and ECL columns. CI now also loads rulisp from Quicklisp's
  local-projects and `load-blob-crate`s a downloaded release asset, as
  the pages instruct.
- **The fuzzers can fail now.** `m4h.thread-race` and
  `m4h.random-op-sequence` asserted only "no unexpected condition"; a
  leaked in-flight count or a free that never reached Rust passed. Both
  now reconcile every generation's live-handle and live-allocation
  counters at the end (captured as wrapper closures, so generations
  reloaded mid-run reconcile against their own library copy), take their
  seed from `RULISP_FUZZ_SEED` (a `workflow_dispatch` input in CI) and
  print it on failure. Verified by mutation: with half of all frees
  skipped, the race fuzzer reports the leak. New `m4h.reload-under-load`
  proves BOUNDARY §4's cross-reload claim — strings round-tripped by four
  threads across three live reloads are released through their own
  generation's dealloc; every generation ends at zero.
- The fetch suite runs in CI (SBCL/Linux and CCL/Linux required; macOS
  best-effort) — the 23 tests BOUNDARY §12 cites had only ever run on the
  maintainer's machine. Its first run on CCL fixed two host assumptions in
  the tests themselves.

## 0.4.0 — 2026-09-02

### Added
- **BOUNDARY.md §12: the conformance table.** Every normative claim in
  §1–§11 (103 rows) classified as compile error, runtime check, test,
  documented-UB-by-design, or gap — with verified citations. The two
  remaining gaps are scheduled v0.4 items and say so in the table.
- Eight new conformance tests (`:rulisp-v04`), closing every prose-only
  claim the sweep found: swallowed `CallbackError` discards the stash;
  swallow-then-fail re-signals the original condition (status 4); a panic
  in a `*_free` shim is caught and swallowed (new `Grenade` fixture handle
  whose `Drop` panics); a poisoned mutex reports `rust-panic` on the next
  lock; `last_error` is thread-local AND per-library (concurrent failures
  in wordbag and rx never cross); out-params survive an ERR return
  untouched (FFI-level sentinel test); ECL's missing-C-compiler failure is
  the named `manifest-error` (injected via `c::*cc*`).
- **`on_dump: <fn>` in `rulisp::module!`** — a declared, zero-arg shutdown
  export the loader auto-registers as an image-dump hook (new wire-additive
  manifest key `(:on-dump "symbol")`; ABI 1 intact). Hooks run in load
  order; a failing hook is warned and skipped — a dump is never wedged by
  its own cleanup. The manifest refuses a declaration whose function takes
  parameters or returns a value (the call goes through a fixed signature),
  and `module!` rejects it at compile time too. `examples/fetch` converts:
  its hook quiesces every live tokio runtime, and the suite proves the
  whole story by dumping an image with a request in flight and restoring
  it (the two tests the v0.3 risk table promised).
- **docs/benchmarks.md** — a dated, release-profile baseline with the
  method; every number quoted in this changelog traces to it.
- **The ECL CI job is required** (was best-effort): 24 consecutive green
  runs since the 0.2 trampoline fix, now including the program-op
  deployment smoke. The workflow documents the demotion procedure.
- **`tools/rulisp-audit.sh`** — BOUNDARY §7 as a command for any glue
  crate (signal-disposition imports on the artifact, tokio signal/process
  features, `block_on`), run over every example by `make audit` in CI. A
  self-test builds a library that deliberately imports `signal()` and
  requires the audit to reject it, so the gate cannot go inert unnoticed
  again. fetch's `audit.sh` is now a wrapper adding its OpenSSL rule.
- **`#[rulisp(constructor, name = "…")]`** — an explicit Lisp name for a
  constructor. Load-bearing since 0.3 made duplicate `:lisp-name` a hard
  error: two constructors on one type both derived `make-<type>`, so a
  second constructor was inexpressible. The attribute grammar is now
  strict — a misspelled key, a non-string name, a name with reader syntax,
  or `name` on a non-constructor are compile errors (previously unknown
  keys were silently ignored).
- **ECL deployment story** (docs/distribution.md Pattern B′): ECL has no
  image dump; applications ship as `asdf:program-op` executables. The
  documented recipe (`:no-uiop t` because the distro ECL cannot satisfy
  ASDF's default static link of `cmp` — no `libcmp.a` — a prologue
  `require`, an explicit epilogue entry call, and the dependencies loaded
  before `program-op`, which the bundled ASDF 3.1.8.8 cannot build from a
  cold cache) is exercised by `tests/ecl-program`, a minimal consumer the
  ECL CI job builds and runs (`make test-ecl-program`).
- The dump/restore test (m7) now really runs on CCL — and Windows —
  instead of passing vacuously off SBCL, with a new assertion: a pre-dump
  handle GC'd after restore must not make a foreign call.

### Fixed
- **Two processes sharing one crate cache could crash each other.** The
  cache copy was named `<crate>-c<n>-<universal-time>` with `n` counted per
  process, so two instances started in the same second wrote the same
  file, and `copy-file` rewrote a library the other process had already
  mapped — a segmentation fault (found by the ECL deployment verification,
  reproduced 5/5). Copies now carry a per-process tag (pid, or a random
  tag where the host has none), recomputed on image restore; the sweep
  deletes this process's older generations immediately and other
  processes' copies only after an hour, so it can no longer unlink a copy
  another process is about to `dlopen`.
- A failed `dlopen` names the artifact the user asked for, not only the
  cache copy.
- rulisp's load-time compiles are quiet now: on ECL, `compile` prints
  per-function notes, so a deployed program printed dozens of lines every
  time it loaded a crate.
- The loader now rejects `(:option :bool)` in a hand-written manifest
  (`option-inner`); previously only the macro refused to emit it.

## 0.3.0 — 2026-08-14

### Added
- **`examples/fetch`** — an async HTTPS client (reqwest + rustls on tokio),
  the v0.3 flagship. Pull-based: `Client` owns the runtime, admission
  semaphore and ready queue; `Req` owns one exchange; bodies are pulled as
  `:bytes` or streamed to a file; headers cross as the raw CRLF field block
  both ways. It needs **no new boundary feature** — no wire change, no ABI
  bump. Ships with a Lisp veneer (conditions with a kind slot, restarts,
  `with-client`), a hermetic loopback test server, and `audit.sh`, an
  executable BOUNDARY §7 check.
- `make bench` — a benchmark suite for the boundary paths.
- **Windows support.** The loader is abstracted over `dlopen`/`dlsym` and
  `LoadLibrary`/`GetProcAddress`, `uintptr` is derived from the pointer
  size (naming a C type is wrong on LLP64), and artifact naming knows
  Windows drops the `lib` prefix. CI runs the full suite there, 177/177.

### Changed
- **Bulk `:bytes`/`:vec` marshalling**: pinned vector + `memcpy`, with the
  inbound side now a true zero-copy borrow. Measured 24× on a 1 MiB byte
  transfer and 307× on a 65k-element `i64` vector.

### Fixed
- **Soundness (issue #1):** an explicit `'static` in an export signature
  compiled cleanly — under `#![forbid(unsafe_code)]` — and let a glue
  crate retain a Lisp-owned buffer past the end of the call (use after
  free). The borrowing helpers' lifetimes were unconstrained, so the
  caller's signature chose them. Fixed at both layers: the macro rejects
  any explicit lifetime anywhere in an export signature (`&'static str`,
  `Option<&'static str>`, slices, handle references, `Callback<'static,…>`,
  and the `&'a self` receiver — each pinned by a trybuild test), and the
  helpers now take a per-call `ShimFrame` whose borrow the returned
  lifetime is inferred from, so the guarantee no longer depends on the
  macro remembering to check. Affects 0.1.0–0.2.1.
- Duplicate `:lisp-name` in a manifest silently shadowed one export; now
  rejected before anything is interned.
- `#[rulisp(constructor)]` on a `&self` method dropped the receiver and
  surfaced as a raw `E0061`; now a compile error naming the fix.
- The `Cargo.toml` scraper could not tolerate CR, so `use-crate` failed on
  any CRLF manifest. The tree is also pinned to LF now: a CRLF checkout
  broke the golden byte-identity fixture and turned Lisp format-string
  line continuations into `FORMAT-ERROR`.

## 0.2.1 — 2026-08-03

### Fixed
- crates.io pages rendered no README: the file lives at the workspace root
  and no crate declared `readme`, so it was never packaged. Crate metadata
  comes from the published artifact, hence a release.

## 0.2.0 — 2026-07-29

### Added
- **`:bytes`** — `&[u8]` parameters and `Vec<u8>` returns as
  `(unsigned-byte 8)` vectors; the `:string` wire minus UTF-8 validation.
- **`(:option T)`** — `Option` of scalars, strings and byte buffers, both
  directions; Lisp `NIL` ↔ `None`. `Option<bool>` is a compile error (nil
  cannot distinguish `None` from `Some(false)`).
- **`(:vec S)`** — `&[scalar]` / `Vec<scalar>` as element-counted buffers,
  freed via `dealloc(ptr, len * size, align)`; Lisp gets specialized arrays.
- **Stored callbacks** — `StoredCallback<A>` plus `rulisp:callback` tokens:
  a registered Lisp closure Rust may keep, clone and invoke later from any
  thread. Fail-safe lifetime — after the token is unregistered or
  garbage-collected, invocation returns an error instead of dangling.
  Cross-thread invocation verified on SBCL and CCL.
- **`rulisp:load-blob-crate`** and the `lib<name>-<os>-<arch>.<ext>`
  convention for prebuilt artifacts (no Rust toolchain needed), with
  `.github/workflows/blobs.yml` building them on release tags.
- Examples: `examples/rx` (the `regex` crate) and `examples/wasm` — a
  WebAssembly runtime for CL with fuel-metered CPU budgets, bounds-checked
  linear-memory access, and host functions that call back into Lisp.
- Docs: quickstart, installation, usage (the two consumption paths),
  distribution, roadmap.

### Fixed
- **ECL is now fully supported.** Callbacks segfaulted after any GC because
  of an apparently unreported ECL bug — `si:make-dynamic-callback` keeps its
  libffi closure metadata only in memory the Boehm GC does not scan
  (writeup: `docs/upstream/ecl-dynamic-callback-gc.md`). rulisp now compiles
  trampolines natively on ECL. Full suite green on ECL 21.2.1; one
  documented limitation remains — ECL cannot adopt foreign threads, so
  stored callbacks must be invoked from Lisp-visible threads there.

### Notes
- Constructor `&key` arguments were dropped from the plan: dogfooding showed
  positional arguments read better at the 0–2 argument sizes real
  constructors have. May return as an opt-in attribute.

## 0.1.0 — 2026-07-15

First release: the frozen boundary (ABI 1) and the PyO3-style workflow.

### Added
- `#[rulisp::handle]`, `#[rulisp::export]`, `rulisp::module!` — plain Rust
  in, `extern "C"` shims plus an embedded s-expression manifest out.
- Load-time binding generation on the CL side: `defun`s, CLOS handle
  classes, typed conditions from Rust error types, GC finalizers.
- Handle safety as a state machine: in-flight counting with deferred free
  makes double-free, use-after-free and free-during-call unreachable;
  handles are gated against the generation of the wrapper that made them.
- Panics become `rulisp:rust-panic`; `panic = "abort"` builds fail to
  compile. Borrowed callbacks tunnel Lisp conditions back without unwinding
  Rust frames.
- Live reload (unique-copy `dlopen`, never `dlclose`) and
  `save-lisp-and-die` support (session counter invalidates pre-dump state,
  bindings regenerate on restore).
- `rulisp:use-crate` (cargo build + load) with `build-error` and a
  `retry-build` restart; `use-value` restarts on failed calls.
- Verified on SBCL and Clozure CL, Linux and macOS.
