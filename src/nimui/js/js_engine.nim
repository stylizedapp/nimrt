## src/nimui/js/js_engine.nim
##
## Safe, Explicit QuickJS Engine Wrapper for NimUI:
## - Routes 100% of QuickJS heap allocations through `corex/allocators.Allocator`
##   so `TrackingAllocator` verifies 0 bytes leaked.
## - Enforces Rust-Safety (memory limit, stack limit, instruction step interrupt,
##   strict mode, static AST/token validator).
## - Enforces Zig-Explicitness (explicit capability permissions, explicit budgets,
##   exception-free Result[T, string] API with `{.raises: [].}`).
## - Provides Python-Simplicity `ui.*` & `Nim.*` prelude alongside DOM & timers.

import std/[os, strutils]
import corex/allocators
import corex/result
import corex/adt
import ./js_validator

const
  qjsDir = currentSourcePath().parentDir().replace('\\', '/')
  qjsLibPath = qjsDir & "/libquickjs.a"

{.passL: qjsLibPath.}
{.passL: "-lm".}

type
  QjsAllocFn = proc(ctx: pointer, size: csize_t, align: csize_t): pointer {.cdecl, gcsafe, raises: [].}
  QjsFreeFn = proc(ctx: pointer, p: pointer, size: csize_t) {.cdecl, gcsafe, raises: [].}
  QjsHostCbFn = proc(
    userData: pointer,
    op: int32,
    a0, a1, a2: cstring,
    outBuf: cstring,
    outCap: int32
  ): int32 {.cdecl, gcsafe, raises: [].}

  QjsBridgeRuntimePtr = pointer

# Safe: C FFI bindings to vendored QuickJS bridge (qjs_bridge.c).
proc qjs_bridge_new(
  allocFn: QjsAllocFn,
  freeFn: QjsFreeFn,
  allocCtx: pointer,
  memLimit: csize_t,
  maxStack: csize_t,
  maxSteps: uint64,
  hostCb: QjsHostCbFn,
  hostUserData: pointer
): QjsBridgeRuntimePtr {.trustedUnsafe, importc, cdecl.}

proc qjs_bridge_free(brt: QjsBridgeRuntimePtr) {.trustedUnsafe, importc, cdecl.}
proc qjs_bridge_set_host(brt: QjsBridgeRuntimePtr, hostCb: QjsHostCbFn, hostUserData: pointer) {.trustedUnsafe, importc, cdecl.}
proc qjs_bridge_reset_steps(brt: QjsBridgeRuntimePtr, maxSteps: uint64) {.trustedUnsafe, importc, cdecl.}
proc qjs_bridge_get_malloc_size(brt: QjsBridgeRuntimePtr): csize_t {.trustedUnsafe, importc, cdecl.}
proc qjs_bridge_get_malloc_count(brt: QjsBridgeRuntimePtr): csize_t {.trustedUnsafe, importc, cdecl.}
proc qjs_bridge_run_gc(brt: QjsBridgeRuntimePtr) {.trustedUnsafe, importc, cdecl.}

proc qjs_bridge_eval(
  brt: QjsBridgeRuntimePtr,
  code: cstring,
  codeLen: csize_t,
  filename: cstring,
  outBuf: cstring,
  outCap: int32,
  errBuf: cstring,
  errCap: int32
): int32 {.trustedUnsafe, importc, cdecl.}

proc qjs_bridge_invoke_cb(
  brt: QjsBridgeRuntimePtr,
  cbId: int32,
  arg0: cstring,
  outBuf: cstring,
  outCap: int32,
  errBuf: cstring,
  errCap: int32
): int32 {.trustedUnsafe, importc, cdecl.}

const
  OpDomGetText* = 1'i32
  OpDomSetText* = 2'i32
  OpDomGetVal* = 3'i32
  OpDomSetVal* = 4'i32
  OpDomSetStyle* = 5'i32
  OpDomGetStyle* = 6'i32
  OpDomAddListener* = 7'i32
  OpTimerSet* = 8'i32
  OpTimerClear* = 9'i32
  OpNimCall* = 10'i32
  OpNimSigGet* = 11'i32
  OpNimSigSet* = 12'i32
  OpConsoleLog* = 13'i32

