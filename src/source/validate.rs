//! Fixed-size token state shared by incremental validation and string output.
use crate::error::leanjson_err;

#[derive(Clone, Copy)]
enum NumberPhase {
    Start, Sign, Zero, Integer, LeadingDot, Dot, Fraction, Exponent, ExponentSign, ExponentDigits,
    HexStart, HexInteger, HexLeadingDot, HexDot, HexFraction, HexExponent, HexExponentSign, HexExponentDigits,
    Word { word: &'static [u8], matched: usize }, Payload, PayloadEnd,
}

const OVERFLOW_MIDPOINT: &[u8; 309] = b"179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792";

/// Only a fixed hex prefix, a decimal midpoint comparison and counters survive
/// a feed. Hex needs at most 54 significant bits. Long exponents saturate
/// beyond any cancellation possible within a u64-sized source.
pub(super) struct NumberState {
    phase: NumberPhase,
    permissive: bool,
    hexadecimal: bool,
    digits: [u8; 15],
    stored: usize,
    decimal_order: std::cmp::Ordering,
    significant: i128,
    fractional: i128,
    exponent: i128,
    exponent_negative: bool,
}

impl NumberState {
    pub(super) fn new(permissive: bool) -> Self {
        Self { phase: NumberPhase::Start, permissive, hexadecimal: false, digits: [0; 15], stored: 0, decimal_order: std::cmp::Ordering::Equal,
            significant: 0, fractional: 0, exponent: 0, exponent_negative: false }
    }
    fn digit(&mut self, byte: u8, fractional: bool) {
        let digit = match byte { b'0'..=b'9' => byte - b'0', b'a'..=b'f' => byte - b'a' + 10, _ => byte - b'A' + 10 };
        if fractional { self.fractional += 1; }
        if self.significant != 0 || digit != 0 {
            self.significant += 1;
            if !self.hexadecimal && self.decimal_order == std::cmp::Ordering::Equal && self.significant <= 309 {
                self.decimal_order = digit.cmp(&(OVERFLOW_MIDPOINT[self.significant as usize - 1] - b'0'));
            }
            if self.stored < self.digits.len() { self.digits[self.stored] = digit; self.stored += 1; }
        }
    }
    fn exponent_digit(&mut self, byte: u8) {
        const CAP: i128 = u64::MAX as i128 * 4 + 4096;
        self.exponent = (self.exponent * 10 + i128::from(byte - b'0')).min(CAP);
    }
    pub(super) fn feed(&mut self, byte: u8) -> Result<(), leanjson_err> {
        use NumberPhase::*;
        self.phase = match (self.phase, byte) {
            (Start, b'-') => Sign,
            (Start, b'+') if self.permissive => Sign,
            (Start | Sign, b'0') => Zero,
            (Start | Sign, b'1'..=b'9') => { self.digit(byte, false); Integer },
            (Sign, b'.') if self.permissive => LeadingDot,
            (Start | Sign, b'i' | b'I') if self.permissive => Word { word: b"infinity", matched: 1 },
            (Start | Sign, b'n' | b'N') if self.permissive => Word { word: b"nan", matched: 1 },
            (Zero, b'x') if self.permissive => { self.hexadecimal = true; HexStart },
            (Zero, b'0'..=b'9') if self.permissive => { self.digit(byte, false); Integer },
            (Integer, b'0'..=b'9') => { self.digit(byte, false); Integer },
            (Zero | Integer, b'.') => Dot,
            (LeadingDot | Dot | Fraction, b'0'..=b'9') => { self.digit(byte, true); Fraction },
            (Zero | Integer | Fraction, b'e' | b'E') => Exponent,
            (Dot, b'e' | b'E') if self.permissive => Exponent,
            (Exponent, b'+' | b'-') => { self.exponent_negative = byte == b'-'; ExponentSign },
            (Exponent | ExponentSign | ExponentDigits, b'0'..=b'9') => { self.exponent_digit(byte); ExponentDigits },
            (HexStart | HexInteger, b'0'..=b'9' | b'a'..=b'f' | b'A'..=b'F') => { self.digit(byte, false); HexInteger },
            (HexStart, b'.') => HexLeadingDot,
            (HexInteger, b'.') => HexDot,
            (HexLeadingDot | HexDot | HexFraction, b'0'..=b'9' | b'a'..=b'f' | b'A'..=b'F') => { self.digit(byte, true); HexFraction },
            (HexInteger | HexDot | HexFraction, b'p' | b'P') => HexExponent,
            (HexExponent, b'+' | b'-') => { self.exponent_negative = byte == b'-'; HexExponentSign },
            (HexExponent | HexExponentSign | HexExponentDigits, b'0'..=b'9') => { self.exponent_digit(byte); HexExponentDigits },
            (Word { word, matched }, byte) if matched < word.len() && byte.to_ascii_lowercase() == word[matched] => Word { word, matched: matched + 1 },
            (Word { word: b"nan", matched: 3 }, b'(') => Payload,
            (Payload, b')') => PayloadEnd,
            (Payload, b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'_') => Payload,
            _ => return Err(leanjson_err::LEANJSON_INVALID_NUMBER),
        };
        Ok(())
    }
    pub(super) fn finish(&self) -> Result<bool, leanjson_err> {
        use NumberPhase::*;
        match self.phase {
            Word { word: b"nan", matched: 3 } | Word { word: b"infinity", matched: 3 | 8 } | PayloadEnd => return Ok(true),
            Zero | Integer | Fraction | ExponentDigits | HexInteger | HexDot | HexFraction | HexExponentDigits => {},
            Dot if self.permissive => {},
            _ => return Err(leanjson_err::LEANJSON_INVALID_NUMBER),
        }
        // The pinned native decoder uses signed-64 saturation for plain
        // decimal integers, so arbitrarily wide integer tokens stay finite.
        if matches!(self.phase, Zero | Integer) { return Ok(false); }
        if self.significant == 0 { return Ok(false); }
        let exponent = if self.exponent_negative { -self.exponent } else { self.exponent };
        if self.hexadecimal {
            let first_bits = 8 - self.digits[0].leading_zeros() as i128;
            let magnitude = exponent + 4 * (self.significant - self.fractional - 1) + first_bits - 1;
            if magnitude != 1023 { return Ok(magnitude > 1023); }
            let mut prefix = 0u64;
            let mut bits = 0;
            for (index, &digit) in self.digits[..self.stored].iter().enumerate() {
                let width = if index == 0 { first_bits as usize } else { 4 };
                for bit in (0..width).rev() {
                    prefix = (prefix << 1) | u64::from((digit >> bit) & 1);
                    bits += 1;
                    if bits == 54 { return Ok(prefix == (1u64 << 54) - 1); }
                }
            }
            return Ok(false); // Missing lower bits are zero, below the midpoint.
        }
        let magnitude = exponent + self.significant - self.fractional - 1;
        if magnitude != 308 { return Ok(magnitude > 308); }
        // A shorter equal prefix has implicit zeroes below the midpoint's
        // remaining nonzero suffix. Extra digits cannot lower an equal prefix.
        Ok(self.decimal_order == std::cmp::Ordering::Greater
            || self.decimal_order == std::cmp::Ordering::Equal && self.significant >= 309)
    }
}

#[derive(Clone, Copy)]
enum StringPhase {
    Plain,
    Escape,
    Hex { unit: u16, digits: u8, high: Option<u16> },
    LowBackslash(u16),
    LowU(u16),
}

pub(super) struct Decoded {
    pub(super) bytes: [u8; 4],
    pub(super) len: usize,
}

impl Decoded {
    fn empty() -> Self { Self { bytes: [0; 4], len: 0 } }
    fn byte(byte: u8) -> Self { Self { bytes: [byte, 0, 0, 0], len: 1 } }
    fn codepoint(value: u32) -> Self {
        let mut bytes = [0; 4];
        // Only validated scalar values enter here, including paired surrogates.
        let len = char::from_u32(value).unwrap().encode_utf8(&mut bytes).len();
        Self { bytes, len }
    }
}

pub(super) struct StringState {
    phase: StringPhase,
    utf8_remaining: u8,
    utf8_low: u8,
    utf8_high: u8,
    raw_bytes: bool,
    needs_escape: bool,
}

impl StringState {
    pub(super) fn new() -> Self {
        Self::with_bytes(false)
    }

