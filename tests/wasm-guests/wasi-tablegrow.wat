(module
  ;; tablegrow: table.grow by 65536 entries until it answers -1, then exit
  ;; with table.size / 65536 — the table is bounded by memory_limit / 8
  ;; entries, so 1 under 1 MiB (131,072 entries) and 3 under 2 MiB
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (table $t 1 funcref)
  (func (export "_start")
    (loop $grow
      (br_if $grow (i32.ne (table.grow $t (ref.null func) (i32.const 65536)) (i32.const -1))))
    (call $proc_exit (i32.div_u (table.size $t) (i32.const 65536)))))
