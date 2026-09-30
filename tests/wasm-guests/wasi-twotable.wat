(module
  ;; twotable: two tables (the table bound is per table, so the sandbox
  ;; allows one) — refused at instantiation with "too many tables"
  (memory (export "memory") 1)
  (table 10 funcref)
  (table 10 funcref)
  (func (export "_start")))
