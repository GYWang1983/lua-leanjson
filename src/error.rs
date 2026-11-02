#![allow(non_camel_case_types)]

use std::fmt::Write;
use std::os::raw::c_int;

pub const LEANJSON_NO_OFFSET: usize = usize::MAX;
pub const LEANJSON_EXPECT_CONTAINER: usize = usize::MAX - 1;

#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum leanjson_err {
    LEANJSON_OK                  =  0,
    LEANJSON_PARSE_ERROR         =  1,
    LEANJSON_NOT_FOUND           =  2,
    LEANJSON_TYPE_MISMATCH       =  3,
    LEANJSON_OUT_OF_RANGE        =  4,
    LEANJSON_DECODE_FAILED       =  5,
    LEANJSON_INVALID_PATH        =  6,
    LEANJSON_INVALID_ARG         =  7,
    LEANJSON_OOM                 =  8,
    LEANJSON_NESTING_TOO_DEEP    =  9,
    LEANJSON_TRAILING_CONTENT    = 10,
    LEANJSON_NUMBER_OUT_OF_RANGE = 11,
    LEANJSON_INVALID_NUMBER      = 12,
    LEANJSON_INVALID_STRING      = 13,
    LEANJSON_INVALID_UTF8        = 14,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct leanjson_error {
    pub code:   c_int,
    pub offset: usize,
}

impl leanjson_error {
    pub fn new(code: leanjson_err, offset: usize) -> Self {
        Self { code: code as c_int, offset }
    }

    pub fn no_offset(code: leanjson_err) -> Self {
        Self::new(code, LEANJSON_NO_OFFSET)
    }
}

impl Default for leanjson_error {
    fn default() -> Self {
        Self::no_offset(leanjson_err::LEANJSON_OK)
    }
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) struct ParseError {
    pub code:   leanjson_err,
    pub offset: usize,
}

impl ParseError {
    pub(crate) fn new(code: leanjson_err, offset: usize) -> Self {
        Self { code, offset }
    }

    pub(crate) fn no_offset(code: leanjson_err) -> Self {
        Self::new(code, LEANJSON_NO_OFFSET)
    }
}

impl From<ParseError> for leanjson_error {
    fn from(err: ParseError) -> Self {
        Self::new(err.code, err.offset)
    }
}

#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum leanjson_type {
    LEANJSON_T_NULL = 0,
    LEANJSON_T_BOOL = 1,
    LEANJSON_T_NUM  = 2,
    LEANJSON_T_STR  = 3,
    LEANJSON_T_ARR  = 4,
    LEANJSON_T_OBJ  = 5,
}

pub fn strerror(code: leanjson_err) -> &'static str {
    match code {
        leanjson_err::LEANJSON_OK                  => "ok",
        leanjson_err::LEANJSON_PARSE_ERROR         => "JSON parse error",
        leanjson_err::LEANJSON_NOT_FOUND           => "path not found",
        leanjson_err::LEANJSON_TYPE_MISMATCH       => "type mismatch at path",
        leanjson_err::LEANJSON_OUT_OF_RANGE        => "numeric out of range",
        leanjson_err::LEANJSON_DECODE_FAILED       => "decode failed",
        leanjson_err::LEANJSON_INVALID_PATH        => "invalid path syntax",
        leanjson_err::LEANJSON_INVALID_ARG         => "invalid argument",
        leanjson_err::LEANJSON_OOM                 => "out of memory",
        leanjson_err::LEANJSON_NESTING_TOO_DEEP    => "nesting depth exceeds limit",
        leanjson_err::LEANJSON_TRAILING_CONTENT    => "trailing content after root value",
        leanjson_err::LEANJSON_NUMBER_OUT_OF_RANGE => "number out of representable range",
        leanjson_err::LEANJSON_INVALID_NUMBER      => "invalid number format (RFC 8259)",
        leanjson_err::LEANJSON_INVALID_STRING      => "invalid string content (unescaped control char)",
        leanjson_err::LEANJSON_INVALID_UTF8        => "invalid UTF-8 in string",
    }
}

