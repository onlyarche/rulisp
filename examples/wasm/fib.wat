(module
  ;; one page of linear memory, exported so the host can read/write it
  (memory (export "memory") 1)

  ;; i32 addition — exercises argument coercion (Lisp i64 -> wasm i32)
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)

  ;; sum N bytes starting at PTR in linear memory — the guest computing
  ;; over a buffer the host (Lisp) wrote there
  (func (export "sum_mem") (param $p i32) (param $n i32) (result i64)
    (local $i i32) (local $acc i64)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc
          (i64.add (local.get $acc)
                   (i64.extend_i32_u
                     (i32.load8_u (i32.add (local.get $p) (local.get $i))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $acc))

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
