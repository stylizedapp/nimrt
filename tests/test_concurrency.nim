## Comprehensive Multi-Threaded Verification Test for corex/concurrency
## Tests all 10 features under --mm:orc --threads:on --panics:on

import corex
import std/[os, osproc, strutils]

# =============================================================================
# Test Suite Runner Infrastructure
# =============================================================================

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
# Feature 25: Atomic[T] and MemoryOrder Tests
# =============================================================================

testCase "Feature 25: MemoryOrder enum and aliases":
  doAssert ord(Relaxed) == 0
  doAssert ord(Consume) == 1
  doAssert ord(Acquire) == 2
  doAssert ord(Release) == 3
  doAssert ord(AcqRel) == 4
  doAssert ord(SeqCst) == 5

  doAssert moRelaxed == Relaxed
  doAssert moConsume == Consume
  doAssert moAcquire == Acquire
  doAssert moRelease == Release
  doAssert moAcqRel == AcqRel
  doAssert moSeqCst == SeqCst
  doAssert moSequentiallyConsistent == SeqCst

testCase "Feature 25: Atomic basic operations (load, store, exchange)":
  var a = initAtomic(100)
  doAssert a.load(Relaxed) == 100
  a.store(200, Release)
  doAssert a.load(Acquire) == 200

  let prev = a.exchange(300, AcqRel)
  doAssert prev == 200
  doAssert a.load(SeqCst) == 300

testCase "Feature 25: Atomic compareExchange strong and weak (var and val expected)":
  var a = initAtomic(42)

  # 1. var expected overload
  var expVar = 42
  let ok1 = a.compareExchange(expVar, 100, SeqCst, Relaxed)
  doAssert ok1
  doAssert a.load() == 100
  doAssert expVar == 42

  # Failed var expected updates expected
  expVar = 999
  let ok2 = a.compareExchange(expVar, 200, SeqCst, Relaxed)
  doAssert not ok2
  doAssert expVar == 100 # expVar updated to actual
  doAssert a.load() == 100

  # 2. val expected overload (literals)
  let ok3 = a.compareExchange(100, 500, SeqCst)
  doAssert ok3
  doAssert a.load() == 500

  let ok4 = a.compareExchange(999, 700, SeqCst)
  doAssert not ok4
  doAssert a.load() == 500

  # 3. compareExchangeWeak
  var cur = a.load(Relaxed)
  while not a.compareExchangeWeak(cur, cur + 1, SeqCst, Relaxed):
    discard
  doAssert a.load() == 501

testCase "Feature 25: Atomic arithmetic (fetchAdd, fetchSub, fetchAnd, fetchOr, fetchXor)":
  var a = initAtomic(10)
  doAssert a.fetchAdd(5) == 10
  doAssert a.load() == 15
  doAssert a.fetchSub(3) == 15
  doAssert a.load() == 12

  doAssert a.fetchAnd(0b1110) == 12 # 12 is 0b1100, 12 and 14 = 12
  doAssert a.load() == 12
  doAssert a.fetchOr(0b0001) == 12  # 12 or 1 = 13
  doAssert a.load() == 13
  doAssert a.fetchXor(0b0011) == 13 # 13 xor 3 = 14
  doAssert a.load() == 14

  a.atomicInc(2)
  doAssert a.load() == 16
  a.atomicDec(6)
  doAssert a.load() == 10
  a += 5
  doAssert a.load() == 15
  a -= 5
  doAssert a.load() == 10

testCase "Feature 25: Atomic bool operations":
  var b = initAtomic(false)
  doAssert not b.load()
  b.store(true)
  doAssert b.load()

  # Bool bitwise
  doAssert b.fetchAnd(false) == true
  doAssert b.load() == false
  doAssert b.fetchOr(true) == false
  doAssert b.load() == true
  doAssert b.fetchXor(true) == true
  doAssert b.load() == false