    pub(super) fn with_bytes(raw_bytes: bool) -> Self {
        Self { phase: StringPhase::Plain, utf8_remaining: 0, utf8_low: 0x80, utf8_high: 0xBF, raw_bytes, needs_escape: false }
    }

    pub(super) fn plain(&mut self, needs_escape: bool) {
        debug_assert!(self.at_boundary());
        self.needs_escape |= needs_escape;
    }

    pub(super) fn needs_escape(&self) -> bool { self.needs_escape }

    pub(super) fn at_boundary(&self) -> bool {
        matches!(self.phase, StringPhase::Plain) && self.utf8_remaining == 0
    }

    pub(super) fn finish(&self) -> Result<(), leanjson_err> {
        if self.utf8_remaining != 0 { Err(leanjson_err::LEANJSON_INVALID_UTF8) }
        else if !matches!(self.phase, StringPhase::Plain) { Err(leanjson_err::LEANJSON_INVALID_STRING) }
        else { Ok(()) }
    }

    pub(super) fn feed(&mut self, byte: u8) -> Result<Decoded, leanjson_err> {
        let decoded = self.decode(byte)?;
        self.needs_escape |= decoded.bytes[..decoded.len].iter().any(|&byte| matches!(byte, b'/' | 0x7F));
        Ok(decoded)
    }

