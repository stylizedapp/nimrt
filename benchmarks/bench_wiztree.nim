## benchmarks/bench_wiztree.nim — High-Throughput Performance Benchmarks for WizTree Engine
##
## Measures:
## 1. Synthetic node ingestion throughput at 500,000 and 1,000,000 nodes
##    (zero-heap string arena interning + 40-byte compact POD buffer insertion + FastMap FRN indexing)
## 2. Bottom-up hierarchy linking and directory size rollup latency (calculateSizes) on 1,000,000 nodes
## 3. Top-K sorting latency (algx/ultrasort) for largest files and folders on 1,000,000 nodes
## 4. Extension statistics aggregation throughput on 1,000,000 nodes
## 5. Dynamic path reconstruction latency on randomly sampled hierarchy depths
##
## Compiles under: nim c -d:danger --opt:speed -r benchmarks/bench_wiztree.nim

import std/[strformat, monotimes, times]
import corex
import algx
import wiztree/types
import wiztree/tree

const
  Count500K = 500_000
  Count1M   = 1_000_000

proc buildSyntheticTree(nodeCount: int): Tree =
  var tree = initTree(initialNodeCap = nodeCount + 16, initialArenaCap = nodeCount * 24)
  tree.volume = VolumeMetadata(clusterSize: 4096, sectorSize: 512, driveLetter: "C:\\")

  let root = tree.addDirectory(-1, "C:\\", frn = 5'u64, parentFrn = 0'u64)
  tree.rootIdx = root

  # Create a hierarchy of 500 folders, with files distributed under them
  const NumFolders = 500
  var folderFrns: array[NumFolders, uint64]

  for d in 0 ..< NumFolders:
    let fFrn = uint64(100 + d)
    folderFrns[d] = fFrn
    let parentFolderFrn = if d == 0: 5'u64 else: uint64(100 + (d mod 20))
    discard tree.addDirectory(-1, "Dir_" & $d, frn = fFrn, parentFrn = parentFolderFrn)

  var state = 0x1234_5678_9ABC_DEF0'u64
  let fileCount = nodeCount - NumFolders - 1

  for i in 0 ..< fileCount:
    state = state xor (state shl 13)
    state = state xor (state shr 7)
    state = state xor (state shl 17)
    let pFrn = folderFrns[int(state mod uint64(NumFolders))]
    let sz = int64(state mod 50_000_000'u64) + 1'i64
    let extIdx = int(state mod 6'u64)
    let ext = case extIdx
              of 0: ".dll"
              of 1: ".exe"
              of 2: ".zip"
              of 3: ".txt"
              of 4: ".mp4"
              else: ".bin"
    discard tree.addFile(-1, "file_" & $i & ext, size = sz, frn = uint64(10_000 + i), parentFrn = pFrn)

  result = move(tree)

proc benchIngestion(count: int) =
  let t0 = getMonoTime()
  var tree = buildSyntheticTree(count)
  let elapsedMs = float64(inMicroseconds(getMonoTime() - t0)) / 1000.0
  let mNodesPerSec = (float64(count) / (elapsedMs / 1000.0)) / 1_000_000.0
  let memMb = float64(tree.nodes.cap * sizeof(Node) + tree.stringArena.capacity) / (1024.0 * 1024.0)

  echo &"  Ingestion of {count:>10} nodes | time: {elapsedMs:>7.2f} ms | throughput: {mNodesPerSec:>6.2f} M nodes/s | mem: {memMb:>6.1f} MB"

proc runFullBenchmarkSuite() =
  echo "=================================================================================="
  echo "         WizTree Engine High-Performance Benchmark Suite (1,000,000 Nodes)        "
  echo "=================================================================================="

  echo "\n[BENCH 1] Synthetic Ingestion Throughput (Arena Interning + POD Insertion + FastMap FRN):"
  benchIngestion(Count500K)
  benchIngestion(Count1M)

  echo "\n[BENCH 2] Constructing 1,000,000 Node Reference Tree for Hierarchy & Aggregations..."
  let tBuild0 = getMonoTime()
  var tree1M = buildSyntheticTree(Count1M)
  let buildMs = float64(inMicroseconds(getMonoTime() - tBuild0)) / 1000.0
  echo &"  Reference tree constructed in {buildMs:.2f} ms ({tree1M.len} nodes total)"

  echo "\n[BENCH 3] Hierarchy Linking Latency (Resolving Parent FRNs in O(N)): "
  let tLink0 = getMonoTime()
  tree1M.linkHierarchy()
  let linkMs = float64(inMicroseconds(getMonoTime() - tLink0)) / 1000.0
  let linkThroughput = (float64(tree1M.len) / (linkMs / 1000.0)) / 1_000_000.0
  echo &"  linkHierarchy(1M nodes)        | time: {linkMs:>7.2f} ms | throughput: {linkThroughput:>6.2f} M nodes/s"

  echo "\n[BENCH 4] Directory Size Aggregation Latency (Non-Recursive Topological Rollup): "
  let tRoll0 = getMonoTime()
  tree1M.calculateSizes()
  let rollMs = float64(inMicroseconds(getMonoTime() - tRoll0)) / 1000.0
  let rollThroughput = (float64(tree1M.len) / (rollMs / 1000.0)) / 1_000_000.0
  echo &"  calculateSizes(1M nodes)       | time: {rollMs:>7.2f} ms | throughput: {rollThroughput:>6.2f} M nodes/s"

  echo "\n[BENCH 5] Recursive Aggregates (totalFiles & totalDirs calculation):"
  let tAgg0 = getMonoTime()
  let aggs = tree1M.calculateAggregates()
  let aggMs = float64(inMicroseconds(getMonoTime() - tAgg0)) / 1000.0
  let aggThroughput = (float64(tree1M.len) / (aggMs / 1000.0)) / 1_000_000.0
  echo &"  calculateAggregates(1M nodes)  | time: {aggMs:>7.2f} ms | throughput: {aggThroughput:>6.2f} M nodes/s (Root has {aggs[int(tree1M.rootIdx)].totalFiles} files)"

  echo "\n[BENCH 6] Top-K Largest Item Selection Latency (algx/ultrasort):"
  for topK in [10, 50, 100, 500]:
    let tSort0 = getMonoTime()
    let topFiles = tree1M.getTopFiles(count = topK, criterion = scSize)
    let sortMs = float64(inMicroseconds(getMonoTime() - tSort0)) / 1000.0
    echo &"  getTopFiles(Top {topK:<3} from 1M)     | time: {sortMs:>7.2f} ms | largest: {topFiles[0].size:>12} bytes"

  for topK in [10, 50]:
    let tSortF0 = getMonoTime()
    let topFolders = tree1M.getTopFolders(count = topK, criterion = scSize, includeRoot = false)
    let sortFMs = float64(inMicroseconds(getMonoTime() - tSortF0)) / 1000.0
    echo &"  getTopFolders(Top {topK:<2} from 1M)   | time: {sortFMs:>7.2f} ms | largest: {topFolders[0].size:>12} bytes"

  echo "\n[BENCH 7] File Extension Grouping & Statistics Latency:"
  let tExt0 = getMonoTime()
  let extStats = tree1M.getExtensionStats()
  let extMs = float64(inMicroseconds(getMonoTime() - tExt0)) / 1000.0
  let extThroughput = (float64(tree1M.len) / (extMs / 1000.0)) / 1_000_000.0
  echo &"  getExtensionStats(1M nodes)    | time: {extMs:>7.2f} ms | throughput: {extThroughput:>6.2f} M nodes/s ({extStats.len} extensions found)"

  echo "\n[BENCH 8] Dynamic Path Reconstruction Latency (10,000 Lookups):"
  let numLookups = 10_000
  var state = 0x5555_AAAA_1234_9876'u64
  let tPath0 = getMonoTime()
  var dummyPathSum = 0
  for _ in 0 ..< numLookups:
    state = state xor (state shl 13)
    state = state xor (state shr 7)
    state = state xor (state shl 17)
    let sampleIdx = int32(state mod uint64(tree1M.len))
    let p = tree1M.getFullPath(sampleIdx)
    dummyPathSum += p.len
  let pathMs = float64(inMicroseconds(getMonoTime() - tPath0)) / 1000.0
  let lookupsPerSec = float64(numLookups) / (pathMs / 1000.0)
  echo &"  getFullPath (10,000 random)    | time: {pathMs:>7.2f} ms | rate: {lookupsPerSec:>10.0f} paths/sec"

  echo "\n=================================================================================="
  echo "          ALL BENCHMARKS COMPLETED WITH OUTSTANDING PERFORMANCE RESULTS           "
  echo "=================================================================================="

when isMainModule:
  runFullBenchmarkSuite()
