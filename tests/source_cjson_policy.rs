use std::ptr;
use leanjson::error::{leanjson_err as E, leanjson_type as T};
use leanjson::source::{DETAIL_BAD_OPTIONS, SPAN_CLEAN, SPAN_DUPLICATES};
use leanjson::source_ffi::*;

const STRING_ESCAPE: u32 = 4;
const NONFINITE: u32 = 8;

unsafe fn parse(bytes: &[u8], mode: u32, split: usize, prefix: u32) -> Result<*mut leanjson_source_v1, leanjson_source_v1_result> {
    let options = leanjson_source_v2_options { mode, window_size: 3, index_depth: 3,
        index_array_limit: prefix, index_budget_bytes: if prefix == 0 { 0 } else { 1048576 }, ..Default::default() };
    let mut result = leanjson_source_v1_result::default();
    let source = leanjson_source_v2_new(&options, &mut result);
    if source.is_null() { return Err(result); }
    for (offset, chunk) in [(0, &bytes[..split]), (split, &bytes[split..])] {
        if leanjson_source_v1_feed(source, offset as u64, chunk.as_ptr(), chunk.len(), &mut result) != 2 {
            leanjson_source_v1_release(source); return Err(result);
        }
    }
    if leanjson_source_v1_finish(source, bytes.len() as u64, &mut result) != 0 {
        leanjson_source_v1_release(source); return Err(result);
    }
    Ok(source)
}
unsafe fn root(source: *mut leanjson_source_v1) -> leanjson_source_v2_node {
    let mut node = leanjson_source_v2_node::default();
    assert_eq!(leanjson_source_v2_root(source, &mut node, ptr::null_mut()), 0);
    node
}
unsafe fn next(iter: *mut leanjson_source_v2_iter, bytes: &[u8]) -> Option<(Vec<u8>, leanjson_source_v2_node, u32)> {
    let mut result = leanjson_source_v1_result::default();
    let mut member = leanjson_source_v2_member::default();
    let mut current = 99;
    loop {
        match leanjson_source_v2_iter_next_current(iter, &mut member, &mut current, &mut result) {
            0 => return Some((std::slice::from_raw_parts(member.key, member.key_len).to_vec(), member.value, current)),
            1 => return None,
            3 => {
                assert_eq!(current, 0);
                let offset = result.offset as usize;
                // One-byte windows force every resumed token state to survive a boundary.
                assert_eq!(leanjson_source_v2_iter_provide_window(iter, result.offset, bytes[offset..offset+1].as_ptr(), 1, &mut result), 0, "{result:?}");
            },
            status => panic!("iterator status {status}: {result:?}"),
        }
    }
}
unsafe fn members(node: leanjson_source_v2_node, bytes: &[u8], mode: u32) -> Vec<(Vec<u8>, leanjson_source_v2_node, u32)> {
    let mut iter = ptr::null_mut();
    assert_eq!(leanjson_source_v2_iter_begin(node, mode, &mut iter, ptr::null_mut()), 0);
    let mut output = Vec::new();
    while let Some(member) = next(iter, bytes) { output.push(member); }
    leanjson_source_v2_iter_release(iter);
    output
}
unsafe fn scalar(node: leanjson_source_v2_node, bytes: &[u8]) -> Vec<u8> {
    let mut op = ptr::null_mut();
    let mut result = leanjson_source_v1_result::default();
    assert!(matches!(leanjson_source_v2_node_scalar_begin(node, &mut op, &mut result), 1 | 3));
    let mut output = Vec::new();
    loop {
        let mut pointer = ptr::null(); let mut len = 0;
        match leanjson_source_v1_op_step(op, &mut pointer, &mut len, &mut result) {
            0 => output.extend_from_slice(std::slice::from_raw_parts(pointer, len)),
            1 => break,
            3 => {
                let offset = result.offset as usize;
                assert_eq!(leanjson_source_v1_provide_window(op, result.offset, bytes[offset..offset+1].as_ptr(), 1, &mut result), 0, "{result:?}");
            },
            status => panic!("scalar status {status}: {result:?}"),
        }
    }
    leanjson_source_v1_op_release(op);
    output
}

