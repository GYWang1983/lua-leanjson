use leanjson::source_ffi::*;
use std::{mem::{size_of, offset_of}, ptr};

fn paths(paths: &[&str]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for path in paths { bytes.extend_from_slice(&(path.len() as u32).to_le_bytes()); bytes.extend_from_slice(path.as_bytes()); }
    bytes
}

unsafe fn selector(paths_: &[&str]) -> *mut leanjson_source_v2_selector {
    let bytes = paths(paths_);
    let mut result = leanjson_source_v1_result::default();
    let selector = leanjson_source_v2_selector_new(bytes.as_ptr(), bytes.len(), &mut result);
    assert!(!selector.is_null(), "{result:?}");
    assert_eq!(result.status, 0);
    selector
}

#[derive(Debug, PartialEq)]
struct Event { event: u32, selected: u32, kind: u32, first: u64, last: u64, key: Vec<u8>, bytes: Vec<u8> }
unsafe fn drain(source: *const leanjson_source_v1, events: &mut Vec<Event>) {
    let mut event = leanjson_source_v2_loading_event::default();
    let mut result = leanjson_source_v1_result::default();
    loop {
        match leanjson_source_v2_next_loading_event(source, &mut event, &mut result) {
            0 => events.push(Event { event: event.event, selected: event.selected, kind: event.kind,
                first: event.raw_start, last: event.raw_end, key: std::slice::from_raw_parts(event.key, event.key_len).to_vec(),
                bytes: std::slice::from_raw_parts(event.bytes, event.bytes_len).to_vec() }),
            1 => break,
            status => panic!("unexpected {status}: {result:?}"),
        }
    }
}

#[test]
fn scan_events_select_deep_far_and_wildcard_values_without_native_indexes() {
    unsafe {
        let options = leanjson_source_v2_options { index_depth: 0, index_array_limit: 0, index_budget_bytes: 0, ..Default::default() };
        let source = leanjson_source_v2_new(&options, ptr::null_mut());
        let selection = selector(&["$.a.b.c.d.e", "$.items[5].x", "$.items[*].role", "$.items[5].x"]);
        assert_eq!(leanjson_source_v2_set_loading(source, selection, 0, ptr::null_mut()), 0);
        leanjson_source_v2_selector_release(selection);
        let bytes = br#"{"a":{"b":{"c":{"d":{"e":"a\n\uD83D\uDE00"}}}},"items":[0,1,2,3,4,{"x":false,"role":null}],"ignored":"large unselected string"}"#;
        let mut events = Vec::new();
        for (offset, &byte) in bytes.iter().enumerate() {
            let mut temporary = [byte];
            assert_eq!(leanjson_source_v1_feed(source, offset as u64, temporary.as_ptr(), 1, ptr::null_mut()), 2);
            temporary[0] = 0;
            drain(source, &mut events);
        }
        assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, ptr::null_mut()), 0);
        drain(source, &mut events);
        let loaded: Vec<_> = events.iter().filter(|e| e.event == 1 && e.selected == 1).map(|e| e.key.as_slice()).collect();
        assert_eq!(loaded, [b"e".as_slice(), b"x", b"role"]);
        let payload: Vec<_> = events.iter().flat_map(|e| e.bytes.iter().copied()).collect();
        assert_eq!(payload, "a\n😀falsenull".as_bytes());
        let mut stats = leanjson_source_v2_stats::default();
        assert_eq!(leanjson_source_v2_get_stats(source, &mut stats, ptr::null_mut()), 0);
        assert_eq!((stats.index_bytes, stats.indexed_nodes), (0, 0));
        leanjson_source_v1_release(source);
    }
}

