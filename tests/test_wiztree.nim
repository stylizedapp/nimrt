## tests/test_wiztree.nim — Comprehensive Quality & Verification Suite for WizTree Engine
##
## Tests:
## 1. Node memory layout, 40-byte compact POD layout, 8-byte alignment, zero-padding invariants,
##    node helper procs (isDir, isFile, isCompressed, isSparse, isSymlink, flags, cluster rounding).
## 2. Tree building: synthetic file/folder hierarchy with FRNs, 64-bit and 48-bit resolution,
##    hierarchy linking (FIFO order), dynamic path reconstruction (getFullPath).
## 3. Edge cases:
##    - Deeply nested trees (1200+ levels) without stack overflow in calculateSizes/calculateAggregates/getFullPath.
##    - Orphaned records: unresolvable parent FRNs handled gracefully.
##    - Cyclic links: topological sort cycle detection and decoupling without hanging.
##    - Empty directories: zero sizes and clean iteration.
##    - Unicode and long filenames: UTF-8 arena interning with zero loss.
## 4. Rollup aggregation: exact bottom-up logical size sum, cluster-rounded size on disk,
##    recursive child counts (totalFiles, totalDirs).
## 5. Top-K sorting: verification against ground-truth sorting using algx/ultrasort.
## 6. Extension statistics: case-insensitive grouping, percentage calculation, sorting by totalBytes.
## 7. Real fallback directory walk: create real local temporary directory tree, scan with scanWin32Fast,
##    verify all entries, rollup, and clean up.
## 8. CLI and serialization: argument parser, streaming JSON export, CSV export, table rendering.
## 9. Memory leak audit: TrackingAllocator & testWithLeakCheck validating 0-byte leaks under ARC/ORC.

import std/[os, strutils, algorithm, monotimes, times]
import corex
import algx
import wiztree/types
import wiztree/tree
import wiztree/scanner
import wiztree/cli

# =============================================================================
# 1. Unit Tests: Node Memory Layout, Alignment & Helpers
# =============================================================================

proc testNodeMemoryLayoutAndInvariants() =
  echo "[TEST 1] Node Memory Layout, 40-Byte POD Invariants & Helper Procs"

  # Physical POD layout guarantees
  doAssert sizeof(Node) == 40, "Node struct must be exactly 40 bytes, got " & $sizeof(Node)
  doAssert alignof(Node) == 8, "Node struct must be 8-byte aligned, got " & $alignof(Node)

  doAssert offsetof(Node, size) == 0, "size offset invariant failed"
  doAssert offsetof(Node, sizeOnDisk) == 8, "sizeOnDisk offset invariant failed"
  doAssert offsetof(Node, parentIdx) == 16, "parentIdx offset invariant failed"
  doAssert offsetof(Node, firstChild) == 20, "firstChild offset invariant failed"
  doAssert offsetof(Node, nextSibling) == 24, "nextSibling offset invariant failed"
  doAssert offsetof(Node, nameOffset) == 28, "nameOffset offset invariant failed"
  doAssert offsetof(Node, attributes) == 32, "attributes offset invariant failed"
  doAssert offsetof(Node, nameLen) == 36, "nameLen offset invariant failed"
  doAssert offsetof(Node, flags) == 38, "flags offset invariant failed"

  # Helper procs & flags validation
  var nFile = initNode(nameOffset = 100, nameLen = 12, parentIdx = 0, size = 1024, sizeOnDisk = 4096)
  doAssert nFile.isFile, "Default node should be a file"
  doAssert not nFile.isDir, "Default node should not be a dir"
  doAssert not nFile.isCompressed
  doAssert not nFile.isSparse
  doAssert not nFile.isSymlink
  doAssert nFile.hasParent
  doAssert not nFile.hasChildren
  doAssert not nFile.hasNextSibling
  doAssert not nFile.isOrphan

  var nDir = initNode(
    nameOffset = 0, nameLen = 4, parentIdx = -1,
    attributes = FILE_ATTRIBUTE_DIRECTORY, firstChild = 5, nextSibling = 8
  )
  doAssert nDir.isDir, "Directory attribute must set isDir"
  doAssert not nDir.isFile, "Directory node must not be isFile"
  doAssert nDir.hasChildren, "firstChild >= 0 must return hasChildren"
  doAssert nDir.hasNextSibling, "nextSibling >= 0 must return hasNextSibling"
  doAssert not nDir.hasParent

  var nSpecial = initNode(
    attributes = FILE_ATTRIBUTE_COMPRESSED or FILE_ATTRIBUTE_SPARSE_FILE or
                 FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_READONLY or
                 FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_SYSTEM
  )
  doAssert nSpecial.isCompressed
  doAssert nSpecial.isSparse
  doAssert nSpecial.isSymlink
  doAssert nSpecial.isReadOnly
  doAssert nSpecial.isHidden
  doAssert nSpecial.isSystem

  # Cluster rounding (calculateSizeOnDisk)
  doAssert types.calculateSizeOnDisk(0, 4096) == 0
  doAssert types.calculateSizeOnDisk(-100, 4096) == 0
  doAssert types.calculateSizeOnDisk(1, 4096) == 4096
  doAssert types.calculateSizeOnDisk(4095, 4096) == 4096
  doAssert types.calculateSizeOnDisk(4096, 4096) == 4096
  doAssert types.calculateSizeOnDisk(4097, 4096) == 8192
  doAssert types.calculateSizeOnDisk(1_000_000, 4096) == 1_003_520 # 245 * 4096

  # VolumeMetadata & ScanStats helpers
  var vol = VolumeMetadata(totalBytes: 1_000_000_000, freeBytes: 300_000_000)
  doAssert vol.usedBytes == 700_000_000
  doAssert abs(vol.usedPercentage - 70.0) < 0.001

  var stats = ScanStats(scannedFiles: 850, scannedDirs: 150)
  doAssert stats.totalItems == 1000

  echo "  -> Node memory layout & helper procs: PASSED"

