//! rulisp-runtime: statically linked into every rulisp glue cdylib.
//!
//! Every symbol here is called *through* the crate's own `<crate>_rulisp_*`
//! exports, never resolved across libraries: each cdylib carries its own copy
//! of this runtime (own TLS slot, own allocator pairing). See BOUNDARY.md.

#![deny(unsafe_op_in_unsafe_fn)]

// catch_unwind is a no-op under panic=abort: the first panic would kill the
// host Lisp image. Refuse to compile instead of failing at runtime.
#[cfg(panic = "abort")]
compile_error!(
    "rulisp requires panic = \"unwind\" (the default). \
     With panic=abort, catch_unwind cannot intercept panics and the first \
     panic would abort the host Lisp image. Remove `panic = \"abort\"` from \
     your Cargo profile."
);

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicI64, Ordering};

mod meta;
pub use meta::{
    render_manifest, FnMeta, HandleMeta, ParamMeta, ParamTy, ResultTy, TARGET,
};

/// Bumped only on a wire-format break of the C ABI protocol (DESIGN.md §4).
pub const ABI_VERSION: u32 = 1;

pub const STATUS_OK: i32 = 0;
pub const STATUS_ERR: i32 = 1;
pub const STATUS_PANIC: i32 = 2;
pub const STATUS_INVALID: i32 = 3;
pub const STATUS_CB_ERR: i32 = 4;

thread_local! {
    // (type, message) as UTF-8 bytes. Never unloaded (rulisp never dlcloses),
    // so TLS destructors are safe here.
    static LAST_ERROR: RefCell<(Vec<u8>, Vec<u8>)> = const { RefCell::new((Vec::new(), Vec::new())) };
}

/// Outstanding Rust->Lisp allocations (strings/buffers) plus live handles are
/// tracked by the glue crate itself; this counter covers `string_into_raw` /
/// `dealloc` pairing so tests can prove nothing leaks across the boundary.
pub static LIVE_ALLOCATIONS: AtomicI64 = AtomicI64::new(0);

pub fn set_last_error(kind: &str, msg: &str) {
    LAST_ERROR.with(|e| {
        let mut e = e.borrow_mut();
        e.0.clear();
        e.0.extend_from_slice(kind.as_bytes());
        e.1.clear();
        e.1.extend_from_slice(msg.as_bytes());
    });
}

/// Backs `<crate>_rulisp_last_error`. Returned pointers are *borrowed*: valid
/// on this thread until the next call into this library. The CL wrapper
/// copies both strings immediately after reading the status code.
///
/// # Safety
/// All four out-pointers must be valid for writes.
pub unsafe fn read_last_error(
    type_ptr: *mut *const u8,
    type_len: *mut usize,
    msg_ptr: *mut *const u8,
    msg_len: *mut usize,
) {
    LAST_ERROR.with(|e| {
        let e = e.borrow();
        unsafe {
            *type_ptr = e.0.as_ptr();
            *type_len = e.0.len();
            *msg_ptr = e.1.as_ptr();
            *msg_len = e.1.len();
        }
    });
}

thread_local! {
    // Set by Callback::call when the Lisp trampoline reports a stashed
    // condition; cleared by the owning shim at entry. Lets the generated
    // shim map a propagated CallbackError (`f.call(..)?`) to STATUS_CB_ERR
    // so the CL wrapper re-signals the original condition (DESIGN.md §4.7).
    static CB_TUNNEL: Cell<bool> = const { Cell::new(false) };
}

pub fn set_callback_tunnel() {
    CB_TUNNEL.with(|c| c.set(true));
}

pub fn clear_callback_tunnel() {
    CB_TUNNEL.with(|c| c.set(false));
}

pub fn callback_tunnel() -> bool {
    CB_TUNNEL.with(|c| c.get())
}

/// Wraps a shim body: catches panics, records them in the last-error slot,
/// maps them to `STATUS_PANIC`. Every generated (or hand-written oracle) shim
/// body runs inside this.
pub fn shim<F: FnOnce() -> i32>(f: F) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(status) => status,
        Err(payload) => {
            let msg: &str = if let Some(s) = payload.downcast_ref::<&str>() {
                s
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s
            } else {
                "panic (non-string payload)"
            };
            set_last_error("panic", msg);
            STATUS_PANIC
        }
    }
}

