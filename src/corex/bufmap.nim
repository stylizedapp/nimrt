## corex/bufmap — Allocator-aware SwissTable Hash Map (`BufMap[K, V]`)
##
## High-performance flat hash map using 1-byte SwissTable control tags,
## single-allocation backing store (ctrl + keys + vals), Result-based error handling,
## and complete ARC/ORC lifecycle integration.

import std/hashes
import ./allocators
import ./result
import ./adt
import ./memory

const
  SlotEmpty*: uint8 = 0'u8
  SlotDeleted*: uint8 = 1'u8
  # Occupied slots have tag in 2..255 (top 8 bits of hash, adjusted >= 2)

type
  BufMap*[K, V] = object
    ctrl*: ptr UncheckedArray[uint8]      # SwissTable control bytes (0=empty, 1=deleted, >=2=tag)
    keys*: ptr UncheckedArray[K]
    vals*: ptr UncheckedArray[V]
    cap*: int                             # Power of 2
    mask*: int                            # cap - 1
    count*: int
    usedSlots*: int
    alloc*: Allocator

# =============================================================================
# Layout & Hash Helpers
# =============================================================================

proc nextPow2(x: int): int {.inline, raises: [].} =
  var v = max(16, x - 1)
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  v = v or (v shr 8)
  v = v or (v shr 16)
  when sizeof(int) == 8:
    v = v or (v shr 32)
  v + 1

proc fastHash*[K](key: K): uint64 {.inline, raises: [].} =
  when compiles(hash(key)):
    when K is SomeInteger:
      var z = cast[uint64](key)
      z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
      z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
      z xor (z shr 31)
    else:
      var z = cast[uint64](hash(key))
      z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
      z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
      z xor (z shr 31)
  else:
    {.error: "Key type K must implement hash(key)".}

proc extractTag(h: uint64): uint8 {.inline, raises: [].} =
  let raw = uint8(h shr 56)
  if raw < 2'u8: raw + 2'u8 else: raw

proc calcOffsets[K, V](cap: int): tuple[totalBytes: int, alignVal: int, offKeys: int, offVals: int] {.inline, raises: [].} =
  let alignK = max(alignof(K), 1)
  let alignV = max(alignof(V), 1)
  let maxAlign = max(max(alignK, alignV), 8)
  let offKeys = int(alignForward(uint(cap * sizeof(uint8)), uint(alignK)))
  let offVals = int(alignForward(uint(offKeys + cap * sizeof(K)), uint(alignV)))
  let totalBytes = offVals + cap * sizeof(V)
  (totalBytes, maxAlign, offKeys, offVals)

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*[K, V](m: var BufMap[K, V]) {.raises: [].} =
  if not m.ctrl.isNil and m.cap > 0:
    for i in 0 ..< m.cap:
      if m.ctrl[i] >= 2'u8:
        `=destroy`(m.keys[i])
        `=destroy`(m.vals[i])
    let (totalBytes, _, _, _) = calcOffsets[K, V](m.cap)
    if not m.alloc.freeFn.isNil:
      m.alloc.dealloc(m.ctrl, totalBytes)
    m.ctrl = nil
    m.keys = nil
    m.vals = nil
    m.cap = 0
    m.mask = 0
    m.count = 0
    m.usedSlots = 0

proc `=wasMoved`*[K, V](m: var BufMap[K, V]) {.inline, raises: [].} =
  m.ctrl = nil
  m.keys = nil
  m.vals = nil
  m.cap = 0
  m.mask = 0
  m.count = 0
  m.usedSlots = 0

proc `=sink`*[K, V](dest: var BufMap[K, V], src: BufMap[K, V]) {.raises: [].} =
  if dest.ctrl != src.ctrl:
    `=destroy`(dest)
  dest.ctrl = src.ctrl
  dest.keys = src.keys
  dest.vals = src.vals
  dest.cap = src.cap
  dest.mask = src.mask
  dest.count = src.count
  dest.usedSlots = src.usedSlots
  dest.alloc = src.alloc

