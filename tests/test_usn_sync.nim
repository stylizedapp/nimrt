## tests/test_usn_sync.nim — Unit & Integration Tests for USN Journal Sync & Monitor
##
## Tests:
## 1. Mock USN stream record parsing and field alignment.
## 2. In-memory Indexer creation, renaming, updating, and deletion via USN records.
## 3. Background USN monitor thread lifecycle and rapid graceful shutdown (<500ms).
## 4. Multi-threaded mock stream ingestion with atomic synchronization.
## 5. Non-admin privilege detection with descriptive error reporting.
## 6. Zero memory leaks verification via testWithLeakCheck.

import std/[monotimes, times, os, strutils]
import corex
import corex/[allocators, result, testing, concurrency]
import corex/platform/windows/win32_fs
import ../apps/everything/src/indexer
import ../apps/everything/src/usn_monitor

# =============================================================================
# Mock Record & Buffer Generators
# =============================================================================

proc makeMockUsnRecord(
  name: string,
  parentFrn: uint64,
  frn: uint64,
  isDir: bool,
  reason: uint32 = USN_REASON_FILE_CREATE,
  usn: USN = 100'i64,
  attrs: uint32 = 0
): seq[byte] =
  let nameUtf16Len = name.len * 2
  let rawLen = 60 + nameUtf16Len
  let alignedLen = ((rawLen + 7) div 8) * 8
  result = newSeq[byte](alignedLen)

  # offset 0: recordLength (uint32)
  cast[ptr uint32](addr result[0])[] = uint32(alignedLen)
  # offset 4: majorVersion (uint16) = 2
  cast[ptr uint16](addr result[4])[] = 2'u16
  # offset 6: minorVersion (uint16) = 0
  cast[ptr uint16](addr result[6])[] = 0'u16
  # offset 8: fileReferenceNumber (uint64)
  cast[ptr uint64](addr result[8])[] = frn
  # offset 16: parentFileReferenceNumber (uint64)
  cast[ptr uint64](addr result[16])[] = parentFrn
  # offset 24: usn (USN / int64)
  cast[ptr int64](addr result[24])[] = usn
  # offset 32: timeStamp (int64)
  cast[ptr int64](addr result[32])[] = 0'i64
  # offset 40: reason (uint32)
  cast[ptr uint32](addr result[40])[] = reason
  # offset 44: sourceInfo (uint32)
  cast[ptr uint32](addr result[44])[] = 0'u32
  # offset 48: securityId (uint32)
  cast[ptr uint32](addr result[48])[] = 0'u32
  # offset 52: fileAttributes (uint32)
  let finalAttrs: uint32 = if attrs != 0: attrs
                          elif isDir: win32_fs.FILE_ATTRIBUTE_DIRECTORY
                          else: 0x00000080'u32
  cast[ptr uint32](addr result[52])[] = finalAttrs
  # offset 56: fileNameLength (uint16)
  cast[ptr uint16](addr result[56])[] = uint16(nameUtf16Len)
  # offset 58: fileNameOffset (uint16)
  cast[ptr uint16](addr result[58])[] = 60'u16

  # UTF-16 bytes of name starting at offset 60
  for i in 0 ..< name.len:
    cast[ptr uint16](addr result[60 + i * 2])[] = uint16(name[i])

proc makeMockUsnBuffer(nextUsn: USN, records: seq[seq[byte]]): seq[byte] =
  result = newSeq[byte](8)
  cast[ptr USN](addr result[0])[] = nextUsn
  for r in records:
    result.add(r)

# =============================================================================
# Main Test Suite
# =============================================================================

