(module
  ;; stat: path_filestat_get("../outside.txt") — the exit code is its errno —
  ;; and path_readlink("escape-file"), whose answer (the link's TEXT, never
  ;; the file it points at) goes to stdout
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (import "wasi_snapshot_preview1" "path_filestat_get"
    (func $path_filestat_get (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_readlink"
    (func $path_readlink (param i32 i32 i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 32) "../outside.txt")      ;; 14 bytes
  (data (i32.const 64) "escape-file")         ;; 11 bytes
  (func (export "_start")
    (local $err i32)
    (local.set $err
      (call $path_filestat_get (i32.const 3) (i32.const 1) (i32.const 32) (i32.const 14) (i32.const 200)))
    (drop (call $path_readlink (i32.const 3) (i32.const 64) (i32.const 11)
                               (i32.const 400) (i32.const 100) (i32.const 300)))
    (i32.store (i32.const 0) (i32.const 400)) (i32.store (i32.const 4) (i32.load (i32.const 300)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16)))
    (call $proc_exit (local.get $err))))