fn expected_type_name(extra: usize) -> Option<&'static str> {
    match extra {
        LEANJSON_EXPECT_CONTAINER => Some("array/object"),
        x if x == leanjson_type::LEANJSON_T_NULL as usize => Some("null"),
        x if x == leanjson_type::LEANJSON_T_BOOL as usize => Some("boolean"),
        x if x == leanjson_type::LEANJSON_T_NUM as usize => Some("number"),
        x if x == leanjson_type::LEANJSON_T_STR as usize => Some("string"),
        x if x == leanjson_type::LEANJSON_T_ARR as usize => Some("array"),
        x if x == leanjson_type::LEANJSON_T_OBJ as usize => Some("object"),
        _ => None,
    }
}

fn inferred_type_name(buf: &[u8], offset: usize) -> Option<&'static str> {
    let lead = *buf.get(offset)?;
    match lead {
        b'{' => Some("object"),
        b'[' => Some("array"),
        b'"' => Some("string"),
        b't' | b'f' => Some("boolean"),
        b'n' => Some("null"),
        b'-' | b'0'..=b'9' => Some("number"),
        _ => None,
    }
}

fn push_offset(msg: &mut String, offset: usize) {
    if offset != LEANJSON_NO_OFFSET {
        write!(msg, " at byte {offset}").expect("write into String");
    }
}

fn escape_unexpected_char(byte: u8) -> String {
    if (0x20..=0x7E).contains(&byte) {
        match byte {
            b'\'' => "'\\''".to_string(),
            b'\\' => "'\\\\'".to_string(),
            _ => format!("'{}'", byte as char),
        }
    } else {
        format!("0x{byte:02X}")
    }
}

fn escape_snippet(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    for &b in bytes {
        if (0x20..=0x7E).contains(&b) {
            match b {
                b'\'' => out.push_str("\\'"),
                b'\\' => out.push_str("\\\\"),
                _ => out.push(b as char),
            }
        } else {
            write!(out, "\\x{b:02X}").expect("write into String");
        }
    }
    out
}

fn is_snippet_boundary(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | b',' | b':' | b'}' | b']')
}

fn snippet_from_offset(buf: &[u8], offset: usize) -> String {
    if offset >= buf.len() {
        return String::new();
    }
    const CAP: usize = 20;
    let mut end = offset;
    while end < buf.len() && end - offset < CAP {
        if end > offset && is_snippet_boundary(buf[end]) {
            break;
        }
        end += 1;
    }
    escape_snippet(&buf[offset..end])
}

