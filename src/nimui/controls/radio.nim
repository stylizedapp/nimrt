## nimui/controls/radio — RadioButton & RadioGroup Controls

import corex/[slab, signals, result]
import algx/swissmap
import ../layout
import ../dsl
import ./common

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

# Safe: tree is nil-checked before deref and owned by the caller.
proc updateVisuals*(radio: RadioButtonControl, tree: ptr UiTree) {.trustedUnsafe, raises: [].} =
  if tree == nil or radio == nil: return
  if radio.outerRingId != SlabId(-1) and tree.nodes.contains(radio.outerRingId):
    tree.nodes[radio.outerRingId].borderColor = if radio.selected: ColFocusRing else: ColBorderCtl
  if radio.innerCircleId != SlabId(-1) and tree.nodes.contains(radio.innerCircleId):
    tree.nodes[radio.innerCircleId].bgColor = if radio.selected: ColTextPrim else: 0x00000000'u32
  tree.isDirty = true

# Safe: tree is a non-owning pointer forwarded to updateVisuals (nil-checked).
proc select*(radio: RadioButtonControl, tree: ptr UiTree = nil) {.trustedUnsafe, raises: [].} =
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

# Safe: tree is a non-owning pointer forwarded to RadioButtonControl.select.
proc select*(group: RadioGroupControl, value: string, tree: ptr UiTree = nil) {.trustedUnsafe, raises: [].} =
  if group == nil: return
  for r in group.radios:
    if r.value == value:
      r.select(tree)
      return

# Safe: tree is a non-owning pointer forwarded to RadioButtonControl.select.
proc select*(group: RadioGroupControl, index: int, tree: ptr UiTree = nil) {.trustedUnsafe, raises: [].} =
  if group == nil: return
  if index >= 0 and index < group.radios.len:
    group.radios[index].select(tree)

# Safe: tree is a non-owning pointer forwarded to RadioGroupControl.select.
proc handleKeyDown*(group: RadioGroupControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.trustedUnsafe, raises: [].} =
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

  # Safe: treePtr is a non-owning pointer to caller-owned UiTree outliving the onClick closure.
  block trustedUnsafe:
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

# Safe: tree and rt are non-owning pointers to caller-owned UiTree/ReactiveRuntime outliving the effect.
proc bindRadioGroup*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  group: RadioGroupControl,
  sig: Signal[string]
): EffectId {.trustedUnsafe, discardable, raises: [].} =
  result = rt.createEffect(proc() =
    let val = sig.get()
    if group.selectedValue != val:
      group.select(val, tree)
  )

  let prevSelect = group.onSelect
  group.onSelect = proc(val: string) {.closure, gcsafe, raises: [].} =
    var copy = newStringOfCap(val.len)
    copy.add(val)
    sig.set(copy)
    if not prevSelect.isNil:
      prevSelect(val)
