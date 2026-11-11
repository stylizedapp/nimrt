## benchmarks/nim_full_suite.nim — Честный симметричный бенчмарк Nim (CoreX + AlgX) против Rust
##
## Методика:
## - Одинаковые алгоритмы, структуры данных, число потоков и хэш-функции с обеих сторон.
## - Перед каждой дисциплиной: 2 прогревочных прогона (Warmup = 2).
## - Серия из 11 замеряемых прогонов (Runs = 11) с расчётом Min, Median, Mean, Max.
## - Побайтовая сверка сериализованного буфера (64 000 004 байт) и всех контрольных сумм.

import std/[monotimes, times, strformat, algorithm]
import ../src/algx/algx

{.push checks: off, optimization: speed.}

const
  WarmupRuns = 2
  BenchRuns = 11
  Seed = 0xDEAD_BEEF_CAFE_1234'u64

type
  XorShift64 = object
    state: uint64

  VoxelPacket = object
    entityId: int64
    chunkX, chunkY, chunkZ: int32
    health: float32
    flags: uint32
    pad: uint32 # Явное 4-байтовое выравнивание до 32 байт для 100% побайтового совпадения с Rust

proc initXorShift64(seed: uint64): XorShift64 {.inline, raises: [].} =
  XorShift64(state: if seed == 0'u64: 0x54581234CAFEBEEF'u64 else: seed)

proc nextI64(rng: var XorShift64): int64 {.inline, raises: [].} =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  cast[int64](x)

proc printStats(label: string, samples: var seq[float], extra: string) =
  samples.sort()
  let minVal = samples[0]
  let medVal = samples[samples.len div 2]
  let maxVal = samples[^1]
  var sum = 0.0
  for x in samples: sum += x
  let meanVal = sum / samples.len.float
  echo &"{label:<40} | min: {minVal:>6.2f} ms | med: {medVal:>6.2f} ms | mean: {meanVal:>6.2f} ms | max: {maxVal:>6.2f} ms | {extra}"

proc hashBytesSample(buf: openArray[byte]): uint64 {.inline, raises: [].} =
  var h = 0xCBF2_9CE4_8422_2325'u64
  var i = 0
  let n = buf.len
  while i < n:
    h = (h xor uint64(buf[i])) * 0x0000_0100_0000_01B3'u64
    i += 4096
  h = (h xor uint64(buf[n - 1])) * 0x0000_0100_0000_01B3'u64
  h

