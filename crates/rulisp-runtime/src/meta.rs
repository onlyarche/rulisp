//! Export metadata + manifest rendering.
//!
//! `#[rulisp::export]` / `#[rulisp::handle]` emit const metadata; `module!`
//! collects it and lazily renders the s-expression manifest. The renderer's
//! formatting is pinned by the golden snapshot (tests/golden/, byte-identity
//! gate — DESIGN.md §8 M3): do not change it without bumping the golden.

/// A parameter (or callback-parameter) type token.
#[derive(Clone, Copy)]
pub enum ParamTy {
    /// A lisp type token like ":i64" (includes the colon).
    Scalar(&'static str),
    Str,
    Bytes,
    /// Rust name of a `#[rulisp::handle]` type.
    Handle(&'static str),
    Callback {
        params: &'static [ParamTy],
        /// result token, ":unit" in v1
        result: &'static str,
    },
    /// v0.2: registered callback — storable, cloneable, any-thread.
    StoredCallback {
        params: &'static [ParamTy],
        result: &'static str,
    },
    /// v0.2: `Option<inner>` — inner is Scalar/Str/Bytes.
    Option(&'static ParamTy),
    /// v0.2: `&[scalar]` — the token is the element's, e.g. ":i64".
    Vec(&'static str),
}

#[derive(Clone, Copy)]
pub enum ResultTy {
    Unit,
    Scalar(&'static str),
    Str,
    Bytes,
    Handle(&'static str),
    /// v0.2: `Option<inner>` — inner is Scalar/Str/Bytes.
    Option(&'static ResultTy),
    /// v0.2: `Vec<scalar>` — the token is the element's.
    Vec(&'static str),
}

pub struct ParamMeta {
    pub name: &'static str,
    pub ty: ParamTy,
}

pub struct FnMeta {
    /// "add" or "WordBag::new"
    pub rust_name: &'static str,
    /// "make-word-bag"
    pub lisp_name: &'static str,
    /// unprefixed C symbol, e.g. "word_bag_new"
    pub symbol: &'static str,
    pub params: &'static [ParamMeta],
    pub result: ResultTy,
    /// error type name ("Error", "ParseError") or None for infallible
    pub error: Option<&'static str>,
}

pub struct HandleMeta {
    pub rust_name: &'static str,
    pub lisp_name: &'static str,
    /// unprefixed free symbol, e.g. "word_bag_free"
    pub free_symbol: &'static str,
}

/// Rust target triple of this build, for the manifest `:target` key.
#[cfg(all(target_arch = "x86_64", target_os = "linux", target_env = "gnu"))]
pub const TARGET: &str = "x86_64-unknown-linux-gnu";
#[cfg(all(target_arch = "x86_64", target_os = "linux", target_env = "musl"))]
pub const TARGET: &str = "x86_64-unknown-linux-musl";
#[cfg(all(target_arch = "aarch64", target_os = "linux", target_env = "gnu"))]
pub const TARGET: &str = "aarch64-unknown-linux-gnu";
#[cfg(all(target_arch = "x86_64", target_os = "macos"))]
pub const TARGET: &str = "x86_64-apple-darwin";
#[cfg(all(target_arch = "aarch64", target_os = "macos"))]
pub const TARGET: &str = "aarch64-apple-darwin";
#[cfg(all(target_arch = "x86_64", target_os = "windows", target_env = "msvc"))]
pub const TARGET: &str = "x86_64-pc-windows-msvc";
#[cfg(all(target_arch = "x86_64", target_os = "windows", target_env = "gnu"))]
pub const TARGET: &str = "x86_64-pc-windows-gnu";
#[cfg(all(target_arch = "aarch64", target_os = "windows"))]
pub const TARGET: &str = "aarch64-pc-windows-msvc";
#[cfg(not(any(
    all(target_arch = "x86_64", target_os = "linux", target_env = "gnu"),
    all(target_arch = "x86_64", target_os = "linux", target_env = "musl"),
    all(target_arch = "aarch64", target_os = "linux", target_env = "gnu"),
    all(target_arch = "x86_64", target_os = "macos"),
    all(target_arch = "aarch64", target_os = "macos"),
    all(target_arch = "x86_64", target_os = "windows", target_env = "msvc"),
    all(target_arch = "x86_64", target_os = "windows", target_env = "gnu"),
    all(target_arch = "aarch64", target_os = "windows"),
)))]
pub const TARGET: &str = "unknown";

fn render_ty(ty: &ParamTy, out: &mut String) {
    match ty {
        ParamTy::Scalar(tok) => out.push_str(tok),
        ParamTy::Str => out.push_str(":string"),
        ParamTy::Bytes => out.push_str(":bytes"),
        ParamTy::Handle(n) => {
            out.push_str("(:handle \"");
            out.push_str(n);
            out.push_str("\")");
        }
        ParamTy::Callback { params, result } => {
            out.push_str("(:callback :params (");
            for (i, p) in params.iter().enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                render_ty(p, out);
            }
            out.push_str(") :result ");
            out.push_str(result);
            out.push(')');
        }
        ParamTy::Option(inner) => {
            out.push_str("(:option ");
            render_ty(inner, out);
            out.push(')');
        }
        ParamTy::Vec(tok) => {
            out.push_str("(:vec ");
            out.push_str(tok);
            out.push(')');
        }
        ParamTy::StoredCallback { params, result } => {
            out.push_str("(:stored-callback :params (");
            for (i, p) in params.iter().enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                render_ty(p, out);
            }
            out.push_str(") :result ");
            out.push_str(result);
            out.push(')');
        }
    }
}

fn render_param(p: &ParamMeta, out: &mut String) {
    out.push_str("(:name \"");
    out.push_str(p.name);
    out.push_str("\" :type ");
    render_ty(&p.ty, out);
    out.push(')');
}

fn render_result(r: &ResultTy, out: &mut String) {
    match r {
        ResultTy::Unit => out.push_str(":unit"),
        ResultTy::Scalar(tok) => out.push_str(tok),
        ResultTy::Str => out.push_str(":string"),
        ResultTy::Bytes => out.push_str(":bytes"),
        ResultTy::Handle(n) => {
            out.push_str("(:handle \"");
            out.push_str(n);
            out.push_str("\")");
        }
        ResultTy::Option(inner) => {
            out.push_str("(:option ");
            render_result(inner, out);
            out.push(')');
        }
        ResultTy::Vec(tok) => {
            out.push_str("(:vec ");
            out.push_str(tok);
            out.push(')');
        }
    }
}

fn render_error(e: &Option<&'static str>, out: &mut String) {
    match e {
        None => out.push_str("nil"),
        Some(name) => {
            out.push('"');
            out.push_str(name);
            out.push('"');
        }
    }
}

/// Renders one fn entry with a 2-space base indent (no trailing newline).
/// Width-driven layout, pinned by the golden snapshot: everything after the
/// name line goes on one line when it fits in `WIDTH` columns; otherwise
/// `:result`/`:error` drop to their own line; if the params list alone still
/// overflows, params break one per line.
fn render_fn(f: &FnMeta, out: &mut String) {
    const WIDTH: usize = 100;

    out.push_str("(:fn :rust-name \"");
    out.push_str(f.rust_name);
    out.push_str("\" :lisp-name \"");
    out.push_str(f.lisp_name);
    out.push_str("\" :symbol \"");
    out.push_str(f.symbol);
    out.push_str("\"\n");

    let params: Vec<String> = f
        .params
        .iter()
        .map(|p| {
            let mut s = String::new();
            render_param(p, &mut s);
            s
        })
        .collect();
    let params_inline = params.join(" ");

    let mut tail = String::from(":result ");
    render_result(&f.result, &mut tail);
    tail.push_str(" :error ");
    render_error(&f.error, &mut tail);
    tail.push(')');

    let one_line = format!("   :params ({params_inline}) {tail}");
    if one_line.len() <= WIDTH {
        out.push_str(&one_line);
        return;
    }
    let params_line = format!("   :params ({params_inline})");
    if params_line.len() <= WIDTH {
        out.push_str(&params_line);
    } else {
        out.push_str("   :params (");
        for (i, p) in params.iter().enumerate() {
            if i > 0 {
                out.push_str("\n            ");
            }
            out.push_str(p);
        }
        out.push(')');
    }
    out.push_str("\n   ");
    out.push_str(&tail);
}

/// Assemble the complete manifest string. Formatting is byte-pinned by the
/// golden snapshot.
pub fn render_manifest(
    crate_name: &str,
    crate_version: &str,
    prefix: &str,
    on_dump: Option<&str>,
    handles: &[&HandleMeta],
    fns: &[&FnMeta],
) -> String {
    let mut out = String::with_capacity(4096);
    out.push_str("(:rulisp-manifest\n :schema 1\n :abi ");
    out.push_str(&crate::ABI_VERSION.to_string());
    out.push_str("\n :crate \"");
    out.push_str(crate_name);
    out.push_str("\"\n :crate-version \"");
    out.push_str(crate_version);
    // enhancement key (docs/stability.md §7): pre-0.5 loaders ignore it
    out.push_str("\"\n :rulisp-version \"");
    out.push_str(crate::RULISP_VERSION);
    out.push_str("\"\n :target \"");
    out.push_str(TARGET);
    out.push_str("\"\n :prefix \"");
    out.push_str(prefix);
    out.push('"');
    // wire-additive since 0.4 (BOUNDARY §10): pre-0.4 loaders ignore it
    if let Some(sym) = on_dump {
        out.push_str("\n :on-dump \"");
        out.push_str(sym);
        out.push('"');
    }
    out.push_str("\n :errors (");
    let mut seen: Vec<&str> = Vec::new();
    for f in fns {
        if let Some(e) = f.error {
            if e != "Error" && !seen.contains(&e) {
                seen.push(e);
            }
        }
    }
    for (i, e) in seen.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        out.push('"');
        out.push_str(e);
        out.push('"');
    }
    out.push_str(")\n :handles\n (");
    for (i, h) in handles.iter().enumerate() {
        if i > 0 {
            out.push_str("\n  ");
        }
        out.push_str("(:handle :rust-name \"");
        out.push_str(h.rust_name);
        out.push_str("\" :lisp-name \"");
        out.push_str(h.lisp_name);
        out.push_str("\" :free \"");
        out.push_str(h.free_symbol);
        out.push_str("\")");
    }
    out.push_str(")\n :functions\n (");
    for (i, f) in fns.iter().enumerate() {
        if i > 0 {
            out.push_str("\n  ");
        }
        render_fn(f, &mut out);
    }
    out.push_str("))\n");
    out
}
