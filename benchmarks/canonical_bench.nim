## benchmarks/canonical_bench.nim — Canonical NimUI + CoreX/AlgX Benchmark App
##
## Features:
## - Separated metric layers:
##   1. CoreX / AlgX: ultrasort (1M int64), swissmap (300K ops), signals (10K updates), arena alloc (100K)
##   2. UI Engine: Minimal UI, Table (200x6), Forms (reactive inputs/buttons), VirtualList (100K items),
##      HTML5/CSS3 parse+cascade+mount, Software SDF Rasterizer (1280x720)
##   3. Full App: Cold start, Warm start (--ping subprocess), Binary size, RSS (WorkingSet / PeakWorkingSet),
##      End-to-end headless frame p50/p95
## - Outputs raw metrics to JSON and CSV (--json:<path>, --csv:<path>)
## - Supports --headless (default), --gui (interactive Vulkan window), and --ping (startup probe)
##
## Build & Run (release):
##   nim c -d:release --opt:speed -o:bin/canonical_bench.exe benchmarks/canonical_bench.nim
##   ./bin/canonical_bench.exe --headless

import std/[os, osproc, strutils, strformat, monotimes, times, algorithm, json]
import corex
import corex/[allocators, signals, slab]
import algx/algx
import nimui
import nimui/gpu/font_atlas

when defined(windows):
  type
    PROCESS_MEMORY_COUNTERS = object
      cb: uint32
      pageFaultCount: uint32
      peakWorkingSetSize: uint
      workingSetSize: uint
      quotaPeakPagedPoolUsage: uint
      quotaPagedPoolUsage: uint
      quotaPeakNonPagedPoolUsage: uint
      quotaNonPagedPoolUsage: uint
      pagefileUsage: uint
      peakPagefileUsage: uint

  proc GetCurrentProcess(): pointer {.stdcall, dynlib: "kernel32.dll", importc: "GetCurrentProcess".}
  proc K32GetProcessMemoryInfo(hProcess: pointer, ppsmemCounters: ptr PROCESS_MEMORY_COUNTERS, cb: uint32): int32 {.stdcall, dynlib: "kernel32.dll", importc: "K32GetProcessMemoryInfo".}

  proc getProcessRssBytes(): tuple[current, peak: uint64] =
    var pmc: PROCESS_MEMORY_COUNTERS
    pmc.cb = uint32(sizeof(PROCESS_MEMORY_COUNTERS))
    if K32GetProcessMemoryInfo(GetCurrentProcess(), addr pmc, pmc.cb) != 0:
      return (uint64(pmc.workingSetSize), uint64(pmc.peakWorkingSetSize))
    (0'u64, 0'u64)
else:
  proc getProcessRssBytes(): tuple[current, peak: uint64] =
    (0'u64, 0'u64)

type
  MetricStats = object
    layer: string
    name: string
    unit: string
    runs: int
    minVal: float
    p50Val: float
    meanVal: float
    p95Val: float
    maxVal: float
    extra: string

  XorShift64 = object
    state: uint64

proc initXorShift64(seed: uint64): XorShift64 {.inline.} =
  XorShift64(state: if seed == 0'u64: 0x54581234CAFEBEEF'u64 else: seed)

proc nextI64(rng: var XorShift64): int64 {.inline.} =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  cast[int64](x)

proc computeStats(layer, name, unit: string, samples: seq[float], extra: string = ""): MetricStats =
  if samples.len == 0:
    return MetricStats(layer: layer, name: name, unit: unit, runs: 0, extra: extra)
  var sorted = samples
  sorted.sort()
  let n = sorted.len
  var sum = 0.0
  for v in sorted: sum += v
  let p50Idx = n div 2
  let p95Idx = min(n - 1, int(float(n - 1) * 0.95))
  MetricStats(
    layer: layer,
    name: name,
    unit: unit,
    runs: n,
    minVal: sorted[0],
    p50Val: sorted[p50Idx],
    meanVal: sum / float(n),
    p95Val: sorted[p95Idx],
    maxVal: sorted[^1],
    extra: extra
  )

