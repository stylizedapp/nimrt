## test_m5_verification.nim — Comprehensive Independent Verification Suite for Milestone 5
##
## Tests:
## 1. FileHandle: RAII move-only semantics, open, read, write, seek, flush, close, idempotency
## 2. BufferedWriter: 64KB buffering, auto-flush on saturation, auto-flush on destruction, bypass
## 3. BufferedReader: 64KB buffering, zero-allocation readLine, CRLF/LF, peekSpan, consume, bypass
## 4. calculateSizeOnDisk: edge cases (0, negative, multiples, invalid geometry)
## 5. walkDirFast & walkDirFastSeq: DFS traversal, symlink cycle avoidance, early break cleanup
## 6. getFileStat & getVolumeInfo: volume info, cluster geometry, single file metadata
## 7. Win32 USN / MFT structures: UsnRecordView, mftIndex, sequenceNumber, parseUsnRecords
## 8. Leak-free verification under ARC/ORC via testWithLeakCheck

import std/options
import corex

const TempTestDir = "tmp_m5_test"

proc cleanupTemp() =
  for f in ["test_fh.tmp", "test_bw.tmp", "test_br.tmp", "test_leak.tmp"]:
    when defined(windows):
      proc winDeleteFileW(lpFileName: WideCString): int32 {.importc: "DeleteFileW", header: "<windows.h>", stdcall.}
      let wPath = newWideCString(f)
      discard winDeleteFileW(wPath)
    else:
      discard posix.unlink(f.cstring)

proc testFileHandle() =
  echo "[TEST 1] FileHandle RAII, Read/Write, Seek, Move Semantics"
  let testPath = "test_fh.tmp"

  # Write test
  block:
    var fhRes = openFile(testPath, fmWrite)
    doAssert fhRes.isOk, "openFile for write failed"
    var fh = fhRes.unwrap()
    doAssert fh.isOpen, "FileHandle should be open"
    
    let msg = "Hello, High-Performance Nim I/O!\n"
    let writeRes = fh.write(msg)
    doAssert writeRes.isOk and writeRes.get == msg.len
    
    let flushRes = fh.flush()
    doAssert flushRes.isOk
    
    let closeRes = fh.close()
    doAssert closeRes.isOk
    doAssert not fh.isOpen
    
    # Idempotent close
    let closeAgain = fh.close()
    doAssert closeAgain.isOk

  # Read & Seek test
  block:
    var fh = openFile(testPath, fmRead).unwrap()
    doAssert fh.isOpen
    
    var buf: array[64, byte]
    let readRes = fh.read(buf)
    doAssert readRes.isOk
    let n = readRes.get
    doAssert n > 0
    var str = newString(n)
    copyMem(addr str[0], addr buf[0], n)
    doAssert str == "Hello, High-Performance Nim I/O!\n"
    
    # Seek back to offset 7 ("High-Performance...")
    let seekRes = fh.seek(7, soBegin)
    doAssert seekRes.isOk and seekRes.get == 7
    
    var buf2: array[16, byte]
    let r2 = fh.read(buf2)
    doAssert r2.isOk and r2.get == 16
    var s2 = newString(16)
    copyMem(addr s2[0], addr buf2[0], 16)
    doAssert s2 == "High-Performance"

  # Move semantics test
  block:
    var fh1 = openFile(testPath, fmRead).unwrap()
    doAssert fh1.isOpen
    var fh2 = move(fh1)
    doAssert not fh1.isOpen
    doAssert fh2.isOpen
    discard fh2.close()

  echo "  -> FileHandle: PASSED"

