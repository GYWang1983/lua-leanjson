use std::ptr;

use leanjson::ffi::{
    leanjson_cursor, leanjson_cursor_object_entry_at, leanjson_doc, leanjson_error, leanjson_free, leanjson_open,
    leanjson_parse,
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

unsafe fn entry_at(root: &leanjson_cursor, i: usize) -> (String, leanjson_cursor) {
    let mut kp: *const u8 = ptr::null();
    let mut kn: usize = 0;
    let mut vc: leanjson_cursor = std::mem::zeroed();
    let rc = leanjson_cursor_object_entry_at(root, i, &mut kp, &mut kn, &mut vc);
    assert_eq!(rc, 0, "entry_at({}) failed with rc={}", i, rc);
    let key = std::slice::from_raw_parts(kp, kn);
    (String::from_utf8(key.to_vec()).unwrap(), vc)
}

#[test]
fn three_keys_in_order() {
    let json = br#"{"a":1,"b":"x","c":[2,3]}"#;
    unsafe {
        let (doc, root) = open_root(json);
        let (k0, _) = entry_at(&root, 0);
        let (k1, _) = entry_at(&root, 1);
        let (k2, _) = entry_at(&root, 2);
        assert_eq!(k0, "a");
        assert_eq!(k1, "b");
        assert_eq!(k2, "c");
        leanjson_free(doc);
    }
}

#[test]
fn key_with_escape_decodes() {
    // The key `"a\nb"` (3 chars: a, newline, b) — verifies the FFI runs the
    // string-decode scratch path rather than handing back raw escaped bytes.
    let json = b"{\"a\\nb\":1}";
    unsafe {
        let (doc, root) = open_root(json);
        let (k0, _) = entry_at(&root, 0);
        assert_eq!(k0, "a\nb");
        leanjson_free(doc);
    }
}

#[test]
fn out_of_range_returns_not_found() {
    let json = br#"{"a":1}"#;
    unsafe {
        let (doc, root) = open_root(json);
        let mut kp: *const u8 = ptr::null();
        let mut kn: usize = 0;
        let mut vc: leanjson_cursor = std::mem::zeroed();
        let rc = leanjson_cursor_object_entry_at(&root, 5, &mut kp, &mut kn, &mut vc);
        assert_eq!(rc, 2); // LEANJSON_NOT_FOUND
        leanjson_free(doc);
    }
}

#[test]
fn array_cursor_returns_type_mismatch() {
    let json = br#"[1,2,3]"#;
    unsafe {
        let (doc, root) = open_root(json);
        let mut kp: *const u8 = ptr::null();
        let mut kn: usize = 0;
        let mut vc: leanjson_cursor = std::mem::zeroed();
        let rc = leanjson_cursor_object_entry_at(&root, 0, &mut kp, &mut kn, &mut vc);
        assert_eq!(rc, 3); // LEANJSON_TYPE_MISMATCH
        leanjson_free(doc);
    }
}
