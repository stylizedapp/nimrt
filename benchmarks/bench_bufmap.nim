import std/[monotimes, times, strformat]
import corex/[allocators, result, adt]
import corex/bufmap
import algx/swissmap

proc runBenchmark() =
  echo "=== BENCHMARK: BufMap vs FastMap (1,000,000 operations) ==="
  const N = 1_000_000

  # 1. FastMap benchmark
  var fm = initFastMap[int64, int64](N)
  let t0 = getMonoTime()
  for i in 0 ..< N:
    fm.put(int64(i), int64(i * 2))
  var fmHits = 0
  for i in 0 ..< N:
    if fm.contains(int64(i)):
      inc(fmHits)
  let fmTime = (getMonoTime() - t0).inMilliseconds
  echo &"FastMap: {fmTime} ms (hits: {fmHits})"

  # 2. BufMap benchmark
  let alloc = heapAllocator()
  var bm = initBufMap[int64, int64](alloc, N).unwrap()
  let t1 = getMonoTime()
  for i in 0 ..< N:
    discard bm.put(int64(i), int64(i * 2))
  var bmHits = 0
  for i in 0 ..< N:
    if bm.contains(int64(i)):
      inc(bmHits)
  let bmTime = (getMonoTime() - t1).inMilliseconds
  echo &"BufMap:  {bmTime} ms (hits: {bmHits})"

  bm.deinit()

  let diff = abs(float(bmTime - fmTime)) / float(fmTime) * 100.0
  echo &"Performance difference: {diff:.2f}%"

when isMainModule:
  runBenchmark()
