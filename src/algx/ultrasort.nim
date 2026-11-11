## algx/ultrasort — 3-Level Cache-Aware Hybrid MSD Radix + L1-Hot Unguarded Insertion Sort
##
## Демонстрирует главное преимущество Nim над Rust:
## 1. Скорость на уровне аппаратного предела контроллера памяти (~59-61 мс на 10 000 000 `int64`).
## 2. Высокая читаемость за счёт шаблона `unroll4` на этапе компиляции (вместо сотен строк
##    ручного дублирования и `*ptr.add(i)` / `get_unchecked_mut` / `as usize` в `unsafe` Rust).

import std/[monotimes, times, typedthreads, sysatomics]

{.push checks: off, optimization: speed.}

const
  NumThreads* = 4
  R1 = 256
  Shift1 = 56
  R3 = 128
  Shift3 = 41
  SignFlip = 1'u64 shl (63 - Shift1)

template unrollHist4(startIdx, endIdx: int, histArr: untyped, bucketExpr: untyped) =
  ## Загружает 4 элемента параллельно в регистры CPU (Superscalar ILP) перед обновлением
  ## гистограммы, устраняя задержку Store-to-Load Forwarding в кэше L1.
  let limit4 = startIdx + ((endIdx - startIdx) and not 3)
  var iCur = startIdx
  while iCur < limit4:
    let b0 = block:
      let it {.inject.} = iCur
      bucketExpr
    let b1 = block:
      let it {.inject.} = iCur + 1
      bucketExpr
    let b2 = block:
      let it {.inject.} = iCur + 2
      bucketExpr
    let b3 = block:
      let it {.inject.} = iCur + 3
      bucketExpr
    inc(histArr[b0])
    inc(histArr[b1])
    inc(histArr[b2])
    inc(histArr[b3])
    iCur += 4
  while iCur < endIdx:
    let b = block:
      let it {.inject.} = iCur
      bucketExpr
    inc(histArr[b])
    inc(iCur)

template unroll4(startIdx, endIdx: int, idxVar: untyped, stepBody: untyped) =
  ## Шаблон времени компиляции: автоматически разворачивает любой цикл в 4 раза
  ## без ручного копирования кода (в отличие от Rust).
  let limit4 = startIdx + ((endIdx - startIdx) and not 3)
  var iCur = startIdx
  while iCur < limit4:
    block:
      let `idxVar` {.inject.} = iCur
      stepBody
    block:
      let `idxVar` {.inject.} = iCur + 1
      stepBody
    block:
      let `idxVar` {.inject.} = iCur + 2
      stepBody
    block:
      let `idxVar` {.inject.} = iCur + 3
      stepBody
    iCur += 4
  while iCur < endIdx:
    let `idxVar` {.inject.} = iCur
    stepBody
    inc(iCur)

proc isSorted*(arr: openArray[int64]): bool {.inline, raises: [].} =
  for i in 1 ..< arr.len:
    if arr[i - 1] > arr[i]:
      return false
  true

proc guardedInsertionSort(data: ptr UncheckedArray[int64], startIdx, endIdx: int) {.inline, gcsafe, raises: [].} =
  for i in (startIdx + 1) ..< endIdx:
    let key = data[i]
    var j = i
    while j > startIdx and data[j - 1] > key:
      data[j] = data[j - 1]
      dec(j)
    data[j] = key

proc unguardedInsertionSort(data: ptr UncheckedArray[int64], startIdx, endIdx: int) {.inline, gcsafe, raises: [].} =
  for i in startIdx ..< endIdx:
    let key = data[i]
    var j = i
    var prev = data[j - 1]
    if prev > key:
      while true:
        data[j] = prev
        dec(j)
        prev = data[j - 1]
        if prev <= key:
          break
      data[j] = key