// Catches missing policy admission, split decimal/hex/special state, and token suffix acceptance.
#[test]
fn permissive_numbers_match_pinned_native_grammar_at_every_split() {
    let valid = ["+12", "0123", "-000.5", "1.", "1.e+2", "-.5", "+.5", "0x6.ffp1", "-0x.8P-2", "0x1.", "0x2a", "NaN", "-nan", "+NAN", "Inf", "-iNfInItY", "nan(payload_12)", "NaN()", "1e9999"];
    unsafe {
        for token in valid {
            let bytes = format!("[{token}]").into_bytes();
            for split in 0..=bytes.len() {
                let source = parse(&bytes, 1, split, 0).unwrap_or_else(|e| panic!("rejected {token}, split {split}: {e:?}"));
                let children = members(root(source), &bytes, 0);
                assert_eq!(children.len(), 1);
                assert_eq!(children[0].1.kind, T::LEANJSON_T_NUM as u32);
                assert_eq!(scalar(children[0].1, &bytes), token.as_bytes());
                leanjson_source_v1_release(source);
            }
        }
        for token in [".5", "0X1", "00x2", "0x", "0x.p2", "0x1p", "0x1p+", "NaNx", "Infinityy", "nan(bad-payload)", "nan(unfinished", "+", "--1", "+-1", "1e", "1e+", "1z", "0x1g"] {
            let bytes = format!("[{token}]").into_bytes();
            for split in 0..=bytes.len() {
                let error = parse(&bytes, 1, split, 0).expect_err("invalid numeric token accepted");
                let code = if token == ".5" { E::LEANJSON_PARSE_ERROR } else { E::LEANJSON_INVALID_NUMBER };
                assert_eq!((error.code, error.detail, error.offset), (code as i32, 0, 1), "{token}, split {split}");
            }
        }
    }
}

// Zero source mode and the legacy v1 constructor must retain RFC number ABNF.
#[test]
fn zero_mode_and_v1_keep_strict_numbers() {
    unsafe {
        for (token, expected_code, expected_offset) in [
            ("+12", E::LEANJSON_PARSE_ERROR, 1), ("0123", E::LEANJSON_INVALID_NUMBER, 1),
            ("1.", E::LEANJSON_INVALID_NUMBER, 1), ("-.5", E::LEANJSON_INVALID_NUMBER, 1),
            ("0x1", E::LEANJSON_INVALID_NUMBER, 1), ("NaN", E::LEANJSON_PARSE_ERROR, 1),
            ("nan", E::LEANJSON_PARSE_ERROR, 2), ("Inf", E::LEANJSON_PARSE_ERROR, 1),
            ("-Infinity", E::LEANJSON_INVALID_NUMBER, 1),
        ] {
            let bytes = format!("[{token}]").into_bytes();
            for split in 0..=bytes.len() {
                let error = parse(&bytes, 0, split, 0).unwrap_err();
                assert_eq!(error.detail, 0, "{token}: {error:?}");
                assert_eq!((error.code, error.offset), (expected_code as i32, expected_offset), "{token}");
            }
            let mut result = leanjson_source_v1_result::default();
            let source = leanjson_source_v1_new(ptr::null(), &mut result);
            assert!(!source.is_null());
            assert_eq!(leanjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), &mut result), 5, "{token}");
            leanjson_source_v1_release(source);
        }
        for token in ["0", "-0", "1.5e+7", "1e9999"] {
            let source = parse(token.as_bytes(), 0, 0, 0).unwrap();
            leanjson_source_v1_release(source);
        }
    }
}

