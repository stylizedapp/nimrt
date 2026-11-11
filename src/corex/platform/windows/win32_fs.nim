## corex/platform/windows/win32_fs — High-Performance Win32 Filesystem Primitives
##
## Implements:
## 1. Fast directory enumeration via FindFirstFileExW with FindExInfoBasic & FIND_FIRST_EX_LARGE_FETCH
## 2. Volume & cluster geometry inspection (GetDiskFreeSpaceW, GetVolumeInformationW)
## 3. Exact "Size on Disk" calculations with compressed/sparse file overrides
## 4. Win32 MFT / USN Journal streaming structures for high-speed indexing (WizTree foundation)

import std/widestrs
import ../../result

# =============================================================================
# 1. Win32 Types, Enums & Constants
# =============================================================================

type
  HANDLE* = pointer
  BOOL* = int32
  DWORD* = uint32
  USN* = int64

const
  INVALID_HANDLE_VALUE* = cast[HANDLE](-1)

  # FindFirstFileExW constants
  FindExInfoStandard* = 0'i32
  FindExInfoBasic*    = 1'i32
  FindExSearchNameMatch* = 0'i32
  FIND_FIRST_EX_CASE_SENSITIVE*       = 0x00000001'u32
  FIND_FIRST_EX_LARGE_FETCH*          = 0x00000002'u32
  FIND_FIRST_EX_ON_DISK_ENTRIES_ONLY* = 0x00000004'u32

  # File Attributes
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

  # USN Journal / MFT Constants
  FSCTL_ENUM_USN_DATA*      = 0x000900B3'u32
  FSCTL_QUERY_USN_JOURNAL*  = 0x000900F4'u32
  USN_PAGE_SIZE*            = 4096

  # USN Reason Flags
  USN_REASON_DATA_OVERWRITE*          = 0x00000001'u32
  USN_REASON_DATA_EXTEND*             = 0x00000002'u32
  USN_REASON_DATA_TRUNCATION*         = 0x00000004'u32
  USN_REASON_FILE_CREATE*             = 0x00000100'u32
  USN_REASON_FILE_DELETE*             = 0x00000200'u32
  USN_REASON_RENAME_OLD_NAME*         = 0x00001000'u32
  USN_REASON_RENAME_NEW_NAME*         = 0x00002000'u32
  USN_REASON_BASIC_INFO_CHANGE*       = 0x00008000'u32
  USN_REASON_CLOSE*                   = 0x80000000'u32

  # Reparse Tags
  IO_REPARSE_TAG_MOUNT_POINT*         = 0xA0000003'u32
  IO_REPARSE_TAG_SYMLINK*             = 0xA000000C'u32

type
  FileAttribute* = enum
    faReadOnly
    faHidden
    faSystem
    faDirectory
    faArchive
    faDevice
    faNormal
    faTemporary
    faSparse
    faReparsePoint
    faCompressed
    faOffline
    faEncrypted

  FILETIME* = object
    dwLowDateTime*: DWORD
    dwHighDateTime*: DWORD

  WIN32_FIND_DATAW* = object
    dwFileAttributes*: DWORD
    ftCreationTime*: FILETIME
    ftLastAccessTime*: FILETIME
    ftLastWriteTime*: FILETIME
    nFileSizeHigh*: DWORD
    nFileSizeLow*: DWORD
    dwReserved0*: DWORD
    dwReserved1*: DWORD
    cFileName*: array[260, uint16]
    cAlternateFileName*: array[14, uint16]

  WIN32_FILE_ATTRIBUTE_DATA* = object
    dwFileAttributes*: DWORD
    ftCreationTime*: FILETIME
    ftLastAccessTime*: FILETIME
    ftLastWriteTime*: FILETIME
    nFileSizeHigh*: DWORD
    nFileSizeLow*: DWORD

  Win32DirEntry* = object
    name*: string
    path*: string
    isDir*: bool
    isSymlink*: bool
    size*: int64
    allocatedSize*: int64
    creationTime*: int64
    lastAccessTime*: int64
    lastWriteTime*: int64
    attributes*: set[FileAttribute]

  Win32VolumeInfo* = object
    volumeName*: string
    fsType*: string
    serialNumber*: uint32
    totalBytes*: int64
    freeBytes*: int64
    clusterSize*: int
    sectorsPerCluster*: int
    bytesPerSector*: int

  USN_JOURNAL_DATA_V0* = object
    UsnJournalID*: uint64
    FirstUsn*: USN
    NextUsn*: USN
    LowestValidUsn*: USN
    MaxUsn*: USN
    MaximumSize*: uint64
    AllocationDelta*: uint64

  MFT_ENUM_DATA_V0* = object
    StartFileReferenceNumber*: uint64
    LowUsn*: USN
    HighUsn*: USN

  USN_RECORD_V2* = object
    recordLength*: uint32
    majorVersion*: uint16
    minorVersion*: uint16
    fileReferenceNumber*: uint64
    parentFileReferenceNumber*: uint64
    usn*: USN
    timeStamp*: int64
    reason*: uint32
    sourceInfo*: uint32
    securityId*: uint32
    fileAttributes*: uint32
    fileName*: string

  UsnRecordView* = object
    raw*: ptr byte

