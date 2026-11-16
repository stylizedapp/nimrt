import std/os
import corex
import corex/platform/windows/win32_fs
import ../apps/everything/src/indexer

proc makeMockUsnRecord(name: string, parentFrn: uint64, frn: uint64, isDir: bool): seq[byte] =
  let nameUtf16Len = name.len * 2
  let rawLen = 60 + nameUtf16Len
  let alignedLen = ((rawLen + 7) div 8) * 8
  result = newSeq[byte](alignedLen)

  # offset 0: recordLength (uint32)
  cast[ptr uint32](addr result[0])[] = uint32(alignedLen)
  # offset 4: majorVersion (uint16)
  cast[ptr uint16](addr result[4])[] = 2'u16
  # offset 6: minorVersion (uint16)
  cast[ptr uint16](addr result[6])[] = 0'u16
  # offset 8: fileReferenceNumber (uint64)
  cast[ptr uint64](addr result[8])[] = frn
  # offset 16: parentFileReferenceNumber (uint64)
  cast[ptr uint64](addr result[16])[] = parentFrn
  # offset 24: usn (USN / int64)
  cast[ptr int64](addr result[24])[] = 100'i64
  # offset 32: timeStamp (int64)
  cast[ptr int64](addr result[32])[] = 0'i64
  # offset 40: reason (uint32)
  cast[ptr uint32](addr result[40])[] = 0'u32
  # offset 44: sourceInfo (uint32)
  cast[ptr uint32](addr result[44])[] = 0'u32
  # offset 48: securityId (uint32)
  cast[ptr uint32](addr result[48])[] = 0'u32
  # offset 52: fileAttributes (uint32)
  let attrs: uint32 = if isDir: win32_fs.FILE_ATTRIBUTE_DIRECTORY else: 0x00000080'u32
  cast[ptr uint32](addr result[52])[] = attrs
  # offset 56: fileNameLength (uint16)
  cast[ptr uint16](addr result[56])[] = uint16(nameUtf16Len)
  # offset 58: fileNameOffset (uint16)
  cast[ptr uint16](addr result[58])[] = 60'u16

  # UTF-16 bytes of name at offset 60
  for i in 0 ..< name.len:
    cast[ptr uint16](addr result[60 + i * 2])[] = uint16(name[i])

proc makeMftEnumBuffer(records: seq[seq[byte]]): seq[byte] =
  result = newSeq[byte](8) # 8-byte NextUsn header for MFT enum buffer
  for r in records:
    result.add(r)

