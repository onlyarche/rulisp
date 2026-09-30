(module
  ;; fdflood: path_open secret.txt again and again, never closing, until
  ;; path_open answers an errno; print the number of descriptors obtained
  ;; as a decimal line on stdout and exit with that errno
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 32) "secret.txt")          ;; 10 bytes
  ;; layout: one iovec at 0; nwritten at 8; opened fd at 120; digits end at 63

  (func (export "_start")
    (local $n i32)     ;; descriptors obtained, then the remaining quotient
    (local $err i32)
    (local $p i32)
    (loop $again
      (local.set $err
        (call $path_open
          (i32.const 3) (i32.const 1)             ;; dirfd, dirflags
          (i32.const 32) (i32.const 10)           ;; path, path_len
          (i32.const 0)                           ;; oflags
          (i64.const 2) (i64.const 0)             ;; rights: FD_READ
          (i32.const 0)                           ;; fdflags
          (i32.const 120)))
      (if (i32.eqz (local.get $err))
        (then (local.set $n (i32.add (local.get $n) (i32.const 1)))
              (br $again))))
    ;; print n
    (i32.store8 (i32.const 63) (i32.const 10))
    (local.set $p (i32.const 63))
    (loop $digit
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p)
        (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10))))
      (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
      (br_if $digit (local.get $n)))
    (i32.store (i32.const 0) (local.get $p))
    (i32.store (i32.const 4) (i32.sub (i32.const 64) (local.get $p)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
    (call $proc_exit (local.get $err))))