proc singleValueStat(layer, name, unit: string, val: float, extra: string = ""): MetricStats =
  MetricStats(
    layer: layer,
    name: name,
    unit: unit,
    runs: 1,
    minVal: val,
    p50Val: val,
    meanVal: val,
    p95Val: val,
    maxVal: val,
    extra: extra
  )

proc elapsedMs(t0, t1: MonoTime): float {.inline.} =
  float(inNanoseconds(t1 - t0)) / 1_000_000.0

# =============================================================================
# Canonical UI Builders (Minimal, Table, Forms, VirtualList, Combined)
# =============================================================================

const
  ColBg      = 0x0A0A0CFF'u32
  ColSurface = 0x121216FF'u32
  ColRaised  = 0x1A1A20FF'u32
  ColBorder  = 0x262630FF'u32
  ColAccent  = 0x3B82F6FF'u32
  ColText    = 0xF4F4F6FF'u32
  ColMuted   = 0x94A3B8FF'u32

proc buildMinimalUi(tree: var UiTree) =
  let root = Box(tree, width = fixed(1280.0f), height = fixed(720.0f), padding = 16.0f, gap = 12.0f, bg = ColBg)
  tree.rootId = root
  let header = Box(tree, parent = root, width = flexGrow(1.0f), height = fixed(48.0f), padding = 12.0f, bg = ColSurface, borderColor = ColBorder, borderWidth = 1.0f, radius = 6.0f, direction = fdRow, alignItems = aiCenter, justifyContent = jcSpaceBetween)
  discard Text(tree, parent = header, text = "Canonical Benchmark — Minimal UI", size = 16.0f, color = ColText)
  discard Button(tree, parent = header, label = "Run", bg = ColAccent, radius = 4.0f)
  let body = Box(tree, parent = root, width = flexGrow(1.0f), height = flexGrow(1.0f), padding = 16.0f, gap = 8.0f, bg = ColSurface, borderColor = ColBorder, borderWidth = 1.0f, radius = 6.0f)
  for i in 0 ..< 8:
    discard Text(tree, parent = body, text = &"Metric slot #{i}: ready", size = 13.0f, color = ColMuted)

proc buildTableUi(tree: var UiTree, rows: int = 200, cols: int = 6) =
  let root = Box(tree, width = fixed(1280.0f), height = fixed(720.0f), padding = 12.0f, gap = 4.0f, bg = ColBg)
  tree.rootId = root
  for r in 0 ..< rows:
    let rowBg = if (r mod 2) == 0: ColSurface else: ColRaised
    let row = Box(tree, parent = root, width = flexGrow(1.0f), height = fixed(24.0f), padding = 4.0f, gap = 8.0f, bg = rowBg, direction = fdRow, alignItems = aiCenter)
    for c in 0 ..< cols:
      let cell = Text(tree, parent = row, text = &"R{r}C{c}", size = 12.0f, color = if r == 0: ColText else: ColMuted)
      tree.nodes[cell].widthMode = flexGrow(1.0f)

proc buildFormsUi(tree: var UiTree, rt: ptr ReactiveRuntime, sigName: Signal[string], sigStatus: Signal[string]) =
  let root = Box(tree, width = fixed(1280.0f), height = fixed(720.0f), padding = 20.0f, gap = 12.0f, bg = ColBg)
  tree.rootId = root
  let card = Box(tree, parent = root, width = fixed(540.0f), height = fitContent(), padding = 16.0f, gap = 10.0f, bg = ColSurface, borderColor = ColBorder, borderWidth = 1.0f, radius = 8.0f)
  let titleId = Text(tree, parent = card, text = "Canonical Form", size = 16.0f, color = ColText)
  bindText(addr tree, rt, titleId, proc(): string {.gcsafe, raises: [].} = sigStatus.get())
  for i in 0 ..< 6:
    let row = Box(tree, parent = card, width = flexGrow(1.0f), height = fixed(36.0f), gap = 8.0f, direction = fdRow, alignItems = aiCenter)
    let lbl = Text(tree, parent = row, text = &"Field {i}:", size = 13.0f, color = ColMuted)
    tree.nodes[lbl].widthMode = fixed(90.0f)
    let inp = TextInput(tree, parent = row, placeholder = "Enter value...", width = flexGrow(1.0f), height = fixed(32.0f), bg = ColRaised, borderColor = ColBorder, borderWidth = 1.0f, radius = 4.0f)
    if i == 0:
      bindInput(addr tree, rt, inp, sigName)
  discard Button(tree, parent = card, label = "Submit Form", bg = ColAccent, radius = 6.0f)

