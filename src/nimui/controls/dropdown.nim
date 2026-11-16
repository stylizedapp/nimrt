## nimui/controls/dropdown — Dropdown / Select Control & Overlay Renderer

import corex/slab
import corex/signals
import algx/swissmap
import ../layout
import ../dsl
import ../gpu/font_atlas
import ../gpu/vulkan_backend
import ./common

proc newDropdown*(
  items: openArray[string],
  selectedIndex: int = 0,
  itemHeight: float32 = 30.0f,
  fontSize: float32 = 13.0f,
  onSelect: proc(idx: int) {.closure, gcsafe, raises: [].} = nil
): DropdownControl {.raises: [].} =
  var itemList = newSeqOfCap[string](items.len)
  for item in items:
    itemList.add(item)
  DropdownControl(
    items: itemList,
    selectedIndex: clamp(selectedIndex, 0, max(0, itemList.len - 1)),
    isOpen: false,
    disabled: false,
    hoveredIndex: -1,
    headerId: SlabId(-1),
    textId: SlabId(-1),
    arrowId: SlabId(-1),
    itemHeight: itemHeight,
    fontSize: fontSize,
    onSelect: onSelect,
    computedHeaderRect: (0.0f, 0.0f, 0.0f, 0.0f)
  )

proc updateVisuals*(dd: DropdownControl, tree: ptr UiTree) {.raises: [].} =
  if tree == nil or dd == nil: return
  if dd.textId != SlabId(-1) and tree.nodes.contains(dd.textId):
    let title = if dd.selectedIndex >= 0 and dd.selectedIndex < dd.items.len:
      dd.items[dd.selectedIndex]
    else:
      ""
    tree.nodes[dd.textId].text = title
  if dd.arrowId != SlabId(-1) and tree.nodes.contains(dd.arrowId):
    tree.nodes[dd.arrowId].text = if dd.isOpen: "▲" else: "▼"
  if dd.headerId != SlabId(-1) and tree.nodes.contains(dd.headerId):
    tree.nodes[dd.headerId].borderColor = if dd.isOpen: ColFocusRing else: ColBorderCtl
  tree.isDirty = true

proc open*(dd: DropdownControl, tree: ptr UiTree = nil) {.raises: [].} =
  if dd == nil or dd.disabled or dd.isOpen: return
  dd.isOpen = true
  if tree != nil:
    updateVisuals(dd, tree)

proc close*(dd: DropdownControl, tree: ptr UiTree = nil) {.raises: [].} =
  if dd == nil or not dd.isOpen: return
  dd.isOpen = false
  dd.hoveredIndex = -1
  if tree != nil:
    updateVisuals(dd, tree)

proc toggle*(dd: DropdownControl, tree: ptr UiTree = nil) {.raises: [].} =
  if dd == nil or dd.disabled: return
  if dd.isOpen: dd.close(tree)
  else: dd.open(tree)

proc select*(dd: DropdownControl, idx: int, tree: ptr UiTree = nil) {.raises: [].} =
  if dd == nil: return
  if idx >= 0 and idx < dd.items.len:
    dd.selectedIndex = idx
    if tree != nil:
      updateVisuals(dd, tree)
    if not dd.onSelect.isNil:
      dd.onSelect(idx)

proc getPopupRect*(dd: DropdownControl, tree: ptr UiTree = nil): tuple[x, y, w, h: float32] {.raises: [].} =
  let (hx, hy, hw, hh) = if tree != nil and tree.nodes.contains(dd.headerId):
    tree.nodes[dd.headerId].computedRect
  else:
    dd.computedHeaderRect
  let popupH = float32(dd.items.len) * dd.itemHeight + 8.0f
  (hx, hy + hh + 4.0f, hw, popupH)

