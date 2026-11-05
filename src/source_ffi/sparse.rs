//! Additive v2 sparse ABI. v1 layouts and functions remain unchanged.
use super::*;
use crate::source::{IndexOptions, Span, SpanMember, SourcePolicy, MODE_INVALID_NUMBERS, MODE_RAW_BYTES, MODE_COMMENTS};
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
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v2_index_stats {
    pub structural_index_bytes: u64, pub lookup_cache_bytes: u64,
    pub lookup_cache_hits: u64, pub lookup_cache_misses: u64,
}
enum CacheWalk { Confirmed, Prefix { ordinal: u64, offset: u64 }, Index(u64), Object { remaining: usize, hash: u64 }, Streaming, Finished }
pub struct leanjson_source_v2_iter {
    source: Rc<leanjson_source_v1>, span: Span, mode: u32, lookup: Option<Lookup>,
    cached: CacheWalk, walker: Option<Walker>, pending: Option<SpanMember>, key_reader: Option<SourceReader>,
    key: Vec<u8>, failure: Option<SourceError>, confirmed: bool,
}

/// Create a capacity-bounded source. Feed/finish/abort/retain/release use v1.
/// # Safety
/// Options and output pointers must be valid; optional directory bytes readable.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_new(opts: *const leanjson_source_v2_options, out: *mut leanjson_source_v1_result) -> *mut leanjson_source_v1 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let opts = if opts.is_null() { leanjson_source_v2_options::default() } else { *opts };
        if opts.api_version != 2 || opts.mode & !(MODE_INVALID_NUMBERS | MODE_RAW_BYTES | MODE_COMMENTS) != 0 || opts.reserved != 0 { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
        let directory = if opts.spill_directory_len == 0 { std::env::temp_dir() } else {
            let bytes = input(opts.spill_directory, opts.spill_directory_len)?;
            if bytes.contains(&0) { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
            #[cfg(unix)] { use std::os::unix::ffi::OsStrExt; std::path::PathBuf::from(std::ffi::OsStr::from_bytes(bytes)) }
            #[cfg(not(unix))] { std::path::PathBuf::from(std::str::from_utf8(bytes).map_err(|_| invalid_arg())?) }
        };
        let indexes = IndexOptions { depth: opts.index_depth, array_limit: opts.index_array_limit, budget_bytes: opts.index_budget_bytes as usize };
        Ok(Rc::into_raw(Rc::new(leanjson_source_v1 { inner: RefCell::new(Source::new_sparse(opts.max_depth, opts.window_size as usize, indexes).with_policy(SourcePolicy { invalid_numbers: opts.mode & MODE_INVALID_NUMBERS != 0, raw_bytes: opts.mode & MODE_RAW_BYTES != 0, comments: opts.mode & MODE_COMMENTS != 0, max_depth: 0 })), spill_dir: directory })) as *mut leanjson_source_v1)
    }));
    match result {
        Ok(Ok(handle)) => { write_result(out, leanjson_source_v1_result::pending(0)); handle },
        Ok(Err(error)) => { write_result(out, leanjson_source_v1_result::error(error)); ptr::null_mut() },
        Err(_) => { write_result(out, oom()); ptr::null_mut() },
    }
}
/// Enable/disable validated string-boundary retention before the first feed.
/// # Safety
/// Handle and result obey the v1 source contract; enabled must be zero or one.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_set_structural_index(handle: *const leanjson_source_v1, enabled: u32, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if enabled > 1 { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
        source(handle)?.inner.borrow_mut().set_structural_index(enabled != 0)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}
