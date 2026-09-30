# rulisp 1.0.0 — the freeze, planned from a measured rehearsal

**Status:** written at the close of v0.7 (2026-09-30), to be executed
after 0.8. Nothing here changes the tree today. Every number below was
measured on the 0.7 tree with `cargo-semver-checks 0.50.0` against the
crates.io 0.6.0 baseline, in a scratch export (`git archive HEAD`), and
can be measured again with the commands given.

1.0 means what docs/stability.md §8 says: the four surfaces frozen for
the whole 1.x line. The Lisp API, the manifest schema and the C ABI need
no change to be frozen — they have not moved since 0.6.0. One surface
needs a last, deliberate break first: the Rust helpers.

## 1. What was measured

`rulisp-runtime`'s functions (`str_arg`, `handle_new`, …) are an
implementation detail of the macros (stability §1) but are `pub`, and
reachable as `rulisp::runtime::…` — so today the semver gate holds them
to the same rules as the API. 1.0 hides them. What the tool makes of
that:

| Change, in a scratch export | Command | Result |
|---|---|---|
| none (the tree as it is) | `cargo semver-checks check-release -p rulisp --release-type minor` | `196 checks: 196 pass, 58 skip` |
| | the same with `-p rulisp-runtime` | `196 checks: 196 pass, 58 skip` |
| | the same with `-p rulisp-macros` | `error: no crates with library targets selected` — a proc-macro crate has no API the tool can check |
| `#[doc(hidden)]` on `pub use rulisp_runtime as runtime;` only | `-p rulisp --release-type minor` | `196 checks: 196 pass, 58 skip` — **invisible**: a re-export of another crate carries no items |
| `#[doc(hidden)]` on every `pub` item of `rulisp-runtime` (41 lines in `lib.rs` and `meta.rs`) | `-p rulisp-runtime --release-type minor` | `196 checks: 191 pass, 5 fail` — `enum_now_doc_hidden`, `function_now_doc_hidden`, `pub_module_level_const_now_doc_hidden`, `pub_static_now_doc_hidden`, `struct_now_doc_hidden`: "semver requires new major version" |
| | `-p rulisp-runtime --release-type major` | `0 checks: 0 pass, 254 skip` — passes, and checks nothing |
| both hides | `RUSTDOCFLAGS="-D warnings" cargo doc --no-deps -p rulisp -p rulisp-macros -p rulisp-runtime` | green |
| both hides | `cargo test --workspace` | **red**: 2 of 8 trybuild cases (`tests/ui/non_send_handle.rs`, `stored_callback.rs`) — rustc prints `Rc<Vec<u8>>` where the recorded expectation says `Rc<std::vec::Vec<u8>>` |
| non-vacuity: `Error::msg` renamed | `-p rulisp --release-type minor` | `196 checks: 195 pass, 1 fail` — `inherent_method_missing` |

What follows from the table:

- **The path hide frees nothing.** Hiding the re-export is cosmetic for
  the tool; the helpers stay checked through `rulisp-runtime`'s own
  entry in the gate's package list. What frees them is hiding the items
  — which the tool calls a major. That is the 1.0 break, and the only
  one.
- **The Rust gate is vacuous on the day of a major.** Under
  `--release-type major` the tool skips every check (`0 checks`). On the
  1.0 push the gate proves nothing; what protects the API that day is the
  manual minor check in §2 step 4.
- **The macros' surface is not the tool's to check.** The attribute
  grammar of `#[rulisp::export]`, `#[rulisp::handle]` and `module!` is
  held by the trybuild cases (`crates/rulisp/tests/ui/`) and the manifest
  golden, as it always was; the package list names `rulisp-macros` and
  the tool skips it.
- **Hiding the items changes two compiler messages.** rustc abbreviates
  a type's path only when the short name is unique among documented
  items; `rulisp-runtime` has `Vec` variants, so today it prints
  `std::vec::Vec`. Hidden, they stop counting and it prints `Vec`. The
  1.0 commit regenerates those two `.stderr` files
  (`TRYBUILD=overwrite cargo test -p rulisp --test compile_fail`) and the
  diff must be exactly that abbreviation. (The v0.7 panel recorded "cargo
  test stays green with both hides"; measured again at the cycle's close,
  it does not.)
- **The pins must become exact.** `crates/rulisp/Cargo.toml` pins
  `rulisp-macros` and `rulisp-runtime` as `"0.6.0"` — a caret
  requirement, which within 0.x means that one minor, but `^1.0.0` means
  every 1.x. "The helpers may change in any minor" would then be
  falsifiable by `cargo update -p rulisp-runtime` in a consumer: a
  `rulisp 1.0.0` built against a `rulisp-runtime 1.1.0` whose helpers
  moved. The pins become `"=1.0.0"` and stay exact for the 1.x line.

## 2. The 1.0.0 commit

One commit, in this order, each step with its check:

1. **Hide the helpers.** `#[doc(hidden)]` on `pub use rulisp_runtime as
   runtime;` (crates/rulisp/src/lib.rs) and on every `pub` item of
   `crates/rulisp-runtime/src/{lib,meta}.rs`. The macros emit
   `::rulisp::runtime::…` paths at every call site — hidden is not
   removed, generated code keeps compiling. Check: `cargo doc -D
   warnings` green; the hidden crate's front page says it is an
   implementation detail of the macros and points at `rulisp`.
2. **Regenerate the two trybuild expectations** and read the diff: only
   `std::vec::Vec` → `Vec`. Check: `cargo test --workspace` green.
