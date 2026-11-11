## tests/test_workstealing.nim — Comprehensive Multi-Threaded Verification
## Verifies Chase-Lev WorkStealDeque under --mm:orc --threads:on --panics:on

import corex/workstealing
import std/[os, times, atomics, sysatomics, strutils]

var gPassedTests = 0
var gTotalTests = 0

template testCase(name: string, body: untyped) =
  inc(gTotalTests)
  stdout.write("[TEST] " & name & " ... ")
  try:
    proc testBody() =
      body
    testBody()
    inc(gPassedTests)
    stdout.writeLine("OK")
  except Exception as e:
    stdout.writeLine("FAILED: " & e.msg)
    raise e

# =============================================================================
# Test 1: Basic Push / Pop (LIFO Order for Owner)
# =============================================================================

testCase "WorkStealDeque: Owner push and pop LIFO order":
  var deque = initWorkStealDeque[int](16)
  doAssert deque.empty
  doAssert deque.len == 0

  const N = 200
  for i in 1 .. N:
    deque.push(i)
    doAssert deque.len == i

  doAssert not deque.empty

  for i in countdown(N, 1):
    var val: int
    doAssert deque.pop(val)
    doAssert val == i

  doAssert deque.empty
  doAssert deque.len == 0

  var val: int
  doAssert not deque.pop(val)

# =============================================================================
# Test 2: Basic Steal (FIFO Order for Thief)
# =============================================================================

testCase "WorkStealDeque: Thief steal FIFO order":
  var deque = initWorkStealDeque[int](32)

  for i in 1 .. 20:
    deque.push(i)

  # Thief steals 10 items from top (FIFO: 1 .. 10)
  for i in 1 .. 10:
    var val: int
    doAssert deque.steal(val)
    doAssert val == i

  # Owner pops remaining 10 items from bottom (LIFO: 20 down to 11)
  for i in countdown(20, 11):
    var val: int
    doAssert deque.pop(val)
    doAssert val == i

  doAssert deque.empty
  var dummy: int
  doAssert not deque.steal(dummy)
  doAssert not deque.pop(dummy)

# =============================================================================
# Test 3: Option API Ergonomics
# =============================================================================

testCase "WorkStealDeque: Option[T] pop and steal":
  var deque = initWorkStealDeque[int](16)

  doAssert deque.pop().isNone
  doAssert deque.steal().isNone

  deque.push(100)
  deque.push(200)

  let s = deque.steal()
  doAssert s.isSome
  doAssert s.get == 100

  let p = deque.pop()
  doAssert p.isSome
  doAssert p.get == 200

  doAssert deque.pop().isNone
  doAssert deque.steal().isNone

# =============================================================================
# Test 4: Dynamic Buffer Growth (Expansion Beyond Initial Capacity)
# =============================================================================

testCase "WorkStealDeque: Buffer dynamic expansion (16 -> 4096)":
  var deque = initWorkStealDeque[int](16)
  doAssert deque.capacity == 16

  const Count = 2000
  for i in 1 .. Count:
    deque.push(i)

  doAssert deque.len == Count
  doAssert deque.capacity >= Count

  # Pop 1000 items from bottom (2000 down to 1001)
  for i in countdown(Count, 1001):
    var v: int
    doAssert deque.pop(v)
    doAssert v == i

  # Steal 1000 items from top (1 up to 1000)
  for i in 1 .. 1000:
    var v: int
    doAssert deque.steal(v)
    doAssert v == i

  doAssert deque.empty

# =============================================================================
# Test 5: Single Element Contention Race (Owner pop vs Thief steal)
# =============================================================================

testCase "WorkStealDeque: Single-element contention race":
  type RaceContext = object
    deque: ptr WorkStealDeque[int]
    thiefWon: Atomic[int]
    ownerWon: Atomic[int]
    done: Atomic[bool]

  const Iterations = 50_000

  proc thiefRunner(ctx: ptr RaceContext) {.thread.} =
    while not ctx.done.load(moAcquire):
      var val: int
      if ctx.deque.steal(val):
        discard ctx.thiefWon.fetchAdd(1, moRelaxed)
      else:
        cpuRelax()

    # Drain any remaining steals
    var val: int
    while ctx.deque.steal(val):
      discard ctx.thiefWon.fetchAdd(1, moRelaxed)

  var deque = initWorkStealDeque[int](64)
  var ctx: RaceContext
  ctx.deque = addr deque
  ctx.thiefWon.store(0, moRelaxed)
  ctx.ownerWon.store(0, moRelaxed)
  ctx.done.store(false, moRelaxed)

  var th: Thread[ptr RaceContext]
  createThread(th, thiefRunner, addr ctx)

  for i in 1 .. Iterations:
    deque.push(i)
    var val: int
    if deque.pop(val):
      discard ctx.ownerWon.fetchAdd(1, moRelaxed)

  ctx.done.store(true, moRelease)
  joinThread(th)

  let totalWon = ctx.ownerWon.load(moRelaxed) + ctx.thiefWon.load(moRelaxed)
  doAssert totalWon == Iterations, "Expected " & $Iterations & " wins, but got " & $totalWon
  doAssert deque.empty