proc handleMouseDown*(dd: DropdownControl, px, py: float32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if dd == nil or dd.disabled: return false

  let (hx, hy, hw, hh) = if tree != nil and tree.nodes.contains(dd.headerId):
    tree.nodes[dd.headerId].computedRect
  else:
    dd.computedHeaderRect

  if px >= hx and px <= hx + hw and py >= hy and py <= hy + hh:
    dd.toggle(tree)
    return true

  if dd.isOpen:
    let (px0, py0, pw, ph) = dd.getPopupRect(tree)
    if px >= px0 and px <= px0 + pw and py >= py0 and py <= py0 + ph:
      let relY = py - (py0 + 4.0f)
      let idx = int(relY / dd.itemHeight)
      if idx >= 0 and idx < dd.items.len:
        dd.select(idx, tree)
        dd.close(tree)
        return true
    else:
      dd.close(tree)
      return true
  false

proc handleMouseMove*(dd: DropdownControl, px, py: float32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if dd == nil or not dd.isOpen: return false
  let (px0, py0, pw, ph) = dd.getPopupRect(tree)
  if px >= px0 and px <= px0 + pw and py >= py0 and py <= py0 + ph:
    let relY = py - (py0 + 4.0f)
    let idx = int(relY / dd.itemHeight)
    if idx >= 0 and idx < dd.items.len:
      if dd.hoveredIndex != idx:
        dd.hoveredIndex = idx
        if tree != nil: tree.isDirty = true
      return true
  else:
    if dd.hoveredIndex != -1:
      dd.hoveredIndex = -1
      if tree != nil: tree.isDirty = true
  false

proc handleKeyDown*(dd: DropdownControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if dd == nil or dd.disabled: return false
  if not dd.isOpen:
    if keyCode == KeySpace or keyCode == KeyReturn or keyCode == KeyDown:
      dd.open(tree)
      return true
  else:
    case keyCode
    of KeyEscape:
      dd.close(tree)
      return true
    of KeyUp:
      if dd.hoveredIndex < 0: dd.hoveredIndex = dd.selectedIndex
      dd.hoveredIndex = max(0, dd.hoveredIndex - 1)
      if tree != nil: tree.isDirty = true
      return true
    of KeyDown:
      if dd.hoveredIndex < 0: dd.hoveredIndex = dd.selectedIndex
      dd.hoveredIndex = min(dd.items.len - 1, dd.hoveredIndex + 1)
      if tree != nil: tree.isDirty = true
      return true
    of KeyReturn, KeySpace:
      if dd.hoveredIndex >= 0 and dd.hoveredIndex < dd.items.len:
        dd.select(dd.hoveredIndex, tree)
      dd.close(tree)
      return true
    else:
      discard
  false

proc renderOverlay*(
  dd: DropdownControl,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas,
  tree: ptr UiTree = nil
) {.raises: [].} =
  if dd == nil or not dd.isOpen or dd.items.len == 0: return

  let (px0, py0, pw, ph) = dd.getPopupRect(tree)
  let clipAll: array[4, uint16] = [0'u16, 0'u16, 0xFFFF'u16, 0xFFFF'u16]

  var cardInst: UiDrawInstance
  cardInst.pos = [px0, py0]
  cardInst.size = [pw, ph]
  cardInst.uvPos = [0.0f, 0.0f]
  cardInst.uvSize = [0.0f, 0.0f]
  cardInst.color = ColBgSurface
  cardInst.borderColor = ColBorderCtl
  cardInst.cornerRadius = 6.0f
  cardInst.borderWidth = 1.0f
  cardInst.softness = 2.0f
  cardInst.clipRect = clipAll
  cardInst.pad = 0'u32
  instances.add(cardInst)

  let textH = if atlas.baseSize > 0.0f: atlas.lineHeight * (dd.fontSize / atlas.baseSize) else: 16.0f

  for i, item in dd.items:
    let iy = py0 + 4.0f + float32(i) * dd.itemHeight
    let isHover = (i == dd.hoveredIndex)
    let isSelected = (i == dd.selectedIndex)

    if isHover or isSelected:
      var itemInst: UiDrawInstance
      itemInst.pos = [px0 + 4.0f, iy]
      itemInst.size = [pw - 8.0f, dd.itemHeight]
      itemInst.uvPos = [0.0f, 0.0f]
      itemInst.uvSize = [0.0f, 0.0f]
      itemInst.color = if isHover: ColBgHover else: ColBgActive
      itemInst.borderColor = 0'u32
      itemInst.cornerRadius = 4.0f
      itemInst.borderWidth = 0.0f
      itemInst.softness = 1.0f
      itemInst.clipRect = clipAll
      itemInst.pad = 0'u32
      instances.add(itemInst)

    let txtCol = if isSelected or isHover: ColTextPrim else: ColTextSec
    let textY = iy + (dd.itemHeight - textH) * 0.5f
    emitTextRun(instances, item, px0 + 12.0f, textY, dd.fontSize, txtCol, clipAll, atlas)

proc Dropdown*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  ctrl: DropdownControl,
  width: SizeMode = fixed(180.0f),
  height: SizeMode = fixed(36.0f)
): SlabId {.raises: [].} =
  let header = HStack(
    tree, parent,
    padding = 8.0f,
    gap = 8.0f,
    bg = ColBgRaised,
    borderColor = if ctrl.isOpen: ColFocusRing else: ColBorderCtl,
    radius = 6.0f,
    borderWidth = 1.0f,
    width = width,
    height = height,
    alignItems = aiCenter
  )
  ctrl.headerId = header

  let currentTitle = if ctrl.selectedIndex >= 0 and ctrl.selectedIndex < ctrl.items.len:
    ctrl.items[ctrl.selectedIndex]
  else:
    ""

  let labelNode = Text(tree, header, currentTitle, size = ctrl.fontSize, color = ColTextPrim)
  ctrl.textId = labelNode
  tree.nodes[labelNode].widthMode = flexGrow()

  let arrowNode = Text(tree, header, if ctrl.isOpen: "▲" else: "▼", size = 10.0f, color = ColTextSec)
  ctrl.arrowId = arrowNode

  let reg = getRegistry()
  reg.dropdowns.add(ctrl)
  reg.nodeToDropdown[header] = ctrl
  reg.nodeToDropdown[labelNode] = ctrl
  reg.nodeToDropdown[arrowNode] = ctrl

  let treePtr = addr tree
  let ddRef = ctrl
  let clickProc = proc() {.closure, gcsafe, raises: [].} =
    ddRef.toggle(treePtr)

  tree.nodes[header].onClick = clickProc
  tree.nodes[labelNode].onClick = clickProc
  tree.nodes[arrowNode].onClick = clickProc

  header

proc Dropdown*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  items: openArray[string],
  selectedIndex: int = 0,
  width: SizeMode = fixed(180.0f),
  height: SizeMode = fixed(36.0f),
  onSelect: proc(idx: int) {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let ctrl = newDropdown(items, selectedIndex, onSelect = onSelect)
  Dropdown(tree, parent, ctrl, width, height)

proc bindDropdown*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  dd: DropdownControl,
  sig: Signal[int]
): EffectId {.discardable, raises: [].} =
  result = rt.createEffect(proc() =
    let val = sig.get()
    if dd.selectedIndex != val:
      dd.select(val, tree)
  )

  let prevSelect = dd.onSelect
  dd.onSelect = proc(idx: int) {.closure, gcsafe, raises: [].} =
    sig.set(idx)
    if not prevSelect.isNil:
      prevSelect(idx)
