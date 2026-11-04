use super::{formats, Canon, CompiledSchema, Decimal, Dependency, Node};
use crate::error::leanjson_type::{self, *};
use base64::Engine;
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;

#[derive(Default)]
struct State {
    failed: bool,
    failed_keys: HashSet<Vec<u8>>,
    present: HashSet<String>,
    keys: HashSet<Vec<u8>>,
    contains: u64,
    unique: HashSet<Canon>,
}
struct Frame {
    kind: leanjson_type,
    key: Vec<u8>,
    ordinal: u64,
    offset: u64,
    states: HashMap<usize, State>,
    bytes: Vec<u8>,
    retain: bool,
    chars: u64,
    count: u64,
    capture: bool,
    children: Vec<Canon>,
    members: BTreeMap<String, Canon>,
}
/// One validation run. Events must be balanced and string data already decoded
/// by the JSON scanner. A plan may be shared by independent runs.
pub struct Validator {
    plan: Rc<CompiledSchema>,
    root: usize,
    stack: Vec<Frame>,
    result: Option<Result<(), String>>,
    protocol_error: Option<String>,
}
impl Validator {
    pub fn new(plan: Rc<CompiledSchema>) -> Self {
        let root = plan.root;
        Self {
            plan,
            root,
            stack: Vec::new(),
            result: None,
            protocol_error: None,
        }
    }
    pub fn begin(&mut self, kind: leanjson_type, key: &[u8], ordinal: u64, offset: u64) {
        if self.result.is_some() {
            self.protocol_error = Some("multiple schema root values".into());
            return;
        }
        let mut ids = Vec::new();
        let mut capture = false;
        if let Some(parent) = self.stack.last() {
            capture = parent.capture;
            for id in parent.states.keys() {
                let node = &self.plan.nodes[*id];
                ids.extend(child_schemas(node, parent.kind, key, ordinal));
                if parent.kind == LEANJSON_T_ARR {
                    if let Some(id) = node.edges.get("contains") {
                        ids.push(*id);
                    }
                }
                if parent.kind == LEANJSON_T_ARR
                    && node.spec.get("uniqueItems").and_then(|v| v.as_bool()) == Some(true)
                {
                    capture = true;
                }
            }
        } else {
            ids.push(self.root);
        }
        let ids = self.plan.expand(&ids);
        capture |= ids.iter().any(|id| self.plan.nodes[*id].capture());
        let retain = capture
            || kind == LEANJSON_T_NUM
            || (kind == LEANJSON_T_STR
                && ids.iter().any(|id| self.plan.nodes[*id].retain_string()));
        let states = ids.into_iter().map(|id| (id, State::default())).collect();
        self.stack.push(Frame {
            kind,
            key: key.to_vec(),
            ordinal,
            offset,
            states,
            bytes: Vec::new(),
            retain,
            chars: 0,
            count: 0,
            capture,
            children: Vec::new(),
            members: BTreeMap::new(),
        });
    }
    pub fn data(&mut self, bytes: &[u8]) {
        if let Some(frame) = self.stack.last_mut() {
            if frame.kind == LEANJSON_T_STR {
                frame.chars = frame
                    .chars
                    .saturating_add(bytes.iter().filter(|b| **b & 0xc0 != 0x80).count() as u64);
            }
            if frame.retain {
                frame.bytes.extend_from_slice(bytes);
            }
        } else {
            self.protocol_error = Some("schema data outside value".into());
        }
    }
    pub fn end(&mut self, kind: leanjson_type, _offset: u64) {
        let Some(frame) = self.stack.pop() else {
            self.protocol_error = Some("unbalanced schema value end".into());
            return;
        };
        if frame.kind != kind {
            self.protocol_error = Some("mismatched schema value end".into());
            return;
        }
        let number = if kind == LEANJSON_T_NUM {
            std::str::from_utf8(&frame.bytes)
                .ok()
                .and_then(Decimal::parse)
        } else {
            None
        };
        let captured = if frame.capture {
            Some(match kind {
                LEANJSON_T_NULL => Canon::Null,
                LEANJSON_T_BOOL => Canon::Bool(frame.bytes == b"true"),
                LEANJSON_T_NUM => match number.clone() {
                    Some(n) => Canon::Num(n),
                    None => {
                        self.protocol_error = Some("invalid schema number event".into());
                        return;
                    }
                },
                LEANJSON_T_STR => match String::from_utf8(frame.bytes.clone()) {
                    Ok(s) => Canon::Str(s),
                    Err(_) => {
                        self.protocol_error = Some("invalid UTF-8 schema string event".into());
                        return;
                    }
                },
                LEANJSON_T_ARR => Canon::Arr(frame.children.clone()),
                LEANJSON_T_OBJ => Canon::Obj(frame.members.clone()),
            })
        } else {
            None
        };
        let mut results = HashMap::new();
        for id in frame.states.keys() {
            evaluate(
                *id,
                &self.plan,
                &frame,
                number.as_ref(),
                captured.as_ref(),
                &mut results,
            );
        }
        if let Some(parent) = self.stack.last_mut() {
            parent.count = parent.count.saturating_add(1);
            let key = match std::str::from_utf8(&frame.key) {
                Ok(key) => key,
                Err(_) => {
                    self.protocol_error = Some(format!(
                        "schema object key is not valid UTF-8 at byte {}",
                        frame.offset
                    ));
                    return;
                }
            };
            for (id, state) in &mut parent.states {
                let node = &self.plan.nodes[*id];
                let mut good = child_schemas(node, parent.kind, &frame.key, frame.ordinal)
                    .iter()
                    .all(|id| results.get(id).copied().unwrap_or(true));
                if parent.kind == LEANJSON_T_OBJ {
                    if let Some(id) = node.edges.get("propertyNames") {
                        let mut name = Self::new(self.plan.clone());
                        name.root = *id;
                        name.begin(LEANJSON_T_STR, b"", 0, frame.offset);
                        name.data(&frame.key);
                        name.end(LEANJSON_T_STR, frame.offset);
                        good &= name.finish().is_ok();
                    }
                    if good {
                        state.failed_keys.remove(&frame.key);
                    } else {
                        state.failed_keys.insert(frame.key.clone());
                    }
                    if node.watch.contains(key) {
                        state.present.insert(key.to_owned());
                    }
                    if node.count_keys() {
                        state.keys.insert(frame.key.clone());
                    }
                } else if parent.kind == LEANJSON_T_ARR {
                    state.failed |= !good;
                    if let Some(id) = node.edges.get("contains") {
                        if results.get(id).copied().unwrap_or(false) {
                            state.contains += 1;
                        }
                    }
                    if node.spec.get("uniqueItems").and_then(|v| v.as_bool()) == Some(true) {
                        if let Some(value) = &captured {
                            if !state.unique.insert(value.clone()) {
                                state.failed = true;
                            }
                        }
                    }
                }
            }
            if parent.capture {
                if let Some(value) = captured {
                    if parent.kind == LEANJSON_T_OBJ {
                        parent.members.insert(key.to_owned(), value);
                    } else {
                        parent.children.push(value);
                    }
                }
            }
        } else {
            self.result = Some(if results.get(&self.root).copied().unwrap_or(true) {
                Ok(())
            } else {
                Err(format!("schema validation failed at byte {}", frame.offset))
            });
        }
    }
    pub fn finish(&mut self) -> Result<(), String> {
        if let Some(error) = &self.protocol_error {
            return Err(error.clone());
        }
        if !self.stack.is_empty() {
            return Err("incomplete schema value stream".into());
        }
        self.result
            .clone()
            .unwrap_or_else(|| Err("empty schema value stream".into()))
    }
    /// Approximate owned data bytes, for verifying retention policies. Includes
    /// per-frame state and capacities; excludes the separately reusable plan.
    pub fn retained_bytes(&self) -> usize {
        self.stack
            .iter()
            .map(|f| {
                std::mem::size_of::<Frame>()
                    + f.key.capacity()
                    + f.bytes.capacity()
                    + f.children.iter().map(Canon::retained_bytes).sum::<usize>()
                    + f.members
                        .iter()
                        .map(|(k, v)| k.capacity() + v.retained_bytes())
                        .sum::<usize>()
                    + f.states
                        .values()
                        .map(|s| {
                            std::mem::size_of::<State>()
                                + s.failed_keys
                                    .iter()
                                    .chain(s.keys.iter())
                                    .map(Vec::capacity)
                                    .sum::<usize>()
                                + s.present.iter().map(String::capacity).sum::<usize>()
                                + s.unique.iter().map(Canon::retained_bytes).sum::<usize>()
                        })
                        .sum::<usize>()
            })
            .sum()
    }
}
fn child_schemas(node: &Node, kind: leanjson_type, key: &[u8], ordinal: u64) -> Vec<usize> {
    let mut out = Vec::new();
    match kind {
        LEANJSON_T_OBJ => {
            let Ok(key) = std::str::from_utf8(key) else {
                return out;
            };
            let mut matched = false;
            if let Some(id) = node.properties.get(key) {
                out.push(*id);
                matched = true;
            }
            for (pattern, id) in &node.patterns {
                if pattern.find(key).is_some() {
                    out.push(*id);
                    matched = true;
                }
            }
            if !matched {
                if let Some(id) = node.edges.get("additionalProperties") {
                    out.push(*id);
                }
            }
        }
        LEANJSON_T_ARR => {
            let tuple = node
                .lists
                .get("prefixItems")
                .or_else(|| node.lists.get("items"));
            if let Some(id) =
                tuple.and_then(|v| usize::try_from(ordinal).ok().and_then(|i| v.get(i)))
            {
                out.push(*id);
            } else if node.lists.contains_key("items") {
                if let Some(id) = node.edges.get("additionalItems") {
                    out.push(*id);
                }
            } else if let Some(id) = node.edges.get("items") {
                out.push(*id);
            }
        }
        _ => {}
    }
    out
}
fn bounded(node: &Node, min: &str, max: &str, count: u64) -> bool {
    node.counts.get(min).is_none_or(|n| count >= *n)
        && node.counts.get(max).is_none_or(|n| count <= *n)
}
fn type_matches(name: &str, kind: leanjson_type, number: Option<&Decimal>) -> bool {
    match name {
        "null" => kind == LEANJSON_T_NULL,
        "boolean" => kind == LEANJSON_T_BOOL,
        "number" => kind == LEANJSON_T_NUM,
        "integer" => kind == LEANJSON_T_NUM && number.is_some_and(Decimal::integer),
        "string" => kind == LEANJSON_T_STR,
        "array" => kind == LEANJSON_T_ARR,
        "object" => kind == LEANJSON_T_OBJ,
        _ => false,
    }
}
fn evaluate(
    id: usize,
    plan: &CompiledSchema,
    frame: &Frame,
    number: Option<&Decimal>,
    captured: Option<&Canon>,
    results: &mut HashMap<usize, bool>,
) -> bool {
    if let Some(result) = results.get(&id) {
        return *result;
    }
    let node = &plan.nodes[id];
    let state = &frame.states[&id];
    let mut valid =
        node.spec.as_bool().unwrap_or(true) && !state.failed && state.failed_keys.is_empty();
    if let Some(types) = node.spec.get("type") {
        valid &= if let Some(name) = types.as_str() {
            type_matches(name, frame.kind, number)
        } else {
            types
                .as_array()
                .expect("compiled types")
                .iter()
                .any(|v| type_matches(v.as_str().expect("type name"), frame.kind, number))
        };
    }
    if let Some(choices) = &node.choices {
        valid &= captured.is_some_and(|v| choices.contains(v));
    }
    if let Some(constant) = &node.constant {
        valid &= captured == Some(constant);
    }
    match frame.kind {
        LEANJSON_T_NUM => {
            if let Some(number) = number {
                for (key, bound) in &node.numbers {
                    valid &= match key.as_str() {
                        "minimum" => number.cmp(bound) != Ordering::Less,
                        "maximum" => number.cmp(bound) != Ordering::Greater,
                        "exclusiveMinimum" => number.cmp(bound) == Ordering::Greater,
                        "exclusiveMaximum" => number.cmp(bound) == Ordering::Less,
                        "multipleOf" => number.multiple_of(bound),
                        _ => true,
                    };
                }
            } else {
                valid = false;
            }
        }
        LEANJSON_T_STR => {
            valid &= bounded(node, "minLength", "maxLength", frame.chars);
            if node.retain_string() {
                if let Ok(s) = std::str::from_utf8(&frame.bytes) {
                    if let Some(pattern) = &node.pattern {
                        valid &= pattern.find(s).is_some();
                    }
                    if let Some(format) = node.spec.get("format").and_then(|v| v.as_str()) {
                        valid &= formats::validate(s, format);
                    }
                    if node.spec.get("contentEncoding").is_some() {
                        valid &= base64::engine::general_purpose::STANDARD.decode(s).is_ok();
                    }
                } else {
                    valid = false;
                }
            }
        }
        LEANJSON_T_ARR => {
            valid &= bounded(node, "minItems", "maxItems", frame.count);
            if node.edges.contains_key("contains") {
                let minimum = node.counts.get("minContains").copied().unwrap_or(1);
                let maximum = node.counts.get("maxContains").copied().unwrap_or(u64::MAX);
                valid &= state.contains >= minimum && state.contains <= maximum;
            }
        }
        LEANJSON_T_OBJ => {
            valid &= bounded(
                node,
                "minProperties",
                "maxProperties",
                state.keys.len() as u64,
            );
            if let Some(required) = node.spec.get("required").and_then(|v| v.as_array()) {
                valid &= required
                    .iter()
                    .all(|v| state.present.contains(v.as_str().expect("required string")));
            }
            for (key, dep) in &node.dependencies {
                let key = key.split_once(':').expect("dependency key").1;
                if state.present.contains(key) {
                    valid &= match dep {
                        Dependency::Required(keys) => {
                            keys.iter().all(|key| state.present.contains(key))
                        }
                        Dependency::Schema(id) => {
                            evaluate(*id, plan, frame, number, captured, results)
                        }
                    };
                }
            }
        }
        _ => {}
    }
    if let Some(child) = node.edges.get("$ref") {
        valid &= evaluate(*child, plan, frame, number, captured, results);
    }
    for key in ["allOf", "anyOf", "oneOf"] {
        if let Some(children) = node.lists.get(key) {
            let count = children
                .iter()
                .filter(|id| evaluate(**id, plan, frame, number, captured, results))
                .count();
            valid &= match key {
                "allOf" => count == children.len(),
                "anyOf" => count > 0,
                _ => count == 1,
            };
        }
    }
    if let Some(child) = node.edges.get("not") {
        valid &= !evaluate(*child, plan, frame, number, captured, results);
    }
    if let Some(condition) = node.edges.get("if") {
        let branch = if evaluate(*condition, plan, frame, number, captured, results) {
            "then"
        } else {
            "else"
        };
        if let Some(child) = node.edges.get(branch) {
            valid &= evaluate(*child, plan, frame, number, captured, results);
        }
    }
    results.insert(id, valid);
    valid
}