proc buildVirtualListUi(tree: var UiTree, itemCount: int = 100_000): SlabId =
  let root = Box(tree, width = fixed(1280.0f), height = fixed(720.0f), padding = 12.0f, gap = 8.0f, bg = ColBg)
  tree.rootId = root
  let vlist = tree.createNode(nkVirtualList)
  tree.nodes[vlist].widthMode = flexGrow(1.0f)
  tree.nodes[vlist].heightMode = flexGrow(1.0f)
  tree.nodes[vlist].bgColor = ColSurface
  tree.nodes[vlist].borderColor = ColBorder
  tree.nodes[vlist].borderWidth = 1.0f
  tree.nodes[vlist].radius = 6.0f
  tree.nodes[vlist].virtualCount = itemCount
  tree.nodes[vlist].itemHeight = 28.0f
  tree.nodes[vlist].isScrollable = true
  tree.nodes[vlist].textColor = ColText
  tree.nodes[vlist].fontSize = 13.0f
  tree.nodes[vlist].renderItemProc = proc(idx: int, selected: bool): string {.closure, gcsafe, raises: [].} =
    &"Row #{idx} — Canonical VirtualList Item"
  tree.addChild(root, vlist)
  vlist

proc buildCombinedAppUi(tree: var UiTree, rt: ptr ReactiveRuntime, sigStatus: Signal[string]): SlabId =
  let root = Box(tree, width = fixed(1280.0f), height = fixed(720.0f), padding = 12.0f, gap = 10.0f, bg = ColBg)
  tree.rootId = root

  # Top bar (Minimal UI)
  let topBar = Box(tree, parent = root, width = flexGrow(1.0f), height = fixed(44.0f), padding = 10.0f, gap = 12.0f, bg = ColSurface, borderColor = ColBorder, borderWidth = 1.0f, radius = 6.0f, direction = fdRow, alignItems = aiCenter, justifyContent = jcSpaceBetween)
  let statusTxt = Text(tree, parent = topBar, text = "Canonical App Ready", size = 15.0f, color = ColText)
  bindText(addr tree, rt, statusTxt, proc(): string {.gcsafe, raises: [].} = sigStatus.get())
  discard Button(tree, parent = topBar, label = "Benchmark", bg = ColAccent, radius = 4.0f)

  # Main split: Left = Form + Compact Table, Right = VirtualList
  let mainRow = Box(tree, parent = root, width = flexGrow(1.0f), height = flexGrow(1.0f), gap = 10.0f, direction = fdRow)
  let leftCol = Box(tree, parent = mainRow, width = fixed(520.0f), height = flexGrow(1.0f), gap = 10.0f)

  # Form card
  let formCard = Box(tree, parent = leftCol, width = flexGrow(1.0f), height = fitContent(), padding = 12.0f, gap = 8.0f, bg = ColSurface, borderColor = ColBorder, borderWidth = 1.0f, radius = 6.0f)
  discard Text(tree, parent = formCard, text = "Parameters Form", size = 14.0f, color = ColText)
  for i in 0 ..< 3:
    discard TextInput(tree, parent = formCard, placeholder = &"Input #{i}", width = flexGrow(1.0f), height = fixed(30.0f), bg = ColRaised, borderColor = ColBorder, borderWidth = 1.0f, radius = 4.0f)

  # Table card (16 rows x 4 cols)
  let tableCard = Box(tree, parent = leftCol, width = flexGrow(1.0f), height = flexGrow(1.0f), padding = 8.0f, gap = 3.0f, bg = ColSurface, borderColor = ColBorder, borderWidth = 1.0f, radius = 6.0f)
  for r in 0 ..< 16:
    let row = Box(tree, parent = tableCard, width = flexGrow(1.0f), height = fixed(22.0f), gap = 6.0f, bg = (if (r mod 2) == 0: ColRaised else: ColSurface), direction = fdRow, alignItems = aiCenter)
    for c in 0 ..< 4:
      let cell = Text(tree, parent = row, text = &"T{r}:{c}", size = 11.0f, color = ColMuted)
      tree.nodes[cell].widthMode = flexGrow(1.0f)

  # Right: VirtualList (100k items)
  let vlist = tree.createNode(nkVirtualList)
  tree.nodes[vlist].widthMode = flexGrow(1.0f)
  tree.nodes[vlist].heightMode = flexGrow(1.0f)
  tree.nodes[vlist].bgColor = ColSurface
  tree.nodes[vlist].borderColor = ColBorder
  tree.nodes[vlist].borderWidth = 1.0f
  tree.nodes[vlist].radius = 6.0f
  tree.nodes[vlist].virtualCount = 100_000
  tree.nodes[vlist].itemHeight = 26.0f
  tree.nodes[vlist].isScrollable = true
  tree.nodes[vlist].textColor = ColText
  tree.nodes[vlist].fontSize = 12.0f
  tree.nodes[vlist].renderItemProc = proc(idx: int, selected: bool): string {.closure, gcsafe, raises: [].} =
    &"[{idx:06}] Canonical List Row"
  tree.addChild(mainRow, vlist)
  vlist

