(module
  ;; unknown-import: sock_connect is not a WASI preview1 function; a guest
  ;; importing something the sandbox does not provide is refused at load
  (import "wasi_snapshot_preview1" "sock_connect"
    (func $sock_connect (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")))