type
  JsTimerEntry* = object
    id*: int32
    intervalMs*: int
    remainingMs*: int
    repeat*: bool
    active*: bool
    cbId*: int32

  JsHostDispatchProc* = proc(
    op: int32,
    a0, a1, a2: string,
    errMsg: var string
  ): string {.closure, gcsafe, raises: [].}

  QjsHostEnvelope = object
    handler: JsHostDispatchProc

  QuickJsConfig* = object
    memLimitBytes*: int
    maxStackBytes*: int
    maxStepsPerCall*: uint64
    validation*: JsValidationConfig

  QuickJsEngine* = object
    alloc*: Allocator
    allocBox: ptr Allocator
    hostBox: ptr QjsHostEnvelope
    brt*: QjsBridgeRuntimePtr
    config*: QuickJsConfig
    timers*: seq[JsTimerEntry]
    nextTimerId: int32
    initialized*: bool

proc defaultQuickJsConfig*(
  caps: JsCapabilities = {jcDom, jcTimers, jcNimBridge, jcConsole}
): QuickJsConfig {.inline, raises: [].} =
  QuickJsConfig(
    memLimitBytes: 8 * 1024 * 1024,
    maxStackBytes: 512 * 1024,
    maxStepsPerCall: 250_000'u64,
    validation: defaultJsValidationConfig(caps)
  )

# Safe: ctx is nil-checked and points to QuickJsEngine.allocBox owned by the engine.
proc qjsNimAllocTrampoline(ctx: pointer, size: csize_t, align: csize_t): pointer {.trustedUnsafe, cdecl, gcsafe, raises: [].} =
  if ctx.isNil: return nil
  let allocPtr = cast[ptr Allocator](ctx)
  let res = allocPtr[].rawAlloc(int(size), int(align))
  if res.isOk():
    res.get()
  else:
    nil

# Safe: ctx and p are nil-checked; delegates to QuickJsEngine.allocBox.dealloc.
proc qjsNimFreeTrampoline(ctx: pointer, p: pointer, size: csize_t) {.trustedUnsafe, cdecl, gcsafe, raises: [].} =
  if ctx.isNil or p.isNil: return
  let allocPtr = cast[ptr Allocator](ctx)
  allocPtr[].dealloc(p, int(size))

# Safe: dst is nil-checked and writes at most cap-1 bytes plus NUL terminator.
proc writeCStringBuffer(dst: cstring, cap: int32, src: string) {.trustedUnsafe, raises: [].} =
  if dst.isNil or cap <= 0:
    return
  let buf = cast[ptr UncheckedArray[char]](dst)
  let copyLen = min(src.len, int(cap) - 1)
  for i in 0 ..< copyLen:
    buf[i] = src[i]
  buf[copyLen] = '\0'

# Safe: userData is nil-checked and points to QuickJsEngine.hostBox owned by the engine.
proc qjsHostTrampoline(
  userData: pointer,
  op: int32,
  a0, a1, a2: cstring,
  outBuf: cstring,
  outCap: int32
): int32 {.trustedUnsafe, cdecl, gcsafe, raises: [].} =
  if userData.isNil:
    writeCStringBuffer(outBuf, outCap, "")
    return 0'i32
  let env = cast[ptr QjsHostEnvelope](userData)
  if env.handler.isNil:
    writeCStringBuffer(outBuf, outCap, "")
    return 0'i32
  let s0 = if a0.isNil: "" else: $a0
  let s1 = if a1.isNil: "" else: $a1
  let s2 = if a2.isNil: "" else: $a2
  var errMsg = ""
  let resStr = env.handler(op, s0, s1, s2, errMsg)
  if errMsg.len > 0:
    writeCStringBuffer(outBuf, outCap, errMsg)
    return -1'i32
  writeCStringBuffer(outBuf, outCap, resStr)
  0'i32

