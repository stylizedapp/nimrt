#include "qjs_bridge.h"
#include "vendor/quickjs.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define QJS_ALLOC_MAGIC 0x514A534252494447ULL

typedef struct {
    size_t req_size;
    size_t magic;
} QjsAllocHdr;

struct QjsBridgeRuntime {
    QjsNimAllocFn alloc_fn;
    QjsNimFreeFn free_fn;
    void* alloc_ctx;

    QjsNimHostCallbackFn host_cb;
    void* host_user_data;

    JSRuntime* rt;
    JSContext* ctx;

    uint64_t step_count;
    uint64_t max_steps;
};

static size_t qjs_hdr_usable_size(const void* ptr) {
    if (!ptr) return 0;
    const QjsAllocHdr* hdr = ((const QjsAllocHdr*)ptr) - 1;
    if (hdr->magic != QJS_ALLOC_MAGIC) return 0;
    return hdr->req_size;
}

static void* qjs_custom_malloc(JSMallocState* s, size_t size) {
    QjsBridgeRuntime* brt = (QjsBridgeRuntime*)s->opaque;
    if (size == 0) size = 1;
    if (s->malloc_limit != (size_t)-1 && s->malloc_size + size > s->malloc_limit) {
        return NULL;
    }
    size_t total = sizeof(QjsAllocHdr) + size;
    QjsAllocHdr* hdr = (QjsAllocHdr*)brt->alloc_fn(brt->alloc_ctx, total, 16);
    if (!hdr) return NULL;
    hdr->req_size = size;
    hdr->magic = QJS_ALLOC_MAGIC;
    s->malloc_count++;
    s->malloc_size += size + sizeof(QjsAllocHdr);
    return (void*)(hdr + 1);
}

static void qjs_custom_free(JSMallocState* s, void* ptr) {
    if (!ptr) return;
    QjsBridgeRuntime* brt = (QjsBridgeRuntime*)s->opaque;
    QjsAllocHdr* hdr = ((QjsAllocHdr*)ptr) - 1;
    if (hdr->magic != QJS_ALLOC_MAGIC) return;
    size_t req_size = hdr->req_size;
    size_t total = sizeof(QjsAllocHdr) + req_size;
    hdr->magic = 0;
    s->malloc_count--;
    if (s->malloc_size >= total) {
        s->malloc_size -= total;
    } else {
        s->malloc_size = 0;
    }
    brt->free_fn(brt->alloc_ctx, (void*)hdr, total);
}

static void* qjs_custom_realloc(JSMallocState* s, void* ptr, size_t size) {
    if (!ptr) {
        if (size == 0) return NULL;
        return qjs_custom_malloc(s, size);
    }
    QjsAllocHdr* old_hdr = ((QjsAllocHdr*)ptr) - 1;
    if (old_hdr->magic != QJS_ALLOC_MAGIC) return NULL;
    size_t old_size = old_hdr->req_size;
    if (size == 0) {
        qjs_custom_free(s, ptr);
        return NULL;
    }
    if (size > old_size && s->malloc_limit != (size_t)-1) {
        size_t delta = size - old_size;
        if (s->malloc_size + delta > s->malloc_limit) {
            return NULL;
        }
    }
    void* new_ptr = qjs_custom_malloc(s, size);
    if (!new_ptr) return NULL;
    size_t copy_sz = old_size < size ? old_size : size;
    memcpy(new_ptr, ptr, copy_sz);
    qjs_custom_free(s, ptr);
    return new_ptr;
}

static int qjs_interrupt_cb(JSRuntime* rt, void* opaque) {
    (void)rt;
    QjsBridgeRuntime* brt = (QjsBridgeRuntime*)opaque;
    if (!brt) return 0;
    brt->step_count++;
    if (brt->max_steps > 0 && brt->step_count > brt->max_steps) {
        return 1;
    }
    return 0;
}

