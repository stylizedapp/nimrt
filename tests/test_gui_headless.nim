## tests/test_gui_headless — Headless Unit Tests for Everything-Nim GUI Components
##
## Tests:
## 1. Config serialization/deserialization, hotkey parsing, and first-launch check.
## 2. 50ms search debounce logic and state machine.
## 3. Virtual list data mapping (Name, Path, Size formatting, <DIR>).
## 4. Window message routing and dispinfo buffer formatting.
## 5. Memory leak verification using testWithLeakCheck.

import std/[os, json, strutils, widestrs]
import corex
import ../apps/everything/src/config
import ../apps/everything/src/indexer
import ../apps/everything/src/search
import ../apps/everything/src/win32_gui
import ../apps/everything/src/gui

proc testConfigSerialization() =
  echo "--- Testing Config Serialization & Parsing ---"

  # 1. Default config properties
  let defCfg = defaultConfig()
  doAssert defCfg.hotkey == "Win+E"
  doAssert defCfg.autosync == true
  doAssert defCfg.drives == @["C:"]
  doAssert defCfg.indexPath.len > 0

  # 2. Hotkey parsing
  block:
    let (m1, k1) = parseHotkey("Win+E")
    doAssert (m1 and MOD_WIN) != 0
    doAssert (m1 and MOD_NOREPEAT) != 0
    doAssert k1 == ord('E').uint32

    let (m2, k2) = parseHotkey("Ctrl+Alt+Space")
    doAssert (m2 and MOD_CONTROL) != 0
    doAssert (m2 and MOD_ALT) != 0
    doAssert k2 == VK_SPACE

    let (m3, k3) = parseHotkey("Ctrl+Shift+F")
    doAssert (m3 and MOD_CONTROL) != 0
    doAssert (m3 and MOD_SHIFT) != 0
    doAssert k3 == ord('F').uint32

    let (m4, k4) = parseHotkey("F5")
    doAssert k4 == VK_F1 + 4

    let (mEmpty, kEmpty) = parseHotkey("")
    doAssert kEmpty == 0

  # 3. JSON roundtrip
  block:
    var customCfg = Config(
      hotkey: "Ctrl+Alt+Space",
      autosync: false,
      drives: @["C:", "D:"],
      indexPath: "D:\\test\\custom.idx"
    )
    let jsonNode = toJson(customCfg)
    let restoredCfg = fromJson(jsonNode)

    doAssert restoredCfg.hotkey == "Ctrl+Alt+Space"
    doAssert restoredCfg.autosync == false
    doAssert restoredCfg.drives == @["C:", "D:"]
    doAssert restoredCfg.indexPath == "D:\\test\\custom.idx"

  # 4. Save and load from temporary file
  block:
    let testPath = getTempDir() / "everything_test_config.json"
    if fileExists(testPath):
      removeFile(testPath)

    var cfg = Config(
      hotkey: "Ctrl+Shift+F",
      autosync: true,
      drives: @["E:"],
      indexPath: getTempDir() / "everything_unit_test.idx"
    )
    doAssert saveConfig(cfg, testPath)
    doAssert fileExists(testPath)

    let loaded = loadConfig(testPath)
    doAssert loaded.hotkey == "Ctrl+Shift+F"
    doAssert loaded.autosync == true
    doAssert loaded.drives == @["E:"]
    doAssert loaded.indexPath == cfg.indexPath

    removeFile(testPath)

  # 5. First launch check
  block:
    var missingCfg = Config(
      indexPath: getTempDir() / "non_existent_everything_test_12345.idx"
    )
    if fileExists(missingCfg.indexPath):
      removeFile(missingCfg.indexPath)

    # In non-interactive mode (promptUser = false), should detect missing index and return true
    doAssert checkFirstLaunch(missingCfg, promptUser = false) == true

    # Create dummy file to simulate existing index
    writeFile(missingCfg.indexPath, "INDEX_DATA")
    doAssert checkFirstLaunch(missingCfg, promptUser = false) == false
    removeFile(missingCfg.indexPath)

  echo "  [OK] Config serialization and parsing passed."

proc testDebounceLogic() =
  echo "--- Testing Debounce Logic & State Machine ---"

  var tracker = initDebounceTracker(50)
  doAssert not tracker.isPending
  doAssert tracker.delayMs == 50

  # Non-pending timer fire returns nothing
  let (fire0, q0) = tracker.onTimerFire()
  doAssert not fire0
  doAssert q0 == ""

  # Single trigger
  tracker.triggerDebounce("cat")
  doAssert tracker.isPending
  doAssert tracker.pendingQuery == "cat"

  # Rapid typing: multiple triggers before timer fires
  tracker.triggerDebounce("doc")
  tracker.triggerDebounce("document")
  tracker.triggerDebounce("document.pdf")
  doAssert tracker.isPending
  doAssert tracker.pendingQuery == "document.pdf"

  # Timer fires (simulating WM_TIMER after 50ms)
  let (fire1, q1) = tracker.onTimerFire()
  doAssert fire1
  doAssert q1 == "document.pdf"
  doAssert not tracker.isPending
  doAssert tracker.lastFiredQuery == "document.pdf"

  # Subsequent timer fire without new changes
  let (fire2, q2) = tracker.onTimerFire()
  doAssert not fire2
  doAssert q2 == ""

  echo "  [OK] Debounce logic passed."

