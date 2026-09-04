# Stability: the four surfaces, and what 1.0 means

rulisp has four independently versioned surfaces. A change is "breaking"
only with respect to a surface, and each surface has its own rule. This
page is the contract for all four; BOUNDARY.md is the normative text for
one of them (the C ABI) and §12 there is the evidence that every claim it
makes is enforced.

## 1. The four surfaces and what breaks them

| Surface | Where it lives | Breaking means |
|---|---|---|
| **Rust API** — `#[rulisp::export]`, `#[rulisp::handle]`, `rulisp::module!`, their attribute grammar, `Error`, `Callback`, `StoredCallback`, `HandleType`, the `prelude` | crates.io: `rulisp`, `rulisp-macros`, `rulisp-runtime` | a glue crate that compiled stops compiling, or compiles to a different manifest/shim |
| **Lisp API** — the 32 symbols `lisp/src/package.lisp` exports (`use-crate`, `load-crate`, `load-blob-crate`, `reload-crate`, `free`, `callback`, the condition classes and their readers, …) | ASDF system `rulisp` | a call that worked signals, returns a different type, or a documented condition class stops being signaled where it was |
| **Manifest schema** — the s-expression a cdylib embeds (`:schema`, `:functions`, `:handles`, type tokens, `:on-dump`, …) | BOUNDARY.md §11 | a manifest a released macro emitted no longer loads, or a token's meaning changes |
| **C ABI** — symbol naming, status codes, `last_error`, buffer ownership, handle and callback wire | BOUNDARY.md §1–§10, `abi_version()` | anything §1–§10 says, changed |

`rulisp-runtime`'s helper functions (`str_arg`, `handle_new`, …) are an
implementation detail of the macros, not a surface: only generated code
and the hand-written ABI oracle call them, and they may change in any
minor.

## 2. Versions

- The three crates and the ASDF system **share one version** and are
  released together (0.5.0 everywhere today). A glue crate built against
  `rulisp = "0.x"` loads under the `rulisp` ASDF system of the same 0.x.
- Pre-1.0 semver: a **minor** (0.x → 0.x+1) may break the Rust API or the
  Lisp API, with the change and its migration named in CHANGELOG.md; a
  **patch** never does.
- The **C ABI** is a named integer, `abi_version()` = 1 since 0.1.0, exact-
  match checked by the loader. It has not changed and every feature since
  has been wire-additive. Bumping it is a major event, not a minor one.
- The **manifest schema** is a named integer too (`:schema` = 1). The
  loader accepts any schema ≤ the one it knows; adding a key never bumps it
  (§11's ignore-unknown-keys rule). See §7 for which keys are allowed to
  ride on that rule.

## 3. Deprecation

Policy only — nothing is deprecated today.

- Rust: `#[deprecated]` for at least one minor before removal, with the
  replacement in the note.
- Lisp: a `style-warning` at first use, for at least one minor, with the
  replacement in the text.
- Manifest tokens are **never removed** while the schema number stands:
  a token a released macro once emitted keeps loading.
- The C ABI is not deprecated; it is bumped (§2), and the loader refuses
  the old number with `abi-mismatch-error`.

## 4. Supported versions

The latest release only, while pre-1.0 (SECURITY.md). A soundness or
security fix ships as a new release and the affected versions are yanked
from crates.io (0.1.0–0.2.1 were, for issue #1); the ASDF system is not
"yanked" — fix forward and say so in CHANGELOG.md.

## 5. Host support

A host is supported exactly when it is a **required** CI job. The one
support table lives in [README §Status](../README.md#status) and equals
the required jobs in `.github/workflows/ci.yml`; a **best-effort** job
(today: SBCL on Linux aarch64) runs on every push without being required
and is not a supported host until promoted. Everything else (LispWorks,
Allegro, ABCL, other architectures) is untested and unclaimed.

Promotion and demotion follow the procedure written into
`.github/workflows/ci.yml`: a job becomes required after a documented
green streak with the platform's deployment path exercised; it is demoted
in **one** commit that restores `continue-on-error`, links the failing
run, records the cause in ROADMAP.md, and downgrades the wording in
CHANGELOG.md and README.md from "supported" to "best-effort" — never by
quietly flipping the flag.

## 6. Minimum supported Rust version

The declared `rust-version` in the three `Cargo.toml`s is the MSRV —
**1.78**, the oldest cargo that reads this repository's lockfile. The
`MSRV` CI job installs exactly that toolchain and checks the three crates
plus the `wordbag` example, so the code the macros generate is held to it
as well. Raising it is a **minor**, named in CHANGELOG.md.

## 7. Manifest keys: which may ride the ignore-unknown-keys rule

A new manifest key is either an **enhancement** — an older loader that
ignores it still runs the crate correctly (`:doc`, `:rulisp-version`) —
or **load-bearing**: a crate that declares it is not correct without it.
`:on-dump` is load-bearing (a 0.4 crate's dump hook silently never runs on
a 0.3 loader; BOUNDARY §10). The rule: a load-bearing key raises
`:schema` in the release that introduces it, so an older loader refuses
the crate instead of mis-running it; an enhancement key does not. (Item 5
of the v0.5 plan applies this rule and adds the informational
`:rulisp-version` key with a `style-warning` on loader/crate skew;
`:on-dump` keeps `:schema` 1 because raising it retroactively would refuse
every 0.5 crate on the 0.4.0 loaders that support it fully.)

## 8. What 1.0 promises, and its exit criteria

1.0 means: the four surfaces above are frozen under the rules above for
the whole 1.x line — a glue crate written against 1.0, and a Lisp
application written against 1.0, keep working on every 1.x without
change. Exit criteria, all checkable:

1. `abi_version()` still 1, unchanged since 0.1.0.
2. The v0.5 plan's items shipped (docs/design/v05-plan.md; item 10 is
   optional).
3. One full release cycle after v0.5 with **no** break on any surface —
   the deprecation policy exercised only if something turns out to need it.
4. Every user-facing claim in README and docs/ cites a test, a CI job or a
   benchmark row, or is gone (v0.5 item 11), and BOUNDARY §12 has no gap.
5. The Quicklisp prerequisites in §9 met.

## 9. Quicklisp prerequisites (listed, not scheduled)

Submission is a 1.0 decision. What it needs, so nothing is discovered at
the last minute:

- A tagged release with attached, audited artifacts for every required
  host (v0.5 item 8).
- `(ql:quickload :rulisp)` succeeds **without cargo on PATH** — loading the
  system opens no library and runs no toolchain; cargo is needed only by
  `use-crate`. The SBCL/Linux CI job proves this on every push.
- `rulisp/test` is documented as requiring cargo (it builds the examples)
  and is excluded from what a dist user loads.
- The examples are not part of the ASDF system and stay out of the dist.
- The manifest key-class rule (§7) in force, so a dist user on an older
  loader is refused rather than mis-run by a newer crate.

## Appendix: the claims register

Every capability, host and performance claim in README.md and the
docs/ pages, each with what enforces or demonstrates it — a suite test,
a trybuild case, a CI job or step, a bench row, or a code site — is
[docs/claims.md](claims.md), built by the v0.5 docs audit. It is a
separate file because it is some three hundred rows; the next audit is
a diff of that file against the pages. A claim it marks **unverified**
is worded as such on its page.
