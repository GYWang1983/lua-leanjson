use std::os::raw::c_char;
use leanjson::ffi::*;

fn parse(s: &[u8]) -> *mut leanjson_doc {
    let mut err = leanjson_error::default();
    let d = unsafe { leanjson_parse(s.as_ptr(), s.len(), &mut err) };
    assert!(!d.is_null());
    d
}

#[test]
fn get_str_simple() {
    let d = parse(b"{\"a\":\"hello\"}");
    let mut p: *const u8 = std::ptr::null();
    let mut n: usize = 0;
    let path = b"a";
    let rc = unsafe { leanjson_get_str(d, path.as_ptr() as *const c_char, path.len(), &mut p, &mut n) };
    assert_eq!(rc, 0);
    let s = unsafe { std::slice::from_raw_parts(p, n) };
    assert_eq!(s, b"hello");
    unsafe { leanjson_free(d) };
}

#[test]
fn get_str_with_escape() {
    let d = parse(b"{\"a\":\"he\\nlo\"}");
    let mut p: *const u8 = std::ptr::null();
    let mut n: usize = 0;
    let path = b"a";
    let rc = unsafe { leanjson_get_str(d, path.as_ptr() as *const c_char, path.len(), &mut p, &mut n) };
    assert_eq!(rc, 0);
    let s = unsafe { std::slice::from_raw_parts(p, n) };
    assert_eq!(s, b"he\nlo");
    unsafe { leanjson_free(d) };
}

#[test]
fn get_str_type_mismatch() {
    let d = parse(b"{\"a\":42}");
    let mut p: *const u8 = std::ptr::null();
    let mut n: usize = 0;
    let path = b"a";
    let rc = unsafe { leanjson_get_str(d, path.as_ptr() as *const c_char, path.len(), &mut p, &mut n) };
    assert_eq!(rc, 3); // TYPE_MISMATCH
    unsafe { leanjson_free(d) };
}
