//! A WebAssembly runtime for Common Lisp, in ~120 lines of glue.
//!
//! Loads a `.wasm` (or `.wat` text) module and calls its exports from the
//! REPL. Runtime choice is deliberate: wasmi is a pure interpreter with NO
//! signal handlers, so it composes safely with SBCL's signal-driven GC —
//! wasmtime's signal-based traps would violate the dependency rule in
//! BOUNDARY.md §7. Wasm traps (unreachable, out-of-bounds, div-by-zero)
//! surface as `wasm:wasm-error` conditions; the image always survives.
//!
//! v1 scope: exports taking/returning i32/i64 (Lisp side speaks i64 and
//! values are coerced per the function's actual signature). Host functions
//! calling back into Lisp need stored callbacks — a v0.2 rulisp feature.

use std::sync::Mutex;

use wasmi::{Engine, Linker, Module, Store, Val};

#[derive(Debug)]
pub struct WasmError(String);

impl std::fmt::Display for WasmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for WasmError {}

impl From<wasmi::Error> for WasmError {
    fn from(e: wasmi::Error) -> Self {
        WasmError(e.to_string())
    }
}

#[rulisp::handle]
pub struct Wasm {
    inner: Mutex<(Store<()>, wasmi::Instance)>,
}

#[rulisp::export]
impl Wasm {
    /// (wasm:make-wasm "/path/to/module.wat") — .wat text or .wasm binary.
    #[rulisp(constructor)]
    pub fn load(path: &str) -> Result<Wasm, WasmError> {
        let bytes = if path.ends_with(".wat") {
            wat::parse_file(path).map_err(|e| WasmError(e.to_string()))?
        } else {
            std::fs::read(path).map_err(|e| WasmError(e.to_string()))?
        };
        let engine = Engine::default();
        let module = Module::new(&engine, &bytes)?;
        let mut store = Store::new(&engine, ());
        let linker: Linker<()> = Linker::new(&engine);
        let instance = linker.instantiate_and_start(&mut store, &module)?;
        Ok(Wasm {
            inner: Mutex::new((store, instance)),
        })
    }

    /// Comma-separated names of the module's exported functions.
    pub fn exports(&self) -> String {
        let (store, instance) = &*self.inner.lock().unwrap();
        instance
            .exports(store)
            .filter(|e| e.clone().into_func().is_some())
            .map(|e| e.name().to_string())
            .collect::<Vec<_>>()
            .join(",")
    }

    pub fn call0(&self, name: &str) -> Result<i64, WasmError> {
        self.call(name, &[])
    }

    pub fn call1(&self, name: &str, a: i64) -> Result<i64, WasmError> {
        self.call(name, &[a])
    }

    pub fn call2(&self, name: &str, a: i64, b: i64) -> Result<i64, WasmError> {
        self.call(name, &[a, b])
    }
}

impl Wasm {
    /// Look up an export, coerce i64 arguments to the function's actual
    /// parameter types (i32/i64), call, coerce the result back to i64.
    fn call(&self, name: &str, args: &[i64]) -> Result<i64, WasmError> {
        let (store, instance) = &mut *self.inner.lock().unwrap();
        let func = instance
            .get_func(&mut *store, name)
            .ok_or_else(|| WasmError(format!("no exported function {name:?}")))?;
        let ty = func.ty(&*store);
        let params: Vec<_> = ty.params().to_vec();
        if params.len() != args.len() {
            return Err(WasmError(format!(
                "{name:?} takes {} argument(s), got {}",
                params.len(),
                args.len()
            )));
        }
        let vals: Vec<Val> = params
            .iter()
            .zip(args)
            .map(|(p, &a)| match p {
                wasmi::core::ValType::I32 => Ok(Val::I32(a as i32)),
                wasmi::core::ValType::I64 => Ok(Val::I64(a)),
                other => Err(WasmError(format!(
                    "{name:?}: unsupported parameter type {other:?} (v1 speaks i32/i64)"
                ))),
            })
            .collect::<Result<_, _>>()?;
        let mut results = vec![Val::I64(0); ty.results().len()];
        func.call(&mut *store, &vals, &mut results)?;
        match results.first() {
            None => Ok(0),
            Some(Val::I32(v)) => Ok(*v as i64),
            Some(Val::I64(v)) => Ok(*v),
            Some(other) => Err(WasmError(format!(
                "{name:?}: unsupported result type {other:?} (v1 speaks i32/i64)"
            ))),
        }
    }
}

rulisp::module! {
    name: "wasm",
    handles: [Wasm],
    fns: [
        Wasm::load, Wasm::exports, Wasm::call0, Wasm::call1, Wasm::call2,
    ],
}
