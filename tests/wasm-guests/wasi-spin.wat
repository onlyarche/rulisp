(module
  ;; spin: _start never returns; only the fuel budget can end this run
  (memory (export "memory") 1)
  (func (export "_start")
    (loop $spin (br $spin))))
