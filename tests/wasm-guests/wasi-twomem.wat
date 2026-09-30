(module
  ;; twomem: two linear memories (wasmi enables multi-memory by default;
  ;; the memory number is per memory, so the sandbox allows one) — refused
  ;; at instantiation with "too many linear memories"
  (memory (export "memory") 1)
  (memory 1)
  (func (export "_start")))
