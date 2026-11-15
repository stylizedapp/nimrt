## =============================================================================
## NimUI Component, SDF & Unicode Gallery — Test-Case Showcase Application 2
##
## Demonstrates:
## - Real-time SDF Box tuning (Corner Radius, Border Width, Softness, Palette)
## - Full Unicode UTF-8 (Cyrillic + Latin + symbols) nkTextInput & Multiline TextArea
## - Checkbox (including disabled state), RadioGroup, Slider, Dropdown popup & Tooltips
## - Hardware/software scissor clip-rect scrolling container
## - Both interactive Vulkan 1.1+ window (1280x820) and --headless-test / --screenshot
## =============================================================================

import std/[os, strformat]
import corex
import corex/unicode
import corex/signals
import nimui
import nimui/controls
import nimui/window
import nimui/gpu/[vulkan_backend, font_atlas]

const
  GalleryWidth = 1280
  GalleryHeight = 820

  ColBgPage      = 0x0A0A0CFF'u32
  ColBgSurface   = 0x121216FF'u32
  ColBgRaised    = 0x1A1A20FF'u32
  ColBorder      = 0x24242CFF'u32
  ColTextPrim    = 0xF4F4F6FF'u32
  ColTextSec     = 0x94A3B8FF'u32
  ColTextMuted   = 0x64748BFF'u32

type
  PaletteSpec = object
    name: string
    bg: uint32
    border: uint32
    accentText: uint32