testCase "Feature 25: Atomic pointer operations":
  var data: array[4, int] = [10, 20, 30, 40]
  var ptrAtom: Atomic[ptr int]
  ptrAtom.store(addr data[0])

  let p0 = ptrAtom.fetchAdd(2)
  doAssert p0 == addr data[0]
  doAssert ptrAtom.load() == addr data[2]
  doAssert ptrAtom.load()[] == 30

  let p2 = ptrAtom.fetchSub(1)
  doAssert p2 == addr data[2]
  doAssert ptrAtom.load() == addr data[1]
  doAssert ptrAtom.load()[] == 20

testCase "Feature 25: Hardware and signal fences":
  fence(SeqCst)
  fence(Acquire)
  fence(Release)
  signalFence(SeqCst)

# =============================================================================
# Feature 26: SpinLock Tests
# =============================================================================

testCase "Feature 26: SpinLock basic acquire, tryAcquire, release":
  var l = initSpinLock()
  doAssert l.tryAcquire()
  doAssert not l.tryAcquire() # Already held
  l.release()
  doAssert l.tryAcquire()
  l.release()

testCase "Feature 26: SpinLock multi-threaded contention stress test":
  type SpinCtx = object
    lock: ptr SpinLock
    counter: int

  proc spinWorker(ctx: ptr SpinCtx) {.thread.} =
    for _ in 1 .. 25_000:
      ctx.lock[].acquire()
      inc(ctx.counter)
      ctx.lock[].release()

  var lock = initSpinLock()
  var ctx: SpinCtx
  ctx.lock = addr lock
  ctx.counter = 0

  const ThreadsCount = 4
  var threads: array[ThreadsCount, Thread[ptr SpinCtx]]
  for i in 0 ..< ThreadsCount:
    createThread(threads[i], spinWorker, addr ctx)
  for i in 0 ..< ThreadsCount:
    joinThread(threads[i])

  doAssert ctx.counter == 100_000

# =============================================================================
# Feature 27: SysLock Tests
# =============================================================================

testCase "Feature 27: SysLock basic acquire, tryAcquire, release":
  var m = initSysLock()
  doAssert m.tryAcquire()
  doAssert not m.tryAcquire() # Exclusive lock already held
  m.release()
  doAssert m.tryAcquire()
  m.release()
  m.deinitSysLock()

testCase "Feature 27: SysLock multi-threaded contention stress test":
  type MutexCtx = object
    lock: ptr SysLock
    counter: int

  proc mutexWorker(ctx: ptr MutexCtx) {.thread.} =
    for _ in 1 .. 25_000:
      acquire(ctx.lock)
      inc(ctx.counter)
      release(ctx.lock)

  var lock = initSysLock()
  var ctx: MutexCtx
  ctx.lock = addr lock
  ctx.counter = 0

  const ThreadsCount = 4
  var threads: array[ThreadsCount, Thread[ptr MutexCtx]]
  for i in 0 ..< ThreadsCount:
    createThread(threads[i], mutexWorker, addr ctx)
  for i in 0 ..< ThreadsCount:
    joinThread(threads[i])

  doAssert ctx.counter == 100_000
  lock.deinitSysLock()

# =============================================================================
# Feature 28: RwLock Tests
# =============================================================================

testCase "Feature 28: RwLock shared read and exclusive write modes":
  var rw = initRwLock()
  # Concurrent reads
  rw.acquireRead()
  doAssert rw.tryAcquireRead()
  rw.releaseRead()
  rw.releaseRead()

  # Exclusive write
  rw.acquireWrite()
  doAssert not rw.tryAcquireRead()
  doAssert not rw.tryAcquireWrite()
  rw.releaseWrite()

  # Exclusive lock aliases
  rw.acquire()
  rw.release()
  rw.deinitRwLock()

