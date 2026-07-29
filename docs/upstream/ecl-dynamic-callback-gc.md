# ECL bug: `si:make-dynamic-callback` metadata is not GC-protected

Status: apparently unreported upstream as of 2026-07 (checked the ECL
GitLab tracker; issue #53 is a different, Windows/compiled-code problem).
Found while diagnosing rulisp's callback segfaults on ECL; verified on
ECL 21.2.1 and by source inspection identical in 24.5.10.

## Symptom

Any bytecodes-compiled `ffi:defcallback` / `cffi:defcallback` (i.e. every
`defcallback` that goes through `eval`/`load` rather than `compile-file`)
works right after definition, then — after enough GC activity — invoking
it from C returns garbage or segfaults.

Minimal reproduction: define a callback taking `(:uint64, :pointer,
:unsigned-long)`, call it from a 5-line C shim → correct. Run `(si:gc t)`
plus ~300k conses, call again → hard SIGSEGV, every time.

## Root cause (src/c/ffi.d, `si_make_dynamic_callback`)

```c
cl_object data = cl_list(5,
                         fun, return_type, arg_types, cc_type,
                         ecl_make_foreign_data(..., cif),
                         ecl_make_foreign_data(..., types));  /* 6 args, count 5! */
int status = ffi_prep_closure_loc(closure, cif, callback_executor,
                                  data, executable_region);
...
si_put_sysprop(sym, @':callback', closure_object);
```

1. `data` — the list holding the Lisp closure, the return type, the arg
   types and the `ffi_cif` wrapper — is stored ONLY as the libffi
   closure's userdata, inside `ffi_closure_alloc`'d memory that the Boehm
   GC does not scan. The `:callback` sysprop retains only
   `closure_object`. Once no scanned stack/register happens to point at
   `data`, a full GC collects it (and the cif); the next invocation makes
   `callback_executor` walk recycled memory.
2. Bonus: `cl_list(5, …)` is passed six objects — the `types` foreign-data
   wrapper is silently dropped from the list (harmless today only by
   accident of it also being reachable through `cif`... which is itself
   collectable, see 1).

SBCL and CCL are unaffected (their defcallback implementations retain
callback metadata in GC-visible storage). ECL's native compiler is also
unaffected — `c1-defcallback`/`t3-defcallback` emit a static C function,
no libffi.

## Suggested fix

Retain `data` (and thereby the cif/types wrappers) in GC-visible storage
for the lifetime of the callback — e.g. store `CONS(closure_object, data)`
in the `:callback` sysprop — and fix the `cl_list` arity slip.

## Workaround (what rulisp does)

On ECL, write the `defcallback` form to a temporary file, `compile-file`
it (native C backend) and `load` the fasl instead of `eval`ing it — see
`%define-callback-trampoline` in `lisp/src/codegen.lisp`. Requires a C
toolchain at runtime; failures signal a clear load-time error instead of
a delayed segfault.
