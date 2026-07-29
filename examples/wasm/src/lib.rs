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
//!
//! Fuel metering: construct with a fuel budget and every wasm instruction
//! consumes fuel — runaway guest code traps with a condition instead of
//! hanging the image. A CPU bound no raw FFI call can ever offer.

use std::sync::Mutex;

use wasmi::{Config, Engine, Linker, Module, Store, Val};

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
    /// (wasm:make-wasm "/path/to/module.wat" 1000000) — .wat text or .wasm
    /// binary. FUEL > 0 enables metering with that budget: every guest
    /// instruction consumes fuel and running out traps (a condition, not a
    /// hang). FUEL = 0 runs unmetered.
    #[rulisp(constructor)]
    pub fn load(path: &str, fuel: u64) -> Result<Wasm, WasmError> {
        let bytes = if path.ends_with(".wat") {
            wat::parse_file(path).map_err(|e| WasmError(e.to_string()))?
        } else {
            std::fs::read(path).map_err(|e| WasmError(e.to_string()))?
        };
        let mut config = Config::default();
        config.consume_fuel(fuel > 0);
        let engine = Engine::new(&config);
        let module = Module::new(&engine, &bytes)?;
        let mut store = Store::new(&engine, ());
        if fuel > 0 {
            store.set_fuel(fuel)?;
        }
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

    /// Copy DATA into the guest's exported linear memory at OFFSET —
    /// :bytes in action: Lisp octets land in the sandbox, bounds-checked.
    pub fn memory_write(&self, offset: u64, data: &[u8]) -> Result<(), WasmError> {
        let (store, instance) = &mut *self.inner.lock().unwrap();
        let memory = instance
            .get_memory(&mut *store, "memory")
            .ok_or_else(|| WasmError("module exports no \"memory\"".into()))?;
        let mem = memory.data_mut(&mut *store);
        let mem_len = mem.len();
        let start = offset as usize;
        let end = start
            .checked_add(data.len())
            .filter(|&end| end <= mem_len)
            .ok_or_else(|| {
                WasmError(format!(
                    "write of {} byte(s) at offset {} exceeds memory size {}",
                    data.len(),
                    offset,
                    mem_len
                ))
            })?;
        mem[start..end].copy_from_slice(data);
        Ok(())
    }

    /// Copy LEN bytes out of the guest's linear memory at OFFSET.
    pub fn memory_read(&self, offset: u64, len: u64) -> Result<Vec<u8>, WasmError> {
        let (store, instance) = &mut *self.inner.lock().unwrap();
        let memory = instance
            .get_memory(&mut *store, "memory")
            .ok_or_else(|| WasmError("module exports no \"memory\"".into()))?;
        let mem = memory.data(&*store);
        let start = offset as usize;
        let src = start
            .checked_add(len as usize)
            .and_then(|end| mem.get(start..end))
            .ok_or_else(|| {
                WasmError(format!(
                    "read of {} byte(s) at offset {} exceeds memory size {}",
                    len,
                    offset,
                    mem.len()
                ))
            })?;
        Ok(src.to_vec())
    }

    /// Top up the fuel budget (metered instances only).
    pub fn refuel(&self, fuel: u64) -> Result<(), WasmError> {
        let (store, _) = &mut *self.inner.lock().unwrap();
        store.set_fuel(fuel).map_err(Into::into)
    }

    /// Remaining fuel; signals on an unmetered instance.
    pub fn fuel_left(&self) -> Result<u64, WasmError> {
        let (store, _) = &*self.inner.lock().unwrap();
        store.get_fuel().map_err(Into::into)
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
        Wasm::memory_write, Wasm::memory_read,
        Wasm::refuel, Wasm::fuel_left,
    ],
}
