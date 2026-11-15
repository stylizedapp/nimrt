## nimui/controls — Expanded Interactive Controls Library
##
## Strict invariants:
## - Checkbox: toggling state, keyboard accessibility, rounded box, crisp checkmark glyph.
## - RadioButton & RadioGroup: group coordination, circular outer ring, inner filled SDF circle.
## - Slider: continuous and stepped values, track line, active filled track, draggable thumb.
## - Dropdown: header box with item + chevron ('▼'), top-level draw instance overlay popup.
## - Tooltip: hover-triggered floating dark card with subtle border and text.
## - Follows NimUI patterns: Slab[UiNode], SmallVec, zero allocation on render, monochrome design tokens.
## - Clean DSL constructors (Checkbox, RadioButton, RadioGroup, Slider, Dropdown, Tooltip) for UiTree.

import std/[math, strformat]
import corex/unicode
import corex/slab
import corex/smallvec
import corex/signals
import corex/allocators
import algx/swissmap
import ./layout
import ./dsl
import ./gpu/font_atlas
import ./gpu/vulkan_backend

# =============================================================================
# Design Tokens (Monochrome High-Craft System)
# =============================================================================

const
  ColBgPage*      = 0x0A0A0CFF'u32  # Deep obsidian page background
  ColBgSurface*   = 0x121215FF'u32  # Primary card surface
  ColBgRaised*    = 0x1A1A1EFF'u32  # Control surface
  ColBgHover*     = 0x222227FF'u32  # Hover state
  ColBgActive*    = 0x2C2C33FF'u32  # Active / selected state
  ColBorder*      = 0x202025FF'u32  # Subtle layout border
  ColBorderCtl*   = 0x323238FF'u32  # Interactive element border
  ColFocusRing*   = 0x666670FF'u32  # High-contrast focus / active border
  ColTextPrim*    = 0xF2F2F2FF'u32  # High-contrast primary text
  ColTextSec*     = 0x8E8E93FF'u32  # Secondary metadata text
  ColTextTert*    = 0x545458FF'u32  # Annotations and shortcuts

# Keyboard key constants
const
  KeyBackspace* = 0x08'u32
  KeyTab*       = 0x09'u32
  KeyReturn*    = 0x0D'u32
  KeyEscape*    = 0x1B'u32
  KeySpace*     = 0x20'u32
  KeyLeft*      = 0x25'u32
  KeyUp*        = 0x26'u32
  KeyRight*     = 0x27'u32
  KeyDown*      = 0x28'u32

# Forward declarations of types
type
  CheckboxControl* = ref object
    checked*: bool
    disabled*: bool
    label*: string
    size*: float32
    boxId*: SlabId
    checkId*: SlabId
    labelId*: SlabId
    rootId*: SlabId
    onToggle*: proc(checked: bool) {.closure, gcsafe, raises: [].}

  RadioGroupControl* = ref object
    selectedValue*: string
    selectedInt*: int
    radios*: seq[RadioButtonControl]
    containerId*: SlabId
    onSelect*: proc(value: string) {.closure, gcsafe, raises: [].}
    onSelectInt*: proc(idx: int) {.closure, gcsafe, raises: [].}

  RadioGroupState* = RadioGroupControl
  CheckboxState* = CheckboxControl

  RadioButtonControl* = ref object
    group*: RadioGroupControl
    value*: string
    valueInt*: int
    selected*: bool
    disabled*: bool
    label*: string
    size*: float32
    outerRingId*: SlabId
    innerCircleId*: SlabId
    labelId*: SlabId
    rootId*: SlabId
    onSelect*: proc() {.closure, gcsafe, raises: [].}

  RadioButtonState* = RadioButtonControl
  SliderState* = SliderControl
  DropdownState* = DropdownControl
  TooltipState* = TooltipControl

  SliderControl* = ref object
    minVal*: float32
    maxVal*: float32
    step*: float32
    currentVal*: float32
    disabled*: bool
    isDragging*: bool
    width*: float32
    trackHeight*: float32
    thumbSize*: float32
    rootId*: SlabId
    trackFillId*: SlabId
    thumbId*: SlabId
    trackEmptyId*: SlabId
    onValueChange*: proc(val: float32) {.closure, gcsafe, raises: [].}

  DropdownControl* = ref object
    items*: seq[string]
    selectedIndex*: int
    isOpen*: bool
    disabled*: bool
    hoveredIndex*: int
    headerId*: SlabId
    textId*: SlabId
    arrowId*: SlabId
    itemHeight*: float32
    fontSize*: float32
    onSelect*: proc(idx: int) {.closure, gcsafe, raises: [].}
    computedHeaderRect*: tuple[x, y, w, h: float32]

  TooltipPlacement* = enum
    tpAbove
    tpBelow
    tpAuto

  TooltipControl* = ref object
    text*: string
    targetId*: SlabId
    visible*: bool
    placement*: TooltipPlacement
    fontSize*: float32
    padding*: float32
    bg*: uint32
    borderColor*: uint32
    borderWidth*: float32
    radius*: float32
    computedRect*: tuple[x, y, w, h: float32]

  ControlRegistry* = ref object
    checkboxes*: seq[CheckboxControl]
    radioGroups*: seq[RadioGroupControl]
    sliders*: seq[SliderControl]
    dropdowns*: seq[DropdownControl]
    tooltips*: seq[TooltipControl]
    nodeToCheckbox*: FastMap[SlabId, CheckboxControl]
    nodeToRadio*: FastMap[SlabId, RadioButtonControl]
    nodeToSlider*: FastMap[SlabId, SliderControl]
    nodeToDropdown*: FastMap[SlabId, DropdownControl]

