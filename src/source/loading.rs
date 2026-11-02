//! Shared-prefix selection and bounded, drainable scan-time construction events.
use std::collections::VecDeque;
use std::rc::Rc;
use super::{SourceError, DETAIL_BAD_OPTIONS, leanjson_type, validate::StringState};

#[derive(Clone, PartialEq, Eq)]
enum Segment { Key(Vec<u8>), Index(u64), Any }
#[derive(Default)]
struct Branch { terminal: bool, edges: Vec<(Segment, usize)> }
pub struct Selector { branches: Vec<Branch> }

fn invalid() -> SourceError { SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX) }
impl Selector {
    /// A sequence of little-endian u32 byte lengths followed by UTF-8 paths.
    pub fn compile(mut encoded: &[u8]) -> Result<Self, SourceError> {
        let mut selector = Self { branches: vec![Branch::default()] };
        while !encoded.is_empty() {
            if encoded.len() < 4 { return Err(invalid()); }
            let len = u32::from_le_bytes(encoded[..4].try_into().unwrap()) as usize;
            encoded = &encoded[4..];
            if encoded.len() < len { return Err(invalid()); }
            let segments = parse(&encoded[..len])?;
            encoded = &encoded[len..];
            let mut current = 0;
            for segment in segments {
                let next = selector.branches[current].edges.iter().find(|(edge, _)| *edge == segment).map(|(_, id)| *id);
                current = match next {
                    Some(id) => id,
                    None => {
                        let id = selector.branches.len();
                        selector.branches.push(Branch::default());
                        selector.branches[current].edges.push((segment, id));
                        id
                    },
                };
            }
            selector.branches[current].terminal = true;
        }
        Ok(selector)
    }
}

fn parse(path: &[u8]) -> Result<Vec<Segment>, SourceError> {
    if path.first() != Some(&b'$') || std::str::from_utf8(path).is_err() { return Err(invalid()); }
    let mut pos = 1;
    let mut segments = Vec::new();
    while pos < path.len() {
        match path[pos] {
            b'.' => {
                pos += 1;
                if path.get(pos) == Some(&b'*') { segments.push(Segment::Any); pos += 1; }
                else {
                    let first = pos;
                    while pos < path.len() && (path[pos].is_ascii_alphanumeric() || matches!(path[pos], b'_' | b'-') || path[pos] >= 0x80) { pos += 1; }
                    if first == pos { return Err(invalid()); }
                    segments.push(Segment::Key(path[first..pos].to_vec()));
                }
            },
            b'[' => {
                pos += 1;
                match path.get(pos).copied() {
                    Some(b'*') => { segments.push(Segment::Any); pos += 1; },
                    Some(quote @ (b'\'' | b'"')) => {
                        pos += 1;
                        let mut key = Vec::new();
                        let mut state = StringState::new();
                        loop {
                            let byte = *path.get(pos).ok_or_else(invalid)?;
                            if byte == quote && state.at_boundary() { pos += 1; break; }
                            if quote == b'\'' && state.at_boundary() && byte == b'\\' && path.get(pos + 1) == Some(&b'\'') {
                                key.push(b'\''); pos += 2; continue;
                            }
                            if quote == b'\'' && state.at_boundary() && byte == b'"' { key.push(byte); }
                            else {
                                let decoded = state.feed(byte).map_err(|_| invalid())?;
                                key.extend_from_slice(&decoded.bytes[..decoded.len]);
                            }
                            pos += 1;
                        }
                        state.finish().map_err(|_| invalid())?;
                        segments.push(Segment::Key(key));
                    },
                    Some(b'0'..=b'9') => {
                        let mut index = 0u64;
                        while let Some(digit @ b'0'..=b'9') = path.get(pos) {
                            index = index.checked_mul(10).and_then(|n| n.checked_add((digit - b'0') as u64)).ok_or_else(invalid)?;
                            pos += 1;
                        }
                        segments.push(Segment::Index(index));
                    },
                    _ => return Err(invalid()),
                }
                if path.get(pos) != Some(&b']') { return Err(invalid()); }
                pos += 1;
            },
            _ => return Err(invalid()),
        }
    }
    Ok(segments)
}

