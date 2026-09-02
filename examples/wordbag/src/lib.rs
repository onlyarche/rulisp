//! The macro-based twin of tests/m1-handwritten: plain Rust + rulisp macros,
//! zero hand-written `extern "C"`. Must be observably identical to the
//! oracle — same exported surface, same manifest bytes (tests/golden/).

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Mutex;

use rulisp::prelude::*;

/// Live WordBag instances (inc in constructor, dec in Drop): lets tests prove
/// GC-driven finalization and deferred-free timing.
static LIVE_WORD_BAGS: AtomicI64 = AtomicI64::new(0);

/// Incremented by `CbGuard::drop`: proves Rust destructors run when a Lisp
/// callback error unwinds `for_each_word` early.
static CB_GUARD_DROPS: AtomicI64 = AtomicI64::new(0);

// ---------------------------------------------------------------------------
// Plain functions
// ---------------------------------------------------------------------------

#[rulisp::export]
pub fn add(a: i64, b: i64) -> i64 {
    a.wrapping_add(b)
}

#[rulisp::export]
pub fn always_panic() {
    panic!("boom: intentional panic from wordbag");
}

#[derive(Debug)]
pub enum ParseError {
    Invalid(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::Invalid(s) => write!(f, "invalid digit found in string: {s:?}"),
        }
    }
}

impl std::error::Error for ParseError {}

#[rulisp::export]
pub fn parse_number(s: &str) -> Result<i64, ParseError> {
    s.trim()
        .parse()
        .map_err(|_| ParseError::Invalid(s.to_owned()))
}

#[cfg(not(feature = "alt-greeting"))]
const GREETING: &str = "Hello";
#[cfg(feature = "alt-greeting")]
const GREETING: &str = "Hi";

#[rulisp::export]
pub fn greet(name: &str) -> String {
    format!("{GREETING}, {name}!")
}

#[rulisp::export]
pub fn echo(s: &str) -> String {
    s.to_owned()
}

#[rulisp::export]
pub fn sum(data: &[u8]) -> u64 {
    data.iter().map(|&b| b as u64).sum()
}

#[rulisp::export]
pub fn rev(data: &[u8]) -> Vec<u8> {
    let mut v = data.to_vec();
    v.reverse();
    v
}

#[rulisp::export]
pub fn find(data: &[u8], b: u8) -> Option<u64> {
    data.iter().position(|&x| x == b).map(|i| i as u64)
}

#[rulisp::export]
pub fn greet_opt(name: Option<&str>) -> String {
    match name {
        Some(n) => format!("Hello, {n}!"),
        None => "Hello, anonymous!".to_string(),
    }
}

#[rulisp::export]
pub fn deltas(xs: &[i64]) -> Vec<i64> {
    xs.windows(2).map(|w| w[1] - w[0]).collect()
}

#[rulisp::export]
pub fn scale(xs: &[f64], k: f64) -> Vec<f64> {
    xs.iter().map(|x| x * k).collect()
}

// ---------------------------------------------------------------------------
// Stored callback (v0.2): Rust keeps a registered Lisp closure and invokes
// it later — same thread or a fresh Rust thread (adopted on entry).
// ---------------------------------------------------------------------------

static NOTIFIER: Mutex<Option<StoredCallback<(i64,)>>> = Mutex::new(None);

#[rulisp::export]
pub fn set_notifier(f: StoredCallback<(i64,)>) {
    *NOTIFIER.lock().unwrap() = Some(f);
}

#[rulisp::export]
pub fn clear_notifier() {
    *NOTIFIER.lock().unwrap() = None;
}

fn current_notifier() -> Result<StoredCallback<(i64,)>, Error> {
    (*NOTIFIER.lock().unwrap()).ok_or_else(|| Error::msg("no notifier registered"))
}

#[rulisp::export]
pub fn notify(x: i64) -> Result<(), Error> {
    current_notifier()?
        .call((x,))
        .map_err(|_| Error::msg("stored callback failed (see warnings)"))
}

#[rulisp::export]
pub fn notify_from_thread(x: i64) -> Result<(), Error> {
    let cb = current_notifier()?;
    std::thread::spawn(move || cb.call((x,)))
        .join()
        .map_err(|_| Error::msg("notifier thread panicked"))?
        .map_err(|_| Error::msg("stored callback failed (see warnings)"))
}

// ---------------------------------------------------------------------------
// WordBag handle
// ---------------------------------------------------------------------------

#[rulisp::handle]
pub struct WordBag {
    words: Mutex<Vec<String>>,
}

impl Drop for WordBag {
    fn drop(&mut self) {
        LIVE_WORD_BAGS.fetch_sub(1, Ordering::SeqCst);
    }
}

#[rulisp::export]
impl WordBag {
    #[rulisp(constructor)]
    pub fn new() -> WordBag {
        LIVE_WORD_BAGS.fetch_add(1, Ordering::SeqCst);
        WordBag {
            words: Mutex::new(Vec::new()),
        }
    }

    /// A second constructor. Without `name = …` this would also be
    /// `make-word-bag`, which the loader rejects as a duplicate.
    #[rulisp(constructor, name = "make-word-bag-from")]
    pub fn from_csv(csv: &str) -> WordBag {
        let bag = WordBag::new();
        {
            let mut words = bag.words.lock().unwrap();
            for w in csv.split(',').map(str::trim).filter(|w| !w.is_empty()) {
                words.push(w.to_owned());
            }
        }
        bag
    }