var gDefaultRegistry {.threadvar.}: ControlRegistry

proc getRegistry*(): ControlRegistry {.raises: [].} =
  if gDefaultRegistry.isNil:
    gDefaultRegistry = ControlRegistry(
      checkboxes: @[],
      radioGroups: @[],
      sliders: @[],
      dropdowns: @[],
      tooltips: @[],
      nodeToCheckbox: initFastMap[SlabId, CheckboxControl](),
      nodeToRadio: initFastMap[SlabId, RadioButtonControl](),
      nodeToSlider: initFastMap[SlabId, SliderControl](),
      nodeToDropdown: initFastMap[SlabId, DropdownControl]()
    )
  gDefaultRegistry

proc resetControls*() {.raises: [].} =
  if not gDefaultRegistry.isNil:
    gDefaultRegistry.checkboxes.setLen(0)
    gDefaultRegistry.radioGroups.setLen(0)
    gDefaultRegistry.sliders.setLen(0)
    gDefaultRegistry.dropdowns.setLen(0)
    gDefaultRegistry.tooltips.setLen(0)
    gDefaultRegistry.nodeToCheckbox.clear()
    gDefaultRegistry.nodeToRadio.clear()
    gDefaultRegistry.nodeToSlider.clear()
    gDefaultRegistry.nodeToDropdown.clear()

# =============================================================================
# 1. Checkbox Component
# =============================================================================

proc newCheckbox*(
  label: string = "",
  checked: bool = false,
  size: float32 = 18.0f,
  onToggle: proc(checked: bool) {.closure, gcsafe, raises: [].} = nil
): CheckboxControl {.raises: [].} =
  result = CheckboxControl(
    checked: checked,
    disabled: false,
    label: label,
    size: size,
    boxId: SlabId(-1),
    checkId: SlabId(-1),
    labelId: SlabId(-1),
    rootId: SlabId(-1),
    onToggle: onToggle
  )

proc updateVisuals*(cb: CheckboxControl, tree: ptr UiTree) {.raises: [].} =
  if tree == nil or cb == nil: return
  if cb.boxId != SlabId(-1) and tree.nodes.contains(cb.boxId):
    let b = addr tree.nodes[cb.boxId]
    b.text = if cb.checked: "✓" else: ""
    b.bgColor = if cb.checked: ColBgActive else: ColBgRaised
    b.borderColor = if cb.checked: ColFocusRing else: ColBorderCtl
  tree.isDirty = true

proc setChecked*(cb: CheckboxControl, checked: bool, tree: ptr UiTree = nil) {.raises: [].} =
  if cb == nil: return
  if cb.checked != checked:
    cb.checked = checked
    if tree != nil:
      updateVisuals(cb, tree)
    if not cb.onToggle.isNil:
      cb.onToggle(cb.checked)

proc toggle*(cb: CheckboxControl, tree: ptr UiTree = nil) {.raises: [].} =
  if cb == nil or cb.disabled: return
  cb.setChecked(not cb.checked, tree)

