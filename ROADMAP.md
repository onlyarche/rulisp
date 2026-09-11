# Roadmap

## v0.6 — the no-break cycle, measured

docs/stability.md §8 criterion 3 asks for one full cycle after v0.5 with
no break on any surface. v0.6 is that cycle, and it makes the claim a CI
fact: each of the four surfaces gets a gate keyed to the 0.5.0 release
(cargo-semver-checks, a golden of the exported Lisp API, three-way
loader/crate/suite compatibility pinned to v0.5.0, an `abi_version()=2`
fixture), the last BOUNDARY §12 GAP closes, and the loader defects the
panel reproduced — the ones only a pre-freeze minor may fix — land
classified up front. No new boundary feature, no flagship; ABI 1 and
`:schema` 1 untouched. Full plan with demand cases, acceptance criteria
and cut order: [docs/design/v06-plan.md](docs/design/v06-plan.md).
Budget 2 M + 12 S. **All fourteen items shipped by 2026-09-11**; the
0.6.0 release follows docs/releasing.md, and 1.0's remaining criterion
is the release cycle itself completing without a break.

1. ✅ **Restore-failure dead pointers** — a crate whose reload failed on
   image restore kept the dead library's pointers; the next dump's hook
   run jumped into unmapped memory (SBCL `CORRUPTION WARNING`). Every
   foreign slot is stubbed with the functions now; `describe` says so;
   `v06.restore-failure-leaves-no-live-foreign-pointer` restores without
   the artifact and runs the hooks — red on the old loader (three checks,
   the fault in the log), green on SBCL and CCL after.
2. ✅ **`m4.gc-finalization` GC-timing assumption** — the aarch64
   "failure" was the pre-GC assertion racing a nursery collection inside
   the constructor loop (the handles were dropped as they were made);
   reproduced on x86-64 with a 256 KiB nursery, 4 of 5 runs. The test now
   holds all 1000 handles while it counts them, then drops every
   reference and runs the unchanged bounded GC loop — 0 of 5 under the
   same mutation. The arm promotion clock restarts at this commit
   (2026-09-08). Promotion, once the streak is documented (ECL's
   precedent: 24 runs over 35 days), is ONE commit: drop
   `continue-on-error`, rename to "(required)", add the
   `ubuntu-24.04-arm / linux-arm64 / so / lib` leg to blobs.yml and raise
   its asset count from 12 to 16, docs/releasing.md "twelve" → sixteen,
   the README §Status table, stability.md §5, usage.md's release blob
   list, docs/claims.md's two host rows, and a `load-blob-crate` step on
   the arm job (Case A exercised on arm). A second, *different* arm
   failure is a real finding: the job stays best-effort and this entry
   says how many runs it has.
3. ✅ **Cross-version gates pinned to v0.5.0** (M) — `make compat` on
   every push: the v0.5.0 loader loads this tree's wordbag (any warning
   but `rulisp-version-skew` is an error) and the v0.5.0 suite runs
   against this tree's loader (366/366 today); the release-asset step is
   pinned to v0.5.0. Both directions falsified: a renderer emitting
   `:schema 2` is refused by the old loader, and a changed `free` return
   value fails ten old-suite checks. `v06.abi-mismatch-refused` loads a
   fixture whose `abi_version()` answers 2 and expects the refusal with
   nothing registered — the §12 row that said "no suite test simulates
   a mismatch" now cites it. The pins move at each release
   (docs/releasing.md step 9).
4. ✅ **Close the last §12 GAP** (M) — the audit dispatches on the
   artifact's magic, not the host: ELF via `nm`, Mach-O via `nm` or
   rustup's `llvm-nm`, PE via rustup's `llvm-readobj --coff-imports`
   against Windows' analogues of a signal handler; a format it cannot
   read fails. The Windows CI job runs `make audit` (its self-test
   rejects the fixture DLL), and the release job re-audits all twelve
   downloaded assets on Linux before attaching them — verified with a
   `publish: false` dispatch for v0.5.0 (12 `audit ok`, assets
   untouched). `grep -c '^|.*GAP' BOUNDARY.md` is 0.
