//! Attach an independently retained Schema plan to the existing Source ABI.
use super::*;
use crate::schema_ffi::leanjson_schema_v1;

/// Configure scan-time assertions before any input is fed. A NULL schema clears
/// the optional plan; configured sources own their own reference to the plan.
/// # Safety
/// Handles must be NULL or live values returned by their constructors; result
/// must be NULL or writable for one source result.
#[no_mangle]
pub unsafe extern "C" fn leanjson_source_v2_set_schema(
    handle: *const leanjson_source_v1,
    schema: *const leanjson_schema_v1,
    out: *mut leanjson_source_v1_result,
) -> i32 {
    boundary(out, || {
        let plan = schema.as_ref().map(|schema| schema.plan.clone());
        source(handle)?.inner.borrow_mut().set_schema(plan)?;
        Ok(leanjson_source_v1_result::status(LEANJSON_SOURCE_V1_READY))
    })
}
