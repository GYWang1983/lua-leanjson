use super::*;

#[derive(Debug, PartialEq)]
struct DecodedString { bytes: Vec<u8>, consumed: usize, closed: bool, error: Option<(leanjson_err, usize)>, escape: bool }

fn legacy(input: &[u8], raw: bool, stop_quote: bool) -> DecodedString {
    let mut state = StringState::with_bytes(raw);
    let mut output = Vec::new();
    for (i, &byte) in input.iter().enumerate() {
        if stop_quote && byte == b'"' && state.at_boundary() {
            return DecodedString { bytes: output, consumed: i+1, closed: true, error: None, escape: state.needs_escape() };
        }
        match state.feed(byte) {
            Ok(decoded) => output.extend_from_slice(&decoded.bytes[..decoded.len]),
            Err(code) => return DecodedString { bytes: Vec::new(), consumed: i, closed: false, error: Some((code, i)), escape: false },
        }
    }
    match state.finish() {
        Ok(()) => DecodedString { bytes: output, consumed: input.len(), closed: false, error: None, escape: state.needs_escape() },
        Err(code) => DecodedString { bytes: Vec::new(), consumed: input.len(), closed: false, error: Some((code, input.len())), escape: false },
    }
}

fn chunked(input: &[u8], raw: bool, stop_quote: bool, split: usize, limit: usize, decode: bool) -> DecodedString {
    let mut state = StringState::with_bytes(raw);
    let mut output = Vec::new();
    for (base, chunk) in [(0, &input[..split]), (split, &input[split..])] {
        let mut offset = 0;
        while offset < chunk.len() {
            let before = output.len();
            match state.scan_chunk(&chunk[offset..], stop_quote, limit, decode, |bytes| output.extend_from_slice(bytes)) {
                Ok(run) => {
                    assert!(run.consumed > 0);
                    assert!(output.len()-before <= limit.saturating_add(3));
                    offset += run.consumed;
                    if run.closed { return DecodedString { bytes: output, consumed: base+offset, closed: true, error: None, escape: state.needs_escape() }; }
                },
                Err(error) => return DecodedString { bytes: Vec::new(), consumed: base+offset+error.index, closed: false,
                    error: Some((error.code, base+offset+error.index)), escape: false },
            }
        }
    }
    match state.finish() {
        Ok(()) => DecodedString { bytes: output, consumed: input.len(), closed: false, error: None, escape: state.needs_escape() },
        Err(code) => DecodedString { bytes: Vec::new(), consumed: input.len(), closed: false, error: Some((code, input.len())), escape: false },
    }
}

#[test]
fn chunk_loop_matches_byte_state_on_every_escape_and_output_boundary() {
    let fixtures: &[&[u8]] = &[
        b"ordinary/\x7f\"tail", b"\\\"\\\\\\/\\b\\f\\n\\r\\t\"tail", b"\\u0000\\u002f\\u007f\\u4e2d\\ud83d\\ude00\"tail",
        b"\xe4\xb8\xad\xf0\x9f\x98\x80\"", b"\\uD7FF\\uE000\\udbff\\udfff\"",
        b"\xc2\x80\xe0\xa0\x80\xed\x9f\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf\"", b"\xff\x80\"", b"\xe0\x80\x80\"", b"\xed\xa0\x80\"",
        b"\xf4\x90\x80\x80\"", b"\xc2\"", b"\\uD800\\u0041\"", b"\\uDC00\"", b"\\u12zz\"", b"\\z\"",
        b"a\0b\"", b"a\nb\"", b"", b"\\", b"\\u12", b"\\ud800\\u", b"no end quote",
    ];
    for input in fixtures {
        for raw in [false, true] {
            for stop_quote in [false, true] {
                let expected = legacy(input, raw, stop_quote);
                for split in 0..=input.len() {
                    for limit in [1,2,3,4,7,65536] {
                        assert_eq!(chunked(input, raw, stop_quote, split, limit, true), expected,
                            "{input:?} raw={raw} quote={stop_quote} split={split} limit={limit}");
                    }
                    let mut skipped = chunked(input, raw, stop_quote, split, usize::MAX, false);
                    assert!(skipped.bytes.is_empty(), "unselected strings must not emit decoded data");
                    skipped.bytes = expected.bytes.clone();
                    assert_eq!(skipped, expected);
                }
            }
        }
    }
}

#[test]
fn chunk_loop_accepts_large_unselected_strings_without_emitting_data() {
    let input = format!("{}\"trailing", "quote\\\" slash\\\\ newline\\n\\ud83d\\ude00/".repeat(32768));
    let result = chunked(input.as_bytes(), true, true, 65535, usize::MAX, false);
    assert!(result.closed);
    assert!(result.bytes.is_empty());
    assert_eq!(result.consumed, input.len()-8);
    assert!(result.escape);
}

#[test]
fn zero_output_budget_leaves_the_string_state_and_input_untouched() {
    let mut state = StringState::with_bytes(false);
    let run = state.scan_chunk(b"\\u4e2d\"", true, 0, true, |_| panic!("must not emit" )).unwrap();
    assert_eq!((run.consumed, run.closed), (0, false));
    let mut output = Vec::new();
    let run = state.scan_chunk(b"\\u4e2d\"", true, 8, true, |bytes| output.extend_from_slice(bytes)).unwrap();
    assert!(run.closed);
    assert_eq!(output, "中".as_bytes());
}

proptest::proptest! {
    #[test]
    fn unicode_and_raw_bytes_cross_check_chunk_scanning(
        chars in proptest::collection::vec(proptest::prelude::any::<char>(), 0..300),
        raw_bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..300),
        split in proptest::prelude::any::<usize>(), limit in 1usize..33,
    ) {
        let text: String = chars.into_iter().collect();
        let quoted = serde_json::to_vec(&text).unwrap();
        let encoded = &quoted[1..];
        let expected = legacy(encoded, false, true);
        proptest::prop_assert_eq!(chunked(encoded, false, true, split % (encoded.len()+1), limit, true), expected);
        for raw in [false, true] {
            let expected = legacy(&raw_bytes, raw, true);
            proptest::prop_assert_eq!(chunked(&raw_bytes, raw, true, split % (raw_bytes.len()+1), limit, true), expected);
        }
    }
}
