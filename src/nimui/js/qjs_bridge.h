#ifndef QJS_BRIDGE_H
#define QJS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* (*QjsNimAllocFn)(void* ctx, size_t size, size_t align);
typedef void  (*QjsNimFreeFn)(void* ctx, void* ptr, size_t size);

typedef int32_t (*QjsNimHostCallbackFn)(
    void* user_data,
    int32_t op,
    const char* a0,
    const char* a1,
    const char* a2,
    char* out_buf,
    int32_t out_cap
);

typedef struct QjsBridgeRuntime QjsBridgeRuntime;

QjsBridgeRuntime* qjs_bridge_new(
    QjsNimAllocFn alloc_fn,
    QjsNimFreeFn free_fn,
    void* alloc_ctx,
    size_t memory_limit_bytes,
    size_t max_stack_bytes,
    uint64_t max_steps,
    QjsNimHostCallbackFn host_cb,
    void* host_user_data
);

void qjs_bridge_free(QjsBridgeRuntime* brt);

void qjs_bridge_set_host(
    QjsBridgeRuntime* brt,
    QjsNimHostCallbackFn host_cb,
    void* host_user_data
);

void qjs_bridge_reset_steps(QjsBridgeRuntime* brt, uint64_t max_steps);
uint64_t qjs_bridge_get_steps(const QjsBridgeRuntime* brt);
size_t qjs_bridge_get_malloc_size(const QjsBridgeRuntime* brt);
size_t qjs_bridge_get_malloc_count(const QjsBridgeRuntime* brt);
void qjs_bridge_run_gc(QjsBridgeRuntime* brt);

/* Returns 0 on success, non-zero on error/exception/interrupt. */
int32_t qjs_bridge_eval(
    QjsBridgeRuntime* brt,
    const char* code,
    size_t code_len,
    const char* filename,
    char* out_buf,
    int32_t out_cap,
    char* err_buf,
    int32_t err_cap
);

/* Calls a global function `func_name(arg0)` (or 0 args if arg0 == NULL). */
int32_t qjs_bridge_call_global1(
    QjsBridgeRuntime* brt,
    const char* func_name,
    const char* arg0,
    char* out_buf,
    int32_t out_cap,
    char* err_buf,
    int32_t err_cap
);

/* Invokes registered JS callback by integer id with optional string arg. */
int32_t qjs_bridge_invoke_cb(
    QjsBridgeRuntime* brt,
    int32_t cb_id,
    const char* arg0,
    char* out_buf,
    int32_t out_cap,
    char* err_buf,
    int32_t err_cap
);

#ifdef __cplusplus
}
#endif

#endif /* QJS_BRIDGE_H */
