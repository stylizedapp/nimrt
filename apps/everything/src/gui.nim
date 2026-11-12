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
  gIndexer: Indexer
  gIndexLock: SysLock
  gConfig: Config
  gMonitor: UsnMonitor
  gHasMonitor: bool = false
  gState: ptr AppState = nil

proc performSearch(query: string): seq[GuiItem] =
  result = @[]
  acquire(addr gIndexLock)
  defer: release(addr gIndexLock)

  let drivePrefix = if gIndexer.driveLetter != '\0': $gIndexer.driveLetter & ":\\" else: "C:\\"
  let qTrimmed = query.strip()
  let qLower = qTrimmed.toLowerAscii()

  var count = 0
  for frn, slabId in gIndexer.nodes.pairs:
    if not gIndexer.slab.contains(slabId):
      continue
    let node = gIndexer.slab[slabId]
    let nameStr = gIndexer.names.resolveString(node.name)

    var matches = false
    if qLower.len == 0:
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

proc startBackgroundUsnMonitor() =
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
    copyMem(addr gMonitor, addr monRes.val, sizeof(UsnMonitor))
    zeroMem(addr monRes.val, sizeof(UsnMonitor))
    gHasMonitor = true

proc stopBackgroundUsnMonitor() =
  if gHasMonitor:
    gMonitor.stop()
    gHasMonitor = false

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

  deinitSysLock(gIndexLock)
  deinit(gIndexer)
  logGui("mainGuiApp finished cleanly")

  exitCode

when isMainModule:
  let code = mainGuiApp()
  quit(code)
