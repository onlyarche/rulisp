(module
  ;; start-ok: a (start) section that writes "s" to stdout, then _start
  ;; writes "m" — the (start) section runs at instantiation, inside
  ;; make-wasi, and its fuel and its output count like _start's
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "sm")
  (func $write (param $ptr i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (i32.const 1))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8))))
  (func $s (call $write (i32.const 16)))
  (start $s)
  (func (export "_start") (call $write (i32.const 17))))
