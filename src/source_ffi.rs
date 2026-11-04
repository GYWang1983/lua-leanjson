//! Versioned C ABI for window-fed sources; see `include/leanjson.h`.
//!
//! Calls are single-threaded and synchronous. Source pointers must be NULL or
//! live handles from `new`. Node pointers borrow their source; iterators and
//! operations hold independent references. All non-NULL input/output pointers
//! must be valid for the indicated readable/writable size. Input windows may
//! be discarded on return. Every export catches unwinding Rust panics.
#![allow(non_camel_case_types)]

use std::cell::RefCell;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::rc::Rc;
use crate::error::{leanjson_err, leanjson_type};
use crate::source::{Source, SourceError, SourceReader, ReadStep, DETAIL_NONE, DETAIL_IO, DETAIL_ABORTED, DETAIL_CLOSED, DETAIL_BAD_OPTIONS};

mod sparse;
pub use sparse::*;
mod loading;
pub use loading::*;
mod schema;
pub use schema::*;

pub const LEANJSON_SOURCE_V1_API: u32 = 1;
pub const LEANJSON_SOURCE_V1_READY: u32 = 0;
pub const LEANJSON_SOURCE_V1_DONE: u32 = 1;
pub const LEANJSON_SOURCE_V1_NEED_INPUT: u32 = 2;
pub const LEANJSON_SOURCE_V1_NEED_READ: u32 = 3;
pub const LEANJSON_SOURCE_V1_ABSENT: u32 = 4;
pub const LEANJSON_SOURCE_V1_ERROR: u32 = 5;

pub struct leanjson_source_v1 { inner: RefCell<Source>, spill_dir: std::path::PathBuf }
pub struct leanjson_source_v1_op { source: Rc<leanjson_source_v1>, reader: SourceReader }
pub struct leanjson_source_v1_iter { source: Rc<leanjson_source_v1>, node: usize, ordinal: usize }

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v1_node { pub source: *const leanjson_source_v1, pub node_id: u64 }

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct leanjson_source_v1_result {
    pub status: u32, pub detail: u32, pub code: i32, pub offset: u64, pub length: u64,
}

impl Default for leanjson_source_v1_result {
    fn default() -> Self { Self { status: LEANJSON_SOURCE_V1_ERROR, detail: 0, code: 0, offset: u64::MAX, length: 0 } }
}

impl leanjson_source_v1_result {
    fn status(status: u32) -> Self { Self { status, ..Self::default() } }
    fn pending(offset: u64) -> Self { Self { offset, ..Self::status(LEANJSON_SOURCE_V1_NEED_INPUT) } }
    fn error(error: SourceError) -> Self {
        Self { detail: error.detail, code: error.code as i32, offset: error.offset, ..Self::status(LEANJSON_SOURCE_V1_ERROR) }
    }
    fn step(step: ReadStep<'_>) -> Self {
        match step {
            ReadStep::Ready(_) => Self::status(LEANJSON_SOURCE_V1_READY),
            ReadStep::Done => Self::status(LEANJSON_SOURCE_V1_DONE),
            ReadStep::NeedRead { offset, length } => Self { offset, length: length as u64, ..Self::status(LEANJSON_SOURCE_V1_NEED_READ) },
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct leanjson_source_v1_options {
    pub api_version: u32, pub mode: u32, pub max_depth: u32, pub window_size: u32,
}

impl Default for leanjson_source_v1_options {
    fn default() -> Self { Self { api_version: 1, mode: 0, max_depth: 0, window_size: 0 } }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v1_node_info {
    pub kind: u32, pub complete: u32, pub raw_start: u64, pub raw_end: u64, pub child_count: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct leanjson_source_v1_member {
    pub ordinal: u64, pub key_start: u64, pub key_end: u64, pub value: leanjson_source_v1_node,
}

fn invalid_arg() -> SourceError { SourceError::argument(DETAIL_NONE, u64::MAX) }
fn oom() -> leanjson_source_v1_result { leanjson_source_v1_result::error(SourceError::json(leanjson_err::LEANJSON_OOM, u64::MAX)) }

unsafe fn write_result(out: *mut leanjson_source_v1_result, result: leanjson_source_v1_result) -> i32 {
    if !out.is_null() { *out = result; }
    result.status as i32
}

unsafe fn boundary(out: *mut leanjson_source_v1_result, body: impl FnOnce() -> Result<leanjson_source_v1_result, SourceError>) -> i32 {
    let result = match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => leanjson_source_v1_result::error(error),
        Err(_) => oom(),
    };
    write_result(out, result)
}

unsafe fn input<'a>(bytes: *const u8, len: usize) -> Result<&'a [u8], SourceError> {
    if len > isize::MAX as usize || (bytes.is_null() && len != 0) { return Err(invalid_arg()); }
    if len == 0 { Ok(&[]) } else { Ok(std::slice::from_raw_parts(bytes, len)) }
}

unsafe fn source<'a>(handle: *const leanjson_source_v1) -> Result<&'a leanjson_source_v1, SourceError> {
    handle.as_ref().ok_or_else(invalid_arg)
}

unsafe fn clone_source(handle: *const leanjson_source_v1) -> Rc<leanjson_source_v1> {
    Rc::increment_strong_count(handle);
    Rc::from_raw(handle)
}

unsafe fn node_source<'a>(node: leanjson_source_v1_node) -> Result<(&'a leanjson_source_v1, usize), SourceError> {
    Ok((source(node.source)?, usize::try_from(node.node_id).map_err(|_| invalid_arg())?))
}

/// Create a source. Only eager mode/API version 1 are supported.
/// # Safety
/// Non-NULL options/result pointers must be readable/writable for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_new(opts: *const leanjson_source_v1_options, out: *mut leanjson_source_v1_result) -> *mut leanjson_source_v1 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let opts = if opts.is_null() { leanjson_source_v1_options::default() } else { *opts };
        if opts.api_version != LEANJSON_SOURCE_V1_API || opts.mode != 0 {
            return Err(SourceError::argument(DETAIL_BAD_OPTIONS, u64::MAX));
        }
        Ok(Rc::into_raw(Rc::new(leanjson_source_v1 { inner: RefCell::new(Source::new(opts.max_depth, opts.window_size as usize)), spill_dir: std::env::temp_dir() })) as *mut leanjson_source_v1)
    }));
    match result {
        Ok(Ok(handle)) => { write_result(out, leanjson_source_v1_result::pending(0)); handle },
        Ok(Err(error)) => { write_result(out, leanjson_source_v1_result::error(error)); ptr::null_mut() },
        Err(_) => { write_result(out, oom()); ptr::null_mut() },
    }
}

