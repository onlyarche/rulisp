(module
  ;; start-exit: a (start) section that calls proc_exit(0) — the module
  ;; never reaches _start, so make-wasi refuses it by name
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func $s (call $proc_exit (i32.const 0)))
  (start $s)
  (func (export "_start")))
