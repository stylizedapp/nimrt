## nimui/controls/slider — Slider Control & Reactive Bindings

import std/math
import corex/[slab, signals, result]
import algx/swissmap
import ../layout
import ../dsl
import ./common

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

# Safe: tree is nil-checked before deref and owned by the caller.
proc updateSliderWeights*(slider: SliderControl, tree: ptr UiTree) {.trustedUnsafe, raises: [].} =
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

# Safe: tree is a non-owning pointer forwarded to updateSliderWeights (nil-checked).
proc setValue*(slider: SliderControl, val: float32, tree: ptr UiTree = nil) {.trustedUnsafe, raises: [].} =
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

# Safe: tree is nil-checked before deref and owned by the caller.
proc handleMouseDown*(slider: SliderControl, px, py: float32, tree: ptr UiTree = nil): bool {.trustedUnsafe, raises: [].} =
  if slider == nil or slider.disabled or tree == nil: return false
  if not tree.nodes.contains(slider.rootId): return false

  let rect = tree.nodes[slider.rootId].computedRect
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

# Safe: tree is nil-checked before deref and owned by the caller.
proc handleMouseMove*(slider: SliderControl, px, py: float32, tree: ptr UiTree = nil): bool {.trustedUnsafe, raises: [].} =
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

# Safe: tree is a non-owning pointer forwarded to setValue (nil-checked).
proc handleKeyDown*(slider: SliderControl, keyCode: uint32, tree: ptr UiTree = nil): bool {.trustedUnsafe, raises: [].} =
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

# Safe: tree and rt are non-owning pointers to caller-owned UiTree/ReactiveRuntime outliving the effect.
proc bindSlider*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  slider: SliderControl,
  sig: Signal[float32]
): EffectId {.trustedUnsafe, discardable, raises: [].} =
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
