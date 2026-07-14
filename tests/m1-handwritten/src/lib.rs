//! M1 ABI oracle: hand-written shims following DESIGN.md §4 exactly.
//! This crate is what `#[rulisp::export]` must generate in M3 — it is kept
//! permanently as the reference implementation (never deleted).
//!
//! Extra `test_*` exports exist so the fiveam suite can prove allocation
//! pairing, handle drop timing, and callback-unwind destructor execution
//! from the Lisp side.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::c_void;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Mutex;

use rulisp::Error;
use rulisp_runtime as rt;

static MANIFEST: &str = include_str!("../wordbag.manifest.sexp");

/// Live WordBag instances (inc in constructor, dec in Drop): lets tests prove
/// GC-driven finalization and deferred-free timing.
static LIVE_WORD_BAGS: AtomicI64 = AtomicI64::new(0);

/// Incremented by `CbGuard::drop`: proves Rust destructors run when a Lisp
/// callback error unwinds `for_each_word` early (normal `?`-style unwind,
/// never a Lisp non-local exit through Rust frames).
static CB_GUARD_DROPS: AtomicI64 = AtomicI64::new(0);

// ---------------------------------------------------------------------------
// Library-level entry points (DESIGN.md §4.9)
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn wordbag_rulisp_abi_version() -> u32 {
    rt::ABI_VERSION
}

/// Static manifest: permanent borrow, caller must never free.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_manifest(len: *mut usize) -> *const u8 {
    unsafe { *len = MANIFEST.len() };
    MANIFEST.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_last_error(
    type_ptr: *mut *const u8,
    type_len: *mut usize,
    msg_ptr: *mut *const u8,
    msg_len: *mut usize,
) {
    unsafe { rt::read_last_error(type_ptr, type_len, msg_ptr, msg_len) }
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_dealloc(ptr: *mut u8, size: usize, align: usize) {
    unsafe { rt::dealloc(ptr, size, align) }
}

// ---------------------------------------------------------------------------
// Plain functions
// ---------------------------------------------------------------------------

/// pub fn add(a: i64, b: i64) -> i64
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_add(a: i64, b: i64, out: *mut i64) -> i32 {
    rt::shim(|| {
        unsafe { *out = a.wrapping_add(b) };
        rt::STATUS_OK
    })
}

/// pub fn always_panic() — M1 item 1: panic must surface as rulisp:rust-panic.
#[no_mangle]
pub extern "C" fn wordbag_rulisp_always_panic() -> i32 {
    rt::shim(|| panic!("boom: intentional panic from wordbag"))
}

/// pub fn parse_number(s: &str) -> Result<i64, ParseError>
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_parse_number(
    s_ptr: *const u8,
    s_len: usize,
    out: *mut i64,
) -> i32 {
    rt::shim(|| {
        let s = match unsafe { rt::str_arg(s_ptr, s_len) } {
            Ok(s) => s,
            Err(status) => return status,
        };
        match s.trim().parse::<i64>() {
            Ok(v) => {
                unsafe { *out = v };
                rt::STATUS_OK
            }
            Err(_) => {
                rt::set_last_error(
                    "ParseError",
                    &format!("invalid digit found in string: {s:?}"),
                );
                rt::STATUS_ERR
            }
        }
    })
}

#[cfg(not(feature = "alt-greeting"))]
const GREETING: &str = "Hello";
#[cfg(feature = "alt-greeting")]
const GREETING: &str = "Hi";

/// pub fn greet(name: &str) -> String
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_greet(
    name_ptr: *const u8,
    name_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    rt::shim(|| {
        let name = match unsafe { rt::str_arg(name_ptr, name_len) } {
            Ok(s) => s,
            Err(status) => return status,
        };
        let (p, l) = rt::string_into_raw(format!("{GREETING}, {name}!"));
        unsafe {
            *out_ptr = p;
            *out_len = l;
        }
        rt::STATUS_OK
    })
}

/// pub fn echo(s: &str) -> String — exercises the len==0 no-allocation path.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_echo(
    s_ptr: *const u8,
    s_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    rt::shim(|| {
        let s = match unsafe { rt::str_arg(s_ptr, s_len) } {
            Ok(s) => s,
            Err(status) => return status,
        };
        let (p, l) = rt::string_into_raw(s.to_owned());
        unsafe {
            *out_ptr = p;
            *out_len = l;
        }
        rt::STATUS_OK
    })
}

// ---------------------------------------------------------------------------
// WordBag handle
// ---------------------------------------------------------------------------

pub struct WordBag {
    words: Mutex<Vec<String>>,
}

