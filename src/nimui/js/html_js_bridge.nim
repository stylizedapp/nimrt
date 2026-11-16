## src/nimui/js/html_js_bridge.nim
##
## Hybrid Nim + QuickJS Bridge for NimUI HTML5/CSS3 Engine:
## - Allows writing UI logic in Pure Nim (`HtmlBindingRegistry`, `Signal[T]`),
##   in philosophy-checked QuickJS JavaScript, or both simultaneously.
## - Preserves Zero-Leak guarantees (`TrackingAllocator` = 0 bytes leaked).
## - Enforces Zig-Explicitness (capability permissions per `<script data-caps="...">`),
##   Rust-Safety (strict JS validator + runtime limits), and Python-Simplicity (`ui.*`/`Nim.*`).

import std/strutils
import corex/allocators
import corex/result
import corex/adt
import corex/slab
import corex/smallvec
import corex/signals
import algx/swissmap
import ../layout
import ../html_css
import ./js_validator
import ./js_engine

type
  NimJsHostProc* = proc(arg1, arg2: string): string {.closure, gcsafe, raises: [].}

  SavedNodeVisual = object
    saved: bool
    widthMode: SizeMode
    heightMode: SizeMode
    bgColor: uint32
    borderColor: uint32

  HtmlJsCore* = object
    alloc*: Allocator
    active*: bool
    engine*: QuickJsEngine
    treePtr*: ptr UiTree
    rtPtr*: ptr ReactiveRuntime
    bindingsPtr*: ptr HtmlBindingRegistry
    nimFuncs*: FastMap[string, NimJsHostProc]
    savedHidden*: FastMap[int32, SavedNodeVisual]
    consoleLogs*: seq[string]
    lastJsError*: string

  HtmlJsSession* = object
    core*: ptr HtmlJsCore

