## corex/signals — High-Performance Zero-Overhead Reactive Engine (SolidJS / Slint Style)
##
## Centralized data-oriented reactive dependency graph:
## - Central `ReactiveRuntime` storing nodes in `Slab[ReactiveNode]` for O(1) allocation/deallocation
##   and L1 cache locality.
## - Double-linked subscription edge pool `Slab[EdgeNode]` (zero seq allocations per node).
## - Type-safe distinct node identifiers: `SignalId`, `ComputedId`, `EffectId`.
## - Primitives:
##   - `Signal[T]`: `createSignal`, `get`, `set`, `peek`.
##   - `Computed[T]`: `createComputed`, `get`, `peek` (lazy, memoized, dirty-flagged).
##   - `Effect`: `createEffect` (automatic dependency tracking & untracking before re-run).
##   - `batch`: Groups updates so effects fire exactly once at batch exit.
##   - `dispose` & `destroy`: Deterministic leak-free cleanup under ARC/ORC.
##
## Strict invariants:
## - Compilation: `--mm:orc --threads:on --panics:on`
## - Public system APIs: `{.raises: [].}`
## - Zero memory leaks under TrackingAllocator.

import ./allocators
import ./result
import ./adt
import ./slab
import ./containers

const
  NilSlabId* = SlabId(-1'i32)

type
  SignalId* = distinct SlabId
  ComputedId* = distinct SlabId
  EffectId* = distinct SlabId
  Effect* = EffectId

  NodeKind* = enum
    nkSignal
    nkComputed
    nkEffect

  NodeState* = enum
    nsClean
    nsDirty

  EdgeNode* = object
    sourceId*: SlabId
    observerId*: SlabId
    prevObs*: SlabId ## In source's observer list
    nextObs*: SlabId
    prevSrc*: SlabId ## In observer's source list
    nextSrc*: SlabId

  ReactiveRuntime* = object
    nodes*: Slab[ReactiveNode]
    edges*: Slab[EdgeNode]
    pendingEffects*: BufSeq[SlabId]
    allocator*: Allocator
    batchDepth*: int

  ReactiveNode* = object
    kind*: NodeKind
    state*: NodeState
    firstObserverEdge*: SlabId ## Head of EdgeNode list where this node is source
    firstSourceEdge*: SlabId   ## Head of EdgeNode list where this node is observer
    isQueued*: bool
    valPtr*: pointer
    valSize*: int
    envPtr*: pointer
    destroyValFn*: proc(p: pointer, alloc: Allocator) {.nimcall, gcsafe, raises: [].}
    destroyEnvFn*: proc(p: pointer, alloc: Allocator) {.nimcall, gcsafe, raises: [].}
    recomputeProc*: proc(rt: ptr ReactiveRuntime, id: SlabId): bool {.nimcall, gcsafe, raises: [].}
    effectFn*: proc() {.closure, gcsafe, raises: [].}

  Signal*[T] = object
    rt*: ptr ReactiveRuntime
    id*: SignalId

  Computed*[T] = object
    rt*: ptr ReactiveRuntime
    id*: ComputedId

  ComputedEnv[T] = object
    computeFn: proc(): T {.closure, gcsafe, raises: [].}
    hasValue: bool

# =============================================================================
# Identifiers & Equality
# =============================================================================

proc `==`*(a, b: SignalId): bool {.inline, raises: [].} = int32(SlabId(a)) == int32(SlabId(b))
proc `==`*(a, b: ComputedId): bool {.inline, raises: [].} = int32(SlabId(a)) == int32(SlabId(b))
proc `==`*(a, b: EffectId): bool {.inline, raises: [].} = int32(SlabId(a)) == int32(SlabId(b))

proc `$`*(id: SignalId): string {.raises: [].} = "SignalId(" & $int32(SlabId(id)) & ")"
proc `$`*(id: ComputedId): string {.raises: [].} = "ComputedId(" & $int32(SlabId(id)) & ")"
proc `$`*(id: EffectId): string {.raises: [].} = "EffectId(" & $int32(SlabId(id)) & ")"

proc toSlabId*(id: SignalId): SlabId {.inline, raises: [].} = SlabId(id)
proc toSlabId*(id: ComputedId): SlabId {.inline, raises: [].} = SlabId(id)
proc toSlabId*(id: EffectId): SlabId {.inline, raises: [].} = SlabId(id)

proc id*[T](sig: Signal[T]): SignalId {.inline, raises: [].} = sig.id
proc id*[T](comp: Computed[T]): ComputedId {.inline, raises: [].} = comp.id
proc runtime*[T](sig: Signal[T]): ptr ReactiveRuntime {.inline, raises: [].} = sig.rt
proc runtime*[T](comp: Computed[T]): ptr ReactiveRuntime {.inline, raises: [].} = comp.rt

# =============================================================================
# Thread-Local Tracking Context
# =============================================================================

var tCurrentObserver {.threadvar.}: SlabId
var tCurrentRuntime {.threadvar.}: ptr ReactiveRuntime

proc currentObserver*(): SlabId {.inline, raises: [].} =
  tCurrentObserver

proc currentRuntime*(): ptr ReactiveRuntime {.inline, raises: [].} =
  tCurrentRuntime

# =============================================================================
# Typed Helpers for Memory Management
# =============================================================================

proc destroyTypedVal[T](p: pointer, alloc: Allocator) {.nimcall, gcsafe, raises: [].} =
  if p != nil:
    # Safe: type-erased destructor on owned signal value slot; no shared GC globals accessed.
    {.cast(gcsafe).}:
      `=destroy`(cast[ptr T](p)[])
    alloc.dealloc(p, sizeof(T))

proc destroyTypedEnv[T](p: pointer, alloc: Allocator) {.nimcall, gcsafe, raises: [].} =
  if p != nil:
    # Safe: type-erased destructor on owned computed env slot; no shared GC globals accessed.
    {.cast(gcsafe).}:
      `=destroy`(cast[ptr ComputedEnv[T]](p)[])
    alloc.dealloc(p, sizeof(ComputedEnv[T]))

# =============================================================================
# Edge Pool & Graph Operations
# =============================================================================

proc addDependency*(rt: ptr ReactiveRuntime, sourceId, observerId: SlabId) {.raises: [].} =
  if rt.isNil or sourceId == NilSlabId or observerId == NilSlabId:
    return
  if not rt.nodes.contains(sourceId) or not rt.nodes.contains(observerId):
    return

  # Fast deduplication: check if already in observer's source list
  var curEdge = rt.nodes[observerId].firstSourceEdge
  while curEdge != NilSlabId and rt.edges.contains(curEdge):
    if rt.edges[curEdge].sourceId == sourceId:
      return # Dependency already registered
    curEdge = rt.edges[curEdge].nextSrc

  var edge = EdgeNode(
    sourceId: sourceId,
    observerId: observerId,
    prevObs: NilSlabId,
    nextObs: NilSlabId,
    prevSrc: NilSlabId,
    nextSrc: NilSlabId
  )

  let edgeRes = rt.edges.insert(edge)
  if not edgeRes.isOk:
    return
  let edgeId = edgeRes.val

  # Prepend to Source's observer list
  let oldFirstObs = rt.nodes[sourceId].firstObserverEdge
  rt.edges[edgeId].nextObs = oldFirstObs
  rt.edges[edgeId].prevObs = NilSlabId
  if oldFirstObs != NilSlabId and rt.edges.contains(oldFirstObs):
    rt.edges[oldFirstObs].prevObs = edgeId
  rt.nodes[sourceId].firstObserverEdge = edgeId

  # Prepend to Observer's source list
  let oldFirstSrc = rt.nodes[observerId].firstSourceEdge
  rt.edges[edgeId].nextSrc = oldFirstSrc
  rt.edges[edgeId].prevSrc = NilSlabId
  if oldFirstSrc != NilSlabId and rt.edges.contains(oldFirstSrc):
    rt.edges[oldFirstSrc].prevSrc = edgeId
  rt.nodes[observerId].firstSourceEdge = edgeId

proc removeEdge*(rt: ptr ReactiveRuntime, edgeId: SlabId) {.raises: [].} =
  if rt.isNil or edgeId == NilSlabId or not rt.edges.contains(edgeId):
    return

  let edge = rt.edges[edgeId]
  let sId = edge.sourceId
  let oId = edge.observerId

  # Unlink from source's observer list
  if rt.nodes.contains(sId):
    if edge.prevObs != NilSlabId:
      if rt.edges.contains(edge.prevObs):
        rt.edges[edge.prevObs].nextObs = edge.nextObs
    else:
      rt.nodes[sId].firstObserverEdge = edge.nextObs

    if edge.nextObs != NilSlabId and rt.edges.contains(edge.nextObs):
      rt.edges[edge.nextObs].prevObs = edge.prevObs

  # Unlink from observer's source list
  if rt.nodes.contains(oId):
    if edge.prevSrc != NilSlabId:
      if rt.edges.contains(edge.prevSrc):
        rt.edges[edge.prevSrc].nextSrc = edge.nextSrc
    else:
      rt.nodes[oId].firstSourceEdge = edge.nextSrc

    if edge.nextSrc != NilSlabId and rt.edges.contains(edge.nextSrc):
      rt.edges[edge.nextSrc].prevSrc = edge.prevSrc

  discard rt.edges.remove(edgeId)

proc clearObserverDependencies*(rt: ptr ReactiveRuntime, oId: SlabId) {.raises: [].} =
  if rt.isNil or not rt.nodes.contains(oId):
    return
  var edgeId = rt.nodes[oId].firstSourceEdge
  while edgeId != NilSlabId and rt.edges.contains(edgeId):
    let nextEdge = rt.edges[edgeId].nextSrc
    rt.removeEdge(edgeId)
    edgeId = nextEdge
  if rt.nodes.contains(oId):
    rt.nodes[oId].firstSourceEdge = NilSlabId

proc clearSourceObservers*(rt: ptr ReactiveRuntime, sId: SlabId) {.raises: [].} =
  if rt.isNil or not rt.nodes.contains(sId):
    return
  var edgeId = rt.nodes[sId].firstObserverEdge
  while edgeId != NilSlabId and rt.edges.contains(edgeId):
    let nextEdge = rt.edges[edgeId].nextObs
    rt.removeEdge(edgeId)
    edgeId = nextEdge
  if rt.nodes.contains(sId):
    rt.nodes[sId].firstObserverEdge = NilSlabId

# =============================================================================
# Forward Declarations
# =============================================================================

proc runEffect*(rt: ptr ReactiveRuntime, effId: SlabId) {.gcsafe, raises: [].}
proc flushPendingEffects*(rt: ptr ReactiveRuntime) {.gcsafe, raises: [].}
proc dispose*(rt: ptr ReactiveRuntime, id: SlabId) {.raises: [].}
proc destroy*(rt: var ReactiveRuntime) {.raises: [].}

# =============================================================================
# Dirty Propagation & Scheduling
# =============================================================================

proc markDirtyAndPropagate*(rt: ptr ReactiveRuntime, sourceId: SlabId) {.raises: [].} =
  if rt.isNil or not rt.nodes.contains(sourceId):
    return

  var edgeId = rt.nodes[sourceId].firstObserverEdge
  while edgeId != NilSlabId and rt.edges.contains(edgeId):
    let oId = rt.edges[edgeId].observerId
    let nextEdge = rt.edges[edgeId].nextObs
    if rt.nodes.contains(oId):
      var obsNode = addr rt.nodes[oId]
      case obsNode.kind
      of nkComputed:
        if obsNode.state != nsDirty:
          obsNode.state = nsDirty
          rt.markDirtyAndPropagate(oId)
      of nkEffect:
        obsNode.state = nsDirty
        if not obsNode.isQueued:
          if rt.pendingEffects.tryAdd(oId).isOk:
            obsNode.isQueued = true
      of nkSignal:
        discard
    edgeId = nextEdge

proc flushPendingEffects*(rt: ptr ReactiveRuntime) {.gcsafe, raises: [].} =
  if rt.isNil or rt.batchDepth > 0:
    return

  var i = 0
  while i < rt.pendingEffects.len:
    let effId = rt.pendingEffects[i]
    inc(i)
    if rt.nodes.contains(effId):
      var node = addr rt.nodes[effId]
      node.isQueued = false
      if node.kind == nkEffect and node.state == nsDirty:
        rt.runEffect(effId)
  rt.pendingEffects.clear()

proc runEffect*(rt: ptr ReactiveRuntime, effId: SlabId) {.gcsafe, raises: [].} =
  if rt.isNil or not rt.nodes.contains(effId):
    return
  if rt.nodes[effId].kind != nkEffect:
    return

  # Automatic dependency untracking before re-run
  rt.clearObserverDependencies(effId)

  let node = addr rt.nodes[effId]
  node.state = nsClean

  let prevObs = tCurrentObserver
  let prevRt = tCurrentRuntime
  tCurrentObserver = effId
  tCurrentRuntime = rt
  try:
    if node.effectFn != nil:
      node.effectFn()
  finally:
    tCurrentObserver = prevObs
    tCurrentRuntime = prevRt

# =============================================================================
# Lifecycle: Init, Dispose & Destroy
# =============================================================================

proc `=copy`*(dest: var ReactiveRuntime, src: ReactiveRuntime) {.
  error: "ReactiveRuntime cannot be copied; pass by pointer or var reference".}

proc dispose*(rt: ptr ReactiveRuntime, id: SlabId) {.raises: [].} =
  if rt.isNil or not rt.nodes.contains(id):
    return

  rt.clearSourceObservers(id)
  rt.clearObserverDependencies(id)

  var node = addr rt.nodes[id]
  if node.destroyValFn != nil and node.valPtr != nil:
    node.destroyValFn(node.valPtr, rt.allocator)
    node.valPtr = nil
  if node.destroyEnvFn != nil and node.envPtr != nil:
    node.destroyEnvFn(node.envPtr, rt.allocator)
    node.envPtr = nil
  reset(node.effectFn)

  discard rt.nodes.remove(id)

proc dispose*(rt: var ReactiveRuntime, id: SlabId) {.inline, raises: [].} =
  dispose(addr rt, id)

proc dispose*(rt: var ReactiveRuntime, id: SignalId) {.inline, raises: [].} =
  dispose(addr rt, SlabId(id))

proc dispose*(rt: var ReactiveRuntime, id: ComputedId) {.inline, raises: [].} =
  dispose(addr rt, SlabId(id))

proc dispose*(rt: var ReactiveRuntime, id: EffectId) {.inline, raises: [].} =
  dispose(addr rt, SlabId(id))

proc dispose*[T](rt: var ReactiveRuntime, sig: Signal[T]) {.inline, raises: [].} =
  dispose(addr rt, SlabId(sig.id))

proc dispose*[T](rt: var ReactiveRuntime, comp: Computed[T]) {.inline, raises: [].} =
  dispose(addr rt, SlabId(comp.id))

proc destroy*(rt: var ReactiveRuntime) {.raises: [].} =
  if rt.nodes.cap > 0 and not rt.nodes.data.isNil:
    for i in 0 ..< rt.nodes.cap:
      let id = SlabId(int32(i))
      if rt.nodes.contains(id):
        (addr rt).dispose(id)
  rt.nodes.deinit()
  rt.edges.deinit()
  rt.pendingEffects.deinit()
  rt.batchDepth = 0

proc destroy*(rt: ptr ReactiveRuntime) {.raises: [].} =
  if rt != nil:
    let alloc = rt.allocator
    destroy(rt[])
    alloc.dealloc(rt, sizeof(ReactiveRuntime))

proc `=destroy`*(rt: var ReactiveRuntime) {.raises: [].} =
  destroy(rt)

proc initReactiveRuntime*(allocator: Allocator = defaultHeapAllocator()): ReactiveRuntime {.raises: [].} =
  let nodesRes = initSlab[ReactiveNode](allocator, 64)
  doAssert nodesRes.isOk, "Failed to initialize ReactiveNode slab"
  let edgesRes = initSlab[EdgeNode](allocator, 128)
  doAssert edgesRes.isOk, "Failed to initialize EdgeNode slab"
  let pendingRes = initBufSeq[SlabId](allocator, 32)
  doAssert pendingRes.isOk, "Failed to initialize pendingEffects queue"

  result.nodes = nodesRes.val
  result.edges = edgesRes.val
  result.pendingEffects = pendingRes.val
  result.allocator = allocator
  result.batchDepth = 0

proc newReactiveRuntime*(allocator: Allocator = defaultHeapAllocator()): ptr ReactiveRuntime {.raises: [].} =
  let rawRes = allocator.rawAlloc(sizeof(ReactiveRuntime), max(alignof(ReactiveRuntime), 8))
  doAssert rawRes.isOk, "Failed to allocate ReactiveRuntime on heap"
  let p = cast[ptr ReactiveRuntime](rawRes.val)
  zeroMem(p, sizeof(ReactiveRuntime))
  p[] = initReactiveRuntime(allocator)
  p

# =============================================================================
# Signal[T]
# =============================================================================

proc createSignal*[T](rt: ptr ReactiveRuntime, initialVal: sink T): Signal[T] {.raises: [].} =
  doAssert not rt.isNil, "ReactiveRuntime pointer is nil"
  let valRes = rt.allocator.rawAlloc(sizeof(T), max(alignof(T), sizeof(pointer)))
  doAssert valRes.isOk, "Out of memory allocating Signal value"
  let pVal = cast[ptr T](valRes.val)
  zeroMem(pVal, sizeof(T))
  pVal[] = initialVal

  var node = ReactiveNode(
    kind: nkSignal,
    state: nsClean,
    firstObserverEdge: NilSlabId,
    firstSourceEdge: NilSlabId,
    isQueued: false,
    valPtr: pVal,
    valSize: sizeof(T),
    envPtr: nil,
    destroyValFn: destroyTypedVal[T],
    destroyEnvFn: nil,
    recomputeProc: nil
  )

  let insertRes = rt.nodes.insert(node)
  doAssert insertRes.isOk, "Failed to insert Signal node into Slab"
  Signal[T](rt: rt, id: SignalId(insertRes.val))

proc createSignal*[T](rt: var ReactiveRuntime, initialVal: sink T): Signal[T] {.inline, raises: [].} =
  createSignal[T](addr rt, initialVal)

proc peek*[T](sig: Signal[T]): T {.inline, raises: [].} =
  doAssert not sig.rt.isNil and sig.rt.nodes.contains(sig.id.toSlabId), "Invalid Signal"
  let pVal = cast[ptr T](sig.rt.nodes[sig.id.toSlabId].valPtr)
  pVal[]

proc get*[T](sig: Signal[T]): T {.raises: [].} =
  let id = sig.id.toSlabId
  if tCurrentObserver != NilSlabId and tCurrentRuntime == sig.rt:
    sig.rt.addDependency(sourceId = id, observerId = tCurrentObserver)
  peek(sig)

proc set*[T](sig: Signal[T], newVal: sink T) {.gcsafe, raises: [].} =
  let id = sig.id.toSlabId
  doAssert not sig.rt.isNil and sig.rt.nodes.contains(id), "Invalid Signal"
  let pVal = cast[ptr T](sig.rt.nodes[id].valPtr)
  when compiles(pVal[] == newVal):
    if pVal[] == newVal:
      return
  pVal[] = newVal
  sig.rt.markDirtyAndPropagate(id)
  if sig.rt.batchDepth == 0:
    sig.rt.flushPendingEffects()

# =============================================================================
# Computed[T]
# =============================================================================

proc recomputeTyped[T](rt: ptr ReactiveRuntime, id: SlabId): bool {.nimcall, gcsafe, raises: [].} =
  let node = addr rt.nodes[id]
  let env = cast[ptr ComputedEnv[T]](node.envPtr)
  let pVal = cast[ptr T](node.valPtr)

  # Clear previous source dependencies before re-tracking
  rt.clearObserverDependencies(id)

  let prevObs = tCurrentObserver
  let prevRt = tCurrentRuntime
  tCurrentObserver = id
  tCurrentRuntime = rt
  var newVal: T
  try:
    newVal = env.computeFn()
  finally:
    tCurrentObserver = prevObs
    tCurrentRuntime = prevRt

  var changed = false
  when compiles(pVal[] != newVal):
    if not env.hasValue or pVal[] != newVal:
      changed = true
  else:
    changed = true

  if changed:
    pVal[] = newVal
    env.hasValue = true

  node.state = nsClean
  changed

proc createComputed*[T](
  rt: ptr ReactiveRuntime,
  computeFn: proc(): T {.closure, gcsafe, raises: [].}
): Computed[T] {.raises: [].} =
  doAssert not rt.isNil, "ReactiveRuntime pointer is nil"
  let valRes = rt.allocator.rawAlloc(sizeof(T), max(alignof(T), sizeof(pointer)))
  doAssert valRes.isOk, "Out of memory allocating Computed value"
  let pVal = cast[ptr T](valRes.val)
  zeroMem(pVal, sizeof(T))

  let envRes = rt.allocator.rawAlloc(sizeof(ComputedEnv[T]), max(alignof(ComputedEnv[T]), sizeof(pointer)))
  doAssert envRes.isOk, "Out of memory allocating ComputedEnv"
  let pEnv = cast[ptr ComputedEnv[T]](envRes.val)
  zeroMem(pEnv, sizeof(ComputedEnv[T]))
  pEnv.computeFn = computeFn
  pEnv.hasValue = false

  var node = ReactiveNode(
    kind: nkComputed,
    state: nsDirty,
    firstObserverEdge: NilSlabId,
    firstSourceEdge: NilSlabId,
    isQueued: false,
    valPtr: pVal,
    valSize: sizeof(T),
    envPtr: pEnv,
    destroyValFn: destroyTypedVal[T],
    destroyEnvFn: destroyTypedEnv[T],
    recomputeProc: recomputeTyped[T]
  )

  let insertRes = rt.nodes.insert(node)
  doAssert insertRes.isOk, "Failed to insert Computed node into Slab"
  Computed[T](rt: rt, id: ComputedId(insertRes.val))

proc createComputed*[T](
  rt: var ReactiveRuntime,
  computeFn: proc(): T {.closure, gcsafe, raises: [].}
): Computed[T] {.inline, raises: [].} =
  createComputed[T](addr rt, computeFn)

proc peek*[T](comp: Computed[T]): T {.raises: [].} =
  let id = comp.id.toSlabId
  doAssert not comp.rt.isNil and comp.rt.nodes.contains(id), "Invalid Computed"
  let node = addr comp.rt.nodes[id]
  let env = cast[ptr ComputedEnv[T]](node.envPtr)
  if node.state == nsDirty or not env.hasValue:
    discard node.recomputeProc(comp.rt, id)
  let pVal = cast[ptr T](node.valPtr)
  pVal[]

proc get*[T](comp: Computed[T]): T {.raises: [].} =
  let id = comp.id.toSlabId
  if tCurrentObserver != NilSlabId and tCurrentRuntime == comp.rt:
    comp.rt.addDependency(sourceId = id, observerId = tCurrentObserver)
  peek(comp)

# =============================================================================
# Effect
# =============================================================================

proc createEffect*(
  rt: ptr ReactiveRuntime,
  effectFn: proc() {.closure, gcsafe, raises: [].}
): EffectId {.raises: [].} =
  doAssert not rt.isNil, "ReactiveRuntime pointer is nil"
  var node = ReactiveNode(
    kind: nkEffect,
    state: nsClean,
    firstObserverEdge: NilSlabId,
    firstSourceEdge: NilSlabId,
    isQueued: false,
    valPtr: nil,
    valSize: 0,
    envPtr: nil,
    destroyValFn: nil,
    destroyEnvFn: nil,
    recomputeProc: nil,
    effectFn: effectFn
  )

  let insertRes = rt.nodes.insert(node)
  doAssert insertRes.isOk, "Failed to insert Effect node into Slab"
  let effId = insertRes.val
  rt.runEffect(effId)
  EffectId(effId)

proc createEffect*(
  rt: var ReactiveRuntime,
  effectFn: proc() {.closure, gcsafe, raises: [].}
): EffectId {.inline, raises: [].} =
  createEffect(addr rt, effectFn)

# =============================================================================
# Batch API
# =============================================================================

template batch*(rt: untyped, body: untyped) =
  let rtp = when rt is ptr ReactiveRuntime: rt else: addr rt
  inc(rtp.batchDepth)
  try:
    body
  finally:
    dec(rtp.batchDepth)
    if rtp.batchDepth == 0:
      rtp.flushPendingEffects()
