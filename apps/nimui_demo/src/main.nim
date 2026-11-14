## =============================================================================
## NimUI Component Showcase — Clean, Modern, Interactive Demo
## =============================================================================

import std/[strformat, unicode, os, monotimes, times]
when defined(windows):
  import winlean

import nimui
import nimui/gpu/[vulkan_api, vulkan_backend, font_atlas]
import nimui/window
import corex/signals

# =============================================================================
# Process Memory Diagnostics (Windows)
# =============================================================================

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

  proc GetCurrentProcess(): Handle {.stdcall, dynlib: "kernel32", importc: "GetCurrentProcess", raises: [].}
  proc GetProcessMemoryInfo(hProcess: Handle, ppsmemCounters: ptr PROCESS_MEMORY_COUNTERS, cb: uint32): int32 {.
    stdcall, dynlib: "psapi", importc: "GetProcessMemoryInfo", raises: [].}

  proc getProcessMemoryBytes(): uint {.raises: [].} =
    var pmc: PROCESS_MEMORY_COUNTERS
    pmc.cb = uint32(sizeof(pmc))
    if GetProcessMemoryInfo(GetCurrentProcess(), addr pmc, pmc.cb) != 0:
      pmc.workingSetSize
    else:
      0'u

  proc formatBytes(bytes: uint): string =
    let mb = float(bytes) / (1024.0 * 1024.0)
    &"{mb:.1f} MB"
else:
  proc getProcessMemoryBytes(): uint = 0'u
  proc formatBytes(bytes: uint): string = "0 MB"

# =============================================================================
# Main Application
# =============================================================================

