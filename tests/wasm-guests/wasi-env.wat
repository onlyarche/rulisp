(module
  ;; env: dump the environ buffer (NUL-separated KEY=VALUE entries) to stdout
  ;; verbatim; exit 0 by returning from _start
  (import "wasi_snapshot_preview1" "environ_sizes_get"
    (func $environ_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "environ_get"
    (func $environ_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; layout: one iovec at 0; nwritten at 8; environ count at 16; environ_buf
  ;;         size at 20; environ pointer array at 1024 (room for 768 entries);
  ;;         environ_buf at 4096 (room for 61440 bytes)

  (func (export "_start")
    (drop (call $environ_sizes_get (i32.const 16) (i32.const 20)))
    (drop (call $environ_get (i32.const 1024) (i32.const 4096)))
    ;; fd_write(1, iovs=0, 1, &nwritten=8) with iovec = (environ_buf, its size)
    (i32.store (i32.const 0) (i32.const 4096))
    (i32.store (i32.const 4) (i32.load (i32.const 20)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))
