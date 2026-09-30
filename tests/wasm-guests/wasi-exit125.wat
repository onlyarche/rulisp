(module
  ;; exit125: proc_exit(125), the largest exit code WASI hands back as a value
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func (export "_start") (call $proc_exit (i32.const 125))))
