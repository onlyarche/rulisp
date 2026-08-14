# rulisp v0.4 — Plan

**Theme:** Enforced, everywhere — every normative BOUNDARY.md claim becomes a compile error, runtime check, or non-vacuous test on every claimed host, and the §10 dump discipline becomes structural; the next issue-#1-grade evaluator finds nothing to file.

Issue #1's reporter (evaluating rulisp for a CL debug agent) praised the boundary because "the surrounding invariants are otherwise enforced rather than merely documented." 0.1.0–0.2.1 were yanked over the one claim that wasn't. v0.4 makes that property total before a user re-runs the review. ABI 1 stays frozen: every wire change below is a manifest key under the ignore-unknown-keys rule (BOUNDARY §11). No item forces a C toolchain on ECL at load time.

Budget: 4 M + 4 S. No L items — the two L candidates (open-ended audit, `examples/proc`) are cut or downsized below.

---

## Items (ordered)

### 1. BOUNDARY conformance sweep: claim→enforcement table, six verified gaps closed — **M**

**Demand case.** Issue #1 was exactly a documented-claim-turned-false (§4's "retention is a compile error" held only under lifetime elision). The reporter's review method — check each claim for an enforcing mechanism — is transferable, and the next serious evaluator will re-run it. Do the sweep before they do.

**Scope.** Classify every normative claim in BOUNDARY §1–§11 as {compile error | runtime check | test | documented-UB-by-design | gap}; append the table to BOUNDARY.md. Pre-verified gaps to close in-cycle (each currently prose-only):

1. **§6.3** — swallowed `CallbackError` discards the stash; swallow-then-fail is status 4. No test exists, and no wordbag export swallows a callback error (verified: `for_each_word` propagates). Needs a new wordbag + oracle export.
2. **§2 exception** — panic inside a `*_free` shim is caught/logged/swallowed. Generated (`crates/rulisp-macros/src/lib.rs:865-872`) and hand-written (`tests/m1-handwritten/src/lib.rs:285-292`), exercised by zero tests — no test crate has a panicking `Drop`.
3. **§8** — poisoned mutex after a caught panic reports status 2 on the next lock. No test.
4. **§3** — `last_error` is thread-local per library. No test with two threads erroring concurrently in one library.
5. **§2** — out-params written only on OK. Structural in the shim, unpinned: assert an out-param sentinel is untouched on ERR.
6. **§7 ECL** — the toolchain requirement already fails through a *named* `manifest-error` ("callbacks on ECL require the native compiler", `lisp/src/codegen.lisp:93-103`) — the gap is a missing test, not a missing message.

New exports mean oracle + hand-written manifest + golden updated in the same commit (the DESIGN §11 item-8 vocabulary-evolution procedure). The table also lists **documented-UB-by-design** entries (§6.4 non-local exit, §5 C-level double free, §9 leaked mappings) so nobody mistakes them for gaps.

**Acceptance.** Table covers every normative sentence in §1–§11; the six tests above green on SBCL+CCL (ECL where applicable); any remaining gap is a filed issue linked from the table. **Timebox:** classification is mandatory; closing every gap is not — anything bigger than S becomes an issue.

**Risk.** The sweep may surface another real hole; budget a 0.4.x fix-forward — that is the point.

### 2. De-vacuous m7: real `ccl:save-application` dump/restore in the required CCL job — **M**

**Demand case.** CHANGELOG 0.1.0 claims save/restore "Verified on SBCL and Clozure CL", and docs/distribution.md sells a Deploy recipe built on dumping — but `tests/suite/m1.lisp:277` is `#-sbcl (pass "…skipped here")`: the dump path has never executed on CCL, a required CI platform. The debug-agent consumer ships as a dumped image. Verified driver: `uiop:dump-image` on CCL is `ccl:save-application … :toplevel-function #'restore-image` (asdf.lisp:4744-4745).

