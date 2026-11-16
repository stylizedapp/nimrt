## corex/platform/windows/win32_mft — Zero-Overhead NTFS Master File Table (MFT) Parser & Streamer
##
## Implements:
## 1. Zero-overhead 1024-byte MFT record parsing:
##    - Validates 'FILE' magic (0x454C4946).
##    - Multi-sector FIXUP array (USA) validation and restoration (end of 512-byte sectors).
##    - Attribute enumeration loop handling non-contiguous, resident, and non-resident attributes.
##    - $STANDARD_INFORMATION (0x10): extracts file flags, creation/modification timestamps.
##    - $FILE_NAME (0x30): extracts parent FRN (lower 48-bit record + sequence), namespace
##      priority (skips DOS 8.3 when POSIX/Win32 present), and decodes UTF-16LE filenames
##      via zero-allocation stack buffer without heap allocations.
##    - $DATA (0x80): extracts real fileSize and allocatedSize (sizeOnDisk).
##      * If resident: size is attribute value length.
##      * If non-resident: parses compressed nibble-encoded variable-length LCN offsets
##        and cluster lengths (runlist) to calculate exact allocated clusters and disk footprint.
## 2. Zero-allocation design:
##    - Non-allocating callback and iterator processing.
##    - Strict `Result[T, IOError]` error handling without exceptions (`{.raises: [].}`).
## 3. Volume raw streamer (elevated mode):
##    - Opens `\\.\<drive>:` with `FILE_FLAG_NO_BUFFERING` and `FILE_FLAG_SEQUENTIAL_SCAN`.
##    - Queries `FSCTL_GET_NTFS_VOLUME_DATA` for cluster geometry and MFT location.
##    - Streams sector-aligned (64KB/1MB) buffers using VirtualAlloc page alignment.

import std/widestrs
import ../../result
import ../../memory
import ./win32_fs

const
  MFT_RECORD_SIZE* = 1024
  MFT_SECTOR_SIZE* = 512
  MFT_MAGIC_FILE* = 0x454C4946'u32 # "FILE" (little-endian)
  MFT_MAGIC_BAAD* = 0x44414142'u32 # "BAAD" (corrupt record mark)

  # MFT Record Header Flags
  MFT_RECORD_IN_USE* = 0x0001'u16
  MFT_RECORD_IS_DIRECTORY* = 0x0002'u16

  # Attribute Type Codes
  ATTR_STANDARD_INFORMATION* = 0x10'u32
  ATTR_ATTRIBUTE_LIST* = 0x20'u32
  ATTR_FILE_NAME* = 0x30'u32
  ATTR_OBJECT_ID* = 0x40'u32
  ATTR_SECURITY_DESCRIPTOR* = 0x50'u32
  ATTR_VOLUME_NAME* = 0x60'u32
  ATTR_VOLUME_INFORMATION* = 0x70'u32
  ATTR_DATA* = 0x80'u32
  ATTR_INDEX_ROOT* = 0x90'u32
  ATTR_INDEX_ALLOCATION* = 0xA0'u32
  ATTR_BITMAP* = 0xB0'u32
  ATTR_REPARSE_POINT* = 0xC0'u32
  ATTR_END_MARKER* = 0xFFFFFFFF'u32

  # Win32 Device & File Flags
  FSCTL_GET_NTFS_VOLUME_DATA* = 0x00090064'u32
  FILE_FLAG_NO_BUFFERING* = 0x20000000'u32
  FILE_FLAG_SEQUENTIAL_SCAN* = 0x08000000'u32
  FILE_FLAG_BACKUP_SEMANTICS* = 0x02000000'u32
  GENERIC_READ* = 0x80000000'u32
  FILE_SHARE_READ* = 0x00000001'u32
  FILE_SHARE_WRITE* = 0x00000002'u32
  OPEN_EXISTING* = 3'u32
  INVALID_HANDLE_VALUE* = cast[pointer](-1)

type
  MftEntry* = object
    frn*: uint64
    parentFrn*: uint64
    baseRecordFrn*: uint64
    linkCount*: uint16
    fileSize*: int64
    sizeOnDisk*: int64
    flags*: uint32
    name*: string
    isDir*: bool
    creationTime*: int64
    modificationTime*: int64
    hasAttrList*: bool
    childFrns*: seq[uint64]

  MftDataRun* = object
    lcn*: int64
    clusterCount*: int64
    isSparse*: bool

  NTFS_VOLUME_DATA_BUFFER* = object
    VolumeSerialNumber*: int64
    NumberSectors*: int64
    TotalClusters*: int64
    FreeClusters*: int64
    TotalReserved*: int64
    BytesPerSector*: uint32
    BytesPerCluster*: uint32
    BytesPerFileRecordSegment*: uint32
    ClustersPerFileRecordSegment*: uint32
    MftValidDataLength*: int64
    MftStartLcn*: int64
    Mft2StartLcn*: int64
    MftZoneStart*: int64
    MftZoneEnd*: int64

  MftStreamStats* = object
    totalRecords*: int64
    activeFiles*: int64
    activeDirs*: int64
    totalBytes*: int64
    totalSizeOnDisk*: int64
    corruptRecords*: int64

  MftStreamer* = object
    handle*: pointer
    drive*: char
    bytesPerSector*: uint32
    bytesPerCluster*: uint32
    bytesPerRecord*: uint32
    mftStartLcn*: int64
    mftValidDataLength*: int64
    isOpen*: bool
    buffer*: ptr UncheckedArray[byte]
    bufferSize*: int
    currentRecordIndex*: uint64

