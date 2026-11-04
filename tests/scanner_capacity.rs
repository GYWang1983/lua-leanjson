use leanjson::__test_api::{Scanner, ScalarScanner};

fn long_string_keeps_metadata_small<S: Scanner>() {
    let mut input = br#"{"payload":""#.to_vec();
    input.extend(std::iter::repeat_n(b'x', 1024 * 1024));
    input.extend_from_slice(br#""}"#);
    let mut offsets = Vec::new();
    S::scan(&input, &mut offsets).unwrap();
    assert_eq!(offsets.len(), 7);
    assert!(offsets.capacity() <= 256, "sparse structural metadata reserved {} entries", offsets.capacity());
}

#[test]
fn scalar_sparse_input_does_not_reserve_in_proportion_to_body_bytes() {
    long_string_keeps_metadata_small::<ScalarScanner>();
}

#[cfg(target_arch = "aarch64")]
#[test]
fn neon_sparse_input_does_not_reserve_in_proportion_to_body_bytes() {
    if std::arch::is_aarch64_feature_detected!("aes") {
        long_string_keeps_metadata_small::<leanjson::__test_api::NeonScanner>();
    }
}

#[cfg(all(target_arch = "x86_64", feature = "avx2"))]
#[test]
fn avx2_sparse_input_does_not_reserve_in_proportion_to_body_bytes() {
    if std::is_x86_feature_detected!("avx2") && std::is_x86_feature_detected!("pclmulqdq") {
        long_string_keeps_metadata_small::<leanjson::__test_api::Avx2Scanner>();
    }
}
