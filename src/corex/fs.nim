## corex/fs — Uniform Cross-Platform Filesystem Interface
##
## Provides high-performance, uniform filesystem operations:
## - Metadata structures: `FileAttribute`, `FileStat`, `DirEntry`, `VolumeInfo`
## - Ultra-fast directory enumeration: `walkDirFast` (iterative DFS stack, zero recursion)
## - Batch sequence collector: `walkDirFastSeq`
## - Cluster geometry and "Size on Disk": `calculateSizeOnDisk`, `getVolumeInfo`
## - Single file stat queries: `getFileStat`
## - Compile-time platform dispatch to `win32_fs` on Windows and `posix_fs` on POSIX

import ./result

when defined(windows):
  import ./platform/windows/win32_fs
  export win32_fs
else:
  import ./platform/posix/posix_fs
  export posix_fs

type
  FileStat* = object
    size*: int64
    allocatedSize*: int64   ## Size on disk (cluster-aligned or sparse block allocation)
    creationTime*: int64    ## Nanoseconds since Unix epoch (1970-01-01 00:00:00 UTC)
    lastAccessTime*: int64  ## Nanoseconds since Unix epoch
    lastWriteTime*: int64   ## Nanoseconds since Unix epoch
    attributes*: set[FileAttribute]

  DirEntry* = object
    name*: string
    path*: string
    stat*: FileStat
    isDir*: bool
    isSymlink*: bool

  VolumeInfo* = object
    volumeName*: string
    fsType*: string
    serialNumber*: uint32
    totalBytes*: int64
    freeBytes*: int64
    clusterSize*: int

# =============================================================================
# Helper Queries
# =============================================================================

proc isDir*(stat: FileStat): bool {.inline, raises: [].} =
  faDirectory in stat.attributes

proc isSymlink*(stat: FileStat): bool {.inline, raises: [].} =
  faReparsePoint in stat.attributes

proc isReadOnly*(stat: FileStat): bool {.inline, raises: [].} =
  faReadOnly in stat.attributes

proc isHidden*(stat: FileStat): bool {.inline, raises: [].} =
  faHidden in stat.attributes

proc isDir*(entry: DirEntry): bool {.inline, raises: [].} =
  entry.isDir

proc isSymlink*(entry: DirEntry): bool {.inline, raises: [].} =
  entry.isSymlink

# =============================================================================
# High-Level Uniform APIs
# =============================================================================

proc getFileStat*(path: string): Result[FileStat, IOError] =
  ## Queries metadata for a specific filesystem path.
  when defined(windows):
    let r = ?win32GetFileStat(path)
    ok[FileStat, IOError](FileStat(
      size: r.size,
      allocatedSize: r.allocatedSize,
      creationTime: r.creationTime,
      lastAccessTime: r.lastAccessTime,
      lastWriteTime: r.lastWriteTime,
      attributes: r.attributes
    ))
  else:
    let r = ?posixGetFileStat(path)
    ok[FileStat, IOError](FileStat(
      size: r.size,
      allocatedSize: r.allocatedSize,
      creationTime: r.creationTime,
      lastAccessTime: r.lastAccessTime,
      lastWriteTime: r.lastWriteTime,
      attributes: r.attributes
    ))

proc getVolumeInfo*(path: string): Result[VolumeInfo, IOError] =
  ## Queries volume information (filesystem type, cluster size, total & free capacity)
  ## for the drive or mount point containing `path`.
  when defined(windows):
    let r = ?win32GetVolumeInfo(path)
    ok[VolumeInfo, IOError](VolumeInfo(
      volumeName: r.volumeName,
      fsType: r.fsType,
      serialNumber: r.serialNumber,
      totalBytes: r.totalBytes,
      freeBytes: r.freeBytes,
      clusterSize: r.clusterSize
    ))
  else:
    let r = ?posixGetVolumeInfo(path)
    ok[VolumeInfo, IOError](VolumeInfo(
      volumeName: r.volumeName,
      fsType: r.fsType,
      serialNumber: r.serialNumber,
      totalBytes: r.totalBytes,
      freeBytes: r.freeBytes,
      clusterSize: r.clusterSize
    ))

iterator walkDirFast*(dirPath: string, recursive: bool = false): DirEntry =
  ## High-performance directory traversal yielding `DirEntry` for each filesystem entry.
  ## Non-recursive by default. When `recursive = true`, traverses subdirectories depth-first,
  ## safely skipping symlinks/junctions to avoid cyclic directory loops.
  ## Uses an iterative stack to prevent compiler recursion limitations and stack overflow.
  var stack: seq[string] = @[dirPath]
  var clusterSize = 4096
  when defined(windows):
    let geomRes = win32GetClusterGeometry(dirPath)
    if geomRes.isOk:
      clusterSize = geomRes.get.clusterSize
  else:
    let volRes = posixGetVolumeInfo(dirPath)
    if volRes.isOk:
      clusterSize = volRes.get.clusterSize

  while stack.len > 0:
    let currDir = stack.pop()
    when defined(windows):
      for wEntry in win32WalkDir(currDir, clusterSize):
        let entry = DirEntry(
          name: wEntry.name,
          path: wEntry.path,
          stat: FileStat(
            size: wEntry.size,
            allocatedSize: wEntry.allocatedSize,
            creationTime: wEntry.creationTime,
            lastAccessTime: wEntry.lastAccessTime,
            lastWriteTime: wEntry.lastWriteTime,
            attributes: wEntry.attributes
          ),
          isDir: wEntry.isDir,
          isSymlink: wEntry.isSymlink
        )
        yield entry
        if recursive and entry.isDir and not entry.isSymlink:
          stack.add(entry.path)
    else:
      for pEntry in posixWalkDir(currDir, clusterSize):
        let entry = DirEntry(
          name: pEntry.name,
          path: pEntry.path,
          stat: FileStat(
            size: pEntry.size,
            allocatedSize: pEntry.allocatedSize,
            creationTime: pEntry.creationTime,
            lastAccessTime: pEntry.lastAccessTime,
            lastWriteTime: pEntry.lastWriteTime,
            attributes: pEntry.attributes
          ),
          isDir: pEntry.isDir,
          isSymlink: pEntry.isSymlink
        )
        yield entry
        if recursive and entry.isDir and not entry.isSymlink:
          stack.add(entry.path)

proc walkDirFastSeq*(dirPath: string, recursive: bool = false): seq[DirEntry] =
  ## Convenience procedure collecting all entries from `walkDirFast` into a `seq[DirEntry]`.
  result = @[]
  for entry in walkDirFast(dirPath, recursive):
    result.add(entry)
