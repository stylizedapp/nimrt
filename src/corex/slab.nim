## corex/slab — Growable Slab Allocator (`Slab[T]`) with O(1) Insert/Remove
##
## Provides stable `SlabId` references (distinct int32, immune to grow reallocations),
## intrusive free-list tracking, single contiguous backing allocation,
## and complete ARC/ORC lifecycle integration.

import ./allocators
import ./result
import ./adt

type
  SlabId* = distinct int32

  Slab*[T] = object
    data*: ptr UncheckedArray[T]
    nextFree*: ptr UncheckedArray[int32]
    freeHead*: int32                    # -1 if no free slots
    cap*: int
    len*: int                           # occupied slots count
    alloc*: Allocator

const
  SlotOccupied: int32 = -2'i32
  FreeListEnd: int32 = -1'i32

proc `==`*(a, b: SlabId): bool {.inline, raises: [].} =
  int32(a) == int32(b)

proc `$`*(id: SlabId): string {.raises: [].} =
  "SlabId(" & $int32(id) & ")"

proc rawIndex*(id: SlabId): int32 {.inline, raises: [].} =
  int32(id)

# =============================================================================
# Layout Helpers
# =============================================================================

proc calcOffsets[T](cap: int): tuple[totalBytes: int, alignVal: int, offNextFree: int] {.inline, raises: [].} =
  let alignT = max(alignof(T), 1)
  let alignNext = max(alignof(int32), 1)
  let maxAlign = max(max(alignT, alignNext), 8)
  let offNextFree = int(alignForward(uint(cap * sizeof(T)), uint(alignNext)))
  let totalBytes = offNextFree + cap * sizeof(int32)
  (totalBytes, maxAlign, offNextFree)

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*[T](s: var Slab[T]) {.raises: [].} =
  if not s.data.isNil and s.cap > 0:
    for i in 0 ..< s.cap:
      if s.nextFree[i] == SlotOccupied:
        `=destroy`(s.data[i])
    let (totalBytes, _, _) = calcOffsets[T](s.cap)
    if not s.alloc.freeFn.isNil:
      s.alloc.dealloc(s.data, totalBytes)
    s.data = nil
    s.nextFree = nil
    s.freeHead = FreeListEnd
    s.cap = 0
    s.len = 0

proc `=wasMoved`*[T](s: var Slab[T]) {.inline, raises: [].} =
  s.data = nil
  s.nextFree = nil
  s.freeHead = FreeListEnd
  s.cap = 0
  s.len = 0

proc `=sink`*[T](dest: var Slab[T], src: Slab[T]) {.raises: [].} =
  if dest.data != src.data:
    `=destroy`(dest)
  dest.data = src.data
  dest.nextFree = src.nextFree
  dest.freeHead = src.freeHead
  dest.cap = src.cap
  dest.len = src.len
  dest.alloc = src.alloc

proc `=copy`*[T](dest: var Slab[T], src: Slab[T]) {.raises: [].} =
  if dest.data == src.data:
    return
  `=destroy`(dest)
  dest.alloc = src.alloc
  if src.cap == 0 or src.data.isNil:
    dest.data = nil
    dest.nextFree = nil
    dest.freeHead = FreeListEnd
    dest.cap = 0
    dest.len = 0
    return

  let (totalBytes, alignVal, offNextFree) = calcOffsets[T](src.cap)
  let rawRes = dest.alloc.rawAlloc(totalBytes, alignVal)
  if rawRes.isOk:
    let raw = rawRes.get
    zeroMem(raw, totalBytes)
    dest.data = cast[ptr UncheckedArray[T]](raw)
    dest.nextFree = cast[ptr UncheckedArray[int32]](cast[uint](raw) + uint(offNextFree))
    dest.freeHead = src.freeHead
    dest.cap = src.cap
    dest.len = src.len

    copyMem(dest.nextFree, src.nextFree, src.cap * sizeof(int32))
    for i in 0 ..< src.cap:
      if src.nextFree[i] == SlotOccupied:
        dest.data[i] = src.data[i]
  else:
    dest.data = nil
    dest.nextFree = nil
    dest.freeHead = FreeListEnd
    dest.cap = 0
    dest.len = 0
    raise (ref Defect)(msg: "Slab.=copy: out of memory")

# =============================================================================
# Construction & Operations
# =============================================================================

