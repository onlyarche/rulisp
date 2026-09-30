(module
  ;; readlink: open argv[1] under the preopen (dirfd 3) read-only, following
  ;; symlinks, and copy the file to stdout; a path_open error becomes the exit
  ;; code (nothing on stdout); success exits 0 by returning from _start
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get"
    (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  ;; layout: one iovec at 0; nread/nwritten at 8; argc at 16; argv_buf size
  ;;         at 20; opened fd at 24; argv pointer array at 32 (argv[1] at 36);
  ;;         argv_buf at 256 (room for 3840 bytes); 4096-byte file buffer at 4096

  (func (export "_start")
    (local $err i32)
    (local $path i32)  ;; argv[1]
    (local $len i32)   ;; its length (bytes before the NUL)
    (drop (call $args_sizes_get (i32.const 16) (i32.const 20)))
    (drop (call $args_get (i32.const 32) (i32.const 256)))
    (local.set $path (i32.load (i32.const 36)))
    (loop $strlen
      (if (i32.load8_u (i32.add (local.get $path) (local.get $len)))
        (then (local.set $len (i32.add (local.get $len) (i32.const 1)))
              (br $strlen))))
    (local.set $err
      (call $path_open
        (i32.const 3) (i32.const 1)                 ;; dirfd, dirflags: SYMLINK_FOLLOW
        (local.get $path) (local.get $len)
        (i32.const 0)                               ;; oflags
        (i64.const 2) (i64.const 0)                 ;; rights: FD_READ; inheriting
        (i32.const 0)                               ;; fdflags
        (i32.const 24)))                            ;; *opened_fd
    (if (local.get $err) (then (call $proc_exit (local.get $err))))
    ;; copy the file to stdout, 4096 bytes at a time
    (block $done
      (loop $again
        (i32.store (i32.const 0) (i32.const 4096))
        (i32.store (i32.const 4) (i32.const 4096))
        (br_if $done (call $fd_read (i32.load (i32.const 24)) (i32.const 0) (i32.const 1) (i32.const 8)))
        (br_if $done (i32.eqz (i32.load (i32.const 8))))   ;; EOF
        (i32.store (i32.const 4) (i32.load (i32.const 8)))
        (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
        (br $again)))))