impl WordBag {
    fn new() -> Self {
        LIVE_WORD_BAGS.fetch_add(1, Ordering::SeqCst);
        WordBag {
            words: Mutex::new(Vec::new()),
        }
    }
}

impl Drop for WordBag {
    fn drop(&mut self) {
        LIVE_WORD_BAGS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// WordBag::new() -> WordBag
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_new(out: *mut *mut c_void) -> i32 {
    rt::shim(|| {
        unsafe { *out = rt::handle_new(WordBag::new()) };
        rt::STATUS_OK
    })
}

/// WordBag::add(&self, word: &str) -> Result<(), Error>
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_add(
    this: *const c_void,
    word_ptr: *const u8,
    word_len: usize,
) -> i32 {
    rt::shim(|| {
        let bag: &WordBag = unsafe { rt::handle_ref(this) };
        let word = match unsafe { rt::str_arg(word_ptr, word_len) } {
            Ok(s) => s,
            Err(status) => return status,
        };
        if word.is_empty() {
            let e = Error::msg("empty word not allowed");
            rt::set_last_error("Error", &e.to_string());
            return rt::STATUS_ERR;
        }
        bag.words.lock().unwrap().push(word.to_owned());
        rt::STATUS_OK
    })
}

/// WordBag::len(&self) -> u64
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_len(this: *const c_void, out: *mut u64) -> i32 {
    rt::shim(|| {
        let bag: &WordBag = unsafe { rt::handle_ref(this) };
        unsafe { *out = bag.words.lock().unwrap().len() as u64 };
        rt::STATUS_OK
    })
}

/// WordBag::slow_len(&self, millis: u64) -> u64 — M1 item 4: lets a test park
/// thread A inside a method while thread B calls rulisp:free.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_slow_len(
    this: *const c_void,
    millis: u64,
    out: *mut u64,
) -> i32 {
    rt::shim(|| {
        let bag: &WordBag = unsafe { rt::handle_ref(this) };
        std::thread::sleep(std::time::Duration::from_millis(millis));
        unsafe { *out = bag.words.lock().unwrap().len() as u64 };
        rt::STATUS_OK
    })
}

/// Free shim: void return, NULL no-op, panics swallowed (finalizer context
/// has no error channel — DESIGN.md §4.1).
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_free(this: *mut c_void) {
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        rt::handle_free::<WordBag>(this)
    }));
    if r.is_err() {
        eprintln!("rulisp[wordbag]: panic in word_bag_free (swallowed)");
    }
}

// ---------------------------------------------------------------------------
// Callback (DESIGN.md §4.7)
// ---------------------------------------------------------------------------

/// Generated typedef for Callback<(&str,), ()>:
/// returns 0 = OK; 1 = Lisp condition stashed (abort iteration, propagate).
pub type Cbty0 = unsafe extern "C" fn(userdata: u64, a0_ptr: *const u8, a0_len: usize) -> i32;

struct CbGuard;

impl Drop for CbGuard {
    fn drop(&mut self) {
        CB_GUARD_DROPS.fetch_add(1, Ordering::SeqCst);
    }
}

/// for_each_word(bag: &WordBag, f: Callback<(&str,), ()>) -> Result<u64, Error>
///
/// Contract details the macro must reproduce:
/// - The words Mutex is NOT held across callback invocations (a reentrant
///   callback calling word_bag_len on the same bag must not deadlock in
///   Rust); we iterate over a snapshot.
/// - A callback status != 0 aborts iteration via a normal early return, so
///   locals Drop normally (proved by CbGuard), and the shim returns
///   STATUS_CB_ERR so the CL wrapper re-signals the stashed condition.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_for_each_word(
    this: *const c_void,
    f: Cbty0,
    userdata: u64,
    out: *mut u64,
) -> i32 {
    rt::shim(|| {
        let bag: &WordBag = unsafe { rt::handle_ref(this) };
        let _guard = CbGuard;
        let words: Vec<String> = bag.words.lock().unwrap().clone();
        for w in &words {
            let status = unsafe { f(userdata, w.as_ptr(), w.len()) };
            if status != 0 {
                return rt::STATUS_CB_ERR; // _guard drops here: destructor ran
            }
        }
        unsafe { *out = words.len() as u64 };
        rt::STATUS_OK
    })
}

// ---------------------------------------------------------------------------
// Test-only introspection exports
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_live_allocations(out: *mut i64) -> i32 {
    rt::shim(|| {
        unsafe { *out = rt::LIVE_ALLOCATIONS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_live_word_bags(out: *mut i64) -> i32 {
    rt::shim(|| {
        unsafe { *out = LIVE_WORD_BAGS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_cb_guard_drops(out: *mut i64) -> i32 {
    rt::shim(|| {
        unsafe { *out = CB_GUARD_DROPS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}
