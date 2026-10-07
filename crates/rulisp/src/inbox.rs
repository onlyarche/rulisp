//! `Inbox<T>`: events from any Rust thread, pulled by Lisp.
//!
//! The queue direction of the boundary, as a library type. A producer —
//! a tokio task, a watcher thread, a C library's callback — puts values in
//! with [`Inbox::try_send`] and never runs Lisp code. A Lisp thread takes
//! them out through an export that calls [`Inbox::recv`], whose wait is
//! capped at [`WAIT_CAP_MS`] so the loop stays in Lisp, where Ctrl-C,
//! restarts and the debugger work (BOUNDARY.md §7). No foreign thread is
//! adopted, so the Lisp's garbage collector and debugger never meet a
//! thread the Lisp did not make.
//!
//! ```
//! use rulisp::Inbox;
//!
//! let inbox: Inbox<u64> = Inbox::new(16);
//! let producer = inbox.clone();
//! std::thread::spawn(move || {
//!     for i in 0..3 {
//!         producer.try_send(i).ok();
//!     }
//!     producer.close();
//! });
//! // what an export called from Lisp does, one capped wait at a time
//! let mut got = Vec::new();
//! loop {
//!     match inbox.recv(100) {
//!         Ok(Some(v)) => got.push(v),
//!         Ok(None) => continue, // nothing yet: return to Lisp, ask again
//!         Err(_closed) => break,
//!     }
//! }
//! assert_eq!(got, vec![0, 1, 2]);
//! ```

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// The longest a single [`Inbox::recv`] waits, whatever it is asked for:
/// a Lisp thread inside a foreign call cannot be interrupted, so every
/// wait is short and the loop that repeats it lives in Lisp.
pub const WAIT_CAP_MS: u64 = 100;

/// Why [`Inbox::try_send`] or [`Inbox::send_timeout`] gave the value back.
#[derive(Debug, PartialEq, Eq)]
pub enum SendError<T> {
    /// The inbox held `capacity` values: the consumer is behind. Drop the
    /// value, count it, or answer the producer's own client with a
    /// refusal — the choice is the producer's.
    Full(T),
    /// The inbox was closed; no value will be taken again.
    Closed(T),
}

impl<T> SendError<T> {
    /// The value that was not sent.
    pub fn into_inner(self) -> T {
        match self {
            SendError::Full(v) | SendError::Closed(v) => v,
        }
    }
}

impl<T> std::fmt::Display for SendError<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SendError::Full(_) => f.write_str("full: the inbox is at capacity"),
            SendError::Closed(_) => f.write_str("closed: the inbox is closed"),
        }
    }
}

impl<T: std::fmt::Debug> std::error::Error for SendError<T> {}

/// [`Inbox::recv`] on an inbox that is closed and empty: every value sent
/// before the close has been taken.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct Closed;

impl std::fmt::Display for Closed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("closed: the inbox is closed and empty")
    }
}

impl std::error::Error for Closed {}

impl From<Closed> for crate::Error {
    fn from(c: Closed) -> Self {
        crate::Error::msg(c.to_string())
    }
}

struct State<T> {
    queue: VecDeque<T>,
    closed: bool,
}

struct Shared<T> {
    state: Mutex<State<T>>,
    not_empty: Condvar,
    not_full: Condvar,
    capacity: usize,
}

/// A bounded, multi-producer queue whose consumer is Lisp. Cloning shares
/// the same queue; give a clone to each producer and keep one in the
/// handle Lisp holds.
pub struct Inbox<T> {
    shared: Arc<Shared<T>>,
}

impl<T> Clone for Inbox<T> {
    fn clone(&self) -> Self {
        Inbox { shared: Arc::clone(&self.shared) }
    }
}

