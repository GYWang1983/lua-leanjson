use std::ptr;
use qjson::source_ffi::*;
use qjson::source::{DETAIL_IO, DETAIL_BAD_OPTIONS, DETAIL_BAD_WINDOW, DETAIL_BAD_OFFSET};
use qjson::error::{qjson_err as E, qjson_type as T};

unsafe fn new(window: u32) -> *mut qjson_source_v1 {
    let options = qjson_source_v1_options { window_size: window, ..Default::default() };
    let mut result = qjson_source_v1_result::default();
    let source = qjson_source_v1_new(&options, &mut result);
    assert!(!source.is_null(), "{result:?}");
    assert_eq!(result.status, QJSON_SOURCE_V1_NEED_INPUT);
    source
}

unsafe fn parse(bytes: &[u8], window: u32) -> (*mut qjson_source_v1, qjson_source_v1_node) {
    let source = new(window);
    let mut result = qjson_source_v1_result::default();
    for (offset, &byte) in bytes.iter().enumerate() {
        let mut temporary = [byte];
        assert_eq!(qjson_source_v1_feed(source, offset as u64, temporary.as_ptr(), 1, &mut result), QJSON_SOURCE_V1_NEED_INPUT as i32, "{result:?}");
        temporary[0] = 0; // feed may not retain the input pointer.
    }
    assert_eq!(qjson_source_v1_finish(source, bytes.len() as u64, &mut result), QJSON_SOURCE_V1_READY as i32, "{result:?}");
    let mut root = qjson_source_v1_node::default();
    assert_eq!(qjson_source_v1_root(source, &mut root, &mut result), QJSON_SOURCE_V1_READY as i32);
    (source, root)
}

unsafe fn drain(op: *mut qjson_source_v1_op, bytes: &[u8], limit: usize) -> Vec<u8> {
    let mut result = qjson_source_v1_result::default();
    let mut output = Vec::new();
    loop {
        let mut pointer = ptr::null();
        let mut length = 999;
        let status = qjson_source_v1_op_step(op, &mut pointer, &mut length, &mut result);
        assert_eq!(status as u32, result.status);
        match result.status {
            QJSON_SOURCE_V1_READY => {
                assert!(length > 0 && length <= limit);
                output.extend_from_slice(std::slice::from_raw_parts(pointer, length));
            },
            QJSON_SOURCE_V1_NEED_READ => {
                assert!(pointer.is_null());
                assert_eq!(length, 0);
                assert!(result.length > 0 && result.length <= limit as u64);
                let mut temporary = bytes[result.offset as usize..(result.offset + result.length) as usize].to_vec();
                assert_eq!(qjson_source_v1_provide_window(op, result.offset, temporary.as_ptr(), temporary.len(), &mut result), QJSON_SOURCE_V1_READY as i32, "{result:?}");
                temporary.fill(0);
            },
            QJSON_SOURCE_V1_DONE => { assert!(pointer.is_null()); assert_eq!(length, 0); break; },
            _ => panic!("unexpected source operation result: {result:?}"),
        }
    }
    output
}