static void copy_cstr_bounded(char* dst, int32_t cap, const char* src) {
    if (!dst || cap <= 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    size_t n = strlen(src);
    if (n >= (size_t)cap) {
        n = (size_t)cap - 1;
    }
    if (n > 0) {
        memcpy(dst, src, n);
    }
    dst[n] = '\0';
}

static void capture_js_exception(JSContext* ctx, char* err_buf, int32_t err_cap) {
    if (!err_buf || err_cap <= 0) return;
    JSValue exc = JS_GetException(ctx);
    const char* str = JS_ToCString(ctx, exc);
    if (str) {
        JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
        if (!JS_IsUndefined(stack) && !JS_IsNull(stack)) {
            const char* stack_str = JS_ToCString(ctx, stack);
            if (stack_str && stack_str[0] != '\0') {
                snprintf(err_buf, (size_t)err_cap, "%s\n%s", str, stack_str);
                JS_FreeCString(ctx, stack_str);
            } else {
                copy_cstr_bounded(err_buf, err_cap, str);
                if (stack_str) JS_FreeCString(ctx, stack_str);
            }
        } else {
            copy_cstr_bounded(err_buf, err_cap, str);
        }
        JS_FreeValue(ctx, stack);
        JS_FreeCString(ctx, str);
    } else {
        copy_cstr_bounded(err_buf, err_cap, "Unknown QuickJS exception");
    }
    JS_FreeValue(ctx, exc);
}

static JSValue js_nim_host_dispatch(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv
) {
    (void)this_val;
    QjsBridgeRuntime* brt = (QjsBridgeRuntime*)JS_GetContextOpaque(ctx);
    if (!brt || !brt->host_cb) {
        return JS_NewString(ctx, "");
    }
    int32_t op = 0;
    if (argc >= 1) {
        JS_ToInt32(ctx, &op, argv[0]);
    }
    const char* a0 = NULL;
    const char* a1 = NULL;
    const char* a2 = NULL;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        a0 = JS_ToCString(ctx, argv[1]);
    }
    if (argc >= 3 && !JS_IsUndefined(argv[2]) && !JS_IsNull(argv[2])) {
        a1 = JS_ToCString(ctx, argv[2]);
    }
    if (argc >= 4 && !JS_IsUndefined(argv[3]) && !JS_IsNull(argv[3])) {
        a2 = JS_ToCString(ctx, argv[3]);
    }

    char out_buf[4096];
    out_buf[0] = '\0';
    int32_t rc = brt->host_cb(
        brt->host_user_data,
        op,
        a0 ? a0 : "",
        a1 ? a1 : "",
        a2 ? a2 : "",
        out_buf,
        (int32_t)sizeof(out_buf)
    );

    if (a0) JS_FreeCString(ctx, a0);
    if (a1) JS_FreeCString(ctx, a1);
    if (a2) JS_FreeCString(ctx, a2);

    if (rc < 0) {
        return JS_ThrowInternalError(ctx, "%s", out_buf[0] ? out_buf : "Host capability error");
    }
    return JS_NewString(ctx, out_buf);
}

QjsBridgeRuntime* qjs_bridge_new(
    QjsNimAllocFn alloc_fn,
    QjsNimFreeFn free_fn,
    void* alloc_ctx,
    size_t memory_limit_bytes,
    size_t max_stack_bytes,
    uint64_t max_steps,
    QjsNimHostCallbackFn host_cb,
    void* host_user_data
) {
    if (!alloc_fn || !free_fn) return NULL;
    QjsBridgeRuntime* brt = (QjsBridgeRuntime*)alloc_fn(alloc_ctx, sizeof(QjsBridgeRuntime), 16);
    if (!brt) return NULL;
    memset(brt, 0, sizeof(QjsBridgeRuntime));
    brt->alloc_fn = alloc_fn;
    brt->free_fn = free_fn;
    brt->alloc_ctx = alloc_ctx;
    brt->host_cb = host_cb;
    brt->host_user_data = host_user_data;
    brt->max_steps = max_steps;
    brt->step_count = 0;

    static const JSMallocFunctions mf = {
        qjs_custom_malloc,
        qjs_custom_free,
        qjs_custom_realloc,
        qjs_hdr_usable_size
    };

    brt->rt = JS_NewRuntime2(&mf, (void*)brt);
    if (!brt->rt) {
        free_fn(alloc_ctx, brt, sizeof(QjsBridgeRuntime));
        return NULL;
    }

    if (memory_limit_bytes > 0) {
        JS_SetMemoryLimit(brt->rt, memory_limit_bytes);
    }
    if (max_stack_bytes > 0) {
        JS_SetMaxStackSize(brt->rt, max_stack_bytes);
    }
    JS_SetInterruptHandler(brt->rt, qjs_interrupt_cb, (void*)brt);

    brt->ctx = JS_NewContext(brt->rt);
    if (!brt->ctx) {
        JS_FreeRuntime(brt->rt);
        free_fn(alloc_ctx, brt, sizeof(QjsBridgeRuntime));
        return NULL;
    }
    JS_SetContextOpaque(brt->ctx, (void*)brt);

    JSValue global_obj = JS_GetGlobalObject(brt->ctx);
    JS_SetPropertyStr(
        brt->ctx,
        global_obj,
        "__nim_host",
        JS_NewCFunction(brt->ctx, js_nim_host_dispatch, "__nim_host", 4)
    );
    JS_FreeValue(brt->ctx, global_obj);

    return brt;
}

