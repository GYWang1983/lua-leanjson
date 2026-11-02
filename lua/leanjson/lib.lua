local ffi = require("ffi")

ffi.cdef[[
typedef struct leanjson_doc leanjson_doc;
typedef struct {
    int code;
    size_t offset;
} leanjson_error;
typedef struct {
    const leanjson_doc* doc;
    uint32_t idx_start, idx_end, _reserved0, _reserved1;
} leanjson_cursor;

typedef struct {
    const leanjson_doc* doc;
    uint32_t idx_current, idx_end;
} leanjson_iter;

typedef struct {
    uint32_t mode;
    uint32_t max_depth;
} leanjson_options;

const char* leanjson_strerror(int code);
size_t leanjson_format_error(int code, size_t offset, size_t extra,
                          const char* buf, size_t buf_len,
                          char* out, size_t out_len);
size_t leanjson_doc_last_error_offset(const leanjson_doc* doc);
leanjson_doc* leanjson_parse   (const uint8_t* buf, size_t len, leanjson_error* err_out);
leanjson_doc* leanjson_parse_ex(const uint8_t* buf, size_t len,
                       const leanjson_options* opts, leanjson_error* err_out);
void     leanjson_free    (leanjson_doc* doc);

int leanjson_get_str (leanjson_doc*, const char* path, size_t path_len, const uint8_t** p, size_t* n);
int leanjson_get_i64 (leanjson_doc*, const char* path, size_t path_len, int64_t* out);
int leanjson_get_u64 (leanjson_doc*, const char* path, size_t path_len, uint64_t* out);
int leanjson_get_f64 (leanjson_doc*, const char* path, size_t path_len, double*  out);
int leanjson_get_bool(leanjson_doc*, const char* path, size_t path_len, int*     out);
int leanjson_is_null (leanjson_doc*, const char* path, size_t path_len, int*     out);
int leanjson_typeof  (leanjson_doc*, const char* path, size_t path_len, int*     out);
int leanjson_len     (leanjson_doc*, const char* path, size_t path_len, size_t*  out);

int leanjson_open        (leanjson_doc*, const char* path, size_t path_len, leanjson_cursor* out);
int leanjson_cursor_open (const leanjson_cursor*, const char* path, size_t path_len, leanjson_cursor* out);
int leanjson_cursor_field(const leanjson_cursor*, const char* key,  size_t key_len, leanjson_cursor* out);
int leanjson_cursor_index(const leanjson_cursor*, size_t i, leanjson_cursor* out);

int leanjson_cursor_get_str (const leanjson_cursor*, const char*, size_t, const uint8_t**, size_t*);
int leanjson_cursor_get_i64 (const leanjson_cursor*, const char*, size_t, int64_t*);
int leanjson_cursor_get_u64 (const leanjson_cursor*, const char*, size_t, uint64_t*);
int leanjson_cursor_get_f64 (const leanjson_cursor*, const char*, size_t, double*);
int leanjson_cursor_get_bool(const leanjson_cursor*, const char*, size_t, int*);
int leanjson_cursor_typeof  (const leanjson_cursor*, const char*, size_t, int*);
int leanjson_cursor_len     (const leanjson_cursor*, const char*, size_t, size_t*);
int leanjson_cursor_bytes(const leanjson_cursor*, size_t* byte_start, size_t* byte_end);
int leanjson_cursor_object_entry_at(const leanjson_cursor*, size_t i,
                                const uint8_t** key_ptr, size_t* key_len,
                                leanjson_cursor* value_out);
int leanjson_iter_init(const leanjson_cursor*, leanjson_iter* it);
int leanjson_iter_next(leanjson_iter* it,
                    const uint8_t** key_ptr, size_t* key_len,
                    leanjson_cursor* value_out);

typedef struct leanjson_source_v1 leanjson_source_v1;
typedef struct leanjson_source_v1_op leanjson_source_v1_op;
typedef struct leanjson_source_v1_iter leanjson_source_v1_iter;
typedef struct { const leanjson_source_v1 *source; uint64_t node_id; } leanjson_source_v1_node;
typedef struct {
    uint32_t status, detail;
    int32_t code;
    uint64_t offset, length;
} leanjson_source_v1_result;
typedef struct { uint32_t api_version, mode, max_depth, window_size; } leanjson_source_v1_options;
typedef struct {
    uint32_t kind, complete;
    uint64_t raw_start, raw_end, child_count;
} leanjson_source_v1_node_info;
typedef struct {
    uint64_t ordinal, key_start, key_end;
    leanjson_source_v1_node value;
} leanjson_source_v1_member;
leanjson_source_v1 *leanjson_source_v1_new(const leanjson_source_v1_options *, leanjson_source_v1_result *);
int leanjson_source_v1_feed(leanjson_source_v1 *, uint64_t, const uint8_t *, size_t, leanjson_source_v1_result *);
int leanjson_source_v1_finish(leanjson_source_v1 *, uint64_t, leanjson_source_v1_result *);
int leanjson_source_v1_abort(leanjson_source_v1 *, uint32_t, leanjson_source_v1_result *);
void leanjson_source_v1_retain(leanjson_source_v1 *);
void leanjson_source_v1_release(leanjson_source_v1 *);
int leanjson_source_v1_root(const leanjson_source_v1 *, leanjson_source_v1_node *, leanjson_source_v1_result *);
int leanjson_source_v1_node_get_info(leanjson_source_v1_node, leanjson_source_v1_node_info *, leanjson_source_v1_result *);
int leanjson_source_v1_iter_begin(leanjson_source_v1_node, leanjson_source_v1_iter **, leanjson_source_v1_result *);
int leanjson_source_v1_iter_next(leanjson_source_v1_iter *, leanjson_source_v1_member *, leanjson_source_v1_result *);
void leanjson_source_v1_iter_release(leanjson_source_v1_iter *);
int leanjson_source_v1_node_raw_begin(leanjson_source_v1_node, leanjson_source_v1_op **, leanjson_source_v1_result *);
int leanjson_source_v1_node_scalar_begin(leanjson_source_v1_node, leanjson_source_v1_op **, leanjson_source_v1_result *);
int leanjson_source_v1_op_step(leanjson_source_v1_op *, const uint8_t **, size_t *, leanjson_source_v1_result *);
int leanjson_source_v1_provide_window(leanjson_source_v1_op *, uint64_t, const uint8_t *, size_t, leanjson_source_v1_result *);
void leanjson_source_v1_op_release(leanjson_source_v1_op *);

/* Sparse sources, additive v2 API. v1 options/layouts/entry points are unchanged.
 * v2_new defaults: depth=3, array prefix=3, optional index budget=1048576.
 * Explicit zeros disable optional preindexing. All integer fields are uint32.
 * max_depth remains the independent full-validation nesting limit. Feed,
 * finish, abort, retain and release use v1 source functions. All new exports
 * catch panics. Source spans borrow their source; iterator/op handles retain it.
 * flags: 0=unknown duplicate status, 1=proven no duplicate in subtree,
 * 2=duplicates in subtree. Unknown must never be interpreted as clean.
 * Only rebuildable native capacity is budgeted. Root/validation stack, active
 * bounded I/O and duplicate work, input, edits, returned values and output are
 * separate semantic/working storage, not a total RSS bound. Wide duplicate
 * indexes spill to owned temporary files; Unix pathnames are unlinked on open.
 */
typedef struct {
    uint32_t api_version, mode, max_depth, window_size;
    uint32_t index_depth, index_array_limit, index_budget_bytes, reserved;
    const uint8_t *spill_directory;
    size_t spill_directory_len;
} leanjson_source_v2_options;
typedef struct {
    const leanjson_source_v1 *source;
    uint64_t raw_start, raw_end, child_count;
    uint32_t kind, flags;
} leanjson_source_v2_node;
typedef struct leanjson_source_v2_iter leanjson_source_v2_iter;
typedef struct {
    uint64_t ordinal, key_start, key_end;
    const uint8_t *key;
    size_t key_len;
    leanjson_source_v2_node value;
} leanjson_source_v2_member;
typedef struct {
    uint64_t budget_bytes, index_bytes, indexed_nodes, indexed_depth;
    uint64_t index_depth, index_array_limit;
} leanjson_source_v2_stats;
leanjson_source_v1 *leanjson_source_v2_new(const leanjson_source_v2_options *, leanjson_source_v1_result *);
int leanjson_source_v2_root(const leanjson_source_v1 *, leanjson_source_v2_node *, leanjson_source_v1_result *);
int leanjson_source_v2_get_stats(const leanjson_source_v1 *, leanjson_source_v2_stats *, leanjson_source_v1_result *);
int leanjson_source_v2_clear_indexes(const leanjson_source_v1 *, leanjson_source_v1_result *);
typedef struct {
    uint64_t spill_file_bytes, spill_live_regions, spill_free_regions;
} leanjson_source_v2_workspace_stats;
int leanjson_source_v2_get_workspace_stats(const leanjson_source_v1 *, leanjson_source_v2_workspace_stats *, leanjson_source_v1_result *);

/* normalize=0 yields every lexical occurrence; normalize=1 yields first-key
 * position with final whole value. Arrays are zero-based. iter_next returns
 * READY, DONE, NEED_READ or ERROR. Supply NEED_READ with a nonempty window at
 * offset, at most length; partial windows work. Key pointer is valid only until
 * next/provide/release on that iterator. Copy keys immediately. Each iterator
 * owns independent traversal and temporary files; release exactly once. */
int leanjson_source_v2_iter_begin(leanjson_source_v2_node, uint32_t normalize, leanjson_source_v2_iter **, leanjson_source_v1_result *);
int leanjson_source_v2_lookup_begin(leanjson_source_v2_node, const uint8_t *key, size_t key_len, uint64_t index, leanjson_source_v2_iter **, leanjson_source_v1_result *);
int leanjson_source_v2_iter_next(leanjson_source_v2_iter *, leanjson_source_v2_member *, leanjson_source_v1_result *);
int leanjson_source_v2_iter_provide_window(leanjson_source_v2_iter *, uint64_t, const uint8_t *, size_t, leanjson_source_v1_result *);
void leanjson_source_v2_iter_release(leanjson_source_v2_iter *);
/* Scalar operations use unchanged v1 op_step/provide/release functions. */
int leanjson_source_v2_node_scalar_begin(leanjson_source_v2_node, leanjson_source_v1_op **, leanjson_source_v1_result *);

]]

