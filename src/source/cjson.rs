//! CJSON-derived lexical fast path; shared Rust validators remain authoritative.
#[cfg(not(miri))]
extern "C" {
    fn leanjson_cjson_scan_plain(bytes: *const u8, len: usize, raw_bytes: u32, needs_escape: *mut u32) -> usize;
}

pub(super) fn plain(bytes: &[u8], raw_bytes: bool) -> (usize, bool) {
    #[cfg(not(miri))]
    {
        let mut escape = 0;
        // The C loop is length-bounded, writes one integer, and retains nothing.
        let len = unsafe { leanjson_cjson_scan_plain(bytes.as_ptr(), bytes.len(), u32::from(raw_bytes), &mut escape) };
        (len, escape != 0)
    }
    #[cfg(miri)]
    {
        let len = bytes.iter().position(|&b| b == b'"' || b == b'\\' || b < 0x20 || !raw_bytes && b >= 0x80).unwrap_or(bytes.len());
        (len, bytes[..len].iter().any(|&b| b == b'/' || b == 0x7f))
    }
}
