#[cfg(feature = "test-panic")]
#[test]
fn panic_does_not_unwind_through_ffi() {
    use leanjson::ffi::leanjson_test_panic;
    let rc = unsafe { leanjson_test_panic() };
    assert_eq!(rc, 8); // LEANJSON_OOM
}

#[cfg(not(feature = "test-panic"))]
#[test]
fn skip() {
    // Compile-only test; the panic-safety test requires `--features test-panic`.
}