// Byte admission must reach both indexed-key readers and unindexed/replayed walkers.
#[test]
fn raw_bytes_roundtrip_in_values_keys_and_duplicate_normalization() {
    let bytes = b"{\"\xff/\":{\"\xfe\":\"\xc0\xaf\\uD834\\uDD1E\"},\"\xff/\":\"\x80\",\"last\":[0,1,2,\"\xf5\x7f\"]}";
    unsafe {
        for prefix in [0, 1, 3] {
            for split in 0..=bytes.len() {
                let source = parse(bytes, 2, split, prefix).unwrap();
                let lexical = members(root(source), bytes, 0);
                assert_eq!(lexical[0].0, b"\xff/");
                let nested = members(lexical[0].1, bytes, 0);
                assert_eq!(nested[0].0, b"\xfe");
                assert_eq!(scalar(nested[0].1, bytes), b"\xc0\xaf\xf0\x9d\x84\x9e");
                let mut lookup = ptr::null_mut();
                assert_eq!(leanjson_source_v2_lookup_begin(root(source), b"\xff/".as_ptr(), 2, 0, &mut lookup, ptr::null_mut()), 0);
                let found = next(lookup, bytes).unwrap();
                assert_eq!(found.0, b"\xff/");
                assert_eq!(scalar(found.1, bytes), b"\x80");
                assert!(next(lookup, bytes).is_none());
                leanjson_source_v2_iter_release(lookup);
                let normalized = members(root(source), bytes, 1);
                assert_eq!(normalized.len(), 2);
                assert_eq!(scalar(normalized[0].1, bytes), b"\x80");
                let replay = members(root(source), bytes, 2);
                assert_eq!(replay.iter().map(|m| m.2).collect::<Vec<_>>(), [0, 1, 1]);
                let array = members(lexical[2].1, bytes, 0);
                assert_eq!(scalar(array[3].1, bytes), b"\xf5\x7f");
                leanjson_source_v1_release(source);
            }
        }
        for mode in [0, 1] {
            let error = parse(bytes, mode, 1, 0).unwrap_err();
            assert_eq!(error.code, E::LEANJSON_INVALID_UTF8 as i32);
            assert_eq!(error.offset, 1);
        }
    }
}

// Raw byte mode must not bypass escape/control validation.
#[test]
fn unicode_escape_and_surrogate_validation_remains_mandatory_in_byte_mode() {
    unsafe {
        for mode in [0, 1, 2, 3] {
            for bytes in [br#""\uD800""#.as_slice(), br#""\uDC00""#, br#""\uD800\u0041""#, br#""\u12xz""#, br#""\q""#, b"\"\x01\""] {
                for split in 0..=bytes.len() {
                    let error = parse(bytes, mode, split, 0).unwrap_err();
                    assert_eq!(error.code, E::LEANJSON_INVALID_STRING as i32, "{bytes:?}, mode {mode}: {error:?}");
                    assert_eq!(error.offset, 0);
                }
            }
        }
    }
}

