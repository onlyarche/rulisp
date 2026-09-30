(module
  ;; sleep: poll_oneoff with one relative monotonic-clock subscription of
  ;; 2 seconds, then proc_exit(errno of poll_oneoff)
  (import "wasi_snapshot_preview1" "poll_oneoff"
    (func $poll_oneoff (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  ;; subscription (48 bytes) at 0:
  ;;   userdata u64 @0; union tag u8 @8 (0 = clock); subscription_clock @16:
  ;;   id u32 @16 (1 = monotonic), timeout u64 @24, precision u64 @32,
  ;;   flags u16 @40 (0 = relative)
  ;; event (32 bytes) at 64; nevents at 96

  (func (export "_start")
    (i64.store   (i32.const 0)  (i64.const 42))            ;; userdata
    (i32.store8  (i32.const 8)  (i32.const 0))             ;; eventtype clock
    (i32.store   (i32.const 16) (i32.const 1))             ;; clockid monotonic
    (i64.store   (i32.const 24) (i64.const 2000000000))    ;; timeout: 2 s in ns
    (i64.store   (i32.const 32) (i64.const 0))             ;; precision
    (i32.store16 (i32.const 40) (i32.const 0))             ;; flags: relative
    (call $proc_exit
      (call $poll_oneoff (i32.const 0) (i32.const 64) (i32.const 1) (i32.const 96)))))