const
  JsPreludeSource = """
"use strict";
globalThis.eval = function() {
  throw new Error("Rust-Safety Violation: dynamic eval() is disabled at runtime");
};
const __qjs_callbacks = {};
let __qjs_next_cb = 1;
function __qjs_reg_cb(fn) {
  if (typeof fn !== "function") {
    throw new TypeError("Expected callback function");
  }
  const id = __qjs_next_cb++;
  __qjs_callbacks[id] = fn;
  return id;
}
function __qjs_invoke_cb(id, arg) {
  const fn = __qjs_callbacks[id];
  if (typeof fn === "function") {
    return fn(arg);
  }
  return undefined;
}
function __qjs_del_cb(id) {
  delete __qjs_callbacks[id];
}
function __qjs_clear_all_cbs() {
  for (const k of Object.keys(__qjs_callbacks)) {
    delete __qjs_callbacks[k];
  }
}
const console = {
  log: function(...args) { __nim_host(13, "log", args.map(String).join(" "), ""); },
  warn: function(...args) { __nim_host(13, "warn", args.map(String).join(" "), ""); },
  error: function(...args) { __nim_host(13, "error", args.map(String).join(" "), ""); }
};
function setTimeout(fn, ms) {
  const cbId = __qjs_reg_cb(fn);
  const delay = ms === undefined ? 0 : Number(ms);
  const tid = __nim_host(8, String(delay), "0", String(cbId));
  return Number(tid);
}
function setInterval(fn, ms) {
  const cbId = __qjs_reg_cb(fn);
  const delay = ms === undefined ? 0 : Number(ms);
  const tid = __nim_host(8, String(delay), "1", String(cbId));
  return Number(tid);
}
function clearTimeout(id) {
  __nim_host(9, String(id), "", "");
}
function clearInterval(id) {
  __nim_host(9, String(id), "", "");
}
function __nim_wrap_el(id) {
  const cleanId = id.startsWith("#") ? id.slice(1) : id;
  const styleProxy = {
    get backgroundColor() { return __nim_host(6, cleanId, "backgroundColor", ""); },
    set backgroundColor(v) { __nim_host(5, cleanId, "backgroundColor", String(v)); },
    get background() { return __nim_host(6, cleanId, "background", ""); },
    set background(v) { __nim_host(5, cleanId, "background", String(v)); },
    get color() { return __nim_host(6, cleanId, "color", ""); },
    set color(v) { __nim_host(5, cleanId, "color", String(v)); },
    get borderColor() { return __nim_host(6, cleanId, "borderColor", ""); },
    set borderColor(v) { __nim_host(5, cleanId, "borderColor", String(v)); },
    get borderRadius() { return __nim_host(6, cleanId, "borderRadius", ""); },
    set borderRadius(v) { __nim_host(5, cleanId, "borderRadius", String(v)); },
    get display() { return __nim_host(6, cleanId, "display", ""); },
    set display(v) { __nim_host(5, cleanId, "display", String(v)); }
  };
  return {
    id: cleanId,
    style: styleProxy,
    get textContent() { return __nim_host(1, cleanId, "", ""); },
    set textContent(v) { __nim_host(2, cleanId, String(v), ""); },
    get innerText() { return __nim_host(1, cleanId, "", ""); },
    set innerText(v) { __nim_host(2, cleanId, String(v), ""); },
    get value() { return __nim_host(3, cleanId, "", ""); },
    set value(v) { __nim_host(4, cleanId, String(v), ""); },
    addEventListener: function(ev, fn) {
      const cbId = __qjs_reg_cb(fn);
      __nim_host(7, cleanId, String(ev), String(cbId));
    },
    on: function(ev, fn) {
      const cbId = __qjs_reg_cb(fn);
      __nim_host(7, cleanId, String(ev), String(cbId));
      return this;
    },
    text: function(v) {
      if (v === undefined) return __nim_host(1, cleanId, "", "");
      __nim_host(2, cleanId, String(v), "");
      return this;
    },
    val: function(v) {
      if (v === undefined) return __nim_host(3, cleanId, "", "");
      __nim_host(4, cleanId, String(v), "");
      return this;
    },
    bg: function(v) { __nim_host(5, cleanId, "backgroundColor", String(v)); return this; },
    color: function(v) { __nim_host(5, cleanId, "color", String(v)); return this; },
    border: function(v) { __nim_host(5, cleanId, "borderColor", String(v)); return this; },
    show: function() { __nim_host(5, cleanId, "display", "flex"); return this; },
    hide: function() { __nim_host(5, cleanId, "display", "none"); return this; }
  };
}
const document = {
  getElementById: function(id) { return __nim_wrap_el(String(id)); },
  querySelector: function(sel) { return __nim_wrap_el(String(sel)); }
};
const ui = {
  get: function(id) { return __nim_wrap_el(String(id)); },
  text: function(id, v) {
    if (v === undefined) return __nim_host(1, String(id), "", "");
    __nim_host(2, String(id), String(v), "");
    return undefined;
  },
  val: function(id, v) {
    if (v === undefined) return __nim_host(3, String(id), "", "");
    __nim_host(4, String(id), String(v), "");
    return undefined;
  },
  style: function(id, prop, v) { __nim_host(5, String(id), String(prop), String(v)); },
  on: function(id, ev, fn) {
    const cbId = __qjs_reg_cb(fn);
    __nim_host(7, String(id), String(ev), String(cbId));
  }
};
const Nim = {
  call: function(name, arg1, arg2) {
    return __nim_host(10, String(name), arg1 === undefined ? "" : String(arg1), arg2 === undefined ? "" : String(arg2));
  },
  get: function(sigName) { return __nim_host(11, String(sigName), "", ""); },
  set: function(sigName, val) { __nim_host(12, String(sigName), String(val), ""); }
};
"""

