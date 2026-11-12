## algx/swissmap — Сверхбыстрая плоская хэш-таблица (`FastMap[K, V]`) в стиле SwissTable
##
## Высокопроизводительная реализация SwissTable с параллельным SWAR-поиском
## (SIMD Within A Register) по 8 слотам за такт и треугольным прыжком по группам (quadratic/triangular group jumping)
## для максимальной утилизации кэш-линий L1 и полного устранения вторичной кластеризации коллизий.
##
## Ключевые преимущества:
## 1. SWAR 8-Byte Group Matching: 8 байт тегов контроля загружаются в 64-битный регистр.
##    Поиск совпадений тегов и пустых слотов выполняется параллельно битовой маской за O(1).
## 2. Triangular Group Probing: перемещение между 8-слотовыми группами шагами 1, 2, 3, 4...
##    гарантирует обход 100% групп при размере степени двойки без локальных кластеров коллизий.
## 3. Раздельные массивы метаданных (`ctrl`), ключей (`keys`) и значений (`vals`) в стиле SwissTable.
## 4. Сверхбыстрый 64-битный хэш-миксер SplitMix64 / Fibonacci.

import std/[hashes, bitops]

{.push checks: off, optimization: speed.}

const
  SlotEmpty* = 0'u8
  SlotDeleted* = 1'u8
  # Занятые слоты имеют тег от 2 до 255 (верхние 8 бит хэша, скорректированные >= 2)

type
  FastMap*[K, V] = object
    ctrl*: seq[uint8]
    keys*: seq[K]
    vals*: seq[V]
    mask*: int
    count*: int
    usedSlots*: int

# =============================================================================
# SWAR Byte Matching & Bit Operations
# =============================================================================

