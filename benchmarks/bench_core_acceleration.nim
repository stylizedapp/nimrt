## benchmarks/bench_core_acceleration.nim
## Comprehensive Benchmarking Suite for Core Expansions and Ironclad Accelerations
##
## Benchmarks:
## 1. FastMap (SWAR accelerated) vs std/tables.Table (2,000,000 ops: inserts, lookups, hits, misses)
## 2. BufMap (SWAR accelerated) with ArenaAllocator vs std/tables.Table (2,000,000 ops)
## 3. UTF-8 validator (SWAR 8-byte fast path) vs standard byte-by-byte on 50MB corpus (GB/s)
## 4. Grapheme iterator across 1,000,000 runes (M clusters/s, M runes/s)
## 5. BinaryHeap (push, pop, heapify) vs std/heapqueue.HeapQueue
##
## Compile: nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/bench_core_acceleration.nim

import std/[monotimes, times, strformat, strutils, tables, heapqueue, hashes, sequtils]
import corex/[unicode, bufmap, allocators, result, adt]
import algx/[swissmap, heap]

# =============================================================================
# High-precision Timing & PRNG Utilities
# =============================================================================

proc blackBox*[T](val: T) {.noinline.} =
  # Volatile/noinline barrier to prevent compiler dead code elimination
  discard

type
  FastPrng = object
    state: uint64

