//! Memory scanning must preserve the existing span ABI and validation policy.
use std::ptr;
use leanjson::source_ffi::*;

struct Handle(*mut leanjson_source_v1);
impl Drop for Handle { fn drop(&mut self) { unsafe { leanjson_source_v1_release(self.0); } } }

unsafe fn message(source: *mut leanjson_source_v1) -> String {
    let len = leanjson_source_v2_format_error(source, ptr::null_mut(), 0);
    let mut bytes = vec![0; len + 1];
    leanjson_source_v2_format_error(source, bytes.as_mut_ptr(), bytes.len());
    String::from_utf8(bytes[..len].to_vec()).unwrap()
}

#[derive(Debug, PartialEq)]
struct Outcome { status: i32, code: i32, detail: u32, offset: u64, message: String, root: Option<(u32, u32, u64, u64, u64)> }

unsafe fn parse(bytes: &[u8], mode: u32, split: usize, fast: bool) -> Outcome {
    let options = leanjson_source_v2_options { mode, window_size: 7, ..Default::default() };
    let mut result = leanjson_source_v1_result::default();
    let source = Handle(leanjson_source_v2_new(&options, &mut result));
    assert!(!source.0.is_null());
    if fast { assert_eq!(leanjson_source_v2_set_scanner(source.0, 1, &mut result), 0); }
    let mut status = 2;
    for (base, len) in [(0, split), (split, bytes.len() - split)] {
        status = if fast { leanjson_source_v2_feed_memory(source.0, bytes.as_ptr(), bytes.len(), base as u64, len, &mut result) }
            else { leanjson_source_v1_feed(source.0, base as u64, bytes.as_ptr().add(base), len, &mut result) };
        if status != 2 { break; }
    }
    if status == 2 {
        status = if fast { leanjson_source_v2_finish_memory(source.0, bytes.as_ptr(), bytes.len(), &mut result) }
            else { leanjson_source_v1_finish(source.0, bytes.len() as u64, &mut result) };
    }
    let root = if status == 0 {
        let mut root = leanjson_source_v2_node::default();
        assert_eq!(leanjson_source_v2_root(source.0, &mut root, ptr::null_mut()), 0);
        Some((root.kind, root.flags, root.raw_start, root.raw_end, root.child_count))
    } else { None };
    Outcome { status, code: result.code, detail: result.detail, offset: result.offset, message: message(source.0), root }
}

#[test]
fn memory_scanner_matches_spans_flags_and_errors_at_every_boundary() {
    let fixtures: &[&[u8]] = &[
        br#"{"model":"x/y","messages":[{"text":"a\n\u4e2d\ud83d\ude00\u007f"}],"model":"last"}"#,
        b"\"hello/\x7f\xff\xe4\xb8\xad\"", b"[0,-0,1.5,1e9999,1.7976931348623159e308]",
        b"[+12,0123,-.5,0x6.ffp1,NaN,-Inf,nan(payload)]", b"/*a*/{\"k\":1}/*end*/",
        b"", b" ", b"[1,]", b"{\"x\":1,,}", b"[tru/*x*/e]", b"[1/*x*/0]", b"{}/*Unclosed",
        b"[NaNx]", b"[0x1g]", b"[1e+]", b"true false", b"\"unclosed", b"\"\x00\"", b"\"\xff\"",
        br#""\uD800""#, br#""\uD800\u0020""#, br#""\u12zz""#, br#""\z""#,
        b"[\"\xe0\x80\x80\"]", b"[\"\xf4\x90\x80\x80\"]", b"[\"\xc2\"]", b"\x00\x00",
    ];
    unsafe {
        for bytes in fixtures {
            for mode in 0..8 {
                let expected = parse(bytes, mode, bytes.len(), false);
                for split in 0..=bytes.len() {
                    assert_eq!(parse(bytes, mode, split, true), expected, "bytes={bytes:?} mode={mode} split={split}");
                }
            }
        }
    }
}

