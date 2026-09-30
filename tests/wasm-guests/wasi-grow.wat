(module
  ;; grow: memory.grow(1) until it answers -1, then print memory.size as a
  ;; decimal ASCII line on stdout; exit 0 by returning from _start
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; layout: one iovec at 0; nwritten at 8; digits built backwards ending at 63

  (func (export "_start")
    (local $n i32)     ;; pages reached, then the remaining quotient
    (local $p i32)     ;; start of the digit string
    (loop $grow
      (br_if $grow (i32.ne (memory.grow (i32.const 1)) (i32.const -1))))
    (local.set $n (memory.size))
    ;; newline at 63, then digits from 62 downwards
    (i32.store8 (i32.const 63) (i32.const 10))
    (local.set $p (i32.const 63))
    (loop $digit
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p)
        (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10))))
      (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
      (br_if $digit (local.get $n)))
    ;; fd_write(1, iovs=0, 1, &nwritten=8) with iovec = (p, 64 - p)
    (i32.store (i32.const 0) (local.get $p))
    (i32.store (i32.const 4) (i32.sub (i32.const 64) (local.get $p)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))
