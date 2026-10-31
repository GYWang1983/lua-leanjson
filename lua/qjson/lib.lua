local ffi = require("ffi")

ffi.cdef[[
typedef struct qjson_doc qjson_doc;
typedef struct {
    int code;
    size_t offset;
} qjson_error;
typedef struct {
    const qjson_doc* doc;
    uint32_t idx_start, idx_end, _reserved0, _reserved1;
} qjson_cursor;

typedef struct {
    const qjson_doc* doc;
    uint32_t idx_current, idx_end;
} qjson_iter;

typedef struct {
    uint32_t mode;
    uint32_t max_depth;
} qjson_options;

const char* qjson_strerror(int code);
size_t qjson_format_error(int code, size_t offset, size_t extra,
                          const char* buf, size_t buf_len,
                          char* out, size_t out_len);
size_t qjson_doc_last_error_offset(const qjson_doc* doc);
qjson_doc* qjson_parse   (const uint8_t* buf, size_t len, qjson_error* err_out);
qjson_doc* qjson_parse_ex(const uint8_t* buf, size_t len,
                       const qjson_options* opts, qjson_error* err_out);
void     qjson_free    (qjson_doc* doc);

int qjson_get_str (qjson_doc*, const char* path, size_t path_len, const uint8_t** p, size_t* n);
int qjson_get_i64 (qjson_doc*, const char* path, size_t path_len, int64_t* out);
int qjson_get_u64 (qjson_doc*, const char* path, size_t path_len, uint64_t* out);
int qjson_get_f64 (qjson_doc*, const char* path, size_t path_len, double*  out);
int qjson_get_bool(qjson_doc*, const char* path, size_t path_len, int*     out);
int qjson_is_null (qjson_doc*, const char* path, size_t path_len, int*     out);
int qjson_typeof  (qjson_doc*, const char* path, size_t path_len, int*     out);
int qjson_len     (qjson_doc*, const char* path, size_t path_len, size_t*  out);

int qjson_open        (qjson_doc*, const char* path, size_t path_len, qjson_cursor* out);
int qjson_cursor_open (const qjson_cursor*, const char* path, size_t path_len, qjson_cursor* out);
int qjson_cursor_field(const qjson_cursor*, const char* key,  size_t key_len, qjson_cursor* out);
int qjson_cursor_index(const qjson_cursor*, size_t i, qjson_cursor* out);

int qjson_cursor_get_str (const qjson_cursor*, const char*, size_t, const uint8_t**, size_t*);
int qjson_cursor_get_i64 (const qjson_cursor*, const char*, size_t, int64_t*);
int qjson_cursor_get_u64 (const qjson_cursor*, const char*, size_t, uint64_t*);
int qjson_cursor_get_f64 (const qjson_cursor*, const char*, size_t, double*);
int qjson_cursor_get_bool(const qjson_cursor*, const char*, size_t, int*);
int qjson_cursor_typeof  (const qjson_cursor*, const char*, size_t, int*);
int qjson_cursor_len     (const qjson_cursor*, const char*, size_t, size_t*);
int qjson_cursor_bytes(const qjson_cursor*, size_t* byte_start, size_t* byte_end);
int qjson_cursor_object_entry_at(const qjson_cursor*, size_t i,
                                const uint8_t** key_ptr, size_t* key_len,
                                qjson_cursor* value_out);
int qjson_iter_init(const qjson_cursor*, qjson_iter* it);
int qjson_iter_next(qjson_iter* it,
                    const uint8_t** key_ptr, size_t* key_len,
                    qjson_cursor* value_out);

typedef struct qjson_source_v1 qjson_source_v1;
typedef struct qjson_source_v1_op qjson_source_v1_op;
typedef struct qjson_source_v1_iter qjson_source_v1_iter;
typedef struct { const qjson_source_v1 *source; uint64_t node_id; } qjson_source_v1_node;
typedef struct {
    uint32_t status, detail;
    int32_t code;
    uint64_t offset, length;
} qjson_source_v1_result;
typedef struct { uint32_t api_version, mode, max_depth, window_size; } qjson_source_v1_options;
typedef struct {
    uint32_t kind, complete;
    uint64_t raw_start, raw_end, child_count;
} qjson_source_v1_node_info;
typedef struct {
    uint64_t ordinal, key_start, key_end;
    qjson_source_v1_node value;
} qjson_source_v1_member;
qjson_source_v1 *qjson_source_v1_new(const qjson_source_v1_options *, qjson_source_v1_result *);
int qjson_source_v1_feed(qjson_source_v1 *, uint64_t, const uint8_t *, size_t, qjson_source_v1_result *);
int qjson_source_v1_finish(qjson_source_v1 *, uint64_t, qjson_source_v1_result *);
int qjson_source_v1_abort(qjson_source_v1 *, uint32_t, qjson_source_v1_result *);
void qjson_source_v1_retain(qjson_source_v1 *);
void qjson_source_v1_release(qjson_source_v1 *);
int qjson_source_v1_root(const qjson_source_v1 *, qjson_source_v1_node *, qjson_source_v1_result *);
int qjson_source_v1_node_get_info(qjson_source_v1_node, qjson_source_v1_node_info *, qjson_source_v1_result *);
int qjson_source_v1_iter_begin(qjson_source_v1_node, qjson_source_v1_iter **, qjson_source_v1_result *);
int qjson_source_v1_iter_next(qjson_source_v1_iter *, qjson_source_v1_member *, qjson_source_v1_result *);
void qjson_source_v1_iter_release(qjson_source_v1_iter *);
int qjson_source_v1_node_raw_begin(qjson_source_v1_node, qjson_source_v1_op **, qjson_source_v1_result *);
int qjson_source_v1_node_scalar_begin(qjson_source_v1_node, qjson_source_v1_op **, qjson_source_v1_result *);
int qjson_source_v1_op_step(qjson_source_v1_op *, const uint8_t **, size_t *, qjson_source_v1_result *);
int qjson_source_v1_provide_window(qjson_source_v1_op *, uint64_t, const uint8_t *, size_t, qjson_source_v1_result *);
void qjson_source_v1_op_release(qjson_source_v1_op *);
]]