# =============================================================================
# CoreX / AlgX Benchmarks
# =============================================================================

proc benchCorexAlgx(warmup, runs: int, allStats: var seq[MetricStats]) =
  # 1. algx/ultrasort (1M int64)
  block:
    const N = 1_000_000
    var master = newSeq[int64](N)
    var rng = initXorShift64(0x123456789ABCDEF0'u64)
    for i in 0 ..< N: master[i] = rng.nextI64()
    var data = newSeq[int64](N)
    var aux = newSeq[int64](N)
    var samples = newSeqOfCap[float](runs)
    for r in 0 ..< (warmup + runs):
      copyMem(addr data[0], addr master[0], N * sizeof(int64))
      let t0 = getMonoTime()
      discard ultraSort(data, aux)
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("corex_algx", "algx_ultrasort_1m", "ms", samples, &"n={N}"))

  # 2. algx/swissmap (300K ops: 100K insert + 100K hit + 100K miss)
  block:
    const K = 100_000
    var keys = newSeq[uint64](K)
    var missKeys = newSeq[uint64](K)
    var rng = initXorShift64(0xCAFEBABE12345678'u64)
    for i in 0 ..< K:
      keys[i] = cast[uint64](rng.nextI64()) or 1'u64
      missKeys[i] = cast[uint64](rng.nextI64()) or 1'u64
    var sink: uint64 = 0
    var samples = newSeqOfCap[float](runs)
    for r in 0 ..< (warmup + runs):
      var m = initFastMap[uint64, uint64](K * 2)
      let t0 = getMonoTime()
      for i in 0 ..< K:
        m[keys[i]] = uint64(i)
      for i in 0 ..< K:
        if keys[i] in m:
          sink += m[keys[i]]
      for i in 0 ..< K:
        if missKeys[i] in m:
          sink += 1'u64
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("corex_algx", "algx_swissmap_300k", "ms", samples, &"sink={sink}"))

  # 3. corex/signals (10,000 reactive updates)
  block:
    var rt = initReactiveRuntime()
    let sig = rt.createSignal(0)
    var effCount = 0
    discard rt.createEffect(proc() =
      let v = sig.get()
      effCount += (v and 1)
    )
    var samples = newSeqOfCap[float](runs)
    for r in 0 ..< (warmup + runs):
      let t0 = getMonoTime()
      for i in 1 .. 10_000:
        sig.set(i)
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    rt.destroy()
    allStats.add(computeStats("corex_algx", "corex_signals_10k", "ms", samples, &"eff={effCount}"))

  # 4. corex/allocators ArenaAllocator (100,000 allocs + reset)
  block:
    var arena = initArenaAllocator(4 * 1024 * 1024)
    let alloc = arena.allocator()
    var samples = newSeqOfCap[float](runs)
    for r in 0 ..< (warmup + runs):
      let t0 = getMonoTime()
      for i in 0 ..< 100_000:
        discard alloc.rawAlloc(32, 8)
      arena.reset()
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    arena.deinit()
    allStats.add(computeStats("corex_algx", "corex_arena_alloc_100k", "ms", samples))