/// Borrow an incoming `(ptr, len)` UTF-8 argument for the duration of the
/// call. Invalid UTF-8 records last-error and yields `STATUS_INVALID`.
///
/// # Safety
/// When `len > 0`, `ptr..ptr+len` must be readable for the duration of the
/// borrow.
pub unsafe fn str_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    let bytes: &[u8] = if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    };
    std::str::from_utf8(bytes).map_err(|e| {
        set_last_error("InvalidUtf8", &e.to_string());
        STATUS_INVALID
    })
}

/// Transfer a byte buffer to the caller (Lisp takes ownership; frees via
/// the crate's `dealloc` with `(ptr, len, 1)`). `len == capacity` is
/// guaranteed by `into_boxed_slice`. Empty buffers transfer no allocation:
/// `(dangling, 0)`, and the CL side skips dealloc when len == 0.
pub fn bytes_into_raw(v: Vec<u8>) -> (*mut u8, usize) {
    let b: Box<[u8]> = v.into_boxed_slice();
    let len = b.len();
    if len == 0 {
        return (std::ptr::NonNull::dangling().as_ptr(), 0);
    }
    LIVE_ALLOCATIONS.fetch_add(1, Ordering::SeqCst);
    (Box::into_raw(b) as *mut u8, len)
}

/// String variant of [`bytes_into_raw`] (same wire convention, align 1).
pub fn string_into_raw(s: String) -> (*mut u8, usize) {
    bytes_into_raw(s.into_bytes())
}

/// Generic transfer of a `Vec<T>` (v0.2 `(:vec ...)`): the caller frees via
/// the crate's `dealloc` with `(ptr, len * size_of::<T>(), align_of::<T>())`.
/// `len` on the wire counts ELEMENTS. Empty vectors transfer no allocation.
pub fn vec_into_raw<T>(v: Vec<T>) -> (*mut T, usize) {
    let b: Box<[T]> = v.into_boxed_slice();
    let len = b.len();
    if len == 0 {
        return (std::ptr::NonNull::dangling().as_ptr(), 0);
    }
    LIVE_ALLOCATIONS.fetch_add(1, Ordering::SeqCst);
    (Box::into_raw(b) as *mut T, len)
}

/// Borrow an incoming `(ptr, len-in-elements)` slice argument for the
/// duration of the call.
///
/// # Safety
/// When `len > 0`, `ptr..ptr+len` (elements) must be readable and properly
/// aligned for the duration of the borrow.
pub unsafe fn slice_arg<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

/// Borrow an incoming `(ptr, len)` byte argument for the duration of the
/// call. Any bytes are legal — no validation.
///
/// # Safety
/// When `len > 0`, `ptr..ptr+len` must be readable for the duration of the
/// borrow.
pub unsafe fn bytes_arg<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

/// Backs `<crate>_rulisp_dealloc` — the single universal deallocator for
/// every buffer this library handed to Lisp. Size 0 is a no-op (paired with
/// the empty-string convention above).
///
/// # Safety
/// `(ptr, size, align)` must describe exactly one prior allocation made by
/// *this* library (e.g. via `string_into_raw`: align 1), not yet deallocated.
pub unsafe fn dealloc(ptr: *mut u8, size: usize, align: usize) {
    if size == 0 {
        return;
    }
    LIVE_ALLOCATIONS.fetch_sub(1, Ordering::SeqCst);
    unsafe {
        std::alloc::dealloc(ptr, std::alloc::Layout::from_size_align_unchecked(size, align));
    }
}

/// Box a value into an opaque handle for Lisp. Exactly-once free is the CL
/// handle cell's job (DESIGN.md §6.2); the C level only guarantees NULL no-op.
pub fn handle_new<T: Send + Sync + 'static>(v: T) -> *mut c_void {
    Box::into_raw(Box::new(v)) as *mut c_void
}

/// Reborrow a handle for the duration of a shim call.
///
/// # Safety
/// `ptr` must come from `handle_new::<T>` and not have been freed. The CL
/// cell state machine guarantees this for calls made through generated
/// wrappers.
pub unsafe fn handle_ref<'a, T>(ptr: *const c_void) -> &'a T {
    unsafe { &*(ptr as *const T) }
}

/// Drop a handle. NULL is a no-op.
///
/// # Safety
/// `ptr` must come from `handle_new::<T>` and must not be used again.
pub unsafe fn handle_free<T>(ptr: *mut c_void) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr as *mut T) });
    }
}
