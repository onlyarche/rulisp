(module
  ;; random: random_get of 1 MiB, again and again. A WASI call costs the few
  ;; fuel of its call instruction whatever the host does for it: 100,000 fuel
  ;; of this ran 103 seconds before host calls had a time budget of their own
  (import "wasi_snapshot_preview1" "random_get"
    (func $random_get (param i32 i32) (result i32)))
  (memory (export "memory") 17)
  (func (export "_start")
    (loop $again
      (drop (call $random_get (i32.const 65536) (i32.const 1048576)))
      (br $again))))