# =============================================================================
# UI Engine Benchmarks
# =============================================================================

proc benchUiEngine(atlas: FontAtlas, warmup, runs: int, allStats: var seq[MetricStats]) =
  var alloc = defaultHeapAllocator()

  # 1. Minimal UI layout + draw
  block:
    var tree = initUiTree(alloc)
    defer: tree.destroy()
    buildMinimalUi(tree)
    var samples = newSeqOfCap[float](runs)
    var instCount = 0
    for r in 0 ..< (warmup + runs):
      tree.isLayoutDirty = true
      tree.isDirty = true
      let t0 = getMonoTime()
      tree.layoutTree(1280.0f, 720.0f, atlas)
      discard tree.buildDrawInstances(atlas)
      instCount = tree.drawInstances.len
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("ui_engine", "ui_minimal_layout_draw", "ms", samples, &"instances={instCount}"))

  # 2. Table (200x6 = 1400+ nodes) layout + draw
  block:
    var tree = initUiTree(alloc)
    defer: tree.destroy()
    buildTableUi(tree, 200, 6)
    var samples = newSeqOfCap[float](runs)
    var instCount = 0
    for r in 0 ..< (warmup + runs):
      tree.isLayoutDirty = true
      tree.isDirty = true
      let t0 = getMonoTime()
      tree.layoutTree(1280.0f, 720.0f, atlas)
      discard tree.buildDrawInstances(atlas)
      instCount = tree.drawInstances.len
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("ui_engine", "ui_table_200x6_layout_draw", "ms", samples, &"instances={instCount}"))

  # 3. Forms + Reactive Signal updates
  block:
    var rt = initReactiveRuntime()
    defer: rt.destroy()
    var tree = initUiTree(alloc)
    defer: tree.destroy()
    let sigName = rt.createSignal("bench-user")
    let sigStatus = rt.createSignal("Canonical Form #0")
    buildFormsUi(tree, addr rt, sigName, sigStatus)
    var samples = newSeqOfCap[float](runs)
    var instCount = 0
    for r in 0 ..< (warmup + runs):
      sigStatus.set(&"Canonical Form #{r}")
      sigName.set(&"user-{r}")
      let t0 = getMonoTime()
      tree.layoutTree(1280.0f, 720.0f, atlas)
      discard tree.buildDrawInstances(atlas)
      instCount = tree.drawInstances.len
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("ui_engine", "ui_forms_reactive_layout_draw", "ms", samples, &"instances={instCount}"))

  # 4. VirtualList 100K items scroll + layout + draw
  block:
    var tree = initUiTree(alloc)
    defer: tree.destroy()
    let vlist = buildVirtualListUi(tree, 100_000)
    var samples = newSeqOfCap[float](runs)
    var instCount = 0
    for r in 0 ..< (warmup + runs):
      tree.nodes[vlist].scrollOffset = float32((r * 700) mod 50_000)
      tree.isLayoutDirty = true
      tree.isDirty = true
      let t0 = getMonoTime()
      tree.layoutTree(1280.0f, 720.0f, atlas)
      discard tree.buildDrawInstances(atlas)
      instCount = tree.drawInstances.len
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("ui_engine", "ui_virtuallist_100k_scroll", "ms", samples, &"instances={instCount}"))

  # 5. HTML5/CSS3 parse + cascade + mount
  block:
    const SampleHtml = """
      <style>
        .panel { background-color: #121216; border: 1px solid #262630; border-radius: 8px; padding: 12px; gap: 6px; }
        .title { color: #F4F4F6; font-size: 16px; }
        .row { background-color: #1A1A20; padding: 6px; border-radius: 4px; }
        .cell { color: #94A3B8; font-size: 12px; }
      </style>
      <div class="panel">
        <h2 class="title">HTML/CSS Canonical Fragment</h2>
        <div class="row"><span class="cell">Col A</span><span class="cell">Col B</span></div>
        <div class="row"><span class="cell">Val 1</span><span class="cell">Val 2</span></div>
        <button data-click="apply">Apply</button>
      </div>
    """
    var samples = newSeqOfCap[float](runs)
    for r in 0 ..< (warmup + runs):
      var rt = initReactiveRuntime()
      var tree = initUiTree(alloc)
      var bindings = initHtmlBindingRegistry()
      let t0 = getMonoTime()
      let res = mountHtmlString(tree, addr rt, SampleHtml, "", bindings)
      let t1 = getMonoTime()
      doAssert res.isOk
      bindings.destroy()
      tree.destroy()
      rt.destroy()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("ui_engine", "ui_html_css_mount", "ms", samples))

  # 6. Software SDF Rasterizer (1280x720)
  block:
    var rt = initReactiveRuntime()
    defer: rt.destroy()
    var tree = initUiTree(alloc)
    defer: tree.destroy()
    let sigStatus = rt.createSignal("Canonical App")
    discard buildCombinedAppUi(tree, addr rt, sigStatus)
    tree.layoutTree(1280.0f, 720.0f, atlas)
    discard tree.buildDrawInstances(atlas)
    let instCount = tree.drawInstances.len
    var fb = initSoftwareFramebuffer(1280, 720, ColBg)
    var samples = newSeqOfCap[float](runs)
    for r in 0 ..< (warmup + runs):
      let t0 = getMonoTime()
      fb.renderInstancesToBuffer(tree.drawInstances, atlas, clearColor = ColBg)
      let t1 = getMonoTime()
      if r >= warmup:
        samples.add(elapsedMs(t0, t1))
    allStats.add(computeStats("ui_engine", "ui_software_sdf_raster_1280x720", "ms", samples, &"instances={instCount}"))