proc runIndexerTests() =
  echo "=== RUNNING EVERYTHING INDEXER UNIT TESTS ==="

  # Test 1: Single mock record insertion
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let recBytes = makeMockUsnRecord("hello.txt", 5'u64, 1001'u64, false)
    let view = UsnRecordView(raw: cast[ptr byte](unsafeAddr recBytes[0]))
    doAssert idx.insertFromUsn(view).isOk
    doAssert idx.slab.len == 1
    doAssert idx.nodes.len == 1
    doAssert idx.nodes.contains(1001'u64)
    let slabId = idx.nodes.get(1001'u64).get()
    doAssert idx.slab[slabId].frn == 1001'u64
    doAssert not idx.slab[slabId].isDir
    doAssert idx.names.resolveString(idx.slab[slabId].name) == "hello.txt"

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: Single mock record insertFromUsn"

  # Test 2: Bulk indexing 100 records from buffer
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    var records: seq[seq[byte]] = @[]
    for i in 0 ..< 100:
      records.add(makeMockUsnRecord("file_" & $i & ".dat", 5'u64, uint64(1000 + i), false))
    let buf = makeMftEnumBuffer(records)

    let count = idx.bulkIndexFromBuffer(buf).unwrap()
    doAssert count == 100
    doAssert idx.slab.len == 100
    doAssert idx.nodes.len == 100

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Bulk index 100 records from MFT buffer"

  # Test 3: Duplicate FRN updates existing node (rename handling)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let r1 = makeMockUsnRecord("original.txt", 5'u64, 5000'u64, false)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr r1[0])))
    doAssert idx.slab.len == 1

    # Second record with same FRN but renamed
    let r2 = makeMockUsnRecord("renamed.txt", 5'u64, 5000'u64, false)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr r2[0])))
    doAssert idx.slab.len == 1 # Still 1 node!
    let slabId = idx.nodes.get(5000'u64).get()
    doAssert idx.names.resolveString(idx.slab[slabId].name) == "renamed.txt"

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: Duplicate FRN update (rename) in-place"

  # Test 4: String deduplication across multiple records
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    var records: seq[seq[byte]] = @[]
    for i in 0 ..< 100:
      records.add(makeMockUsnRecord("file.txt", 5'u64, uint64(2000 + i), false))
    let buf = makeMftEnumBuffer(records)
    discard idx.bulkIndexFromBuffer(buf)

    doAssert idx.slab.len == 100
    # String interner has exactly 1 interned name!
    doAssert idx.names.len == 1

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: StringInterner deduplicates 100 identical filenames into 1 entry"

  # Test 5: Hierarchical path resolution (Documents -> report.pdf)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    const docFrn = 100'u64
    const reportFrn = 200'u64

    # Documents directory (parent = 5, NTFS root)
    let docRec = makeMockUsnRecord("Documents", 5'u64, docFrn, true)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr docRec[0])))

    # report.pdf (parent = Documents)
    let reportRec = makeMockUsnRecord("report.pdf", docFrn, reportFrn, false)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr reportRec[0])))

    let reportSlabId = idx.nodes.get(reportFrn).get()
    let path = idx.resolvePath(reportSlabId).unwrap()
    doAssert path == "Documents\\report.pdf"

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: resolvePath(report) == 'Documents\\report.pdf'"

  # Test 6: Deep nested path resolution (Root -> A -> B -> C -> target.txt)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let rA = makeMockUsnRecord("A", 5'u64, 10'u64, true)
    let rB = makeMockUsnRecord("B", 10'u64, 20'u64, true)
    let rC = makeMockUsnRecord("C", 20'u64, 30'u64, true)
    let rT = makeMockUsnRecord("target.txt", 30'u64, 40'u64, false)

    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rA[0])))
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rB[0])))
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rC[0])))
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rT[0])))

    let targetId = idx.nodes.get(40'u64).get()
    let path = idx.resolvePath(targetId).unwrap()
    doAssert path == "A\\B\\C\\target.txt"

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Deep nested 4-level path resolution"

  # Test 7: Direct child of NTFS root (parent = 5)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let rRoot = makeMockUsnRecord("rootfile.sys", 5'u64, 888'u64, false)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rRoot[0])))
    let rootFileId = idx.nodes.get(888'u64).get()
    let path = idx.resolvePath(rootFileId).unwrap()
    doAssert path == "rootfile.sys"

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Direct root file path resolution"

  # Test 8: Directory attribute flag verification
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let rFolder = makeMockUsnRecord("MyFolder", 5'u64, 11'u64, true)
    let rFile = makeMockUsnRecord("MyFile", 5'u64, 22'u64, false)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rFolder[0])))
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rFile[0])))

    let folderId = idx.nodes.get(11'u64).get()
    let fileId = idx.nodes.get(22'u64).get()
    doAssert idx.slab[folderId].isDir == true
    doAssert idx.slab[fileId].isDir == false

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Directory and file attribute flags verified"

  # Test 9: Move / Sink semantics on Indexer
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx1 = newIndexer(alloc, 4096).unwrap()
    let rMoved = makeMockUsnRecord("moved.log", 5'u64, 999'u64, false)
    discard idx1.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr rMoved[0])))

    var idx2 = move(idx1)
    doAssert idx2.len == 1
    let id = idx2.nodes.get(999'u64).get()
    doAssert idx2.names.resolveString(idx2.slab[id].name) == "moved.log"

    idx1.deinit()
    idx2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 09: Sink / Move semantics on Indexer"

  # Test 10: testWithLeakCheck on 1000 bulk records
  testWithLeakCheck("Indexer 1000 records bulk index"):
    var idx = newIndexer(testAlloc, 4096).unwrap()
    var records: seq[seq[byte]] = @[]
    for i in 0 ..< 1000:
      records.add(makeMockUsnRecord("bench_file_" & $i & ".tmp", 5'u64, uint64(5000 + i), false))
    let buf = makeMftEnumBuffer(records)
    discard idx.bulkIndexFromBuffer(buf)
    doAssert idx.len == 1000
    idx.deinit()
  echo "[OK] 10: testWithLeakCheck on 1000 records verified 0 leaks"

  # Test 11: Node removal by FRN and SlabId
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let id1 = idx.insertOrUpdate(101'u64, 5'u64, "del_me.txt", false, 100).unwrap()
    let id2 = idx.insertOrUpdate(102'u64, 5'u64, "keep_me.txt", false, 200).unwrap()
    doAssert idx.len == 2

    doAssert idx.removeNode(101'u64) == true
    doAssert idx.removeNode(101'u64) == false
    doAssert idx.len == 1
    doAssert not idx.nodes.contains(101'u64)
    doAssert idx.nodes.contains(102'u64)

    doAssert idx.removeNode(id2) == true
    doAssert idx.removeNode(id2) == false
    doAssert idx.len == 0

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 11: removeNode by FRN and SlabId"

  # Test 12: Node update and insertOrUpdate
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    discard idx.insertOrUpdate(300'u64, 5'u64, "old_name.log", false, 50).unwrap()
    doAssert idx.len == 1
    let id = idx.nodes.get(300'u64).get()
    doAssert idx.names.resolveString(idx.slab[id].name) == "old_name.log"

    let updated = idx.updateNode(300'u64, "new_name.log", 5'u64, false, 100).unwrap()
    doAssert updated == true
    doAssert idx.len == 1
    doAssert idx.names.resolveString(idx.slab[id].name) == "new_name.log"
    doAssert idx.slab[id].size == 100

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 12: updateNode and insertOrUpdate"

  # Test 13: Binary serialization and deserialization save/load
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx1 = newIndexer(alloc, 4096, 'D').unwrap()
    idx1.lastUsn = 987654321'i64

    discard idx1.insertOrUpdate(10'u64, 5'u64, "folder", true, 0).unwrap()
    discard idx1.insertOrUpdate(20'u64, 10'u64, "nested.pdf", false, 123456).unwrap()

    let testIdxFile = getTempDir() / "test_indexer_roundtrip.idx"
    let saveRes = idx1.saveToFile(testIdxFile)
    doAssert saveRes.isOk

    var idx2 = loadFromFile(alloc, testIdxFile).unwrap()
    doAssert idx2.len == 2
    doAssert idx2.driveLetter == 'D'
    doAssert idx2.lastUsn == 987654321'i64
    doAssert idx2.nodes.contains(10'u64)
    doAssert idx2.nodes.contains(20'u64)

    let nId = idx2.nodes.get(20'u64).get()
    let path = idx2.resolvePath(nId).unwrap()
    doAssert path == "folder\\nested.pdf"
    doAssert idx2.slab[nId].size == 123456

    idx1.deinit()
    idx2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 13: Binary saveToFile & loadFromFile roundtrip"

  # Test 14: USN_REASON_FILE_DELETE auto-removal
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    let recBytes = makeMockUsnRecord("temp.dat", 5'u64, 777'u64, false)
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr recBytes[0])))
    doAssert idx.len == 1

    var delRecBytes = recBytes
    cast[ptr uint32](addr delRecBytes[40])[] = 0x00000200'u32 # USN_REASON_FILE_DELETE
    discard idx.insertFromUsn(UsnRecordView(raw: cast[ptr byte](unsafeAddr delRecBytes[0])))
    doAssert idx.len == 0

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 14: USN_REASON_FILE_DELETE auto-removal"

  # Test 15: testWithLeakCheck on mutations and save/load
  testWithLeakCheck("Indexer mutations and serialization 0 leaks"):
    var idx = newIndexer(testAlloc, 4096).unwrap()
    for i in 0 ..< 500:
      discard idx.insertOrUpdate(uint64(1000 + i), 5'u64, "item_" & $i & ".ext", false, int64(i * 10)).unwrap()
    doAssert idx.len == 500
    for i in 0 ..< 200:
      discard idx.removeNode(uint64(1000 + i))
    doAssert idx.len == 300

    let p = getTempDir() / "test_leak_check.idx"
    doAssert idx.saveToFile(p).isOk

    var loaded = loadFromFile(testAlloc, p).unwrap()
    doAssert loaded.len == 300
    loaded.deinit()
    idx.deinit()
  echo "[OK] 15: testWithLeakCheck on mutations & save/load verified 0 leaks"

  echo "=== ALL 15 EVERYTHING INDEXER TESTS PASSED ==="

when isMainModule:
  runIndexerTests()