    pub fn add(&self, word: &str) -> Result<(), Error> {
        if word.is_empty() {
            return Err(Error::msg("empty word not allowed"));
        }
        self.words.lock().unwrap().push(word.to_owned());
        Ok(())
    }

    pub fn len(&self) -> u64 {
        self.words.lock().unwrap().len() as u64
    }

    /// Parks the caller inside a foreign call so tests can race rulisp:free
    /// against an in-flight method.
    pub fn slow_len(&self, millis: u64) -> u64 {
        std::thread::sleep(std::time::Duration::from_millis(millis));
        self.words.lock().unwrap().len() as u64
    }
    /// Panics while holding the words mutex, poisoning it: BOUNDARY §8 —
    /// the NEXT lock's unwrap panics too and surfaces as status 2.
    pub fn poison(&self) {
        let _guard = self.words.lock().unwrap();
        panic!("wordbag: poisoning the words mutex");
    }

}

// ---------------------------------------------------------------------------
// Callback
// ---------------------------------------------------------------------------

struct CbGuard;

impl Drop for CbGuard {
    fn drop(&mut self) {
        CB_GUARD_DROPS.fetch_add(1, Ordering::SeqCst);
    }
}

/// Swallows callback failures and keeps counting: BOUNDARY §6.3(3), first
/// sentence — a swallowed CallbackError's stash is discarded when the shim
/// returns OK, so the caller sees a normal return, not a re-signal.
#[rulisp::export]
pub fn count_ok(bag: &WordBag, f: Callback<(&str,), ()>) -> u64 {
    let words: Vec<String> = bag.words.lock().unwrap().clone();
    let mut ok: u64 = 0;
    for w in &words {
        if f.call((w.as_str(),)).is_ok() {
            ok += 1;
        }
    }
    ok
}

/// Swallows a callback failure, then fails with its OWN error: BOUNDARY
/// §6.3(3), second sentence — the call is conservatively status 4, so the
/// stashed Lisp condition re-signals instead of this error.
#[rulisp::export]
pub fn swallow_then_fail(f: Callback<(i64,), ()>) -> Result<(), Error> {
    let _ = f.call((7,));
    Err(Error::msg("own error after swallow"))
}

#[rulisp::export]
pub fn for_each_word(bag: &WordBag, f: Callback<(&str,), ()>) -> Result<u64, Error> {
    let _guard = CbGuard;
    // snapshot: never hold the Mutex across a callback — a reentrant
    // word-bag-len on the same bag must not deadlock in Rust
    let words: Vec<String> = bag.words.lock().unwrap().clone();
    for w in &words {
        f.call((w.as_str(),))?;
    }
    Ok(words.len() as u64)
}

// ---------------------------------------------------------------------------
// Test-only introspection exports
// ---------------------------------------------------------------------------

#[rulisp::export]
pub fn test_live_allocations() -> i64 {
    rulisp::runtime::LIVE_ALLOCATIONS.load(Ordering::SeqCst)
}

#[rulisp::export]
pub fn test_live_word_bags() -> i64 {
    LIVE_WORD_BAGS.load(Ordering::SeqCst)
}

#[rulisp::export]
pub fn test_cb_guard_drops() -> i64 {
    CB_GUARD_DROPS.load(Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Module registry: entries are const paths — a typo is a compile error.
// The fns order is the manifest order (byte-pinned by tests/golden/).
// ---------------------------------------------------------------------------

static DUMP_PREPS: AtomicI64 = AtomicI64::new(0);
static DUMP_PREP_FAIL: AtomicI64 = AtomicI64::new(0);

/// The crate's declared dump hook (BOUNDARY §10 :on-dump). Counts its
/// invocations so tests can observe the loader-driven call, and fails on
/// demand so the warn-and-proceed contract is testable.
#[rulisp::export]
pub fn dump_prep() -> Result<(), Error> {
    DUMP_PREPS.fetch_add(1, Ordering::SeqCst);
    if DUMP_PREP_FAIL.load(Ordering::SeqCst) != 0 {
        return Err(Error::msg("dump_prep armed to fail"));
    }
    Ok(())
}

#[rulisp::export]
pub fn set_dump_prep_fail(fail: bool) {
    DUMP_PREP_FAIL.store(if fail { 1 } else { 0 }, Ordering::SeqCst);
}

#[rulisp::export]
pub fn test_dump_preps() -> i64 {
    DUMP_PREPS.load(Ordering::SeqCst)
}

/// Drop panics when armed: BOUNDARY §2's exception — a panic inside a
/// `*_free` shim is caught, logged to stderr and swallowed, never crossing
/// the boundary.
#[rulisp::handle]
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

#[rulisp::export]
impl Grenade {
    #[rulisp(constructor)]
    pub fn new(armed: bool) -> Grenade {
        Grenade { armed }
    }
}

rulisp::module! {
    name: "wordbag",
    handles: [WordBag, Grenade],
    fns: [
        add, always_panic, parse_number, greet, echo, sum, rev,
        find, greet_opt, deltas, scale,
        set_notifier, clear_notifier, notify, notify_from_thread,
        WordBag::new, WordBag::add, WordBag::len, WordBag::slow_len,
        for_each_word, count_ok, swallow_then_fail,
        WordBag::poison, Grenade::new,
        test_live_allocations, test_live_word_bags, test_cb_guard_drops,
        dump_prep, set_dump_prep_fail, test_dump_preps,
        WordBag::from_csv,
    ],
    on_dump: dump_prep,
}
