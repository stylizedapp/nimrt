## apps/everything/src/indexer — In-Memory High-Speed USN Journal File Indexer
##
## Backs the Everything-style instant search engine:
## - Indexed via `BufMap[uint64, SlabId]` (64-bit FRN -> SlabId).
## - Node storage in `Slab[FileNode]` for O(1) removals and stable identity.
## - String deduplication through `StringInterner` (32-bit InternedStr).
## - Fast hierarchical path resolution from leaf FRN up to NTFS Root (FRN 5).
## - Binary serialization & deserialization to/from compact %TEMP%\everything.idx.

import std/os
import corex
import corex/platform/windows/win32_fs

const
  IndexMagic*: array[8, char] = ['E', 'V', 'I', 'D', 'X', '0', '1', '\0']
  IndexVersion*: uint32 = 1'u32

type
  FileNode* = object
    name*: InternedStr
    parentFrn*: uint64
    frn*: uint64
    isDir*: bool
    size*: int64
    sizeOnDisk*: int64
    attributes*: uint32

  DiskNode = object
    frn: uint64
    parentFrn: uint64
    nameId: int32
    isDir: uint8
    pad: array[3, byte]
    size: int64
    sizeOnDisk: int64
    attributes: uint32

  Indexer* = object
    nodes*: BufMap[uint64, SlabId]
    slab*: Slab[FileNode]
    names*: StringInterner
    alloc*: Allocator
    clusterSize*: int
    lastUsn*: int64
    driveLetter*: char

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*(idx: var Indexer) {.raises: [].} =
  `=destroy`(idx.nodes)
  `=destroy`(idx.slab)
  `=destroy`(idx.names)
  idx.clusterSize = 0
  idx.lastUsn = 0
  idx.driveLetter = 'C'

proc `=wasMoved`*(idx: var Indexer) {.inline, raises: [].} =
  `=wasMoved`(idx.nodes)
  `=wasMoved`(idx.slab)
  `=wasMoved`(idx.names)
  idx.clusterSize = 0
  idx.lastUsn = 0
  idx.driveLetter = 'C'

proc `=sink`*(dest: var Indexer, src: Indexer) {.raises: [].} =
  if cast[pointer](unsafeAddr dest) != cast[pointer](unsafeAddr src):
    `=destroy`(dest)
    copyMem(addr dest, unsafeAddr src, sizeof(Indexer))
    let pSrc = cast[ptr Indexer](unsafeAddr src)
    `=wasMoved`(pSrc[])

# =============================================================================
# Construction & Operations
# =============================================================================

proc newIndexer*(
  alloc: Allocator,
  clusterSize: int = 4096,
  driveLetter: char = 'C',
  initialCap: int = 256
): Result[Indexer, AllocError] {.raises: [].} =
  let cap = max(16, initialCap)
  let nodes = ?initBufMap[uint64, SlabId](alloc, cap)
  let slab = ?initSlab[FileNode](alloc, cap)
  let names = ?initStringInterner(alloc, cap)
  ok[Indexer, AllocError](Indexer(
    nodes: nodes,
    slab: slab,
    names: names,
    alloc: alloc,
    clusterSize: clusterSize,
    lastUsn: 0'i64,
    driveLetter: driveLetter
  ))

proc deinit*(idx: var Indexer) {.inline, raises: [].} =
  `=destroy`(idx)

proc len*(idx: Indexer): int {.inline, raises: [].} =
  idx.slab.len

proc removeNode*(idx: var Indexer, frn: uint64): bool {.raises: [].} =
  let opt = idx.nodes.get(frn)
  if opt.isNone:
    return false
  let slabId = opt.get
  discard idx.slab.remove(slabId)
  discard idx.nodes.del(frn)
  true

proc deleteNode*(idx: var Indexer, frn: uint64): bool {.inline, raises: [].} =
  idx.removeNode(frn)

proc removeNode*(idx: var Indexer, id: SlabId): bool {.raises: [].} =
  if not idx.slab.contains(id):
    return false
  let frn = idx.slab[id].frn
  discard idx.slab.remove(id)
  discard idx.nodes.del(frn)
  true

proc updateNode*(
  idx: var Indexer,
  frn: uint64,
  name: string,
  parentFrn: uint64,
  isDir: bool,
  size: int64 = 0,
  attributes: uint32 = 0
): Result[bool, AllocError] {.raises: [].} =
  let opt = idx.nodes.get(frn)
  if opt.isNone:
    return ok[bool, AllocError](false)
  let slabId = opt.get
  let interned = ?idx.names.internString(name)
  idx.slab[slabId].name = interned
  idx.slab[slabId].parentFrn = parentFrn
  idx.slab[slabId].isDir = isDir
  idx.slab[slabId].size = size
  idx.slab[slabId].sizeOnDisk = calculateSizeOnDisk(size, idx.clusterSize)
  idx.slab[slabId].attributes = attributes
  ok[bool, AllocError](true)