// Escape/nonfinite metadata cannot poison duplicate-cleanliness or disappear on resumed walks.
#[test]
fn string_key_and_number_flags_propagate_independently_of_duplicate_flags() {
    let bytes = br#"[{"/":{"s":"\u007f","n":1e9999}},{"s":"\u002f"},{"n":NaN},{"x":1,"x":2}]"#;
    unsafe {
        for prefix in [0, 1, 3] {
            let source = parse(bytes, 1, 5, prefix).unwrap();
            let root = root(source);
            assert_eq!(root.flags & (STRING_ESCAPE | NONFINITE), STRING_ESCAPE | NONFINITE);
            let lexical = members(root, bytes, 0);
            assert_eq!(lexical[0].1.flags & (STRING_ESCAPE | NONFINITE), STRING_ESCAPE | NONFINITE);
            assert_eq!(lexical[1].1.flags & STRING_ESCAPE, STRING_ESCAPE);
            assert_eq!(lexical[2].1.flags & NONFINITE, NONFINITE);
            // Initial cached containers intentionally have unknown duplicate
            // status. Rescan to prove cleanliness independently of flags 4/8.
            assert_eq!(leanjson_source_v2_clear_indexes(source, ptr::null_mut()), 0);
            let checked = members(root, bytes, 1);
            assert_eq!(checked[0].1.flags & (SPAN_CLEAN | SPAN_DUPLICATES), SPAN_CLEAN);
            assert_eq!(checked[1].1.flags & (SPAN_CLEAN | SPAN_DUPLICATES), SPAN_CLEAN);
            assert_eq!(checked[2].1.flags & (SPAN_CLEAN | SPAN_DUPLICATES), SPAN_CLEAN);
            assert_eq!(checked[3].1.flags & (SPAN_CLEAN | SPAN_DUPLICATES), SPAN_DUPLICATES);
            let inner = members(members(checked[0].1, bytes, 1)[0].1, bytes, 1);
            assert_eq!(inner[0].1.flags, SPAN_CLEAN | STRING_ESCAPE);
            assert_eq!(inner[1].1.flags, SPAN_CLEAN | NONFINITE);
            leanjson_source_v1_release(source);
        }
    }
}

#[test]
fn overflow_flags_distinguish_finite_boundaries_and_huge_cancelled_exponents() {
    unsafe {
        for (token, nonfinite) in [
            ("1.7976931348623157e308", false), ("1.7976931348623158e308", false),
            ("1.7976931348623159e308", true), ("-1e9999999999999999999999999999999", true),
            ("0e9999999999999999999999999999999", false), ("1e-9999999999999999999999999999999", false),
            ("0x1.fffffffffffff7p1023", false), ("0x1.fffffffffffff8p1023", true),
            ("0x0p9999999999999999999999999999999", false), ("0x1p1024", true),
        ] {
            let source = parse(token.as_bytes(), 1, token.len()/2, 0).unwrap();
            assert_eq!(root(source).flags & NONFINITE != 0, nonfinite, "{token}");
            leanjson_source_v1_release(source);
        }
        let token = format!("{}e-8000", "9".repeat(8192));
        let source = parse(token.as_bytes(), 1, 5000, 0).unwrap();
        assert_eq!(root(source).flags & NONFINITE, 0);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn v2_mode_rejects_unknown_bits_and_v1_does_not_admit_v2_flags() {
    unsafe {
        for mode in [8, 9, 12, u32::MAX] {
            let mut result = leanjson_source_v1_result::default();
            let source = leanjson_source_v2_new(&leanjson_source_v2_options { mode, ..Default::default() }, &mut result);
            assert!(source.is_null());
            assert_eq!((result.code, result.detail), (E::LEANJSON_INVALID_ARG as i32, DETAIL_BAD_OPTIONS));
        }
        for mode in [1, 2, 3, 4, 7] {
            let mut result = leanjson_source_v1_result::default();
            let source = leanjson_source_v1_new(&leanjson_source_v1_options { mode, ..Default::default() }, &mut result);
            assert!(source.is_null());
            assert_eq!(result.detail, DETAIL_BAD_OPTIONS);
        }
    }
}

#[test]
fn saturated_plain_decimal_integers_are_finite_for_bounded_output() {
    unsafe {
        for sign in ["", "-", "+"] {
            let token = format!("{sign}{}", "9".repeat(1048576));
            let source = parse(token.as_bytes(), 1, 4096, 0).unwrap();
            assert_eq!(root(source).flags & NONFINITE, 0);
            leanjson_source_v1_release(source);
        }
    }
}


// Feed-time construction must use the same byte policy and END metadata as late reads.
#[test]
fn eager_and_preload_events_keep_byte_keys_and_flags() {
    let bytes = b"{\"\xff/\":{\"v\":\"\x80\\u007f\",\"n\":-Infinity}}";
    unsafe {
        for eager in [0, 1] {
            let options = leanjson_source_v2_options { mode: 3, window_size: 1, ..Default::default() };
            let mut result = leanjson_source_v1_result::default();
            let source = leanjson_source_v2_new(&options, &mut result);
            assert!(!source.is_null(), "{result:?}");
            let path = b"$[*]";
            let mut encoded = (path.len() as u32).to_le_bytes().to_vec(); encoded.extend_from_slice(path);
            let selector = leanjson_source_v2_selector_new(encoded.as_ptr(), encoded.len(), &mut result);
            assert!(!selector.is_null());
            assert_eq!(leanjson_source_v2_set_loading(source, selector, eager, &mut result), 0);
            leanjson_source_v2_selector_release(selector);
            let mut keys = Vec::new(); let mut data = Vec::new(); let mut ends = Vec::new();
            for offset in 0..=bytes.len() {
                if offset == bytes.len() { assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, &mut result), 0, "{result:?}"); }
                else { assert_eq!(leanjson_source_v1_feed(source, offset as u64, bytes[offset..offset+1].as_ptr(), 1, &mut result), 2, "{result:?}"); }
                loop {
                    let mut event = leanjson_source_v2_loading_event::default();
                    match leanjson_source_v2_next_loading_event(source, &mut event, &mut result) {
                        0 => match event.event {
                            1 if event.key_len != 0 => keys.push(std::slice::from_raw_parts(event.key, event.key_len).to_vec()),
                            2 => data.extend_from_slice(std::slice::from_raw_parts(event.bytes, event.bytes_len)),
                            3 => ends.push((event.kind, event.flags)),
                            _ => {},
                        },
                        1 => break,
                        status => panic!("loading status {status}: {result:?}"),
                    }
                }
            }
            assert!(keys.contains(&b"\xff/".to_vec()));
            assert_eq!(data, b"\x80\x7f-Infinity");
            assert!(ends.contains(&(T::LEANJSON_T_STR as u32, SPAN_CLEAN | STRING_ESCAPE)));
            assert!(ends.contains(&(T::LEANJSON_T_NUM as u32, SPAN_CLEAN | NONFINITE)));
            assert_eq!(root(source).flags & (STRING_ESCAPE | NONFINITE), STRING_ESCAPE | NONFINITE);
            leanjson_source_v1_release(source);
        }
    }
}