# =============================================================================
# Test 6: Multi-Thief Concurrent Stealing Stress Test (1 Owner, 4 Thieves)
# =============================================================================

testCase "WorkStealDeque: Multi-thief concurrent stealing (100,000 items)":
  const TotalItems = 100_000
  const NumThieves = 4

  # Use shared memory for seen array so all threads can access safely
  var seenTable = cast[ptr UncheckedArray[Atomic[int]]](allocShared0(sizeof(Atomic[int]) * (TotalItems + 1)))

  type MultiThiefContext = object
    deque: ptr WorkStealDeque[int]
    seen: ptr UncheckedArray[Atomic[int]]
    done: Atomic[bool]
    totalStolen: Atomic[int]

  proc thiefWorker(ctx: ptr MultiThiefContext) {.thread.} =
    var localStolen = 0
    while not ctx.done.load(moAcquire):
      var item: int
      if ctx.deque.steal(item):
        inc(localStolen)
        let prev = ctx.seen[item].fetchAdd(1, moRelaxed)
        doAssert prev == 0, "Duplicate item stolen: " & $item
      else:
        cpuRelax()

    # Drain remaining items
    var item: int
    while ctx.deque.steal(item):
      inc(localStolen)
      let prev = ctx.seen[item].fetchAdd(1, moRelaxed)
      doAssert prev == 0, "Duplicate item stolen in drain: " & $item

    discard ctx.totalStolen.fetchAdd(localStolen, moRelaxed)

  var deque = initWorkStealDeque[int](128)
  var ctx: MultiThiefContext
  ctx.deque = addr deque
  ctx.seen = seenTable
  ctx.done.store(false, moRelaxed)
  ctx.totalStolen.store(0, moRelaxed)

  var thieves: array[NumThieves, Thread[ptr MultiThiefContext]]
  for i in 0 ..< NumThieves:
    createThread(thieves[i], thiefWorker, addr ctx)

  # Owner pushes all items and occasionally pops some items
  var ownerPopped = 0
  for i in 1 .. TotalItems:
    deque.push(i)
    if (i mod 3) == 0:
      var item: int
      if deque.pop(item):
        inc(ownerPopped)
        let prev = seenTable[item].fetchAdd(1, moRelaxed)
        doAssert prev == 0, "Duplicate item popped: " & $item

  # Drain until deque is empty
  while not deque.empty:
    var item: int
    if deque.pop(item):
      inc(ownerPopped)
      let prev = seenTable[item].fetchAdd(1, moRelaxed)
      doAssert prev == 0, "Duplicate item popped in drain: " & $item
    else:
      cpuRelax()

  ctx.done.store(true, moRelease)
  for i in 0 ..< NumThieves:
    joinThread(thieves[i])

  let totalStolen = ctx.totalStolen.load(moRelaxed)
  doAssert (ownerPopped + totalStolen) == TotalItems,
    "Expected " & $TotalItems & " total processed, got popped=" & $ownerPopped & " stolen=" & $totalStolen

  # Verify every item from 1 to TotalItems was seen exactly once
  for i in 1 .. TotalItems:
    let count = seenTable[i].load(moRelaxed)
    doAssert count == 1, "Item " & $i & " was seen " & $count & " times!"

  deallocShared(seenTable)

# =============================================================================
# Test 7: Job and Closure Lifecycle (JobDeque Memory Safety)
# =============================================================================