const
  Palettes = [
    PaletteSpec(name: "Obsidian Indigo", bg: 0x1E1B4BFF'u32, border: 0x6366F1FF'u32, accentText: 0xC7D2FEFF'u32),
    PaletteSpec(name: "Emerald Matrix",  bg: 0x064E3BFF'u32, border: 0x10B981FF'u32, accentText: 0xA7F3D0FF'u32),
    PaletteSpec(name: "Crimson Solar",   bg: 0x4C0519FF'u32, border: 0xF43F5EFF'u32, accentText: 0xFECDD3FF'u32),
    PaletteSpec(name: "Arctic Slate",    bg: 0x1E293BFF'u32, border: 0x38BDF8FF'u32, accentText: 0xBAE6FDFF'u32)
  ]

  ShapePresetNames = [
    "Pill Card (18px, 2px)",
    "Sharp Tech (4px, 1px)",
    "Soft Bubble (32px, 3px)",
    "Glass Frame (12px, 1.5px)"
  ]

type
  GalleryApp = ref object
    alloc: Allocator
    atlas: FontAtlas
    tree: UiTree
    rt: ReactiveRuntime

    # SDF parameters
    cornerRadius: float32
    borderWidth: float32
    softness: float32
    previewWidth: float32
    paletteIdx: int
    presetIdx: int

    # Controls & UI handles
    previewBoxId: SlabId
    previewTitleId: SlabId
    previewMetaId: SlabId
    utf8InputId: SlabId
    selInputId: SlabId
    notesHostId: SlabId
    notesArea: TextArea
    scrollCardId: SlabId
    presetDropdown: DropdownControl
    paletteGroup: RadioGroupControl
    sliderRadius: SliderControl
    sliderBorder: SliderControl
    sliderSoftness: SliderControl
    sliderWidth: SliderControl
    cbSubpixel: CheckboxControl
    cbClip: CheckboxControl
    cbLocked: CheckboxControl
    actionBtnId: SlabId
    actionTooltip: TooltipControl

    # Signals
    headerBadgeSig: Signal[string]
    sdfReadoutSig: Signal[string]
    utf8Sig: Signal[string]
    runeStatsSig: Signal[string]
    flagsSig: Signal[string]

proc updateSdfPreviewNode(app: GalleryApp) {.raises: [].} =
  let pal = Palettes[clamp(app.paletteIdx, 0, Palettes.high)]
  if app.tree.nodes.contains(app.previewBoxId):
    let p = addr app.tree.nodes[app.previewBoxId]
    p.bgColor = pal.bg
    p.borderColor = pal.border
    p.radius = app.cornerRadius
    p.borderWidth = app.borderWidth
    p.softness = app.softness
    p.widthMode = fixed(app.previewWidth)
  if app.tree.nodes.contains(app.previewTitleId):
    app.tree.nodes[app.previewTitleId].textColor = pal.accentText
    app.tree.nodes[app.previewTitleId].text = pal.name & " SDF Box"
  if app.tree.nodes.contains(app.previewMetaId):
    app.tree.nodes[app.previewMetaId].text = &"R:{app.cornerRadius:.1f}  B:{app.borderWidth:.1f}  S:{app.softness:.2f}  W:{app.previewWidth:.0f}px"
  app.tree.isLayoutDirty = true
  app.tree.isDirty = true
  if app.sdfReadoutSig.runtime != nil:
    app.sdfReadoutSig.set(&"Radius {app.cornerRadius:.1f}px | Border {app.borderWidth:.1f}px | Softness {app.softness:.2f}px | Width {app.previewWidth:.0f}px")

proc updateFlagReadout(app: GalleryApp) {.raises: [].} =
  let aaStr = if app.cbSubpixel != nil and app.cbSubpixel.checked: "ON" else: "OFF"
  let clipStr = if app.cbClip != nil and app.cbClip.checked: "ON" else: "OFF"
  if app.flagsSig.runtime != nil:
    app.flagsSig.set("Subpixel AA: " & aaStr & " | Scissor Clip: " & clipStr)

proc buildGalleryUi(app: GalleryApp) {.raises: [].} =
  resetControls()
  app.tree.destroy()
  app.rt.destroy()

  app.tree = initUiTree(app.alloc)
  app.rt = initReactiveRuntime(app.alloc)

  app.headerBadgeSig = app.rt.createSignal("Preset: " & ShapePresetNames[app.presetIdx])
  app.sdfReadoutSig = app.rt.createSignal(&"Radius {app.cornerRadius:.1f}px | Border {app.borderWidth:.1f}px | Softness {app.softness:.2f}px | Width {app.previewWidth:.0f}px")
  app.utf8Sig = app.rt.createSignal("Привет, NimUI! CoreX • UTF-8 • 0 Leaks")
  app.runeStatsSig = app.rt.createSignal("")
  app.flagsSig = app.rt.createSignal("Subpixel AA: ON | Scissor Clip: ON")

  let root = Box(
    app.tree,
    direction = fdColumn,
    padding = 14.0f,
    gap = 12.0f,
    width = flexGrow(),
    height = flexGrow(),
    bg = ColBgPage
  )

  # --- Header ---
  let header = HStack(
    app.tree, root,
    padding = 12.0f,
    gap = 12.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow(),
    height = fixed(54.0f),
    alignItems = aiCenter
  )
  let titleCol = VStack(app.tree, header, gap = 2.0f)
  discard Text(app.tree, titleCol, "NimUI Component, SDF & Unicode Gallery", size = 17.0f, color = ColTextPrim)
  discard Text(app.tree, titleCol, "Vulkan 1.1+ Signed Distance Fields • CoreX UTF-8 Runes • Zero External Dependencies", size = 11.0f, color = ColTextMuted)
  discard Box(app.tree, header, width = flexGrow(), height = fixed(1.0f))

  let presetBadge = HStack(
    app.tree, header,
    padding = 6.0f,
    bg = 0x171726FF'u32,
    borderColor = 0x4F46E5FF'u32,
    radius = 6.0f,
    borderWidth = 1.0f
  )
  let presetBadgeText = Text(app.tree, presetBadge, app.headerBadgeSig.get(), size = 12.0f, color = 0xC7D2FEFF'u32)
  bindText(addr app.tree, addr app.rt, presetBadgeText, proc(): string {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.headerBadgeSig.get()
  )

  # --- Main Two-Column Body ---
  let bodyRow = HStack(app.tree, root, gap = 12.0f, width = flexGrow(), height = flexGrow())

  # ===========================================================================
  # LEFT COLUMN: SDF Shader Geometry & Palette Lab
  # ===========================================================================
  let leftCol = VStack(
    app.tree, bodyRow,
    padding = 14.0f,
    gap = 10.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = fixed(580.0f),
    height = flexGrow()
  )
  discard Text(app.tree, leftCol, "1. Interactive SDF Geometry & Surface Palette Lab", size = 15.0f, color = ColTextPrim)

  let readoutLbl = Text(app.tree, leftCol, app.sdfReadoutSig.get(), size = 12.0f, color = 0x60A5FAFF'u32)
  bindText(addr app.tree, addr app.rt, readoutLbl, proc(): string {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.sdfReadoutSig.get()
  )

  discard Text(app.tree, leftCol, "Surface Palette (RadioGroup):", size = 12.0f, color = ColTextSec)
  let paletteNames = [Palettes[0].name, Palettes[1].name, Palettes[2].name, Palettes[3].name]
  let (_, pGroup) = RadioGroup(
    app.tree, leftCol,
    options = paletteNames,
    selectedIndex = app.paletteIdx,
    direction = fdRow,
    gap = 12.0f,
    onSelect = proc(idx: int, val: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.paletteIdx = idx
        app.updateSdfPreviewNode()
  )
  app.paletteGroup = pGroup

  # Shape Presets Dropdown
  let presetRow = HStack(app.tree, leftCol, gap = 10.0f, width = flexGrow(), alignItems = aiCenter)
  discard Text(app.tree, presetRow, "Geometry Preset:", size = 12.0f, color = ColTextSec)
  let dd = newDropdown(
    items = ShapePresetNames,
    selectedIndex = app.presetIdx,
    itemHeight = 28.0f,
    fontSize = 12.0f,
    onSelect = proc(idx: int) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.presetIdx = idx
        case idx
        of 0:
          app.cornerRadius = 18.0f; app.borderWidth = 2.0f; app.softness = 1.2f
        of 1:
          app.cornerRadius = 4.0f;  app.borderWidth = 1.0f; app.softness = 0.8f
        of 2:
          app.cornerRadius = 32.0f; app.borderWidth = 3.0f; app.softness = 1.8f
        else:
          app.cornerRadius = 12.0f; app.borderWidth = 1.5f; app.softness = 2.4f
        app.headerBadgeSig.set("Preset: " & ShapePresetNames[idx])
        app.updateSdfPreviewNode()
  )
  app.presetDropdown = dd
  let ddNodeId = Dropdown(app.tree, presetRow, dd, width = fixed(240.0f), height = fixed(30.0f))
  Tooltip(app.tree, ddNodeId, "Choose a corner radius & border preset (renders popup overlay)", tpBelow)

  # Sliders
  discard Text(app.tree, leftCol, "Corner Radius (0 .. 36 px)", size = 12.0f, color = ColTextSec)
  app.sliderRadius = newSlider(0.0f, 36.0f, app.cornerRadius, step = 1.0f, onValueChange = proc(v: float32) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.cornerRadius = v
      app.updateSdfPreviewNode()
  )
  discard Slider(app.tree, leftCol, app.sliderRadius, width = flexGrow())

  discard Text(app.tree, leftCol, "Border Width (0 .. 6 px)", size = 12.0f, color = ColTextSec)
  app.sliderBorder = newSlider(0.0f, 6.0f, app.borderWidth, step = 0.5f, onValueChange = proc(v: float32) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.borderWidth = v
      app.updateSdfPreviewNode()
  )
  discard Slider(app.tree, leftCol, app.sliderBorder, width = flexGrow())

  discard Text(app.tree, leftCol, "SDF Edge Softness / AA (0.5 .. 3.5 px)", size = 12.0f, color = ColTextSec)
  app.sliderSoftness = newSlider(0.5f, 3.5f, app.softness, step = 0.1f, onValueChange = proc(v: float32) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.softness = v
      app.updateSdfPreviewNode()
  )
  discard Slider(app.tree, leftCol, app.sliderSoftness, width = flexGrow())

  discard Text(app.tree, leftCol, "Target Card Width (180 .. 460 px)", size = 12.0f, color = ColTextSec)
  app.sliderWidth = newSlider(180.0f, 460.0f, app.previewWidth, step = 10.0f, onValueChange = proc(v: float32) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.previewWidth = v
      app.updateSdfPreviewNode()
  )
  discard Slider(app.tree, leftCol, app.sliderWidth, width = flexGrow())

  # Live SDF Preview Stage
  let stageBox = VStack(
    app.tree, leftCol,
    padding = 16.0f,
    bg = 0x070709FF'u32,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow(),
    height = flexGrow(),
    alignItems = aiCenter,
    justifyContent = jcCenter
  )
  let initPal = Palettes[app.paletteIdx]
  app.previewBoxId = VStack(
    app.tree, stageBox,
    padding = 16.0f,
    gap = 6.0f,
    bg = initPal.bg,
    borderColor = initPal.border,
    radius = app.cornerRadius,
    borderWidth = app.borderWidth,
    softness = app.softness,
    width = fixed(app.previewWidth),
    height = fixed(140.0f),
    alignItems = aiCenter,
    justifyContent = jcCenter
  )
  app.previewTitleId = Text(app.tree, app.previewBoxId, initPal.name & " SDF Box", size = 16.0f, color = initPal.accentText)
  app.previewMetaId = Text(
    app.tree, app.previewBoxId,
    &"R:{app.cornerRadius:.1f}  B:{app.borderWidth:.1f}  S:{app.softness:.2f}  W:{app.previewWidth:.0f}px",
    size = 12.0f,
    color = ColTextPrim
  )

  # ===========================================================================
  # RIGHT COLUMN: Unicode TextInput, Checkboxes, Scroll Area & TextArea
  # ===========================================================================
  let rightCol = VStack(
    app.tree, bodyRow,
    gap = 12.0f,
    width = flexGrow(),
    height = flexGrow()
  )

  # Card A: Rich Unicode UTF-8 Input Showcase
  let unicodeCard = VStack(
    app.tree, rightCol,
    padding = 14.0f,
    gap = 8.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow()
  )
  discard Text(app.tree, unicodeCard, "2. CoreX UTF-8 Rich TextInput (Cyrillic + English + Selection)", size = 15.0f, color = ColTextPrim)

  app.utf8InputId = TextInput(
    app.tree, unicodeCard,
    placeholder = "Введите UTF-8 текст...",
    text = app.utf8Sig.get(),
    size = 14.0f,
    width = flexGrow(),
    height = fixed(34.0f),
    bg = 0x0B0B0FFF'u32,
    borderColor = 0x334155FF'u32
  )
  bindInput(addr app.tree, addr app.rt, app.utf8InputId, app.utf8Sig)

  let statsTextId = Text(app.tree, unicodeCard, "", size = 12.0f, color = 0x34D399FF'u32)
  bindText(addr app.tree, addr app.rt, statsTextId, proc(): string {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let t = app.utf8Sig.get()
      &"Rune Count: {runeLen(t)} runes | UTF-8 Byte Len: {t.len} bytes"
  )

  # Second TextInput with visible active selection range & caret
  app.selInputId = TextInput(
    app.tree, unicodeCard,
    placeholder = "Selection demo...",
    text = "Selected CoreX Span — Ctrl+A / Ctrl+C / Ctrl+V",
    size = 13.0f,
    width = flexGrow(),
    height = fixed(32.0f),
    bg = 0x0B0B0FFF'u32,
    borderColor = 0x6366F1FF'u32
  )
  let sNode = addr app.tree.nodes[app.selInputId]
  sNode.isFocused = true
  sNode.caretPos = 14
  sNode.selStart = 9
  sNode.selEnd = 14
  sNode.caretInitialized = true
  app.tree.focusedNode = app.selInputId

  # Card B: Checkboxes, Disabled State & Action Tooltips
  let ctlCard = VStack(
    app.tree, rightCol,
    padding = 14.0f,
    gap = 8.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow()
  )
  discard Text(app.tree, ctlCard, "3. Checkboxes, Disabled Controls & Tooltip Overlays", size = 15.0f, color = ColTextPrim)

  app.cbSubpixel = newCheckbox("Subpixel SDF Anti-Aliasing", checked = true, onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.updateFlagReadout()
  )
  discard Checkbox(app.tree, ctlCard, app.cbSubpixel)

  app.cbClip = newCheckbox("Hardware Scissor Clipping Enforcement", checked = true, onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.updateFlagReadout()
  )
  discard Checkbox(app.tree, ctlCard, app.cbClip)

  app.cbLocked = newCheckbox("Locked Hardware Overlay Flag (disabled = true)", checked = false)
  app.cbLocked.disabled = true
  discard Checkbox(app.tree, ctlCard, app.cbLocked)

  let flagsLbl = Text(app.tree, ctlCard, app.flagsSig.get(), size = 12.0f, color = ColTextSec)
  bindText(addr app.tree, addr app.rt, flagsLbl, proc(): string {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.flagsSig.get()
  )

  let btnRow = HStack(app.tree, ctlCard, gap = 8.0f, alignItems = aiCenter)
  app.actionBtnId = Button(
    app.tree, btnRow,
    label = "Toggle Soft-Edge Demo",
    size = 12.0f,
    bg = 0x2563EBFF'u32,
    borderColor = 0x3B82F6FF'u32,
    onClick = proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.softness = if app.softness < 2.0f: 2.8f else: 1.0f
        app.sliderSoftness.setValue(app.softness, addr app.tree)
        app.updateSdfPreviewNode()
  )
  app.actionTooltip = Tooltip(app.tree, app.actionBtnId, "Applies soft SDF edge gradient (1.0 <-> 2.8 px)", tpAbove)

  discard Button(
    app.tree, btnRow,
    label = "Append Cyrillic UTF-8",
    size = 12.0f,
    onClick = proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.utf8Sig.set("Явность и безопасность на Nim • Zero-JS!")
  )

  # Card C: Bottom Split (Multiline TextArea + Scissor-Clipped Scroll Box)
  let bottomRow = HStack(app.tree, rightCol, gap = 12.0f, width = flexGrow(), height = flexGrow())

  let notesCard = VStack(
    app.tree, bottomRow,
    padding = 12.0f,
    gap = 6.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow(1.2f),
    height = flexGrow()
  )
  discard Text(app.tree, notesCard, "4. Multiline TextArea (Word Wrap + Sync)", size = 13.0f, color = ColTextPrim)
  app.notesHostId = Box(
    app.tree, notesCard,
    width = flexGrow(),
    height = flexGrow(),
    bg = 0x0B0B0FFF'u32,
    borderColor = ColBorder,
    radius = 6.0f,
    borderWidth = 1.0f
  )

  let scrollCard = VStack(
    app.tree, bottomRow,
    padding = 12.0f,
    gap = 6.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 8.0f,
    borderWidth = 1.0f,
    width = flexGrow(1.0f),
    height = flexGrow()
  )
  discard Text(app.tree, scrollCard, "5. Scissor-Clipped Scroll Box", size = 13.0f, color = ColTextPrim)
  app.scrollCardId = VStack(
    app.tree, scrollCard,
    padding = 8.0f,
    gap = 6.0f,
    bg = 0x0B0B0FFF'u32,
    borderColor = ColBorder,
    radius = 6.0f,
    borderWidth = 1.0f,
    width = flexGrow(),
    height = flexGrow()
  )
  app.tree.nodes[app.scrollCardId].isScrollable = true
  for rowIdx in 0 ..< 14:
    let rowBox = HStack(
      app.tree, app.scrollCardId,
      padding = 6.0f,
      bg = if (rowIdx mod 2 == 0): 0x16161DFF'u32 else: 0x121218FF'u32,
      borderColor = 0x22222BFF'u32,
      radius = 4.0f,
      borderWidth = 1.0f,
      width = flexGrow(),
      height = fixed(26.0f),
      alignItems = aiCenter
    )
    discard Text(app.tree, rowBox, &"Clipped Item #{rowIdx + 1:02d} — Zero-Alloc Retained Node", size = 11.0f, color = ColTextSec)

  app.tree.layoutTree(float32(GalleryWidth), float32(GalleryHeight), app.atlas)
  app.notesArea.syncWithNode(app.tree, app.notesHostId, app.atlas)

proc newGalleryApp(alloc: Allocator, atlas: FontAtlas): GalleryApp =
  result = GalleryApp(
    alloc: alloc,
    atlas: atlas,
    tree: initUiTree(alloc),
    rt: initReactiveRuntime(alloc),
    cornerRadius: 18.0f,
    borderWidth: 2.0f,
    softness: 1.2f,
    previewWidth: 340.0f,
    paletteIdx: 0,
    presetIdx: 0,
    notesArea: initTextArea(
      text = "=== NimUI Multiline Notes ===\nWord-wrap active inside TextArea bounds.\nSupports Ctrl+C / Ctrl+V clipboard & Cyrillic UTF-8:\nБезопасность (Rust), явность (Zig), простота (Python).",
      fontSize = 12.0f,
      bounds = (0.0f, 0.0f, 300.0f, 160.0f)
    )
  )
  result.buildGalleryUi()

proc destroyGalleryApp(app: GalleryApp) =
  resetControls()
  app.tree.destroy()
  app.rt.destroy()

proc renderGalleryInstances(app: GalleryApp, w, h: float32) {.raises: [].} =
  if app.tree.isLayoutDirty:
    app.tree.layoutTree(w, h, app.atlas)
    app.notesArea.syncWithNode(app.tree, app.notesHostId, app.atlas)
  discard app.tree.buildDrawInstances(app.atlas)
  if app.tree.nodes.contains(app.notesHostId):
    let b = app.notesArea.bounds
    let clip: array[4, uint16] = [
      uint16(max(0.0f, b.x)),
      uint16(max(0.0f, b.y)),
      uint16(min(w, b.x + b.w)),
      uint16(min(h, b.y + b.h))
    ]
    app.notesArea.emitDrawInstances(app.tree.drawInstances, app.atlas, clip)
  renderControlOverlays(app.tree, app.atlas, w, h)

proc runHeadlessVerification(screenshotPath, dropdownScreenshotPath: string) =
  echo "================================================================="
  echo ">>> WIDGET GALLERY HEADLESS VERIFICATION & PNG EXPORT <<<"
  echo "================================================================="
  let atlas = initFontAtlas("Segoe UI", 32.0f)

  testWithLeakCheck("Widget Gallery Controls, SDF, UTF-8 & PNG Zero-Leak Audit"):
    let app = newGalleryApp(testAlloc, atlas)
    defer: app.destroyGalleryApp()

    # Verify disabled checkbox invariant
    app.cbLocked.toggle(addr app.tree)
    doAssert not app.cbLocked.checked, "Disabled checkbox must not toggle"

    # Verify UTF-8 Cyrillic rune length vs byte length
    doAssert runeLen(app.utf8Sig.get()) < app.utf8Sig.get().len

    # Verify SDF state transition via Slider & RadioGroup
    app.sliderRadius.setValue(24.0f, addr app.tree)
    doAssert app.tree.nodes[app.previewBoxId].radius == 24.0f
    app.paletteGroup.select(1, addr app.tree) # Emerald Matrix
    doAssert app.paletteIdx == 1
    doAssert app.tree.nodes[app.previewBoxId].bgColor == Palettes[1].bg

    # Reset back to showcase default (Indigo, 18px) for main gallery screenshot
    app.paletteGroup.select(0, addr app.tree)
    app.sliderRadius.setValue(18.0f, addr app.tree)
    app.renderGalleryInstances(float32(GalleryWidth), float32(GalleryHeight))

    if screenshotPath.len > 0:
      var fb = initSoftwareFramebuffer(GalleryWidth, GalleryHeight, ColBgPage)
      fb.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgPage)
      doAssert fb.savePng(screenshotPath)
      echo "  [OK] Exported gallery screenshot: ", screenshotPath

    if dropdownScreenshotPath.len > 0:
      # Open Dropdown + simulate hover on Action Button to verify top-level overlays
      app.presetDropdown.open(addr app.tree)
      app.presetDropdown.hoveredIndex = 2
      app.tree.nodes[app.actionBtnId].isHovered = true
      app.paletteGroup.select(1, addr app.tree) # Emerald Matrix in second shot to showcase variety!
      app.sliderRadius.setValue(28.0f, addr app.tree)
      app.renderGalleryInstances(float32(GalleryWidth), float32(GalleryHeight))

      var fb2 = initSoftwareFramebuffer(GalleryWidth, GalleryHeight, ColBgPage)
      fb2.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgPage)
      doAssert fb2.savePng(dropdownScreenshotPath)
      echo "  [OK] Exported gallery open-dropdown overlay screenshot: ", dropdownScreenshotPath

  echo "  [PASS] Widget Gallery controls, SDF, UTF-8 & 0-leak audit verified."

proc runInteractiveWindow() =
  var win = initNativeWindow("NimUI Component, SDF & Unicode Gallery", GalleryWidth, GalleryHeight)
  let atlas = initFontAtlas("Segoe UI", 32.0f)
  var backendRes = initVulkanBackend(win.hwnd, uint32(win.width), uint32(win.height), atlas)
  if not backendRes.isOk:
    echo "[FATAL] Vulkan init failed: ", backendRes.error
    return
  var backend = backendRes.get()
  let app = newGalleryApp(heapAllocator(), atlas)
  var mouseX = 0.0f
  var mouseY = 0.0f

  while win.running:
    let events = win.pollEvents()
    for ev in events:
      case ev.kind
      of ueResize:
        backend.needsResize = true
        app.tree.isLayoutDirty = true
        app.tree.isDirty = true
      of ueMouseMove:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        discard handleControlMouseMove(app.tree, mouseX, mouseY)
        if app.notesArea.isDragging:
          app.notesArea.handleMouseMove(mouseX, mouseY, atlas)
        app.tree.handleMouseMove(mouseX, mouseY)
      of ueMouseDown:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        var handled = handleControlMouseDown(app.tree, mouseX, mouseY)
        if not handled:
          let b = app.notesArea.bounds
          if mouseX >= b.x and mouseX <= b.x + b.w and mouseY >= b.y and mouseY <= b.y + b.h:
            app.notesArea.handleMouseDown(mouseX, mouseY, atlas)
            app.notesArea.isFocused = true
            handled = true
          else:
            app.notesArea.isFocused = false
        if not handled:
          app.tree.handleMouseDown(mouseX, mouseY)
      of ueMouseUp:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        discard handleControlMouseUp(app.tree, mouseX, mouseY)
        if app.notesArea.isDragging:
          app.notesArea.handleMouseUp(mouseX, mouseY)
        app.tree.handleMouseUp(mouseX, mouseY)
      of ueMouseWheel:
        let b = app.notesArea.bounds
        if mouseX >= b.x and mouseX <= b.x + b.w and mouseY >= b.y and mouseY <= b.y + b.h:
          app.notesArea.scrollOffsetY = max(0.0f, app.notesArea.scrollOffsetY - float32(ev.wheelDelta) * 20.0f)
        else:
          app.tree.handleMouseWheel(mouseX, mouseY, float32(ev.wheelDelta) * 60.0f)
      of ueKeyDown:
        var handled = handleControlKeyDown(app.tree, ev.keyCode)
        if not handled and app.notesArea.isFocused:
          discard app.notesArea.handleKeyDown(ev.keyCode, ev.ctrlDown, ev.shiftDown)
          handled = true
        if not handled:
          app.tree.handleKeyDown(ev.keyCode, ev.ctrlDown, ev.shiftDown)
      of ueChar:
        if app.notesArea.isFocused:
          app.notesArea.handleChar(ev.charVal)
        else:
          app.tree.handleChar(ev.charVal)
      else:
        discard

    if app.tree.isLayoutDirty or backend.needsResize:
      app.tree.layoutTree(float32(win.width), float32(win.height), atlas)
      app.notesArea.syncWithNode(app.tree, app.notesHostId, atlas)

    let frameRes = backend.beginFrame(uint32(win.width), uint32(win.height))
    if frameRes.isOk:
      let imgIdx = frameRes.get()
      app.renderGalleryInstances(float32(win.width), float32(win.height))
      if app.tree.drawInstances.len > 0:
        backend.renderInstances(imgIdx, addr app.tree.drawInstances[0], app.tree.drawInstances.len, ColBgPage)
    else:
      app.tree.isDirty = true

    if not app.tree.isDirty and not app.tree.isLayoutDirty and win.running:
      win.waitEvents(16)

  app.destroyGalleryApp()
  backend.destroy()

proc main() =
  var headless = false
  var screenshotPath = ""
  var dropdownScreenshotPath = ""
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--headless-test":
      headless = true
      inc i
    elif args[i] == "--screenshot" and i + 1 < args.len:
      screenshotPath = args[i + 1]
      headless = true
      inc(i, 2)
    elif args[i] == "--screenshot-open-dropdown" and i + 1 < args.len:
      dropdownScreenshotPath = args[i + 1]
      headless = true
      inc(i, 2)
    else:
      inc i

  if headless:
    runHeadlessVerification(screenshotPath, dropdownScreenshotPath)
  else:
    runInteractiveWindow()

when isMainModule:
  main()
