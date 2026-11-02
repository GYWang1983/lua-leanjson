use leanjson::error::leanjson_err;
use leanjson::source::{IndexOptions, Source};
use leanjson::source_ffi::*;
use std::ptr;

unsafe fn parsed(bytes: &[u8], options: leanjson_source_v2_options, chunk: usize) -> *mut leanjson_source_v1 {
    let mut result = leanjson_source_v1_result::default();
    let source = leanjson_source_v2_new(&options, &mut result);
    assert!(!source.is_null(), "{result:?}");
    for (i, bytes) in bytes.chunks(chunk).enumerate() {
        assert_eq!(leanjson_source_v1_feed(source, (i * chunk) as u64, bytes.as_ptr(), bytes.len(), &mut result), 2, "{result:?}");
    }
    assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, &mut result), 0, "{result:?}");
    source
}
unsafe fn root(source: *const leanjson_source_v1) -> leanjson_source_v2_node {
    let mut root = leanjson_source_v2_node::default();
    assert_eq!(leanjson_source_v2_root(source, &mut root, ptr::null_mut()), 0);
    root
}
unsafe fn iterator(node: leanjson_source_v2_node, normalize: bool) -> *mut leanjson_source_v2_iter {
    let mut iter = ptr::null_mut();
    assert_eq!(leanjson_source_v2_iter_begin(node, u32::from(normalize), &mut iter, ptr::null_mut()), 0);
    iter
}
unsafe fn next(iter: *mut leanjson_source_v2_iter, bytes: &[u8], partial: usize) -> Option<(Vec<u8>, leanjson_source_v2_node)> {
    let mut member = leanjson_source_v2_member::default();
    let mut result = leanjson_source_v1_result::default();
    loop {
        match leanjson_source_v2_iter_next(iter, &mut member, &mut result) {
            0 => return Some((std::slice::from_raw_parts(member.key, member.key_len).to_vec(), member.value)),
            1 => return None,
            3 => {
                let size = (result.length as usize).min(partial);
                let mut window = bytes[result.offset as usize..result.offset as usize + size].to_vec();
                assert_eq!(leanjson_source_v2_iter_provide_window(iter, result.offset, window.as_ptr(), size, &mut result), 0, "{result:?}");
                window.fill(0); // Every supplied pointer is ephemeral.
            },
            status => panic!("unexpected status {status}: {result:?}"),
        }
    }
}

#[test]
fn index_capacity_is_bounded_at_zero_tiny_and_default_limits_without_weakening_validation() {
    let bytes = br#"{"a":{"b":{"c":{"d":7}}},"arr":[0,1,2,3,4]}"#;
    for depth in [0, 1, 3] {
        for prefix in [0, 1, 3] {
            for budget in [0, 1, 96, 1048576] {
                let mut source = Source::new_sparse(0, 1, IndexOptions { depth, array_limit: prefix, budget_bytes: budget });
                for (i, byte) in bytes.iter().enumerate() { source.feed(i as u64, &[*byte]).unwrap(); }
                source.finish(bytes.len() as u64).unwrap();
                assert!(source.index_bytes() <= budget);
                assert!(source.indexed_depth() <= depth);
                if depth == 0 || budget == 0 { assert_eq!(source.indexed_nodes(), 0); }
                assert_eq!(source.node(0).unwrap().unwrap().child_count, 2);
            }
        }
    }
    for bytes in [br#"{"a":{"b":{"c":{"bad":"\uD800x"}}}}"#.as_slice(), b"[0,1,2,01]"] {
        let mut source = Source::new_sparse(0, 1, IndexOptions { depth: 0, array_limit: 0, budget_bytes: 0 });
        let error = source.feed(0, bytes).unwrap_err();
        assert!(matches!(error.code, leanjson_err::LEANJSON_INVALID_STRING | leanjson_err::LEANJSON_INVALID_NUMBER));
    }
}

#[test]
fn default_frontier_is_a_b_c_and_array_prefix_is_three() {
    let bytes = br#"{"a":{"b":{"c":{"d":7}}},"arr":[0,1,2,3,4]}"#;
    let mut source = Source::new_sparse(0, 7, IndexOptions::default());
    source.feed(0, bytes).unwrap(); source.finish(bytes.len() as u64).unwrap();
    let root = source.node(0).unwrap().unwrap();
    let a = source.node(root.members[0].value).unwrap().unwrap();
    let b = source.node(a.members[0].value).unwrap().unwrap();
    let c = source.node(b.members[0].value).unwrap().unwrap();
    assert_eq!((c.raw_start, c.raw_end), (15, 22));
    assert!(c.members.is_empty(), "frontier spans must not retain deeper children");
    let array = source.node(root.members[1].value).unwrap().unwrap();
    assert_eq!(array.child_count, 5);
    assert_eq!(array.members.len(), 3);
    assert_eq!(source.indexed_depth(), 3);
}

