//! Resumable member walks over immutable spans. No public handle refers to an
//! evictable index entry and no walk retains skipped siblings.
use std::path::PathBuf;
use super::{Source, SourceError, Span, SpanMember, SourcePolicy, DETAIL_BAD_WINDOW};
use super::duplicates::{KeyMap, WorkspacePool};
use crate::error::leanjson_type;

pub(crate) enum WalkStep { Member(SpanMember), NeedRead { offset: u64, length: usize }, Done }
#[derive(Clone, PartialEq, Eq)]
pub(crate) enum Lookup { Key(Vec<u8>), Index(u64) }
pub(crate) struct Walker {
    parser: Source, end: u64, limit: usize, window: Vec<u8>, window_base: u64, cursor: usize, requested: bool,
    normalized: Option<KeyMap>, collected: bool, lookup: Option<Lookup>, found: Option<SpanMember>, done: bool,
    replay: Option<Box<Walker>>, current: bool,
}
impl Walker {
    pub(crate) fn new(span: Span, limit: usize, normalize: bool, lookup: Option<Lookup>, directory: PathBuf, workspace: WorkspacePool, policy: SourcePolicy) -> Self {
        let normalized = (normalize && span.kind == leanjson_type::LEANJSON_T_OBJ).then(|| KeyMap::new(directory.clone(), workspace.clone()));
        Self { parser: Source::walker(span.raw_start, limit, normalize, directory, workspace, policy), end: span.raw_end,
            limit, window: Vec::new(), window_base: span.raw_start, cursor: 0, requested: false, normalized, collected: false,
            lookup, found: None, done: false, replay: None, current: true }
    }
    pub(crate) fn linked(span: Span, limit: usize, directory: PathBuf, workspace: WorkspacePool, policy: SourcePolicy) -> Self {
        let mut walker = Self::new(span, limit, false, None, directory.clone(), workspace.clone(), policy);
        walker.normalized = Some(KeyMap::new(directory.clone(), workspace.clone()));
        walker.replay = Some(Box::new(Self::new(span, limit, false, None, directory, workspace, policy)));
        walker
    }
    pub(crate) fn with_structural_index(mut self, index: super::structural::SharedIndex) -> Self {
        self.parser.use_structural_index(index.clone());
        if let Some(replay) = self.replay.take() { self.replay = Some(Box::new(replay.with_structural_index(index))); }
        self
    }
    pub(crate) fn is_current(&self) -> bool { self.current }
    pub(crate) fn resume(span: Span, resume: (u64, u64), limit: usize, normalize: bool, directory: PathBuf, workspace: WorkspacePool, policy: SourcePolicy) -> Self {
        let (offset, ordinal) = resume;
        let mut walker = Self::new(span, limit, normalize, None, directory.clone(), workspace.clone(), policy);
        walker.parser = Source::walker_resume(span, (offset, ordinal), limit, normalize, directory, workspace, policy);
        walker
    }
    pub(crate) fn next(&mut self) -> Result<WalkStep, SourceError> {
        if self.done { return Ok(WalkStep::Done); }
        if self.collected {
            if let Some(replay) = self.replay.as_mut() {
                let step = replay.next()?;
                match &step {
                    WalkStep::Member(member) => self.current = self.normalized.as_mut().unwrap().is_current(member)?,
                    WalkStep::Done => self.done = true,
                    WalkStep::NeedRead { .. } => {},
                }
                return Ok(step);
            }
            if let Some(map) = self.normalized.as_mut() {
                return Ok(match map.next()? { Some(member) => WalkStep::Member(member), None => { self.done = true; WalkStep::Done } });
            }
            self.done = true;
            return Ok(match self.found.take() { Some(member) => WalkStep::Member(member), None => WalkStep::Done });
        }
        loop {
            let member = if let Some(member) = self.parser.skip_indexed_string() {
                let offset = self.parser.offset();
                if offset >= self.window_base && offset <= self.window_base + self.window.len() as u64 {
                    self.cursor = (offset - self.window_base) as usize;
                } else { self.window.clear(); self.cursor = 0; }
                member
            } else if self.cursor < self.window.len() {
                let (consumed, member) = self.parser.feed_member(self.parser.offset(), &self.window[self.cursor..])?;
                self.cursor += consumed;
                member
            } else { None };
            if let Some(member) = member {
                if let Some(lookup) = &self.lookup {
                    let matched = match lookup { Lookup::Key(key) => key == &member.key, Lookup::Index(index) => *index == member.ordinal };
                    if matched {
                        if matches!(lookup, Lookup::Index(_)) { self.done = true; return Ok(WalkStep::Member(member)); }
                        self.found = Some(member);
                    }
                } else if let Some(map) = self.normalized.as_mut() { map.insert(member)?; }
                else { return Ok(WalkStep::Member(member)); }
                continue;
            }
            // The parser may have stopped immediately after a string opener;
            // finish its validated span before considering another I/O request.
            if self.parser.string_jump.is_some() || self.cursor < self.window.len() { continue; }
            if self.parser.offset() == self.end {
                self.parser.finish(self.end)?;
                self.window = Vec::new(); self.collected = true;
                if self.normalized.is_some() || self.lookup.is_some() { return self.next(); }
                self.done = true; return Ok(WalkStep::Done);
            }
            self.requested = true;
            return Ok(WalkStep::NeedRead { offset: self.parser.offset(), length: self.parser.indexed_read_length((self.end - self.parser.offset()).min(self.limit as u64) as usize) });
        }
    }
    pub(crate) fn provide(&mut self, offset: u64, bytes: &[u8]) -> Result<(), SourceError> {
        if self.collected {
            if let Some(replay) = self.replay.as_mut() { return replay.provide(offset, bytes); }
        }
        if !self.requested || offset != self.parser.offset() || bytes.is_empty() || bytes.len() > self.limit
            || offset.checked_add(bytes.len() as u64).is_none_or(|end| end > self.end) {
            return Err(SourceError::argument(DETAIL_BAD_WINDOW, offset));
        }
        self.window.clear(); self.window.extend_from_slice(bytes); self.window_base = offset; self.cursor = 0; self.requested = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::IndexOptions;

    #[test]
    fn retained_string_boundaries_and_walk_requests_remain_u64_after_four_gib() {
        let mut source = Source::new_sparse(0, 65536, IndexOptions { depth: 0, array_limit: 0, budget_bytes: 4096 });
        let whitespace = vec![b' '; 1024 * 1024];
        for index in 0..4096 { source.feed(index * whitespace.len() as u64, &whitespace).unwrap(); }
        let base = 1u64 << 32;
        let mut bytes = br#"{"payload":""#.to_vec();
        bytes.extend(std::iter::repeat_n(b'x', 32768));
        bytes.extend_from_slice(br#"","answer":"\u0041"}"#);
        source.feed(base, &bytes).unwrap(); source.finish(base + bytes.len() as u64).unwrap();
        let node = source.node(0).unwrap().unwrap();
        let span = Span { kind: node.kind, flags: node.flags, raw_start: node.raw_start, raw_end: node.raw_end, child_count: node.child_count };
        let mut walker = Walker::new(span, 65536, false, Some(Lookup::Key(b"answer".to_vec())),
            std::env::temp_dir(), source.workspace(), source.policy()).with_structural_index(source.structural_index());
        let mut read_bytes = 0;
        let mut found = false;
        loop {
            match walker.next().unwrap() {
                WalkStep::NeedRead { offset, length } => {
                    assert!(offset > u32::MAX as u64);
                    read_bytes += length;
                    let start = (offset - base) as usize;
                    walker.provide(offset, &bytes[start..start + length]).unwrap();
                },
                WalkStep::Member(member) => {
                    assert_eq!(member.key, b"answer");
                    let start = (member.value.raw_start - base) as usize;
                    let end = (member.value.raw_end - base) as usize;
                    assert_eq!(&bytes[start..end], br#""\u0041""#);
                    found = true;
                },
                WalkStep::Done => break,
            }
        }
        assert!(found);
        assert!(read_bytes < 64, "string interiors were reread: {read_bytes}");
    }
}
