## algx/swissmap — Сверхбыстрая плоская хэш-таблица (`FastMap[K, V]`) в стиле SwissTable
##
## Высокопроизводительная реализация SwissTable с параллельным 16-байтовым SSE2-поиском
## (`_mm_cmpeq_epi8` + `_mm_movemask_epi8` на x86/amd64, с 16-байтовым SWAR фоллбэком)
## по 16 слотам за такт и треугольным прыжком по группам (quadratic/triangular group jumping)
## для максимальной утилизации кэш-линий L1 и полного устранения вторичной кластеризации коллизий.
##
## Ключевые преимущества:
## 1. SSE2 16-Byte Group Matching: 16 байт тегов контроля загружаются в 128-битный XMM-регистр.
##    Поиск совпадений тегов, удалённых и пустых слотов выполняется параллельно битовой маской за O(1).
## 2. Triangular Group Probing: перемещение между 16-слотовыми группами шагами 1, 2, 3, 4...
##    гарантирует обход 100% групп при размере степени двойки без локальных кластеров коллизий.
## 3. Раздельные массивы метаданных (`ctrl`), ключей (`keys`) и значений (`vals`) в стиле SwissTable.
## 4. Сверхбыстрый 64-битный хэш-миксер SplitMix64.

import std/bitops
import corex/adt
export adt

when defined(release) or defined(danger):
  {.push checks: off, optimization: speed.}
else:
  {.push optimization: speed.}

const
  SlotEmpty* = 0'u8
  SlotDeleted* = 1'u8
  # Занятые слоты имеют тег от 2 до 255 (верхние 8 бит хэша, скорректированные >= 2)
  GroupWidth* = 16
  UseSse2* = (defined(x86) or defined(amd64)) and not defined(noSse2)

type
  FastMap*[K, V] = object
    ctrl*: seq[uint8]
    keys*: seq[K]
    vals*: seq[V]
    mask*: int
    count*: int
    usedSlots*: int

# =============================================================================
# SWAR & SSE2 16-Byte Group Matching
# =============================================================================