testCase "Feature 28: RwLock multi-threaded readers-writer coordination":
  type RwCtx = object
    lock: ptr RwLock
    sharedValue: int
    readCount: Atomic[int]
    stop: Atomic[bool]

  proc readerProc(ctx: ptr RwCtx) {.thread.} =
    while not ctx.stop.load(moRelaxed):
      ctx.lock[].acquireRead()
      let v = ctx.sharedValue
      discard ctx.readCount.fetchAdd(1, moRelaxed)
      doAssert v >= 0
      ctx.lock[].releaseRead()

  proc writerProc(ctx: ptr RwCtx) {.thread.} =
    for i in 1 .. 5_000:
      ctx.lock[].acquireWrite()
      ctx.sharedValue = i
      ctx.lock[].releaseWrite()

  var rw = initRwLock()
  var ctx: RwCtx
  ctx.lock = addr rw
  ctx.sharedValue = 0
  ctx.readCount.store(0)
  ctx.stop.store(false)

  var readers: array[4, Thread[ptr RwCtx]]
  var writers: array[2, Thread[ptr RwCtx]]
  for i in 0 ..< 4:
    createThread(readers[i], readerProc, addr ctx)
  for i in 0 ..< 2:
    createThread(writers[i], writerProc, addr ctx)

  for i in 0 ..< 2:
    joinThread(writers[i])
  ctx.stop.store(true)
  for i in 0 ..< 4:
    joinThread(readers[i])

  doAssert ctx.readCount.load() > 1000
  rw.deinitRwLock()

# =============================================================================
# Feature 29: RAII Lock Guards Tests
# =============================================================================

testCase "Feature 29: RAII withLock, withReadLock, withWriteLock":
  var m = initSysLock()
  var spin = initSpinLock()
  var rw = initRwLock()

  # Expression value propagation
  let val1 = withLock(m):
    10 + 20
  doAssert val1 == 30
  doAssert m.tryAcquire()
  m.release()

  let val2 = withLock(spin):
    100 * 2
  doAssert val2 == 200
  doAssert spin.tryAcquire()
  spin.release()

  let val3 = withReadLock(rw):
    "hello" & " world"
  doAssert val3 == "hello world"

  let val4 = withWriteLock(rw):
    42
  doAssert val4 == 42
  doAssert rw.tryAcquireWrite()
  rw.releaseWrite()

  # Early return unlock guarantee
  proc earlyReturnHelper(lock: var SysLock): int =
    withLock(lock):
      if true:
        return 777
    return 0

  doAssert earlyReturnHelper(m) == 777
  doAssert m.tryAcquire() # Must be released despite early return!
  m.release()

# =============================================================================
# Feature 30: Barrier Tests
# =============================================================================

testCase "Feature 30: Barrier cyclic phases and trip leader election":
  type BarrierCtx = object
    b: ptr Barrier
    phase1Count: Atomic[int]
    phase2Count: Atomic[int]
    leaders: Atomic[int]

  proc barrierWorker(ctx: ptr BarrierCtx) {.thread.} =
    discard ctx.phase1Count.fetchAdd(1, moRelaxed)
    if ctx.b[].wait():
      discard ctx.leaders.fetchAdd(1, moRelaxed)

    discard ctx.phase2Count.fetchAdd(1, moRelaxed)
    if ctx.b[].wait():
      discard ctx.leaders.fetchAdd(1, moRelaxed)

  var b = initBarrier(4)
  doAssert b.parties == 4
  doAssert b.count == 4

  var ctx: BarrierCtx
  ctx.b = addr b
  ctx.phase1Count.store(0)
  ctx.phase2Count.store(0)
  ctx.leaders.store(0)

  var threads: array[4, Thread[ptr BarrierCtx]]
  for i in 0 ..< 4:
    createThread(threads[i], barrierWorker, addr ctx)
  for i in 0 ..< 4:
    joinThread(threads[i])

  doAssert ctx.phase1Count.load() == 4
  doAssert ctx.phase2Count.load() == 4
  doAssert ctx.leaders.load() == 2 # Exactly 1 leader per phase
  b.reset()
  doAssert b.count == 4

# =============================================================================
# Feature 31: WaitGroup Tests
# =============================================================================

