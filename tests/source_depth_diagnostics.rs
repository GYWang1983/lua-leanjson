//! Public wording is additive: the original source result tuple is available
//! unchanged to callers that need machine-readable strict validation errors.
use leanjson::source_ffi::*;
use std::ptr;

unsafe fn formatted(source: *const leanjson_source_v1) -> String {
    let length = leanjson_source_v2_format_error(source, ptr::null_mut(), 0);
    let mut bytes = vec![0; length + 1];
    assert_eq!(length, leanjson_source_v2_format_error(source, bytes.as_mut_ptr(), bytes.len()));
    String::from_utf8(bytes[..length].to_vec()).unwrap()
}

#[test]
fn diagnostics_preserve_original_result_tuple_at_every_split() {
    unsafe {
        let bytes = br#"{"a" "bad\q"}"#;
        for split in 0..=bytes.len() {
            let mut result = leanjson_source_v1_result::default();
            let options = leanjson_source_v2_options { mode: 3, max_depth: 1000, ..Default::default() };
            let source = leanjson_source_v2_new(&options, &mut result);
            assert!(!source.is_null());
            let mut status = leanjson_source_v1_feed(source, 0, bytes.as_ptr(), split, &mut result);
            if status == 2 { status = leanjson_source_v1_feed(source, split as u64, bytes.as_ptr().add(split), bytes.len() - split, &mut result); }
            if status == 2 { status = leanjson_source_v1_finish(source, bytes.len() as u64, &mut result); }
            assert_eq!(5, status);
            assert_eq!((1, 0, 5), (result.code, result.detail, result.offset));
            assert_eq!("Expected colon but found invalid escape code at character 10", formatted(source));
            leanjson_source_v1_release(source);
        }
    }
}

#[test]
fn v2_accepts_real_depth_above4096_without_retaining_deep_indexes() {
    unsafe {
        let bytes = format!("{}0{}", "[".repeat(5000), "]".repeat(5000)).into_bytes();
        let mut result = leanjson_source_v1_result::default();
        let options = leanjson_source_v2_options { max_depth: 6000, index_depth: 0, index_budget_bytes: 0, ..Default::default() };
        let source = leanjson_source_v2_new(&options, &mut result);
        assert!(!source.is_null());
        for (index, chunk) in bytes.chunks(37).enumerate() { assert_eq!(2, leanjson_source_v1_feed(source, (index * 37) as u64, chunk.as_ptr(), chunk.len(), &mut result)); }
        assert_eq!(0, leanjson_source_v1_finish(source, bytes.len() as u64, &mut result));
        assert_eq!("", formatted(source));
        let mut stats = leanjson_source_v2_stats::default();
        assert_eq!(0, leanjson_source_v2_get_stats(source, &mut stats, &mut result));
        assert_eq!((0, 0, 0), (stats.index_bytes, stats.indexed_nodes, stats.indexed_depth));
        leanjson_source_v1_release(source);
    }
}

#[test]
fn original_legacy_source_depth_clamp_remains_separate() {
    unsafe {
        let bytes = format!("{}0{}", "[".repeat(4097), "]".repeat(4097)).into_bytes();
        let mut result = leanjson_source_v1_result::default();
        let options = leanjson_source_v1_options { max_depth: 6000, ..Default::default() };
        let source = leanjson_source_v1_new(&options, &mut result);
        assert_eq!(5, leanjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), &mut result));
        assert_eq!((9, 4096), (result.code, result.offset));
        leanjson_source_v1_release(source);
    }
}

#[test]
fn comment_errors_match_native_diagnostics_at_every_split() {
    unsafe {
        for (bytes, expected, code, offset) in [
            (b"{}/*Unclosed".as_slice(), "Expected the end but found unclosed multi-line comment at character 13", 1, 12),
            (b"[1/*x*/0]", "Expected comma or array end but found T_INTEGER at character 8", 1, 7),
            (b"[tru/*x*/e]", "Expected value but found invalid token at character 2", 1, 4),
            (b"/", "Expected value but found invalid token at character 1", 1, 0),
        ] {
            for split in 0..=bytes.len() {
                let mut result = leanjson_source_v1_result::default();
                let options = leanjson_source_v2_options { mode: 7, ..Default::default() };
                let source = leanjson_source_v2_new(&options, &mut result);
                assert!(!source.is_null(), "{result:?}");
                let mut status = leanjson_source_v1_feed(source, 0, bytes.as_ptr(), split, &mut result);
                if status == 2 { status = leanjson_source_v1_feed(source, split as u64, bytes.as_ptr().add(split), bytes.len()-split, &mut result); }
                if status == 2 { status = leanjson_source_v1_finish(source, bytes.len() as u64, &mut result); }
                assert_eq!(status, 5, "{bytes:?} split {split}");
                assert_eq!((result.code, result.detail, result.offset), (code, 0, offset), "{bytes:?} split {split}");
                assert_eq!(formatted(source), expected, "{bytes:?} split {split}");
                leanjson_source_v1_release(source);
            }
        }
    }
}
