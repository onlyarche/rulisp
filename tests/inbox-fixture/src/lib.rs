//! rulisp::Inbox's tested example (tests/suite/v09.lisp): the queue
//! direction of the boundary, with no Lisp callback and no adopted thread.

use std::sync::atomic::{AtomicU64, Ordering};

/// Producer threads still running: lets v09 observe that freeing a
/// ticker stops its producer.
static LIVE_PRODUCERS: AtomicU64 = AtomicU64::new(0);

struct LiveGuard;

impl Drop for LiveGuard {
    fn drop(&mut self) {
        LIVE_PRODUCERS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Producer threads of every ticker that have not exited yet.
#[rulisp::export]
pub fn producers_live() -> u64 {
    LIVE_PRODUCERS.load(Ordering::SeqCst)
}

use rulisp::prelude::*;

/// Numbered events produced on a thread of its own and delivered through
/// a `rulisp::Inbox`: the queue direction of the boundary, with no
/// Lisp callback and no adopted thread. The producer sends `count` values,
/// one every `interval_ms` (at most 1000), counts the ones the full inbox
/// refused, and closes the inbox when done or when the ticker is freed.
#[rulisp::handle]
pub struct Ticker {
    inbox: rulisp::Inbox<u64>,
    dropped: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl Drop for Ticker {
    fn drop(&mut self) {
        // the producer sees the close at its next send and exits
        self.inbox.close();
    }
}

#[rulisp::export]
impl Ticker {
    #[rulisp(constructor)]
    pub fn new(count: u64, interval_ms: u64, capacity: u64) -> Ticker {
        let inbox = rulisp::Inbox::new(capacity.min(1 << 20) as usize);
        let dropped = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
        let (tx, lost) = (inbox.clone(), dropped.clone());
        let interval = std::time::Duration::from_millis(interval_ms.min(1000));
        LIVE_PRODUCERS.fetch_add(1, Ordering::SeqCst);
        std::thread::spawn(move || {
            let _live = LiveGuard;
            for i in 0..count {
                match tx.try_send(i) {
                    Ok(()) => {}
                    Err(rulisp::SendError::Full(_)) => {
                        lost.fetch_add(1, Ordering::SeqCst);
                    }
                    Err(rulisp::SendError::Closed(_)) => return,
                }
                std::thread::sleep(interval);
            }
            tx.close();
        });
        Ticker { inbox, dropped }
    }

    /// The next event, or NIL when none arrived within WAIT-MS (capped at
    /// 100 ms). Signals `rulisp:rust-error` "closed: …" once the producer
    /// finished and every event was taken.
    pub fn next(&self, wait_ms: u64) -> Result<Option<u64>, Error> {
        Ok(self.inbox.recv(wait_ms)?)
    }

    /// Events the producer could not deliver because the inbox was full.
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::SeqCst)
    }

    /// Events waiting to be taken.
    pub fn pending(&self) -> u64 {
        self.inbox.len() as u64
    }
}

rulisp::module! {
    name: "inboxfix",
    handles: [Ticker],
    fns: [Ticker::new, Ticker::next, Ticker::dropped, Ticker::pending, producers_live],
}
