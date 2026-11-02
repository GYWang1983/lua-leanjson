use proptest::prelude::*;
use leanjson::error::{leanjson_err as E, leanjson_type as T};
use leanjson::source::{Source, SourceError, DETAIL_ABORTED, DETAIL_BAD_OFFSET};

fn parse(bytes: &[u8], chunk: usize) -> Result<Source, SourceError> {
    let mut source = Source::new(0, chunk);
    for (i, bytes) in bytes.chunks(chunk).enumerate() {
        source.feed((i * chunk) as u64, bytes)?;
        assert_eq!(source.root()?, None, "EOF must be explicit");
    }
    source.finish(bytes.len() as u64)?;
    Ok(source)
}

#[test]
fn every_byte_feed_preserves_absolute_spans_and_lexical_duplicates() {
    let bytes = br#" {"a":1,"a\u0062":[true,null,"\uD834\uDD1E"],"a":-2.5e+4} "#;
    let source = parse(bytes, 1).unwrap();
    let root = source.node(source.root().unwrap().unwrap()).unwrap().unwrap();
    assert_eq!(root.kind, T::LEANJSON_T_OBJ);
    assert_eq!((root.raw_start, root.raw_end), (1, 57));
    assert_eq!(root.members.len(), 3);
    assert_eq!((root.members[0].key_start, root.members[0].key_end), (2, 5));
    assert_eq!((root.members[1].key_start, root.members[1].key_end), (8, 17));
    assert_eq!((root.members[2].key_start, root.members[2].key_end), (45, 48));
    let array = source.node(root.members[1].value).unwrap().unwrap();
    assert_eq!(array.kind, T::LEANJSON_T_ARR);
    assert_eq!(array.members.len(), 3);
    assert!(array.members.iter().all(|m| m.key_start == 0 && m.key_end == 0));
    let number = source.node(root.members[2].value).unwrap().unwrap();
    assert_eq!(&bytes[number.raw_start as usize..number.raw_end as usize], b"-2.5e+4");
}

#[test]
fn all_split_positions_accept_utf8_escapes_literals_and_exponents() {
    let bytes = "[\"中😀\\\\\\\"\\u00E9\\uD834\\uDD1E\",-0.125e-30,false,true,null]".as_bytes();
    for split in 0..=bytes.len() {
        let mut source = Source::new(0, 7);
        source.feed(0, &bytes[..split]).unwrap();
        source.feed(split as u64, &bytes[split..]).unwrap();
        source.finish(bytes.len() as u64).unwrap();
        assert!(source.root().unwrap().is_some());
    }
}

#[test]
fn malformed_tokens_report_absolute_token_starts() {
    let cases: &[(&[u8], E, u64)] = &[
        (b"[01]", E::LEANJSON_INVALID_NUMBER, 1),
        (b"[1.]", E::LEANJSON_INVALID_NUMBER, 1),
        (b"[1e+]", E::LEANJSON_INVALID_NUMBER, 1),
        (b"[\"\\q\"]", E::LEANJSON_INVALID_STRING, 1),
        (b"[\"\\uD800x\"]", E::LEANJSON_INVALID_STRING, 1),
        (b"[\"\\uDC00\"]", E::LEANJSON_INVALID_STRING, 1),
        (b"[\"\xED\xA0\x80\"]", E::LEANJSON_INVALID_UTF8, 1),
        (b"[\"\xF4\x90\x80\x80\"]", E::LEANJSON_INVALID_UTF8, 1),
        (b"[\"\xC0\xAF\"]", E::LEANJSON_INVALID_UTF8, 1),
        (b"[\"\x01\"]", E::LEANJSON_INVALID_STRING, 1),
        (b"[1,]", E::LEANJSON_PARSE_ERROR, 3),
        (b"{\"x\":1,}", E::LEANJSON_PARSE_ERROR, 7),
        (b"{} x", E::LEANJSON_TRAILING_CONTENT, 3),
        (b"[}", E::LEANJSON_PARSE_ERROR, 1),
    ];
    for &(bytes, code, offset) in cases {
        for chunk in [1, 2, 7, 1024] {
            let error = parse(bytes, chunk).err().unwrap_or_else(|| panic!("accepted {bytes:?}"));
            assert_eq!((error.code, error.offset), (code, offset), "{bytes:?}, chunk={chunk}");
        }
    }
}

#[test]
fn finish_rejects_truncated_tokens_and_containers() {
    let cases: &[(&[u8], E, u64)] = &[
        (b"", E::LEANJSON_PARSE_ERROR, 0),
        (b"[1,", E::LEANJSON_PARSE_ERROR, 3),
        (b"{\"x\":", E::LEANJSON_PARSE_ERROR, 5),
        (b"\"abc", E::LEANJSON_PARSE_ERROR, 4),
        (b"\"\\", E::LEANJSON_INVALID_STRING, 0),
        (b"\"\\u12", E::LEANJSON_INVALID_STRING, 0),
        (b"\"\xE2\x82", E::LEANJSON_INVALID_UTF8, 0),
        (b"1e+", E::LEANJSON_INVALID_NUMBER, 0),
        (b"tru", E::LEANJSON_PARSE_ERROR, 3),
    ];
    for &(bytes, code, offset) in cases {
        let error = parse(bytes, 1).err().unwrap_or_else(|| panic!("accepted {bytes:?}"));
        assert_eq!((error.code, error.offset), (code, offset), "{bytes:?}");
    }
}

