CARGO ?= $(HOME)/.cargo/bin/cargo
SBCL ?= sbcl

.PHONY: build test-m1 test-m2 test-m3 test-m4 test-fetch test-ccl test-ecl-program bench clean

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

# ECL has no image dump: applications ship as asdf:program-op executables.
# Builds the minimal consumer in tests/ecl-program and runs it against the
# wordbag artifact. ECL exits 0 even from its debugger, so the marker is
# the gate, not the exit code.
ECL ?= ecl
test-ecl-program:
	$(CARGO) build -p wordbag
	rm -f tests/ecl-program/rulisp-ecl-smoke
	$(ECL) --norc --load tests/ecl-program/build.lisp 2>&1 | tee ecl-program-build.log | grep -q BUILD-DONE
	RULISP_SMOKE_CRATE=$(CURDIR)/target/debug/libwordbag.so timeout 120 \
	  tests/ecl-program/rulisp-ecl-smoke </dev/null 2>&1 | tee ecl-program-run.log
	grep -q ECL-PROGRAM-OK ecl-program-run.log && ! grep -q FAIL ecl-program-run.log

bench:
	$(SBCL) --non-interactive --load tests/bench.lisp

# best-effort second implementation (download CCL, then: make test-ccl)
CCL ?= $(HOME)/ccl/lx86cl64
test-ccl:
	$(CCL) --batch --load tests/run-m4.lisp

clean:
	$(CARGO) clean
	rm -rf tests/m1-handwritten/target tests/m1-handwritten/target-abort-check
