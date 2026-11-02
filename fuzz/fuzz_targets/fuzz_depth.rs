#![no_main]

use std::os::raw::{c_char, c_int};
use std::ptr;
use std::sync::Once;

use libfuzzer_sys::fuzz_target;
use leanjson::doc::Document;
use leanjson::error::leanjson_err;
use leanjson::ffi::{
    leanjson_cursor, leanjson_cursor_bytes, leanjson_cursor_field, leanjson_cursor_index, leanjson_cursor_len,
    leanjson_error, leanjson_free, leanjson_open, leanjson_parse_ex,
};
use leanjson::options::{
    Options, LEANJSON_DEFAULT_MAX_DEPTH, LEANJSON_MAX_MAX_DEPTH, LEANJSON_MODE_EAGER, LEANJSON_MODE_LAZY,
};

static BOUNDARY_ASSERTIONS: Once = Once::new();

fuzz_target!(|data: &[u8]| {
    BOUNDARY_ASSERTIONS.call_once(run_boundary_assertions);
    run_generated_case(data);
});

fn run_boundary_assertions() {
    for mode in [LEANJSON_MODE_EAGER, LEANJSON_MODE_LAZY] {
        assert_boundary(mode, 0, LEANJSON_DEFAULT_MAX_DEPTH, ShapeMode::Array);
        assert_boundary(
            mode,
            LEANJSON_MAX_MAX_DEPTH,
            LEANJSON_MAX_MAX_DEPTH,
            ShapeMode::Object,
        );
        assert_boundary(mode, u32::MAX, LEANJSON_MAX_MAX_DEPTH, ShapeMode::Mixed);
    }
}

fn assert_boundary(
    mode: u32,
    requested_max_depth: u32,
    effective_max_depth: u32,
    shape: ShapeMode,
) {
    let opts = Options {
        mode,
        max_depth: requested_max_depth,
    };

    let at_limit = nested_json(effective_max_depth, shape, &[0]);
    assert_parse_ok(&at_limit, &opts);
    walk_accepted_doc(&at_limit, &opts, shape.path_steps(effective_max_depth));

    let over_limit = nested_json(effective_max_depth + 1, shape, &[0]);
    assert_nesting_error(&over_limit, &opts);
}

fn run_generated_case(data: &[u8]) {
    let opts = Options {
        mode: if byte(data, 0) & 1 == 0 {
            LEANJSON_MODE_EAGER
        } else {
            LEANJSON_MODE_LAZY
        },
        max_depth: requested_max_depth(data),
    };
    let effective = effective_max_depth(opts.max_depth);
    let depth = generated_depth(data, effective);
    let shape = ShapeMode::from_byte(byte(data, 4));
    let mut json = nested_json(depth, shape, data);
    let mutated = mutate_skeleton(&mut json, data);

    let result = Document::parse_with_options(&json, &opts);
    let ffi_err = ffi_parse_error(&json, &opts);
    assert_ne!(
        ffi_err,
        leanjson_err::LEANJSON_OOM as c_int,
        "panic barrier tripped for {json:?}"
    );

    if !mutated {
        if depth > effective {
            assert_eq!(result.err(), Some(leanjson_err::LEANJSON_NESTING_TOO_DEEP));
            assert_eq!(ffi_err, leanjson_err::LEANJSON_NESTING_TOO_DEEP as c_int);
        } else {
            assert!(
                result.is_ok(),
                "valid depth {depth} <= {effective} was rejected"
            );
            assert_eq!(ffi_err, leanjson_err::LEANJSON_OK as c_int);
            if depth <= 256 {
                walk_accepted_doc(
                    &json,
                    &opts,
                    (0..depth).map(|level| shape.step(level, data)),
                );
            }
        }
    }
}

fn assert_parse_ok(json: &[u8], opts: &Options) {
    assert!(
        Document::parse_with_options(json, opts).is_ok(),
        "depth at limit should parse: mode={} max_depth={}",
        opts.mode,
        opts.max_depth,
    );
    assert_eq!(ffi_parse_error(json, opts), leanjson_err::LEANJSON_OK as c_int);
}

fn assert_nesting_error(json: &[u8], opts: &Options) {
    assert_eq!(
        Document::parse_with_options(json, opts).err(),
        Some(leanjson_err::LEANJSON_NESTING_TOO_DEEP),
        "one past depth limit should return LEANJSON_NESTING_TOO_DEEP: mode={} max_depth={}",
        opts.mode,
        opts.max_depth,
    );
    assert_eq!(
        ffi_parse_error(json, opts),
        leanjson_err::LEANJSON_NESTING_TOO_DEEP as c_int,
        "FFI one-past-limit parse should surface the same clean error",
    );
}

fn ffi_parse_error(json: &[u8], opts: &Options) -> c_int {
    unsafe {
        let mut err = leanjson_error::default();
        let doc = leanjson_parse_ex(json.as_ptr(), json.len(), opts as *const Options, &mut err);
        if !doc.is_null() {
            leanjson_free(doc);
        }
        err.code
    }
}