# =============================================================================
# Full App Benchmarks (Cold/Warm Start, RSS, Binary Size, E2E Frame)
# =============================================================================

proc benchFullApp(atlas: FontAtlas, warmup, runs: int, allStats: var seq[MetricStats]) =
  let exePath = getAppFilename()
  let binSize = float(getFileSize(exePath))
  allStats.add(singleValueStat("full_app", "app_binary_size_bytes", "bytes", binSize, exePath))

  # Cold & Warm start via subprocess --ping
  var startSamples = newSeqOfCap[float](5)
  for i in 0 ..< 5:
    let t0 = getMonoTime()
    let res = execCmdEx(quoteShellCommand([exePath, "--ping"]))
    let t1 = getMonoTime()
    if res.exitCode == 0:
      startSamples.add(elapsedMs(t0, t1))
  if startSamples.len > 0:
    allStats.add(singleValueStat("full_app", "app_cold_start_ms", "ms", startSamples[0], "first subprocess --ping"))
    if startSamples.len > 1:
      allStats.add(computeStats("full_app", "app_warm_start_ms", "ms", startSamples[1 .. ^1], "warm subprocess --ping"))

  # End-to-end headless frame (signal -> layout -> draw instances -> software SDF raster)
  var alloc = defaultHeapAllocator()
  var rt = initReactiveRuntime()
  defer: rt.destroy()
  var tree = initUiTree(alloc)
  defer: tree.destroy()
  let sigStatus = rt.createSignal("E2E Frame #0")
  let vlist = buildCombinedAppUi(tree, addr rt, sigStatus)
  var fb = initSoftwareFramebuffer(1280, 720, ColBg)
  var e2eSamples = newSeqOfCap[float](runs)
  var instCount = 0
  for r in 0 ..< (warmup + runs):
    let t0 = getMonoTime()
    sigStatus.set(&"E2E Frame #{r}")
    tree.nodes[vlist].scrollOffset = float32((r * 260) mod 20_000)
    tree.isLayoutDirty = true
    tree.isDirty = true
    tree.layoutTree(1280.0f, 720.0f, atlas)
    discard tree.buildDrawInstances(atlas)
    instCount = tree.drawInstances.len
    fb.renderInstancesToBuffer(tree.drawInstances, atlas, clearColor = ColBg)
    let t1 = getMonoTime()
    if r >= warmup:
      e2eSamples.add(elapsedMs(t0, t1))
  allStats.add(computeStats("full_app", "app_e2e_frame_headless_ms", "ms", e2eSamples, &"1280x720 instances={instCount}"))

  let rss = getProcessRssBytes()
  allStats.add(singleValueStat("full_app", "app_rss_current_bytes", "bytes", float(rss.current)))
  allStats.add(singleValueStat("full_app", "app_rss_peak_bytes", "bytes", float(rss.peak)))