/// Consume a sequential input chunk without retaining its pointer.
/// # Safety
/// Follow the module's source/input/output pointer contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_feed(handle: *mut leanjson_source_v1, base: u64, bytes: *const u8, len: usize, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        let mut source = source(handle)?.inner.borrow_mut();
        source.feed(base, input(bytes, len)?)?;
        Ok(leanjson_source_v1_result::pending(source.offset()))
    })
}

/// Confirm EOF, total length and complete validation.
/// # Safety
/// Follow the module's source/output pointer contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_finish(handle: *mut leanjson_source_v1, total_len: u64, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        source(handle)?.inner.borrow_mut().finish(total_len)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}

/// Invalidate all users with an I/O, cancellation or closed-source error.
/// # Safety
/// Follow the module's source/output pointer contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_abort(handle: *mut leanjson_source_v1, detail: u32, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if !matches!(detail, DETAIL_IO | DETAIL_ABORTED | DETAIL_CLOSED) { return Err(invalid_arg()); }
        Err(source(handle)?.inner.borrow_mut().abort(detail))
    })
}

/// Retain a source. NULL is a no-op.
/// # Safety
/// A non-NULL handle must be live; all references are single-threaded.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_retain(handle: *mut leanjson_source_v1) {
    let _ = catch_unwind(AssertUnwindSafe(|| { if !handle.is_null() { Rc::increment_strong_count(handle); } }));
}

/// Release one source reference. NULL is a no-op.
/// # Safety
/// A non-NULL handle must have an unreleased reference owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_release(handle: *mut leanjson_source_v1) {
    let _ = catch_unwind(AssertUnwindSafe(|| { if !handle.is_null() { drop(Rc::from_raw(handle)); } }));
}

/// Return a borrowed stable root node only after finish.
/// # Safety
/// Follow the module's source/output pointer contract; retain its source while using the node.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_root(handle: *const leanjson_source_v1, node_out: *mut leanjson_source_v1_node, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if node_out.is_null() { return Err(invalid_arg()); }
        let source = source(handle)?.inner.borrow();
        match source.root()? {
            None => Ok(leanjson_source_v1_result::pending(source.offset())),
            Some(id) => { *node_out = leanjson_source_v1_node { source: handle, node_id: id as u64 }; Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY)) },
        }
    })
}

/// Read validated metadata; never requests source bytes.
/// # Safety
/// The node's source must be live and output pointers valid for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_node_get_info(node: leanjson_source_v1_node, info_out: *mut leanjson_source_v1_node_info, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if info_out.is_null() { return Err(invalid_arg()); }
        let (handle, id) = node_source(node)?;
        let source = handle.inner.borrow();
        match source.node(id)? {
            None => Ok(leanjson_source_v1_result::pending(source.offset())),
            Some(node) => {
                *info_out = leanjson_source_v1_node_info { kind: node.kind as u32, complete: u32::from(node.complete), raw_start: node.raw_start, raw_end: node.raw_end, child_count: node.members.len() as u64 };
                Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
            },
        }
    })
}

