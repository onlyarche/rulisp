(module
  ;; fileops: what a reader does to a file, through the read-only wrapper —
  ;; fd_readdir on the preopen (exit 99 unless it lists something), then on
  ;; secret.txt: fd_filestat_get, fd_seek to 2, fd_read 2 bytes ("si"),
  ;; fd_pread 3 bytes at 0 ("ins"); stdout "siins", exit = the file's size
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_readdir"
    (func $fd_readdir (param i32 i32 i32 i64 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_filestat_get"
    (func $fd_filestat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_seek"
    (func $fd_seek (param i32 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_pread"
    (func $fd_pread (param i32 i32 i32 i64 i32) (result i32)))
  (memory (export "memory") 2)
  (data (i32.const 32) "secret.txt")          ;; 10 bytes
  (func $out (param $p i32) (param $n i32)
    (i32.store (i32.const 0) (local.get $p)) (i32.store (i32.const 4) (local.get $n))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16))))
  (func (export "_start")
    (local $fd i32)
    (if (i32.or (call $fd_readdir (i32.const 3) (i32.const 4096) (i32.const 4096) (i64.const 0) (i32.const 24))
                (i32.eqz (i32.load (i32.const 24))))
      (then (call $proc_exit (i32.const 99))))
    (if (call $path_open (i32.const 3) (i32.const 1) (i32.const 32) (i32.const 10)
                         (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 120))
      (then (call $proc_exit (i32.const 98))))
    (local.set $fd (i32.load (i32.const 120)))
    (if (call $fd_filestat_get (local.get $fd) (i32.const 200)) (then (call $proc_exit (i32.const 97))))
    (if (call $fd_seek (local.get $fd) (i64.const 2) (i32.const 0) (i32.const 280))
      (then (call $proc_exit (i32.const 96))))
    (i32.store (i32.const 0) (i32.const 300)) (i32.store (i32.const 4) (i32.const 2))
    (if (call $fd_read (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 16))
      (then (call $proc_exit (i32.const 95))))
    (call $out (i32.const 300) (i32.const 2))
    (i32.store (i32.const 0) (i32.const 320)) (i32.store (i32.const 4) (i32.const 3))
    (if (call $fd_pread (local.get $fd) (i32.const 0) (i32.const 1) (i64.const 0) (i32.const 16))
      (then (call $proc_exit (i32.const 94))))
    (call $out (i32.const 320) (i32.const 3))
    (call $proc_exit (i32.load (i32.const 232)))))   ;; filestat.size: u64 at +32
