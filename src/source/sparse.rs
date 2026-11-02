//! Resumable member walks over immutable spans. No public handle refers to an
//! evictable index entry and no walk retains skipped siblings.
use std::path::PathBuf;
use super::{Source, SourceError, Span, SpanMember, DETAIL_BAD_WINDOW};
use super::duplicates::{KeyMap, WorkspacePool};
use crate::error::leanjson_type;

pub(crate) enum WalkStep { Member(SpanMember), NeedRead { offset: u64, length: usize }, Done }
#[derive(Clone)]
pub(crate) enum Lookup { Key(Vec<u8>), Index(u64) }
pub(crate) struct Walker {
    parser: Source, end: u64, limit: usize, window: Vec<u8>, cursor: usize, requested: bool,
    normalized: Option<KeyMap>, collected: bool, lookup: Option<Lookup>, found: Option<SpanMember>, done: bool,
}
impl Walker {
    pub(crate) fn new(span: Span, limit: usize, normalize: bool, lookup: Option<Lookup>, directory: PathBuf, workspace: WorkspacePool) -> Self {
        let normalized = (normalize && span.kind == leanjson_type::LEANJSON_T_OBJ).then(|| KeyMap::new(directory.clone(), workspace.clone()));
        Self { parser: Source::walker(span.raw_start, limit, normalize, directory, workspace), end: span.raw_end,
            limit, window: Vec::new(), cursor: 0, requested: false, normalized, collected: false,
            lookup, found: None, done: false }
    }
    pub(crate) fn resume(span: Span, offset: u64, ordinal: u64, limit: usize, normalize: bool, directory: PathBuf, workspace: WorkspacePool) -> Self {
        let mut walker = Self::new(span, limit, normalize, None, directory.clone(), workspace.clone());
        walker.parser = Source::walker_resume(span, offset, ordinal, limit, normalize, directory, workspace);
        walker
    }
    pub(crate) fn next(&mut self) -> Result<WalkStep, SourceError> {
        if self.done { return Ok(WalkStep::Done); }
        if self.collected {
            if let Some(map) = self.normalized.as_mut() {
                return Ok(match map.next()? { Some(member) => WalkStep::Member(member), None => { self.done = true; WalkStep::Done } });
            }
            self.done = true;
            return Ok(match self.found.take() { Some(member) => WalkStep::Member(member), None => WalkStep::Done });
        }
        loop {
            if self.cursor < self.window.len() {
                let (consumed, member) = self.parser.feed_member(self.parser.offset(), &self.window[self.cursor..])?;
                self.cursor += consumed;
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
            }
            if self.parser.offset() == self.end {
                self.parser.finish(self.end)?;
                self.window = Vec::new(); self.collected = true;
                if self.normalized.is_some() || self.lookup.is_some() { return self.next(); }
                self.done = true; return Ok(WalkStep::Done);
            }
            self.requested = true;
            return Ok(WalkStep::NeedRead { offset: self.parser.offset(), length: (self.end - self.parser.offset()).min(self.limit as u64) as usize });
        }
    }
    pub(crate) fn provide(&mut self, offset: u64, bytes: &[u8]) -> Result<(), SourceError> {
        if !self.requested || offset != self.parser.offset() || bytes.is_empty() || bytes.len() > self.limit
            || offset.checked_add(bytes.len() as u64).is_none_or(|end| end > self.end) {
            return Err(SourceError::argument(DETAIL_BAD_WINDOW, offset));
        }
        self.window.clear(); self.window.extend_from_slice(bytes); self.cursor = 0; self.requested = false;
        Ok(())
    }
}
