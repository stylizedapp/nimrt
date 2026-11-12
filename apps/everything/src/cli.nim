## apps/everything/src/cli — Everything-Nim High-Speed CLI Interface
##
## Supported Commands:
## 1. `everything index <Drive>`:
##    - Opens volume `\\.\<Drive>:`.
##    - Performs high-speed MFT enumeration via FSCTL_ENUM_USN_DATA.
##    - Displays live progress counter to stdout.
##    - Serializes index to `%TEMP%\everything.idx`.
##    - Non-admin handling: prints descriptive error to stderr and exits with code 1.
## 2. `everything search "<Pattern>"`:
##    - Deserializes `%TEMP%\everything.idx` into memory.
##    - Executes ultra-fast search (<100ms on 1M files).
##    - Outputs full paths to stdout.
## 3. `everything sync`:
##    - Opens volume and queries USN Journal changes since saved NextUsn.
##    - Applies incremental additions, renames, and deletions.
##    - Updates and persists index back to `%TEMP%\everything.idx`.

import std/[cmdline, strutils]
import corex
import corex/platform/windows/[win32_fs, win32_volume]
import ./indexer
import ./search
import ./usn_monitor

when defined(windows):
  proc deviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: DWORD,
    lpInBuffer: pointer,
    nInBufferSize: DWORD,
    lpOutBuffer: pointer,
    nOutBufferSize: DWORD,
    lpBytesReturned: ptr DWORD,
    lpOverlapped: pointer
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl", sideEffect.}

proc isAccessDenied(msg: string): bool {.inline.} =
  msg.contains("Win32 error 5") or
  msg.contains("Access is denied") or
  msg.contains("Administrative privileges required")

proc getEffectiveAllocator(alloc: Allocator): Allocator {.inline.} =
  if alloc.allocFn.isNil: heapAllocator() else: alloc

proc parseDrive*(driveArg: string): char =
  if driveArg.len == 0:
    return 'C'
  var s = driveArg.strip()
  if s.len > 0 and (s[0] == '\\' or s[0] == '/'):
    s = s.strip(chars = {'\\', '/', '.'})
  if s.len > 0:
    return toUpperAscii(s[0])
  'C'

# =============================================================================
# 1. Indexing Command
# =============================================================================

proc indexVolume*(
  drive: char,
  outPath: string = defaultIndexPath(),
  alloc: Allocator = Allocator(),
  showProgress: bool = true,
  outStream: File = stdout,
  errStream: File = stderr
): Result[int, IOError] =
  ## Opens volume `\\.\<drive>:`, enumerates MFT records, and writes index to `outPath`.
  var volRes = openVolume(drive)
  if volRes.isErr:
    return err[int, IOError](volRes.error)
  var vol = move(volRes.val)
  defer: vol.closeVolume()

  let usnRes = vol.queryUsnJournal()
  if usnRes.isErr:
    return err[int, IOError](usnRes.error)
  let usnData = usnRes.val

  let effectiveAlloc = getEffectiveAllocator(alloc)
  var idxRes = newIndexer(effectiveAlloc, vol.clusterSize, driveLetter = drive, initialCap = 65536)
  if idxRes.isErr:
    return err[int, IOError](ioError("Failed to allocate indexer: " & $idxRes.errVal))
  var idx = idxRes.get()
  defer: idx.deinit()
  idx.lastUsn = usnData.NextUsn
  idx.driveLetter = drive

  when defined(windows):
    var med: MFT_ENUM_DATA_V0
    med.StartFileReferenceNumber = 0'u64
    med.LowUsn = 0'i64
    med.HighUsn = usnData.NextUsn

    const bufSize = 1024 * 1024 # 1 MB buffer for fast bulk transfer
    var buf = newSeq[byte](bufSize)
    var totalIndexed = 0
    var bytesReturned: DWORD = 0

    while true:
      bytesReturned = 0
      let ret = deviceIoControl(
        vol.handle,
        FSCTL_ENUM_USN_DATA,
        addr med,
        DWORD(sizeof(MFT_ENUM_DATA_V0)),
        addr buf[0],
        DWORD(buf.len),
        addr bytesReturned,
        nil
      )
      if ret == 0 or bytesReturned <= 8'u32:
        break

      med.StartFileReferenceNumber = cast[ptr uint64](addr buf[0])[]
      let parsed = idx.bulkIndexFromBuffer(toOpenArray(buf, 0, int(bytesReturned) - 1))
      if parsed.isOk:
        totalIndexed += parsed.get()
        if showProgress:
          outStream.write("\rIndexed " & $totalIndexed & " files...")
          outStream.flushFile()

    if showProgress and totalIndexed > 0:
      outStream.writeLine("")

  let saveRes = idx.saveToFile(outPath)
  if saveRes.isErr:
    return err[int, IOError](saveRes.error)

  ok[int, IOError](idx.len)

