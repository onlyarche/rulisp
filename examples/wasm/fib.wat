(module
  ;; i32 addition — exercises argument coercion (Lisp i64 -> wasm i32)
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)

  ;; naive recursive fibonacci over i64
  (func $fib (export "fib") (param i64) (result i64)
    (if (result i64) (i64.lt_s (local.get 0) (i64.const 2))
      (then (local.get 0))
      (else
        (i64.add
          (call $fib (i64.sub (local.get 0) (i64.const 1)))
          (call $fib (i64.sub (local.get 0) (i64.const 2)))))))

  ;; deliberate trap — surfaces as a WASM:WASM-ERROR condition in Lisp
  (func (export "boom")
    unreachable))
