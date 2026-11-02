//! Bounded, strictly validated JSON source metadata. Input storage belongs to the caller.

use crate::error::{leanjson_err, leanjson_type};
use crate::options::{LEANJSON_DEFAULT_MAX_DEPTH, LEANJSON_MAX_MAX_DEPTH};

mod validate;
mod window;
pub use window::{ReadStep, SourceReader};
use validate::{NumberState, StringState};

pub const DETAIL_NONE: u32 = 0;
pub const DETAIL_IO: u32 = 1;
pub const DETAIL_ABORTED: u32 = 2;
pub const DETAIL_CLOSED: u32 = 3;
pub const DETAIL_BAD_WINDOW: u32 = 4;
pub const DETAIL_BAD_OFFSET: u32 = 5;
pub const DETAIL_BAD_OPTIONS: u32 = 6;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceError {
    pub code: leanjson_err,
    pub detail: u32,
    pub offset: u64,
}

impl SourceError {
    pub(crate) fn json(code: leanjson_err, offset: u64) -> Self {
        Self { code, detail: DETAIL_NONE, offset }
    }

    pub(crate) fn argument(detail: u32, offset: u64) -> Self {
        Self { code: leanjson_err::LEANJSON_INVALID_ARG, detail, offset }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Member {
    pub key_start: u64,
    pub key_end: u64,
    pub value: usize,
}

#[derive(Debug)]
pub struct Node {
    pub kind: leanjson_type,
    pub raw_start: u64,
    pub raw_end: u64,
    pub complete: bool,
    pub members: Vec<Member>,
}

#[derive(Clone, Copy)]
enum FrameState {
    ArrayFirst, ArrayValue, ArrayAfter,
    ObjectFirst, ObjectKey, ObjectColon, ObjectValue, ObjectAfter,
}

struct Frame {
    node: usize,
    state: FrameState,
    key: (u64, u64),
}

enum Token {
    String { start: u64, node: Option<usize>, state: StringState },
    Number { node: usize, state: NumberState },
    Literal { node: usize, expected: &'static [u8], matched: usize },
}

/// A single-threaded parser retaining O(nodes + depth) metadata and no input bytes.
///
/// `feed` borrows bytes for the duration of that call only. A completed root is
/// deliberately unavailable until `finish` confirms EOF. All parse failures and
/// explicit aborts are sticky, including for existing node/operation users.
pub struct Source {
    nodes: Vec<Node>,
    frames: Vec<Frame>,
    token: Option<Token>,
    next_offset: u64,
    finished: bool,
    failure: Option<SourceError>,
    max_depth: u32,
    window_size: usize,
}

impl Source {
    pub fn new(max_depth: u32, window_size: usize) -> Self {
        Self {
            nodes: Vec::new(), frames: Vec::new(), token: None,
            next_offset: 0, finished: false, failure: None,
            max_depth: if max_depth == 0 { LEANJSON_DEFAULT_MAX_DEPTH } else { max_depth.min(LEANJSON_MAX_MAX_DEPTH) },
            window_size: if window_size == 0 { 65536 } else { window_size },
        }
    }

    pub fn window_size(&self) -> usize { self.window_size }
    pub fn offset(&self) -> u64 { self.next_offset }

    pub fn ready(&self) -> Result<bool, SourceError> {
        match self.failure { Some(error) => Err(error), None => Ok(self.finished) }
    }

    fn fail<T>(&mut self, error: SourceError) -> Result<T, SourceError> {
        self.failure = Some(error);
        Err(error)
    }

    pub fn feed(&mut self, base: u64, bytes: &[u8]) -> Result<(), SourceError> {
        self.ready()?;
        if self.finished {
            return Err(SourceError::argument(DETAIL_CLOSED, self.next_offset));
        }
        let end = match base.checked_add(bytes.len() as u64) {
            Some(end) if base == self.next_offset => end,
            _ => return self.fail(SourceError::argument(DETAIL_BAD_OFFSET, base)),
        };
        let mut i = 0;
        while i < bytes.len() {
            let offset = base + i as u64;
            // Whitespace is legal in every grammar state outside a token. The
            // tight loop also permits testing 64-bit positions with a reused
            // bounded whitespace window rather than a multi-gigabyte buffer.
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
                Ok(false) => {}, // Number ended before this structural byte.
                Err(error) => { self.next_offset = offset; return self.fail(error); }
            }
        }
        self.next_offset = end;
        Ok(())
    }

    pub fn finish(&mut self, total_len: u64) -> Result<(), SourceError> {
        self.ready()?;
        if total_len != self.next_offset {
            return self.fail(SourceError::argument(DETAIL_BAD_OFFSET, total_len));
        }
        if self.finished { return Ok(()); }
        let eof_error = match self.token.take() {
            Some(Token::Number { node, state }) => match state.finish() {
                Ok(()) => { self.complete(node, total_len); None },
                Err(code) => Some(SourceError::json(code, self.nodes[node].raw_start)),
            },
            Some(Token::String { start, state, .. }) => Some(match state.finish() {
                Err(code) => SourceError::json(code, start),
                Ok(()) => SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, total_len),
            }),
            Some(Token::Literal { .. }) => Some(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, total_len)),
            None => None,
        };
        if let Some(error) = eof_error { return self.fail(error); }
        if self.nodes.is_empty() || !self.frames.is_empty() || !self.nodes[0].complete {
            return self.fail(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, total_len));
        }
        self.finished = true;
        Ok(())
    }

    pub fn root(&self) -> Result<Option<usize>, SourceError> {
        self.ready().map(|ready| if ready { Some(0) } else { None })
    }

    pub fn node(&self, id: usize) -> Result<Option<&Node>, SourceError> {
        if !self.ready()? { return Ok(None); }
        self.nodes.get(id).map(Some).ok_or_else(|| SourceError::argument(DETAIL_NONE, self.next_offset))
    }

    pub fn abort(&mut self, detail: u32) -> SourceError {
        *self.failure.get_or_insert(SourceError { code: leanjson_err::LEANJSON_OK, detail, offset: self.next_offset })
    }

    fn complete(&mut self, id: usize, end: u64) {
        self.nodes[id].raw_end = end;
        self.nodes[id].complete = true;
    }

    fn allocate(&mut self, kind: leanjson_type, offset: u64) -> usize {
        let id = self.nodes.len();
        self.nodes.push(Node { kind, raw_start: offset, raw_end: offset, complete: false, members: Vec::new() });
        if let Some(frame) = self.frames.last_mut() {
            let (key_start, key_end) = frame.key;
            self.nodes[frame.node].members.push(Member { key_start, key_end, value: id });
            frame.key = (0, 0);
            frame.state = match frame.state {
                FrameState::ObjectValue => FrameState::ObjectAfter,
                _ => FrameState::ArrayAfter,
            };
        }
        id
    }

    fn start_value(&mut self, byte: u8, offset: u64) -> Result<(), SourceError> {
        let kind = match byte {
            b'{' => leanjson_type::LEANJSON_T_OBJ,
            b'[' => leanjson_type::LEANJSON_T_ARR,
            b'"' => leanjson_type::LEANJSON_T_STR,
            b't' | b'f' => leanjson_type::LEANJSON_T_BOOL,
            b'n' => leanjson_type::LEANJSON_T_NULL,
            b'-' | b'0'..=b'9' => leanjson_type::LEANJSON_T_NUM,
            _ => return Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset)),
        };
        if matches!(byte, b'{' | b'[') && self.frames.len() as u32 >= self.max_depth {
            return Err(SourceError::json(leanjson_err::LEANJSON_NESTING_TOO_DEEP, offset));
        }
        let node = self.allocate(kind, offset);
        match byte {
            b'{' | b'[' => self.frames.push(Frame {
                node, key: (0, 0),
                state: if byte == b'{' { FrameState::ObjectFirst } else { FrameState::ArrayFirst },
            }),
            b'"' => self.token = Some(Token::String { start: offset, node: Some(node), state: StringState::new() }),
            b't' | b'f' | b'n' => self.token = Some(Token::Literal {
                node, expected: match byte { b't' => b"true", b'f' => b"false", _ => b"null" }, matched: 1,
            }),
            _ => {
                let mut state = NumberState::new();
                state.feed(byte).map_err(|code| SourceError::json(code, offset))?;
                self.token = Some(Token::Number { node, state });
            },
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
                self.token = Some(Token::String { start: offset, node: None, state: StringState::new() });
                Ok(())
            },
            Some(ObjectColon) if byte == b':' => {
                self.frames.last_mut().unwrap().state = ObjectValue;
                Ok(())
            },
            Some(ArrayAfter) if byte == b',' => {
                self.frames.last_mut().unwrap().state = ArrayValue;
                Ok(())
            },
            Some(ObjectAfter) if byte == b',' => {
                self.frames.last_mut().unwrap().state = ObjectKey;
                Ok(())
            },
            Some(ArrayAfter) if byte == b']' => self.close_container(offset),
            Some(ObjectAfter) if byte == b'}' => self.close_container(offset),
            _ => Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset)),
        }
    }

    fn close_container(&mut self, offset: u64) -> Result<(), SourceError> {
        let frame = self.frames.pop().unwrap();
        self.complete(frame.node, offset + 1);
        Ok(())
    }

    fn token_byte(&mut self, token: Token, byte: u8, offset: u64) -> Result<bool, SourceError> {
        match token {
            Token::String { start, node, mut state } => {
                if byte == b'"' && state.at_boundary() {
                    match node {
                        Some(node) => self.complete(node, offset + 1),
                        None => {
                            let frame = self.frames.last_mut().unwrap();
                            frame.key = (start, offset + 1);
                            frame.state = FrameState::ObjectColon;
                        },
                    }
                } else {
                    state.feed(byte).map_err(|code| SourceError::json(code, start))?;
                    self.token = Some(Token::String { start, node, state });
                }
            },
            Token::Number { node, mut state } => {
                if is_delimiter(byte) {
                    state.finish().map_err(|code| SourceError::json(code, self.nodes[node].raw_start))?;
                    self.complete(node, offset);
                    return Ok(false);
                }
                state.feed(byte).map_err(|code| SourceError::json(code, self.nodes[node].raw_start))?;
                self.token = Some(Token::Number { node, state });
            },
            Token::Literal { node, expected, mut matched } => {
                if byte != expected[matched] {
                    return Err(SourceError::json(leanjson_err::LEANJSON_PARSE_ERROR, offset));
                }
                matched += 1;
                if matched == expected.len() { self.complete(node, offset + 1); }
                else { self.token = Some(Token::Literal { node, expected, matched }); }
            },
        }
        Ok(true)
    }
}

fn is_whitespace(byte: u8) -> bool { matches!(byte, b' ' | b'\t' | b'\r' | b'\n') }
fn is_delimiter(byte: u8) -> bool { is_whitespace(byte) || matches!(byte, b',' | b':' | b'[' | b']' | b'{' | b'}') }
