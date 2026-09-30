# Roadmap

## 1.0 — the freeze (after 0.8)

What the 1.0.0 commit contains, measured in advance with
cargo-semver-checks, the release-day sequence, the commit that opens
1.1 and the Quicklisp issue text:
[docs/design/v10-plan.md](docs/design/v10-plan.md).

## v0.8 — the axum flagship (next)

An HTTP server with Lisp handlers on axum — probed in the v0.7 panel (47
packages, 38 s cold build, §7 sweep clean, loopback answered) and
pull-based by design, since a stored callback returns no value to Rust.
MCP (rmcp) follows it: its HTTP transport sits on axum. Planned by a
panel when the cycle opens. The cycle is open: the gates compare against
v0.7.0, and the aarch64 job loads its own release asset with
`load-blob-crate`, as the x86-64 job does.

## v0.7 — the freeze rehearsal, and the flagship the ask named

The freeze rehearsal before 1.0 (0.8, the axum flagship, comes first —
the maintainer's call, 2026-09-28), and the first cycle with a flagship on
demand — the maintainer's own ask ("the very first reason I made this
project was wasm; what about the AI-agent programs built in Rust?").
No surface moves: ABI 1, `:schema` 1, the Lisp API golden and the Rust
API (checked as a minor against 0.6.0) all unchanged. The cycle fixes
the two gates that go red on *allowed* changes before 1.0 freezes
them, lands the corrupt-artifact hazard found in v0.6, stops the dist
indexing a test program, promotes what the written procedures have
earned, gives `examples/wasm` the suite it never had and grows it into
a WASI plugin sandbox, makes `make clean` clean, and writes the 1.0.0
plan from a measured rehearsal. Full plan with demand cases, acceptance
criteria and cut order: [docs/design/v07-plan.md](docs/design/v07-plan.md).
Budget 1 L + 1 M + 7 S.

**Released as 0.7.0** (2026-09-30): all nine items, the flagship with
its review and its adversarial pass, a pre-release review of the whole
cycle, and a Rust-built guest in the suite. No versioned surface moved.

1. ✅ **`make compat` tells additive from breaking** — the old tree's
   `rulisp.asd` is assembled from this tree's `rulisp` defsystem and the
   previous release's `rulisp/test`, this tree's golden replaces the
   archived one, and `tests/compat/api-subset.lisp` requires every
   previous entry present and unchanged. Falsified both ways: a
   documented new export turned the old gate red and passes now; a new
   loader file the old `.asd` never loaded fails the old gate and loads
   now; a golden missing `retry-build`, or with `use-crate`'s lambda
   list changed, fails api-subset by name.
2. ✅ **A truncated or corrupt artifact is refused before `dlopen`** —
   `%check-artifact-shape` reads the headers before the cache copy is
   made: ELF section table and every `PT_LOAD`, Mach-O `LC_SEGMENT_64`s,
   PE section raw data, each must end within the file; a violation is
   `crate-not-loaded-error` "truncated or corrupt". Falsified: against
   the unmodified loader `v07.truncated-artifact-is-refused` fails
   because the 60 % cut *loads* (generation bumped, artifact replaced)
   and the 4 KiB head's subprocess log carries `Signal 7`, `CORRUPTION
   WARNING` and `bus error`; after, 13/13 and none of the three; all
   twelve v0.6.0 assets accepted and 36 cuts of them (60 %, 4 KiB,
   −1 KiB) refused naming the segment, section or table that overruns.
3. ✅ **One `.asd` in the tarball** — the ECL smoke's system file is a
   committed template, `rulisp-ecl-smoke.asd.in`, that its `build.lisp`
   writes out as a `.asd` at test time (ignored by git); `git ls-files
   '*.asd'` is `lisp/rulisp.asd` alone and the dist dry run asserts two
   systems, not three. Ultralisp's index still lists `rulisp-ecl-smoke`
   until it polls this tree — `tools/check-dist.sh` now prints the
   dist's system rows so the change is visible when it happens.
4. ✅ **Version-agnostic manifest-golden comparison** — both golden
   tests replace the value of the `:rulisp-version` key by pattern
   instead of the literal `"0.4.0"`: with the golden's version set to
   `9.9.9` both stay green (both red before), any other changed byte
   still turns both red, and releasing.md step 3 has nothing left to
   edit.
5. ✅ **Every attached asset has a job that runs its suite on its host** —
   the macOS fetch step is required (promoted 2026-09-28 after 37
   consecutive green runs; demotion procedure beside it); fetch runs on
   Windows as a best-effort step, `fetch.dll` found by the example's
   audit wrapper — its first run: `audit ok`, 117/117. Streak from
   2026-09-28 (run 36388353221).
6. **aarch64** — A ✅: the deployment path rehearsed from branch
   `arm-deploy-rehearsal` (blobs.yml + the `ubuntu-24.04-arm /
   linux-arm64 / so / lib` leg and the 16-asset count, not merged):
   `publish: false` dispatch for v0.6.0, run 36388354650 — the arm leg
   built and audited the four examples in 1m1s, the release job
   re-audited 16 downloaded assets on Linux, nothing published. B ✅
   (2026-09-30): promoted in one commit at 26 consecutive green runs on
   main since 2026-09-08 (34173012968 … 36669486379) — the job is
   `(required)` with the promotion/demotion record beside it, blobs.yml
   has the `linux-arm64` leg and expects 16 assets, the release gate
   counts seven jobs, and README, stability §5, releasing, usage,
   installation and the claims register say so. The arm job's own
   `load-blob-crate` step came with the first release that has an arm
   asset, in the commit that opened 0.8.
7. **The flagship (L)** — *commit 1 done:* `tests/suite/wasm.lisp`
   pins the existing API (15 tests, 46 checks, SBCL/CCL/ECL; four
   mutations — `boom` that no longer traps, `host.notify` swallowing the
   closure's failure, a wrapped memory offset, a wrong expected value —
   each fail the test that names the claim). *Commit 2 done:* the `Wasi`
   handle — fuel mandatory, one memory number for memory, table and
   captured output, a scheduler that never waits (the stock one slept
   3.0 s at zero fuel, measured), stdio as bytes, preopens as the whole
   filesystem — with sixteen `wasm.wasi-*` tests over hand-written
   guests; seven readers established the facts first (the WASI context
   API, every fuel-free blocking path, the output cap's errno — an
   `io::Error` would have been a trap — wasmi's limits, the macros, the
   three Lisps' scratch idioms, the guests), then the branch run was the
   cross-host check: run 36663154994 on `wasi-sandbox`, 8/8 green at the
   first attempt — the sixteen tests ran on Windows (588 checks, the
   symlink test skipping itself), macOS arm64 and Linux aarch64 (599),
   SBCL/CCL Linux (602) and ECL (582); the escape refusals answered the
   same EPERM through cap-std's manual resolver on macOS and Windows as
   through Linux's openat2. A five-lens adversarial review of the branch
   (rust, sandbox attacks, test vacuity, hosts, docs; every unreproduced
   finding given a skeptic; a critic last) found 21, kept 19, all fixed
   before the merge: preopens are now read-only (a guest wrote 8 MiB of
   host disk for 5,000 fuel and could plant symlinks), the guest's
   descriptors are capped at 256 and released when the run ends (a
   guest exhausted the image's descriptors and kept them until the
   handle was freed), `_start`'s type is checked at load, NUL bytes and
   malformed or repeated environment keys are refused, a `(start)`
   section that exits is refused by name, every method answers rather
   than blocks while another thread is inside a run, entropy comes from
   the OS instead of a thread-local RNG that registered a fork handler,
   the wall-time estimate says minutes where it said seconds, and the
   tests pin the two-memory/two-table refusal, the unaligned and the
   stderr cap, the (start) section's fuel, the defaults of stdin and
   argv, and configuration after a run. Two review remarks were refuted
   by their skeptics (an aligned cap is not a defect; inheriting stdin
   would be caught). *The pass, done:* attacks written against the
   finished sandbox, each now a test or a stated limit. Found and closed:
   **host calls are not metered by fuel** — `random_get` of 1 MiB in a
   loop ran 103.6 s on 100,000 fuel (1e9: days), `fd_readdir` of a
   5,000-entry directory likewise — so the time inside host calls has a
   budget of a second plus a microsecond per unit of fuel (the same
   guests now trap at 1.10 s; `wasm.wasi-host-time-is-budgeted`); **a
   FIFO inside a preopen blocked the run forever** — a preopen now
   offers regular files and directories only
   (`wasm.wasi-special-files-are-refused`). Attacked and held, now
   pinned: unbounded recursion and a WASI call without an exported
   memory are traps (`wasi-traps-leave-the-image-standing`); the cap
   cuts inside a call and inside an iovec, `table.grow` answers −1 at
   the bound (added to the output and memory tests); `path_filestat_get`
   outside is EPERM and an opened subdirectory is its own root
   (`wasi-every-path-call-stays-inside`); reading through the wrapper
   works — readdir, filestat, seek, pread (`wasi-reads-through-the-
   wrapper`); `fd_renumber` onto stdout loses nothing and writes nothing
   (`wasi-renumbering-stdout-loses-nothing`); a second thread's call
   during a run answers at once (`wasi-busy-handle-answers`); fuel and
   memory at u64's maximum, a memory number of 0, and freeing the handle
   from another thread during a run behave (probed, not pinned). Stated
   as limits in SECURITY.md and on `make-wasi`: in-process, not
   isolation; ~3× the memory number resident; one host call in flight;
   the module file's size; real clocks, real entropy, names and sizes
   under a preopen and the text of its symlinks; a slow or changing
   filesystem. Two mutations fail exactly the tests that name them (the
   budget check removed; the file-type check removed — that one hung
   the suite until the test got a writer that releases a wrongly
   admitted open, so a regression now fails instead of hanging CI).
   SECURITY.md is
   re-cited and says `make-wasm` is for trusted modules, as its docstring
   now does. The item: `examples/wasm` gets the suite it never had
   (six README claims, SECURITY.md's "supported approach", three blobs
   per release, zero tests), then grows a WASI plugin sandbox: a second
   `Wasi` handle on wasmi 0.50 + wasmi_wasi 0.50 + cap-std (117 packages,
   no C, 43 s cold build, audit-clean — probed), fuel and one memory cap
   that also bounds captured stdio, explicit args/env/preopens, exit code
   as a value; hand-written `.wat` guests; an adversarial pass over the
   sandbox claims before the tag. Boundary features it would want are
   recorded as 1.x findings, not 0.7 wire changes.
8. ✅ **`make clean` removes every regenerable artifact** the suite leaves
   in the tree — every `.gitignore` entry by name (a 3.9 GB checkout back
   to 40 MB, `.git` included; `git clean -Xdn` then lists nothing); `clean-cache` removes the loader's cache on request and
   prints its size first.
9. ✅ **Close the cycle (M)** — the release gate counts the `cargo
   tests` job too (eight jobs; a red semver gate, golden, trybuild or
   audit now refuses a tag); `docs/design/v10-plan.md` written from a
   rehearsal measured again on this tree: the re-export hide is
   invisible to cargo-semver-checks (196 of 196 pass), hiding the
   runtime's items fires five `*_now_doc_hidden` lints as a minor and
   passes as a major with 0 checks — and, new against the panel's
   record, it changes two trybuild expectations (`Rc<Vec<u8>>` where
   rustc printed `Rc<std::vec::Vec<u8>>`), so the 1.0 commit
   regenerates them; the macros crate is not checkable by the tool at
   all. Stability §3 and §8 read as of 0.7; 1.0 follows 0.8.

**Pre-release review** (2026-09-30, the whole `v0.6.0..HEAD` diff). No
defect in behaviour; documents that disagreed with the code, and a gap
in the release procedure. A real Rust program built for `wasm32-wasip1`
ran in the sandbox for the first time — arguments, environment, stdin,
files, EPERM, EROFS, read_dir, the exit code, `thread::sleep` panicking
into a trap, fuel, a failed allocation, the output cap — and showed that
`make-wasi`'s own example numbers refused it: Rust asks for 17 pages of
memory before it runs, the example said 1 MiB (now 16 MiB, and says
why). BOUNDARY §9 said a section-stripped ELF is refused; it loads, as
it should — the sentence is corrected and
`v07.section-stripped-artifact-still-loads` holds the loader to it (an
over-refusing check fails it). The release workflow was rehearsed on
HEAD for the first time — sixteen assets built and audited on four
hosts, `libwasm` with its WASI dependencies audited on macOS and
Windows at last — and the rehearsal is now a step of
docs/releasing.md, before crates.io, with the notes step guarded so it
can end green. The Rust guest is committed, by the maintainer's call,
as `tests/wasm-guests/rust-guest.wasm` with its source, and
`wasm.wasi-runs-a-toolchain-built-module` makes that run a test rather
than a record.

Not in v0.7 (causes in the plan): an axum HTTP server with Lisp
handlers — probed clean (47 packages, 38 s, §7 sweep ok) and decided as
**the 0.8 flagship**, pull-based like fetch's mirror; an MCP example on
rmcp as the flagship (feasible — probed over a duplex — but its standard
transports are what §7 refuses or duplicates, and it is fetch's whole
pattern again as a fifth crate: the candidate after axum, whose HTTP
transport it builds on), tokenizers (ready for 1.x, one
flagship per cycle), llama.cpp (cmake/libclang/C++ on every job,
`abort()` on fault, no hermetic model), candle (fails the audit: a
transitive `lscpu` spawn), rig/async-openai (a second TLS stack for
what fetch already gives), a new `examples/wasi` crate, wasmi 2.0,
compiling real `.wasm` in CI, preview2/the component model, hiding
`rulisp::runtime` early, a docs/api.md generator, a benchmark refresh,
the Quicklisp submission, and every earlier refusal.

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
Budget 2 M + 12 S. **All fourteen items shipped by 2026-09-11; released
as 0.6.0 on 2026-09-14** (crates.io, tag `v0.6.0`, a GitHub Release with
12 re-audited assets cut through the new CI gate). stability.md §8
criterion 3 — one cycle after v0.5 with no break on any surface — is
met by this release: every gate item 3, 6 and 7 built stayed green from
0.5.0 to 0.6.0, and the one non-additive change (item 9) is a §4
soundness fix on record.

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

Found during item 1 (closed by v0.7 item 2 — the check runs before the
copy on the load path, which the restore path shares): a **truncated
artifact at restore** — the file is present but cut
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

Found during v0.7 item 2, not scheduled: `m4h.reload-under-load` failed
ONCE on CCL in CI (run 36404431479 attempt 1, job 108869644728; green on
the rerun and in every other CCL run since the test landed 2026-09-03) —
one `UNDEFINED-FUNCTION` caught by a thread round-tripping strings while
the crate reloaded. Not reproduced locally on CCL 1.13 in 40 iterations
(120 reloads, 4.3 M calls) with the same loader. The GREET/ECHO wrapper
calls only loader functions a reload never rebinds; `commit-bindings`
unbinds nothing when the export set is unchanged; CCL's `export` leaves
an already-external symbol alone and its documentation store is locked.
The fuzzers now print each unexpected condition's report text instead of
the object, so the next occurrence names the function and its arguments.

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
- What the 0.7 flagship would have used, had it existed (each a new type
  token, so `:schema` 2 and additive in 1.x — the flagship needed none):
  `(:vec :string)` for argument lists, environments and export names
  (`wasi-arg` is one call per item, `wasm-exports` is comma-joined); a
  structured trap payload, kind and exit code in one condition, instead
  of a message the caller parses; several values from one call (exit
  code, stdout, stderr); a stored callback that returns a value to the
  guest — host functions implemented in Lisp with results.
- Bulk zero-copy data via Apache Arrow's C data interface.
- LispWorks / Allegro / ABCL validation.

## Non-goals (unchanged from v0.1)

Auto-binding arbitrary existing crates; `&mut self` across the boundary;
`dlclose`/true unloading; Rust holding Lisp object references. See
DESIGN.md §1.
