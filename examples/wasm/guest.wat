(module
  ;; the guest IMPORTS a host function — which rulisp routes to a stored
  ;; Lisp callback: wasm code calling straight into your REPL
  (import "host" "notify" (func $notify (param i64)))

  ;; call notify(i*i) for i in 0..n
  (func (export "emit_squares") (param $n i64)
    (local $i i64)
    (block $done
      (loop $l
        (br_if $done (i64.ge_s (local.get $i) (local.get $n)))
        (call $notify (i64.mul (local.get $i) (local.get $i)))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $l)))))
