(module
  ;; bigmem: asks for 100 pages (6.4 MiB) of linear memory up front, so
  ;; instantiation itself is refused under a 1 MiB limit; _start is empty
  (memory (export "memory") 100)
  (func (export "_start")))
