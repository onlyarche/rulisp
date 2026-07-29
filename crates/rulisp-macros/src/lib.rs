//! Proc-macros for rulisp glue crates.
//!
//! The generated shims are pinned by the hand-written ABI oracle in
//! `tests/m1-handwritten/` and the manifest formatting by the golden
//! snapshot in `tests/golden/` (byte-identity gate, DESIGN.md §8 M3).

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::{format_ident, quote};
use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::{
    parse_macro_input, Error, FnArg, GenericArgument, Ident, ImplItem, ItemFn, ItemImpl,
    ItemStruct, LitStr, Pat, Path, PathArguments, ReturnType, Token, Type,
};

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------

fn crate_name() -> String {
    std::env::var("CARGO_PKG_NAME").expect("CARGO_PKG_NAME not set (run under cargo)")
}

fn crate_prefix() -> String {
    format!("{}_rulisp_", crate_name().replace('-', "_"))
}

fn camel_to_snake(s: &str) -> String {
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if ch.is_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.extend(ch.to_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

fn snake_to_kebab(s: &str) -> String {
    s.replace('_', "-")
}

// ---------------------------------------------------------------------------
// Type classification (the closed v1 vocabulary)
// ---------------------------------------------------------------------------

const SCALARS: &[(&str, &str)] = &[
    ("i8", ":i8"),
    ("i16", ":i16"),
    ("i32", ":i32"),
    ("i64", ":i64"),
    ("u8", ":u8"),
    ("u16", ":u16"),
    ("u32", ":u32"),
    ("u64", ":u64"),
    ("f32", ":f32"),
    ("f64", ":f64"),
];

enum PTy {
    Scalar { tok: &'static str, ty: Type },
    Bool,
    StrRef,
    BytesRef,
    HandleRef(Path),
    Callback { param_toks: Vec<&'static str> },
    StoredCallback { param_toks: Vec<&'static str> },
    OptionScalar { tok: &'static str, ty: Type },
    OptionStr,
    OptionBytes,
    VecScalar { tok: &'static str, ty: Type },
}

fn unsupported(span: proc_macro2::Span) -> Error {
    Error::new(
        span,
        "rulisp: unsupported type for export — accepted: i8..i64, u8..u64, f32, f64, bool, \
         &str, &[u8], &[scalar], Option of these, &HandleType, Callback/StoredCallback; \
         String/Vec<u8>/Vec<scalar>/Option/handle returns; and Result thereof \
         (DESIGN.md §5 type vocabulary; Option<bool> is rejected — Lisp nil is ambiguous)",
    )
}

fn classify_param(ty: &Type) -> Result<PTy, Error> {
    match ty {
        Type::Reference(r) => {
            if r.mutability.is_some() {
                return Err(Error::new(
                    ty.span(),
                    "rulisp: &mut parameters are not supported (v1) — use interior \
                     mutability (Mutex/RwLock/atomics) inside the handle type",
                ));
            }
            match &*r.elem {
                Type::Path(p) if p.path.is_ident("str") => Ok(PTy::StrRef),
                Type::Slice(s) => match &*s.elem {
                    Type::Path(p) if p.path.is_ident("u8") => Ok(PTy::BytesRef),
                    Type::Path(p) => {
                        let name = p.path.segments.last().unwrap().ident.to_string();
                        match SCALARS.iter().find(|(r, _)| *r == name) {
                            Some((_, tok)) => Ok(PTy::VecScalar {
                                tok,
                                ty: (*s.elem).clone(),
                            }),
                            None => Err(unsupported(s.elem.span())),
                        }
                    }
                    other => Err(unsupported(other.span())),
                },
                Type::Path(p) => Ok(PTy::HandleRef(p.path.clone())),
                other => Err(unsupported(other.span())),
            }
        }
        Type::Path(p) => {
            let seg = p.path.segments.last().ok_or_else(|| unsupported(ty.span()))?;
            let name = seg.ident.to_string();
            if let Some((_, tok)) = SCALARS.iter().find(|(r, _)| *r == name) {
                return Ok(PTy::Scalar {
                    tok,
                    ty: ty.clone(),
                });
            }
            if name == "bool" {
                return Ok(PTy::Bool);
            }
            if name == "Callback" {
                return classify_callback(seg, ty.span(), false);
            }
            if name == "StoredCallback" {
                return classify_callback(seg, ty.span(), true);
            }
            if name == "Option" {
                let PathArguments::AngleBracketed(args) = &seg.arguments else {
                    return Err(unsupported(ty.span()));
                };
                let Some(GenericArgument::Type(inner)) = args.args.first() else {
                    return Err(unsupported(ty.span()));
                };
                return match classify_param(inner)? {
                    PTy::Scalar { tok, ty } => Ok(PTy::OptionScalar { tok, ty }),
                    PTy::StrRef => Ok(PTy::OptionStr),
                    PTy::BytesRef => Ok(PTy::OptionBytes),
                    PTy::Bool => Err(Error::new(
                        inner.span(),
                        "rulisp: Option<bool> is rejected — Lisp nil cannot \
                         distinguish None from Some(false); use Option<i8>",
                    )),
                    _ => Err(unsupported(inner.span())),
                };
            }
            Err(unsupported(ty.span()))
        }
        other => Err(unsupported(other.span())),
    }
}

fn classify_callback(
    seg: &syn::PathSegment,
    span: proc_macro2::Span,
    stored: bool,
) -> Result<PTy, Error> {
    let PathArguments::AngleBracketed(args) = &seg.arguments else {
        return Err(unsupported(span));
    };
    let tys: Vec<&Type> = args
        .args
        .iter()
        .filter_map(|a| match a {
            GenericArgument::Type(t) => Some(t),
            _ => None,
        })
        .collect();
    // StoredCallback<A> defaults R to (); both accept an explicit R too
    let (tuple, result) = match tys.as_slice() {
        [tuple] if stored => (tuple, None),
        [tuple, result] => (tuple, Some(result)),
        _ => return Err(unsupported(span)),
    };
    let Type::Tuple(t) = *tuple else {
        return Err(unsupported(span));
    };
    if let Some(result) = result {
        if !matches!(*result, Type::Tuple(rt) if rt.elems.is_empty()) {
            return Err(Error::new(
                span,
                "rulisp: callbacks must return () — Callback<(...), ()>",
            ));
        }
    }
    let mut param_toks = Vec::new();
    for elem in &t.elems {
        match classify_param(elem)? {
            PTy::StrRef => param_toks.push(":string"),
            PTy::Scalar { tok, .. } => param_toks.push(tok),
            PTy::Bool => param_toks.push(":bool"),
            _ => {
                return Err(Error::new(
                    elem.span(),
                    "rulisp: v1 callback parameters may only be scalars or &str",
                ))
            }
        }
    }
    Ok(if stored {
        PTy::StoredCallback { param_toks }
    } else {
        PTy::Callback { param_toks }
    })
}

enum RTy {
    Unit,
    Scalar { tok: &'static str, ty: Type },
    Bool,
    Str,
    Bytes,
    Handle(Path),
    OptionScalar { tok: &'static str, ty: Type },
    OptionStr,
    OptionBytes,
    VecScalar { tok: &'static str, ty: Type },
}

/// Classify a *success* return type (after unwrapping Result).
fn classify_result(ty: Option<&Type>, ctor: bool) -> Result<RTy, Error> {
    let Some(ty) = ty else { return Ok(RTy::Unit) };
    match ty {
        Type::Tuple(t) if t.elems.is_empty() => Ok(RTy::Unit),
        Type::Path(p) => {
            let seg = p.path.segments.last().ok_or_else(|| unsupported(ty.span()))?;
            let name = seg.ident.to_string();
            if let Some((_, tok)) = SCALARS.iter().find(|(r, _)| *r == name) {
                return Ok(RTy::Scalar {
                    tok,
                    ty: ty.clone(),
                });
            }
            match name.as_str() {
                "bool" => Ok(RTy::Bool),
                "String" => Ok(RTy::Str),
                "Vec" => {
                    if let PathArguments::AngleBracketed(args) = &seg.arguments {
                        if let Some(GenericArgument::Type(elem @ Type::Path(ep))) =
                            args.args.first()
                        {
                            if args.args.len() == 1 {
                                if ep.path.is_ident("u8") {
                                    return Ok(RTy::Bytes);
                                }
                                let ename =
                                    ep.path.segments.last().unwrap().ident.to_string();
                                if let Some((_, tok)) =
                                    SCALARS.iter().find(|(r, _)| *r == ename)
                                {
                                    return Ok(RTy::VecScalar {
                                        tok,
                                        ty: elem.clone(),
                                    });
                                }
                            }
                        }
                    }
                    Err(unsupported(ty.span()))
                }
                "Option" => {
                    let PathArguments::AngleBracketed(args) = &seg.arguments else {
                        return Err(unsupported(ty.span()));
                    };
                    let Some(GenericArgument::Type(inner)) = args.args.first() else {
                        return Err(unsupported(ty.span()));
                    };
                    match classify_result(Some(inner), false)? {
                        RTy::Scalar { tok, ty } => Ok(RTy::OptionScalar { tok, ty }),
                        RTy::Str => Ok(RTy::OptionStr),
                        RTy::Bytes => Ok(RTy::OptionBytes),
                        RTy::Bool => Err(Error::new(
                            inner.span(),
                            "rulisp: Option<bool> is rejected — Lisp nil cannot \
                             distinguish None from Some(false); use Option<i8>",
                        )),
                        _ => Err(unsupported(inner.span())),
                    }
                }
                _ if ctor => Ok(RTy::Handle(p.path.clone())),
                _ => Err(Error::new(
                    ty.span(),
                    "rulisp: handle-returning functions must be constructors — \
                     mark the method with #[rulisp(constructor)]",
                )),
            }
        }
        other => Err(unsupported(other.span())),
    }
}

/// Split `Result<T, E>` into (T, Some(E-name)); anything else is infallible.
fn split_result(rt: &ReturnType) -> (Option<Type>, Option<String>) {
    let ReturnType::Type(_, ty) = rt else {
        return (None, None);
    };
    if let Type::Path(p) = &**ty {
        if let Some(seg) = p.path.segments.last() {
            if seg.ident == "Result" {
                if let PathArguments::AngleBracketed(args) = &seg.arguments {
                    let tys: Vec<&Type> = args
                        .args
                        .iter()
                        .filter_map(|a| match a {
                            GenericArgument::Type(t) => Some(t),
                            _ => None,
                        })
                        .collect();
                    if let [ok, err] = tys.as_slice() {
                        let err_name = match err {
                            Type::Path(ep) => ep
                                .path
                                .segments
                                .last()
                                .map(|s| s.ident.to_string())
                                .unwrap_or_default(),
                            _ => String::new(),
                        };
                        return (Some((*ok).clone()), Some(err_name));
                    }
                }
            }
        }
    }
    (Some((**ty).clone()), None)
}

// ---------------------------------------------------------------------------
// Shim + metadata generation for one function
// ---------------------------------------------------------------------------

struct ExportedFn {
    /// e.g. "WordBag::new" or "add"
    rust_name: String,
    lisp_name: String,
    /// unprefixed symbol, e.g. "word_bag_new"
    symbol: String,
    /// (manifest param name, classified type)
    params: Vec<(String, PTy)>,
    result: RTy,
    error: Option<String>,
    /// how the shim invokes the user fn, given arg expressions
    call: CallKind,
}

enum CallKind {
    Free(Ident),
    Method { method: Ident },
    Ctor { self_ty: Path, method: Ident },
}

fn cb_ffi_types(param_toks: &[&'static str]) -> TokenStream2 {
    let mut cb_ffi = TokenStream2::new();
    for tok in param_toks {
        match *tok {
            ":string" => cb_ffi.extend(quote! { *const u8, usize, }),
            ":bool" | ":u8" => cb_ffi.extend(quote! { u8, }),
            ":i8" => cb_ffi.extend(quote! { i8, }),
            ":i16" => cb_ffi.extend(quote! { i16, }),
            ":i32" => cb_ffi.extend(quote! { i32, }),
            ":i64" => cb_ffi.extend(quote! { i64, }),
            ":u16" => cb_ffi.extend(quote! { u16, }),
            ":u32" => cb_ffi.extend(quote! { u32, }),
            ":u64" => cb_ffi.extend(quote! { u64, }),
            ":f32" => cb_ffi.extend(quote! { f32, }),
            ":f64" => cb_ffi.extend(quote! { f64, }),
            _ => unreachable!(),
        }
    }
    cb_ffi
}

fn gen_fn(f: &ExportedFn) -> Result<TokenStream2, Error> {
    let prefix = crate_prefix();
    let shim_ident = format_ident!("{}{}", prefix, f.symbol);

    let mut extern_params = TokenStream2::new(); // shim signature params
    let mut preludes = TokenStream2::new(); // arg conversions
    let mut call_args: Vec<TokenStream2> = Vec::new(); // user-fn arguments
    let mut self_expr: Option<TokenStream2> = None;
    let mut has_callback = false;

    for (name, pty) in &f.params {
        let is_self = name == "self";
        let ident = if is_self {
            format_ident!("this")
        } else {
            format_ident!("{}", name)
        };
        match pty {
            PTy::Scalar { ty, .. } => {
                extern_params.extend(quote! { #ident: #ty, });
                call_args.push(quote! { #ident });
            }
            PTy::Bool => {
                extern_params.extend(quote! { #ident: u8, });
                call_args.push(quote! { (#ident != 0) });
            }
            PTy::StrRef => {
                let ptr = format_ident!("{}_ptr", ident);
                let len = format_ident!("{}_len", ident);
                extern_params.extend(quote! { #ptr: *const u8, #len: usize, });
                preludes.extend(quote! {
                    let #ident = match unsafe { ::rulisp::runtime::str_arg(#ptr, #len) } {
                        Ok(s) => s,
                        Err(status) => return status,
                    };
                });
                call_args.push(quote! { #ident });
            }
            PTy::BytesRef => {
                let ptr = format_ident!("{}_ptr", ident);
                let len = format_ident!("{}_len", ident);
                extern_params.extend(quote! { #ptr: *const u8, #len: usize, });
                preludes.extend(quote! {
                    let #ident: &[u8] =
                        unsafe { ::rulisp::runtime::bytes_arg(#ptr, #len) };
                });
                call_args.push(quote! { #ident });
            }
            PTy::VecScalar { ty, .. } => {
                let ptr = format_ident!("{}_ptr", ident);
                let len = format_ident!("{}_len", ident);
                extern_params.extend(quote! { #ptr: *const #ty, #len: usize, });
                preludes.extend(quote! {
                    let #ident: &[#ty] =
                        unsafe { ::rulisp::runtime::slice_arg(#ptr, #len) };
                });
                call_args.push(quote! { #ident });
            }
            PTy::OptionScalar { ty, .. } => {
                let present = format_ident!("{}_present", ident);
                extern_params.extend(quote! { #present: u8, #ident: #ty, });
                preludes.extend(quote! {
                    let #ident = if #present != 0 { Some(#ident) } else { None };
                });
                call_args.push(quote! { #ident });
            }
            PTy::OptionStr => {
                let present = format_ident!("{}_present", ident);
                let ptr = format_ident!("{}_ptr", ident);
                let len = format_ident!("{}_len", ident);
                extern_params.extend(quote! {
                    #present: u8, #ptr: *const u8, #len: usize,
                });
                preludes.extend(quote! {
                    let #ident = if #present != 0 {
                        match unsafe { ::rulisp::runtime::str_arg(#ptr, #len) } {
                            Ok(s) => Some(s),
                            Err(status) => return status,
                        }
                    } else {
                        None
                    };
                });
                call_args.push(quote! { #ident });
            }
            PTy::OptionBytes => {
                let present = format_ident!("{}_present", ident);
                let ptr = format_ident!("{}_ptr", ident);
                let len = format_ident!("{}_len", ident);
                extern_params.extend(quote! {
                    #present: u8, #ptr: *const u8, #len: usize,
                });
                preludes.extend(quote! {
                    let #ident = if #present != 0 {
                        Some(unsafe { ::rulisp::runtime::bytes_arg(#ptr, #len) })
                    } else {
                        None
                    };
                });
                call_args.push(quote! { #ident });
            }
            PTy::HandleRef(path) => {
                extern_params.extend(quote! { #ident: *const ::std::ffi::c_void, });
                preludes.extend(quote! {
                    let #ident: &#path = unsafe { ::rulisp::runtime::handle_ref(#ident) };
                });
                if is_self {
                    self_expr = Some(quote! { #ident });
                } else {
                    call_args.push(quote! { #ident });
                }
            }
            PTy::Callback { param_toks } => {
                has_callback = true;
                let userdata = format_ident!("{}_userdata", ident);
                let cb_ffi = cb_ffi_types(param_toks);
                extern_params.extend(quote! {
                    #ident: unsafe extern "C" fn(u64, #cb_ffi) -> i32,
                    #userdata: u64,
                });
                preludes.extend(quote! {
                    let #ident = unsafe {
                        ::rulisp::Callback::from_raw(#ident as *const (), #userdata)
                    };
                });
                call_args.push(quote! { #ident });
            }
            PTy::StoredCallback { param_toks } => {
                // same two ABI values as Callback — userdata carries the
                // registry id; no tunnel involvement (errors are warned on
                // the Lisp side and reported as plain CallbackError)
                let userdata = format_ident!("{}_userdata", ident);
                let cb_ffi = cb_ffi_types(param_toks);
                extern_params.extend(quote! {
                    #ident: unsafe extern "C" fn(u64, #cb_ffi) -> i32,
                    #userdata: u64,
                });
                preludes.extend(quote! {
                    let #ident = unsafe {
                        ::rulisp::StoredCallback::from_raw(#ident as usize, #userdata)
                    };
                });
                call_args.push(quote! { #ident });
            }
        }
    }

    let call = match &f.call {
        CallKind::Free(ident) => quote! { #ident(#(#call_args),*) },
        CallKind::Method { method, .. } => {
            let recv = self_expr.ok_or_else(|| {
                Error::new(method.span(), "rulisp: methods must take &self")
            })?;
            quote! { #recv.#method(#(#call_args),*) }
        }
        CallKind::Ctor { self_ty, method } => quote! { <#self_ty>::#method(#(#call_args),*) },
    };

    // success plumbing: out-params + writer
    let (out_params, write_ok) = match &f.result {
        RTy::Unit => (quote! {}, quote! { let _ = __v; }),
        RTy::Scalar { ty, .. } => (
            quote! { out: *mut #ty, },
            quote! { unsafe { *out = __v }; },
        ),
        RTy::Bool => (
            quote! { out: *mut u8, },
            quote! { unsafe { *out = if __v { 1 } else { 0 } }; },
        ),
        RTy::Str => (
            quote! { out_ptr: *mut *mut u8, out_len: *mut usize, },
            quote! {
                let (__p, __l) = ::rulisp::runtime::string_into_raw(__v);
                unsafe {
                    *out_ptr = __p;
                    *out_len = __l;
                }
            },
        ),
        RTy::Bytes => (
            quote! { out_ptr: *mut *mut u8, out_len: *mut usize, },
            quote! {
                let (__p, __l) = ::rulisp::runtime::bytes_into_raw(__v);
                unsafe {
                    *out_ptr = __p;
                    *out_len = __l;
                }
            },
        ),
        RTy::Handle(_) => (
            quote! { out: *mut *mut ::std::ffi::c_void, },
            quote! { unsafe { *out = ::rulisp::runtime::handle_new(__v) }; },
        ),
        RTy::VecScalar { ty, .. } => (
            quote! { out_ptr: *mut *mut #ty, out_len: *mut usize, },
            quote! {
                let (__p, __l) = ::rulisp::runtime::vec_into_raw(__v);
                unsafe {
                    *out_ptr = __p;
                    *out_len = __l;
                }
            },
        ),
        RTy::OptionScalar { ty, .. } => (
            quote! { some_out: *mut u8, out: *mut #ty, },
            quote! {
                match __v {
                    Some(__x) => unsafe {
                        *some_out = 1;
                        *out = __x;
                    },
                    None => unsafe { *some_out = 0 },
                }
            },
        ),
        RTy::OptionStr => (
            quote! { some_out: *mut u8, out_ptr: *mut *mut u8, out_len: *mut usize, },
            quote! {
                match __v {
                    Some(__s) => {
                        let (__p, __l) = ::rulisp::runtime::string_into_raw(__s);
                        unsafe {
                            *some_out = 1;
                            *out_ptr = __p;
                            *out_len = __l;
                        }
                    }
                    None => unsafe { *some_out = 0 },
                }
            },
        ),
        RTy::OptionBytes => (
            quote! { some_out: *mut u8, out_ptr: *mut *mut u8, out_len: *mut usize, },
            quote! {
                match __v {
                    Some(__b) => {
                        let (__p, __l) = ::rulisp::runtime::bytes_into_raw(__b);
                        unsafe {
                            *some_out = 1;
                            *out_ptr = __p;
                            *out_len = __l;
                        }
                    }
                    None => unsafe { *some_out = 0 },
                }
            },
        ),
    };

    let clear_tunnel = if has_callback {
        quote! { ::rulisp::runtime::clear_callback_tunnel(); }
    } else {
        quote! {}
    };
    let tunnel_check = if has_callback {
        quote! {
            if ::rulisp::runtime::callback_tunnel() {
                return ::rulisp::runtime::STATUS_CB_ERR;
            }
        }
    } else {
        quote! {}
    };

    let body = match &f.error {
        None => quote! {
            let __v = #call;
            #write_ok
            ::rulisp::runtime::STATUS_OK
        },
        Some(err_name) => quote! {
            match #call {
                Ok(__v) => {
                    #write_ok
                    ::rulisp::runtime::STATUS_OK
                }
                Err(__e) => {
                    #tunnel_check
                    ::rulisp::runtime::set_last_error(#err_name, &__e.to_string());
                    ::rulisp::runtime::STATUS_ERR
                }
            }
        },
    };

    Ok(quote! {
        #[no_mangle]
        pub unsafe extern "C" fn #shim_ident(#extern_params #out_params) -> i32 {
            ::rulisp::runtime::shim(|| {
                #clear_tunnel
                #preludes
                #body
            })
        }
    })
}

fn gen_meta_const(f: &ExportedFn) -> TokenStream2 {
    let rust_name = &f.rust_name;
    let lisp_name = &f.lisp_name;
    let symbol = &f.symbol;
    let params: Vec<TokenStream2> = f
        .params
        .iter()
        .map(|(name, pty)| {
            let ty = match pty {
                PTy::Scalar { tok, .. } => quote! { ::rulisp::runtime::ParamTy::Scalar(#tok) },
                PTy::Bool => quote! { ::rulisp::runtime::ParamTy::Scalar(":bool") },
                PTy::StrRef => quote! { ::rulisp::runtime::ParamTy::Str },
                PTy::BytesRef => quote! { ::rulisp::runtime::ParamTy::Bytes },
                PTy::HandleRef(p) => quote! {
                    ::rulisp::runtime::ParamTy::Handle(
                        <#p as ::rulisp::HandleType>::RUST_NAME)
                },
                PTy::Callback { param_toks } => quote! {
                    ::rulisp::runtime::ParamTy::Callback {
                        params: &[#(::rulisp::runtime::ParamTy::Scalar(#param_toks)),*],
                        result: ":unit",
                    }
                },
                PTy::StoredCallback { param_toks } => quote! {
                    ::rulisp::runtime::ParamTy::StoredCallback {
                        params: &[#(::rulisp::runtime::ParamTy::Scalar(#param_toks)),*],
                        result: ":unit",
                    }
                },
                PTy::OptionScalar { tok, .. } => quote! {
                    ::rulisp::runtime::ParamTy::Option(
                        &::rulisp::runtime::ParamTy::Scalar(#tok))
                },
                PTy::OptionStr => quote! {
                    ::rulisp::runtime::ParamTy::Option(&::rulisp::runtime::ParamTy::Str)
                },
                PTy::OptionBytes => quote! {
                    ::rulisp::runtime::ParamTy::Option(&::rulisp::runtime::ParamTy::Bytes)
                },
                PTy::VecScalar { tok, .. } => quote! {
                    ::rulisp::runtime::ParamTy::Vec(#tok)
                },
            };
            quote! { ::rulisp::runtime::ParamMeta { name: #name, ty: #ty } }
        })
        .collect();
    let result = match &f.result {
        RTy::Unit => quote! { ::rulisp::runtime::ResultTy::Unit },
        RTy::Scalar { tok, .. } => quote! { ::rulisp::runtime::ResultTy::Scalar(#tok) },
        RTy::Bool => quote! { ::rulisp::runtime::ResultTy::Scalar(":bool") },
        RTy::Str => quote! { ::rulisp::runtime::ResultTy::Str },
        RTy::Bytes => quote! { ::rulisp::runtime::ResultTy::Bytes },
        RTy::Handle(p) => quote! {
            ::rulisp::runtime::ResultTy::Handle(<#p as ::rulisp::HandleType>::RUST_NAME)
        },
        RTy::OptionScalar { tok, .. } => quote! {
            ::rulisp::runtime::ResultTy::Option(
                &::rulisp::runtime::ResultTy::Scalar(#tok))
        },
        RTy::OptionStr => quote! {
            ::rulisp::runtime::ResultTy::Option(&::rulisp::runtime::ResultTy::Str)
        },
        RTy::OptionBytes => quote! {
            ::rulisp::runtime::ResultTy::Option(&::rulisp::runtime::ResultTy::Bytes)
        },
        RTy::VecScalar { tok, .. } => quote! {
            ::rulisp::runtime::ResultTy::Vec(#tok)
        },
    };
    let error = match &f.error {
        None => quote! { None },
        Some(e) => quote! { Some(#e) },
    };
    quote! {
        ::rulisp::runtime::FnMeta {
            rust_name: #rust_name,
            lisp_name: #lisp_name,
            symbol: #symbol,
            params: &[#(#params),*],
            result: #result,
            error: #error,
        }
    }
}

/// Note: Callback params render as Scalar(tok) in the meta, which prints
/// ":string" identically to ParamTy::Str for callback parameter lists.
fn meta_const_ident(name: &str) -> Ident {
    format_ident!("__RULISP_META_{}", name.to_uppercase())
}

// ---------------------------------------------------------------------------
// #[rulisp::handle]
// ---------------------------------------------------------------------------

#[proc_macro_attribute]
pub fn handle(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let item = parse_macro_input!(item as ItemStruct);
    let ty = &item.ident;
    let ty_str = ty.to_string();
    let snake = camel_to_snake(&ty_str);
    let kebab = snake_to_kebab(&snake);
    let free_symbol = format!("{snake}_free");
    let free_ident = format_ident!("{}{}", crate_prefix(), free_symbol);
    let swallow_msg = format!(
        "rulisp[{}]: panic in {} (swallowed)",
        crate_name(),
        free_symbol
    );

    // impl HandleType enforces Send + Sync + 'static (supertrait bounds):
    // a non-thread-safe handle type is a compile error, as required —
    // finalizers may drop on any thread and same-handle calls may overlap.
    quote! {
        #item

        impl ::rulisp::HandleType for #ty {
            const RUST_NAME: &'static str = #ty_str;
            const LISP_NAME: &'static str = #kebab;
        }

        impl #ty {
            #[doc(hidden)]
            pub const __RULISP_HANDLE_META: ::rulisp::runtime::HandleMeta =
                ::rulisp::runtime::HandleMeta {
                    rust_name: #ty_str,
                    lisp_name: #kebab,
                    free_symbol: #free_symbol,
                };
        }

        #[no_mangle]
        pub unsafe extern "C" fn #free_ident(this: *mut ::std::ffi::c_void) {
            let r = ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| unsafe {
                ::rulisp::runtime::handle_free::<#ty>(this)
            }));
            if r.is_err() {
                eprintln!(#swallow_msg);
            }
        }
    }
    .into()
}

// ---------------------------------------------------------------------------
// #[rulisp::export]
// ---------------------------------------------------------------------------

#[proc_macro_attribute]
pub fn export(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let item2: TokenStream2 = item.clone().into();
    if let Ok(f) = syn::parse::<ItemFn>(item.clone()) {
        match export_free_fn(&f) {
            Ok(extra) => quote! { #item2 #extra }.into(),
            Err(e) => e.to_compile_error().into(),
        }
    } else if let Ok(i) = syn::parse::<ItemImpl>(item) {
        match export_impl(i) {
            Ok(ts) => ts.into(),
            Err(e) => e.to_compile_error().into(),
        }
    } else {
        Error::new(
            proc_macro2::Span::call_site(),
            "rulisp: #[rulisp::export] goes on a fn or an impl block",
        )
        .to_compile_error()
        .into()
    }
}

fn fn_params(sig: &syn::Signature, self_ty: Option<&Path>) -> Result<Vec<(String, PTy)>, Error> {
    let mut params = Vec::new();
    for input in &sig.inputs {
        match input {
            FnArg::Receiver(r) => {
                if r.mutability.is_some() {
                    return Err(Error::new(
                        r.span(),
                        "rulisp: &mut self methods are not supported (v1) — use interior \
                         mutability (Mutex/RwLock/atomics)",
                    ));
                }
                if r.reference.is_none() {
                    return Err(Error::new(
                        r.span(),
                        "rulisp: by-value self is not supported — methods take &self",
                    ));
                }
                let self_ty = self_ty.ok_or_else(|| {
                    Error::new(r.span(), "rulisp: self outside an exported impl block")
                })?;
                params.push(("self".to_string(), PTy::HandleRef(self_ty.clone())));
            }
            FnArg::Typed(t) => {
                let name = match &*t.pat {
                    Pat::Ident(p) => p.ident.to_string(),
                    other => {
                        return Err(Error::new(
                            other.span(),
                            "rulisp: parameter patterns are not supported — use plain names",
                        ))
                    }
                };
                params.push((name, classify_param(&t.ty)?));
            }
        }
    }
    Ok(params)
}

fn export_free_fn(f: &ItemFn) -> Result<TokenStream2, Error> {
    let name = f.sig.ident.to_string();
    let (ok_ty, err) = split_result(&f.sig.output);
    let exported = ExportedFn {
        rust_name: name.clone(),
        lisp_name: snake_to_kebab(&name),
        symbol: name.clone(),
        params: fn_params(&f.sig, None)?,
        result: classify_result(ok_ty.as_ref(), false)?,
        error: err,
        call: CallKind::Free(f.sig.ident.clone()),
    };
    let shim = gen_fn(&exported)?;
    let meta = gen_meta_const(&exported);
    let meta_ident = meta_const_ident(&name);
    Ok(quote! {
        #shim
        #[doc(hidden)]
        pub const #meta_ident: ::rulisp::runtime::FnMeta = #meta;
    })
}

fn export_impl(mut i: ItemImpl) -> Result<TokenStream2, Error> {
    let Type::Path(self_path) = &*i.self_ty else {
        return Err(Error::new(
            i.self_ty.span(),
            "rulisp: exported impl must be on a plain type",
        ));
    };
    let self_ty = self_path.path.clone();
    let ty_ident = self_ty
        .segments
        .last()
        .ok_or_else(|| Error::new(self_ty.span(), "rulisp: bad impl type"))?
        .ident
        .to_string();
    let snake = camel_to_snake(&ty_ident);
    let kebab = snake_to_kebab(&snake);

    let mut extra = TokenStream2::new();
    let mut metas = TokenStream2::new();

    for item in &mut i.items {
        let ImplItem::Fn(m) = item else { continue };
        // detect + strip #[rulisp(constructor)]
        let mut is_ctor = false;
        m.attrs.retain(|a| {
            if a.path().is_ident("rulisp") {
                let mut ctor = false;
                let _ = a.parse_nested_meta(|meta| {
                    if meta.path.is_ident("constructor") {
                        ctor = true;
                    }
                    Ok(())
                });
                if ctor {
                    is_ctor = true;
                    return false; // strip
                }
            }
            true
        });

        let method = m.sig.ident.clone();
        let mname = method.to_string();
        let (ok_ty, err) = split_result(&m.sig.output);
        let exported = ExportedFn {
            rust_name: format!("{ty_ident}::{mname}"),
            lisp_name: if is_ctor {
                format!("make-{kebab}")
            } else {
                format!("{}-{}", kebab, snake_to_kebab(&mname))
            },
            symbol: format!("{snake}_{mname}"),
            params: fn_params(&m.sig, Some(&self_ty))?,
            result: classify_result(ok_ty.as_ref(), is_ctor)?,
            error: err,
            call: if is_ctor {
                CallKind::Ctor {
                    self_ty: self_ty.clone(),
                    method,
                }
            } else {
                CallKind::Method { method }
            },
        };
        extra.extend(gen_fn(&exported)?);
        let meta = gen_meta_const(&exported);
        let meta_ident = meta_const_ident(&mname);
        metas.extend(quote! {
            #[doc(hidden)]
            pub const #meta_ident: ::rulisp::runtime::FnMeta = #meta;
        });
    }

    Ok(quote! {
        #i
        impl #self_ty { #metas }
        #extra
    })
}

// ---------------------------------------------------------------------------
// rulisp::module! { name: "...", handles: [...], fns: [...] }
// ---------------------------------------------------------------------------

struct ModuleInput {
    name: LitStr,
    handles: Vec<Path>,
    fns: Vec<Path>,
}

impl Parse for ModuleInput {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let mut name = None;
        let mut handles = None;
        let mut fns = None;
        while !input.is_empty() {
            let key: Ident = input.parse()?;
            input.parse::<Token![:]>()?;
            match key.to_string().as_str() {
                "name" => name = Some(input.parse::<LitStr>()?),
                "handles" => {
                    let content;
                    syn::bracketed!(content in input);
                    handles = Some(
                        Punctuated::<Path, Token![,]>::parse_terminated(&content)?
                            .into_iter()
                            .collect(),
                    );
                }
                "fns" => {
                    let content;
                    syn::bracketed!(content in input);
                    fns = Some(
                        Punctuated::<Path, Token![,]>::parse_terminated(&content)?
                            .into_iter()
                            .collect(),
                    );
                }
                other => {
                    return Err(Error::new(
                        key.span(),
                        format!("rulisp: unknown module! key `{other}` (expected name/handles/fns)"),
                    ))
                }
            }
            if input.peek(Token![,]) {
                input.parse::<Token![,]>()?;
            }
        }
        Ok(ModuleInput {
            name: name.ok_or_else(|| input.error("rulisp: module! needs name:"))?,
            handles: handles.ok_or_else(|| input.error("rulisp: module! needs handles: []"))?,
            fns: fns.ok_or_else(|| input.error("rulisp: module! needs fns: []"))?,
        })
    }
}

/// `fns:` entries are const paths: `greet` → `__RULISP_META_GREET`,
/// `WordBag::new` → `WordBag::__RULISP_META_NEW`. A typo is a compile error
/// (unresolved const) — the registry is explicit by design.
fn meta_path(p: &Path) -> Result<TokenStream2, Error> {
    let segs: Vec<&Ident> = p.segments.iter().map(|s| &s.ident).collect();
    match segs.as_slice() {
        [f] => {
            let c = meta_const_ident(&f.to_string());
            Ok(quote! { #c })
        }
        [ty, m] => {
            let c = meta_const_ident(&m.to_string());
            Ok(quote! { #ty::#c })
        }
        _ => Err(Error::new(
            p.span(),
            "rulisp: fns entries are `fn_name` or `Type::method`",
        )),
    }
}

#[proc_macro]
pub fn module(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as ModuleInput);
    let name = input.name.value();
    let pkg = crate_name();
    if name != pkg {
        return Error::new(
            input.name.span(),
            format!("rulisp: module! name {name:?} must equal the cargo package name {pkg:?}"),
        )
        .to_compile_error()
        .into();
    }
    let prefix = crate_prefix();

    let handle_metas: Vec<TokenStream2> = input
        .handles
        .iter()
        .map(|h| quote! { &#h::__RULISP_HANDLE_META })
        .collect();
    let fn_metas: Vec<TokenStream2> = match input.fns.iter().map(meta_path).collect() {
        Ok(v) => v,
        Err(e) => return e.to_compile_error().into(),
    };

    let abi_ident = format_ident!("{}abi_version", prefix);
    let manifest_ident = format_ident!("{}manifest", prefix);
    let last_error_ident = format_ident!("{}last_error", prefix);
    let dealloc_ident = format_ident!("{}dealloc", prefix);

    quote! {
        #[doc(hidden)]
        pub fn __rulisp_manifest_str() -> &'static str {
            static MANIFEST: ::std::sync::OnceLock<String> = ::std::sync::OnceLock::new();
            MANIFEST.get_or_init(|| {
                ::rulisp::runtime::render_manifest(
                    #name,
                    env!("CARGO_PKG_VERSION"),
                    #prefix,
                    &[#(#handle_metas),*],
                    &[#(&#fn_metas),*],
                )
            })
        }

        #[no_mangle]
        pub extern "C" fn #abi_ident() -> u32 {
            ::rulisp::runtime::ABI_VERSION
        }

        /// Static after first assembly: permanent borrow, caller never frees.
        #[no_mangle]
        pub unsafe extern "C" fn #manifest_ident(len: *mut usize) -> *const u8 {
            let s = __rulisp_manifest_str();
            unsafe { *len = s.len() };
            s.as_ptr()
        }

        #[no_mangle]
        pub unsafe extern "C" fn #last_error_ident(
            type_ptr: *mut *const u8,
            type_len: *mut usize,
            msg_ptr: *mut *const u8,
            msg_len: *mut usize,
        ) {
            unsafe { ::rulisp::runtime::read_last_error(type_ptr, type_len, msg_ptr, msg_len) }
        }

        #[no_mangle]
        pub unsafe extern "C" fn #dealloc_ident(ptr: *mut u8, size: usize, align: usize) {
            unsafe { ::rulisp::runtime::dealloc(ptr, size, align) }
        }
    }
    .into()
}
