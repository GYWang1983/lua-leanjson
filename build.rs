fn main() {
    println!("cargo:rerun-if-changed=src/source/cjson_scan.c");
    // Miri interprets the Rust fallback, including cross-endian CI targets.
    if std::env::var_os("CARGO_CFG_MIRI").is_none() {
        cc::Build::new().file("src/source/cjson_scan.c").std("c99")
            .warnings(true).compile("leanjson_cjson_scan");
    }
}