proc `=copy`*[K, V](dest: var BufMap[K, V], src: BufMap[K, V]) {.raises: [].} =
  if dest.ctrl == src.ctrl:
    return
  `=destroy`(dest)
  dest.alloc = src.alloc
  if src.cap == 0 or src.ctrl.isNil:
    dest.ctrl = nil
    dest.keys = nil
    dest.vals = nil
    dest.cap = 0
    dest.mask = 0
    dest.count = 0
    dest.usedSlots = 0
    return

  let (totalBytes, alignVal, offKeys, offVals) = calcOffsets[K, V](src.cap)
  let rawRes = dest.alloc.rawAlloc(totalBytes, alignVal)
  if rawRes.isOk:
    let raw = rawRes.get
    zeroMem(raw, totalBytes)
    dest.ctrl = cast[ptr UncheckedArray[uint8]](raw)
    dest.keys = cast[ptr UncheckedArray[K]](cast[uint](raw) + uint(offKeys))
    dest.vals = cast[ptr UncheckedArray[V]](cast[uint](raw) + uint(offVals))
    dest.cap = src.cap
    dest.mask = src.mask
    dest.count = src.count
    dest.usedSlots = src.usedSlots

    copyMem(dest.ctrl, src.ctrl, src.cap * sizeof(uint8))
    for i in 0 ..< src.cap:
      if src.ctrl[i] >= 2'u8:
        dest.keys[i] = src.keys[i]
        dest.vals[i] = src.vals[i]
  else:
    dest.ctrl = nil
    dest.keys = nil
    dest.vals = nil
    dest.cap = 0
    dest.mask = 0
    dest.count = 0
    dest.usedSlots = 0
    raise (ref Defect)(msg: "BufMap.=copy: out of memory")

# =============================================================================
# Construction & Operations
# =============================================================================

proc initBufMap*[K, V](alloc: Allocator, initialCap: int = 64): Result[BufMap[K, V], AllocError] {.raises: [].} =
  let cap = nextPow2((initialCap * 4 + 2) div 3)
  let (totalBytes, alignVal, offKeys, offVals) = calcOffsets[K, V](cap)
  let raw = ?alloc.rawAlloc(totalBytes, alignVal)
  zeroMem(raw, totalBytes)
  ok[BufMap[K, V], AllocError](BufMap[K, V](
    ctrl: cast[ptr UncheckedArray[uint8]](raw),
    keys: cast[ptr UncheckedArray[K]](cast[uint](raw) + uint(offKeys)),
    vals: cast[ptr UncheckedArray[V]](cast[uint](raw) + uint(offVals)),
    cap: cap,
    mask: cap - 1,
    count: 0,
    usedSlots: 0,
    alloc: alloc
  ))

proc deinit*[K, V](m: var BufMap[K, V]) {.inline, raises: [].} =
  `=destroy`(m)

proc len*[K, V](m: BufMap[K, V]): int {.inline, raises: [].} =
  m.count

proc cap*[K, V](m: BufMap[K, V]): int {.inline, raises: [].} =
  m.cap

proc isEmpty*[K, V](m: BufMap[K, V]): bool {.inline, raises: [].} =
  m.count == 0

proc clear*[K, V](m: var BufMap[K, V]) {.raises: [].} =
  if m.ctrl.isNil or m.cap == 0:
    return
  for i in 0 ..< m.cap:
    if m.ctrl[i] >= 2'u8:
      `=destroy`(m.keys[i])
      `=destroy`(m.vals[i])
      wasMoved(m.keys[i])
      wasMoved(m.vals[i])
  zeroMem(m.ctrl, m.cap * sizeof(uint8))
  m.count = 0
  m.usedSlots = 0

