## algx/zeropack — Zero-Overhead Бинарная и JSON Сериализация на этапе компиляции
##
## Чем лучше `serde` в Rust и `std/json` в Nim:
## 1. Не требует процедурных макро-крейтов (`syn`/`quote`/`serde_derive`), тормозящих компиляцию.
## 2. Автоматически определяет на этапе компиляции (`when isBlittable(T)`), состоит ли структура/массив
##    из плоских примитивов (POD), и копирует целые массивы структур за ОДНУ инструкцию `copyMem`!
## 3. Генерирует JSON напрямую в преаллоцированный буфер без создания `JsonNode` дерева в куче.

import std/[typetraits, strutils]

{.push checks: off, optimization: speed.}

template isBlittable*(T: typedesc): bool =
  ## Проверяет на этапе компиляции, можно ли копировать тип `T` напрямую побайтово (Zero-Copy POD).
  supportsCopyMem(T)

# =============================================================================
# 1. Сверхбыстрая бинарная сериализация (Zero-Copy POD + рекурсивный обход)
# =============================================================================

proc writeBin*[T](buf: var seq[byte], offset: var int, val: T) {.inline, raises: [].} =
  when T is SomeNumber or T is bool or T is char or T is enum:
    let sz = sizeof(T)
    if offset + sz > buf.len:
      buf.setLen(max(buf.len * 2, offset + sz + 64))
    copyMem(addr buf[offset], unsafeAddr val, sz)
    offset += sz
  elif T is string:
    let n = int32(val.len)
    writeBin(buf, offset, n)
    if n > 0:
      if offset + int(n) > buf.len:
        buf.setLen(max(buf.len * 2, offset + int(n) + 64))
      copyMem(addr buf[offset], unsafeAddr val[0], int(n))
      offset += int(n)
  elif T is seq:
    type ElemT = typeof(val[0])
    let n = int32(val.len)
    writeBin(buf, offset, n)
    if n > 0:
      when isBlittable(ElemT):
        let totalBytes = int(n) * sizeof(ElemT)
        if offset + totalBytes > buf.len:
          buf.setLen(max(buf.len * 2, offset + totalBytes + 64))
        copyMem(addr buf[offset], unsafeAddr val[0], totalBytes)
        offset += totalBytes
      else:
        for i in 0 ..< val.len:
          writeBin(buf, offset, val[i])
  elif T is object or T is tuple:
    when isBlittable(T):
      let sz = sizeof(T)
      if offset + sz > buf.len:
        buf.setLen(max(buf.len * 2, offset + sz + 64))
      copyMem(addr buf[offset], unsafeAddr val, sz)
      offset += sz
    else:
      for _, fieldVal in fieldPairs(val):
        writeBin(buf, offset, fieldVal)

proc readBin*[T](buf: openArray[byte], offset: var int, outVal: var T) {.inline, raises: [].} =
  when T is SomeNumber or T is bool or T is char or T is enum:
    let sz = sizeof(T)
    copyMem(addr outVal, unsafeAddr buf[offset], sz)
    offset += sz
  elif T is string:
    var n: int32
    readBin(buf, offset, n)
    outVal.setLen(int(n))
    if n > 0:
      copyMem(addr outVal[0], unsafeAddr buf[offset], int(n))
      offset += int(n)
  elif T is seq:
    type ElemT = typeof(outVal[0])
    var n: int32
    readBin(buf, offset, n)
    outVal.setLen(int(n))
    if n > 0:
      when isBlittable(ElemT):
        let totalBytes = int(n) * sizeof(ElemT)
        copyMem(addr outVal[0], unsafeAddr buf[offset], totalBytes)
        offset += totalBytes
      else:
        for i in 0 ..< int(n):
          readBin(buf, offset, outVal[i])
  elif T is object or T is tuple:
    when isBlittable(T):
      let sz = sizeof(T)
      copyMem(addr outVal, unsafeAddr buf[offset], sz)
      offset += sz
    else:
      for _, fieldVal in fieldPairs(outVal):
        readBin(buf, offset, fieldVal)

proc packBin*[T](val: T, initialCap: int = 256): seq[byte] {.inline, raises: [].} =
  when T is seq:
    type ElemT = typeof(val[0])
    when isBlittable(ElemT):
      let n = int32(val.len)
      let payloadBytes = val.len * sizeof(ElemT)
      result = newSeqUninit[byte](4 + payloadBytes)
      copyMem(addr result[0], unsafeAddr n, 4)
      if payloadBytes > 0:
        copyMem(addr result[4], unsafeAddr val[0], payloadBytes)
    else:
      result = newSeqUninit[byte](max(16, initialCap))
      var offset = 0
      writeBin(result, offset, val)
      result.setLen(offset)
  else:
    result = newSeqUninit[byte](max(16, initialCap))
    var offset = 0
    writeBin(result, offset, val)
    result.setLen(offset)

proc unpackBin*[T](buf: openArray[byte]): T {.inline, raises: [].} =
  when T is seq:
    type ElemT = typeof(result[0])
    when isBlittable(ElemT):
      var n: int32
      copyMem(addr n, unsafeAddr buf[0], 4)
      if n > 0:
        result = newSeqUninit[ElemT](int(n))
        copyMem(addr result[0], unsafeAddr buf[4], int(n) * sizeof(ElemT))
    else:
      var offset = 0
      readBin(buf, offset, result)
  else:
    var offset = 0
    readBin(buf, offset, result)

# =============================================================================
# 2. Zero-DOM Генерация JSON напрямую в строковый буфер (`toJsonFast`)
# =============================================================================

proc appendFastInt*(dst: var string, v: int64) {.inline, raises: [].} =
  if v == 0:
    dst.add('0')
    return
  var u = if v < 0:
    dst.add('-')
    uint64(-v)
  else:
    uint64(v)
  var tmp: array[20, char]
  var idx = 0
  while u > 0'u64:
    tmp[idx] = char(ord('0') + int(u mod 10'u64))
    u = u div 10'u64
    inc(idx)
  while idx > 0:
    dec(idx)
    dst.add(tmp[idx])

proc appendJsonFast*[T](dst: var string, val: T) {.inline, raises: [].} =
  when T is SomeSignedInt:
    appendFastInt(dst, int64(val))
  elif T is SomeUnsignedInt:
    appendFastInt(dst, int64(val))
  elif T is SomeFloat:
    dst.addFloat(float(val))
  elif T is bool:
    if val: dst.add("true") else: dst.add("false")
  elif T is string:
    dst.add('"')
    dst.add(val)
    dst.add('"')
  elif T is seq or T is array:
    dst.add('[')
    for i in 0 ..< val.len:
      if i > 0: dst.add(',')
      appendJsonFast(dst, val[i])
    dst.add(']')
  elif T is object or T is tuple:
    dst.add('{')
    var first = true
    for fName, fVal in fieldPairs(val):
      if not first: dst.add(',')
      first = false
      dst.add('"')
      dst.add(fName)
      dst.add("\":")
      appendJsonFast(dst, fVal)
    dst.add('}')

proc toJsonFast*[T](val: T, initialCap: int = 128): string {.inline, raises: [].} =
  result = newStringOfCap(initialCap)
  appendJsonFast(result, val)

{.pop.}