testCase "Feature 31: WaitGroup batch worker coordination":
  type WgCtx = object
    wg: ptr WaitGroup
    total: Atomic[int]

  proc wgWorker(ctx: ptr WgCtx) {.thread.} =
    discard ctx.total.fetchAdd(10, moRelaxed)
    ctx.wg[].done()

  var wg = initWaitGroup()
  var ctx: WgCtx
  ctx.wg = addr wg
  ctx.total.store(0)

  const NumWorkers = 8
  wg.add(NumWorkers)
  doAssert wg.value == NumWorkers

  var threads: array[NumWorkers, Thread[ptr WgCtx]]
  for i in 0 ..< NumWorkers:
    createThread(threads[i], wgWorker, addr ctx)

  wg.wait()
  for i in 0 ..< NumWorkers:
    joinThread(threads[i])

  doAssert ctx.total.load() == 80
  doAssert wg.value == 0

testCase "Feature 31: WaitGroup negative counter raises Defect":
  let helperPath = "c:\\Users\\sanal\\Desktop\\nim\\.agents\\teamwork\\sub_orch_m4\\worker_1\\defect_test.nim"
  writeFile(helperPath, """
import corex
var wg = initWaitGroup()
wg.add(-1)
""")
  let (outp, exitCode) = execCmdEx("nim c -r --hints:off " & helperPath)
  if fileExists(helperPath): removeFile(helperPath)
  if fileExists(changeFileExt(helperPath, ExeExt)): removeFile(changeFileExt(helperPath, ExeExt))
  doAssert exitCode != 0
  doAssert outp.contains("negative WaitGroup counter")

# =============================================================================
# Feature 32: SpscQueue Tests
# =============================================================================

testCase "Feature 32: SpscQueue basic capacity, push, pop, len, empty, full":
  var q = initSpscQueue[int, 4]()
  doAssert q.empty
  doAssert not q.full
  doAssert q.len == 0

  doAssert q.push(10)
  doAssert q.push(20)
  doAssert q.push(30)
  doAssert q.push(40)
  doAssert q.full
  doAssert not q.push(50) # Queue is full!

  var v: int
  doAssert q.pop(v)
  doAssert v == 10
  doAssert not q.full

  let opt = q.pop()
  doAssert opt.isSome
  doAssert opt.get == 20

  doAssert q.pop(v) and v == 30
  doAssert q.pop(v) and v == 40
  doAssert q.empty
  doAssert not q.pop(v)

testCase "Feature 32: SpscQueue lock-free multi-threaded streaming (100,000 items)":
  const N = 100_000
  const Cap = 256

  type SpscCtx = object
    q: ptr SpscQueue[int, Cap]
    receivedSum: Atomic[int64]

  proc producer(ctx: ptr SpscCtx) {.thread.} =
    for i in 1 .. N:
      while not ctx.q[].push(i):
        discard

  proc consumer(ctx: ptr SpscCtx) {.thread.} =
    var localSum: int64 = 0
    for i in 1 .. N:
      var v: int
      while not ctx.q[].pop(v):
        discard
      localSum += int64(v)
    ctx.receivedSum.store(localSum, moRelaxed)

  var q = initSpscQueue[int, Cap]()
  var ctx: SpscCtx
  ctx.q = addr q
  ctx.receivedSum.store(0)

  var thProd, thCons: Thread[ptr SpscCtx]
  createThread(thProd, producer, addr ctx)
  createThread(thCons, consumer, addr ctx)

  joinThread(thProd)
  joinThread(thCons)

  let expectedSum = (int64(N) * (int64(N) + 1)) div 2
  doAssert ctx.receivedSum.load() == expectedSum

# =============================================================================
# Feature 33: MpmcQueue Tests
# =============================================================================

testCase "Feature 33: MpmcQueue basic push, pop, len, empty, full":
  var q = initMpmcQueue[int, 8]()
  doAssert q.empty
  for i in 1 .. 8:
    doAssert q.push(i)
  doAssert q.full
  doAssert not q.push(999)

  var sum = 0
  for i in 1 .. 8:
    var v: int
    doAssert q.pop(v)
    sum += v
  doAssert sum == 36
  doAssert q.empty

