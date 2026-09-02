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

use rulisp::{Error, StoredCallback};
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
        let _frame = rt::ShimFrame::new();
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
        let _frame = rt::ShimFrame::new();
        let s = match unsafe { rt::str_arg(&_frame, s_ptr, s_len) } {
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
        let _frame = rt::ShimFrame::new();
        let name = match unsafe { rt::str_arg(&_frame, name_ptr, name_len) } {
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
        let _frame = rt::ShimFrame::new();
        let s = match unsafe { rt::str_arg(&_frame, s_ptr, s_len) } {
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

/// pub fn sum(data: &[u8]) -> u64   (v0.2 :bytes — borrowed octets in)
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_sum(
    data_ptr: *const u8,
    data_len: usize,
    out: *mut u64,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let data = unsafe { rt::bytes_arg(&_frame, data_ptr, data_len) };
        unsafe { *out = data.iter().map(|&b| b as u64).sum() };
        rt::STATUS_OK
    })
}

/// pub fn rev(data: &[u8]) -> Vec<u8>   (v0.2 :bytes — owned octets out)
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_rev(
    data_ptr: *const u8,
    data_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let data = unsafe { rt::bytes_arg(&_frame, data_ptr, data_len) };
        let mut v = data.to_vec();
        v.reverse();
        let (p, l) = rt::bytes_into_raw(v);
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
        let _frame = rt::ShimFrame::new();
        unsafe { *out = rt::handle_new(WordBag::new()) };
        rt::STATUS_OK
    })
}

/// WordBag::from_csv(csv: &str) -> WordBag — the second constructor,
/// exported under an explicit lisp name ("make-word-bag-from").
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_from_csv(
    csv_ptr: *const u8,
    csv_len: usize,
    out: *mut *mut c_void,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let csv = match unsafe { rt::str_arg(&_frame, csv_ptr, csv_len) } {
            Ok(s) => s,
            Err(status) => return status,
        };
        let bag = WordBag::new();
        {
            let mut words = bag.words.lock().unwrap();
            for w in csv.split(',').map(str::trim).filter(|w| !w.is_empty()) {
                words.push(w.to_owned());
            }
        }
        unsafe { *out = rt::handle_new(bag) };
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
        let _frame = rt::ShimFrame::new();
        let bag: &WordBag = unsafe { rt::handle_ref(&_frame, this) };
        let word = match unsafe { rt::str_arg(&_frame, word_ptr, word_len) } {
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
        let _frame = rt::ShimFrame::new();
        let bag: &WordBag = unsafe { rt::handle_ref(&_frame, this) };
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
        let _frame = rt::ShimFrame::new();
        let bag: &WordBag = unsafe { rt::handle_ref(&_frame, this) };
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
        let _frame = rt::ShimFrame::new();
        let bag: &WordBag = unsafe { rt::handle_ref(&_frame, this) };
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

pub type Cbty1 = unsafe extern "C" fn(userdata: u64, a0: i64) -> i32;

/// count_ok(bag, f) -> u64: swallows callback failures and keeps counting.
/// BOUNDARY §6.3(3), first sentence — with the shim returning OK, the
/// stashed condition is discarded, not re-signaled.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_count_ok(
    this: *const c_void,
    f: Cbty0,
    userdata: u64,
    out: *mut u64,
) -> i32 {
    rt::shim(|| {
        rt::clear_callback_tunnel();
        let _frame = rt::ShimFrame::new();
        let bag: &WordBag = unsafe { rt::handle_ref(&_frame, this) };
        let words: Vec<String> = bag.words.lock().unwrap().clone();
        let mut ok: u64 = 0;
        for w in &words {
            if unsafe { f(userdata, w.as_ptr(), w.len()) } == 0 {
                ok += 1;
            }
        }
        unsafe { *out = ok };
        rt::STATUS_OK
    })
}

/// swallow_then_fail(f) -> Result<(), Error>: swallows the callback error,
/// then fails on its own. BOUNDARY §6.3(3), second sentence — the tunnel
/// flag is still up, so the failure is conservatively STATUS_CB_ERR and
/// the ORIGINAL Lisp condition re-signals (mirrors the macro's
/// tunnel_check on the Err branch).
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_swallow_then_fail(f: Cbty1, userdata: u64) -> i32 {
    rt::shim(|| {
        rt::clear_callback_tunnel();
        let _ = unsafe { f(userdata, 7) };
        if rt::callback_tunnel() {
            return rt::STATUS_CB_ERR;
        }
        rt::set_last_error("Error", "own error after swallow");
        rt::STATUS_ERR
    })
}

/// WordBag::poison(&self): panics while holding the words mutex —
/// BOUNDARY §8's poisoned-mutex clause; the next lock reports status 2.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_word_bag_poison(this: *const c_void) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let bag: &WordBag = unsafe { rt::handle_ref(&_frame, this) };
        let _guard = bag.words.lock().unwrap();
        panic!("wordbag: poisoning the words mutex");
    })
}

