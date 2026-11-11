## corex/platform/posix/posix_fs — High-Performance POSIX Filesystem Fallback
##
## Implements:
## 1. Directory enumeration via <dirent.h> (opendir, readdir, closedir)
## 2. Metadata inspection via <sys/stat.h> (lstat) with nanosecond timestamps
## 3. Volume & cluster geometry inspection via <sys/statvfs.h> (statvfs)
## 4. Symlink cycle protection and zero-allocation dot skipping

import ../../result

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

  PosixDirEntry* = object
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

  PosixVolumeInfo* = object
    volumeName*: string
    fsType*: string
    serialNumber*: uint32
    totalBytes*: int64
    freeBytes*: int64
    clusterSize*: int

proc calculateSizeOnDisk*(fileSize: int64, clusterSize: int): int64 {.inline, raises: [].} =
  ## Computes the physical allocation size on disk based on cluster geometry.
  ## Edge cases:
  ## - fileSize <= 0: 0 bytes
  ## - clusterSize <= 0: returns fileSize
  if fileSize <= 0: return 0'i64
  if clusterSize <= 0: return fileSize
  let c = int64(clusterSize)
  ((fileSize + c - 1) div c) * c

when defined(posix):
  import std/posix

  proc isDotOrDotDot(name: ptr UncheckedArray[cchar]): bool {.inline, raises: [].} =
    if name[0] == '.'.cchar:
      if name[1] == 0.cchar: return true
      if name[1] == '.'.cchar and name[2] == 0.cchar: return true
    false

  proc toFileAttributes*(st_mode: Mode, name: string): set[FileAttribute] {.inline, raises: [].} =
    var res: set[FileAttribute] = {}
    if S_ISDIR(st_mode): res.incl(faDirectory)
    if S_ISLNK(st_mode): res.incl(faReparsePoint)
    if S_ISCHR(st_mode) or S_ISBLK(st_mode): res.incl(faDevice)
    if (st_mode and 0o222.Mode) == 0: res.incl(faReadOnly)
    if name.len > 0 and name[0] == '.': res.incl(faHidden)
    if res == {}: res.incl(faNormal)
    res

  iterator posixWalkDir*(dirPath: string, clusterSize: int = 4096): PosixDirEntry =
    let d = opendir(dirPath.cstring)
    if d != nil:
      try:
        let basePath = if dirPath.len > 0 and dirPath[^1] == '/':
                         dirPath
                       else:
                         dirPath & "/"
        while true:
          let ent = readdir(d)
          if ent == nil: break
          let pName = cast[ptr UncheckedArray[cchar]](addr ent.d_name[0])
          if not isDotOrDotDot(pName):
            let name = $cast[cstring](addr ent.d_name[0])
            let fullPath = basePath & name
            var st: Stat
            if lstat(fullPath.cstring, st) == 0:
              let isDir = S_ISDIR(st.st_mode)
              let isLnk = S_ISLNK(st.st_mode)
              let size = int64(st.st_size)
              let allocSize = int64(st.st_blocks) * 512'i64
              let aTime = int64(st.st_atim.tv_sec) * 1_000_000_000'i64 + int64(st.st_atim.tv_nsec)
              let mTime = int64(st.st_mtim.tv_sec) * 1_000_000_000'i64 + int64(st.st_mtim.tv_nsec)
              let cTime = int64(st.st_ctim.tv_sec) * 1_000_000_000'i64 + int64(st.st_ctim.tv_nsec)
              let attrs = toFileAttributes(st.st_mode, name)
              yield PosixDirEntry(
                name: name,
                path: fullPath,
                isDir: isDir,
                isSymlink: isLnk,
                size: size,
                allocatedSize: allocSize,
                creationTime: cTime,
                lastAccessTime: aTime,
                lastWriteTime: mTime,
                attributes: attrs
              )
      finally:
        discard closedir(d)

  proc posixGetFileStat*(path: string): Result[PosixDirEntry, IOError] =
    var st: Stat
    if lstat(path.cstring, st) != 0:
      return err[PosixDirEntry, IOError](IOError(msg: "lstat failed for: " & path))
    let isDir = S_ISDIR(st.st_mode)
    let isLnk = S_ISLNK(st.st_mode)
    let size = int64(st.st_size)
    let allocSize = int64(st.st_blocks) * 512'i64
    let aTime = int64(st.st_atim.tv_sec) * 1_000_000_000'i64 + int64(st.st_atim.tv_nsec)
    let mTime = int64(st.st_mtim.tv_sec) * 1_000_000_000'i64 + int64(st.st_mtim.tv_nsec)
    let cTime = int64(st.st_ctim.tv_sec) * 1_000_000_000'i64 + int64(st.st_ctim.tv_nsec)
    var slashIdx = -1
    for i in countdown(path.len - 1, 0):
      if path[i] == '/':
        slashIdx = i
        break
    let name = if slashIdx >= 0: path[slashIdx + 1 .. ^1] else: path
    let attrs = toFileAttributes(st.st_mode, name)
    ok[PosixDirEntry, IOError](PosixDirEntry(
      name: name,
      path: path,
      isDir: isDir,
      isSymlink: isLnk,
      size: size,
      allocatedSize: allocSize,
      creationTime: cTime,
      lastAccessTime: aTime,
      lastWriteTime: mTime,
      attributes: attrs
    ))

  proc posixGetVolumeInfo*(path: string): Result[PosixVolumeInfo, IOError] =
    var sv: Statvfs
    if statvfs(path.cstring, sv) != 0:
      return err[PosixVolumeInfo, IOError](IOError(msg: "statvfs failed for: " & path))
    let clusterSize = int(if sv.f_frsize > 0: sv.f_frsize else: sv.f_bsize)
    let totalBytes = int64(sv.f_blocks) * int64(clusterSize)
    let freeBytes = int64(sv.f_bavail) * int64(clusterSize)
    let serialNum = uint32(sv.f_fsid and 0xFFFFFFFF'u)
    ok[PosixVolumeInfo, IOError](PosixVolumeInfo(
      volumeName: path,
      fsType: "posix_fs",
      serialNumber: serialNum,
      totalBytes: totalBytes,
      freeBytes: freeBytes,
      clusterSize: clusterSize
    ))

else:
  # Dummy stubs when compiled on non-POSIX (e.g. Windows)
  iterator posixWalkDir*(dirPath: string, clusterSize: int = 4096): PosixDirEntry =
    discard

  proc posixGetFileStat*(path: string): Result[PosixDirEntry, IOError] =
    ok[PosixDirEntry, IOError](PosixDirEntry())

  proc posixGetVolumeInfo*(path: string): Result[PosixVolumeInfo, IOError] =
    ok[PosixVolumeInfo, IOError](PosixVolumeInfo())
