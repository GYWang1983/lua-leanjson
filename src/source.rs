//! Strict incremental validation with optional, capacity-bounded source indexes.

use crate::error::{leanjson_err, leanjson_type};
use crate::options::{LEANJSON_DEFAULT_MAX_DEPTH, LEANJSON_MAX_MAX_DEPTH};

mod validate;
mod window;
pub mod loading;
pub(crate) mod duplicates;
pub(crate) mod sparse;
pub use window::{ReadStep, SourceReader};
use validate::{NumberState, StringState};
use duplicates::KeyMap;

pub const DETAIL_NONE: u32 = 0;
pub const DETAIL_IO: u32 = 1;
pub const DETAIL_ABORTED: u32 = 2;
pub const DETAIL_CLOSED: u32 = 3;
pub const DETAIL_BAD_WINDOW: u32 = 4;
pub const DETAIL_BAD_OFFSET: u32 = 5;
pub const DETAIL_BAD_OPTIONS: u32 = 6;
pub const SPAN_CLEAN: u32 = 1;
pub const SPAN_DUPLICATES: u32 = 2;
pub const SPAN_STRING_ESCAPE: u32 = 4;
pub const SPAN_NONFINITE: u32 = 8;
pub const MODE_INVALID_NUMBERS: u32 = 1;
pub const MODE_RAW_BYTES: u32 = 2;