static DUMP_PREPS: AtomicI64 = AtomicI64::new(0);
static DUMP_PREP_FAIL: AtomicI64 = AtomicI64::new(0);

/// The declared dump hook (BOUNDARY §10 :on-dump): zero-arg, unit result,
/// called by the loader through a fixed () -> int32 signature.
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_dump_prep() -> i32 {
    rt::shim(|| {
        DUMP_PREPS.fetch_add(1, Ordering::SeqCst);
        if DUMP_PREP_FAIL.load(Ordering::SeqCst) != 0 {
            rt::set_last_error("Error", "dump_prep armed to fail");
            return rt::STATUS_ERR;
        }
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_set_dump_prep_fail(fail: u8) -> i32 {
    rt::shim(|| {
        DUMP_PREP_FAIL.store(if fail != 0 { 1 } else { 0 }, Ordering::SeqCst);
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_dump_preps(out: *mut i64) -> i32 {
    rt::shim(|| {
        unsafe { *out = DUMP_PREPS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}

// ---------------------------------------------------------------------------
// Grenade: a handle whose Drop panics when armed (BOUNDARY §2's exception —
// a panic inside a *_free shim is caught, logged and swallowed)
// ---------------------------------------------------------------------------

pub struct Grenade {
    armed: bool,
}

impl Drop for Grenade {
    fn drop(&mut self) {
        if self.armed {
            panic!("grenade: boom in drop");
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_grenade_new(
    armed: u8,
    out: *mut *mut c_void,
) -> i32 {
    rt::shim(|| {
        unsafe { *out = rt::handle_new(Grenade { armed: armed != 0 }) };
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_grenade_free(this: *mut c_void) {
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
        rt::handle_free::<Grenade>(this)
    }));
    if r.is_err() {
        eprintln!("rulisp: panic in wordbag_rulisp_grenade_free (caught, handle leaked)");
    }
}

/// pub fn find(data: &[u8], b: u8) -> Option<u64>   (v0.2 (:option ...))
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_find(
    data_ptr: *const u8,
    data_len: usize,
    b: u8,
    some_out: *mut u8,
    out: *mut u64,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let data = unsafe { rt::bytes_arg(&_frame, data_ptr, data_len) };
        match data.iter().position(|&x| x == b) {
            Some(i) => unsafe {
                *some_out = 1;
                *out = i as u64;
            },
            None => unsafe { *some_out = 0 },
        }
        rt::STATUS_OK
    })
}

/// pub fn greet_opt(name: Option<&str>) -> String   (v0.2 optional param)
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_greet_opt(
    name_present: u8,
    name_ptr: *const u8,
    name_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let name = if name_present != 0 {
            match unsafe { rt::str_arg(&_frame, name_ptr, name_len) } {
                Ok(s) => Some(s),
                Err(status) => return status,
            }
        } else {
            None
        };
        let s = match name {
            Some(n) => format!("Hello, {n}!"),
            None => "Hello, anonymous!".to_string(),
        };
        let (p, l) = rt::string_into_raw(s);
        unsafe {
            *out_ptr = p;
            *out_len = l;
        }
        rt::STATUS_OK
    })
}

/// pub fn deltas(xs: &[i64]) -> Vec<i64>   (v0.2 (:vec ...): elements on the
/// wire, freed via dealloc(ptr, len * size, align))
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_deltas(
    xs_ptr: *const i64,
    xs_len: usize,
    out_ptr: *mut *mut i64,
    out_len: *mut usize,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let xs = unsafe { rt::slice_arg(&_frame, xs_ptr, xs_len) };
        let v: Vec<i64> = xs.windows(2).map(|w| w[1] - w[0]).collect();
        let (p, l) = rt::vec_into_raw(v);
        unsafe {
            *out_ptr = p;
            *out_len = l;
        }
        rt::STATUS_OK
    })
}

/// pub fn scale(xs: &[f64], k: f64) -> Vec<f64>   (float (:vec ...) path)
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_scale(
    xs_ptr: *const f64,
    xs_len: usize,
    k: f64,
    out_ptr: *mut *mut f64,
    out_len: *mut usize,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let xs = unsafe { rt::slice_arg(&_frame, xs_ptr, xs_len) };
        let v: Vec<f64> = xs.iter().map(|x| x * k).collect();
        let (p, l) = rt::vec_into_raw(v);
        unsafe {
            *out_ptr = p;
            *out_len = l;
        }
        rt::STATUS_OK
    })
}

// ---------------------------------------------------------------------------
// Stored callback (v0.2): Rust keeps a registered Lisp closure and invokes
// it later — same thread or a fresh Rust thread (adopted on entry).
// ---------------------------------------------------------------------------

static NOTIFIER: Mutex<Option<StoredCallback<(i64,), ()>>> = Mutex::new(None);

/// set_notifier(f: StoredCallback<(i64,)>)
#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_set_notifier(
    f: unsafe extern "C" fn(u64, i64) -> i32,
    f_userdata: u64,
) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let f = unsafe { StoredCallback::from_raw(f as usize, f_userdata) };
        *NOTIFIER.lock().unwrap() = Some(f);
        rt::STATUS_OK
    })
}