# =============================================================================
# Output Writers (JSON & CSV)
# =============================================================================

proc writeResultsJson(path: string, stats: seq[MetricStats], warmup, runs: int) =
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  let rss = getProcessRssBytes()
  let exePath = getAppFilename()
  let binSize = if fileExists(exePath): getFileSize(exePath) else: 0'i64
  let buildMode = when defined(danger): "danger" elif defined(release): "release" else: "debug"

  var metricsArr = newJArray()
  for s in stats:
    metricsArr.add(%*{
      "layer": s.layer,
      "name": s.name,
      "unit": s.unit,
      "runs": s.runs,
      "min": s.minVal,
      "p50": s.p50Val,
      "mean": s.meanVal,
      "p95": s.p95Val,
      "max": s.maxVal,
      "extra": s.extra
    })

  let doc = %*{
    "schema_version": 1,
    "timestamp_utc": now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "environment": {
      "os": hostOS,
      "cpu_arch": hostCPU,
      "cpu_cores": countProcessors(),
      "nim_version": NimVersion,
      "build_mode": buildMode,
      "mm": (when defined(gcOrc): "orc" elif defined(gcArc): "arc" else: "other"),
      "binary_path": exePath,
      "binary_size_bytes": binSize,
      "rss_current_bytes": rss.current,
      "rss_peak_bytes": rss.peak
    },
    "config": {
      "warmup_runs": warmup,
      "measured_runs": runs
    },
    "metrics": metricsArr
  }
  writeFile(path, pretty(doc))

proc writeResultsCsv(path: string, stats: seq[MetricStats]) =
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var lines = @["layer,name,unit,runs,min,p50,mean,p95,max,extra"]
  for s in stats:
    let safeExtra = s.extra.replace("\"", "\"\"")
    lines.add(&"{s.layer},{s.name},{s.unit},{s.runs},{s.minVal:.4f},{s.p50Val:.4f},{s.meanVal:.4f},{s.p95Val:.4f},{s.maxVal:.4f},\"{safeExtra}\"")
  writeFile(path, lines.join("\n") & "\n")

proc runPing() =
  var alloc = defaultHeapAllocator()
  var atlas = initFontAtlas(fontSize = 18.0f)
  var tree = initUiTree(alloc)
  defer: tree.destroy()
  buildMinimalUi(tree)
  tree.layoutTree(1280.0f, 720.0f, atlas)
  discard tree.buildDrawInstances(atlas)
  echo "PING_OK"