proc handleKeyDown*(cb: CheckboxControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if cb == nil or cb.disabled: return false
  if keyCode == KeySpace or keyCode == KeyReturn:
    cb.toggle(tree)
    return true
  false

proc Checkbox*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  ctrl: CheckboxControl,
  gap: float32 = 8.0f
): SlabId {.raises: [].} =
  let root = HStack(
    tree, parent,
    padding = 2.0f,
    gap = gap,
    alignItems = aiCenter
  )
  ctrl.rootId = root

  let box = Button(
    tree, root,
    label = if ctrl.checked: "✓" else: "",
    size = max(10.0f, ctrl.size - 4.0f),
    bg = if ctrl.checked: ColBgActive else: ColBgRaised,
    bgHover = ColBgHover,
    bgActive = ColBgActive,
    borderColor = if ctrl.checked: ColFocusRing else: ColBorderCtl,
    radius = 4.0f,
    borderWidth = 1.0f,
    color = ColTextPrim,
    padding = 0.0f
  )
  ctrl.boxId = box
  tree.nodes[box].widthMode = fixed(ctrl.size)
  tree.nodes[box].heightMode = fixed(ctrl.size)

  var lbl = SlabId(-1)
  if ctrl.label.len > 0:
    lbl = Text(tree, root, ctrl.label, size = 14.0f, color = ColTextPrim)
    ctrl.labelId = lbl

  let reg = getRegistry()
  reg.checkboxes.add(ctrl)
  reg.nodeToCheckbox[root] = ctrl
  reg.nodeToCheckbox[box] = ctrl
  if lbl != SlabId(-1):
    reg.nodeToCheckbox[lbl] = ctrl

  let treePtr = addr tree
  let cbRef = ctrl
  let clickProc = proc() {.closure, gcsafe, raises: [].} =
    cbRef.toggle(treePtr)

  tree.nodes[box].onClick = clickProc
  tree.nodes[root].onClick = clickProc
  if lbl != SlabId(-1):
    tree.nodes[lbl].onClick = clickProc

  root

proc Checkbox*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  label: string = "",
  checked: bool = false,
  size: float32 = 18.0f,
  gap: float32 = 8.0f,
  onToggle: proc(checked: bool) {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let ctrl = newCheckbox(label, checked, size, onToggle)
  Checkbox(tree, parent, ctrl, gap)

proc bindCheckbox*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  cb: CheckboxControl,
  sig: Signal[bool]
): EffectId {.discardable, raises: [].} =
  # 1. Signal -> Checkbox UI
  result = rt.createEffect(proc() =
    let val = sig.get()
    if cb.checked != val:
      cb.checked = val
      cb.updateVisuals(tree)
  )

  # 2. Checkbox UI -> Signal
  let prevToggle = cb.onToggle
  cb.onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
    sig.set(c)
    if not prevToggle.isNil:
      prevToggle(c)

# =============================================================================
# 2. RadioButton & RadioGroup Component
# =============================================================================

proc newRadioGroup*(
  onSelect: proc(value: string) {.closure, gcsafe, raises: [].} = nil,
  onSelectInt: proc(idx: int) {.closure, gcsafe, raises: [].} = nil
): RadioGroupControl {.raises: [].} =
  RadioGroupControl(
    selectedValue: "",
    selectedInt: -1,
    radios: @[],
    containerId: SlabId(-1),
    onSelect: onSelect,
    onSelectInt: onSelectInt
  )

proc newRadioButton*(
  label: string = "",
  value: string = "",
  selected: bool = false,
  group: RadioGroupControl = nil,
  valueInt: int = 0,
  size: float32 = 18.0f,
  onSelect: proc() {.closure, gcsafe, raises: [].} = nil
): RadioButtonControl {.raises: [].} =
  result = RadioButtonControl(
    group: group,
    value: if value.len > 0: value else: label,
    valueInt: valueInt,
    selected: selected,
    disabled: false,
    label: label,
    size: size,
    outerRingId: SlabId(-1),
    innerCircleId: SlabId(-1),
    labelId: SlabId(-1),
    rootId: SlabId(-1),
    onSelect: onSelect
  )
  if group != nil:
    group.radios.add(result)
    if selected:
      group.selectedValue = result.value
      group.selectedInt = result.valueInt

proc updateVisuals*(radio: RadioButtonControl, tree: ptr UiTree) {.raises: [].} =
  if tree == nil or radio == nil: return
  if radio.outerRingId != SlabId(-1) and tree.nodes.contains(radio.outerRingId):
    let outer = addr tree.nodes[radio.outerRingId]
    outer.borderColor = if radio.selected: ColFocusRing else: ColBorderCtl
  if radio.innerCircleId != SlabId(-1) and tree.nodes.contains(radio.innerCircleId):
    let inner = addr tree.nodes[radio.innerCircleId]
    inner.bgColor = if radio.selected: ColTextPrim else: 0x00000000'u32
  tree.isDirty = true