#[test]
fn large_unselected_string_keeps_bounded_metadata_and_original_offsets() {
    let bytes = format!("{{\"model\":\"m\",\"prompt\":\"{}\"}}", "x".repeat(2 * 1024 * 1024));
    unsafe {
        let options = leanjson_source_v2_options { mode: 3, index_budget_bytes: 128, ..Default::default() };
        let source = Handle(leanjson_source_v2_new(&options, ptr::null_mut()));
        assert_eq!(leanjson_source_v2_set_scanner(source.0, 1, ptr::null_mut()), 0);
        for base in (0..bytes.len()).step_by(65536) {
            assert_eq!(leanjson_source_v2_feed_memory(source.0, bytes.as_ptr(), bytes.len(), base as u64, (bytes.len()-base).min(65536), ptr::null_mut()), 2);
        }
        assert_eq!(leanjson_source_v2_finish_memory(source.0, bytes.as_ptr(), bytes.len(), ptr::null_mut()), 0);
        let mut stats = leanjson_source_v2_stats::default();
        assert_eq!(leanjson_source_v2_get_stats(source.0, &mut stats, ptr::null_mut()), 0);
        assert!(stats.index_bytes <= 128, "{stats:?}");
        let mut root = leanjson_source_v2_node::default();
        assert_eq!(leanjson_source_v2_root(source.0, &mut root, ptr::null_mut()), 0);
        assert_eq!((root.kind, root.raw_start, root.raw_end, root.child_count), (5, 0, bytes.len() as u64, 2));
    }
}

#[test]
fn memory_feed_rejects_out_of_bounds_ranges_without_reading_them() {
    unsafe {
        for (base, len) in [(3, 0), (0, 3), (1, usize::MAX), (u64::MAX, 1)] {
            let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
            let mut result = leanjson_source_v1_result::default();
            assert_eq!(leanjson_source_v2_feed_memory(source.0, b"{}".as_ptr(), 2, base, len, &mut result), 5);
            assert_eq!(result.detail, 5);
        }
        let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
        assert_eq!(leanjson_source_v2_feed_memory(source.0, ptr::null(), 1, 0, 1, ptr::null_mut()), 5);
        assert_eq!(leanjson_source_v2_finish_memory(ptr::null_mut(), ptr::null(), 0, ptr::null_mut()), 5);
    }
}

#[test]
fn source_rejects_mixing_memory_and_ordinary_feeds() {
    unsafe {
        for memory_first in [true, false] {
            let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
            if memory_first {
                assert_eq!(leanjson_source_v2_feed_memory(source.0, b"{}".as_ptr(), 2, 0, 1, ptr::null_mut()), 2);
                assert_eq!(leanjson_source_v1_feed(source.0, 1, b"}".as_ptr(), 1, ptr::null_mut()), 5);
            } else {
                assert_eq!(leanjson_source_v1_feed(source.0, 0, b"{".as_ptr(), 1, ptr::null_mut()), 2);
                assert_eq!(leanjson_source_v2_feed_memory(source.0, b"{}".as_ptr(), 2, 1, 1, ptr::null_mut()), 5);
            }
        }
    }
}

#[test]
fn streaming_fast_scan_preserves_diagnostics_across_every_split() {
    unsafe {
        for bytes in [b"{\"a\":\"plain/\x7f\xe4\xb8\xad\\u4e2d\",\"n\":1}".as_slice(),
            b"\"x\x00\"", b"{}/*Unclosed", b"[1/*x*/0]", b"[tru/*x*/e]", b"\"\\uD800\"", b"\"\\z\"", b"[0x1g]", b"\x00\x00"] {
            for mode in 0..8 {
                let expected = parse(bytes, mode, bytes.len(), false);
                for split in 0..=bytes.len() {
                    let options = leanjson_source_v2_options { mode, ..Default::default() };
                    let source = Handle(leanjson_source_v2_new(&options, ptr::null_mut()));
                    let mut result = leanjson_source_v1_result::default();
                    assert_eq!(leanjson_source_v2_set_scanner(source.0, 1, &mut result), 0);
                    let mut status = leanjson_source_v1_feed(source.0, 0, bytes.as_ptr(), split, &mut result);
                    if status == 2 { status = leanjson_source_v1_feed(source.0, split as u64, bytes.as_ptr().add(split), bytes.len()-split, &mut result); }
                    if status == 2 { status = leanjson_source_v1_finish(source.0, bytes.len() as u64, &mut result); }
                    assert_eq!(status, expected.status, "{bytes:?} mode={mode} split={split}");
                    assert_eq!((result.code, result.detail, result.offset), (expected.code, expected.detail, expected.offset));
                    assert_eq!(message(source.0), expected.message);
                }
            }
        }
    }
}