5. ✅ **"Required" becomes a release gate** — `tools/required-ci-green.sh`
   in the release job: the tagged commit's latest CI run must have every
   `(required)` job and `MSRV` green; no run, in progress, or fewer than
   six such jobs refuses, naming the job; `skip-ci-gate` is the loud,
   documented override. Live: a scratch tag on a commit with no CI run
   was refused before any asset was touched; v0.5.0 passed. The matching
   repository ruleset on `main` is the maintainer's call — it would
   force every change through a pull request — and is not set.
6. ✅ **Rust API gate** — `cargo-semver-checks` over the three crates
   against the latest crates.io release with `--release-type minor`, in
   the cargo-tests job on every push (196 checks per crate, green on
   HEAD). Falsified: renaming `Error::msg` reports
   `inherent_method_missing` and fails. `rulisp::runtime` stays public
   and checked; hiding it is the 1.0 major's first commit.
7. ✅ **Lisp API gate** — `tests/golden/lisp-api.sexp` pins the 32
   exports with kind, superclasses and lambda lists;
   `v06.exported-api-golden` compares it on every host (lambda lists
   exactly on SBCL, by parameter names on CCL and ECL). Falsified: a
   golden without `retry-build` fails naming it. From here every
   package.lisp change co-updates the golden — item 8 is the first.
8. ✅ **Export what the docs already name** — `rulisp-version-skew` with
   its three readers and the eleven condition readers that were internal
   while their siblings were exported (32 → 47, the golden regenerated in
   the same commit); a class documentation on every exported condition,
   `crate` and `callback-token` (when it is signaled, which restart) and a
   docstring on every exported reader; `v06.exports-are-documented` keeps
   it so (red today: 13 classes and 10 readers). `Error::msg`'s Rust doc
   no longer names `<crate>:rust-error`.
9. ✅ **`crate-generation` is a reader** — the exported `setf` let a stale
   handle into a new library (reset the counter, reload); the writer is
   gone, `v06.crate-generation-is-read-only` checks no exported symbol
   names a setf function, and the panel's probe now stops at the `setf`
   with an undefined-function error. A §4 soundness fix, the cycle's one
   non-additive Lisp change; the v0.5.0 suite under `make compat` only
   ever read the counter and stays green.
10. ✅ **A cargo that cannot run is `build-error`** with a `retry-build`
    that looks cargo up again, identically on every host. Before: SBCL
    let the host's error escape, CCL signaled with an empty stderr, and
    the restart re-ran the old lookup — the test's one-shot retry showed
    the old code looping forever on CCL. `v06.missing-cargo-is-a-build-error`
    asserts the class, a non-empty stderr, the restart, and a retry that
    recovers; `rulisp::*cargo*` (internal) names the missing program
    without touching the environment.
11. ✅ **`Option<f32>`/`Option<f64>` NIL** was a host TYPE-ERROR on SBCL
    and CCL — the wrapper passed a fixnum 0 in the value slot; the
    placeholder is typed now. `opt_scale`/`opt_scale32` joined wordbag
    (oracle shims and the manifest golden co-updated);
    `v06.option-float-nil-is-none` was red on the old codegen and is
    green on every host. quickstart states the plain-scalar policy as it
    is: host-checked.
12. ✅ **Renamed artifacts** — the "not a rulisp crate" refusal now says
    to pass `:crate` (distribution.md shows the call), and a load that
    does not commit deletes the cache copy it made before verifying
    (best-effort on Windows). `v06.renamed-artifact-names-the-fix` and
    `v06.failed-load-leaves-no-cache-copy` were red on the old loader.
