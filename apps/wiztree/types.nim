## src/wiztree/types.nim — Foundational Data Models and Contracts for WizTree Engine
##
## Defines the core memory layouts, containers, volume metadata, scan statistics,
## and API signatures for high-performance MFT/USN scanning, tree indexing,
## and terminal/JSON reporting.
##
## Architectural Invariants:
## 1. Node struct: Exactly 40-byte POD layout (8-byte aligned, 0 padding holes).
## 2. Zero-heap filename storage: All file names interned in Tree.stringArena.
## 3. High cache locality: Flat BufSeq[Node] buffer; 8-way sequential iteration.
## 4. FRN index resolution: O(1) SwissTable FastMap[uint64, int32].
## 5. Deterministic ARC/ORC lifecycle: Complete =destroy, =copy, =sink, =wasMoved hooks.

import corex/allocators
import corex/memory
import corex/containers
import corex/result
import algx/swissmap

# =============================================================================
# 1. Win32 Attribute Bitmasks & Node Flags
# =============================================================================

when defined(windows):
  import corex/platform/windows/win32_fs
  export
    win32_fs.FILE_ATTRIBUTE_READONLY,
    win32_fs.FILE_ATTRIBUTE_HIDDEN,
    win32_fs.FILE_ATTRIBUTE_SYSTEM,
    win32_fs.FILE_ATTRIBUTE_DIRECTORY,
    win32_fs.FILE_ATTRIBUTE_ARCHIVE,
    win32_fs.FILE_ATTRIBUTE_DEVICE,
    win32_fs.FILE_ATTRIBUTE_NORMAL,
    win32_fs.FILE_ATTRIBUTE_TEMPORARY,
    win32_fs.FILE_ATTRIBUTE_SPARSE_FILE,
    win32_fs.FILE_ATTRIBUTE_REPARSE_POINT,
    win32_fs.FILE_ATTRIBUTE_COMPRESSED,
    win32_fs.FILE_ATTRIBUTE_OFFLINE,
    win32_fs.FILE_ATTRIBUTE_NOT_CONTENT_INDEXED,
    win32_fs.FILE_ATTRIBUTE_ENCRYPTED
else:
  const
    FILE_ATTRIBUTE_READONLY*            = 0x00000001'u32
    FILE_ATTRIBUTE_HIDDEN*              = 0x00000002'u32
    FILE_ATTRIBUTE_SYSTEM*              = 0x00000004'u32
    FILE_ATTRIBUTE_DIRECTORY*           = 0x00000010'u32
    FILE_ATTRIBUTE_ARCHIVE*             = 0x00000020'u32
    FILE_ATTRIBUTE_DEVICE*              = 0x00000040'u32
    FILE_ATTRIBUTE_NORMAL*              = 0x00000080'u32
    FILE_ATTRIBUTE_TEMPORARY*           = 0x00000100'u32
    FILE_ATTRIBUTE_SPARSE_FILE*         = 0x00000200'u32
    FILE_ATTRIBUTE_REPARSE_POINT*       = 0x00000400'u32
    FILE_ATTRIBUTE_COMPRESSED*          = 0x00000800'u32
    FILE_ATTRIBUTE_OFFLINE*             = 0x00001000'u32
    FILE_ATTRIBUTE_NOT_CONTENT_INDEXED* = 0x00002000'u32
    FILE_ATTRIBUTE_ENCRYPTED*           = 0x00004000'u32

const
  # Node-specific status flags (16-bit bitmask)
  NODE_FLAG_NONE*       = 0x0000'u16
  NODE_FLAG_DIR*        = 0x0001'u16 ## Explicit directory marker
  NODE_FLAG_COMPRESSED* = 0x0002'u16 ## File is compressed
  NODE_FLAG_SPARSE*     = 0x0004'u16 ## File is sparse
  NODE_FLAG_SYMLINK*    = 0x0008'u16 ## Reparse point / junction / symlink
  NODE_FLAG_SCANNED*    = 0x0010'u16 ## Processed by volume scanner
  NODE_FLAG_AGGREGATED* = 0x0020'u16 ## Rollup sizes aggregated
  NODE_FLAG_ORPHAN*     = 0x0040'u16 ## Unresolved parent / pending hierarchy

# =============================================================================
# 2. Node POD Struct (40 Bytes, 8-Byte Aligned, Zero Padding)
# =============================================================================

