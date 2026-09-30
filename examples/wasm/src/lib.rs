//! A WebAssembly runtime for Common Lisp, in a few hundred lines of glue.
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
    ///
    /// For modules you trust: an unmetered instance can run forever and
    /// nothing here bounds memory. For code you do not trust, make-wasi is
    /// the sandbox.
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
//   host time     fuel meters instructions, not what the host does for
//                 a WASI call: random_get of 1 MiB again and again ran
//                 103 s on 100,000 fuel (measured; 1e9 would be days).
//                 So the wall-clock time spent inside host calls has a
//                 budget of its own, derived from the fuel — one second
//                 plus a microsecond per unit — and the run traps past it.
//   preopens      read-only, regular files and directories only (a FIFO
//                 or a device would block for as long as the host likes),
//                 and the descriptors opened through them counted (256 at
//                 once): a guest cannot write the host's disk — 5,000
//                 fuel wrote 8 MiB before — nor hold the image's file
//                 descriptors; they are released when the run ends, not
//                 when the handle is freed.
// What it does not bound is stated on `Wasi::load`.
// ---------------------------------------------------------------------------

use std::any::Any;
use std::future::Future;
use std::io::{IoSlice, IoSliceMut, SeekFrom};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, MutexGuard, TryLockError};
use std::time::{Duration, Instant};

use wasmi::{CallHook, CompilationMode, StoreLimits, StoreLimitsBuilder};
use wasmi_wasi::wasi_common::dir::{OpenResult, ReaddirCursor, ReaddirEntity, WasiDir};
use wasmi_wasi::wasi_common::file::{Advice, FdFlags, FileType, Filestat, OFlags};
use wasmi_wasi::wasi_common::pipe::ReadPipe;
use wasmi_wasi::wasi_common::sched::{Poll, WasiSched};
use wasmi_wasi::wasi_common::snapshots::preview_1::error::Errno;
use wasmi_wasi::wasi_common::sync::clocks_ctx;
use wasmi_wasi::wasi_common::{Error as WasiError, ErrorExt, SystemTimeSpec, Table};
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

/// Descriptors a guest may hold open at once, all preopens together.
const OPEN_DESCRIPTORS: usize = 256;

/// The count of descriptors the guest holds, shared by every preopen.
struct Live(AtomicUsize);

impl Live {
    fn new() -> Arc<Live> {
        Arc::new(Live(AtomicUsize::new(0)))
    }
}

/// One held descriptor; dropping it — fd_close, or the end of the run —
/// gives the slot back.
struct Slot(Arc<Live>);

