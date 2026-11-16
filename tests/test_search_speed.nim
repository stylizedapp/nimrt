import std/[monotimes, times, strformat]
import corex
import ../apps/everything/src/indexer
import ../apps/everything/src/search

proc runSearchSpeedBenchmark() =
  echo "================================================================="
  echo " RUNNING 1,000,000 FILES SEARCH SPEED BENCHMARK & LEAK CHECK"
  echo "================================================================="

  testWithLeakCheck("1,000,000 Mock Records Search Speed"):
    echo "[1/4] Generating 1,000,000 mock records in Indexer..."
    let tGen0 = getMonoTime()
    var idx = newIndexer(testAlloc, 4096, 'C', initialCap = 1_000_000).unwrap()

    const
      prefixes = ["report", "invoice", "document", "photo", "backup",
                  "data", "archive", "summary", "quarterly", "contract"]
      extensions = [".pdf", ".docx", ".xlsx", ".png", ".jpg",
                    ".zip", ".txt", ".csv", ".log", ".dat"]

    # Pre-generate 10,000 distinct file names
    var namesPool: seq[string] = @[]
    namesPool.setLen(10000)
    for pIdx, pfx in prefixes:
      for eIdx, ext in extensions:
        for num in 0 ..< 100:
          let idxName = (pIdx * 10 + eIdx) * 100 + num
          namesPool[idxName] = pfx & "_" & $num & ext

    # Insert 1,000,000 files distributed across 10,000 directories
    for i in 0 ..< 1_000_000:
      let frn = uint64(10_000 + i)
      let parentFrn = uint64(5 + (i mod 10000))
      let name = namesPool[i mod 10000]
      let isDir = false
      let size = int64((i and 0xFFFF) * 1024)
      discard idx.insertOrUpdate(frn, parentFrn, name, isDir, size).unwrap()

    let genSec = (getMonoTime() - tGen0).inMicroseconds.float / 1_000_000.0
    echo &"      -> Generated {idx.len} records in {genSec:.3f} s"
    doAssert idx.len == 1_000_000

    echo "[2/4] Building high-performance search indices (prefix, suffix, trigram signatures)..."
    let tIdx0 = getMonoTime()
    var si = initSearchIndex(idx, testAlloc).unwrap()
    let idxSec = (getMonoTime() - tIdx0).inMicroseconds.float / 1_000_000.0
    echo &"      -> Search index built in {idxSec:.3f} s"

    echo "[3/4] Executing benchmark queries against 1,000,000 files..."

    # 1. Prefix Search: target < 10ms (doAssert elapsed < 0.010)
    block:
      # Warmup
      discard si.searchPrefix("report")
      let t0 = getMonoTime()
      let results = si.searchPrefix("report", limit = 1000)
      let elapsed = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
      echo &"      [PREFIX] query 'report*' -> found {results.len} matches in {elapsed * 1000.0:.3f} ms (target < 10.0 ms)"
      doAssert results.len > 0
      doAssert elapsed < 0.010, &"Prefix search took {elapsed * 1000.0:.3f} ms, expected < 10 ms"

    # 2. Suffix Search: target < 10ms (doAssert elapsed < 0.010)
    block:
      # Warmup
      discard si.searchSuffix("*.pdf")
      let t0 = getMonoTime()
      let results = si.searchSuffix("*.pdf", limit = 1000)
      let elapsed = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
      echo &"      [SUFFIX] query '*.pdf'  -> found {results.len} matches in {elapsed * 1000.0:.3f} ms (target < 10.0 ms)"
      doAssert results.len > 0
      doAssert elapsed < 0.010, &"Suffix search took {elapsed * 1000.0:.3f} ms, expected < 10 ms"

    # 3. Substring Search: target < 50ms (doAssert elapsed < 0.050)
    block:
      # Warmup
      discard si.searchSubstring("*quarterly*")
      let t0 = getMonoTime()
      let results = si.searchSubstring("*quarterly*", limit = 1000)
      let elapsed = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
      echo &"      [SUBSTR] query '*quarterly*' -> found {results.len} matches in {elapsed * 1000.0:.3f} ms (target < 50.0 ms)"
      doAssert results.len > 0
      doAssert elapsed < 0.050, &"Substring search took {elapsed * 1000.0:.3f} ms, expected < 50 ms"

    # 4. Ranked Unified Search
    block:
      let t0 = getMonoTime()
      let results = si.search("invoice", limit = 100)
      let elapsed = (getMonoTime() - t0).inMicroseconds.float / 1_000_000.0
      echo &"      [RANKED] query 'invoice' -> found {results.len} matches in {elapsed * 1000.0:.3f} ms"
      doAssert results.len > 0

    echo "[4/4] Deallocating index structures & verifying zero memory leaks..."
    si.deinit()
    idx.deinit()

  echo "[OK] testWithLeakCheck PASSED: 0 MEMORY LEAKS on 1,000,000 files!"
  echo "================================================================="
  echo " ALL 1M FILES SEARCH SPEED BENCHMARKS & LEAK CHECKS PASSED!"
  echo "================================================================="

when isMainModule:
  runSearchSpeedBenchmark()
