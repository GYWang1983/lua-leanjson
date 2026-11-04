//! Index effects are measured at the actual NEED_READ/provide boundary.
use leanjson::source_ffi::*;
use std::ptr;

unsafe fn parse(bytes: &[u8], budget: u32, depth: u32, window: u32) -> *mut leanjson_source_v1 {
    let opts = leanjson_source_v2_options { index_depth: depth, index_array_limit: 0,
        index_budget_bytes: budget, window_size: window, ..Default::default() };
    let source = leanjson_source_v2_new(&opts, ptr::null_mut());
    assert!(!source.is_null());
    for (index, chunk) in bytes.chunks(7).enumerate() {
        assert_eq!(leanjson_source_v1_feed(source, (index * 7) as u64, chunk.as_ptr(), chunk.len(), ptr::null_mut()), 2);
    }
    assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, ptr::null_mut()), 0);
    source
}
unsafe fn root(source: *const leanjson_source_v1) -> leanjson_source_v2_node {
    let mut node = leanjson_source_v2_node::default();
    assert_eq!(leanjson_source_v2_root(source, &mut node, ptr::null_mut()), 0);
    node
}
unsafe fn lookup(node: leanjson_source_v2_node, key: &[u8], index: u64, bytes: &[u8]) -> (Option<leanjson_source_v2_node>, usize) {
    let mut iter = ptr::null_mut();
    assert_eq!(leanjson_source_v2_lookup_begin(node, key.as_ptr(), key.len(), index, &mut iter, ptr::null_mut()), 0);
    let mut result = leanjson_source_v1_result::default();
    let mut member = leanjson_source_v2_member::default();
    let mut value = None;
    let mut read_bytes = 0;
    loop {
        match leanjson_source_v2_iter_next(iter, &mut member, &mut result) {
            0 => { assert!(value.is_none()); value = Some(member.value); },
            1 => break,
            3 => {
                let offset = result.offset as usize;
                let length = result.length as usize;
                read_bytes += length;
                assert_eq!(leanjson_source_v2_iter_provide_window(iter, result.offset, bytes[offset..offset + length].as_ptr(), length, &mut result), 0, "{result:?}");
            },
            status => panic!("status {status}: {result:?}"),
        }
    }
    leanjson_source_v2_iter_release(iter);
    (value, read_bytes)
}
fn long_document() -> Vec<u8> {
    let mut bytes = br#"{"payload":""#.to_vec();
    for _ in 0..4096 { bytes.extend_from_slice(br#"abc\"\\\u0041"#); }
    bytes.extend_from_slice(br#"","branch":{"answer":42},"\u0064up":0,"dup":7}"#);
    bytes
}

#[test]
fn structural_boundaries_prevent_body_reads_even_with_large_requested_windows() {
    unsafe {
        let bytes = long_document();
        let source = parse(&bytes, 65536, 0, 65536);
        let (answer, reads) = lookup(root(source), b"dup", 0, &bytes);
        let answer = answer.unwrap();
        assert_eq!(&bytes[answer.raw_start as usize..answer.raw_end as usize], b"7");
        assert!(reads < 128, "validated string bodies must not enter requested windows: read {reads}");
        leanjson_source_v1_release(source);
    }
}

#[test]
fn final_demand_results_and_path_ancestors_eliminate_repeated_reads() {
    unsafe {
        let bytes = long_document();
        let source = parse(&bytes, 65536, 0, 31);
        for key in [b"branch".as_slice(), b"absent", b"dup"] {
            let (first, first_reads) = lookup(root(source), key, 0, &bytes);
            assert!(first_reads > 0);
            let (again, repeated_reads) = lookup(root(source), key, 0, &bytes);
            assert_eq!(first.map(|n| n.raw_start), again.map(|n| n.raw_start));
            assert_eq!(repeated_reads, 0, "confirmed {key:?} lookup rescanned its container");
            if key == b"branch" {
                let node = first.unwrap();
                let (answer, _) = lookup(node, b"answer", 0, &bytes);
                assert_eq!(&bytes[answer.unwrap().raw_start as usize..answer.unwrap().raw_end as usize], b"42");
                assert_eq!(lookup(node, b"answer", 0, &bytes).1, 0);
            }
        }
        leanjson_source_v1_release(source);
    }
}

#[test]
fn incomplete_prefix_never_overrides_later_escaped_duplicate_and_cache_survives_eviction() {
    unsafe {
        let mut bytes = br#"{"dup":0,"padding":""#.to_vec();
        bytes.extend(std::iter::repeat_n(b'x', 8192));
        bytes.extend_from_slice(br#"","other":1,"\u0064up":false}"#);
        let source = parse(&bytes, 512, 1, 32);
        let held = root(source);
        let (value, _) = lookup(held, b"dup", 0, &bytes);
        assert_eq!(value.unwrap().kind, 1);
        assert_eq!(lookup(held, b"dup", 0, &bytes).1, 0);
        let mut stats = leanjson_source_v2_stats::default();
        assert_eq!(leanjson_source_v2_get_stats(source, &mut stats, ptr::null_mut()), 0);
        assert!(stats.index_bytes <= stats.budget_bytes);
        assert_eq!(leanjson_source_v2_clear_indexes(source, ptr::null_mut()), 0);
        assert_eq!(lookup(held, b"dup", 0, &bytes).0.unwrap().kind, 1);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn wide_integer_object_retains_only_budgeted_targeted_results() {
    unsafe {
        let mut bytes = vec![b'{'];
        for index in 0..30000 {
            if index != 0 { bytes.push(b','); }
            bytes.extend_from_slice(format!("\"k{index}\":{index}").as_bytes());
        }
        bytes.push(b'}');
        for budget in [0, 1, 4096] {
            let source = parse(&bytes, budget, 0, 65536);
            let (value, reads) = lookup(root(source), b"k29999", 0, &bytes);
            let value = value.unwrap();
            assert_eq!(&bytes[value.raw_start as usize..value.raw_end as usize], b"29999");
            let (_, repeated_reads) = lookup(root(source), b"k29999", 0, &bytes);
            if budget > 1 { assert_eq!(repeated_reads, 0); }
            else { assert_eq!(repeated_reads, reads); }
            let mut stats = leanjson_source_v2_stats::default();
            assert_eq!(leanjson_source_v2_get_stats(source, &mut stats, ptr::null_mut()), 0);
            assert!(stats.index_bytes <= budget as u64);
            assert_eq!(stats.indexed_nodes, 0);
            let mut metadata = leanjson_source_v2_index_stats::default();
            assert_eq!(leanjson_source_v2_get_index_stats(source, &mut metadata, ptr::null_mut()), 0);
            assert_eq!(metadata.structural_index_bytes, 0);
            assert_eq!(metadata.lookup_cache_bytes, stats.index_bytes);
            assert!(metadata.lookup_cache_bytes < 1024, "one lookup must not cache 30000 siblings");
            leanjson_source_v1_release(source);
        }
    }
}

#[test]
fn structural_option_is_sealed_by_first_feed_even_when_empty() {
    unsafe {
        let source = leanjson_source_v2_new(ptr::null(), ptr::null_mut());
        assert_eq!(leanjson_source_v2_set_structural_index(source, 2, ptr::null_mut()), 5);
        assert_eq!(leanjson_source_v2_set_structural_index(source, 0, ptr::null_mut()), 0);
        assert_eq!(leanjson_source_v1_feed(source, 0, ptr::null(), 0, ptr::null_mut()), 2);
        assert_eq!(leanjson_source_v2_set_structural_index(source, 1, ptr::null_mut()), 5);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn disabled_structural_retention_preserves_demand_cache_and_full_validation() {
    unsafe {
        let bytes = long_document();
        let opts = leanjson_source_v2_options { index_depth: 0, window_size: 65536, ..Default::default() };
        let source = leanjson_source_v2_new(&opts, ptr::null_mut());
        assert_eq!(leanjson_source_v2_set_structural_index(source, 0, ptr::null_mut()), 0);
        assert_eq!(leanjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), ptr::null_mut()), 2);
        assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, ptr::null_mut()), 0);
        assert_eq!(leanjson_source_v2_set_structural_index(source, 1, ptr::null_mut()), 5);
        let (value, reads) = lookup(root(source), b"dup", 0, &bytes);
        assert_eq!(&bytes[value.unwrap().raw_start as usize..value.unwrap().raw_end as usize], b"7");
        assert_eq!(reads, bytes.len());
        assert_eq!(lookup(root(source), b"dup", 0, &bytes).1, 0);
        let mut stats = leanjson_source_v2_index_stats::default();
        assert_eq!(leanjson_source_v2_get_index_stats(source, &mut stats, ptr::null_mut()), 0);
        assert_eq!(stats.structural_index_bytes, 0);
        assert!(stats.lookup_cache_bytes > 0);
        assert_eq!((stats.lookup_cache_hits, stats.lookup_cache_misses), (1, 1));
        assert_eq!(leanjson_source_v2_clear_indexes(source, ptr::null_mut()), 0);
        assert_eq!(leanjson_source_v2_get_index_stats(source, &mut stats, ptr::null_mut()), 0);
        assert_eq!(stats.lookup_cache_bytes, 0);
        leanjson_source_v1_release(source);
        for enabled in [0, 1] {
            let source = leanjson_source_v2_new(&opts, ptr::null_mut());
            assert_eq!(leanjson_source_v2_set_structural_index(source, enabled, ptr::null_mut()), 0);
            let malformed = br#"["bad\uD800"]"#;
            let feed = leanjson_source_v1_feed(source, 0, malformed.as_ptr(), malformed.len(), ptr::null_mut());
            assert!(feed == 5 || leanjson_source_v1_finish(source, malformed.len() as u64, ptr::null_mut()) == 5);
            leanjson_source_v1_release(source);
        }
    }
}

#[test]
fn array_demand_results_beyond_automatic_prefix_and_aborted_hits_obey_lifecycle() {
    unsafe {
        let bytes = br#"[0,1,2,{"value":7}]"#;
        let source = parse(bytes, 4096, 0, 3);
        let node = root(source);
        let (value, first_reads) = lookup(node, b"", 3, bytes);
        assert_eq!(value.unwrap().kind, 5);
        assert!(first_reads > 0);
        assert_eq!(lookup(node, b"", 3, bytes).1, 0);
        assert!(lookup(node, b"", 99, bytes).0.is_none());
        assert!(lookup(node, b"", 99, bytes).0.is_none());
        let mut iter = ptr::null_mut();
        assert_eq!(leanjson_source_v2_lookup_begin(node, ptr::null(), 0, 3, &mut iter, ptr::null_mut()), 0);
        assert_eq!(leanjson_source_v1_abort(source, 2, ptr::null_mut()), 5);
        let mut member = leanjson_source_v2_member::default();
        assert_eq!(leanjson_source_v2_iter_next(iter, &mut member, ptr::null_mut()), 5);
        leanjson_source_v1_release(source);
        leanjson_source_v2_iter_release(iter);
    }
}

#[test]
fn one_byte_source_windows_keep_escaped_value_strings_and_decoded_keys_correct() {
    unsafe {
        let bytes = br#"{"a\"b":"\"\\\uD83D\uDE00","nested":["long\"string"],"a\u0022b":false}"#;
        let source = parse(bytes, 4096, 0, 1);
        let (value, reads) = lookup(root(source), b"a\"b", 0, bytes);
        assert_eq!(value.unwrap().kind, 1);
        assert!(reads < bytes.len() - 20);
        assert_eq!(lookup(root(source), b"a\"b", 0, bytes).1, 0);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn identical_in_flight_lookup_completions_preserve_existing_metadata_and_counters() {
    unsafe {
        let bytes = br#"{"body":"a long value", "x":1}"#;
        for (key, budget) in [(b"x".as_slice(), 180), (b"absent".as_slice(), 192)] {
            let source = parse(bytes, budget, 0, 65536);
            let mut first = ptr::null_mut();
            let mut second = ptr::null_mut();
            for output in [&mut first, &mut second] {
                assert_eq!(leanjson_source_v2_lookup_begin(root(source), key.as_ptr(), key.len(), 0, output, ptr::null_mut()), 0);
            }
            let mut before = leanjson_source_v2_index_stats::default();
            for (ordinal, iter) in [first, second].into_iter().enumerate() {
                let mut result = leanjson_source_v1_result::default();
                let mut member = leanjson_source_v2_member::default();
                let mut found = false;
                loop {
                    match leanjson_source_v2_iter_next(iter, &mut member, &mut result) {
                        0 => { assert!(!found); found = true; assert_eq!(member.value.kind, 2); },
                        1 => break,
                        3 => {
                            let start = result.offset as usize;
                            let length = result.length as usize;
                            assert_eq!(leanjson_source_v2_iter_provide_window(iter, result.offset,
                                bytes[start..start + length].as_ptr(), length, &mut result), 0);
                        },
                        status => panic!("status {status}: {result:?}"),
                    }
                }
                assert_eq!(found, key == b"x");
                leanjson_source_v2_iter_release(iter);
                let mut after = leanjson_source_v2_index_stats::default();
                assert_eq!(leanjson_source_v2_get_index_stats(source, &mut after, ptr::null_mut()), 0);
                assert_eq!((after.lookup_cache_hits, after.lookup_cache_misses), (0, 2));
                if ordinal == 0 {
                    assert!(after.structural_index_bytes > 0);
                    assert!(after.lookup_cache_bytes > 0);
                    before = after;
                } else {
                    assert_eq!(after.structural_index_bytes, before.structural_index_bytes,
                        "an already confirmed lookup must not evict structural metadata");
                    assert_eq!(after.lookup_cache_bytes, before.lookup_cache_bytes);
                }
            }
            assert_eq!(lookup(root(source), key, 0, bytes).1, 0);
            let mut stats = leanjson_source_v2_index_stats::default();
            assert_eq!(leanjson_source_v2_get_index_stats(source, &mut stats, ptr::null_mut()), 0);
            assert_eq!((stats.lookup_cache_hits, stats.lookup_cache_misses), (1, 2));
            leanjson_source_v1_release(source);
        }
    }
}
