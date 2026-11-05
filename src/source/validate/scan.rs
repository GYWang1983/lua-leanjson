//! Block-local string work. The byte state remains the boundary/legacy oracle.
use super::{Decoded, StringState};
use crate::error::leanjson_err;

#[derive(Debug)]
pub(crate) struct StringRun { pub consumed: usize, pub closed: bool }
#[derive(Debug)]
pub(crate) struct StringScanError { pub code: leanjson_err, pub index: usize }

pub(crate) enum Escape { Byte(u8), Unicode(u32) }
impl Escape {
    fn len(&self) -> usize { match self { Self::Byte(_) => 1, Self::Unicode(n) => match n { 0..=0x7f => 1, 0x80..=0x7ff => 2, 0x800..=0xffff => 3, _ => 4 } } }
    fn needs_escape(&self) -> bool { matches!(self, Self::Byte(b'/' | 0x7f) | Self::Unicode(0x2f | 0x7f)) }
    fn decoded(&self) -> Decoded { match *self { Self::Byte(byte) => Decoded::byte(byte), Self::Unicode(n) => Decoded::codepoint(n) } }
}

pub(crate) enum EscapeRead { Complete { consumed: usize, value: Escape }, Incomplete, Invalid(usize) }

fn hex4(bytes: &[u8], base: usize) -> Result<u32, usize> {
    let mut value = 0;
    for (i, &b) in bytes.iter().enumerate() {
        value = (value << 4) | u32::from(match b {
            b'0'..=b'9' => b-b'0', b'a'..=b'f' => b-b'a'+10, b'A'..=b'F' => b-b'A'+10,
            _ => return Err(base+i),
        });
    }
    Ok(value)
}

/// Only Complete is consumed by diagnostics. Invalid/incomplete input stays on
/// its original state machine so native error positions/wording are unchanged.
pub(crate) fn read_escape(bytes: &[u8]) -> EscapeRead {
    debug_assert_eq!(bytes.first(), Some(&b'\\'));
    let Some(&code) = bytes.get(1) else { return EscapeRead::Incomplete; };
    let byte = match code {
        b'"' | b'\\' | b'/' => code, b'b' => 8, b'f' => 12, b'n' => b'\n', b'r' => b'\r', b't' => b'\t',
        b'u' => {
            let Some(hex) = bytes.get(2..6) else { return EscapeRead::Incomplete; };
            let high = match hex4(hex, 2) { Ok(n) => n, Err(index) => return EscapeRead::Invalid(index) };
            if (0xdc00..=0xdfff).contains(&high) { return EscapeRead::Invalid(5); }
            if !(0xd800..=0xdbff).contains(&high) { return EscapeRead::Complete { consumed: 6, value: Escape::Unicode(high) }; }
            if bytes.len() < 12 { return EscapeRead::Incomplete; }
            if bytes[6] != b'\\' { return EscapeRead::Invalid(6); }
            if bytes[7] != b'u' { return EscapeRead::Invalid(7); }
            let low = match hex4(&bytes[8..12], 8) { Ok(n) => n, Err(index) => return EscapeRead::Invalid(index) };
            if !(0xdc00..=0xdfff).contains(&low) { return EscapeRead::Invalid(11); }
            return EscapeRead::Complete { consumed: 12, value: Escape::Unicode(0x10000+((high-0xd800)<<10)+(low-0xdc00)) };
        },
        _ => return EscapeRead::Invalid(1),
    };
    EscapeRead::Complete { consumed: 2, value: Escape::Byte(byte) }
}

fn utf8_width(byte: u8) -> Option<usize> { match byte { 0xc2..=0xdf => Some(2), 0xe0..=0xef => Some(3), 0xf0..=0xf4 => Some(4), _ => None } }
fn utf8_error(bytes: &[u8]) -> Option<usize> {
    let low = match bytes[0] { 0xe0 => 0xa0, 0xf0 => 0x90, _ => 0x80 };
    let high = match bytes[0] { 0xed => 0x9f, 0xf4 => 0x8f, _ => 0xbf };
    if !(low..=high).contains(&bytes[1]) { return Some(1); }
    bytes[2..].iter().position(|&b| !(0x80..=0xbf).contains(&b)).map(|i| i+2)
}