proc resolveTextSlab*(tree: var UiTree, slab: SlabId, createIfMissing: bool): SlabId {.raises: [].} =
  if not tree.nodes.contains(slab):
    return SlabId(-1'i32)
  let k = tree.nodes[slab].kind
  if k == nkText or k == nkButton or k == nkTextInput:
    return slab
  let childCount = tree.nodes[slab].children.len
  for i in 0 ..< childCount:
    let cid = tree.nodes[slab].children[i]
    if tree.nodes.contains(cid) and tree.nodes[cid].kind == nkText:
      return cid
  if createIfMissing:
    let txtSlab = tree.createNode(nkText)
    tree.nodes[txtSlab].textColor = tree.nodes[slab].textColor
    tree.nodes[txtSlab].fontSize = tree.nodes[slab].fontSize
    tree.nodes[txtSlab].widthMode = fitContent()
    tree.nodes[txtSlab].heightMode = fitContent()
    tree.addChild(slab, txtSlab)
    return txtSlab
  SlabId(-1'i32)

# Safe: core/treePtr are nil- and active-checked before deref; owned by HtmlJsSession.
proc getElementText*(core: ptr HtmlJsCore, id: string): string {.trustedUnsafe, raises: [].} =
  if core.isNil or core.treePtr.isNil or core.bindingsPtr.isNil:
    return ""
  let opt = core.bindingsPtr[].getNodeById(id)
  if opt.isNone():
    return ""
  let slab = opt.get()
  let txtSlab = resolveTextSlab(core.treePtr[], slab, createIfMissing = false)
  if txtSlab == SlabId(-1'i32) or not core.treePtr[].nodes.contains(txtSlab):
    return ""
  core.treePtr[].nodes[txtSlab].text

proc getElementText*(s: HtmlJsSession, id: string): string {.raises: [].} =
  getElementText(s.core, id)

# Safe: core/treePtr are nil- and active-checked before deref; owned by HtmlJsSession.
proc setElementText*(core: ptr HtmlJsCore, id, txt: string) {.trustedUnsafe, raises: [].} =
  if core.isNil or core.treePtr.isNil or core.bindingsPtr.isNil:
    return
  let opt = core.bindingsPtr[].getNodeById(id)
  if opt.isNone():
    return
  let slab = opt.get()
  let txtSlab = resolveTextSlab(core.treePtr[], slab, createIfMissing = true)
  if txtSlab == SlabId(-1'i32) or not core.treePtr[].nodes.contains(txtSlab):
    return
  if core.treePtr[].nodes[txtSlab].text != txt:
    core.treePtr[].nodes[txtSlab].text = txt
    core.treePtr[].nodes[txtSlab].isDirty = true
    core.treePtr[].nodes[txtSlab].isLayoutDirty = true
    core.treePtr[].isDirty = true
    core.treePtr[].isLayoutDirty = true

proc setElementText*(s: HtmlJsSession, id, txt: string) {.raises: [].} =
  setElementText(s.core, id, txt)

# Safe: core/treePtr are nil- and active-checked before deref; owned by HtmlJsSession.
proc setElementStyleProp(core: ptr HtmlJsCore, id, prop, val: string) {.trustedUnsafe, raises: [].} =
  if core.isNil or core.treePtr.isNil or core.bindingsPtr.isNil:
    return
  let opt = core.bindingsPtr[].getNodeById(id)
  if opt.isNone():
    return
  let slab = opt.get()
  if not core.treePtr[].nodes.contains(slab):
    return
  let lowProp = toLowerAscii(prop)
  let lowVal = toLowerAscii(val.strip())

  case lowProp
  of "backgroundcolor", "background-color", "background":
    let c = parseCssColor(val)
    if c.isSome():
      core.treePtr[].nodes[slab].bgColor = c.get()
      core.treePtr[].nodes[slab].isDirty = true
      core.treePtr[].isDirty = true
  of "color":
    let c = parseCssColor(val)
    if c.isSome():
      let col = c.get()
      core.treePtr[].nodes[slab].textColor = col
      let txtSlab = resolveTextSlab(core.treePtr[], slab, createIfMissing = false)
      if txtSlab != SlabId(-1'i32) and core.treePtr[].nodes.contains(txtSlab):
        core.treePtr[].nodes[txtSlab].textColor = col
        core.treePtr[].nodes[txtSlab].isDirty = true
      core.treePtr[].nodes[slab].isDirty = true
      core.treePtr[].isDirty = true
  of "bordercolor", "border-color":
    let c = parseCssColor(val)
    if c.isSome():
      core.treePtr[].nodes[slab].borderColor = c.get()
      core.treePtr[].nodes[slab].isDirty = true
      core.treePtr[].isDirty = true
  of "borderradius", "border-radius":
    let r = parseCssLength(val)
    if r.isSome():
      core.treePtr[].nodes[slab].radius = r.get()
      core.treePtr[].nodes[slab].isDirty = true
      core.treePtr[].isDirty = true
  of "display":
    let key = int32(slab)
    if lowVal == "none":
      if not core.savedHidden.contains(key):
        core.savedHidden.put(key, SavedNodeVisual(
          saved: true,
          widthMode: core.treePtr[].nodes[slab].widthMode,
          heightMode: core.treePtr[].nodes[slab].heightMode,
          bgColor: core.treePtr[].nodes[slab].bgColor,
          borderColor: core.treePtr[].nodes[slab].borderColor
        ))
      core.treePtr[].nodes[slab].widthMode = fixed(0.0'f32)
      core.treePtr[].nodes[slab].heightMode = fixed(0.0'f32)
      core.treePtr[].nodes[slab].bgColor = 0'u32
      core.treePtr[].nodes[slab].borderColor = 0'u32
      core.treePtr[].isLayoutDirty = true
      core.treePtr[].isDirty = true
    else:
      if core.savedHidden.contains(key):
        let prev = core.savedHidden.getOrDefault(key)
        if prev.saved:
          core.treePtr[].nodes[slab].widthMode = prev.widthMode
          core.treePtr[].nodes[slab].heightMode = prev.heightMode
          core.treePtr[].nodes[slab].bgColor = prev.bgColor
          core.treePtr[].nodes[slab].borderColor = prev.borderColor
        discard core.savedHidden.del(key)
        core.treePtr[].isLayoutDirty = true
        core.treePtr[].isDirty = true
  else:
    discard

# Safe: core/treePtr are nil- and active-checked before deref; owned by HtmlJsSession.
proc getElementStyleProp(core: ptr HtmlJsCore, id, prop: string): string {.trustedUnsafe, raises: [].} =
  if core.isNil or core.treePtr.isNil or core.bindingsPtr.isNil:
    return ""
  let opt = core.bindingsPtr[].getNodeById(id)
  if opt.isNone():
    return ""
  let slab = opt.get()
  if not core.treePtr[].nodes.contains(slab):
    return ""
  case toLowerAscii(prop)
  of "display":
    if core.savedHidden.contains(int32(slab)): "none" else: "flex"
  else:
    ""

# Safe: core/treePtr are nil- and active-checked before deref; owned by HtmlJsSession.
proc attachJsListener(core: ptr HtmlJsCore, id, evName: string, cbId: int32) {.trustedUnsafe, raises: [].} =
  if core.isNil or core.treePtr.isNil or core.bindingsPtr.isNil:
    return
  let opt = core.bindingsPtr[].getNodeById(id)
  if opt.isNone():
    return
  let slab = opt.get()
  if not core.treePtr[].nodes.contains(slab):
    return

  let lowEv = toLowerAscii(evName)
  if lowEv == "click":
    let prevClick = core.treePtr[].nodes[slab].onClick
    let newClick: HtmlClickProc = proc() {.closure, gcsafe, raises: [].} =
      if not prevClick.isNil:
        prevClick()
      if not core.isNil and core.active:
        let res = core.engine.invokeCallback(cbId)
        if res.isErr():
          core.lastJsError = res.error()
    core.treePtr[].nodes[slab].onClick = newClick
    propagateOnClickRecursive(core.treePtr[], slab, newClick)
  elif lowEv == "input":
    let prevInput = core.treePtr[].nodes[slab].onInput
    let newInput: HtmlInputProc = proc(txt: string) {.closure, gcsafe, raises: [].} =
      if not prevInput.isNil:
        prevInput(txt)
      if not core.isNil and core.active:
        let res = core.engine.invokeCallback(cbId, txt)
        if res.isErr():
          core.lastJsError = res.error()
    core.treePtr[].nodes[slab].onInput = newInput

proc parseInt32Safe(s: string): int32 {.raises: [].} =
  var acc = 0'i32
  var neg = false
  var idx = 0
  if idx < s.len and s[idx] == '-':
    neg = true
    inc idx
  while idx < s.len and s[idx] >= '0' and s[idx] <= '9':
    let d = int32(ord(s[idx]) - ord('0'))
    if acc <= (high(int32) - d) div 10'i32:
      acc = acc * 10'i32 + d
    inc idx
  if neg: -acc else: acc

# Safe: core is nil- and active-checked inside the returned QuickJS host dispatcher closure.
proc makeHostDispatcher(core: ptr HtmlJsCore): JsHostDispatchProc {.trustedUnsafe, raises: [].} =
  result = proc(op: int32, a0, a1, a2: string, errMsg: var string): string {.closure, gcsafe, raises: [].} =
    if core.isNil or not core.active:
      return ""
    let caps = core.engine.config.validation.allowedCaps
    case op
    of OpDomGetText, OpDomGetVal:
      if core.engine.config.validation.requireExplicitCaps and jcDom notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z03]: DOM read denied without 'dom' capability"
        return ""
      return core.getElementText(a0)
    of OpDomSetText, OpDomSetVal:
      if core.engine.config.validation.requireExplicitCaps and jcDom notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z03]: DOM write denied without 'dom' capability"
        return ""
      core.setElementText(a0, a1)
      return ""
    of OpDomSetStyle:
      if core.engine.config.validation.requireExplicitCaps and jcDom notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z03]: DOM style denied without 'dom' capability"
        return ""
      core.setElementStyleProp(a0, a1, a2)
      return ""
    of OpDomGetStyle:
      if core.engine.config.validation.requireExplicitCaps and jcDom notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z03]: DOM style read denied without 'dom' capability"
        return ""
      return core.getElementStyleProp(a0, a1)
    of OpDomAddListener:
      if core.engine.config.validation.requireExplicitCaps and jcDom notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z03]: DOM listener denied without 'dom' capability"
        return ""
      let cbId = parseInt32Safe(a2)
      core.attachJsListener(a0, a1, cbId)
      return ""
    of OpTimerSet:
      if core.engine.config.validation.requireExplicitCaps and jcTimers notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z01]: Timer registration denied without 'timers' capability"
        return ""
      let delayMs = int(parseInt32Safe(a0))
      let repeat = (a1 == "1")
      let cbId = parseInt32Safe(a2)
      let tid = core.engine.registerTimer(delayMs, repeat, cbId)
      return $tid
    of OpTimerClear:
      if core.engine.config.validation.requireExplicitCaps and jcTimers notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z01]: Timer clear denied without 'timers' capability"
        return ""
      let tid = parseInt32Safe(a0)
      core.engine.clearTimer(tid)
      return ""
    of OpNimCall:
      if core.engine.config.validation.requireExplicitCaps and jcNimBridge notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z02]: Nim.call denied without 'nim' capability"
        return ""
      if core.nimFuncs.contains(a0):
        let fn = core.nimFuncs.getOrDefault(a0)
        if not fn.isNil:
          return fn(a1, a2)
      errMsg = "Nim host function not registered: '" & a0 & "'"
      return ""
    of OpNimSigGet:
      if core.engine.config.validation.requireExplicitCaps and jcNimBridge notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z02]: Nim.get denied without 'nim' capability"
        return ""
      if not core.bindingsPtr.isNil:
        if core.bindingsPtr[].textSignals.contains(a0):
          return core.bindingsPtr[].textSignals.getOrDefault(a0).get()
        elif core.bindingsPtr[].inputSignals.contains(a0):
          return core.bindingsPtr[].inputSignals.getOrDefault(a0).get()
      return ""
    of OpNimSigSet:
      if core.engine.config.validation.requireExplicitCaps and jcNimBridge notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z02]: Nim.set denied without 'nim' capability"
        return ""
      if not core.bindingsPtr.isNil:
        if core.bindingsPtr[].textSignals.contains(a0):
          core.bindingsPtr[].textSignals.getOrDefault(a0).set(a1)
        elif core.bindingsPtr[].inputSignals.contains(a0):
          core.bindingsPtr[].inputSignals.getOrDefault(a0).set(a1)
      return ""
    of OpConsoleLog:
      if core.engine.config.validation.requireExplicitCaps and jcConsole notin caps:
        errMsg = "Zig-Explicitness Violation [JS-Z04]: console denied without 'console' capability"
        return ""
      core.consoleLogs.add("[" & a0 & "] " & a1)
      return ""
    else:
      return ""

