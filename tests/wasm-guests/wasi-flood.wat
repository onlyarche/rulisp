(module
  ;; flood: write a 65536-byte chunk to stdout again and again until fd_write
  ;; answers a non-zero errno, then proc_exit(that errno). With an uncapped
  ;; stdout this only ends by running out of fuel.
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  ;; page 0: one iovec at 0, nwritten at 8; page 1 (65536..131071): the chunk
  (memory (export "memory") 2)

  (func (export "_start")
    (local $err i32)
    (i32.store (i32.const 0) (i32.const 65536))   ;; iovec.buf = page 1
    (i32.store (i32.const 4) (i32.const 65536))   ;; iovec.len = one page
    (loop $again
      (local.set $err (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
      (br_if $again (i32.eqz (local.get $err))))
    (call $proc_exit (local.get $err))))
