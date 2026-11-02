//! Additive scan-time loading ABI; existing source structs remain unchanged.
use super::*;
use crate::source::loading::Selector;

pub struct leanjson_source_v2_selector { selector: Rc<Selector> }
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct leanjson_source_v2_loading_event {
    pub event: u32, pub selected: u32, pub kind: u32, pub flags: u32,
    pub raw_start: u64, pub raw_end: u64, pub child_count: u64, pub ordinal: u64,
    pub key: *const u8, pub key_len: usize, pub bytes: *const u8, pub bytes_len: usize,
}

/// Compile length-prefixed UTF-8 JSONPath strings into an immutable prefix trie.
/// # Safety
/// Input/result pointers obey the v1 source contract.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_selector_new(bytes: *const u8, len: usize, out: *mut leanjson_source_v1_result) -> *mut leanjson_source_v2_selector {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let selector = Selector::compile(input(bytes, len)?)?;
        Ok(Box::into_raw(Box::new(leanjson_source_v2_selector { selector: Rc::new(selector) })))
    }));
    match result {
        Ok(Ok(selector)) => {
            write_result(out, leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY));
            selector
        },
        Ok(Err(error)) => { write_result(out, leanjson_source_v1_result::error(error)); ptr::null_mut() },
        Err(_) => { write_result(out, oom()); ptr::null_mut() },
    }
}
/// Release a selector; configured sources own their independent immutable copy.
/// # Safety
/// Handle is NULL or one live selector, released exactly once.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_selector_release(handle: *mut leanjson_source_v2_selector) {
    let _ = catch_unwind(AssertUnwindSafe(|| { if !handle.is_null() { drop(Box::from_raw(handle)); } }));
}
/// Enable construction events before the first feed. eager=1 selects all values.
/// # Safety
/// Handles/results obey their source/selector ownership contracts.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_set_loading(handle: *const leanjson_source_v1, selector: *const leanjson_source_v2_selector, eager: u32, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if eager > 1 { return Err(invalid_arg()); }
        let selector = selector.as_ref().map(|value| value.selector.clone());
        source(handle)?.inner.borrow_mut().set_loading(eager != 0, selector)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}
/// Drain BEGIN=1, decoded DATA=2, END=3 events after each bounded feed/finish.
/// DONE means the current queue is empty. Bytes borrow the source until its next
/// feed/finish/next-event/release. No event is a validated provisional result.
/// # Safety
/// Handle/output pointers obey the v1 source contract; copy borrowed bytes.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_next_loading_event(handle: *const leanjson_source_v1, event: *mut leanjson_source_v2_loading_event, out: *mut leanjson_source_v1_result) -> i32 {
    boundary(out, || {
        if event.is_null() { return Err(invalid_arg()); }
        *event = leanjson_source_v2_loading_event::default();
        let mut source = source(handle)?.inner.borrow_mut();
        match source.next_loading_event()? {
            Some(value) => {
                *event = leanjson_source_v2_loading_event { event: value.event, selected: value.selected as u32,
                    kind: value.kind as u32, flags: value.flags, raw_start: value.start, raw_end: value.end,
                    child_count: value.count, ordinal: value.ordinal, key: value.key.as_ptr(), key_len: value.key.len(),
                    bytes: value.bytes.as_ptr(), bytes_len: value.bytes.len() };
                Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
            },
            None => Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_DONE)),
        }
    })
}
