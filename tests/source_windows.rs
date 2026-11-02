use proptest::prelude::*;
use leanjson::source::{ReadStep, Source, SourceReader, DETAIL_BAD_WINDOW};

fn parsed(bytes: &[u8], window: usize) -> Source {
    let mut source = Source::new(0, window);
    for (i, chunk) in bytes.chunks(13).enumerate() { source.feed((i * 13) as u64, chunk).unwrap(); }
    source.finish(bytes.len() as u64).unwrap();
    source
}

fn read(source: &Source, node: usize, bytes: &[u8], scalar: bool, window: usize) -> Vec<u8> {
    let mut reader = SourceReader::new(source.node(node).unwrap().unwrap(), scalar, window).unwrap();
    let mut output = Vec::new();
    loop {
        match reader.step().unwrap() {
            ReadStep::Ready(chunk) => {
                assert!(!chunk.is_empty());
                assert!(chunk.len() <= window);
                output.extend_from_slice(chunk);
            },
            ReadStep::NeedRead { offset, length } => {
                assert!(length > 0 && length <= window);
                // A partial nonempty window is sufficient, even when its end
                // splits a UTF-8 sequence or a twelve-byte surrogate pair.
                let length = length.min(3);
                let mut borrowed = bytes[offset as usize..offset as usize + length].to_vec();
                reader.provide_window(offset, &borrowed).unwrap();
                borrowed.fill(0); // No chunk pointer may survive provide_window.
            },
            ReadStep::Done => break,
        }
    }
    assert!(matches!(reader.step().unwrap(), ReadStep::Done));
    output
}

#[test]
fn raw_windows_preserve_all_source_bytes_and_trim_only_outer_whitespace() {
    let bytes = br#"  { "key": [1, "\u0041", false], "key":null } \n"#;
    // The last two bytes in the fixture are outside the JSON and supplied
    // separately as real whitespace below.
    let mut bytes = bytes[..bytes.len() - 2].to_vec();
    bytes.push(b'\n');
    let source = parsed(&bytes, 7);
    let root = source.root().unwrap().unwrap();
    assert_eq!(read(&source, root, &bytes, false, 7), br#"{ "key": [1, "\u0041", false], "key":null }"#);
}

#[test]
fn scalar_string_decodes_every_escape_and_surrogate_pair_in_one_byte_windows() {
    let bytes = "\"A中😀\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0000\\u00E9\\uD834\\uDD1E\"".as_bytes();
    let source = parsed(bytes, 1);
    let root = source.root().unwrap().unwrap();
    assert_eq!(read(&source, root, bytes, true, 1), "A中😀\"\\/\u{8}\u{c}\n\r\t\0é𝄞".as_bytes());
}

#[test]
fn number_scalar_streams_exact_digits_and_never_converts_to_f64() {
    for bytes in [b"90071992547409931234567890".as_slice(), b"1.000000000000000000000001e99999999", b"-0"] {
        let source = parsed(bytes, 5);
        assert_eq!(read(&source, 0, bytes, true, 5), bytes);
    }
}

#[test]
fn empty_string_completes_without_asking_for_an_empty_window() {
    let source = parsed(b"\"\"", 1);
    assert!(read(&source, 0, b"\"\"", true, 1).is_empty());
}

#[test]
fn scalar_containers_are_type_errors() {
    for bytes in [b"{}".as_slice(), b"[]"] {
        let source = parsed(bytes, 3);
        assert!(SourceReader::new(source.node(0).unwrap().unwrap(), true, 3).is_err());
    }
}

#[test]
fn provide_window_rejects_gaps_empty_and_oversized_windows() {
    let bytes = b"123456789";
    let source = parsed(bytes, 4);
    for (base, input) in [(1, &bytes[..1]), (0, &bytes[..0]), (0, &bytes[..5]), (u64::MAX, &bytes[..1])] {
        let mut reader = SourceReader::new(source.node(0).unwrap().unwrap(), false, 4).unwrap();
        assert!(matches!(reader.step().unwrap(), ReadStep::NeedRead { offset: 0, length: 4 }));
        let error = reader.provide_window(base, input).unwrap_err();
        assert_eq!(error.detail, DETAIL_BAD_WINDOW);
        assert_eq!(reader.step().unwrap_err(), error);
    }
}

#[test]
fn independent_readers_can_interleave_windows() {
    let bytes = br#"["first","second"]"#;
    let source = parsed(bytes, 2);
    let a = source.node(0).unwrap().unwrap().members[0].value;
    let b = source.node(0).unwrap().unwrap().members[1].value;
    let mut first = SourceReader::new(source.node(a).unwrap().unwrap(), true, 2).unwrap();
    let mut second = SourceReader::new(source.node(b).unwrap().unwrap(), true, 2).unwrap();
    assert!(matches!(first.step().unwrap(), ReadStep::NeedRead { offset: 2, .. }));
    assert!(matches!(second.step().unwrap(), ReadStep::NeedRead { offset: 10, .. }));
    first.provide_window(2, b"fi").unwrap();
    second.provide_window(10, b"se").unwrap();
    assert!(matches!(second.step().unwrap(), ReadStep::Ready(b"se")));
    assert!(matches!(first.step().unwrap(), ReadStep::Ready(b"fi")));
}

#[test]
fn long_string_output_is_bounded_even_when_feed_is_larger_than_the_window() {
    let mut bytes = Vec::from(b"\"".as_slice());
    for _ in 0..32768 { bytes.extend_from_slice(br#"a\uD834\uDD1E"#); }
    bytes.push(b'"');
    let mut source = Source::new(0, 31);
    source.feed(0, &bytes).unwrap();
    source.finish(bytes.len() as u64).unwrap();
    let decoded = read(&source, 0, &bytes, true, 31);
    assert_eq!(decoded.len(), 32768 * 5);
    assert_eq!(&decoded[..5], "a𝄞".as_bytes());
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]
    #[test]
    fn streamed_string_matches_serde_decoder(value in ".{0,500}", window in 1usize..64) {
        let bytes = serde_json::to_vec(&value).unwrap();
        let source = parsed(&bytes, window);
        prop_assert_eq!(read(&source, 0, &bytes, true, window), value.as_bytes());
        prop_assert_eq!(read(&source, 0, &bytes, false, window), bytes);
    }
}