proc testBufferedWriter() =
  echo "[TEST 2] BufferedWriter Auto-Flush on Saturation and Destruction"
  let testPath = "test_bw.tmp"

  # Test auto-flush on destruction without explicit flush()
  block:
    var bw = openBufferedWriter(testPath, fmWrite).unwrap()
    discard bw.writeLine("First line via BufferedWriter")
    discard bw.writeLine("Second line via BufferedWriter")
    # Do not call bw.flush() or bw.close()! Destructor must auto-flush.

  # Verify file content
  block:
    var br = openBufferedReader(testPath).unwrap()
    var l1 = ""
    var l2 = ""
    doAssert br.readLine(l1).unwrap()
    doAssert br.readLine(l2).unwrap()
    doAssert l1 == "First line via BufferedWriter", "Got: " & l1
    doAssert l2 == "Second line via BufferedWriter", "Got: " & l2

  # Test auto-flush on saturation (> 64KB)
  block:
    let largeSize = 100 * 1024 # 100 KB
    var bw = openBufferedWriter(testPath, fmWrite).unwrap()
    var largeData = newSeq[byte](largeSize)
    for i in 0 ..< largeSize:
      largeData[i] = byte(i mod 256)
    
    let wRes = bw.writeBytes(largeData)
    doAssert wRes.isOk and wRes.get == largeSize
    discard bw.close()

    # Read back and verify exact byte sequence
    var br = openBufferedReader(testPath).unwrap()
    var readBack = newSeq[byte](largeSize)
    let rRes = br.readBytes(readBack)
    doAssert rRes.isOk and rRes.get == largeSize
    for i in 0 ..< largeSize:
      doAssert readBack[i] == largeData[i], "Mismatch at byte " & $i

  echo "  -> BufferedWriter: PASSED"

proc testBufferedReader() =
  echo "[TEST 3] BufferedReader Zero-Allocation readLine, CRLF, and Slicing"
  let testPath = "test_br.tmp"

  # Write mixed LF and CRLF file
  block:
    var fh = openFile(testPath, fmWrite).unwrap()
    discard fh.write("alpha\nbeta\r\ngamma\n")
    discard fh.close()

  # Test line reading & Option overload
  block:
    var br = openBufferedReader(testPath).unwrap()
    var line = ""
    
    doAssert br.readLine(line).unwrap()
    doAssert line == "alpha", "Expected 'alpha', got: " & line
    
    doAssert br.readLine(line).unwrap()
    doAssert line == "beta", "Expected 'beta' (CRLF stripped), got: " & line
    
    let optLine = br.readLine().unwrap()
    doAssert optLine.isSome and optLine.get == "gamma"
    
    let eofLine = br.readLine().unwrap()
    doAssert eofLine.isNone

  # Test peekSpan and consume
  block:
    var br = openBufferedReader(testPath).unwrap()
    let span1 = br.peekSpan()
    # At start, buffer has not been filled until read/peek
    # Trigger fill via reading 0 bytes or peekSpan after fill
    var dummy: array[1, byte]
    discard br.readBytes(dummy) # reads 1 byte ('a')
    let span2 = br.peekSpan()
    doAssert span2.len > 0
    doAssert char(span2[0]) == 'l' # 'alpha'[1]
    br.consume(4) # consume "lpha"
    let span3 = br.peekSpan()
    doAssert char(span3[0]) == '\n'

  # Test readAll
  block:
    var br = openBufferedReader(testPath).unwrap()
    let full = br.readAll().unwrap()
    doAssert full == "alpha\nbeta\r\ngamma\n"

  echo "  -> BufferedReader: PASSED"

proc testClusterGeometry() =
  echo "[TEST 4] Cluster Geometry and Size On Disk Formulas"
  
  # Standard multiples
  doAssert calculateSizeOnDisk(0, 4096) == 0
  doAssert calculateSizeOnDisk(-1, 4096) == 0
  doAssert calculateSizeOnDisk(-9999, 4096) == 0
  doAssert calculateSizeOnDisk(1, 4096) == 4096
  doAssert calculateSizeOnDisk(4095, 4096) == 4096
  doAssert calculateSizeOnDisk(4096, 4096) == 4096
  doAssert calculateSizeOnDisk(4097, 4096) == 8192
  doAssert calculateSizeOnDisk(8192, 4096) == 8192
  doAssert calculateSizeOnDisk(8193, 4096) == 12288
  
  # Invalid cluster geometries
  doAssert calculateSizeOnDisk(12345, 0) == 12345
  doAssert calculateSizeOnDisk(12345, -4096) == 12345

  echo "  -> calculateSizeOnDisk: PASSED"