proc insertOrUpdate*(
  idx: var Indexer,
  frn: uint64,
  parentFrn: uint64,
  name: string,
  isDir: bool,
  size: int64 = 0,
  attributes: uint32 = 0
): Result[SlabId, AllocError] {.raises: [].} =
  let interned = ?idx.names.internString(name)
  let opt = idx.nodes.get(frn)
  if opt.isSome:
    let slabId = opt.get
    idx.slab[slabId].name = interned
    idx.slab[slabId].parentFrn = parentFrn
    idx.slab[slabId].isDir = isDir
    idx.slab[slabId].size = size
    idx.slab[slabId].sizeOnDisk = calculateSizeOnDisk(size, idx.clusterSize)
    idx.slab[slabId].attributes = attributes
    return ok[SlabId, AllocError](slabId)

  let node = FileNode(
    name: interned,
    parentFrn: parentFrn,
    frn: frn,
    isDir: isDir,
    size: size,
    sizeOnDisk: calculateSizeOnDisk(size, idx.clusterSize),
    attributes: attributes
  )
  let slabId = ?idx.slab.insert(node)
  ?idx.nodes.put(frn, slabId)
  ok[SlabId, AllocError](slabId)

proc insertFromUsn*(idx: var Indexer, rec: UsnRecordView): Result[void, AllocError] {.raises: [].} =
  let frn = rec.fileReferenceNumber
  idx.lastUsn = max(idx.lastUsn, rec.usn)
  if (rec.reason and USN_REASON_FILE_DELETE) != 0:
    discard idx.removeNode(frn)
    return ok(void, AllocError)

  let nameStr = rec.fileName()
  let internedName = ?idx.names.internString(nameStr)
  let isDir = (rec.fileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0
  let parentFrn = rec.parentFileReferenceNumber

  let existingOpt = idx.nodes.get(frn)
  if existingOpt.isSome:
    # Existing record (e.g., rename or attribute update) -> update in-place in Slab
    let slabId = existingOpt.get
    idx.slab[slabId].name = internedName
    idx.slab[slabId].parentFrn = parentFrn
    idx.slab[slabId].attributes = rec.fileAttributes
    idx.slab[slabId].isDir = isDir
    return ok(void, AllocError)

  let node = FileNode(
    name: internedName,
    parentFrn: parentFrn,
    frn: frn,
    isDir: isDir,
    size: 0'i64,
    sizeOnDisk: calculateSizeOnDisk(0'i64, idx.clusterSize),
    attributes: rec.fileAttributes
  )

  let slabId = ?idx.slab.insert(node)
  ?idx.nodes.put(frn, slabId)
  ok(void, AllocError)

proc bulkIndexFromBuffer*(idx: var Indexer, buf: openArray[byte]): Result[int, AllocError] {.raises: [].} =
  var count = 0
  for rec in parseUsnRecords(buf, isMftEnumBuffer = true):
    ?idx.insertFromUsn(rec)
    inc(count)
  ok[int, AllocError](count)

proc resolvePath*(idx: Indexer, nodeId: SlabId, alloc: Allocator = Allocator()): Result[string, AllocError] {.raises: [].} =
  if not idx.slab.contains(nodeId):
    return ok[string, AllocError]("")

  var parts: seq[string] = @[]
  var currentSlabId = nodeId

  while true:
    let node = idx.slab[currentSlabId]
    let nameStr = idx.names.resolveString(node.name)
    parts.add(nameStr)

    let parentFrn = node.parentFrn
    # Root of NTFS is typically FRN 5 (Root Directory)
    if parentFrn == 5'u64 or parentFrn == 0'u64 or parentFrn == node.frn:
      break

    let parentOpt = idx.nodes.get(parentFrn)
    if parentOpt.isSome:
      currentSlabId = parentOpt.get
    else:
      break

  if parts.len == 0:
    return ok[string, AllocError]("")

  # Reverse from root to leaf
  var fullPath = ""
  for i in countdown(parts.len - 1, 0):
    if fullPath.len > 0:
      fullPath.add('\\')
    fullPath.add(parts[i])

  ok[string, AllocError](fullPath)

# =============================================================================
# Persistence: Compact Binary Serialization & Deserialization
# =============================================================================

proc defaultIndexPath*(): string =
  getTempDir() / "everything.idx"

proc saveToFile*(idx: Indexer, path: string = defaultIndexPath()): Result[void, IOError] =
  var writer = ?openBufferedWriter(path, fmWrite)
  errdefer: discard writer.close()

  # 1. Header
  var magic = IndexMagic
  discard ?writer.writeBytes(addr magic[0], 8)
  var ver = IndexVersion
  discard ?writer.writeBytes(addr ver, sizeof(uint32))
  var cs = int32(idx.clusterSize)
  discard ?writer.writeBytes(addr cs, sizeof(int32))
  var usn = idx.lastUsn
  discard ?writer.writeBytes(addr usn, sizeof(int64))
  var drive = idx.driveLetter
  discard ?writer.writeBytes(addr drive, sizeof(char))
  var pad: array[3, byte]
  discard ?writer.writeBytes(addr pad[0], 3)
  var strCount = uint32(idx.names.len)
  discard ?writer.writeBytes(addr strCount, sizeof(uint32))
  var nodeCount = uint32(idx.nodes.len)
  discard ?writer.writeBytes(addr nodeCount, sizeof(uint32))

  # 2. StringInterner strings
  for i in 0 ..< idx.names.len:
    let sp = idx.names.resolve(InternedStr(int32(i)))
    var sLen = uint32(sp.len)
    discard ?writer.writeBytes(addr sLen, sizeof(uint32))
    if sp.len > 0:
      discard ?writer.writeBytes(sp.rawData, sp.len)

  # 3. Nodes
  for frn, slabId in idx.nodes.pairs:
    let n = idx.slab[slabId]
    var dn = DiskNode(
      frn: n.frn,
      parentFrn: n.parentFrn,
      nameId: int32(n.name),
      isDir: if n.isDir: 1'u8 else: 0'u8,
      size: n.size,
      sizeOnDisk: n.sizeOnDisk,
      attributes: n.attributes
    )
    discard ?writer.writeBytes(addr dn, sizeof(DiskNode))

  ?writer.flush()
  ?writer.close()
  ok(void, IOError)

proc loadFromFile*(alloc: Allocator, path: string = defaultIndexPath()): Result[Indexer, IOError] =
  var reader = ?openBufferedReader(path)
  errdefer: discard reader.close()

  # 1. Header
  var magic: array[8, char]
  var n = ?reader.readBytes(addr magic[0], 8)
  if n < 8 or magic != IndexMagic:
    return err[Indexer, IOError](ioError("Invalid index magic"))

  var ver: uint32
  n = ?reader.readBytes(addr ver, sizeof(uint32))
  if n < sizeof(uint32) or ver != IndexVersion:
    return err[Indexer, IOError](ioError("Unsupported index version"))

  var cs: int32
  discard ?reader.readBytes(addr cs, sizeof(int32))
  var usn: int64
  discard ?reader.readBytes(addr usn, sizeof(int64))
  var drive: char
  discard ?reader.readBytes(addr drive, sizeof(char))
  var pad: array[3, byte]
  discard ?reader.readBytes(addr pad[0], 3)
  var strCount: uint32
  discard ?reader.readBytes(addr strCount, sizeof(uint32))
  var nodeCount: uint32
  discard ?reader.readBytes(addr nodeCount, sizeof(uint32))

  var idxRes = newIndexer(alloc, int(cs), drive, initialCap = max(256, int(nodeCount)))
  if idxRes.isErr:
    return err[Indexer, IOError](ioError("Failed to allocate indexer: " & $idxRes.errVal))
  var idx = idxRes.get()
  idx.lastUsn = usn

  # 2. StringInterner strings
  var strBuf: seq[byte] = @[]
  for i in 0 ..< int(strCount):
    var sLen: uint32
    discard ?reader.readBytes(addr sLen, sizeof(uint32))
    if strBuf.len < int(sLen):
      strBuf.setLen(int(sLen))
    if sLen > 0:
      let bytesRead = ?reader.readBytes(addr strBuf[0], int(sLen))
      if bytesRead < int(sLen):
        return err[Indexer, IOError](ioError("Truncated string data in index"))
      let internRes = idx.names.intern(toOpenArray(cast[ptr UncheckedArray[byte]](addr strBuf[0]), 0, int(sLen) - 1))
      if internRes.isErr:
        return err[Indexer, IOError](ioError("Out of memory interning string"))
    else:
      let internRes = idx.names.intern(toOpenArray(cast[ptr UncheckedArray[byte]](nil), 0, -1))
      if internRes.isErr:
        return err[Indexer, IOError](ioError("Out of memory interning empty string"))

  # 3. Nodes
  for i in 0 ..< int(nodeCount):
    var dn: DiskNode
    let bytesRead = ?reader.readBytes(addr dn, sizeof(DiskNode))
    if bytesRead < sizeof(DiskNode):
      return err[Indexer, IOError](ioError("Truncated node data in index"))
    let node = FileNode(
      name: InternedStr(dn.nameId),
      parentFrn: dn.parentFrn,
      frn: dn.frn,
      isDir: dn.isDir != 0,
      size: dn.size,
      sizeOnDisk: dn.sizeOnDisk,
      attributes: dn.attributes
    )
    let sRes = idx.slab.insert(node)
    if sRes.isErr:
      return err[Indexer, IOError](ioError("Out of memory inserting slab node"))
    let slabId = sRes.get()
    let mRes = idx.nodes.put(dn.frn, slabId)
    if mRes.isErr:
      return err[Indexer, IOError](ioError("Out of memory inserting into node map"))

  discard reader.close()
  ok[Indexer, IOError](move(idx))