# Safe: brt is an owned QjsBridgeRuntimePtr; outBuf/errBuf are sized stack-owned strings.
proc evalRawInternal(
  brt: QjsBridgeRuntimePtr,
  code: string,
  filename: string
): Result[string, string] {.trustedUnsafe, raises: [].} =
  var outBuf = newString(4096)
  var errBuf = newString(2048)
  let cCode = if code.len > 0: code.cstring else: "".cstring
  let rc = qjs_bridge_eval(
    brt,
    cCode,
    csize_t(code.len),
    filename.cstring,
    outBuf.cstring,
    int32(outBuf.len),
    errBuf.cstring,
    int32(errBuf.len)
  )
  if rc != 0:
    let errLen = errBuf.cstring.len
    let msg = if errLen > 0: errBuf[0 ..< errLen] else: "QuickJS execution failed"
    return err[string, string](msg)
  let outLen = outBuf.cstring.len
  ok[string, string](if outLen > 0: outBuf[0 ..< outLen] else: "")

# Safe: brt is an owned QjsBridgeRuntimePtr forwarded to evalRawInternal.
proc evalCleanupInternal(
  brt: QjsBridgeRuntimePtr,
  code: string,
  filename: string
) {.trustedUnsafe, raises: [].} =
  let res = evalRawInternal(brt, code, filename)
  if res.isErr():
    return

# Safe: hostBox and brt are nil-checked and owned by QuickJsEngine.
proc setHostHandler*(eng: var QuickJsEngine, handler: JsHostDispatchProc) {.trustedUnsafe, raises: [].} =
  if not eng.hostBox.isNil:
    eng.hostBox.handler = handler
    if not eng.brt.isNil:
      qjs_bridge_set_host(eng.brt, qjsHostTrampoline, eng.hostBox)