proc runIndex*(
  driveArg: string,
  outPath: string = defaultIndexPath(),
  alloc: Allocator = Allocator(),
  showProgress: bool = true,
  outStream: File = stdout,
  errStream: File = stderr
): int =
  let drive = parseDrive(driveArg)
  let res = indexVolume(drive, outPath, alloc, showProgress, outStream, errStream)
  if res.isErr:
    let msg = res.error.msg
    if isAccessDenied(msg):
      errStream.writeLine("Error: Administrator privileges required to index NTFS USN Journal on volume " & drive & ":\nRun terminal as Administrator.")
    else:
      errStream.writeLine("Error: " & msg)
    return 1

  outStream.writeLine("Indexed " & $res.get() & " files on volume " & drive & ": -> " & outPath)
  return 0

# =============================================================================
# 2. Search Command
# =============================================================================

proc searchAndResolve*(
  idx: Indexer,
  si: SearchIndex,
  pattern: string,
  limit: int = 1000
): seq[string] =
  result = @[]
  let results = si.search(pattern, limit = limit)
  let drivePrefix = if idx.driveLetter != '\0': $idx.driveLetter & ":\\" else: ""

  for r in results:
    let pRes = idx.resolvePath(r.slabId)
    if pRes.isOk and pRes.get().len > 0:
      let relPath = pRes.get()
      if relPath.len >= 2 and relPath[1] == ':':
        result.add(relPath)
      else:
        result.add(drivePrefix & relPath)
    else:
      result.add(drivePrefix & r.name)

proc runSearch*(
  pattern: string,
  indexPath: string = defaultIndexPath(),
  alloc: Allocator = Allocator(),
  limit: int = 1000,
  outStream: File = stdout,
  errStream: File = stderr
): int =
  if pattern.len == 0:
    errStream.writeLine("Error: Search pattern cannot be empty.")
    return 1

  let effectiveAlloc = getEffectiveAllocator(alloc)
  let loadRes = loadFromFile(effectiveAlloc, indexPath)
  if loadRes.isErr:
    errStream.writeLine("Error: Index file not found or corrupted at '" & indexPath & "': " & loadRes.error.msg)
    return 1

  var idx = loadRes.get()
  defer: idx.deinit()
  var siRes = initSearchIndex(addr idx, effectiveAlloc)
  if siRes.isErr:
    errStream.writeLine("Error: Failed to initialize search index: " & $siRes.errVal)
    return 1

  var si = siRes.get()
  defer: si.deinit()
  let paths = searchAndResolve(idx, si, pattern, limit)
  for p in paths:
    outStream.writeLine(p)
  outStream.flushFile()
  return 0

# =============================================================================
# 3. Sync Command
# =============================================================================