# =============================================================================
# 1. Zero-Allocation UTF-16LE Decoding & Hex Formatters
# =============================================================================

func hexWord(w: uint16): string {.raises: [].} =
  const hexChars = "0123456789ABCDEF"
  result = newString(4)
  result[0] = hexChars[(w shr 12) and 0x0F]
  result[1] = hexChars[(w shr 8) and 0x0F]
  result[2] = hexChars[(w shr 4) and 0x0F]
  result[3] = hexChars[w and 0x0F]

proc decodeUtf16LeFast*(
  buf: openArray[byte],
  startOffset: int,
  charCount: int,
  dst: var string
) {.inline, raises: [].} =
  ## In-place UTF-16LE to UTF-8 decoding using stack buffer. Zero heap allocations.
  if startOffset < 0 or charCount <= 0 or charCount > (buf.len - startOffset) div 2:
    dst.setLen(0)
    return

  # Fast path: pure ASCII validation
  var isAscii = true
  for i in 0 ..< charCount:
    let idx = startOffset + i * 2
    if buf[idx + 1] != 0 or buf[idx] >= 0x80'u8:
      isAscii = false
      break

  if isAscii:
    dst.setLen(charCount)
    for i in 0 ..< charCount:
      dst[i] = char(buf[startOffset + i * 2])
    return

  # Multibyte path: decode UTF-16LE code points to UTF-8 via stack buffer
  var stackBuf: array[1024, char]
  var outLen = 0
  var i = 0

  while i < charCount:
    let idx = startOffset + i * 2
    let w1 = uint16(buf[idx]) or (uint16(buf[idx + 1]) shl 8)
    inc i
    var codePoint = uint32(w1)

    # Surrogate pair check
    if codePoint >= 0xD800'u32 and codePoint <= 0xDBFF'u32 and i < charCount:
      let nextIdx = startOffset + i * 2
      let w2 = uint16(buf[nextIdx]) or (uint16(buf[nextIdx + 1]) shl 8)
      if w2 >= 0xDC00'u16 and w2 <= 0xDFFF'u16:
        codePoint = (((codePoint - 0xD800'u32) shl 10) or (uint32(w2) - 0xDC00'u32)) + 0x10000'u32
        inc i

    # Encode UTF-8
    if codePoint < 0x80'u32:
      if outLen < stackBuf.len:
        stackBuf[outLen] = char(codePoint)
        inc outLen
    elif codePoint < 0x800'u32:
      if outLen + 2 <= stackBuf.len:
        stackBuf[outLen] = char(0xC0'u32 or (codePoint shr 6))
        stackBuf[outLen + 1] = char(0x80'u32 or (codePoint and 0x3F'u32))
        outLen += 2
    elif codePoint < 0x10000'u32:
      if outLen + 3 <= stackBuf.len:
        stackBuf[outLen] = char(0xE0'u32 or (codePoint shr 12))
        stackBuf[outLen + 1] = char(0x80'u32 or ((codePoint shr 6) and 0x3F'u32))
        stackBuf[outLen + 2] = char(0x80'u32 or (codePoint and 0x3F'u32))
        outLen += 3
    else:
      if outLen + 4 <= stackBuf.len:
        stackBuf[outLen] = char(0xF0'u32 or (codePoint shr 18))
        stackBuf[outLen + 1] = char(0x80'u32 or ((codePoint shr 12) and 0x3F'u32))
        stackBuf[outLen + 2] = char(0x80'u32 or ((codePoint shr 6) and 0x3F'u32))
        stackBuf[outLen + 3] = char(0x80'u32 or (codePoint and 0x3F'u32))
        outLen += 4

  dst.setLen(outLen)
  if outLen > 0:
    copyMem(addr dst[0], addr stackBuf[0], outLen)

proc decodeUtf16LeFast*(
  span: ByteSpan,
  startOffset: int,
  charCount: int,
  dst: var string
) {.inline, raises: [].} =
  decodeUtf16LeFast(toOpenArray(span.data, 0, span.len - 1), startOffset, charCount, dst)

# =============================================================================
# 2. Multi-Sector FIXUP (USA) Validation & Restoration
# =============================================================================

proc restoreFixups*(record: var openArray[byte]): Result[void, IOError] {.raises: [].} =
  ## Validates and restores the multi-sector fixup array (Update Sequence Array).
  ## Applies the 2-byte fixup word replacement to the end of each 512-byte sector.
  if record.len < MFT_RECORD_SIZE:
    return err[void, IOError](IOError(msg: "Record too small for MFT fixup (expected at least 1024 bytes)"))

  let magic = cast[ptr uint32](addr record[0])[]
  if magic != MFT_MAGIC_FILE:
    if magic == MFT_MAGIC_BAAD:
      return err[void, IOError](IOError(msg: "MFT record marked as corrupted ('BAAD')"))
    return err[void, IOError](IOError(msg: "Invalid MFT signature: expected 'FILE'"))

  let usaOffset = int(cast[ptr uint16](addr record[4])[])
  let usaCount = int(cast[ptr uint16](addr record[6])[])

  if usaCount < 1:
    return err[void, IOError](IOError(msg: "Invalid USA count in MFT record"))

  let usaBytesNeeded = usaOffset + usaCount * 2
  if usaBytesNeeded > record.len:
    return err[void, IOError](IOError(msg: "USA array exceeds record bounds"))

  let checkWord = cast[ptr uint16](addr record[usaOffset])[]
  let sectorCount = usaCount - 1

  for i in 0 ..< sectorCount:
    let sectorEnd = (i + 1) * MFT_SECTOR_SIZE - 2
    if sectorEnd + 2 > record.len:
      return err[void, IOError](IOError(msg: "Sector boundary exceeds record buffer"))

    let actualWord = cast[ptr uint16](addr record[sectorEnd])[]
    if actualWord != checkWord:
      return err[void, IOError](IOError(msg: "Multi-sector FIXUP mismatch at sector " & $i &
        ": expected 0x" & hexWord(checkWord) & " but found 0x" & hexWord(actualWord)))

    let replacement = cast[ptr uint16](addr record[usaOffset + 2 + i * 2])[]
    cast[ptr uint16](addr record[sectorEnd])[] = replacement

  ok[void, IOError]()