# Safe: allocates owned HtmlJsCore storing non-owning pointers to caller-owned tree/rt/bindings.
proc initHtmlJsSession*(
  alloc: Allocator,
  tree: var UiTree,
  rt: var ReactiveRuntime,
  bindings: var HtmlBindingRegistry,
  cfg: QuickJsConfig = defaultQuickJsConfig()
): Result[HtmlJsSession, string] {.trustedUnsafe, raises: [].} =
  var engRes = initQuickJsEngine(alloc, cfg)
  if engRes.isErr():
    return err[HtmlJsSession, string](engRes.error())

  let coreVal = HtmlJsCore(
    alloc: alloc,
    active: true,
    engine: engRes.get(),
    treePtr: addr tree,
    rtPtr: addr rt,
    bindingsPtr: addr bindings,
    nimFuncs: initFastMap[string, NimJsHostProc](16),
    savedHidden: initFastMap[int32, SavedNodeVisual](8),
    consoleLogs: @[],
    lastJsError: ""
  )
  let coreRes = alloc.create(coreVal)
  if coreRes.isErr():
    var tmpEng = coreVal.engine
    tmpEng.destroy()
    return err[HtmlJsSession, string]("OutOfMemory allocating HtmlJsCore")

  let corePtr = coreRes.get()
  corePtr.engine.setHostHandler(makeHostDispatcher(corePtr))
  ok[HtmlJsSession, string](HtmlJsSession(core: corePtr))

