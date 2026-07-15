CARGO ?= $(HOME)/.cargo/bin/cargo
SBCL ?= sbcl

.PHONY: build test-m1 test-m2 clean

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

# best-effort second implementation (download CCL, then: make test-ccl)
CCL ?= $(HOME)/ccl/lx86cl64
test-ccl:
	$(CCL) --batch --load tests/run-m4.lisp

clean:
	$(CARGO) clean
	rm -rf tests/m1-handwritten/target tests/m1-handwritten/target-abort-check
