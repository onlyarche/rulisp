(module
  ;; cat: copy stdin (fd 0) to stdout (fd 1) until EOF, 4096 bytes at a time;
  ;; exit 0 by returning from _start (no proc_exit)
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; layout: one iovec at 0 (buf ptr at 0, len at 4); nread/nwritten at 8;
  ;;         4096-byte buffer at 4096

  (func (export "_start")
    (local $n i32)     ;; bytes still to write from this read
    (local $p i32)     ;; where they start
    (block $done
      (loop $read
        ;; fd_read(0, iovs=0, 1, &nread=8) into the whole buffer
        (i32.store (i32.const 0) (i32.const 4096))
        (i32.store (i32.const 4) (i32.const 4096))
        (br_if $done (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))
        (local.set $n (i32.load (i32.const 8)))
        (br_if $done (i32.eqz (local.get $n)))          ;; nread == 0: EOF
        ;; fd_write(1, ...) the n bytes; tolerate short writes
        (local.set $p (i32.const 4096))
        (loop $write
          (i32.store (i32.const 0) (local.get $p))
          (i32.store (i32.const 4) (local.get $n))
          (br_if $done (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
          (local.set $p (i32.add (local.get $p) (i32.load (i32.const 8))))
          (local.set $n (i32.sub (local.get $n) (i32.load (i32.const 8))))
          (br_if $write (local.get $n)))
        (br $read)))))
