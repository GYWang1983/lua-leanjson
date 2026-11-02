use std::ptr;

use leanjson::ffi::{
    leanjson_cursor, leanjson_cursor_get_i64, leanjson_cursor_typeof, leanjson_doc, leanjson_free,
    leanjson_error, leanjson_iter, leanjson_iter_init, leanjson_iter_next, leanjson_open, leanjson_parse,
};

unsafe fn open_root(json: &[u8]) -> (*mut leanjson_doc, leanjson_cursor) {
    let mut err = leanjson_error::default();
    let doc = leanjson_parse(json.as_ptr(), json.len(), &mut err);
    assert!(!doc.is_null());
    assert_eq!(err.code, 0);

    let mut root: leanjson_cursor = std::mem::zeroed();
    let rc = leanjson_open(doc, ptr::null(), 0, &mut root);
    assert_eq!(rc, 0);
    (doc, root)
}

unsafe fn init_iter(cur: &leanjson_cursor) -> leanjson_iter {
    let mut it: leanjson_iter = std::mem::zeroed();
    let rc = leanjson_iter_init(cur, &mut it);
    assert_eq!(rc, 0);
    it
}

unsafe fn next(it: &mut leanjson_iter) -> Option<(String, leanjson_cursor)> {
    let mut key_ptr: *const u8 = ptr::null();
    let mut key_len: usize = 0;
    let mut value: leanjson_cursor = std::mem::zeroed();
    let rc = leanjson_iter_next(it, &mut key_ptr, &mut key_len, &mut value);
    if rc == 2 {
        return None;
    }
    assert_eq!(rc, 0);
    let key = std::slice::from_raw_parts(key_ptr, key_len);
    Some((String::from_utf8(key.to_vec()).unwrap(), value))
}

#[test]
fn stateful_iter_empty_object_exhausts_immediately() {
    unsafe {
        let (doc, root) = open_root(br#"{}"#);
        let mut it = init_iter(&root);
        assert!(next(&mut it).is_none());
        assert!(next(&mut it).is_none());
        leanjson_free(doc);
    }
}

#[test]
fn stateful_iter_returns_keys_and_value_cursors_in_source_order() {
    unsafe {
        let (doc, root) = open_root(br#"{"a":1,"b":{"x":2},"c":[3]}"#);
        let mut it = init_iter(&root);

        let (k0, v0) = next(&mut it).unwrap();
        let mut n = 0i64;
        assert_eq!(k0, "a");
        assert_eq!(leanjson_cursor_get_i64(&v0, ptr::null(), 0, &mut n), 0);
        assert_eq!(n, 1);

        let (k1, v1) = next(&mut it).unwrap();
        let mut t = -1;
        assert_eq!(k1, "b");
        assert_eq!(leanjson_cursor_typeof(&v1, ptr::null(), 0, &mut t), 0);
        assert_eq!(t, 5); // LEANJSON_T_OBJ

        let (k2, v2) = next(&mut it).unwrap();
        assert_eq!(k2, "c");
        assert_eq!(leanjson_cursor_typeof(&v2, ptr::null(), 0, &mut t), 0);
        assert_eq!(t, 4); // LEANJSON_T_ARR

        assert!(next(&mut it).is_none());
        leanjson_free(doc);
    }
}

#[test]
fn multiple_iterators_keep_independent_positions() {
    unsafe {
        let (doc, root) = open_root(br#"{"outer":{"a":1,"b":2},"other":{"c":3}}"#);
        let mut root_it = init_iter(&root);

        let (outer_key, outer_cur) = next(&mut root_it).unwrap();
        assert_eq!(outer_key, "outer");
        let mut outer_it = init_iter(&outer_cur);

        let (other_key, _other_cur) = next(&mut root_it).unwrap();
        assert_eq!(other_key, "other");

        let (a_key, a_cur) = next(&mut outer_it).unwrap();
        let mut n = 0i64;
        assert_eq!(a_key, "a");
        assert_eq!(leanjson_cursor_get_i64(&a_cur, ptr::null(), 0, &mut n), 0);
        assert_eq!(n, 1);

        let (b_key, b_cur) = next(&mut outer_it).unwrap();
        assert_eq!(b_key, "b");
        assert_eq!(leanjson_cursor_get_i64(&b_cur, ptr::null(), 0, &mut n), 0);
        assert_eq!(n, 2);

        assert!(next(&mut outer_it).is_none());
        assert!(next(&mut root_it).is_none());
        leanjson_free(doc);
    }
}

#[test]
fn iter_init_rejects_non_object_cursor() {
    unsafe {
        let (doc, root) = open_root(br#"[1,2,3]"#);
        let mut it: leanjson_iter = std::mem::zeroed();
        let rc = leanjson_iter_init(&root, &mut it);
        assert_eq!(rc, 3); // LEANJSON_TYPE_MISMATCH
        leanjson_free(doc);
    }
}
