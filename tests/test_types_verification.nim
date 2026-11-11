## Verification test for src/wiztree/types.nim

import std/[strformat]
import ../src/corex/allocators
import ../src/corex/memory
import ../src/corex/containers
import ../src/corex/testing
import ../src/algx/swissmap
import ../src/wiztree/types

proc main() =
  echo "=== Running WizTree Types Verification Suite ==="

  # 1. Node Layout & Alignment Invariants
  block:
    doAssert sizeof(Node) == 40, "Node must be exactly 40 bytes"
    doAssert alignof(Node) == 8, "Node must be 8-byte aligned"
    
    var n = initNode(
      nameOffset = 100'u32,
      nameLen = 12'u16,
      parentIdx = 5'i32,
      size = 1048576'i64,
      sizeOnDisk = 1052672'i64,
      attributes = FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_COMPRESSED
    )
    doAssert n.isDir == true
    doAssert n.isFile == false
    doAssert n.isCompressed == true
    doAssert n.isSparse == false
    doAssert n.isSymlink == false
    doAssert n.hasParent == true
    doAssert n.hasChildren == false
    doAssert n.hasNextSibling == false

    var fileNode = initNode(
      nameOffset = 200'u32,
      nameLen = 8'u16,
      parentIdx = 0'i32,
      size = 500'i64,
      sizeOnDisk = 4096'i64,
      attributes = FILE_ATTRIBUTE_NORMAL or FILE_ATTRIBUTE_SPARSE_FILE
    )
    doAssert fileNode.isDir == false
    doAssert fileNode.isFile == true
    doAssert fileNode.isSparse == true
    echo "  [PASS] 1. Node POD layout & helpers verified"

  # 2. VolumeMetadata, ScanStats, and ScanOptions
  block:
    let vol = VolumeMetadata(
      clusterSize: 4096,
      sectorSize: 512,
      totalBytes: 1_000_000_000'i64,
      freeBytes: 400_000_000'i64,
      fsType: "NTFS",
      volumeName: "Local Disk",
      driveLetter: "C:"
    )
    doAssert vol.usedBytes == 600_000_000'i64
    doAssert abs(vol.usedPercentage - 60.0) < 0.001

    let stats = ScanStats(
      scannedFiles: 950_000,
      scannedDirs: 50_000,
      totalBytes: 500_000_000_000'i64,
      totalBytesOnDisk: 510_000_000_000'i64,
      elapsedMs: 1250.0,
      throughputFilesPerSec: 800_000.0,
      scanMode: smMftDirect
    )
    doAssert stats.totalItems == 1_000_000'i64
    doAssert $stats.scanMode == "MFT Direct"

    let opts = defaultScanOptions("C:\\")
    doAssert opts.rootPath == "C:\\"
    doAssert opts.scanModePreference == smMftDirect
    doAssert opts.computeSizeOnDisk == true
    doAssert opts.maxDepth == -1

    doAssert calculateSizeOnDisk(10, 4096) == 4096
    doAssert calculateSizeOnDisk(4096, 4096) == 4096
    doAssert calculateSizeOnDisk(4097, 4096) == 8192
    echo "  [PASS] 2. Metadata, Stats & Options verified"

  # 3. Tree Ingestion, String Arena & Lifecycle Under TrackingAllocator
  block:
    testWithLeakCheck("Tree Ingestion & RAII Lifecycle"):
      var tree = initTree(initialNodeCap = 128, initialArenaCap = 1024, nodeAlloc = testAlloc)
      doAssert tree.len == 0
      doAssert tree.isEmpty == true

      # Intern root
      let (rOffset, rLen) = tree.internName("C:\\")
      let rootIdx = tree.addNode(initNode(
        nameOffset = rOffset,
        nameLen = rLen,
        parentIdx = -1,
        attributes = FILE_ATTRIBUTE_DIRECTORY
      ), frn = 0x0001000000000005'u64)
      tree.rootIdx = rootIdx

      # Intern children
      let (wOffset, wLen) = tree.internName("Windows")
      let winIdx = tree.addNode(initNode(
        nameOffset = wOffset,
        nameLen = wLen,
        parentIdx = rootIdx,
        attributes = FILE_ATTRIBUTE_DIRECTORY
      ), frn = 0x0001000000000020'u64)

      let (uOffset, uLen) = tree.internName("Users")
      let usersIdx = tree.addNode(initNode(
        nameOffset = uOffset,
        nameLen = uLen,
        parentIdx = rootIdx,
        attributes = FILE_ATTRIBUTE_DIRECTORY
      ), frn = 0x0001000000000030'u64)

      # Link siblings
      tree[rootIdx].firstChild = winIdx
      tree[winIdx].nextSibling = usersIdx

      doAssert tree.len == 3
      doAssert tree.getName(rootIdx) == "C:\\"
      doAssert tree.getName(winIdx) == "Windows"
      doAssert tree.getName(usersIdx) == "Users"

      # Check zero-copy ByteSpan
      let spanWin = tree.getNameByteSpan(tree[winIdx])
      doAssert spanWin.len == 7
      doAssert spanWin.asString == "Windows"

      # Check FRN lookup in frnMap
      doAssert tree.frnMap.contains(0x0001000000000005'u64)
      doAssert tree.frnMap.getOrDefault(0x0001000000000005'u64, -1) == rootIdx
      doAssert tree.frnMap.getOrDefault(0x0001000000000020'u64, -1) == winIdx
      doAssert tree.frnMap.getOrDefault(0x0001000000000030'u64, -1) == usersIdx

      # Children iteration
      var childCount = 0
      for childIdx in tree.children(rootIdx):
        inc(childCount)
      doAssert childCount == 2
      echo "  [PASS] 3. Tree Ingestion, String Arena & SwissTable lookup verified"

  # 4. Tree Move & Copy Semantics
  block:
    var tree1 = initTree(initialNodeCap = 64, initialArenaCap = 512)
    let (nOff, nLen) = tree1.internName("test_copy.txt")
    let idx = tree1.addNode(initNode(nameOffset = nOff, nameLen = nLen, size = 1234), frn = 999)
    doAssert tree1.len == 1
    doAssert tree1.getName(idx) == "test_copy.txt"

    # Copy
    var tree2 = tree1
    doAssert tree2.len == 1
    doAssert tree2.getName(0) == "test_copy.txt"
    doAssert tree2.frnMap.getOrDefault(999'u64, -1) == 0

    # Mutate tree2 without affecting tree1
    let (nOff2, nLen2) = tree2.internName("second_file.bin")
    discard tree2.addNode(initNode(nameOffset = nOff2, nameLen = nLen2, size = 5678))
    doAssert tree2.len == 2
    doAssert tree1.len == 1

    # Move (sink)
    var tree3 = move(tree2)
    doAssert tree3.len == 2
    doAssert tree3.getName(1) == "second_file.bin"
    doAssert tree2.len == 0
    echo "  [PASS] 4. Tree copy/move semantics and deep isolation verified"

  # 5. Reporting Types
  block:
    let top = TopItem(
      nodeIdx: 12,
      size: 10_000_000_000'i64,
      sizeOnDisk: 10_000_004_096'i64,
      childCount: 42,
      isDir: true
    )
    doAssert top.nodeIdx == 12
    doAssert top.isDir == true

    let ext = ExtensionStat(
      ext: ".mp4",
      fileCount: 150,
      totalBytes: 50_000_000_000'i64,
      totalBytesOnDisk: 50_000_100_000'i64,
      percentage: 25.5
    )
    doAssert ext.ext == ".mp4"
    doAssert ext.fileCount == 150
    echo "  [PASS] 5. Reporting Types verified"

  echo "=== All WizTree Types Verifications PASSED Successfully! ==="

when isMainModule:
  main()