type
  Node* = object
    size*: int64             ## 8 bytes [0..7]: Logical file or directory size in bytes
    sizeOnDisk*: int64       ## 8 bytes [8..15]: Physical allocated size on disk in bytes
    parentIdx*: int32        ## 4 bytes [16..19]: Index of parent in Tree.nodes (-1 for root/orphan)
    firstChild*: int32       ## 4 bytes [20..23]: Index of first child in Tree.nodes (-1 if empty)
    nextSibling*: int32      ## 4 bytes [24..27]: Index of next sibling in Tree.nodes (-1 if end of chain)
    nameOffset*: uint32      ## 4 bytes [28..31]: Byte offset in Tree.stringArena
    attributes*: uint32      ## 4 bytes [32..35]: Win32 file attribute bitmask (FILE_ATTRIBUTE_*)
    nameLen*: uint16         ## 2 bytes [36..37]: Length of filename in bytes (UTF-8)
    flags*: uint16           ## 2 bytes [38..39]: Node-specific flags (NODE_FLAG_*)

# Compile-time physical layout guarantees
static:
  doAssert sizeof(Node) == 40, "Node struct must be exactly 40 bytes"
  doAssert alignof(Node) == 8, "Node struct must be 8-byte aligned"
  doAssert offsetof(Node, size) == 0
  doAssert offsetof(Node, sizeOnDisk) == 8
  doAssert offsetof(Node, parentIdx) == 16
  doAssert offsetof(Node, firstChild) == 20
  doAssert offsetof(Node, nextSibling) == 24
  doAssert offsetof(Node, nameOffset) == 28
  doAssert offsetof(Node, attributes) == 32
  doAssert offsetof(Node, nameLen) == 36
  doAssert offsetof(Node, flags) == 38

# Inline Node Helper Functions

proc isDir*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if the node represents a directory.
  ((node.attributes and FILE_ATTRIBUTE_DIRECTORY) != 0) or ((node.flags and NODE_FLAG_DIR) != 0)

proc isFile*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if the node represents a standard file.
  not node.isDir

proc isCompressed*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if the file or directory has NTFS compression enabled.
  ((node.attributes and FILE_ATTRIBUTE_COMPRESSED) != 0) or ((node.flags and NODE_FLAG_COMPRESSED) != 0)

proc isSparse*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if the file is marked as sparse.
  ((node.attributes and FILE_ATTRIBUTE_SPARSE_FILE) != 0) or ((node.flags and NODE_FLAG_SPARSE) != 0)

proc isSymlink*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if the node is a reparse point (symlink, junction, mount point).
  ((node.attributes and FILE_ATTRIBUTE_REPARSE_POINT) != 0) or ((node.flags and NODE_FLAG_SYMLINK) != 0)

proc isReadOnly*(node: Node): bool {.inline, raises: [].} =
  (node.attributes and FILE_ATTRIBUTE_READONLY) != 0

proc isHidden*(node: Node): bool {.inline, raises: [].} =
  (node.attributes and FILE_ATTRIBUTE_HIDDEN) != 0

proc isSystem*(node: Node): bool {.inline, raises: [].} =
  (node.attributes and FILE_ATTRIBUTE_SYSTEM) != 0

proc hasChildren*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if this directory has at least one linked child.
  node.firstChild >= 0

proc hasParent*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if this node has a linked parent.
  node.parentIdx >= 0

proc hasNextSibling*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if this node has a sibling in its parent's child list.
  node.nextSibling >= 0

proc isOrphan*(node: Node): bool {.inline, raises: [].} =
  ## Returns true if this node has an unresolved parent.
  (node.flags and NODE_FLAG_ORPHAN) != 0 or (node.parentIdx < 0 and not node.isDir)

