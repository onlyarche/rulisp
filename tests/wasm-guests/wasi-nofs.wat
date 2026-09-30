(module
  ;; nofs: path_open "secret.txt" under dirfd 3 when nothing is preopened,
  ;; then proc_exit(errno) -- expected 8 (badf: fd 3 is not in the table)
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 32) "secret.txt")         ;; 10 bytes

  (func (export "_start")
    (call $proc_exit
      (call $path_open
        (i32.const 3) (i32.const 0)           ;; dirfd, dirflags
        (i32.const 32) (i32.const 10)         ;; path, path_len
        (i32.const 0)                         ;; oflags
        (i64.const 2) (i64.const 0)           ;; rights: FD_READ; inheriting
        (i32.const 0)                         ;; fdflags
        (i32.const 120)))))                   ;; *opened_fd
