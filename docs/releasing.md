# Releasing rulisp

One version string, released together: the three crates, `rulisp.asd` and
the tag (docs/stability.md §2). The steps below are in the order that has
worked; each has a check, so a slip is caught before the next step.

1. **Bump.** Set the new version in `crates/rulisp/Cargo.toml` — the
   source of truth — then in every site `make check-versions` lists: the
   other two crates, the two path-dependency pins, `lisp/rulisp.asd`, the
   README status line, the `rulisp = "X.Y"` lines in docs/quickstart.md
   and docs/usage.md. `make check-versions` must pass; `cargo build`
   refreshes `Cargo.lock`, which is committed.
2. **CHANGELOG.** Rename `## Unreleased (…)` to `## X.Y.Z — YYYY-MM-DD`.
   The release workflow takes that section, verbatim, as the GitHub
   Release body — and fails if it cannot find it.
3. **Golden.** Nothing to do for a version bump: both golden tests
   replace the value of the golden's `:rulisp-version` key, whatever it
   is, with the running version before comparing byte for byte.
   Regenerate the goldens only when the renderer's output changed.
4. **Gates.** Push and wait for every required CI job plus `MSRV` and
   `cargo tests` to be green. Never tag on a red run — and the release
   job checks: before it attaches a single asset,
   `tools/required-ci-green.sh` looks up the tagged commit's CI run and
   refuses, naming the job, unless every `(required)` job, `MSRV` and
   `cargo tests` (the Rust API gate, the manifest golden, trybuild, the
   signal audit) concluded success (no run, or a run still
   in progress, refuses too). The `skip-ci-gate` dispatch input is the
   documented override; it prints a warning in the release log.
5. **Publish to crates.io, in dependency order** — each waits for the
   previous one to be indexed:

   ```sh
   cargo publish -p rulisp-runtime
   cargo publish -p rulisp-macros
   cargo publish -p rulisp
   ```

6. **Tag, and push the tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`.
   The tag push runs `.github/workflows/blobs.yml`: release-profile builds
   of the four examples on every required host, each run through
   `tools/rulisp-audit.sh` on its own host and again, all sixteen
   together, in the release job on Linux (BOUNDARY §7), attached to a
   GitHub Release for the tag with the CHANGELOG section as its body.
7. **Check the assets.** `gh release view vX.Y.Z` lists sixteen:
   `lib<crate>-linux-x86_64.so`, `lib<crate>-linux-arm64.so`,
   `lib<crate>-darwin-arm64.dylib` and `<crate>-windows-x86_64.dll` for
   `wordbag`, `rx`, `wasm`, `fetch`. A
   host that flaked is re-run for the same tag from the Actions tab
   (`blobs` → Run workflow → the tag); existing assets are replaced.
8. **Ultralisp.** The dist polls GitHub on its own schedule and has
   lagged a tag by days. Run `sh tools/check-dist.sh` until it prints
   the new version; if it has not within a day, the place to look is the
   Ultralisp project page — its sources and its check queue — not the
   tree. Users then get it with `(ql:update-dist "ultralisp")`. Quicklisp
   is a 1.0 decision (docs/stability.md §9).
9. **Open the next cycle.** Add `## Unreleased (X.Y+1 development)` at
   the top of CHANGELOG.md, and move the previous-release pins in
   `.github/workflows/ci.yml` to the release just made: `make compat
   PREV=vX.Y.Z` and `gh release download vX.Y.Z` — they compare every
   push against the last release, so they cannot be moved at step 1.

**Yanking.** A release found unsound is yanked from crates.io
(`cargo yank --vers X.Y.Z -p <crate>`, all three crates) and the GitHub
Release notes say so; the tag stays. 0.1.0–0.2.1 were yanked this way
after issue #1 (see CHANGELOG 0.3.0).
