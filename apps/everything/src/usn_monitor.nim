## apps/everything/src/usn_monitor — Real-Time NTFS USN Journal Monitor & Live Sync
##
## Spawns a background thread that continuously monitors raw NTFS USN Journal changes
## via FSCTL_READ_USN_JOURNAL, applying incremental create, rename, modify, and delete
## events to an in-memory Everything-style Indexer.
##
## Features:
## - Native Nim thread (`std/threads`) with ARC/ORC memory safety.
## - Responsive non-blocking stop mechanism using atomic flags & sliced polling.
## - Clean RAII resource destruction (=destroy joins thread, closes volume handle, frees buffers).
## - Clean non-admin privilege detection with descriptive error reporting.
## - Synchronous volume sync API for CLI and offline index updates.

import std/[atomics, os]
import corex
import corex/concurrency
import corex/platform/windows/win32_fs
import corex/platform/windows/win32_volume
import ./indexer

type
  UsnMonitorContext* = object
    idx*: ptr Indexer
    lock*: ptr SysLock
    stopFlag*: Atomic[bool]
    isFinished*: Atomic[bool]
    drive*: char
    startUsn*: USN
    currentUsn*: USN
    pollIntervalMs*: int
    recordsProcessed*: Atomic[int]
    vol*: VolumeHandle
    isMock*: bool
    mockRawBuf*: pointer
    mockRawLen*: int

  UsnMonitor* = object
    thread*: Thread[ptr UsnMonitorContext]
    ctx*: ptr UsnMonitorContext
    running*: bool

# =============================================================================
# 1. Index Mutation Helpers (Create / Rename / Modify / Delete)
# =============================================================================

proc deleteNodeFromIndex*(idx: var Indexer, frn: uint64): bool {.inline, raises: [].} =
  ## Deletes a file node identified by FRN from the Indexer.
  when compiles(idx.removeNode(frn)):
    idx.removeNode(frn)
  elif compiles(idx.deleteNode(frn)):
    idx.deleteNode(frn)
  else:
    let opt = idx.nodes.get(frn)
    if opt.isSome:
      let slabId = opt.get
      discard idx.slab.remove(slabId)
      discard idx.nodes.del(frn)
      true
    else:
      false

proc applyUsnRecord*(idx: var Indexer, rec: UsnRecordView): bool {.discardable, raises: [].} =
  ## Applies a single USN change record to the Indexer.
  ## Handles deletion, creation, renaming, and metadata updates according to reason mask.
  let reason = rec.reason

  # 1. File Deletion
  if (reason and USN_REASON_FILE_DELETE) != 0:
    return idx.deleteNodeFromIndex(rec.fileReferenceNumber)

  # 2. Rename Old Name (skip, wait for RENAME_NEW_NAME)
  if (reason and USN_REASON_RENAME_OLD_NAME) != 0 and (reason and USN_REASON_RENAME_NEW_NAME) == 0:
    return false

  # 3. Rename New Name / File Creation / Attribute Modification / Data Change
  let res = idx.insertFromUsn(rec)
  res.isOk

proc applyUsnBuffer*(
  idx: var Indexer,
  buffer: openArray[byte],
  bytesRead: int,
  lastUsn: var USN
): int {.raises: [].} =
  ## Parses USN records from `buffer[0 ..< bytesRead]` and applies changes to `idx`.
  ## Updates `lastUsn` with continuation NextUsn from the 8-byte header.
  ## Returns number of records applied.
  if bytesRead < sizeof(USN):
    return 0
  lastUsn = cast[ptr USN](unsafeAddr buffer[0])[]
  var count = 0
  if bytesRead > sizeof(USN):
    let slice = buffer[0 ..< bytesRead]
    for view in parseUsnRecords(slice, isMftEnumBuffer = true):
      if idx.applyUsnRecord(view):
        inc count
  count

# =============================================================================
# 2. Background Thread Worker Loop
# =============================================================================

