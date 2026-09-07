CARGO ?= $(HOME)/.cargo/bin/cargo
SBCL ?= sbcl

.PHONY: build test-m1 test-m2 test-m3 test-m4 test-fetch test-fetch-ccl test-ccl test-ecl-program audit doc check-versions compat bench clean

build:
	$(CARGO) build

test-m1:
	$(SBCL) --non-interactive --load tests/run-m1.lisp

test-m2:
	$(SBCL) --non-interactive --load tests/run-m2.lisp

test-m3:
	$(CARGO) test --workspace
	$(SBCL) --non-interactive --load tests/run-m3.lisp

test-m4:
	$(CARGO) test --workspace
	$(SBCL) --non-interactive --load tests/run-m4.lisp

test-fetch:
	sh examples/fetch/audit.sh
	$(SBCL) --non-interactive --load tests/run-fetch.lisp

# the same suite on Clozure CL (the dump tests use the CCL harness from m7)
test-fetch-ccl:
	sh examples/fetch/audit.sh
	$(CCL) --batch --load tests/run-fetch.lisp

# ECL has no image dump: applications ship as asdf:program-op executables.
# Builds the minimal consumer in tests/ecl-program and runs it against the
# wordbag artifact. ECL exits 0 even from its debugger, so the marker is
# the gate, not the exit code — except a timeout kill (124), which must
# fail on its own, so the run is not piped (a pipe would discard it).
ECL ?= ecl
test-ecl-program:
	$(CARGO) build -p wordbag
	rm -f tests/ecl-program/rulisp-ecl-smoke
	$(ECL) --norc --load tests/ecl-program/build.lisp > ecl-program-build.log 2>&1; \
	  grep -q BUILD-DONE ecl-program-build.log || { tail -40 ecl-program-build.log; exit 1; }
	RULISP_SMOKE_CRATE=$(CURDIR)/target/debug/libwordbag.so timeout 120 \
	  tests/ecl-program/rulisp-ecl-smoke </dev/null > ecl-program-run.log 2>&1; \
	  st=$$?; cat ecl-program-run.log; test $$st -eq 0 \
	  && grep -q ECL-PROGRAM-OK ecl-program-run.log && ! grep -q FAIL ecl-program-run.log

# BOUNDARY §7 as a gate over every example, with a self-test proving the
# audit can still fail (tools/audit-fixture imports signal()).
audit:
	sh tools/rulisp-audit-selftest.sh
	$(CARGO) build --workspace
	for c in wordbag rx wasm fetch; do \
	  sh tools/rulisp-audit.sh target/debug/lib$$c.so examples/$$c || exit 1; done

# what docs.rs will show: no missing docs, no broken links, doctest compiles
doc:
	RUSTDOCFLAGS="-D warnings" $(CARGO) doc --no-deps -p rulisp -p rulisp-macros -p rulisp-runtime
	$(CARGO) test --doc -p rulisp

# docs/stability.md §8 criterion 3, checked (Linux): the previous release's
# loader loads the tree's crate (forward), and the previous release's test
# suite runs against the tree's loader (its calls, our code). PREV is the
# last release; docs/releasing.md step 9 moves it. When the old suite
# fails: a test that reaches rulisp:: internals is recorded and skipped by
# name; a failure through an exported symbol is a break and does not land.
PREV ?= v0.5.0
COMPAT := $(CURDIR)/target/compat
compat:
	$(CARGO) build -p wordbag
	rm -rf $(COMPAT) && mkdir -p $(COMPAT)/loader $(COMPAT)/tree
	git archive $(PREV) lisp | tar -x -C $(COMPAT)/loader
	RULISP_PREV=$(PREV) RULISP_PREV_LISP=$(COMPAT)/loader/lisp/ \
	  RULISP_ARTIFACT=$(CURDIR)/target/debug/libwordbag.so \
	  $(SBCL) --non-interactive --load tests/compat/old-loader.lisp 2>&1 | tee $(COMPAT)/old-loader.log
	grep -q "OLD-LOADER-OK Hello, $(PREV) loader!" $(COMPAT)/old-loader.log
	git archive $(PREV) | tar -x -C $(COMPAT)/tree
	cp lisp/src/*.lisp $(COMPAT)/tree/lisp/src/
	cd $(COMPAT)/tree && $(SBCL) --non-interactive --load tests/run-m4.lisp > $(COMPAT)/old-suite.log 2>&1; \
	  tail -4 $(COMPAT)/old-suite.log
	grep -q "Fail: 0" $(COMPAT)/old-suite.log

# one version string across the crates, the path pins, the ASDF system
# and the docs (docs/releasing.md step 1); fails on any site that disagrees
check-versions:
	sh tools/check-versions.sh

bench:
	$(SBCL) --non-interactive --load tests/bench.lisp

# best-effort second implementation (download CCL, then: make test-ccl)
CCL ?= $(HOME)/ccl/lx86cl64
test-ccl:
	$(CCL) --batch --load tests/run-m4.lisp

clean:
	$(CARGO) clean
	rm -rf tests/m1-handwritten/target tests/m1-handwritten/target-abort-check
