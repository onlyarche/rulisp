//! One error type. Condition granularity lives on the Lisp side, where
//! conditions have slots and restarts; `kind` is a stable lowercase token
//! the veneer dispatches on — never a parsed prose prefix.

#[derive(Debug, Clone)]
pub struct HttpError {
    pub kind: &'static str,
    pub msg: String,
}

impl HttpError {
    pub fn new(kind: &'static str, msg: impl Into<String>) -> Self {
        HttpError {
            kind,
            msg: msg.into(),
        }
    }

    /// The client (or this request) is finished; calling further is a usage
    /// error, and it must answer immediately rather than hang.
    pub fn usage(msg: impl Into<String>) -> Self {
        Self::new("usage", msg)
    }
    pub fn busy(msg: impl Into<String>) -> Self {
        Self::new("busy", msg)
    }
    pub fn request(msg: impl Into<String>) -> Self {
        Self::new("request", msg)
    }
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // "kind: message" — the veneer splits on the first colon, so the
        // kind token must never contain one.
        write!(f, "{}: {}", self.kind, self.msg)
    }
}

impl std::error::Error for HttpError {}
