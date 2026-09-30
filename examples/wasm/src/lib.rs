//! A WebAssembly runtime for Common Lisp, in under 250 lines of glue.
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

use rulisp::StoredCallback;
use wasmi::{Caller, Config, Engine, Linker, Module, Store, Val};

/// Per-instance host state: the Lisp callback behind the guest-importable
/// `host.notify` function (a rulisp stored callback — Copy, any-thread).
type HostState = Option<StoredCallback<(i64,)>>;

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
    inner: Mutex<(Store<HostState>, wasmi::Instance)>,
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
        let mut store = Store::new(&engine, None);
        if fuel > 0 {
            store.set_fuel(fuel)?;
        }
        let mut linker: Linker<HostState> = Linker::new(&engine);
        // host.notify is always importable; without a Lisp callback set via
        // wasm-on-notify, calling it traps (a condition, never a crash)
        linker.func_wrap(
            "host",
            "notify",
            |caller: Caller<'_, HostState>, x: i64| -> Result<(), wasmi::Error> {
                match *caller.data() {
                    Some(cb) => cb.call((x,)).map_err(|_| {
                        wasmi::Error::new("lisp callback failed (see warnings)")
                    }),
                    None => Err(wasmi::Error::new(
                        "no host callback set (call wasm-on-notify first)",
                    )),
                }
            },
        )
        .map_err(|e| WasmError(e.to_string()))?;
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

    /// Route the guest-importable `host.notify(i64)` to a stored Lisp
    /// callback: wasm code calls straight into the REPL.
    pub fn on_notify(&self, f: StoredCallback<(i64,)>) {
        let (store, _) = &mut *self.inner.lock().unwrap();
        *store.data_mut() = Some(f);
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


// ---------------------------------------------------------------------------
// The WASI sandbox (v0.7): run a command module — anything compiled for
// wasm32-wasip1, or a hand-written .wat — with a CPU budget, one memory
// number, and nothing of the host it was not given.
//
// What bounds the run, and why each bound is there:
//   fuel          every guest instruction; the run is synchronous on the
//                 calling Lisp thread, which cannot be interrupted inside
//                 foreign code, so the budget is what makes it finite.
//                 A metered instance is therefore mandatory (fuel > 0).
//   memory_limit  the guest's linear memory (wasmi's resource limiter: a
//                 module asking for more is refused at load, memory.grow
//                 past it answers -1), its table (memory_limit / 8
//                 funcrefs, so a table cannot outgrow the memory), AND the
//                 total bytes captured on stdout + stderr: a guest that
//                 floods its output gets ENOSPC from fd_write, never a
//                 hang or a host allocation it did not pay for. Measured
//                 before the cap: 5 M fuel bought 101 GiB of output.
//   no waiting    WASI's poll_oneoff / sleep go to a scheduler; the stock
//                 one calls std::thread::sleep for a guest-chosen u64 of
//                 nanoseconds at zero fuel. Ours answers ENOTSUP at once.
// What it does not bound is stated on `Wasi::load`.
// ---------------------------------------------------------------------------

use std::future::Future;
use std::io::IoSlice;
use std::pin::Pin;
use std::sync::Arc;

use wasmi::{CompilationMode, StoreLimits, StoreLimitsBuilder};
use wasmi_wasi::wasi_common::file::{FdFlags, FileType};
use wasmi_wasi::wasi_common::pipe::ReadPipe;
use wasmi_wasi::wasi_common::sched::{Poll, WasiSched};
use wasmi_wasi::wasi_common::snapshots::preview_1::error::Errno;
use wasmi_wasi::wasi_common::sync::{clocks_ctx, random_ctx};
use wasmi_wasi::wasi_common::{Error as WasiError, ErrorExt, Table};
use wasmi_wasi::{WasiCtx, WasiFile};

/// What a WASI host function returns: wasmi_wasi drives these futures with
/// a one-shot executor, so every one below is ready on its first poll.
type Ready<'t, T> = Pin<Box<dyn Future<Output = T> + Send + 't>>;

/// A scheduler that never waits. `wasi_common::WasiSched` is declared with
/// `#[async_trait]`, which wasmi_wasi does not re-export; this is the form
/// that attribute expands to.
struct NoWait;

impl WasiSched for NoWait {
    fn poll_oneoff<'a, 'l0, 'l1, 't>(&'l0 self, _poll: &'l1 mut Poll<'a>) -> Ready<'t, Result<(), WasiError>>
    where
        'a: 't,
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(std::future::ready(Err(WasiError::not_supported()
            .context("poll_oneoff is refused: a sandboxed run cannot wait"))))
    }
    fn sched_yield<'l0, 't>(&'l0 self) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(std::future::ready(Ok(())))
    }
    fn sleep<'l0, 't>(&'l0 self, _duration: std::time::Duration) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(std::future::ready(Err(WasiError::not_supported()
            .context("sleep is refused: a sandboxed run cannot wait"))))
    }
}

