#![cfg_attr(not(test), no_main)]

#[cfg(not(test))]
use libfuzzer_sys::fuzz_target;
use leanjson::error::leanjson_type;
use leanjson::source::{Node, ReadStep, Source, SourceError, SourceReader};

// Raw JSON inputs keep the existing corpus directly reusable. These independent
// caps also bound replay when a caller omits libFuzzer's -max_len option.
const MAX_INPUT: usize = 16 * 1024;
const MAX_DEPTH: u32 = 128;
const MAX_NODES: usize = 128;
const MAX_REPLAY_BYTES: usize = MAX_INPUT * 4;

#[cfg(not(test))]
fuzz_target!(|data: &[u8]| fuzz_one(data));

fn fuzz_one(data: &[u8]) {
    if data.len() > MAX_INPUT {
        return;
    }
    // Use every byte as scheduling entropy without removing bytes from the JSON
    // payload. Mutating syntax also explores feed, read and output boundaries.
    let seed = data.iter().fold(0x9E37_79B9u32, |seed, &byte| {
        seed.rotate_left(5) ^ u32::from(byte)
    });
    let window = 1 + (seed as usize % 64);
    let whole = parse(data, window, None);
    let chunked = parse(data, window, Some(seed));
    let one_byte = parse(data, window, Some(0));
    assert_eq!(whole.as_ref().err(), chunked.as_ref().err());
    assert_eq!(whole.as_ref().err(), one_byte.as_ref().err());

    let (Ok(whole), Ok(chunked), Ok(one_byte)) = (whole, chunked, one_byte) else {
        return;
    };
    let root = whole.root().unwrap().unwrap();
    let root_node = whole.node(root).unwrap().unwrap();
    let start = data.iter().position(|&byte| !json_whitespace(byte)).unwrap();
    let end = data.iter().rposition(|&byte| !json_whitespace(byte)).unwrap() + 1;
    assert_eq!((root_node.raw_start, root_node.raw_end), (start as u64, end as u64));

    let mut todo = vec![(root, chunked.root().unwrap().unwrap(), one_byte.root().unwrap().unwrap())];
    let mut replay_budget = MAX_REPLAY_BYTES;
    for _ in 0..MAX_NODES {
        let Some((whole_id, chunked_id, byte_id)) = todo.pop() else { break };
        let node = whole.node(whole_id).unwrap().unwrap();
        let other = chunked.node(chunked_id).unwrap().unwrap();
        let byte_node = one_byte.node(byte_id).unwrap().unwrap();
        assert_metadata(node, other);
        assert_metadata(node, byte_node);

        let raw = &data[node.raw_start as usize..node.raw_end as usize];
        // Budget includes nested repeated spans, preventing O(input * depth)
        // read amplification while always replaying the root's exact bytes.
        if raw.len() <= replay_budget {
            replay_budget -= raw.len();
            assert_eq!(stream(node, false, data, window, seed), raw);
            if !matches!(node.kind, leanjson_type::LEANJSON_T_ARR | leanjson_type::LEANJSON_T_OBJ)
                && raw.len() <= replay_budget
            {
                replay_budget -= raw.len();
                let scalar = stream(node, true, data, window, seed.rotate_left(7));
                if node.kind == leanjson_type::LEANJSON_T_STR {
                    let expected: String = serde_json::from_slice(raw).unwrap();
                    assert_eq!(scalar, expected.as_bytes());
                } else {
                    // Numeric tokens remain exact even outside f64's range.
                    assert_eq!(scalar, raw);
                }
            }
        }
        for ((member, other), byte_member) in node.members.iter().zip(&other.members).zip(&byte_node.members).rev() {
            assert_eq!((member.key_start, member.key_end), (other.key_start, other.key_end));
            assert_eq!((member.key_start, member.key_end), (byte_member.key_start, byte_member.key_end));
            if node.kind == leanjson_type::LEANJSON_T_OBJ {
                let key = &data[member.key_start as usize..member.key_end as usize];
                let _: String = serde_json::from_slice(key).unwrap();
            } else {
                assert_eq!((member.key_start, member.key_end), (0, 0));
            }
            todo.push((member.value, other.value, byte_member.value));
        }
    }
}