    fn decode(&mut self, byte: u8) -> Result<Decoded, leanjson_err> {
        use StringPhase::*;
        if self.utf8_remaining != 0 {
            if !(self.utf8_low..=self.utf8_high).contains(&byte) { return Err(leanjson_err::LEANJSON_INVALID_UTF8); }
            self.utf8_remaining -= 1;
            self.utf8_low = 0x80;
            self.utf8_high = 0xBF;
            return Ok(Decoded::byte(byte));
        }
        match self.phase {
            Plain => match byte {
                0..=0x1F | b'"' => return Err(leanjson_err::LEANJSON_INVALID_STRING),
                b'\\' => self.phase = Escape,
                0x20..=0x7F => return Ok(Decoded::byte(byte)),
                0x80..=0xFF if self.raw_bytes => return Ok(Decoded::byte(byte)),
                0xC2..=0xDF => self.utf8_remaining = 1,
                0xE0..=0xEF => {
                    self.utf8_remaining = 2;
                    self.utf8_low = if byte == 0xE0 { 0xA0 } else { 0x80 };
                    self.utf8_high = if byte == 0xED { 0x9F } else { 0xBF };
                },
                0xF0..=0xF4 => {
                    self.utf8_remaining = 3;
                    self.utf8_low = if byte == 0xF0 { 0x90 } else { 0x80 };
                    self.utf8_high = if byte == 0xF4 { 0x8F } else { 0xBF };
                },
                _ => return Err(leanjson_err::LEANJSON_INVALID_UTF8),
            },
            Escape => {
                self.phase = Plain;
                return Ok(match byte {
                    b'"' | b'\\' | b'/' => Decoded::byte(byte),
                    b'b' => Decoded::byte(8), b'f' => Decoded::byte(12),
                    b'n' => Decoded::byte(b'\n'), b'r' => Decoded::byte(b'\r'), b't' => Decoded::byte(b'\t'),
                    b'u' => { self.phase = Hex { unit: 0, digits: 0, high: None }; Decoded::empty() },
                    _ => return Err(leanjson_err::LEANJSON_INVALID_STRING),
                });
            },
            Hex { mut unit, mut digits, high } => {
                let value = match byte {
                    b'0'..=b'9' => byte - b'0', b'a'..=b'f' => byte - b'a' + 10,
                    b'A'..=b'F' => byte - b'A' + 10,
                    _ => return Err(leanjson_err::LEANJSON_INVALID_STRING),
                };
                unit = (unit << 4) | value as u16;
                digits += 1;
                if digits < 4 { self.phase = Hex { unit, digits, high }; }
                else if let Some(high) = high {
                    if !(0xDC00..=0xDFFF).contains(&unit) { return Err(leanjson_err::LEANJSON_INVALID_STRING); }
                    self.phase = Plain;
                    return Ok(Decoded::codepoint(0x10000 + (((high as u32 - 0xD800) << 10) | (unit as u32 - 0xDC00))));
                } else if (0xD800..=0xDBFF).contains(&unit) { self.phase = LowBackslash(unit); }
                else if (0xDC00..=0xDFFF).contains(&unit) { return Err(leanjson_err::LEANJSON_INVALID_STRING); }
                else { self.phase = Plain; return Ok(Decoded::codepoint(unit as u32)); }
            },
            LowBackslash(high) => {
                if byte != b'\\' { return Err(leanjson_err::LEANJSON_INVALID_STRING); }
                self.phase = LowU(high);
            },
            LowU(high) => {
                if byte != b'u' { return Err(leanjson_err::LEANJSON_INVALID_STRING); }
                self.phase = Hex { unit: 0, digits: 0, high: Some(high) };
            },
        }
        if self.utf8_remaining != 0 { Ok(Decoded::byte(byte)) } else { Ok(Decoded::empty()) }
    }
}
