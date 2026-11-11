## High-Contention Benchmark and Verification for Work-Stealing ThreadPool
## Compares task throughput and recursive parallel divide-and-conquer,
## and verifies zero memory leaks under --mm:orc --threads:on --panics:on.

import corex
import std/[monotimes, times, strformat, cpuinfo, os]

type
  DivideConquerContext = object
    pool: ptr ThreadPool
    wg: ptr WaitGroup
    sum: ptr Atomic[int64]
    data: ptr UncheckedArray[int]
    threshold: int

proc runDivideConquer(ctx: ptr DivideConquerContext, low, high: int) {.gcsafe.}

type
  TaskPayload = object
    ctx: ptr DivideConquerContext
    low: int
    high: int

proc taskPayloadProc(p: pointer) {.nimcall, gcsafe.} =
  let payload = cast[ptr TaskPayload](p)
  runDivideConquer(payload.ctx, payload.low, payload.high)
  deallocShared(payload)

proc runDivideConquer(ctx: ptr DivideConquerContext, low, high: int) =
  let count = high - low
  if count <= ctx.threshold:
    var localSum = 0'i64
    for i in low ..< high:
      localSum += ctx.data[i]
    discard ctx.sum[].fetchAdd(localSum, Relaxed)
    ctx.wg[].done()
  else:
    let mid = low + (count div 2)
    # Right half: spawned asynchronously
    ctx.wg[].add(1)
    
    # We test spawning closure task:
    let pCtx = ctx
    ctx.pool[].spawn(proc() {.gcsafe.} =
      runDivideConquer(pCtx, mid, high)
    )
    # Left half: executed directly by the current worker
    runDivideConquer(ctx, low, mid)

# =============================================================================
# Benchmark 1: High-Contention Fine-Grained External Task Throughput
# =============================================================================