impl Slot {
    fn take(live: &Arc<Live>) -> Result<Slot, WasiError> {
        if live.0.fetch_add(1, Ordering::AcqRel) >= OPEN_DESCRIPTORS {
            live.0.fetch_sub(1, Ordering::AcqRel);
            return Err(WasiError::from(Errno::Mfile));
        }
        Ok(Slot(live.clone()))
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.0 .0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// A preopened directory as the guest sees it: read-only — every way of
/// changing it answers EROFS — and every descriptor opened through it
/// counted against OPEN_DESCRIPTORS (EMFILE beyond).
struct ReadOnlyDir {
    inner: Box<dyn WasiDir>,
    live: Arc<Live>,
    _slot: Option<Slot>,
}

impl ReadOnlyDir {
    fn preopen(dir: cap_std::fs::Dir, live: Arc<Live>) -> ReadOnlyDir {
        ReadOnlyDir {
            inner: Box::new(wasmi_wasi::wasi_common::sync::dir::Dir::from_cap_std(dir)),
            live,
            _slot: None,
        }
    }
}

fn read_only<'t, T: Send + 't>() -> Ready<'t, Result<T, WasiError>> {
    Box::pin(std::future::ready(Err(WasiError::from(Errno::Rofs))))
}

impl WasiDir for ReadOnlyDir {
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn open_file<'l0, 'l1, 't>(
        &'l0 self,
        symlink_follow: bool,
        path: &'l1 str,
        oflags: OFlags,
        read: bool,
        write: bool,
        fdflags: FdFlags,
    ) -> Ready<'t, Result<OpenResult, WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(async move {
            if write || oflags.intersects(OFlags::CREATE | OFlags::TRUNCATE | OFlags::EXCLUSIVE) {
                return Err(WasiError::from(Errno::Rofs));
            }
            // regular files and directories only: opening a FIFO, or
            // reading a device, blocks for as long as the host likes (a
            // symlink left unfollowed goes on to the open, which says ELOOP)
            let kind = self.inner.get_path_filestat(path, symlink_follow).await?.filetype;
            if !matches!(kind, FileType::RegularFile | FileType::Directory | FileType::SymbolicLink) {
                return Err(WasiError::from(Errno::Acces));
            }
            let slot = Slot::take(&self.live)?;
            Ok(match self.inner.open_file(symlink_follow, path, oflags, read, false, fdflags).await? {
                OpenResult::File(file) => OpenResult::File(Box::new(CountedFile { inner: file, _slot: slot })),
                OpenResult::Dir(dir) => OpenResult::Dir(Box::new(ReadOnlyDir {
                    inner: dir,
                    live: self.live.clone(),
                    _slot: Some(slot),
                })),
            })
        })
    }
    fn readdir<'l0, 't>(
        &'l0 self,
        cursor: ReaddirCursor,
    ) -> Ready<'t, Result<Box<dyn Iterator<Item = Result<ReaddirEntity, WasiError>> + Send>, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.readdir(cursor).await })
    }
    fn read_link<'l0, 'l1, 't>(&'l0 self, path: &'l1 str) -> Ready<'t, Result<PathBuf, WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.read_link(path).await })
    }
    fn get_filestat<'l0, 't>(&'l0 self) -> Ready<'t, Result<Filestat, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.get_filestat().await })
    }
    fn get_path_filestat<'l0, 'l1, 't>(
        &'l0 self,
        path: &'l1 str,
        follow_symlinks: bool,
    ) -> Ready<'t, Result<Filestat, WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.get_path_filestat(path, follow_symlinks).await })
    }
    // everything that would change the directory: EROFS
    fn create_dir<'l0, 'l1, 't>(&'l0 self, _path: &'l1 str) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        read_only()
    }
    fn symlink<'l0, 'l1, 'l2, 't>(&'l0 self, _old: &'l1 str, _new: &'l2 str) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        'l2: 't,
        Self: 't,
    {
        read_only()
    }
    fn remove_dir<'l0, 'l1, 't>(&'l0 self, _path: &'l1 str) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        read_only()
    }
    fn unlink_file<'l0, 'l1, 't>(&'l0 self, _path: &'l1 str) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        read_only()
    }
    fn rename<'l0, 'l1, 'l2, 'l3, 't>(
        &'l0 self,
        _path: &'l1 str,
        _dest_dir: &'l2 dyn WasiDir,
        _dest_path: &'l3 str,
    ) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        'l2: 't,
        'l3: 't,
        Self: 't,
    {
        read_only()
    }
    fn hard_link<'l0, 'l1, 'l2, 'l3, 't>(
        &'l0 self,
        _path: &'l1 str,
        _target_dir: &'l2 dyn WasiDir,
        _target_path: &'l3 str,
    ) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        'l2: 't,
        'l3: 't,
        Self: 't,
    {
        read_only()
    }
    fn set_times<'l0, 'l1, 't>(
        &'l0 self,
        _path: &'l1 str,
        _atime: Option<SystemTimeSpec>,
        _mtime: Option<SystemTimeSpec>,
        _follow_symlinks: bool,
    ) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        read_only()
    }
}

/// A file the guest opened: read side delegated, write side left to the
/// trait's defaults (EBADF — it was opened read-only anyway), and one
/// counted slot held until it is closed.
struct CountedFile {
    inner: Box<dyn WasiFile>,
    _slot: Slot,
}

impl WasiFile for CountedFile {
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn isatty(&self) -> bool {
        self.inner.isatty()
    }
    fn num_ready_bytes(&self) -> Result<u64, WasiError> {
        self.inner.num_ready_bytes()
    }
    fn get_filetype<'l0, 't>(&'l0 self) -> Ready<'t, Result<FileType, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.get_filetype().await })
    }
    fn get_fdflags<'l0, 't>(&'l0 self) -> Ready<'t, Result<FdFlags, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.get_fdflags().await })
    }
    fn set_fdflags<'l0, 't>(&'l0 mut self, flags: FdFlags) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.set_fdflags(flags).await })
    }
    fn get_filestat<'l0, 't>(&'l0 self) -> Ready<'t, Result<Filestat, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.get_filestat().await })
    }
    fn advise<'l0, 't>(&'l0 self, offset: u64, len: u64, advice: Advice) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.advise(offset, len, advice).await })
    }
    fn read_vectored<'a, 'l0, 'l1, 't>(
        &'l0 self,
        bufs: &'l1 mut [IoSliceMut<'a>],
    ) -> Ready<'t, Result<u64, WasiError>>
    where
        'a: 't,
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.read_vectored(bufs).await })
    }
    fn read_vectored_at<'a, 'l0, 'l1, 't>(
        &'l0 self,
        bufs: &'l1 mut [IoSliceMut<'a>],
        offset: u64,
    ) -> Ready<'t, Result<u64, WasiError>>
    where
        'a: 't,
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.read_vectored_at(bufs, offset).await })
    }
    fn seek<'l0, 't>(&'l0 self, pos: SeekFrom) -> Ready<'t, Result<u64, WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.seek(pos).await })
    }
    fn peek<'l0, 'l1, 't>(&'l0 self, buf: &'l1 mut [u8]) -> Ready<'t, Result<u64, WasiError>>
    where
        'l0: 't,
        'l1: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.peek(buf).await })
    }
    fn readable<'l0, 't>(&'l0 self) -> Ready<'t, Result<(), WasiError>>
    where
        'l0: 't,
        Self: 't,
    {
        Box::pin(async move { self.inner.readable().await })
    }
}

