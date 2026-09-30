(module
  ;; nomem: a WASI call from a module that does not export its memory — the
  ;; host function has nowhere to read its arguments from: a trap
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory 1)
  (func (export "_start")
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16)))))
