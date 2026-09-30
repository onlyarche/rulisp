(module
  ;; start-spins: a (start) section that never returns — it runs at
  ;; instantiation, i.e. inside make-wasi, under the fuel set before it
  (memory (export "memory") 1)
  (func $spin (loop $l (br $l)))
  (start $spin)
  (func (export "_start")))
