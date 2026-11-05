//! Native public diagnostics without decoded values or retained input. This
//! companion tokenizer deliberately accepts native numeric prefixes and raw
//! control bytes; the strict validator remains authoritative for acceptance.
use super::validate::NumberState;

#[derive(Clone, Copy)]
enum Context { ArrayFirst, ArrayValue, ArrayAfter, ObjectFirst, ObjectKey, ObjectColon, ObjectValue, ObjectAfter }
#[derive(Clone, Copy, PartialEq)]
enum Kind { Object, ObjectEnd, Array, ArrayEnd, String, Number, Integer, Boolean, Null, Colon, Comma, End }
impl Kind {
    fn name(self) -> &'static str { match self {
        Self::Object => "T_OBJ_BEGIN", Self::ObjectEnd => "T_OBJ_END", Self::Array => "T_ARR_BEGIN", Self::ArrayEnd => "T_ARR_END",
        Self::String => "T_STRING", Self::Number => "T_NUMBER", Self::Integer => "T_INTEGER", Self::Boolean => "T_BOOLEAN",
        Self::Null => "T_NULL", Self::Colon => "T_COLON", Self::Comma => "T_COMMA", Self::End => "T_END",
    } }
}
#[derive(Clone, Copy)]
enum StringPhase { Plain, Escape(u64), Hex { slash: u64, unit: u16, digits: u8, low: bool }, LowSlash(u64), LowU(u64) }
enum Lex {
    Comment { start: u64, state: super::comment::Comment },
    String { start: u64, phase: StringPhase },
    Word { start: u64, bytes: [u8; 5], len: usize },
    Number { start: u64, state: NumberState, accepted: Option<u64>, tail: [u8; 16], tail_len: usize, float: bool, strict_bad: bool, first_zero: bool, digits: usize },
}
#[derive(Clone)]
pub(super) enum Diagnostic {
    Syntax { expected: &'static str, found: &'static str, offset: u64 },
    Depth { depth: usize, offset: u64 },
    Encoding,
}
impl Diagnostic {
    pub(super) fn message(&self) -> String { match self {
        Self::Syntax { expected, found, offset } => format!("Expected {expected} but found {found} at character {}", offset + 1),
        Self::Depth { depth, offset } => format!("Found too many nested data structures ({depth}) at character {}", offset + 1),
        Self::Encoding => "JSON parser does not support UTF-16 or UTF-32".into(),
    } }
}
pub(super) struct Diagnostics {
    frames: Vec<Context>, lex: Option<Lex>, root: bool, ended: bool, max_depth: u32, invalid_numbers: bool, comments: bool,
    first: Option<u8>, seen: u64, error: Option<Diagnostic>,
}
impl Diagnostics {
    pub(super) fn new(max_depth: u32, invalid_numbers: bool, comments: bool) -> Self {
        Self { frames: Vec::new(), lex: None, root: false, ended: false, max_depth, invalid_numbers, comments, first: None, seen: 0, error: None }
    }
    pub(super) fn error(&self) -> Option<&Diagnostic> { if self.seen >= 2 { self.error.as_ref() } else { None } }
    fn expected(&self) -> &'static str { use Context::*; match self.frames.last() {
        Some(ObjectFirst | ObjectKey) => "object key string", Some(ObjectColon) => "colon",
        Some(ArrayAfter) => "comma or array end", Some(ObjectAfter) => "comma or object end",
        None if self.root => "the end", _ => "value",
    } }
    fn fail(&mut self, found: &'static str, offset: u64) { self.error = Some(Diagnostic::Syntax { expected: self.expected(), found, offset }); }
    fn token(&mut self, kind: Kind, offset: u64) {
        use Context::*;
        if self.error.is_some() { return; }
        match self.frames.last().copied() {
            Some(ArrayFirst) if kind == Kind::ArrayEnd => { self.frames.pop(); return; },
            Some(ObjectFirst) if kind == Kind::ObjectEnd => { self.frames.pop(); return; },
            Some(ObjectFirst | ObjectKey) if kind == Kind::String => { *self.frames.last_mut().unwrap() = ObjectColon; return; },
            Some(ObjectColon) if kind == Kind::Colon => { *self.frames.last_mut().unwrap() = ObjectValue; return; },
            Some(ArrayAfter) if kind == Kind::Comma => { *self.frames.last_mut().unwrap() = ArrayValue; return; },
            Some(ObjectAfter) if kind == Kind::Comma => { *self.frames.last_mut().unwrap() = ObjectKey; return; },
            Some(ArrayAfter) if kind == Kind::ArrayEnd => { self.frames.pop(); return; },
            Some(ObjectAfter) if kind == Kind::ObjectEnd => { self.frames.pop(); return; },
            None if self.root && kind == Kind::End => { self.ended = true; return; },
            Some(ArrayFirst | ArrayValue | ObjectValue) => {},
            None if !self.root => {},
            _ => { self.fail(kind.name(), offset); return; },
        }
        if !matches!(kind, Kind::String | Kind::Number | Kind::Integer | Kind::Boolean | Kind::Null | Kind::Array | Kind::Object) {
            self.fail(kind.name(), offset); return;
        }
        if let Some(state) = self.frames.last_mut() { *state = if matches!(state, ObjectValue) { ObjectAfter } else { ArrayAfter }; }
        else { self.root = true; }
        if matches!(kind, Kind::Array | Kind::Object) {
            if self.frames.len() as u32 >= self.max_depth { self.error = Some(Diagnostic::Depth { depth: self.frames.len() + 1, offset }); }
            else { self.frames.push(if kind == Kind::Array { ArrayFirst } else { ObjectFirst }); }
        }
    }
    pub(super) fn feed_slice(&mut self, bytes: &[u8], base: u64, fast: bool) {
        let mut i = 0;
        while i < bytes.len() {
            // The first two bytes have special encoding-detection semantics.
            if fast && self.seen >= 2 {
                if self.error.is_some() || self.ended { self.seen += (bytes.len() - i) as u64; break; }
                if matches!(&self.lex, Some(Lex::String { phase: StringPhase::Plain, .. })) {
                    let (count, _) = super::cjson::plain(&bytes[i..], true);
                    if count != 0 { self.seen += count as u64; i += count; continue; }
                }
            }
            self.feed(bytes[i], base + i as u64);
            i += 1;
        }
    }
    pub(super) fn feed(&mut self, byte: u8, offset: u64) {
        if self.seen == 0 { self.first = Some(byte); }
        if self.seen == 1 && (self.first == Some(0) || byte == 0) { self.error = Some(Diagnostic::Encoding); }
        self.seen += 1;
        if self.error.is_none() && !self.ended { self.byte(byte, offset); }
    }
    fn byte(&mut self, byte: u8, offset: u64) {
        if self.error.is_some() || self.ended { return; }
        match self.lex.take() {
            None => {
                let kind = match byte {
                    b' ' | b'\n' | b'\r' | b'\t' => return,
                    b'/' if self.comments => { self.lex = Some(Lex::Comment { start: offset, state: super::comment::Comment::Start }); return; },
                    b'{' => Kind::Object, b'}' => Kind::ObjectEnd, b'[' => Kind::Array, b']' => Kind::ArrayEnd,
                    b':' => Kind::Colon, b',' => Kind::Comma, 0 => Kind::End,
                    b'"' => { self.lex = Some(Lex::String { start: offset, phase: StringPhase::Plain }); return; },
                    b't' | b'f' | b'n' | b'i' | b'I' | b'N' => { let mut bytes = [0;5]; bytes[0] = byte; self.lex = Some(Lex::Word { start: offset, bytes, len: 1 }); return; },
                    b'-' | b'0'..=b'9' => { self.number(byte, offset); return; },
                    b'+' if self.invalid_numbers => { self.number(byte, offset); return; },
                    _ => { self.fail("invalid token", offset); return; },
                };
                self.token(kind, offset);
            },
            Some(Lex::Comment { start, mut state }) => {
                use super::comment::Step;
                match state.feed(byte) {
                    Step::More => self.lex = Some(Lex::Comment { start, state }),
                    Step::End => {},
                    Step::EndInput => self.token(Kind::End, offset),
                    Step::Invalid => self.fail("invalid token", start),
                    Step::Unclosed => self.fail("unclosed multi-line comment", offset),
                }
            },
            Some(Lex::String { start, mut phase }) => {
                use StringPhase::*;
                phase = match phase {
                    Plain if byte == b'"' => { self.token(Kind::String, start); return; },
                    Plain if byte == 0 => { self.fail("unexpected end of string", offset); return; },
                    Plain if byte == b'\\' => Escape(offset),
                    Plain => Plain,
                    Escape(slash) => match byte {
                        b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => Plain,
                        b'u' => Hex { slash, unit: 0, digits: 0, low: false },
                        _ => { self.fail("invalid escape code", slash); return; },
                    },
                    Hex { slash, unit, digits, low } => {
                        let hex = match byte { b'0'..=b'9' => byte-b'0', b'a'..=b'f' => byte-b'a'+10, b'A'..=b'F' => byte-b'A'+10,
                            _ => { self.fail("invalid unicode escape code", slash); return; } };
                        let unit = unit << 4 | u16::from(hex);
                        if digits < 3 { Hex { slash, unit, digits: digits + 1, low } }
                        else if low { if !(0xDC00..=0xDFFF).contains(&unit) { self.fail("invalid unicode escape code", slash); return; } Plain }
                        else if (0xD800..=0xDBFF).contains(&unit) { LowSlash(slash) }
                        else if (0xDC00..=0xDFFF).contains(&unit) { self.fail("invalid unicode escape code", slash); return; }
                        else { Plain }
                    },
                    LowSlash(slash) => { if byte != b'\\' { self.fail("invalid unicode escape code", slash); return; } LowU(slash) },
                    LowU(slash) => { if byte != b'u' { self.fail("invalid unicode escape code", slash); return; } Hex { slash, unit: 0, digits: 0, low: true } },
                };
                self.lex = Some(Lex::String { start, phase });
            },
            Some(Lex::Word { start, mut bytes, mut len }) => {
                bytes[len] = byte; len += 1;
                let prefix = &bytes[..len];
                let numeric_word = self.invalid_numbers && (b"nan".get(..len).is_some_and(|word| word.eq_ignore_ascii_case(prefix))
                    || b"inf".get(..len).is_some_and(|word| word.eq_ignore_ascii_case(prefix)));
                if numeric_word && len < 3 { self.lex = Some(Lex::Word { start, bytes, len }); }
                else if numeric_word {
                    let mut state = NumberState::new(true);
                    for &b in prefix { state.feed(b).unwrap(); }
                    self.lex = Some(Lex::Number { start, accepted: state.finish().ok().map(|_| offset+1), state, tail: [0;16], tail_len: 0, float: true, strict_bad: false, first_zero: false, digits: 0 });
                } else if prefix == b"true" || prefix == b"false" || prefix == b"null" { self.token(if prefix == b"null" { Kind::Null } else { Kind::Boolean }, start); }
                else if b"true".starts_with(prefix) || b"false".starts_with(prefix) || b"null".starts_with(prefix) {
                    self.lex = Some(Lex::Word { start, bytes, len });
                } else { self.fail("invalid token", start); }
            },
            Some(Lex::Number { start, mut state, mut accepted, mut tail, mut tail_len, mut float, mut strict_bad, mut first_zero, mut digits }) => {
                if matches!(byte, b'.' | b'e' | b'E' | b'x') { float = true; }
                if digits == 0 && byte == b'0' { first_zero = true; }
                if digits == 0 && matches!(byte, b'i' | b'I' | b'n' | b'N') { float = true; strict_bad = true; }
                if byte.is_ascii_digit() { digits += 1; if first_zero && digits > 1 && !float { strict_bad = true; } }
                if matches!(byte, b'x' | b'X') && first_zero { strict_bad = true; }
                if state.feed(byte).is_ok() {
                    if state.finish().is_ok() { accepted = Some(offset + 1); tail_len = 0; }
                    else if tail_len < tail.len() { tail[tail_len] = byte; tail_len += 1; }
                    self.lex = Some(Lex::Number { start, state, accepted, tail, tail_len, float, strict_bad, first_zero, digits });
                } else { self.end_number(start, accepted, &tail[..tail_len], float, strict_bad); self.byte(byte, offset); }
            },
        }
    }
    fn number(&mut self, byte: u8, start: u64) {
        let mut state = NumberState::new(true); state.feed(byte).unwrap();
        self.lex = Some(Lex::Number { start, accepted: state.finish().ok().map(|_| start+1), state, tail: [0;16], tail_len: 0,
            float: false, strict_bad: false, first_zero: byte == b'0', digits: usize::from(byte.is_ascii_digit()) });
    }
    fn end_number(&mut self, start: u64, accepted: Option<u64>, tail: &[u8], float: bool, strict_bad: bool) {
        if strict_bad && !self.invalid_numbers { self.fail("invalid number", start); return; }
        if let Some(end) = accepted {
            self.token(if float { Kind::Number } else { Kind::Integer }, start);
            for (i, &byte) in tail.iter().enumerate() { self.byte(byte, end + i as u64); }
        } else { self.fail("invalid number", start); }
    }
    pub(super) fn finish(&mut self, offset: u64) {
        if self.error.is_some() { return; }
        match self.lex.take() {
            Some(Lex::Comment { start, state }) => { if let Some(found) = state.eof_error() {
                self.fail(found, if matches!(state, super::comment::Comment::Start) { start } else { offset });
            } },
            Some(Lex::String { phase, .. }) => { match phase {
                StringPhase::Escape(slash) => self.fail("invalid escape code", slash),
                StringPhase::Hex { slash, .. } | StringPhase::LowSlash(slash) | StringPhase::LowU(slash) => self.fail("invalid unicode escape code", slash),
                _ => self.fail("unexpected end of string", offset),
            } },
            Some(Lex::Word { start, .. }) => self.fail("invalid token", start),
            Some(Lex::Number { start, accepted, tail, tail_len, float, strict_bad, .. }) => {
                self.end_number(start, accepted, &tail[..tail_len], float, strict_bad);
                if self.lex.is_some() { self.finish(offset); }
            },
            None => {},
        }
        if self.error.is_none() && !self.ended { self.token(Kind::End, offset); }
    }
    pub(super) fn message(&self) -> Option<String> { self.error.as_ref().map(Diagnostic::message) }
}