# Safe: frees owned QuickJS runtime, hostBox, and allocBox in reverse init order with nil guards.
proc destroy*(eng: var QuickJsEngine) {.trustedUnsafe, raises: [].} =
  if not eng.brt.isNil:
    evalCleanupInternal(eng.brt, "__qjs_clear_all_cbs();", "<cleanup>")
    qjs_bridge_free(eng.brt)
    eng.brt = nil
  if not eng.hostBox.isNil:
    reset(eng.hostBox.handler)
    eng.alloc.dealloc(eng.hostBox, sizeof(QjsHostEnvelope))
    eng.hostBox = nil
  if not eng.allocBox.isNil:
    eng.alloc.dealloc(eng.allocBox, sizeof(Allocator))
    eng.allocBox = nil
  eng.timers.setLen(0)
  eng.initialized = false

# Safe: allocates owned allocBox/hostBox/brt and cleans up on any allocation/init failure.
proc initQuickJsEngine*(
  alloc: Allocator,
  cfg: QuickJsConfig = defaultQuickJsConfig()
): Result[QuickJsEngine, string] {.trustedUnsafe, raises: [].} =
  let allocBoxRes = alloc.create(alloc)
  if allocBoxRes.isErr():
    return err[QuickJsEngine, string]("OutOfMemory allocating QuickJS Allocator box")
  let allocBox = allocBoxRes.get()

  let hostBoxRes = alloc.create(QjsHostEnvelope(handler: nil))
  if hostBoxRes.isErr():
    alloc.dealloc(allocBox, sizeof(Allocator))
    return err[QuickJsEngine, string]("OutOfMemory allocating QuickJS HostEnvelope")
  let hostBox = hostBoxRes.get()

  let brt = qjs_bridge_new(
    qjsNimAllocTrampoline,
    qjsNimFreeTrampoline,
    allocBox,
    csize_t(max(0, cfg.memLimitBytes)),
    csize_t(max(0, cfg.maxStackBytes)),
    cfg.maxStepsPerCall,
    qjsHostTrampoline,
    hostBox
  )
  if brt.isNil:
    alloc.dealloc(hostBox, sizeof(QjsHostEnvelope))
    alloc.dealloc(allocBox, sizeof(Allocator))
    return err[QuickJsEngine, string]("Failed to initialize QuickJS runtime")

  let preludeRes = evalRawInternal(brt, JsPreludeSource, "<nimui-prelude>")
  if preludeRes.isErr():
    qjs_bridge_free(brt)
    alloc.dealloc(hostBox, sizeof(QjsHostEnvelope))
    alloc.dealloc(allocBox, sizeof(Allocator))
    return err[QuickJsEngine, string]("Failed to load QuickJS prelude: " & preludeRes.error())

  ok[QuickJsEngine, string](QuickJsEngine(
    alloc: alloc,
    allocBox: allocBox,
    hostBox: hostBox,
    brt: brt,
    config: cfg,
    timers: @[],
    nextTimerId: 1'i32,
    initialized: true
  ))

proc evalValidated*(
  eng: var QuickJsEngine,
  code: string,
  filename: string = "<script>",
  capsOverride: Option[JsCapabilities] = none[JsCapabilities]()
): Result[string, string] {.raises: [].} =
  if not eng.initialized or eng.brt.isNil:
    return err[string, string]("QuickJsEngine is not initialized")

  var valCfg = eng.config.validation
  if capsOverride.isSome:
    valCfg.allowedCaps = capsOverride.get()
  let valRes = validateJsPhilosophy(code, valCfg)
  if valRes.isErr():
    return err[string, string](valRes.error())

  qjs_bridge_reset_steps(eng.brt, eng.config.maxStepsPerCall)
  evalRawInternal(eng.brt, code, filename)

