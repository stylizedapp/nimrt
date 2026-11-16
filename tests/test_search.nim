import std/strutils
import corex
import ../apps/everything/src/indexer
import ../apps/everything/src/search

proc runSearchUnitTests() =
  echo "=== RUNNING EVERYTHING SEARCH UNIT TESTS ==="

  # Test 1: Basic Prefix, Suffix, Substring matching
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    discard idx.insertOrUpdate(101'u64, 5'u64, "report_annual.pdf", false).unwrap()
    discard idx.insertOrUpdate(102'u64, 5'u64, "report_q1.xlsx", false).unwrap()
    discard idx.insertOrUpdate(103'u64, 5'u64, "my_report.docx", false).unwrap()
    discard idx.insertOrUpdate(104'u64, 5'u64, "summary.pdf", false).unwrap()
    discard idx.insertOrUpdate(105'u64, 5'u64, "photo.jpg", false).unwrap()

    var si = initSearchIndex(idx, alloc).unwrap()

    # Prefix search
    let pfx = si.searchPrefix("report")
    doAssert pfx.len == 2
    doAssert pfx[0].name.startsWith("report")
    doAssert pfx[1].name.startsWith("report")
    echo "[OK] 01: searchPrefix matched expected items"

    # Suffix search
    let sfx = si.searchSuffix("*.pdf")
    doAssert sfx.len == 2
    for r in sfx:
      doAssert r.name.endsWith(".pdf")
    echo "[OK] 02: searchSuffix matched expected items"

    # Substring search
    let sub = si.searchSubstring("*report*")
    doAssert sub.len == 3
    for r in sub:
      doAssert "report" in r.name
    echo "[OK] 03: searchSubstring matched expected items"

    si.deinit()
    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: Zero leaks in basic search tests"

  # Test 2: Ranking (Exact > Prefix > Substring > Fuzzy; shorter > longer)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var idx = newIndexer(alloc, 4096).unwrap()

    discard idx.insertOrUpdate(201'u64, 5'u64, "test", false).unwrap()             # Exact, len 4
    discard idx.insertOrUpdate(202'u64, 5'u64, "testing", false).unwrap()          # Prefix, len 7
    discard idx.insertOrUpdate(203'u64, 5'u64, "testing_long_file", false).unwrap()# Prefix, len 17
    discard idx.insertOrUpdate(204'u64, 5'u64, "great_test_file", false).unwrap()  # Substring
    discard idx.insertOrUpdate(205'u64, 5'u64, "tempest", false).unwrap()          # Fuzzy (t..e..s..t)

    var si = initSearchIndex(idx, alloc).unwrap()
    let results = si.search("test")

    doAssert results.len == 5
    doAssert results[0].name == "test"               # Exact
    doAssert results[1].name == "testing"            # Prefix, shorter
    doAssert results[2].name == "testing_long_file"   # Prefix, longer
    doAssert results[3].name == "great_test_file"     # Substring
    doAssert results[4].name == "tempest"             # Fuzzy

    si.deinit()
    idx.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Fast ranking exact > prefix > substring > fuzzy; shorter > longer"

  # Test 3: testWithLeakCheck
  testWithLeakCheck("SearchIndex testWithLeakCheck"):
    var idx = newIndexer(testAlloc, 4096).unwrap()
    for i in 0 ..< 200:
      let name = if i mod 3 == 0: "doc_" & $i & ".pdf"
                 elif i mod 3 == 1: "image_" & $i & ".png"
                 else: "archive_" & $i & ".zip"
      discard idx.insertOrUpdate(uint64(5000 + i), 5'u64, name, false).unwrap()

    var si = initSearchIndex(idx, testAlloc).unwrap()
    discard si.search("doc*")
    discard si.search("*.pdf")
    discard si.search("*image*")
    discard si.search("archive")

    si.deinit()
    idx.deinit()

  echo "[OK] 06: testWithLeakCheck verified 0 memory leaks"
  echo "=== ALL EVERYTHING SEARCH UNIT TESTS PASSED ==="

when isMainModule:
  runSearchUnitTests()