# =============================================================================
# 3. NTFS Runlist Parsing (Nibble-Encoded LCNs & Cluster Lengths)
# =============================================================================

proc calculateAllocatedClusters*(
  data: openArray[byte],
  startOffset: int,
  maxLen: int
): int64 {.inline, raises: [].} =
  ## Fast zero-allocation calculator for total allocated clusters from a runlist.
  ## Skips sparse runs (where offset length nibble is 0).
  if startOffset < 0 or maxLen <= 0 or startOffset >= data.len:
    return 0'i64
  var rOff = startOffset
  let endOff = startOffset + min(maxLen, data.len - startOffset)
  var allocatedClusters: int64 = 0

  while rOff < endOff:
    let b = data[rOff]
    if b == 0:
      break # Runlist terminator

    let lenBytes = int(b and 0x0F)
    let offBytes = int((b shr 4) and 0x0F)
    inc rOff

    if lenBytes == 0 or lenBytes > 8 or offBytes > 8:
      break
    if rOff + lenBytes + offBytes > endOff:
      break

    var clusterCount: uint64 = 0'u64
    for i in 0 ..< lenBytes:
      clusterCount = clusterCount or (uint64(data[rOff + i]) shl (i * 8))
    rOff += lenBytes

    if offBytes > 0:
      rOff += offBytes
      if clusterCount <= uint64(high(int64) - allocatedClusters):
        allocatedClusters += int64(clusterCount)
      else:
        allocatedClusters = high(int64)

  allocatedClusters

