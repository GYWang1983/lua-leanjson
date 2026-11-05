//! JSON string output helpers. Every call is synchronous and retains no pointer.
//!
//! # Safety
//! Input/output/state pointers must be valid for their declared sizes; writable
//! buffers/state must not alias each other or input. NULL input/output is allowed
//! only with zero length/capacity. Cursor input and flags must stay unchanged
//! across chunks; callers own cursor/depth state and synchronize access.
#![allow(non_camel_case_types)]
use std::panic::{catch_unwind, AssertUnwindSafe};
use crate::error::leanjson_err;
pub use crate::encode::{EncodeCursor as leanjson_encode_cursor, DepthState as leanjson_encode_depth_state};

fn boundary(body: impl FnOnce() -> Result<(), leanjson_err>) -> i32 {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => 0, Ok(Err(code)) => code as i32, Err(_) => leanjson_err::LEANJSON_OOM as i32,
    }
}
unsafe fn input<'a>(bytes: *const u8, len: usize, flags: u32) -> Result<&'a [u8], leanjson_err> {
    if len > isize::MAX as usize || bytes.is_null() && len != 0 || flags & !crate::encode::ESCAPE_SLASH != 0 {
        return Err(leanjson_err::LEANJSON_INVALID_ARG);
    }
    if len == 0 { Ok(&[]) } else { Ok(std::slice::from_raw_parts(bytes, len)) }
}

/// Count encoded string body bytes, excluding its two JSON quotes.
/// # Safety
/// Follow the module's pointer and non-aliasing contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_encode_string_length(bytes: *const u8, len: usize, flags: u32, out: *mut usize) -> i32 {
    boundary(|| {
        let out = out.as_mut().ok_or(leanjson_err::LEANJSON_INVALID_ARG)?;
        *out = crate::encode::string_length(input(bytes,len,flags)?,flags)?;
        Ok(())
    })
}

/// Encode at most capacity string body bytes. A partial escape stays in cursor.
/// # Safety
/// Follow the module's pointer and non-aliasing contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_encode_string_chunk(bytes: *const u8, len: usize, flags: u32,
    cursor: *mut leanjson_encode_cursor, output: *mut u8, capacity: usize, out_len: *mut usize) -> i32
{
    boundary(|| {
        let bytes = input(bytes,len,flags)?;
        if capacity > isize::MAX as usize || output.is_null() && capacity != 0 { return Err(leanjson_err::LEANJSON_INVALID_ARG); }
        let cursor = cursor.as_mut().ok_or(leanjson_err::LEANJSON_INVALID_ARG)?;
        let out_len = out_len.as_mut().ok_or(leanjson_err::LEANJSON_INVALID_ARG)?;
        let output = if capacity == 0 { &mut [] } else { std::slice::from_raw_parts_mut(output,capacity) };
        *out_len = crate::encode::string_chunk(bytes,flags,cursor,output)?;
        Ok(())
    })
}

/// Check nesting across a validated raw source window, preserving lexical state.
/// # Safety
/// Follow the module's pointer and non-aliasing contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_encode_depth_chunk(bytes: *const u8, len: usize, state: *mut leanjson_encode_depth_state) -> i32 {
    boundary(|| crate::encode::depth_chunk(input(bytes,len,0)?,state.as_mut().ok_or(leanjson_err::LEANJSON_INVALID_ARG)?))
}