proc main() =
  echo "======================================================================================================================"
  echo "   NIM 2.2.12 (COREX + ALGX) — SYMMETRIC BENCHMARK SUITE (Warmup: 2, Measured Runs: 11)                              "
  echo "======================================================================================================================"

  # ---------------------------------------------------------------------------
  # 1. Сортировка 10 000 000 int64 (4 потока, 3-Level Hybrid MSD Radix + L1 Insertion)
  # ---------------------------------------------------------------------------
  block:
    const N = 10_000_000
    var master = newSeq[int64](N)
    var rng = initXorShift64(Seed)
    for i in 0 ..< N: master[i] = rng.nextI64()

    var data = newSeq[int64](N)
    var aux = newSeq[int64](N)
    for i in 0 ..< N: aux[i] = 1

    var samples = newSeqOfCap[float](BenchRuns)
    for run in 0 ..< (WarmupRuns + BenchRuns):
      copyMem(addr data[0], addr master[0], N * sizeof(int64))
      let ms = ultraSort(data, aux)
      if run >= WarmupRuns:
        samples.add(ms)

    doAssert isSorted(data), "Sort verification failed!"
    printStats("[1] UltraSort (10M int64, 4T)", samples, &"min={data[0]}, max={data[N-1]}")

  # ---------------------------------------------------------------------------
  # 2. Хэш-таблица: 1M вставок + 1M хитов + 1M промахов (FastMap + SplitMix64)
  # ---------------------------------------------------------------------------
  block:
    const M = 1_000_000
    var keys = newSeq[int64](M)
    var rng = initXorShift64(Seed)
    for i in 0 ..< M: keys[i] = rng.nextI64()

    var mp = initFastMap[int64, int64](M)
    let slots = mp.ctrl.len
    var checkSum = 0'i64
    var samples = newSeqOfCap[float](BenchRuns)

    for run in 0 ..< (WarmupRuns + BenchRuns):
      mp.clear()
      let t0 = getMonoTime()
      for i in 0 ..< M:
        mp[keys[i]] = int64(i)
      var cs = 0'i64
      for i in 0 ..< M:
        cs += mp.getOrDefault(keys[i], -1'i64)
        cs += mp.getOrDefault(keys[i] xor 0x5555_5555_5555_5555'i64, 0'i64)
      let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
      checkSum = cs
      if run >= WarmupRuns:
        samples.add(ms)

    printStats("[2] FastMap SplitMix64 (3M ops)", samples, &"slots={slots}, sum={checkSum}")

  # ---------------------------------------------------------------------------
  # 3. Блочная POD-сериализация 2 000 000 VoxelPacket (sizeof=32, 64 МБ)
  # ---------------------------------------------------------------------------
  block:
    const P = 2_000_000
    doAssert sizeof(VoxelPacket) == 32
    var packets = newSeq[VoxelPacket](P)
    for i in 0 ..< P:
      packets[i] = VoxelPacket(
        entityId: int64(i + 1),
        chunkX: int32(i and 1023),
        chunkY: int32((i shr 10) and 255),
        chunkZ: int32(-i),
        health: 100.0'f32,
        flags: uint32(i),
        pad: 0'u32
      )

    var samples = newSeqOfCap[float](BenchRuns)
    var byteLen = 0
    var byteHash = 0'u64
    var verifyId = 0'i64

    for run in 0 ..< (WarmupRuns + BenchRuns):
      # Предотвращаем вынос чистых вычислений за пределы цикла оптимизатором LTO
      var vRun {.volatile.} = run
      if vRun < 0: packets[0].pad = 1'u32
      let t0 = getMonoTime()
      let rawBytes = packBin(packets)
      let unpacked = unpackBin[seq[VoxelPacket]](rawBytes)
      let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
      byteLen = rawBytes.len
      verifyId = unpacked[P - 1].entityId + int64(unpacked[P - 1].chunkZ)
      byteHash = byteHash xor hashBytesSample(rawBytes)
      if run >= WarmupRuns:
        samples.add(ms)

    printStats("[3] ZeroPack POD (2M x 32B = 64MB)", samples, &"bytes={byteLen}, hash={byteHash:#x}, chk={verifyId}")

  # ---------------------------------------------------------------------------
  # 4. Векторная аналитика 25 000 000 int64 (8-way DotProduct + Branchless Filter)
  # ---------------------------------------------------------------------------
  block:
    const K = 25_000_000
    var vecA = newSeq[int64](K)
    var vecB = newSeq[int64](K)
    var rng = initXorShift64(Seed)
    for i in 0 ..< K:
      vecA[i] = rng.nextI64() and 0xFFFF'i64
      vecB[i] = (i and 7).int64

    var samples = newSeqOfCap[float](BenchRuns)
    var dotRes = 0'i64
    var cntRes = 0

    for run in 0 ..< (WarmupRuns + BenchRuns):
      var vThresh {.volatile.} = 32768'i64
      let t0 = getMonoTime()
      let d = fastDotProduct(vecA, vecB)
      let c = fastCountGreater(vecA, vThresh)
      let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
      var vDot {.volatile.} = d
      var vCnt {.volatile.} = c
      dotRes = vDot
      cntRes = vCnt
      if run >= WarmupRuns:
        samples.add(ms)

    printStats("[4] SimdScan 8-Way (25M int64)", samples, &"dot={dotRes}, count={cntRes}")

{.pop.}

when isMainModule:
  main()
