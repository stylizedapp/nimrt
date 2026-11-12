## tests/test_ironclad_async_iocp.nim
## Ironclad Concurrency and IOCP Async Verification Suite
##
## Rigorously validates:
## 1. Native Windows IOCP creation, batch dequeuing (GetQueuedCompletionStatusEx), and wakeups.
## 2. Dmitry Vyukov lock-free OverlappedPool memory mechanics, offset tracking, and burst allocation.
## 3. High-concurrency I/O stress test:
##    - 1,024 concurrent async writes + 1,024 concurrent async reads + 1,024 interleaved read/writes.
##    - 100% byte-for-byte data integrity against ground truth.
##    - Verified execution on Work-Stealing ThreadPool worker threads (`currentWorkerId() >= 0`).
## 4. Graceful reactor shutdown without hangs or abandoned handles.
## 5. Zero-byte memory leak guarantee under TrackingAllocator with ARC/ORC lifecycle hooks.

import std/[os, strformat, atomics, monotimes, times]
import corex/[async, concurrency, memory, allocators, result]
import corex/platform/windows/win32_iocp

# =============================================================================
# Helper Utilities
# =============================================================================

const
  StressTempFile = "tests/test_async_iocp_stress_temp.bin"
  NumStressOps = 1024
  ChunkSize = 64
  MaxWorkersTracked = 32

type
  StressContext = object
    writesRemaining: Atomic[int]
    readsRemaining: Atomic[int]
    interleavedRemaining: Atomic[int]
    workerHits: array[MaxWorkersTracked, Atomic[int]]
    truthData: ptr UncheckedArray[byte]
    readData: ptr UncheckedArray[byte]
    interleavedTruth: ptr UncheckedArray[byte]
    interleavedRead: ptr UncheckedArray[byte]

# =============================================================================
# Test Suite 1: Native Win32 IOCP Primitives & Batch Completion Polling
# =============================================================================

