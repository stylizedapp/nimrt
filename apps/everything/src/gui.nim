## apps/everything/src/gui — Everything-Nim Main GUI Application Entrypoint
##
## Coordinates:
## - Persistent configuration loading (%APPDATA%\everything-nim\config.json)
## - First-launch checking & initial index prompt
## - Index loading from disk (%TEMP%\everything.idx)
## - Live USN Journal background monitoring via apps/everything/src/usn_monitor
## - Pure Win32 GUI window with instant debounced search and virtual list view
## - Auto-saving index and config upon exit

import std/[os, strutils]
import corex
import corex/concurrency
import ./config
import ./indexer
import ./search
import ./usn_monitor
import ./win32_gui

var
  gIndexer*: Indexer
  gIndexLock*: SysLock
  gConfig*: Config
  gMonitor*: UsnMonitor
  gHasMonitor*: bool = false
  gSearchIndex*: SearchIndex
  gHasSearchIndex*: bool = false
  gLastProcessedCount*: int = 0
  gState*: ptr AppState = nil

proc rebuildSearchIndex*(alloc: Allocator = Allocator()) =
  ## Rebuilds the fast binary search and Bloom filter indices over gIndexer.
  let effAlloc = if alloc.allocFn != nil: alloc
                 elif gIndexer.alloc.allocFn != nil: gIndexer.alloc
                 else: heapAllocator()
  var sRes = initSearchIndex(addr gIndexer, effAlloc)
  if sRes.isOk:
    gSearchIndex = move(sRes.val)
    gHasSearchIndex = true
    logGui("SearchIndex built successfully (" & $gSearchIndex.prefixEntries.len & " entries)")
  else:
    logGui("Failed to build SearchIndex")

proc deinitSearchIndex*() =
  if gHasSearchIndex:
    deinit(gSearchIndex)
    gHasSearchIndex = false

proc performSearch*(query: string): seq[GuiItem] =
  result = @[]
  acquire(addr gIndexLock)
  defer: release(addr gIndexLock)

  # Check if background USN sync processed new records; if so, update/rebuild SearchIndex
  if gHasMonitor:
    let currentProcessed = gMonitor.recordsProcessed
    if currentProcessed != gLastProcessedCount:
      gLastProcessedCount = currentProcessed
      rebuildSearchIndex()

  let drivePrefix = if gIndexer.driveLetter != '\0': $gIndexer.driveLetter & ":\\" else: "C:\\"
  let qTrimmed = query.strip()
  let isWildcardAll = qTrimmed.len == 0 or qTrimmed == "*" or qTrimmed == "*.*"

  if gHasSearchIndex and not isWildcardAll:
    let searchResults = gSearchIndex.search(qTrimmed, limit = 2000)
    result = newSeqOfCap[GuiItem](searchResults.len)
    for sr in searchResults:
      if not gIndexer.slab.contains(sr.slabId):
        continue
      let node = gIndexer.slab[sr.slabId]
      let pathRes = gIndexer.resolvePath(sr.slabId)
      let fullPath = if pathRes.isOk and pathRes.get().len > 0:
                       let p = pathRes.get()
                       if p.len >= 2 and p[1] == ':': p else: drivePrefix & p
                     else:
                       drivePrefix & sr.name
      result.add(GuiItem(
        name: sr.name,
        path: fullPath,
        size: node.size,
        isDir: node.isDir
      ))
  elif gHasSearchIndex and isWildcardAll:
    # Empty query or wildcard all: return top items up to 2000 from prefixEntries
    let total = min(2000, gSearchIndex.prefixEntries.len)
    result = newSeqOfCap[GuiItem](total)
    for i in 0 ..< total:
      let slabId = gSearchIndex.prefixEntries[i].slabId
      if not gIndexer.slab.contains(slabId):
        continue
      let node = gIndexer.slab[slabId]
      let nameStr = gIndexer.names.resolveString(node.name)
      let pathRes = gIndexer.resolvePath(slabId)
      let fullPath = if pathRes.isOk and pathRes.get().len > 0:
                       let p = pathRes.get()
                       if p.len >= 2 and p[1] == ':': p else: drivePrefix & p
                     else:
                       drivePrefix & nameStr
      result.add(GuiItem(
        name: nameStr,
        path: fullPath,
        size: node.size,
        isDir: node.isDir
      ))
  else:
    # Fallback to linear scan if SearchIndex not yet built
    let qLower = qTrimmed.toLowerAscii()
    var count = 0
    for frn, slabId in gIndexer.nodes.pairs:
      if not gIndexer.slab.contains(slabId):
        continue
      let node = gIndexer.slab[slabId]
      let nameStr = gIndexer.names.resolveString(node.name)

      var matches = false
      if qLower.len == 0 or qLower == "*" or qLower == "*.*":
        matches = true
      else:
        matches = matchGlob(nameStr, qLower)

      if matches:
        let pathRes = gIndexer.resolvePath(slabId)
        let fullPath = if pathRes.isOk and pathRes.get().len > 0:
                         let p = pathRes.get()
                         if p.len >= 2 and p[1] == ':': p else: drivePrefix & p
                       else:
                         drivePrefix & nameStr
        result.add(GuiItem(
          name: nameStr,
          path: fullPath,
          size: node.size,
          isDir: node.isDir
        ))
        inc(count)
        if count >= 2000:
          break