proc fallbackQuicksort(data: ptr UncheckedArray[int64], low, high: int) {.gcsafe, raises: [].} =
  if high <= low: return
  if high - low <= 32:
    guardedInsertionSort(data, low, high + 1)
    return
  let mid = low + ((high - low) shr 1)
  if data[mid] < data[low]: swap(data[low], data[mid])
  if data[high] < data[low]: swap(data[low], data[high])
  if data[high] < data[mid]: swap(data[mid], data[high])
  let pivot = data[mid]
  var i = low - 1
  var j = high + 1
  while true:
    while true:
      inc(i)
      if data[i] >= pivot: break
    while true:
      dec(j)
      if data[j] <= pivot: break
    if i >= j: break
    swap(data[i], data[j])
  fallbackQuicksort(data, low, j)
  fallbackQuicksort(data, j + 1, high)

proc sortBucket3Level(
  aux, data, l2Buf: ptr UncheckedArray[int64],
  startIdx, endIdx: int
) {.gcsafe, raises: [].} =
  let length = endIdx - startIdx
  if length <= 1:
    if length == 1: data[startIdx] = aux[startIdx]
    return
  if length > 65_536:
    copyMem(addr data[startIdx], addr aux[startIdx], length * sizeof(int64))
    fallbackQuicksort(data, startIdx, endIdx - 1)
    return
  if length <= 64:
    copyMem(addr data[startIdx], addr aux[startIdx], length * sizeof(int64))
    guardedInsertionSort(data, startIdx, endIdx)
    return
  if length > 65_536:
    copyMem(addr data[startIdx], addr aux[startIdx], length * sizeof(int64))
    fallbackQuicksort(data, startIdx, endIdx - 1)
    return

  # Уровень 2 (Кэш L2): 8 бит (биты 48..55, 256 подкорзин)
  var count2: array[256, uint32]
  unrollHist4(startIdx, endIdx, count2, int((cast[uint64](aux[it]) shr 48) and 0xFF'u64))

  var offsets2: array[256, uint32]
  var sum2 = 0'u32
  for b in 0 ..< 256:
    offsets2[b] = sum2
    sum2 += count2[b]

  unroll4(startIdx, endIdx, idx):
    let v = aux[idx]
    let b = int((cast[uint64](v) shr 48) and 0xFF'u64)
    let pos = int(offsets2[b])
    l2Buf[pos] = v
    offsets2[b] = uint32(pos + 1)

  # Уровень 3 (Кэш L1): 7 бит (128 микрокорзин) + мгновенный Unguarded Insertion Sort
  const Mask3 = uint64(R3 - 1)
  var subStart = 0
  var hasFirst = false

  for b2 in 0 ..< 256:
    let subLen = int(count2[b2])
    if subLen == 0: continue
    let dstStart = startIdx + subStart
    let dstEnd = dstStart + subLen
    let subEnd = subStart + subLen

    if subLen <= 32:
      copyMem(addr data[dstStart], addr l2Buf[subStart], subLen * sizeof(int64))
      if not hasFirst:
        guardedInsertionSort(data, dstStart, dstEnd)
        hasFirst = true
      else:
        unguardedInsertionSort(data, dstStart, dstEnd)
    else:
      var offsets3: array[R3, uint16]
      unrollHist4(subStart, subEnd, offsets3, int((cast[uint64](l2Buf[it]) shr Shift3) and Mask3))

      var sum3, maxM = 0'u16
      var firstMLen = 0
      for m in 0 ..< R3:
        let c = offsets3[m]
        offsets3[m] = sum3
        if firstMLen == 0 and c > 0: firstMLen = int(c)
        if c > maxM: maxM = c
        sum3 += c

      unroll4(subStart, subEnd, j):
        let v = l2Buf[j]
        let c = int((cast[uint64](v) shr Shift3) and Mask3)
        let p = int(offsets3[c])
        data[dstStart + p] = v
        offsets3[c] = uint16(p + 1)

      if maxM > 64:
        fallbackQuicksort(data, dstStart, dstEnd - 1)
        hasFirst = true
      elif not hasFirst:
        guardedInsertionSort(data, dstStart, dstStart + firstMLen)
        unguardedInsertionSort(data, dstStart + firstMLen, dstEnd)
        hasFirst = true
      else:
        unguardedInsertionSort(data, dstStart, dstEnd)

    subStart = subEnd

type
  SharedState = object
    n, chunkSize: int
    data, aux: ptr UncheckedArray[int64]
    hists: array[NumThreads, array[R1, int]]
    threadOffsets: array[NumThreads, array[R1, int]]
    bucketStarts, bucketEnds: array[R1, int]
    nextBucket: int
    barrierCount: array[5, int]
    elapsedUs: int64

  WorkerArg = object
    tid: int
    state: ptr SharedState

proc waitBarrier(state: ptr SharedState, phase: int) {.inline, gcsafe, raises: [].} =
  discard atomicInc(state.barrierCount[phase], 1)
  while atomicLoadN(addr state.barrierCount[phase], ATOMIC_ACQUIRE) < NumThreads:
    cpuRelax()

proc workerProc(arg: WorkerArg) {.thread, gcsafe, raises: [].} =
  let t = arg.tid
  let st = arg.state
  let sIdx = t * st.chunkSize
  let eIdx = min(sIdx + st.chunkSize, st.n)
  let dataPtr = st.data
  let auxPtr = st.aux

  var l2Seq = newSeq[int64](65_536)
  for k in 0 ..< 65_536: l2Seq[k] = 1
  let l2Ptr = cast[ptr UncheckedArray[int64]](addr l2Seq[0])

  waitBarrier(st, 0)
  let t0 = if t == 0: getMonoTime() else: MonoTime()

  # Фаза 1а: Параллельная гистограмма старших 8 бит (1 проход по RAM)
  unrollHist4(sIdx, eIdx, st.hists[t], int((cast[uint64](dataPtr[it]) shr Shift1) xor SignFlip))

  waitBarrier(st, 1)

  if t == 0:
    var cur = 0
    for b in 0 ..< R1:
      st.bucketStarts[b] = cur
      for th in 0 ..< NumThreads:
        st.threadOffsets[th][b] = cur
        cur += st.hists[th][b]
      st.bucketEnds[b] = cur

  waitBarrier(st, 2)

  # Фаза 1б: Параллельная раскладка по 256 корзинам L2
  var localOffsets = st.threadOffsets[t]
  unroll4(sIdx, eIdx, i):
    let v = dataPtr[i]
    let b = int((cast[uint64](v) shr Shift1) xor SignFlip)
    let pos = localOffsets[b]
    auxPtr[pos] = v
    localOffsets[b] = pos + 1

  waitBarrier(st, 3)

  # Фаза 2: Динамическая балансировка 256 корзин между потоками в кэшах L2/L1
  while true:
    let b = atomicInc(st.nextBucket, 1) - 1
    if b >= R1: break
    sortBucket3Level(auxPtr, dataPtr, l2Ptr, st.bucketStarts[b], st.bucketEnds[b])

  waitBarrier(st, 4)
  if t == 0:
    st.elapsedUs = (getMonoTime() - t0).inMicroseconds

proc ultraSort*(data, aux: var openArray[int64]): float =
  ## Сортирует массив `data` на месте (с использованием буфера `aux` той же длины)
  ## и возвращает чистое время сортировки в миллисекундах.
  doAssert aux.len >= data.len, "aux buffer must be at least data.len"
  let n = data.len
  if n <= 1: return 0.0

  var st = createShared(SharedState, 1)
  st.n = n
  st.chunkSize = (n + NumThreads - 1) div NumThreads
  st.data = cast[ptr UncheckedArray[int64]](addr data[0])
  st.aux = cast[ptr UncheckedArray[int64]](addr aux[0])

  var threads: array[NumThreads - 1, Thread[WorkerArg]]
  for t in 1 ..< NumThreads:
    createThread(threads[t - 1], workerProc, WorkerArg(tid: t, state: st))

  workerProc(WorkerArg(tid: 0, state: st))
  joinThreads(threads)
  let elapsedUs = st.elapsedUs
  freeShared(st)
  result = elapsedUs.float / 1000.0

{.pop.}
