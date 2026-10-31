#ifndef QJSON_H
#define QJSON_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    QJSON_OK                  =  0,
    QJSON_PARSE_ERROR         =  1,
    QJSON_NOT_FOUND           =  2,
    QJSON_TYPE_MISMATCH       =  3,
    QJSON_OUT_OF_RANGE        =  4,
    QJSON_DECODE_FAILED       =  5,
    QJSON_INVALID_PATH        =  6,
    QJSON_INVALID_ARG         =  7,
    QJSON_OOM                 =  8,
    QJSON_NESTING_TOO_DEEP    =  9,
    QJSON_TRAILING_CONTENT    = 10,
    QJSON_NUMBER_OUT_OF_RANGE = 11,
    QJSON_INVALID_NUMBER      = 12,
    QJSON_INVALID_STRING      = 13,
    QJSON_INVALID_UTF8        = 14
} qjson_err;

typedef struct {
    int    code;
    size_t offset;
} qjson_error;

typedef enum {
    QJSON_T_NULL = 0, QJSON_T_BOOL = 1, QJSON_T_NUM = 2,
    QJSON_T_STR  = 3, QJSON_T_ARR  = 4, QJSON_T_OBJ = 5
} qjson_type;

#define QJSON_MODE_EAGER          0u
#define QJSON_MODE_LAZY           1u
#define QJSON_DEFAULT_MAX_DEPTH   1024u
#define QJSON_MAX_MAX_DEPTH       4096u

typedef struct {
    uint32_t mode;       /* QJSON_MODE_EAGER (0) or QJSON_MODE_LAZY (1) */
    uint32_t max_depth;  /* 0 = default; values above QJSON_MAX_MAX_DEPTH are clamped */
} qjson_options;

typedef struct qjson_doc qjson_doc;

typedef struct {
    const qjson_doc* doc;
    uint32_t       idx_start;
    uint32_t       idx_end;
    uint32_t       _reserved0;
    uint32_t       _reserved1;
} qjson_cursor;

typedef struct {
    const qjson_doc* doc;
    uint32_t       idx_current;
    uint32_t       idx_end;
} qjson_iter;

const char* qjson_strerror(int code);
size_t qjson_format_error(int code, size_t offset, size_t extra,
                          const char* buf, size_t buf_len,
                          char* out, size_t out_len);
size_t qjson_doc_last_error_offset(const qjson_doc* doc);

qjson_doc* qjson_parse(const uint8_t* buf, size_t len, qjson_error* err_out);
qjson_doc* qjson_parse_ex(const uint8_t* buf, size_t len,
                      const qjson_options* opts, qjson_error* err_out);
void     qjson_free (qjson_doc* doc);

int qjson_get_str  (qjson_doc*, const char* path, size_t path_len,
                  const uint8_t** out_ptr, size_t* out_len);
int qjson_get_i64  (qjson_doc*, const char* path, size_t path_len, int64_t* out);
int qjson_get_u64  (qjson_doc*, const char* path, size_t path_len, uint64_t* out);
int qjson_get_f64  (qjson_doc*, const char* path, size_t path_len, double*  out);
int qjson_get_bool (qjson_doc*, const char* path, size_t path_len, int*     out);
int qjson_is_null  (qjson_doc*, const char* path, size_t path_len, int*     out);
int qjson_typeof   (qjson_doc*, const char* path, size_t path_len, int*     type_out);
int qjson_len      (qjson_doc*, const char* path, size_t path_len, size_t*  out);

int qjson_open            (qjson_doc*, const char* path, size_t path_len, qjson_cursor* out);
int qjson_cursor_open     (const qjson_cursor*, const char* path, size_t path_len, qjson_cursor* out);
int qjson_cursor_field    (const qjson_cursor*, const char* key,  size_t key_len, qjson_cursor* out);
int qjson_cursor_index    (const qjson_cursor*, size_t i, qjson_cursor* out);

int qjson_cursor_get_str  (const qjson_cursor*, const char* path, size_t path_len,
                         const uint8_t** out_ptr, size_t* out_len);
int qjson_cursor_get_i64  (const qjson_cursor*, const char* path, size_t path_len, int64_t* out);
int qjson_cursor_get_u64  (const qjson_cursor*, const char* path, size_t path_len, uint64_t* out);
int qjson_cursor_get_f64  (const qjson_cursor*, const char* path, size_t path_len, double*  out);
int qjson_cursor_get_bool (const qjson_cursor*, const char* path, size_t path_len, int*     out);
int qjson_cursor_typeof   (const qjson_cursor*, const char* path, size_t path_len, int*     out);
int qjson_cursor_len      (const qjson_cursor*, const char* path, size_t path_len, size_t*  out);
int qjson_cursor_bytes    (const qjson_cursor*, size_t* byte_start, size_t* byte_end);
int qjson_cursor_object_entry_at(const qjson_cursor*, size_t i,
                                const uint8_t** key_ptr, size_t* key_len,
                                qjson_cursor* value_out);
int qjson_iter_init(const qjson_cursor*, qjson_iter* it);
int qjson_iter_next(qjson_iter* it,
                    const uint8_t** key_ptr, size_t* key_len,
                    qjson_cursor* value_out);