impl StringState {
    /// Consume one string-body chunk. An end quote is consumed only when
    /// allowed; output may exceed its budget by at most one scalar's 3-byte
    /// remainder, which bounded readers keep outside their returned chunk.
    /// `decode=false` validates and counts without emitting/materializing bytes.
    pub(in crate::source) fn scan_chunk<F: FnMut(&[u8])>(&mut self, bytes: &[u8], end_quote: bool,
        output_limit: usize, decode: bool, mut emit: F) -> Result<StringRun, StringScanError>
    {
        let mut i = 0;
        let mut produced = 0usize;
        let mut bulk_plain = bytes.len() >= 128;
        while i < bytes.len() && produced < output_limit {
            // At most one split UTF-8 sequence or escape enters here. Complete
            // sequences below never round-trip through the generic byte state.
            if !self.at_boundary() {
                let decoded = self.feed(bytes[i]).map_err(|code| StringScanError { code, index: i })?;
                if decode && decoded.len != 0 { emit(&decoded.bytes[..decoded.len]); }
                produced += decoded.len;
                i += 1;
                continue;
            }
            let byte = bytes[i];
            if byte == b'"' {
                if end_quote { return Ok(StringRun { consumed: i+1, closed: true }); }
                return Err(StringScanError { code: leanjson_err::LEANJSON_INVALID_STRING, index: i });
            }
            if byte == b'\\' {
                match read_escape(&bytes[i..]) {
                    EscapeRead::Complete { consumed, value } => {
                        self.needs_escape |= value.needs_escape();
                        if decode { let decoded = value.decoded(); emit(&decoded.bytes[..decoded.len]); }
                        produced += value.len();
                        i += consumed;
                        continue;
                    },
                    EscapeRead::Invalid(index) => return Err(StringScanError { code: leanjson_err::LEANJSON_INVALID_STRING, index: i+index }),
                    EscapeRead::Incomplete => {
                        // Feed the slash once, then the pending branch handles
                        // any available suffix and preserves exact byte errors.
                        self.feed(byte).map_err(|code| StringScanError { code, index: i })?;
                        i += 1;
                        continue;
                    },
                }
            }
            if byte < 0x20 { return Err(StringScanError { code: leanjson_err::LEANJSON_INVALID_STRING, index: i }); }
            if byte >= 0x80 && !self.raw_bytes {
                let width = utf8_width(byte).ok_or(StringScanError { code: leanjson_err::LEANJSON_INVALID_UTF8, index: i })?;
                if bytes.len()-i < width {
                    let decoded = self.feed(byte).map_err(|code| StringScanError { code, index: i })?;
                    if decode { emit(&decoded.bytes[..decoded.len]); }
                    produced += decoded.len;
                    i += 1;
                } else {
                    let raw = &bytes[i..i+width];
                    if let Some(index) = utf8_error(raw) { return Err(StringScanError { code: leanjson_err::LEANJSON_INVALID_UTF8, index: i+index }); }
                    if decode { emit(raw); }
                    produced += width;
                    i += width;
                }
                continue;
            }
            let first = i;
            let max = (bytes.len()-i).min(output_limit-produced);
            if bulk_plain {
                let (count, escape) = crate::source::cjson::plain(&bytes[i..i+max], self.raw_bytes);
                self.needs_escape |= escape;
                i += count;
                // Dense escapes stay entirely in this Rust loop after the
                // first short run instead of making repeated tiny C calls.
                if count < 64 { bulk_plain = false; }
            } else {
                let end = i+max;
                while i < end {
                    let ch = bytes[i];
                    if ch < 0x20 || ch == b'"' || ch == b'\\' || !self.raw_bytes && ch >= 0x80 { break; }
                    self.needs_escape |= ch == b'/' || ch == 0x7f;
                    i += 1;
                }
            }
            debug_assert!(i > first);
            if decode { emit(&bytes[first..i]); }
            produced += i-first;
        }
        Ok(StringRun { consumed: i, closed: false })
    }
}