proc runUsnSyncTests() =
  echo "=== RUNNING USN JOURNAL SYNC & MONITOR TESTS ==="

  # ---------------------------------------------------------------------------
  # Test 1: Record Creation via USN_REASON_FILE_CREATE
  # ---------------------------------------------------------------------------
  block:
    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()

    let rRoot = makeMockUsnRecord("C:", 0'u64, 5'u64, true, USN_REASON_FILE_CREATE, 100'i64)
    let rFolder = makeMockUsnRecord("Projects", 5'u64, 100'u64, true, USN_REASON_FILE_CREATE, 101'i64)
    let rFile = makeMockUsnRecord("main.nim", 100'u64, 200'u64, false, USN_REASON_FILE_CREATE, 102'i64)

    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rRoot[0])))
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rFolder[0])))
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rFile[0])))

    doAssert idx.len == 3
    doAssert idx.nodes.contains(200'u64)

    let fileSlabId = idx.nodes.get(200'u64).get
    let resolved = idx.resolvePath(fileSlabId).unwrap()
    doAssert resolved == "Projects\\main.nim", "Expected 'Projects\\main.nim', got: " & resolved

    idx.deinit()
    echo "[OK] 01: File and folder creation with hierarchical path resolution"

  # ---------------------------------------------------------------------------
  # Test 2: File Renaming via USN_REASON_RENAME_NEW_NAME
  # ---------------------------------------------------------------------------
  block:
    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()

    let rOrig = makeMockUsnRecord("old_name.txt", 5'u64, 300'u64, false, USN_REASON_FILE_CREATE, 200'i64)
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rOrig[0])))
    doAssert idx.len == 1

    # RENAME_OLD_NAME should be ignored (preserves existing node)
    let rOld = makeMockUsnRecord("old_name.txt", 5'u64, 300'u64, false, USN_REASON_RENAME_OLD_NAME, 201'i64)
    doAssert not idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rOld[0])))
    doAssert idx.len == 1

    # RENAME_NEW_NAME updates node name in-place
    let rNew = makeMockUsnRecord("new_name.txt", 5'u64, 300'u64, false, USN_REASON_RENAME_NEW_NAME, 202'i64)
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rNew[0])))
    doAssert idx.len == 1

    let slabId = idx.nodes.get(300'u64).get
    let nameStr = idx.names.resolveString(idx.slab[slabId].name)
    doAssert nameStr == "new_name.txt", "Expected 'new_name.txt', got: " & nameStr

    idx.deinit()
    echo "[OK] 02: File rename handling (RENAME_OLD_NAME ignored, RENAME_NEW_NAME applied)"

  # ---------------------------------------------------------------------------
  # Test 3: File Deletion via USN_REASON_FILE_DELETE
  # ---------------------------------------------------------------------------
  block:
    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()

    let r1 = makeMockUsnRecord("keep.txt", 5'u64, 401'u64, false, USN_REASON_FILE_CREATE, 300'i64)
    let r2 = makeMockUsnRecord("delete_me.txt", 5'u64, 402'u64, false, USN_REASON_FILE_CREATE, 301'i64)
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr r1[0])))
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr r2[0])))
    doAssert idx.len == 2
    doAssert idx.nodes.contains(402'u64)

    # Delete record removes node
    let rDel = makeMockUsnRecord("delete_me.txt", 5'u64, 402'u64, false, USN_REASON_FILE_DELETE, 302'i64)
    doAssert idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rDel[0])))
    doAssert idx.len == 1
    doAssert not idx.nodes.contains(402'u64)
    doAssert idx.nodes.contains(401'u64)

    # Deleting non-existent node returns false safely
    let rDelNonExistent = makeMockUsnRecord("ghost.txt", 5'u64, 9999'u64, false, USN_REASON_FILE_DELETE, 303'i64)
    doAssert not idx.applyUsnRecord(UsnRecordView(raw: cast[ptr byte](unsafeAddr rDelNonExistent[0])))

    idx.deinit()
    echo "[OK] 03: File deletion handling and non-existent delete safety"

  # ---------------------------------------------------------------------------
  # Test 4: Batch Buffer Stream Parsing via applyUsnBuffer
  # ---------------------------------------------------------------------------
  block:
    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()

    var records: seq[seq[byte]] = @[]
    records.add(makeMockUsnRecord("fileA.txt", 5'u64, 501'u64, false, USN_REASON_FILE_CREATE, 400'i64))
    records.add(makeMockUsnRecord("fileB.txt", 5'u64, 502'u64, false, USN_REASON_FILE_CREATE, 401'i64))
    records.add(makeMockUsnRecord("fileA_renamed.txt", 5'u64, 501'u64, false, USN_REASON_RENAME_NEW_NAME, 402'i64))
    records.add(makeMockUsnRecord("fileB.txt", 5'u64, 502'u64, false, USN_REASON_FILE_DELETE, 403'i64))

    let rawBuf = makeMockUsnBuffer(5000'i64, records)
    var continuationUsn: USN = 0'i64

    let appliedCount = applyUsnBuffer(idx, rawBuf, rawBuf.len, continuationUsn)
    doAssert appliedCount == 4
    doAssert continuationUsn == 5000'i64
    doAssert idx.len == 1
    doAssert idx.nodes.contains(501'u64)
    doAssert not idx.nodes.contains(502'u64)

    let slabId = idx.nodes.get(501'u64).get
    let nameStr = idx.names.resolveString(idx.slab[slabId].name)
    doAssert nameStr == "fileA_renamed.txt"

    idx.deinit()
    echo "[OK] 04: Batch USN buffer parsing, continuation USN update, and mixed operations"

  # ---------------------------------------------------------------------------
  # Test 5: Background Monitor Thread Lifecycle & Rapid Graceful Shutdown
  # ---------------------------------------------------------------------------
  block:
    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()
    var lock = initSysLock()

    var records: seq[seq[byte]] = @[]
    for i in 0 ..< 50:
      records.add(makeMockUsnRecord("worker_file_" & $i & ".dat", 5'u64, uint64(6000 + i), false, USN_REASON_FILE_CREATE, int64(1000 + i)))
    let rawBuf = makeMockUsnBuffer(2000'i64, records)

    var mon = startMockUsnMonitor(addr idx, rawBuf, 0'i64, addr lock, pollIntervalMs = 10)
    doAssert mon.isRunning

    # Allow thread to process records with deadline
    let deadline = getMonoTime() + initDuration(milliseconds = 2000)
    while mon.recordsProcessed < 50 and getMonoTime() < deadline:
      os.sleep(10)

    doAssert mon.recordsProcessed >= 50, "Expected at least 50 records processed, got: " & $mon.recordsProcessed
    doAssert idx.len >= 50

    # Measure shutdown latency
    let t0 = getMonoTime()
    mon.stop()
    let elapsedMs = (getMonoTime() - t0).inMilliseconds

    doAssert not mon.isRunning
    doAssert elapsedMs < 500, "Thread shutdown must be prompt (<500ms), took: " & $elapsedMs & "ms"

    # Verify idempotency of stop
    mon.stop()
    mon.stop()

    idx.deinit()
    echo "[OK] 05: Background monitor thread lifecycle, atomic processing, and rapid shutdown (", elapsedMs, "ms)"

  # Regression test: returning UsnMonitor inside Result[UsnMonitor, IOError] and moving it out
  block:
    proc startMockMonitorResult(
      idx: ptr Indexer,
      buf: seq[byte],
      lock: ptr SysLock
    ): Result[UsnMonitor, IOError] =
      var mon = startMockUsnMonitor(idx, buf, 0'i64, lock, pollIntervalMs = 10)
      ok[UsnMonitor, IOError](mon)

    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()
    var lock = initSysLock()
    let r = makeMockUsnRecord("moved_result.txt", 5'u64, 7001'u64, false, USN_REASON_FILE_CREATE, 1500'i64)
    let rawBuf = makeMockUsnBuffer(1600'i64, @[r])

    var monRes = startMockMonitorResult(addr idx, rawBuf, addr lock)
    doAssert monRes.isOk
    var m = move(monRes.val)
    doAssert m.isRunning

    let deadline = getMonoTime() + initDuration(milliseconds = 2000)
    while m.recordsProcessed < 1 and getMonoTime() < deadline:
      os.sleep(10)

    doAssert m.recordsProcessed >= 1, "Moved Result UsnMonitor failed to process records"
    m.stop()
    doAssert not m.isRunning
    idx.deinit()
    echo "[OK] 05b: Result[UsnMonitor, IOError] move safety regression verified"

  # ---------------------------------------------------------------------------
  # Test 6: Non-Admin Privilege Detection & Descriptive Error Reporting
  # ---------------------------------------------------------------------------
  block:
    var tracker = initTrackingAllocator()
    var idx = newIndexer(tracker.allocator(), 4096).unwrap()

    # In non-elevated user mode, openVolume and startUsnMonitor on 'C' fail with access denied
    var monRes = startUsnMonitor(addr idx, 'C')
    if monRes.isErr:
      let errStr = monRes.error.msg
      echo "     [Detected non-admin environment]: ", errStr
      doAssert "Administrative privileges required to open volume for USN Journal reading" in errStr or
               "Access is denied" in errStr or
               "Win32 error 5" in errStr
      echo "[OK] 06: Non-admin error handling returned clean descriptive message"
    else:
      var m = move(monRes.val)
      m.stop()
      echo "[OK] 06: Admin privileges detected; monitor initialized and stopped successfully"

    # Non-existent drive 'Z' must also fail cleanly
    var zRes = startUsnMonitor(addr idx, 'Z')
    doAssert zRes.isErr, "Expected opening non-existent drive 'Z' to fail"

    idx.deinit()

  # ---------------------------------------------------------------------------
  # Test 7: Zero-Leak Verification under testWithLeakCheck
  # ---------------------------------------------------------------------------
  testWithLeakCheck("USN Sync & Monitor Zero-Leak Verification"):
    var idx = newIndexer(testAlloc, 4096).unwrap()
    var lock = initSysLock()

    # 1. 200 Creates
    var creates: seq[seq[byte]] = @[]
    for i in 0 ..< 200:
      creates.add(makeMockUsnRecord("leak_file_" & $i & ".bin", 5'u64, uint64(8000 + i), false, USN_REASON_FILE_CREATE, int64(3000 + i)))
    let createBuf = makeMockUsnBuffer(3500'i64, creates)
    var curUsn: USN = 0'i64
    discard applyUsnBuffer(idx, createBuf, createBuf.len, curUsn)
    doAssert idx.len == 200

    # 2. 100 Renames
    var renames: seq[seq[byte]] = @[]
    for i in 0 ..< 100:
      renames.add(makeMockUsnRecord("renamed_file_" & $i & ".bin", 5'u64, uint64(8000 + i), false, USN_REASON_RENAME_NEW_NAME, int64(3500 + i)))
    let renameBuf = makeMockUsnBuffer(3600'i64, renames)
    discard applyUsnBuffer(idx, renameBuf, renameBuf.len, curUsn)
    doAssert idx.len == 200

    # 3. 150 Deletes
    var deletes: seq[seq[byte]] = @[]
    for i in 0 ..< 150:
      deletes.add(makeMockUsnRecord("renamed_file_" & $i & ".bin", 5'u64, uint64(8000 + i), false, USN_REASON_FILE_DELETE, int64(3700 + i)))
    let deleteBuf = makeMockUsnBuffer(3800'i64, deletes)
    discard applyUsnBuffer(idx, deleteBuf, deleteBuf.len, curUsn)
    doAssert idx.len == 50

    # 4. Background thread start and RAII destruction
    block:
      var mon = startMockUsnMonitor(addr idx, [], 0'i64, addr lock, pollIntervalMs = 10)
      doAssert mon.isRunning
      mon.stop()

    idx.deinit()

  echo "[OK] 07: testWithLeakCheck on 450 mixed USN mutations and thread monitor verified 0 leaks"

  echo "=== ALL USN JOURNAL SYNC & MONITOR TESTS PASSED ==="

when isMainModule:
  runUsnSyncTests()
