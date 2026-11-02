//! Smoke test for leanjson_parse_ex and leanjson_options C ABI.

use leanjson::ffi::{leanjson_doc, leanjson_error, leanjson_free, leanjson_parse, leanjson_parse_ex};
use leanjson::options::Options;

#[test]
fn parse_ex_default_options_matches_parse() {
    let buf = b"{\"a\":1}";
    let mut err = leanjson_error::default();
    let d1: *mut leanjson_doc = unsafe { leanjson_parse(buf.as_ptr(), buf.len(), &mut err) };
    assert!(!d1.is_null());
    assert_eq!(err.code, 0);

    let opts = Options { mode: 0, max_depth: 0 };
    let mut err2 = leanjson_error::default();
    let d2: *mut leanjson_doc = unsafe { leanjson_parse_ex(buf.as_ptr(), buf.len(), &opts, &mut err2) };
    assert!(!d2.is_null());
    assert_eq!(err2.code, 0);

    unsafe { leanjson_free(d1); leanjson_free(d2); }
}

#[test]
fn parse_ex_null_opts_uses_defaults() {
    let buf = b"{}";
    let mut err = leanjson_error::default();
    let d: *mut leanjson_doc = unsafe {
        leanjson_parse_ex(buf.as_ptr(), buf.len(), std::ptr::null(), &mut err)
    };
    assert!(!d.is_null());
    assert_eq!(err.code, 0);
    unsafe { leanjson_free(d) };
}

#[test]
fn parse_ex_null_err_returns_null_on_bad_buf() {
    let opts = Options { mode: 0, max_depth: 0 };
    let d: *mut leanjson_doc = unsafe {
        leanjson_parse_ex(std::ptr::null(), 0, &opts, std::ptr::null_mut())
    };
    assert!(d.is_null());
}