**Scope.** Port the m7 subprocess harness to CCL. Add the assertions the SBCL test lacks: a pre-dump handle signals rulisp's typed condition, not CCL's dead-macptr error; freeing a dead-session handle makes no foreign call (`%maybe-foreign-free`'s session gate, `lisp/src/handle.lisp`); a pre-dump handle GC'd *after* restore skips the foreign call (the finalizer path, designed for and tested nowhere). Any remaining off-host skip becomes a **loud** named pass citing its cause — never a silent vacuous green.

**Acceptance.** CCL/Linux (required) runs m7 non-vacuously; the three new assertions pass on both hosts; `git grep '#-sbcl (pass'` returns nothing without an adjacent cause string.

**Risk.** `save-application`'s thread/purify/macptr semantics may surface real loader bugs — that is verification working; subprocess orchestration adds CCL-job minutes.

### 3. `#[rulisp(on_dump)]`: declared shutdown export, auto-registered dump hook — **M**

**Demand case.** BOUNDARY §10 confesses: "There is no guardrail against dumping with live foreign threads." Today every consumer hand-wires `uiop:register-image-dump-hook` from prose (docs/distribution.md Pattern B; `with-client`'s docstring in `examples/fetch/http.lisp`). fetch's `Client` owns a tokio runtime — the standing demand case — and the v0.3 risk table (v03-async-plan.md row 6) promised `v03.dump.shutdown-hook-quiesces` and `v03.dump.restored-handles-refuse`, which verifiably never shipped (zero dump tests in `tests/suite/v03.lisp` or `fetch.lisp`). The deferral said "v0.4 at the earliest" (v03-async-plan.md §7) — this is the slot, and the enforcement theme is the new cause: it converts §10 from documented to structural.

**Scope — deliberately minimal.** `#[rulisp(on_dump)]` marks one zero-arg export; the manifest gains `(:on-dump "symbol")` — wire-additive, old loaders ignore it, ABI 1 intact; plain export, zero ECL load-time cost. The loader registers one `uiop:register-image-dump-hook` that calls every loaded crate's declared hook **in load order**; a signaling/panicking hook is warned and skipped (the dump proceeds). **Dump-only** — no reload semantics, no detection of undeclared threads (unportable; claiming it would repeat the §4 mistake). BOUNDARY §10 text lands *before* code: ordering rule, the §7 capped-wait rule made normative for hook bodies, error behavior. fetch converts as the worked example (a crate-level quiesce export).

**Acceptance.** The two promised v03.dump tests finally ship against the hook — `(length (bt:all-threads))` = 1 after the hook fires with requests in flight; restored pre-dump handles refuse — on SBCL **and** CCL (sequenced after item 2's harness). Golden/oracle updated in the same commit as the manifest key.

**Risk.** A blocking hook wedges the dump; the loader cannot cap it portably — mitigated by the normative capped-wait rule plus fetch as the reference implementation.

### 4. ECL deploy story: `program-op` is the dump, tested and documented — **M**

**Demand case.** ROADMAP §5 left "ECL?" open. Settled by inspection: `uiop:dump-image` on ECL reaches `(not-implemented-error 'dump-image)` (asdf.lisp:4784-4785 — ECL absent from the dispatch); the real path is `create-image`/`asdf:program-op`, whose `:program` epilogue is `(shell-boolean-exit (restore-image))` (asdf.lisp:4812-4817) — so rulisp's restore hook (`%restore-all-crates`, registered in `lisp/src/crate.lisp`) already runs at executable startup, with no pre-dump state to invalidate. Nothing in docs or the suite says or verifies this: a claimed-supported platform has a silent delivery story.

**Scope.** distribution.md gains an ECL section — "no dump exists; ship `program-op`; the restore-hook pattern works unchanged" — plus a smoke test that `program-op`-builds a minimal wordbag consumer, runs it, asserts load→call→exit 0. Lands in the **best-effort** ECL job first. Constraint-clean: the C toolchain is build-time and ECL-inherent; load-time requirements unchanged.

**Acceptance.** The smoke test green in the ECL job; the docs section merged; m7's ECL skip cites this item as its cause.

**Risk.** ECL linking quirks and slow builds — contained by the best-effort job.

### 5. `#[rulisp(constructor, name = "…")]` — **S**

**Demand case.** No longer polish: constructor lisp-names are hardcoded `format!("make-{kebab}")` (`crates/rulisp-macros/src/lib.rs:1041`), handle-returning fns *must* be constructors (lib.rs:344), and duplicate `:lisp-name` became a hard error in v0.3 (`v03.duplicate-lisp-name-rejected`) — so a two-constructor handle type (`Session::attach` vs `Session::launch` is the debug-agent shape) is **inexpressible, with no workaround**. The v0.3 plan deferred it to v0.4 by name (v03-async-plan.md §7: "Deferred to v0.4, where the first two-constructor handle type will justify it") — a scheduled slot, not a reopened refusal.

**Acceptance.** A two-constructor handle type in a test crate exports both; the explicit name flows through the existing duplicate-`:lisp-name` rejection (test: two constructors given the same name → `manifest-error`); trybuild case for a malformed attribute; oracle/golden in the same commit. Zero wire change — it only alters a string already in the manifest.

### 6. Reusable §7 signal-audit tool — **S**

**Demand case.** BOUNDARY §7 orders every glue author to "audit dependencies for `sigaction`", but the only executable form is `examples/fetch/audit.sh` — hardcoded to `libfetch.so`, and carrying in its own comments the proof that unshipped checks rot (the anchored regex that "made this gate inert" against glibc's version-tagged imports).

**Scope.** Extract the `nm -D` sweep + tokio-feature + `block_on` checks into a crate-agnostic script (artifact path/crate parameterized), documented in distribution.md; run it in CI over all four examples — all pass as-is (wasm uses **wasmi**, chosen precisely because it installs no signal handlers; no allowlist needed). Add the self-test: a deliberately signal-linking fixture must FAIL the gate, so it can never go inert again. Scope to ELF/Mach-O; document the Windows `dumpbin` gap rather than blocking on it.

**Acceptance.** `sh tools/rulisp-audit.sh <artifact>` green on all examples in CI; the failing fixture red; fetch's `audit.sh` becomes a two-line wrapper.

### 7. `docs/benchmarks.md`: published baselines with a documented method — **S**

**Demand case.** CHANGELOG quotes 24×/307× with no reproducible method, while the v0.3 plan's own rule was "if a number ships, it comes from a release build with a documented method." **Corrected scope:** `make bench` already builds wordbag with `:profile :release` (`tests/bench.lisp:21-23`) — this is a run-and-document task, not measurement machinery: hardware, date, commit, host lisp, raw per-host output, README link.

**Acceptance.** docs/benchmarks.md exists with the method section and dated raw output; README links it; the CHANGELOG numbers trace to it. Explicitly **not** a CI regression gate — that is separate, later machinery.

### 8. Promote the ECL CI job to required — **S, gated stretch**

**Demand case.** CHANGELOG 0.2.0: "ECL is now fully supported." `ci.yml:89-91`: "best-effort, may fail", `continue-on-error: true`. That is the claim/enforcement gap this cycle exists to close, applied to CI; Windows made the same promotion (6f8f18f).

**Acceptance.** Flip only after item 4 lands and a documented green streak (~30 days), with a written demotion procedure in the workflow. If ECL flakes, the item slips without shame — the gate is the deliverable.

---

## Explicitly not in v0.4

- **Boundary vocabulary round 2** — `(:vec :string)`, nested containers, multiple return values → `(values …)`, tagged enums → condition subclasses: all refused-with-cause in v03-async-plan.md §7; no NEW demand case exists (issue #1's reporter asked for none). Closed stays closed.
- **Push/doorbell `StoredCallback` layer for fetch** — declaring one forces `compile-file` and a C toolchain on ECL at binding-generation time; the 100 ms capped poll delivers the latency. `fetch.manifest-has-no-stored-callbacks` stays.
- **`on_dump` reload semantics** (quiescing the outgoing generation before reload) — reload is already recoverable: gen-1 handles signal `stale-handle-error` and gen-1's runtime is reclaimed via `free`/GC (v03 risk row 5). Dump is the only unguarded, unrecoverable path; extend on a real demand case.
- **Flagship example** (including a debug-agent `examples/proc`) — L effort with a per-OS child-process tax on the required Windows job, and the demand is anticipatory: the reporter filed a soundness report, not feature asks. Earn their dump/enforcement trust this cycle; build the v0.5 flagship from what they actually request.
- **Display-driven `print-object` + macro error spans** — ROADMAP §7 keeps it open, but no demand exists, both cited raw-diagnostic bugs were fixed in 0.3.0 (no reproduced bad case remains), and it competes with the sweep for macro-crate attention.
- **LispWorks / Allegro / ABCL validation, ocicl** — zero consumer stories; adding an untested column before de-vacuousing the existing three repeats the exact mistake this cycle fixes.
- **Quicklisp submission** — deferred to 1.0 by user decision; Ultralisp + crates.io + release blobs remain the channels.
- **Constructor `&key`, zero-copy `:string`, streaming uploads, cookie/redirect/proxy config** — unchanged refusals-with-cause; no new demand.
- **`dlclose`/true unloading, any ABI break** — non-goals; every v0.4 wire change is manifest-key additive.
- **CI benchmark regression gating; CCL dump exotica** (`:purify` tuning, SBCL `:compression`) — baselines and the default `uiop:dump-image` path only, until a user report.

---

## Start here

**Task: de-vacuous m7 on CCL** (item 2 — the harness items 3's tests build on).

Files: `tests/suite/m1.lisp` (test `m7.dump-restore`, lines 274–338).

Failing-first check: narrow the host gate `#-sbcl (pass …)` (line 277) to exclude only non-SBCL-non-CCL hosts, and replace the hardcoded `sb-ext:save-lisp-and-die` in the generated dump-phase script (line 298) with `uiop:dump-image` — which dispatches to `save-lisp-and-die` on SBCL and `ccl:save-application :toplevel-function #'restore-image` on CCL (asdf.lisp:4744-4745). Because CCL's toplevel is fixed to `restore-image`, the post-restore assertions must move out of the SBCL-only `:toplevel` lambda into a thunk the script registers via `uiop:register-image-restore-hook` (with exit-code plumbing through `uiop:quit`), shared by both hosts. Run `ccl --load tests/run-m1.lisp`: m7 now *executes* and fails until the harness port is complete — that first red run is the proof the test stopped being vacuous. Green on both hosts, then add the two new assertions (typed stale condition, no-foreign-call dead-session free via the finalizer path) before touching item 3.