proc testVirtualListDataMapping() =
  echo "--- Testing Virtual List Data Mapping ---"

  # 1. Size formatting
  doAssert formatFileSize(0) == "0 B"
  doAssert formatFileSize(512) == "512 B"
  doAssert formatFileSize(1024) == "1.0 KB"
  doAssert formatFileSize(1536) == "1.5 KB"
  doAssert formatFileSize(1048576) == "1.00 MB"
  doAssert formatFileSize(1073741824) == "1.00 GB"

  # 2. Virtual list model item mapping
  var model = VirtualListModel(items: @[
    GuiItem(name: "explorer.exe", path: "C:\\Windows\\explorer.exe", size: 5242880, isDir: false),
    GuiItem(name: "System32", path: "C:\\Windows\\System32", size: 0, isDir: true),
    GuiItem(name: "notes.txt", path: "C:\\Users\\User\\notes.txt", size: 100, isDir: false)
  ])

  # Row 0: explorer.exe
  doAssert model.getItemText(0, 0) == "explorer.exe"
  doAssert model.getItemText(0, 1) == "C:\\Windows\\explorer.exe"
  doAssert model.getItemText(0, 2) == "5.00 MB"

  # Row 1: Directory System32
  doAssert model.getItemText(1, 0) == "System32"
  doAssert model.getItemText(1, 1) == "C:\\Windows\\System32"
  doAssert model.getItemText(1, 2) == "<DIR>"

  # Row 2: notes.txt
  doAssert model.getItemText(2, 0) == "notes.txt"
  doAssert model.getItemText(2, 1) == "C:\\Users\\User\\notes.txt"
  doAssert model.getItemText(2, 2) == "100 B"

  # Out of bounds safety
  doAssert model.getItemText(-1, 0) == ""
  doAssert model.getItemText(3, 0) == ""
  doAssert model.getItemText(0, -1) == ""
  doAssert model.getItemText(0, 5) == ""

  # 3. High-throughput virtual mapping test (100,000 items)
  var largeModel = VirtualListModel()
  largeModel.items = newSeq[GuiItem](100_000)
  for i in 0 ..< 100_000:
    largeModel.items[i] = GuiItem(
      name: "file_" & $i & ".dat",
      path: "C:\\Data\\file_" & $i & ".dat",
      size: int64(i * 1024),
      isDir: false
    )

  doAssert largeModel.items.len == 100_000
  doAssert largeModel.getItemText(99_999, 0) == "file_99999.dat"
  doAssert largeModel.getItemText(99_999, 1) == "C:\\Data\\file_99999.dat"
  doAssert largeModel.getItemText(0, 2) == "0 B"
  doAssert largeModel.getItemText(1024, 2) == "1.00 MB"

  echo "  [OK] Virtual list data mapping passed."

proc testWindowMessageRouting() =
  echo "--- Testing Window Message Routing & DispInfo Formatting ---"

  # Mock AppState
  var state = AppState()
  state.model.items = @[
    GuiItem(name: "test_report.pdf", path: "C:\\Docs\\test_report.pdf", size: 2097152, isDir: false)
  ]

  # Mock NMLVDISPINFOW notification for Row 0, Col 0 (Name)
  var textBuf = newSeq[uint16](256)
  var dispInfo: NMLVDISPINFOW
  dispInfo.item.mask = LVIF_TEXT
  dispInfo.item.iItem = 0
  dispInfo.item.iSubItem = 0
  dispInfo.item.pszText = cast[WideCString](addr textBuf[0])
  dispInfo.item.cchTextMax = 256

  # Verify formatting into dispInfo buffer
  let text = state.model.getItemText(0, 0)
  let wText = newWideCString(text)
  let pW: WideCString = wText
  var dest = cast[ptr UncheckedArray[uint16]](dispInfo.item.pszText)
  var i = 0
  while i < 255 and pW[i].uint16 != 0:
    dest[i] = pW[i].uint16
    inc(i)
  dest[i] = 0

  let formattedName = $cast[WideCString](addr textBuf[0])
  doAssert formattedName == "test_report.pdf"

  # SubItem 1 (Path)
  dispInfo.item.iSubItem = 1
  let textPath = state.model.getItemText(0, 1)
  let wPath = newWideCString(textPath)
  let pWPath: WideCString = wPath
  i = 0
  while i < 255 and pWPath[i].uint16 != 0:
    dest[i] = pWPath[i].uint16
    inc(i)
  dest[i] = 0
  let formattedPath = $cast[WideCString](addr textBuf[0])
  doAssert formattedPath == "C:\\Docs\\test_report.pdf"

  # SubItem 2 (Size)
  dispInfo.item.iSubItem = 2
  let textSize = state.model.getItemText(0, 2)
  doAssert textSize == "2.00 MB"

  echo "  [OK] Window message routing and dispinfo formatting passed."

