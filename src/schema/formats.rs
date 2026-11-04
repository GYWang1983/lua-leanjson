use chrono::{DateTime, NaiveDate, Timelike, Utc};
use regress::Regex;
use std::cell::RefCell;
use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr};

pub(super) const FORMATS: &[&str] = &[
    "date-time",
    "date",
    "time",
    "duration",
    "email",
    "hostname",
    "ipv4",
    "ipv6",
    "uri",
    "uri-reference",
    "uuid",
    "regex",
    "json-pointer",
    "relative-json-pointer",
];
pub(super) fn pattern(s: &str) -> Result<Regex, String> {
    // regress does not implement Unicode property escapes. Never interpret an
    // unsupported executable construct as a literal expression.
    if s.contains("\\p{") || s.contains("\\P{") || s.contains("[[:") {
        return Err("unsupported regex construct".into());
    }
    Regex::new(s).map_err(|e| format!("invalid pattern: {e}"))
}
thread_local! {
    // Only the fixed patterns in this module are admitted to this cache.
    static FORMAT_PATTERNS: RefCell<HashMap<&'static str, Regex>> = RefCell::new(HashMap::new());
}
fn matches(pattern: &'static str, s: &str) -> bool {
    FORMAT_PATTERNS.with(|patterns| {
        patterns
            .borrow_mut()
            .entry(pattern)
            .or_insert_with(|| Regex::new(pattern).expect("fixed format regex"))
            .find(s)
            .is_some_and(|found| found.range().start == 0 && found.range().end == s.len())
    })
}
fn pointer(s: &str) -> bool {
    if !s.is_empty() && !s.starts_with('/') {
        return false;
    }
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '~' && !matches!(chars.next(), Some('0' | '1')) {
            return false;
        }
    }
    true
}
fn hostname(s: &str) -> bool {
    let s = s.strip_suffix('.').unwrap_or(s);
    !s.is_empty()
        && s.len() <= 253
        && s.split('.').all(|l| {
            !l.is_empty()
                && l.len() <= 63
                && l.as_bytes()[0].is_ascii_alphanumeric()
                && l.as_bytes()[l.len() - 1].is_ascii_alphanumeric()
                && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}
// RFC 3339 Appendix A requires contiguous units: Y-M-D and H-M-S.
// For example Y followed directly by D, or fractional seconds, is invalid.
fn duration(s: &str) -> bool {
    fn components(part: &str, units: &[u8]) -> bool {
        let bytes = part.as_bytes();
        let mut at = 0;
        let mut previous = None;
        while at < bytes.len() {
            let start = at;
            while at < bytes.len() && bytes[at].is_ascii_digit() {
                at += 1;
            }
            if at == start || at == bytes.len() {
                return false;
            }
            let Some(unit) = units.iter().position(|b| *b == bytes[at]) else {
                return false;
            };
            if previous.is_some_and(|last| unit != last + 1) {
                return false;
            }
            previous = Some(unit);
            at += 1;
        }
        previous.is_some()
    }
    let Some(body) = s.strip_prefix('P') else {
        return false;
    };
    if let Some((date, time)) = body.split_once('T') {
        (date.is_empty() || components(date, b"YMD")) && components(time, b"HMS")
    } else {
        components(body, b"YMD") || components(body, b"W")
    }
}
fn date_time(s: &str) -> bool {
    let Ok(value) = DateTime::parse_from_rfc3339(s) else {
        return false;
    };
    // Chrono represents second 60 as second 59 plus >= 1e9 nanoseconds.
    // RFC 3339 permits it only at 23:59 in UTC, including offset spellings.
    if value.nanosecond() >= 1_000_000_000 {
        let utc = value.with_timezone(&Utc);
        utc.hour() == 23 && utc.minute() == 59
    } else {
        true
    }
}
pub(super) fn validate(s: &str, format: &str) -> bool {
    match format {
        "date-time" => {
            s.as_bytes()
                .get(10)
                .is_some_and(|b| matches!(b, b'T' | b't'))
                && date_time(s)
        }
        "date" => {
            matches(r"^\d{4}-\d{2}-\d{2}$", s) && NaiveDate::parse_from_str(s, "%Y-%m-%d").is_ok()
        }
        "time" => date_time(&format!("2000-01-01T{s}")),
        "duration" => duration(s),
        "email" => {
            let Some((local, domain)) = s.rsplit_once('@') else {
                return false;
            };
            !local.is_empty()
                && local.len() <= 64
                && (hostname(domain)
                    || domain
                        .strip_prefix('[')
                        .and_then(|d| d.strip_suffix(']'))
                        .is_some_and(|d| {
                            d.parse::<Ipv4Addr>().is_ok()
                                || d.strip_prefix("IPv6:")
                                    .is_some_and(|d| d.parse::<Ipv6Addr>().is_ok())
                        }))
                && (matches(
                    r#"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$"#,
                    local,
                ) || matches(
                    r#"^"(?:[\x20-\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E])*"$"#,
                    local,
                ))
        }
        "hostname" => hostname(s),
        "ipv4" => s.parse::<Ipv4Addr>().is_ok(),
        "ipv6" => s.parse::<Ipv6Addr>().is_ok(),
        "uri" => fluent_uri::Uri::parse(s).is_ok(),
        "uri-reference" => fluent_uri::UriRef::parse(s).is_ok(),
        "uuid" => matches(
            r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
            s,
        ),
        "regex" => pattern(s).is_ok(),
        "json-pointer" => pointer(s),
        "relative-json-pointer" => {
            let n = s.bytes().take_while(u8::is_ascii_digit).count();
            n > 0 && (n == 1 || !s.starts_with('0')) && (s[n..] == *"#" || pointer(&s[n..]))
        }
        _ => false,
    }
}
