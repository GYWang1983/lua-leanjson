//! Additive v2 sparse ABI. v1 layouts and functions remain unchanged.
use super::*;
use crate::source::{IndexOptions, Span, SpanMember};
use crate::source::sparse::{Walker, WalkStep, Lookup};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct leanjson_source_v2_options {
    pub api_version: u32, pub mode: u32, pub max_depth: u32, pub window_size: u32,
    pub index_depth: u32, pub index_array_limit: u32, pub index_budget_bytes: u32, pub reserved: u32,
    pub spill_directory: *const u8, pub spill_directory_len: usize,
}
impl Default for leanjson_source_v2_options {
    fn default() -> Self { Self { api_version: 2, mode: 0, max_depth: 0, window_size: 65536,
        index_depth: 3, index_array_limit: 3, index_budget_bytes: 1048576, reserved: 0,
        spill_directory: ptr::null(), spill_directory_len: 0 } }
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v2_node {
    pub source: *const leanjson_source_v1, pub raw_start: u64, pub raw_end: u64,
    pub child_count: u64, pub kind: u32, pub flags: u32,
}
impl leanjson_source_v2_node {
    fn from_span(source: *const leanjson_source_v1, span: Span) -> Self {
        Self { source, raw_start: span.raw_start, raw_end: span.raw_end, child_count: span.child_count, kind: span.kind as u32, flags: span.flags }
    }
    unsafe fn span(self) -> Result<Span, SourceError> {
        let handle = source(self.source)?;
        let source = handle.inner.borrow();
        if !source.ready()? || self.raw_start >= self.raw_end || self.raw_end > source.offset() { return Err(invalid_arg()); }
        let kind = match self.kind { 0 => leanjson_type::LEANJSON_T_NULL, 1 => leanjson_type::LEANJSON_T_BOOL,
            2 => leanjson_type::LEANJSON_T_NUM, 3 => leanjson_type::LEANJSON_T_STR,
            4 => leanjson_type::LEANJSON_T_ARR, 5 => leanjson_type::LEANJSON_T_OBJ, _ => return Err(invalid_arg()) };
        Ok(Span { kind, flags: self.flags, raw_start: self.raw_start, raw_end: self.raw_end, child_count: self.child_count })
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct leanjson_source_v2_member {
    pub ordinal: u64, pub key_start: u64, pub key_end: u64,
    pub key: *const u8, pub key_len: usize, pub value: leanjson_source_v2_node,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v2_stats {
    pub budget_bytes: u64, pub index_bytes: u64, pub indexed_nodes: u64, pub indexed_depth: u64,
    pub index_depth: u64, pub index_array_limit: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v2_workspace_stats {
    pub spill_file_bytes: u64, pub spill_live_regions: u64, pub spill_free_regions: u64,
}
enum CacheWalk { Prefix { ordinal: u64, offset: u64 }, Index(u64), Object { remaining: usize, hash: u64 }, Streaming, Finished }
pub struct leanjson_source_v2_iter {
    source: Rc<leanjson_source_v1>, span: Span, normalize: bool, lookup: Option<Lookup>,
    cached: CacheWalk, walker: Option<Walker>, pending: Option<SpanMember>, key_reader: Option<SourceReader>,
    key: Vec<u8>, failure: Option<SourceError>,
}

/// Create a capacity-bounded source. Feed/finish/abort/retain/release use v1.
/// # Safety
/// Options and output pointers must be valid; optional directory bytes readable.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_new(opts: *const leanjson_source_v2_options, out: *mut leanjson_source_v1_result) -> *mut leanjson_source_v1 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let opts = if opts.is_null() { leanjson_source_v2_options::default() } else { *opts };
        if opts.api_version != 2 || opts.mode != 0 || opts.reserved != 0 { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
        let directory = if opts.spill_directory_len == 0 { std::env::temp_dir() } else {
            let bytes = input(opts.spill_directory, opts.spill_directory_len)?;
            if bytes.contains(&0) { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
            #[cfg(unix)] { use std::os::unix::ffi::OsStrExt; std::path::PathBuf::from(std::ffi::OsStr::from_bytes(bytes)) }
            #[cfg(not(unix))] { std::path::PathBuf::from(std::str::from_utf8(bytes).map_err(|_| invalid_arg())?) }
        };
        let indexes = IndexOptions { depth: opts.index_depth, array_limit: opts.index_array_limit, budget_bytes: opts.index_budget_bytes as usize };
        Ok(Rc::into_raw(Rc::new(leanjson_source_v1 { inner: RefCell::new(Source::new_sparse(opts.max_depth, opts.window_size as usize, indexes)), spill_dir: directory })) as *mut leanjson_source_v1)
    }));
    match result {
        Ok(Ok(handle)) => { write_result(out, leanjson_source_v1_result::pending(0)); handle },
        Ok(Err(error)) => { write_result(out, leanjson_source_v1_result::error(error)); ptr::null_mut() },
        Err(_) => { write_result(out, oom()); ptr::null_mut() },
    }
}
/// Return the immutable root span after full validation and EOF.
/// # Safety
/// Handle and outputs obey the v1 source contract; node borrows the source.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_root(handle: *const leanjson_source_v1, node_out: *mut leanjson_source_v2_node, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if node_out.is_null() { return Err(invalid_arg()); }
        let source = source(handle)?.inner.borrow();
        match source.node(0)? {
            None => Ok(leanjson_source_v1_result::pending(source.offset())),
            Some(node) => { *node_out = leanjson_source_v2_node { source: handle, raw_start: node.raw_start, raw_end: node.raw_end,
                child_count: node.child_count, kind: node.kind as u32, flags: node.flags }; Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY)) },
        }
    })
}
/// Capacity-accounted rebuildable indexes only; excludes input, validation
/// stack, active I/O/duplicate workspace, mutations, and caller-retained values.
/// # Safety
/// Handle/output pointers obey the v1 source contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_get_stats(handle: *const leanjson_source_v1, stats: *mut leanjson_source_v2_stats, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if stats.is_null() { return Err(invalid_arg()); }
        let source = source(handle)?.inner.borrow(); source.ready()?;
        let options = source.index_options().ok_or_else(invalid_arg)?;
        *stats = leanjson_source_v2_stats { budget_bytes: options.budget_bytes as u64,
            index_bytes: source.index_bytes() as u64, indexed_nodes: source.indexed_nodes() as u64,
            indexed_depth: source.indexed_depth() as u64, index_depth: options.depth as u64, index_array_limit: options.array_limit as u64 };
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}
/// Report active shared spill file length and current allocated/free regions.
/// Free intervals are coalesced, reused, and trailing free bytes are truncated.
/// No active spill map returns all zeros; this is disk, not native heap or RSS.
/// # Safety
/// Handle and output pointers obey the v1 source contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_get_workspace_stats(handle: *const leanjson_source_v1, stats: *mut leanjson_source_v2_workspace_stats, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if stats.is_null() { return Err(invalid_arg()); }
        let source = source(handle)?.inner.borrow(); source.ready()?;
        let (spill_file_bytes, spill_live_regions, spill_free_regions) = source.workspace().stats()?;
        *stats = leanjson_source_v2_workspace_stats { spill_file_bytes, spill_live_regions, spill_free_regions };
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}
/// Discard all rebuildable indexes. Immutable span handles remain valid.
/// # Safety
/// Handle and result obey the v1 source contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_clear_indexes(handle: *const leanjson_source_v1, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || { source(handle)?.inner.borrow_mut().clear_indexes()?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY)) })
}
unsafe fn iter_begin(node: leanjson_source_v2_node, normalize: u32, lookup: Option<Lookup>, iter_out: *mut *mut leanjson_source_v2_iter) -> Result<leanjson_source_v1_result, SourceError> {
    if iter_out.is_null() || normalize > 1 { return Err(invalid_arg()); }
    *iter_out = ptr::null_mut(); let span = node.span()?;
    if !matches!(span.kind, leanjson_type::LEANJSON_T_ARR | leanjson_type::LEANJSON_T_OBJ) {
        return Err(SourceError::json(leanjson_err::LEANJSON_TYPE_MISMATCH, span.raw_start));
    }
    let handle = source(node.source)?;
    let cached = match &lookup {
        Some(Lookup::Index(index)) if *index >= span.child_count => CacheWalk::Finished,
        Some(Lookup::Index(index)) => CacheWalk::Index(*index),
        Some(Lookup::Key(key)) => match handle.inner.borrow().cached_count(span.raw_start) {
            Some((count, total)) if count as u64 == total => {
                let mut hash = 0xcbf29ce484222325u64;
                for byte in key { hash ^= *byte as u64; hash = hash.wrapping_mul(0x100000001b3); }
                CacheWalk::Object { remaining: count, hash }
            },
            _ => CacheWalk::Streaming,
        },
        None if normalize == 1 && span.kind == leanjson_type::LEANJSON_T_OBJ => CacheWalk::Streaming,
        None => CacheWalk::Prefix { ordinal: 0, offset: span.raw_start },
    };
    *iter_out = Box::into_raw(Box::new(leanjson_source_v2_iter { source: clone_source(node.source), span,
        normalize: normalize == 1, lookup, cached, walker: None, pending: None, key_reader: None,
        key: Vec::new(), failure: None }));
    Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
}
/// Start lexical (normalize=0) or first-slot/last-value normalized iteration.
/// # Safety
/// Span source must be live, outputs writable. Iterator independently retains source.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_iter_begin(node: leanjson_source_v2_node, normalize: u32, iter_out: *mut *mut leanjson_source_v2_iter, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || iter_begin(node, normalize, None, iter_out))
}
/// Start one targeted lookup: objects compare decoded key bytes, arrays use
/// zero-based index. A matching object occurrence replaces the whole prior value.
/// # Safety
/// Key bytes readable, node/source live, outputs writable.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_lookup_begin(node: leanjson_source_v2_node, key: *const u8, key_len: usize, index: u64, iter_out: *mut *mut leanjson_source_v2_iter, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        let lookup = if node.kind == 5 { Lookup::Key(input(key, key_len)?.to_vec()) } else { Lookup::Index(index) };
        iter_begin(node, 0, Some(lookup), iter_out)
    })
}
fn output_member(iter: &mut leanjson_source_v2_iter, member: SpanMember) -> leanjson_source_v2_member {
    iter.key = member.key;
    leanjson_source_v2_member { ordinal: member.ordinal, key_start: member.key_start, key_end: member.key_end,
        key: iter.key.as_ptr(), key_len: iter.key.len(), value: leanjson_source_v2_node::from_span(Rc::as_ptr(&iter.source), member.value) }
}
impl leanjson_source_v2_iter {
    fn cached_entry(&self, ordinal: usize) -> Option<(crate::source::Member, Span)> {
        self.source.inner.borrow().cached_member(self.span.raw_start, ordinal)
    }
    fn prepare_key(&mut self, member: crate::source::Member, span: Span, ordinal: u64) -> Result<(), SourceError> {
        self.pending = Some(SpanMember { ordinal, key_start: member.key_start, key_end: member.key_end, key: Vec::new(), value: span });
        self.key.clear();
        let node = Span { kind: leanjson_type::LEANJSON_T_STR, flags: 1, raw_start: member.key_start, raw_end: member.key_end, child_count: 0 }.node();
        self.key_reader = Some(SourceReader::new(&node, true, self.source.inner.borrow().window_size())?);
        Ok(())
    }
    fn next(&mut self) -> Result<WalkStep, SourceError> {
        if let Some(error) = self.failure { return Err(error); }
        loop {
            if let Some(reader) = self.key_reader.as_mut() {
                match reader.step()? {
                    ReadStep::NeedRead { offset, length } => return Ok(WalkStep::NeedRead { offset, length }),
                    ReadStep::Ready(bytes) => { self.key.extend_from_slice(bytes); continue; },
                    ReadStep::Done => {},
                }
                self.key_reader = None;
                let mut member = self.pending.take().unwrap();
                member.key = std::mem::take(&mut self.key);
                if let Some(Lookup::Key(key)) = &self.lookup {
                    if &member.key != key { continue; }
                    self.cached = CacheWalk::Finished;
                }
                return Ok(WalkStep::Member(member));
            }
            match self.cached {
                CacheWalk::Finished => return Ok(WalkStep::Done),
                CacheWalk::Streaming => {
                    if self.walker.is_none() {
                        self.walker = Some(Walker::new(self.span, self.source.inner.borrow().window_size(), self.normalize,
                            self.lookup.clone(), self.source.spill_dir.clone(), self.source.inner.borrow().workspace()));
                    }
                    return self.walker.as_mut().unwrap().next();
                },
                CacheWalk::Index(index) => {
                    if let Some((member, value)) = usize::try_from(index).ok().and_then(|index| self.cached_entry(index)) {
                        self.cached = CacheWalk::Finished;
                        return Ok(WalkStep::Member(SpanMember { ordinal: index, key_start: member.key_start, key_end: member.key_end, key: Vec::new(), value }));
                    }
                    self.cached = CacheWalk::Streaming;
                },
                CacheWalk::Prefix { ordinal, offset } => {
                    if ordinal == self.span.child_count { self.cached = CacheWalk::Finished; continue; }
                    if let Some((member, value)) = usize::try_from(ordinal).ok().and_then(|index| self.cached_entry(index)) {
                        self.cached = CacheWalk::Prefix { ordinal: ordinal + 1, offset: value.raw_end };
                        if self.span.kind == leanjson_type::LEANJSON_T_OBJ { self.prepare_key(member, value, ordinal)?; }
                        else { return Ok(WalkStep::Member(SpanMember { ordinal, key_start: 0, key_end: 0, key: Vec::new(), value })); }
                    } else {
                        self.walker = Some(Walker::resume(self.span, offset, ordinal, self.source.inner.borrow().window_size(),
                            self.normalize, self.source.spill_dir.clone(), self.source.inner.borrow().workspace()));
                        self.cached = CacheWalk::Streaming;
                    }
                },
                CacheWalk::Object { remaining: 0, .. } => { self.cached = CacheWalk::Finished; },
                CacheWalk::Object { remaining, hash } => {
                    self.cached = CacheWalk::Object { remaining: remaining - 1, hash };
                    if let Some((member, value)) = self.cached_entry(remaining - 1) {
                        if member.key_hash == hash { self.prepare_key(member, value, (remaining - 1) as u64)?; }
                    } else { self.cached = CacheWalk::Streaming; }
                },
            }
        }
    }
    fn provide(&mut self, base: u64, bytes: &[u8]) -> Result<(), SourceError> {
        if let Some(error) = self.failure { return Err(error); }
        let result = if let Some(reader) = self.key_reader.as_mut() { reader.provide_window(base, bytes) }
            else if let Some(walker) = self.walker.as_mut() { walker.provide(base, bytes) }
            else { Err(SourceError::argument(crate::source::DETAIL_BAD_WINDOW, base)) };
        if let Err(error) = result { self.failure = Some(error); }
        result
    }
}
/// Next member, DONE, or NEED_READ. Copy key bytes before any next/provide call.
/// # Safety
/// Iterator live, outputs writable for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_iter_next(iter: *mut leanjson_source_v2_iter, member_out: *mut leanjson_source_v2_member, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if member_out.is_null() { return Err(invalid_arg()); }
        let iter = iter.as_mut().ok_or_else(invalid_arg)?; iter.source.inner.borrow().ready()?;
        let step = match iter.next() { Ok(step) => step, Err(error) => { iter.failure = Some(error); return Err(error); } };
        Ok(match step {
            WalkStep::Member(member) => { *member_out = output_member(iter, member); leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY) },
            WalkStep::Done => leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_DONE),
            WalkStep::NeedRead { offset, length } => leanjson_source_v1_result { offset, length: length as u64, ..leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_NEED_READ) },
        })
    })
}
/// Supply one requested nonempty bounded window; no caller pointer survives.
/// # Safety
/// Iterator live and byte/output pointers valid for stated sizes.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_iter_provide_window(iter: *mut leanjson_source_v2_iter, base: u64, bytes: *const u8, len: usize, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || { let iter = iter.as_mut().ok_or_else(invalid_arg)?;
        iter.source.inner.borrow().ready()?; iter.provide(base, input(bytes, len)?)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY)) })
}
/// Release iterator, its work files, and its independent source reference.
/// # Safety
/// NULL or live owned iterator, released exactly once.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_iter_release(iter: *mut leanjson_source_v2_iter) {
    let _ = catch_unwind(AssertUnwindSafe(|| { if !iter.is_null() { drop(Box::from_raw(iter)); } }));
}
/// Start bounded scalar output from an immutable span, using v1 op functions.
/// # Safety
/// Span/source live, operation/result outputs writable.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_node_scalar_begin(node: leanjson_source_v2_node, op_out: *mut *mut leanjson_source_v1_op, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if op_out.is_null() { return Err(invalid_arg()); } *op_out = ptr::null_mut();
        let span = node.span()?; let handle = source(node.source)?;
        let mut reader = SourceReader::new(&span.node(), true, handle.inner.borrow().window_size())?;
        let result = leanjson_source_v1_result::step(reader.step()?);
        *op_out = Box::into_raw(Box::new(leanjson_source_v1_op { source: clone_source(node.source), reader })); Ok(result)
    })
}