#[test]
fn ffi_requires_explicit_finish_and_preserves_lexical_members() {
    unsafe {
        let source = new(4);
        let bytes = br#"{"a":1,"a\u0062":2,"a":3}"#;
        let mut result = qjson_source_v1_result::default();
        let mut root = qjson_source_v1_node::default();
        assert_eq!(qjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), &mut result), 2);
        assert_eq!(qjson_source_v1_root(source, &mut root, &mut result), 2);
        assert_eq!(qjson_source_v1_finish(source, bytes.len() as u64, &mut result), 0);
        assert_eq!(qjson_source_v1_finish(source, bytes.len() as u64, &mut result), 0);
        assert_eq!(qjson_source_v1_root(source, &mut root, &mut result), 0);
        let mut info = qjson_source_v1_node_info::default();
        assert_eq!(qjson_source_v1_node_get_info(root, &mut info, &mut result), 0);
        assert_eq!((info.kind, info.complete, info.raw_start, info.raw_end, info.child_count), (T::QJSON_T_OBJ as u32, 1, 0, 25, 3));
        let mut iter = ptr::null_mut();
        assert_eq!(qjson_source_v1_iter_begin(root, &mut iter, &mut result), 0);
        let mut member = qjson_source_v1_member::default();
        let mut values = Vec::new();
        for ordinal in 0..3 {
            assert_eq!(qjson_source_v1_iter_next(iter, &mut member, &mut result), 0);
            assert_eq!(member.ordinal, ordinal);
            let mut op = ptr::null_mut();
            assert_eq!(qjson_source_v1_node_scalar_begin(member.value, &mut op, &mut result), 3);
            values.push(drain(op, bytes, 4));
            qjson_source_v1_op_release(op);
        }
        assert_eq!(values, [b"1".to_vec(), b"2".to_vec(), b"3".to_vec()]);
        assert_eq!(qjson_source_v1_iter_next(iter, &mut member, &mut result), 1);
        qjson_source_v1_iter_release(iter);
        qjson_source_v1_release(source);
    }
}

#[test]
fn operation_retains_source_after_original_owner_releases_it() {
    unsafe {
        let bytes = br#""long\n\uD834\uDD1E""#;
        let (source, root) = parse(bytes, 2);
        let mut result = qjson_source_v1_result::default();
        let mut op = ptr::null_mut();
        assert_eq!(qjson_source_v1_node_scalar_begin(root, &mut op, &mut result), 3);
        qjson_source_v1_release(source);
        assert_eq!(drain(op, bytes, 2), "long\n𝄞".as_bytes());
        qjson_source_v1_op_release(op);
    }
}