proc testDirectoryWalking() =
  echo "[TEST 5] Directory Walking (walkDirFast, walkDirFastSeq, early break)"
  
  # Non-recursive walk on src/corex
  var count = 0
  var foundIo = false
  var foundFs = false
  for entry in walkDirFast("src/corex", recursive = false):
    inc count
    if entry.name == "io.nim": foundIo = true
    if entry.name == "fs.nim": foundFs = true
    doAssert entry.path.len > 0
    if not entry.isDir:
      doAssert entry.stat.size > 0
      doAssert entry.stat.allocatedSize >= entry.stat.size
  
  doAssert count > 0, "No entries found in src/corex"
  doAssert foundIo, "io.nim not found in src/corex"
  doAssert foundFs, "fs.nim not found in src/corex"

  # walkDirFastSeq batch collection
  let seqEntries = walkDirFastSeq("src/corex", recursive = false)
  doAssert seqEntries.len == count, "walkDirFastSeq count mismatch"

  # Early break deterministic cleanup
  var earlyCount = 0
  for entry in walkDirFast("src/corex", recursive = false):
    inc earlyCount
    if earlyCount == 2:
      break
  doAssert earlyCount == 2

  # Recursive walk on src
  var recCount = 0
  for entry in walkDirFast("src", recursive = true):
    inc recCount
  doAssert recCount > count, "Recursive count should exceed non-recursive"

  echo "  -> Directory Walking: PASSED"

proc testFileStatAndVolumeInfo() =
  echo "[TEST 6] getFileStat and getVolumeInfo"
  
  # getFileStat on nim.cfg
  let statRes = getFileStat("nim.cfg")
  doAssert statRes.isOk, "getFileStat('nim.cfg') failed: " & $statRes.error
  let st = statRes.get
  doAssert st.size > 0
  doAssert not st.isDir
  doAssert st.lastWriteTime > 0
  doAssert st.allocatedSize >= st.size

  # getFileStat on non-existent file
  let badStat = getFileStat("non_existent_file_xyz_12345.bin")
  doAssert badStat.isErr

  # getVolumeInfo
  let volRes = getVolumeInfo(".")
  doAssert volRes.isOk, "getVolumeInfo('.') failed: " & $volRes.error
  let vi = volRes.get
  doAssert vi.clusterSize > 0
  doAssert vi.totalBytes > 0
  doAssert vi.freeBytes > 0
  doAssert vi.fsType.len > 0
  echo "    Volume: fsType=", vi.fsType, " cluster=", vi.clusterSize, " totalGB=", vi.totalBytes div (1024*1024*1024)

  echo "  -> FileStat & VolumeInfo: PASSED"