proc runGui() =
  var alloc = defaultHeapAllocator()
  var rt = initReactiveRuntime()
  defer: rt.destroy()
  var atlas = initFontAtlas(fontSize = 18.0f)
  var tree = initUiTree(alloc)
  defer: tree.destroy()
  let sigStatus = rt.createSignal("Canonical Benchmark (Interactive GUI)")
  discard buildCombinedAppUi(tree, addr rt, sigStatus)

  var win = initNativeWindow("NimUI Canonical Benchmark", 1280, 720)
  defer: win.close()
  var backendRes = initVulkanBackend(win.hwnd, uint32(win.width), uint32(win.height), atlas)
  if not backendRes.isOk:
    echo "[WARN] Vulkan init failed: ", backendRes.error
    return
  var backend = backendRes.get()
  defer: backend.destroy()

  while win.running:
    let events = win.pollEvents()
    for ev in events:
      if ev.kind == ueResize:
        backend.needsResize = true
        tree.isLayoutDirty = true
        tree.isDirty = true
    if backend.needsResize:
      discard backend.recreateSwapchain(uint32(win.width), uint32(win.height))
      backend.needsResize = false
    if tree.isLayoutDirty or tree.isDirty:
      tree.layoutTree(float32(win.width), float32(win.height), atlas)
      discard tree.buildDrawInstances(atlas)
      let frameRes = backend.beginFrame(uint32(win.width), uint32(win.height))
      if frameRes.isOk and tree.drawInstances.len > 0:
        backend.renderInstances(frameRes.get(), addr tree.drawInstances[0], tree.drawInstances.len, ColBg)
    else:
      win.waitEvents(16)

proc main() =
  var isPing = false
  var isGui = false
  var warmup = 3
  var runs = 15
  var jsonPath = "benchmarks/results/canonical_bench.json"
  var csvPath = "benchmarks/results/canonical_bench.csv"

  for arg in commandLineParams():
    if arg == "--ping":
      isPing = true
    elif arg == "--gui":
      isGui = true
    elif arg == "--headless":
      isGui = false
    elif arg.startsWith("--warmup:"):
      warmup = parseInt(arg[9 .. ^1])
    elif arg.startsWith("--runs:"):
      runs = parseInt(arg[7 .. ^1])
    elif arg.startsWith("--json:"):
      jsonPath = arg[7 .. ^1]
    elif arg.startsWith("--csv:"):
      csvPath = arg[6 .. ^1]

  if isPing:
    runPing()
    return
  if isGui:
    runGui()
    return

  echo "================================================================================"
  echo "  Canonical NimUI + CoreX/AlgX Benchmark (Headless)"
  echo &"  Warmup: {warmup} | Measured Runs: {runs} | CPUs: {countProcessors()}"
  echo "================================================================================"

  var atlas = initFontAtlas(fontSize = 18.0f)
  var allStats: seq[MetricStats] = @[]

  benchCorexAlgx(warmup, runs, allStats)
  benchUiEngine(atlas, warmup, runs, allStats)
  benchFullApp(atlas, warmup, runs, allStats)

  echo &"""{"Layer":<12} | {"Metric":<32} | {"p50":>10} | {"p95":>10} | {"min":>10} | {"Unit":<6}"""
  echo "-----------------------------------------------------------------------------------------------"
  for s in allStats:
    echo &"{s.layer:<12} | {s.name:<32} | {s.p50Val:>10.3f} | {s.p95Val:>10.3f} | {s.minVal:>10.3f} | {s.unit:<6}"

  writeResultsJson(jsonPath, allStats, warmup, runs)
  writeResultsCsv(csvPath, allStats)
  echo "-----------------------------------------------------------------------------------------------"
  echo &"Saved JSON: {jsonPath}"
  echo &"Saved CSV : {csvPath}"

main()