/// clear_notifier()
#[no_mangle]
pub extern "C" fn wordbag_rulisp_clear_notifier() -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        *NOTIFIER.lock().unwrap() = None;
        rt::STATUS_OK
    })
}

fn current_notifier() -> Result<StoredCallback<(i64,), ()>, i32> {
    NOTIFIER.lock().unwrap().ok_or_else(|| {
        rt::set_last_error("Error", "no notifier registered");
        rt::STATUS_ERR
    })
}

/// notify(x: i64) -> Result<(), Error> — invoke on the calling thread.
#[no_mangle]
pub extern "C" fn wordbag_rulisp_notify(x: i64) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let cb = match current_notifier() {
            Ok(cb) => cb,
            Err(status) => return status,
        };
        match cb.call((x,)) {
            Ok(()) => rt::STATUS_OK,
            Err(_) => {
                rt::set_last_error("Error", "stored callback failed (see warnings)");
                rt::STATUS_ERR
            }
        }
    })
}

/// notify_from_thread(x: i64) -> Result<(), Error> — invoke from a fresh
/// Rust thread (joined for determinism; the Lisp adopts it on entry).
#[no_mangle]
pub extern "C" fn wordbag_rulisp_notify_from_thread(x: i64) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        let cb = match current_notifier() {
            Ok(cb) => cb,
            Err(status) => return status,
        };
        match std::thread::spawn(move || cb.call((x,))).join() {
            Ok(Ok(())) => rt::STATUS_OK,
            Ok(Err(_)) => {
                rt::set_last_error("Error", "stored callback failed (see warnings)");
                rt::STATUS_ERR
            }
            Err(_) => {
                rt::set_last_error("Error", "notifier thread panicked");
                rt::STATUS_ERR
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Test-only introspection exports
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_live_allocations(out: *mut i64) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        unsafe { *out = rt::LIVE_ALLOCATIONS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_live_word_bags(out: *mut i64) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        unsafe { *out = LIVE_WORD_BAGS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn wordbag_rulisp_test_cb_guard_drops(out: *mut i64) -> i32 {
    rt::shim(|| {
        let _frame = rt::ShimFrame::new();
        unsafe { *out = CB_GUARD_DROPS.load(Ordering::SeqCst) };
        rt::STATUS_OK
    })
}