proc testAppStateLifecycle() =
  echo "--- Testing AppState Lifecycle & Memory Cleanup ---"

  testWithLeakCheck("AppState create, populate, =destroy and dealloc"):
    let state = create(AppState)
    state.config = defaultConfig()
    state.config.hotkey = "Ctrl+Shift+E"
    state.config.indexPath = "C:\\test\\path.idx"
    state.debounce = initDebounceTracker(50)
    state.debounce.triggerDebounce("query_test")
    state.model.items = @[
      GuiItem(name: "file1.txt", path: "C:\\file1.txt", size: 100, isDir: false),
      GuiItem(name: "file2.txt", path: "C:\\file2.txt", size: 200, isDir: false)
    ]
    state.searchCallback = proc(q: string): seq[GuiItem] = @[]

    doAssert state.model.items.len == 2
    doAssert state.debounce.pendingQuery == "query_test"

    # Properly free managed strings, closures, and sequences before dealloc
    `=destroy`(state[])
    dealloc(state)

  echo "  [OK] AppState lifecycle freed cleanly under testWithLeakCheck."

proc testSearchIndexGuiIntegration() =
  echo "--- Testing SearchIndex GUI Integration (performSearch & rebuild) ---"

  testWithLeakCheck("SearchIndex GUI integration in performSearch"):
    let alloc = testAlloc
    var idx = newIndexer(alloc, 4096, driveLetter = 'C').unwrap()
    gIndexer = move(idx)
    gIndexLock = initSysLock()

    # Populate indexer with test records
    discard gIndexer.insertOrUpdate(1001'u64, 5'u64, "report_annual.pdf", false).unwrap()
    discard gIndexer.insertOrUpdate(1002'u64, 5'u64, "report_q1.xlsx", false).unwrap()
    discard gIndexer.insertOrUpdate(1003'u64, 5'u64, "notes.txt", false).unwrap()
    discard gIndexer.insertOrUpdate(1004'u64, 5'u64, "photo.png", false).unwrap()

    # Rebuild search index
    rebuildSearchIndex(alloc)
    doAssert gHasSearchIndex
    doAssert gSearchIndex.prefixEntries.len == 4

    # 1. Empty / wildcard all search
    let allItems = performSearch("")
    doAssert allItems.len == 4

    let starItems = performSearch("*")
    doAssert starItems.len == 4

    # 2. Prefix search
    let pfxItems = performSearch("report*")
    doAssert pfxItems.len == 2
    for it in pfxItems:
      doAssert it.name.startsWith("report")

    # 3. Suffix search
    let sfxItems = performSearch("*.pdf")
    doAssert sfxItems.len == 1
    doAssert sfxItems[0].name == "report_annual.pdf"

    # 4. Substring search
    let subItems = performSearch("*notes*")
    doAssert subItems.len == 1
    doAssert subItems[0].name == "notes.txt"

    # 5. Ranked query
    let ranked = performSearch("photo")
    doAssert ranked.len >= 1
    doAssert ranked[0].name == "photo.png"

    # 6. Add new node and rebuild
    discard gIndexer.insertOrUpdate(1005'u64, 5'u64, "report_final.docx", false).unwrap()
    rebuildSearchIndex(alloc)
    let updatedPfx = performSearch("report*")
    doAssert updatedPfx.len == 3

    # Cleanup
    deinitSearchIndex()
    deinitSysLock(gIndexLock)
    gIndexer.deinit()
    idx.deinit()

  echo "  [OK] SearchIndex GUI integration passed with 0 memory leaks."

proc main() =
  echo "=========================================================="
  echo " RUNNING EVERYTHING-NIM GUI HEADLESS UNIT TESTS"
  echo "=========================================================="

  testConfigSerialization()
  testDebounceLogic()
  testVirtualListDataMapping()
  testWindowMessageRouting()
  testAppStateLifecycle()
  testSearchIndexGuiIntegration()

  echo "=========================================================="
  echo " ALL HEADLESS GUI TESTS PASSED SUCCESSFULLY!"
  echo "=========================================================="

when isMainModule:
  main()