3. **Exact pins and the version.** `version = "1.0.0"` in the three
   crates, `rulisp-macros = { …, version = "=1.0.0" }` and the same for
   `rulisp-runtime`; `tools/check-versions.sh` accepts the `=` (its two
   pin patterns become `version = \"=?$V\"`); every site the script
   lists: `lisp/rulisp.asd`, README's status line, `rulisp = "1.0"` in
   docs/quickstart.md and docs/usage.md, the `describe` transcript.
   Check: `make check-versions`.
4. **The gate, for this one push.** `.github/workflows/ci.yml`:
   `release-type: major` on the Rust API step. Before pushing, by hand:
   `cargo semver-checks check-release -p rulisp -p rulisp-runtime
   --release-type minor` on the commit — its **only** findings must be
   the five `*_now_doc_hidden` lints on `rulisp-runtime`. Anything else
   is an unintended break and stops the release.
5. **The words that flip.** Every sentence that says "pre-1.0", "until
   1.0", "at 1.0", "will promise": README (status paragraph),
   SECURITY.md ("Supported versions"), docs/stability.md (title, §1's
   helper paragraph, §2 "Pre-1.0 semver", §3, §4, §8's status line, §9),
   docs/releasing.md step 8, docs/usage.md's Ultralisp line,
   docs/claims.md's matching rows, the comment at ci.yml's semver step.
   `git grep -n -i 'pre-1\.0\|until 1\.0\|before 1\.0\|at 1\.0\|1\.0 will'`
   finds them; stability §2 gains the 1.x rule in place of the 0.x one
   (a minor is additive on every surface; a break is 2.0).
6. **CHANGELOG 1.0.0** with its surfaces paragraph: *Rust API* — the
   helpers hidden, the one break, a major by the tool's own rule; nothing
   else. *Lisp API*, *manifest*, *C ABI* — unchanged since 0.6.0 / 1.
7. **Criteria.** `make check-1.0` green; docs/stability.md §8's status
   line says all five hold.

## 3. Release day

The sequence of docs/releasing.md, with what is different at 1.0:

1. Push the commit; wait for all eight gated jobs (six hosts, MSRV, cargo
   tests) — `tools/required-ci-green.sh` refuses the tag otherwise.
2. `cargo publish -p rulisp-runtime`, `-p rulisp-macros`, `-p rulisp`, in
   that order, each after the previous is indexed.
3. `git tag v1.0.0 && git push origin v1.0.0` — blobs.yml builds, audits
   and attaches **sixteen** assets (four hosts × four examples) and
   re-audits them; `gh release view v1.0.0 --json assets --jq
   '.assets|length'` → 16.
4. `sh tools/check-dist.sh` until Ultralisp serves 1.0.0, and its system
   rows read `rulisp` and `rulisp/test` only.
5. Refresh docs/benchmarks.md on the three hosts at the tag, by the
   procedure at the end of that file — the numbers a 1.0 user will
   quote should be the code they run.
6. **The Quicklisp submission** — an issue at quicklisp/quicklisp-projects:

   > **Please add rulisp**
   >
   > Repository: https://github.com/onlyarche/rulisp (MIT). An in-process
   > bridge between Rust and Common Lisp: Rust proc-macros generate C-ABI
   > shims and a manifest, the loader generates CLOS handles, conditions
   > and docstrings from it at load time.
   >
   > Systems: `rulisp` (in `lisp/rulisp.asd`; depends on cffi, babel,
   > trivial-garbage, bordeaux-threads) and `rulisp/test` (adds fiveam).
   > That one `.asd` is the only one in the tree.
   >
   > Loading either system needs **no Rust toolchain** and opens no
   > foreign library; cargo is used only when a user calls
   > `rulisp:use-crate`. The repository's CI proves this on every push:
   > the step "Quicklisp dist dry run" loads every system of a `git
   > archive` with cargo unreachable. (Running `rulisp/test` does build
   > the example crates, so it needs cargo.)
   >
   > Tested on SBCL (Linux x86-64 and aarch64, macOS arm64, Windows), CCL
   > and ECL (Linux), all required CI jobs.

## 4. The commit that opens 1.1

docs/releasing.md step 9, plus what only 1.0 changes:

- `release-type: minor` back in ci.yml — after 1.0.0 is on crates.io, so
  the baseline the tool fetches is 1.0.0 (a releasing.md step says so).
- The pins move: `make compat PREV=v1.0.0`, `gh release download v1.0.0`
  on the SBCL/Linux job and on the aarch64 job.
- From here `make compat`'s API subset check is the Lisp surface's
  promise in executable form: every entry of 1.0.0's
  `tests/golden/lisp-api.sexp` present and unchanged, additions allowed.
- `## Unreleased (1.1 development)`.

## 5. Explicitly not in 1.0

- **New type vocabulary** (`(:vec :string)`, structured error payloads,
  several return values, stored callbacks that return a value — the 0.7
  flagship's wish list, ROADMAP "Later"): each is a new manifest token,
  so `:schema` 2 by stability §7, additive in 1.x. 1.0 freezes what
  exists; it is not the release that grows it.
- **New examples.** MCP on rmcp and a tokenizers example were probed for
  0.7 and are 1.x candidates; axum is 0.8's.
- **An ABI bump.** `abi_version()` is 1 and 1.0 ships it.
- **Removing `rulisp::runtime`.** Hidden, not removed: generated code
  needs the path.
