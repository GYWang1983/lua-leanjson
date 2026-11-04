//! Exact finite decimal arithmetic. Exponents are arbitrary-size integers; a
//! token such as 1e100000000000000000000 does not allocate that many zeroes.
use num_bigint::{BigInt, BigUint, Sign};
use num_traits::{One, ToPrimitive, Zero};
use std::cmp::Ordering;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) struct Decimal {
    negative: bool,
    digits: Vec<u8>,
    exponent: BigInt,
}
impl Decimal {
    pub fn parse(s: &str) -> Option<Self> {
        let (negative, s) = match s.strip_prefix('-') {
            Some(s) => (true, s),
            None => (false, s),
        };
        let mut parts = s.split(['e', 'E']);
        let mantissa = parts.next()?;
        let mut exponent = match parts.next() {
            Some(s) => s.parse().ok()?,
            None => BigInt::zero(),
        };
        if parts.next().is_some() {
            return None;
        }
        let mut digits = Vec::new();
        let mut fractional = false;
        for b in mantissa.bytes() {
            if b == b'.' && !fractional {
                fractional = true;
            } else if b.is_ascii_digit() {
                digits.push(b);
                if fractional {
                    exponent -= 1;
                }
            } else {
                return None;
            }
        }
        if digits.is_empty() {
            return None;
        }
        let start = digits
            .iter()
            .position(|b| *b != b'0')
            .unwrap_or(digits.len());
        digits.drain(..start);
        if digits.is_empty() {
            return Some(Self {
                negative: false,
                digits: vec![b'0'],
                exponent: BigInt::zero(),
            });
        }
        while digits.last() == Some(&b'0') {
            digits.pop();
            exponent += 1;
        }
        Some(Self {
            negative,
            digits,
            exponent,
        })
    }
    pub fn as_u64(&self) -> Option<u64> {
        if self.negative || !self.integer() {
            return None;
        }
        let exponent = self.exponent.to_u32()?;
        if exponent > 19 {
            return None;
        }
        let coefficient = std::str::from_utf8(&self.digits)
            .ok()?
            .parse::<u64>()
            .ok()?;
        coefficient.checked_mul(10u64.checked_pow(exponent)?)
    }
    pub fn integer(&self) -> bool {
        self.exponent.sign() != Sign::Minus
    }
    pub fn positive(&self) -> bool {
        !self.negative && self.digits != b"0"
    }
    pub fn cmp(&self, other: &Self) -> Ordering {
        if self == other {
            return Ordering::Equal;
        }
        if self.negative != other.negative {
            return if self.negative {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
        let order = if self.digits == b"0" {
            Ordering::Less
        } else if other.digits == b"0" {
            Ordering::Greater
        } else {
            let a = &self.exponent + BigInt::from(self.digits.len());
            let b = &other.exponent + BigInt::from(other.digits.len());
            a.cmp(&b).then_with(|| {
                (0..self.digits.len().max(other.digits.len()))
                    .map(|i| {
                        self.digits
                            .get(i)
                            .copied()
                            .unwrap_or(b'0')
                            .cmp(&other.digits.get(i).copied().unwrap_or(b'0'))
                    })
                    .find(|v| *v != Ordering::Equal)
                    .unwrap_or(Ordering::Equal)
            })
        };
        if self.negative {
            order.reverse()
        } else {
            order
        }
    }
    pub fn multiple_of(&self, other: &Self) -> bool {
        if self.digits == b"0" {
            return true;
        }
        let shift = &self.exponent - &other.exponent;
        if shift.sign() == Sign::Minus {
            return false;
        }
        let divisor = BigUint::parse_bytes(&other.digits, 10).expect("decimal digits");
        if divisor.is_one() {
            return true;
        }
        let coefficient = BigUint::parse_bytes(&self.digits, 10).expect("decimal digits");
        let power = BigUint::from(10u8).modpow(&shift.to_biguint().expect("nonnegative"), &divisor);
        (coefficient * power % divisor).is_zero()
    }
    pub fn retained_bytes(&self) -> usize {
        self.digits.capacity() + self.exponent.bits() as usize / 8
    }
}