#[test]
fn v1_operation_on_v2_root_uses_its_source_byte_policy() {
    let bytes = b"\"\xff\\u00e9\"";
    unsafe {
        let source = parse(bytes, 2, 2, 0).unwrap();
        let mut node = leanjson_source_v1_node::default();
        assert_eq!(leanjson_source_v1_root(source, &mut node, ptr::null_mut()), 0);
        let mut op = ptr::null_mut();
        let mut result = leanjson_source_v1_result::default();
        assert_eq!(leanjson_source_v1_node_scalar_begin(node, &mut op, &mut result), 3);
        let mut output = Vec::new();
        loop {
            let mut pointer = ptr::null(); let mut len = 0;
            match leanjson_source_v1_op_step(op, &mut pointer, &mut len, &mut result) {
                0 => output.extend_from_slice(std::slice::from_raw_parts(pointer, len)),
                1 => break,
                3 => {
                    let offset = result.offset as usize;
                    assert_eq!(leanjson_source_v1_provide_window(op, result.offset, bytes[offset..offset+1].as_ptr(), 1, &mut result), 0);
                },
                status => panic!("operation status {status}: {result:?}"),
            }
        }
        assert_eq!(output, b"\xff\xc3\xa9");
        leanjson_source_v1_op_release(op);
        leanjson_source_v1_release(source);
    }
}

