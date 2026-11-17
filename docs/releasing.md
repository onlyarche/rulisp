# Releasing rulisp

One version string, released together: the three crates, `rulisp.asd` and
the tag (docs/stability.md §2). The steps below are in the order that has
worked; each has a check, so a slip is caught before the next step.

1. **Bump.** Set the new version in `crates/rulisp/Cargo.toml` — the
   source of truth — then in every site `make check-versions` lists: the
   other two crates, the two path-dependency pins, `lisp/rulisp.asd`, the
   README status line, the `rulisp = "X.Y"` lines in docs/quickstart.md
   and docs/usage.md (major.minor — a patch leaves them), docs/usage.md's
   `describe` transcript and docs/stability.md §2's
   "(X.Y.Z everywhere today)". The script's other two checks hold the
   three crates to one `rust-version`; a bump leaves it alone.
   `make check-versions` must pass; `cargo build` refreshes
   `Cargo.lock`, which is committed. The standalone fixtures
   pin rulisp by path in their own locks: run `cargo update -p rulisp`
   with `--manifest-path tests/m1-handwritten/Cargo.toml` and with
   `--manifest-path tests/inbox-fixture/Cargo.toml`, and commit both.
2. **CHANGELOG.** Rename `## Unreleased (…)` to `## X.Y.Z — YYYY-MM-DD`.
   The release workflow takes that section, verbatim, as the GitHub
   Release body — and fails if it cannot find it.
3. **Golden.** Nothing to do for a version bump: both golden tests
   replace the value of the golden's `:rulisp-version` key, whatever it
   is, with the running version before comparing byte for byte.
   Regenerate the goldens only when the renderer's output changed.
   **A patch** adds a check that no gate makes. The Lisp API golden and
   the package definition are byte-identical to the previous tag —
   `git diff --quiet vPREV HEAD -- tests/golden/lisp-api.sexp lisp/src/package.lisp`
   exits 0 — and the wordbag manifest golden differs from that tag's
   inside `:doc` strings only (read
   `git diff vPREV HEAD -- tests/golden/wordbag.manifest.sexp`):
   anything else there means the macros' rendering or the fixture
   moved. The reason: an added export is caught by the golden alone
   (`v06.exported-api-golden`, and `make check-1.0`'s export count
   against its rows), docs/stability.md §1 tells a contributor to
   regenerate it in the same commit, and `make compat` passes an
   addition by design — after that every gate is green and the patch
   has grown a surface.
4. **Gates.** Push and wait for every required CI job plus `MSRV` and
   `cargo tests` to be green. Never tag on a red run — and the release
   job checks: before it attaches a single asset,
   `tools/required-ci-green.sh` looks up the tagged commit's CI run and
   refuses, naming the job, unless every `(required)` job, `MSRV` and
   `cargo tests` (the Rust API gate, the manifest golden, trybuild, the
   signal audit) concluded success (no run, or a run still
   in progress, refuses too). The `skip-ci-gate` dispatch input is the
   documented override; it prints a warning in the release log.
   **Rehearse the release workflow on this commit before step 5** —
   crates.io cannot be undone, and the examples' release-profile builds
   and their audits on macOS and Windows run nowhere else: Actions →
   `blobs` → Run workflow with `tag` = `main` and `publish` unchecked
   builds and audits all sixteen assets, runs the CI gate and the
   re-audit, and publishes nothing. The release notes are checked only
   when publishing, so check them here too: after step 2,
   `awk -v v=X.Y.Z '$1=="##" && $2==v {p=1; next} $1=="##" {p=0} p' CHANGELOG.md | grep -q .`
   must succeed.
5. **Publish to crates.io, in dependency order** — each waits for the
   previous one to be indexed:

   ```sh
   cargo publish -p rulisp-runtime
   cargo publish -p rulisp-macros
   cargo publish -p rulisp
   ```

6. **Tag, and push the tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`.
   The tag push runs `.github/workflows/blobs.yml`: release-profile builds
   of four of the examples (wordbag, rx, wasm, fetch; httpd ships as
   source) on every required host, each run through
   `tools/rulisp-audit.sh` on its own host and again, all sixteen
   together, in the release job on Linux (BOUNDARY §7), attached to a
   GitHub Release for the tag with the CHANGELOG section as its body.
7. **Check the assets.** `gh release view vX.Y.Z` lists sixteen:
   `lib<crate>-linux-x86_64.so`, `lib<crate>-linux-arm64.so`,
   `lib<crate>-darwin-arm64.dylib` and `<crate>-windows-x86_64.dll` for
   `wordbag`, `rx`, `wasm`, `fetch`. A
   host that flaked is re-run for the same tag from the Actions tab
   (`blobs` → Run workflow → the tag); existing assets are replaced. A
   release job that failed on a GitHub API error (`gh: Server Error` in
   the gate step, seen in the 0.8.0 rehearsal) is re-run in place, the
   build jobs' results standing:
   `gh api -X POST repos/onlyarche/rulisp/actions/runs/<run id>/rerun-failed-jobs`.
8. **Ultralisp.** The dist polls GitHub on its own schedule and has
   lagged a tag by days. Run `sh tools/check-dist.sh` until it prints
   the new version; if it has not within a day, the place to look is the
   Ultralisp project page — its sources and its check queue — not the
   tree. Users then get it with `(ql:update-dist "ultralisp")`. Quicklisp
   is a 1.0 decision (docs/stability.md §9).
9. **Open the next cycle.** Add `## Unreleased (<next version> development)`
   at the top of CHANGELOG.md, and move the previous-release pins to the
   release just made: the Makefile's `PREV ?=`, and in
   `.github/workflows/ci.yml` `make compat PREV=vX.Y.Z` with the step
   name above it, and both `gh release download vX.Y.Z` lines (x86-64
   and aarch64) — they compare every push against the last release, so
   they cannot be moved at step 1. In the same file, set the Rust API
   gate's `release-type` — and the word in its step name and in the
   comment above it — to the kind of release the cycle being opened
   is: `patch` for a patch cycle, `minor` for a minor. After 0.8.1 it
   stays `patch` up to the 1.0.0 commit (the 1.0 cycle's commits before
   it are to add no Rust API item), and docs/stability.md §1's gate
   sentence says so from the commit that opens that cycle — "`minor`
   (`patch` in a patch cycle)" alone does not cover it. The 1.0.0
   commit sets `major` for its one push (docs/design/v10-plan.md §2
   step 4), and the commit that opens 1.1 sets `minor` once crates.io
   serves 1.0.0 — the release the gate then compares against.
   ROADMAP's stub for the next cycle says the cycle is open.

**Yanking.** A release found unsound is yanked from crates.io
(`cargo yank --vers X.Y.Z -p <crate>`, all three crates) and the GitHub
Release notes say so; the tag stays. 0.1.0–0.2.1 were yanked this way
after issue #1 (see CHANGELOG 0.3.0).