#[test]
fn held_spans_and_prefix_iterators_survive_clearing_indexes_and_owner_release() {
    unsafe {
        let bytes = br#"[{"x":1},{"x":2},{"x":3},{"x":4}]"#;
        let source = parsed(bytes, leanjson_source_v2_options { window_size: 7, ..Default::default() }, 1);
        let iter = iterator(root(source), false);
        let mut member = leanjson_source_v2_member::default();
        // The cached prefix returns a whole child span without source reads.
        assert_eq!(leanjson_source_v2_iter_next(iter, &mut member, ptr::null_mut()), 0);
        let held = member.value;
        assert_eq!((held.raw_start, held.raw_end, held.child_count), (1, 8, 1));
        assert_eq!(leanjson_source_v2_clear_indexes(source, ptr::null_mut()), 0);
        leanjson_source_v1_release(source);
        for expected in [br#"{"x":2}"#.as_slice(), br#"{"x":3}"#, br#"{"x":4}"#] {
            let (_, value) = next(iter, bytes, 1).unwrap();
            assert_eq!(&bytes[value.raw_start as usize..value.raw_end as usize], expected);
        }
        assert!(next(iter, bytes, 1).is_none());
        let nested = iterator(held, true);
        let (key, value) = next(nested, bytes, 1).unwrap();
        assert_eq!(key, b"x");
        assert_eq!(&bytes[value.raw_start as usize..value.raw_end as usize], b"1");
        leanjson_source_v2_iter_release(nested);
        leanjson_source_v2_iter_release(iter);
    }
}

