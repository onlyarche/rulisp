(module
  ;; recurse: unbounded recursion — wasmi keeps guest frames on the heap and
  ;; stops at its depth limit with a trap; the host stack is never at risk
  (memory (export "memory") 1)
  (func $r (result i32) (i32.add (call $r) (i32.const 1)))
  (func (export "_start") (drop (call $r))))
