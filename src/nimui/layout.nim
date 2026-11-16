## nimui/layout — Data-Oriented Retained-Mode UI Tree & Zero-Alloc Flexbox Layout
##
## Strict invariants:
## - All UI nodes stored in Slab[UiNode] (from corex/slab).
## - Children hierarchy stored in SmallVec[SlabId, 8] (from corex/smallvec).
## - Two-pass Flexbox layout engine (Bottom-Up sizing + Top-Down positioning).
## - Zero allocations on the hot render path (ArenaAllocator with reset per frame).
## - Z-order hit-testing, mouse/keyboard focus, and VirtualList virtualization.

import std/math
import corex/unicode
import corex/slab
import corex/smallvec
import corex/allocators
import corex/result
import ./clipboard
import ./gpu/font_atlas
import ./gpu/vulkan_backend
export unicode

type
  FlexDirection* = enum
    fdRow
    fdColumn

  SizeModeKind* = enum
    smFixed
    smFlexGrow
    smFitContent

  SizeMode* = object
    kind*: SizeModeKind
    val*: float32

  AlignItems* = enum
    aiStart
    aiCenter
    aiEnd
    aiStretch

  JustifyContent* = enum
    jcStart
    jcCenter
    jcEnd
    jcSpaceBetween

  NodeKind* = enum
    nkBox
    nkText
    nkButton
    nkTextInput
    nkVirtualList

  RenderVirtualItemProc* = proc(index: int, selected: bool): string {.closure, gcsafe, raises: [].}

  UiNode* = object
    kind*: NodeKind
    parent*: SlabId
    children*: SmallVec[SlabId, 8]
    direction*: FlexDirection
    padding*: array[4, float32] # [top, right, bottom, left]
    gap*: float32
    widthMode*: SizeMode
    heightMode*: SizeMode
    alignItems*: AlignItems
    justifyContent*: JustifyContent

    # Visual Style
    bgColor*: uint32
    bgHoverColor*: uint32
    bgActiveColor*: uint32
    borderColor*: uint32
    borderHoverColor*: uint32
    radius*: float32
    borderWidth*: float32
    softness*: float32

    # Text & Typography
    text*: string
    placeholder*: string
    textColor*: uint32
    fontSize*: float32

    # VirtualList specifics
    virtualCount*: int
    itemHeight*: float32
    renderItemProc*: RenderVirtualItemProc
    selectedIndex*: int

    # State & Interactivity
    isHovered*: bool
    isPressed*: bool
    isFocused*: bool
    isScrollable*: bool
    scrollOffset*: float32
    contentHeight*: float32
    caretPos*: int
    selStart*: int
    selEnd*: int
    caretInitialized*: bool

    # Callbacks
    onClick*: proc() {.closure, gcsafe, raises: [].}
    onInput*: proc(text: string) {.closure, gcsafe, raises: [].}
    onSelect*: proc(index: int) {.closure, gcsafe, raises: [].}

    # Computed Layout Outputs
    computedRect*: tuple[x, y, w, h: float32]
    intrinsicSize*: tuple[w, h: float32]
    clipRect*: array[4, uint16] # [minX, minY, maxX, maxY]

    # Flags
    isDirty*: bool
    isLayoutDirty*: bool

  UiTree* = object
    nodes*: Slab[UiNode]
    rootId*: SlabId
    hoveredNode*: SlabId
    focusedNode*: SlabId
    pressedNode*: SlabId
    isDirty*: bool
    isLayoutDirty*: bool
    dpiScale*: float32
    allocator*: Allocator
    arena*: ArenaAllocator
    drawInstances*: seq[UiDrawInstance]

proc `=destroy`*(node: var UiNode) {.raises: [].} =
  `=destroy`(node.children)
  `=destroy`(node.text)
  `=destroy`(node.placeholder)
  node.onClick = nil
  node.onInput = nil
  node.onSelect = nil
  node.renderItemProc = nil

# Helper constructors for SizeMode
proc fixed*(px: float32): SizeMode {.inline, raises: [].} =
  SizeMode(kind: smFixed, val: px)

proc flexGrow*(weight: float32 = 1.0f): SizeMode {.inline, raises: [].} =
  SizeMode(kind: smFlexGrow, val: weight)

proc fitContent*(): SizeMode {.inline, raises: [].} =
  SizeMode(kind: smFitContent, val: 0.0f)

# =============================================================================
# Construction & Lifecycle
# =============================================================================

