(module
  ;; a hand-written WASI preview1 "command": no toolchain needed to build it
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get"
    (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "hello from wasi\n")   ;; 16 bytes
  (data (i32.const 32) "secret.txt")         ;; 10 bytes
  (data (i32.const 48) "../outside.txt")     ;; 14 bytes

  ;; write LEN bytes at PTR to FD (one iovec at address 0; nwritten at 100)
  (func $write (param $fd i32) (param $ptr i32) (param $len i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (local.get $len))
    (drop (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 100))))

  ;; open PATH under preopen fd 3 read-only; result errno; opened fd at 120
  (func $open (param $path i32) (param $len i32) (result i32)
    (call $path_open
      (i32.const 3) (i32.const 0)                 ;; dirfd, dirflags
      (local.get $path) (local.get $len)
      (i32.const 0)                               ;; oflags
      (i64.const 2) (i64.const 0)                 ;; rights: FD_READ; inheriting
      (i32.const 0)                               ;; fdflags
      (i32.const 120)))                           ;; *opened_fd

  (func (export "_start")
    (local $err i32)
    ;; 1. stdout
    (call $write (i32.const 1) (i32.const 8) (i32.const 16))
    ;; 2. args: argv_buf is NUL-separated; echo it to stdout verbatim
    (drop (call $args_sizes_get (i32.const 104) (i32.const 108)))
    (drop (call $args_get (i32.const 200) (i32.const 400)))
    (call $write (i32.const 1) (i32.const 400) (i32.load (i32.const 108)))
    ;; 3. read secret.txt from the preopened dir, echo to stdout
    (if (i32.eqz (call $open (i32.const 32) (i32.const 10)))
      (then
        (i32.store (i32.const 0) (i32.const 600))
        (i32.store (i32.const 4) (i32.const 64))
        (drop (call $fd_read (i32.load (i32.const 120)) (i32.const 0) (i32.const 1) (i32.const 124)))
        (call $write (i32.const 1) (i32.const 600) (i32.load (i32.const 124)))))
    ;; 4. try to escape the sandbox; the errno goes to stderr as one byte
    (local.set $err (call $open (i32.const 48) (i32.const 14)))
    (i32.store8 (i32.const 700) (local.get $err))
    (call $write (i32.const 2) (i32.const 700) (i32.const 1))
    ;; 5. exit code
    (call $proc_exit (i32.const 7))))