proc select*(radio: RadioButtonControl, tree: ptr UiTree = nil) {.raises: [].} =
  if radio == nil or radio.disabled: return
  if radio.group != nil:
    for other in radio.group.radios:
      if other != radio:
        other.selected = false
        if tree != nil:
          updateVisuals(other, tree)
    radio.group.selectedValue = radio.value
    radio.group.selectedInt = radio.valueInt

  radio.selected = true
  if tree != nil:
    updateVisuals(radio, tree)

  if not radio.onSelect.isNil:
    radio.onSelect()
  if radio.group != nil:
    if not radio.group.onSelect.isNil:
      radio.group.onSelect(radio.value)
    if not radio.group.onSelectInt.isNil:
      radio.group.onSelectInt(radio.valueInt)

proc select*(group: RadioGroupControl, value: string, tree: ptr UiTree = nil) {.raises: [].} =
  if group == nil: return
  for r in group.radios:
    if r.value == value:
      r.select(tree)
      return

proc select*(group: RadioGroupControl, index: int, tree: ptr UiTree = nil) {.raises: [].} =
  if group == nil: return
  if index >= 0 and index < group.radios.len:
    group.radios[index].select(tree)

proc handleKeyDown*(group: RadioGroupControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if group == nil or group.radios.len == 0: return false
  case keyCode
  of KeyUp, KeyLeft:
    var curIdx = group.selectedInt
    if curIdx < 0: curIdx = 0
    else: curIdx = (curIdx - 1 + group.radios.len) mod group.radios.len
    group.select(curIdx, tree)
    return true
  of KeyDown, KeyRight:
    var curIdx = group.selectedInt
    if curIdx < 0: curIdx = 0
    else: curIdx = (curIdx + 1) mod group.radios.len
    group.select(curIdx, tree)
    return true
  of KeySpace, KeyReturn:
    if group.selectedInt >= 0 and group.selectedInt < group.radios.len:
      group.select(group.selectedInt, tree)
      return true
  else:
    discard
  false

proc RadioButton*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  ctrl: RadioButtonControl,
  gap: float32 = 8.0f
): SlabId {.raises: [].} =
  let root = HStack(
    tree, parent,
    padding = 2.0f,
    gap = gap,
    alignItems = aiCenter
  )
  ctrl.rootId = root

  let outer = Box(
    tree, root,
    width = fixed(ctrl.size),
    height = fixed(ctrl.size),
    bg = ColBgRaised,
    borderColor = if ctrl.selected: ColFocusRing else: ColBorderCtl,
    radius = ctrl.size * 0.5f,
    borderWidth = 1.5f,
    softness = 1.0f,
    alignItems = aiCenter,
    justifyContent = jcCenter
  )
  ctrl.outerRingId = outer

  let innerSize = max(4.0f, ctrl.size - 8.0f)
  let innerPad = (ctrl.size - innerSize) * 0.5f
  tree.nodes[outer].padding = [innerPad, innerPad, innerPad, innerPad]

  let inner = Box(
    tree, outer,
    width = fixed(innerSize),
    height = fixed(innerSize),
    bg = if ctrl.selected: ColTextPrim else: 0x00000000'u32,
    radius = innerSize * 0.5f,
    borderWidth = 0.0f,
    softness = 1.0f
  )
  ctrl.innerCircleId = inner

  var lbl = SlabId(-1)
  if ctrl.label.len > 0:
    lbl = Text(tree, root, ctrl.label, size = 14.0f, color = ColTextPrim)
    ctrl.labelId = lbl

  let reg = getRegistry()
  reg.nodeToRadio[root] = ctrl
  reg.nodeToRadio[outer] = ctrl
  reg.nodeToRadio[inner] = ctrl
  if lbl != SlabId(-1):
    reg.nodeToRadio[lbl] = ctrl

  let treePtr = addr tree
  let radioRef = ctrl
  let clickProc = proc() {.closure, gcsafe, raises: [].} =
    radioRef.select(treePtr)

  tree.nodes[outer].onClick = clickProc
  tree.nodes[inner].onClick = clickProc
  tree.nodes[root].onClick = clickProc
  if lbl != SlabId(-1):
    tree.nodes[lbl].onClick = clickProc

  root