local tried = {}
local attempts = {}
local last_error
local required_symbols = {
    "leanjson_strerror",
    "leanjson_format_error",
    "leanjson_doc_last_error_offset",
    "leanjson_parse",
    "leanjson_parse_ex",
    "leanjson_free",
    "leanjson_get_str",
    "leanjson_get_i64",
    "leanjson_get_u64",
    "leanjson_get_f64",
    "leanjson_get_bool",
    "leanjson_is_null",
    "leanjson_typeof",
    "leanjson_len",
    "leanjson_open",
    "leanjson_cursor_open",
    "leanjson_cursor_field",
    "leanjson_cursor_index",
    "leanjson_cursor_get_str",
    "leanjson_cursor_get_i64",
    "leanjson_cursor_get_u64",
    "leanjson_cursor_get_f64",
    "leanjson_cursor_get_bool",
    "leanjson_cursor_typeof",
    "leanjson_cursor_len",
    "leanjson_cursor_bytes",
    "leanjson_cursor_object_entry_at",
    "leanjson_iter_init",
    "leanjson_iter_next",
    "leanjson_source_v1_new", "leanjson_source_v1_feed", "leanjson_source_v1_finish",
    "leanjson_source_v1_abort", "leanjson_source_v1_retain", "leanjson_source_v1_release",
    "leanjson_source_v1_root", "leanjson_source_v1_node_get_info", "leanjson_source_v1_iter_begin",
    "leanjson_source_v1_iter_next", "leanjson_source_v1_iter_release", "leanjson_source_v1_node_raw_begin",
    "leanjson_source_v1_node_scalar_begin", "leanjson_source_v1_op_step",
    "leanjson_source_v1_provide_window", "leanjson_source_v1_op_release",
    "leanjson_source_v2_new",
    "leanjson_source_v2_root",
    "leanjson_source_v2_get_stats",
    "leanjson_source_v2_get_workspace_stats",
    "leanjson_source_v2_clear_indexes",
    "leanjson_source_v2_iter_begin",
    "leanjson_source_v2_lookup_begin",
    "leanjson_source_v2_iter_next",
    "leanjson_source_v2_iter_provide_window",
    "leanjson_source_v2_iter_release",
    "leanjson_source_v2_node_scalar_begin",
}

local function try_load(name)
    if tried[name] then
        return nil
    end
    tried[name] = true
    attempts[#attempts + 1] = name
    local ok, lib = pcall(ffi.load, name)
    if ok then
        for _, required_symbol in ipairs(required_symbols) do
            local has_symbol, symbol = pcall(function()
                return lib[required_symbol]
            end)
            if not has_symbol or symbol == nil then
                last_error = "loaded " .. name .. " but missing required symbol " .. required_symbol
                return nil
            end
        end
        return lib
    end
    last_error = lib
    return nil
end

local function load_from_cpath()
    local names = { "leanjson", "libleanjson" }
    for template in string.gmatch(package.cpath, "[^;]+") do
        if string.find(template, "?", 1, true) then
            for _, name in ipairs(names) do
                local path = string.gsub(template, "%?", name)
                local lib = try_load(path)
                if lib then
                    return lib
                end
            end
        end
    end
    return nil
end

local lib = try_load("leanjson") or try_load("libleanjson") or load_from_cpath()
if not lib then
    error("leanjson: failed to load native library leanjson; tried "
        .. table.concat(attempts, ", ")
        .. "; last error: " .. tostring(last_error))
end

return lib
