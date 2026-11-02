#ifndef LEANJSON_H
#define LEANJSON_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    LEANJSON_OK                  =  0,
    LEANJSON_PARSE_ERROR         =  1,
    LEANJSON_NOT_FOUND           =  2,
    LEANJSON_TYPE_MISMATCH       =  3,
    LEANJSON_OUT_OF_RANGE        =  4,
    LEANJSON_DECODE_FAILED       =  5,
    LEANJSON_INVALID_PATH        =  6,
    LEANJSON_INVALID_ARG         =  7,
    LEANJSON_OOM                 =  8,
    LEANJSON_NESTING_TOO_DEEP    =  9,
    LEANJSON_TRAILING_CONTENT    = 10,
    LEANJSON_NUMBER_OUT_OF_RANGE = 11,
    LEANJSON_INVALID_NUMBER      = 12,
    LEANJSON_INVALID_STRING      = 13,
    LEANJSON_INVALID_UTF8        = 14
} leanjson_err;

typedef struct {
    int    code;
    size_t offset;
} leanjson_error;

typedef enum {
    LEANJSON_T_NULL = 0, LEANJSON_T_BOOL = 1, LEANJSON_T_NUM = 2,
    LEANJSON_T_STR  = 3, LEANJSON_T_ARR  = 4, LEANJSON_T_OBJ = 5
} leanjson_type;

#define LEANJSON_MODE_EAGER          0u
#define LEANJSON_MODE_LAZY           1u
#define LEANJSON_DEFAULT_MAX_DEPTH   1024u
#define LEANJSON_MAX_MAX_DEPTH       4096u

typedef struct {
    uint32_t mode;       /* LEANJSON_MODE_EAGER (0) or LEANJSON_MODE_LAZY (1) */
    uint32_t max_depth;  /* 0 = default; values above LEANJSON_MAX_MAX_DEPTH are clamped */
} leanjson_options;

typedef struct leanjson_doc leanjson_doc;

typedef struct {
    const leanjson_doc* doc;
    uint32_t       idx_start;
    uint32_t       idx_end;
    uint32_t       _reserved0;
    uint32_t       _reserved1;
} leanjson_cursor;

typedef struct {
    const leanjson_doc* doc;
    uint32_t       idx_current;
    uint32_t       idx_end;
} leanjson_iter;

const char* leanjson_strerror(int code);
size_t leanjson_format_error(int code, size_t offset, size_t extra,
                          const char* buf, size_t buf_len,
                          char* out, size_t out_len);
size_t leanjson_doc_last_error_offset(const leanjson_doc* doc);

leanjson_doc* leanjson_parse(const uint8_t* buf, size_t len, leanjson_error* err_out);
leanjson_doc* leanjson_parse_ex(const uint8_t* buf, size_t len,
                      const leanjson_options* opts, leanjson_error* err_out);
void     leanjson_free (leanjson_doc* doc);

int leanjson_get_str  (leanjson_doc*, const char* path, size_t path_len,
                  const uint8_t** out_ptr, size_t* out_len);
int leanjson_get_i64  (leanjson_doc*, const char* path, size_t path_len, int64_t* out);
int leanjson_get_u64  (leanjson_doc*, const char* path, size_t path_len, uint64_t* out);
int leanjson_get_f64  (leanjson_doc*, const char* path, size_t path_len, double*  out);
int leanjson_get_bool (leanjson_doc*, const char* path, size_t path_len, int*     out);
int leanjson_is_null  (leanjson_doc*, const char* path, size_t path_len, int*     out);
int leanjson_typeof   (leanjson_doc*, const char* path, size_t path_len, int*     type_out);
int leanjson_len      (leanjson_doc*, const char* path, size_t path_len, size_t*  out);

int leanjson_open            (leanjson_doc*, const char* path, size_t path_len, leanjson_cursor* out);
int leanjson_cursor_open     (const leanjson_cursor*, const char* path, size_t path_len, leanjson_cursor* out);
int leanjson_cursor_field    (const leanjson_cursor*, const char* key,  size_t key_len, leanjson_cursor* out);
int leanjson_cursor_index    (const leanjson_cursor*, size_t i, leanjson_cursor* out);

