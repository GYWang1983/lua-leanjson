//! Additive opaque compiled-schema ABI. Each pointer owns one Rc; Source clones
//! the plan when attaching it, independently of the Lua wrapper's lifetime.
use crate::schema::CompiledSchema;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;
#[allow(non_camel_case_types)]
pub struct leanjson_schema_v1 {
    pub(crate) plan: Rc<CompiledSchema>,
}
unsafe fn write_error(error: *mut u8, capacity: usize, message: &str) {
    if !error.is_null() && capacity > 0 {
        let n = message.len().min(capacity - 1);
        std::ptr::copy_nonoverlapping(message.as_ptr(), error.cast(), n);
        *error.add(n) = 0;
    }
}
/// Compile a JSON object/boolean schema. Returns null on invalid input or panic;
/// error is NUL terminated when a nonempty writable error buffer is provided.
/// # Safety
/// Input and error buffers must be valid for their stated lengths. They must
/// not overlap; neither buffer is retained after this call.
#[no_mangle]
pub unsafe extern "C" fn leanjson_schema_v1_new(
    bytes: *const u8,
    len: usize,
    error: *mut u8,
    capacity: usize,
) -> *mut leanjson_schema_v1 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        write_error(error, capacity, "");
        if bytes.is_null() || len > isize::MAX as usize {
            return Err("invalid schema input pointer or length".to_owned());
        }
        let plan = CompiledSchema::compile(std::slice::from_raw_parts(bytes, len))?;
        Ok(Box::into_raw(Box::new(leanjson_schema_v1 { plan })))
    }));
    match result {
        Ok(Ok(plan)) => plan,
        Ok(Err(message)) => {
            write_error(error, capacity, &message);
            std::ptr::null_mut()
        }
        Err(_) => {
            write_error(
                error,
                capacity,
                "schema compiler panic or allocation failure",
            );
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// A non-null pointer must have been returned by new and not yet released.
#[no_mangle]
pub unsafe extern "C" fn leanjson_schema_v1_release(schema: *mut leanjson_schema_v1) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !schema.is_null() {
            drop(Box::from_raw(schema));
        }
    }));
}
