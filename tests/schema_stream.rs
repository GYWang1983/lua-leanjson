use leanjson::error::leanjson_type::*;
use leanjson::schema::{CompiledSchema, Validator};
use serde_json::Value;

fn emit(v: &Value, key: &[u8], ordinal: u64, out: &mut Validator) {
    let kind = match v {
        Value::Null => LEANJSON_T_NULL,
        Value::Bool(_) => LEANJSON_T_BOOL,
        Value::Number(_) => LEANJSON_T_NUM,
        Value::String(_) => LEANJSON_T_STR,
        Value::Array(_) => LEANJSON_T_ARR,
        Value::Object(_) => LEANJSON_T_OBJ,
    };
    out.begin(kind, key, ordinal, 0);
    match v {
        Value::Object(map) => {
            for (i, (k, v)) in map.iter().enumerate() {
                emit(v, k.as_bytes(), i as u64, out);
            }
        }
        Value::Array(items) => {
            for (i, v) in items.iter().enumerate() {
                emit(v, b"", i as u64, out);
            }
        }
        Value::String(s) => {
            for chunk in s.as_bytes().chunks(2) {
                out.data(chunk);
            }
        }
        _ => {
            for chunk in v.to_string().as_bytes().chunks(2) {
                out.data(chunk);
            }
        }
    }
    out.end(kind, 0);
}
fn valid(schema: &str, instance: &str) -> bool {
    let mut v = Validator::new(CompiledSchema::compile(schema.as_bytes()).unwrap());
    emit(
        &serde_json::from_str::<Value>(instance).unwrap(),
        b"",
        0,
        &mut v,
    );
    v.finish().is_ok()
}
#[test]
fn types_properties_and_last_wins_are_streamed() {
    let plan = CompiledSchema::compile(
        br#"{"type":"object","required":["x"],"additionalProperties":{"type":"integer"}}"#,
    )
    .unwrap();
    for (first, last, expected) in [
        (LEANJSON_T_STR, LEANJSON_T_NUM, true),
        (LEANJSON_T_NUM, LEANJSON_T_STR, false),
    ] {
        let mut v = Validator::new(plan.clone());
        v.begin(LEANJSON_T_OBJ, b"", 0, 0);
        for (i, kind) in [first, last].iter().enumerate() {
            v.begin(*kind, b"x", i as u64, 1);
            v.data(b"1");
            v.end(*kind, 2);
        }
        v.end(LEANJSON_T_OBJ, 3);
        assert_eq!(v.finish().is_ok(), expected);
    }
    assert!(!valid(r#"{"required":["x"]}"#, "{}"));
    assert!(!valid(
        r#"{"properties":{"x":{"type":"integer"}},"additionalProperties":false}"#,
        r#"{"x":1,"y":2}"#
    ));
}
#[test]
fn memory_does_not_follow_type_only_strings_or_valid_wide_members() {
    let plan =
        CompiledSchema::compile(br#"{"type":"object","additionalProperties":{"type":"integer"}}"#)
            .unwrap();
    let mut v = Validator::new(plan);
    v.begin(LEANJSON_T_OBJ, b"", 0, 0);
    for i in 0..30000 {
        let key = format!("k{i}");
        v.begin(LEANJSON_T_NUM, key.as_bytes(), i, 0);
        v.data(b"1");
        v.end(LEANJSON_T_NUM, 1);
    }
    assert!(v.retained_bytes() < 4096, "{}", v.retained_bytes());
    v.end(LEANJSON_T_OBJ, 2);
    assert!(v.finish().is_ok());
    let mut v = Validator::new(
        CompiledSchema::compile(br#"{"type":"string","minLength":8000000}"#).unwrap(),
    );
    v.begin(LEANJSON_T_STR, b"", 0, 0);
    for _ in 0..8192 {
        v.data(&[b'x'; 1024]);
    }
    assert!(v.retained_bytes() < 4096);
    v.end(LEANJSON_T_STR, 8388608);
    assert!(v.finish().is_ok());
}
#[test]
fn exact_numbers_and_deep_equality() {
    assert!(!valid(
        r#"{"maximum":9007199254740992}"#,
        "9007199254740993"
    ));
    assert!(valid(r#"{"multipleOf":0.1}"#, "0.3"));
    assert!(!valid(r#"{"multipleOf":0.1}"#, "0.30000000000000001"));
    assert!(valid(r#"{"type":"integer"}"#, "1.0"));
    assert!(!valid(r#"{"type":"integer"}"#, "1e-1000"));
    assert!(valid(r#"{"minimum":1e1000}"#, "2e1000"));
    assert!(valid(r#"{"enum":[{"n":1}]}"#, r#"{"n":1.0}"#));
    assert!(!valid(r#"{"uniqueItems":true}"#, "[1,1.0]"));
}
#[test]
fn containers_branches_refs_dependencies_and_strings() {
    for (s, good, bad) in [
        (
            r#"{"patternProperties":{"^x":{"type":"integer"}},"additionalProperties":false,"propertyNames":{"maxLength":2}}"#,
            r#"{"x1":1}"#,
            r#"{"xxx":1}"#,
        ),
        (
            r#"{"dependencies":{"a":["b"]}}"#,
            r#"{"a":1,"b":2}"#,
            r#"{"a":1}"#,
        ),
        (
            r#"{"dependentSchemas":{"a":{"required":["b"]}}}"#,
            r#"{"a":1,"b":2}"#,
            r#"{"a":1}"#,
        ),
        (
            r#"{"prefixItems":[{"type":"string"}],"items":{"type":"integer"},"minItems":2,"contains":{"const":3},"minContains":1,"maxContains":1}"#,
            r#"["x",2,3]"#,
            r#"["x",3,3]"#,
        ),
        (
            r#"{"allOf":[{"minimum":1},{"maximum":3}],"not":{"const":2}}"#,
            "3",
            "2",
        ),
        (r#"{"oneOf":[{"type":"number"},{"minimum":0}]}"#, "-1", "1"),
        (r#"{"anyOf":[{"const":1},{"const":2}]}"#, "1", "3"),
        (
            r#"{"if":{"type":"number"},"then":{"minimum":2},"else":{"type":"string"}}"#,
            "2",
            "false",
        ),
        (
            r##"{"$defs":{"n":{"type":"integer"}},"$ref":"#/$defs/n"}"##,
            "2",
            "2.1",
        ),
        (
            r#"{"minLength":2,"maxLength":3,"pattern":"^é"}"#,
            r#""é好""#,
            r#""é""#,
        ),
        (r#"{"contentEncoding":"base64"}"#, r#""eA==""#, r#""!!!!""#),
        (r#"{"format":"ipv4"}"#, r#""127.0.0.1""#, r#""999.0.0.1""#),
    ] {
        assert!(valid(s, good), "{s} -> {good}");
        assert!(!valid(s, bad), "{s} -> {bad}");
    }
}
#[test]
fn compilation_rejects_unimplemented_or_invalid_assertions() {
    for s in [
        r#"{"unevaluatedProperties":false}"#,
        r#"{"x-gateway-image-size":{}}"#,
        r#"{"format":"custom"}"#,
        r#"{"type":"integer-ish"}"#,
        r#"{"minimum":"1"}"#,
        r#"{"required":"x"}"#,
        r##"{"$ref":"https://example.com/a"}"##,
        r##"{"$ref":"#"}"##,
    ] {
        assert!(CompiledSchema::compile(s.as_bytes()).is_err(), "{s}");
    }
    assert!(CompiledSchema::compile(br#"{"x-gateway-authorizable":true}"#).is_ok());
}

#[test]
fn compiler_ffi_reports_errors_and_owns_reusable_plan() {
    use leanjson::schema_ffi::{leanjson_schema_v1_new, leanjson_schema_v1_release};
    let mut error = [0u8; 256];
    unsafe {
        let bad = br#"{"unsupported":true}"#;
        let p = leanjson_schema_v1_new(bad.as_ptr(), bad.len(), error.as_mut_ptr(), error.len());
        assert!(p.is_null());
        assert_ne!(error[0], 0);
        let good = b"true";
        let p = leanjson_schema_v1_new(good.as_ptr(), good.len(), error.as_mut_ptr(), error.len());
        assert!(!p.is_null());
        assert_eq!(error[0], 0);
        leanjson_schema_v1_release(p);
        assert!(
            leanjson_schema_v1_new(std::ptr::null(), 1, error.as_mut_ptr(), error.len()).is_null()
        );
        leanjson_schema_v1_release(std::ptr::null_mut());
    }
}

#[test]
fn standard_format_assertions_reject_near_misses() {
    for (format, good, bad) in [
        ("date", "2024-02-29", "2023-02-29"),
        ("date-time", "2024-02-29T23:59:59Z", "2024-02-29 23:59:59Z"),
        ("time", "23:59:59+08:00", "25:59:59Z"),
        ("duration", "P1Y2M3DT4H5M6S", "P1Y2WT"),
        (
            "email",
            "hello+schema@example.com",
            "hello..schema@example.com",
        ),
        ("email", "user@[192.168.0.1]", "user@[999.168.0.1]"),
        ("hostname", "schema.example.com", "-schema.example.com"),
        ("ipv6", "2001:db8::1", "2001:db8::g"),
        (
            "uri",
            "https://example.com/a%20b",
            "https://example.com/a%ZZ",
        ),
        ("uri-reference", "../a?b=c#d", "http://example.com/a b"),
        (
            "uuid",
            "123e4567-e89b-12d3-a456-426614174000",
            "123e4567-e89b-12d3-a456-42661417400x",
        ),
        ("regex", "^(a+)\\1$", "["),
        ("json-pointer", "/a~1b/~0c", "/a~2b"),
        ("relative-json-pointer", "1/a~1b", "01/a"),
    ] {
        let s = serde_json::json!({"format":format}).to_string();
        assert!(
            valid(&s, &serde_json::to_string(good).unwrap()),
            "format {format}: {good}"
        );
        assert!(
            !valid(&s, &serde_json::to_string(bad).unwrap()),
            "format {format}: {bad}"
        );
    }
}
#[test]
fn recursive_and_escaped_local_refs_and_tuple_items() {
    let schema = r##"{"$defs":{"a/b":{"type":"object","properties":{"next":{"$ref":"#/$defs/a~1b"},"n":{"type":"integer"}}}},"$ref":"#/$defs/a~1b"}"##;
    assert!(valid(schema, r#"{"n":1,"next":{"n":2}}"#));
    assert!(!valid(schema, r#"{"n":1,"next":{"n":"bad"}}"#));
    assert!(valid(
        r##"{"definitions":{"A B":{"const":3}},"$ref":"#/definitions/A%20B"}"##,
        "3"
    ));
    assert!(valid(
        r#"{"items":[{"type":"string"}],"additionalItems":false}"#,
        r#"["ok"]"#
    ));
    assert!(!valid(
        r#"{"items":[{"type":"string"}],"additionalItems":false}"#,
        r#"["ok",1]"#
    ));
}
#[test]
fn numeric_bounds_multiples_and_huge_exponents_are_exact() {
    for (schema, good, bad) in [
        (
            r#"{"exclusiveMinimum":-2,"exclusiveMaximum":2}"#,
            "1.999999999999999999999",
            "2",
        ),
        (
            r#"{"minimum":-9007199254740992}"#,
            "-9007199254740992",
            "-9007199254740993",
        ),
        (r#"{"multipleOf":0.25}"#, "-1.5", "1.6"),
        (r#"{"multipleOf":12}"#, "120", "121"),
        (
            r#"{"multipleOf":3}"#,
            "3e999999999999999999999",
            "1e999999999999999999999",
        ),
        (
            r#"{"minimum":1e999999999999999999999}"#,
            "2e999999999999999999999",
            "2e999999999999999999998",
        ),
        (
            r#"{"const":-0}"#,
            "0e-999999999999999999999",
            "0.000000000000000000001",
        ),
    ] {
        assert!(valid(schema, good), "{schema} -> {good}");
        assert!(!valid(schema, bad), "{schema} -> {bad}");
    }
}
#[test]
fn final_duplicate_values_control_composition_and_equality() {
    for schema in [
        r#"{"const":{"x":1}}"#,
        r#"{"allOf":[{"required":["x"]},{"properties":{"x":{"type":"integer"}}}],"maxProperties":1,"minProperties":1}"#,
    ] {
        let plan = CompiledSchema::compile(schema.as_bytes()).unwrap();
        let mut v = Validator::new(plan);
        v.begin(LEANJSON_T_OBJ, b"", 0, 0);
        v.begin(LEANJSON_T_STR, b"x", 0, 1);
        v.data(b"wrong");
        v.end(LEANJSON_T_STR, 7);
        v.begin(LEANJSON_T_NUM, b"x", 1, 9);
        v.data(b"1");
        v.end(LEANJSON_T_NUM, 10);
        v.end(LEANJSON_T_OBJ, 11);
        assert!(v.finish().is_ok(), "{schema}");
    }
    assert!(!valid(
        r#"{"uniqueItems":true}"#,
        r#"[{"x":1,"y":2},{"y":2,"x":1.0}]"#
    ));
    assert!(valid(
        r#"{"contains":{"type":"integer"},"minContains":0,"maxContains":0}"#,
        r#"["x"]"#
    ));
    assert!(!valid(
        r#"{"contains":{"type":"integer"},"minContains":0,"maxContains":0}"#,
        r#"["x",1]"#
    ));
}
#[test]
fn regular_expression_semantics_are_ecmascript_and_compiled_once() {
    assert!(valid(r#"{"pattern":"^(a+)\\1$"}"#, r#""aaaa""#));
    assert!(!valid(r#"{"pattern":"^\\d+$"}"#, r#""١٢٣""#));
    assert!(valid(r#"{"pattern":"^(?=a)a$"}"#, r#""a""#));
    for pattern in [r"\p{L}", r"[[:alpha:]]", "["] {
        let schema = serde_json::json!({"pattern":pattern}).to_string();
        assert!(CompiledSchema::compile(schema.as_bytes()).is_err());
    }
}
#[test]
fn incomplete_and_unbalanced_event_streams_fail_closed() {
    let plan = CompiledSchema::compile(b"true").unwrap();
    let mut empty = Validator::new(plan.clone());
    assert!(empty.finish().is_err());
    let mut partial = Validator::new(plan.clone());
    partial.begin(LEANJSON_T_OBJ, b"", 0, 0);
    assert!(partial.finish().is_err());
    let mut mismatch = Validator::new(plan.clone());
    mismatch.begin(LEANJSON_T_OBJ, b"", 0, 0);
    mismatch.end(LEANJSON_T_ARR, 1);
    assert!(mismatch.finish().is_err());
    let mut multiple = Validator::new(plan);
    emit(&Value::Null, b"", 0, &mut multiple);
    emit(&Value::Null, b"", 0, &mut multiple);
    assert!(multiple.finish().is_err());
}

#[test]
fn uri_formats_use_rfc3986_grammar_without_url_repairs() {
    assert!(!valid(r#"{"format":"uri-reference"}"#, r#""/a[b]""#));
    assert!(valid(
        r#"{"format":"uri"}"#,
        r#""urn:example:animal:ferret:nose""#
    ));
    assert!(valid(
        r#"{"format":"uri-reference"}"#,
        r#""//[2001:db8::1]/""#
    ));
}
#[test]
fn integer_valued_schema_counts_accept_decimal_notation() {
    assert!(valid(r#"{"minLength":1.0,"maxLength":2e0}"#, r#""ab""#));
    assert!(!valid(r#"{"minLength":1.0,"maxLength":2e0}"#, r#""abc""#));
}

#[test]
fn invalid_utf8_keys_cannot_alias_the_empty_property_name() {
    let plan =
        CompiledSchema::compile(br#"{"additionalProperties":false,"properties":{"":{"const":1}}}"#)
            .unwrap();
    let mut v = Validator::new(plan);
    v.begin(LEANJSON_T_OBJ, b"", 0, 0);
    v.begin(LEANJSON_T_NUM, &[255], 0, 1);
    v.data(b"1");
    v.end(LEANJSON_T_NUM, 2);
    v.end(LEANJSON_T_OBJ, 3);
    assert!(v.finish().is_err());
}
#[test]
fn duration_and_format_endings_follow_rfc3339_grammar() {
    for s in ["PT0.5S", "P1Y2D", "PT1H2S", "P1D\n"] {
        assert!(
            !valid(
                r#"{"format":"duration"}"#,
                &serde_json::to_string(s).unwrap()
            ),
            "{s:?}"
        );
    }
    for s in [
        "P1Y2M",
        "PT1H2M",
        "PT1M2S",
        "P01D",
        "P99999999999999999999999999999999999999D",
    ] {
        assert!(
            valid(
                r#"{"format":"duration"}"#,
                &serde_json::to_string(s).unwrap()
            ),
            "{s:?}"
        );
    }
    assert!(!valid(
        r#"{"format":"uuid"}"#,
        r#""123e4567-e89b-12d3-a456-426614174000\n""#
    ));
}

#[test]
fn email_quoted_locals_follow_ascii_smtp_grammar() {
    let schema = r#"{"format":"email"}"#;
    for email in [
        "\"é\"@example.com",
        "\"a\u{1}b\"@example.com",
        "\"a\\é\"@example.com",
    ] {
        assert!(
            !valid(schema, &serde_json::to_string(email).unwrap()),
            "{email:?}"
        );
    }
    for email in ["\"a b\"@example.com", "\"a\\\"b\"@example.com"] {
        assert!(
            valid(schema, &serde_json::to_string(email).unwrap()),
            "{email:?}"
        );
    }
}
#[test]
fn leap_seconds_use_offset_normalized_utc_minutes() {
    for (format, good, bad) in [
        ("time", "00:59:60+01:00", "23:59:60+01:00"),
        ("time", "23:59:60Z", "12:34:60Z"),
        (
            "date-time",
            "2024-01-01T00:59:60+01:00",
            "2024-01-01T12:34:60Z",
        ),
    ] {
        let schema = serde_json::json!({"format":format}).to_string();
        assert!(
            valid(&schema, &serde_json::to_string(good).unwrap()),
            "{good}"
        );
        assert!(
            !valid(&schema, &serde_json::to_string(bad).unwrap()),
            "{bad}"
        );
    }
}
#[test]
fn excessive_same_instance_reference_depth_is_rejected() {
    let mut defs = serde_json::Map::new();
    for i in 0..300 {
        defs.insert(
            format!("n{i:03}"),
            if i == 0 {
                serde_json::json!({"type":"integer"})
            } else {
                serde_json::json!({"$ref":format!("#/$defs/n{:03}",i-1)})
            },
        );
    }
    let schema = serde_json::json!({"$defs":defs,"$ref":"#/$defs/n299"});
    assert!(CompiledSchema::compile(schema.to_string().as_bytes()).is_err());
}

#[test]
fn legal_schema_data_keys_do_not_alias_serde_number_representation() {
    let schema = br#"{"const":{"$serde_json::private::Number":"123"}}"#;
    let plan = CompiledSchema::compile(schema).unwrap();
    let mut object = Validator::new(plan.clone());
    object.begin(LEANJSON_T_OBJ, b"", 0, 0);
    object.begin(LEANJSON_T_STR, b"$serde_json::private::Number", 0, 1);
    object.data(b"123");
    object.end(LEANJSON_T_STR, 2);
    object.end(LEANJSON_T_OBJ, 3);
    assert!(object.finish().is_ok());
    let mut number = Validator::new(plan);
    emit(&serde_json::json!(123), b"", 0, &mut number);
    assert!(number.finish().is_err());
}

#[test]
fn unknown_schema_dialects_fail_explicitly() {
    for schema in [
        r#"{"$schema":"https://example.com/custom-metaschema","minimum":2}"#,
        r#"{"$schema":"http://json-schema.org/draft-07/schema#"}"#,
        r#"{"$schema":false}"#,
    ] {
        assert!(
            CompiledSchema::compile(schema.as_bytes()).is_err(),
            "{schema}"
        );
    }
    for schema in [
        r#"{"$schema":"https://json-schema.org/draft/2020-12/schema"}"#,
        r#"{"$schema":"https://json-schema.org/draft/2020-12/schema#"}"#,
    ] {
        assert!(
            CompiledSchema::compile(schema.as_bytes()).is_ok(),
            "{schema}"
        );
    }
}

#[test]
fn empty_enum_is_a_valid_deny_all_assertion() {
    for instance in ["null", "true", "1", r#""text""#, "[]", "{}"] {
        assert!(!valid(r#"{"enum":[]}"#, instance));
    }
}