fn walk_accepted_doc(json: &[u8], opts: &Options, steps: impl Iterator<Item = Step>) {
    unsafe {
        let mut err = leanjson_error::default();
        let doc = leanjson_parse_ex(json.as_ptr(), json.len(), opts as *const Options, &mut err);
        assert!(
            !doc.is_null(),
            "accepted Phase 2 sample failed to parse: err={err:?}"
        );
        assert_eq!(err.code, leanjson_err::LEANJSON_OK as c_int);

        let mut cur: leanjson_cursor = std::mem::zeroed();
        assert_eq!(
            leanjson_open(doc, ptr::null(), 0, &mut cur),
            leanjson_err::LEANJSON_OK as c_int
        );

        let key = b"k";
        for step in steps {
            let mut len = usize::MAX;
            assert_eq!(
                leanjson_cursor_len(&cur, ptr::null(), 0, &mut len),
                leanjson_err::LEANJSON_OK as c_int,
            );
            assert_eq!(len, 1);

            let mut next: leanjson_cursor = std::mem::zeroed();
            let rc = match step {
                Step::Index0 => leanjson_cursor_index(&cur, 0, &mut next),
                Step::KeyK => {
                    leanjson_cursor_field(&cur, key.as_ptr() as *const c_char, key.len(), &mut next)
                }
            };
            assert_eq!(rc, leanjson_err::LEANJSON_OK as c_int);
            cur = next;
        }

        let mut byte_start = usize::MAX;
        let mut byte_end = usize::MAX;
        assert_eq!(
            leanjson_cursor_bytes(&cur, &mut byte_start, &mut byte_end),
            leanjson_err::LEANJSON_OK as c_int,
        );
        assert!(byte_start < byte_end && byte_end <= json.len());
        leanjson_free(doc);
    }
}

fn requested_max_depth(data: &[u8]) -> u32 {
    match byte(data, 1) % 5 {
        0 => 0,
        1 => LEANJSON_DEFAULT_MAX_DEPTH,
        2 => LEANJSON_MAX_MAX_DEPTH,
        3 => u32::MAX,
        _ => 1 + u32::from(u16_at(data, 2)) % LEANJSON_MAX_MAX_DEPTH,
    }
}

fn effective_max_depth(requested: u32) -> u32 {
    let depth = if requested == 0 {
        LEANJSON_DEFAULT_MAX_DEPTH
    } else {
        requested
    };
    depth.min(LEANJSON_MAX_MAX_DEPTH)
}

fn generated_depth(data: &[u8], effective: u32) -> u32 {
    match byte(data, 5) % 8 {
        0 => effective.saturating_sub(1).max(1),
        1 => effective,
        2 => effective + 1,
        3 => effective + 2,
        _ => 1 + u32::from(u16_at(data, 6)) % (LEANJSON_MAX_MAX_DEPTH + 2),
    }
}

fn nested_json(depth: u32, shape: ShapeMode, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity((depth as usize).saturating_mul(6).saturating_add(8));
    let mut closers = Vec::with_capacity(depth as usize);

    for level in 0..depth {
        match shape.step(level, data) {
            Step::Index0 => {
                out.push(b'[');
                closers.push(b']');
            }
            Step::KeyK => {
                out.extend_from_slice(br#"{"k":"#);
                closers.push(b'}');
            }
        }
    }

    match byte(data, 8) % 4 {
        0 => out.push(b'0'),
        1 => out.extend_from_slice(b"true"),
        2 => out.extend_from_slice(b"null"),
        _ => out.extend_from_slice(br#""x""#),
    }

    for closer in closers.into_iter().rev() {
        out.push(closer);
    }

    out
}

fn mutate_skeleton(json: &mut Vec<u8>, data: &[u8]) -> bool {
    if json.is_empty() {
        return false;
    }

    match byte(data, 9) % 5 {
        0 => false,
        1 => {
            let new_len = usize::from(u16_at(data, 10)) % json.len();
            json.truncate(new_len);
            true
        }
        2 => {
            let pos = usize::from(u16_at(data, 10)) % json.len();
            json[pos] = match json[pos] {
                b'[' => b'{',
                b'{' => b'[',
                b']' => b'}',
                b'}' => b']',
                b'"' => b'\\',
                _ => b'[',
            };
            true
        }
        3 => {
            json.push(b' ');
            json.push(b'x');
            true
        }
        _ => {
            let pos = usize::from(u16_at(data, 10)) % (json.len() + 1);
            json.insert(pos, byte(data, 12));
            true
        }
    }
}

fn byte(data: &[u8], idx: usize) -> u8 {
    data.get(idx).copied().unwrap_or(0)
}

fn u16_at(data: &[u8], idx: usize) -> u16 {
    u16::from_le_bytes([byte(data, idx), byte(data, idx + 1)])
}

#[derive(Copy, Clone)]
enum ShapeMode {
    Array,
    Object,
    Mixed,
}

impl ShapeMode {
    fn from_byte(byte: u8) -> Self {
        match byte % 3 {
            0 => Self::Array,
            1 => Self::Object,
            _ => Self::Mixed,
        }
    }

    fn step(self, level: u32, data: &[u8]) -> Step {
        match self {
            Self::Array => Step::Index0,
            Self::Object => Step::KeyK,
            Self::Mixed => {
                let selector = byte(data, 13 + (level as usize % 16));
                if (selector >> (level % 8)) & 1 == 0 {
                    Step::Index0
                } else {
                    Step::KeyK
                }
            }
        }
    }

    fn path_steps(self, depth: u32) -> impl Iterator<Item = Step> {
        (0..depth).map(move |level| self.step(level, &[]))
    }
}

#[derive(Copy, Clone)]
enum Step {
    Index0,
    KeyK,
}