proc benchExternalTaskThroughput(pool: ptr ThreadPool, totalTasks: int = 100_000): float =
  var counter = initAtomic(0'i64)
  var wg = initWaitGroup()
  wg.add(totalTasks)

  let t0 = getMonoTime()
  for _ in 0 ..< totalTasks:
    pool.spawn(proc() {.gcsafe.} =
      discard counter.fetchAdd(1, Relaxed)
      wg.done()
    )
  wg.wait()
  let elapsedSec = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
  doAssert counter.load(Relaxed) == totalTasks.int64, "Counter mismatch in external throughput"
  let ops = totalTasks.float / elapsedSec
  echo &"  [External Spawning] {totalTasks} tasks executed in {elapsedSec*1000.0:>6.2f} ms ({ops/1000.0:>8.2f} K tasks/sec)"
  return ops

# =============================================================================
# Benchmark 2: Recursive Divide-and-Conquer
# =============================================================================

proc benchRecursiveDivideConquer(pool: ptr ThreadPool, numElements: int = 2_000_000, threshold: int = 2_000): float =
  let data = cast[ptr UncheckedArray[int]](allocShared0(sizeof(int) * numElements))
  var expectedSum = 0'i64
  for i in 0 ..< numElements:
    data[i] = (i mod 100) + 1
    expectedSum += data[i]

  var totalSum = initAtomic(0'i64)
  var wg = initWaitGroup()
  wg.add(1) # For the root task

  var ctx = DivideConquerContext(
    pool: pool,
    wg: addr wg,
    sum: addr totalSum,
    data: data,
    threshold: threshold
  )

  let t0 = getMonoTime()
  pool.spawn(proc() {.gcsafe.} =
    runDivideConquer(addr ctx, 0, numElements)
  )
  wg.wait()
  let elapsedSec = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
  let actualSum = totalSum.load(Relaxed)
  doAssert actualSum == expectedSum, &"Sum mismatch: expected {expectedSum}, got {actualSum}"

  deallocShared(data)
  let ops = numElements.float / elapsedSec
  echo &"  [Divide-and-Conquer] {numElements} items (threshold {threshold}) in {elapsedSec*1000.0:>6.2f} ms ({ops/1_000_000.0:>6.2f} M items/sec)"
  return ops

# =============================================================================
# Benchmark 3: Multi-Producer Concurrent External Contention
# =============================================================================

type ProducerArg = object
  pool: ptr ThreadPool
  tasksPerProducer: int
  counter: ptr Atomic[int64]
  wg: ptr WaitGroup

proc producerThread(p: ptr ProducerArg) {.thread.} =
  for _ in 0 ..< p.tasksPerProducer:
    p.pool[].spawn(proc() {.gcsafe.} =
      discard p.counter[].fetchAdd(1, Relaxed)
      p.wg[].done()
    )

proc benchMultiProducerContention(pool: ptr ThreadPool, numProducers: int = 4, tasksPerProducer: int = 25_000): float =
  let totalTasks = numProducers * tasksPerProducer
  var counter = initAtomic(0'i64)
  var wg = initWaitGroup()
  wg.add(totalTasks)

  var producers = newSeq[Thread[ptr ProducerArg]](numProducers)
  var args = newSeq[ProducerArg](numProducers)
  for i in 0 ..< numProducers:
    args[i] = ProducerArg(
      pool: pool,
      tasksPerProducer: tasksPerProducer,
      counter: addr counter,
      wg: addr wg
    )

  let t0 = getMonoTime()
  for i in 0 ..< numProducers:
    createThread(producers[i], producerThread, addr args[i])
  for i in 0 ..< numProducers:
    joinThread(producers[i])
  wg.wait()
  let elapsedSec = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
  doAssert counter.load(Relaxed) == totalTasks.int64, "Counter mismatch in multi-producer contention"
  let ops = totalTasks.float / elapsedSec
  echo &"  [Multi-Producer Contention] {numProducers} producers x {tasksPerProducer} = {totalTasks} tasks in {elapsedSec*1000.0:>6.2f} ms ({ops/1000.0:>8.2f} K tasks/sec)"
  return ops

# =============================================================================
# Benchmark 4: Memory Leak Verification under --mm:orc
# =============================================================================

proc verifyZeroMemoryLeaks(pool: ptr ThreadPool) =
  echo "[Memory Leak Verification under --mm:orc]"
  # Warm-up run to stabilize allocations and thread stacks
  discard benchExternalTaskThroughput(pool, 20_000)
  GC_fullCollect()

  let initialMem = getOccupiedMem()
  echo &"  Base occupied memory: {initialMem} bytes"

  const LoopRounds = 3
  for round in 1 .. LoopRounds:
    discard benchExternalTaskThroughput(pool, 50_000)
    discard benchRecursiveDivideConquer(pool, 500_000, 1_000)
    GC_fullCollect()
    let currentMem = getOccupiedMem()
    echo &"  Round {round}: occupied memory = {currentMem} bytes (delta: {currentMem - initialMem} bytes)"

  GC_fullCollect()
  let finalMem = getOccupiedMem()
  let leakBytes = finalMem - initialMem
  echo &"  Final occupied memory: {finalMem} bytes (net leak: {leakBytes} bytes)"
  # Under ORC with shared allocations, memory should stabilize.
  # We check that leakBytes does not exceed a minimal tolerance (e.g. 64KB for internal heap fragmentation).
  doAssert leakBytes < 65536, &"Potential memory leak detected: {leakBytes} bytes"
  echo "  [OK] Zero memory leak verification PASSED!"

# =============================================================================
# Main Benchmark Runner
# =============================================================================

proc main() =
  echo "================================================================================"
  echo "       High-Contention ThreadPool Benchmark & Memory Verification"
  echo &"       CPUs: {countProcessors()} | Memory Manager: ORC | Threads: ON"
  echo "================================================================================"

  let workers = countProcessors()
  var pool = initThreadPool(workers)

  echo "\n--- 1. External High-Contention Task Throughput ---"
  discard benchExternalTaskThroughput(addr pool, 100_000)

  echo "\n--- 2. Multi-Producer Concurrent Task Submission ---"
  discard benchMultiProducerContention(addr pool, 4, 25_000)

  echo "\n--- 3. Recursive Parallel Divide-and-Conquer ---"
  discard benchRecursiveDivideConquer(addr pool, 2_000_000, 1_000)

  echo "\n--- 4. Memory Leak Verification ---"
  verifyZeroMemoryLeaks(addr pool)

  echo "\nShutting down ThreadPool..."
  pool.shutdown()
  echo "Shutdown complete."
  echo "\n================================================================================"
  echo "                   ALL BENCHMARKS & VERIFICATIONS COMPLETED"
  echo "================================================================================"

when isMainModule:
  main()
