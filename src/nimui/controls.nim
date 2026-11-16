## nimui/controls — Expanded Interactive Controls Library (Facade)
##
## Re-exports cohesive control submodules under src/nimui/controls/:
## - common: Monochrome design tokens, key constants, control types & thread-local registry
## - checkbox: CheckboxControl, Checkbox, bindCheckbox
## - radio: RadioGroupControl, RadioButtonControl, RadioButton, RadioGroup, bindRadioGroup
## - slider: SliderControl, Slider, bindSlider
## - dropdown: DropdownControl, Dropdown, bindDropdown, overlay rendering
## - tooltip: TooltipControl, Tooltip, overlay rendering

import corex/slab
import algx/swissmap
import ./layout
import ./gpu/font_atlas
import ./gpu/vulkan_backend

import ./controls/common
import ./controls/checkbox
import ./controls/radio
import ./controls/slider
import ./controls/dropdown
import ./controls/tooltip

export common
export checkbox
export radio
export slider
export dropdown
export tooltip

# =============================================================================
# Unified Event Dispatching & Overlay Rendering
# =============================================================================

proc handleControlMouseDown*(tree: var UiTree, px, py: float32): bool {.raises: [].} =
  let reg = getRegistry()
  let treePtr = addr tree

  for dd in reg.dropdowns:
    if dd.isOpen:
      if dd.handleMouseDown(px, py, treePtr):
        return true

  for s in reg.sliders:
    if s.handleMouseDown(px, py, treePtr):
      return true

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

  for dd in reg.dropdowns:
    if dd.isOpen:
      if dd.handleKeyDown(keyCode, treePtr):
        return true

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
  let startIdx = tree.drawInstances.len

  for dd in reg.dropdowns:
    if dd.isOpen:
      dd.renderOverlay(tree.drawInstances, atlas, treePtr)

  for tt in reg.tooltips:
    tt.update(tree, atlas, screenW, screenH)
    if tt.visible:
      tt.renderOverlay(tree.drawInstances, atlas)

  if tree.dpiScale > 0.1f and abs(tree.dpiScale - 1.0f) >= 1e-4f:
    scaleDrawInstancesForDpi(tree.drawInstances, tree.dpiScale, startIdx)

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
