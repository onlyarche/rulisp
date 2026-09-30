(module
  ;; subdir: open "sub" as a directory, then "../secret.txt" relative to IT;
  ;; exit with the errno of the second open (100 + errno if the first
  ;; failed). An opened directory is its own root: `..` does not climb back
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 32) "sub")                 ;; 3 bytes
  (data (i32.const 48) "../secret.txt")       ;; 13 bytes
  (func $open (param $dir i32) (param $path i32) (param $len i32) (param $oflags i32) (result i32)
    (call $path_open (local.get $dir) (i32.const 1) (local.get $path) (local.get $len)
                     (local.get $oflags) (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 120)))
  (func (export "_start")
    (local $err i32)
    (local.set $err (call $open (i32.const 3) (i32.const 32) (i32.const 3) (i32.const 2)))  ;; O_DIRECTORY
    (if (local.get $err) (then (call $proc_exit (i32.add (i32.const 100) (local.get $err)))))
    (call $proc_exit
      (call $open (i32.load (i32.const 120)) (i32.const 48) (i32.const 13) (i32.const 0)))))