void qjs_bridge_free(QjsBridgeRuntime* brt) {
    if (!brt) return;
    if (brt->ctx) {
        JS_FreeContext(brt->ctx);
        brt->ctx = NULL;
    }
    if (brt->rt) {
        JS_RunGC(brt->rt);
        JS_FreeRuntime(brt->rt);
        brt->rt = NULL;
    }
    QjsNimFreeFn free_fn = brt->free_fn;
    void* alloc_ctx = brt->alloc_ctx;
    if (free_fn) {
        free_fn(alloc_ctx, (void*)brt, sizeof(QjsBridgeRuntime));
    }
}

void qjs_bridge_set_host(
    QjsBridgeRuntime* brt,
    QjsNimHostCallbackFn host_cb,
    void* host_user_data
) {
    if (!brt) return;
    brt->host_cb = host_cb;
    brt->host_user_data = host_user_data;
}

void qjs_bridge_reset_steps(QjsBridgeRuntime* brt, uint64_t max_steps) {
    if (!brt) return;
    brt->step_count = 0;
    brt->max_steps = max_steps;
}

uint64_t qjs_bridge_get_steps(const QjsBridgeRuntime* brt) {
    return brt ? brt->step_count : 0;
}

size_t qjs_bridge_get_malloc_size(const QjsBridgeRuntime* brt) {
    if (!brt || !brt->rt) return 0;
    JSMemoryUsage stats;
    JS_ComputeMemoryUsage(brt->rt, &stats);
    return (size_t)stats.malloc_size;
}

size_t qjs_bridge_get_malloc_count(const QjsBridgeRuntime* brt) {
    if (!brt || !brt->rt) return 0;
    JSMemoryUsage stats;
    JS_ComputeMemoryUsage(brt->rt, &stats);
    return (size_t)stats.malloc_count;
}

void qjs_bridge_run_gc(QjsBridgeRuntime* brt) {
    if (brt && brt->rt) {
        JS_RunGC(brt->rt);
    }
}

static int32_t drain_pending_jobs(QjsBridgeRuntime* brt, char* err_buf, int32_t err_cap) {
    JSContext* pctx = NULL;
    int rc;
    while ((rc = JS_ExecutePendingJob(brt->rt, &pctx)) > 0) {
        /* keep draining */
    }
    if (rc < 0 && pctx) {
        capture_js_exception(pctx, err_buf, err_cap);
        return -1;
    }
    return 0;
}

int32_t qjs_bridge_eval(
    QjsBridgeRuntime* brt,
    const char* code,
    size_t code_len,
    const char* filename,
    char* out_buf,
    int32_t out_cap,
    char* err_buf,
    int32_t err_cap
) {
    if (out_buf && out_cap > 0) out_buf[0] = '\0';
    if (err_buf && err_cap > 0) err_buf[0] = '\0';
    if (!brt || !brt->ctx || !code) {
        copy_cstr_bounded(err_buf, err_cap, "Invalid QuickJS runtime or code pointer");
        return -1;
    }
    JS_UpdateStackTop(brt->rt);
    brt->step_count = 0;

    JSValue val = JS_Eval(
        brt->ctx,
        code,
        code_len,
        filename ? filename : "<inline>",
        JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT
    );
    if (JS_IsException(val)) {
        capture_js_exception(brt->ctx, err_buf, err_cap);
        JS_FreeValue(brt->ctx, val);
        return -1;
    }

    if (!JS_IsUndefined(val) && !JS_IsNull(val) && out_buf && out_cap > 0) {
        const char* res_str = JS_ToCString(brt->ctx, val);
        if (res_str) {
            copy_cstr_bounded(out_buf, out_cap, res_str);
            JS_FreeCString(brt->ctx, res_str);
        }
    }
    JS_FreeValue(brt->ctx, val);

    if (drain_pending_jobs(brt, err_buf, err_cap) != 0) {
        return -1;
    }
    return 0;
}