pub(super) struct ValueState { paths: Vec<usize>, pub full: bool, pub interesting: bool }
pub struct Event {
    pub event: u32, pub selected: bool, pub kind: leanjson_type, pub flags: u32,
    pub start: u64, pub end: u64, pub count: u64, pub ordinal: u64,
    pub key: Vec<u8>, pub bytes: Vec<u8>,
}
pub(super) struct Loading {
    pub eager: bool, selector: Option<Rc<Selector>>, events: VecDeque<Event>, current: Option<Event>,
}
impl Loading {
    pub fn new(eager: bool, selector: Option<Rc<Selector>>) -> Self {
        Self { eager, selector, events: VecDeque::new(), current: None }
    }
    pub fn state(&self, parent: Option<(&ValueState, leanjson_type, &[u8], u64)>) -> ValueState {
        let mut paths = Vec::new();
        let mut full = self.eager;
        if let Some((parent, kind, key, ordinal)) = parent {
            full |= parent.full;
            if !full {
                if let Some(selector) = &self.selector {
                    for &id in &parent.paths {
                        for (segment, child) in &selector.branches[id].edges {
                            let matches = match segment {
                                Segment::Key(name) => kind == leanjson_type::LEANJSON_T_OBJ && name == key,
                                Segment::Index(index) => kind == leanjson_type::LEANJSON_T_ARR && *index == ordinal,
                                Segment::Any => true,
                            };
                            if matches && !paths.contains(child) { paths.push(*child); }
                        }
                    }
                }
            }
        } else if let Some(selector) = &self.selector { paths.push(0); full |= selector.branches[0].terminal; }
        if let Some(selector) = &self.selector { full |= paths.iter().any(|&id| selector.branches[id].terminal); }
        let interesting = full || paths.iter().any(|&id| self.selector.as_ref().is_some_and(|s| !s.branches[id].edges.is_empty()));
        ValueState { paths, full, interesting }
    }
    pub fn key_limit(&self, value: &ValueState) -> usize {
        if value.full { return usize::MAX; }
        let mut maximum = 0usize;
        if let Some(selector) = &self.selector {
            for &id in &value.paths {
                for (edge, _) in &selector.branches[id].edges {
                    match edge { Segment::Any => return usize::MAX, Segment::Key(key) => maximum = maximum.max(key.len()), _ => {} }
                }
            }
        }
        maximum.saturating_add(1)
    }
    pub fn begin(&mut self, value: &super::Value) {
        if !value.loading.as_ref().is_some_and(|s| s.interesting) { return; }
        self.events.push_back(Event { event: 1, selected: value.loading.as_ref().unwrap().full, kind: value.kind, flags: 0,
            start: value.start, end: 0, count: 0, ordinal: value.ordinal, key: value.decoded_key.clone(), bytes: Vec::new() });
    }
    pub fn data(&mut self, value: &super::Value, bytes: &[u8]) {
        if bytes.is_empty() || !value.loading.as_ref().is_some_and(|s| s.full) { return; }
        if let Some(last) = self.events.back_mut().filter(|e| e.event == 2) { last.bytes.extend_from_slice(bytes); }
        else { self.events.push_back(Event { event: 2, selected: true, kind: value.kind, flags: 0, start: value.start,
            end: 0, count: 0, ordinal: 0, key: Vec::new(), bytes: bytes.to_vec() }); }
    }
    pub fn end(&mut self, value: &super::Value, end: u64, count: u64, flags: u32) {
        if !value.loading.as_ref().is_some_and(|s| s.interesting) { return; }
        self.events.push_back(Event { event: 3, selected: value.loading.as_ref().unwrap().full, kind: value.kind, flags,
            start: value.start, end, count, ordinal: value.ordinal, key: Vec::new(), bytes: Vec::new() });
    }
    pub fn next(&mut self, finished: bool) -> Option<&Event> {
        self.current = self.events.pop_front();
        if finished && self.current.is_none() { self.events = VecDeque::new(); self.selector = None; }
        self.current.as_ref()
    }
}
