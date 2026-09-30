(module
  ;; exit126: proc_exit(126) — outside [0..126), which WASI refuses as a trap
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func (export "_start") (call $proc_exit (i32.const 126))))
