(module
  ;; write: try to create a file in the preopen (path_open with O_CREAT and
  ;; write rights), then to open the existing secret.txt for writing; exit
  ;; with the first errno — a read-only preopen answers EROFS (69) to both
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 32) "new.txt")             ;; 7 bytes
  (data (i32.const 48) "secret.txt")          ;; 10 bytes

  (func $open (param $path i32) (param $len i32) (param $oflags i32) (result i32)
    (call $path_open
      (i32.const 3) (i32.const 1)               ;; dirfd, dirflags
      (local.get $path) (local.get $len)
      (local.get $oflags)
      (i64.const 66) (i64.const 0)              ;; rights: FD_READ | FD_WRITE
      (i32.const 0)                             ;; fdflags
      (i32.const 120)))                         ;; *opened_fd

  (func (export "_start")
    (local $err i32)
    ;; 1. create new.txt (oflags CREAT = 1)
    (local.set $err (call $open (i32.const 32) (i32.const 7) (i32.const 1)))
    (if (local.get $err) (then (call $proc_exit (local.get $err))))
    ;; 2. open the existing file with write rights
    (local.set $err (call $open (i32.const 48) (i32.const 10) (i32.const 0)))
    (call $proc_exit (local.get $err))))