# Safe: marks core inactive and destroys owned QuickJsEngine and HtmlJsCore via its allocator.
proc destroy*(s: var HtmlJsSession) {.trustedUnsafe, raises: [].} =
  if s.core.isNil:
    return
  let alloc = s.core.alloc
  s.core.active = false
  s.core.engine.destroy()
  s.core.nimFuncs.clear()
  s.core.savedHidden.clear()
  s.core.consoleLogs.setLen(0)
  s.core.lastJsError = ""
  alloc.destroy(s.core)
  s.core = nil

# Safe: s.core is nil-checked before deref; owned by HtmlJsSession.
proc registerNimFunc*(s: var HtmlJsSession, name: string, fn: NimJsHostProc) {.trustedUnsafe, raises: [].} =
  if not s.core.isNil:
    s.core.nimFuncs.put(name, fn)

# Safe: s.core is nil- and active-checked before deref; owned by HtmlJsSession.
proc executeScript*(
  s: var HtmlJsSession,
  code: string,
  filename: string = "<script>",
  capsStr: string = ""
): Result[string, string] {.trustedUnsafe, raises: [].} =
  if s.core.isNil or not s.core.active:
    return err[string, string]("HtmlJsSession is not active")

  let engineCaps = s.core.engine.config.validation.allowedCaps
  var scriptCaps = engineCaps
  if capsStr.len > 0:
    let parsedCaps = parseScriptCaps(capsStr)
    if parsedCaps.isErr():
      return err[string, string](parsedCaps.error())
    let requested = parsedCaps.get()
    # Capabilities cannot exceed the host engine's explicit allowed set.
    let denied = requested - engineCaps
    if denied != {}:
      return err[string, string](
        "Zig-Explicitness Violation [JS-Z05]: script requested unpermitted capabilities"
      )
    scriptCaps = requested

  let prevCaps = s.core.engine.config.validation.allowedCaps
  s.core.engine.config.validation.allowedCaps = scriptCaps
  let evalRes = s.core.engine.evalValidated(code, filename, some(scriptCaps))
  if evalRes.isErr():
    s.core.engine.config.validation.allowedCaps = prevCaps
    return err[string, string](evalRes.error())
  # Restore union or script caps for runtime callbacks registered by the script
  ok[string, string](evalRes.get())