#[test]
fn scanner_selection_is_validated_and_frozen_before_empty_first_feed() {
    unsafe {
        let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
        assert_eq!(leanjson_source_v2_set_scanner(source.0, 2, ptr::null_mut()), 5);
        assert_eq!(leanjson_source_v2_set_scanner(source.0, 1, ptr::null_mut()), 0);
        assert_eq!(leanjson_source_v1_feed(source.0, 0, ptr::null(), 0, ptr::null_mut()), 2);
        assert_eq!(leanjson_source_v2_set_scanner(source.0, 0, ptr::null_mut()), 5);
    }
}

proptest::proptest! {
    #[test]
    fn arbitrary_string_bytes_match_the_legacy_validator(
        body in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..1024),
        split in proptest::prelude::any::<usize>(), mode in 0u32..8,
    ) {
        let mut bytes = b"{\"key\":\"".to_vec();
        bytes.extend_from_slice(&body); bytes.extend_from_slice(b"\"}");
        let split = split % (bytes.len()+1);
        unsafe { proptest::prop_assert_eq!(parse(&bytes, mode, split, true), parse(&bytes, mode, split, false)); }
    }

    #[test]
    fn escaped_unicode_keys_and_values_keep_identical_spans(
        key in proptest::collection::vec(proptest::prelude::any::<char>(), 0..80),
        value in proptest::collection::vec(proptest::prelude::any::<char>(), 0..300),
        split in proptest::prelude::any::<usize>(),
    ) {
        let key: String = key.into_iter().collect();
        let value: String = value.into_iter().collect();
        let bytes = serde_json::to_vec(&serde_json::json!({key: value})).unwrap();
        unsafe { proptest::prop_assert_eq!(parse(&bytes, 0, split % (bytes.len()+1), true), parse(&bytes, 0, bytes.len(), false)); }
    }
}

#[test]
fn deferred_json_diagnostics_never_replace_source_argument_or_close_errors() {
    unsafe {
        let bytes = b"[1,]";
        // The first call fails on its offset, before validating any JSON.
        let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
        let mut result = leanjson_source_v1_result::default();
        assert_eq!(leanjson_source_v2_feed_memory(source.0, bytes.as_ptr(), bytes.len(), 1, 1, &mut result), 5);
        assert_eq!(result.detail, 5);
        assert_eq!(message(source.0), "");

        // Likewise, premature EOF is a source range error, not malformed JSON.
        let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
        assert_eq!(leanjson_source_v2_feed_memory(source.0, bytes.as_ptr(), bytes.len(), 0, 1, &mut result), 2);
        assert_eq!(leanjson_source_v2_finish_memory(source.0, bytes.as_ptr(), bytes.len(), &mut result), 5);
        assert_eq!(result.detail, 5);
        assert_eq!(message(source.0), "");

        let source = Handle(leanjson_source_v2_new(ptr::null(), ptr::null_mut()));
        assert_eq!(leanjson_source_v2_feed_memory(source.0, bytes.as_ptr(), bytes.len(), 0, 1, &mut result), 2);
        assert_eq!(leanjson_source_v1_abort(source.0, 3, &mut result), 5);
        assert_eq!(leanjson_source_v2_feed_memory(source.0, bytes.as_ptr(), bytes.len(), 1, 1, &mut result), 5);
        assert_eq!(result.detail, 3);
        assert_eq!(message(source.0), "");
    }
}