#[test]
fn eager_events_build_every_lexical_value_with_no_optional_native_tree() {
    unsafe {
        let source = leanjson_source_v2_new(ptr::null(), ptr::null_mut());
        assert_eq!(leanjson_source_v2_set_loading(source, ptr::null(), 1, ptr::null_mut()), 0);
        let bytes = br#"{"a":9007199254740993,"\u0061":false,"b":[null,[],{}]}"#;
        assert_eq!(leanjson_source_v1_feed(source, 0, bytes.as_ptr(), bytes.len(), ptr::null_mut()), 2);
        assert_eq!(leanjson_source_v1_finish(source, bytes.len() as u64, ptr::null_mut()), 0);
        let mut events = Vec::new(); drain(source, &mut events);
        assert_eq!(events.iter().filter(|e| e.event == 1).count(), 7);
        assert!(events.iter().filter(|e| e.event == 1).all(|e| e.selected == 1));
        assert_eq!(events.iter().filter(|e| e.event == 1 && e.key == b"a").count(), 2);
        assert!(events.iter().any(|e| e.bytes == b"9007199254740993"));
        let mut stats = leanjson_source_v2_stats::default();
        assert_eq!(leanjson_source_v2_get_stats(source, &mut stats, ptr::null_mut()), 0);
        assert_eq!((stats.index_bytes, stats.indexed_nodes), (0, 0));
        leanjson_source_v1_release(source);
    }
}

#[test]
fn selectors_validate_supported_syntax_and_reject_invalid_arguments() {
    unsafe {
        for path in ["$", "$.a.b", "$['a\\'b']", "$[\"q\\\"uote\"]", "$[\"\\uD83D\\uDE00\"]", "$[18446744073709551615]", "$.*[*]"] {
            leanjson_source_v2_selector_release(selector(&[path]));
        }
        for path in ["", "a", "$..a", "$[-1]", "$[1:2]", "$[1,2]", "$[?(@)]", "$.*x", "$[18446744073709551616]", "$[\"\\uD800\"]"] {
            let bytes = paths(&[path]);
            let mut result = leanjson_source_v1_result::default();
            assert!(leanjson_source_v2_selector_new(bytes.as_ptr(), bytes.len(), &mut result).is_null(), "{path}");
            assert_eq!((result.status, result.detail), (5, 6));
        }
        assert!(leanjson_source_v2_selector_new(ptr::null(), 1, ptr::null_mut()).is_null());
        assert_eq!(leanjson_source_v2_set_loading(ptr::null(), ptr::null(), 0, ptr::null_mut()), 5);
        assert_eq!(leanjson_source_v2_next_loading_event(ptr::null(), ptr::null_mut(), ptr::null_mut()), 5);
        leanjson_source_v2_selector_release(ptr::null_mut());
        let source = leanjson_source_v2_new(ptr::null(), ptr::null_mut());
        assert_eq!(leanjson_source_v2_set_loading(source, ptr::null(), 2, ptr::null_mut()), 5);
        assert_eq!(leanjson_source_v1_feed(source, 0, b"[]".as_ptr(), 2, ptr::null_mut()), 2);
        assert_eq!(leanjson_source_v2_set_loading(source, ptr::null(), 1, ptr::null_mut()), 5);
        leanjson_source_v1_release(source);
    }
}

#[test]
fn new_exports_preserve_published_layouts_and_define_event_layout() {
    assert_eq!(size_of::<leanjson_source_v1_options>(), 16);
    assert_eq!(size_of::<leanjson_source_v1_result>(), 32);
    assert_eq!(offset_of!(leanjson_source_v1_result, offset), 16);
    assert_eq!(size_of::<leanjson_source_v1_node>(), 16);
    assert_eq!(size_of::<leanjson_source_v2_options>(), 48);
    assert_eq!(offset_of!(leanjson_source_v2_options, spill_directory), 32);
    assert_eq!(size_of::<leanjson_source_v2_node>(), 40);
    assert_eq!(size_of::<leanjson_source_v2_stats>(), 48);
    assert_eq!(size_of::<leanjson_source_v2_workspace_stats>(), 24);
    assert_eq!(size_of::<leanjson_source_v2_loading_event>(), 80);
    assert_eq!(offset_of!(leanjson_source_v2_loading_event, key), 48);
    assert_eq!(offset_of!(leanjson_source_v2_loading_event, bytes_len), 72);
}