proc RadioButton*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  label: string = "",
  selected: bool = false,
  group: RadioGroupControl = nil,
  value: string = "",
  valueInt: int = 0,
  size: float32 = 18.0f,
  gap: float32 = 8.0f,
  onSelect: proc() {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let ctrl = newRadioButton(label, value, selected, group, valueInt, size, onSelect)
  RadioButton(tree, parent, ctrl, gap)

proc RadioGroup*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  options: openArray[string],
  selectedIndex: int = 0,
  direction: FlexDirection = fdColumn,
  gap: float32 = 8.0f,
  onSelect: proc(idx: int, val: string) {.closure, gcsafe, raises: [].} = nil
): tuple[containerId: SlabId, group: RadioGroupControl] {.raises: [].} =
  var optList = newSeqOfCap[string](options.len)
  for opt in options:
    optList.add(opt)

  let group = newRadioGroup(
    onSelect = proc(v: string) {.closure, gcsafe, raises: [].} =
      if not onSelect.isNil:
        var foundIdx = -1
        for i, opt in optList:
          if opt == v: foundIdx = i; break
        onSelect(foundIdx, v),
    onSelectInt = proc(i: int) {.closure, gcsafe, raises: [].} =
      if not onSelect.isNil and i >= 0 and i < optList.len:
        onSelect(i, optList[i])
  )

  let container = Box(
    tree, parent,
    direction = direction,
    gap = gap
  )
  group.containerId = container

  for i, opt in options:
    let isSel = (i == selectedIndex)
    let radioCtrl = newRadioButton(opt, opt, isSel, group, i)
    discard RadioButton(tree, container, radioCtrl, gap = 8.0f)

  if selectedIndex >= 0 and selectedIndex < options.len:
    group.selectedValue = options[selectedIndex]
    group.selectedInt = selectedIndex

  getRegistry().radioGroups.add(group)
  (container, group)

proc bindRadioGroup*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  group: RadioGroupControl,
  sig: Signal[string]
): EffectId {.discardable, raises: [].} =
  result = rt.createEffect(proc() =
    let val = sig.get()
    if group.selectedValue != val:
      group.select(val, tree)
  )

  let prevSelect = group.onSelect
  group.onSelect = proc(val: string) {.closure, gcsafe, raises: [].} =
    sig.set(val)
    if not prevSelect.isNil:
      prevSelect(val)

# =============================================================================
# 3. Slider Component
# =============================================================================

proc newSlider*(
  minVal: float32 = 0.0f,
  maxVal: float32 = 100.0f,
  currentVal: float32 = 0.0f,
  step: float32 = 0.0f,
  trackHeight: float32 = 4.0f,
  thumbSize: float32 = 16.0f,
  onValueChange: proc(val: float32) {.closure, gcsafe, raises: [].} = nil
): SliderControl {.raises: [].} =
  let clamped = clamp(currentVal, minVal, maxVal)
  SliderControl(
    minVal: minVal,
    maxVal: maxVal,
    step: step,
    currentVal: clamped,
    disabled: false,
    isDragging: false,
    width: 0.0f,
    trackHeight: trackHeight,
    thumbSize: thumbSize,
    rootId: SlabId(-1),
    trackFillId: SlabId(-1),
    thumbId: SlabId(-1),
    trackEmptyId: SlabId(-1),
    onValueChange: onValueChange
  )

proc updateSliderWeights*(slider: SliderControl, tree: ptr UiTree) {.raises: [].} =
  if tree == nil or slider == nil: return
  let span = max(0.0001f, slider.maxVal - slider.minVal)
  let ratio = clamp((slider.currentVal - slider.minVal) / span, 0.0f, 1.0f)

  let epsFill = max(0.0001f, ratio)
  let epsEmpty = max(0.0001f, 1.0f - ratio)

  if slider.trackFillId != SlabId(-1) and tree.nodes.contains(slider.trackFillId):
    tree.nodes[slider.trackFillId].widthMode = flexGrow(epsFill)
  if slider.trackEmptyId != SlabId(-1) and tree.nodes.contains(slider.trackEmptyId):
    tree.nodes[slider.trackEmptyId].widthMode = flexGrow(epsEmpty)

  tree.isLayoutDirty = true
  tree.isDirty = true

proc setValue*(slider: SliderControl, val: float32, tree: ptr UiTree = nil) {.raises: [].} =
  if slider == nil: return
  var clamped = clamp(val, slider.minVal, slider.maxVal)
  if slider.step > 0.0f:
    clamped = slider.minVal + round((clamped - slider.minVal) / slider.step) * slider.step
    clamped = clamp(clamped, slider.minVal, slider.maxVal)

  if slider.currentVal != clamped:
    slider.currentVal = clamped
    if tree != nil:
      updateSliderWeights(slider, tree)
    if not slider.onValueChange.isNil:
      slider.onValueChange(slider.currentVal)

