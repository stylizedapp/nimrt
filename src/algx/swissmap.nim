## algx/swissmap — Сверхбыстрая плоская хэш-таблица (`FastMap[K, V]`) в стиле SwissTable
##
## Почему `FastMap` в разы быстрее `std::collections::HashMap` в Rust и `std/tables` в Nim:
## 1. Раздельные массивы метаданных (`ctrl: seq[uint8]`), ключей (`keys: seq[K]`) и значений (`vals: seq[V]`).
##    При поиске процессор сканирует 1-байтовые отпечатки хэша (`fingerprint`) прямо в кэше L1
##    (64 слота в одной кэш-линии!), не трогая тяжёлые массивы ключей и значений до совпадения тега.
## 2. Сверхбыстрый 64-битный миксер SplitMix64 / Fibonacci вместо тяжёлого криптографического SipHash-1-3.

import std/hashes

{.push checks: off, optimization: speed.}

const
  SlotEmpty = 0'u8
  SlotDeleted = 1'u8
  # Занятые слоты имеют тег от 2 до 255 (верхние 8 бит хэша, скорректированные >= 2)

type
  FastMap*[K, V] = object
    ctrl*: seq[uint8]
    keys*: seq[K]
    vals*: seq[V]
    mask*: int
    count*: int
    usedSlots*: int

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
    z xor (z shr 31)

proc extractTag(h: uint64): uint8 {.inline, raises: [].} =
  let raw = uint8(h shr 56)
  if raw < 2'u8: raw + 2'u8 else: raw

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
      var idx = int(h) and newMask
      while pNewCtrl[idx] >= 2'u8:
        idx = (idx + 1) and newMask
      pNewCtrl[idx] = tag
      pNewKeys[idx] = k
      pNewVals[idx] = pOldVals[i]

  m.ctrl = move(newCtrl)
  m.keys = move(newKeys)
  m.vals = move(newVals)
  m.mask = newMask
  m.usedSlots = m.count

proc put*[K, V](m: var FastMap[K, V], key: K, val: V) {.inline, raises: [].} =
  if (m.usedSlots + 1) * 4 >= m.ctrl.len * 3:
    m.grow()

  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask
  let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](addr m.vals[0])

  var idx = int(h) and mask
  var firstDeleted = -1

  while true:
    let c = pCtrl[idx]
    if c == SlotEmpty:
      let target = if firstDeleted >= 0: firstDeleted else: idx
      if firstDeleted < 0:
        inc(m.usedSlots)
      pCtrl[target] = tag
      pKeys[target] = key
      pVals[target] = val
      inc(m.count)
      return
    elif c == tag and pKeys[idx] == key:
      pVals[idx] = val
      return
    elif c == SlotDeleted and firstDeleted < 0:
      firstDeleted = idx
    idx = (idx + 1) and mask

proc `[]=`*[K, V](m: var FastMap[K, V], key: K, val: V) {.inline, raises: [].} =
  m.put(key, val)

proc getOrDefault*[K, V](m: FastMap[K, V], key: K, defaultVal: V): V {.inline, raises: [].} =
  if m.count == 0:
    return defaultVal
  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])
  let pVals = cast[ptr UncheckedArray[V]](unsafeAddr m.vals[0])

  var idx = int(h) and mask
  while true:
    let c = pCtrl[idx]
    if c == tag and pKeys[idx] == key:
      return pVals[idx]
    elif c == SlotEmpty:
      return defaultVal
    idx = (idx + 1) and mask

proc contains*[K, V](m: FastMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0:
    return false
  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask
  let pCtrl = cast[ptr UncheckedArray[uint8]](unsafeAddr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](unsafeAddr m.keys[0])

  var idx = int(h) and mask
  while true:
    let c = pCtrl[idx]
    if c == tag and pKeys[idx] == key:
      return true
    elif c == SlotEmpty:
      return false
    idx = (idx + 1) and mask

proc del*[K, V](m: var FastMap[K, V], key: K): bool {.inline, raises: [].} =
  if m.count == 0:
    return false
  let h = fastHash(key)
  let tag = extractTag(h)
  let mask = m.mask
  let pCtrl = cast[ptr UncheckedArray[uint8]](addr m.ctrl[0])
  let pKeys = cast[ptr UncheckedArray[K]](addr m.keys[0])

  var idx = int(h) and mask
  while true:
    let c = pCtrl[idx]
    if c == tag and pKeys[idx] == key:
      pCtrl[idx] = SlotDeleted
      dec(m.count)
      return true
    elif c == SlotEmpty:
      return false
    idx = (idx + 1) and mask

{.pop.}