proc usnMonitorWorker(ctx: ptr UsnMonitorContext) {.thread.} =
  {.cast(gcsafe).}:
    var buffer = newSeq[byte](65536)

    while not ctx.stopFlag.load(moAcquire):
      if ctx.isMock:
        if ctx.mockRawBuf != nil and ctx.mockRawLen > 0:
          let bufLen = ctx.mockRawLen
          let pBytes = cast[ptr UncheckedArray[byte]](ctx.mockRawBuf)
          if not ctx.lock.isNil: ctx.lock.acquire()
          let count = applyUsnBuffer(ctx.idx[], toOpenArray(pBytes, 0, bufLen - 1), bufLen, ctx.currentUsn)
          if not ctx.lock.isNil: ctx.lock.release()

          discard atomics.fetchAdd(ctx.recordsProcessed, count, moRelaxed)
          ctx.mockRawLen = 0
      else:
        when defined(windows):
          var res = ctx.vol.readUsnJournal(ctx.currentUsn, 0xFFFFFFFF'u32, buffer)
          if res.isOk:
            let bytesRead = res.get
            if bytesRead > sizeof(USN):
              if not ctx.lock.isNil: ctx.lock.acquire()
              let count = applyUsnBuffer(ctx.idx[], buffer, bytesRead, ctx.currentUsn)
              if not ctx.lock.isNil: ctx.lock.release()
              discard atomics.fetchAdd(ctx.recordsProcessed, count, moRelaxed)
            elif bytesRead == sizeof(USN):
              ctx.currentUsn = cast[ptr USN](addr buffer[0])[]
          else:
            # If read fails (e.g. journal wrapped or error), sleep before retrying
            discard

      # Sleep in small 10ms slices for instant stop reaction
      let slices = max(1, ctx.pollIntervalMs div 10)
      for _ in 0 ..< slices:
        if ctx.stopFlag.load(moAcquire):
          break
        os.sleep(10)

    ctx.isFinished.store(true, moRelease)

# =============================================================================
# 3. Monitor Lifecycle Management & RAII
# =============================================================================

proc isRunning*(m: UsnMonitor): bool {.inline, raises: [].} =
  m.running

proc recordsProcessed*(m: UsnMonitor): int {.inline, raises: [].} =
  if m.ctx.isNil: 0 else: m.ctx.recordsProcessed.load(moRelaxed)

proc currentUsn*(m: UsnMonitor): USN {.inline, raises: [].} =
  if m.ctx.isNil: 0'i64 else: m.ctx.currentUsn

proc stop*(m: var UsnMonitor) {.raises: [].} =
  ## Signals the monitor background thread to terminate and waits for join.
  if m.running and not m.ctx.isNil:
    m.ctx.stopFlag.store(true, moRelease)
    joinThread(m.thread)
    m.running = false
    if not m.ctx.isMock:
      when defined(windows):
        m.ctx.vol.closeVolume()
    if m.ctx.mockRawBuf != nil:
      deallocShared(m.ctx.mockRawBuf)
      m.ctx.mockRawBuf = nil
      m.ctx.mockRawLen = 0

proc `=destroy`*(m: var UsnMonitor) {.raises: [].} =
  m.stop()
  if not m.ctx.isNil:
    deallocShared(m.ctx)
    m.ctx = nil

proc `=wasMoved`*(m: var UsnMonitor) {.inline, raises: [].} =
  m.ctx = nil
  m.running = false

proc `=sink`*(dest: var UsnMonitor, src: UsnMonitor) {.raises: [].} =
  if dest.running and not dest.ctx.isNil:
    dest.stop()
  if not dest.ctx.isNil:
    deallocShared(dest.ctx)
    dest.ctx = nil

  copyMem(addr dest.thread, unsafeAddr src.thread, sizeof(dest.thread))
  dest.ctx = src.ctx
  dest.running = src.running

  # Neutralize src so that src's =destroy does not terminate dest's active thread
  cast[ptr UsnMonitor](unsafeAddr src).ctx = nil
  cast[ptr UsnMonitor](unsafeAddr src).running = false

proc `=copy`*(dest: var UsnMonitor, src: UsnMonitor) {.error: "UsnMonitor cannot be copied; use move semantics".}

# =============================================================================
# 4. Constructors (Live Volume & Mock Feeder)
# =============================================================================

proc startUsnMonitor*(
  idx: ptr Indexer,
  drive: char,
  startUsn: USN = 0'i64,
  lock: ptr SysLock = nil,
  pollIntervalMs: int = 100
): Result[UsnMonitor, IOError] {.raises: [].} =
  ## Starts a real-time USN Journal reader background thread for `drive`.
  ## Returns IOError with descriptive administrator required message if non-elevated.
  var volRes = openVolume(drive)
  if volRes.isErr:
    return err[UsnMonitor, IOError](volRes.error)

  var vol = move(volRes.val)
  var usn = startUsn
  if usn == 0'i64:
    let qRes = vol.queryUsnJournal()
    if qRes.isOk:
      usn = qRes.val.NextUsn

  var ctx = cast[ptr UsnMonitorContext](allocShared0(sizeof(UsnMonitorContext)))
  ctx.idx = idx
  ctx.lock = lock
  ctx.drive = drive
  ctx.startUsn = usn
  ctx.currentUsn = usn
  ctx.pollIntervalMs = pollIntervalMs
  ctx.vol = move(vol)
  ctx.isMock = false

  var mon: UsnMonitor
  mon.ctx = ctx
  mon.running = false
  try:
    createThread(mon.thread, usnMonitorWorker, ctx)
    mon.running = true
  except CatchableError as e:
    deallocShared(ctx)
    return err[UsnMonitor, IOError](IOError(msg: "Failed to spawn USN monitor thread: " & e.msg))
  ok[UsnMonitor, IOError](mon)

proc startMockUsnMonitor*(
  idx: ptr Indexer,
  mockData: openArray[byte] = [],
  startUsn: USN = 0'i64,
  lock: ptr SysLock = nil,
  pollIntervalMs: int = 10
): UsnMonitor {.raises: [].} =
  ## Starts a background USN monitor thread reading from a mock buffer.
  var ctx = cast[ptr UsnMonitorContext](allocShared0(sizeof(UsnMonitorContext)))
  ctx.idx = idx
  ctx.lock = lock
  ctx.startUsn = startUsn
  ctx.currentUsn = startUsn
  ctx.pollIntervalMs = pollIntervalMs
  ctx.isMock = true
  if mockData.len > 0:
    ctx.mockRawBuf = allocShared(mockData.len)
    copyMem(ctx.mockRawBuf, unsafeAddr mockData[0], mockData.len)
    ctx.mockRawLen = mockData.len

  result.ctx = ctx
  result.running = false
  try:
    createThread(result.thread, usnMonitorWorker, ctx)
    result.running = true
  except CatchableError:
    discard

proc feedMockData*(m: var UsnMonitor, data: openArray[byte]) {.raises: [].} =
  ## Feeds a new buffer of mock USN records into an active mock monitor.
  if m.running and not m.ctx.isNil and m.ctx.isMock:
    if m.ctx.mockRawBuf != nil:
      deallocShared(m.ctx.mockRawBuf)
      m.ctx.mockRawBuf = nil
      m.ctx.mockRawLen = 0
    if data.len > 0:
      m.ctx.mockRawBuf = allocShared(data.len)
      copyMem(m.ctx.mockRawBuf, unsafeAddr data[0], data.len)
      m.ctx.mockRawLen = data.len

# =============================================================================
# 5. Synchronous Volume Sync (for CLI `everything sync`)
# =============================================================================

proc syncVolume*(
  idx: var Indexer,
  drive: char,
  startUsn: USN,
  nextUsn: var USN
): Result[int, IOError] {.raises: [].} =
  ## Reads all available USN journal changes synchronously since `startUsn`
  ## and applies them to `idx`. Updates `nextUsn` with the latest continuation USN.
  var volRes = openVolume(drive)
  if volRes.isErr:
    return err[int, IOError](volRes.error)
  var vol = move(volRes.val)
  defer: vol.closeVolume()

  var curUsn = startUsn
  var totalApplied = 0
  var buf = newSeq[byte](65536)

  while true:
    let rRes = vol.readUsnJournal(curUsn, 0xFFFFFFFF'u32, buf)
    if rRes.isErr:
      return err[int, IOError](rRes.error)
    let bytesRead = rRes.get
    if bytesRead <= sizeof(USN):
      if bytesRead == sizeof(USN):
        curUsn = cast[ptr USN](addr buf[0])[]
      break

    let count = applyUsnBuffer(idx, buf, bytesRead, curUsn)
    totalApplied += count

  nextUsn = curUsn
  ok[int, IOError](totalApplied)