proc invokeCallback*(
  eng: var QuickJsEngine,
  cbId: int32,
  arg0: string = ""
): Result[string, string] {.raises: [].} =
  if not eng.initialized or eng.brt.isNil:
    return err[string, string]("QuickJsEngine is not initialized")
  qjs_bridge_reset_steps(eng.brt, eng.config.maxStepsPerCall)
  var outBuf = newString(4096)
  var errBuf = newString(2048)
  let cArg = if arg0.len > 0: arg0.cstring else: nil
  let rc = qjs_bridge_invoke_cb(
    eng.brt,
    cbId,
    cArg,
    outBuf.cstring,
    int32(outBuf.len),
    errBuf.cstring,
    int32(errBuf.len)
  )
  if rc != 0:
    let errLen = errBuf.cstring.len
    let msg = if errLen > 0: errBuf[0 ..< errLen] else: "QuickJS callback failed"
    return err[string, string](msg)
  let outLen = outBuf.cstring.len
  ok[string, string](if outLen > 0: outBuf[0 ..< outLen] else: "")

proc registerTimer*(
  eng: var QuickJsEngine,
  delayMs: int,
  repeat: bool,
  cbId: int32
): int32 {.raises: [].} =
  let tid = eng.nextTimerId
  inc eng.nextTimerId
  let clampedMs = if delayMs < 1: 1 else: delayMs
  eng.timers.add(JsTimerEntry(
    id: tid,
    intervalMs: clampedMs,
    remainingMs: clampedMs,
    repeat: repeat,
    active: true,
    cbId: cbId
  ))
  tid

proc clearTimer*(eng: var QuickJsEngine, tid: int32) {.raises: [].} =
  for i in 0 ..< eng.timers.len:
    if eng.timers[i].id == tid and eng.timers[i].active:
      eng.timers[i].active = false
      evalCleanupInternal(eng.brt, "__qjs_del_cb(" & $eng.timers[i].cbId & ");", "<timer-gc>")
      break

proc hasActiveTimers*(eng: QuickJsEngine): bool {.inline, raises: [].} =
  for t in eng.timers:
    if t.active:
      return true
  false

proc tickTimers*(eng: var QuickJsEngine, dtMs: int): Result[int, string] {.raises: [].} =
  if not eng.initialized or eng.brt.isNil or dtMs <= 0:
    return ok[int, string](0)

  var fired = 0
  # Snapshot length so timers added during callbacks run on subsequent ticks
  let n = eng.timers.len
  for i in 0 ..< n:
    if i >= eng.timers.len:
      break
    if not eng.timers[i].active:
      continue
    eng.timers[i].remainingMs -= dtMs
    if eng.timers[i].remainingMs <= 0:
      let cbId = eng.timers[i].cbId
      let isRepeat = eng.timers[i].repeat
      if isRepeat:
        let iv = eng.timers[i].intervalMs
        while eng.timers[i].remainingMs <= 0:
          eng.timers[i].remainingMs += iv
      else:
        eng.timers[i].active = false

      let invRes = eng.invokeCallback(cbId)
      if not isRepeat and eng.initialized and not eng.brt.isNil:
        evalCleanupInternal(eng.brt, "__qjs_del_cb(" & $cbId & ");", "<timer-gc>")
      if invRes.isErr():
        return err[int, string](invRes.error())
      inc fired

  # Compact inactive timers
  var writeIdx = 0
  for readIdx in 0 ..< eng.timers.len:
    if eng.timers[readIdx].active:
      if writeIdx != readIdx:
        eng.timers[writeIdx] = eng.timers[readIdx]
      inc writeIdx
  if writeIdx < eng.timers.len:
    eng.timers.setLen(writeIdx)

  ok[int, string](fired)

proc activeMallocBytes*(eng: QuickJsEngine): int {.inline, raises: [].} =
  if eng.brt.isNil: return 0
  int(qjs_bridge_get_malloc_size(eng.brt))

proc activeMallocCount*(eng: QuickJsEngine): int {.inline, raises: [].} =
  if eng.brt.isNil: return 0
  int(qjs_bridge_get_malloc_count(eng.brt))

proc runGc*(eng: var QuickJsEngine) {.inline, raises: [].} =
  if not eng.brt.isNil:
    qjs_bridge_run_gc(eng.brt)