# =============================================================================
# 2. Win32 Kernel32 & FFI Declarations
# =============================================================================

when defined(windows):
  proc findFirstFileExW(
    lpFileName: WideCString,
    fInfoLevelId: int32,
    lpFindFileData: ptr WIN32_FIND_DATAW,
    fSearchOp: int32,
    lpSearchFilter: pointer,
    dwAdditionalFlags: DWORD
  ): HANDLE {.stdcall, dynlib: "kernel32", importc: "FindFirstFileExW", sideEffect.}

  proc findNextFileW(
    hFindFile: HANDLE,
    lpFindFileData: ptr WIN32_FIND_DATAW
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "FindNextFileW", sideEffect.}

  proc findClose(
    hFindFile: HANDLE
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "FindClose", sideEffect.}

  proc wideCharToMultiByte(
    codePage: uint32,
    dwFlags: uint32,
    lpWideCharStr: ptr uint16,
    cchWideChar: int32,
    lpMultiByteStr: cstring,
    cbMultiByte: int32,
    lpDefaultChar: cstring,
    lpUsedDefaultChar: ptr int32
  ): int32 {.stdcall, dynlib: "kernel32", importc: "WideCharToMultiByte", sideEffect.}

  proc getDiskFreeSpaceW(
    lpRootPathName: WideCString,
    lpSectorsPerCluster: ptr DWORD,
    lpBytesPerSector: ptr DWORD,
    lpNumberOfFreeClusters: ptr DWORD,
    lpTotalNumberOfClusters: ptr DWORD
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "GetDiskFreeSpaceW", sideEffect.}

  proc getDiskFreeSpaceExW(
    lpDirectoryName: WideCString,
    lpFreeBytesAvailableToCaller: ptr int64,
    lpTotalNumberOfBytes: ptr int64,
    lpTotalNumberOfFreeBytes: ptr int64
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "GetDiskFreeSpaceExW", sideEffect.}

  proc getVolumeInformationW(
    lpRootPathName: WideCString,
    lpVolumeNameBuffer: ptr uint16,
    nVolumeNameSize: DWORD,
    lpVolumeSerialNumber: ptr DWORD,
    lpMaximumComponentLength: ptr DWORD,
    lpFileSystemFlags: ptr DWORD,
    lpFileSystemNameBuffer: ptr uint16,
    nFileSystemNameSize: DWORD
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "GetVolumeInformationW", sideEffect.}

  proc getCompressedFileSizeW(
    lpFileName: WideCString,
    lpFileSizeHigh: ptr DWORD
  ): DWORD {.stdcall, dynlib: "kernel32", importc: "GetCompressedFileSizeW", sideEffect.}

  proc getFileAttributesExW(
    lpFileName: WideCString,
    fInfoLevelId: int32,
    lpFileInformation: ptr WIN32_FILE_ATTRIBUTE_DATA
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "GetFileAttributesExW", sideEffect.}

  proc getLastError(): DWORD {.stdcall, dynlib: "kernel32", importc: "GetLastError", sideEffect.}