/// Create a lexical child iterator including duplicate keys; retains the source.
/// # Safety
/// The node's source must be live and output pointers valid for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_iter_begin(node: leanjson_source_v1_node, iter_out: *mut *mut leanjson_source_v1_iter, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if iter_out.is_null() { return Err(invalid_arg()); }
        *iter_out = ptr::null_mut();
        let (handle, id) = node_source(node)?;
        let source = handle.inner.borrow();
        let value = match source.node(id)? { Some(value) => value, None => return Ok(leanjson_source_v1_result::pending(source.offset())) };
        if !matches!(value.kind, leanjson_type::LEANJSON_T_ARR | leanjson_type::LEANJSON_T_OBJ) {
            return Err(SourceError::json(leanjson_err::LEANJSON_TYPE_MISMATCH, value.raw_start));
        }
        *iter_out = Box::into_raw(Box::new(leanjson_source_v1_iter { source: clone_source(node.source), node: id, ordinal: 0 }));
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}

/// Return one lexical member or DONE. Child nodes borrow the iterator's source.
/// # Safety
/// The iterator must be live and non-NULL outputs writable for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_iter_next(iter: *mut leanjson_source_v1_iter, member_out: *mut leanjson_source_v1_member, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if member_out.is_null() { return Err(invalid_arg()); }
        let iter = iter.as_mut().ok_or_else(invalid_arg)?;
        let source = iter.source.inner.borrow();
        let node = source.node(iter.node)?.ok_or_else(invalid_arg)?;
        let member = match node.members.get(iter.ordinal) { Some(member) => member, None => return Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_DONE)) };
        *member_out = leanjson_source_v1_member {
            ordinal: iter.ordinal as u64, key_start: member.key_start, key_end: member.key_end,
            value: leanjson_source_v1_node { source: Rc::as_ptr(&iter.source), node_id: member.value as u64 },
        };
        iter.ordinal += 1;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}

/// Release an iterator and its source reference. NULL is a no-op.
/// # Safety
/// The iterator must be NULL or live and must be released exactly once.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_iter_release(iter: *mut leanjson_source_v1_iter) {
    let _ = catch_unwind(AssertUnwindSafe(|| { if !iter.is_null() { drop(Box::from_raw(iter)); } }));
}

unsafe fn begin(node: leanjson_source_v1_node, scalar: bool, op_out: *mut *mut leanjson_source_v1_op) -> Result<leanjson_source_v1_result, SourceError> {
    if op_out.is_null() { return Err(invalid_arg()); }
    *op_out = ptr::null_mut();
    let (handle, id) = node_source(node)?;
    let source = handle.inner.borrow();
    let value = match source.node(id)? { Some(value) => value, None => return Ok(leanjson_source_v1_result::pending(source.offset())) };
    let mut reader = SourceReader::with_policy(value, scalar, source.window_size(), source.policy())?;
    let result = leanjson_source_v1_result::step(reader.step()?);
    *op_out = Box::into_raw(Box::new(leanjson_source_v1_op { source: clone_source(node.source), reader }));
    Ok(result)
}

/// Begin streaming exact raw bytes. The operation retains the source.
/// # Safety
/// The node's source must be live and output pointers valid for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_node_raw_begin(node: leanjson_source_v1_node, op_out: *mut *mut leanjson_source_v1_op, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || begin(node, false, op_out))
}

/// Begin streaming decoded string bytes or exact raw number/bool/null bytes.
/// # Safety
/// The node's source must be live and output pointers valid for their types.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_node_scalar_begin(node: leanjson_source_v1_node, op_out: *mut *mut leanjson_source_v1_op, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || begin(node, true, op_out))
}

/// Yield a bounded output chunk, a bounded NEED_READ range, or DONE.
/// # Safety
/// Operation/output pointers must be live/writable. Copy the chunk before the next operation call.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_op_step(op: *mut leanjson_source_v1_op, pointer_out: *mut *const u8, len_out: *mut usize, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if !pointer_out.is_null() { *pointer_out = ptr::null(); }
        if !len_out.is_null() { *len_out = 0; }
        if pointer_out.is_null() || len_out.is_null() { return Err(invalid_arg()); }
        let op = op.as_mut().ok_or_else(invalid_arg)?;
        op.source.inner.borrow().ready()?;
        let step = op.reader.step()?;
        if let ReadStep::Ready(bytes) = step { *pointer_out = bytes.as_ptr(); *len_out = bytes.len(); }
        Ok(leanjson_source_v1_result::step(step))
    })
}

/// Supply the requested nonempty bounded window; consumes/copies it before returning.
/// # Safety
/// Follow the module's operation/input/output pointer contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_provide_window(op: *mut leanjson_source_v1_op, base: u64, bytes: *const u8, len: usize, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        let op = op.as_mut().ok_or_else(invalid_arg)?;
        op.source.inner.borrow().ready()?;
        op.reader.provide_window(base, input(bytes, len)?)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}

/// Release an operation and its source reference. NULL is a no-op.
/// # Safety
/// The operation must be NULL or live and must be released exactly once.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_op_release(op: *mut leanjson_source_v1_op) {
    let _ = catch_unwind(AssertUnwindSafe(|| { if !op.is_null() { drop(Box::from_raw(op)); } }));
}

/// Exercise the shared status panic barrier without touching caller data.
/// # Safety
/// Non-NULL result must point to a writable result struct.
#[cfg(feature = "test-panic")]
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v1_force_panic(out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || panic!("forced source panic for test"))
}