#[test]
fn iterator_retains_source_and_can_create_operations_after_owner_release() {
    unsafe {
        let bytes = br#"["one","two"]"#;
        let (source, root) = parse(bytes, 3);
        let mut iter = ptr::null_mut();
        let mut result = qjson_source_v1_result::default();
        assert_eq!(qjson_source_v1_iter_begin(root, &mut iter, &mut result), 0);
        qjson_source_v1_release(source);
        let mut member = qjson_source_v1_member::default();
        assert_eq!(qjson_source_v1_iter_next(iter, &mut member, &mut result), 0);
        assert_eq!((member.key_start, member.key_end), (0, 0));
        let mut op = ptr::null_mut();
        qjson_source_v1_node_raw_begin(member.value, &mut op, &mut result);
        qjson_source_v1_iter_release(iter);
        assert_eq!(drain(op, bytes, 3), br#""one""#);
        qjson_source_v1_op_release(op);
    }
}

#[test]
fn io_abort_is_sticky_for_root_iterator_and_active_operation() {
    unsafe {
        let (source, root) = parse(br#"[123]"#, 2);
        let mut result = qjson_source_v1_result::default();
        let mut iter = ptr::null_mut();
        qjson_source_v1_iter_begin(root, &mut iter, &mut result);
        let mut op = ptr::null_mut();
        qjson_source_v1_node_raw_begin(root, &mut op, &mut result);
        assert_eq!(qjson_source_v1_abort(source, DETAIL_IO, &mut result), 5);
        assert_eq!((result.detail, result.code, result.offset), (DETAIL_IO, E::QJSON_OK as i32, 5));
        let expected = result;
        assert_eq!(qjson_source_v1_root(source, &mut qjson_source_v1_node::default(), &mut result), 5);
        assert_eq!(result, expected);
        assert_eq!(qjson_source_v1_iter_next(iter, &mut qjson_source_v1_member::default(), &mut result), 5);
        assert_eq!(result, expected);
        let mut pointer = ptr::null();
        let mut length = 0;
        assert_eq!(qjson_source_v1_op_step(op, &mut pointer, &mut length, &mut result), 5);
        assert_eq!(result, expected);
        qjson_source_v1_op_release(op);
        qjson_source_v1_iter_release(iter);
        qjson_source_v1_release(source);
    }
}

#[test]
fn bad_options_offsets_and_json_errors_have_separate_details() {
    unsafe {
        for options in [qjson_source_v1_options { api_version: 0, ..Default::default() }, qjson_source_v1_options { mode: 1, ..Default::default() }] {
            let mut result = qjson_source_v1_result::default();
            assert!(qjson_source_v1_new(&options, &mut result).is_null());
            assert_eq!((result.status, result.detail, result.code), (5, DETAIL_BAD_OPTIONS, E::QJSON_INVALID_ARG as i32));
        }
        let source = new(1);
        let mut result = qjson_source_v1_result::default();
        assert_eq!(qjson_source_v1_feed(source, u64::MAX, b"0".as_ptr(), 1, &mut result), 5);
        assert_eq!(result.detail, DETAIL_BAD_OFFSET);
        qjson_source_v1_release(source);
        let source = new(1);
        assert_eq!(qjson_source_v1_feed(source, 0, b"[01]".as_ptr(), 4, &mut result), 5);
        assert_eq!((result.detail, result.code, result.offset), (0, E::QJSON_INVALID_NUMBER as i32, 1));
        assert_eq!(qjson_source_v1_finish(source, 4, &mut result), 5);
        qjson_source_v1_release(source);
    }
}

#[test]
fn bad_window_does_not_invalidate_an_independent_operation() {
    unsafe {
        let bytes = b"12345";
        let (source, root) = parse(bytes, 2);
        let mut result = qjson_source_v1_result::default();
        let mut first = ptr::null_mut();
        let mut second = ptr::null_mut();
        qjson_source_v1_node_raw_begin(root, &mut first, &mut result);
        qjson_source_v1_node_raw_begin(root, &mut second, &mut result);
        assert_eq!(qjson_source_v1_provide_window(first, 1, bytes.as_ptr(), 1, &mut result), 5);
        assert_eq!(result.detail, DETAIL_BAD_WINDOW);
        assert_eq!(drain(second, bytes, 2), bytes);
        qjson_source_v1_op_release(first);
        qjson_source_v1_op_release(second);
        qjson_source_v1_release(source);
    }
}

#[test]
fn null_arguments_return_error_and_null_releases_are_safe() {
    unsafe {
        let mut result = qjson_source_v1_result::default();
        assert_eq!(qjson_source_v1_feed(ptr::null_mut(), 0, ptr::null(), 0, &mut result), 5);
        assert_eq!(result.code, E::QJSON_INVALID_ARG as i32);
        assert_eq!(qjson_source_v1_root(ptr::null(), ptr::null_mut(), ptr::null_mut()), 5);
        let source = new(1);
        assert_eq!(qjson_source_v1_feed(source, 0, ptr::null(), 0, &mut result), 2);
        assert_eq!(qjson_source_v1_feed(source, 0, ptr::null(), 1, &mut result), 5);
        qjson_source_v1_retain(source);
        qjson_source_v1_release(source);
        qjson_source_v1_release(source);
        qjson_source_v1_retain(ptr::null_mut());
        qjson_source_v1_release(ptr::null_mut());
        qjson_source_v1_iter_release(ptr::null_mut());
        qjson_source_v1_op_release(ptr::null_mut());
    }
}

#[cfg(feature = "test-panic")]
#[test]
fn forced_source_panic_becomes_an_oom_result() {
    unsafe {
        let mut result = qjson_source_v1_result::default();
        assert_eq!(qjson_source_v1_force_panic(&mut result), QJSON_SOURCE_V1_ERROR as i32);
        assert_eq!((result.status, result.code, result.detail, result.offset), (QJSON_SOURCE_V1_ERROR, E::QJSON_OOM as i32, 0, u64::MAX));
        assert_eq!(qjson_source_v1_force_panic(ptr::null_mut()), QJSON_SOURCE_V1_ERROR as i32);
    }
}