/* Window-fed sources are a separate, versioned ABI. Legacy layouts above stay
 * unchanged. All calls are synchronous, single-threaded and have panic barriers.
 * Rust owns metadata only; callers own immutable, randomly readable source bytes,
 * file descriptors and spools. No input pointer survives feed/provide_window. */
#define QJSON_SOURCE_V1_API 1u
#define QJSON_SOURCE_V1_READY       0u
#define QJSON_SOURCE_V1_DONE        1u
#define QJSON_SOURCE_V1_NEED_INPUT  2u
#define QJSON_SOURCE_V1_NEED_READ   3u
#define QJSON_SOURCE_V1_ABSENT      4u
#define QJSON_SOURCE_V1_ERROR       5u

#define QJSON_SOURCE_V1_DETAIL_NONE         0u
#define QJSON_SOURCE_V1_DETAIL_IO           1u
#define QJSON_SOURCE_V1_DETAIL_ABORTED      2u
#define QJSON_SOURCE_V1_DETAIL_CLOSED       3u
#define QJSON_SOURCE_V1_DETAIL_BAD_WINDOW   4u
#define QJSON_SOURCE_V1_DETAIL_BAD_OFFSET   5u
#define QJSON_SOURCE_V1_DETAIL_BAD_OPTIONS  6u

typedef struct qjson_source_v1 qjson_source_v1;
typedef struct qjson_source_v1_op qjson_source_v1_op;
typedef struct qjson_source_v1_iter qjson_source_v1_iter;

typedef struct {
    const qjson_source_v1 *source;
    uint64_t node_id;
} qjson_source_v1_node;

typedef struct {
    uint32_t status;
    uint32_t detail;
    int32_t code;       /* existing qjson_err, never a source-specific code */
    uint64_t offset;    /* absolute byte position; UINT64_MAX if inapplicable */
    uint64_t length;    /* NEED_READ's requested range; otherwise zero */
} qjson_source_v1_result;

typedef struct {
    uint32_t api_version; /* QJSON_SOURCE_V1_API; NULL opts selects defaults */
    uint32_t mode;        /* only QJSON_MODE_EAGER is supported by source v1 */
    uint32_t max_depth;   /* 0/default, clamped to QJSON_MAX_MAX_DEPTH */
    uint32_t window_size; /* 0 = 65536; working bound, never an input size limit */
} qjson_source_v1_options;

typedef struct {
    uint32_t kind;        /* existing qjson_type */
    uint32_t complete;
    uint64_t raw_start;   /* half-open absolute span, including own quotes/braces */
    uint64_t raw_end;
    uint64_t child_count; /* lexical members/elements, including duplicate keys */
} qjson_source_v1_node_info;

typedef struct {
    uint64_t ordinal;     /* zero-based lexical position */
    uint64_t key_start;   /* quoted raw key span; both key positions 0 for arrays */
    uint64_t key_end;
    qjson_source_v1_node value;
} qjson_source_v1_member;

/* int results equal result.status; result may be NULL. JSON/source failures
 * return ERROR with code/detail/absolute offset, never ABSENT. finish is the
 * only EOF confirmation. root/info/iter/begin return NEED_INPUT until finish.
 * feed base must be the next input offset. Successful finish is idempotent. */
qjson_source_v1 *qjson_source_v1_new(const qjson_source_v1_options *, qjson_source_v1_result *);
int qjson_source_v1_feed(qjson_source_v1 *, uint64_t base, const uint8_t *, size_t, qjson_source_v1_result *);
int qjson_source_v1_finish(qjson_source_v1 *, uint64_t total_len, qjson_source_v1_result *);
/* detail must be IO, ABORTED or CLOSED; first failure is retained. Abort also
 * invalidates existing iterators/operations. Calls never close/unlink files. */
int qjson_source_v1_abort(qjson_source_v1 *, uint32_t detail, qjson_source_v1_result *);
void qjson_source_v1_retain(qjson_source_v1 *);
void qjson_source_v1_release(qjson_source_v1 *);
int qjson_source_v1_root(const qjson_source_v1 *, qjson_source_v1_node *, qjson_source_v1_result *);
int qjson_source_v1_node_get_info(qjson_source_v1_node, qjson_source_v1_node_info *, qjson_source_v1_result *);
int qjson_source_v1_iter_begin(qjson_source_v1_node, qjson_source_v1_iter **, qjson_source_v1_result *);
int qjson_source_v1_iter_next(qjson_source_v1_iter *, qjson_source_v1_member *, qjson_source_v1_result *);
void qjson_source_v1_iter_release(qjson_source_v1_iter *);

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
int qjson_source_v1_node_raw_begin(qjson_source_v1_node, qjson_source_v1_op **, qjson_source_v1_result *);
int qjson_source_v1_node_scalar_begin(qjson_source_v1_node, qjson_source_v1_op **, qjson_source_v1_result *);
int qjson_source_v1_op_step(qjson_source_v1_op *, const uint8_t **, size_t *, qjson_source_v1_result *);
int qjson_source_v1_provide_window(qjson_source_v1_op *, uint64_t base, const uint8_t *, size_t, qjson_source_v1_result *);
void qjson_source_v1_op_release(qjson_source_v1_op *);

#ifdef __cplusplus
}
#endif

#endif