#[test]
fn depth_is_checked_at_the_rejected_opener() {
    let mut source = Source::new(2, 1);
    source.feed(0, b"[[").unwrap();
    let error = source.feed(2, b"[0]]]").unwrap_err();
    assert_eq!((error.code, error.offset), (E::LEANJSON_NESTING_TOO_DEEP, 2));
    assert_eq!(source.finish(7).unwrap_err(), error);
}

#[test]
fn input_offsets_and_finish_length_are_checked_without_wrapping() {
    for offset in [1, u32::MAX as u64 + 1, u64::MAX] {
        let mut source = Source::new(0, 8);
        let error = source.feed(offset, b"0").unwrap_err();
        assert_eq!(error.detail, DETAIL_BAD_OFFSET);
    }
    let mut source = Source::new(0, 8);
    source.feed(0, b"0").unwrap();
    assert_eq!(source.feed(0, b"0").unwrap_err().detail, DETAIL_BAD_OFFSET);
    let mut source = Source::new(0, 8);
    source.feed(0, b"0").unwrap();
    assert_eq!(source.finish(2).unwrap_err().detail, DETAIL_BAD_OFFSET);
}

#[test]
fn aborted_source_never_becomes_absent_or_ready() {
    let mut source = Source::new(0, 8);
    source.feed(0, b"{\"a\":1,").unwrap();
    let error = source.abort(DETAIL_ABORTED);
    assert_eq!(error.detail, DETAIL_ABORTED);
    assert_eq!(source.root().unwrap_err(), error);
    assert_eq!(source.feed(7, b"\"a\":2}").unwrap_err(), error);
    assert_eq!(source.finish(7).unwrap_err(), error);
}

#[test]
fn scanning_huge_numbers_never_requires_f64_range_or_token_storage() {
    let mut source = Source::new(0, 17);
    let digits = vec![b'9'; 8192];
    source.feed(0, &digits).unwrap();
    source.feed(8192, b"e9999999999999999999999999999").unwrap();
    source.finish(8221).unwrap();
    let root = source.node(source.root().unwrap().unwrap()).unwrap().unwrap();
    assert_eq!(root.kind, T::LEANJSON_T_NUM);
    assert_eq!((root.raw_start, root.raw_end), (0, 8221));
}

#[test]
fn json_test_suite_accepts_y_and_rejects_n_under_one_byte_feeds() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/vendor/JSONTestSuite/test_parsing");
    let mut paths: Vec<_> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    paths.sort();
    let mut checked = 0;
    for path in paths {
        let name = path.file_name().unwrap().to_str().unwrap();
        if !name.ends_with(".json") || !(name.starts_with("y_") || name.starts_with("n_")) { continue; }
        let bytes = std::fs::read(&path).unwrap();
        let result = parse(&bytes, 1);
        assert_eq!(result.is_ok(), name.starts_with("y_"), "{name}: {:?}", result.err());
        checked += 1;
    }
    assert!(checked > 250);
}

fn json_value() -> BoxedStrategy<serde_json::Value> {
    let leaf = prop_oneof![
        Just(serde_json::Value::Null),
        any::<bool>().prop_map(serde_json::Value::Bool),
        any::<i64>().prop_map(|v| serde_json::Value::Number(v.into())),
        ".{0,60}".prop_map(serde_json::Value::String),
    ];
    leaf.prop_recursive(4, 80, 8, |inner| {
        prop_oneof![
            proptest::collection::vec(inner.clone(), 0..8).prop_map(serde_json::Value::Array),
            proptest::collection::btree_map(".{0,20}", inner, 0..8)
                .prop_map(|entries| serde_json::Value::Object(entries.into_iter().collect())),
        ]
    }).boxed()
}

fn value_from_spans(source: &Source, id: usize, bytes: &[u8]) -> serde_json::Value {
    let node = source.node(id).unwrap().unwrap();
    match node.kind {
        T::LEANJSON_T_ARR => serde_json::Value::Array(node.members.iter().map(|member| value_from_spans(source, member.value, bytes)).collect()),
        T::LEANJSON_T_OBJ => {
            let mut object = serde_json::Map::new();
            for member in &node.members {
                let key = serde_json::from_slice::<String>(&bytes[member.key_start as usize..member.key_end as usize]).unwrap();
                object.insert(key, value_from_spans(source, member.value, bytes));
            }
            serde_json::Value::Object(object)
        },
        _ => serde_json::from_slice(&bytes[node.raw_start as usize..node.raw_end as usize]).unwrap(),
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]
    #[test]
    fn generated_strings_validate_at_arbitrary_window_boundaries(value in ".{0,300}", chunk in 1usize..32) {
        let bytes = serde_json::to_vec(&value).unwrap();
        let source = parse(&bytes, chunk).unwrap();
        let root = source.node(source.root().unwrap().unwrap()).unwrap().unwrap();
        prop_assert_eq!(root.kind, T::LEANJSON_T_STR);
        prop_assert_eq!((root.raw_start, root.raw_end), (0, bytes.len() as u64));
    }

    #[test]
    fn nested_node_metadata_reconstructs_generated_json(value in json_value(), chunk in 1usize..32) {
        let bytes = serde_json::to_vec(&value).unwrap();
        let source = parse(&bytes, chunk).unwrap();
        prop_assert_eq!(value_from_spans(&source, 0, &bytes), value);
    }

    #[test]
    fn adversarial_bytes_have_chunk_independent_error_codes_and_offsets(bytes in proptest::collection::vec(any::<u8>(), 0..128), chunk in 1usize..64) {
        let one_byte = parse(&bytes, 1);
        let arbitrary = parse(&bytes, chunk);
        prop_assert_eq!(one_byte.is_ok(), arbitrary.is_ok());
        prop_assert_eq!(one_byte.err(), arbitrary.err());
    }
}