#[test]
fn cached_object_lookup_compares_decoded_keys_and_uses_the_last_whole_value() {
    unsafe {
        let bytes = br#"{"a":{"old":1},"\u0061":false,"a":null,"ab":7}"#;
        let source = parsed(bytes, leanjson_source_v2_options { window_size: 2, ..Default::default() }, 1);
        let mut lookup = ptr::null_mut();
        assert_eq!(leanjson_source_v2_lookup_begin(root(source), b"a".as_ptr(), 1, 0, &mut lookup, ptr::null_mut()), 0);
        let (key, value) = next(lookup, bytes, 1).unwrap();
        assert_eq!(key, b"a"); assert_eq!(value.kind, 0);
        assert_eq!(&bytes[value.raw_start as usize..value.raw_end as usize], b"null");
        assert!(next(lookup, bytes, 1).is_none());
        leanjson_source_v2_iter_release(lookup);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn streamed_wide_normalization_keeps_first_slots_and_last_values_with_zero_cache() {
    unsafe {
        let mut bytes = Vec::from(b"{".as_slice());
        for i in 0..128 {
            if i > 0 { bytes.push(b','); }
            bytes.extend_from_slice(format!("\"k{i}\":{{\"x\":1,\"x\":2}}").as_bytes());
        }
        bytes.extend_from_slice(br#", "\u006b0":null,"k127":false}"#);
        let source = parsed(&bytes, leanjson_source_v2_options { index_depth: 0, index_array_limit: 0, index_budget_bytes: 0, window_size: 11, ..Default::default() }, 1);
        let iter = iterator(root(source), true);
        for i in 0..128 {
            let (key, value) = next(iter, &bytes, 1).unwrap();
            assert_eq!(key, format!("k{i}").as_bytes());
            assert_eq!(value.kind, if i == 0 { 0 } else if i == 127 { 1 } else { 5 });
            if i != 0 && i != 127 { assert_eq!(value.flags, 2, "nested duplicates cannot be treated as clean"); }
        }
        assert!(next(iter, &bytes, 1).is_none());
        leanjson_source_v2_iter_release(iter); leanjson_source_v1_release(source);
    }
}

#[test]
fn bad_windows_are_sticky_per_iterator_and_abort_invalidates_cached_and_streaming_users() {
    unsafe {
        let bytes = br#"{"x":1}"#;
        let source = parsed(bytes, leanjson_source_v2_options { index_budget_bytes: 0, window_size: 2, ..Default::default() }, 2);
        let bad = iterator(root(source), false);
        let good = iterator(root(source), false);
        let mut member = leanjson_source_v2_member::default();
        let mut result = leanjson_source_v1_result::default();
        assert_eq!(leanjson_source_v2_iter_next(bad, &mut member, &mut result), 3);
        assert_eq!(leanjson_source_v2_iter_provide_window(bad, 1, b"{ ".as_ptr(), 2, &mut result), 5);
        let error = result;
        assert_eq!(result.detail, 4);
        assert_eq!(leanjson_source_v2_iter_next(bad, &mut member, &mut result), 5);
        assert_eq!(result, error);
        assert_eq!(next(good, bytes, 1).unwrap().0, b"x");
        assert_eq!(leanjson_source_v1_abort(source, 2, &mut result), 5);
        assert_eq!(leanjson_source_v2_iter_next(good, &mut member, &mut result), 5);
        assert_eq!(result.detail, 2);
        leanjson_source_v2_iter_release(bad); leanjson_source_v2_iter_release(good);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn v2_option_status_and_scalar_operation_contracts_preserve_v1_layouts() {
    unsafe {
        assert_eq!(std::mem::size_of::<leanjson_source_v1_options>(), 16);
        assert_eq!(std::mem::size_of::<leanjson_source_v1_node>(), 16);
        for options in [
            leanjson_source_v2_options { api_version: 1, ..Default::default() },
            leanjson_source_v2_options { mode: 1, ..Default::default() },
            leanjson_source_v2_options { reserved: 1, ..Default::default() },
        ] {
            let mut result = leanjson_source_v1_result::default();
            assert!(leanjson_source_v2_new(&options, &mut result).is_null());
            assert_eq!((result.status, result.detail), (5, 6));
        }
        let mut result = leanjson_source_v1_result::default();
        let source = leanjson_source_v2_new(ptr::null(), &mut result);
        assert!(!source.is_null());
        assert_eq!(result.status, 2);
        let mut node = leanjson_source_v2_node::default();
        assert_eq!(leanjson_source_v2_root(source, &mut node, &mut result), 2);
        let bytes = br#""\u0041""#;
        assert_eq!(leanjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), &mut result), 2);
        assert_eq!(leanjson_source_v2_root(source, &mut node, &mut result), 2);
        assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, &mut result), 0);
        assert_eq!(leanjson_source_v2_root(source, &mut node, &mut result), 0);
        let mut stats = leanjson_source_v2_stats::default();
        assert_eq!(leanjson_source_v2_get_stats(source, &mut stats, &mut result), 0);
        assert_eq!((stats.index_depth, stats.index_array_limit, stats.budget_bytes), (3, 3, 1048576));
        let mut op = ptr::null_mut();
        assert_eq!(leanjson_source_v2_node_scalar_begin(node, &mut op, &mut result), 3);
        assert_eq!(leanjson_source_v2_clear_indexes(source, &mut result), 0);
        leanjson_source_v1_release(source);
        let mut output = Vec::new();
        loop {
            let mut pointer = ptr::null();
            let mut length = 0;
            match leanjson_source_v1_op_step(op, &mut pointer, &mut length, &mut result) {
                0 => output.extend_from_slice(std::slice::from_raw_parts(pointer, length)),
                1 => break,
                3 => {
                    assert_eq!(leanjson_source_v1_provide_window(op, result.offset,
                        bytes[result.offset as usize..].as_ptr(), 1, &mut result), 0);
                },
                status => panic!("unexpected status {status}: {result:?}"),
            }
        }
        assert_eq!(output, b"A");
        leanjson_source_v1_op_release(op);
        leanjson_source_v2_iter_release(ptr::null_mut());
    }
}

#[test]
fn annotated_lexical_iteration_marks_exact_final_occurrences_in_two_partial_window_passes() {
    unsafe {
        let mut bytes = Vec::from(b"{".as_slice());
        for i in 0..128 {
            if i != 0 { bytes.push(b','); }
            bytes.extend_from_slice(format!("\"k{i}\":{{\"x\":{i}}}").as_bytes());
        }
        bytes.extend_from_slice(br#", "\u006b0":false,"k127":null}"#);
        let source = parsed(&bytes, leanjson_source_v2_options { window_size: 7, index_budget_bytes: 0, ..Default::default() }, 1);
        let mut iter = ptr::null_mut();
        let mut result = leanjson_source_v1_result::default();
        assert_eq!(leanjson_source_v2_iter_begin(root(source), 2, &mut iter, &mut result), 0);
        let mut member = leanjson_source_v2_member::default();
        assert_eq!(leanjson_source_v2_iter_next_current(iter, &mut member, ptr::null_mut(), &mut result), 5);
        assert_eq!(leanjson_source_v2_clear_indexes(source, &mut result), 0);
        leanjson_source_v1_release(source);
        let mut count = 0;
        let mut provided_bytes = 0;
        loop {
            let mut current = 99;
            match leanjson_source_v2_iter_next_current(iter, &mut member, &mut current, &mut result) {
                0 => {
                    let key = std::slice::from_raw_parts(member.key, member.key_len);
                    match count {
                        0..=127 => {
                            assert_eq!(key, format!("k{count}").as_bytes());
                            assert_eq!(current, u32::from(count != 0 && count != 127));
                        },
                        128 => { assert_eq!(key, b"k0"); assert_eq!(current, 1); assert_eq!(member.value.kind, 1); },
                        129 => { assert_eq!(key, b"k127"); assert_eq!(current, 1); assert_eq!(member.value.kind, 0); },
                        _ => panic!("extra lexical occurrence"),
                    }
                    assert_eq!(member.ordinal, count);
                    count += 1;
                },
                1 => { assert_eq!(current, 0); break; },
                3 => {
                    assert_eq!(current, 0);
                    let mut window = [bytes[result.offset as usize]];
                    assert_eq!(leanjson_source_v2_iter_provide_window(iter, result.offset, window.as_ptr(), 1, &mut result), 0);
                    window.fill(0);
                    provided_bytes += 1;
                },
                status => panic!("unexpected status {status}: {result:?}"),
            }
        }
        assert_eq!(count, 130);
        assert_eq!(provided_bytes, bytes.len() * 2);
        leanjson_source_v2_iter_release(iter);
    }
}