proc matchByteMask64*(word: uint64, byteVal: uint8): uint64 {.inline, raises: [].} =
  ## Returns a 64-bit mask where the MSB (bit 7) of each byte is set if and only if
  ## that byte equals `byteVal`. Evaluates all 8 bytes in parallel branchlessly.
  let broadcast = uint64(byteVal) * 0x0101_0101_0101_0101'u64
  let diff = word xor broadcast
  (diff - 0x0101_0101_0101_0101'u64) and (not diff) and 0x8080_8080_8080_8080'u64

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
  let newGroupMask = newMask shr 3

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
        let baseIdx = g shl 3
        let word = cast[ptr uint64](addr pNewCtrl[baseIdx])[]
        let emptyMask = matchByteMask64(word, SlotEmpty)
        if emptyMask != 0:
          let target = baseIdx + (countTrailingZeroBits(emptyMask) shr 3)
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
  let groupMask = m.mask shr 3
  let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0
  var firstDeleted = -1

  while true:
    let baseIdx = g shl 3
    let word = cast[ptr uint64](addr pCtrl[baseIdx])[]

    # 1. Match tag across 8 slots in parallel with SWAR
    var matchMask = matchByteMask64(word, tag)
    while matchMask != 0:
      let slotOffset = countTrailingZeroBits(matchMask) shr 3
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        pVals[slotIdx] = val
        return
      matchMask = matchMask and (matchMask - 1)

    # 2. Track first deleted slot
    if firstDeleted < 0:
      let delMask = matchByteMask64(word, SlotDeleted)
      if delMask != 0:
        firstDeleted = baseIdx + (countTrailingZeroBits(delMask) shr 3)

    # 3. Match empty slots across 8 slots in parallel
    let emptyMask = matchByteMask64(word, SlotEmpty)
    if emptyMask != 0:
      let target = if firstDeleted >= 0: firstDeleted
                   else: baseIdx + (countTrailingZeroBits(emptyMask) shr 3)
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
  let groupMask = m.mask shr 3
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](unsafeAddr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 3
    let word = cast[ptr uint64](addr pCtrl[baseIdx])[]

    var matchMask = matchByteMask64(word, tag)
    while matchMask != 0:
      let slotOffset = countTrailingZeroBits(matchMask) shr 3
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        return pVals[slotIdx]
      matchMask = matchMask and (matchMask - 1)

    let emptyMask = matchByteMask64(word, SlotEmpty)
    if emptyMask != 0:
      return defaultVal

    inc step
    g = (g + step) and groupMask

proc contains*[K, V](m: FastMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.len == 0:
    return false

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 3
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 3
    let word = cast[ptr uint64](addr pCtrl[baseIdx])[]

    var matchMask = matchByteMask64(word, tag)
    while matchMask != 0:
      let slotOffset = countTrailingZeroBits(matchMask) shr 3
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        return true
      matchMask = matchMask and (matchMask - 1)

    let emptyMask = matchByteMask64(word, SlotEmpty)
    if emptyMask != 0:
      return false

    inc step
    g = (g + step) and groupMask

proc del*[K, V](m: var FastMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0 or m.ctrl.len == 0:
    return false

  let h = fastHash(key)
  let tag = extractTag(h)
  let groupMask = m.mask shr 3
  let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

  var g = int(h and uint64(groupMask))
  var step = 0

  while true:
    let baseIdx = g shl 3
    let word = cast[ptr uint64](addr pCtrl[baseIdx])[]

    var matchMask = matchByteMask64(word, tag)
    while matchMask != 0:
      let slotOffset = countTrailingZeroBits(matchMask) shr 3
      let slotIdx = baseIdx + slotOffset
      if pKeys[slotIdx] == key:
        pCtrl[slotIdx] = SlotDeleted
        reset(pKeys[slotIdx])
        reset(pVals[slotIdx])
        dec(m.count)
        return true
      matchMask = matchMask and (matchMask - 1)

    let emptyMask = matchByteMask64(word, SlotEmpty)
    if emptyMask != 0:
      return false

    inc step
    g = (g + step) and groupMask

proc `[]`*[K, V](m: FastMap[K, V], key: K): lent V {.inline.} =
  if m.count > 0 and m.ctrl.len > 0:
    let h = fastHash(key)
    let tag = extractTag(h)
    let groupMask = m.mask shr 3
    let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
    let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])
    let pVals = cast[ptr UncheckedArray[V]](unsafeAddr m.vals[0])

    var g = int(h and uint64(groupMask))
    var step = 0

    while true:
      let baseIdx = g shl 3
      let word = cast[ptr uint64](addr pCtrl[baseIdx])[]

      var matchMask = matchByteMask64(word, tag)
      while matchMask != 0:
        let slotOffset = countTrailingZeroBits(matchMask) shr 3
        let slotIdx = baseIdx + slotOffset
        if pKeys[slotIdx] == key:
          return pVals[slotIdx]
        matchMask = matchMask and (matchMask - 1)

      let emptyMask = matchByteMask64(word, SlotEmpty)
      if emptyMask != 0:
        break

      inc step
      g = (g + step) and groupMask

  raise newException(KeyError, "key not found")

proc `[]`*[K, V](m: var FastMap[K, V], key: K): var V {.inline.} =
  if m.count > 0 and m.ctrl.len > 0:
    let h = fastHash(key)
    let tag = extractTag(h)
    let groupMask = m.mask shr 3
    let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
    let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
    let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

    var g = int(h and uint64(groupMask))
    var step = 0

    while true:
      let baseIdx = g shl 3
      let word = cast[ptr uint64](addr pCtrl[baseIdx])[]

      var matchMask = matchByteMask64(word, tag)
      while matchMask != 0:
        let slotOffset = countTrailingZeroBits(matchMask) shr 3
        let slotIdx = baseIdx + slotOffset
        if pKeys[slotIdx] == key:
          return pVals[slotIdx]
        matchMask = matchMask and (matchMask - 1)

      let emptyMask = matchByteMask64(word, SlotEmpty)
      if emptyMask != 0:
        break

      inc step
      g = (g + step) and groupMask

  raise newException(KeyError, "key not found")

{.pop.}