/// stdout and stderr, captured under ONE byte budget.
struct Captured {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    cap: usize,
}

#[derive(Clone, Copy)]
enum Stream {
    Stdout,
    Stderr,
}

/// One of the two output streams as the guest's fd 1 or fd 2. A write
/// past the budget fails with ENOSPC — as a disk that is full would: the
/// bytes that fit are kept, the next non-empty write is refused. (An
/// `io::Error` from a plain `WritePipe` would not do: wasi-common turns
/// any kind it cannot map into a trap that ends the whole run.)
struct CappedStream {
    shared: Arc<Mutex<Captured>>,
    stream: Stream,
}

impl WasiFile for CappedStream {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
    fn get_filetype<'l0, 't>(&'l0 self) -> Ready<'t, Result<FileType, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(std::future::ready(Ok(FileType::Pipe)))
    }
    fn get_fdflags<'l0, 't>(&'l0 self) -> Ready<'t, Result<FdFlags, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(std::future::ready(Ok(FdFlags::APPEND)))
    }
    fn write_vectored<'a, 'l0, 'l1, 't>(
        &'l0 self,
        bufs: &'l1 [IoSlice<'a>],
    ) -> Ready<'t, Result<u64, WasiError>>
    where
        'a: 't,
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        let total: usize = bufs.iter().map(|b| b.len()).sum();
        let result = if total == 0 {
            Ok(0)
        } else {
            let mut c = self.shared.lock().unwrap_or_else(|p| p.into_inner());
            let room = c.cap.saturating_sub(c.stdout.len() + c.stderr.len());
            if room == 0 {
                Err(WasiError::from(Errno::Nospc))
            } else {
                let target = match self.stream {
                    Stream::Stdout => &mut c.stdout,
                    Stream::Stderr => &mut c.stderr,
                };
                let mut n = 0;
                for b in bufs {
                    let take = (room - n).min(b.len());
                    target.extend_from_slice(&b[..take]);
                    n += take;
                    if n == room {
                        break;
                    }
                }
                Ok(n as u64)
            }
        };
        Box::pin(std::future::ready(result))
    }
}

/// Per-instance host state of a sandboxed run.
struct WasiHost {
    wasi: WasiCtx,
    limits: StoreLimits,
    captured: Arc<Mutex<Captured>>,
}

struct WasiInner {
    store: Store<WasiHost>,
    instance: wasmi::Instance,
    /// `_start` runs once; after it the instance is spent, whatever happened.
    ran: bool,
}

/// A WASI command module in a sandbox: a fuel budget, one memory number,
/// stdio as bytes, the preopened directories as its whole filesystem.
#[rulisp::handle]
pub struct Wasi {
    inner: Mutex<WasiInner>,
}