proc startBackgroundUsnMonitor*() =
  if not gConfig.autosync:
    return
  let driveChar = if gConfig.drives.len > 0 and gConfig.drives[0].len > 0: gConfig.drives[0][0] else: 'C'
  var monRes = startUsnMonitor(
    idx = addr gIndexer,
    drive = driveChar,
    startUsn = gIndexer.lastUsn,
    lock = addr gIndexLock,
    pollIntervalMs = 100
  )
  if monRes.isOk:
    gMonitor = move(monRes.val)
    gHasMonitor = true

proc stopBackgroundUsnMonitor*() =
  if gHasMonitor:
    gMonitor.stop()
    gHasMonitor = false

proc syncIndex*(driveChar: char = '\0'): Result[int, IOError] =
  ## Synchronously syncs USN Journal changes into gIndexer and rebuilds SearchIndex.
  acquire(addr gIndexLock)
  defer: release(addr gIndexLock)
  let d = if driveChar != '\0': driveChar
          elif gConfig.drives.len > 0 and gConfig.drives[0].len > 0: gConfig.drives[0][0]
          else: 'C'
  var nextUsn: USN = 0
  let res = syncVolume(gIndexer, d, gIndexer.lastUsn, nextUsn)
  if res.isOk:
    gIndexer.lastUsn = nextUsn
    rebuildSearchIndex()
  res

proc mainGuiApp*(promptFirstLaunch: bool = true): int32 =
  # 0. Ensure directories exist
  ensureAppDirectories()
  logGui("mainGuiApp starting...")

  # 1. Load configuration
  gConfig = loadConfig()
  logGui("Configuration loaded, indexPath=" & gConfig.indexPath)

  # 2. Check first launch / index existence
  discard checkFirstLaunch(gConfig, promptUser = promptFirstLaunch)

  # 3. Load or create Indexer using fast heap allocator
  let alloc = heapAllocator()

  if fileExists(gConfig.indexPath):
    logGui("Loading index from: " & gConfig.indexPath)
    let loadRes = loadFromFile(alloc, gConfig.indexPath)
    if loadRes.isOk:
      gIndexer = loadRes.get
      logGui("Index loaded successfully: " & $gIndexer.len & " files")
    else:
      logGui("Failed to load index, creating empty indexer: " & loadRes.error.msg)
      let newRes = newIndexer(alloc, 4096, driveLetter = 'C')
      if newRes.isOk:
        gIndexer = newRes.get
  else:
    logGui("Index file does not exist, creating empty indexer")
    let newRes = newIndexer(alloc, 4096, driveLetter = 'C')
    if newRes.isOk:
      gIndexer = newRes.get

  # Initialize concurrency lock for thread-safe live updates
  gIndexLock = initSysLock()

  # Rebuild/init SearchIndex after index loading finishes
  rebuildSearchIndex()

  # 4. Start background real-time USN monitor thread
  startBackgroundUsnMonitor()

  # 5. Create Win32 GUI window with search callback
  gState = createMainWindow(
    hInstance = nil,
    cfg = gConfig,
    searchCb = performSearch,
    width = 900,
    height = 650
  )

  if gState.isNil:
    logGui("Failed to create main window")
    stopBackgroundUsnMonitor()
    deinitSearchIndex()
    deinitSysLock(gIndexLock)
    deinit(gIndexer)
    return 1

  # Perform initial empty query search to populate view with top files
  logGui("Performing initial empty search")
  gState.executeSearch("")

  # 6. Run Win32 Message Loop
  logGui("Entering runMessageLoop")
  let exitCode = runMessageLoop(gState)
  logGui("Exited runMessageLoop with code " & $exitCode)

  # 7. Application Shutdown & Auto-save
  stopBackgroundUsnMonitor()

  # Auto-save index to disk
  logGui("Auto-saving index to " & gConfig.indexPath)
  discard gIndexer.saveToFile(gConfig.indexPath)

  # Auto-save config
  discard saveConfig(gConfig)

  deinitSearchIndex()

  deinitSysLock(gIndexLock)
  deinit(gIndexer)
  logGui("mainGuiApp finished cleanly")

  exitCode

when isMainModule:
  let code = mainGuiApp()
  quit(code)