/// Additive metadata accounting; existing v2 stats/layout stay unchanged.
/// # Safety
/// Handle and output pointers obey the v1 source contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_get_index_stats(handle: *const leanjson_source_v1, stats: *mut leanjson_source_v2_index_stats, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if stats.is_null() { return Err(invalid_arg()); }
        let source = source(handle)?.inner.borrow(); source.ready()?;
        if source.index_options().is_none() { return Err(invalid_arg()); }
        *stats = leanjson_source_v2_index_stats { structural_index_bytes: source.structural_index_bytes() as u64,
            lookup_cache_bytes: source.lookup_cache_bytes() as u64, lookup_cache_hits: source.lookup_cache_hits(), lookup_cache_misses: source.lookup_cache_misses() };
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
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
    if iter_out.is_null() || normalize > 2 { return Err(invalid_arg()); }
    *iter_out = ptr::null_mut(); let span = node.span()?;
    if !matches!(span.kind, leanjson_type::LEANJSON_T_ARR | leanjson_type::LEANJSON_T_OBJ) {
        return Err(SourceError::json(leanjson_err::LEANJSON_TYPE_MISMATCH, span.raw_start));
    }
    let handle = source(node.source)?;
    let demand = lookup.as_ref().and_then(|lookup| handle.inner.borrow_mut().lookup_cached(span.raw_start, lookup));
    let confirmed = demand.is_some();
    let cached = if confirmed { CacheWalk::Confirmed } else { match &lookup {
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
        None if normalize != 0 && span.kind == leanjson_type::LEANJSON_T_OBJ => CacheWalk::Streaming,
        None => CacheWalk::Prefix { ordinal: 0, offset: span.raw_start },
    }};
    *iter_out = Box::into_raw(Box::new(leanjson_source_v2_iter { source: clone_source(node.source), span,
        mode: normalize, lookup, cached, walker: None, pending: demand.flatten(), key_reader: None,
        key: Vec::new(), failure: None, confirmed }));
    Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
}
/// Start lexical (0), normalized (1), or lexical with final-occurrence metadata
/// (2). Mode 2 pre-scans one bounded/spilled key map, then replays the source.
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
    fn is_current(&self) -> bool {
        self.span.kind != leanjson_type::LEANJSON_T_OBJ || self.mode == 1
            || (self.mode == 2 && self.walker.as_ref().is_some_and(Walker::is_current))
    }
    fn cached_entry(&self, ordinal: usize) -> Option<(crate::source::Member, Span)> {
        self.source.inner.borrow().cached_member(self.span.raw_start, ordinal)
    }
    fn prepare_key(&mut self, member: crate::source::Member, span: Span, ordinal: u64) -> Result<(), SourceError> {
        self.pending = Some(SpanMember { ordinal, key_start: member.key_start, key_end: member.key_end, key: Vec::new(), value: span });
        self.key.clear();
        let node = Span { kind: leanjson_type::LEANJSON_T_STR, flags: 1, raw_start: member.key_start, raw_end: member.key_end, child_count: 0 }.node();
        self.key_reader = Some(SourceReader::with_policy(&node, true, self.source.inner.borrow().window_size(), self.source.inner.borrow().policy())?);
        Ok(())
    }
    fn next(&mut self) -> Result<WalkStep, SourceError> {
        let step = self.next_uncached()?;
        if !self.confirmed {
            if let Some(lookup) = &self.lookup {
                match &step {
                    WalkStep::Member(member) => { self.source.inner.borrow_mut().cache_lookup(self.span.raw_start, lookup, Some(member)); self.confirmed = true; },
                    WalkStep::Done => { self.source.inner.borrow_mut().cache_lookup(self.span.raw_start, lookup, None); self.confirmed = true; },
                    WalkStep::NeedRead { .. } => {},
                }
            }
        }
        Ok(step)
    }
    fn next_uncached(&mut self) -> Result<WalkStep, SourceError> {
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
                CacheWalk::Confirmed => {
                    self.cached = CacheWalk::Finished;
                    return Ok(match self.pending.take() { Some(member) => WalkStep::Member(member), None => WalkStep::Done });
                },
                CacheWalk::Finished => return Ok(WalkStep::Done),
                CacheWalk::Streaming => {
                    if self.walker.is_none() {
                        let source = self.source.inner.borrow();
                        self.walker = Some((if self.mode == 2 && self.span.kind == leanjson_type::LEANJSON_T_OBJ {
                            Walker::linked(self.span, source.window_size(), self.source.spill_dir.clone(), source.workspace(), source.policy())
                        } else {
                            Walker::new(self.span, source.window_size(), self.mode == 1,
                                self.lookup.clone(), self.source.spill_dir.clone(), source.workspace(), source.policy())
                        }).with_structural_index(source.structural_index()));
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
                        self.walker = Some(Walker::resume(self.span, (offset, ordinal), self.source.inner.borrow().window_size(),
                            self.mode == 1, self.source.spill_dir.clone(), self.source.inner.borrow().workspace(), self.source.inner.borrow().policy())
                            .with_structural_index(self.source.inner.borrow().structural_index()));
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
    boundary(out, || next_member(iter, member_out, None))
}
unsafe fn next_member(iter: *mut leanjson_source_v2_iter, member_out: *mut leanjson_source_v2_member, mut current: Option<&mut u32>) -> Result<leanjson_source_v1_result, SourceError> {
    if let Some(current) = current.as_deref_mut() { *current = 0; }
    if member_out.is_null() { return Err(invalid_arg()); }
    let iter = iter.as_mut().ok_or_else(invalid_arg)?; iter.source.inner.borrow().ready()?;
    let step = match iter.next() { Ok(step) => step, Err(error) => { iter.failure = Some(error); return Err(error); } };
    Ok(match step {
        WalkStep::Member(member) => {
            if let Some(current) = current { *current = u32::from(iter.is_current()); }
            *member_out = output_member(iter, member); leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY)
        },
        WalkStep::Done => leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_DONE),
        WalkStep::NeedRead { offset, length } => leanjson_source_v1_result { offset, length: length as u64, ..leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_NEED_READ) },
    })
}
/// Step as iter_next and report whether the occurrence is the final decoded key
/// in mode 2. Arrays and normalized mode 1 report 1; lexical mode 0 is unknown/0.
/// Non-READY results reset current_out to 0. Existing member layouts are unchanged.
/// # Safety
/// Iterator live and all output pointers writable for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_iter_next_current(iter: *mut leanjson_source_v2_iter, member_out: *mut leanjson_source_v2_member, current_out: *mut u32, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || next_member(iter, member_out, Some(current_out.as_mut().ok_or_else(invalid_arg)?)))
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
        let mut reader = SourceReader::with_policy(&span.node(), true, handle.inner.borrow().window_size(), handle.inner.borrow().policy())?;
        let result = leanjson_source_v1_result::step(reader.step()?);
        *op_out = Box::into_raw(Box::new(leanjson_source_v1_op { source: clone_source(node.source), reader })); Ok(result)
    })
}

