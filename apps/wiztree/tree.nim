## src/wiztree/tree.nim — High-Throughput In-Memory File Tree Structures and Operations
##
## Implements:
## 1. Tree Lifecycle & Node Insertion: Arena-based filename interning, POD node insertion.
## 2. FRN Resolution: 64-bit FRN / 48-bit MFT index to NodeId lookup via SwissTable FastMap.
## 3. Sibling & Child Linking: O(N) backward pass establishing parent-child hierarchy.
## 4. Directory Size Aggregation (calculateSizes): Non-recursive bottom-up roll-up of logical size,
##    physical size-on-disk, file counts, and directory counts without stack recursion.
## 5. Dynamic Path Reconstruction (getFullPath): O(depth) on-the-fly path building from parent pointers.
## 6. Top-K Sorting: Sub-millisecond sorting of largest files and folders utilizing algx/ultrasort.
## 7. Extension Statistics: File count and byte footprint grouped by normalized extension.

import std/algorithm
import corex/allocators
import corex/memory
import corex/containers
import algx/swissmap
import algx/ultrasort
import ./types

export types

# =============================================================================
# 1. Tree Lifecycle & Factory Helpers
# =============================================================================

proc createTree*(
  initialNodeCap: int = 65536,
  initialArenaCap: int = 1024 * 1024,
  volume: VolumeMetadata = VolumeMetadata()
): Tree {.inline, raises: [].} =
  ## Creates an initialized Tree with pre-allocated node buffer and string arena.
  initTree(initialNodeCap, initialArenaCap, volume)

proc setRoot*(tree: var Tree, rootIdx: int32) {.inline, raises: [].} =
  ## Explicitly designates the root node index in the tree.
  tree.rootIdx = rootIdx

proc addFile*(
  tree: var Tree,
  parentIdx: int32,
  name: string,
  size: int64,
  sizeOnDisk: int64 = 0,
  attributes: uint32 = 0,
  frn: uint64 = 0,
  parentFrn: uint64 = 0
): int32 {.raises: [].} =
  ## Appends a file node into the tree, interning its name in the string arena.
  ## Computes size on disk using volume cluster geometry if omitted.
  let (offset, nLen) = tree.internName(name)
  let sod = if sizeOnDisk > 0: sizeOnDisk
            elif tree.volume.clusterSize > 0: calculateSizeOnDisk(size, tree.volume.clusterSize)
            else: size
  var attrs = attributes
  if attrs == 0:
    attrs = FILE_ATTRIBUTE_NORMAL
  let node = initNode(
    nameOffset = offset,
    nameLen = nLen,
    parentIdx = parentIdx,
    size = size,
    sizeOnDisk = sod,
    attributes = attrs
  )
  result = tree.addNode(node, frn, parentFrn)

proc addDirectory*(
  tree: var Tree,
  parentIdx: int32,
  name: string,
  attributes: uint32 = FILE_ATTRIBUTE_DIRECTORY,
  frn: uint64 = 0,
  parentFrn: uint64 = 0
): int32 {.raises: [].} =
  ## Appends a directory node into the tree, interning its name in the string arena.
  let (offset, nLen) = tree.internName(name)
  let attrs = attributes or FILE_ATTRIBUTE_DIRECTORY
  let node = initNode(
    nameOffset = offset,
    nameLen = nLen,
    parentIdx = parentIdx,
    size = 0,
    sizeOnDisk = 0,
    attributes = attrs,
    flags = NODE_FLAG_DIR
  )
  result = tree.addNode(node, frn, parentFrn)

# =============================================================================
# 2. FRN Resolution & Fast Registration
# =============================================================================

proc registerFrn*(tree: var Tree, frn: uint64, nodeIdx: int32) {.inline, raises: [].} =
  ## Registers both full 64-bit FRN and masked 48-bit MFT record number into frnMap.
  if frn == 0: return
  tree.frnMap.put(frn, nodeIdx)
  let mftIndex = frn and 0x0000FFFFFFFFFFFF'u64
  if mftIndex != frn:
    tree.frnMap.put(mftIndex, nodeIdx)