proc initSlab*[T](alloc: Allocator, initialCap: int = 64): Result[Slab[T], AllocError] {.raises: [].} =
  let cap = max(1, initialCap)
  let (totalBytes, alignVal, offNextFree) = calcOffsets[T](cap)
  let raw = ?alloc.rawAlloc(totalBytes, alignVal)
  zeroMem(raw, totalBytes)

  let pData = cast[ptr UncheckedArray[T]](raw)
  let pNextFree = cast[ptr UncheckedArray[int32]](cast[uint](raw) + uint(offNextFree))

  for i in 0 ..< cap - 1:
    pNextFree[i] = int32(i + 1)
  pNextFree[cap - 1] = FreeListEnd

  ok[Slab[T], AllocError](Slab[T](
    data: pData,
    nextFree: pNextFree,
    freeHead: 0'i32,
    cap: cap,
    len: 0,
    alloc: alloc
  ))

proc deinit*[T](s: var Slab[T]) {.inline, raises: [].} =
  `=destroy`(s)

proc len*[T](s: Slab[T]): int {.inline, raises: [].} =
  s.len

proc cap*[T](s: Slab[T]): int {.inline, raises: [].} =
  s.cap

proc contains*[T](s: Slab[T], id: SlabId): bool {.inline, raises: [].} =
  let idx = int32(id)
  idx >= 0 and idx < int32(s.cap) and not s.nextFree.isNil and s.nextFree[idx] == SlotOccupied

proc grow[T](s: var Slab[T]): Result[void, AllocError] {.raises: [].} =
  let oldCap = s.cap
  let newCap = if oldCap == 0: 64 else: oldCap * 2
  let (newBytes, newAlign, newOffNextFree) = calcOffsets[T](newCap)

  let raw = ?s.alloc.rawAlloc(newBytes, newAlign)
  zeroMem(raw, newBytes)

  let newData = cast[ptr UncheckedArray[T]](raw)
  let newNextFree = cast[ptr UncheckedArray[int32]](cast[uint](raw) + uint(newOffNextFree))

  if oldCap > 0 and not s.data.isNil:
    for i in 0 ..< oldCap:
      newNextFree[i] = s.nextFree[i]
      if s.nextFree[i] == SlotOccupied:
        copyMem(addr newData[i], addr s.data[i], sizeof(T))
        wasMoved(s.data[i])

  # Initialize new free list nodes from oldCap to newCap
  for i in oldCap ..< newCap - 1:
    newNextFree[i] = int32(i + 1)
  newNextFree[newCap - 1] = s.freeHead
  let newFreeHead = int32(oldCap)

  let (oldBytes, _, _) = calcOffsets[T](oldCap)
  if not s.alloc.freeFn.isNil and oldCap > 0:
    s.alloc.dealloc(s.data, oldBytes)

  s.data = newData
  s.nextFree = newNextFree
  s.freeHead = newFreeHead
  s.cap = newCap
  ok(void, AllocError)

proc insert*[T](s: var Slab[T], val: sink T): Result[SlabId, AllocError] {.raises: [].} =
  if s.freeHead == FreeListEnd or s.cap == 0:
    ?s.grow()

  let slot = s.freeHead
  s.freeHead = s.nextFree[slot]
  s.nextFree[slot] = SlotOccupied

  copyMem(addr s.data[slot], addr val, sizeof(T))
  wasMoved(val)
  inc(s.len)
  ok[SlabId, AllocError](SlabId(slot))

proc remove*[T](s: var Slab[T], id: SlabId): Option[T] {.raises: [].} =
  let idx = int32(id)
  if idx < 0 or idx >= int32(s.cap) or s.nextFree.isNil or s.nextFree[idx] != SlotOccupied:
    return none[T]()

  var extracted: T
  copyMem(addr extracted, addr s.data[idx], sizeof(T))
  wasMoved(s.data[idx])

  s.nextFree[idx] = s.freeHead
  s.freeHead = idx
  dec(s.len)
  some[T](move(extracted))

proc `[]`*[T](s: Slab[T], id: SlabId): lent T {.inline, raises: [].} =
  let idx = int32(id)
  doAssert idx >= 0 and idx < int32(s.cap) and s.nextFree[idx] == SlotOccupied, "Slab: access to unoccupied slot"
  s.data[idx]

proc `[]`*[T](s: var Slab[T], id: SlabId): var T {.inline, raises: [].} =
  let idx = int32(id)
  doAssert idx >= 0 and idx < int32(s.cap) and s.nextFree[idx] == SlotOccupied, "Slab: access to unoccupied slot"
  s.data[idx]

proc clear*[T](s: var Slab[T]) {.raises: [].} =
  if s.data.isNil or s.cap == 0:
    return
  for i in 0 ..< s.cap:
    if s.nextFree[i] == SlotOccupied:
      `=destroy`(s.data[i])
      wasMoved(s.data[i])
    s.nextFree[i] = if i < s.cap - 1: int32(i + 1) else: FreeListEnd
  s.freeHead = 0'i32
  s.len = 0