proc testNativeIocpBatchPolling() =
  echo "[test_ironclad_async_iocp] 1. Testing native IOCP creation and batch completion polling..."

  # 1.1 Create standalone IOCP
  let portRes = createCompletionPort(0)
  doAssert portRes.isOk, &"Failed to create IOCP: {portRes.errVal}"
  let port = portRes.val
  doAssert port != nil and port != INVALID_HANDLE_VALUE, "Invalid IOCP handle returned"

  # 1.2 Post 128 queued completion status packets
  const TotalPackets = 128
  var postedKeys: array[TotalPackets, uint]
  var postedBytes: array[TotalPackets, uint32]

  for i in 0 ..< TotalPackets:
    postedKeys[i] = uint(0x1000 + i)
    postedBytes[i] = uint32((i + 1) * 8)
    let postRes = postQueuedCompletionStatus(port, postedBytes[i], postedKeys[i], nil)
    doAssert postRes.isOk, &"postQueuedCompletionStatus failed at {i}: {postRes.errVal}"

  # 1.3 Batch dequeue using GetQueuedCompletionStatusEx in chunks of 32
  var receivedEntries: array[32, OVERLAPPED_ENTRY]
  var receivedCount = 0
  var receivedMap: array[TotalPackets, bool]
  var batchBatchesObserved = 0

  while receivedCount < TotalPackets:
    var removed: uint32 = 0
    let pollRes = getQueuedCompletionStatusEx(
      port,
      cast[ptr UncheckedArray[OVERLAPPED_ENTRY]](addr receivedEntries[0]),
      uint32(receivedEntries.len),
      removed,
      timeoutMs = 1000'u32,
      alertable = false
    )
    doAssert pollRes.isOk, &"getQueuedCompletionStatusEx failed: {pollRes.errVal}"
    doAssert removed > 0, "Expected non-zero dequeued completions"
    if removed > 1:
      inc batchBatchesObserved

    for i in 0 ..< int(removed):
      let key = receivedEntries[i].lpCompletionKey
      let bytes = receivedEntries[i].dwNumberOfBytesTransferred
      let idx = int(key - 0x1000'u)
      doAssert idx >= 0 and idx < TotalPackets, &"Unexpected completion key: {key:#X}"
      doAssert bytes == postedBytes[idx], &"Byte transfer mismatch at {idx}: got {bytes}, expected {postedBytes[idx]}"
      doAssert not receivedMap[idx], &"Duplicate completion entry received for index {idx}"
      receivedMap[idx] = true
      inc receivedCount

  doAssert receivedCount == TotalPackets, &"Total received count mismatch: {receivedCount} vs {TotalPackets}"
  doAssert batchBatchesObserved > 0, "GetQueuedCompletionStatusEx failed to batch-dequeue multiple packets in one kernel call"

  # 1.4 Test non-blocking / timeout behavior on empty IOCP
  let emptyPollRes = pollCompletions(port, receivedEntries, timeoutMs = 10)
  doAssert emptyPollRes.isOk, "Empty poll returned error"
  doAssert emptyPollRes.val == 0, &"Expected 0 entries on empty poll, got {emptyPollRes.val}"

  # 1.5 Close IOCP handle
  let closeRes = closeHandle(port)
  doAssert closeRes.isOk, "Failed to close IOCP handle"

  echo &"[test_ironclad_async_iocp] Native IOCP passed: {TotalPackets} packets batch-dequeued and verified."

# =============================================================================
# Test Suite 2: OverlappedCtx, 64-bit Offsets & OverlappedPool Mechanics
# =============================================================================

proc testOverlappedPoolAndOffsets() =
  echo "[test_ironclad_async_iocp] 2. Testing OverlappedCtx, 64-bit offsets and OverlappedPool..."

  # 2.1 OverlappedCtx offset manipulation and pointer conversions
  var ctx: OverlappedCtx
  ctx.reset()
  doAssert offsetof(OverlappedCtx, overlapped) == 0, "OverlappedCtx.overlapped offset must be 0"

  # Test small, 32-bit boundary, and > 4GB 64-bit offsets
  const BigOffset = 0x00000002_80001000'i64 # ~10.5 GB
  ctx.setOffset(BigOffset)
  doAssert ctx.getOffset() == BigOffset, &"Offset mismatch: got {ctx.getOffset():#X}, expected {BigOffset:#X}"

  let pOv = toOverlapped(ctx)
  doAssert pOv == cast[ptr OVERLAPPED](addr ctx)
  let recovered = fromOverlapped(pOv)
  doAssert recovered == addr ctx

  # 2.2 OverlappedPool with TrackingAllocator & burst allocations
  var tracker = initTrackingAllocator()
  doAssert not tracker.hasLeaks()

  block:
    const PreallocatedCap = 32
    var pool = initOverlappedPool(PreallocatedCap, tracker.allocator())
    doAssert tracker.activeAllocs == 1, "Expected 1 pool array allocation"
    doAssert tracker.activeBytes >= sizeof(OverlappedCtx) * PreallocatedCap

    # Acquire all preallocated nodes
    var nodes: array[PreallocatedCap, ptr OverlappedCtx]
    for i in 0 ..< PreallocatedCap:
      nodes[i] = pool.acquire()
      doAssert nodes[i] != nil, &"Failed to acquire preallocated node {i}"

    # Pool is now exhausted: next acquisitions trigger dynamic burst fallback
    const BurstCount = 16
    var burstNodes: array[BurstCount, ptr OverlappedCtx]
    let allocsBeforeBurst = tracker.allocCount
    for i in 0 ..< BurstCount:
      burstNodes[i] = pool.acquire()
      doAssert burstNodes[i] != nil, &"Failed to acquire burst node {i}"
    doAssert tracker.allocCount == allocsBeforeBurst + BurstCount, "Burst nodes did not use tracking allocator"

    # Recycle all burst nodes
    for i in 0 ..< BurstCount:
      pool.recycle(burstNodes[i])

    # Recycle all preallocated nodes
    for i in 0 ..< PreallocatedCap:
      pool.recycle(nodes[i])

    # Destroy pool: must release preallocated storage and dynamic burst nodes
    destroy(pool)

  # Verify 0 memory leaks in pool
  doAssert tracker.activeAllocs == 0, &"Leaked activeAllocs in OverlappedPool: {tracker.activeAllocs}"
  doAssert tracker.activeBytes == 0, &"Leaked activeBytes in OverlappedPool: {tracker.activeBytes}"
  doAssert tracker.allocCount == tracker.freeCount, &"Mismatch allocCount={tracker.allocCount} vs freeCount={tracker.freeCount}"
  doAssert not tracker.hasLeaks(), "TrackingAllocator reported leaks after OverlappedPool destruction"

  echo "[test_ironclad_async_iocp] OverlappedCtx and OverlappedPool mechanics passed with 0 leaks."

# =============================================================================
# Test Suite 3: Concurrency Stress Test with WorkStealing ThreadPool
# =============================================================================

proc stressWriteCallback(bytesTransferred: uint32, err: int32, userData: pointer) {.nimcall, gcsafe, raises: [].} =
  let ctx = cast[ptr StressContext](userData)
  if ctx.isNil: return

  doAssert err == 0, "Async write callback received error: " & $err
  doAssert bytesTransferred == uint32(ChunkSize), "Async write bytes mismatch: " & $bytesTransferred

  # Verify execution on Work-Stealing ThreadPool worker thread
  let wid = currentWorkerId()
  doAssert wid >= 0, "Async write callback did not execute on a ThreadPool worker!"
  if wid < MaxWorkersTracked:
    atomicInc(ctx.workerHits[wid], 1)

  atomicDec(ctx.writesRemaining, 1)

proc stressReadCallback(bytesTransferred: uint32, err: int32, userData: pointer) {.nimcall, gcsafe, raises: [].} =
  let ctx = cast[ptr StressContext](userData)
  if ctx.isNil: return

  doAssert err == 0, "Async read callback received error: " & $err
  doAssert bytesTransferred == uint32(ChunkSize), "Async read bytes mismatch: " & $bytesTransferred

  # Verify execution on Work-Stealing ThreadPool worker thread
  let wid = currentWorkerId()
  doAssert wid >= 0, "Async read callback did not execute on a ThreadPool worker!"
  if wid < MaxWorkersTracked:
    atomicInc(ctx.workerHits[wid], 1)

  atomicDec(ctx.readsRemaining, 1)

proc stressInterleavedCallback(bytesTransferred: uint32, err: int32, userData: pointer) {.nimcall, gcsafe, raises: [].} =
  let ctx = cast[ptr StressContext](userData)
  if ctx.isNil: return

  doAssert err == 0, "Interleaved async callback received error: " & $err
  doAssert bytesTransferred == uint32(ChunkSize), "Interleaved bytes mismatch: " & $bytesTransferred

  let wid = currentWorkerId()
  doAssert wid >= 0, "Interleaved callback did not execute on a ThreadPool worker!"
  if wid < MaxWorkersTracked:
    atomicInc(ctx.workerHits[wid], 1)

  atomicDec(ctx.interleavedRemaining, 1)

proc testConcurrencyStressIo() =
  echo &"[test_ironclad_async_iocp] 3. Running concurrency stress test ({NumStressOps}+ concurrent ops)..."

  # Ensure clean file state
  if fileExists(StressTempFile):
    removeFile(StressTempFile)

  # Allocate shared test context
  let ctx = cast[ptr StressContext](allocShared0(sizeof(StressContext)))
  defer: deallocShared(ctx)

  const TotalBytes = NumStressOps * ChunkSize # 65,536 bytes
  ctx.truthData = cast[ptr UncheckedArray[byte]](allocShared0(TotalBytes))
  ctx.readData = cast[ptr UncheckedArray[byte]](allocShared0(TotalBytes))
  ctx.interleavedTruth = cast[ptr UncheckedArray[byte]](allocShared0(TotalBytes))
  ctx.interleavedRead = cast[ptr UncheckedArray[byte]](allocShared0(TotalBytes))
  defer:
    deallocShared(ctx.truthData)
    deallocShared(ctx.readData)
    deallocShared(ctx.interleavedTruth)
    deallocShared(ctx.interleavedRead)

  # Generate deterministic ground truth data
  for c in 0 ..< NumStressOps:
    for b in 0 ..< ChunkSize:
      let idx = c * ChunkSize + b
      ctx.truthData[idx] = byte((c * 37 + b * 11 + 0xA5) and 0xFF)
      ctx.interleavedTruth[idx] = byte((c * 53 + b * 19 + 0x3C) and 0xFF)

  # 3.1 Initialize ThreadPool with 4 workers and AsyncReactor
  var pool = initThreadPool(4)
  var reactor: AsyncReactor
  let initRes = initAsyncReactor(reactor, addr pool, poolCapacity = 2048)
  doAssert initRes.isOk, &"Failed to init AsyncReactor: {initRes.errVal}"

  # 3.2 Open AsyncFile with FILE_FLAG_OVERLAPPED
  let fileRes = openAsyncFile(addr reactor, StressTempFile, writeAccess = true, createAlways = true)
  doAssert fileRes.isOk, &"Failed to open AsyncFile: {fileRes.errVal}"
  var file = fileRes.val

  # ---------------------------------------------------------------------------
  # Phase A: 1,024 Concurrent Asynchronous Writes across multiple offsets
  # ---------------------------------------------------------------------------
  echo &"   -> Dispatching {NumStressOps} concurrent async writes..."
  ctx.writesRemaining.store(NumStressOps, moRelease)

  for c in 0 ..< NumStressOps:
    let offset = int64(c * ChunkSize)
    let sp = byteSpan(addr ctx.truthData[offset], ChunkSize)
    let res = file.asyncWrite(offset, sp, stressWriteCallback, cast[pointer](ctx))
    doAssert res.isOk, &"asyncWrite failed at chunk {c}: {res.errVal}"

  # Wait for all writes to complete
  var elapsedMs = 0
  while ctx.writesRemaining.load(moAcquire) > 0:
    sleep(2)
    elapsedMs += 2
    doAssert elapsedMs < 20_000, "Timed out waiting for concurrent async writes"

  echo &"   -> All {NumStressOps} writes completed in {elapsedMs}ms."

  # ---------------------------------------------------------------------------
  # Phase B: 1,024 Concurrent Asynchronous Reads across multiple offsets
  # ---------------------------------------------------------------------------
  echo &"   -> Dispatching {NumStressOps} concurrent async reads..."
  ctx.readsRemaining.store(NumStressOps, moRelease)

  for c in 0 ..< NumStressOps:
    let offset = int64(c * ChunkSize)
    let sp = byteSpan(addr ctx.readData[offset], ChunkSize)
    let res = file.asyncRead(offset, sp, stressReadCallback, cast[pointer](ctx))
    doAssert res.isOk, &"asyncRead failed at chunk {c}: {res.errVal}"

  # Wait for all reads to complete
  elapsedMs = 0
  while ctx.readsRemaining.load(moAcquire) > 0:
    sleep(2)
    elapsedMs += 2
    doAssert elapsedMs < 20_000, "Timed out waiting for concurrent async reads"

  echo &"   -> All {NumStressOps} reads completed in {elapsedMs}ms."

  # ---------------------------------------------------------------------------
  # Phase C: 100% Byte-for-Byte Data Integrity Verification
  # ---------------------------------------------------------------------------
  echo "   -> Verifying data integrity against expected ground truth buffer..."
  var byteMismatches = 0
  for c in 0 ..< NumStressOps:
    for b in 0 ..< ChunkSize:
      let idx = c * ChunkSize + b
      if ctx.readData[idx] != ctx.truthData[idx]:
        inc byteMismatches
  doAssert byteMismatches == 0, &"Data corruption detected: {byteMismatches} byte mismatches found!"
  echo &"   -> Data integrity confirmed: {TotalBytes} bytes match ground truth exactly."

  # ---------------------------------------------------------------------------
  # Phase D: Interleaved Concurrent Simultaneous Reads and Writes
  # ---------------------------------------------------------------------------
  echo "   -> Dispatching simultaneous interleaved reads (odd chunks) and writes (even chunks)..."
  ctx.interleavedRemaining.store(NumStressOps, moRelease)

  for c in 0 ..< NumStressOps:
    let offset = int64(c * ChunkSize)
    if (c and 1) == 0:
      # Even chunks: write new interleaved pattern
      let sp = byteSpan(addr ctx.interleavedTruth[offset], ChunkSize)
      let res = file.asyncWrite(offset, sp, stressInterleavedCallback, cast[pointer](ctx))
      doAssert res.isOk
    else:
      # Odd chunks: read existing pattern
      let sp = byteSpan(addr ctx.interleavedRead[offset], ChunkSize)
      let res = file.asyncRead(offset, sp, stressInterleavedCallback, cast[pointer](ctx))
      doAssert res.isOk

  elapsedMs = 0
  while ctx.interleavedRemaining.load(moAcquire) > 0:
    sleep(2)
    elapsedMs += 2
    doAssert elapsedMs < 20_000, "Timed out waiting for interleaved I/O operations"

  # Verify odd chunks matched original truthData
  for c in 0 ..< NumStressOps:
    if (c and 1) != 0:
      for b in 0 ..< ChunkSize:
        let idx = c * ChunkSize + b
        doAssert ctx.interleavedRead[idx] == ctx.truthData[idx],
          &"Interleaved read corruption at chunk {c}, byte {b}"

  echo "   -> Interleaved concurrent operations verified without races or corruptions."

  # ---------------------------------------------------------------------------
  # Phase E: Verify ThreadPool Worker Participation
  # ---------------------------------------------------------------------------
  echo "   -> Verifying completions executed across WorkStealing ThreadPool workers..."
  var activeWorkerCount = 0
  var totalCompletedJobs = 0
  for w in 0 ..< 4:
    let hits = ctx.workerHits[w].load(moRelaxed)
    totalCompletedJobs += hits
    if hits > 0:
      inc activeWorkerCount
    echo &"      Worker {w}: processed {hits} completion jobs"

  doAssert activeWorkerCount >= 2, &"Expected multiple workers to participate, got {activeWorkerCount}"
  doAssert totalCompletedJobs == (NumStressOps * 3),
    &"Completion count mismatch: {totalCompletedJobs} vs expected {NumStressOps * 3}"

  # Clean shutdown of file, reactor, and thread pool
  let closeRes = file.close()
  doAssert closeRes.isOk
  reactor.stop()
  reactor.destroy()
  pool.shutdown()

  if fileExists(StressTempFile):
    removeFile(StressTempFile)

  echo "[test_ironclad_async_iocp] Concurrency stress test PASSED flawlessly."

# =============================================================================
# Test Suite 4: Graceful Shutdown & Zero Memory Leaks under TrackingAllocator
# =============================================================================

proc testGracefulShutdownAndLeakCheck() =
  echo "[test_ironclad_async_iocp] 4. Testing graceful shutdown and TrackingAllocator leak invariants..."

  var tracker = initTrackingAllocator()
  doAssert not tracker.hasLeaks()

  # 4.1 Allocate heap-backed AsyncReactor with TrackingAllocator
  block:
    var pool = initThreadPool(2)
    let reactorRes = newAsyncReactor(addr pool, poolCapacity = 128, allocator = tracker.allocator())
    doAssert reactorRes.isOk, "Failed to create reactor with tracking allocator"
    let reactor = reactorRes.val

    # Verify allocations were tracked
    doAssert tracker.activeAllocs > 0, "Tracker failed to record reactor allocations"
    doAssert tracker.activeBytes > 0, "Tracker failed to record reactor allocated bytes"

    # Acquire and recycle a few contexts
    let ctx1 = reactor.overlappedPool.acquire()
    let ctx2 = reactor.overlappedPool.acquire()
    doAssert ctx1 != nil and ctx2 != nil
    reactor.overlappedPool.recycle(ctx1)
    reactor.overlappedPool.recycle(ctx2)

    # Perform graceful shutdown
    stop(reactor)
    destroy(reactor)
    pool.shutdown()

  # 4.2 Verify 0 bytes leaked under TrackingAllocator
  echo &"   -> TrackingAllocator stats: allocCount={tracker.allocCount}, freeCount={tracker.freeCount}, activeAllocs={tracker.activeAllocs}, activeBytes={tracker.activeBytes}"
  doAssert tracker.activeAllocs == 0, &"LEAK DETECTED: activeAllocs={tracker.activeAllocs}"
  doAssert tracker.activeBytes == 0, &"LEAK DETECTED: activeBytes={tracker.activeBytes}"
  doAssert tracker.allocCount == tracker.freeCount, &"LEAK DETECTED: allocCount({tracker.allocCount}) != freeCount({tracker.freeCount})"
  doAssert not tracker.hasLeaks(), "TrackingAllocator reported memory leaks!"

  # 4.3 Test rapid stop and restart responsiveness (no hangs or abandoned handles)
  block:
    var r: AsyncReactor
    let res = initAsyncReactor(r, nil, poolCapacity = 64)
    doAssert res.isOk
    # Immediate stop without operations
    let t0 = getMonoTime()
    r.stop()
    r.destroy()
    let elapsedMs = int((getMonoTime() - t0).inMilliseconds)
    doAssert elapsedMs < 500, &"Reactor stop hung for {elapsedMs}ms"
    doAssert r.iocpHandle == nil, "IOCP handle abandoned after destroy"

  echo "[test_ironclad_async_iocp] Graceful shutdown and 0-byte leak check PASSED."

# =============================================================================
# Main Test Entry Point
# =============================================================================

when isMainModule:
  echo "==============================================================================="
  echo "       IRONCLAD CONCURRENCY & IOCP ASYNC VERIFICATION TEST SUITE               "
  echo "==============================================================================="
  testNativeIocpBatchPolling()
  testOverlappedPoolAndOffsets()
  testConcurrencyStressIo()
  testGracefulShutdownAndLeakCheck()
  echo "\n>>> [test_ironclad_async_iocp] ALL TESTS PASSED UNCOMPROMISINGLY <<<"