int32_t qjs_bridge_call_global1(
    QjsBridgeRuntime* brt,
    const char* func_name,
    const char* arg0,
    char* out_buf,
    int32_t out_cap,
    char* err_buf,
    int32_t err_cap
) {
    if (out_buf && out_cap > 0) out_buf[0] = '\0';
    if (err_buf && err_cap > 0) err_buf[0] = '\0';
    if (!brt || !brt->ctx || !func_name) {
        copy_cstr_bounded(err_buf, err_cap, "Invalid runtime or function name");
        return -1;
    }
    JS_UpdateStackTop(brt->rt);
    brt->step_count = 0;

    JSValue global_obj = JS_GetGlobalObject(brt->ctx);
    JSValue fn = JS_GetPropertyStr(brt->ctx, global_obj, func_name);
    if (!JS_IsFunction(brt->ctx, fn)) {
        JS_FreeValue(brt->ctx, fn);
        JS_FreeValue(brt->ctx, global_obj);
        copy_cstr_bounded(err_buf, err_cap, "Global JS function not found");
        return -1;
    }

    JSValue res;
    if (arg0 != NULL) {
        JSValue jarg = JS_NewString(brt->ctx, arg0);
        res = JS_Call(brt->ctx, fn, global_obj, 1, &jarg);
        JS_FreeValue(brt->ctx, jarg);
    } else {
        res = JS_Call(brt->ctx, fn, global_obj, 0, NULL);
    }

    JS_FreeValue(brt->ctx, fn);
    JS_FreeValue(brt->ctx, global_obj);

    if (JS_IsException(res)) {
        capture_js_exception(brt->ctx, err_buf, err_cap);
        JS_FreeValue(brt->ctx, res);
        return -1;
    }
    if (!JS_IsUndefined(res) && !JS_IsNull(res) && out_buf && out_cap > 0) {
        const char* res_str = JS_ToCString(brt->ctx, res);
        if (res_str) {
            copy_cstr_bounded(out_buf, out_cap, res_str);
            JS_FreeCString(brt->ctx, res_str);
        }
    }
    JS_FreeValue(brt->ctx, res);

    if (drain_pending_jobs(brt, err_buf, err_cap) != 0) {
        return -1;
    }
    return 0;
}

int32_t qjs_bridge_invoke_cb(
    QjsBridgeRuntime* brt,
    int32_t cb_id,
    const char* arg0,
    char* out_buf,
    int32_t out_cap,
    char* err_buf,
    int32_t err_cap
) {
    if (out_buf && out_cap > 0) out_buf[0] = '\0';
    if (err_buf && err_cap > 0) err_buf[0] = '\0';
    if (!brt || !brt->ctx) {
        copy_cstr_bounded(err_buf, err_cap, "Invalid runtime");
        return -1;
    }
    JS_UpdateStackTop(brt->rt);
    brt->step_count = 0;

    JSValue global_obj = JS_GetGlobalObject(brt->ctx);
    JSValue fn = JS_GetPropertyStr(brt->ctx, global_obj, "__qjs_invoke_cb");
    if (!JS_IsFunction(brt->ctx, fn)) {
        JS_FreeValue(brt->ctx, fn);
        JS_FreeValue(brt->ctx, global_obj);
        copy_cstr_bounded(err_buf, err_cap, "Missing __qjs_invoke_cb dispatcher");
        return -1;
    }

    JSValue argv[2];
    argv[0] = JS_NewInt32(brt->ctx, cb_id);
    argv[1] = arg0 ? JS_NewString(brt->ctx, arg0) : JS_UNDEFINED;
    JSValue res = JS_Call(brt->ctx, fn, global_obj, 2, argv);
    JS_FreeValue(brt->ctx, argv[0]);
    JS_FreeValue(brt->ctx, argv[1]);
    JS_FreeValue(brt->ctx, fn);
    JS_FreeValue(brt->ctx, global_obj);

    if (JS_IsException(res)) {
        capture_js_exception(brt->ctx, err_buf, err_cap);
        JS_FreeValue(brt->ctx, res);
        return -1;
    }
    if (!JS_IsUndefined(res) && !JS_IsNull(res) && out_buf && out_cap > 0) {
        const char* res_str = JS_ToCString(brt->ctx, res);
        if (res_str) {
            copy_cstr_bounded(out_buf, out_cap, res_str);
            JS_FreeCString(brt->ctx, res_str);
        }
    }
    JS_FreeValue(brt->ctx, res);

    if (drain_pending_jobs(brt, err_buf, err_cap) != 0) {
        return -1;
    }
    return 0;
}