# =============================================================================
# 3. Helpers: UTF-16, Timestamps, Dot Skipping, Attribute Mapping
# =============================================================================

proc isDotOrDotDot*(w: ptr UncheckedArray[uint16]): bool {.inline, raises: [].} =
  ## Returns true if wchar buffer is "." or "..", false otherwise.
  if w[0] == 0x002E'u16: # '.'
    let c1 = w[1]
    if c1 == 0'u16: return true
    if c1 == 0x002E'u16 and w[2] == 0'u16: return true
  false

proc utf16ToUtf8Fast*(src: ptr UncheckedArray[uint16], dst: var string) {.inline, raises: [].} =
  ## In-place ultra-fast conversion with zero intermediate allocations.
  var i = 0
  var isAscii = true
  while true:
    let w = src[i]
    if w == 0'u16: break
    if w >= 0x80'u16:
      isAscii = false
      break
    inc i

  if isAscii:
    dst.setLen(i)
    for j in 0 ..< i:
      dst[j] = char(src[j])
  else:
    when defined(windows):
      var buf: array[1024, char]
      let written = wideCharToMultiByte(65001'u32, 0, cast[ptr uint16](src), -1, cast[cstring](addr buf[0]), 1024, nil, nil)
      if written > 1:
        dst.setLen(written - 1)
        copyMem(addr dst[0], addr buf[0], written - 1)
      else:
        dst.setLen(0)
    else:
      dst.setLen(0)

proc toUtf8*(src: ptr UncheckedArray[uint16]): string {.inline, raises: [].} =
  utf16ToUtf8Fast(src, result)

proc toFileAttributes*(dwAttrs: DWORD): set[FileAttribute] {.inline, raises: [].} =
  ## Maps Win32 attribute bitmask to uniform FileAttribute set.
  var res: set[FileAttribute] = {}
  if (dwAttrs and FILE_ATTRIBUTE_READONLY) != 0: res.incl(faReadOnly)
  if (dwAttrs and FILE_ATTRIBUTE_HIDDEN) != 0: res.incl(faHidden)
  if (dwAttrs and FILE_ATTRIBUTE_SYSTEM) != 0: res.incl(faSystem)
  if (dwAttrs and FILE_ATTRIBUTE_DIRECTORY) != 0: res.incl(faDirectory)
  if (dwAttrs and FILE_ATTRIBUTE_ARCHIVE) != 0: res.incl(faArchive)
  if (dwAttrs and FILE_ATTRIBUTE_DEVICE) != 0: res.incl(faDevice)
  if (dwAttrs and FILE_ATTRIBUTE_NORMAL) != 0: res.incl(faNormal)
  if (dwAttrs and FILE_ATTRIBUTE_TEMPORARY) != 0: res.incl(faTemporary)
  if (dwAttrs and FILE_ATTRIBUTE_SPARSE_FILE) != 0: res.incl(faSparse)
  if (dwAttrs and FILE_ATTRIBUTE_REPARSE_POINT) != 0: res.incl(faReparsePoint)
  if (dwAttrs and FILE_ATTRIBUTE_COMPRESSED) != 0: res.incl(faCompressed)
  if (dwAttrs and FILE_ATTRIBUTE_OFFLINE) != 0: res.incl(faOffline)
  if (dwAttrs and FILE_ATTRIBUTE_ENCRYPTED) != 0: res.incl(faEncrypted)
  res

proc fileTimeToUnixNs*(ft: FILETIME): int64 {.inline, raises: [].} =
  ## Converts Win32 100ns intervals since 1601 to Unix epoch nanoseconds.
  let ftVal = (uint64(ft.dwHighDateTime) shl 32) or uint64(ft.dwLowDateTime)
  const EPOCH_DIFF = 116444736000000000'u64
  if ftVal >= EPOCH_DIFF:
    int64(ftVal - EPOCH_DIFF) * 100'i64
  else:
    0'i64

proc fileTimeToUnixSec*(ft: FILETIME): int64 {.inline, raises: [].} =
  ## Converts Win32 FILETIME to Unix epoch seconds.
  let ftVal = (uint64(ft.dwHighDateTime) shl 32) or uint64(ft.dwLowDateTime)
  const EPOCH_DIFF = 116444736000000000'u64
  if ftVal >= EPOCH_DIFF:
    int64((ftVal - EPOCH_DIFF) div 10_000_000'u64)
  else:
    0'i64

# =============================================================================
# 4. Cluster Geometry & Size On Disk
# =============================================================================

proc calculateSizeOnDisk*(fileSize: int64, clusterSize: int): int64 {.inline, raises: [].} =
  ## Computes the physical allocation size on disk based on cluster geometry.
  ## Edge cases:
  ## - fileSize <= 0: 0 bytes (0-byte file occupies no data clusters on NTFS)
  ## - clusterSize <= 0: returns fileSize
  if fileSize <= 0: return 0'i64
  if clusterSize <= 0: return fileSize
  let c = int64(clusterSize)
  ((fileSize + c - 1) div c) * c

proc getVolumeRootPath*(path: string): string {.inline, raises: [].} =
  if path.len >= 2 and path[1] == ':':
    result = $path[0] & ":\\"
  elif path.len >= 2 and ((path[0] == '\\' and path[1] == '\\') or (path[0] == '/' and path[1] == '/')):
    var slashCount = 0
    var endIdx = path.len
    for i in 2 ..< path.len:
      if path[i] == '\\' or path[i] == '/':
        inc slashCount
        if slashCount == 2:
          endIdx = i + 1
          break
    result = path[0 ..< endIdx]
    if result[^1] != '\\' and result[^1] != '/':
      result.add('\\')
  else:
    result = "C:\\"

proc win32GetClusterGeometry*(path: string): Result[tuple[clusterSize: int, sectorsPerCluster: int, bytesPerSector: int], IOError] =
  ## Retrieves cluster geometry for the volume housing `path`.
  when defined(windows):
    let root = getVolumeRootPath(path)
    var spc, bps, freeClust, totClust: DWORD
    let wRoot = newWideCString(root)
    if getDiskFreeSpaceW(wRoot, addr spc, addr bps, addr freeClust, addr totClust) == 0:
      return err[tuple[clusterSize: int, sectorsPerCluster: int, bytesPerSector: int], IOError](
        IOError(msg: "GetDiskFreeSpaceW failed for '" & root & "': error " & $getLastError()))
    let cSize = int(spc) * int(bps)
    ok[tuple[clusterSize: int, sectorsPerCluster: int, bytesPerSector: int], IOError](
      (clusterSize: cSize, sectorsPerCluster: int(spc), bytesPerSector: int(bps)))
  else:
    ok[tuple[clusterSize: int, sectorsPerCluster: int, bytesPerSector: int], IOError](
      (clusterSize: 4096, sectorsPerCluster: 8, bytesPerSector: 512))

proc win32GetVolumeInfo*(path: string): Result[Win32VolumeInfo, IOError] =
  ## Retrieves volume label, filesystem type, serial number, and capacity.
  when defined(windows):
    let root = getVolumeRootPath(path)
    let wRoot = newWideCString(root)
    var volNameBuf: array[260, uint16]
    var fsNameBuf: array[260, uint16]
    var serialNum, maxCompLen, fsFlags: DWORD

    if getVolumeInformationW(
      wRoot,
      addr volNameBuf[0], 260,
      addr serialNum,
      addr maxCompLen,
      addr fsFlags,
      addr fsNameBuf[0], 260
    ) == 0:
      return err[Win32VolumeInfo, IOError](IOError(msg: "GetVolumeInformationW failed for '" & root & "': error " & $getLastError()))

    var freeAvail, totalBytes, totalFree: int64
    discard getDiskFreeSpaceExW(wRoot, addr freeAvail, addr totalBytes, addr totalFree)

    var spc, bps, freeC, totC: DWORD
    discard getDiskFreeSpaceW(wRoot, addr spc, addr bps, addr freeC, addr totC)
    let clusterSize = int(spc) * int(bps)

    var volName, fsName: string
    utf16ToUtf8Fast(cast[ptr UncheckedArray[uint16]](addr volNameBuf[0]), volName)
    utf16ToUtf8Fast(cast[ptr UncheckedArray[uint16]](addr fsNameBuf[0]), fsName)

    ok[Win32VolumeInfo, IOError](Win32VolumeInfo(
      volumeName: volName,
      fsType: fsName,
      serialNumber: serialNum,
      totalBytes: totalBytes,
      freeBytes: totalFree,
      clusterSize: clusterSize,
      sectorsPerCluster: int(spc),
      bytesPerSector: int(bps)
    ))
  else:
    ok[Win32VolumeInfo, IOError](Win32VolumeInfo(
      volumeName: "",
      fsType: "NTFS",
      serialNumber: 0,
      totalBytes: 0,
      freeBytes: 0,
      clusterSize: 4096,
      sectorsPerCluster: 8,
      bytesPerSector: 512
    ))

proc win32GetAllocatedFileSize*(filePath: string, fileSize: int64, dwAttrs: DWORD, clusterSize: int): int64 =
  ## Returns physical allocation on disk.
  ## For compressed or sparse files, queries GetCompressedFileSizeW directly.
  when defined(windows):
    if (dwAttrs and (FILE_ATTRIBUTE_COMPRESSED or FILE_ATTRIBUTE_SPARSE_FILE)) != 0:
      var high: DWORD = 0
      let wPath = newWideCString(filePath)
      let low = getCompressedFileSizeW(wPath, addr high)
      if low != 0xFFFFFFFF'u32 or getLastError() == 0:
        return (int64(high) shl 32) or int64(low)
  calculateSizeOnDisk(fileSize, clusterSize)

proc win32GetFileStat*(path: string): Result[Win32DirEntry, IOError] =
  ## Queries metadata for a specific filesystem path.
  when defined(windows):
    let wPath = newWideCString(path)
    var fad: WIN32_FILE_ATTRIBUTE_DATA
    if getFileAttributesExW(wPath, 0, addr fad) == 0:
      return err[Win32DirEntry, IOError](IOError(msg: "Failed to stat file '" & path & "': error " & $getLastError()))
    let size = (int64(fad.nFileSizeHigh) shl 32) or int64(fad.nFileSizeLow)
    let clusterGeom = win32GetClusterGeometry(path)
    let cSize = if clusterGeom.isOk: clusterGeom.get.clusterSize else: 4096
    let allocSize = win32GetAllocatedFileSize(path, size, fad.dwFileAttributes, cSize)
    var slashIdx = -1
    for i in countdown(path.len - 1, 0):
      if path[i] == '\\' or path[i] == '/':
        slashIdx = i
        break
    let name = if slashIdx >= 0: path[slashIdx + 1 .. ^1] else: path
    ok[Win32DirEntry, IOError](Win32DirEntry(
      name: name,
      path: path,
      isDir: (fad.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0,
      isSymlink: (fad.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) != 0,
      size: size,
      allocatedSize: allocSize,
      creationTime: fileTimeToUnixNs(fad.ftCreationTime),
      lastAccessTime: fileTimeToUnixNs(fad.ftLastAccessTime),
      lastWriteTime: fileTimeToUnixNs(fad.ftLastWriteTime),
      attributes: toFileAttributes(fad.dwFileAttributes)
    ))
  else:
    ok[Win32DirEntry, IOError](Win32DirEntry(name: path, path: path))

# =============================================================================
# 5. Fast Directory Enumeration
# =============================================================================

iterator win32WalkDir*(dirPath: string, clusterSize: int = 4096): Win32DirEntry =
  ## High-speed non-recursive directory walker using FindFirstFileExW.
  when defined(windows):
    let basePath = if dirPath.len > 0 and (dirPath[^1] == '\\' or dirPath[^1] == '/'):
                     dirPath
                   else:
                     dirPath & "\\"
    let pattern = basePath & "*"
    let wPattern = newWideCString(pattern)
    var fd: WIN32_FIND_DATAW
    let hFind = findFirstFileExW(
      wPattern,
      FindExInfoBasic,
      addr fd,
      FindExSearchNameMatch,
      nil,
      FIND_FIRST_EX_LARGE_FETCH
    )
    if hFind != INVALID_HANDLE_VALUE:
      try:
        var entry: Win32DirEntry
        while true:
          let pW = cast[ptr UncheckedArray[uint16]](addr fd.cFileName[0])
          if not isDotOrDotDot(pW):
            utf16ToUtf8Fast(pW, entry.name)
            entry.path = basePath & entry.name
            entry.isDir = (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0
            entry.isSymlink = (fd.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) != 0
            entry.size = (int64(fd.nFileSizeHigh) shl 32) or int64(fd.nFileSizeLow)
            if (fd.dwFileAttributes and (FILE_ATTRIBUTE_COMPRESSED or FILE_ATTRIBUTE_SPARSE_FILE)) != 0:
              entry.allocatedSize = win32GetAllocatedFileSize(entry.path, entry.size, fd.dwFileAttributes, clusterSize)
            else:
              entry.allocatedSize = calculateSizeOnDisk(entry.size, clusterSize)
            entry.creationTime = fileTimeToUnixNs(fd.ftCreationTime)
            entry.lastAccessTime = fileTimeToUnixNs(fd.ftLastAccessTime)
            entry.lastWriteTime = fileTimeToUnixNs(fd.ftLastWriteTime)
            entry.attributes = toFileAttributes(fd.dwFileAttributes)
            yield entry
          if findNextFileW(hFind, addr fd) == 0:
            break
      finally:
        discard findClose(hFind)

# =============================================================================
# 6. USN Journal & MFT Streaming Foundation (WizTree Engine)
# =============================================================================

proc mftIndex*(frn: uint64): uint64 {.inline, raises: [].} =
  ## Masks out sequence number to yield 48-bit MFT record index.
  frn and 0x0000FFFFFFFFFFFF'u64

proc sequenceNumber*(frn: uint64): uint16 {.inline, raises: [].} =
  ## Extracts 16-bit sequence number from a 64-bit FRN.
  uint16(frn shr 48)

proc recordLength*(v: UsnRecordView): uint32 {.inline, raises: [].} =
  cast[ptr uint32](v.raw)[]

proc majorVersion*(v: UsnRecordView): uint16 {.inline, raises: [].} =
  cast[ptr uint16](cast[uint](v.raw) + 4)[]

proc minorVersion*(v: UsnRecordView): uint16 {.inline, raises: [].} =
  cast[ptr uint16](cast[uint](v.raw) + 6)[]

proc fileReferenceNumber*(v: UsnRecordView): uint64 {.inline, raises: [].} =
  cast[ptr uint64](cast[uint](v.raw) + 8)[]

proc sequenceNumber*(v: UsnRecordView): uint16 {.inline, raises: [].} =
  ## Extracts 16-bit sequence number from a USN record view.
  sequenceNumber(v.fileReferenceNumber)

proc parentFileReferenceNumber*(v: UsnRecordView): uint64 {.inline, raises: [].} =
  cast[ptr uint64](cast[uint](v.raw) + 16)[]

proc fileIndex*(v: UsnRecordView): uint64 {.inline, raises: [].} =
  v.fileReferenceNumber.mftIndex

proc parentFileIndex*(v: UsnRecordView): uint64 {.inline, raises: [].} =
  v.parentFileReferenceNumber.mftIndex

proc usn*(v: UsnRecordView): USN {.inline, raises: [].} =
  cast[ptr USN](cast[uint](v.raw) + 24)[]

proc timeStamp*(v: UsnRecordView): int64 {.inline, raises: [].} =
  cast[ptr int64](cast[uint](v.raw) + 32)[]

proc reason*(v: UsnRecordView): uint32 {.inline, raises: [].} =
  cast[ptr uint32](cast[uint](v.raw) + 40)[]

proc sourceInfo*(v: UsnRecordView): uint32 {.inline, raises: [].} =
  cast[ptr uint32](cast[uint](v.raw) + 44)[]

proc securityId*(v: UsnRecordView): uint32 {.inline, raises: [].} =
  cast[ptr uint32](cast[uint](v.raw) + 48)[]

proc fileAttributes*(v: UsnRecordView): uint32 {.inline, raises: [].} =
  cast[ptr uint32](cast[uint](v.raw) + 52)[]

proc fileNameLength*(v: UsnRecordView): uint16 {.inline, raises: [].} =
  cast[ptr uint16](cast[uint](v.raw) + 56)[]

proc fileNameOffset*(v: UsnRecordView): uint16 {.inline, raises: [].} =
  cast[ptr uint16](cast[uint](v.raw) + 58)[]

proc rawFileNameUtf16*(v: UsnRecordView): ptr UncheckedArray[uint16] {.inline, raises: [].} =
  cast[ptr UncheckedArray[uint16]](cast[uint](v.raw) + uint(v.fileNameOffset))

proc fileName*(v: UsnRecordView, dst: var string) {.inline, raises: [].} =
  let byteLen = int(v.fileNameLength)
  if byteLen <= 0:
    dst.setLen(0)
    return
  let charCount = byteLen div 2
  let pU16 = v.rawFileNameUtf16
  var isAscii = true
  for i in 0 ..< charCount:
    if pU16[i] >= 0x80'u16:
      isAscii = false
      break
  if isAscii:
    dst.setLen(charCount)
    for i in 0 ..< charCount:
      dst[i] = char(pU16[i])
  else:
    when defined(windows):
      var buf: array[1024, char]
      let written = wideCharToMultiByte(65001'u32, 0, cast[ptr uint16](pU16), int32(charCount), cast[cstring](addr buf[0]), 1024, nil, nil)
      if written > 0:
        dst.setLen(written)
        copyMem(addr dst[0], addr buf[0], written)
      else:
        dst.setLen(0)
    else:
      dst.setLen(0)

proc fileName*(v: UsnRecordView): string {.inline, raises: [].} =
  v.fileName(result)

iterator parseUsnRecords*(buf: openArray[byte], isMftEnumBuffer: bool = false): UsnRecordView =
  ## Parses a sequence of UsnRecordView from raw buffer.
  ## If isMftEnumBuffer is true, the first 8 bytes contain NextUsn and are skipped.
  var offset = if isMftEnumBuffer: 8 else: 0
  while offset + sizeof(uint32) <= buf.len:
    let pRec = cast[ptr byte](unsafeAddr buf[offset])
    let recLen = cast[ptr uint32](pRec)[]
    if recLen == 0 or offset + int(recLen) > buf.len:
      break
    yield UsnRecordView(raw: pRec)
    offset += int(recLen)

proc getNextUsn*(buf: openArray[byte]): USN {.inline, raises: [].} =
  ## Extracts the continuation NextUsn from the start of an MFT enumeration buffer.
  if buf.len >= sizeof(USN):
    cast[ptr USN](unsafeAddr buf[0])[]
  else:
    0'i64

proc parseUsnRecord*(buf: openArray[byte], offset: int): UsnRecordV2 =
  ## Materializes a single concrete UsnRecordV2 from buffer offset.
  let pRec = cast[ptr byte](unsafeAddr buf[offset])
  let view = UsnRecordView(raw: pRec)
  result = UsnRecordV2(
    recordLength: view.recordLength,
    majorVersion: view.majorVersion,
    minorVersion: view.minorVersion,
    fileReferenceNumber: view.fileReferenceNumber,
    parentFileReferenceNumber: view.parentFileReferenceNumber,
    usn: view.usn,
    timeStamp: view.timeStamp,
    reason: view.reason,
    sourceInfo: view.sourceInfo,
    securityId: view.securityId,
    fileAttributes: view.fileAttributes,
    fileName: view.fileName
  )