proc handleMouseDown*(slider: SliderControl, px, py: float32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if slider == nil or slider.disabled or tree == nil: return false
  if not tree.nodes.contains(slider.rootId): return false

  let rect = tree.nodes[slider.rootId].computedRect
  # Hit-test slider bounds with 4px grab margin
  if px >= rect.x - 4.0f and px <= rect.x + rect.w + 4.0f and
     py >= rect.y - 6.0f and py <= rect.y + rect.h + 6.0f:
    slider.isDragging = true
    let innerW = max(1.0f, rect.w - slider.thumbSize)
    let relX = px - (rect.x + slider.thumbSize * 0.5f)
    let ratio = clamp(relX / innerW, 0.0f, 1.0f)
    let rawVal = slider.minVal + ratio * (slider.maxVal - slider.minVal)
    slider.setValue(rawVal, tree)
    return true
  false

proc handleMouseMove*(slider: SliderControl, px, py: float32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if slider == nil or not slider.isDragging or slider.disabled or tree == nil: return false
  if not tree.nodes.contains(slider.rootId): return false

  let rect = tree.nodes[slider.rootId].computedRect
  let innerW = max(1.0f, rect.w - slider.thumbSize)
  let relX = px - (rect.x + slider.thumbSize * 0.5f)
  let ratio = clamp(relX / innerW, 0.0f, 1.0f)
  let rawVal = slider.minVal + ratio * (slider.maxVal - slider.minVal)
  slider.setValue(rawVal, tree)
  return true

proc handleMouseUp*(slider: SliderControl, px, py: float32): bool {.raises: [].} =
  if slider != nil and slider.isDragging:
    slider.isDragging = false
    return true
  false

proc handleKeyDown*(slider: SliderControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.raises: [].} =
  if slider == nil or slider.disabled: return false
  let stepVal = if slider.step > 0.0f: slider.step else: (slider.maxVal - slider.minVal) * 0.05f
  case keyCode
  of KeyLeft, KeyDown:
    slider.setValue(slider.currentVal - stepVal, tree)
    return true
  of KeyRight, KeyUp:
    slider.setValue(slider.currentVal + stepVal, tree)
    return true
  else:
    discard
  false

proc Slider*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  ctrl: SliderControl,
  width: SizeMode = flexGrow()
): SlabId {.raises: [].} =
  let span = max(0.0001f, ctrl.maxVal - ctrl.minVal)
  let ratio = clamp((ctrl.currentVal - ctrl.minVal) / span, 0.0f, 1.0f)

  let containerH = max(ctrl.trackHeight, ctrl.thumbSize) + 8.0f
  let root = HStack(
    tree, parent,
    width = width,
    height = fixed(containerH),
    alignItems = aiCenter
  )
  ctrl.rootId = root

  let epsFill = max(0.0001f, ratio)
  let epsEmpty = max(0.0001f, 1.0f - ratio)

  let fillTrack = Box(
    tree, root,
    width = flexGrow(epsFill),
    height = fixed(ctrl.trackHeight),
    bg = ColFocusRing,
    radius = ctrl.trackHeight * 0.5f,
    borderWidth = 0.0f
  )
  ctrl.trackFillId = fillTrack

  let thumb = Button(
    tree, root,
    label = "",
    size = 10.0f,
    bg = ColTextPrim,
    bgHover = 0xFFFFFFFF'u32,
    bgActive = 0xCCCCCCFF'u32,
    borderColor = ColBorderCtl,
    radius = ctrl.thumbSize * 0.5f,
    borderWidth = 1.0f,
    padding = 0.0f
  )
  ctrl.thumbId = thumb
  tree.nodes[thumb].widthMode = fixed(ctrl.thumbSize)
  tree.nodes[thumb].heightMode = fixed(ctrl.thumbSize)

  let emptyTrack = Box(
    tree, root,
    width = flexGrow(epsEmpty),
    height = fixed(ctrl.trackHeight),
    bg = ColBgRaised,
    radius = ctrl.trackHeight * 0.5f,
    borderWidth = 0.0f
  )
  ctrl.trackEmptyId = emptyTrack

  let reg = getRegistry()
  reg.sliders.add(ctrl)
  reg.nodeToSlider[root] = ctrl
  reg.nodeToSlider[fillTrack] = ctrl
  reg.nodeToSlider[thumb] = ctrl
  reg.nodeToSlider[emptyTrack] = ctrl

  root

proc Slider*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  minVal: float32 = 0.0f,
  maxVal: float32 = 100.0f,
  currentVal: float32 = 0.0f,
  step: float32 = 0.0f,
  width: SizeMode = flexGrow(),
  trackHeight: float32 = 4.0f,
  thumbSize: float32 = 16.0f,
  onValueChange: proc(val: float32) {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let ctrl = newSlider(minVal, maxVal, currentVal, step, trackHeight, thumbSize, onValueChange)
  Slider(tree, parent, ctrl, width)

proc bindSlider*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  slider: SliderControl,
  sig: Signal[float32]
): EffectId {.discardable, raises: [].} =
  result = rt.createEffect(proc() =
    let val = sig.get()
    if slider.currentVal != val:
      slider.setValue(val, tree)
  )

  let prevChange = slider.onValueChange
  slider.onValueChange = proc(val: float32) {.closure, gcsafe, raises: [].} =
    sig.set(val)
    if not prevChange.isNil:
      prevChange(val)

# =============================================================================
# 4. Dropdown / Select Component
# =============================================================================

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

  # Click inside header
  if px >= hx and px <= hx + hw and py >= hy and py <= hy + hh:
    dd.toggle(tree)
    return true

  # If open, check popup options or outside click
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
      # Clicked outside popup
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

  # 1. Overlay Container Card (Top-level SDF quad)
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

  # 2. Render Options
  let textH = if atlas.baseSize > 0.0f: atlas.lineHeight * (dd.fontSize / atlas.baseSize) else: 16.0f

  for i, item in dd.items:
    let iy = py0 + 4.0f + float32(i) * dd.itemHeight
    let isHover = (i == dd.hoveredIndex)
    let isSelected = (i == dd.selectedIndex)

    # Highlight quad
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

# =============================================================================
# 5. Tooltip Component
# =============================================================================

proc newTooltip*(
  targetId: SlabId,
  text: string,
  placement: TooltipPlacement = tpAuto,
  fontSize: float32 = 12.0f,
  padding: float32 = 8.0f
): TooltipControl {.raises: [].} =
  TooltipControl(
    text: text,
    targetId: targetId,
    visible: false,
    placement: placement,
    fontSize: fontSize,
    padding: padding,
    bg: ColBgSurface,
    borderColor: ColBorderCtl,
    borderWidth: 1.0f,
    radius: 4.0f,
    computedRect: (0.0f, 0.0f, 0.0f, 0.0f)
  )

proc update*(
  tt: TooltipControl,
  tree: UiTree,
  atlas: FontAtlas,
  screenW: float32 = 1920.0f,
  screenH: float32 = 1080.0f
) {.raises: [].} =
  if tt == nil: return
  if tt.targetId == SlabId(-1) or not tree.nodes.contains(tt.targetId):
    tt.visible = false
    return

  let target = addr tree.nodes[tt.targetId]
  let isHovered = target.isHovered or (tree.hoveredNode == tt.targetId)
  tt.visible = isHovered

  if tt.visible:
    let (tw, th) = if atlas.baseSize > 0.0f:
      atlas.measureText(tt.text, tt.fontSize)
    else:
      (float32(tt.text.len) * 8.0f, 16.0f)

    let cw = tw + tt.padding * 2.0f
    let ch = th + tt.padding * 1.5f
    let (tx, ty, twTarget, thTarget) = target.computedRect

    var cx = tx + (twTarget - cw) * 0.5f
    cx = max(4.0f, min(screenW - cw - 4.0f, cx))

    var cy = 0.0f
    case tt.placement
    of tpAbove:
      cy = ty - ch - 6.0f
    of tpBelow:
      cy = ty + thTarget + 6.0f
    of tpAuto:
      if ty - ch - 6.0f >= 0.0f:
        cy = ty - ch - 6.0f
      else:
        cy = ty + thTarget + 6.0f

    tt.computedRect = (cx, cy, cw, ch)

proc renderOverlay*(
  tt: TooltipControl,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas
) {.raises: [].} =
  if tt == nil or not tt.visible or tt.text.len == 0: return

  let clipAll: array[4, uint16] = [0'u16, 0'u16, 0xFFFF'u16, 0xFFFF'u16]
  let (cx, cy, cw, ch) = tt.computedRect

  # Tooltip background card
  var cardInst: UiDrawInstance
  cardInst.pos = [cx, cy]
  cardInst.size = [cw, ch]
  cardInst.uvPos = [0.0f, 0.0f]
  cardInst.uvSize = [0.0f, 0.0f]
  cardInst.color = tt.bg
  cardInst.borderColor = tt.borderColor
  cardInst.cornerRadius = tt.radius
  cardInst.borderWidth = tt.borderWidth
  cardInst.softness = 2.0f
  cardInst.clipRect = clipAll
  cardInst.pad = 0'u32
  instances.add(cardInst)

  # Tooltip text
  let textY = cy + tt.padding * 0.75f
  emitTextRun(instances, tt.text, cx + tt.padding, textY, tt.fontSize, ColTextPrim, clipAll, atlas)

proc Tooltip*(
  tree: var UiTree,
  targetId: SlabId,
  text: string,
  placement: TooltipPlacement = tpAuto
): TooltipControl {.discardable, raises: [].} =
  let tt = newTooltip(targetId, text, placement)
  getRegistry().tooltips.add(tt)
  tt

# =============================================================================
# Unified Event Dispatching & Overlay Rendering
# =============================================================================

proc handleControlMouseDown*(tree: var UiTree, px, py: float32): bool {.raises: [].} =
  let reg = getRegistry()
  let treePtr = addr tree

  # Check open dropdowns first (highest priority)
  for dd in reg.dropdowns:
    if dd.isOpen:
      if dd.handleMouseDown(px, py, treePtr):
        return true

  # Sliders
  for s in reg.sliders:
    if s.handleMouseDown(px, py, treePtr):
      return true

  # Closed dropdown headers
  for dd in reg.dropdowns:
    if not dd.isOpen:
      if dd.handleMouseDown(px, py, treePtr):
        return true

  false

proc handleControlMouseMove*(tree: var UiTree, px, py: float32): bool {.raises: [].} =
  let reg = getRegistry()
  let treePtr = addr tree
  var handled = false

  for s in reg.sliders:
    if s.isDragging:
      if s.handleMouseMove(px, py, treePtr):
        handled = true

  for dd in reg.dropdowns:
    if dd.isOpen:
      if dd.handleMouseMove(px, py, treePtr):
        handled = true

  handled

proc handleControlMouseUp*(tree: var UiTree, px, py: float32): bool {.raises: [].} =
  let reg = getRegistry()
  var handled = false
  for s in reg.sliders:
    if s.handleMouseUp(px, py):
      handled = true
  handled

proc handleControlKeyDown*(tree: var UiTree, keyCode: uint32): bool {.raises: [].} =
  let reg = getRegistry()
  let treePtr = addr tree

  # Open dropdowns intercept escape / arrow keys first
  for dd in reg.dropdowns:
    if dd.isOpen:
      if dd.handleKeyDown(keyCode, treePtr):
        return true

  # Focused controls
  if tree.focusedNode != SlabId(-1):
    let f = tree.focusedNode
    let cb = reg.nodeToCheckbox.getOrDefault(f)
    if cb != nil:
      return cb.handleKeyDown(keyCode, treePtr)
    let r = reg.nodeToRadio.getOrDefault(f)
    if r != nil:
      if r.group != nil:
        return r.group.handleKeyDown(keyCode, treePtr)
      elif keyCode == KeySpace or keyCode == KeyReturn:
        r.select(treePtr)
        return true
    let s = reg.nodeToSlider.getOrDefault(f)
    if s != nil:
      return s.handleKeyDown(keyCode, treePtr)
    let dd = reg.nodeToDropdown.getOrDefault(f)
    if dd != nil:
      return dd.handleKeyDown(keyCode, treePtr)

  false

proc renderControlOverlays*(
  tree: var UiTree,
  atlas: FontAtlas,
  screenW: float32 = 1920.0f,
  screenH: float32 = 1080.0f
) {.raises: [].} =
  let reg = getRegistry()
  let treePtr = addr tree

  # 1. Open Dropdowns
  for dd in reg.dropdowns:
    if dd.isOpen:
      dd.renderOverlay(tree.drawInstances, atlas, treePtr)

  # 2. Visible Tooltips
  for tt in reg.tooltips:
    tt.update(tree, atlas, screenW, screenH)
    if tt.visible:
      tt.renderOverlay(tree.drawInstances, atlas)

proc buildDrawInstancesWithOverlays*(
  tree: var UiTree,
  atlas: FontAtlas,
  screenW: float32 = 1920.0f,
  screenH: float32 = 1080.0f
): ptr UiDrawInstance {.raises: [].} =
  discard tree.buildDrawInstances(atlas)
  renderControlOverlays(tree, atlas, screenW, screenH)
  if tree.drawInstances.len > 0:
    addr tree.drawInstances[0]
  else:
    nil
