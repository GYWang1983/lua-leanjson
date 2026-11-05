use leanjson::encode_ffi::{leanjson_encode_cursor, leanjson_encode_depth_state,
    leanjson_encode_string_length, leanjson_encode_string_chunk, leanjson_encode_depth_chunk};
use proptest::prelude::*;
use std::ptr;

fn encode(bytes: &[u8], flags: u32, capacity: usize) -> Vec<u8> {
    unsafe {
        let mut length = 0;
        assert_eq!(leanjson_encode_string_length(bytes.as_ptr(), bytes.len(), flags, &mut length), 0);
        let mut cursor = leanjson_encode_cursor::default();
        let mut out = Vec::new();
        while cursor.offset < bytes.len() {
            let mut buffer = vec![0xa5; capacity+2];
            let mut written = usize::MAX;
            assert_eq!(leanjson_encode_string_chunk(bytes.as_ptr(), bytes.len(), flags, &mut cursor,
                buffer.as_mut_ptr().add(1), capacity, &mut written), 0);
            assert!(written > 0 && written <= capacity);
            assert_eq!(buffer[0], 0xa5); assert_eq!(buffer[capacity+1], 0xa5);
            out.extend_from_slice(&buffer[1..1+written]);
        }
        assert_eq!(cursor.escape_offset, 0);
        assert_eq!(out.len(), length);
        out
    }
}

#[test]
fn escapes_have_exact_cjson_spelling_at_every_output_capacity() {
    let raw = b"a\"\\\n\r\t\x08\x0c\x00\x01/\x7f\xff\xe4\xb8\xad";
    let plain = b"a\\\"\\\\\\n\\r\\t\\b\\f\\u0000\\u0001/\\u007f\xff\xe4\xb8\xad";
    let slash = b"a\\\"\\\\\\n\\r\\t\\b\\f\\u0000\\u0001\\/\\u007f\xff\xe4\xb8\xad";
    for capacity in [1,2,3,4,5,6,7,17,65536] {
        assert_eq!(encode(raw, 0, capacity), plain);
        assert_eq!(encode(raw, 1, capacity), slash);
    }
    assert_eq!(encode(b"", 0, 1), b"");
}

proptest! {
    #[test]
    fn unicode_output_matches_independent_json_encoder(s in any::<String>(), slash in any::<bool>(), capacity in 1usize..65) {
        let encoded = serde_json::to_string(&s).unwrap().replace('\u{7f}', "\\u007f");
        let expected = if slash { encoded.replace('/', "\\/") } else { encoded };
        prop_assert_eq!(encode(s.as_bytes(), u32::from(slash), capacity), expected.as_bytes()[1..expected.len()-1].to_vec());
    }
}

#[test]
fn depth_state_survives_every_quote_and_escape_split() {
    let raw = br#"{"a":["braces{}[] and quote\" and slash\\",{}]}"#;
    unsafe {
        for split in 0..=raw.len() {
            let mut state = leanjson_encode_depth_state { maximum: 3, ..Default::default() };
            for (start,end) in [(0,split),(split,raw.len())] {
                assert_eq!(leanjson_encode_depth_chunk(raw[start..end].as_ptr(), end-start, &mut state), 0);
            }
            assert_eq!(state.depth, 0);assert_eq!(state.quoted, 0);assert_eq!(state.escaped, 0);
        }
        let mut state = leanjson_encode_depth_state { maximum: 2, ..Default::default() };
        assert_eq!(leanjson_encode_depth_chunk(raw.as_ptr(),raw.len(),&mut state), 9);
    }
}

#[test]
fn zero_capacity_and_invalid_ffi_arguments_never_advance_or_write() {
    unsafe {
        let raw=b"/";let mut cursor=leanjson_encode_cursor::default();let mut n=99usize;
        assert_eq!(leanjson_encode_string_chunk(raw.as_ptr(),1,1,&mut cursor,ptr::null_mut(),0,&mut n),0);
        assert_eq!(n,0);assert_eq!(cursor.offset,0);
        assert_eq!(leanjson_encode_string_length(ptr::null(),1,0,&mut n),7);
        assert_eq!(leanjson_encode_string_length(raw.as_ptr(),1,2,&mut n),7);
        assert_eq!(leanjson_encode_string_length(raw.as_ptr(),1,0,ptr::null_mut()),7);
        cursor.offset=2;
        assert_eq!(leanjson_encode_string_chunk(raw.as_ptr(),1,0,&mut cursor,ptr::null_mut(),0,&mut n),7);
        let mut state=leanjson_encode_depth_state { maximum: 0, ..Default::default() };
        assert_eq!(leanjson_encode_depth_chunk(ptr::null(),0,&mut state),7);
    }
}