impl<T> Inbox<T> {
    /// An inbox holding at most `capacity` values (at least one).
    pub fn new(capacity: usize) -> Self {
        Inbox {
            shared: Arc::new(Shared {
                state: Mutex::new(State { queue: VecDeque::new(), closed: false }),
                not_empty: Condvar::new(),
                not_full: Condvar::new(),
                capacity: capacity.max(1),
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State<T>> {
        // no user code runs under this lock, so a poisoned one still
        // holds a consistent queue
        self.shared.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Put a value in without waiting, from any thread, async code
    /// included. The value comes back when the inbox is full or closed.
    pub fn try_send(&self, value: T) -> Result<(), SendError<T>> {
        let mut st = self.lock();
        if st.closed {
            return Err(SendError::Closed(value));
        }
        if st.queue.len() >= self.shared.capacity {
            return Err(SendError::Full(value));
        }
        st.queue.push_back(value);
        drop(st);
        self.shared.not_empty.notify_one();
        Ok(())
    }

    /// Put a value in, waiting up to `timeout` for room. For a producer
    /// thread that may block — never an async task, and never a Lisp
    /// thread (use [`Inbox::try_send`] there).
    pub fn send_timeout(&self, value: T, timeout: Duration) -> Result<(), SendError<T>> {
        let deadline = Instant::now() + timeout;
        let mut st = self.lock();
        loop {
            if st.closed {
                return Err(SendError::Closed(value));
            }
            if st.queue.len() < self.shared.capacity {
                st.queue.push_back(value);
                drop(st);
                self.shared.not_empty.notify_one();
                return Ok(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(SendError::Full(value));
            }
            st = self
                .shared
                .not_full
                .wait_timeout(st, deadline - now)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    /// Take the next value, waiting at most `wait_ms`, capped at
    /// [`WAIT_CAP_MS`]. `Ok(None)` means nothing arrived in that time;
    /// `Err(Closed)` means the inbox is closed and every value sent before
    /// the close has been taken. Call it from the export Lisp loops on.
    pub fn recv(&self, wait_ms: u64) -> Result<Option<T>, Closed> {
        let deadline = Instant::now() + Duration::from_millis(wait_ms.min(WAIT_CAP_MS));
        let mut st = self.lock();
        loop {
            if let Some(v) = st.queue.pop_front() {
                drop(st);
                self.shared.not_full.notify_one();
                return Ok(Some(v));
            }
            if st.closed {
                return Err(Closed);
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            st = self
                .shared
                .not_empty
                .wait_timeout(st, deadline - now)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    /// Refuse further values and wake every waiter. Values already in stay
    /// and are still taken by [`Inbox::recv`]; after them it answers
    /// `Err(Closed)`. Closing twice is harmless.
    pub fn close(&self) {
        self.lock().closed = true;
        self.shared.not_empty.notify_all();
        self.shared.not_full.notify_all();
    }

    /// True once [`Inbox::close`] was called.
    pub fn is_closed(&self) -> bool {
        self.lock().closed
    }

    /// Values waiting to be taken.
    pub fn len(&self) -> usize {
        self.lock().queue.len()
    }

    /// True when no value is waiting.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The most values the inbox holds at once.
    pub fn capacity(&self) -> usize {
        self.shared.capacity
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn order_full_and_closed() {
        let ib = Inbox::new(2);
        assert_eq!(ib.try_send(1), Ok(()));
        assert_eq!(ib.try_send(2), Ok(()));
        assert_eq!(ib.try_send(3), Err(SendError::Full(3)));
        ib.close();
        assert_eq!(ib.try_send(4), Err(SendError::Closed(4)));
        assert_eq!(ib.recv(0), Ok(Some(1)));
        assert_eq!(ib.recv(0), Ok(Some(2)));
        assert_eq!(ib.recv(0), Err(Closed));
    }

    #[test]
    fn recv_is_capped() {
        let ib: Inbox<u8> = Inbox::new(1);
        let t = Instant::now();
        assert_eq!(ib.recv(60_000), Ok(None));
        assert!(t.elapsed() < Duration::from_millis(WAIT_CAP_MS + 400));
    }

    #[test]
    fn recv_wakes_on_send_and_on_close() {
        let ib: Inbox<u8> = Inbox::new(1);
        let p = ib.clone();
        let h = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            p.try_send(7).unwrap();
            std::thread::sleep(Duration::from_millis(20));
            p.close();
        });
        let mut got = None;
        while got.is_none() {
            got = ib.recv(100).unwrap();
        }
        assert_eq!(got, Some(7));
        let closed = loop {
            match ib.recv(100) {
                Ok(None) => continue,
                other => break other,
            }
        };
        assert_eq!(closed, Err(Closed));
        h.join().unwrap();
    }

    #[test]
    fn send_timeout_waits_for_room() {
        let ib = Inbox::new(1);
        ib.try_send(1).unwrap();
        assert_eq!(ib.send_timeout(2, Duration::from_millis(20)), Err(SendError::Full(2)));
        let c = ib.clone();
        let h = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            c.recv(100).unwrap()
        });
        assert_eq!(ib.send_timeout(2, Duration::from_secs(5)), Ok(()));
        assert_eq!(h.join().unwrap(), Some(1));
        assert_eq!(ib.recv(0), Ok(Some(2)));
    }

    #[test]
    fn capacity_is_at_least_one() {
        let ib = Inbox::new(0);
        assert_eq!(ib.capacity(), 1);
        assert!(ib.try_send(()).is_ok());
    }
}