13. ✅ **Quicklisp dist dry run in CI** — `make dist-dryrun` exports HEAD
    with `git archive`, finds every `.asd`, and `quickload`s every system
    each defines with no cargo reachable (off PATH, `RULISP_CARGO` pointed
    at nothing — rulisp's lookup would otherwise find `~/.cargo/bin`):
    `rulisp`, `rulisp/test`, `rulisp-ecl-smoke` load. Falsified: a
    top-level `use-crate` in an exported suite file turns it red, and so
    does a reachable cargo. stability §9 no longer claims `rulisp/test`
    is excluded from the dist — it loads; only running it needs cargo.
14. ✅ **Close the cycle** — `tools/check-1.0.sh` holds the mechanical
    part of the exit criteria (run by the MSRV job); `tools/check-dist.sh`
    says which rulisp the Ultralisp dist serves (0.3.0, a week after the
    v0.5.0 tag — releasing.md step 8 is a command now, and the source
    cleanup on ultralisp.org is the maintainer's); §12's 110 drifted
    `file:line` ranges re-anchored by a four-way verification and a
    checker, its three false "no test" cells cite the tests that exist,
    and `v06.invalid-utf8-is-invalid-argument` drives status 3 end to
    end; the stale ROADMAP sentences, the claims count, CHANGELOG's
    surfaces paragraph and stability §3's review result are in place.

Found during item 1, not scheduled (a decision for the maintainer):
a **truncated artifact at restore** — the file is present but cut
short, as a partial copy leaves it — faults inside glibc's `dlopen`
(SBCL: `Signal 7 … Continuing with fingers crossed`; ld.so's load lock
is left held, so a later `reload-crate` from another thread hangs; CCL
hangs at startup). Reproduced by the item-1 attack agent on SBCL 2.1.11
and CCL 1.13 (scripts in the session scratchpad). The stub itself works;
the hazard is the dlopen of a corrupt file, which no check precedes. A
fix would validate the object file's headers against its size before
`dlopen` (ELF, Mach-O and PE each need their own ~15 lines) — an S item
if wanted, with a test that truncates the artifact between dump and
restore.

Not in v0.6 (causes in the plan): a flagship (no external request),
hiding `rulisp::runtime` (the 1.0 major), a deprecation round (nothing
to deprecate), renames, scheduled arm promotion (the streak decides),
scalar coercion, structured error payloads, Miri/sanitizers/soak,
introspection APIs without a consumer, and every v0.4/v0.5 refusal.

## v0.5 — a 1.0 candidate a stranger can verify

**Released as 0.5.0 on 2026-09-04** (crates.io, tag `v0.5.0`, GitHub Release with 12 audited assets). Items 1–9 and 11 shipped; 10 cut.

Make every front door true — CI runs what BOUNDARY §12 cites, releases
exist, docs.rs and the REPL explain themselves — fix the two defects §12
cannot see, and write down what 1.0 promises. No new boundary feature, no
flagship (still no external request; the tracker holds one closed
soundness issue). ABI 1 frozen; every wire change is an additive manifest
key. Full plan with demand cases, acceptance criteria and cut order:
docs/design/v05-plan.md (three-proposal panel, two verifying judges).

1. **Run the fetch suite in CI** — 23 tests §12 cites as enforcement have
   only ever run on the maintainer's machine.
2. ✅ **docs/stability.md** — the four versioned surfaces, semver and
   deprecation policy, host support = the required matrix with the
   promotion/demotion procedure, the manifest key-class rule, the 1.0 exit
   criteria, and the Quicklisp prerequisites (listed, not scheduled). The
   SBCL/Linux job now proves `(ql:quickload :rulisp)` needs no cargo.
3. ✅ **CCL pin semantics** — confirmed and fixed: with a 4 MiB buffer
   lent for 600 ms, another thread completed 0 collections on CCL (~30
   unpinned); the loader now pins only for a memcpy there. The test
   counts completed collections via the host GC counter — its first
   version counted requests and passed on the broken code, its second
   let a warm-up window through; the shipped one starts counting at the
   call.
4. ✅ **Falsifiable fuzzers** — per-generation live-count reconciliation
   (captured wrappers, so reloaded generations reconcile against their own
   copy), `RULISP_FUZZ_SEED` in messages and as a CI dispatch input, and
   `m4h.reload-under-load` for the §4 cross-reload claim. Mutation-tested:
   skipping half the frees makes the race fuzzer fail.
5. ✅ **Manifest skew rule + `:rulisp-version`** — the key-class rule is
   normative in BOUNDARY §11; every crate records the rulisp it was built
   with, and an older loader warns (`rulisp-version-skew`, a
   style-warning) and loads anyway. The golden carries a placeholder
   version so a release bump does not rewrite it. The 0.3-loader exposure
   of `on_dump` is stated in the changelog rather than re-fixed.
6. ✅ **REPL front door** — all three layers: docstrings synthesized from
   the manifest on every function and handle class, `describe-object` on
   a crate, and Rust `///` carried as the `:doc` enhancement key with a
   proper string escaper in the renderer (the golden now carries nine).
7. ✅ **docs.rs front door** — `///` on the three macros with the
   attribute grammar and the type table, `missing_docs` clean on `rulisp`
   and `rulisp-macros`, a compiled crate-level doctest, `make doc` and a
   CI step with `RUSTDOCFLAGS=-D warnings`.
8. ✅ **Release engineering + Linux aarch64** — every `v*` tag now
   yields a GitHub Release with twelve audited assets (three required
   hosts × four examples, named for `load-blob-crate`; Windows unaudited,
   recorded in BOUNDARY §12) and the CHANGELOG section as body; v0.4.0
   was backfilled the same way and its Linux blob loads. The first macOS
   run found a real audit bug (an inner `_signal` read as a signal
   import). `rust-version = "1.78"` with an MSRV job that also checks
   generated code, `make check-versions` (fails on a skewed site),
   docs/releasing.md, and `SBCL / Linux aarch64 (best-effort)` — green on
   its first four runs; its one failure, on the 0.5.0 release commit,
   was `m4.gc-finalization`'s pre-GC assertion racing a nursery
   collection inside the constructor loop — a timing assumption in the
   test, reproduced on x86-64 with a 256 KiB nursery, never an arm
   difference. Fixed in v0.6 item 2, where the promotion clock restarts.
9. ✅ **`:string` ASCII fast path** — a typed check-and-store loop in
   both directions, babel from the first char/byte ≥ 128, a peek before
   any allocation so non-ASCII text pays nothing extra: 64 KiB ASCII
   1015 → 318 µs (3.2×), non-ASCII unchanged. Differentially tested
   against babel on all three hosts (no counterexample in ~12k checks)
   and swept adversarially through echo; zero-copy `:string` stays
   refused.
10. ✂ **Miri over the generated shims** — cut, as the plan's cut order
    said to do first: the shims are macro-generated and byte-identical
    to the hand-written oracle crate under the golden gate, so the
    expected yield of a nightly Miri job did not justify another
    best-effort CI leg this cycle. Not deferred to a date; re-proposed
    only with a concrete UB hypothesis.
11. ✅ **User-facing docs claim audit** — 371 claims across README and
    the six docs pages, each cited in docs/claims.md or corrected (45
    were flagged; 24 false). It found two loader defects, not just prose:
    docstrings naming a nonexistent `<crate>:rust-error`, and `describe`
    printing doc prose where the call shape belongs. One support table,
    per-host benchmark columns, and two CI steps that follow the pages'
    own instructions (local-projects, a downloaded release asset).

Not in v0.5 (causes in the plan): a flagship example, vocabulary round 2,
zero-copy `:string`, a retroactive `:schema 2`, print-object polish, a
soak workflow, cargo-fuzz/sanitizers (Miri fits; sanitizers cannot
coexist with SBCL's signal-driven GC), `cargo rulisp new`, LispWorks/
Allegro/ABCL/ocicl, macOS x86_64 blobs, Quicklisp (1.0), constructor
`&key`, push callbacks, dlclose, any ABI bump.

## v0.4 — enforced, everywhere

Issue #1's reporter praised the boundary because "the surrounding
invariants are otherwise enforced rather than merely documented" — and
0.1.0–0.2.1 were yanked over the one claim that wasn't. v0.4 makes that
property total: every normative BOUNDARY.md claim becomes a compile error,
a runtime check, or a non-vacuous test on every claimed host, and the §10
dump discipline becomes structural. ABI 1 stays frozen; nothing here adds
an ECL load-time toolchain requirement. Full plan with demand cases and
acceptance criteria: docs/design/v04-plan.md (scoped by a three-proposal
panel with two verifying judges).

1. ✅ **BOUNDARY conformance sweep** — §12: all 103 normative claims
   classified with verified citations. The six pre-verified prose-only
   gaps got tests, plus two the sweep itself found (per-library
   last_error isolation; loader-side `(:option :bool)` rejection).
2. ✅ **De-vacuous m7** — the dump/restore test now really runs on CCL
   (`uiop:dump-image` → `ccl:save-application`; assertions live in
   `*image-entry-point*` since CCL's toplevel is fixed), plus a new
   finalizer assertion: a pre-dump handle GC'd after restore must not make
   a foreign call. First real CCL execution passed immediately — the
   machinery was portable all along; only the test was missing.
3. ✅ **`on_dump`** — a declared zero-arg shutdown export in
   `rulisp::module!`, auto-registered as a dump hook by the loader
   (wire-additive `(:on-dump "symbol")` key; validated at macro AND
   loader). fetch converted; the flagship test dumps an image with a
   tokio transfer live and restores it — the two tests v0.3's risk table
   promised.
4. ✅ **ECL deploy story** — no `dump-image` exists there (verified);
   `asdf:program-op` is the delivery path. Three traps found and
   documented (docs/distribution.md Pattern B′): the distro ECL cannot
   satisfy ASDF's default static link (its `cmp.asd` names a `libcmp.a`
   the package does not ship), so `:no-uiop t` + a prologue `require`;
   `:no-uiop` also drops the entry-point wiring; and the bundled ASDF
   3.1.8.8 cannot `program-op` the dependencies from a cold cache — load
   them first. `tests/ecl-program` is the smoke consumer, run by the ECL
   job (`make test-ecl-program`). The adversarial verification of this
   item also found a real core bug on every host — two processes sharing
   a cache could crash each other (copy names were unique only per
   process) — and rulisp's load-time compiles went quiet, since a
   deployed ECL program printed fifty compiler notes per crate load.
5. ✅ **`#[rulisp(constructor, name = "…")]`** — wordbag's second
   constructor (`make-word-bag-from`) is the demand case; the attribute
   grammar became strict on the way (misspelled keys used to be ignored
   silently). Oracle, manifest and golden co-updated; trybuild pins the
   four rejection paths.
6. ✅ **Reusable signal-audit tool** — `tools/rulisp-audit.sh`, run over
   all four examples by `make audit` in CI; `tools/audit-fixture` imports
   `signal()` on purpose and the self-test requires the audit to reject
   it. The last GAP row in BOUNDARY §12 closed with it.
7. ✅ **docs/benchmarks.md** — dated, release-profile baseline with host,
   toolchain and raw `make bench` output; the CHANGELOG multipliers trace
   to two of its rows. It also says plainly that `:string` is the slow
   path (UTF-8 codec, deliberately deferred) — pass bulk data as `:bytes`.
8. ✅ **ECL CI promoted to required** — 24 consecutive green runs since
   2026-07-29 (35 days), item 4's program-op smoke included. The workflow
   carries a written demotion procedure so a flake is handled in one
   honest commit, never by quietly flipping a flag.

Not in v0.4 (causes in the plan): boundary vocabulary round 2
(`(:vec :string)`, multiple values, tagged enums), the push/doorbell
callback layer, reload semantics for on_dump, a new flagship example,
print-object polish, LispWorks/ABCL/ocicl, Quicklisp (1.0, user
decision), constructor `&key`, anything that would `dlclose`.

## v0.3 — prove it on something hard, and keep it fast

Theme: v0.1 froze the boundary, v0.2 filled in types and callbacks; v0.3
takes a demanding real consumer and makes the performance claims defensible.
The flagship is an **async HTTPS client** (`examples/fetch`: reqwest +
rustls on a tokio runtime), chosen because CL's TLS story is genuinely
painful and because tokio is the hardest test of the v0.2 thread contract.

A design panel (three independent designs, two judges) settled the API:
**pull-based**, two handles (`Client` owning the runtime + readiness queue,
`Req` per in-flight request), bodies pulled chunk-by-chunk as `:bytes`,
headers crossing as the raw CRLF field block in `:bytes` both ways, every
wait capped in Rust with the loop in Lisp, and a thin pure-Lisp veneer
providing conditions, restarts and `with-client`. Headline finding:

> **It requires zero new boundary features.** No wire change, no ABI bump,
> no new type token. `:bytes` in callback params, `(:vec :string)`,
> core cancellation and `Vec<Vec<u8>>` were each examined and refused with
> cause — the pull design either doesn't need them or is better without.

### Prerequisites (all zero-wire, ABI 1 preserved)
- ✅ **Bulk `:bytes`/`:vec` marshalling** — pinned vector + `memcpy` fast
  paths, element-wise fallback retained. Measured: 1 MiB byte transfer
  **24× faster**, a 65k-element `i64` vector **307× faster**. A flagship
  moving megabyte bodies could not ship on the old marshaller.
- ✅ **Duplicate `:lisp-name` rejected at the manifest** — shipped v0.2.1
  silently shadowed the loser (two `#[rulisp(constructor)]` fns on one type
  both compute `make-<type>`), leaving it unreachable with no diagnostic.
- ✅ **`#[rulisp(constructor)]` on a `&self` method is a compile error**
  with the workaround in the message — it used to drop the receiver and
  surface as a raw `E0061` inside generated code.
- ✅ **Contract text** (BOUNDARY §7/§10): cap blocking waits in Rust,
  refuse re-entry from runtime threads, and the surprising one — dumping
  with live foreign threads succeeds silently, so thread-owning crates need
  an explicit shutdown called from a dump hook.

### Remaining
- ✅ `examples/fetch` — shipped, with its Lisp veneer and a hermetic
  loopback test server. An adversarial review (3 lenses, per-finding
  verification) produced **18 findings, all 18 confirmed**, most reproduced
  empirically; every one is fixed and covered by a regression test. The
  sharpest were: a failed `download` reported as success (the sink drain
  loop could exit without ever re-entering the read that carries the
  error), an uncapped default body size that would exhaust the Lisp heap,
  CRLF request-splitting through caller-supplied header values, an
  audit-gate regex that could never fire because glibc imports are
  version-tagged, and a `TaskGuard` ordering that published "done" before
  releasing the admission permit.
- ✅ **Windows works** — and earlier than planned. `uintptr` is derived
  from the pointer size (naming a C type was wrong on LLP64, where
  `unsigned long` is 32 bits); the loader is abstracted over
  `dlopen`/`dlsym` and `LoadLibrary`/`GetProcAddress`; artifact naming
  knows Windows drops the `lib` prefix and uses `.dll`; the unique-copy
  load policy, added for macOS dyld caching, also sidesteps the DLL-in-use
  lock. Three real portability bugs surfaced on the way, none of them
  Windows-only in principle: a Cargo.toml scraper that could not tolerate
  CR, the golden fixture broken by CRLF translation, and Lisp format
  strings whose `~` end-of-line continuation is not the tilde-newline
  directive once a CR sits between them (the tree is now pinned to LF).
  The CI job is **required**, at 177/177. (It runs three fewer assertions
  than Linux: `fx.target-check` guards a couple of them behind
  `#+(and x86-64 linux)`.)
- ✅ A worked Deploy recipe (docs/distribution.md), including the two things
  that bite silently: platform-named artifacts and quiescing foreign
  threads in a dump hook.
- **Quicklisp: deliberately deferred to 1.0.** Until then rulisp ships via
  Ultralisp (and crates.io for the Rust side) — a pre-1.0 API does not
  belong in a dist users treat as stable.

Explicitly **not** in v0.3: the push/doorbell layer (no `StoredCallback` in
the example — declaring one forces `compile-file` and a C toolchain on ECL
at binding-generation time), streaming uploads, cookie/redirect/proxy
configuration, zero-copy `:string`, constructor `&key`.


v0.1.0 shipped the frozen boundary (BOUNDARY.md, ABI 1) and the PyO3-style
developer experience. Everything below is **additive on the wire** — the
manifest's ignore-unknown-keys rule and the universal `dealloc(ptr, size,
align)` ABI were designed so these land without an ABI bump.

Items are grouped by theme; roughly priority-ordered within each. Demand
notes reference real cases hit while building the examples.

## v0.2

### 1. Type vocabulary: binary data and optionals

- ✅ `:bytes` — **shipped** (0.2 dev): `&[u8]` / `Vec<u8>` crossings, same
  `(ptr,len)` + dealloc convention strings use, no UTF-8 validation.
  Verified on SBCL + CCL; oracle/golden updated in lockstep.
- ✅ `(:option T)` — **shipped** (0.2 dev): `Option<scalar/&str/&[u8]>`
  params and `Option<scalar/String/Vec<u8>>` results as a (present, value)
  pair; Lisp NIL ↔ None. `Option<bool>` is rejected at compile time (nil
  cannot distinguish None from Some(false)). rx gained `first-match`.
- ✅ `(:vec T)` — **shipped** (0.2 dev): `&[scalar]` params / `Vec<scalar>`
  results as element-counted `(ptr,len)`, freed via
  `dealloc(ptr, len*size, align)`; Lisp side gets specialized arrays.

### 2. Stored and cross-thread callbacks

- ✅ **Shipped** (0.2 dev): `StoredCallback<A>` + `rulisp:callback` tokens
  — registered closures Rust may store, clone and invoke from any thread
  (foreign threads are adopted; verified on SBCL AND CCL). Fail-safe
  lifetime: a dead id warns and errors, never dangles. The wire is the
  `userdata` slot v1 reserved — ABI 1 unchanged. Demand case closed: wasm
  host functions (examples/wasm `on-notify` + guest.wat).
- ✅ Queue-polling: documented as a five-line user pattern in
  docs/usage.md — a dedicated helper adds nothing over it.

### 3. Constructor `&key` arguments

**Deferred with cause** (was: deferred from M3). Dogfooding overturned the
premise: `(rx:make-regex "[0-9]+")` reads strictly better than
`(rx:make-regex :pattern "[0-9]+")` — all real constructors so far take
0–2 obvious positional arguments. Revisit only when a multi-argument
constructor demand case appears, and then as an OPT-IN attribute
(`#[rulisp(constructor, keyargs)]`), not a blanket rule.

### 4. Distribution tooling

- ✅ `rulisp:load-blob-crate` + the `lib<name>-<os>-<arch>.<ext>` naming
  convention, and `.github/workflows/blobs.yml` building release blobs for
  Linux x86-64 and macOS arm64 (dispatch + release tags).
- Since closed: the worked Deploy recipe shipped in v0.3
  (docs/distribution.md Pattern B); Quicklisp submission is a 1.0
  decision (docs/stability.md §9), with the dist dry run in CI since v0.6.

### 5. Portability

- ✅ **ECL callback segfault — root-caused and fixed** (0.2 dev): an
  apparently unreported ECL bug (`si:make-dynamic-callback` doesn't
  GC-protect its libffi closure metadata — writeup for upstream filing in
  docs/upstream/ecl-dynamic-callback-gc.md). rulisp natively compiles
  trampolines on ECL instead of eval'ing them; full suite now green on
  ECL 21.2.1 (139/139), with one documented platform limitation:
  foreign-thread stored-callback invocation (ECL cannot adopt foreign
  threads).
- Image dump/restore on non-SBCL hosts: the m7 test runs for real on CCL
  and on Windows since v0.4; ECL has no image dump and ships
  `program-op` executables instead (docs/distribution.md Pattern B′).
- Windows: excluded from v1; needs LLP64 `uintptr` handling, DLL
  file-locking discipline for reload, and CI.

### 6. Performance

- Zero-copy paths for `:bytes`/`:string` (static-vectors,
  `with-pointer-to-vector-data`) where the borrow contract allows.
- A small benchmark suite (call overhead, string sizes, callback round
  trips) so regressions are visible.

### 7. DX polish

- Opt-in `Display`-driven `print-object` for handles (DESIGN.md §6.4).
- ✅ Wasm linear-memory access via `:bytes` — shipped alongside `:bytes`
  (bounds-checked `memory-read`/`memory-write` + a guest function summing
  a host-written buffer). Host functions via stored callbacks shipped
  with 0.2 (§2 above); WASI stays unplanned.

## Later / exploratory

- Tagged enums / richer value types (UniFFI-style semantics without the
  per-call serialization cost).
- Multiple return values mapped to CL `(values ...)`.
- Bulk zero-copy data via Apache Arrow's C data interface.
- LispWorks / Allegro / ABCL validation.

## Non-goals (unchanged from v0.1)

Auto-binding arbitrary existing crates; `&mut self` across the boundary;
`dlclose`/true unloading; Rust holding Lisp object references. See
DESIGN.md §1.