proc matchByteMask64*(word: uint64, byteVal: uint8): uint64 {.inline, raises: [].} =
  ## Returns a 64-bit mask where the MSB (bit 7) of each byte is set if and only if
  ## that byte equals `byteVal`. Evaluates all 8 bytes in parallel branchlessly.
  let broadcast = uint64(byteVal) * 0x0101_0101_0101_0101'u64
  let diff = word xor broadcast
  (diff - 0x0101_0101_0101_0101'u64) and (not diff) and 0x8080_8080_8080_8080'u64

when UseSse2:
  type
    M128i {.importc: "__m128i", header: "<emmintrin.h>".} = object
    CtrlGroup = M128i

  proc mm_loadu_si128(p: ptr M128i): M128i {.importc: "_mm_loadu_si128", header: "<emmintrin.h>".}
  proc mm_setzero_si128(): M128i {.importc: "_mm_setzero_si128", header: "<emmintrin.h>".}
  proc mm_set1_epi8(b: int8): M128i {.importc: "_mm_set1_epi8", header: "<emmintrin.h>".}
  proc mm_cmpeq_epi8(a, b: M128i): M128i {.importc: "_mm_cmpeq_epi8", header: "<emmintrin.h>".}
  proc mm_movemask_epi8(a: M128i): int32 {.importc: "_mm_movemask_epi8", header: "<emmintrin.h>".}

  proc loadCtrlGroup(p: ptr uint8): CtrlGroup {.inline, raises: [].} =
    mm_loadu_si128(cast[ptr M128i](p))

  proc matchGroupTag(grp: CtrlGroup, byteVal: uint8): uint32 {.inline, raises: [].} =
    uint32(mm_movemask_epi8(mm_cmpeq_epi8(grp, mm_set1_epi8(cast[int8](byteVal)))))

  proc matchGroupEmpty(grp: CtrlGroup): uint32 {.inline, raises: [].} =
    uint32(mm_movemask_epi8(mm_cmpeq_epi8(grp, mm_setzero_si128())))

  proc matchGroupDeleted(grp: CtrlGroup): uint32 {.inline, raises: [].} =
    uint32(mm_movemask_epi8(mm_cmpeq_epi8(grp, mm_set1_epi8(cast[int8](SlotDeleted)))))

else:
  type
    CtrlGroup = array[2, uint64]

  proc loadCtrlGroup(p: ptr uint8): CtrlGroup {.inline, raises: [].} =
    cast[ptr array[2, uint64]](p)[]

  proc packMask64To8(m: uint64): uint32 {.inline, raises: [].} =
    uint32((((m shr 7) * 0x0102_0408_1020_4080'u64) shr 56) and 0xFF'u64)

  proc matchGroupTag(grp: CtrlGroup, byteVal: uint8): uint32 {.inline, raises: [].} =
    let lo = packMask64To8(matchByteMask64(grp[0], byteVal))
    let hi = packMask64To8(matchByteMask64(grp[1], byteVal))
    lo or (hi shl 8)

  proc matchGroupEmpty(grp: CtrlGroup): uint32 {.inline, raises: [].} =
    matchGroupTag(grp, SlotEmpty)

  proc matchGroupDeleted(grp: CtrlGroup): uint32 {.inline, raises: [].} =
    matchGroupTag(grp, SlotDeleted)

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

proc splitMix64*(z0: uint64): uint64 {.inline, raises: [].} =
  var z = z0
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

proc hashBytes64*(p: pointer, length: int): uint64 {.inline, raises: [].} =
  var h = 0xCBF2_9CE4_8422_2325'u64
  if p != nil and length > 0:
    let bytes = cast[ptr UncheckedArray[byte]](p)
    var i = 0
    while i + 8 <= length:
      var w: uint64
      copyMem(addr w, addr bytes[i], 8)
      h = splitMix64(h xor w)
      i += 8
    while i < length:
      h = (h xor uint64(bytes[i])) * 0x0000_0100_0000_01B3'u64
      inc(i)
  splitMix64(h xor uint64(length))

proc fastHash*[K](key: K): uint64 {.inline, raises: [].} =
  when K is SomeInteger:
    when K is SomeUnsignedInt:
      splitMix64(uint64(key))
    else:
      splitMix64(cast[uint64](int64(key)))
  elif K is enum:
    splitMix64(uint64(ord(key)))
  elif K is pointer or K is ptr:
    splitMix64(cast[uint64](key))
  elif K is string:
    hashBytes64(if key.len > 0: unsafeAddr key[0] else: nil, key.len)
  else:
    mixin hash
    when compiles(hash(key)):
      splitMix64(cast[uint64](int64(hash(key))))
    else:
      hashBytes64(unsafeAddr key, sizeof(K))

proc extractTag(h: uint64): uint8 {.inline, raises: [].} =
  let raw = uint8(h shr 56)
  if raw < 2'u8: raw + 2'u8 else: raw

# =============================================================================
# Construction & Query API
# =============================================================================

proc initFastMap*[K, V](initialCapacity: int = 64): FastMap[K, V] {.inline, raises: [].} =
  let cap = nextPow2((initialCapacity * 4 + 2) div 3)
  FastMap[K, V](
    ctrl: newSeq[uint8](cap),
    keys: newSeq[K](cap),
    vals: newSeq[V](cap),
    mask: cap - 1,
    count: 0,
    usedSlots: 0
  )

proc len*[K, V](m: FastMap[K, V]): int {.inline, raises: [].} =
  m.count

proc clear*[K, V](m: var FastMap[K, V]) {.inline, raises: [].} =
  if m.ctrl.len > 0:
    zeroMem(addr m.ctrl[0], m.ctrl.len)
  m.count = 0
  m.usedSlots = 0

proc grow[K, V](m: var FastMap[K, V]) {.raises: [].} =
  let oldCap = m.ctrl.len
  let newCap = if oldCap == 0: 64 else: oldCap * 2
  let newMask = newCap - 1
  let newGroupMask = newMask shr 4

  var newCtrl = newSeq[uint8](newCap)
  var newKeys = newSeq[K](newCap)
  var newVals = newSeq[V](newCap)

  let pOldCtrl = if oldCap > 0: cast[ptr UncheckedArray[uint8]](addr m.ctrl[0]) else: nil
  let pOldKeys = if oldCap > 0: cast[ptr UncheckedArray[K]](addr m.keys[0]) else: nil
  let pOldVals = if oldCap > 0: cast[ptr UncheckedArray[V]](addr m.vals[0]) else: nil

  let pNewCtrl = cast[ptr UncheckedArray[uint8]](addr newCtrl[0])
  let pNewKeys = cast[ptr UncheckedArray[K]](addr newKeys[0])
  let pNewVals = cast[ptr UncheckedArray[V]](addr newVals[0])

  for i in 0 ..< oldCap:
    let tag = pOldCtrl[i]
    if tag >= 2'u8:
      let k = pOldKeys[i]
      let h = fastHash(k)
      var g = int(h and uint64(newGroupMask))
      var step = 0
      while true:
        let baseIdx = g shl 4
        let grp = loadCtrlGroup(addr pNewCtrl[baseIdx])
        let emptyMask = matchGroupEmpty(grp)
        if emptyMask != 0'u32:
          let target = baseIdx + countTrailingZeroBits(emptyMask)
          pNewCtrl[target] = tag
          pNewKeys[target] = k
          pNewVals[target] = pOldVals[i]
          break
        inc step
        g = (g + step) and newGroupMask

  m.ctrl = move(newCtrl)
  m.keys = move(newKeys)
  m.vals = move(newVals)
  m.mask = newMask
  m.usedSlots = m.count

proc put*[K, V](m: var FastMap[K, V], key: K, val: V) {.inline, raises: [].} =
  if m.ctrl.len == 0 or (m.usedSlots + 1) * 4 >= m.ctrl.len * 3:
    m.grow()

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 4
  let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0
  var firstDeleted = -1

  while true:
    let baseIdx = g shl 4
    let grp = loadCtrlGroup(addr pCtrl[baseIdx])

    # 1. Match tag across 16 slots in parallel with SSE2
    var matchMask = matchGroupTag(grp, tag)
    while matchMask != 0'u32:
      let slotOffset = countTrailingZeroBits(matchMask)
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        pVals[slotIdx] = val
        return
      matchMask = matchMask and (matchMask - 1'u32)

    # 2. Track first deleted slot
    if firstDeleted < 0:
      let delMask = matchGroupDeleted(grp)
      if delMask != 0'u32:
        firstDeleted = baseIdx + countTrailingZeroBits(delMask)

    # 3. Match empty slots across 16 slots in parallel
    let emptyMask = matchGroupEmpty(grp)
    if emptyMask != 0'u32:
      let target = if firstDeleted >= 0: firstDeleted
                   else: baseIdx + countTrailingZeroBits(emptyMask)
      if firstDeleted < 0:
        inc(m.usedSlots)
      pCtrl[target] = tag
      pKeys[target] = key
      pVals[target] = val
      inc(m.count)
      return

    # 4. Triangular / quadratic group jumping
    inc step
    g = (g + step) and groupMask

proc `[]=`*[K, V](m: var FastMap[K, V], key: K, val: V) {.inline, raises: [].} =
  m.put(key, val)

proc getOrDefault*[K, V](m: FastMap[K, V], key: K, defaultVal: V): V {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.len == 0:
    return defaultVal

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 4
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](unsafeAddr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 4
    let grp = loadCtrlGroup(addr pCtrl[baseIdx])

    var matchMask = matchGroupTag(grp, tag)
    while matchMask != 0'u32:
      let slotOffset = countTrailingZeroBits(matchMask)
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        return pVals[slotIdx]
      matchMask = matchMask and (matchMask - 1'u32)

    let emptyMask = matchGroupEmpty(grp)
    if emptyMask != 0'u32:
      return defaultVal

    inc step
    g = (g + step) and groupMask

proc getOrDefault*[K, V](m: FastMap[K, V], key: K): V {.inline, raises: [].} =
  getOrDefault(m, key, default(V))

proc contains*[K, V](m: FastMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.len == 0:
    return false

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 4
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 4
    let grp = loadCtrlGroup(addr pCtrl[baseIdx])

    var matchMask = matchGroupTag(grp, tag)
    while matchMask != 0'u32:
      let slotOffset = countTrailingZeroBits(matchMask)
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        return true
      matchMask = matchMask and (matchMask - 1'u32)

    let emptyMask = matchGroupEmpty(grp)
    if emptyMask != 0'u32:
      return false

    inc step
    g = (g + step) and groupMask

proc del*[K, V](m: var FastMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.len == 0:
    return false

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 4
  let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 4
    let grp = loadCtrlGroup(addr pCtrl[baseIdx])

    var matchMask = matchGroupTag(grp, tag)
    while matchMask != 0'u32:
      let slotOffset = countTrailingZeroBits(matchMask)
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        pCtrl[slotIdx] = SlotDeleted
        reset(pKeys[slotIdx])
        reset(pVals[slotIdx])
        dec(m.count)
        return true
      matchMask = matchMask and (matchMask - 1'u32)

    let emptyMask = matchGroupEmpty(grp)
    if emptyMask != 0'u32:
      return false

    inc step
    g = (g + step) and groupMask

proc get*[K, V](m: FastMap[K, V], key: K): Option[V] {.inline, raises: [].} =
  ## Safe non-panicking lookup returning Some(val) or None if key is absent.
  if m.count == 0 or m.ctrl.len == 0:
    return none(V)

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 4
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](unsafeAddr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 4
    let grp = loadCtrlGroup(addr pCtrl[baseIdx])

    var matchMask = matchGroupTag(grp, tag)
    while matchMask != 0'u32:
      let slotOffset = countTrailingZeroBits(matchMask)
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        return some(pVals[slotIdx])
      matchMask = matchMask and (matchMask - 1'u32)

    let emptyMask = matchGroupEmpty(grp)
    if emptyMask != 0'u32:
      return none(V)

    inc step
    g = (g + step) and groupMask

proc `[]`*[K, V](m: FastMap[K, V], key: K): lent V {.inline, raises: [].} =
  if m.count > 0 and m.ctrl.len > 0:
    let h = fastHash(key)
    let tag = extractTag(h)
    let groupMask = m.mask shr 4
    let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
    let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])
    let pVals = cast[ptr UncheckedArray[V]](unsafeAddr m.vals[0])

    var g = int(h and uint64(groupMask))
    var step = 0

    while true:
      let baseIdx = g shl 4
      let grp = loadCtrlGroup(addr pCtrl[baseIdx])

      var matchMask = matchGroupTag(grp, tag)
      while matchMask != 0'u32:
        let slotOffset = countTrailingZeroBits(matchMask)
        let slotIdx = baseIdx + slotOffset
        if pKeys[slotIdx] == key:
          return pVals[slotIdx]
        matchMask = matchMask and (matchMask - 1'u32)

      let emptyMask = matchGroupEmpty(grp)
      if emptyMask != 0'u32:
        break

      inc step
      g = (g + step) and groupMask

  raiseAssert("FastMap[]: key not found")

proc `[]`*[K, V](m: var FastMap[K, V], key: K): var V {.inline, raises: [].} =
  if m.count > 0 and m.ctrl.len > 0:
    let h = fastHash(key)
    let tag = extractTag(h)
    let groupMask = m.mask shr 4
    let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
    let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
    let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

    var g = int(h and uint64(groupMask))
    var step = 0

    while true:
      let baseIdx = g shl 4
      let grp = loadCtrlGroup(addr pCtrl[baseIdx])

      var matchMask = matchGroupTag(grp, tag)
      while matchMask != 0'u32:
        let slotOffset = countTrailingZeroBits(matchMask)
        let slotIdx = baseIdx + slotOffset
        if pKeys[slotIdx] == key:
          return pVals[slotIdx]
        matchMask = matchMask and (matchMask - 1'u32)

      let emptyMask = matchGroupEmpty(grp)
      if emptyMask != 0'u32:
        break

      inc step
      g = (g + step) and groupMask

  raiseAssert("FastMap[]: key not found")

{.pop.}
