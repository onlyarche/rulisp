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
3. **Golden.** The manifest goldens carry `:rulisp-version "0.4.0"` as a
   placeholder that both golden tests substitute with the running
   version, so a version bump does not rewrite them. Regenerate only when
   the renderer's output changed — and if the regenerated golden then
   carries a different version, update the placeholder string in
   `tests/suite/m2.lisp` and `examples/wordbag/tests/manifest_golden.rs`
   to match it.
4. **Gates.** Push and wait for every required CI job plus `MSRV` to be
   green. Never tag on a red run.
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
   `tools/rulisp-audit.sh` (Windows: SKIP — BOUNDARY §12), attached to a
   GitHub Release for the tag with the CHANGELOG section as its body.
7. **Check the assets.** `gh release view vX.Y.Z` lists twelve:
   `lib<crate>-linux-x86_64.so`, `lib<crate>-darwin-arm64.dylib` and
   `<crate>-windows-x86_64.dll` for `wordbag`, `rx`, `wasm`, `fetch`. A
   host that flaked is re-run for the same tag from the Actions tab
   (`blobs` → Run workflow → the tag); existing assets are replaced.
8. **Ultralisp.** The dist polls GitHub; after about an hour
   `(ql:update-dist "ultralisp")` followed by `(ql:quickload :rulisp)`
   loads the tagged version — check with
   `(asdf:component-version (asdf:find-system :rulisp))`. Quicklisp is a
   1.0 decision (docs/stability.md §9).
9. **Open the next cycle.** Add `## Unreleased (X.Y+1 development)` at
   the top of CHANGELOG.md.

**Yanking.** A release found unsound is yanked from crates.io
(`cargo yank --vers X.Y.Z -p <crate>`, all three crates) and the GitHub
Release notes say so; the tag stays. 0.1.0–0.2.1 were yanked this way
after issue #1 (see CHANGELOG 0.3.0).
