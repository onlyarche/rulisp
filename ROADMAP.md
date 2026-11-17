# Roadmap

## 1.0 — the freeze (after 0.8.1)

What the 1.0.0 commit contains, measured in advance with
cargo-semver-checks, the release-day sequence, the commit that opens
1.1 and the Quicklisp issue text:
[docs/design/v10-plan.md](docs/design/v10-plan.md). Opens after 0.8.1;
its gates will compare against v0.8.1.

## v0.8.1 — the documents and the examples, tidied (next)

A patch (docs/stability.md §2): nothing on the four surfaces moves. No
Rust API item is added or removed (cargo-semver-checks against crates.io
0.8.0, run as a `patch` for the cycle — item 11), the Lisp API golden's
47 rows stay byte-identical to v0.8.0 (`v06.exported-api-golden` on six
hosts; `git diff --quiet v0.8.0 HEAD -- tests/golden/lisp-api.sexp
lisp/src/package.lisp` exits 0 today and must at the tag), ABI 1 and
`:schema` 1 stand. What the cycle does is what the 2026-11-04 review of
the documents and the five examples found — ten lenses, 97 findings, a
skeptic and a fix review on each, none refuted, and a completeness pass
that added six. No defect in the published crates or the loader: text
that aged, and three small slips in the examples (a docstring that
states the wrong cap, a tokio feature missing from a manifest, an oracle
line on stderr that differs from the macro's). The registers' citations
moved under them (36 docs/claims.md rows and 8 BOUNDARY §12 rows cite a
test at a line outside it — tests/suite/m1.lisp and m2.lisp moved 11
lines under them in e32e114 of 2026-09-07 and 33c5920 of 2026-09-30; 25
rows citing lisp/src/build.lisp at the v0.5.0 tree's lines, moved by
8c8704d of 2026-09-09; 8 rows citing ci.yml lines that are other steps
now); the examples' `///` docstrings — what `(documentation
'rx:regex-first-match 'function)` prints — still say "(v0.2)", "v1
speaks i32/i64", "(v0.6 — the value slot carried a fixnum 0 …)"; three
counts rotted ("all twelve assets" at tools/rulisp-audit.sh:17 and
docs/distribution.md:243 against blobs.yml:145's 16; "some three hundred
rows" at stability.md:234 against the register's 429; README.md:161's
"every suite but fetch" against run-m4's 13 suites and httpd's own
runner); and two examples have no user page — wasm's 19 functions and
two handles are shown nowhere, fetch's 13 `HTTP` exports, 24 `FETCH`
functions and twelve error kinds are named nowhere. The cycle is open
(opened by 4197662 on 2026-10-14 as 1.0's; re-aimed at 0.8.1 — decided
2026-11-04, this section written 2026-11-17): the gates compare against
v0.8.0 throughout, and the x86-64 and aarch64 jobs load its `wordbag`
assets with `load-blob-crate`; the pins move to v0.8.1 when it ships,
and 1.0 opens then. No plan file: a patch's items are listed here;
0.2.1, the only earlier patch, had neither a plan nor a ROADMAP record.
The Windows fetch promotion (v0.8 item 5, 26 green at the release) stays
carried: it moves the host matrix and is a change of its own, not a
patch's. The benchmarks table is not re-run (no code changed; 1.0's
release day does it), and each page that shows an example's veneer says
it is a pattern, not a frozen surface.
Budget 8 S + 6 M, one S reserved for what the review finds.

1. ✅ **Open the cycle on the right name.** CHANGELOG.md:8 `## Unreleased (1.0 development)` → `(0.8.1 development)` (the form docs/releasing.md:74 prescribes); ROADMAP.md:3 `(next)` → `(after 0.8.1)` and its "cycle is open" sentence moves into this section; v0.8 item 8's "This commit opens 1.0" names 4197662 and this section; docs/design/v10-plan.md:3-4 "to be executed after 0.8" → "after 0.8.1 (the patch decided 2026-11-04)". Acceptance: `sed -n '8p' CHANGELOG.md`; `grep -n '^## ' ROADMAP.md | head -3` prints 1.0 (after 0.8.1), v0.8.1 (next), v0.8; `grep -c 'after 0\.8\.1' docs/design/v10-plan.md` = 1 (S). Done 2026-11-17 by the commit that adds this section; item 11's ci.yml half (`release-type: patch`, with the two sentences of stability §1 and §2) went in with it.
2. ☐ **Document truth on the user pages.** Every sentence a reader meets that is false or points wrong today, each a same-line edit with its register row: README.md:161 "every suite but fetch" → "every suite but fetch and httpd" (tests/run-m4.lisp runs 13 suites, neither fetch nor httpd; Makefile:32-33 "its own runner, not run-m4") and a `make test-httpd` line after :162; README.md:41 and docs/quickstart.md:108 `(asdf:load-system :rulisp)` → `(ql:quickload :rulisp)`, the form installation.md:101/:120/:136, usage.md:26/:104/:120 and httpd.md:37 use (lisp/rulisp.asd:6 depends on cffi, babel, trivial-garbage, bordeaux-threads, uiop, which load-system does not fetch); quickstart.md:10-13 "SBCL (or CCL) … this repository set up" → the three hosts of README §Status (ECL is required at README.md:140, and its job builds examples/rx through tests/suite/v04.lisp:188) and "loadable from Ultralisp or a checkout" (installation.md:97), four lines kept; installation.md:144 "everything, on SBCL", :146 "HTTP" → "HTTPS" (README:162, ci.yml:98), :132 "the bundled `regex` example" → "the bundled `rx` example, a wrapper of the `regex` crate" (`ls examples/` has no regex; examples/rx/Cargo.toml:2); usage.md:30 `#<CRATE` → `#<RULISP:CRATE` (crate.lisp:44-45 prints with `:type t`; README:43, quickstart:110, usage:214 carry the prefix); usage.md:217-218 a `  ...` line between Artifact and Built with (crate.lisp:504-513 prints Loaded copy, State and Crate version between them); stability.md:69 "(§11's ignore-unknown-keys rule)" → "(BOUNDARY §11's …)" (stability has nine sections; BOUNDARY.md:260 is `## 11. Manifest`); stability.md:234 "some three hundred rows" → "long" (claims.md:482: 429); SECURITY.md:179 "§4 has the full support and deprecation policy" → "§4 states the supported versions; §3 the deprecation policy" (stability.md:72, :98); docs/distribution.md:243 and tools/rulisp-audit.sh:17 "twelve" → "every asset it attaches" (blobs.yml:145 asserts 16; these are the two live sites); DESIGN.md gains a two-line header naming it the v0.1 plan of 2026-07 with BOUNDARY.md and docs/stability.md as the normative text, and README.md:124 says so. Register rows 99, 163, 165, 167, 189 (+ the `ECL / Linux (required)` job), 235, 239 ("exactly those four" → "those four plus httpd, which ships as source"; `ls examples/` = five) with its sister 308 (blobs.yml:76/:80, :148), 269 ("9 :doc keys" → 11: `grep -c ':doc' tests/golden/wordbag.manifest.sexp`). Acceptance: `grep -c 'every suite but fetch and httpd' README.md docs/installation.md` → 1 and 1; `grep -c 'asdf:load-system :rulisp' README.md docs/quickstart.md` → 0 0; `grep -rniw twelve tools docs/*.md` empty; `grep -c 'three hundred' docs/stability.md` = 0; `grep -c '#<CRATE ' docs/usage.md` = 0; `sh tools/check-versions.sh` ok; `make test-httpd` green (httpd.veneer-hello finds the hello by `(search "(web:with-server" text)`, so inserted lines move nothing it reads) (M).
3. ☐ **The examples' Lisp-visible text: docstrings and messages.** A `///` on an export is the Lisp docstring (usage.md:226-227; the manifest's `:doc`), and the examples carry version-era remarks and wrong facts in them. examples/rx/src/lib.rs:37-38 "no more sentinel values (v0.2)" → "First match, or NIL when there is none — `Option<String>` crosses as `(:option :string)`" (two lines kept so claims.md:216's :38-41 holds), :4 "~60 lines" → "under 70" (`wc -l` = 68); examples/wasm/src/lib.rs:10-12 "v1 scope … a v0.2 rulisp feature" → the shipped description plus one `//!` paragraph naming the `Wasi` sandbox (643 of the file's 813 non-blank non-comment lines, introduced today only by a `//` block at :230-266), and :212/:223 "(v1 speaks i32/i64)" → "(only i32 and i64 cross)" in two `wasm:wasm-error` messages, and :231's banner loses "(v0.7)"; examples/wordbag/src/lib.rs:120-121 the opt_scale docstring loses "(v0.6 — the value slot carried a fixnum 0 …)" (two lines kept), with the same two lines in tests/golden/wordbag.manifest.sexp:119-120 and the oracle's copy tests/m1-handwritten/wordbag.manifest.sexp:119-120 (`cmp` = IDENTICAL today; the oracle serves it via `include_str!`) and the oracle's twin comment at tests/m1-handwritten/src/lib.rs:74-75; examples/fetch/src/lib.rs:343-345 "capped like every other wait" → "bounded at 5 s, the one deliberate exception to the 100 ms cap" (:359 `grace_ms.min(5_000)`, :43 `WAIT_CAP_MS = 100`; three lines kept so `pub fn shutdown` stays :346 for BOUNDARY.md:393), :281-283 make-client gains the clamps 1..64 / 1..4096 and "0 = 30 s" (:291, :311, :318, :319), :414-417 make-req gains "TIMEOUT-MS 0 means no timeout" (:683), examples/fetch/http.lisp:225 the same for `:timeout-ms`; examples/httpd/src/lib.rs:586-588 server-wait gains 'kind "usage" once the server is stopped' (:591-593; take-request's :708-710 already says it); bind's docstring after :489 gains the clamp line — queue 1..65536, workers 1..64, body-cap 1 KiB..1 GiB, head-ms/body-ms 1..3 600 000, queue-wait-ms ≤ 3 600 000, max-connections 1..1 048 576 (:512-530), handler-ms taken as given (:528). The published crates' rustdoc — the docs.rs front door — carries the same remarks on ten lines (crates/rulisp/src/lib.rs:120, :175, :178; crates/rulisp-runtime/src/lib.rs:189; crates/rulisp-runtime/src/meta.rs:19, :22, :27, :29, :40, :42): same-line rewordings, comments only, so the crates stay API-identical to v0.8.0. Two loader docstrings forget Windows: lisp/src/build.lisp:94 (`load-blob-crate` loads `<name>-<os>-<arch>.dll` there, build.lisp:87-91) and lisp/src/crate.lisp:123 (`load-crate`'s ".so/.dylib" → ".so/.dylib/.dll"); docstrings are not in the Lisp API golden. One `### Changed` line in the CHANGELOG for the docstrings a blob or example user sees; the wordbag golden's diff against v0.8.0 is confined to `:doc` values (the decision below). Acceptance: with item 9, `grep -rn 'v0\.[0-9]\|v1 speaks' examples/*/src/*.rs` empty; `grep -nE '^\s*//[!/].*(v0\.[0-9]|\bv1\b)' crates/*/src/*.rs` empty, `git diff v0.8.0 HEAD -- crates/` shows comment lines only and `make doc` is green; `cargo test -p wordbag` and `make test-m2` green with the regenerated golden; `make test-fetch`, `make test-httpd`, `make test-m4` green; claims.md:58's "1066 lines total" re-measured (M).
4. ☐ **docs/fetch.md and the HTTP client's bounds.** On the docs/httpd.md model: loading (http.lisp:8-9 — `use-crate` the directory, then `load` http.lisp; the release blob carries the FETCH package only, no veneer), `http:with-client` / `http:get` → `(values body status headers)` (http.lisp:216-217, :245), `http:download` (:254-256), the `http-error` slots (:36-39) and twelve kind tokens (usage, busy, request — error.rs:21-29; runtime, cancelled, timeout, transport, io, too-large, stalled — lib.rs; status — http.lisp:242; the fallback "error" — http.lisp:36, :49), the `retry-request` restart (:247-249), and a limits table: WAIT_CAP_MS 100 ms (lib.rs:43), make-client's four arguments with the veneer defaults 2/16/8/30000 (http.lisp:144) and their clamps (lib.rs:291, :311, :318, :319), `*max-bytes*` 256 MiB (http.lisp:165), `:timeout-ms` 30000 and 0 = none (http.lisp:213, lib.rs:683), READY_CAP 4096 (lib.rs:200), shutdown grace ≤ 5 s (lib.rs:359), CRLF/NUL header refusal (http.lisp:64-89); one sentence that the veneer is example code, not a frozen surface — the sentence httpd.md:4 and the wasm section get too. Then `### What the HTTP client bounds, and what it does not` in SECURITY.md after :175 (`grep -c fetch SECURITY.md` = 0 today; :47-48's intro names httpd only), a pointer section in usage.md after :140, the link from README.md:115-118 as :122 links httpd.md, and one test — `fetch.progress-accessors`, appended after tests/suite/fetch.lisp:583 — for the six FETCH exports no test or veneer calls (req-id, req-settled, req-failed, req-head-done, req-header, req-buffered), so the page's accessor rows can cite it. Register: a `## docs/fetch.md` section after the httpd rows (:427-479), one row per sentence citing fetch.buffered-body-is-capped-by-default (:351), fetch.header-injection-refused (:365), fetch.admission-refuses-loudly (:231), fetch.waits-are-capped (:68), fetch.body-and-status (:98); claims.md:3's "seven docs/ pages" brought to the tree's count (item 8's header edit); the footer recounted with its `, 0 unverified.` tail (tools/check-1.0.sh greps it). Acceptance: `test -f docs/fetch.md`; `grep -c 'HTTP client bounds' SECURITY.md` = 1; `grep -c 'fetch.md' README.md docs/usage.md` ≥ 1 each; `grep -c '^(test ' tests/suite/fetch.lisp` = 24 and `make test-fetch` green; `sh tools/check-1.0.sh` prints `ok criterion 4: docs/claims.md: 0 unverified` (M).
5. ☐ **WebAssembly from the REPL.** docs/usage.md gains a section between :140 and :142 (`## Events from Rust threads`): the load line (tests/suite/wasm.lisp:21-23's) and the blob form; the runner — `wasm:make-wasm` on examples/wasm/fib.wat with a string path (lib.rs:60 `path: &str`) and fuel, `wasm:wasm-exports` → "add,boom,fib,sum_mem" and `(wasm:wasm-call1 w "fib" 20)` → 6765 (wasm.lisp:83, :124) under `unwind-protect`/`rulisp:free`; the sandbox — `wasm:make-wasi` on examples/wasm/wasi-hello.wat with fuel and a memory limit, `wasi-run` → the exit code, `wasi-stdout` as octets to decode (lib.rs:996 `Vec<u8>`), `wasi-preopen` with its two arguments (lib.rs:944); traps and out-of-fuel signal `wasm:wasm-error`, a `rulisp:rust-error` (wasm.lisp:46-49); on ECL loading the crate compiles a trampoline for its stored callback, so a C toolchain is needed (README.md:148, wasm.lisp:66-70). Today README.md:94-114 is the example's only page and names none of the 19 functions the module! block (lib.rs:1055-1066) generates; the README idiom v07-plan.md:61/:97 promised never landed. Link from README.md:94; register rows after claims.md:274; footer recounted; the snippet run once before committing (no test reads it). Acceptance: `grep -c 'make-wasm\|make-wasi' docs/usage.md` ≥ 2; `grep -c 'usage.md' README.md` grows by one at :94; `sh tools/check-1.0.sh` ok (S).
6. ☐ **docs/httpd.md's gaps.** (a) Deploying (:172-177): `web:server` listens on 127.0.0.1 unless `:address` is given — a literal IP, not a hostname (web.lisp:138 `(address "127.0.0.1")`; lib.rs:503-507 refuses a name with kind "usage"; `grep -i address docs/httpd.md` = 0 today) — and the per-platform builds are the reader's own: the Release attaches no httpd asset (blobs.yml:76/:80 build four crates; usage.md:48 "httpd ships as source"); (b) under the Limits table after :155: out-of-range values are clamped, not refused (item 3's ranges; lib.rs:512-530), `:handler-ms` taken as given; (c) :99-100 names `web:http-error-kind` and `web:http-error-detail` (web.lisp:29 exports them, :51-53 define them; both count 0 on every user page today) and the kinds a handler meets; :56 says `start` runs four pullers by default (web.lisp:255 `(threads 4)`) and `stop` ends with `web:shutdown` (web.lisp:283); (d) :180 "(2 s each at most)" for the dump hook (lib.rs:1125, :1135); (e) :71 `(ql:quickload '(:com.inuoe.jzon :alexandria))` — the block uses `alexandria:plist-hash-table` (:79) and neither rulisp.asd:6 nor jzon depends on alexandria; it loads today only through cffi (cffi.asd:40-42). Register: new rows after :464 and :474, rows 444/449/473/475 extended, footer recounted; row 446 re-dated after the JSON block is re-run. Acceptance: `grep -c ':address' docs/httpd.md` ≥ 1; `grep -c 'http-error-kind' docs/httpd.md` ≥ 1; `grep -c 'clamped' docs/httpd.md` = 1; `make test-httpd` green (S).
7. ☐ **installation.md and usage.md: what a newcomer and a Case-A user miss.** installation.md: an ECL block after the CCL one (:35-40) — `sudo apt install -y ecl` (ci.yml:288) — and two gate lines after :145 (`ecl --norc --load tests/run-m4.lisp`, ci.yml:308; `make test-ecl-program`, Makefile:47-56): today `grep -ni ecl docs/installation.md` hits only :11 though README.md:140 lists ECL as required; a Windows bullet after :91-93 saying `make test-fetch` and `make test-httpd` are best-effort there (README.md:144-145, stability.md:124-125, ci.yml:265/:271 `continue-on-error: true`), the fetch promotion staying carried, both are named; the Runtime-facts bullet :160 names `use-crate`'s `:features` and `:package` (lisp-api.sexp:55 `(crate-dir &key (profile :dev) package features)`; build.lisp:52-54, crate.lisp:121-131) and what `reload-crate` does (no cargo; crate.lisp:132-139) — `grep -n ':features\|:package'` over the user pages is empty today. usage.md: after :55 one sentence saying what the `wordbag` blob is — the suites' fixture, 35 fns and 2 handles (`grep -c '(:fn ' tests/golden/wordbag.manifest.sexp` = 35), shipped so the no-toolchain path can be exercised; README's "4 fns, 1 handle" is the trimmed snippet (`grep -n examples/wordbag README.md docs/*.md` minus claims hits only benchmarks.md:12); :39-41 lists the four published blob names (blobs.yml:43/47/51/55: linux-x86_64, darwin-arm64, windows-x86_64, linux-arm64 — `darwin-arm64` and `linux-arm64` appear on no user page today). Register: rows for each new sentence in the installation (:128-183) and usage (:225-283) sections, row 236 extended and its `build.lisp:58-75` → :74-91 (host-blob-suffix and blob-file-name, both named by the row), footer recounted, and claims.md:350's `docs/installation.md:97` re-anchored once after all installation.md inserts (the only line-numbered citation of that page). Acceptance: `grep -c 'apt install -y ecl' docs/installation.md` = 1; `grep -c 'best-effort' docs/installation.md` = 1; `grep -c ':features' docs/installation.md` = 1; `grep -c 'darwin-arm64' docs/usage.md` = 1; `grep -c "suites' fixture" docs/usage.md` = 1; `sh tools/check-1.0.sh` ok (M).
8. ☐ **The registers re-anchored.** Every line citation in docs/claims.md and BOUNDARY §12 checked against today's files, the way bc5e7ac did for lib.rs before 0.8.0 (52 rows): (a) 36 claims.md rows cite a test at a line outside it (docs/claims.md:219's m5.callback-basic 183→194 among them) — tests/suite/m1.lisp +11 since e32e114 (m6.reload 234→245, m7.dump-restore 274→285, m4.free-vs-in-flight 151→162, m5.callback-basic 183→194), m2.lisp +11 since 33c5920 (fx.golden-manifest 125→136, fx.use-value-restart 84→95, fx.target-check 71→82), v05.lisp wrong since the register's first commit (doc-escaping 149→154, describe-crate 170→175, utf8-fastpath-boundary 185→193); the same m2 shift in 8 BOUNDARY §12 rows (:314, :315, :417, :418, :419, :421, :425, :426 — fx.golden-manifest runs 136-158) and manifest.lisp's three off-by-one ranges (:417 → 25-34, :418 → 36-50, :422 → 52-62); (b) 25 claims rows cite lisp/src/build.lisp at the v0.5.0 tree's lines (today find-cargo 12, %run-cargo-build 47 with `--release` at 52, host-blob-suffix 74, blob-file-name 87, load-blob-crate 93-104, use-crate 106-131, restart-case 117-124), plus conditions.lisp (rows 171/253 `56-61` → build-error 90-99; 206 `5-12` → 9-16; 210/252 → stale-handle-error 62-75), package.lisp:41 → :56 (row 118), codegen.lisp `238-239` → 242-246 (row 30) and `378-405` → 394-426 (row 260); (c) 8 rows cite ci.yml lines that are other steps now (305 :66/:110, 311/312 :186-187, 315 :170-175, 318/368 :175, 340/342 :181-185, 368 :101) — cite the job/step names as rows 82-86 and 167 do; Makefile:75/70-71 → :143/:139-140 (rows 146, 166, 168), blobs.yml:42-44/65-68/104 → :50-53/:76,80/:148 (rows 307, 308), tools/rulisp-audit.sh:16/36-40/44-52 → :24/:81-84/:93-98 (row 344); (d) tests/bench.lisp rows 362/363/380/392/393/417/420 (the rx block is :70-83, the callback blocks :105-115 and :117-122), crate.lisp `409-428` → 625-646 (row 301), rows 82/83/85/86/138/148 add the test-httpd steps the jobs run (ci.yml:98-101, :178-181, :212-215, :351-354), quickstart.md:92-94 → :96-98 (row 164), examples/wordbag/src/lib.rs:149 → `notify_from_thread`'s line after items 3 and 9, tests/ecl-program/build.lisp:17 → :25 and :3-19 → :3-26 (rows 335, 313; the quickload form moved in d04680e of 2026-09-30); (e) the header: "seven docs/ pages" → the count after item 4, "347 are rows here" made historical, :159/:256 refreshed, and one clause at :9-10 — the next audit also checks every `NAME (tests/suite/X.lisp:N)` against its `(test NAME` line; BOUNDARY.md:435's verification note dated 0.8.1 and its two stale "corrected" citations (`lib.rs:17,37-42`, `codegen.lisp:179-185`) dropped. Then every `path:line` citation in both registers is re-read against the tree, row by row — the audit claims.md:9-10 promises. Acceptance: `grep -cE '(m1\.lisp:(151|183|191|234|238|240|242|248|274)|m2\.lisp:(71-78|84|125)|v05\.lisp:(149|170-175|185))\b' docs/claims.md` = 0 (36 today); `grep -cE 'm2\.lisp:(26-29|31-33|35-37|57-61|71-78|96-118|125-146)' BOUNDARY.md` = 0 (8 today); `grep -cE 'lisp/src/build\.lisp:(7-1[01]|41-56|49-56|58-75|77-88|90-(91|102|108|112)|104|97,106-111|99-105|46\b|109\b|73-74)|build\.lisp:(96|7-11,98)' docs/claims.md` = 0 (25 today); `grep -cE 'ci\.yml:(66|110|170-175|175|181-185|184-185|186-187|101)\b' docs/claims.md` = 0 (8 today); `grep -c 'ecl-program/build\.lisp:17\b\|ecl-program/build\.lisp:3-19' docs/claims.md` = 0 (2 today); `sh tools/check-1.0.sh` ok (M).
9. ☐ **Example source hygiene** — comments and manifests, nothing Lisp sees. examples/wordbag/src/lib.rs:134 and tests/m1-handwritten/src/lib.rs:655 "Stored callback (v0.2)" → "Stored callback", and the oracle's five `(v0.2 …)` shim comments (:183, :198, :555, :578, :610) lose the tag; lib.rs:303-306's "Module registry" banner moved above `rulisp::module!` (:357), the dump hook and Grenade (:308-355) headed by their own; the header (:1-3) says README's hero snippet is this crate's greet/WordBag corner and the rest the suites' fixture (`grep -rn examples/wordbag README.md docs/{installation,quickstart,usage}.md` = 0 today); examples/wordbag/Cargo.toml:5 in the other four's "rulisp example: …" shape, naming the ABI oracle instead of "M1"; examples/wordbag/tests/manifest_golden.rs:1-2 "frozen in M2" → regenerated with the oracle's copy whenever the manifest changes (`git log --oneline -3 -- tests/golden/wordbag.manifest.sexp` shows three regenerations); tests/m1-handwritten/src/lib.rs:551 prints the macro's line `rulisp[wordbag]: panic in grenade_free (swallowed)` (crates/rulisp-macros/src/lib.rs:897-901; its own :374 already does); examples/fetch/src/lib.rs:24 one line naming 0.4's `on_dump` as the one feature past 0.3 it uses (:795); examples/fetch/src/testserver.rs:59 says the blank line is kept (:42, :61 — nothing strips it); examples/httpd/src/lib.rs:12-18 re-flowed without "not in a later commit" (seven lines kept); examples/httpd/web.lisp:3-4 "nine positional limits" → "an address, eight positional limits" (lib.rs:492-501; two lines kept so :22-30 stays cited); examples/httpd/Cargo.toml:19 gains `"io-util"` (lib.rs:38 imports AsyncReadExt/AsyncWriteExt; fetch's Cargo.toml:19 lists it); Makefile:4 `.PHONY` gains test-httpd test-httpd-ccl (targets :34, :38; 19 names today, 21 targets); ci.yml:100 "httpd suite (the HTTP server example, v0.8's flagship)" → the :214 form; ci.yml:267-268 "httpd.dll will ship in every release" → httpd ships as source; tests/bench.lisp:71-72 "a memchr sweep" → benchmarks.md:90-93's wording (claims.md:418 records the attribution as removed); tests/run-m4.lisp:2 "All suites (M1..M4)" → what it runs (13 suites, neither fetch nor httpd), and run-v05/v06/v07.lisp:2, which copied the line, name their one suite; lisp/src/stored-callback.lisp:3 "Stored callbacks (v0.2)" → "Stored callbacks" (lisp/src/package.lisp:12's twin stays, the file being byte-identical to v0.8.0 for item 11's check; codegen.lisp:540's "(v1)" in a condition message is loader text, left for 1.0). Acceptance: `grep -rn 'v0\.[0-9]' examples/wordbag tests/m1-handwritten/src/lib.rs` empty; `sed -n '4p' Makefile | grep -c 'test-httpd test-httpd-ccl'` = 1; `grep -c memchr tests/bench.lisp` = 0; `grep -c "v0.8's flagship" .github/workflows/ci.yml` = 0; `grep -c 'All suites (M1..M4)' tests/run-*.lisp` all 0; `make audit`, `cargo test -p wordbag`, `make test-httpd` green (S).
10. ☐ **ROADMAP and CHANGELOG records, and the sentences that point at them.** ROADMAP.md:105 (line numbers as this section left them) "eight items ✅ (1, 2, 3, 6, 7, 9, 10, 11)" → "nine items ✅ (1, 2, 3, 6–11)" (items :117-127 carry nine ✅, one ✂, one ☐); :189 and :203 gain the leading ✅ every other numbered item has (51 of 53 do; :146 says 0.7.0 shipped all nine); :779-781 dates the blob legs — two in 0.2, Windows x86-64 in 0.5 (a71af56), Linux aarch64 in 0.7 (2b77a1f), four since — against blobs.yml:42-55; :796 ✅ (v0.4 item 2, CHANGELOG.md:554-555); :807 ✅ (v0.3's groundwork 902bac7 and v0.4 item 7), :805/:812 "refused with cause"; "Later / exploratory" (:819) gains the 0.8 flagship's 1.x findings and streaming responses, and a line on the httpd adversarial pass — not scheduled; httpd stays source-only until it runs — that SECURITY.md:99 and :173 point at instead of the closed v0.8 item 2; CHANGELOG.md's 0.6.0 section loses its nine repeated headings (:261, :276, :283, :290, :298, :311 `### Added`; :334 `### Changed`; :355, :375 `### Fixed` — every other release has one per kind); docs/releasing.md:67's "gh 2.4.0" aside and installation.md:10's "tested with 1.97" dropped or dated. Acceptance: `grep -nE '^[0-9]+\. ' ROADMAP.md | grep -vcE '^[0-9]+:[0-9]+\. (✅|✂|☐)'` = 0; `awk 'NR>=242 && NR<=380 && /^### /' CHANGELOG.md | wc -l` = 3; `grep -c '^\*\*Released as 0\.8\.0\*\*.*nine items' ROADMAP.md` = 1; `grep -c 'ROADMAP v0.8 item 2' SECURITY.md` = 0 (S).
11. ☐ **releasing.md for a patch, and the gates.** docs/releasing.md step 1 (:7-11) names 8 of `make check-versions`' 12 sites: add docs/usage.md's `describe` transcript (check-versions.sh:27) and stability §2's "(X.Y.Z everywhere today)" (:28, a site since 5fe4655), and say the `rulisp = "X.Y"` lines are major.minor — a patch leaves them (:10 `MM=${V%.*}`); step 3 (:19-22) gains the patch rule — the goldens byte-identical to the previous tag, `git diff --quiet vPREV HEAD -- tests/golden/lisp-api.sexp lisp/src/package.lisp` (exits 0 against v0.8.0 today), the wordbag golden's diff confined to `:doc` values — because an added export fails only `v06.exported-api-golden` and stability.md:30-31 tells a contributor to regenerate it, after which every gate is green; step 9 (:74-81) gains the Rust API gate's `release-type` for the cycle being opened (`grep -c release-type docs/releasing.md` = 0 today). The gate itself went in with item 1's commit: ci.yml:43 `release-type: minor` → `patch` for this cycle — the tool's 58 Minor-level lints (`*_struct_added`, `*_enum_added`, `trait_added`, `inherent_method_added`, `pub_const_added`, `pub_static_added`) then fail too, a free `pub fn` or `pub mod` has no lint under either — with :39's name "as a patch", the :33-38 comment saying why, stability.md:34 "(`patch` during a patch cycle)" and :63 "a **patch** neither breaks nor adds"; the crates are byte-identical to v0.8.0 at that commit (`git diff --stat v0.8.0 HEAD -- crates/` empty), so its run is green or the action refused the value; item 3's doc-comment edits leave them API-identical. Acceptance: `grep -c 'everywhere today' docs/releasing.md` = 1; `grep -c 'byte-identical' docs/releasing.md` = 1; `grep -c 'release-type' docs/releasing.md` ≥ 1; `grep -c '^ *release-type: patch' .github/workflows/ci.yml` = 1; `sh tools/check-1.0.sh` prints `ok criterion 3: ci.yml runs cargo-semver-checks-action` (S).
12. ☐ **v10-plan corrections the tree already contradicts.** docs/design/v10-plan.md step 2 (:79-80) → "the diff must consist only of std path abbreviations" over 10 ui cases (only non_send_handle.stderr has `std::vec::Vec`); step 3's pin pattern `=` required, not `=?`, and stability §2's shared-version site added to its list; step 5's grep widened to `planned for 1\.0`, `1\.0 decision`, `follows 0\.8` and its page list gaining docs/installation.md:97 and docs/distribution.md:9-15/:263-264; step 1's check gaining "re-anchor every lib.rs/meta.rs citation in BOUNDARY §12 and claims.md"; the Quicklisp issue text's depends-on gaining `uiop` (lisp/rulisp.asd:6); §4 :153 and :88-89 saying which release-type the gate ran as before the 1.0 push; :61's example pin `"0.8.0"` → `"0.8.1"` at the release. Not here: the §1 table's re-measurement, which waits until crates.io serves 0.8.1 — the gate's baseline then. Acceptance: `grep -c uiop docs/design/v10-plan.md` ≥ 1; `grep -c '=?' docs/design/v10-plan.md` = 0; `grep -c 'planned for 1' docs/design/v10-plan.md` ≥ 1; `grep -c '"0\.8\.0"' docs/design/v10-plan.md` = 0 after the release commit (S).
13. ☐ **Handling conditions** (1.0-cycle work a docs cycle can take; last in the cut order). docs/usage.md gains a short section: the class tree with `rulisp-error` as the root, one `handler-case` reading `rust-error-type`/`rust-error-message`/`rust-error-function-name`, one on `build-error` reading `build-error-stderr`/`build-error-command`, the `use-value` and `retry-build` restarts, the `rulisp-version-skew` warning's readers. 21 condition readers are exported (package.lisp:34-54) and no user page names one (`build-error-stderr` appears only in claims.md:171/:253/:347); 22 of the 47 exports appear on no user page. A claims row per sentence, the footer recounted; stability.md:75-80's "named only in DESIGN.md or the CHANGELOG" reviewed. Acceptance: `grep -c 'handler-case' docs/usage.md` ≥ 1; `grep -cw 'rust-error-message' docs/usage.md` ≥ 1; `sh tools/check-1.0.sh` ok (M).
14. ☐ **Reserved: one S for what the review finds** (S).

## v0.8 — the server that owns a listener

The first example that owns a listening socket: `examples/httpd`, an
HTTP/1.1 + h2c server on axum/hyper/tokio whose handlers are Lisp
functions, built on the boundary exactly as 0.7's flagship was — the
maintainer's call of 2026-09-28 ("a recent web server, light and fast,
with good async support"; MCP on rmcp follows it, on its HTTP
transport). The shape is dictated: a stored callback returns no value
to Rust, so the server is fetch's mirror, pull-based — Rust owns the
listener, every connection and the protocol, parks each request in a
bounded queue, Lisp threads pull with capped waits and answer through
the request handle. The panel's probe built it on 0.7.0's macros
unchanged (axum 0.8.9, tokio 1.53.1, hyper 1.11.1; 52 registry
packages, four new over fetch's tree; 2.03 MB stripped with h2;
`audit ok`) and measured it from SBCL: two OS threads and no Lisp thread
per server, 14k req/s with two pullers, h2c answered, 413/503/500 where
they belong, the dump hook quiescing and the restored image serving.
One surface moves, additively: the Rust API gains `rulisp::Inbox`
(item 11), checked as a minor against 0.7.0; ABI 1, `:schema` 1 and the
Lisp API golden's 47 rows (no export added) stand. Every
bound a server cannot ship without — a head timer, a body timer, a
handler timeout, a connection cap, a bounded queue that waits before
503, dead-slot pruning, a bounded dump drain — is in the first feature
commit, because the probe measured the holes and `axum::serve` sets no
timer; the cross-host compile is dispatched from a branch before any
feature; the suite's client is an in-crate `Probe`; a web developer
reads docs/httpd.md first. CI is budgeted on the measured baseline —
run 36690864696 (2026-09-30): 6 min 42 s wall, Lisp jobs 134-397 s; the
0.7 flagship cost +30-50 s per Lisp job — and 0.8's cost was measured the
same way at its close (below). The cycle's gates compared against
v0.7.0, and the aarch64 job loaded its own release asset with
`load-blob-crate`, as the x86-64 job does. Full plan with demand cases,
acceptance criteria and cut order:
[docs/design/v08-plan.md](docs/design/v08-plan.md).
Budget 1 L + 1 M + 7 S, one S reserved for what the review and the pass find.

**Released as 0.8.0** (2026-10-14): eight items ✅ (1, 2, 3, 6, 7, 9, 10,
11); item 4 cut (httpd ships source-only, sixteen assets); item 5
carried (the Windows fetch count passed 24 only at the release — see the
item); item 8 closed by the release commit and the one that opens the
next cycle. One surface moved, additively: the Rust API gained
`rulisp::Inbox`; ABI 1, `:schema` 1 and the 47 Lisp exports are as 0.7.0
left them. CI cost at the close, run 38351565952 (bc5e7ac, 2026-10-13):
6 min 8 s wall, Lisp jobs 166–365 s, against 0.7's baseline of 6 min
42 s and 134–397 s — SBCL/Linux grew most, 168 → 286 s, with the httpd,
v08 and v09 suites; CCL 134 → 166 s, aarch64 173 → 202 s, macOS 234 →
238 s; ECL (291 → 288 s) and Windows (397 → 365 s) got shorter.

1. ✅ Open the cycle on true documents: BOUNDARY §12's fetch rows name the four hosts that run them, README and claims.md add aarch64, ROADMAP's missing ✅ and stale v0.2 sentences, stability.md's "0.6.0 suite" (S). Done 2026-10-01: the three §12 rows cite the `make test-fetch` steps of the four required jobs and the best-effort Windows step; README's job paragraph and claims row 162 add aarch64 (required since 2026-09-30); v0.5 item 1 ✅ with c58ff38; the v0.2 Windows and WASI sentences are records now; stability §1 says "the previous release's suite". Found on the way: two claims rows cited ROADMAP by line numbers that had been stale since v0.3 — they cite by section now, which does not rot; `check-1.0.sh` holds and the footer still reads 362 rows.
2. ✅ The flagship: `examples/httpd` — the pull-based server with every bound in the first feature commit, the `web` veneer with the debugger-in-the-handler-frame discipline, an in-crate `Probe` client, ≈ 33 tests on fetch's route (required on SBCL/Linux, CCL, macOS, aarch64; best-effort on Windows), the cross-host compile dispatched first, the five-lens review and the adversarial pass before any blob ships (L). Progress (2026-10-02): commits 0, 1 and the review's fixes merged to main at 58d4765 — the fifth crate compiled and loaded on every host from the first dispatch; the review (five lenses, 16 skeptics, a critic) found three bounds the first cut lacked — hyper-util's protocol sniff has no timer, one h2c connection could hold 200 streams × BODY-CAP, `respond-file` opened before it stat'ed — and the framing hyper would have asserted on, all closed with a test each (41 tests, 229 checks); commit 2 adds `web.lisp`, the dump tests, BOUNDARY §12's rows and SECURITY's list; the planned adversarial pass was not run, and the maintainer chose to ship httpd as a source-only pattern example instead (2026-10-07). What stands in for it is the pre-merge review's attack lens and the tests it left (slowloris and silent connections, unanswered handlers, a client that left while parked, CRLF/NUL in Lisp headers, racing pullers, double respond, port reuse, reload and dump while serving, the h2 body bound); floods past the queue, huge or lying lengths, h2 SETTINGS floods and rapid reset, a handler that frees or stops its server, descriptor exhaustion and a GC storm under load remain unattacked, and SECURITY.md says the pass was not run. Reframed 2026-10-07 (043da14): docs/httpd.md opens on the split — Rust events, Lisp handlers, a queue between.
3. ✅ The web developer's page: docs/httpd.md (transcripts, the loop's contract, the error discipline, the limits table, testing, deployment), the six-line hello in docs/usage.md evaluated byte-identically by a test, the README sentence, and a claims row per sentence with the footer recounted (S). Done 2026-10-07: docs/httpd.md (168 lines; the JSON transcript uses jzon as the user's choice, and the page's Lisp blocks were evaluated verbatim with their curl output diffed against the page); `httpd.veneer-hello` reads the hello from docs/usage.md (only the port swapped) and asserts docs/httpd.md prints the same text — changing the page's response text alone fails it; README's sentence and job paragraph; installation's `make test-httpd`; 56 claims rows (47 for the page), footer 418 / 370 / 48 / 0. Deferred to item 4: usage.md:44's "four examples ship this way", which becomes true for httpd only when blobs.yml builds it.
4. ✂ The fifth crate across every count site (blobs.yml 16 → 20, releasing, usage, distribution, claims, v10-plan, installation) and the release path rehearsed from a branch with `publish=false` and twenty assets before the tag (M). Cut 2026-10-07 by the plan's own clause: httpd ships source-only, blobs.yml stays at sixteen assets for four of the examples, and docs/releasing.md, docs/distribution.md, docs/usage.md and the CHANGELOG say so. The pass it waited on was not run (item 2).
5. ☐ Windows: the fetch step promoted at ECL's count of 24 green runs; the httpd step starts best-effort on the same procedure (S). Not promoted: 19 consecutive green Windows fetch executions on main from 36388353221 (729b888) to 37575345718 (da4e5d2), short of 24; the step stays best-effort and the count carries into the next cycle, never by calendar. At the 0.8.0 release the count is 26: seven more green executions, 37588981465 (877ff03) through 38351565952 (bc5e7ac), so the threshold is met; 0.8.0 ships with the step still best-effort — the promotion is a change of its own (ci.yml's `continue-on-error`, stability §5, README's table, BOUNDARY §12's fetch rows, claims) and is pending.
6. ✅ `load-crate` on a directory signals `crate-not-loaded-error` naming `use-crate`, not the host's stream error (reproduced on SBCL: `SIMPLE-STREAM-ERROR … Is a directory`); tests/suite/v08.lisp on all six Lisp jobs (S). Done 2026-10-07 (942be6e): failing first on SBCL 2.1.11 with SB-INT:SIMPLE-STREAM-ERROR for both spellings (6 of 8 checks); green on SBCL, CCL and ECL through run-m4.
7. ✅ Two macro diagnostics the flagship's author hit: `Option<Handle>` as a result names its real rule, and `on_dump` naming a function with parameters is a rulisp-worded error, not a raw E0308; two trybuild cases (S). Done 2026-10-07 (877ff03, narrowed in the review fixes): `#[diagnostic::on_unimplemented]` was probed on MSRV 1.78 and is not used for an arity mismatch (E0593) or a non-unit result (E0271); the guard is a const assertion on the export's own metadata, on parameters only, so a hook with a result still compiles and is refused by the loader as in 0.7. No Rust API item added; trybuild option_handle_result and on_dump_with_params.
8. ✅ Close the cycle: the pre-release review of v0.7.0..HEAD, the write-up with its falsification evidence and the measured CI cost, stability §3/§8 "as of 0.8", 0.8.0 with sixteen assets (httpd source-only, item 4 cut), and the commit that opens the next cycle with the pins at v0.8.0 (S). Done 2026-10-14: three passes reviewed the cycle — the whole-diff review that is item 9's record (722fd07, 2026-10-07); bc5e7ac's final review of 2268804..HEAD (three lenses — code, documents, release readiness — and a skeptic per finding; four findings confirmed, no code defect: citations re-anchored by hand, the cache stated host-local, the release notes completed, send_timeout's no-deadline branch exercised); and the pre-publish check on 1b89247 (three lenses, a skeptic per finding), which found three older document slips, fixed in 5fe4655 before `cargo publish` (README's fifteen relative links, dead on crates.io since 0.7.0 because cargo records the crate's directory as the README's path, made absolute; stability §2's shared version, stale through two releases and a check-versions site now; the hello's line count). The write-up is the paragraph above, and stability §3 is reviewed for 0.8 and §8 reads as of 0.8.0 (1b89247). Release day as docs/releasing.md: the workflow rehearsed twice from main with `publish=false` — 38468233245 on 1b89247, whose release job failed in the gate step on a GitHub API 502 and passed when the failed job was re-run in place (step 7 says how now), and 38471288870 on 5fe4655, clean — then the three crates published in order (crates.io 0.8.0 ×3), the tag on 5fe4655, and its run 38490986425 green at the first attempt: sixteen assets, `audit ok` on their own hosts and `re-audited 16 assets` on Linux, the Release body the CHANGELOG section. Ultralisp still served 0.7.0 minutes after the tag (`tools/check-dist.sh`; it polls on its own schedule). The commit that follows, 4197662, opens the next cycle — written as 1.0's, re-labelled 0.8.1 on 2026-11-17 (the v0.8.1 section) — with the pins at v0.8.0 — locally `make compat PREV=v0.8.0` is green (the 0.8.0 loader loads this tree's wordbag; API-SUBSET-OK, all 47 entries; the 0.8.0 suite's 716 checks pass with nothing skipped, the versions agreeing again) and v0.8.0's `libwordbag-linux-x86_64.so` loads with `load-blob-crate`, cargo out of reach. The release is dated 2026-10-14 here and in the CHANGELOG: the release commits were made on the 13th UTC, the crates, the tag and the Release went out after midnight.
9. ✅ Reserved: one S for what the review and the pass find; if nothing claims it, the three WASI behaviours 0.7 probed but did not pin (ROADMAP v0.7 item 7's "probed, not pinned") (S). Claimed by the pre-release review (2026-10-07, five lenses' worth in four: inbox, macros, docs, tests; 12 findings verified, all confirmed, plus a critic): send_timeout's overflow on a huge timeout, the on_dump assertion narrowed to parameters, the 503 at stop now carries Retry-After (pinned in httpd.stop-answers-parked-503-and-pulled-finish), every lib.rs citation in BOUNDARY.md and docs/claims.md re-anchored after the diff moved them, the tier-1 sentence matched to the Windows example steps, the free-mid-stream test now observes the producer stop, a refused answer no longer counts as answered in web.lisp. The WASI behaviours stay unpinned.
10. ✅ Added 2026-10-07 by the maintainer, after the httpd discussion: **host tiers** (docs/stability.md §5) — SBCL gets every feature, CCL what CFFI, bordeaux-threads, trivial-garbage, UIOP and standard CL express, ECL the core; no required job demoted (d92a4a0).
11. ✅ Added 2026-10-07 by the maintainer: **`rulisp::Inbox<T>`**, the queue direction of the boundary as a library type (2268804; moved to tests/inbox-fixture in 2c949b3 because wordbag must stay identical to the hand-written oracle). Falsification: tests/suite/v09.lisp; WAIT_CAP_MS at 2000 fails exactly v09.inbox-wait-is-capped, the capacity check removed fails exactly v09.inbox-full-is-backpressure. The cache sweep fix (7e5055e) came from the same week: 180 copies of exited processes, 3.4 GB.

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

1. ✅ **Run the fetch suite in CI** — 23 tests §12 cites as enforcement had
   only ever run on the maintainer's machine; since c58ff38 (2026-09-02)
   the SBCL/Linux and CCL/Linux jobs run `make test-fetch` (the macOS
   step, required since v0.7, and the aarch64 job run it too; Windows
   best-effort).
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
  docs/usage.md — a dedicated helper adds nothing over it. Superseded
  2026-10-07: `rulisp::Inbox` is that helper, because the pattern's real
  cost was not the five Lisp lines but each thread-owning crate
  re-deriving the capped wait, the bound and the close on the Rust side.

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
- Windows: shipped in 0.3 (`uintptr` derived from the pointer size,
  `LoadLibrary`/`GetProcAddress`, artifact naming without the `lib`
  prefix); the Windows job is required and runs the full suite.

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
  with 0.2 (§2 above); WASI is 0.7's flagship — the `Wasi` sandbox
  (v0.7 item 7).

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