# Safe: s.core, treePtr, rtPtr, bindingsPtr are nil- and active-checked; owned by caller/session.
proc mountHtmlWithJs*(
  s: var HtmlJsSession,
  html: string,
  extraCss: string = "",
  parentId: SlabId = SlabId(-1'i32)
): Result[SlabId, string] {.trustedUnsafe, raises: [].} =
  if s.core.isNil or not s.core.active:
    return err[SlabId, string]("HtmlJsSession is not active")

  let docRes = parseHtmlDoc(html, allowJs = true)
  if docRes.isErr():
    return err[SlabId, string](docRes.error())
  let doc = docRes.get()

  let embeddedSheet = parseCssSheet(doc.embeddedCss)
  let extraSheet = parseCssSheet(extraCss)
  let combined = mergeStylesheets(embeddedSheet, extraSheet)

  let mountRes = mountHtml(
    s.core.treePtr[],
    s.core.rtPtr,
    doc,
    combined,
    s.core.bindingsPtr[],
    parentId
  )
  if mountRes.isErr():
    return err[SlabId, string](mountRes.error())

  for idx, blk in doc.scripts:
    let scRes = s.executeScript(blk.code, "<script #" & $idx & ">", blk.caps)
    if scRes.isErr():
      return err[SlabId, string](scRes.error())

  mountRes

# Safe: s.core is nil- and active-checked before deref; owned by HtmlJsSession.
proc tick*(s: var HtmlJsSession, dtMs: int): Result[int, string] {.trustedUnsafe, raises: [].} =
  if s.core.isNil or not s.core.active:
    return ok[int, string](0)
  s.core.engine.tickTimers(dtMs)

# Safe: s.core is nil- and active-checked before deref; owned by HtmlJsSession.
proc hasActiveTimers*(s: HtmlJsSession): bool {.trustedUnsafe, inline, raises: [].} =
  if s.core.isNil or not s.core.active:
    return false
  s.core.engine.hasActiveTimers()

# Safe: s.core is nil-checked before deref; owned by HtmlJsSession.
proc consoleLogs*(s: HtmlJsSession): seq[string] {.trustedUnsafe, raises: [].} =
  if s.core.isNil: return @[]
  s.core.consoleLogs

# Safe: s.core is nil-checked before deref; owned by HtmlJsSession.
proc lastJsError*(s: HtmlJsSession): string {.trustedUnsafe, raises: [].} =
  if s.core.isNil: return ""
  s.core.lastJsError