proc main() =
  echo "Starting NimUI Component Showcase..."

  var win = initNativeWindow("NimUI Component Showcase", 880, 640)
  echo &"Window created: {win.width}x{win.height}"

  let fontAtlas = initFontAtlas("Segoe UI", 16.0f)
  echo &"FontAtlas initialized: {fontAtlas.width}x{fontAtlas.height}"

  var backendRes = initVulkanBackend(win.hwnd, uint32(win.width), uint32(win.height), fontAtlas)
  if not backendRes.isOk:
    echo "Failed to initialize Vulkan backend: ", backendRes.error
    quit(1)

  var backend = backendRes.get()
  defer: backend.destroy()

  var rt = initReactiveRuntime()
  defer: rt.destroy()

  # Reactive Signals
  var clickCountSig = rt.createSignal(0)
  var typedTextSig = rt.createSignal("Hello, NimUI!")
  var selectedItemSig = rt.createSignal("🚀 Fast Native Vulkan Engine")

  let sampleItems = @[
    "🚀 Fast Native Vulkan Engine",
    "⚡ Zero Allocation Hot Path",
    "🎨 Declarative Flexbox Layout",
    "📦 Pure Nim + ORC (No DLLs)",
    "🖥️ Per-Monitor v2 DPI Aware",
    "🌿 Reactive Signals Engine"
  ]

  # Retained UI Hierarchy Tree
  var tree = initUiTree()
  defer: tree.destroy()

  # Outer Window Shell (Slate Navy Theme)
  let root = VStack(
    tree,
    padding = 16.0f,
    gap = 12.0f,
    bg = 0x0F172AFF'u32, # Slate 900
    width = flexGrow(),
    height = flexGrow()
  )
  tree.rootId = root

  # 1. Header Card
  let header = HStack(
    tree, root,
    padding = 12.0f,
    gap = 12.0f,
    bg = 0x1E293BFF'u32, # Slate 800
    borderColor = 0x334155FF'u32, # Slate 700
    radius = 10.0f,
    borderWidth = 1.0f,
    width = flexGrow(),
    height = fixed(64.0f),
    alignItems = aiCenter
  )

  let headerTitles = VStack(tree, header, gap = 2.0f, width = flexGrow())
  discard Text(tree, headerTitles, "NimUI Component Showcase", size = 18.0f, color = 0xFFFFFFFF'u32)
  discard Text(tree, headerTitles, "Declarative UI Framework • Vulkan 1.1+ SDF Rendering • Zero Allocation Path", size = 12.0f, color = 0x38BDF8FF'u32)

  # Status Badge
  let badge = HStack(tree, header, padding = 6.0f, bg = 0x065F46FF'u32, borderColor = 0x10B981FF'u32, radius = 6.0f, borderWidth = 1.0f)
  discard Text(tree, badge, "● VULKAN READY", size = 11.0f, color = 0x6EE7B7FF'u32)

  # 2. Main Content Split: Left Form / Buttons & Right List
  let contentRow = HStack(
    tree, root,
    gap = 12.0f,
    width = flexGrow(),
    height = flexGrow()
  )

  # --- LEFT COLUMN (Cards: Buttons & Inputs) ---
  let leftCol = VStack(tree, contentRow, gap = 12.0f, width = flexGrow(), height = flexGrow())

  # Card A: Interactive Buttons & Signals
  let cardButtons = VStack(
    tree, leftCol,
    padding = 14.0f,
    gap = 10.0f,
    bg = 0x1E293BFF'u32,
    borderColor = 0x334155FF'u32,
    radius = 10.0f,
    borderWidth = 1.0f,
    width = flexGrow()
  )
  discard Text(tree, cardButtons, "Interactive Buttons & Reactive Signals", size = 14.0f, color = 0xF1F5F9FF'u32)

  let btnRow = HStack(tree, cardButtons, gap = 8.0f, alignItems = aiCenter)

  let btnCounter = Button(
    tree, btnRow,
    label = "🚀 Click Me! Count: 0",
    size = 13.0f,
    bg = 0x2563EBFF'u32, # Vibrant Blue
    bgHover = 0x3B82F6FF'u32,
    bgActive = 0x1D4ED8FF'u32,
    borderColor = 0x60A5FAFF'u32,
    radius = 6.0f,
    borderWidth = 1.0f,
    color = 0xFFFFFFFF'u32,
    padding = 8.0f,
    onClick = proc() {.gcsafe, raises: [].} =
      clickCountSig.set(clickCountSig.get() + 1)
  )

  discard Button(
    tree, btnRow,
    label = "🔄 Reset",
    size = 13.0f,
    bg = 0x334155FF'u32,
    bgHover = 0x475569FF'u32,
    bgActive = 0x1E293BFF'u32,
    borderColor = 0x64748BFF'u32,
    radius = 6.0f,
    borderWidth = 1.0f,
    color = 0xE2E8F0FF'u32,
    padding = 8.0f,
    onClick = proc() {.gcsafe, raises: [].} =
      clickCountSig.set(0)
  )

  let counterLabel = Text(tree, cardButtons, "Counter: 0 clicks recorded.", size = 12.0f, color = 0x94A3B8FF'u32)

  # Card B: Text Input & Keyboard Typing
  let cardInputs = VStack(
    tree, leftCol,
    padding = 14.0f,
    gap = 10.0f,
    bg = 0x1E293BFF'u32,
    borderColor = 0x334155FF'u32,
    radius = 10.0f,
    borderWidth = 1.0f,
    width = flexGrow()
  )
  discard Text(tree, cardInputs, "Text Input & Caret Handling", size = 14.0f, color = 0xF1F5F9FF'u32)

  let searchInput = TextInput(
    tree, cardInputs,
    placeholder = "Click here and start typing...",
    text = "Hello, NimUI!",
    size = 14.0f,
    width = flexGrow(),
    height = fixed(40.0f),
    bg = 0x0F172AFF'u32,
    borderColor = 0x38BDF8AA'u32,
    radius = 6.0f,
    borderWidth = 1.0f,
    color = 0xFFFFFFFF'u32,
    onInput = proc(s: string) {.gcsafe, raises: [].} =
      typedTextSig.set(s)
  )

  let echoLabel = Text(tree, cardInputs, "You typed: Hello, NimUI!", size = 13.0f, color = 0xFBBF24FF'u32)

  # --- RIGHT COLUMN (Card: Virtual List) ---
  let rightCol = VStack(
    tree, contentRow,
    padding = 14.0f,
    gap = 10.0f,
    bg = 0x1E293BFF'u32,
    borderColor = 0x334155FF'u32,
    radius = 10.0f,
    borderWidth = 1.0f,
    width = fixed(380.0f),
    height = flexGrow()
  )
  discard Text(tree, rightCol, "VirtualList Component (Selectable)", size = 14.0f, color = 0xF1F5F9FF'u32)

  let listNode = VirtualList(
    tree, rightCol,
    count = sampleItems.len,
    itemHeight = 36.0f,
    width = flexGrow(),
    height = flexGrow(),
    bg = 0x0F172AFF'u32,
    renderItem = proc(idx: int, selected: bool): string {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        if idx >= 0 and idx < sampleItems.len:
          sampleItems[idx]
        else:
          ""
    ,
    onSelect = proc(idx: int) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        if idx >= 0 and idx < sampleItems.len:
          selectedItemSig.set(sampleItems[idx])
  )

  let listStatus = Text(tree, rightCol, "Selected: 🚀 Fast Native Vulkan Engine", size = 12.0f, color = 0x38BDF8FF'u32)

  # 3. Footer Bar
  let footer = HStack(
    tree, root,
    padding = 8.0f,
    gap = 8.0f,
    bg = 0x1E293BFF'u32,
    borderColor = 0x334155FF'u32,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow(),
    height = fixed(34.0f),
    alignItems = aiCenter
  )
  discard Text(tree, footer, "ESC: Exit  •  Tab: Focus  •  Click / Type to interact", size = 12.0f, color = 0x64748BFF'u32)
  discard Box(tree, footer, width = flexGrow(), height = fixed(1.0f))
  discard Text(tree, footer, "60 FPS  •  0% GPU Idle", size = 12.0f, color = 0x10B981FF'u32)

  # --- Fine-Grained Reactive Effects ---
  discard rt.createEffect(proc() {.gcsafe, raises: [].} =
    let c = clickCountSig.get()
    if tree.nodes.contains(btnCounter):
      tree.nodes[btnCounter].text = &"🚀 Click Me! Count: {c}"
      tree.isDirty = true
      tree.isLayoutDirty = true
    if tree.nodes.contains(counterLabel):
      tree.nodes[counterLabel].text = &"Counter: {c} clicks recorded."
      tree.isDirty = true
  )

  discard rt.createEffect(proc() {.gcsafe, raises: [].} =
    let txt = typedTextSig.get()
    if tree.nodes.contains(echoLabel):
      tree.nodes[echoLabel].text = &"You typed: {txt}"
      tree.isDirty = true
  )

  discard rt.createEffect(proc() {.gcsafe, raises: [].} =
    let sel = selectedItemSig.get()
    if tree.nodes.contains(listStatus):
      tree.nodes[listStatus].text = &"Selected: {sel}"
      tree.isDirty = true
  )

  # Initial layout pass
  tree.layoutTree(float32(win.width), float32(win.height), fontAtlas)
  tree.isLayoutDirty = false
  tree.isDirty = true

  var frameCount = 0
  var lastFpsTime = getMonoTime()
  var currentFps = 60.0f
  var avgCpuMs = 0.05f
  var primeFrames = 5

  # Main Loop
  while win.running:
    let frameStart = getMonoTime()

    # 1. Native Events
    let events = win.pollEvents()
    for ev in events:
      case ev.kind
      of ueMouseMove:
        tree.handleMouseMove(ev.mouseX, ev.mouseY)
      of ueMouseDown:
        tree.handleMouseDown(ev.mouseX, ev.mouseY)
      of ueMouseUp:
        tree.handleMouseUp(ev.mouseX, ev.mouseY)
      of ueMouseWheel:
        tree.handleMouseWheel(ev.mouseX, ev.mouseY, ev.wheelDelta)
      of ueChar:
        tree.handleChar(ev.charVal)
      of ueKeyDown:
        if ev.keyCode == 0x1B'u32: # VK_ESCAPE
          win.close()
          break
        elif ev.keyCode == 0x26'u32: # VK_UP
          let n = addr tree.nodes[listNode]
          if n.selectedIndex > 0:
            dec(n.selectedIndex)
            if not n.onSelect.isNil: n.onSelect(n.selectedIndex)
            tree.isDirty = true
        elif ev.keyCode == 0x28'u32: # VK_DOWN
          let n = addr tree.nodes[listNode]
          if n.selectedIndex < n.virtualCount - 1:
            inc(n.selectedIndex)
            if not n.onSelect.isNil: n.onSelect(n.selectedIndex)
            tree.isDirty = true
        elif ev.keyCode == 0x09'u32: # VK_TAB
          if tree.focusedNode == searchInput:
            tree.focusedNode = btnCounter
          else:
            tree.focusedNode = searchInput
          tree.isDirty = true
        else:
          tree.handleKeyDown(ev.keyCode)
      of ueResize:
        backend.needsResize = true
        tree.isLayoutDirty = true
        tree.isDirty = true

    # 2. Flush Signals
    addr(rt).flushPendingEffects()

    # 3. Layout Pass (if resized or dirty)
    if tree.isLayoutDirty or backend.needsResize:
      tree.layoutTree(float32(win.width), float32(win.height), fontAtlas)
      tree.isLayoutDirty = false
      tree.isDirty = true

    # 4. Render
    if primeFrames > 0:
      dec(primeFrames)
      tree.isDirty = true

    if tree.isDirty:
      let frameRes = backend.beginFrame(uint32(win.width), uint32(win.height))
      if frameRes.isOk:
        let instancesPtr = tree.buildDrawInstances(fontAtlas)
        let imgIndex = frameRes.get()
        backend.renderInstances(imgIndex, instancesPtr, tree.drawInstances.len, 0x0F172AFF'u32)
      else:
        tree.isDirty = true

    let frameEnd = getMonoTime()
    let frameCpuMs = float(inNanoseconds(frameEnd - frameStart)) / 1_000_000.0
    avgCpuMs = avgCpuMs * 0.9f + frameCpuMs * 0.1f

    # 5. Window Title Diagnostics
    inc(frameCount)
    let now = getMonoTime()
    let elapsedSec = float(inNanoseconds(now - lastFpsTime)) / 1_000_000_000.0
    if elapsedSec >= 0.25:
      currentFps = float(frameCount) / elapsedSec
      frameCount = 0
      lastFpsTime = now
      let ramStr = formatBytes(getProcessMemoryBytes())
      win.setTitle(&"NimUI Showcase | {currentFps:.0f} FPS | CPU: {avgCpuMs:.3f} ms | RAM: {ramStr}")

    # 6. Zero-Cost Idle
    if not tree.isDirty and not tree.isLayoutDirty and win.running:
      win.waitEvents(16)

when isMainModule:
  main()