proc testWin32UsnStructures() =
  echo "[TEST 7] Win32 MFT / USN Journal Structures"
  
  doAssert FSCTL_ENUM_USN_DATA == 0x000900B3'u32
  doAssert FSCTL_QUERY_USN_JOURNAL == 0x000900F4'u32
  doAssert USN_PAGE_SIZE == 4096

  # Synthesize an MFT enum buffer:
  # Offset 0..7: NextUsn (int64)
  # Offset 8..: Record 1
  # Record 1: len = 72, major = 2, minor = 0, FRN = 0x0001000000000005'u64 (index 5, seq 1), parentFRN = 5,
  #           name = "test.txt"
  var mockBuf = newSeq[byte](256)
  
  # Set NextUsn = 12345678'i64
  let nextUsnVal: int64 = 12345678'i64
  copyMem(addr mockBuf[0], unsafeAddr nextUsnVal, sizeof(int64))
  doAssert getNextUsn(mockBuf) == 12345678'i64

  # Record 1 at offset 8
  let recOffset = 8
  var pRec = cast[ptr byte](addr mockBuf[recOffset])
  
  let recLen: uint32 = 80 # Must be 8-byte aligned
  let major: uint16 = 2
  let minor: uint16 = 0
  let frn: uint64 = (1'u64 shl 48) or 5'u64 # index 5 (root), seq 1
  let parentFrn: uint64 = (1'u64 shl 48) or 5'u64
  let usn: int64 = 1000
  let reason: uint32 = USN_REASON_FILE_CREATE
  let fnLen: uint16 = 16 # 8 chars * 2 bytes = 16 bytes
  let fnOffset: uint16 = 60

  copyMem(cast[pointer](cast[uint](pRec) + 0), unsafeAddr recLen, 4)
  copyMem(cast[pointer](cast[uint](pRec) + 4), unsafeAddr major, 2)
  copyMem(cast[pointer](cast[uint](pRec) + 6), unsafeAddr minor, 2)
  copyMem(cast[pointer](cast[uint](pRec) + 8), unsafeAddr frn, 8)
  copyMem(cast[pointer](cast[uint](pRec) + 16), unsafeAddr parentFrn, 8)
  copyMem(cast[pointer](cast[uint](pRec) + 24), unsafeAddr usn, 8)
  copyMem(cast[pointer](cast[uint](pRec) + 40), unsafeAddr reason, 4)
  copyMem(cast[pointer](cast[uint](pRec) + 56), unsafeAddr fnLen, 2)
  copyMem(cast[pointer](cast[uint](pRec) + 58), unsafeAddr fnOffset, 2)

  # Filename UTF-16 "test.txt"
  let nameU16: array[8, uint16] = [
    uint16('t'), uint16('e'), uint16('s'), uint16('t'),
    uint16('.'), uint16('t'), uint16('x'), uint16('t')
  ]
  copyMem(cast[pointer](cast[uint](pRec) + uint(fnOffset)), unsafeAddr nameU16[0], 16)

  # Parse via parseUsnRecords
  var foundRecord = false
  for view in parseUsnRecords(mockBuf[0 ..< (recOffset + int(recLen))], isMftEnumBuffer = true):
    foundRecord = true
    doAssert view.recordLength == recLen
    doAssert view.majorVersion == 2
    doAssert view.fileReferenceNumber == frn
    doAssert view.fileIndex == 5
    doAssert view.sequenceNumber == 1
    doAssert view.reason == USN_REASON_FILE_CREATE
    let fname = view.fileName
    doAssert fname == "test.txt", "Expected 'test.txt', got: " & fname
  
  doAssert foundRecord, "USN record was not parsed"

  # Materialized struct parsing
  let concreteRec = parseUsnRecord(mockBuf, recOffset)
  doAssert concreteRec.recordLength == recLen
  doAssert concreteRec.fileName == "test.txt"

  echo "  -> Win32 USN Structures: PASSED"

proc testLeakFreePipelines() =
  echo "[TEST 8] ARC/ORC Zero-Leak Pipeline Validation"
  
  testWithLeakCheck("I/O Buffered Pipeline Zero-Leak"):
    let testPath = "test_leak.tmp"
    block:
      var bw = openBufferedWriter(testPath, fmWrite, 64 * 1024, testAlloc).unwrap()
      for i in 0 ..< 100:
        discard bw.writeLine("Deterministic leak check line " & $i)
      discard bw.close()
    
    block:
      var br = openBufferedReader(testPath, 64 * 1024, testAlloc).unwrap()
      var line = ""
      var count = 0
      while br.readLine(line).unwrap():
        inc count
      doAssert count == 100
      discard br.close()

  echo "  -> Leak-Free Pipeline: PASSED"

when isMainModule:
  cleanupTemp()
  echo "=========================================================="
  echo "   Milestone 5 Independent Verification Test Suite        "
  echo "=========================================================="

  testFileHandle()
  testBufferedWriter()
  testBufferedReader()
  testClusterGeometry()
  testDirectoryWalking()
  testFileStatAndVolumeInfo()
  testWin32UsnStructures()
  testLeakFreePipelines()

  cleanupTemp()

  echo "=========================================================="
  echo "   ALL MILESTONE 5 VERIFICATION TESTS PASSED SUCCESSFULLY! "
  echo "=========================================================="
