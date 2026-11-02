use std::ffi::CStr;

use leanjson::ffi::{
    leanjson_cursor, leanjson_cursor_get_i64, leanjson_doc, leanjson_free, leanjson_get_i64, leanjson_open,
    leanjson_error, leanjson_parse, leanjson_strerror,
};

#[test]
fn parse_and_free_roundtrip() {
    let json = b"{\"a\":1}";
    let mut err = leanjson_error::default();
    let doc: *mut leanjson_doc = unsafe { leanjson_parse(json.as_ptr(), json.len(), &mut err) };
    assert!(!doc.is_null());
    assert_eq!(err.code, 0);
    unsafe { leanjson_free(doc); }
}

#[test]
fn root_scalar_is_accessible_through_ffi() {
    let json = b"4";
    let mut err = leanjson_error::default();
    let doc: *mut leanjson_doc = unsafe { leanjson_parse(json.as_ptr(), json.len(), &mut err) };
    assert!(!doc.is_null());
    assert_eq!(err.code, 0);

    let mut direct = 0i64;
    let rc = unsafe { leanjson_get_i64(doc, std::ptr::null(), 0, &mut direct) };
    assert_eq!(rc, 0);
    assert_eq!(direct, 4);

    let mut cur = leanjson_cursor {
        doc: std::ptr::null(),
        idx_start: 0,
        idx_end: 0,
        _reserved0: 0,
        _reserved1: 0,
    };
    let rc = unsafe { leanjson_open(doc, std::ptr::null(), 0, &mut cur) };
    assert_eq!(rc, 0);

    let mut via_cursor = 0i64;
    let rc = unsafe { leanjson_cursor_get_i64(&cur, std::ptr::null(), 0, &mut via_cursor) };
    assert_eq!(rc, 0);
    assert_eq!(via_cursor, 4);

    unsafe { leanjson_free(doc); }
}

#[test]
fn parse_error_returns_null() {
    let bad = b"{";
    let mut err = leanjson_error::default();
    let doc = unsafe { leanjson_parse(bad.as_ptr(), bad.len(), &mut err) };
    assert!(doc.is_null());
    assert_eq!(err.code, 1); // LEANJSON_PARSE_ERROR
}

#[test]
fn parse_null_buffer_returns_invalid_arg() {
    let mut err = leanjson_error::default();
    let doc = unsafe { leanjson_parse(std::ptr::null(), 0, &mut err) };
    assert!(doc.is_null());
    assert_eq!(err.code, 7); // LEANJSON_INVALID_ARG
}

#[test]
fn free_null_is_safe() {
    unsafe { leanjson_free(std::ptr::null_mut()); }
}

#[test]
fn strerror_returns_non_empty() {
    for code in 0..=8 {
        let p = unsafe { leanjson_strerror(code) };
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(!s.is_empty(), "code {}", code);
    }
}
