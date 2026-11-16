## nimui/controls/checkbox — Checkbox Control & Reactive Bindings

import corex/[slab, signals, result]
import algx/swissmap
import ../layout
import ../dsl
import ./common

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

# Safe: tree is nil-checked before deref and owned by the caller.
proc updateVisuals*(cb: CheckboxControl, tree: ptr UiTree) {.trustedUnsafe, raises: [].} =
  if tree == nil or cb == nil: return
  if cb.boxId != SlabId(-1) and tree.nodes.contains(cb.boxId):
    template b: untyped = tree.nodes[cb.boxId]
    b.text = if cb.checked: "✓" else: ""
    b.bgColor = if cb.checked: ColBgActive else: ColBgRaised
    b.borderColor = if cb.checked: ColFocusRing else: ColBorderCtl
  tree.isDirty = true

# Safe: tree is a non-owning pointer forwarded to updateVisuals (nil-checked).
proc setChecked*(cb: CheckboxControl, checked: bool, tree: ptr UiTree = nil) {.trustedUnsafe, raises: [].} =
  if cb == nil: return
  if cb.checked != checked:
    cb.checked = checked
    if tree != nil:
      updateVisuals(cb, tree)
    if not cb.onToggle.isNil:
      cb.onToggle(cb.checked)

# Safe: tree is a non-owning pointer forwarded to setChecked (nil-checked).
proc toggle*(cb: CheckboxControl, tree: ptr UiTree = nil) {.trustedUnsafe, raises: [].} =
  if cb == nil or cb.disabled: return
  cb.setChecked(not cb.checked, tree)

# Safe: tree is a non-owning pointer forwarded to toggle (nil-checked).
proc handleKeyDown*(cb: CheckboxControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.trustedUnsafe, raises: [].} =
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

  # Safe: treePtr is a non-owning pointer to caller-owned UiTree outliving the onClick closure.
  block trustedUnsafe:
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

# Safe: tree and rt are non-owning pointers to caller-owned UiTree/ReactiveRuntime outliving the effect.
proc bindCheckbox*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  cb: CheckboxControl,
  sig: Signal[bool]
): EffectId {.trustedUnsafe, discardable, raises: [].} =
  result = rt.createEffect(proc() =
    let val = sig.get()
    if cb.checked != val:
      cb.checked = val
      cb.updateVisuals(tree)
  )

  let prevToggle = cb.onToggle
  cb.onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
    sig.set(c)
    if not prevToggle.isNil:
      prevToggle(c)