/// Per-instance host state of a sandboxed run.
struct WasiHost {
    wasi: WasiCtx,
    limits: StoreLimits,
    captured: Arc<Mutex<Captured>>,
    /// descriptors the guest holds through its preopens
    live: Arc<Live>,
    host_time: HostTime,
}

/// The wall-clock time the guest has spent inside host calls, against its
/// budget: one second plus a microsecond per unit of fuel.
struct HostTime {
    budget: Duration,
    spent: Duration,
    entered: Option<Instant>,
}

impl HostTime {
    fn for_fuel(fuel: u64) -> HostTime {
        HostTime {
            budget: Duration::from_secs(1).saturating_add(Duration::from_micros(fuel)),
            spent: Duration::ZERO,
            entered: None,
        }
    }
}

struct WasiInner {
    store: Store<WasiHost>,
    instance: wasmi::Instance,
    /// `_start` runs once; after it the instance is spent, whatever happened.
    ran: bool,
    /// environment keys given so far (a key is set once)
    env_keys: Vec<String>,
}

/// The guest's WASI context: no arguments, no environment, no preopens,
/// stdin empty, the scheduler that never waits, entropy from the OS (the
/// crate's default RNG would register a fork handler in the process).
fn fresh_wasi() -> WasiCtx {
    WasiCtx::new(
        Box::new(cap_rand::rngs::OsRng::default(cap_rand::ambient_authority())),
        clocks_ctx(),
        Box::new(NoWait),
        Table::new(),
    )
}

/// A WASI command module in a sandbox: a fuel budget, one memory number,
/// stdio as bytes, the preopened directories as its whole filesystem.
#[rulisp::handle]
pub struct Wasi {
    inner: Mutex<WasiInner>,
}