// A comment policy must survive initial feed splits and unindexed late walkers,
// mark only affected spans, and leave strict C zero/v1 modes unchanged.
#[test]
fn comments_are_bounded_trivia_with_precise_span_flags_and_late_policy() {
    const COMMENTS: u32 = 16;
    let bytes = b"/*lead*/{\"a\":{/*empty*/},\"clean\":{ \"n\" : 1.00 },\"list\":[//x\r\n1/*end*/,true],\"s\":\"/*text*/\"}//tail";
    unsafe {
        for prefix in [0, 3] {
            for split in 0..=bytes.len() {
                let source = parse(bytes, 7, split, prefix).unwrap_or_else(|error| panic!("split {split}: {error:?}"));
                let parent = root(source);
                assert_eq!((parent.raw_start, parent.raw_end), (8, bytes.len() as u64 - 6));
                assert_ne!(parent.flags & COMMENTS, 0);
                let children = members(parent, bytes, 0);
                assert_eq!(children.len(), 4);
                assert_ne!(children[0].1.flags & COMMENTS, 0);
                assert_eq!(children[0].1.child_count, 0);
                assert_eq!(children[1].1.flags & COMMENTS, 0);
                assert_ne!(children[2].1.flags & COMMENTS, 0);
                let list = members(children[2].1, bytes, 0);
                assert_eq!(scalar(list[0].1, bytes), b"1");
                assert_eq!(scalar(list[1].1, bytes), b"true");
                assert_eq!(scalar(children[3].1, bytes), b"/*text*/");
                leanjson_source_v1_release(source);
            }
        }
        assert!(parse(bytes, 0, 3, 0).is_err());
        for bytes in [b"/*\xff*/1".as_slice(), b"[/*\xfe*/1]", b"true//\xff\r", b"1/*x*//*y*/"] {
            for split in 0..=bytes.len() {
                let source = parse(bytes, 4, split, 0).unwrap_or_else(|error| panic!("{bytes:?} split {split}: {error:?}"));
                leanjson_source_v1_release(source);
            }
        }
        let mut result = leanjson_source_v1_result::default();
        let source = leanjson_source_v1_new(ptr::null(), &mut result);
        assert_eq!(leanjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), &mut result), 5);
        leanjson_source_v1_release(source);
        for bytes in [b"[1/*x*/0]".as_slice(), b"[tru/*x*/e]", b"[1e/*x*/2]", b"/*unclosed", b"/"] {
            for split in 0..=bytes.len() { assert!(parse(bytes, 7, split, 0).is_err(), "{bytes:?} split {split}"); }
        }
    }
}

#[test]
fn comments_do_not_generate_loading_payload_or_bracket_depth() {
    unsafe {
        let options = leanjson_source_v2_options { mode: 4, max_depth: 1, window_size: 17, index_depth: 0, index_budget_bytes: 0, ..Default::default() };
        let mut result = leanjson_source_v1_result::default();
        let source = leanjson_source_v2_new(&options, &mut result);
        assert!(!source.is_null(), "{result:?}");
        assert_eq!(leanjson_source_v2_set_loading(source, ptr::null(), 1, &mut result), 0);
        let bytes = format!("[/*{}*/1]", "\\\"[{{]\u{ff}".repeat(200000)).into_bytes();
        let mut payload = Vec::new();
        for (index, bytes) in bytes.chunks(17).enumerate() {
            assert_eq!(leanjson_source_v1_feed(source, (index*17) as u64, bytes.as_ptr(), bytes.len(), &mut result), 2, "{result:?}");
            loop {
                let mut event = leanjson_source_v2_loading_event::default();
                match leanjson_source_v2_next_loading_event(source, &mut event, &mut result) {
                    0 if event.event == 2 => payload.extend_from_slice(std::slice::from_raw_parts(event.bytes, event.bytes_len)),
                    0 => {}, 1 => break, status => panic!("event status {status}: {result:?}"),
                }
            }
        }
        assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, &mut result), 0, "{result:?}");
        assert_eq!(payload, b"1");
        assert_eq!(root(source).flags & 16, 16);
        leanjson_source_v1_release(source);
    }
}