proc resolveFrn*(tree: Tree, frn: uint64): int32 {.inline, raises: [].} =
  ## Fast O(1) lookup from 64-bit FRN or 48-bit MFT index to node index in tree.nodes.
  ## Returns -1 if unmapped.
  if frn == 0: return -1'i32
  let direct = tree.frnMap.getOrDefault(frn, -1'i32)
  if direct >= 0:
    return direct
  let mftIndex = frn and 0x0000FFFFFFFFFFFF'u64
  if mftIndex != frn:
    return tree.frnMap.getOrDefault(mftIndex, -1'i32)
  return -1'i32

# =============================================================================
# 3. Sibling & Child Hierarchy Linking
# =============================================================================

proc linkHierarchy*(tree: var Tree) {.raises: [].} =
  ## Resolves parent FRN linkages and builds full firstChild / nextSibling hierarchies
  ## across all nodes in O(N) time with zero secondary heap allocations.
  let n = tree.nodes.len
  if n == 0: return

  # Phase 1: Resolve pending parent FRNs
  let pFrnLen = tree.parentFrns.len
  for i in 0 ..< n:
    if tree.nodes[i].parentIdx < 0 and i < pFrnLen:
      let pFrn = tree.parentFrns[i]
      if pFrn != 0:
        let resolved = tree.resolveFrn(pFrn)
        if resolved >= 0 and resolved != int32(i):
          tree.nodes[i].parentIdx = resolved
        elif resolved < 0:
          tree.nodes[i].flags = tree.nodes[i].flags or NODE_FLAG_ORPHAN

  # Phase 2: Identify root node if unassigned
  if tree.rootIdx < 0:
    # Check standard NTFS root MFT record 5
    let mft5 = tree.resolveFrn(5'u64)
    if mft5 >= 0 and mft5 < int32(n):
      tree.rootIdx = mft5
    else:
      # Find first directory node with parentIdx < 0 that is not marked orphan
      for i in 0 ..< n:
        if tree.nodes[i].isDir and tree.nodes[i].parentIdx < 0 and (tree.nodes[i].flags and NODE_FLAG_ORPHAN) == 0:
          tree.rootIdx = int32(i)
          break
      # Fallback to index 0 if valid directory
      if tree.rootIdx < 0 and tree.nodes[0].isDir:
        tree.rootIdx = 0'i32

  # Phase 3: Clear existing child and sibling links
  for i in 0 ..< n:
    tree.nodes[i].firstChild = -1'i32
    tree.nodes[i].nextSibling = -1'i32

  # Phase 4: Backward pass linking children to preserve insertion order (FIFO)
  for i in countdown(n - 1, 0):
    let p = tree.nodes[i].parentIdx
    if p >= 0 and p < int32(n) and p != int32(i):
      tree.nodes[i].nextSibling = tree.nodes[p].firstChild
      tree.nodes[p].firstChild = int32(i)

  # Phase 5: Reclaim temporary parent FRN tracking slice
  tree.clearParentFrns()

proc linkHierarchy*(tree: var Tree, parentFrns: openArray[uint64]) {.raises: [].} =
  ## Overload accepting external parent FRN array (e.g. from custom scanner feeds).
  tree.parentFrns = @parentFrns
  tree.linkHierarchy()

# =============================================================================
# 4. Directory Size Aggregation (Non-Recursive Bottom-Up Rollup)
# =============================================================================

proc calculateSizes*(tree: var Tree) {.raises: [].} =
  ## Computes bottom-up directory aggregation for logical size and size-on-disk.
  ## Implements non-recursive Kahn's topological sort (out-degree based), guaranteeing
  ## zero call stack overflow even for trees with 10,000+ depth levels.
  let n = tree.nodes.len
  if n == 0: return

  # Step 1: Reset directory sizes and ensure cluster-rounded file sizes on disk
  let clusterSize = tree.volume.clusterSize
  for i in 0 ..< n:
    if tree.nodes[i].isDir:
      tree.nodes[i].size = 0'i64
      tree.nodes[i].sizeOnDisk = 0'i64
    else:
      if tree.nodes[i].sizeOnDisk == 0 and tree.nodes[i].size > 0 and clusterSize > 0:
        tree.nodes[i].sizeOnDisk = calculateSizeOnDisk(tree.nodes[i].size, clusterSize)

  # Step 2: Compute out-degrees (number of children pointing to each parent)
  var outDegree = newSeq[int32](n)
  for i in 0 ..< n:
    let p = tree.nodes[i].parentIdx
    if p >= 0 and p < int32(n) and p != int32(i):
      inc(outDegree[p])

  # Step 3: Enqueue all leaves (files and empty directories with out-degree 0)
  var queue = newSeqOfCap[int32](n)
  for i in 0 ..< n:
    if outDegree[i] == 0:
      queue.add(int32(i))

  # Step 4: Bottom-up topological rollup
  var head = 0
  while head < queue.len:
    let u = queue[head]
    inc(head)
    let p = tree.nodes[u].parentIdx
    if p >= 0 and p < int32(n) and p != u:
      tree.nodes[p].size += tree.nodes[u].size
      tree.nodes[p].sizeOnDisk += tree.nodes[u].sizeOnDisk
      dec(outDegree[p])
      if outDegree[p] == 0:
        queue.add(p)

  # Step 5: Cycle detection & decoupling
  if queue.len < n:
    for i in 0 ..< n:
      if outDegree[i] > 0:
        tree.nodes[i].parentIdx = -1'i32
        tree.nodes[i].flags = tree.nodes[i].flags or NODE_FLAG_ORPHAN

  # Step 6: Rollup global scan statistics
  var totalFiles = 0'i64
  var totalDirs = 0'i64
  var totalBytes = 0'i64
  var totalBytesOnDisk = 0'i64

  for i in 0 ..< n:
    if tree.nodes[i].isDir:
      inc(totalDirs)
      tree.nodes[i].flags = tree.nodes[i].flags or NODE_FLAG_AGGREGATED
    else:
      inc(totalFiles)
      totalBytes += tree.nodes[i].size
      totalBytesOnDisk += tree.nodes[i].sizeOnDisk

  tree.stats.scannedFiles = totalFiles
  tree.stats.scannedDirs = totalDirs
  tree.stats.totalBytes = totalBytes
  tree.stats.totalBytesOnDisk = totalBytesOnDisk

proc calculateAggregates*(tree: Tree): seq[DirAggregate] {.raises: [].} =
  ## Computes recursive file count and directory count for all nodes in O(N).
  let n = tree.nodes.len
  result = newSeq[DirAggregate](n)
  if n == 0: return

  var outDegree = newSeq[int32](n)
  for i in 0 ..< n:
    let p = tree.nodes[i].parentIdx
    if p >= 0 and p < int32(n) and p != int32(i):
      inc(outDegree[p])

  var queue = newSeqOfCap[int32](n)
  for i in 0 ..< n:
    if outDegree[i] == 0:
      queue.add(int32(i))

  var head = 0
  while head < queue.len:
    let u = queue[head]
    inc(head)
    let p = tree.nodes[u].parentIdx
    if p >= 0 and p < int32(n) and p != u:
      if tree.nodes[u].isDir:
        result[p].totalDirs += result[u].totalDirs + 1
        result[p].totalFiles += result[u].totalFiles
      else:
        result[p].totalFiles += 1
      dec(outDegree[p])
      if outDegree[p] == 0:
        queue.add(p)

proc getDirAggregate*(tree: Tree, nodeIdx: int32): DirAggregate {.raises: [].} =
  ## Returns the recursive file and directory count under `nodeIdx`.
  if nodeIdx < 0 or nodeIdx >= tree.nodes.len:
    return DirAggregate()
  let aggs = tree.calculateAggregates()
  aggs[nodeIdx]

# =============================================================================
# 5. Dynamic Path Reconstruction
# =============================================================================

proc getFullPath*(tree: Tree, nodeIdx: int32): string {.raises: [].} =
  ## Reconstructs the complete hierarchical filesystem path for `nodeIdx` on the fly
  ## by traversing parent pointers. Avoids storing redundant path strings.
  if nodeIdx < 0 or nodeIdx >= tree.nodes.len:
    return ""

  var chain = newSeqOfCap[int32](32)
  var cur = nodeIdx
  var steps = 0
  let maxSteps = tree.nodes.len

  while cur >= 0 and cur < tree.nodes.len and steps < maxSteps:
    chain.add(cur)
    inc(steps)
    let p = tree.nodes[cur].parentIdx
    if p < 0 or p == cur:
      break
    cur = p

  if chain.len == 0:
    return ""

  var parts = newSeqOfCap[string](chain.len)
  for i in countdown(chain.len - 1, 0):
    let idx = chain[i]
    var name = tree.getName(idx)
    # Root node formatting override
    if idx == tree.rootIdx and (name.len == 0 or name == "\\" or name == "/"):
      if tree.volume.driveLetter.len > 0:
        name = tree.volume.driveLetter
    if name.len > 0:
      parts.add(name)

  if parts.len == 0:
    return ""

  var res = parts[0]
  for i in 1 ..< parts.len:
    let part = parts[i]
    if res.len > 0 and res[res.len - 1] != '\\' and res[res.len - 1] != '/':
      res.add('\\')
    res.add(part)
  return res

# =============================================================================
# 6. Top-K Sorting (Utilizing algx/ultrasort)
# =============================================================================

type
  SortCandidate = object
    nodeIdx: int32
    key: int64
    size: int64
    sizeOnDisk: int64
    childCount: int32
    isDir: bool

proc siftDown(heap: var openArray[SortCandidate], startIdx, count: int) {.inline, raises: [].} =
  var root = startIdx
  while true:
    var child = 2 * root + 1
    if child >= count: break
    if child + 1 < count:
      if heap[child + 1].key < heap[child].key or
         (heap[child + 1].key == heap[child].key and heap[child + 1].nodeIdx > heap[child].nodeIdx):
        inc child
    if heap[child].key < heap[root].key or
       (heap[child].key == heap[root].key and heap[child].nodeIdx > heap[root].nodeIdx):
      swap(heap[root], heap[child])
      root = child
    else:
      break

proc siftUp(heap: var openArray[SortCandidate], startIdx: int) {.inline, raises: [].} =
  var child = startIdx
  while child > 0:
    let parent = (child - 1) shr 1
    if heap[child].key < heap[parent].key or
       (heap[child].key == heap[parent].key and heap[child].nodeIdx > heap[parent].nodeIdx):
      swap(heap[parent], heap[child])
      child = parent
    else:
      break

proc pushMinHeap(heap: var seq[SortCandidate], cand: SortCandidate, maxK: int) {.inline, raises: [].} =
  if heap.len < maxK:
    heap.add(cand)
    siftUp(heap, heap.len - 1)
  elif cand.key > heap[0].key or (cand.key == heap[0].key and cand.nodeIdx < heap[0].nodeIdx):
    heap[0] = cand
    siftDown(heap, 0, heap.len)

proc sortCandidatesDesc(candidates: var seq[SortCandidate]) {.raises: [].} =
  ## Sorts candidates descending by key, breaking ties with nodeIdx ascending.
  candidates.sort(proc(a, b: SortCandidate): int =
    let c = cmp(b.key, a.key)
    if c != 0: c
    else: cmp(a.nodeIdx, b.nodeIdx)
  )

proc sortTopCandidates(candidates: var seq[SortCandidate]) {.raises: [].} =
  ## Sorts top K candidates descending. For small K (e.g. <= 64), uses insertion/tim sort.
  ## For large K, utilizes algx/ultrasort for cache-aware partitioned sorting.
  if candidates.len <= 64:
    sortCandidatesDesc(candidates)
  else:
    var keys = newSeq[int64](candidates.len)
    var aux = newSeq[int64](candidates.len)
    for i in 0 ..< candidates.len:
      let localIdx = int64(i and 0xFFFF)
      keys[i] = (candidates[i].key shl 16) or localIdx
    try:
      discard ultraSort(keys, aux)
    except CatchableError:
      keys.sort(system.cmp)
    var sorted = newSeqOfCap[SortCandidate](candidates.len)
    for i in countdown(keys.len - 1, 0):
      let origIdx = int(keys[i] and 0xFFFF'i64)
      sorted.add(candidates[origIdx])
    candidates = move(sorted)

proc getTopFiles*(
  tree: Tree,
  count: int = 20,
  criterion: SortCriterion = scSize
): seq[TopItem] {.raises: [].} =
  ## Returns the top `count` largest files sorted descending by `criterion`.
  ## Uses an inline streaming min-heap of size K for O(N log K) selection with zero
  ## secondary heap bloat, then sorts the top K candidates using algx/ultrasort.
  if tree.nodes.len == 0 or count <= 0:
    return @[]

  var heap = newSeqOfCap[SortCandidate](count)
  for i in 0 ..< tree.nodes.len:
    if tree.nodes[i].isFile:
      let k = case criterion
              of scSize: tree.nodes[i].size
              of scSizeOnDisk: tree.nodes[i].sizeOnDisk
              of scItemCount: 0'i64
      pushMinHeap(heap, SortCandidate(
        nodeIdx: int32(i),
        key: k,
        size: tree.nodes[i].size,
        sizeOnDisk: tree.nodes[i].sizeOnDisk,
        childCount: 0'i32,
        isDir: false
      ), count)

  if heap.len == 0:
    return @[]

  sortTopCandidates(heap)

  result = newSeqOfCap[TopItem](heap.len)
  for i in 0 ..< heap.len:
    result.add(TopItem(
      nodeIdx: heap[i].nodeIdx,
      size: heap[i].size,
      sizeOnDisk: heap[i].sizeOnDisk,
      childCount: 0'i32,
      isDir: false
    ))

proc getTopFolders*(
  tree: Tree,
  count: int = 20,
  criterion: SortCriterion = scSize,
  includeRoot: bool = true
): seq[TopItem] {.raises: [].} =
  ## Returns the top `count` largest folders sorted descending by `criterion`.
  ## Populates recursive child counts for each folder via streaming min-heap.
  if tree.nodes.len == 0 or count <= 0:
    return @[]

  let aggs = tree.calculateAggregates()
  var heap = newSeqOfCap[SortCandidate](count)

  for i in 0 ..< tree.nodes.len:
    if tree.nodes[i].isDir:
      if not includeRoot and int32(i) == tree.rootIdx:
        continue
      let totalChildren = int32(aggs[i].totalFiles + aggs[i].totalDirs)
      let k = case criterion
              of scSize: tree.nodes[i].size
              of scSizeOnDisk: tree.nodes[i].sizeOnDisk
              of scItemCount: int64(totalChildren)
      pushMinHeap(heap, SortCandidate(
        nodeIdx: int32(i),
        key: k,
        size: tree.nodes[i].size,
        sizeOnDisk: tree.nodes[i].sizeOnDisk,
        childCount: totalChildren,
        isDir: true
      ), count)

  if heap.len == 0:
    return @[]

  sortTopCandidates(heap)

  result = newSeqOfCap[TopItem](heap.len)
  for i in 0 ..< heap.len:
    result.add(TopItem(
      nodeIdx: heap[i].nodeIdx,
      size: heap[i].size,
      sizeOnDisk: heap[i].sizeOnDisk,
      childCount: heap[i].childCount,
      isDir: true
    ))

proc getTopItems*(
  tree: Tree,
  count: int = 20,
  criterion: SortCriterion = scSize
): seq[TopItem] {.raises: [].} =
  ## Returns top `count` items across both files and folders sorted by `criterion`.
  ## Conforms to GetTopItemsFn contract from types.nim.
  if tree.nodes.len == 0 or count <= 0:
    return @[]

  let aggs = tree.calculateAggregates()
  var heap = newSeqOfCap[SortCandidate](count)

  for i in 0 ..< tree.nodes.len:
    let isDirectory = tree.nodes[i].isDir
    let childCount = if isDirectory: int32(aggs[i].totalFiles + aggs[i].totalDirs) else: 0'i32
    let k = case criterion
            of scSize: tree.nodes[i].size
            of scSizeOnDisk: tree.nodes[i].sizeOnDisk
            of scItemCount: int64(childCount)
    pushMinHeap(heap, SortCandidate(
      nodeIdx: int32(i),
      key: k,
      size: tree.nodes[i].size,
      sizeOnDisk: tree.nodes[i].sizeOnDisk,
      childCount: childCount,
      isDir: isDirectory
    ), count)

  if heap.len == 0:
    return @[]

  sortTopCandidates(heap)

  result = newSeqOfCap[TopItem](heap.len)
  for i in 0 ..< heap.len:
    result.add(TopItem(
      nodeIdx: heap[i].nodeIdx,
      size: heap[i].size,
      sizeOnDisk: heap[i].sizeOnDisk,
      childCount: heap[i].childCount,
      isDir: heap[i].isDir
    ))

# =============================================================================
# 7. File Extension Statistics
# =============================================================================

proc extractExt*(filename: string): string {.inline, raises: [].} =
  ## Extracts normalized lowercase file extension including dot (e.g. ".zip").
  ## Returns empty string for filenames without an extension.
  if filename.len == 0:
    return ""
  var dotPos = -1
  for i in countdown(filename.len - 1, 0):
    let c = filename[i]
    if c == '.':
      dotPos = i
      break
    elif c == '\\' or c == '/':
      break
  if dotPos < 0:
    return ""
  var res = newString(filename.len - dotPos)
  for i in dotPos ..< filename.len:
    let c = filename[i]
    res[i - dotPos] = if c in {'A'..'Z'}: chr(ord(c) + 32) else: c
  return res

proc getExtensionStats*(tree: Tree): seq[ExtensionStat] {.raises: [].} =
  ## Aggregates total file count, logical bytes, and physical size on disk
  ## grouped by lowercase file extension. Returns list sorted by totalBytes descending.
  if tree.nodes.len == 0:
    return @[]

  var extMap = initFastMap[string, int](256)
  var stats: seq[ExtensionStat] = @[]

  for i in 0 ..< tree.nodes.len:
    if tree.nodes[i].isFile:
      let name = tree.getName(int32(i))
      let ext = extractExt(name)
      let idx = extMap.getOrDefault(ext, -1)
      if idx >= 0:
        inc(stats[idx].fileCount)
        stats[idx].totalBytes += tree.nodes[i].size
        stats[idx].totalBytesOnDisk += tree.nodes[i].sizeOnDisk
      else:
        let newIdx = stats.len
        extMap.put(ext, newIdx)
        stats.add(ExtensionStat(
          ext: ext,
          fileCount: 1,
          totalBytes: tree.nodes[i].size,
          totalBytesOnDisk: tree.nodes[i].sizeOnDisk,
          percentage: 0.0
        ))

  # Compute percentage of total scanned volume size
  var totalScanned = tree.stats.totalBytes
  if totalScanned <= 0:
    for s in stats:
      totalScanned += s.totalBytes

  for i in 0 ..< stats.len:
    if totalScanned > 0:
      stats[i].percentage = (float64(stats[i].totalBytes) / float64(totalScanned)) * 100.0
    else:
      stats[i].percentage = 0.0

  # Sort by totalBytes descending, breaking ties with fileCount
  stats.sort(proc(a, b: ExtensionStat): int =
    let c = cmp(b.totalBytes, a.totalBytes)
    if c != 0: c
    else: cmp(b.fileCount, a.fileCount)
  )

  result = stats