testCase "Feature 33: MpmcQueue multi-producer multi-consumer (4 prods, 4 cons, 80,000 items)":
  const ItemsPerProd = 20_000
  const NumProds = 4
  const NumCons = 4
  const TotalItems = ItemsPerProd * NumProds
  const Cap = 128

  type MpmcCtx = object
    q: ptr MpmcQueue[int, Cap]
    totalPopped: Atomic[int]
    totalSum: Atomic[int64]

  proc mpmcProducer(ctx: ptr MpmcCtx) {.thread.} =
    for i in 1 .. ItemsPerProd:
      while not ctx.q[].push(1):
        discard

  proc mpmcConsumer(ctx: ptr MpmcCtx) {.thread.} =
    var localCount = 0
    while localCount < (TotalItems div NumCons):
      var v: int
      if ctx.q[].pop(v):
        inc(localCount)
        discard ctx.totalPopped.fetchAdd(1, moRelaxed)
        discard ctx.totalSum.fetchAdd(int64(v), moRelaxed)

  var q = initMpmcQueue[int, Cap]()
  var ctx: MpmcCtx
  ctx.q = addr q
  ctx.totalPopped.store(0)
  ctx.totalSum.store(0)

  var prods: array[NumProds, Thread[ptr MpmcCtx]]
  var cons: array[NumCons, Thread[ptr MpmcCtx]]
  for i in 0 ..< NumProds:
    createThread(prods[i], mpmcProducer, addr ctx)
  for i in 0 ..< NumCons:
    createThread(cons[i], mpmcConsumer, addr ctx)

  for i in 0 ..< NumProds:
    joinThread(prods[i])
  for i in 0 ..< NumCons:
    joinThread(cons[i])

  doAssert ctx.totalPopped.load() == TotalItems
  doAssert ctx.totalSum.load() == int64(TotalItems)

# =============================================================================
# Feature 34: ThreadPool & parallelFor Tests
# =============================================================================

testCase "Feature 34: ThreadPool spawn asynchronous tasks":
  var pool = initThreadPool(4)
  var executed = initAtomic(0)

  for i in 1 .. 50:
    pool.spawn(proc() {.gcsafe.} =
      discard executed.fetchAdd(1, moRelaxed)
    )

  pool.shutdown()
  doAssert executed.load() == 50

testCase "Feature 34: ThreadPool parallelFor chunk range partitioning":
  var pool = initThreadPool(4)
  const Size = 10_000
  var arr: seq[int] = newSeq[int](Size)

  # Parallel write: fn(s, e)
  pool.parallelFor(0, Size, proc(s, e: int) {.gcsafe.} =
    for i in s ..< e:
      arr[i] = i * 2
  )

  for i in 0 ..< Size:
    doAssert arr[i] == i * 2

  # Parallel item: fn(i)
  pool.parallelFor(0, Size, proc(i: int) {.gcsafe.} =
    arr[i] = arr[i] + 1
  )

  for i in 0 ..< Size:
    doAssert arr[i] == i * 2 + 1

  pool.shutdown()

testCase "Feature 34: Global ThreadPool facades (spawn, parallelFor, shutdownThreadPool)":
  var sum = initAtomic(0)

  spawn(proc() {.gcsafe.} =
    discard sum.fetchAdd(100, moRelaxed)
  )

  # Let task run
  while sum.load() == 0:
    discard

  doAssert sum.load() == 100

  const N = 5_000
  var results: seq[int] = newSeq[int](N)
  parallelFor(0, N, proc(i: int) {.gcsafe.} =
    results[i] = i + 10
  )

  for i in 0 ..< N:
    doAssert results[i] == i + 10

  shutdownThreadPool()

# =============================================================================
# Final Summary
# =============================================================================

echo ""
echo "================================================================================"
echo "Corex Concurrency Test Suite Completed: ", gPassedTests, " / ", gTotalTests, " PASSED"
echo "================================================================================"
doAssert gPassedTests == gTotalTests