int leanjson_cursor_get_str  (const leanjson_cursor*, const char* path, size_t path_len,
                         const uint8_t** out_ptr, size_t* out_len);
int leanjson_cursor_get_i64  (const leanjson_cursor*, const char* path, size_t path_len, int64_t* out);
int leanjson_cursor_get_u64  (const leanjson_cursor*, const char* path, size_t path_len, uint64_t* out);
int leanjson_cursor_get_f64  (const leanjson_cursor*, const char* path, size_t path_len, double*  out);
int leanjson_cursor_get_bool (const leanjson_cursor*, const char* path, size_t path_len, int*     out);
int leanjson_cursor_typeof   (const leanjson_cursor*, const char* path, size_t path_len, int*     out);
int leanjson_cursor_len      (const leanjson_cursor*, const char* path, size_t path_len, size_t*  out);
int leanjson_cursor_bytes    (const leanjson_cursor*, size_t* byte_start, size_t* byte_end);
int leanjson_cursor_object_entry_at(const leanjson_cursor*, size_t i,
                                const uint8_t** key_ptr, size_t* key_len,
                                leanjson_cursor* value_out);
int leanjson_iter_init(const leanjson_cursor*, leanjson_iter* it);
int leanjson_iter_next(leanjson_iter* it,
                    const uint8_t** key_ptr, size_t* key_len,
                    leanjson_cursor* value_out);

/* Window-fed sources are a separate, versioned ABI. Legacy layouts above stay
 * unchanged. All calls are synchronous, single-threaded and have panic barriers.
 * Rust owns metadata only; callers own immutable, randomly readable source bytes,
 * file descriptors and spools. No input pointer survives feed/provide_window. */
#define LEANJSON_SOURCE_V1_API 1u
#define LEANJSON_SOURCE_V1_READY       0u
#define LEANJSON_SOURCE_V1_DONE        1u
#define LEANJSON_SOURCE_V1_NEED_INPUT  2u
#define LEANJSON_SOURCE_V1_NEED_READ   3u
#define LEANJSON_SOURCE_V1_ABSENT      4u
#define LEANJSON_SOURCE_V1_ERROR       5u

#define LEANJSON_SOURCE_V1_DETAIL_NONE         0u
#define LEANJSON_SOURCE_V1_DETAIL_IO           1u
#define LEANJSON_SOURCE_V1_DETAIL_ABORTED      2u
#define LEANJSON_SOURCE_V1_DETAIL_CLOSED       3u
#define LEANJSON_SOURCE_V1_DETAIL_BAD_WINDOW   4u
#define LEANJSON_SOURCE_V1_DETAIL_BAD_OFFSET   5u
#define LEANJSON_SOURCE_V1_DETAIL_BAD_OPTIONS  6u

typedef struct leanjson_source_v1 leanjson_source_v1;
typedef struct leanjson_source_v1_op leanjson_source_v1_op;
typedef struct leanjson_source_v1_iter leanjson_source_v1_iter;

typedef struct {
    const leanjson_source_v1 *source;
    uint64_t node_id;
} leanjson_source_v1_node;

typedef struct {
    uint32_t status;
    uint32_t detail;
    int32_t code;       /* existing leanjson_err, never a source-specific code */
    uint64_t offset;    /* absolute byte position; UINT64_MAX if inapplicable */
    uint64_t length;    /* NEED_READ's requested range; otherwise zero */
} leanjson_source_v1_result;

typedef struct {
    uint32_t api_version; /* LEANJSON_SOURCE_V1_API; NULL opts selects defaults */
    uint32_t mode;        /* only LEANJSON_MODE_EAGER is supported by source v1 */
    uint32_t max_depth;   /* 0/default, clamped to LEANJSON_MAX_MAX_DEPTH */
    uint32_t window_size; /* 0 = 65536; working bound, never an input size limit */
} leanjson_source_v1_options;

