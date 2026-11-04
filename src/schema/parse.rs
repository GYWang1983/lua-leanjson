//! Parse the schema (never an instance) with the existing native scanner.
//!
//! serde_json's arbitrary_precision Value visitor reserves an object member
//! name for its private number transport. A legal JSON object using that name
//! must not turn into a number. Build Value explicitly from scanner token kinds
//! and parse only individual string/number tokens with serde_json.
use crate::error::leanjson_type::*;
use crate::source::Source;
use serde_json::{Map, Value};

pub(super) fn schema(bytes: &[u8]) -> Result<Value, String> {
    let mut source = Source::new(128, 65536);
    source
        .feed(0, bytes)
        .map_err(|e| format!("invalid schema JSON at byte {}: {:?}", e.offset, e.code))?;
    source
        .finish(bytes.len() as u64)
        .map_err(|e| format!("invalid schema JSON at byte {}: {:?}", e.offset, e.code))?;
    fn value(source: &Source, bytes: &[u8], id: usize) -> Result<Value, String> {
        let node = source
            .node(id)
            .map_err(|e| format!("invalid schema node: {:?}", e.code))?
            .ok_or("incomplete schema node")?;
        let raw = &bytes[node.raw_start as usize..node.raw_end as usize];
        Ok(match node.kind {
            LEANJSON_T_NULL => Value::Null,
            LEANJSON_T_BOOL => Value::Bool(raw == b"true"),
            LEANJSON_T_NUM => Value::Number(
                std::str::from_utf8(raw)
                    .map_err(|_| "invalid schema number bytes")?
                    .parse()
                    .map_err(|e| format!("invalid schema number: {e}"))?,
            ),
            LEANJSON_T_STR => Value::String(
                serde_json::from_slice::<String>(raw)
                    .map_err(|e| format!("invalid schema string: {e}"))?,
            ),
            LEANJSON_T_ARR => Value::Array(
                node.members
                    .iter()
                    .map(|m| value(source, bytes, m.value))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            LEANJSON_T_OBJ => {
                let mut map = Map::new();
                for member in &node.members {
                    let key = serde_json::from_slice::<String>(
                        &bytes[member.key_start as usize..member.key_end as usize],
                    )
                    .map_err(|e| format!("invalid schema key: {e}"))?;
                    map.insert(key, value(source, bytes, member.value)?);
                }
                Value::Object(map)
            }
        })
    }
    value(&source, bytes, 0)
}