/// Format the optional native public diagnostic. Original result code, detail
/// and offset remain unchanged. Returns bytes required, excluding the NUL.
/// # Safety
/// Handle is live; output is writable for capacity bytes when non-NULL.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_format_error(handle: *const leanjson_source_v1, output: *mut u8, capacity: usize) -> usize {
    catch_unwind(AssertUnwindSafe(|| {
        let message = source(handle).ok().and_then(|handle| handle.inner.borrow().public_error());
        let Some(message) = message else { return 0; };
        if !output.is_null() && capacity > 0 {
            let size = message.len().min(capacity - 1);
            ptr::copy_nonoverlapping(message.as_ptr(), output, size); *output.add(size) = 0;
        }
        message.len()
    })).unwrap_or(0)
}

/// Feed a bounded range of a complete, immutable memory document. Neither the
/// range nor the document pointer is retained. The full input is used only to
/// recover native-compatible diagnostics after a validation error.
/// # Safety
/// Handle/result obey v1. Document must be readable for document_len bytes on
/// every call and contain the same bytes throughout all feeds and finalization.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_feed_memory(handle: *mut leanjson_source_v1, document: *const u8, document_len: usize, base: u64, len: usize, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        let bytes = input(document, document_len)?;
        let first = usize::try_from(base).ok().filter(|&first| first <= bytes.len())
            .ok_or_else(|| SourceError::argument(crate::source::DETAIL_BAD_OFFSET, base))?;
        let end = first.checked_add(len).filter(|&end| end <= bytes.len())
            .ok_or_else(|| SourceError::argument(crate::source::DETAIL_BAD_OFFSET, base))?;
        let mut source = source(handle)?.inner.borrow_mut();
        match source.feed_memory(base, &bytes[first..end]) {
            Ok(()) => Ok(leanjson_source_v1_result::pending(source.offset())),
            Err(error) => { source.diagnose_memory(bytes, error); Err(error) },
        }
    })
}

/// Confirm EOF for a memory-feed source, using the complete original input for
/// error diagnostics only. Successful finalization remains idempotent.
/// # Safety
/// Same handle/document/result contract as leanjson_source_v2_feed_memory.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_finish_memory(handle: *mut leanjson_source_v1, document: *const u8, document_len: usize, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        let bytes = input(document, document_len)?;
        let mut source = source(handle)?.inner.borrow_mut();
        match source.finish_memory(bytes) {
            Ok(()) => Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY)),
            Err(error) => { source.diagnose_memory(bytes, error); Err(error) },
        }
    })
}

/// Select scalar byte-wise (0) or CJSON-derived batched string scanning (1)
/// before any feed, including an empty one. Existing v1/v2 defaults are unchanged.
/// # Safety
/// Handle/result obey the v1 source contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_set_scanner(handle: *const leanjson_source_v1, scanner: u32, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if scanner > 1 { return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX)); }
        source(handle)?.inner.borrow_mut().set_scanner(scanner == 1)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}