proc initNode*(
  nameOffset: uint32 = 0,
  nameLen: uint16 = 0,
  parentIdx: int32 = -1,
  size: int64 = 0,
  sizeOnDisk: int64 = 0,
  attributes: uint32 = 0,
  flags: uint16 = 0,
  firstChild: int32 = -1,
  nextSibling: int32 = -1
): Node {.inline, raises: [].} =
  ## Factory constructor for Node with default -1 linkage pointers.
  var f = flags
  if (attributes and FILE_ATTRIBUTE_DIRECTORY) != 0:
    f = f or NODE_FLAG_DIR
  if (attributes and FILE_ATTRIBUTE_COMPRESSED) != 0:
    f = f or NODE_FLAG_COMPRESSED
  if (attributes and FILE_ATTRIBUTE_SPARSE_FILE) != 0:
    f = f or NODE_FLAG_SPARSE
  if (attributes and FILE_ATTRIBUTE_REPARSE_POINT) != 0:
    f = f or NODE_FLAG_SYMLINK
  Node(
    size: size,
    sizeOnDisk: sizeOnDisk,
    parentIdx: parentIdx,
    firstChild: firstChild,
    nextSibling: nextSibling,
    nameOffset: nameOffset,
    attributes: attributes,
    nameLen: nameLen,
    flags: f
  )

# =============================================================================
# 3. Volume Metadata, Scan Statistics & Options
# =============================================================================

type
  ScanMode* = enum
    smMftDirect = "MFT Direct"   ## Direct USN / MFT kernel streaming (Elevated NTFS)
    smWin32Fast = "Win32 Fast"   ## Batched FindFirstFileExW traversal (Non-elevated / Fallback)

  SortCriterion* = enum
    scSize = "size"              ## Sort by logical size descending
    scSizeOnDisk = "disk"        ## Sort by allocated size on disk descending
    scItemCount = "count"        ## Sort by recursive child count descending

  OutputFormat* = enum
    ofTable = "table"            ## Human-readable ASCII/Unicode terminal table
    ofJson = "json"              ## High-performance streaming JSON export
    ofCsv = "csv"                ## Comma-separated values export

  VolumeMetadata* = object
    clusterSize*: int            ## Bytes per allocation cluster (e.g. 4096)
    sectorSize*: int             ## Physical sector size in bytes (e.g. 512 or 4096)
    totalBytes*: int64           ## Total capacity of the volume in bytes
    freeBytes*: int64            ## Available free space on volume in bytes
    fsType*: string              ## Filesystem identifier (e.g. "NTFS", "FAT32", "ReFS")
    volumeName*: string          ## Volume label / friendly name
    driveLetter*: string         ## Drive letter or root specifier (e.g. "C:", "D:\\")

  ScanStats* = object
    scannedFiles*: int64         ## Total count of individual file entries scanned
    scannedDirs*: int64          ## Total count of directory entries scanned
    totalBytes*: int64           ## Total logical bytes across all scanned items
    totalBytesOnDisk*: int64     ## Total physical allocation size on disk in bytes
    elapsedMs*: float64          ## Wall-clock duration of the scan in milliseconds
    throughputFilesPerSec*: float64 ## Scan throughput in items per second
    scanMode*: ScanMode          ## Which scanning strategy was executed

  ScanOptions* = object
    rootPath*: string            ## Target path or drive to scan (e.g. "C:\\", "D:", ".")
    scanModePreference*: ScanMode ## Requested scanning strategy
    computeSizeOnDisk*: bool     ## Query cluster geometry and physical allocations
    maxDepth*: int               ## Maximum traversal depth (-1 = unlimited)
    initialNodeCap*: int         ## Pre-allocated capacity for BufSeq[Node] (default: 65536)
    initialArenaCap*: int        ## Pre-allocated byte capacity for filename arena (default: 1MB)