proc initPrng(seed: uint64 = 0x9E37_79B9_7F4A_7C15'u64): FastPrng {.inline.} =
  FastPrng(state: if seed == 0: 0x853C_49E6_5D8F_ED13'u64 else: seed)

proc nextU64(p: var FastPrng): uint64 {.inline.} =
  p.state = p.state + 0x9E37_79B9_7F4A_7C15'u64
  var z = p.state
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

proc nextI64(p: var FastPrng): int64 {.inline.} =
  cast[int64](p.nextU64())

proc printBenchResult(nameStr: string, ms, mops, latencyNs: float64) =
  let tag = alignLeft(nameStr, 34)
  echo &"  {tag}: {ms:>8.2f} ms | {mops:>8.2f} M ops/s | {latencyNs:>7.1f} ns/op"

template benchmark(nameStr: string, opsCount: int, body: untyped): float64 =
  let tStart = getMonoTime()
  body
  let tDuration = (getMonoTime() - tStart).inNanoseconds
  let sec = float64(tDuration) / 1_000_000_000.0
  let ms = float64(tDuration) / 1_000_000.0
  let mops = if sec > 0.0: (float64(opsCount) / 1_000_000.0) / sec else: 0.0
  let latencyNs = if opsCount > 0: float64(tDuration) / float64(opsCount) else: 0.0
  printBenchResult(nameStr, ms, mops, latencyNs)
  ms

# =============================================================================
# Benchmark 1 & 2: FastMap & BufMap vs std/tables.Table (2,000,000 Operations)
# =============================================================================

proc benchMaps() =
  const N = 2_000_000
  echo "\n================================================================================"
  echo "1. MAP ACCELERATION BENCHMARK (2,000,000 Operations: int64 -> int64)"
  echo "================================================================================"

  # Generate 2,000,000 keys and miss keys
  # Keys have bit 0 = 0 (even), MissKeys have bit 0 = 1 (odd)
  # This guarantees 0% false hits on miss lookups without expensive set lookups
  var rngKeys = initPrng(0xCAFE_BABE_0001_2026'u64)
  var rngMiss = initPrng(0x1357_9BDF_2468_ACE0'u64)
  var keys = newSeq[int64](N)
  var vals = newSeq[int64](N)
  var missKeys = newSeq[int64](N)
  for i in 0 ..< N:
    keys[i] = rngKeys.nextI64() and (not 1'i64)
    vals[i] = rngKeys.nextI64()
    missKeys[i] = rngMiss.nextI64() or 1'i64

  # ---------------------------------------------------------------------------
  # A. std/tables.Table
  # ---------------------------------------------------------------------------
  echo "\n[A] std/tables.Table[int64, int64]:"
  var stdTab = initTable[int64, int64](N)
  let stdInsertMs = benchmark("Table.insert (2M)", N):
    for i in 0 ..< N:
      stdTab[keys[i]] = vals[i]

  var stdHitSum = 0'i64
  let stdHitMs = benchmark("Table.lookup 100% hits (2M)", N):
    for i in 0 ..< N:
      stdHitSum += stdTab[keys[i]]

  var stdMissCount = 0
  let stdMissMs = benchmark("Table.lookup 100% misses (2M)", N):
    for i in 0 ..< N:
      if missKeys[i] in stdTab:
        inc(stdMissCount)
  blackBox(stdMissCount)
  doAssert stdHitSum != 0
  doAssert stdMissCount == 0
  let stdTotalMs = stdInsertMs + stdHitMs + stdMissMs

  # ---------------------------------------------------------------------------
  # B. FastMap[int64, int64] (SWAR 8-byte group matching)
  # ---------------------------------------------------------------------------
  echo "\n[B] FastMap[int64, int64] (SWAR Accelerated SwissTable):"
  var fastMap = initFastMap[int64, int64](N)
  let fastInsertMs = benchmark("FastMap.insert (2M)", N):
    for i in 0 ..< N:
      fastMap.put(keys[i], vals[i])

  var fastHitSum = 0'i64
  let fastHitMs = benchmark("FastMap.lookup 100% hits (2M)", N):
    for i in 0 ..< N:
      fastHitSum += fastMap.getOrDefault(keys[i], 0'i64)

  var fastMissCount = 0
  let fastMissMs = benchmark("FastMap.lookup 100% misses (2M)", N):
    for i in 0 ..< N:
      if fastMap.contains(missKeys[i]):
        inc(fastMissCount)
  blackBox(fastMissCount)
  doAssert fastHitSum == stdHitSum
  doAssert fastMissCount == 0
  let fastTotalMs = fastInsertMs + fastHitMs + fastMissMs

  # ---------------------------------------------------------------------------
  # C. BufMap[int64, int64] (SWAR Accelerated + ArenaAllocator)
  # ---------------------------------------------------------------------------
  echo "\n[C] BufMap[int64, int64] (SWAR Accelerated + ArenaAllocator):"
  var arena = initArena(256 * 1024 * 1024) # 256MB pre-allocated arena
  let alloc = arena.allocator()
  var bufMapRes = initBufMap[int64, int64](alloc, N)
  doAssert bufMapRes.isOk
  var bufMap = bufMapRes.get

  let bufInsertMs = benchmark("BufMap.insert (2M)", N):
    for i in 0 ..< N:
      discard bufMap.put(keys[i], vals[i])

  var bufHitSum = 0'i64
  let bufHitMs = benchmark("BufMap.lookup 100% hits (2M)", N):
    for i in 0 ..< N:
      let opt = bufMap.get(keys[i])
      if opt.isSome:
        bufHitSum += opt.get

  var bufMissCount = 0
  let bufMissMs = benchmark("BufMap.lookup 100% misses (2M)", N):
    for i in 0 ..< N:
      if bufMap.contains(missKeys[i]):
        inc(bufMissCount)
  blackBox(bufMissCount)
  doAssert bufHitSum == stdHitSum
  doAssert bufMissCount == 0
  let bufTotalMs = bufInsertMs + bufHitMs + bufMissMs
  let arenaAllocatedMB = float64(arena.peakUsed) / (1024.0 * 1024.0)

  echo "\n--- MAP PERFORMANCE COMPARISON SUMMARY ---"
  echo &"std/tables Total Time: {stdTotalMs:>8.2f} ms"
  echo &"FastMap Total Time:    {fastTotalMs:>8.2f} ms | Speedup: {stdTotalMs / fastTotalMs:>5.2f}x faster"
  echo &"BufMap Total Time:     {bufTotalMs:>8.2f} ms | Speedup: {stdTotalMs / bufTotalMs:>5.2f}x faster"
  echo &"FastMap Insert Speedup: {stdInsertMs / fastInsertMs:>5.2f}x | Hit Speedup: {stdHitMs / fastHitMs:>5.2f}x | Miss Speedup: {stdMissMs / fastMissMs:>5.2f}x"
  echo &"BufMap Insert Speedup:  {stdInsertMs / bufInsertMs:>5.2f}x | Hit Speedup: {stdHitMs / bufHitMs:>5.2f}x | Miss Speedup: {stdMissMs / bufMissMs:>5.2f}x"
  echo &"Arena Allocator Stats:  {arenaAllocatedMB:.2f} MB used (0 system heap calls during 2M insertions!)"

  arena.deinit()

# =============================================================================
# Benchmark 3: UTF-8 Validator (SWAR 8-byte fast path vs byte-by-byte) on 50MB
# =============================================================================

# Standard reference byte-by-byte RFC 3629 validator
proc validateUtf8Std(s: openArray[char]): bool {.noinline.} =
  var i = 0
  let n = s.len
  while i < n:
    let b0 = uint8(s[i])
    if b0 < 0x80'u8:
      inc i
    elif b0 in 0xC2'u8 .. 0xDF'u8:
      if i + 1 >= n: return false
      let b1 = uint8(s[i + 1])
      if (b1 and 0xC0'u8) != 0x80'u8: return false
      i += 2
    elif b0 == 0xE0'u8:
      if i + 2 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      if b1 notin 0xA0'u8 .. 0xBF'u8 or (b2 and 0xC0'u8) != 0x80'u8: return false
      i += 3
    elif (b0 in 0xE1'u8 .. 0xEC'u8) or (b0 in 0xEE'u8 .. 0xEF'u8):
      if i + 2 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      if (b1 and 0xC0'u8) != 0x80'u8 or (b2 and 0xC0'u8) != 0x80'u8: return false
      i += 3
    elif b0 == 0xED'u8:
      if i + 2 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      if b1 notin 0x80'u8 .. 0x9F'u8 or (b2 and 0xC0'u8) != 0x80'u8: return false
      i += 3
    elif b0 == 0xF0'u8:
      if i + 3 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      let b3 = uint8(s[i + 3])
      if b1 notin 0x90'u8 .. 0xBF'u8 or (b2 and 0xC0'u8) != 0x80'u8 or (b3 and 0xC0'u8) != 0x80'u8: return false
      i += 4
    elif b0 in 0xF1'u8 .. 0xF3'u8:
      if i + 3 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      let b3 = uint8(s[i + 3])
      if (b1 and 0xC0'u8) != 0x80'u8 or (b2 and 0xC0'u8) != 0x80'u8 or (b3 and 0xC0'u8) != 0x80'u8: return false
      i += 4
    elif b0 == 0xF4'u8:
      if i + 3 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      let b3 = uint8(s[i + 3])
      if b1 notin 0x80'u8 .. 0x8F'u8 or (b2 and 0xC0'u8) != 0x80'u8 or (b3 and 0xC0'u8) != 0x80'u8: return false
      i += 4
    else:
      return false
  true

proc buildCorpus(targetBytes: int, pattern: string): string =
  let reps = (targetBytes + pattern.len - 1) div pattern.len
  result = newStringOfCap(reps * pattern.len)
  for _ in 1 .. reps:
    result.add(pattern)

proc benchUtf8() =
  echo "\n================================================================================"
  echo "2. UTF-8 VALIDATOR BENCHMARK (50 MB Corpus: SWAR 8-byte fast path vs Byte-by-Byte)"
  echo "================================================================================"

  const ChunkSize = 12_500_000 # ~12.5 MB per sub-corpus
  let asciiPattern = "The quick brown fox jumps over the lazy dog! 1234567890\n"
  let cyrillicPattern = "Быстрая коричневая лисица перепрыгивает через ленивую собаку!\n"
  let emojiPattern = "😀😁😂🤣😃😄😅😆😉😊😋😎😍😘🥰\n"
  let mixedPattern = "Nim 2.0: High-performance systems programming! Быстрый и безопасный! 🚀 日本語テスト 🦀\n"

  echo "Generating ~50MB corpus (12.5MB ASCII, 12.5MB Cyrillic, 12.5MB Emoji, 12.5MB Mixed)..."
  let asciiCorpus = buildCorpus(ChunkSize, asciiPattern)
  let cyrillicCorpus = buildCorpus(ChunkSize, cyrillicPattern)
  let emojiCorpus = buildCorpus(ChunkSize, emojiPattern)
  let mixedCorpus = buildCorpus(ChunkSize, mixedPattern)

  let fullCorpus = asciiCorpus & cyrillicCorpus & emojiCorpus & mixedCorpus
  let totalBytes = fullCorpus.len
  let totalMB = float64(totalBytes) / (1024.0 * 1024.0)
  echo &"Corpus ready: {totalMB:.2f} MB ({totalBytes} bytes)"

  # Verify sanity
  doAssert validateUtf8Std(fullCorpus) == true, "Validation failure with validateUtf8Std"
  doAssert validateUtf8(fullCorpus) == true, "Validation failure with validateUtf8 (SWAR)"

  proc printValidatorResult(nameStr: string, msPerRun, gbPerSec, mbPerSec: float64) =
    let tag = alignLeft(nameStr, 36)
    echo &"  {tag}: {msPerRun:>7.2f} ms | {gbPerSec:>6.2f} GB/s ({mbPerSec:>8.2f} MB/s)"

  template measureValidator(name: string, fn: untyped): float64 =
    discard fn(fullCorpus)
    let tStart = getMonoTime()
    const Iterations = 5
    for _ in 1 .. Iterations:
      let ok = fn(fullCorpus)
      doAssert ok
    let elapsedSec = float64((getMonoTime() - tStart).inNanoseconds) / 1_000_000_000.0
    let totalProcessedBytes = float64(totalBytes * Iterations)
    let gbPerSec = (totalProcessedBytes / 1_000_000_000.0) / elapsedSec
    let mbPerSec = (totalProcessedBytes / (1024.0 * 1024.0)) / elapsedSec
    let msPerRun = (elapsedSec / float64(Iterations)) * 1000.0
    printValidatorResult(name, msPerRun, gbPerSec, mbPerSec)
    gbPerSec

  proc measureSubCorpus(name: string, corpus: string) =
    echo &"\n  -- Sub-corpus: {name} ({float64(corpus.len)/(1024.0*1024.0):.2f} MB) --"
    const Iters = 10
    let t0 = getMonoTime()
    for _ in 1 .. Iters: discard validateUtf8Std(corpus)
    let stdSec = float64((getMonoTime() - t0).inNanoseconds) / 1e9
    let stdGB = (float64(corpus.len * Iters) / 1e9) / stdSec

    let t1 = getMonoTime()
    for _ in 1 .. Iters: discard validateUtf8(corpus)
    let swarSec = float64((getMonoTime() - t1).inNanoseconds) / 1e9
    let swarGB = (float64(corpus.len * Iters) / 1e9) / swarSec

    echo &"    Byte-by-byte: {stdGB:>6.2f} GB/s"
    echo &"    SWAR 8-byte:  {swarGB:>6.2f} GB/s (Speedup: {swarGB/stdGB:>5.2f}x)"

  measureSubCorpus("Pure ASCII (12.5MB)", asciiCorpus)
  measureSubCorpus("Pure Cyrillic 2-byte (12.5MB)", cyrillicCorpus)
  measureSubCorpus("Pure Emoji 4-byte (12.5MB)", emojiCorpus)
  measureSubCorpus("Mixed Multi-byte (12.5MB)", mixedCorpus)

  echo "\n  -- Full 50MB Corpus Overall Throughput --"
  let stdGb = measureValidator("Byte-by-byte RFC 3629", validateUtf8Std)
  let swarGb = measureValidator("SWAR 8-byte Fast Path (validateUtf8)", validateUtf8)
  echo &"\n>>> Overall UTF-8 Validation Speedup: {swarGb / stdGb:.2f}x ({swarGb:.2f} GB/s vs {stdGb:.2f} GB/s) <<<"

# =============================================================================
# Benchmark 4: Grapheme Iterator across 1,000,000 Runes
# =============================================================================

proc benchGraphemes() =
  echo "\n================================================================================"
  echo "3. GRAPHEME CLUSTER SEGMENTATION (UAX #29 across 1,000,000 Runes)"
  echo "================================================================================"

  let units = [
    "Hello ",                # 6 runes, 6 clusters
    "world! ",               # 7 runes, 7 clusters
    "e\u0301cole ",          # 7 runes (e + combining acute), 6 clusters
    "🇺🇸 ",                  # 3 runes (2 regional + space), 2 clusters
    "🇬🇧 ",                  # 3 runes, 2 clusters
    "👨‍👩‍👧‍👦 ",               # 8 runes (4 people + 3 ZWJ + space), 2 clusters
    "👩‍💻 ",                  # 4 runes (woman + ZWJ + laptop + space), 2 clusters
    "Привет ",               # 7 runes, 7 clusters
    "мир! ",                 # 5 runes, 5 clusters
    "👍🏽 "                   # 3 runes (thumbs up + tone + space), 2 clusters
  ]

  var unitRunes = 0
  for u in units:
    var pos = 0
    while pos < u.len:
      let (_, rLen) = decodeRune(u, pos)
      inc(unitRunes)
      pos += rLen

  let reps = (1_000_000 + unitRunes - 1) div unitRunes
  var corpus = ""
  for _ in 1 .. reps:
    for u in units:
      corpus.add(u)

  var totalRunes = 0
  var pos = 0
  while pos < corpus.len:
    let (_, rLen) = decodeRune(corpus, pos)
    inc(totalRunes)
    pos += rLen

  echo &"Generated test corpus with {totalRunes} runes ({corpus.len} UTF-8 bytes)"

  # Warmup
  var warmupClusters = 0
  for g in graphemes(corpus):
    inc(warmupClusters)

  let tStart = getMonoTime()
  const Iterations = 3
  var clusterCount = 0
  for _ in 1 .. Iterations:
    clusterCount = 0
    for g in graphemes(corpus):
      inc(clusterCount)

  let elapsedSec = float64((getMonoTime() - tStart).inNanoseconds) / 1_000_000_000.0
  let totalProcessedRunes = float64(totalRunes * Iterations)
  let totalProcessedClusters = float64(clusterCount * Iterations)
  let mRunesPerSec = (totalProcessedRunes / 1_000_000.0) / elapsedSec
  let mClustersPerSec = (totalProcessedClusters / 1_000_000.0) / elapsedSec
  let msPerRun = (elapsedSec / float64(Iterations)) * 1000.0

  echo &"  Clusters found per run: {clusterCount}"
  echo &"  Execution time:         {msPerRun:.2f} ms per 1M runes"
  echo &"  Throughput:             {mRunesPerSec:.2f} M runes/s | {mClustersPerSec:.2f} M clusters/s"

# =============================================================================
# Benchmark 5: BinaryHeap (push, pop, heapify) vs std/heapqueue.HeapQueue
# =============================================================================

proc benchHeap() =
  const N = 1_000_000
  const HeapifyN = 2_000_000
  echo "\n================================================================================"
  echo "4. BINARY HEAP ACCELERATION BENCHMARK (1,000,000 Push/Pop, 2,000,000 Heapify)"
  echo "================================================================================"

  var rng = initPrng(0x55AA_1234_BEEF_9999'u64)
  var data = newSeq[int](N)
  for i in 0 ..< N:
    data[i] = int(rng.nextU64() and 0x7FFF_FFFF'u64)

  # ---------------------------------------------------------------------------
  # A. std/heapqueue.HeapQueue
  # ---------------------------------------------------------------------------
  echo "\n[A] std/heapqueue.HeapQueue[int]:"
  var hq = initHeapQueue[int]()
  let hqPushMs = benchmark("HeapQueue.push (1M)", N):
    for i in 0 ..< N:
      hq.push(data[i])

  var hqPopSum = 0
  let hqPopMs = benchmark("HeapQueue.pop (1M)", N):
    for i in 0 ..< N:
      hqPopSum += hq.pop()

  var hqData = newSeq[int](HeapifyN)
  for i in 0 ..< HeapifyN:
    hqData[i] = int(rng.nextU64() and 0x7FFF_FFFF'u64)

  let hqHeapifyMs = benchmark("HeapQueue construction (2M)", HeapifyN):
    var hqBuild = initHeapQueue[int]()
    for i in 0 ..< HeapifyN:
      hqBuild.push(hqData[i])

  # ---------------------------------------------------------------------------
  # B. algx/heap.BinaryHeap (Pre-allocated, Hole-filtering, In-place Floyd heapify)
  # ---------------------------------------------------------------------------
  echo "\n[B] algx/heap.BinaryHeap[int] (Hole-filtering Sift + Floyd Heapify):"
  var binHeap = initBinaryHeap[int](capacity = N, isMinHeap = true)
  let binPushMs = benchmark("BinaryHeap.push (1M)", N):
    for i in 0 ..< N:
      binHeap.push(data[i])

  var binPopSum = 0
  let binPopMs = benchmark("BinaryHeap.pop (1M)", N):
    for i in 0 ..< N:
      binPopSum += binHeap.pop()
  doAssert binPopSum == hqPopSum

  var binData = hqData # clone the same 2M array
  let binHeapifyMs = benchmark("BinaryHeap.heapify in-place (2M)", HeapifyN):
    heapify(binData, isMinHeap = true)

  echo "\n--- HEAP PERFORMANCE COMPARISON SUMMARY ---"
  echo &"Push Speedup:    {hqPushMs / binPushMs:>5.2f}x faster ({binPushMs:.2f} ms vs {hqPushMs:.2f} ms)"
  echo &"Pop Speedup:     {hqPopMs / binPopMs:>5.2f}x faster ({binPopMs:.2f} ms vs {hqPopMs:.2f} ms)"
  echo &"Heapify Speedup: {hqHeapifyMs / binHeapifyMs:>5.2f}x faster ({binHeapifyMs:.2f} ms vs {hqHeapifyMs:.2f} ms)"

# =============================================================================
# Main Entry Point
# =============================================================================

proc main() =
  echo "################################################################################"
  echo "#         NIM HIGH-PERFORMANCE CORE ACCELERATION BENCHMARK SUITE               #"
  echo "################################################################################"
  benchMaps()
  benchUtf8()
  benchGraphemes()
  benchHeap()
  echo "\n================================================================================"
  echo "ALL BENCHMARKS COMPLETED SUCCESSFULLY."
  echo "================================================================================"

when isMainModule:
  main()
