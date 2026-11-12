## tests/test_cli.nim — Comprehensive Unit & Integration Tests for Everything CLI
##
## Tests:
## 1. Drive parsing & argument validation
## 2. CLI help & usage execution
## 3. Missing argument & invalid command error handling (exit code 1)
## 4. Non-admin privilege detection & graceful exit code 1 handling
## 5. Mock volume indexing & index file persistence
## 6. High-speed search execution (prefix, suffix, substring) with path resolution
## 7. CLI dispatcher end-to-end with custom index paths
## 8. Memory leak verification under ARC/ORC via testWithLeakCheck

import std/[os, times, strutils]
import corex
import corex/[allocators, result, testing]
import corex/platform/windows/win32_fs
import everything/src/[indexer, search, cli]

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
  result = newSeq[byte](8) # 8-byte NextUsn header
  cast[ptr int64](addr result[0])[] = 1000'i64
  for r in records:
    result.add(r)

proc runCliTests() =
  echo "=== RUNNING EVERYTHING CLI TESTS ==="

  let testDir = getTempDir() / "everything_cli_test"
  createDir(testDir)
  let testIdxPath = testDir / "test_everything.idx"

  # Test 1: Drive argument parsing
  block:
    doAssert parseDrive("C") == 'C'
    doAssert parseDrive("c") == 'C'
    doAssert parseDrive("C:") == 'C'
    doAssert parseDrive("c:\\") == 'C'
    doAssert parseDrive("D:") == 'D'
    doAssert parseDrive("\\\\.\\E:") == 'E'
    doAssert parseDrive("") == 'C'
    echo "[OK] 01: Drive argument parsing verified"

  # Test 2: Help & Usage
  block:
    doAssert runCli(@[]) == 0
    doAssert runCli(@["--help"]) == 0
    doAssert runCli(@["-h"]) == 0
    doAssert runCli(@["help"]) == 0
    echo "[OK] 02: Help and usage display return code 0"

  # Test 3: Missing arguments & invalid commands
  block:
    doAssert runCli(@["index"]) == 1
    doAssert runCli(@["search"]) == 1
    doAssert runCli(@["invalid_command_xyz"]) == 1
    echo "[OK] 03: Missing arguments and invalid commands return code 1"

  # Test 4: Non-admin error handling (exit code 1)
  block:
    # On Windows without elevated privileges, opening volume C: fails with error 5.
    # The CLI must catch this, print the required guidance, and return code 1.
    let code = runIndex("C", outPath = testIdxPath, showProgress = false)
    doAssert code == 1, "Expected runIndex to return exit code 1 in non-elevated environment"
    let cliCode = runCli(@["index", "C", "--out=" & testIdxPath])
    doAssert cliCode == 1, "Expected runCli index to return code 1"
    echo "[OK] 04: Non-admin volume access caught gracefully with exit code 1"

  # Test 5: Mock volume indexing and index persistence
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096, driveLetter = 'C', initialCap = 256).unwrap()

    var records: seq[seq[byte]] = @[]
    records.add(makeMockUsnRecord("Users", 5'u64, 10'u64, true))
    records.add(makeMockUsnRecord("sanal", 10'u64, 20'u64, true))
    records.add(makeMockUsnRecord("report_annual.pdf", 20'u64, 101'u64, false))
    records.add(makeMockUsnRecord("financial_report.docx", 20'u64, 102'u64, false))
    records.add(makeMockUsnRecord("Windows", 5'u64, 30'u64, true))
    records.add(makeMockUsnRecord("System32", 30'u64, 40'u64, true))
    records.add(makeMockUsnRecord("notepad.exe", 40'u64, 201'u64, false))
    records.add(makeMockUsnRecord("sample.pdf", 5'u64, 301'u64, false))

    let mftBuf = makeMftEnumBuffer(records)
    let parsedCount = idx.bulkIndexFromBuffer(mftBuf).unwrap()
    doAssert parsedCount == 8
    doAssert idx.len == 8

    let saveRes = idx.saveToFile(testIdxPath)
    doAssert saveRes.isOk, "Failed to save mock index to " & testIdxPath
    doAssert fileExists(testIdxPath)
    doAssert getFileSize(testIdxPath) > 0

    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Mock volume indexing and binary persistence verified"

  # Test 6: Search execution & path resolution
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()

    let loadRes = loadFromFile(alloc, testIdxPath)
    doAssert loadRes.isOk, "Failed to load index from " & testIdxPath
    var idx = loadRes.get()

    var siRes = initSearchIndex(addr idx, alloc)
    doAssert siRes.isOk
    var si = siRes.get()

    # Suffix search: "*.pdf"
    let pdfPaths = searchAndResolve(idx, si, "*.pdf")
    doAssert pdfPaths.len == 2, "Expected 2 PDF matches, got: " & $pdfPaths
    doAssert pdfPaths.contains("C:\\Users\\sanal\\report_annual.pdf")
    doAssert pdfPaths.contains("C:\\sample.pdf")

    # Prefix search: "report*"
    let pfxPaths = searchAndResolve(idx, si, "report*")
    doAssert pfxPaths.len == 1, "Expected 1 prefix match, got: " & $pfxPaths
    doAssert pfxPaths[0] == "C:\\Users\\sanal\\report_annual.pdf"

    # Substring search: "*report*"
    let subPaths = searchAndResolve(idx, si, "*report*")
    doAssert subPaths.len == 2, "Expected 2 substring matches, got: " & $subPaths
    doAssert subPaths.contains("C:\\Users\\sanal\\report_annual.pdf")
    doAssert subPaths.contains("C:\\Users\\sanal\\financial_report.docx")

    # Exact search: "notepad.exe"
    let exePaths = searchAndResolve(idx, si, "notepad.exe")
    doAssert exePaths.len == 1
    doAssert exePaths[0] == "C:\\Windows\\System32\\notepad.exe"

    si.deinit()
    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Search execution and hierarchical path resolution verified"

  # Test 7: CLI dispatcher with search and sync commands
  block:
    # Search via runCli
    let sCode = runCli(@["search", "*.pdf", "--index=" & testIdxPath])
    doAssert sCode == 0, "Expected search command to succeed with code 0"

    # Sync via runCli (non-admin volume access will return 1 cleanly)
    let syncCode = runCli(@["sync", "--index=" & testIdxPath])
    doAssert syncCode == 1, "Expected sync to fail gracefully with code 1 under non-admin"

    echo "[OK] 07: CLI dispatcher end-to-end execution verified"

  # Test 8: High-scale search speed (<100ms on 10,000 files)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096, driveLetter = 'C', initialCap = 10000).unwrap()

    var records: seq[seq[byte]] = @[]
    for i in 0 ..< 10000:
      let name = "document_" & $i & (if i mod 3 == 0: ".pdf" elif i mod 3 == 1: ".docx" else: ".txt")
      records.add(makeMockUsnRecord(name, 5'u64, uint64(1000 + i), false))
    let buf = makeMftEnumBuffer(records)
    discard idx.bulkIndexFromBuffer(buf)
    doAssert idx.len == 10000

    var siRes = initSearchIndex(addr idx, alloc)
    doAssert siRes.isOk
    var si = siRes.get()

    let t0 = cpuTime()
    let results = si.search("*.pdf", limit = 500)
    let elapsedMs = (cpuTime() - t0) * 1000.0
    doAssert results.len == 500
    doAssert elapsedMs < 100.0, "Search took too long: " & $elapsedMs & "ms"

    si.deinit()
    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Search speed verified (" & $elapsedMs & "ms for 10k items)"

  # Test 9: Memory safety verification via testWithLeakCheck
  testWithLeakCheck("CLI Memory Lifecycle & Search Leak Check"):
    var idx = newIndexer(testAlloc, 4096, driveLetter = 'C', initialCap = 512).unwrap()
    var recs: seq[seq[byte]] = @[]
    for i in 0 ..< 100:
      recs.add(makeMockUsnRecord("test_file_" & $i & ".log", 5'u64, uint64(5000 + i), false))
    let buf = makeMftEnumBuffer(recs)
    discard idx.bulkIndexFromBuffer(buf)
    doAssert idx.len == 100

    var si = initSearchIndex(addr idx, testAlloc).unwrap()
    let res = searchAndResolve(idx, si, "*.log", limit = 50)
    doAssert res.len == 50

    si.deinit()
    idx.deinit()
  echo "[OK] 09: testWithLeakCheck verified 0 leaks in CLI search pipeline"

  # Clean up temp test directory
  try:
    removeDir(testDir)
  except CatchableError:
    discard

  echo "=== ALL EVERYTHING CLI TESTS PASSED ==="

when isMainModule:
  runCliTests()