proc usedBytes*(vol: VolumeMetadata): int64 {.inline, raises: [].} =
  ## Returns total used space on volume in bytes.
  max(0'i64, vol.totalBytes - vol.freeBytes)

proc usedPercentage*(vol: VolumeMetadata): float64 {.inline, raises: [].} =
  ## Returns volume space utilization percentage (0.0 to 100.0).
  if vol.totalBytes <= 0: 0.0
  else: (float64(vol.usedBytes) / float64(vol.totalBytes)) * 100.0

proc totalItems*(stats: ScanStats): int64 {.inline, raises: [].} =
  ## Returns aggregate count of files and directories scanned.
  stats.scannedFiles + stats.scannedDirs

proc defaultScanOptions*(rootPath: string = ""): ScanOptions {.inline, raises: [].} =
  ## Constructs default scanning options with MFT preference and 1MB arena.
  ScanOptions(
    rootPath: rootPath,
    scanModePreference: smMftDirect,
    computeSizeOnDisk: true,
    maxDepth: -1,
    initialNodeCap: 65536,
    initialArenaCap: 1024 * 1024 # 1 MB initial arena buffer
  )

proc calculateSizeOnDisk*(fileSize: int64, clusterSize: int): int64 {.inline, raises: [].} =
  ## Computes physical disk occupancy by rounding up to next cluster boundary.
  if fileSize <= 0 or clusterSize <= 0: return 0'i64
  let c = int64(clusterSize)
  (fileSize + c - 1) and not(c - 1)

# =============================================================================
# 4. Reporting & Aggregation Structures
# =============================================================================

type
  TopItem* = object
    nodeIdx*: int32              ## Index of item in Tree.nodes
    size*: int64                 ## Logical size in bytes (aggregated for dirs)
    sizeOnDisk*: int64           ## Physical size on disk in bytes
    childCount*: int32           ## Recursive file + folder count for directories
    isDir*: bool                 ## True for directory, false for file

  ExtensionStat* = object
    ext*: string                 ## Normalized lowercase file extension (e.g. ".zip", ".dll")
    fileCount*: int64            ## Total count of files with this extension
    totalBytes*: int64           ## Total logical bytes across all files with this extension
    totalBytesOnDisk*: int64     ## Total physical allocation on disk in bytes
    percentage*: float64         ## Percentage of scanned volume size (0.0 to 100.0)

  DirAggregate* = object
    totalFiles*: int64           ## Recursive file count under directory
    totalDirs*: int64            ## Recursive directory count under directory

# =============================================================================
# 5. Tree In-Memory Structure & Deterministic ARC/ORC Lifecycle
# =============================================================================

type
  Tree* = object
    nodes*: BufSeq[Node]            ## Contiguous cache-aligned buffer of nodes
    stringArena*: ArenaAllocator    ## Linear region storing raw UTF-8 filename bytes
    frnMap*: FastMap[uint64, int32] ## 64-bit FRN / 48-bit MFT index -> node index in nodes
    parentFrns*: seq[uint64]        ## Parent FRN for each node (parallel to nodes, used during USN linking)
    volume*: VolumeMetadata         ## Physical volume geometry and metadata
    rootIdx*: int32                 ## Root directory node index (-1 if unassigned)
    stats*: ScanStats               ## Execution metrics and scan throughput

proc `=destroy`*(tree: var Tree) {.raises: [].} =
  ## Deterministic RAII destruction for Tree: frees string arena and node buffer.
  tree.stringArena.deinit()
  `=destroy`(tree.nodes)
  # tree.frnMap and parentFrns are managed automatically by ARC/ORC

proc `=wasMoved`*(tree: var Tree) {.inline, raises: [].} =
  ## ARC/ORC move hook resets all internal handles to moved state.
  tree.stringArena = ArenaAllocator()
  `=wasMoved`(tree.nodes)
  tree.frnMap = FastMap[uint64, int32]()
  tree.parentFrns = @[]
  tree.rootIdx = -1

proc `=sink`*(dest: var Tree, src: Tree) {.raises: [].} =
  ## Move assignment operator transfers ownership without deep copies.
  if dest.stringArena.backing != src.stringArena.backing:
    `=destroy`(dest)
  dest.nodes = src.nodes
  dest.stringArena = src.stringArena
  dest.frnMap = src.frnMap
  dest.parentFrns = src.parentFrns
  dest.volume = src.volume
  dest.rootIdx = src.rootIdx
  dest.stats = src.stats

proc `=copy`*(dest: var Tree, src: Tree) {.raises: [].} =
  ## Deep copy hook for Tree duplicating node buffer, string arena, and map.
  if dest.stringArena.backing == src.stringArena.backing and not dest.stringArena.backing.isNil:
    return
  `=destroy`(dest)
  dest.volume = src.volume
  dest.rootIdx = src.rootIdx
  dest.stats = src.stats
  dest.frnMap = src.frnMap
  dest.parentFrns = src.parentFrns
  dest.nodes = src.nodes

  if src.stringArena.capacity > 0 and not src.stringArena.backing.isNil:
    dest.stringArena = initArena(src.stringArena.capacity)
    dest.stringArena.offset = src.stringArena.offset
    dest.stringArena.peakUsed = src.stringArena.peakUsed
    if src.stringArena.offset > 0:
      copyMem(dest.stringArena.backing, src.stringArena.backing, src.stringArena.offset)
  else:
    dest.stringArena = ArenaAllocator()

proc initTree*(
  initialNodeCap: int = 65536,
  initialArenaCap: int = 1024 * 1024,
  volume: VolumeMetadata = VolumeMetadata(),
  nodeAlloc: Allocator = defaultHeapAllocator()
): Tree {.raises: [].} =
  ## Initializes an empty Tree with pre-allocated node buffer and string arena.
  let cap = max(16, initialNodeCap)
  let arenaCap = max(4096, initialArenaCap)
  let nodesRes = initBufSeq[Node](nodeAlloc, cap)
  let nodesBuf = if nodesRes.isOk: nodesRes.get else: BufSeq[Node]()

  Tree(
    nodes: nodesBuf,
    stringArena: initArena(arenaCap),
    frnMap: initFastMap[uint64, int32](cap),
    parentFrns: newSeqOfCap[uint64](cap),
    volume: volume,
    rootIdx: -1,
    stats: ScanStats()
  )

proc deinit*(tree: var Tree) {.inline, raises: [].} =
  ## Explicitly releases all resources owned by the Tree.
  `=destroy`(tree)

# =============================================================================
# 6. Tree Operations: Indexing, Arenas, and String Resolution
# =============================================================================

proc len*(tree: Tree): int {.inline, raises: [].} =
  ## Number of nodes stored in the tree.
  tree.nodes.len

proc cap*(tree: Tree): int {.inline, raises: [].} =
  ## Pre-allocated node capacity in the tree buffer.
  tree.nodes.cap

proc isEmpty*(tree: Tree): bool {.inline, raises: [].} =
  tree.nodes.len == 0

proc `[]`*(tree: Tree, idx: int32): lent Node {.inline, raises: [].} =
  ## Read-only index access to node by index.
  tree.nodes[int(idx)]

proc `[]`*(tree: var Tree, idx: int32): var Node {.inline, raises: [].} =
  ## Mutable index access to node by index.
  tree.nodes[int(idx)]

proc root*(tree: Tree): lent Node {.inline, raises: [].} =
  ## Returns read-only reference to the root node.
  if unlikely(tree.rootIdx < 0 or tree.rootIdx >= tree.nodes.len):
    raise (ref IndexDefect)(msg: "Tree has no valid root node index")
  tree.nodes[int(tree.rootIdx)]

proc root*(tree: var Tree): var Node {.inline, raises: [].} =
  ## Returns mutable reference to the root node.
  if unlikely(tree.rootIdx < 0 or tree.rootIdx >= tree.nodes.len):
    raise (ref IndexDefect)(msg: "Tree has no valid root node index")
  tree.nodes[int(tree.rootIdx)]

proc ensureArenaCapacity*(tree: var Tree, extraBytes: int) {.raises: [].} =
  ## Ensures the linear string arena has room for `extraBytes` more bytes.
  let needed = tree.stringArena.offset + extraBytes
  if needed > tree.stringArena.capacity:
    var newCap = if tree.stringArena.capacity <= 0: 65536 else: tree.stringArena.capacity * 2
    while newCap < needed:
      newCap *= 2
    let newMem = allocShared0(newCap)
    if tree.stringArena.offset > 0 and not tree.stringArena.backing.isNil:
      copyMem(newMem, tree.stringArena.backing, tree.stringArena.offset)
      deallocShared(tree.stringArena.backing)
    tree.stringArena.backing = newMem
    tree.stringArena.capacity = newCap

proc internName*(tree: var Tree, name: openArray[char]): tuple[offset: uint32, len: uint16] {.raises: [].} =
  ## Stores a UTF-8 filename in the string arena with zero heap fragmentation.
  let nLen = name.len
  if nLen <= 0:
    return (0'u32, 0'u16)
  let clampedLen = min(nLen, int(high(uint16)))
  tree.ensureArenaCapacity(clampedLen)
  let offset = uint32(tree.stringArena.offset)
  let dst = cast[pointer](cast[uint](tree.stringArena.backing) + uint(offset))
  copyMem(dst, unsafeAddr name[0], clampedLen)
  tree.stringArena.offset += clampedLen
  if tree.stringArena.offset > tree.stringArena.peakUsed:
    tree.stringArena.peakUsed = tree.stringArena.offset
  (offset, uint16(clampedLen))

proc internName*(tree: var Tree, name: string): tuple[offset: uint32, len: uint16] {.inline, raises: [].} =
  ## String overload for internName.
  if name.len == 0: (0'u32, 0'u16)
  else: tree.internName(name.toOpenArray(0, name.len - 1))

proc getNameByteSpan*(tree: Tree, node: Node): ByteSpan {.inline, raises: [].} =
  ## Zero-copy non-owning slice viewing the node's filename in the arena.
  if node.nameLen == 0 or tree.stringArena.backing.isNil:
    ByteSpan(data: nil, len: 0)
  else:
    let p = cast[ptr UncheckedArray[byte]](cast[uint](tree.stringArena.backing) + uint(node.nameOffset))
    ByteSpan(data: p, len: int(node.nameLen))

proc getName*(tree: Tree, node: Node): string {.inline, raises: [].} =
  ## Allocates and returns a standard string copy of the node's filename.
  if node.nameLen == 0 or tree.stringArena.backing.isNil:
    return ""
  result = newString(int(node.nameLen))
  let p = cast[pointer](cast[uint](tree.stringArena.backing) + uint(node.nameOffset))
  copyMem(addr result[0], p, int(node.nameLen))

proc getName*(tree: Tree, nodeIdx: int32): string {.inline, raises: [].} =
  ## Returns the filename string of the node at index `nodeIdx`.
  if nodeIdx < 0 or nodeIdx >= tree.nodes.len:
    return ""
  tree.getName(tree.nodes[int(nodeIdx)])

proc addNode*(tree: var Tree, node: sink Node, frn: uint64 = 0, parentFrn: uint64 = 0): int32 {.raises: [].} =
  ## Appends a new Node into the tree buffer and records its FRN and parentFRN.
  ## Returns the assigned node index in tree.nodes.
  let idx = int32(tree.nodes.len)
  tree.nodes.add(node)
  if frn != 0:
    tree.frnMap.put(frn, idx)
  tree.parentFrns.add(parentFrn)
  result = idx

proc clearParentFrns*(tree: var Tree) {.inline, raises: [].} =
  ## Releases temporary parent FRN tracking memory once hierarchy linking completes.
  tree.parentFrns = @[]

iterator children*(tree: Tree, parentIdx: int32): int32 =
  ## Iterates over all direct child node indices of parentIdx.
  if parentIdx >= 0 and parentIdx < tree.nodes.len:
    var cur = tree.nodes[int(parentIdx)].firstChild
    while cur >= 0 and cur < tree.nodes.len:
      yield cur
      cur = tree.nodes[int(cur)].nextSibling

# =============================================================================
# 7. Core Subsystem Signatures & Contracts
# =============================================================================
#
# These procedural signatures specify the contracts between modules:
# - src/wiztree/scanner.nim (owned by @mft_scanner)
# - src/wiztree/tree.nim (owned by @indexer)
# - src/wiztree/cli.nim & src/wiztree.nim (owned by @reporter)

type
  ScanVolumeFn* = proc(options: ScanOptions): Result[Tree, string] {.nimcall.}
    ## Contract for main scanner entry point in scanner.nim

  ScanMftDirectFn* = proc(drivePath: string, tree: var Tree, options: ScanOptions): Result[ScanStats, string] {.nimcall.}
    ## Direct NTFS MFT enumeration path via FSCTL_ENUM_USN_DATA

  ScanWin32FastFn* = proc(rootPath: string, tree: var Tree, options: ScanOptions): Result[ScanStats, string] {.nimcall.}
    ## Fast FindFirstFileExW traversal fallback path

  LinkHierarchyFn* = proc(tree: var Tree) {.nimcall.}
    ## Links child/sibling relationships and resolves FRN parent links

  CalculateSizesFn* = proc(tree: var Tree) {.nimcall.}
    ## Non-recursive bottom-up size and count aggregation

  GetFullPathFn* = proc(tree: Tree, nodeIdx: int32): string {.nimcall.}
    ## Dynamic path reconstruction by walking parent pointers up to root

  GetTopItemsFn* = proc(tree: Tree, count: int, criterion: SortCriterion): seq[TopItem] {.nimcall.}
    ## Top-K item selection using algx/ultrasort

  GetExtensionStatsFn* = proc(tree: Tree): seq[ExtensionStat] {.nimcall.}
    ## Aggregates file count and byte footprint grouped by extension