typedef struct {
    uint32_t kind;        /* existing leanjson_type */
    uint32_t complete;
    uint64_t raw_start;   /* half-open absolute span, including own quotes/braces */
    uint64_t raw_end;
    uint64_t child_count; /* lexical members/elements, including duplicate keys */
} leanjson_source_v1_node_info;

typedef struct {
    uint64_t ordinal;     /* zero-based lexical position */
    uint64_t key_start;   /* quoted raw key span; both key positions 0 for arrays */
    uint64_t key_end;
    leanjson_source_v1_node value;
} leanjson_source_v1_member;

/* int results equal result.status; result may be NULL. JSON/source failures
 * return ERROR with code/detail/absolute offset, never ABSENT. finish is the
 * only EOF confirmation. root/info/iter/begin return NEED_INPUT until finish.
 * feed base must be the next input offset. Successful finish is idempotent. */
leanjson_source_v1 *leanjson_source_v1_new(const leanjson_source_v1_options *, leanjson_source_v1_result *);
int leanjson_source_v1_feed(leanjson_source_v1 *, uint64_t base, const uint8_t *, size_t, leanjson_source_v1_result *);
int leanjson_source_v1_finish(leanjson_source_v1 *, uint64_t total_len, leanjson_source_v1_result *);
/* detail must be IO, ABORTED or CLOSED; first failure is retained. Abort also
 * invalidates existing iterators/operations. Calls never close/unlink files. */
int leanjson_source_v1_abort(leanjson_source_v1 *, uint32_t detail, leanjson_source_v1_result *);
void leanjson_source_v1_retain(leanjson_source_v1 *);
void leanjson_source_v1_release(leanjson_source_v1 *);
int leanjson_source_v1_root(const leanjson_source_v1 *, leanjson_source_v1_node *, leanjson_source_v1_result *);
int leanjson_source_v1_node_get_info(leanjson_source_v1_node, leanjson_source_v1_node_info *, leanjson_source_v1_result *);
int leanjson_source_v1_iter_begin(leanjson_source_v1_node, leanjson_source_v1_iter **, leanjson_source_v1_result *);
int leanjson_source_v1_iter_next(leanjson_source_v1_iter *, leanjson_source_v1_member *, leanjson_source_v1_result *);
void leanjson_source_v1_iter_release(leanjson_source_v1_iter *);

/* Operations/iterators retain the source. Bare nodes do not: retain a source
 * while any copied node is used. Creation returns an operation plus NEED_READ
 * (or DONE for an empty scalar string). step yields nonempty READY output,
 * NEED_READ or DONE. Raw output is exact source bytes; scalar strings decode
 * escapes into UTF-8 bytes (a chunk may split a codepoint), while numbers,
 * booleans and null stream their exact raw token. Numeric conversion/range
 * checks belong to the caller's explicit materialization. Containers cannot
 * be read as scalars. Every output chunk is <= window_size and its pointer is
 * invalid after the next call on that operation. Separate operations interleave.
 *
 * On NEED_READ, provide a nonempty window at result.offset, <= result.length;
 * partial windows are accepted. The call copies <= window_size bytes. Empty,
 * oversized, misplaced or unsolicited windows cause a sticky BAD_WINDOW.
 * Empty reads are never EOF: the adapter must abort(IO) on short-source EOF.
 * Release all operation/iterator handles exactly once; NULL is a no-op. */
int leanjson_source_v1_node_raw_begin(leanjson_source_v1_node, leanjson_source_v1_op **, leanjson_source_v1_result *);
int leanjson_source_v1_node_scalar_begin(leanjson_source_v1_node, leanjson_source_v1_op **, leanjson_source_v1_result *);
int leanjson_source_v1_op_step(leanjson_source_v1_op *, const uint8_t **, size_t *, leanjson_source_v1_result *);
int leanjson_source_v1_provide_window(leanjson_source_v1_op *, uint64_t base, const uint8_t *, size_t, leanjson_source_v1_result *);
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

#ifdef __cplusplus
}
#endif

#endif
