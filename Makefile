CARGO ?= $(HOME)/.cargo/bin/cargo
SBCL ?= sbcl

.PHONY: build test-m1 clean

build:
	$(CARGO) build

test-m1:
	$(SBCL) --non-interactive --load tests/run-m1.lisp

clean:
	$(CARGO) clean
	rm -rf tests/m1-handwritten/target tests/m1-handwritten/target-abort-check