proc parseRunList*(
  data: openArray[byte],
  startOffset: int,
  maxLen: int,
  runs: var seq[MftDataRun]
): Result[int64, IOError] {.raises: [].} =
  ## Parses compressed nibble-encoded variable-length LCN offsets and cluster lengths.
  ## Populates `runs` and returns total allocated clusters (excluding sparse runs).
  runs.setLen(0)
  if startOffset < 0 or maxLen <= 0 or startOffset >= data.len:
    return ok[int64, IOError](0'i64)
  var rOff = startOffset
  let endOff = startOffset + min(maxLen, data.len - startOffset)
  var allocatedClusters: int64 = 0
  var currentLcn: int64 = 0

  while rOff < endOff:
    let b = data[rOff]
    if b == 0:
      break # Runlist terminator

    let lenBytes = int(b and 0x0F)
    let offBytes = int((b shr 4) and 0x0F)
    inc rOff

    if lenBytes == 0 or lenBytes > 8 or offBytes > 8:
      return err[int64, IOError](IOError(msg: "Corrupt data run: invalid nibble sizes"))

    if rOff + lenBytes + offBytes > endOff:
      return err[int64, IOError](IOError(msg: "Corrupt data run: run exceeds attribute buffer"))

    var clusterCountU: uint64 = 0'u64
    for i in 0 ..< lenBytes:
      clusterCountU = clusterCountU or (uint64(data[rOff + i]) shl (i * 8))
    rOff += lenBytes

    if clusterCountU > uint64(high(int64)):
      return err[int64, IOError](IOError(msg: "Corrupt data run: cluster count exceeds int64 range"))
    let clusterCount = int64(clusterCountU)

    if offBytes > 0:
      var lcnDeltaU: uint64 = 0'u64
      for i in 0 ..< offBytes:
        lcnDeltaU = lcnDeltaU or (uint64(data[rOff + i]) shl (i * 8))

      # Sign-extend lcnDelta safely (avoid shifting by 64 when offBytes == 8)
      let signBit = 1'u64 shl (offBytes * 8 - 1)
      if (lcnDeltaU and signBit) != 0'u64 and offBytes < 8:
        let signMask = (not 0'u64) shl (offBytes * 8)
        lcnDeltaU = lcnDeltaU or signMask
      let lcnDelta = cast[int64](lcnDeltaU)

      rOff += offBytes
      if (lcnDelta > 0 and currentLcn > high(int64) - lcnDelta) or
         (lcnDelta < 0 and currentLcn < low(int64) - lcnDelta):
        return err[int64, IOError](IOError(msg: "Corrupt data run: LCN overflow"))
      currentLcn += lcnDelta

      if allocatedClusters > high(int64) - clusterCount:
        return err[int64, IOError](IOError(msg: "Corrupt data run: allocated clusters overflow"))
      allocatedClusters += clusterCount
      runs.add(MftDataRun(lcn: currentLcn, clusterCount: clusterCount, isSparse: false))
    else:
      # Sparse run (offBytes == 0)
      runs.add(MftDataRun(lcn: 0, clusterCount: clusterCount, isSparse: true))

  ok[int64, IOError](allocatedClusters)

# =============================================================================
# 4. Zero-Overhead MFT Record Parser
# =============================================================================

proc parseMftRecord*(
  raw: openArray[byte],
  entry: var MftEntry,
  recordIndex: uint64 = 0,
  bytesPerCluster: uint32 = 4096,
  onlyInUse: bool = true
): Result[bool, IOError] {.raises: [].} =
  ## Parses a 1024-byte MFT record from `raw`, validates signature, applies fixup array,
  ## and extracts $STANDARD_INFORMATION, $FILE_NAME, and $DATA attributes into `entry`.
  ## Returns:
  ##   ok(true)  if a valid record was extracted into `entry`.
  ##   ok(false) if the record was skipped (e.g. not in use when onlyInUse = true).
  ##   err(...)  if the record is corrupted.
  if raw.len < MFT_RECORD_SIZE:
    return err[bool, IOError](IOError(msg: "Buffer too small for MFT record (expected 1024 bytes)"))

  # Copy to local stack buffer to apply fixup restoration safely
  var rec: array[MFT_RECORD_SIZE, byte]
  copyMem(addr rec[0], unsafeAddr raw[0], MFT_RECORD_SIZE)

  let fixRes = restoreFixups(rec)
  if fixRes.isErr:
    return err[bool, IOError](fixRes.error)

  let recordFlags = cast[ptr uint16](addr rec[22])[]
  let inUse = (recordFlags and MFT_RECORD_IN_USE) != 0
  if onlyInUse and not inUse:
    return ok[bool, IOError](false)

  let isRecordDir = (recordFlags and MFT_RECORD_IS_DIRECTORY) != 0
  let sequenceNumber = cast[ptr uint16](addr rec[16])[]
  let linkCount = cast[ptr uint16](addr rec[18])[]
  let firstAttrOffset = int(cast[ptr uint16](addr rec[20])[])
  let baseRecordFrn = cast[ptr uint64](addr rec[32])[]

  var recNum = recordIndex
  if recNum == 0:
    let hdrRecNum = cast[ptr uint32](addr rec[44])[]
    if hdrRecNum != 0:
      recNum = uint64(hdrRecNum)

  let frn = (uint64(sequenceNumber) shl 48) or (recNum and 0x0000FFFFFFFFFFFF'u64)

  entry.frn = frn
  entry.parentFrn = 0'u64
  entry.baseRecordFrn = baseRecordFrn
  entry.linkCount = linkCount
  entry.fileSize = 0'i64
  entry.sizeOnDisk = 0'i64
  entry.flags = if isRecordDir: 0x00000010'u32 else: 0'u32
  entry.isDir = isRecordDir
  entry.creationTime = 0'i64
  entry.modificationTime = 0'i64
  entry.name.setLen(0)
  entry.hasAttrList = false
  entry.childFrns.setLen(0)

  var bestNamespaceRank = -1
  var attrOffset = firstAttrOffset

  while attrOffset + 8 <= MFT_RECORD_SIZE:
    let attrType = cast[ptr uint32](addr rec[attrOffset])[]
    if attrType == ATTR_END_MARKER or attrType == 0'u32:
      break

    let attrLen = cast[ptr uint32](addr rec[attrOffset + 4])[]
    if attrLen < 16'u32 or attrLen > uint32(MFT_RECORD_SIZE - attrOffset):
      break # Corrupt or out-of-bounds attribute length

    let nonResident = rec[attrOffset + 8] != 0
    let nameLen = int(rec[attrOffset + 9])

    case attrType
    of ATTR_STANDARD_INFORMATION:
      if not nonResident and attrLen >= 24'u32 and attrOffset + 24 <= MFT_RECORD_SIZE:
        let valLen = min(int(cast[ptr uint32](addr rec[attrOffset + 16])[]), MFT_RECORD_SIZE)
        let valOff = int(cast[ptr uint16](addr rec[attrOffset + 20])[])
        let pOff = attrOffset + valOff
        if pOff + 36 <= MFT_RECORD_SIZE and valLen >= 36:
          entry.creationTime = cast[ptr int64](addr rec[pOff + 0])[]
          entry.modificationTime = cast[ptr int64](addr rec[pOff + 8])[]
          let siFlags = cast[ptr uint32](addr rec[pOff + 32])[]
          entry.flags = entry.flags or siFlags
          if (siFlags and 0x00000010'u32) != 0:
            entry.isDir = true

    of ATTR_ATTRIBUTE_LIST:
      entry.hasAttrList = true
      if not nonResident:
        if attrLen >= 24'u32 and attrOffset + 24 <= MFT_RECORD_SIZE:
          let valLen = min(int(cast[ptr uint32](addr rec[attrOffset + 16])[]), MFT_RECORD_SIZE)
          let valOff = int(cast[ptr uint16](addr rec[attrOffset + 20])[])
          let pOff = attrOffset + valOff
          let pEnd = min(pOff + valLen, MFT_RECORD_SIZE)
          var curOff = pOff
          while curOff + 24 <= pEnd:
            let alRecLen = int(cast[ptr uint16](addr rec[curOff + 4])[])
            if alRecLen < 24:
              break
            let childFrn = cast[ptr uint64](addr rec[curOff + 16])[]
            if childFrn != 0 and (childFrn and 0x0000FFFFFFFFFFFF'u64) != (frn and 0x0000FFFFFFFFFFFF'u64):
              var alreadyPresent = false
              for c in entry.childFrns:
                if c == childFrn:
                  alreadyPresent = true
                  break
              if not alreadyPresent:
                entry.childFrns.add(childFrn)
            curOff += alRecLen
      else:
        if attrLen >= 40'u32 and attrOffset + 40 <= MFT_RECORD_SIZE:
          let runListOff = int(cast[ptr uint16](addr rec[attrOffset + 32])[])
          if runListOff > 0 and runListOff < int(attrLen) and attrOffset + runListOff < MFT_RECORD_SIZE:
            let maxRunBytes = min(int(attrLen) - runListOff, MFT_RECORD_SIZE - (attrOffset + runListOff))
            let allocatedClusters = calculateAllocatedClusters(rec, attrOffset + runListOff, maxRunBytes)
            if bytesPerCluster > 0'u32 and allocatedClusters > 0:
              let bpc = int64(bytesPerCluster)
              if allocatedClusters <= (high(int64) - entry.sizeOnDisk) div bpc:
                entry.sizeOnDisk += allocatedClusters * bpc
              else:
                entry.sizeOnDisk = high(int64)

    of ATTR_FILE_NAME:
      if not nonResident and attrLen >= 24'u32 and attrOffset + 24 <= MFT_RECORD_SIZE:
        let valLen = min(int(cast[ptr uint32](addr rec[attrOffset + 16])[]), MFT_RECORD_SIZE)
        let valOff = int(cast[ptr uint16](addr rec[attrOffset + 20])[])
        let pOff = attrOffset + valOff
        if pOff + 66 <= MFT_RECORD_SIZE and valLen >= 66:
          let pFrn = cast[ptr uint64](addr rec[pOff + 0])[]
          let fnAllocSize = cast[ptr int64](addr rec[pOff + 40])[]
          let fnRealSize = cast[ptr int64](addr rec[pOff + 48])[]
          let fnFlags = cast[ptr uint32](addr rec[pOff + 56])[]
          let fnCharCount = int(rec[pOff + 64])
          let fnNamespace = int(rec[pOff + 65])
          let nameBytesStart = pOff + 66
          let nameBytesEnd = nameBytesStart + fnCharCount * 2

          if nameBytesEnd <= MFT_RECORD_SIZE and nameBytesEnd <= pOff + valLen:
            # Rank namespaces: Win32 (1) & Win32+DOS (3) -> rank 3; POSIX (0) -> rank 2; DOS (2) -> rank 1
            let rank = case fnNamespace
              of 1, 3: 3
              of 0: 2
              of 2: 1
              else: 0

            if rank > bestNamespaceRank:
              bestNamespaceRank = rank
              entry.parentFrn = pFrn
              decodeUtf16LeFast(rec, nameBytesStart, fnCharCount, entry.name)
              if (fnFlags and 0x00000010'u32) != 0:
                entry.isDir = true
              entry.flags = entry.flags or fnFlags
              # Fallback size if $DATA is absent
              if entry.fileSize == 0 and not entry.isDir:
                entry.fileSize = fnRealSize
                if entry.sizeOnDisk == 0:
                  entry.sizeOnDisk = fnAllocSize

    of ATTR_DATA:
      # Primary unnamed data stream only (nameLen == 0)
      if nameLen == 0:
        if not nonResident:
          if attrLen >= 24'u32 and attrOffset + 24 <= MFT_RECORD_SIZE:
            let valLen = int(cast[ptr uint32](addr rec[attrOffset + 16])[])
            entry.fileSize = int64(valLen)
            entry.sizeOnDisk = int64(valLen)
        else:
          if attrLen >= 56'u32 and attrOffset + 56 <= MFT_RECORD_SIZE:
            let allocatedSizeHdr = cast[ptr int64](addr rec[attrOffset + 40])[]
            let realSizeHdr = cast[ptr int64](addr rec[attrOffset + 48])[]
            entry.fileSize = realSizeHdr

            let runListOff = int(cast[ptr uint16](addr rec[attrOffset + 32])[])
            if runListOff > 0 and runListOff < int(attrLen) and attrOffset + runListOff < MFT_RECORD_SIZE:
              let maxRunBytes = min(int(attrLen) - runListOff, MFT_RECORD_SIZE - (attrOffset + runListOff))
              let allocatedClusters = calculateAllocatedClusters(rec, attrOffset + runListOff, maxRunBytes)
              if bytesPerCluster > 0'u32:
                let bpc = int64(bytesPerCluster)
                if allocatedClusters <= high(int64) div bpc:
                  entry.sizeOnDisk = allocatedClusters * bpc
                else:
                  entry.sizeOnDisk = high(int64)
              else:
                entry.sizeOnDisk = allocatedSizeHdr
            else:
              entry.sizeOnDisk = allocatedSizeHdr
    else:
      discard

    attrOffset += int(attrLen)

  ok[bool, IOError](true)

proc parseMftRecord*(
  span: ByteSpan,
  entry: var MftEntry,
  recordIndex: uint64 = 0,
  bytesPerCluster: uint32 = 4096,
  onlyInUse: bool = true
): Result[bool, IOError] {.inline, raises: [].} =
  if span.len < MFT_RECORD_SIZE:
    return err[bool, IOError](IOError(msg: "ByteSpan too small for MFT record (expected 1024 bytes)"))
  parseMftRecord(toOpenArray(span.data, 0, span.len - 1), entry, recordIndex, bytesPerCluster, onlyInUse)

iterator parseMftBuffer*(
  buf: openArray[byte],
  startRecordIndex: uint64 = 0,
  bytesPerCluster: uint32 = 4096,
  onlyInUse: bool = true
): MftEntry {.raises: [].} =
  ## Iterates through consecutive 1024-byte MFT records in `buf`.
  let count = buf.len div MFT_RECORD_SIZE
  var entry: MftEntry
  for i in 0 ..< count:
    let offset = i * MFT_RECORD_SIZE
    let res = parseMftRecord(buf.toOpenArray(offset, offset + MFT_RECORD_SIZE - 1), entry, startRecordIndex + uint64(i), bytesPerCluster, onlyInUse)
    if res.isOk and res.get:
      yield entry

# =============================================================================
# 5. Extension Record Merging & Hardlink Deduplication
# =============================================================================

proc mergeExtensionRecord*(baseEntry: var MftEntry, childEntry: MftEntry) {.raises: [].} =
  ## Merges child MFT record (extension record) extents into baseEntry:
  ## - Sums sizeOnDisk across all extents from the child record into the base file record.
  ## - Updates fileSize if child holds larger stream size.
  ## - Preserves filename from child if base record filename was in extension record.
  baseEntry.sizeOnDisk += childEntry.sizeOnDisk
  if childEntry.fileSize > baseEntry.fileSize:
    baseEntry.fileSize = childEntry.fileSize
  if baseEntry.name.len == 0 and childEntry.name.len > 0:
    baseEntry.name = childEntry.name
    baseEntry.parentFrn = childEntry.parentFrn
  var found = false
  for c in baseEntry.childFrns:
    if c == childEntry.frn:
      found = true
      break
  if not found:
    baseEntry.childFrns.add(childEntry.frn)

type
  MftVolumeCalculator* = object
    processedFrns*: seq[uint64]
    totalBytes*: int64
    totalSizeOnDisk*: int64
    activeFiles*: int64
    activeDirs*: int64
    hardlinksDeduplicated*: int64
    extensionsMerged*: int64

proc initMftVolumeCalculator*(): MftVolumeCalculator {.raises: [].} =
  result.processedFrns = @[]
  result.totalBytes = 0
  result.totalSizeOnDisk = 0
  result.activeFiles = 0
  result.activeDirs = 0
  result.hardlinksDeduplicated = 0
  result.extensionsMerged = 0

proc addRecord*(calc: var MftVolumeCalculator, entry: MftEntry): bool {.raises: [].} =
  ## Adds an MftEntry to the volume calculation with hardlink and extension deduplication:
  ## - Child extension records (baseRecordFrn != 0) sum sizeOnDisk without incrementing file count.
  ## - Files with multiple hardlinks (linkCount > 1) have their physical clusters counted exactly once.
  ## Returns true if counted as a new active entity, false if deduplicated / merged.
  if entry.baseRecordFrn != 0:
    inc calc.extensionsMerged
    calc.totalSizeOnDisk += entry.sizeOnDisk
    return false

  let rawFrn = entry.frn and 0x0000FFFFFFFFFFFF'u64
  for existing in calc.processedFrns:
    if existing == rawFrn:
      inc calc.hardlinksDeduplicated
      return false

  calc.processedFrns.add(rawFrn)
  if entry.isDir:
    inc calc.activeDirs
  else:
    inc calc.activeFiles
    calc.totalBytes += entry.fileSize
    calc.totalSizeOnDisk += entry.sizeOnDisk
  return true

# =============================================================================
# 6. Volume Raw Streamer (Elevated Administrator Access)
# =============================================================================

when defined(windows):
  const
    MEM_COMMIT = 0x00001000'u32
    MEM_RESERVE = 0x00002000'u32
    MEM_RELEASE = 0x00008000'u32
    PAGE_READWRITE = 0x04'u32

  proc createFileW(
    lpFileName: WideCString,
    dwDesiredAccess: uint32,
    dwShareMode: uint32,
    lpSecurityAttributes: pointer,
    dwCreationDisposition: uint32,
    dwFlagsAndAttributes: uint32,
    hTemplateFile: pointer
  ): pointer {.stdcall, dynlib: "kernel32", importc: "CreateFileW", sideEffect.}

  proc closeHandle(hObject: pointer): int32 {.stdcall, dynlib: "kernel32", importc: "CloseHandle", sideEffect.}

  proc deviceIoControl(
    hDevice: pointer,
    dwIoControlCode: uint32,
    lpInBuffer: pointer,
    nInBufferSize: uint32,
    lpOutBuffer: pointer,
    nOutBufferSize: uint32,
    lpBytesReturned: ptr uint32,
    lpOverlapped: pointer
  ): int32 {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl", sideEffect.}

  proc getLastError(): uint32 {.stdcall, dynlib: "kernel32", importc: "GetLastError", sideEffect.}

  proc virtualAlloc(lpAddress: pointer, dwSize: int, flAllocationType: uint32, flProtect: uint32): pointer {.stdcall, dynlib: "kernel32", importc: "VirtualAlloc", sideEffect.}
  proc virtualFree(lpAddress: pointer, dwSize: int, dwFreeType: uint32): int32 {.stdcall, dynlib: "kernel32", importc: "VirtualFree", sideEffect.}

  proc setFilePointerEx(
    hFile: pointer,
    liDistanceToMove: int64,
    lpNewFilePointer: ptr int64,
    dwMoveMethod: uint32
  ): int32 {.stdcall, dynlib: "kernel32", importc: "SetFilePointerEx", sideEffect.}

  proc readFile(
    hFile: pointer,
    lpBuffer: pointer,
    nNumberOfBytesToRead: uint32,
    lpNumberOfBytesRead: ptr uint32,
    lpOverlapped: pointer
  ): int32 {.stdcall, dynlib: "kernel32", importc: "ReadFile", sideEffect.}

  proc close*(s: var MftStreamer) {.raises: [].} =
    ## Closes raw volume handle and releases aligned streaming buffer.
    if s.isOpen:
      if s.handle != cast[pointer](-1) and not s.handle.isNil:
        discard closeHandle(s.handle)
      if not s.buffer.isNil:
        discard virtualFree(cast[pointer](s.buffer), 0, MEM_RELEASE)
      s.handle = cast[pointer](-1)
      s.buffer = nil
      s.isOpen = false
      s.drive = '\0'
      s.bufferSize = 0

  proc `=destroy`*(s: var MftStreamer) {.raises: [].} =
    close(s)

  proc `=wasMoved`*(s: var MftStreamer) {.inline, raises: [].} =
    s.handle = cast[pointer](-1)
    s.buffer = nil
    s.isOpen = false
    s.drive = '\0'
    s.bufferSize = 0

  proc `=sink`*(dest: var MftStreamer, src: MftStreamer) {.raises: [].} =
    if dest.handle != src.handle:
      close(dest)
    dest.handle = src.handle
    dest.drive = src.drive
    dest.bytesPerSector = src.bytesPerSector
    dest.bytesPerCluster = src.bytesPerCluster
    dest.bytesPerRecord = src.bytesPerRecord
    dest.mftStartLcn = src.mftStartLcn
    dest.mftValidDataLength = src.mftValidDataLength
    dest.isOpen = src.isOpen
    dest.buffer = src.buffer
    dest.bufferSize = src.bufferSize
    dest.currentRecordIndex = src.currentRecordIndex

  proc `=copy`*(dest: var MftStreamer, src: MftStreamer) {.error: "MftStreamer cannot be copied; use move semantics".}

  proc openMftStreamer*(
    drive: char,
    bufferSize: int = 1024 * 1024
  ): Result[MftStreamer, IOError] {.raises: [].} =
    ## Opens raw volume `\\.\<drive>:` with FILE_FLAG_NO_BUFFERING and FILE_FLAG_SEQUENTIAL_SCAN.
    ## Queries FSCTL_GET_NTFS_VOLUME_DATA for bytesPerCluster and MftStartLcn.
    ## Allocates sector-aligned buffer via VirtualAlloc.
    let path = "\\\\.\\" & $drive & ":"
    let wPath = newWideCString(path)

    let hVol = createFileW(
      wPath,
      GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil,
      OPEN_EXISTING,
      FILE_FLAG_NO_BUFFERING or FILE_FLAG_SEQUENTIAL_SCAN or FILE_FLAG_BACKUP_SEMANTICS,
      nil
    )

    if hVol == INVALID_HANDLE_VALUE or hVol.isNil:
      let errCode = getLastError()
      let msg = if errCode == 5'u32:
        "Failed to open raw volume '" & path & "': Administrative privileges required for raw MFT streaming (Win32 error 5: Access is denied)"
      else:
        "Failed to open raw volume '" & path & "': Win32 error " & $errCode
      return err[MftStreamer, IOError](IOError(msg: msg))

    var ntfsData: NTFS_VOLUME_DATA_BUFFER
    var bytesReturned: uint32 = 0
    let ioctlRes = deviceIoControl(
      hVol,
      FSCTL_GET_NTFS_VOLUME_DATA,
      nil, 0,
      addr ntfsData, uint32(sizeof(NTFS_VOLUME_DATA_BUFFER)),
      addr bytesReturned, nil
    )

    if ioctlRes == 0:
      let errCode = getLastError()
      discard closeHandle(hVol)
      return err[MftStreamer, IOError](IOError(msg: "FSCTL_GET_NTFS_VOLUME_DATA failed on '" & path & "': Win32 error " & $errCode))

    let bSector = if ntfsData.BytesPerSector > 0'u32: ntfsData.BytesPerSector else: 512'u32
    let bCluster = if ntfsData.BytesPerCluster > 0'u32: ntfsData.BytesPerCluster else: 4096'u32
    let bRecord = if ntfsData.BytesPerFileRecordSegment > 0'u32: ntfsData.BytesPerFileRecordSegment else: 1024'u32

    # Buffer must be a multiple of sector/cluster size for FILE_FLAG_NO_BUFFERING
    var alignedBufSize = bufferSize
    if alignedBufSize < int(bCluster):
      alignedBufSize = int(bCluster)
    alignedBufSize = (alignedBufSize + int(bCluster) - 1) div int(bCluster) * int(bCluster)

    let bufPtr = virtualAlloc(nil, alignedBufSize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE)
    if bufPtr.isNil:
      discard closeHandle(hVol)
      return err[MftStreamer, IOError](IOError(msg: "Failed to allocate aligned sector buffer (" & $alignedBufSize & " bytes)"))

    ok[MftStreamer, IOError](MftStreamer(
      handle: hVol,
      drive: drive,
      bytesPerSector: bSector,
      bytesPerCluster: bCluster,
      bytesPerRecord: bRecord,
      mftStartLcn: ntfsData.MftStartLcn,
      mftValidDataLength: ntfsData.MftValidDataLength,
      isOpen: true,
      buffer: cast[ptr UncheckedArray[byte]](bufPtr),
      bufferSize: alignedBufSize,
      currentRecordIndex: 0'u64
    ))

  proc streamAll*(
    s: var MftStreamer,
    cb: proc(entry: var MftEntry) {.closure, raises: [].},
    onlyInUse: bool = true
  ): Result[MftStreamStats, IOError] {.raises: [].} =
    ## Streams all MFT records from raw volume using aligned streaming buffers.
    ## Invokes `cb` in-place on each record with zero heap allocations.
    if not s.isOpen or s.handle == INVALID_HANDLE_VALUE:
      return err[MftStreamStats, IOError](IOError(msg: "MftStreamer is not open"))

    var stats = MftStreamStats()

    # Step 1: Read Record 0 to extract complete $MFT runlist
    let startOffset = s.mftStartLcn * int64(s.bytesPerCluster)
    var newPtr: int64 = 0
    if setFilePointerEx(s.handle, startOffset, addr newPtr, 0'u32) == 0:
      let errCode = getLastError()
      return err[MftStreamStats, IOError](IOError(msg: "Seek to MFT start LCN failed: Win32 error " & $errCode))

    var bytesRead: uint32 = 0
    let readRes = readFile(s.handle, cast[pointer](s.buffer), uint32(min(s.bufferSize, 64 * 1024)), addr bytesRead, nil)
    if readRes == 0 or bytesRead < MFT_RECORD_SIZE:
      let errCode = getLastError()
      return err[MftStreamStats, IOError](IOError(msg: "Failed to read MFT Record 0: Win32 error " & $errCode))

    var mftRuns: seq[MftDataRun] = @[]
    block extractRuns:
      var rec0: array[MFT_RECORD_SIZE, byte]
      copyMem(addr rec0[0], addr s.buffer[0], MFT_RECORD_SIZE)
      if restoreFixups(rec0).isOk:
        let firstAttr = int(cast[ptr uint16](addr rec0[20])[])
        var off = firstAttr
        while off + 8 <= MFT_RECORD_SIZE:
          let aType = cast[ptr uint32](addr rec0[off])[]
          if aType == ATTR_END_MARKER or aType == 0'u32: break
          let aLen = cast[ptr uint32](addr rec0[off + 4])[]
          if aLen < 16'u32 or off + int(aLen) > MFT_RECORD_SIZE: break
          let nonRes = rec0[off + 8] != 0
          let nLen = int(rec0[off + 9])
          if aType == ATTR_DATA and nLen == 0 and nonRes:
            let rOff = int(cast[ptr uint16](addr rec0[off + 32])[])
            if rOff > 0 and rOff < int(aLen) and off + rOff < MFT_RECORD_SIZE:
              let maxRBytes = min(int(aLen) - rOff, MFT_RECORD_SIZE - (off + rOff))
              let runsRes = parseRunList(rec0, off + rOff, maxRBytes, mftRuns)
              if runsRes.isErr:
                mftRuns.setLen(0)
              break
          off += int(aLen)

    # Fallback to single contiguous run if no runs extracted from Record 0
    if mftRuns.len == 0:
      let estClusters = (s.mftValidDataLength + int64(s.bytesPerCluster) - 1) div int64(s.bytesPerCluster)
      mftRuns.add(MftDataRun(lcn: s.mftStartLcn, clusterCount: estClusters, isSparse: false))

    # Step 2: Stream through each extent
    var entry: MftEntry
    var currentRecIdx: uint64 = 0
    let totalRecLimit = if s.mftValidDataLength > 0: uint64(s.mftValidDataLength div int64(s.bytesPerRecord)) else: 0xFFFFFFFFFFFFFFFF'u64

    for run in mftRuns:
      if currentRecIdx >= totalRecLimit:
        break

      if run.isSparse or run.lcn <= 0:
        let skipRecords = uint64(run.clusterCount * int64(s.bytesPerCluster) div int64(s.bytesPerRecord))
        currentRecIdx += skipRecords
        stats.totalRecords += int64(skipRecords)
        continue

      let runStartByte = run.lcn * int64(s.bytesPerCluster)
      var runBytesRemaining = run.clusterCount * int64(s.bytesPerCluster)
      var currentByteOffset = runStartByte

      while runBytesRemaining > 0 and currentRecIdx < totalRecLimit:
        let toRead = uint32(min(runBytesRemaining, int64(s.bufferSize)))
        var movedPtr: int64 = 0
        if setFilePointerEx(s.handle, currentByteOffset, addr movedPtr, 0'u32) == 0:
          inc stats.corruptRecords
          break

        var readChunk: uint32 = 0
        if readFile(s.handle, cast[pointer](s.buffer), toRead, addr readChunk, nil) == 0 or readChunk == 0:
          break

        let numRecordsInChunk = int(readChunk) div int(s.bytesPerRecord)
        for i in 0 ..< numRecordsInChunk:
          if currentRecIdx >= totalRecLimit:
            break

          let recOffset = i * int(s.bytesPerRecord)
          let parseRes = parseMftRecord(toOpenArray(s.buffer, recOffset, recOffset + int(s.bytesPerRecord) - 1), entry, currentRecIdx, s.bytesPerCluster, onlyInUse)
          if parseRes.isOk:
            if parseRes.get:
              if entry.isDir:
                inc stats.activeDirs
              else:
                inc stats.activeFiles
                stats.totalBytes += entry.fileSize
                stats.totalSizeOnDisk += entry.sizeOnDisk
              cb(entry)
          else:
            inc stats.corruptRecords

          inc currentRecIdx
          inc stats.totalRecords

        currentByteOffset += int64(readChunk)
        runBytesRemaining -= int64(readChunk)

    ok[MftStreamStats, IOError](stats)

else:
  proc close*(s: var MftStreamer) {.raises: [].} = discard

  proc openMftStreamer*(
    drive: char,
    bufferSize: int = 1024 * 1024
  ): Result[MftStreamer, IOError] {.raises: [].} =
    err[MftStreamer, IOError](IOError(msg: "Raw MFT streaming only supported on Windows"))

  proc streamAll*(
    s: var MftStreamer,
    cb: proc(entry: var MftEntry) {.closure, raises: [].},
    onlyInUse: bool = true
  ): Result[MftStreamStats, IOError] {.raises: [].} =
    err[MftStreamStats, IOError](IOError(msg: "Raw MFT streaming only supported on Windows"))