#[rulisp::export]
impl Wasi {
    /// (wasm:make-wasi "/path/to/module.wasm" 1000000 1048576) — a WASI
    /// preview1 command module (anything built for wasm32-wasip1, or .wat
    /// text), to be run once with wasi-run.
    ///
    /// FUEL bounds the run: every guest instruction consumes fuel and
    /// running out is a condition. The run is synchronous on the calling
    /// thread, so an unmetered sandbox is refused (FUEL must be positive).
    /// MEMORY-LIMIT, in bytes, bounds the guest's linear memory (a module
    /// asking for more is refused here; memory.grow past it answers -1),
    /// its table, and the bytes kept from stdout and stderr together (a
    /// write past the cap fails inside the guest with ENOSPC).
    ///
    /// The guest starts with no arguments, no environment, no directories,
    /// empty stdin, and stdout/stderr captured; nothing of the process is
    /// inherited. It cannot wait: WASI's poll_oneoff and sleep answer
    /// ENOTSUP at once, so the run ends within its fuel.
    ///
    /// What the numbers do not bound: wall time is fuel times the work a
    /// host call does (a WASI call costs a few fuel but may touch up to
    /// MEMORY-LIMIT bytes — 1e9 fuel is tens of seconds of an
    /// uninterruptible thread); resident host memory reaches about three
    /// times MEMORY-LIMIT (memory, table, captured output); the time to
    /// read and validate the module file, linear in its size and the
    /// caller's to choose; what the host filesystem does inside a preopened
    /// directory (a FIFO blocks like a FIFO); and, as for every crate, a
    /// bug in wasmi or in this glue — the sandbox is a budget for a guest,
    /// not isolation from the host. The guest sees the real clocks and real
    /// entropy.
    #[rulisp(constructor)]
    pub fn load(path: &str, fuel: u64, memory_limit: u64) -> Result<Wasi, WasmError> {
        if fuel == 0 {
            return Err(WasmError(
                "fuel must be positive: a sandboxed run is synchronous and only its fuel budget makes it finite".into(),
            ));
        }
        let memory_limit = usize::try_from(memory_limit)
            .map_err(|_| WasmError("memory limit exceeds the address space".into()))?;
        let bytes = if path.ends_with(".wat") {
            wat::parse_file(path).map_err(|e| WasmError(e.to_string()))?
        } else {
            std::fs::read(path).map_err(|e| WasmError(e.to_string()))?
        };
        let mut config = Config::default();
        config.consume_fuel(true);
        // validate and translate everything now: a module that does not
        // validate is refused here, and no translation is charged to fuel
        config.compilation_mode(CompilationMode::Eager);
        let engine = Engine::new(&config);
        let module = Module::new(&engine, &bytes)?;
        if module.get_export("_start").map(|ty| ty.func().is_some()) != Some(true) {
            return Err(WasmError(
                "module exports no _start function: not a WASI command".into(),
            ));
        }
        let captured = Arc::new(Mutex::new(Captured {
            stdout: Vec::new(),
            stderr: Vec::new(),
            cap: memory_limit,
        }));
        let wasi = WasiCtx::new(random_ctx(), clocks_ctx(), Box::new(NoWait), Table::new());
        wasi.set_stdout(Box::new(CappedStream { shared: captured.clone(), stream: Stream::Stdout }));
        wasi.set_stderr(Box::new(CappedStream { shared: captured.clone(), stream: Stream::Stderr }));
        let limits = StoreLimitsBuilder::new()
            .memory_size(memory_limit)
            .table_elements(memory_limit / 8)
            .memories(1)
            .tables(1)
            .instances(1)
            .build();
        let mut store = Store::new(&engine, WasiHost { wasi, limits, captured });
        store.limiter(|h| &mut h.limits);
        store.set_fuel(fuel)?;
        let mut linker: Linker<WasiHost> = Linker::new(&engine);
        wasmi_wasi::add_to_linker(&mut linker, |h: &mut WasiHost| &mut h.wasi)
            .map_err(|e| WasmError(e.to_string()))?;
        // a (start) section runs here, under the fuel and the limits
        let instance = linker.instantiate_and_start(&mut store, &module)?;
        Ok(Wasi {
            inner: Mutex::new(WasiInner { store, instance, ran: false }),
        })
    }

    /// Append one command-line argument (argv[0] included: pass the program
    /// name first if the guest expects one). Before wasi-run only.
    pub fn arg(&self, arg: &str) -> Result<(), WasmError> {
        let mut inner = self.inner.lock().unwrap();
        inner.not_run_yet("wasi-arg")?;
        inner.store.data_mut().wasi.push_arg(arg).map_err(|e| WasmError(e.to_string()))
    }

    /// Set one environment variable for the guest. Before wasi-run only.
    pub fn env(&self, key: &str, value: &str) -> Result<(), WasmError> {
        let mut inner = self.inner.lock().unwrap();
        inner.not_run_yet("wasi-env")?;
        inner.store.data_mut().wasi.push_env(key, value).map_err(|e| WasmError(e.to_string()))
    }

