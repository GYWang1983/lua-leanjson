use crate::error::{leanjson_err, leanjson_type};
use super::{Node, SourceError, DETAIL_BAD_WINDOW};
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
}

impl SourceReader {
    pub fn new(node: &Node, scalar: bool, window_size: usize) -> Result<Self, SourceError> {
        if scalar && matches!(node.kind, leanjson_type::LEANJSON_T_ARR | leanjson_type::LEANJSON_T_OBJ) {
            return Err(SourceError::json(leanjson_err::LEANJSON_TYPE_MISMATCH, node.raw_start));
        }
        let string = scalar && node.kind == leanjson_type::LEANJSON_T_STR;
        let limit = if window_size == 0 { 65536 } else { window_size };
        Ok(Self {
            position: node.raw_start + u64::from(string), end: node.raw_end - u64::from(string),
            token_start: node.raw_start, limit,
            string: if string { Some(StringState::new()) } else { None },
            window: Vec::new(), window_index: 0, output: Vec::new(),
            pending: [0; 4], pending_start: 0, pending_end: 0, requested: false, failure: None,
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