#[derive(Clone, Copy, Default)]
pub(crate) struct SourcePolicy { pub invalid_numbers: bool, pub raw_bytes: bool }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceError { pub code: leanjson_err, pub detail: u32, pub offset: u64 }
impl SourceError {
    pub(crate) fn json(code: leanjson_err, offset: u64) -> Self { Self { code, detail: DETAIL_NONE, offset } }
    pub(crate) fn argument(detail: u32, offset: u64) -> Self { Self { code: leanjson_err::LEANJSON_INVALID_ARG, detail, offset } }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Member { pub key_start: u64, pub key_end: u64, pub key_hash: u64, pub value: usize }
#[derive(Debug)]
pub struct Node {
    pub kind: leanjson_type, pub raw_start: u64, pub raw_end: u64, pub complete: bool,
    pub members: Vec<Member>, pub child_count: u64, pub flags: u32,
}
#[derive(Clone, Copy, Debug)]
pub struct Span {
    pub kind: leanjson_type, pub flags: u32, pub raw_start: u64, pub raw_end: u64, pub child_count: u64,
}
impl Span {
    pub(crate) fn node(self) -> Node {
        Node { kind: self.kind, raw_start: self.raw_start, raw_end: self.raw_end, complete: true,
            members: Vec::new(), child_count: self.child_count, flags: self.flags }
    }
}
#[derive(Debug)]
pub(crate) struct SpanMember {
    pub ordinal: u64, pub key_start: u64, pub key_end: u64, pub key: Vec<u8>, pub value: Span,
}
#[derive(Clone, Copy, Debug)]
pub struct IndexOptions { pub depth: u32, pub array_limit: u32, pub budget_bytes: usize }
impl Default for IndexOptions {
    fn default() -> Self { Self { depth: 3, array_limit: 3, budget_bytes: 1048576 } }
}

#[derive(Clone, Copy)]
enum FrameState { ArrayFirst, ArrayValue, ArrayAfter, ObjectFirst, ObjectKey, ObjectColon, ObjectValue, ObjectAfter }
struct Value {
    id: Option<usize>, kind: leanjson_type, start: u64,
    key: (u64, u64), decoded_key: Vec<u8>, ordinal: u64, loading: Option<loading::ValueState>,
}
struct Frame {
    value: Value, state: FrameState, key: (u64, u64), key_hash: u64, decoded_key: Vec<u8>, count: u64,
    duplicates: Option<KeyMap>, flags: u32,
}
enum Token {
    PendingNull { start: u64 },
    String { start: u64, value: Option<Value>, state: StringState, key: Option<Vec<u8>>, key_hash: u64, key_limit: usize },
    Number { value: Value, state: NumberState },
    Literal { value: Value, expected: &'static [u8], matched: usize },
}

/// Input bytes are never retained. Legacy sources retain the published v1 tree;
/// sparse sources retain only optional indexes within `IndexOptions` plus one
/// root span and the validation stack. Span identities do not refer to indexes.
pub struct Source {
    nodes: Vec<Node>, frames: Vec<Frame>, token: Option<Token>, next_offset: u64,
    finished: bool, failure: Option<SourceError>, max_depth: u32, window_size: usize,
    indexes: Option<IndexOptions>, index_bytes: usize, indexed_depth: u32,
    events: bool, detect_duplicates: bool, member: Option<SpanMember>, spill_dir: std::path::PathBuf, workspace: duplicates::WorkspacePool,
    loading: Option<loading::Loading>, policy: SourcePolicy,
}
impl Source {
    pub fn new(max_depth: u32, window_size: usize) -> Self {
        Self {
            nodes: Vec::new(), frames: Vec::new(), token: None, next_offset: 0,
            finished: false, failure: None,
            max_depth: if max_depth == 0 { LEANJSON_DEFAULT_MAX_DEPTH } else { max_depth.min(LEANJSON_MAX_MAX_DEPTH) },
            window_size: if window_size == 0 { 65536 } else { window_size },
            indexes: None, index_bytes: 0, indexed_depth: 0, events: false,
            detect_duplicates: false, member: None, spill_dir: std::env::temp_dir(), workspace: duplicates::WorkspacePool::default(),
            loading: None, policy: SourcePolicy::default(),
        }
    }
    pub fn new_sparse(max_depth: u32, window_size: usize, indexes: IndexOptions) -> Self {
        let mut source = Self::new(max_depth, window_size);
        source.indexes = Some(indexes);
        source
    }
    pub(crate) fn with_policy(mut self, policy: SourcePolicy) -> Self { self.policy = policy; self }
    pub(crate) fn policy(&self) -> SourcePolicy { self.policy }
    pub(crate) fn walker(start: u64, window_size: usize, detect: bool, spill_dir: std::path::PathBuf, workspace: duplicates::WorkspacePool, policy: SourcePolicy) -> Self {
        let mut source = Self::new_sparse(LEANJSON_MAX_MAX_DEPTH, window_size,
            IndexOptions { depth: 0, array_limit: 0, budget_bytes: 0 });
        source.policy = policy;
        source.next_offset = start;
        source.events = true;
        source.detect_duplicates = detect;
        source.spill_dir = spill_dir;
        source.workspace = workspace;
        source
    }
    pub(crate) fn walker_resume(span: Span, resume: (u64, u64), window_size: usize, detect: bool, spill_dir: std::path::PathBuf, workspace: duplicates::WorkspacePool, policy: SourcePolicy) -> Self {
        let (offset, ordinal) = resume;
        let mut source = Self::walker(span.raw_start, window_size, detect, spill_dir, workspace, policy);
        if ordinal != 0 {
            let opener = if span.kind == leanjson_type::LEANJSON_T_ARR { b'[' } else { b'{' };
            source.start_value(opener, span.raw_start).unwrap();
            let frame = source.frames.last_mut().unwrap();
            frame.count = ordinal;
            frame.state = if opener == b'[' { FrameState::ArrayAfter } else { FrameState::ObjectAfter };
            source.next_offset = offset;
        }
        source
    }
    pub(crate) fn cached_count(&self, start: u64) -> Option<(usize, u64)> {
        let index = self.nodes.binary_search_by_key(&start, |node| node.raw_start).ok()?;
        let node = &self.nodes[index];
        Some((node.members.len(), node.child_count))
    }
    pub(crate) fn cached_member(&self, start: u64, ordinal: usize) -> Option<(Member, Span)> {
        let index = self.nodes.binary_search_by_key(&start, |node| node.raw_start).ok()?;
        let member = *self.nodes[index].members.get(ordinal)?;
        let value = self.nodes.get(member.value)?;
        Some((member, Span { kind: value.kind, flags: value.flags, raw_start: value.raw_start, raw_end: value.raw_end, child_count: value.child_count }))
    }
    pub(crate) fn workspace(&self) -> duplicates::WorkspacePool { self.workspace.clone() }
    pub fn window_size(&self) -> usize { self.window_size }
    pub fn set_loading(&mut self, eager: bool, selector: Option<std::rc::Rc<loading::Selector>>) -> Result<(), SourceError> {
        if self.next_offset != 0 || !self.nodes.is_empty() || self.finished || self.indexes.is_none() { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
        self.loading = Some(loading::Loading::new(eager, selector));
        Ok(())
    }
    pub fn next_loading_event(&mut self) -> Result<Option<&loading::Event>, SourceError> {
        self.ready()?;
        Ok(self.loading.as_mut().and_then(|loading| loading.next(self.finished)))
    }
    pub fn offset(&self) -> u64 { self.next_offset }
    pub fn index_bytes(&self) -> usize { self.index_bytes }
    pub fn clear_indexes(&mut self) -> Result<(), SourceError> {
        if !self.ready()? || self.indexes.is_none() { return Err(SourceError::argument(DETAIL_NONE, self.next_offset)); }
        let mut root = self.nodes.remove(0);
        root.members = Vec::new();
        self.nodes = vec![root];
        self.index_bytes = 0;
        self.indexed_depth = 0;
        Ok(())
    }
    pub fn indexed_nodes(&self) -> usize { self.nodes.len().saturating_sub(1) }
    pub fn indexed_depth(&self) -> u32 { self.indexed_depth }
    pub fn index_options(&self) -> Option<IndexOptions> { self.indexes }
    pub fn ready(&self) -> Result<bool, SourceError> { match self.failure { Some(error) => Err(error), None => Ok(self.finished) } }
    fn fail<T>(&mut self, error: SourceError) -> Result<T, SourceError> { self.failure = Some(error); Err(error) }

    pub fn feed(&mut self, base: u64, bytes: &[u8]) -> Result<(), SourceError> {
        self.consume(base, bytes, false).map(|_| ())
    }
    pub(crate) fn feed_member(&mut self, base: u64, bytes: &[u8]) -> Result<(usize, Option<SpanMember>), SourceError> {
        let count = self.consume(base, bytes, true)?;
        Ok((count, self.member.take()))
    }
    fn consume(&mut self, base: u64, bytes: &[u8], stop: bool) -> Result<usize, SourceError> {
        self.ready()?;
        if self.finished { return Err(SourceError::argument(DETAIL_CLOSED, self.next_offset)); }
        if base != self.next_offset || base.checked_add(bytes.len() as u64).is_none() {
            return self.fail(SourceError::argument(DETAIL_BAD_OFFSET, base));
        }
        let mut i = 0;
        while i < bytes.len() {
            let offset = base + i as u64;
            if self.token.is_none() && is_whitespace(bytes[i]) {
                i += 1;
                while i < bytes.len() && is_whitespace(bytes[i]) { i += 1; }
                continue;
            }
            let result = match self.token.take() {
                Some(token) => self.token_byte(token, bytes[i], offset),
                None => self.structural_byte(bytes[i], offset).map(|()| true),
            };
            match result {
                Ok(true) => i += 1,
                Ok(false) => {},
                Err(error) => { self.next_offset = offset; return self.fail(error); }
            }
            if stop && self.member.is_some() { break; }
        }
        self.next_offset = base + i as u64;
        Ok(i)
    }
    pub fn finish(&mut self, total_len: u64) -> Result<(), SourceError> {
        self.ready()?;
        if total_len != self.next_offset { return self.fail(SourceError::argument(DETAIL_BAD_OFFSET, total_len)); }
        if self.finished { return Ok(()); }
        let eof_error = match self.token.take() {
            Some(Token::Number { value, state }) => match state.finish() {
                Ok(nonfinite) => { self.complete(value, total_len, 0, SPAN_CLEAN | if nonfinite { SPAN_NONFINITE } else { 0 }); None },
                Err(code) => Some(SourceError::json(code, value.start)),
            },
            Some(Token::String { start, state, .. }) => Some(match state.finish() {
                Err(code) => SourceError::json(code, start),
                Ok(()) => SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, total_len),
            }),
            Some(Token::Literal { .. } | Token::PendingNull { .. }) => Some(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, total_len)),
            None => None,
        };
        if let Some(error) = eof_error { return self.fail(error); }
        if self.nodes.is_empty() || !self.frames.is_empty() || !self.nodes[0].complete {
            return self.fail(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, total_len));
        }
        self.finished = true;
        self.frames = Vec::new();
        Ok(())
    }
    pub fn root(&self) -> Result<Option<usize>, SourceError> { self.ready().map(|ready| if ready { Some(0) } else { None }) }
    pub fn node(&self, id: usize) -> Result<Option<&Node>, SourceError> {
        if !self.ready()? { return Ok(None); }
        self.nodes.get(id).map(Some).ok_or_else(|| SourceError::argument(DETAIL_NONE, self.next_offset))
    }
    pub fn abort(&mut self, detail: u32) -> SourceError {
        *self.failure.get_or_insert(SourceError { code: leanjson_err::LEANJSON_OK, detail, offset: self.next_offset })
    }
    fn complete(&mut self, value: Value, end: u64, count: u64, flags: u32) {
        if let Some(loading) = &mut self.loading { loading.end(&value, end, count, flags); }
        if let Some(id) = value.id {
            self.nodes[id].raw_end = end;
            self.nodes[id].complete = true;
            self.nodes[id].child_count = count;
            self.nodes[id].flags = flags;
        }
        if let Some(parent) = self.frames.last_mut() { parent.flags |= flags & !SPAN_CLEAN; }
        if self.events && self.frames.len() == 1 {
            self.member = Some(SpanMember { ordinal: value.ordinal, key_start: value.key.0,
                key_end: value.key.1, key: value.decoded_key,
                value: Span { kind: value.kind, flags, raw_start: value.start, raw_end: end, child_count: count } });
        }
    }
    fn optional_index(&mut self) -> Option<usize> {
        if self.loading.as_ref().is_some_and(|loading| loading.eager) { return None; }
        if self.frames.is_empty() { return None; }
        let parent = self.frames.last().unwrap();
        let parent_id = parent.value.id?;
        if let Some(options) = self.indexes {
            if self.frames.len() as u32 > options.depth || options.budget_bytes == 0
                || (parent.value.kind == leanjson_type::LEANJSON_T_ARR && parent.count >= options.array_limit as u64) { return None; }
            let node_growth = if self.nodes.len() == self.nodes.capacity() { self.nodes.capacity().max(1) } else { 0 };
            let members = &self.nodes[parent_id].members;
            let member_growth = if members.len() == members.capacity() { members.capacity().max(1) } else { 0 };
            let cost = node_growth.checked_mul(std::mem::size_of::<Node>())?
                .checked_add(member_growth.checked_mul(std::mem::size_of::<Member>())?)?;
            if cost > options.budget_bytes.saturating_sub(self.index_bytes) { return None; }
            if node_growth > 0 { self.nodes.reserve_exact(node_growth); }
            if member_growth > 0 { self.nodes[parent_id].members.reserve_exact(member_growth); }
            self.index_bytes += cost;
        }
        self.indexed_depth = self.indexed_depth.max(self.frames.len() as u32);
        Some(parent_id)
    }
    fn allocate(&mut self, kind: leanjson_type, offset: u64) -> Value {
        let parent_id = self.optional_index();
        let id = if self.frames.is_empty() || parent_id.is_some() {
            let id = self.nodes.len();
            if id == 0 && self.indexes.is_some() { self.nodes.reserve_exact(1); }
            self.nodes.push(Node { kind, raw_start: offset, raw_end: offset, complete: false,
                members: Vec::new(), child_count: 0, flags: 0 });
            Some(id)
        } else { None };
        let loading = self.loading.as_ref().map(|loading| loading.state(self.frames.last().map(|frame|
            (frame.value.loading.as_ref().unwrap(), frame.value.kind, frame.decoded_key.as_slice(), frame.count))));
        let interesting = loading.as_ref().is_some_and(|state| state.interesting);
        let mut value = Value { id, kind, start: offset, key: (0, 0), decoded_key: Vec::new(), ordinal: 0, loading };
        let direct = self.events && self.frames.len() == 1;
        if let Some(frame) = self.frames.last_mut() {
            value.key = frame.key;
            value.ordinal = frame.count;
            frame.count += 1;
            if direct || interesting { value.decoded_key = std::mem::take(&mut frame.decoded_key); }
            else { frame.decoded_key.clear(); }
            if let (Some(parent_id), Some(id)) = (parent_id, id) {
                self.nodes[parent_id].members.push(Member { key_start: frame.key.0, key_end: frame.key.1, key_hash: frame.key_hash, value: id });
            }
            frame.key = (0, 0);
            frame.state = match frame.state { FrameState::ObjectValue => FrameState::ObjectAfter, _ => FrameState::ArrayAfter };
        }
        if let Some(loading) = &mut self.loading { loading.begin(&value); }
        value
    }
    fn start_value(&mut self, byte: u8, offset: u64) -> Result<(), SourceError> {
        // Lowercase n can begin null or a native NaN token. Delay publication
        // until the second byte determines its type, including loading events.
        if byte == b'n' && self.policy.invalid_numbers {
            self.token = Some(Token::PendingNull { start: offset });
            return Ok(());
        }
        let kind = match byte {
            b'{' => leanjson_type::LEANJSON_T_OBJ, b'[' => leanjson_type::LEANJSON_T_ARR,
            b'"' => leanjson_type::LEANJSON_T_STR, b't' | b'f' => leanjson_type::LEANJSON_T_BOOL,
            b'n' => leanjson_type::LEANJSON_T_NULL, b'-' | b'0'..=b'9' => leanjson_type::LEANJSON_T_NUM,
            b'+' | b'i' | b'I' | b'N' if self.policy.invalid_numbers => leanjson_type::LEANJSON_T_NUM,
            _ => return Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset)),
        };
        if matches!(byte, b'{' | b'[') && self.frames.len() as u32 >= self.max_depth {
            return Err(SourceError::json(leanjson_err::LEANJSON_NESTING_TOO_DEEP, offset));
        }
        let value = self.allocate(kind, offset);
        match byte {
            b'{' | b'[' => {
                let duplicates = (self.detect_duplicates && !self.frames.is_empty() && byte == b'{')
                    .then(|| KeyMap::new(self.spill_dir.clone(), self.workspace.clone()));
                self.frames.push(Frame { value, key: (0, 0), key_hash: 0, decoded_key: Vec::new(), count: 0,
                    state: if byte == b'{' { FrameState::ObjectFirst } else { FrameState::ArrayFirst }, duplicates, flags: 0 });
            },
            b'"' => self.token = Some(Token::String { start: offset, value: Some(value), state: StringState::with_bytes(self.policy.raw_bytes), key: None, key_hash: 0xcbf29ce484222325, key_limit: 0 }),
            b't' | b'f' | b'n' => {
                if let Some(loading) = &mut self.loading { loading.data(&value, &[byte]); }
                self.token = Some(Token::Literal { value, expected: match byte { b't' => b"true", b'f' => b"false", _ => b"null" }, matched: 1 });
            },
            _ => { let mut state = NumberState::new(self.policy.invalid_numbers); state.feed(byte).map_err(|code| SourceError::json(code, offset))?;
                if let Some(loading) = &mut self.loading { loading.data(&value, &[byte]); }
                self.token = Some(Token::Number { value, state }); },
        }
        Ok(())
    }
    fn structural_byte(&mut self, byte: u8, offset: u64) -> Result<(), SourceError> {
        use FrameState::*;
        match self.frames.last().map(|f| f.state) {
            None if self.nodes.is_empty() => self.start_value(byte, offset),
            None => Err(SourceError::json(leanjson_err::LEANJSON_TRAILING_CONTENT, offset)),
            Some(ArrayFirst) if byte == b']' => self.close_container(offset),
            Some(ArrayFirst | ArrayValue | ObjectValue) => self.start_value(byte, offset),
            Some(ObjectFirst) if byte == b'}' => self.close_container(offset),
            Some(ObjectFirst | ObjectKey) if byte == b'"' => {
                let capture = self.events && self.frames.len() == 1 || self.frames.last().unwrap().duplicates.is_some();
                let key_limit = if capture { usize::MAX } else { self.loading.as_ref().map_or(0, |loading|
                    loading.key_limit(self.frames.last().unwrap().value.loading.as_ref().unwrap())) };
                self.token = Some(Token::String { start: offset, value: None, state: StringState::with_bytes(self.policy.raw_bytes), key: (key_limit != 0).then(Vec::new), key_hash: 0xcbf29ce484222325, key_limit }); Ok(())
            },
            Some(ObjectColon) if byte == b':' => { self.frames.last_mut().unwrap().state = ObjectValue; Ok(()) },
            Some(ArrayAfter) if byte == b',' => { self.frames.last_mut().unwrap().state = ArrayValue; Ok(()) },
            Some(ObjectAfter) if byte == b',' => { self.frames.last_mut().unwrap().state = ObjectKey; Ok(()) },
            Some(ArrayAfter) if byte == b']' => self.close_container(offset),
            Some(ObjectAfter) if byte == b'}' => self.close_container(offset),
            _ => Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset)),
        }
    }
    fn close_container(&mut self, offset: u64) -> Result<(), SourceError> {
        let frame = self.frames.pop().unwrap();
        let duplicate = frame.flags & SPAN_DUPLICATES != 0 || frame.duplicates.as_ref().is_some_and(|d| d.had_duplicates());
        let flags = frame.flags | if self.detect_duplicates { if duplicate { SPAN_DUPLICATES } else { SPAN_CLEAN } } else { 0 };
        self.complete(frame.value, offset + 1, frame.count, flags);
        Ok(())
    }
    fn token_byte(&mut self, token: Token, byte: u8, offset: u64) -> Result<bool, SourceError> {
        match token {
            Token::PendingNull { start } => {
                if byte == b'u' {
                    let value = self.allocate(leanjson_type::LEANJSON_T_NULL, start);
                    if let Some(loading) = &mut self.loading { loading.data(&value, b"nu"); }
                    self.token = Some(Token::Literal { value, expected: b"null", matched: 2 });
                } else if matches!(byte, b'a' | b'A') {
                    let value = self.allocate(leanjson_type::LEANJSON_T_NUM, start);
                    let mut state = NumberState::new(true);
                    state.feed(b'n').unwrap(); state.feed(byte).unwrap();
                    if let Some(loading) = &mut self.loading { loading.data(&value, &[b'n', byte]); }
                    self.token = Some(Token::Number { value, state });
                } else { return Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset)); }
            },
            Token::String { start, value, mut state, mut key, mut key_hash, key_limit } => {
                if byte == b'"' && state.at_boundary() {
                    match value {
                        Some(value) => self.complete(value, offset + 1, 0, SPAN_CLEAN | if state.needs_escape() { SPAN_STRING_ESCAPE } else { 0 }),
                        None => {
                            let frame = self.frames.last_mut().unwrap();
                            if state.needs_escape() { frame.flags |= SPAN_STRING_ESCAPE; }
                            frame.key = (start, offset + 1);
                            frame.key_hash = key_hash;
                            if let Some(key) = key {
                                if let Some(duplicates) = frame.duplicates.as_mut() { duplicates.insert_key(&key)?; }
                                frame.decoded_key = key;
                            }
                            frame.state = FrameState::ObjectColon;
                        },
                    }
                } else {
                    let decoded = state.feed(byte).map_err(|code| SourceError::json(code, start))?;
                    if value.is_none() {
                        for byte in &decoded.bytes[..decoded.len] { key_hash ^= *byte as u64; key_hash = key_hash.wrapping_mul(0x100000001b3); }
                    }
                    if let Some(value) = &value { if let Some(loading) = &mut self.loading { loading.data(value, &decoded.bytes[..decoded.len]); } }
                    if let Some(key) = key.as_mut() {
                        let count = decoded.len.min(key_limit.saturating_sub(key.len()));
                        key.extend_from_slice(&decoded.bytes[..count]);
                    }
                    self.token = Some(Token::String { start, value, state, key, key_hash, key_limit });
                }
            },
            Token::Number { value, mut state } => {
                if is_delimiter(byte) {
                    let nonfinite = state.finish().map_err(|code| SourceError::json(code, value.start))?;
                    self.complete(value, offset, 0, SPAN_CLEAN | if nonfinite { SPAN_NONFINITE } else { 0 }); return Ok(false);
                }
                state.feed(byte).map_err(|code| SourceError::json(code, value.start))?;
                if let Some(loading) = &mut self.loading { loading.data(&value, &[byte]); }
                self.token = Some(Token::Number { value, state });
            },
            Token::Literal { value, expected, mut matched } => {
                if byte != expected[matched] { return Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset)); }
                if let Some(loading) = &mut self.loading { loading.data(&value, &[byte]); }
                matched += 1;
                if matched == expected.len() { self.complete(value, offset + 1, 0, SPAN_CLEAN); }
                else { self.token = Some(Token::Literal { value, expected, matched }); }
            },
        }
        Ok(true)
    }
}
fn is_whitespace(byte: u8) -> bool { matches!(byte, b' ' | b'\t' | b'\r' | b'\n') }
fn is_delimiter(byte: u8) -> bool { is_whitespace(byte) || matches!(byte, b',' | b':' | b'[' | b']' | b'{' | b'}') }
