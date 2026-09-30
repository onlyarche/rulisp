(module
  ;; bad-start: _start takes a parameter — not a WASI command; refused at
  ;; make-wasi rather than at wasi-run, which would spend the instance
  (memory (export "memory") 1)
  (func (export "_start") (param i32)))
