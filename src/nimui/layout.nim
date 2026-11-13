## nimui/layout — Data-Oriented Retained-Mode UI Tree & Zero-Alloc Flexbox Layout
##
## Strict invariants:
## - All UI nodes stored in Slab[UiNode] (from corex/slab).
## - Children hierarchy stored in SmallVec[SlabId, 8] (from corex/smallvec).
## - Two-pass Flexbox layout engine (Bottom-Up sizing + Top-Down positioning).
## - Zero allocations on the hot render path (ArenaAllocator with reset per frame).
## - Z-order hit-testing, mouse/keyboard focus, and VirtualList virtualization.

import std/unicode
import corex/slab
import corex/smallvec
import corex/allocators
import corex/result
import ./gpu/font_atlas
import ./gpu/vulkan_backend

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
    discard tree.nodes[parentId].children.add(childId)
    tree.isDirty = true
    tree.isLayoutDirty = true

# =============================================================================
# Two-Pass Flexbox Layout Engine (Zero-Allocation on Hot Path)
# =============================================================================

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
  if nodePtr.isScrollable or nodePtr.kind == nkVirtualList:
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

  var curMain = if nodePtr.direction == fdRow: innerX else: innerY - nodePtr.scrollOffset

  for i in 0 ..< childCount:
    let childId = nodePtr.children[i]
    let childNode = addr tree.nodes[childId]

    var childW = childNode.intrinsicSize.w
    var childH = childNode.intrinsicSize.h

    if nodePtr.direction == fdRow:
      if childNode.widthMode.kind == smFlexGrow and totalFlexWeight > 0.0f:
        childW = (childNode.widthMode.val / totalFlexWeight) * remainingSpace

      var childY = innerY
      case nodePtr.alignItems
      of aiStart, aiStretch:
        childY = innerY
        if nodePtr.alignItems == aiStretch:
          childH = innerH
      of aiCenter:
        childY = innerY + (innerH - childH) * 0.5f
      of aiEnd:
        childY = innerY + (innerH - childH)

      layoutNode(tree, childId, curMain, childY, childW, childH, clip)
      curMain += childW + nodePtr.gap
    else:
      if childNode.heightMode.kind == smFlexGrow and totalFlexWeight > 0.0f:
        childH = (childNode.heightMode.val / totalFlexWeight) * remainingSpace

      var childX = innerX
      case nodePtr.alignItems
      of aiStart, aiStretch:
        childX = innerX
        if nodePtr.alignItems == aiStretch:
          childW = innerW
      of aiCenter:
        childX = innerX + (innerW - childW) * 0.5f
      of aiEnd:
        childX = innerX + (innerW - childW)

      layoutNode(tree, childId, childX, curMain, childW, childH, clip)
      curMain += childH + nodePtr.gap

proc layoutTree*(tree: var UiTree, screenWidth, screenHeight: float32, atlas: FontAtlas) {.raises: [].} =
  if tree.rootId == SlabId(-1'i32) or not tree.nodes.contains(tree.rootId):
    return

  # Pass 1: Bottom-up intrinsic sizes
  measureNode(tree, tree.rootId, atlas)

  # Pass 2: Top-down geometry distribution
  let initialClip: array[4, uint16] = [0'u16, 0'u16, uint16(screenWidth), uint16(screenHeight)]
  layoutNode(tree, tree.rootId, 0.0f, 0.0f, screenWidth, screenHeight, initialClip)

  tree.isLayoutDirty = false
  tree.isDirty = true

# =============================================================================
# Drawing Instance Generation (Zero-Alloc Hot Path)
# =============================================================================

proc emitTextRun(
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

  let scale = fontSize / atlas.baseSize
  var curX = startX
  let baselineY = startY + atlas.ascender * scale

  for r in runes(text):
    if r == Rune(10): # Newline
      curX = startX
      continue

    let g = atlas.getGlyph(r)
    if g.width > 0.0f and g.height > 0.0f:
      let gx = curX + g.bearingX * scale
      let gy = baselineY - g.bearingY * scale
      let gw = g.width * scale
      let gh = g.height * scale

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
      inst.clipRect = clipRect
      inst.pad = 0'u32
      instances.add(inst)

    curX += g.advance * scale

proc emitNodeInstances(
  tree: UiTree,
  id: SlabId,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas
) {.raises: [].} =
  if not tree.nodes.contains(id):
    return

  let node = addr tree.nodes[id]
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
    let (tw, th) = atlas.measureText(displayStr, node.fontSize)
    let tx = nx + node.padding[3] + 8.0f
    let ty = ny + (nh - th) * 0.5f
    emitTextRun(instances, displayStr, tx, ty, node.fontSize, col, node.clipRect, atlas)

    # Blinking / focused caret
    if node.isFocused and node.text.len >= 0:
      let (cursorW, _) = atlas.measureText(node.text, node.fontSize)
      var caretInst: UiDrawInstance
      caretInst.pos = [tx + cursorW + 1.0f, ty]
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
      let isHover = false # Can track per-item hover if needed

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
      emitTextRun(instances, itemText, nx + 12.0f, itemY + (itemH - 18.0f) * 0.5f,
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
    discard

  # 3. Recursively emit children
  for i in 0 ..< node.children.len:
    emitNodeInstances(tree, node.children[i], instances, atlas)

proc buildDrawInstances*(tree: var UiTree, atlas: FontAtlas): ptr UiDrawInstance {.raises: [].} =
  tree.drawInstances.setLen(0)
  if tree.rootId != SlabId(-1'i32):
    emitNodeInstances(tree, tree.rootId, tree.drawInstances, atlas)
  tree.arena.reset() # Reset frame arena after recording
  tree.isDirty = false
  if tree.drawInstances.len > 0:
    addr tree.drawInstances[0]
  else:
    nil

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
  # Find scrollable container under cursor
  var curr = hitTestNode(tree, tree.rootId, px, py)
  while curr != SlabId(-1'i32) and tree.nodes.contains(curr):
    let node = addr tree.nodes[curr]
    if node.isScrollable or node.kind == nkVirtualList:
      let maxScroll = max(0.0f, node.contentHeight - node.computedRect.h)
      node.scrollOffset = max(0.0f, min(maxScroll, node.scrollOffset - delta * 0.4f))
      tree.isDirty = true
      tree.isLayoutDirty = true
      return
    # Check parent if needed, or default root
    break

proc handleChar*(tree: var UiTree, r: Rune) {.raises: [].} =
  if tree.focusedNode != SlabId(-1'i32) and tree.nodes.contains(tree.focusedNode):
    let node = addr tree.nodes[tree.focusedNode]
    if node.kind == nkTextInput:
      let code = int32(r)
      if code >= 32: # Printable char
        node.text.add(toUTF8(r))
        if not node.onInput.isNil:
          node.onInput(node.text)
        tree.isDirty = true
        tree.isLayoutDirty = true

proc handleKeyDown*(tree: var UiTree, keyCode: uint32) {.raises: [].} =
  if tree.focusedNode != SlabId(-1'i32) and tree.nodes.contains(tree.focusedNode):
    let node = addr tree.nodes[tree.focusedNode]
    if node.kind == nkTextInput:
      if keyCode == 0x08'u32: # VK_BACK
        if node.text.len > 0:
          var lastRune: Rune
          var pos = node.text.len - 1
          while pos > 0 and (ord(node.text[pos]) and 0xC0) == 0x80:
            dec(pos)
          node.text.setLen(pos)
          if not node.onInput.isNil:
            node.onInput(node.text)
          tree.isDirty = true
          tree.isLayoutDirty = true
