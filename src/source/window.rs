use crate::error::{leanjson_err, leanjson_type};
use super::{Node, SourceError, SourcePolicy, DETAIL_BAD_WINDOW};
use super::validate::StringState;

#[derive(Debug)]
pub enum ReadStep<'a> {
    Ready(&'a [u8]),
    NeedRead { offset: u64, length: usize },
    Done,
}

/// One resumable operation. Only a bounded owned window/output and a four-byte
/// decoded-codepoint remainder survive calls; no caller pointer is retained.
pub struct SourceReader {
    position: u64,
    end: u64,
    token_start: u64,
    limit: usize,
    string: Option<StringState>,
    window: Vec<u8>,
    window_index: usize,
    output: Vec<u8>,
    pending: [u8; 4],
    pending_start: usize,
    pending_end: usize,
    requested: bool,
    failure: Option<SourceError>,
    fast_strings: bool,
}

impl SourceReader {
    pub fn new(node: &Node, scalar: bool, window_size: usize) -> Result<Self, SourceError> {
        Self::with_policy(node, scalar, window_size, SourcePolicy::default())
    }
    pub(crate) fn with_policy(node: &Node, scalar: bool, window_size: usize, policy: SourcePolicy) -> Result<Self, SourceError> {
        if scalar && matches!(node.kind, leanjson_type::LEANJSON_T_ARR | leanjson_type::LEANJSON_T_OBJ) {
            return Err(SourceError::json(leanjson_err::LEANJSON_TYPE_MISMATCH, node.raw_start));
        }
        let string = scalar && node.kind == leanjson_type::LEANJSON_T_STR;
        let limit = if window_size == 0 { 65536 } else { window_size };
        Ok(Self {
            position: node.raw_start + u64::from(string), end: node.raw_end - u64::from(string),
            token_start: node.raw_start, limit,
            string: if string { Some(StringState::with_bytes(policy.raw_bytes)) } else { None },
            window: Vec::new(), window_index: 0, output: Vec::new(),
            pending: [0; 4], pending_start: 0, pending_end: 0, requested: false, failure: None, fast_strings: policy.fast_strings,
        })
    }

    pub fn step(&mut self) -> Result<ReadStep<'_>, SourceError> {
        if let Some(error) = self.failure { return Err(error); }
        self.output.clear();
        while self.output.len() < self.limit {
            if self.pending_start < self.pending_end {
                let count = (self.pending_end - self.pending_start).min(self.limit - self.output.len());
                self.output.extend_from_slice(&self.pending[self.pending_start..self.pending_start + count]);
                self.pending_start += count;
                continue;
            }
            if self.window_index == self.window.len() { break; }
            if self.fast_strings {
                if let Some(state) = self.string.as_mut() {
                    let output = &mut self.output;
                    let pending = &mut self.pending;
                    let pending_end = &mut self.pending_end;
                    self.pending_start = 0;
                    *pending_end = 0;
                    let run = state.scan_chunk(&self.window[self.window_index..], false,
                        self.limit-output.len(), true, |decoded| {
                            let count = decoded.len().min(self.limit-output.len());
                            output.extend_from_slice(&decoded[..count]);
                            if count != decoded.len() {
                                let rest = &decoded[count..];
                                debug_assert!(rest.len() <= 3);
                                pending[..rest.len()].copy_from_slice(rest);
                                *pending_end = rest.len();
                            }
                        });
                    match run {
                        Ok(run) => { self.window_index += run.consumed; self.position += run.consumed as u64; },
                        Err(error) => {
                            self.position += error.index as u64+1;
                            let error = SourceError::json(error.code, self.token_start);
                            self.failure = Some(error); self.output.clear(); return Err(error);
                        },
                    }
                    continue;
                }
            }
            let byte = self.window[self.window_index];
            self.window_index += 1;
            self.position += 1;
            if let Some(state) = self.string.as_mut() {
                match state.feed(byte) {
                    Ok(decoded) => {
                        self.pending = decoded.bytes;
                        self.pending_start = 0;
                        self.pending_end = decoded.len;
                    },
                    Err(code) => {
                        let error = SourceError::json(code, self.token_start);
                        self.failure = Some(error);
                        self.output.clear();
                        return Err(error);
                    },
                }
            } else { self.output.push(byte); }
        }
        if !self.output.is_empty() { return Ok(ReadStep::Ready(&self.output)); }
        if self.position == self.end {
            if let Some(state) = self.string.as_ref() {
                if let Err(code) = state.finish() {
                    let error = SourceError::json(code, self.token_start);
                    self.failure = Some(error);
                    return Err(error);
                }
            }
            return Ok(ReadStep::Done);
        }
        self.requested = true;
        Ok(ReadStep::NeedRead { offset: self.position, length: (self.end - self.position).min(self.limit as u64) as usize })
    }

    pub fn provide_window(&mut self, base: u64, bytes: &[u8]) -> Result<(), SourceError> {
        if let Some(error) = self.failure { return Err(error); }
        self.output.clear();
        if !self.requested || base != self.position || bytes.is_empty() || bytes.len() > self.limit
            || base.checked_add(bytes.len() as u64).is_none_or(|end| end > self.end)
        {
            let error = SourceError::argument(DETAIL_BAD_WINDOW, base);
            self.failure = Some(error);
            return Err(error);
        }
        self.window.clear();
        self.window.extend_from_slice(bytes);
        self.window_index = 0;
        self.requested = false;
        Ok(())
    }
}

#[cfg(test)]
mod string_loop_tests {
    use super::*;
    fn read(raw: &[u8], window: usize, fast: bool, raw_bytes: bool) -> Result<Vec<u8>, SourceError> {
        let node = Node { kind: leanjson_type::LEANJSON_T_STR, raw_start: 0, raw_end: raw.len() as u64,
            complete: true, members: Vec::new(), child_count: 0, flags: 1 };
        let mut reader = SourceReader::with_policy(&node, true, window,
            SourcePolicy { fast_strings: fast, raw_bytes, ..Default::default() }).unwrap();
        let mut output = Vec::new();
        loop { match reader.step()? {
            ReadStep::Ready(bytes) => { assert!(!bytes.is_empty() && bytes.len() <= window); output.extend_from_slice(bytes); },
            ReadStep::NeedRead { offset, length } => {
                assert!(length <= window);
                let first = offset as usize;
                reader.provide_window(offset, &raw[first..first+length])?;
            },
            ReadStep::Done => return Ok(output),
        } }
    }
    #[test]
    fn decoded_strings_keep_bounded_output_and_codepoint_remainders() {
        for raw in [br#""a\n\u4e2d\ud83d\ude00/\u007f\"\\end""#.as_slice(), b"\"\xe4\xb8\xad\xf0\x9f\x98\x80\"", b"\"\xff\x80\""] {
            for window in [1,2,3,4,5,7,11,17,65536] {
                for raw_bytes in [false,true] {
                    assert_eq!(read(raw, window, true, raw_bytes), read(raw, window, false, raw_bytes), "{raw:?} window={window}");
                }
            }
        }
    }
    #[test]
    fn malformed_strings_report_the_same_reader_error() {
        for raw in [br#""\ud800\u0041""#.as_slice(), br#""\u12zz""#, br#""\z""#, b"\"\xe0\x80\x80\"", b"\"\xc2\""] {
            for window in [1,2,3,7,65536] {
                let a = read(raw, window, true, false).unwrap_err();
                let b = read(raw, window, false, false).unwrap_err();
                assert_eq!(a,b,"{raw:?} window={window}");
            }
        }
    }
}