local tried = {}
local attempts = {}
local last_error
local required_symbols = {
    "qjson_strerror",
    "qjson_format_error",
    "qjson_doc_last_error_offset",
    "qjson_parse",
    "qjson_parse_ex",
    "qjson_free",
    "qjson_get_str",
    "qjson_get_i64",
    "qjson_get_u64",
    "qjson_get_f64",
    "qjson_get_bool",
    "qjson_is_null",
    "qjson_typeof",
    "qjson_len",
    "qjson_open",
    "qjson_cursor_open",
    "qjson_cursor_field",
    "qjson_cursor_index",
    "qjson_cursor_get_str",
    "qjson_cursor_get_i64",
    "qjson_cursor_get_u64",
    "qjson_cursor_get_f64",
    "qjson_cursor_get_bool",
    "qjson_cursor_typeof",
    "qjson_cursor_len",
    "qjson_cursor_bytes",
    "qjson_cursor_object_entry_at",
    "qjson_iter_init",
    "qjson_iter_next",
    "qjson_source_v1_new", "qjson_source_v1_feed", "qjson_source_v1_finish",
    "qjson_source_v1_abort", "qjson_source_v1_retain", "qjson_source_v1_release",
    "qjson_source_v1_root", "qjson_source_v1_node_get_info", "qjson_source_v1_iter_begin",
    "qjson_source_v1_iter_next", "qjson_source_v1_iter_release", "qjson_source_v1_node_raw_begin",
    "qjson_source_v1_node_scalar_begin", "qjson_source_v1_op_step",
    "qjson_source_v1_provide_window", "qjson_source_v1_op_release",
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
    local names = { "qjson", "libqjson" }
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

local lib = try_load("qjson") or try_load("libqjson") or load_from_cpath()
if not lib then
    error("qjson: failed to load native library qjson; tried "
        .. table.concat(attempts, ", ")
        .. "; last error: " .. tostring(last_error))
end

return lib