fn parse(data: &[u8], window: usize, schedule: Option<u32>) -> Result<Source, SourceError> {
    let mut source = Source::new(MAX_DEPTH, window);
    let mut offset = 0;
    let mut state = schedule.unwrap_or(0);
    while offset < data.len() {
        let len = match schedule {
            None => data.len(),
            Some(0) => 1,
            Some(_) => {
                state = state.rotate_left(7).wrapping_add(u32::from(data[offset]) + 1);
                1 + state as usize % 97
            },
        }.min(data.len() - offset);
        if state & 3 == 0 {
            source.feed(offset as u64, &[])?;
        }
        let mut temporary = data[offset..offset + len].to_vec();
        let result = source.feed(offset as u64, &temporary);
        // Overwrite then free the caller's allocation before any subsequent
        // feed/finish/metadata/read. ASan can detect an unsafe retained pointer;
        // value assertions detect implementations that reread changed bytes.
        temporary.fill(0xA5);
        drop(temporary);
        if let Err(error) = result {
            assert_eq!(source.root().unwrap_err(), error);
            assert_eq!(source.finish(data.len() as u64).unwrap_err(), error);
            return Err(error);
        }
        assert_eq!(source.root().unwrap(), None);
        offset += len;
    }
    source.finish(data.len() as u64)?;
    Ok(source)
}

fn assert_metadata(expected: &Node, actual: &Node) {
    assert!(expected.complete && actual.complete);
    assert_eq!(
        (expected.kind, expected.raw_start, expected.raw_end, expected.members.len()),
        (actual.kind, actual.raw_start, actual.raw_end, actual.members.len()),
    );
}

fn stream(node: &Node, scalar: bool, data: &[u8], window: usize, mut state: u32) -> Vec<u8> {
    let mut reader = SourceReader::new(node, scalar, window).unwrap();
    let mut output = Vec::new();
    let mut next_read = node.raw_start + u64::from(scalar && node.kind == leanjson_type::LEANJSON_T_STR);
    let read_end = node.raw_end - u64::from(scalar && node.kind == leanjson_type::LEANJSON_T_STR);
    // Every nonterminal step must consume input or emit output. Each input
    // string byte produces at most one output byte, so this also detects stalls.
    for _ in 0..(4 * (node.raw_end - node.raw_start) as usize + 16) {
        match reader.step().unwrap() {
            ReadStep::Ready(bytes) => {
                assert!(!bytes.is_empty() && bytes.len() <= window);
                output.extend_from_slice(bytes);
                assert!(output.len() <= (node.raw_end - node.raw_start) as usize);
            },
            ReadStep::NeedRead { offset, length } => {
                assert_eq!(offset, next_read);
                assert!(length > 0 && length <= window);
                assert!(offset + length as u64 <= read_end);
                // Repeating a pending request must not advance the operation.
                if state & 1 == 0 {
                    assert!(matches!(reader.step().unwrap(), ReadStep::NeedRead { offset: again, length: len } if again == offset && len == length));
                }
                state = state.rotate_left(3).wrapping_add(u32::from(data[offset as usize]) + 1);
                let len = 1 + state as usize % length;
                let mut temporary = data[offset as usize..offset as usize + len].to_vec();
                reader.provide_window(offset, &temporary).unwrap();
                temporary.fill(0x5A);
                drop(temporary);
                next_read += len as u64;
            },
            ReadStep::Done => {
                assert_eq!(next_read, read_end);
                assert!(matches!(reader.step().unwrap(), ReadStep::Done));
                return output;
            },
        }
    }
    panic!("bounded source reader did not make progress");
}

fn json_whitespace(byte: u8) -> bool { matches!(byte, b' ' | b'\t' | b'\r' | b'\n') }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_source_window_replay_covers_tokens_and_errors() {
        for data in [
            b"".as_slice(), b" ", b"[1,]", b"[1e+]", b"[\"\\uD800x\"]", b"{}x", b"\"\xF4\x90\x80\x80\"",
            br#" {"a":1,"a":2,"a\u0062":[true,false,null,"\u0000\uD834\uDD1E"]} "#,
            br#"["plain","\\\"\\u0061",-0,90071992547409931234567890,1e999999999999999]"#,
            "\"中😀é\"".as_bytes(),
        ] { fuzz_one(data); }
    }

    #[test]
    fn source_window_replay_is_bounded_for_deep_and_wide_inputs() {
        let mut deep = vec![b'['; 129];
        deep.push(b'0');
        deep.extend_from_slice(&[b']'; 129]);
        fuzz_one(&deep);
        fuzz_one(format!("[{}0]", "0,".repeat(4096)).as_bytes());
        fuzz_one(format!("\"{}\"", "\\uD834\\uDD1E".repeat(512)).as_bytes());
        fuzz_one(&vec![b' '; MAX_INPUT + 1]);
    }

    #[test]
    fn replay_existing_bounded_json_corpus() {
        let corpus = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("corpus/fuzz_parse_eager");
        let mut replayed = 0;
        for entry in std::fs::read_dir(corpus).unwrap() {
            let path = entry.unwrap().path();
            if path.is_file() && std::fs::metadata(&path).unwrap().len() <= MAX_INPUT as u64 {
                fuzz_one(&std::fs::read(&path).unwrap());
                replayed += 1;
            }
        }
        assert!(replayed > 0);
        println!("source/window replay covered {replayed} bounded existing corpus entries");
    }
}
