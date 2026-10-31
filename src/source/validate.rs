//! Fixed-size token state shared by incremental validation and string output.
use crate::error::qjson_err;

#[derive(Clone, Copy)]
enum NumberPhase { Start, Minus, Zero, Integer, Dot, Fraction, Exponent, Sign, ExponentDigits }

pub(super) struct NumberState(NumberPhase);

impl NumberState {
    pub(super) fn new() -> Self { Self(NumberPhase::Start) }

    pub(super) fn feed(&mut self, byte: u8) -> Result<(), qjson_err> {
        use NumberPhase::*;
        self.0 = match (self.0, byte) {
            (Start, b'-') => Minus,
            (Start | Minus, b'0') => Zero,
            (Start | Minus, b'1'..=b'9') | (Integer, b'0'..=b'9') => Integer,
            (Zero | Integer, b'.') => Dot,
            (Dot | Fraction, b'0'..=b'9') => Fraction,
            (Zero | Integer | Fraction, b'e' | b'E') => Exponent,
            (Exponent, b'+' | b'-') => Sign,
            (Exponent | Sign | ExponentDigits, b'0'..=b'9') => ExponentDigits,
            _ => return Err(qjson_err::QJSON_INVALID_NUMBER),
        };
        Ok(())
    }

    pub(super) fn finish(&self) -> Result<(), qjson_err> {
        use NumberPhase::*;
        if matches!(self.0, Zero | Integer | Fraction | ExponentDigits) { Ok(()) }
        else { Err(qjson_err::QJSON_INVALID_NUMBER) }
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
}

impl StringState {
    pub(super) fn new() -> Self {
        Self { phase: StringPhase::Plain, utf8_remaining: 0, utf8_low: 0x80, utf8_high: 0xBF }
    }

    pub(super) fn at_boundary(&self) -> bool {
        matches!(self.phase, StringPhase::Plain) && self.utf8_remaining == 0
    }

    pub(super) fn finish(&self) -> Result<(), qjson_err> {
        if self.utf8_remaining != 0 { Err(qjson_err::QJSON_INVALID_UTF8) }
        else if !matches!(self.phase, StringPhase::Plain) { Err(qjson_err::QJSON_INVALID_STRING) }
        else { Ok(()) }
    }

    pub(super) fn feed(&mut self, byte: u8) -> Result<Decoded, qjson_err> {
        use StringPhase::*;
        if self.utf8_remaining != 0 {
            if !(self.utf8_low..=self.utf8_high).contains(&byte) { return Err(qjson_err::QJSON_INVALID_UTF8); }
            self.utf8_remaining -= 1;
            self.utf8_low = 0x80;
            self.utf8_high = 0xBF;
            return Ok(Decoded::byte(byte));
        }
        match self.phase {
            Plain => match byte {
                0..=0x1F | b'"' => return Err(qjson_err::QJSON_INVALID_STRING),
                b'\\' => self.phase = Escape,
                0x20..=0x7F => return Ok(Decoded::byte(byte)),
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
                _ => return Err(qjson_err::QJSON_INVALID_UTF8),
            },
            Escape => {
                self.phase = Plain;
                return Ok(match byte {
                    b'"' | b'\\' | b'/' => Decoded::byte(byte),
                    b'b' => Decoded::byte(8), b'f' => Decoded::byte(12),
                    b'n' => Decoded::byte(b'\n'), b'r' => Decoded::byte(b'\r'), b't' => Decoded::byte(b'\t'),
                    b'u' => { self.phase = Hex { unit: 0, digits: 0, high: None }; Decoded::empty() },
                    _ => return Err(qjson_err::QJSON_INVALID_STRING),
                });
            },
            Hex { mut unit, mut digits, high } => {
                let value = match byte {
                    b'0'..=b'9' => byte - b'0', b'a'..=b'f' => byte - b'a' + 10,
                    b'A'..=b'F' => byte - b'A' + 10,
                    _ => return Err(qjson_err::QJSON_INVALID_STRING),
                };
                unit = (unit << 4) | value as u16;
                digits += 1;
                if digits < 4 { self.phase = Hex { unit, digits, high }; }
                else if let Some(high) = high {
                    if !(0xDC00..=0xDFFF).contains(&unit) { return Err(qjson_err::QJSON_INVALID_STRING); }
                    self.phase = Plain;
                    return Ok(Decoded::codepoint(0x10000 + (((high as u32 - 0xD800) << 10) | (unit as u32 - 0xDC00))));
                } else if (0xD800..=0xDBFF).contains(&unit) { self.phase = LowBackslash(unit); }
                else if (0xDC00..=0xDFFF).contains(&unit) { return Err(qjson_err::QJSON_INVALID_STRING); }
                else { self.phase = Plain; return Ok(Decoded::codepoint(unit as u32)); }
            },
            LowBackslash(high) => {
                if byte != b'\\' { return Err(qjson_err::QJSON_INVALID_STRING); }
                self.phase = LowU(high);
            },
            LowU(high) => {
                if byte != b'u' { return Err(qjson_err::QJSON_INVALID_STRING); }
                self.phase = Hex { unit: 0, digits: 0, high: Some(high) };
            },
        }
        if self.utf8_remaining != 0 { Ok(Decoded::byte(byte)) } else { Ok(Decoded::empty()) }
    }
}
