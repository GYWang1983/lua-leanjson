//! Exercise genuine >4 GiB logical input with a reused one-MiB working buffer.
#![cfg(target_pointer_width = "64")]

use std::ptr;
use qjson::source_ffi::*;

#[test]
fn ffi_spans_and_random_read_requests_remain_u64_past_four_gib() {
    unsafe {
        let mut result = qjson_source_v1_result::default();
        let options = qjson_source_v1_options { window_size: 3, ..Default::default() };
        let source = qjson_source_v1_new(&options, &mut result);
        assert!(!source.is_null());
        let whitespace = vec![b' '; 1024 * 1024];
        let mut offset = 0u64;
        for _ in 0..4096 {
            assert_eq!(qjson_source_v1_feed(source, offset, whitespace.as_ptr(), whitespace.len(), &mut result), 2);
            offset += whitespace.len() as u64;
        }
        assert_eq!(offset, 1u64 << 32);
        let bytes = br#"["\u0041",9007199254740993]"#;
        assert_eq!(qjson_source_v1_feed(source, offset, bytes.as_ptr(), bytes.len(), &mut result), 2);
        assert_eq!(qjson_source_v1_finish(source, offset + bytes.len() as u64, &mut result), 0);
        let mut root = qjson_source_v1_node::default();
        assert_eq!(qjson_source_v1_root(source, &mut root, &mut result), 0);
        let mut info = qjson_source_v1_node_info::default();
        assert_eq!(qjson_source_v1_node_get_info(root, &mut info, &mut result), 0);
        assert_eq!((info.raw_start, info.raw_end), (offset, offset + bytes.len() as u64));
        let mut iter = ptr::null_mut();
        assert_eq!(qjson_source_v1_iter_begin(root, &mut iter, &mut result), 0);
        let mut member = qjson_source_v1_member::default();
        assert_eq!(qjson_source_v1_iter_next(iter, &mut member, &mut result), 0);
        assert_eq!(qjson_source_v1_node_get_info(member.value, &mut info, &mut result), 0);
        assert_eq!((info.raw_start, info.raw_end), (offset + 1, offset + 9));
        let mut op = ptr::null_mut();
        assert_eq!(qjson_source_v1_node_scalar_begin(member.value, &mut op, &mut result), 3);
        let mut decoded = Vec::new();
        loop {
            let mut pointer = ptr::null();
            let mut length = 0;
            match qjson_source_v1_op_step(op, &mut pointer, &mut length, &mut result) {
                0 => decoded.extend_from_slice(std::slice::from_raw_parts(pointer, length)),
                1 => break,
                3 => {
                    assert!(result.offset > u32::MAX as u64);
                    assert!(result.length > 0 && result.length <= 3);
                    let index = (result.offset - offset) as usize;
                    assert_eq!(qjson_source_v1_provide_window(op, result.offset, bytes[index..].as_ptr(), result.length as usize, &mut result), 0);
                },
                _ => panic!("{result:?}"),
            }
        }
        assert_eq!(decoded, b"A");
        qjson_source_v1_op_release(op);
        qjson_source_v1_iter_release(iter);
        qjson_source_v1_release(source);
    }
}
