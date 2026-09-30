(module
  ;; iovec: fd_write with TWO 40,000-byte iovecs per call until an errno,
  ;; then proc_exit(errno) — the cap cuts inside a call and inside an iovec
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 2)
  (func (export "_start")
    (local $err i32)
    (i32.store (i32.const 0) (i32.const 65536)) (i32.store (i32.const 4) (i32.const 40000))
    (i32.store (i32.const 8) (i32.const 65536)) (i32.store (i32.const 12) (i32.const 40000))
    (loop $again
      (local.set $err (call $fd_write (i32.const 1) (i32.const 0) (i32.const 2) (i32.const 16)))
      (br_if $again (i32.eqz (local.get $err))))
    (call $proc_exit (local.get $err))))