proc initUiTree*(alloc: Allocator = defaultHeapAllocator()): UiTree {.raises: [].} =
  let slabRes = initSlab[UiNode](alloc, 256)
  doAssert slabRes.isOk, "Failed to initialize UiNode slab"
  result.nodes = slabRes.val
  result.rootId = SlabId(-1'i32)
  result.hoveredNode = SlabId(-1'i32)
  result.focusedNode = SlabId(-1'i32)
  result.pressedNode = SlabId(-1'i32)
  result.isDirty = true
  result.isLayoutDirty = true
  result.dpiScale = 1.0f
  result.allocator = alloc
  result.arena = initArenaAllocator(2 * 1024 * 1024) # 2MB frame arena
  result.drawInstances = newSeqOfCap[UiDrawInstance](1024)

proc destroy*(tree: var UiTree) {.raises: [].} =
  tree.nodes.deinit()
  tree.drawInstances.setLen(0)
  tree.arena.deinit()

# =============================================================================
# Node Creation Helpers
# =============================================================================

proc createNode*(tree: var UiTree, kind: NodeKind): SlabId {.raises: [].} =
  var node = UiNode(
    kind: kind,
    parent: SlabId(-1'i32),
    children: initSmallVec[SlabId, 8](tree.allocator),
    direction: fdColumn,
    padding: [0.0f, 0.0f, 0.0f, 0.0f],
    gap: 0.0f,
    widthMode: fitContent(),
    heightMode: fitContent(),
    alignItems: aiStart,
    justifyContent: jcStart,
    bgColor: 0x00000000'u32,
    bgHoverColor: 0x00000000'u32,
    bgActiveColor: 0x00000000'u32,
    borderColor: 0x00000000'u32,
    borderHoverColor: 0x00000000'u32,
    radius: 0.0f,
    borderWidth: 0.0f,
    softness: 1.0f,
    text: "",
    placeholder: "",
    textColor: 0xFFFFFFFF'u32,
    fontSize: 14.0f,
    virtualCount: 0,
    itemHeight: 28.0f,
    renderItemProc: nil,
    selectedIndex: -1,
    isHovered: false,
    isPressed: false,
    isFocused: false,
    isScrollable: false,
    scrollOffset: 0.0f,
    contentHeight: 0.0f,
    caretPos: 0,
    selStart: 0,
    selEnd: 0,
    caretInitialized: false,
    onClick: nil,
    onInput: nil,
    onSelect: nil,
    computedRect: (0.0f, 0.0f, 0.0f, 0.0f),
    intrinsicSize: (0.0f, 0.0f),
    clipRect: [0'u16, 0'u16, 0xFFFF'u16, 0xFFFF'u16],
    isDirty: true,
    isLayoutDirty: true
  )

  let insertRes = tree.nodes.insert(node)
  doAssert insertRes.isOk, "Failed to insert node into Slab"
  let id = insertRes.val
  if tree.rootId == SlabId(-1'i32):
    tree.rootId = id
  tree.isDirty = true
  tree.isLayoutDirty = true
  id

proc addChild*(tree: var UiTree, parentId, childId: SlabId) {.raises: [].} =
  if tree.nodes.contains(parentId) and tree.nodes.contains(childId):
    let addRes = tree.nodes[parentId].children.add(childId)
    doAssert addRes.isOk, "Failed to add child to UiNode children SmallVec"
    tree.nodes[childId].parent = parentId
    tree.isDirty = true
    tree.isLayoutDirty = true

# =============================================================================
# Two-Pass Flexbox Layout Engine (Zero-Allocation on Hot Path)
# =============================================================================

{.push stacktrace: off, linetrace: off.}

proc measureNode*(tree: var UiTree, id: SlabId, atlas: FontAtlas) {.raises: [].} =
  if not tree.nodes.contains(id):
    return

  let nodePtr = addr tree.nodes[id]
  var intrinsicW = 0.0f
  var intrinsicH = 0.0f

  case nodePtr.kind
  of nkText:
    if nodePtr.text.len > 0:
      let (tw, th) = atlas.measureText(nodePtr.text, nodePtr.fontSize)
      intrinsicW = tw + nodePtr.padding[3] + nodePtr.padding[1]
      intrinsicH = th + nodePtr.padding[0] + nodePtr.padding[2]
    else:
      intrinsicW = nodePtr.padding[3] + nodePtr.padding[1]
      intrinsicH = atlas.lineHeight * (nodePtr.fontSize / atlas.baseSize) + nodePtr.padding[0] + nodePtr.padding[2]

  of nkButton, nkTextInput:
    let displayStr = if nodePtr.text.len > 0: nodePtr.text else: nodePtr.placeholder
    let (tw, th) = atlas.measureText(displayStr, nodePtr.fontSize)
    intrinsicW = tw + nodePtr.padding[3] + nodePtr.padding[1] + 16.0f
    intrinsicH = th + nodePtr.padding[0] + nodePtr.padding[2] + 8.0f

  of nkVirtualList:
    intrinsicW = 100.0f
    intrinsicH = float32(nodePtr.virtualCount) * nodePtr.itemHeight
    nodePtr.contentHeight = intrinsicH

  of nkBox:
    var accMain = 0.0f
    var maxCross = 0.0f
    let childCount = nodePtr.children.len

    for i in 0 ..< childCount:
      let childId = nodePtr.children[i]
      measureNode(tree, childId, atlas)
      let childNode = addr tree.nodes[childId]

      if nodePtr.direction == fdRow:
        accMain += childNode.intrinsicSize.w
        if childNode.intrinsicSize.h > maxCross:
          maxCross = childNode.intrinsicSize.h
      else:
        accMain += childNode.intrinsicSize.h
        if childNode.intrinsicSize.w > maxCross:
          maxCross = childNode.intrinsicSize.w

    let totalGaps = if childCount > 1: float32(childCount - 1) * nodePtr.gap else: 0.0f

    if nodePtr.direction == fdRow:
      intrinsicW = accMain + totalGaps + nodePtr.padding[3] + nodePtr.padding[1]
      intrinsicH = maxCross + nodePtr.padding[0] + nodePtr.padding[2]
    else:
      intrinsicW = maxCross + nodePtr.padding[3] + nodePtr.padding[1]
      intrinsicH = accMain + totalGaps + nodePtr.padding[0] + nodePtr.padding[2]

    nodePtr.contentHeight = intrinsicH

  # Override with fixed size if configured
  if nodePtr.widthMode.kind == smFixed:
    intrinsicW = nodePtr.widthMode.val
  if nodePtr.heightMode.kind == smFixed:
    intrinsicH = nodePtr.heightMode.val

  nodePtr.intrinsicSize = (intrinsicW, intrinsicH)

proc layoutNode*(
  tree: var UiTree,
  id: SlabId,
  x, y, availableW, availableH: float32,
  parentClip: array[4, uint16]
) {.raises: [].} =
  if not tree.nodes.contains(id):
    return

  let nodePtr = addr tree.nodes[id]

  # 1. Compute node's actual dimensions
  var actualW: float32
  case nodePtr.widthMode.kind
  of smFixed:
    actualW = nodePtr.widthMode.val
  of smFlexGrow:
    actualW = availableW
  of smFitContent:
    actualW = min(nodePtr.intrinsicSize.w, availableW)

  var actualH: float32
  case nodePtr.heightMode.kind
  of smFixed:
    actualH = nodePtr.heightMode.val
  of smFlexGrow:
    actualH = availableH
  of smFitContent:
    actualH = min(nodePtr.intrinsicSize.h, availableH)

  nodePtr.computedRect = (x, y, actualW, actualH)

  # 2. Intersect clip rect
  var clip = parentClip
  if nodePtr.isScrollable or nodePtr.kind == nkVirtualList or nodePtr.kind == nkTextInput:
    let minX = max(parentClip[0], uint16(max(0.0f, x)))
    let minY = max(parentClip[1], uint16(max(0.0f, y)))
    let maxX = min(parentClip[2], uint16(max(0.0f, x + actualW)))
    let maxY = min(parentClip[3], uint16(max(0.0f, y + actualH)))
    clip = [minX, minY, maxX, maxY]

  nodePtr.clipRect = clip

  # 3. Position and distribute children
  let childCount = nodePtr.children.len
  if childCount == 0:
    return

  let innerX = x + nodePtr.padding[3] # left
  let innerY = y + nodePtr.padding[0] # top
  let innerW = max(0.0f, actualW - nodePtr.padding[3] - nodePtr.padding[1])
  let innerH = max(0.0f, actualH - nodePtr.padding[0] - nodePtr.padding[2])

  let totalGaps = if childCount > 1: float32(childCount - 1) * nodePtr.gap else: 0.0f

  var fixedSpace = 0.0f
  var totalFlexWeight = 0.0f

  for i in 0 ..< childCount:
    let childId = nodePtr.children[i]
    let childNode = addr tree.nodes[childId]
    if nodePtr.direction == fdRow:
      if childNode.widthMode.kind == smFlexGrow:
        totalFlexWeight += childNode.widthMode.val
      else:
        fixedSpace += childNode.intrinsicSize.w
    else:
      if childNode.heightMode.kind == smFlexGrow:
        totalFlexWeight += childNode.heightMode.val
      else:
        fixedSpace += childNode.intrinsicSize.h

  let remainingSpace = if nodePtr.direction == fdRow:
    max(0.0f, innerW - fixedSpace - totalGaps)
  else:
    max(0.0f, innerH - fixedSpace - totalGaps)

  var startOffset = 0.0f
  var effectiveGap = nodePtr.gap
  if totalFlexWeight == 0.0f and remainingSpace > 0.0f:
    case nodePtr.justifyContent
    of jcStart:
      startOffset = 0.0f
    of jcCenter:
      startOffset = remainingSpace * 0.5f
    of jcEnd:
      startOffset = remainingSpace
    of jcSpaceBetween:
      if childCount > 1:
        effectiveGap = nodePtr.gap + remainingSpace / float32(childCount - 1)

  var curMain = if nodePtr.direction == fdRow:
    innerX + startOffset
  else:
    innerY + startOffset - nodePtr.scrollOffset

  for i in 0 ..< childCount:
    let childId = nodePtr.children[i]
    let childNode = addr tree.nodes[childId]

    var childW = childNode.intrinsicSize.w
    var childH = childNode.intrinsicSize.h

    if nodePtr.direction == fdRow:
      if childNode.widthMode.kind == smFlexGrow and totalFlexWeight > 0.0f:
        childW = (childNode.widthMode.val / totalFlexWeight) * remainingSpace

      var childY = innerY
      if childNode.heightMode.kind == smFlexGrow or nodePtr.alignItems == aiStretch:
        childH = innerH
      else:
        case nodePtr.alignItems
        of aiStart, aiStretch:
          childY = innerY
        of aiCenter:
          childY = innerY + (innerH - childH) * 0.5f
        of aiEnd:
          childY = innerY + (innerH - childH)

      layoutNode(tree, childId, curMain, childY, childW, childH, clip)
      curMain += childW + effectiveGap
    else:
      if childNode.heightMode.kind == smFlexGrow and totalFlexWeight > 0.0f:
        childH = (childNode.heightMode.val / totalFlexWeight) * remainingSpace

      var childX = innerX
      if childNode.widthMode.kind == smFlexGrow or nodePtr.alignItems == aiStretch:
        childW = innerW
      else:
        case nodePtr.alignItems
        of aiStart, aiStretch:
          childX = innerX
        of aiCenter:
          childX = innerX + (innerW - childW) * 0.5f
        of aiEnd:
          childX = innerX + (innerW - childW)

      layoutNode(tree, childId, childX, curMain, childW, childH, clip)
      curMain += childH + effectiveGap

proc setDpiScale*(tree: var UiTree, dpiScale: float32) {.inline, raises: [].} =
  let clamped = if dpiScale > 0.1f: dpiScale else: 1.0f
  if tree.dpiScale != clamped:
    tree.dpiScale = clamped
    tree.isLayoutDirty = true
    tree.isDirty = true

proc layoutTree*(tree: var UiTree, screenWidth, screenHeight: float32, atlas: FontAtlas) {.raises: [].} =
  if tree.rootId == SlabId(-1'i32) or not tree.nodes.contains(tree.rootId):
    return

  # Pass 1: Bottom-up intrinsic sizes
  measureNode(tree, tree.rootId, atlas)

  # Pass 2: Top-down geometry distribution
  let initialClip: array[4, uint16] = [0'u16, 0'u16, uint16(clamp(screenWidth, 0.0f, 65535.0f)), uint16(clamp(screenHeight, 0.0f, 65535.0f))]
  layoutNode(tree, tree.rootId, 0.0f, 0.0f, screenWidth, screenHeight, initialClip)

  tree.isLayoutDirty = false
  tree.isDirty = true

proc layoutTreePhysical*(
  tree: var UiTree,
  physicalWidth, physicalHeight: float32,
  atlas: FontAtlas,
  dpiScale: float32 = 1.0f
) {.raises: [].} =
  ## Lay out the UI tree in logical DIPs derived from physical framebuffer pixels and DPI scale.
  let scale = if dpiScale > 0.1f: dpiScale else: 1.0f
  tree.dpiScale = scale
  tree.layoutTree(physicalWidth / scale, physicalHeight / scale, atlas)

# =============================================================================
# Drawing Instance Generation (Zero-Alloc Hot Path)
# =============================================================================

proc isZeroWidthOrIgnored*(r: Rune): bool {.inline, raises: [].} =
  isIgnoredCodepoint(uint32(r))

proc hasSelection*(node: UiNode): bool {.inline, raises: [].} =
  node.selStart != node.selEnd

proc clampTextInputState*(node: var UiNode) {.inline, raises: [].} =
  let rLen = runeLen(node.text)
  if not node.caretInitialized:
    node.caretPos = rLen
    node.selStart = rLen
    node.selEnd = rLen
    node.caretInitialized = true
  else:
    node.caretPos = clamp(node.caretPos, 0, rLen)
    node.selStart = clamp(node.selStart, 0, rLen)
    node.selEnd = clamp(node.selEnd, 0, rLen)

proc deleteTextInputSelection(node: var UiNode) {.raises: [].} =
  let lo = min(node.selStart, node.selEnd)
  let hi = max(node.selStart, node.selEnd)
  if lo < hi:
    let bLo = runeByteOffset(node.text, lo)
    let bHi = runeByteOffset(node.text, hi)
    let delBytes = bHi - bLo
    let rem = node.text.len - bHi
    if rem > 0:
      moveMem(addr node.text[bLo], addr node.text[bHi], rem)
    node.text.setLen(node.text.len - delBytes)
    node.caretPos = lo
    node.selStart = lo
    node.selEnd = lo

proc insertUtf8At(s: var string, bytePos: int, ins: string) {.inline, raises: [].} =
  if ins.len == 0:
    return
  let bPos = clamp(bytePos, 0, s.len)
  let oldLen = s.len
  s.setLen(oldLen + ins.len)
  let tail = oldLen - bPos
  if tail > 0:
    moveMem(addr s[bPos + ins.len], addr s[bPos], tail)
  copyMem(addr s[bPos], unsafeAddr ins[0], ins.len)

proc measureRunePrefix*(atlas: FontAtlas, text: string, runeCount: int, fontSize: float32): float32 {.raises: [].} =
  if runeCount <= 0 or text.len == 0 or atlas.baseSize <= 0.0f:
    return 0.0f
  let scale = fontSize / atlas.baseSize
  var curW = 0.0f
  var hasPrev = false
  var prevRune = Rune(0)
  var idx = 0
  for r in runes(text):
    if idx >= runeCount:
      break
    inc(idx)
    if isZeroWidthOrIgnored(r):
      continue
    if hasPrev:
      curW += atlas.getKerning(prevRune, r) * scale
    let g = atlas.getGlyph(r)
    curW += g.advance * scale
    prevRune = r
    hasPrev = true
  curW

proc emitTextRun*(
  instances: var seq[UiDrawInstance],
  text: string,
  startX, startY: float32,
  fontSize: float32,
  color: uint32,
  clipRect: array[4, uint16],
  atlas: FontAtlas
) {.raises: [].} =
  if text.len == 0 or atlas.baseSize <= 0.0f:
    return
  if clipRect[0] >= clipRect[2] or clipRect[1] >= clipRect[3]:
    return

  let scale = fontSize / atlas.baseSize
  var curX = startX
  # Snap baseline to integer pixel boundary for razor-sharp horizontal stems
  var baselineY = floor(startY + atlas.ascender * scale + 0.5f)
  var hasPrev = false
  var prevRune = Rune(0)

  # Provide a 2px anti-aliasing breathing apron so edge pixels are never clipped
  var textClip = clipRect
  if textClip[0] >= 2'u16: textClip[0] -= 2'u16
  else: textClip[0] = 0'u16
  if textClip[1] >= 2'u16: textClip[1] -= 2'u16
  else: textClip[1] = 0'u16
  if textClip[2] <= 0xFFFD'u16: textClip[2] += 2'u16
  if textClip[3] <= 0xFFFD'u16: textClip[3] += 2'u16

  for r in runes(text):
    if r == Rune(10): # Newline
      curX = startX
      baselineY += floor(atlas.lineHeight * scale + 0.5f)
      hasPrev = false
      continue

    if isZeroWidthOrIgnored(r):
      continue

    if hasPrev:
      curX += atlas.getKerning(prevRune, r) * scale

    let g = atlas.getGlyph(r)
    let cp = uint32(r)
    # Never emit quads for space or empty glyphs (prevents solid SDF box specks)
    if g.width > 0.0f and g.height > 0.0f and cp != 32'u32 and (g.uvMax[0] > g.uvMin[0]):
      # Subpixel pixel-snapped quad placement: guarantees every raster pixel is fully covered
      let gx = floor(curX + g.bearingX * scale + 0.5f)
      let gy = floor(baselineY - g.bearingY * scale + 0.5f)
      let gw = max(1.0f, floor(g.width * scale + 0.5f))
      let gh = max(1.0f, floor(g.height * scale + 0.5f))

      if gx + gw >= float32(textClip[0]) and gx <= float32(textClip[2]) and
         gy + gh >= float32(textClip[1]) and gy <= float32(textClip[3]):
        var inst: UiDrawInstance
        inst.pos = [gx, gy]
        inst.size = [gw, gh]
        inst.uvPos = g.uvMin
        inst.uvSize = [g.uvMax[0] - g.uvMin[0], g.uvMax[1] - g.uvMin[1]]
        inst.color = color
        inst.borderColor = 0
        inst.cornerRadius = 0.0f
        inst.borderWidth = 0.0f
        inst.softness = 1.0f
        inst.clipRect = textClip
        inst.pad = 0'u32
        instances.add(inst)

    curX += g.advance * scale
    prevRune = r
    hasPrev = true

template emitTextInstances*(
  instances: var seq[UiDrawInstance],
  text: string,
  startX, startY: float32,
  fontSize: float32,
  color: uint32,
  clipRect: array[4, uint16],
  atlas: FontAtlas
) =
  emitTextRun(instances, text, startX, startY, fontSize, color, clipRect, atlas)

proc emitNodeInstances(
  tree: UiTree,
  id: SlabId,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas
) {.raises: [].} =
  if not tree.nodes.contains(id):
    return

  let node = addr tree.nodes[id]
  if node.clipRect[0] >= node.clipRect[2] or node.clipRect[1] >= node.clipRect[3]:
    return

  let (nx, ny, nw, nh) = node.computedRect

  # 1. Background & Border SDF primitive
  var bg = node.bgColor
  var bc = node.borderColor

  if node.isPressed and node.bgActiveColor != 0:
    bg = node.bgActiveColor
  elif node.isHovered:
    if node.bgHoverColor != 0:
      bg = node.bgHoverColor
    if node.borderHoverColor != 0:
      bc = node.borderHoverColor

  if bg != 0 or bc != 0:
    if nx + nw >= float32(node.clipRect[0]) and nx <= float32(node.clipRect[2]) and
       ny + nh >= float32(node.clipRect[1]) and ny <= float32(node.clipRect[3]):
      var inst: UiDrawInstance
      inst.pos = [nx, ny]
      inst.size = [nw, nh]
      inst.uvPos = [0.0f, 0.0f]
      inst.uvSize = [0.0f, 0.0f] # Solid SDF
      inst.color = bg
      inst.borderColor = bc
      inst.cornerRadius = node.radius
      inst.borderWidth = node.borderWidth
      inst.softness = max(1.0f, node.softness)
      inst.clipRect = node.clipRect
      inst.pad = 0'u32
      instances.add(inst)

  # 2. Text rendering
  case node.kind
  of nkText:
    if node.text.len > 0:
      emitTextRun(instances, node.text, nx + node.padding[3], ny + node.padding[0],
                  node.fontSize, node.textColor, node.clipRect, atlas)
  of nkButton:
    if node.text.len > 0:
      let (tw, th) = atlas.measureText(node.text, node.fontSize)
      let tx = nx + (nw - tw) * 0.5f
      let ty = ny + (nh - th) * 0.5f
      emitTextRun(instances, node.text, tx, ty, node.fontSize, node.textColor, node.clipRect, atlas)
  of nkTextInput:
    let displayStr = if node.text.len > 0: node.text else: node.placeholder
    let col = if node.text.len > 0: node.textColor else: (node.textColor and 0x00FFFFFF'u32) or 0x66000000'u32
    let (_, th) = atlas.measureText(displayStr, node.fontSize)
    let tx = nx + node.padding[3] + 8.0f
    let ty = ny + (nh - th) * 0.5f
    let availTextW = max(8.0f, nw - node.padding[3] - node.padding[1] - 16.0f)
    let totalRunes = runeLen(node.text)
    let curPos = if node.caretInitialized: clamp(node.caretPos, 0, totalRunes) else: totalRunes
    let cursorW = if node.text.len > 0: measureRunePrefix(atlas, node.text, curPos, node.fontSize) else: 0.0f
    let textScrollX = if node.text.len > 0 and cursorW > availTextW: cursorW - availTextW else: 0.0f

    # Focused selection highlight behind text
    if node.isFocused and hasSelection(node[]) and node.text.len > 0:
      let sLo = clamp(min(node.selStart, node.selEnd), 0, totalRunes)
      let sHi = clamp(max(node.selStart, node.selEnd), 0, totalRunes)
      if sLo < sHi:
        let x1 = measureRunePrefix(atlas, node.text, sLo, node.fontSize)
        let x2 = measureRunePrefix(atlas, node.text, sHi, node.fontSize)
        if x2 > x1:
          var selInst: UiDrawInstance
          selInst.pos = [tx - textScrollX + x1, ty]
          selInst.size = [x2 - x1, th]
          selInst.uvPos = [0.0f, 0.0f]
          selInst.uvSize = [0.0f, 0.0f]
          selInst.color = 0x3B82F655'u32
          selInst.borderColor = 0
          selInst.cornerRadius = 2.0f
          selInst.borderWidth = 0.0f
          selInst.softness = 1.0f
          selInst.clipRect = node.clipRect
          selInst.pad = 0'u32
          instances.add(selInst)

    emitTextRun(instances, displayStr, tx - textScrollX, ty, node.fontSize, col, node.clipRect, atlas)

    # Blinking / focused caret
    if node.isFocused and node.text.len >= 0:
      var caretInst: UiDrawInstance
      caretInst.pos = [tx + cursorW - textScrollX + 1.0f, ty]
      caretInst.size = [2.0f, th]
      caretInst.uvPos = [0.0f, 0.0f]
      caretInst.uvSize = [0.0f, 0.0f]
      caretInst.color = 0x3B82F6FF'u32 # Accent blue
      caretInst.borderColor = 0
      caretInst.cornerRadius = 1.0f
      caretInst.borderWidth = 0.0f
      caretInst.softness = 1.0f
      caretInst.clipRect = node.clipRect
      caretInst.pad = 0'u32
      instances.add(caretInst)

  of nkVirtualList:
    # Virtualized list: render only visible rows!
    let itemH = node.itemHeight
    let viewportH = nh
    let offset = node.scrollOffset

    let firstIdx = max(0, int(offset / itemH))
    let lastIdx = min(node.virtualCount - 1, int((offset + viewportH) / itemH) + 1)

    for idx in firstIdx .. lastIdx:
      let itemY = ny + float32(idx) * itemH - offset
      let isSelected = (idx == node.selectedIndex)

      # Item background (subtle alternating or selection)
      let itemBg = if isSelected: 0x2A3B54FF'u32
                   elif (idx mod 2 == 1): 0x1A1A1EFF'u32
                   else: 0x141416FF'u32

      var itemInst: UiDrawInstance
      itemInst.pos = [nx + 4.0f, itemY]
      itemInst.size = [nw - 8.0f, itemH - 2.0f]
      itemInst.uvPos = [0.0f, 0.0f]
      itemInst.uvSize = [0.0f, 0.0f]
      itemInst.color = itemBg
      itemInst.borderColor = if isSelected: 0x3B82F6FF'u32 else: 0'u32
      itemInst.cornerRadius = 4.0f
      itemInst.borderWidth = if isSelected: 1.0f else: 0.0f
      itemInst.softness = 1.0f
      itemInst.clipRect = node.clipRect
      itemInst.pad = 0'u32
      instances.add(itemInst)

      # Render item text
      let itemText = if not node.renderItemProc.isNil:
        node.renderItemProc(idx, isSelected)
      else:
        "Item #" & $idx

      let itemTextCol = if isSelected: 0xFFFFFFFF'u32 else: 0xCCCCCCFF'u32
      let itemTextH = if atlas.baseSize > 0.0f: atlas.lineHeight * (node.fontSize / atlas.baseSize) else: 18.0f
      emitTextRun(instances, itemText, nx + 12.0f, itemY + (itemH - itemTextH) * 0.5f,
                  node.fontSize, itemTextCol, node.clipRect, atlas)

    # Render scrollbar track and thumb if content overflows
    if node.contentHeight > viewportH:
      let trackW = 6.0f
      let trackX = nx + nw - trackW - 2.0f
      let thumbH = max(20.0f, (viewportH / node.contentHeight) * viewportH)
      let thumbY = ny + (offset / (node.contentHeight - viewportH)) * (viewportH - thumbH)

      var thumbInst: UiDrawInstance
      thumbInst.pos = [trackX, thumbY]
      thumbInst.size = [trackW, thumbH]
      thumbInst.uvPos = [0.0f, 0.0f]
      thumbInst.uvSize = [0.0f, 0.0f]
      thumbInst.color = 0x66667088'u32
      thumbInst.borderColor = 0
      thumbInst.cornerRadius = 3.0f
      thumbInst.borderWidth = 0.0f
      thumbInst.softness = 1.0f
      thumbInst.clipRect = node.clipRect
      thumbInst.pad = 0'u32
      instances.add(thumbInst)

  of nkBox:
    if node.isScrollable and node.contentHeight > nh and nh > 0.0f:
      let maxScroll = max(1.0f, node.contentHeight - nh)
      let trackW = 6.0f
      let trackX = nx + nw - trackW - 2.0f
      let thumbH = max(20.0f, (nh / node.contentHeight) * nh)
      let thumbY = ny + clamp(node.scrollOffset / maxScroll, 0.0f, 1.0f) * max(0.0f, nh - thumbH)

      var thumbInst: UiDrawInstance
      thumbInst.pos = [trackX, thumbY]
      thumbInst.size = [trackW, thumbH]
      thumbInst.uvPos = [0.0f, 0.0f]
      thumbInst.uvSize = [0.0f, 0.0f]
      thumbInst.color = 0x66667088'u32
      thumbInst.borderColor = 0
      thumbInst.cornerRadius = 3.0f
      thumbInst.borderWidth = 0.0f
      thumbInst.softness = 1.0f
      thumbInst.clipRect = node.clipRect
      thumbInst.pad = 0'u32
      instances.add(thumbInst)

  # 3. Recursively emit children
  for i in 0 ..< node.children.len:
    emitNodeInstances(tree, node.children[i], instances, atlas)

proc scaleDrawInstancesForDpi*(
  instances: var openArray[UiDrawInstance],
  dpiScale: float32,
  startIdx: int = 0
) {.raises: [].} =
  ## Scales logical DIP draw instances into physical framebuffer pixels.
  ## Preserves sentinel unclipped bounds (0xFFFF).
  if dpiScale <= 0.1f or abs(dpiScale - 1.0f) < 1e-4f:
    return
  for i in max(0, startIdx) ..< instances.len:
    let inst = addr instances[i]
    inst.pos[0] *= dpiScale
    inst.pos[1] *= dpiScale
    inst.size[0] *= dpiScale
    inst.size[1] *= dpiScale
    inst.cornerRadius *= dpiScale
    inst.borderWidth *= dpiScale
    inst.softness *= dpiScale
    for k in 0 ..< 4:
      let c = inst.clipRect[k]
      if c != 0xFFFF'u16:
        inst.clipRect[k] = uint16(clamp(int(round(float32(c) * dpiScale)), 0, 65535))

proc buildDrawInstances*(tree: var UiTree, atlas: FontAtlas): ptr UiDrawInstance {.raises: [].} =
  tree.drawInstances.setLen(0)
  if tree.rootId != SlabId(-1'i32):
    emitNodeInstances(tree, tree.rootId, tree.drawInstances, atlas)
  if tree.dpiScale > 0.1f and abs(tree.dpiScale - 1.0f) >= 1e-4f:
    scaleDrawInstancesForDpi(tree.drawInstances, tree.dpiScale)
  tree.arena.reset() # Reset frame arena after recording
  tree.isDirty = false
  if tree.drawInstances.len > 0:
    addr tree.drawInstances[0]
  else:
    nil

{.pop.}

# =============================================================================
# Input Handling & Hit-Testing
# =============================================================================

proc hitTestNode*(tree: UiTree, id: SlabId, px, py: float32): SlabId {.raises: [].} =
  if not tree.nodes.contains(id):
    return SlabId(-1'i32)

  let node = addr tree.nodes[id]
  let (x, y, w, h) = node.computedRect

  # Check clipping bounds
  if px < float32(node.clipRect[0]) or px > float32(node.clipRect[2]) or
     py < float32(node.clipRect[1]) or py > float32(node.clipRect[3]):
    return SlabId(-1'i32)

  # Check node rect
  if px >= x and px <= x + w and py >= y and py <= y + h:
    # Recurse children in reverse Z-order
    for i in countdown(node.children.len - 1, 0):
      let hit = hitTestNode(tree, node.children[i], px, py)
      if hit != SlabId(-1'i32):
        return hit
    return id

  SlabId(-1'i32)

proc handleMouseMove*(tree: var UiTree, px, py: float32) {.raises: [].} =
  let hit = hitTestNode(tree, tree.rootId, px, py)
  if hit != tree.hoveredNode:
    if tree.hoveredNode != SlabId(-1'i32) and tree.nodes.contains(tree.hoveredNode):
      tree.nodes[tree.hoveredNode].isHovered = false
    tree.hoveredNode = hit
    if hit != SlabId(-1'i32) and tree.nodes.contains(hit):
      tree.nodes[hit].isHovered = true
    tree.isDirty = true

proc handleMouseDown*(tree: var UiTree, px, py: float32) {.raises: [].} =
  let hit = hitTestNode(tree, tree.rootId, px, py)
  if tree.focusedNode != hit:
    if tree.focusedNode != SlabId(-1'i32) and tree.nodes.contains(tree.focusedNode):
      tree.nodes[tree.focusedNode].isFocused = false
    tree.focusedNode = hit
    if hit != SlabId(-1'i32) and tree.nodes.contains(hit):
      tree.nodes[hit].isFocused = true
      if tree.nodes[hit].kind == nkTextInput:
        let rLen = runeLen(tree.nodes[hit].text)
        tree.nodes[hit].caretPos = rLen
        tree.nodes[hit].selStart = rLen
        tree.nodes[hit].selEnd = rLen
        tree.nodes[hit].caretInitialized = true
    tree.isDirty = true

  tree.pressedNode = hit
  if hit != SlabId(-1'i32) and tree.nodes.contains(hit):
    tree.nodes[hit].isPressed = true
    # VirtualList item selection
    if tree.nodes[hit].kind == nkVirtualList:
      let relY = py - tree.nodes[hit].computedRect.y + tree.nodes[hit].scrollOffset
      let clickedIdx = int(relY / tree.nodes[hit].itemHeight)
      if clickedIdx >= 0 and clickedIdx < tree.nodes[hit].virtualCount:
        tree.nodes[hit].selectedIndex = clickedIdx
        if not tree.nodes[hit].onSelect.isNil:
          tree.nodes[hit].onSelect(clickedIdx)
    tree.isDirty = true

proc handleMouseUp*(tree: var UiTree, px, py: float32) {.raises: [].} =
  let hit = hitTestNode(tree, tree.rootId, px, py)
  if tree.pressedNode != SlabId(-1'i32) and tree.nodes.contains(tree.pressedNode):
    tree.nodes[tree.pressedNode].isPressed = false
    if tree.pressedNode == hit and not tree.nodes[hit].onClick.isNil:
      tree.nodes[hit].onClick()
    tree.pressedNode = SlabId(-1'i32)
    tree.isDirty = true

proc handleMouseWheel*(tree: var UiTree, px, py, delta: float32) {.raises: [].} =
  # Find scrollable container under cursor, bubbling up through parents
  var curr = hitTestNode(tree, tree.rootId, px, py)
  while curr != SlabId(-1'i32) and tree.nodes.contains(curr):
    let node = addr tree.nodes[curr]
    if node.isScrollable or node.kind == nkVirtualList:
      let maxScroll = max(0.0f, node.contentHeight - node.computedRect.h)
      node.scrollOffset = max(0.0f, min(maxScroll, node.scrollOffset - delta * 0.4f))
      tree.isDirty = true
      tree.isLayoutDirty = true
      return
    curr = node.parent

proc handleChar*(tree: var UiTree, r: Rune) {.raises: [].} =
  if tree.focusedNode != SlabId(-1'i32) and tree.nodes.contains(tree.focusedNode):
    let node = addr tree.nodes[tree.focusedNode]
    if node.kind == nkTextInput:
      let code = uint32(r)
      if code >= 32'u32 and code != 127'u32: # Printable char
        clampTextInputState(node[])
        if hasSelection(node[]):
          deleteTextInputSelection(node[])
        let utf8 = toUTF8(r)
        let bPos = runeByteOffset(node.text, node.caretPos)
        insertUtf8At(node.text, bPos, utf8)
        inc(node.caretPos)
        node.selStart = node.caretPos
        node.selEnd = node.caretPos
        if not node.onInput.isNil:
          node.onInput(node.text)
        tree.isDirty = true
        tree.isLayoutDirty = true

proc handleKeyDown*(tree: var UiTree, keyCode: uint32, ctrlDown: bool = false, shiftDown: bool = false) {.raises: [].} =
  if tree.focusedNode != SlabId(-1'i32) and tree.nodes.contains(tree.focusedNode):
    let node = addr tree.nodes[tree.focusedNode]
    if node.kind == nkTextInput:
      clampTextInputState(node[])
      let totalRunes = runeLen(node.text)

      if ctrlDown:
        case keyCode
        of 0x41'u32: # Ctrl+A: Select All
          node.selStart = 0
          node.selEnd = totalRunes
          node.caretPos = totalRunes
          tree.isDirty = true
        of 0x43'u32: # Ctrl+C: Copy
          if hasSelection(node[]):
            let lo = min(node.selStart, node.selEnd)
            let hi = max(node.selStart, node.selEnd)
            let bLo = runeByteOffset(node.text, lo)
            let bHi = runeByteOffset(node.text, hi)
            if bHi > bLo:
              discard setClipboardText(node.text[bLo ..< bHi])
        of 0x58'u32: # Ctrl+X: Cut
          if hasSelection(node[]):
            let lo = min(node.selStart, node.selEnd)
            let hi = max(node.selStart, node.selEnd)
            let bLo = runeByteOffset(node.text, lo)
            let bHi = runeByteOffset(node.text, hi)
            if bHi > bLo:
              discard setClipboardText(node.text[bLo ..< bHi])
            deleteTextInputSelection(node[])
            if not node.onInput.isNil:
              node.onInput(node.text)
            tree.isDirty = true
            tree.isLayoutDirty = true
        of 0x56'u32: # Ctrl+V: Paste single-line text
          let rawClip = getClipboardText()
          if rawClip.len > 0:
            var cleanClip = newStringOfCap(rawClip.len)
            for ch in rawClip:
              if ch != '\r' and ch != '\n':
                cleanClip.add(ch)
            if hasSelection(node[]):
              deleteTextInputSelection(node[])
            if cleanClip.len > 0:
              let bPos = runeByteOffset(node.text, node.caretPos)
              insertUtf8At(node.text, bPos, cleanClip)
              node.caretPos += runeLen(cleanClip)
              node.selStart = node.caretPos
              node.selEnd = node.caretPos
              if not node.onInput.isNil:
                node.onInput(node.text)
              tree.isDirty = true
              tree.isLayoutDirty = true
        else:
          discard
        return

      case keyCode
      of 0x25'u32: # VK_LEFT
        if not shiftDown and hasSelection(node[]):
          let lo = min(node.selStart, node.selEnd)
          node.caretPos = lo
          node.selStart = lo
          node.selEnd = lo
        else:
          if node.caretPos > 0:
            dec(node.caretPos)
          if shiftDown:
            node.selEnd = node.caretPos
          else:
            node.selStart = node.caretPos
            node.selEnd = node.caretPos
        tree.isDirty = true
      of 0x27'u32: # VK_RIGHT
        if not shiftDown and hasSelection(node[]):
          let hi = max(node.selStart, node.selEnd)
          node.caretPos = hi
          node.selStart = hi
          node.selEnd = hi
        else:
          if node.caretPos < totalRunes:
            inc(node.caretPos)
          if shiftDown:
            node.selEnd = node.caretPos
          else:
            node.selStart = node.caretPos
            node.selEnd = node.caretPos
        tree.isDirty = true
      of 0x24'u32: # VK_HOME
        node.caretPos = 0
        if shiftDown:
          node.selEnd = 0
        else:
          node.selStart = 0
          node.selEnd = 0
        tree.isDirty = true
      of 0x23'u32: # VK_END
        node.caretPos = totalRunes
        if shiftDown:
          node.selEnd = totalRunes
        else:
          node.selStart = totalRunes
          node.selEnd = totalRunes
        tree.isDirty = true
      of 0x08'u32: # VK_BACK
        if hasSelection(node[]):
          deleteTextInputSelection(node[])
          if not node.onInput.isNil:
            node.onInput(node.text)
          tree.isDirty = true
          tree.isLayoutDirty = true
        elif node.caretPos > 0:
          let bLo = runeByteOffset(node.text, node.caretPos - 1)
          let bHi = runeByteOffset(node.text, node.caretPos)
          let delBytes = bHi - bLo
          let rem = node.text.len - bHi
          if rem > 0:
            moveMem(addr node.text[bLo], addr node.text[bHi], rem)
          node.text.setLen(node.text.len - delBytes)
          dec(node.caretPos)
          node.selStart = node.caretPos
          node.selEnd = node.caretPos
          if not node.onInput.isNil:
            node.onInput(node.text)
          tree.isDirty = true
          tree.isLayoutDirty = true
      of 0x2E'u32: # VK_DELETE
        if hasSelection(node[]):
          deleteTextInputSelection(node[])
          if not node.onInput.isNil:
            node.onInput(node.text)
          tree.isDirty = true
          tree.isLayoutDirty = true
        elif node.caretPos < totalRunes:
          let bLo = runeByteOffset(node.text, node.caretPos)
          let bHi = runeByteOffset(node.text, node.caretPos + 1)
          let delBytes = bHi - bLo
          let rem = node.text.len - bHi
          if rem > 0:
            moveMem(addr node.text[bLo], addr node.text[bHi], rem)
          node.text.setLen(node.text.len - delBytes)
          node.selStart = node.caretPos
          node.selEnd = node.caretPos
          if not node.onInput.isNil:
            node.onInput(node.text)
          tree.isDirty = true
          tree.isLayoutDirty = true
      else:
        discard