#[rulisp::export]
impl Wasi {
    /// (wasm:make-wasi "/path/to/module.wasm" 10000000 16777216) — a WASI
    /// preview1 command module (what a wasm32-wasip1 toolchain produces,
    /// or .wat text), to be run once with wasi-run.
    ///
    /// FUEL bounds the run: every guest instruction consumes fuel and
    /// running out is a condition. The run is synchronous on the calling
    /// thread, so an unmetered sandbox is refused (FUEL must be positive).
    /// MEMORY-LIMIT, in bytes, bounds the guest's linear memory (a module
    /// asking for more is refused here — one built by Rust asks for 17
    /// pages, 1.1 MiB, before it runs; memory.grow past it answers -1),
    /// its table, and the bytes kept from stdout and stderr together (a
    /// write past the cap fails inside the guest with ENOSPC, on either
    /// stream: a guest that fills the cap on stdout has no room left to
    /// complain on stderr).
    ///
    /// The guest starts with no arguments, no environment, no directories,
    /// empty stdin, and stdout/stderr captured; nothing of the process is
    /// inherited. Its preopens are read-only, offer regular files and
    /// directories only (a FIFO, a device or a socket is EACCES), and it
    /// may hold 256 open descriptors at once (EMFILE beyond), all released
    /// when the run ends. It cannot wait: poll_oneoff and sleep answer
    /// ENOTSUP at once — C sees the errno and goes on, Rust's
    /// std::thread::sleep panics on it (the run ends in a trap), Go's
    /// runtime throws.
    ///
    /// How long a run can take: fuel meters instructions (tens of millions
    /// a second), and the time spent inside WASI calls — which fuel does
    /// not meter — has its own budget of one second plus a microsecond per
    /// unit of FUEL, past which the run ends in a trap. So a run takes at
    /// most about a second plus a microsecond per unit of fuel, plus the
    /// one host call in flight (which may touch MEMORY-LIMIT bytes, or
    /// list a directory as large as the host made it): size FUEL as the
    /// seconds you can wait times a million.
    ///
    /// What the numbers do not bound: resident host memory reaches about
    /// three times MEMORY-LIMIT (memory, table, captured output); the time
    /// to read and validate the module file, linear in its size and the
    /// caller's to choose; a filesystem that is itself slow; and, as for
    /// every crate, a bug in wasmi or in this glue — the sandbox is a
    /// budget for a guest, not isolation from the host. The guest sees the
    /// real clocks and real entropy.
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
        match module.get_export("_start").and_then(|ty| ty.func().cloned()) {
            Some(start) if start.params().is_empty() && start.results().is_empty() => {}
            Some(_) => {
                return Err(WasmError(
                    "module's _start is not a function of no parameters and no result: not a WASI command".into(),
                ))
            }
            None => {
                return Err(WasmError(
                    "module exports no _start function: not a WASI command".into(),
                ))
            }
        }
        let captured = Arc::new(Mutex::new(Captured {
            stdout: Vec::new(),
            stderr: Vec::new(),
            cap: memory_limit,
        }));
        let wasi = fresh_wasi();
        wasi.set_stdout(Box::new(CappedStream { shared: captured.clone(), stream: Stream::Stdout }));
        wasi.set_stderr(Box::new(CappedStream { shared: captured.clone(), stream: Stream::Stderr }));
        let limits = StoreLimitsBuilder::new()
            .memory_size(memory_limit)
            .table_elements(memory_limit / 8)
            .memories(1)
            .tables(1)
            .instances(1)
            .build();
        let mut store = Store::new(
            &engine,
            WasiHost { wasi, limits, captured, live: Live::new(), host_time: HostTime::for_fuel(fuel) },
        );
        store.limiter(|h| &mut h.limits);
        store.call_hook(|h: &mut WasiHost, hook| {
            match hook {
                CallHook::CallingHost => h.host_time.entered = Some(Instant::now()),
                CallHook::ReturningFromHost => {
                    if let Some(entered) = h.host_time.entered.take() {
                        h.host_time.spent = h.host_time.spent.saturating_add(entered.elapsed());
                    }
                    if h.host_time.spent > h.host_time.budget {
                        return Err(wasmi::Error::new(
                            "host-call time budget exhausted: more than a second plus a microsecond per unit of fuel was spent inside WASI calls",
                        ));
                    }
                }
                _ => {}
            }
            Ok(())
        });
        store.set_fuel(fuel)?;
        let mut linker: Linker<WasiHost> = Linker::new(&engine);
        wasmi_wasi::add_to_linker(&mut linker, |h: &mut WasiHost| &mut h.wasi)
            .map_err(|e| WasmError(e.to_string()))?;
        // a (start) section runs here, under the fuel and the limits — and
        // with the still-empty context: a command's work belongs in _start
        let instance = linker.instantiate_and_start(&mut store, &module).map_err(|e| {
            match e.i32_exit_status() {
                Some(code) => WasmError(format!("the module's (start) section exited with status {code} before _start could run")),
                None => WasmError::from(e),
            }
        })?;
        Ok(Wasi {
            inner: Mutex::new(WasiInner { store, instance, ran: false, env_keys: Vec::new() }),
        })
    }

    /// Append one command-line argument (argv[0] included: pass the program
    /// name first if the guest expects one; no NUL bytes). Before wasi-run
    /// only.
    pub fn arg(&self, arg: &str) -> Result<(), WasmError> {
        let mut inner = self.lock("wasi-arg")?;
        inner.not_run_yet("wasi-arg")?;
        no_nul("wasi-arg", arg)?;
        inner.store.data_mut().wasi.push_arg(arg).map_err(|e| WasmError(e.to_string()))
    }

    /// Set one environment variable for the guest: KEY is set once (a
    /// second value for the same key is refused — the guest's libc would
    /// only ever see the first), non-empty, and free of `=` and NUL.
    /// Before wasi-run only.
    pub fn env(&self, key: &str, value: &str) -> Result<(), WasmError> {
        let mut inner = self.lock("wasi-env")?;
        inner.not_run_yet("wasi-env")?;
        no_nul("wasi-env", key)?;
        no_nul("wasi-env", value)?;
        if key.is_empty() || key.contains('=') {
            return Err(WasmError(format!("wasi-env: {key:?} is not a variable name")));
        }
        if inner.env_keys.iter().any(|k| k == key) {
            return Err(WasmError(format!("wasi-env: {key} is already set")));
        }
        inner.store.data_mut().wasi.push_env(key, value).map_err(|e| WasmError(e.to_string()))?;
        inner.env_keys.push(key.to_owned());
        Ok(())
    }

    /// Give the guest the host directory HOST-DIR as GUEST-PATH (the first
    /// preopen is fd 3, the next fd 4, ...), read-only: creating, writing,
    /// truncating, unlinking, renaming, linking and setting times inside
    /// it answer EROFS, and only regular files and directories open (a
    /// FIFO, a device or a socket is EACCES: it could block the run). The
    /// preopens are the guest's whole filesystem: a path that leads outside
    /// one — through `..`, an absolute path, a symlink to the outside, or
    /// an absolute symlink even when its target lies inside — fails with
    /// EPERM; a relative symlink that stays inside works. Before wasi-run
    /// only.
    pub fn preopen(&self, host_dir: &str, guest_path: &str) -> Result<(), WasmError> {
        let mut inner = self.lock("wasi-preopen")?;
        inner.not_run_yet("wasi-preopen")?;
        let dir = cap_std::fs::Dir::open_ambient_dir(host_dir, cap_std::ambient_authority())
            .map_err(|e| WasmError(format!("cannot open {host_dir}: {e}")))?;
        let host = inner.store.data_mut();
        let dir = ReadOnlyDir::preopen(dir, host.live.clone());
        host.wasi
            .push_preopened_dir(Box::new(dir), guest_path)
            .map_err(|e| WasmError(e.to_string()))
    }

    /// The bytes the guest reads from stdin (fd 0); EOF after them. Before
    /// wasi-run only; the last call wins.
    pub fn stdin(&self, data: &[u8]) -> Result<(), WasmError> {
        let mut inner = self.lock("wasi-stdin")?;
        inner.not_run_yet("wasi-stdin")?;
        inner.store.data_mut().wasi.set_stdin(Box::new(ReadPipe::from(data.to_vec())));
        Ok(())
    }

    /// Run `_start` once and return the exit code as a value: 0 when the
    /// guest returns, N when it calls proc_exit(N) (0..125 — larger codes
    /// are refused by WASI as a trap). A trap — out of fuel, unreachable,
    /// a memory fault — is a wasm:wasm-error, and so is a second run: the
    /// instance is spent either way. (A refused wait is not a trap: the
    /// guest gets ENOTSUP and decides.) Every descriptor the guest opened,
    /// and the preopens, are released when the run ends.
    pub fn run(&self) -> Result<i64, WasmError> {
        let mut inner = self.lock("wasi-run")?;
        inner.not_run_yet("wasi-run")?;
        inner.ran = true;
        let WasiInner { store, instance, .. } = &mut *inner;
        let outcome = instance
            .get_typed_func::<(), ()>(&*store, "_start")
            .map_err(WasmError::from)
            .and_then(|start| match start.call(&mut *store, ()) {
                Ok(()) => Ok(0),
                Err(e) => match e.i32_exit_status() {
                    Some(code) => Ok(i64::from(code)),
                    None => Err(e.into()),
                },
            });
        // the run is over either way: drop the guest's descriptor table
        // (its open files and the preopened directories) now, not when the
        // handle is freed — captured output lives elsewhere
        store.data_mut().wasi = fresh_wasi();
        outcome
    }

    /// What the guest wrote to stdout (at most MEMORY-LIMIT bytes together
    /// with stderr).
    pub fn stdout(&self) -> Result<Vec<u8>, WasmError> {
        Ok(self.lock("wasi-stdout")?.captured(Stream::Stdout))
    }

    /// What the guest wrote to stderr.
    pub fn stderr(&self) -> Result<Vec<u8>, WasmError> {
        Ok(self.lock("wasi-stderr")?.captured(Stream::Stderr))
    }

    /// Fuel not yet consumed.
    pub fn fuel_left(&self) -> Result<u64, WasmError> {
        self.lock("wasi-fuel-left")?.store.get_fuel().map_err(Into::into)
    }
}

fn no_nul(what: &str, s: &str) -> Result<(), WasmError> {
    if s.contains('\0') {
        Err(WasmError(format!("{what}: a NUL byte cannot be passed to the guest")))
    } else {
        Ok(())
    }
}

impl Wasi {
    /// The handle's state, unless another thread is inside a run on it —
    /// waiting there would make this thread uninterruptible for as long
    /// as that run lasts.
    fn lock(&self, what: &str) -> Result<MutexGuard<'_, WasiInner>, WasmError> {
        self.inner.try_lock().map_err(|e| match e {
            TryLockError::WouldBlock => {
                WasmError(format!("{what}: a run is in progress on another thread"))
            }
            TryLockError::Poisoned(_) => {
                WasmError(format!("{what}: this instance is poisoned by an earlier panic"))
            }
        })
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