proc runSync*(
  indexPath: string = defaultIndexPath(),
  alloc: Allocator = Allocator(),
  outStream: File = stdout,
  errStream: File = stderr
): int =
  let effectiveAlloc = getEffectiveAllocator(alloc)
  let loadRes = loadFromFile(effectiveAlloc, indexPath)
  if loadRes.isErr:
    errStream.writeLine("Error: Cannot sync, index file not found at '" & indexPath & "': " & loadRes.error.msg)
    return 1

  var idx = loadRes.get()
  defer: idx.deinit()
  let drive = if idx.driveLetter != '\0': idx.driveLetter else: 'C'

  var nextUsn: USN = 0
  let syncRes = syncVolume(idx, drive, idx.lastUsn, nextUsn)
  if syncRes.isErr:
    let msg = syncRes.error.msg
    if isAccessDenied(msg):
      errStream.writeLine("Error: Administrator privileges required to sync NTFS USN Journal on volume " & drive & ":\nRun terminal as Administrator.")
    else:
      errStream.writeLine("Error syncing USN Journal: " & msg)
    return 1

  let appliedCount = syncRes.get()
  idx.lastUsn = nextUsn

  let saveRes = idx.saveToFile(indexPath)
  if saveRes.isErr:
    errStream.writeLine("Error saving synced index: " & saveRes.error.msg)
    return 1

  outStream.writeLine("Synced " & $appliedCount & " changes on volume " & drive & ":. Updated index saved.")
  return 0

# =============================================================================
# 4. Usage & Command Dispatcher
# =============================================================================

proc printUsage*(outStream: File = stdout) =
  outStream.writeLine("Everything-Nim CLI - Ultra-Fast NTFS USN Journal Indexer & Search")
  outStream.writeLine("")
  outStream.writeLine("Usage:")
  outStream.writeLine("  everything index <Drive>       Index NTFS volume MFT/USN Journal (e.g. 'everything index C')")
  outStream.writeLine("  everything search \"<Pattern>\"  Search indexed files by pattern (e.g. 'everything search \"*.pdf\"')")
  outStream.writeLine("  everything sync                Sync USN changes since last index into existing index")
  outStream.writeLine("  everything --help              Display this help message")
  outStream.flushFile()

proc runCli*(
  args: openArray[string],
  alloc: Allocator = Allocator(),
  outStream: File = stdout,
  errStream: File = stderr
): int =
  if args.len == 0:
    printUsage(outStream)
    return 0

  let cmd = args[0].toLowerAscii()
  case cmd
  of "help", "-h", "--help", "/?":
    printUsage(outStream)
    return 0
  of "index":
    if args.len < 2:
      errStream.writeLine("Error: Missing drive argument for index command. Example: everything index C")
      return 1
    var outPath = defaultIndexPath()
    for i in 2 ..< args.len:
      if args[i].startsWith("--out:"):
        outPath = args[i][6 .. ^1]
      elif args[i].startsWith("--out="):
        outPath = args[i][6 .. ^1]
    return runIndex(args[1], outPath = outPath, alloc = alloc, showProgress = true, outStream = outStream, errStream = errStream)
  of "search":
    if args.len < 2:
      errStream.writeLine("Error: Missing search pattern. Example: everything search \"*.pdf\"")
      return 1
    var indexPath = defaultIndexPath()
    var limit = 1000
    for i in 2 ..< args.len:
      if args[i].startsWith("--index:"):
        indexPath = args[i][8 .. ^1]
      elif args[i].startsWith("--index="):
        indexPath = args[i][8 .. ^1]
      elif args[i].startsWith("--limit:"):
        try: limit = parseInt(args[i][8 .. ^1]) except CatchableError: discard
      elif args[i].startsWith("--limit="):
        try: limit = parseInt(args[i][8 .. ^1]) except CatchableError: discard
    return runSearch(args[1], indexPath = indexPath, alloc = alloc, limit = limit, outStream = outStream, errStream = errStream)
  of "sync":
    var indexPath = defaultIndexPath()
    for i in 1 ..< args.len:
      if args[i].startsWith("--index:"):
        indexPath = args[i][8 .. ^1]
      elif args[i].startsWith("--index="):
        indexPath = args[i][8 .. ^1]
    return runSync(indexPath = indexPath, alloc = alloc, outStream = outStream, errStream = errStream)
  else:
    errStream.writeLine("Error: Unknown command '" & args[0] & "'.")
    printUsage(errStream)
    return 1

proc main*(): int =
  let args = commandLineParams()
  runCli(args)

when isMainModule:
  quit(main())
