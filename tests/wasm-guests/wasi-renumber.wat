(module
  ;; renumber: write "before\n" to stdout, open secret.txt, fd_renumber it
  ;; onto fd 1, write again; exit with the errno of that second write (100 +
  ;; errno if the renumber itself failed). A guest may replace its own
  ;; stdout; what was captured stays, and the file is read-only
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_renumber"
    (func $fd_renumber (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 32) "secret.txt")          ;; 10 bytes
  (data (i32.const 64) "before\n")            ;; 7 bytes
  (func (export "_start")
    (local $err i32)
    (i32.store (i32.const 0) (i32.const 64)) (i32.store (i32.const 4) (i32.const 7))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16)))
    (drop (call $path_open (i32.const 3) (i32.const 1) (i32.const 32) (i32.const 10)
                           (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 120)))
    (local.set $err (call $fd_renumber (i32.load (i32.const 120)) (i32.const 1)))
    (if (local.get $err) (then (call $proc_exit (i32.add (i32.const 100) (local.get $err)))))
    (call $proc_exit (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16)))))