pub fn format_error(code: leanjson_err, offset: usize, extra: usize, buf: &[u8]) -> String {
    match code {
        leanjson_err::LEANJSON_PARSE_ERROR => {
            let mut msg = String::new();
            if offset != LEANJSON_NO_OFFSET {
                if let Some(&byte) = buf.get(offset) {
                    write!(msg, "parse error at byte {offset}: unexpected {}", escape_unexpected_char(byte))
                        .expect("write into String");
                    if matches!(byte, b'}' | b']' | b',') {
                        msg.push_str(", expected value");
                    }
                } else {
                    write!(msg, "parse error at byte {offset}").expect("write into String");
                }
            } else {
                msg.push_str("parse error");
            }
            msg
        }
        leanjson_err::LEANJSON_INVALID_NUMBER => {
            let mut msg = String::new();
            let snippet = snippet_from_offset(buf, offset);
            if snippet.is_empty() {
                msg.push_str("invalid number");
            } else {
                write!(msg, "invalid number '{snippet}'").expect("write into String");
            }
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_INVALID_STRING => {
            let mut msg = "invalid string content".to_string();
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_INVALID_UTF8 => {
            let mut msg = "invalid UTF-8 in string".to_string();
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_NESTING_TOO_DEEP => {
            let mut msg = String::new();
            if offset == LEANJSON_NO_OFFSET {
                write!(msg, "nesting too deep (max {extra})").expect("write into String");
            } else {
                write!(msg, "nesting too deep at byte {offset} (max {extra})")
                    .expect("write into String");
            }
            msg
        }
        leanjson_err::LEANJSON_TRAILING_CONTENT => {
            let mut msg = String::new();
            let snippet = snippet_from_offset(buf, offset);
            if snippet.is_empty() {
                msg.push_str("trailing content after root value");
            } else {
                write!(msg, "trailing content '{snippet}' after root value").expect("write into String");
            }
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_TYPE_MISMATCH => {
            let mut msg = String::new();
            match (expected_type_name(extra), inferred_type_name(buf, offset)) {
                (Some(expected), Some(got)) => {
                    write!(msg, "type mismatch: expected {expected}, got {got}").expect("write into String");
                }
                _ => {
                    msg.push_str("type mismatch");
                }
            }
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_OUT_OF_RANGE | leanjson_err::LEANJSON_NUMBER_OUT_OF_RANGE => {
            let mut msg = "out of range".to_string();
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_DECODE_FAILED => {
            let mut msg = "decode failed".to_string();
            push_offset(&mut msg, offset);
            msg
        }
        leanjson_err::LEANJSON_NOT_FOUND => "path not found".to_string(),
        leanjson_err::LEANJSON_INVALID_PATH => "invalid path syntax".to_string(),
        leanjson_err::LEANJSON_INVALID_ARG => "invalid argument".to_string(),
        leanjson_err::LEANJSON_OK => "ok".to_string(),
        leanjson_err::LEANJSON_OOM => "out of memory".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strerror_covers_every_variant() {
        for code in [
            leanjson_err::LEANJSON_OK, leanjson_err::LEANJSON_PARSE_ERROR, leanjson_err::LEANJSON_NOT_FOUND,
            leanjson_err::LEANJSON_TYPE_MISMATCH, leanjson_err::LEANJSON_OUT_OF_RANGE,
            leanjson_err::LEANJSON_DECODE_FAILED, leanjson_err::LEANJSON_INVALID_PATH,
            leanjson_err::LEANJSON_INVALID_ARG, leanjson_err::LEANJSON_OOM,
            leanjson_err::LEANJSON_NESTING_TOO_DEEP, leanjson_err::LEANJSON_TRAILING_CONTENT,
            leanjson_err::LEANJSON_NUMBER_OUT_OF_RANGE, leanjson_err::LEANJSON_INVALID_NUMBER,
            leanjson_err::LEANJSON_INVALID_STRING, leanjson_err::LEANJSON_INVALID_UTF8,
        ] {
            assert!(!strerror(code).is_empty());
        }
    }

    #[test]
    fn format_parse_error_with_expected_value_clause() {
        let msg = format_error(leanjson_err::LEANJSON_PARSE_ERROR, 1, 0, b"[}");
        assert_eq!(msg, "parse error at byte 1: unexpected '}', expected value");
    }

    #[test]
    fn format_parse_error_escapes_unexpected_char() {
        let msg = format_error(leanjson_err::LEANJSON_PARSE_ERROR, 0, 0, b"\\");
        assert_eq!(msg, "parse error at byte 0: unexpected '\\\\'");
    }

    #[test]
    fn format_number_and_trailing_snippets() {
        assert_eq!(
            format_error(leanjson_err::LEANJSON_INVALID_NUMBER, 1, 0, b"[01]"),
            "invalid number '01' at byte 1"
        );
        assert_eq!(
            format_error(leanjson_err::LEANJSON_TRAILING_CONTENT, 2, 0, b"{}garbage"),
            "trailing content 'garbage' after root value at byte 2"
        );
    }

    #[test]
    fn format_type_mismatch_with_and_without_got_type() {
        let msg = format_error(
            leanjson_err::LEANJSON_TYPE_MISMATCH,
            15,
            leanjson_type::LEANJSON_T_STR as usize,
            br#"{"user":{"age":42}}"#,
        );
        assert_eq!(msg, "type mismatch: expected string, got number at byte 15");

        let msg = format_error(
            leanjson_err::LEANJSON_TYPE_MISMATCH,
            LEANJSON_NO_OFFSET,
            leanjson_type::LEANJSON_T_STR as usize,
            b"",
        );
        assert_eq!(msg, "type mismatch");

        let msg = format_error(
            leanjson_err::LEANJSON_TYPE_MISMATCH,
            5,
            LEANJSON_EXPECT_CONTAINER,
            br#"{"n":1}"#,
        );
        assert_eq!(msg, "type mismatch: expected array/object, got number at byte 5");
    }

    #[test]
    fn format_nesting_and_range_messages() {
        assert_eq!(
            format_error(leanjson_err::LEANJSON_NESTING_TOO_DEEP, 2, 7, b"[[[0]]]"),
            "nesting too deep at byte 2 (max 7)"
        );
        assert_eq!(
            format_error(leanjson_err::LEANJSON_OUT_OF_RANGE, 24, 0, b""),
            "out of range at byte 24"
        );
    }
}
