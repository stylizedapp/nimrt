## corex/smallvec — Inline Stack-Allocated Small Vector (`SmallVec[T, N]`)
##
## Optimization for small collections (HTML attributes, CSS selectors, HTTP headers):
## Stores up to `N` elements in-place on the stack/object without heap allocation.
## Automatically spills over to explicit `Allocator` dynamic storage on overflow.

import ./allocators
import ./result
import ./memory

type
  SmallVec*[T; N: static int] = object
    len*: int
    inlineData: array[N, T]
    heapData: ptr UncheckedArray[T]
    heapCap: int
    alloc: Allocator

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*[T; N: static int](s: var SmallVec[T, N]) {.raises: [].} =
  if s.heapData.isNil:
    for i in 0 ..< s.len:
      `=destroy`(s.inlineData[i])
  else:
    for i in 0 ..< s.len:
      `=destroy`(s.heapData[i])
    if not s.alloc.freeFn.isNil and s.heapCap > 0:
      s.alloc.dealloc(s.heapData, sizeof(T) * s.heapCap)
    s.heapData = nil
    s.heapCap = 0
  s.len = 0

proc `=wasMoved`*[T; N: static int](s: var SmallVec[T, N]) {.inline, raises: [].} =
  s.heapData = nil
  s.heapCap = 0
  s.len = 0

proc `=sink`*[T; N: static int](dest: var SmallVec[T, N], src: SmallVec[T, N]) {.raises: [].} =
  if dest.heapData != src.heapData or (dest.heapData.isNil and src.heapData.isNil):
    `=destroy`(dest)
  dest.len = src.len
  dest.heapCap = src.heapCap
  dest.heapData = src.heapData
  dest.alloc = src.alloc
  if src.heapData.isNil:
    for i in 0 ..< src.len:
      dest.inlineData[i] = src.inlineData[i]

proc `=copy`*[T; N: static int](dest: var SmallVec[T, N], src: SmallVec[T, N]) {.raises: [].} =
  if dest.heapData == src.heapData and not dest.heapData.isNil:
    return
  `=destroy`(dest)
  dest.alloc = src.alloc
  dest.len = src.len
  if src.heapData.isNil:
    for i in 0 ..< src.len:
      dest.inlineData[i] = src.inlineData[i]
  else:
    let rawRes = dest.alloc.rawAlloc(sizeof(T) * src.heapCap, max(alignof(T), 1))
    if rawRes.isOk:
      let raw = rawRes.get
      zeroMem(raw, sizeof(T) * src.heapCap)
      dest.heapData = cast[ptr UncheckedArray[T]](raw)
      dest.heapCap = src.heapCap
      for i in 0 ..< src.len:
        dest.heapData[i] = src.heapData[i]
    else:
      dest.heapData = nil
      dest.heapCap = 0
      dest.len = 0
      raise (ref Defect)(msg: "SmallVec.=copy: out of memory")

# =============================================================================
# Construction & Operations
# =============================================================================

proc initSmallVec*[T; N: static int](alloc: Allocator = Allocator()): SmallVec[T, N] {.inline, raises: [].} =
  SmallVec[T, N](
    len: 0,
    heapData: nil,
    heapCap: 0,
    alloc: alloc
  )

proc deinit*[T; N: static int](s: var SmallVec[T, N]) {.inline, raises: [].} =
  `=destroy`(s)

proc len*[T; N: static int](s: SmallVec[T, N]): int {.inline, raises: [].} =
  s.len

proc isInline*[T; N: static int](s: SmallVec[T, N]): bool {.inline, raises: [].} =
  s.heapData.isNil

proc cap*[T; N: static int](s: SmallVec[T, N]): int {.inline, raises: [].} =
  if s.heapData.isNil: N else: s.heapCap

proc add*[T; N: static int](s: var SmallVec[T, N], val: sink T): Result[void, AllocError] {.raises: [].} =
  if s.len < N and s.heapData.isNil:
    s.inlineData[s.len] = val
    inc(s.len)
    return ok(void, AllocError)

  # Spill over or expand heap storage
  if s.heapData.isNil:
    let newCap = max(N * 2, s.len + 1)
    let raw = ?s.alloc.rawAlloc(sizeof(T) * newCap, max(alignof(T), 1))
    zeroMem(raw, sizeof(T) * newCap)
    let pHeap = cast[ptr UncheckedArray[T]](raw)
    for i in 0 ..< s.len:
      copyMem(addr pHeap[i], addr s.inlineData[i], sizeof(T))
      wasMoved(s.inlineData[i])
    copyMem(addr pHeap[s.len], addr val, sizeof(T))
    wasMoved(val)
    s.heapData = pHeap
    s.heapCap = newCap
    inc(s.len)
  else:
    if s.len >= s.heapCap:
      let newCap = s.heapCap * 2
      let raw = ?s.alloc.rawAlloc(sizeof(T) * newCap, max(alignof(T), 1))
      zeroMem(raw, sizeof(T) * newCap)
      let pHeap = cast[ptr UncheckedArray[T]](raw)
      for i in 0 ..< s.len:
        copyMem(addr pHeap[i], addr s.heapData[i], sizeof(T))
        wasMoved(s.heapData[i])
      if not s.alloc.freeFn.isNil and s.heapCap > 0:
        s.alloc.dealloc(s.heapData, sizeof(T) * s.heapCap)
      s.heapData = pHeap
      s.heapCap = newCap
    copyMem(addr s.heapData[s.len], addr val, sizeof(T))
    wasMoved(val)
    inc(s.len)

  ok(void, AllocError)

proc `[]`*[T; N: static int](s: SmallVec[T, N], i: int): lent T {.inline, raises: [].} =
  doAssert i >= 0 and i < s.len, "SmallVec: index out of bounds"
  if s.heapData.isNil:
    return s.inlineData[i]
  else:
    return s.heapData[i]

proc `[]`*[T; N: static int](s: var SmallVec[T, N], i: int): var T {.inline, raises: [].} =
  doAssert i >= 0 and i < s.len, "SmallVec: index out of bounds"
  if s.heapData.isNil:
    return s.inlineData[i]
  else:
    return s.heapData[i]

proc `[]=`*[T; N: static int](s: var SmallVec[T, N], i: int, val: T) {.inline, raises: [].} =
  doAssert i >= 0 and i < s.len, "SmallVec: index out of bounds"
  if s.heapData.isNil:
    s.inlineData[i] = val
  else:
    s.heapData[i] = val

proc clear*[T; N: static int](s: var SmallVec[T, N]) {.raises: [].} =
  if s.heapData.isNil:
    for i in 0 ..< s.len:
      `=destroy`(s.inlineData[i])
      wasMoved(s.inlineData[i])
  else:
    for i in 0 ..< s.len:
      `=destroy`(s.heapData[i])
      wasMoved(s.heapData[i])
  s.len = 0

iterator items*[T; N: static int](s: SmallVec[T, N]): lent T {.inline.} =
  if s.heapData.isNil:
    for i in 0 ..< s.len:
      yield s.inlineData[i]
  else:
    for i in 0 ..< s.len:
      yield s.heapData[i]

iterator mitems*[T; N: static int](s: var SmallVec[T, N]): var T {.inline.} =
  if s.heapData.isNil:
    for i in 0 ..< s.len:
      yield s.inlineData[i]
  else:
    for i in 0 ..< s.len:
      yield s.heapData[i]
