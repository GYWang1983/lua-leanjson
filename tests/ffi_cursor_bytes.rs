use std::os::raw::c_int;
use std::ptr;

use leanjson::error::leanjson_err;
use leanjson::ffi::{
    leanjson_cursor, leanjson_cursor_bytes, leanjson_cursor_field, leanjson_doc, leanjson_error, leanjson_free,
    leanjson_open, leanjson_parse,
};

unsafe fn open_root(json: &[u8]) -> (*mut leanjson_doc, leanjson_cursor) {
    let mut err = leanjson_error::default();
    let doc = leanjson_parse(json.as_ptr(), json.len(), &mut err);
    assert!(!doc.is_null());
    let mut cur: leanjson_cursor = std::mem::zeroed();
    let rc = leanjson_open(doc, ptr::null(), 0, &mut cur);
    assert_eq!(rc, 0);
    (doc, cur)
}

#[test]
fn bytes_of_root_object_covers_full_json() {
    let json = br#"{"a":1,"b":[2,3]}"#;
    unsafe {
        let (doc, cur) = open_root(json);
        let mut bs: usize = 0;
        let mut be: usize = 0;
        let rc = leanjson_cursor_bytes(&cur, &mut bs, &mut be);
        assert_eq!(rc, 0);
        assert_eq!(&json[bs..be], json.as_ref());
        leanjson_free(doc);
    }
}

#[test]
fn bytes_of_string_value_is_quoted_span() {
    let json = br#"{"k":"hello"}"#;
    unsafe {
        let (doc, root) = open_root(json);
        let mut child: leanjson_cursor = std::mem::zeroed();
        let rc = leanjson_cursor_field(&root, b"k".as_ptr() as *const std::ffi::c_char, 1, &mut child);
        assert_eq!(rc, 0);
        let mut bs: usize = 0;
        let mut be: usize = 0;
        let rc = leanjson_cursor_bytes(&child, &mut bs, &mut be);
        assert_eq!(rc, 0);
        assert_eq!(&json[bs..be], br#""hello""#);
        leanjson_free(doc);
    }
}

#[test]
fn bytes_of_number_value_strips_separators() {
    let json = br#"{"k": 42 ,"x":1}"#;
    unsafe {
        let (doc, root) = open_root(json);
        let mut child: leanjson_cursor = std::mem::zeroed();
        let rc = leanjson_cursor_field(&root, b"k".as_ptr() as *const std::ffi::c_char, 1, &mut child);
        assert_eq!(rc, 0);
        let mut bs: usize = 0;
        let mut be: usize = 0;
        let rc = leanjson_cursor_bytes(&child, &mut bs, &mut be);
        assert_eq!(rc, 0);
        assert_eq!(&json[bs..be], b"42");
        leanjson_free(doc);
    }
}

#[test]
fn bytes_with_null_out_pointer_returns_invalid_arg() {
    let json = br#"{"a":1}"#;
    unsafe {
        let (doc, root) = open_root(json);
        let rc = leanjson_cursor_bytes(&root, ptr::null_mut(), ptr::null_mut());
        assert_eq!(rc, leanjson_err::LEANJSON_INVALID_ARG as c_int);
        leanjson_free(doc);
    }
}

#[test]
fn bytes_of_root_array_covers_full_json() {
    let json = br#"[1,"two",true]"#;
    unsafe {
        let (doc, cur) = open_root(json);
        let mut bs: usize = 0;
        let mut be: usize = 0;
        let rc = leanjson_cursor_bytes(&cur, &mut bs, &mut be);
        assert_eq!(rc, 0);
        assert_eq!(&json[bs..be], json.as_ref());
        leanjson_free(doc);
    }
}