# =============================================================================
# 2. Tree Building, FRN Resolution & Path Reconstruction
# =============================================================================

proc testTreeBuildingAndHierarchy() =
  echo "[TEST 2] Tree Building, FRN Resolution, Hierarchy Linking & Dynamic Paths"

  var tree = initTree(initialNodeCap = 64, initialArenaCap = 4096)
  tree.volume.clusterSize = 4096
  tree.volume.driveLetter = "C:\\"

  # Add nodes in out-of-order sequence (simulating real MFT records)
  # Root: FRN 5
  # Windows: FRN 10, parent 5
  # System32: FRN 20, parent 10
  # kernel32.dll: FRN 50, parent 20 (size 1,500,000)
  # Users: FRN 30, parent 5
  # Alice: FRN 40, parent 30
  # notes.txt: FRN 60, parent 40 (size 12,345)
  # root_file.sys: FRN 70, parent 5 (size 8,192)

  let rIdx = tree.addDirectory(-1, "C:\\", frn = 5'u64, parentFrn = 0'u64)
  tree.rootIdx = rIdx

  # Insert in scrambled order
  let k32Idx = tree.addFile(-1, "kernel32.dll", size = 1_500_000, frn = 50'u64, parentFrn = 20'u64)
  let s32Idx = tree.addDirectory(-1, "System32", frn = 20'u64, parentFrn = 10'u64)
  let winIdx = tree.addDirectory(-1, "Windows", frn = 10'u64, parentFrn = 5'u64)
  let notesIdx = tree.addFile(-1, "notes.txt", size = 12_345, frn = 60'u64, parentFrn = 40'u64)
  let aliceIdx = tree.addDirectory(-1, "Alice", frn = 40'u64, parentFrn = 30'u64)
  let usersIdx = tree.addDirectory(-1, "Users", frn = 30'u64, parentFrn = 5'u64)
  let sysIdx = tree.addFile(-1, "root_file.sys", size = 8_192, frn = 70'u64, parentFrn = 5'u64)

  # Check FRN lookup before linking
  doAssert tree.resolveFrn(5'u64) == rIdx
  doAssert tree.resolveFrn(10'u64) == winIdx
  doAssert tree.resolveFrn(20'u64) == s32Idx
  doAssert tree.resolveFrn(50'u64) == k32Idx

  # Test 48-bit masked FRN resolution with high 16-bit sequence number
  let frnWithSeq = 0x0003_0000_0000_0014'u64 # MFT index 20 (System32) with seq 3
  tree.registerFrn(frnWithSeq, s32Idx)
  doAssert tree.resolveFrn(frnWithSeq) == s32Idx
  doAssert tree.resolveFrn(20'u64) == s32Idx

  # Link hierarchy
  tree.linkHierarchy()

  # Verify parent links resolved
  doAssert tree.nodes[int(winIdx)].parentIdx == rIdx
  doAssert tree.nodes[int(usersIdx)].parentIdx == rIdx
  doAssert tree.nodes[int(sysIdx)].parentIdx == rIdx
  doAssert tree.nodes[int(s32Idx)].parentIdx == winIdx
  doAssert tree.nodes[int(k32Idx)].parentIdx == s32Idx
  doAssert tree.nodes[int(aliceIdx)].parentIdx == usersIdx
  doAssert tree.nodes[int(notesIdx)].parentIdx == aliceIdx

  # Verify child list iteration
  var rootChildren: seq[int32] = @[]
  for ch in tree.children(rIdx):
    rootChildren.add(ch)
  doAssert rootChildren.contains(winIdx)
  doAssert rootChildren.contains(usersIdx)
  doAssert rootChildren.contains(sysIdx)

  var winChildren: seq[int32] = @[]
  for ch in tree.children(winIdx):
    winChildren.add(ch)
  doAssert winChildren == @[s32Idx]

  var s32Children: seq[int32] = @[]
  for ch in tree.children(s32Idx):
    s32Children.add(ch)
  doAssert s32Children == @[k32Idx]

  # Dynamic Path Reconstruction
  let k32Path = tree.getFullPath(k32Idx)
  doAssert k32Path == "C:\\Windows\\System32\\kernel32.dll", "Got: " & k32Path

  let notesPath = tree.getFullPath(notesIdx)
  doAssert notesPath == "C:\\Users\\Alice\\notes.txt", "Got: " & notesPath

  let rootFilePath = tree.getFullPath(sysIdx)
  doAssert rootFilePath == "C:\\root_file.sys", "Got: " & rootFilePath

  let rootPath = tree.getFullPath(rIdx)
  doAssert rootPath == "C:\\", "Got: " & rootPath

  echo "  -> Tree building & hierarchy resolution: PASSED"

# =============================================================================
# 3. Edge Cases: Deep Trees, Orphans, Cycles, Empty Dirs, Unicode
# =============================================================================

proc testEdgeCases() =
  echo "[TEST 3] Edge Cases: Deep Trees (1200+ levels), Orphans, Cycles, Empty Dirs, Unicode"

  # Case A: Deeply nested tree (1200 levels) - verify non-recursive rollup & traversal
  block:
    var deepTree = initTree(initialNodeCap = 2048, initialArenaCap = 64 * 1024)
    deepTree.volume.clusterSize = 4096
    deepTree.volume.driveLetter = "C:\\"

    let root = deepTree.addDirectory(-1, "C:\\", frn = 1'u64, parentFrn = 0'u64)
    deepTree.rootIdx = root

    const Depth = 1200
    var curParent = root
    for d in 1 .. Depth:
      let dirIdx = deepTree.addDirectory(curParent, "D" & $d, frn = uint64(d + 1), parentFrn = uint64(d))
      curParent = dirIdx

    # Place a file at the deepest leaf
    let leafFile = deepTree.addFile(curParent, "deep_leaf.dat", size = 500_000, frn = 9999'u64, parentFrn = uint64(Depth + 1))

    deepTree.linkHierarchy()
    # Must not overflow call stack!
    deepTree.calculateSizes()
    let aggs = deepTree.calculateAggregates()

    doAssert deepTree.nodes[int(root)].size == 500_000, "Root logical size mismatch: " & $deepTree.nodes[int(root)].size
    doAssert deepTree.nodes[int(root)].sizeOnDisk == types.calculateSizeOnDisk(500_000, 4096)
    doAssert aggs[int(root)].totalFiles == 1
    doAssert aggs[int(root)].totalDirs == int64(Depth)

    # Path reconstruction on deep leaf
    let path = deepTree.getFullPath(leafFile)
    doAssert path.startsWith("C:\\D1\\D2\\")
    doAssert path.endsWith("deep_leaf.dat")
    echo "    - Deep tree (1200 levels non-recursive stack safe): PASSED"

  # Case B: Orphaned records (unresolvable parent FRN)
  block:
    var orphanTree = initTree(initialNodeCap = 16, initialArenaCap = 1024)
    let root = orphanTree.addDirectory(-1, "C:\\", frn = 5'u64, parentFrn = 0'u64)
    orphanTree.rootIdx = root
    let orphanFile = orphanTree.addFile(-1, "ghost.bin", size = 1000, frn = 500'u64, parentFrn = 0xDEADBEEF'u64)
    orphanTree.linkHierarchy()

    doAssert orphanTree.nodes[int(orphanFile)].isOrphan, "Unresolved parent must be flagged as orphan"
    orphanTree.calculateSizes()
    doAssert orphanTree.stats.scannedFiles == 1
    echo "    - Orphan record handling: PASSED"

  # Case C: Cyclic links (Node A -> Node B -> Node A)
  block:
    var cycleTree = initTree(initialNodeCap = 16, initialArenaCap = 1024)
    let a = cycleTree.addDirectory(-1, "DirA")
    let b = cycleTree.addDirectory(-1, "DirB")
    cycleTree.nodes[int(a)].parentIdx = b
    cycleTree.nodes[int(b)].parentIdx = a

    # Out-degree cycle must be detected and broken without hanging in an infinite loop
    cycleTree.calculateSizes()
    doAssert (cycleTree.nodes[int(a)].flags and NODE_FLAG_ORPHAN) != 0, "Cycle node A must be decoupled"
    doAssert (cycleTree.nodes[int(b)].flags and NODE_FLAG_ORPHAN) != 0, "Cycle node B must be decoupled"
    echo "    - Cyclic link detection and decoupling: PASSED"

  # Case D: Empty directories
  block:
    var emptyTree = initTree(initialNodeCap = 16, initialArenaCap = 1024)
    let root = emptyTree.addDirectory(-1, "EmptyRoot")
    emptyTree.rootIdx = root
    let sub = emptyTree.addDirectory(root, "EmptySub")
    emptyTree.linkHierarchy()
    emptyTree.calculateSizes()

    doAssert emptyTree.nodes[int(root)].size == 0
    doAssert emptyTree.nodes[int(sub)].size == 0
    doAssert not emptyTree.nodes[int(sub)].hasChildren
    echo "    - Empty directories handling: PASSED"

  # Case E: Unicode & Long File Names
  block:
    var uniTree = initTree(initialNodeCap = 16, initialArenaCap = 4096)
    let cyrillicName = "Отчёт_производительности_2026.docx"
    let cjkName = "高速NTFS扫描引擎_WizTree.dat"
    let emojiName = "⚡Ultra🚀Speed🔥Index.log"
    let longName = repeat("very_long_path_segment_", 12) & ".bin" # 280+ chars

    let cIdx = uniTree.addFile(-1, cyrillicName, size = 100)
    let cjkIdx = uniTree.addFile(-1, cjkName, size = 200)
    let emoIdx = uniTree.addFile(-1, emojiName, size = 300)
    let longIdx = uniTree.addFile(-1, longName, size = 400)

    doAssert uniTree.getName(cIdx) == cyrillicName
    doAssert uniTree.getName(cjkIdx) == cjkName
    doAssert uniTree.getName(emoIdx) == emojiName
    doAssert uniTree.getName(longIdx) == longName

    let span = uniTree.getNameByteSpan(uniTree.nodes[int(cIdx)])
    doAssert span.len == cyrillicName.len
    echo "    - Unicode and long filename interning: PASSED"

  echo "  -> Edge cases test suite: PASSED"

# =============================================================================
# 4. Rollup Aggregation & Size-On-Disk Invariants
# =============================================================================

proc testRollupAggregation() =
  echo "[TEST 4] Rollup Aggregation, Physical Disk Rounding & Recursive Counts"

  var tree = initTree(initialNodeCap = 32, initialArenaCap = 4096)
  tree.volume.clusterSize = 4096
  tree.volume.driveLetter = "D:\\"

  # Construct hierarchy:
  # Root (D:\)
  # ├── FolderA
  # │   ├── FileA1: 1,000 bytes -> 4,096 on disk
  # │   ├── FileA2: 5,000 bytes -> 8,192 on disk
  # │   └── SubA
  # │       └── FileSubA: 4,096 bytes -> 4,096 on disk
  # └── FolderB
  #     ├── FileB1: 10,000 bytes -> 12,288 on disk
  #     └── EmptyFolderB

  let rIdx = tree.addDirectory(-1, "D:\\")
  tree.rootIdx = rIdx

  let fA = tree.addDirectory(rIdx, "FolderA")
  let fileA1 = tree.addFile(fA, "FileA1.dat", size = 1_000)
  let fileA2 = tree.addFile(fA, "FileA2.bin", size = 5_000)
  let subA = tree.addDirectory(fA, "SubA")
  let fileSubA = tree.addFile(subA, "FileSubA.log", size = 4_096)

  let fB = tree.addDirectory(rIdx, "FolderB")
  let fileB1 = tree.addFile(fB, "FileB1.txt", size = 10_000)
  let emptyB = tree.addDirectory(fB, "EmptyFolderB")

  tree.linkHierarchy()
  tree.calculateSizes()

  # Check exact sizes
  let expectedSubASize = 4_096'i64
  let expectedSubADisk = 4_096'i64
  doAssert tree.nodes[int(subA)].size == expectedSubASize
  doAssert tree.nodes[int(subA)].sizeOnDisk == expectedSubADisk

  let expectedFolderASize = 1_000'i64 + 5_000'i64 + 4_096'i64 # 10,096
  let expectedFolderADisk = 4_096'i64 + 8_192'i64 + 4_096'i64 # 16,384
  doAssert tree.nodes[int(fA)].size == expectedFolderASize
  doAssert tree.nodes[int(fA)].sizeOnDisk == expectedFolderADisk

  let expectedFolderBSize = 10_000'i64
  let expectedFolderBDisk = 12_288'i64
  doAssert tree.nodes[int(fB)].size == expectedFolderBSize
  doAssert tree.nodes[int(fB)].sizeOnDisk == expectedFolderBDisk

  let expectedRootSize = expectedFolderASize + expectedFolderBSize # 20,096
  let expectedRootDisk = expectedFolderADisk + expectedFolderBDisk # 28,672
  doAssert tree.nodes[int(rIdx)].size == expectedRootSize
  doAssert tree.nodes[int(rIdx)].sizeOnDisk == expectedRootDisk

  # Verify stats
  doAssert tree.stats.scannedFiles == 4
  doAssert tree.stats.scannedDirs == 5 # D:\, FolderA, SubA, FolderB, EmptyFolderB
  doAssert tree.stats.totalBytes == expectedRootSize
  doAssert tree.stats.totalBytesOnDisk == expectedRootDisk

  # Verify recursive child counts via calculateAggregates
  let aggs = tree.calculateAggregates()
  doAssert aggs[int(rIdx)].totalFiles == 4
  doAssert aggs[int(rIdx)].totalDirs == 4 # FolderA, SubA, FolderB, EmptyFolderB
  doAssert aggs[int(fA)].totalFiles == 3
  doAssert aggs[int(fA)].totalDirs == 1 # SubA
  doAssert aggs[int(fB)].totalFiles == 1
  doAssert aggs[int(fB)].totalDirs == 1 # EmptyFolderB
  doAssert aggs[int(emptyB)].totalFiles == 0
  doAssert aggs[int(emptyB)].totalDirs == 0

  echo "  -> Rollup aggregation invariants: PASSED"

# =============================================================================
# 5. Top-K Sorting (Verified against Ground-Truth ultrasort)
# =============================================================================

proc testTopKSorting() =
  echo "[TEST 5] Top-K Sorting against Ground-Truth UltraSort"

  var tree = initTree(initialNodeCap = 2500, initialArenaCap = 64 * 1024)
  tree.volume.clusterSize = 4096
  let root = tree.addDirectory(-1, "C:\\")
  tree.rootIdx = root

  # Pseudo-random deterministic sizes
  const NumFiles = 2000
  var state = 0xDEAD_BEEF_CAFE_0001'u64
  var allFileSizes = newSeq[int64](NumFiles)

  for i in 0 ..< NumFiles:
    state = state xor (state shl 13)
    state = state xor (state shr 7)
    state = state xor (state shl 17)
    let sz = int64(state mod 1_000_000_000'u64) + 1'i64
    allFileSizes[i] = sz
    discard tree.addFile(root, "file_" & $i & ".bin", size = sz)

  # Also add 50 folders of varying sizes
  for i in 0 ..< 50:
    let dirIdx = tree.addDirectory(root, "dir_" & $i)
    discard tree.addFile(dirIdx, "subfile_" & $i & ".dat", size = int64((i + 1) * 10_000_000))

  tree.linkHierarchy()
  tree.calculateSizes()

  # 1. Test getTopFiles (count = 20)
  let topFiles = tree.getTopFiles(count = 20, criterion = scSize)
  doAssert topFiles.len == 20

  # Check descending order
  for i in 0 ..< topFiles.len - 1:
    doAssert topFiles[i].size >= topFiles[i + 1].size,
      "Top files not sorted descending at index " & $i

  # Ground truth check with ultrasort
  var gtSizes = allFileSizes
  var aux = newSeq[int64](gtSizes.len)
  discard ultraSort(gtSizes, aux) # sorts ascending

  # Top 20 largest files should match top 20 elements of gtSizes from end
  for i in 0 ..< 20:
    let expected = gtSizes[gtSizes.len - 1 - i]
    doAssert topFiles[i].size == expected,
      "Top file rank " & $i & " mismatch: expected " & $expected & ", got " & $topFiles[i].size

  # 2. Test getTopFolders
  let topFolders = tree.getTopFolders(count = 10, criterion = scSize, includeRoot = false)
  doAssert topFolders.len == 10
  for i in 0 ..< topFolders.len - 1:
    doAssert topFolders[i].size >= topFolders[i + 1].size

  # 3. Test getTopItems by item count
  let topItems = tree.getTopItems(count = 15, criterion = scItemCount)
  doAssert topItems.len == 15
  for i in 0 ..< topItems.len - 1:
    doAssert topItems[i].childCount >= topItems[i + 1].childCount

  echo "  -> Top-K sorting against ground truth: PASSED"

# =============================================================================
# 6. Extension Statistics
# =============================================================================

proc testExtensionStatistics() =
  echo "[TEST 6] Extension Statistics Aggregation & Normalization"

  var tree = initTree(initialNodeCap = 64, initialArenaCap = 4096)
  tree.volume.clusterSize = 4096
  let root = tree.addDirectory(-1, "C:\\")
  tree.rootIdx = root

  # Insert files with mixed-case extensions
  discard tree.addFile(root, "archive.ZIP", size = 50_000)
  discard tree.addFile(root, "backup.zip", size = 50_000) # total .zip: 2 files, 100,000 bytes
  discard tree.addFile(root, "system.DLL", size = 30_000)
  discard tree.addFile(root, "core.dll", size = 20_000)   # total .dll: 2 files, 50,000 bytes
  discard tree.addFile(root, "doc.txt", size = 5_000)
  discard tree.addFile(root, "README.TXT", size = 5_000)  # total .txt: 2 files, 10,000 bytes
  discard tree.addFile(root, "LICENSE", size = 2_000)     # no ext: 1 file, 2,000 bytes

  tree.linkHierarchy()
  tree.calculateSizes()

  let extStats = tree.getExtensionStats()
  doAssert extStats.len == 4 # .zip, .dll, .txt, ""

  # Sorted by totalBytes descending: .zip (100k), .dll (50k), .txt (10k), "" (2k)
  doAssert extStats[0].ext == ".zip"
  doAssert extStats[0].fileCount == 2
  doAssert extStats[0].totalBytes == 100_000

  doAssert extStats[1].ext == ".dll"
  doAssert extStats[1].fileCount == 2
  doAssert extStats[1].totalBytes == 50_000

  doAssert extStats[2].ext == ".txt"
  doAssert extStats[2].fileCount == 2
  doAssert extStats[2].totalBytes == 10_000

  doAssert extStats[3].ext == ""
  doAssert extStats[3].fileCount == 1
  doAssert extStats[3].totalBytes == 2_000

  # Percentages sum to ~100%
  var sumPct = 0.0
  for s in extStats:
    sumPct += s.percentage
  doAssert abs(sumPct - 100.0) < 0.1, "Percentages sum mismatch: " & $sumPct

  echo "  -> Extension statistics: PASSED"

# =============================================================================
# 7. Fallback Directory Walk on Real Local Temporary Folder
# =============================================================================

proc testFallbackDirectoryWalkOnRealFolder() =
  echo "[TEST 7] Fallback Directory Walk (scanWin32Fast) on Real Filesystem"

  let tempDir = getTempDir() / "wiztree_verifier_tmp_" & $getCurrentProcessId()
  createDir(tempDir)
  createDir(tempDir / "subA")
  createDir(tempDir / "subB" / "nested")

  let file1 = tempDir / "file1.txt"
  let file2 = tempDir / "subA" / "file2.bin"
  let file3 = tempDir / "subB" / "nested" / "file3.log"

  writeFile(file1, "Hello from WizTree Test Root File!")
  writeFile(file2, repeat("ABCD", 256)) # 1024 bytes
  writeFile(file3, repeat("XYZ", 512))  # 1536 bytes

  let totalRawBytes = int64(readFile(file1).len + readFile(file2).len + readFile(file3).len)

  try:
    var opts = defaultScanOptions(tempDir)
    opts.scanModePreference = smWin32Fast
    let scanRes = scanVolume(opts)
    doAssert scanRes.isOk, "scanVolume failed on real folder: " & scanRes.error

    var scannedTree = scanRes.unwrap()
    doAssert scannedTree.len >= 4 # root + 3 files + subdirs
    doAssert scannedTree.stats.scannedFiles == 3
    doAssert scannedTree.stats.scannedDirs >= 3
    doAssert scannedTree.stats.totalBytes == totalRawBytes

    scannedTree.calculateSizes()
    doAssert scannedTree.nodes[int(scannedTree.rootIdx)].size == totalRawBytes

    let topFiles = scannedTree.getTopFiles(count = 5)
    doAssert topFiles.len == 3
    doAssert topFiles[0].size >= topFiles[1].size
    doAssert topFiles[1].size >= topFiles[2].size

  finally:
    removeDir(tempDir)

  echo "  -> Fallback directory walk on real disk: PASSED"

# =============================================================================
# 8. CLI Presentation, Argument Parsing & Streaming Exports
# =============================================================================

proc testCliAndExports() =
  echo "[TEST 8] CLI Parameter Parsing & Streaming Exports (JSON, CSV, Table)"

  # Arg parser
  let args = ["C:\\Test", "--format:json", "--top:50", "--sort:disk", "--mode:fast", "--quiet"]
  let cfg = parseArgs(args)
  doAssert cfg.targetPath == "C:\\Test"
  doAssert cfg.format == ofJson
  doAssert cfg.topCount == 50
  doAssert cfg.sortCriterion == scSizeOnDisk
  doAssert cfg.scanMode == smWin32Fast
  doAssert cfg.quiet == true

  # Synthetic tree for export rendering
  var tree = initTree(initialNodeCap = 32, initialArenaCap = 4096)
  tree.volume = VolumeMetadata(
    clusterSize: 4096, sectorSize: 512,
    totalBytes: 100_000_000_000, freeBytes: 40_000_000_000,
    fsType: "NTFS", volumeName: "OS_DISK", driveLetter: "C:\\"
  )
  let r = tree.addDirectory(-1, "C:\\")
  tree.rootIdx = r
  discard tree.addFile(r, "app.exe", size = 15_000_000)
  discard tree.addFile(r, "data.db", size = 25_000_000)
  tree.linkHierarchy()
  tree.calculateSizes()

  # Top items and stats
  let topFiles = tree.getTopFiles(5)
  let topFolders = tree.getTopFolders(5, includeRoot = false)
  let extStats = tree.getExtensionStats()

  # Streaming JSON export
  let jsonOutput = renderJson(tree, topFiles, topFolders, extStats)
  doAssert jsonOutput.contains("\"volume\":"), "JSON must contain volume object"
  doAssert jsonOutput.contains("\"stats\":"), "JSON must contain stats object"
  doAssert jsonOutput.contains("\"topFiles\":"), "JSON must contain topFiles array"
  doAssert jsonOutput.contains("app.exe"), "JSON must contain app.exe"

  # CSV export
  let csvOutput = renderCsv(tree, topFiles, topFolders, extStats)
  doAssert csvOutput.contains("# Section: Volume"), "CSV must contain volume summary section"
  doAssert csvOutput.contains("# Section: Top Files"), "CSV must contain top files section"
  doAssert csvOutput.contains("app.exe"), "CSV must list app.exe"

  # Table rendering
  var normalCfg = cfg
  normalCfg.quiet = false
  let tableOutput = renderTable(tree, topFiles, topFolders, extStats, normalCfg)
  doAssert tableOutput.contains("WizTree High-Performance Disk Scanner Engine"), "Table must contain header"
  doAssert tableOutput.contains("Largest Files"), "Table must show top files section"
  doAssert tableOutput.contains("Largest Folders"), "Table must show top folders section"
  doAssert tableOutput.contains("Extension Distribution"), "Table must show extension section"

  echo "  -> CLI parameters & streaming exports: PASSED"

# =============================================================================
# 9. Memory Leak Audit via TrackingAllocator & ARC/ORC Invariants
# =============================================================================

proc testMemoryLeakAudit() =
  echo "[TEST 9] Memory Leak Audit under TrackingAllocator & ARC/ORC"

  testWithLeakCheck("BufSeq and Tree Memory Lifecycle"):
    # Test BufSeq allocation and reallocation under TrackingAllocator
    var bRes = initBufSeq[Node](testAlloc, initialCap = 16)
    doAssert bRes.isOk
    var bSeq = bRes.unwrap()
    for i in 0 ..< 100:
      bSeq.add(initNode(size = int64(i * 100)))
    doAssert bSeq.len == 100
    `=destroy`(bSeq)

  testWithLeakCheck("Tree Node Insertion, Move & Copy Semantics"):
    var tree = initTree(initialNodeCap = 64, initialArenaCap = 4096, nodeAlloc = testAlloc)
    for i in 0 ..< 120:
      discard tree.addFile(-1, "test_file_" & $i, size = int64(i * 50))
    doAssert tree.len == 120

    # Test move semantics
    var movedTree = move(tree)
    doAssert movedTree.len == 120
    doAssert tree.len == 0

    # Test deep copy semantics
    var copiedTree = movedTree
    doAssert copiedTree.len == 120
    doAssert movedTree.len == 120

    # Destructors run at block exit and must leave 0 active allocations in testAlloc

  echo "  -> Memory leak audit (0 byte leaks verified): PASSED"

# =============================================================================
# Main Verification Test Runner
# =============================================================================

proc runVerificationSuite() =
  echo "=================================================================="
  echo "       WizTree Engine Comprehensive Verification Test Suite       "
  echo "=================================================================="
  let t0 = getMonoTime()

  testNodeMemoryLayoutAndInvariants()
  testTreeBuildingAndHierarchy()
  testEdgeCases()
  testRollupAggregation()
  testTopKSorting()
  testExtensionStatistics()
  testFallbackDirectoryWalkOnRealFolder()
  testCliAndExports()
  testMemoryLeakAudit()

  let elapsed = float64(inMicroseconds(getMonoTime() - t0)) / 1000.0
  echo "=================================================================="
  echo "   ALL 9 VERIFICATION TEST SUITES PASSED IN " & $elapsed.formatFloat(ffDecimal, 2) & " ms"
  echo "   0 WARNINGS, 0 ERRORS, 0 LEAKS DETECTED"
  echo "=================================================================="

when isMainModule:
  runVerificationSuite()
