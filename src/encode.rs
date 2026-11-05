//! Bounded byte processing for JSON output. No input pointer is retained.
use crate::error::leanjson_err;

pub const ESCAPE_SLASH: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct EncodeCursor { pub offset: usize, pub escape_offset: u32, pub reserved: u32 }

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DepthState { pub depth: u32, pub maximum: u32, pub quoted: u32, pub escaped: u32 }

fn escape(byte: u8, flags: u32) -> Option<([u8; 6], usize)> {
    let code = match byte {
        b'"' => b'"', b'\\' => b'\\', b'/' if flags & ESCAPE_SLASH != 0 => b'/',
        8 => b'b', 12 => b'f', b'\n' => b'n', b'\r' => b'r', b'\t' => b't',
        0..=31 | 127 => {
            const HEX: &[u8; 16] = b"0123456789abcdef";
            return Some(([b'\\',b'u',b'0',b'0',HEX[(byte >> 4) as usize],HEX[(byte & 15) as usize]],6));
        },
        _ => return None,
    };
    Some(([b'\\',code,0,0,0,0],2))
}

pub fn string_length(bytes: &[u8], flags: u32) -> Result<usize, leanjson_err> {
    let mut length = bytes.len();
    for &byte in bytes {
        if let Some((_, count)) = escape(byte, flags) {
            length = length.checked_add(count-1).ok_or(leanjson_err::LEANJSON_OUT_OF_RANGE)?;
        }
    }
    Ok(length)
}

pub fn string_chunk(bytes: &[u8], flags: u32, cursor: &mut EncodeCursor, output: &mut [u8]) -> Result<usize, leanjson_err> {
    use leanjson_err::LEANJSON_INVALID_ARG;
    if cursor.reserved != 0 || cursor.offset > bytes.len() { return Err(LEANJSON_INVALID_ARG); }
    if cursor.escape_offset != 0 {
        let count = bytes.get(cursor.offset).and_then(|&byte| escape(byte, flags)).map(|(_, n)| n);
        if count.is_none_or(|n| cursor.escape_offset as usize >= n) { return Err(LEANJSON_INVALID_ARG); }
    }
    let mut written = 0;
    while cursor.offset < bytes.len() && written < output.len() {
        if let Some((encoded, count)) = escape(bytes[cursor.offset], flags) {
            let first = cursor.escape_offset as usize;
            let n = (count-first).min(output.len()-written);
            output[written..written+n].copy_from_slice(&encoded[first..first+n]);
            written += n;
            if first+n == count { cursor.offset += 1; cursor.escape_offset = 0; }
            else { cursor.escape_offset = (first+n) as u32; }
        } else {
            let first = cursor.offset;
            let end = bytes.len().min(first+output.len()-written);
            cursor.offset += 1;
            while cursor.offset < end && escape(bytes[cursor.offset], flags).is_none() { cursor.offset += 1; }
            let n = cursor.offset-first;
            output[written..written+n].copy_from_slice(&bytes[first..cursor.offset]);
            written += n;
        }
    }
    Ok(written)
}

/// Source bytes are already JSON-validated. This checks only output nesting,
/// keeping quote/escape state across input windows without decoded strings.
pub fn depth_chunk(bytes: &[u8], state: &mut DepthState) -> Result<(), leanjson_err> {
    use leanjson_err::*;
    if state.maximum == 0 || state.depth > state.maximum || state.quoted > 1 || state.escaped > 1
        || state.escaped != 0 && state.quoted == 0 { return Err(LEANJSON_INVALID_ARG); }
    for &byte in bytes {
        if state.quoted != 0 {
            if state.escaped != 0 { state.escaped = 0; }
            else if byte == b'\\' { state.escaped = 1; }
            else if byte == b'"' { state.quoted = 0; }
        } else { match byte {
            b'"' => state.quoted = 1,
            b'{' | b'[' => {
                state.depth = state.depth.checked_add(1).ok_or(LEANJSON_NESTING_TOO_DEEP)?;
                if state.depth > state.maximum { return Err(LEANJSON_NESTING_TOO_DEEP); }
            },
            b'}' | b']' => state.depth = state.depth.checked_sub(1).ok_or(LEANJSON_INVALID_ARG)?,
            _ => {},
        } }
    }
    Ok(())
}