proc grow[K, V](m: var BufMap[K, V]): Result[void, AllocError] {.raises: [].} =
  let oldCap = m.cap
  let newCap = if oldCap == 0: 64 else: oldCap * 2
  let newMask = newCap - 1
  let (newBytes, newAlign, newOffKeys, newOffVals) = calcOffsets[K, V](newCap)

  let raw = ?m.alloc.rawAlloc(newBytes, newAlign)
  zeroMem(raw, newBytes)

  let newCtrl = cast[ptr UncheckedArray[uint8]](raw)
  let newKeys = cast[ptr UncheckedArray[K]](cast[uint](raw) + uint(newOffKeys))
  let newVals = cast[ptr UncheckedArray[V]](cast[uint](raw) + uint(newOffVals))

  for i in 0 ..< oldCap:
    let tag = m.ctrl[i]
    if tag >= 2'u8:
      let h = fastHash(m.keys[i])
      var idx = int(h and uint64(newMask))
      while newCtrl[idx] >= 2'u8:
        idx = (idx + 1) and newMask
      newCtrl[idx] = tag
      copyMem(addr newKeys[idx], addr m.keys[i], sizeof(K))
      copyMem(addr newVals[idx], addr m.vals[i], sizeof(V))
      wasMoved(m.keys[i])
      wasMoved(m.vals[i])

  let (oldBytes, _, _, _) = calcOffsets[K, V](oldCap)
  if not m.alloc.freeFn.isNil and oldCap > 0:
    m.alloc.dealloc(m.ctrl, oldBytes)

  m.ctrl = newCtrl
  m.keys = newKeys
  m.vals = newVals
  m.cap = newCap
  m.mask = newMask
  m.usedSlots = m.count
  ok(void, AllocError)

proc put*[K, V](m: var BufMap[K, V], key: K, val: V): Result[void, AllocError] {.inline, raises: [].} =
  if m.cap == 0 or (m.usedSlots + 1) * 4 >= m.cap * 3:
    ?m.grow()

  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask

  var idx = int(h and uint64(mask))
  var firstDeleted = -1

  while true:
    let c = m.ctrl[idx]
    if c == SlotEmpty:
      let target = if firstDeleted >= 0: firstDeleted else: idx
      if firstDeleted < 0:
        inc(m.usedSlots)
      m.ctrl[target] = tag
      var kCopy = key
      var vCopy = val
      copyMem(addr m.keys[target], addr kCopy, sizeof(K))
      copyMem(addr m.vals[target], addr vCopy, sizeof(V))
      wasMoved(kCopy)
      wasMoved(vCopy)
      inc(m.count)
      return ok(void, AllocError)
    elif c == tag and m.keys[idx] == key:
      m.vals[idx] = val
      return ok(void, AllocError)
    elif c == SlotDeleted and firstDeleted < 0:
      firstDeleted = idx
    idx = (idx + 1) and mask

proc get*[K, V](m: BufMap[K, V], key: K): Option[V] {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.isNil:
    return none[V]()
  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask

  var idx = int(h and uint64(mask))
  while true:
    let c = m.ctrl[idx]
    if c == tag and m.keys[idx] == key:
      return some[V](m.vals[idx])
    elif c == SlotEmpty:
      return none[V]()
    idx = (idx + 1) and mask

proc contains*[K, V](m: BufMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.isNil:
    return false
  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask

  var idx = int(h and uint64(mask))
  while true:
    let c = m.ctrl[idx]
    if c == tag and m.keys[idx] == key:
      return true
    elif c == SlotEmpty:
      return false
    idx = (idx + 1) and mask

proc del*[K, V](m: var BufMap[K, V], key: K): bool {.raises: [].} =
  if m.count == 0 or m.ctrl.isNil:
    return false
  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask

  var idx = int(h and uint64(mask))
  while true:
    let c = m.ctrl[idx]
    if c == tag and m.keys[idx] == key:
      m.ctrl[idx] = SlotDeleted
      `=destroy`(m.keys[idx])
      `=destroy`(m.vals[idx])
      wasMoved(m.keys[idx])
      wasMoved(m.vals[idx])
      dec(m.count)
      return true
    elif c == SlotEmpty:
      return false
    idx = (idx + 1) and mask

iterator pairs*[K, V](m: BufMap[K, V]): tuple[key: K, val: V] {.inline.} =
  if not m.ctrl.isNil:
    for i in 0 ..< m.cap:
      if m.ctrl[i] >= 2'u8:
        yield (m.keys[i], m.vals[i])

iterator keys*[K, V](m: BufMap[K, V]): K {.inline.} =
  if not m.ctrl.isNil:
    for i in 0 ..< m.cap:
      if m.ctrl[i] >= 2'u8:
        yield m.keys[i]

iterator values*[K, V](m: BufMap[K, V]): V {.inline.} =
  if not m.ctrl.isNil:
    for i in 0 ..< m.cap:
      if m.ctrl[i] >= 2'u8:
        yield m.vals[i]
