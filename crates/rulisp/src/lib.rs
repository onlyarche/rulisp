//! User-facing crate for rulisp glue crates.
//!
//! Write plain Rust, annotate it with `#[rulisp::handle]` / `#[rulisp::export]`,
//! list the exports in `rulisp::module!`, build a cdylib — then load it from
//! Common Lisp with `(rulisp:use-crate #p"...")`.

pub use rulisp_macros::{export, handle, module};
pub use rulisp_runtime as runtime;

use std::marker::PhantomData;

pub mod prelude {
    pub use crate::{export, handle, module, Callback, Error, StoredCallback};
}

/// Generic string error for glue code that doesn't define its own error type.
/// Crosses the boundary as last-error type `"Error"`.
#[derive(Debug)]
pub struct Error(String);

impl Error {
    pub fn msg(m: impl Into<String>) -> Self {
        Error(m.into())
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

/// A Lisp callback signaled a condition; it is stashed on the CL side and
/// will be re-signaled there. Propagate with `?` — Rust destructors run
/// normally on the way out, and the shim reports `STATUS_CB_ERR`.
#[derive(Debug)]
pub struct CallbackError;

impl std::fmt::Display for CallbackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Lisp callback signaled a condition")
    }
}

impl std::error::Error for CallbackError {}

impl From<CallbackError> for Error {
    fn from(_: CallbackError) -> Self {
        Error::msg("Lisp callback signaled a condition")
    }
}

/// Implemented by `#[rulisp::handle]` types. Carries the names the macros
/// and the manifest agree on; also what makes `&T` parameters type-check as
/// handle parameters.
pub trait HandleType: Send + Sync + 'static {
    const RUST_NAME: &'static str;
    const LISP_NAME: &'static str;
}

/// Relates a callback's DECLARED argument tuple (the `A` in `Callback<A, ()>`,
/// whose reference lifetimes are the caller's and irrelevant) to the tuple
/// actually passed at a call site (which may borrow locals). Encodes the
/// arguments onto the C trampoline. v1 shapes only — extend by adding impls.
pub trait CbArgsFor<Decl> {
    /// # Safety
    /// `fnptr` must be the trampoline pointer matching this tuple's shape.
    unsafe fn invoke(fnptr: *const (), userdata: u64, args: Self) -> i32;
}

impl<'call, 'decl> CbArgsFor<(&'decl str,)> for (&'call str,) {
    unsafe fn invoke(fnptr: *const (), userdata: u64, args: Self) -> i32 {
        let f: unsafe extern "C" fn(u64, *const u8, usize) -> i32 =
            unsafe { std::mem::transmute(fnptr) };
        unsafe { f(userdata, args.0.as_ptr(), args.0.len()) }
    }
}

macro_rules! impl_cb_args_scalar {
    ($($t:ty),*) => {$(
        impl CbArgsFor<($t,)> for ($t,) {
            unsafe fn invoke(fnptr: *const (), userdata: u64, args: Self) -> i32 {
                let f: unsafe extern "C" fn(u64, $t) -> i32 =
                    unsafe { std::mem::transmute(fnptr) };
                unsafe { f(userdata, args.0) }
            }
        }
    )*};
}

impl_cb_args_scalar!(i8, i16, i32, i64, u16, u32, u64, f32, f64);

impl CbArgsFor<(bool,)> for (bool,) {
    unsafe fn invoke(fnptr: *const (), userdata: u64, args: Self) -> i32 {
        let f: unsafe extern "C" fn(u64, u8) -> i32 =
            unsafe { std::mem::transmute(fnptr) };
        unsafe { f(userdata, args.0 as u8) }
    }
}

impl CbArgsFor<(u8,)> for (u8,) {
    unsafe fn invoke(fnptr: *const (), userdata: u64, args: Self) -> i32 {
        let f: unsafe extern "C" fn(u64, u8) -> i32 =
            unsafe { std::mem::transmute(fnptr) };
        unsafe { f(userdata, args.0) }
    }
}

/// A borrowed Lisp callback (DESIGN.md §4.7): synchronous, same-thread,
/// valid only for the duration of the export call — `!Send`/`!Sync` via the
/// raw-pointer marker and pinned by the `'a` lifetime the shim supplies, so
/// storing or moving it to a thread is a compile error.
pub struct Callback<'a, A, R> {
    fnptr: *const (),
    userdata: u64,
    _marker: PhantomData<(*mut (), &'a (), fn(A) -> R)>,
}

/// A REGISTERED Lisp callback (v0.2): unlike [`Callback`], this one may be
/// stored, cloned and invoked later from any thread — it is two plain
/// numbers (the per-shape trampoline pointer and a registry id minted by
/// `rulisp:callback` on the Lisp side, carried in the ABI slot v1 reserved).
///
/// Lifetime contract: the Lisp `callback-token` keeps the closure
/// registered. Once the token is unregistered or garbage-collected,
/// invoking here fails SAFELY — `Err(CallbackError)` plus a Lisp-side
/// warning — never undefined behavior. Conditions signaled inside the
/// closure are warned and reported as `Err(CallbackError)`; they do not
/// unwind into Rust.
#[derive(Clone, Copy)]
pub struct StoredCallback<A, R = ()> {
    fnptr: usize,
    id: u64,
    _marker: PhantomData<fn(A) -> R>,
}

impl<A> StoredCallback<A, ()> {
    /// Used by generated shims only — the macro guarantees `fnptr` matches
    /// the declared shape `A`.
    #[doc(hidden)]
    pub unsafe fn from_raw(fnptr: usize, id: u64) -> Self {
        StoredCallback {
            fnptr,
            id,
            _marker: PhantomData,
        }
    }

    pub fn call<Args: CbArgsFor<A>>(&self, args: Args) -> Result<(), CallbackError> {
        let status =
            unsafe { CbArgsFor::invoke(self.fnptr as *const (), self.id, args) };
        if status == 0 {
            Ok(())
        } else {
            Err(CallbackError)
        }
    }
}

impl<'a, A> Callback<'a, A, ()> {
    /// Used by generated shims only — the macro guarantees `fnptr` matches
    /// the declared shape `A`. The frame pins `'a` to the shim invocation,
    /// so the callback cannot be given a caller-chosen lifetime.
    #[doc(hidden)]
    pub unsafe fn from_raw(
        _frame: &'a runtime::ShimFrame,
        fnptr: *const (),
        userdata: u64,
    ) -> Self {
        Callback {
            fnptr,
            userdata,
            _marker: PhantomData,
        }
    }

    /// Invoke the Lisp closure. `Err(CallbackError)` means the closure
    /// signaled: the condition is stashed on the CL side — propagate with
    /// `?` and let the shim turn it into `STATUS_CB_ERR`.
    pub fn call<Args: CbArgsFor<A>>(&self, args: Args) -> Result<(), CallbackError> {
        let status = unsafe { CbArgsFor::invoke(self.fnptr, self.userdata, args) };
        if status == 0 {
            Ok(())
        } else {
            runtime::set_callback_tunnel();
            Err(CallbackError)
        }
    }
}
