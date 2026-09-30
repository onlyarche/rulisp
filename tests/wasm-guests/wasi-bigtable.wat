(module
  ;; bigtable: asks for a 200,000-entry funcref table up front (1.6 MB of
  ;; host memory at 8 bytes an entry) with an empty _start — refused at
  ;; instantiation under a memory number below 1.6 MB, since the table is
  ;; bounded by memory_limit / 8 entries
  (memory (export "memory") 1)
  (table 200000 funcref)
  (func (export "_start")))