    /// Give the guest the host directory HOST-DIR as GUEST-PATH (the first
    /// preopen is fd 3, the next fd 4, ...). The preopens are the guest's
    /// whole filesystem: a path that leads outside one — through `..`, an
    /// absolute path, or a symlink, even a symlink whose target lies inside
    /// — fails with EPERM. Before wasi-run only.
    pub fn preopen(&self, host_dir: &str, guest_path: &str) -> Result<(), WasmError> {
        let mut inner = self.inner.lock().unwrap();
        inner.not_run_yet("wasi-preopen")?;
        let dir = cap_std::fs::Dir::open_ambient_dir(host_dir, cap_std::ambient_authority())
            .map_err(|e| WasmError(format!("cannot open {host_dir}: {e}")))?;
        let dir = wasmi_wasi::wasi_common::sync::dir::Dir::from_cap_std(dir);
        inner
            .store
            .data_mut()
            .wasi
            .push_preopened_dir(Box::new(dir), guest_path)
            .map_err(|e| WasmError(e.to_string()))
    }

    /// The bytes the guest reads from stdin (fd 0); EOF after them. Before
    /// wasi-run only; the last call wins.
    pub fn stdin(&self, data: &[u8]) -> Result<(), WasmError> {
        let mut inner = self.inner.lock().unwrap();
        inner.not_run_yet("wasi-stdin")?;
        inner.store.data_mut().wasi.set_stdin(Box::new(ReadPipe::from(data.to_vec())));
        Ok(())
    }

    /// Run `_start` once and return the exit code as a value: 0 when the
    /// guest returns, N when it calls proc_exit(N) (0..125 — larger codes
    /// are refused by WASI as a trap). A trap — out of fuel, unreachable,
    /// a memory fault, a refused wait — is a wasm:wasm-error, and so is a
    /// second run: the instance is spent either way.
    pub fn run(&self) -> Result<i64, WasmError> {
        let mut inner = self.inner.lock().unwrap();
        inner.not_run_yet("wasi-run")?;
        inner.ran = true;
        let WasiInner { store, instance, .. } = &mut *inner;
        let start = instance.get_typed_func::<(), ()>(&*store, "_start")?;
        match start.call(&mut *store, ()) {
            Ok(()) => Ok(0),
            Err(e) => match e.i32_exit_status() {
                Some(code) => Ok(i64::from(code)),
                None => Err(e.into()),
            },
        }
    }

    /// What the guest wrote to stdout (at most MEMORY-LIMIT bytes together
    /// with stderr).
    pub fn stdout(&self) -> Vec<u8> {
        self.inner.lock().unwrap().captured(Stream::Stdout)
    }

    /// What the guest wrote to stderr.
    pub fn stderr(&self) -> Vec<u8> {
        self.inner.lock().unwrap().captured(Stream::Stderr)
    }

    /// Fuel not yet consumed.
    pub fn fuel_left(&self) -> Result<u64, WasmError> {
        self.inner.lock().unwrap().store.get_fuel().map_err(Into::into)
    }
}

impl WasiInner {
    fn not_run_yet(&self, what: &str) -> Result<(), WasmError> {
        if self.ran {
            Err(WasmError(format!(
                "{what}: this instance has already run; a Wasi runs _start once — make another"
            )))
        } else {
            Ok(())
        }
    }

    fn captured(&self, stream: Stream) -> Vec<u8> {
        let c = self.store.data().captured.lock().unwrap_or_else(|p| p.into_inner());
        match stream {
            Stream::Stdout => c.stdout.clone(),
            Stream::Stderr => c.stderr.clone(),
        }
    }
}

rulisp::module! {
    name: "wasm",
    handles: [Wasm, Wasi],
    fns: [
        Wasm::load, Wasm::exports, Wasm::call0, Wasm::call1, Wasm::call2,
        Wasm::on_notify,
        Wasm::memory_write, Wasm::memory_read,
        Wasm::refuel, Wasm::fuel_left,
        Wasi::load, Wasi::arg, Wasi::env, Wasi::preopen, Wasi::stdin,
        Wasi::run, Wasi::stdout, Wasi::stderr, Wasi::fuel_left,
    ],
}