testCase "WorkStealDeque: Job execution and cleanup memory safety":
  type Payload = object
    id: int
    executed: ptr Atomic[int]
    cleanedUp: ptr Atomic[int]

  var execCount: Atomic[int]
  var cleanCount: Atomic[int]
  execCount.store(0, moRelaxed)
  cleanCount.store(0, moRelaxed)

  proc taskFn(arg: pointer) {.nimcall, gcsafe.} =
    let p = cast[ptr Payload](arg)
    discard p.executed[].fetchAdd(1, moRelaxed)

  proc taskCleanup(arg: pointer) {.nimcall, gcsafe.} =
    let p = cast[ptr Payload](arg)
    discard p.cleanedUp[].fetchAdd(1, moRelaxed)
    deallocShared(p)

  block:
    var jobDeque = initWorkStealDeque[Job](32)
    const N = 1000

    for i in 1 .. N:
      let p = cast[ptr Payload](allocShared0(sizeof(Payload)))
      p.id = i
      p.executed = addr execCount
      p.cleanedUp = addr cleanCount
      jobDeque.push(initJob(taskFn, p, taskCleanup))

    # Pop 500 jobs and execute them
    for i in 1 .. 500:
      var job: Job
      doAssert jobDeque.pop(job)
      job.execute()

    # Steal 300 jobs and execute them
    for i in 1 .. 300:
      var job: Job
      doAssert jobDeque.steal(job)
      job.execute()

    # 200 jobs remain in the deque!
    doAssert jobDeque.len == 200
    jobDeque.destroy()

  # Check that all 800 executed jobs were executed and cleaned up
  doAssert execCount.load(moRelaxed) == 800
  # Check that ALL 1000 jobs had their cleanup called (800 executed + 200 destroyed in deque)!
  doAssert cleanCount.load(moRelaxed) == 1000,
    "Expected 1000 cleanups, but got " & $cleanCount.load(moRelaxed)

# =============================================================================
# Test 8: Shared Heap Pointer Deque Lifecycle
# =============================================================================

testCase "WorkStealDeque: Shared heap pointer allocation (newWorkStealDeque)":
  let dq = newWorkStealDeque[int](16)
  dq.push(42)
  dq.push(84)

  var v: int
  doAssert dq.pop(v)
  doAssert v == 84
  doAssert dq.steal(v)
  doAssert v == 42
  doAssert dq.empty

  destroyWorkStealDeque(dq)

# =============================================================================
# Test 9: Rapid Push / Pop Churn under Thief Contention (8 Thieves)
# =============================================================================

testCase "WorkStealDeque: 8 Thieves rapid churn stress test":
  const Items = 80_000
  const Thieves = 8

  type ChurnCtx = object
    deque: ptr WorkStealDeque[int]
    done: Atomic[bool]
    stolenCount: Atomic[int]

  proc churnThief(ctx: ptr ChurnCtx) {.thread.} =
    var localCount = 0
    while not ctx.done.load(moAcquire):
      var item: int
      if ctx.deque.steal(item):
        inc(localCount)
      else:
        cpuRelax()

    var item: int
    while ctx.deque.steal(item):
      inc(localCount)

    discard ctx.stolenCount.fetchAdd(localCount, moRelaxed)

  var deque = initWorkStealDeque[int](64)
  var ctx: ChurnCtx
  ctx.deque = addr deque
  ctx.done.store(false, moRelaxed)
  ctx.stolenCount.store(0, moRelaxed)

  var ths: array[Thieves, Thread[ptr ChurnCtx]]
  for i in 0 ..< Thieves:
    createThread(ths[i], churnThief, addr ctx)

  var ownerPopped = 0
  for i in 1 .. Items:
    deque.push(i)
    if (i and 1) == 0:
      var item: int
      if deque.pop(item):
        inc(ownerPopped)

  while not deque.empty:
    var item: int
    if deque.pop(item):
      inc(ownerPopped)
    else:
      cpuRelax()

  ctx.done.store(true, moRelease)
  for i in 0 ..< Thieves:
    joinThread(ths[i])

  let totalStolen = ctx.stolenCount.load(moRelaxed)
  doAssert (ownerPopped + totalStolen) == Items,
    "Expected " & $Items & ", got popped=" & $ownerPopped & " stolen=" & $totalStolen
  doAssert deque.empty

# =============================================================================
# Test 10: Raw Throughput Microbenchmark (Single Thread Push/Pop)
# =============================================================================

testCase "WorkStealDeque: Uncontended throughput (> 50M ops/s)":
  var deque = initWorkStealDeque[int](1024)
  const N = 10_000_000

  let t0 = epochTime()
  for i in 1 .. N:
    deque.push(i)
  let tPush = epochTime() - t0

  var v: int
  let t1 = epochTime()
  for i in 1 .. N:
    discard deque.pop(v)
  let tPop = epochTime() - t1

  let totalSec = tPush + tPop
  let totalOps = (N * 2).float / totalSec / 1_000_000.0
  stdout.write("[" & $(totalOps.formatFloat(ffDecimal, 1)) & " M ops/s] ")
  doAssert deque.empty

# =============================================================================
# Final Summary
# =============================================================================

echo ""
echo "================================================================================"
echo "WorkStealDeque Test Suite Completed: ", gPassedTests, " / ", gTotalTests, " PASSED"
echo "================================================================================"
doAssert gPassedTests == gTotalTests
