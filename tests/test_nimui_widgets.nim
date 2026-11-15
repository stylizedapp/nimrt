## tests/test_nimui_widgets.nim — Comprehensive Headless Tests for NimUI Widgets & Subsystems
##
## Strict invariants:
## 1. Checkbox: toggling, hit-testing, state transitions, keyboard accessibility, reactive bindings.
## 2. RadioButton & RadioGroup: mutual exclusivity, arrow navigation, callbacks, reactive bindings.
## 3. Slider: value clamping, stepping, track fill calculation, mouse drag emulation, keyboard stepping.
## 4. Dropdown: opening, option selection, outside click closing, keyboard navigation, overlay rendering.
## 5. Tooltip: hover trigger, geometry bounds (above/below/auto), screen edge clamping, overlay rendering.
## 6. Clipboard: safe UTF-16 <-> UTF-8 conversion, in-memory fallback, system roundtrip.
## 7. Multiline: newline splitting, word-wrapping, oversized word breaking, coordinate mapping.
## 8. TextArea: typing, backspace/delete, navigation, selection range, clipboard cut/copy/paste.
## 9. Strict zero-leak audit using testWithLeakCheck (1,000 cycles for every component & combined tree).
##
## Compilation: nim c -r tests/test_nimui_widgets.nim under --mm:orc --threads:on --panics:on

import std/[strformat, strutils, math]
import corex
import corex/unicode
import nimui
import nimui/layout
import nimui/dsl
import nimui/controls
import nimui/clipboard
import nimui/multiline
import nimui/gpu/font_atlas
import nimui/gpu/vulkan_backend

proc approxEq(a, b: float32, eps: float32 = 0.05f): bool {.inline, raises: [].} =
  abs(a - b) <= eps

# =============================================================================
# SUITE 1: Checkbox Invariants & State Transitions
# =============================================================================

proc testCheckboxSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 1] CHECKBOX INVARIANTS & STATE TRANSITIONS <<<"
  echo "================================================================="

  testWithLeakCheck("1.1 Checkbox Default Construction & Visual State"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let cb = newCheckbox(label = "Enable Physics", checked = false, size = 18.0f)
    let root = Checkbox(tree, SlabId(-1), cb)
    tree.rootId = root

    tree.layoutTree(400.0f, 300.0f, atlas)

    doAssert not cb.checked
    doAssert cb.label == "Enable Physics"
    doAssert cb.boxId != SlabId(-1)
    doAssert cb.labelId != SlabId(-1)
    doAssert tree.nodes[cb.boxId].text == ""
    doAssert tree.nodes[cb.boxId].bgColor == ColBgRaised
    doAssert tree.nodes[cb.boxId].borderColor == ColBorderCtl
    doAssert tree.nodes[cb.labelId].text == "Enable Physics"
    echo "  [PASS] 1.1 Checkbox default construction & visual state verified."

  testWithLeakCheck("1.2 Checkbox Toggling & onToggle Callback"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    var toggleCount = 0
    var lastState = false
    let cb = newCheckbox("Toggle Me", checked = false, size = 18.0f, onToggle = proc(c: bool) =
      inc(toggleCount)
      lastState = c
    )
    let root = Checkbox(tree, SlabId(-1), cb)
    tree.rootId = root
    tree.layoutTree(400.0f, 300.0f, atlas)

    # First toggle: false -> true
    cb.toggle(addr tree)
    doAssert cb.checked
    doAssert toggleCount == 1
    doAssert lastState
    doAssert tree.nodes[cb.boxId].text == "✓"
    doAssert tree.nodes[cb.boxId].bgColor == ColBgActive
    doAssert tree.nodes[cb.boxId].borderColor == ColFocusRing

    # Second toggle: true -> false
    cb.toggle(addr tree)
    doAssert not cb.checked
    doAssert toggleCount == 2
    doAssert not lastState
    doAssert tree.nodes[cb.boxId].text == ""
    doAssert tree.nodes[cb.boxId].bgColor == ColBgRaised
    doAssert tree.nodes[cb.boxId].borderColor == ColBorderCtl

    # setChecked idempotency
    cb.setChecked(false, addr tree)
    doAssert toggleCount == 2 # No callback if state unchanged
    cb.setChecked(true, addr tree)
    doAssert toggleCount == 3
    doAssert cb.checked
    echo "  [PASS] 1.2 Checkbox toggling & onToggle callback verified."

  testWithLeakCheck("1.3 Checkbox Hit-Testing & Click Dispatch"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let cb = newCheckbox("Click Target", checked = false, size = 20.0f)
    let root = Checkbox(tree, SlabId(-1), cb)
    tree.rootId = root
    tree.layoutTree(400.0f, 300.0f, atlas)

    let boxRect = tree.nodes[cb.boxId].computedRect
    let clickX = boxRect.x + boxRect.w * 0.5f
    let clickY = boxRect.y + boxRect.h * 0.5f

    # Simulate mouse down and up inside box
    tree.handleMouseDown(clickX, clickY)
    doAssert tree.pressedNode == cb.boxId
    tree.handleMouseUp(clickX, clickY)
    doAssert cb.checked
    doAssert tree.nodes[cb.boxId].text == "✓"

    # Click again to untoggle
    tree.handleMouseDown(clickX, clickY)
    tree.handleMouseUp(clickX, clickY)
    doAssert not cb.checked
    doAssert tree.nodes[cb.boxId].text == ""

    # Click on label toggles checkbox as well
    let lblRect = tree.nodes[cb.labelId].computedRect
    let lblClickX = lblRect.x + lblRect.w * 0.5f
    let lblClickY = lblRect.y + lblRect.h * 0.5f
    tree.handleMouseDown(lblClickX, lblClickY)
    tree.handleMouseUp(lblClickX, lblClickY)
    doAssert cb.checked

    # Click outside does NOT toggle
    tree.handleMouseDown(350.0f, 250.0f)
    tree.handleMouseUp(350.0f, 250.0f)
    doAssert cb.checked
    echo "  [PASS] 1.3 Checkbox hit-testing & click dispatch verified."

  testWithLeakCheck("1.4 Checkbox Keyboard Accessibility (Space & Return)"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let cb = newCheckbox("Key Focus", checked = false)
    let root = Checkbox(tree, SlabId(-1), cb)
    tree.rootId = root
    tree.layoutTree(400.0f, 300.0f, atlas)

    # Focus boxId
    tree.focusedNode = cb.boxId
    tree.nodes[cb.boxId].isFocused = true

    # Space key toggles
    let handledSpace = handleControlKeyDown(tree, KeySpace)
    doAssert handledSpace
    doAssert cb.checked

    # Return key toggles back
    let handledReturn = handleControlKeyDown(tree, KeyReturn)
    doAssert handledReturn
    doAssert not cb.checked

    # Other keys do not toggle
    let handledTab = handleControlKeyDown(tree, KeyTab)
    doAssert not handledTab
    doAssert not cb.checked
    echo "  [PASS] 1.4 Checkbox keyboard accessibility verified."

  testWithLeakCheck("1.5 Checkbox Reactive Two-Way Signal Binding"):
    resetControls()
    var rt = initReactiveRuntime(testAlloc)
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      rt.destroy()
      resetControls()

    let sig = rt.createSignal(false)
    let cb = newCheckbox("Reactive Checkbox", checked = false)
    discard Checkbox(tree, SlabId(-1), cb)
    discard bindCheckbox(addr tree, addr rt, cb, sig)

    # 1. Signal -> Checkbox
    sig.set(true)
    doAssert cb.checked
    doAssert tree.nodes[cb.boxId].text == "✓"

    sig.set(false)
    doAssert not cb.checked
    doAssert tree.nodes[cb.boxId].text == ""

    # 2. Checkbox -> Signal
    cb.toggle(addr tree)
    doAssert cb.checked
    doAssert sig.get() == true

    cb.toggle(addr tree)
    doAssert not cb.checked
    doAssert sig.get() == false
    echo "  [PASS] 1.5 Checkbox reactive two-way signal binding verified."

  testWithLeakCheck("1.6 Checkbox Disabled State Invariants"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let cb = newCheckbox("Disabled", checked = false)
    cb.disabled = true
    let root = Checkbox(tree, SlabId(-1), cb)
    tree.rootId = root
    tree.layoutTree(400.0f, 300.0f, atlas)

    cb.toggle(addr tree)
    doAssert not cb.checked

    let handled = cb.handleKeyDown(KeySpace, addr tree)
    doAssert not handled
    doAssert not cb.checked
    echo "  [PASS] 1.6 Checkbox disabled state invariants verified."

# =============================================================================
# SUITE 2: RadioButton & RadioGroup Mutual Exclusivity
# =============================================================================

proc testRadioSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 2] RADIOBUTTON & RADIOGROUP EXCLUSIVITY <<<"
  echo "================================================================="

  testWithLeakCheck("2.1 RadioGroup Mutual Exclusivity & State Tracking"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    var selectedIdxHistory: seq[int] = @[]
    var selectedValHistory: seq[string] = @[]

    let (container, group) = RadioGroup(
      tree, SlabId(-1),
      options = ["Low", "Medium", "High", "Ultra"],
      selectedIndex = 0,
      direction = fdColumn,
      gap = 6.0f,
      onSelect = proc(idx: int, val: string) =
        selectedIdxHistory.add(idx)
        selectedValHistory.add(val)
    )
    tree.rootId = container
    tree.layoutTree(400.0f, 400.0f, atlas)

    doAssert group.radios.len == 4
    doAssert group.selectedValue == "Low"
    doAssert group.selectedInt == 0
    doAssert group.radios[0].selected
    doAssert not group.radios[1].selected
    doAssert not group.radios[2].selected
    doAssert not group.radios[3].selected

    # Verify visual node representation
    doAssert tree.nodes[group.radios[0].outerRingId].borderColor == ColFocusRing
    doAssert tree.nodes[group.radios[0].innerCircleId].bgColor == ColTextPrim
    doAssert tree.nodes[group.radios[1].outerRingId].borderColor == ColBorderCtl
    doAssert tree.nodes[group.radios[1].innerCircleId].bgColor == 0'u32

    # Select "High" (index 2)
    group.select(2, addr tree)
    doAssert group.selectedValue == "High"
    doAssert group.selectedInt == 2
    doAssert not group.radios[0].selected
    doAssert not group.radios[1].selected
    doAssert group.radios[2].selected
    doAssert not group.radios[3].selected

    # Verify visuals updated
    doAssert tree.nodes[group.radios[0].outerRingId].borderColor == ColBorderCtl
    doAssert tree.nodes[group.radios[0].innerCircleId].bgColor == 0'u32
    doAssert tree.nodes[group.radios[2].outerRingId].borderColor == ColFocusRing
    doAssert tree.nodes[group.radios[2].innerCircleId].bgColor == ColTextPrim

    # Select "Ultra" by string
    group.select("Ultra", addr tree)
    doAssert group.selectedValue == "Ultra"
    doAssert group.selectedInt == 3
    doAssert group.radios[3].selected
    doAssert not group.radios[2].selected

    # Note: currently RadioGroup invokes both onSelect and onSelectInt closures
    doAssert 2 in selectedIdxHistory
    doAssert 3 in selectedIdxHistory
    doAssert "High" in selectedValHistory
    doAssert "Ultra" in selectedValHistory
    echo "  [PASS] 2.1 RadioGroup mutual exclusivity & state tracking verified."

  testWithLeakCheck("2.2 RadioGroup Keyboard Arrow Navigation (Circular)"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let (container, group) = RadioGroup(
      tree, SlabId(-1),
      options = ["A", "B", "C"],
      selectedIndex = 0
    )
    tree.rootId = container
    tree.layoutTree(400.0f, 300.0f, atlas)

    # Down arrow -> B (1)
    discard group.handleKeyDown(KeyDown, addr tree)
    doAssert group.selectedInt == 1
    doAssert group.selectedValue == "B"

    # Right arrow -> C (2)
    discard group.handleKeyDown(KeyRight, addr tree)
    doAssert group.selectedInt == 2
    doAssert group.selectedValue == "C"

    # Down arrow wraps -> A (0)
    discard group.handleKeyDown(KeyDown, addr tree)
    doAssert group.selectedInt == 0
    doAssert group.selectedValue == "A"

    # Up arrow wraps backwards -> C (2)
    discard group.handleKeyDown(KeyUp, addr tree)
    doAssert group.selectedInt == 2
    doAssert group.selectedValue == "C"

    # Left arrow -> B (1)
    discard group.handleKeyDown(KeyLeft, addr tree)
    doAssert group.selectedInt == 1
    doAssert group.selectedValue == "B"
    echo "  [PASS] 2.2 RadioGroup keyboard arrow navigation verified."

  testWithLeakCheck("2.3 RadioGroup Hit-Testing & Click Dispatch"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let (container, group) = RadioGroup(
      tree, SlabId(-1),
      options = ["Opt0", "Opt1", "Opt2"],
      selectedIndex = 0
    )
    tree.rootId = container
    tree.layoutTree(400.0f, 300.0f, atlas)

    # Click on Opt1 outer ring
    let r1RingRect = tree.nodes[group.radios[1].outerRingId].computedRect
    let clickX = r1RingRect.x + r1RingRect.w * 0.5f
    let clickY = r1RingRect.y + r1RingRect.h * 0.5f

    tree.handleMouseDown(clickX, clickY)
    tree.handleMouseUp(clickX, clickY)
    doAssert group.selectedInt == 1
    doAssert group.selectedValue == "Opt1"
    doAssert group.radios[1].selected
    doAssert not group.radios[0].selected

    # Click on Opt2 label
    let r2LblRect = tree.nodes[group.radios[2].labelId].computedRect
    let lblClickX = r2LblRect.x + r2LblRect.w * 0.5f
    let lblClickY = r2LblRect.y + r2LblRect.h * 0.5f

    tree.handleMouseDown(lblClickX, lblClickY)
    tree.handleMouseUp(lblClickX, lblClickY)
    doAssert group.selectedInt == 2
    doAssert group.selectedValue == "Opt2"
    doAssert group.radios[2].selected
    doAssert not group.radios[1].selected
    echo "  [PASS] 2.3 RadioGroup hit-testing & click dispatch verified."

  testWithLeakCheck("2.4 RadioGroup Reactive Signal Two-Way Binding"):
    resetControls()
    var rt = initReactiveRuntime(testAlloc)
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      rt.destroy()
      resetControls()

    let sig = rt.createSignal("Fast")
    let (container, group) = RadioGroup(
      tree, SlabId(-1),
      options = ["Slow", "Normal", "Fast", "Ludicrous"],
      selectedIndex = 0
    )
    discard bindRadioGroup(addr tree, addr rt, group, sig)

    # 1. Signal -> RadioGroup
    sig.set("Ludicrous")
    doAssert group.selectedValue == "Ludicrous"
    doAssert group.selectedInt == 3
    doAssert group.radios[3].selected

    # 2. RadioGroup -> Signal
    group.select("Slow", addr tree)
    doAssert sig.get() == "Slow"
    echo "  [PASS] 2.4 RadioGroup reactive signal two-way binding verified."

# =============================================================================
# SUITE 3: Slider Clamping, Stepping & Drag Emulation
# =============================================================================

proc testSliderSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 3] SLIDER CLAMPING, STEPPING & DRAG EMULATION <<<"
  echo "================================================================="

  testWithLeakCheck("3.1 Slider Initialization & Clamping Invariants"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    # Min clamped
    let s1 = newSlider(minVal = 10.0f, maxVal = 100.0f, currentVal = 2.0f)
    doAssert approxEq(s1.currentVal, 10.0f)

    # Max clamped
    let s2 = newSlider(minVal = 10.0f, maxVal = 100.0f, currentVal = 150.0f)
    doAssert approxEq(s2.currentVal, 100.0f)

    # setValue out of range clamping
    s1.setValue(-50.0f)
    doAssert approxEq(s1.currentVal, 10.0f)
    s1.setValue(999.0f)
    doAssert approxEq(s1.currentVal, 100.0f)
    s1.setValue(45.5f)
    doAssert approxEq(s1.currentVal, 45.5f)
    echo "  [PASS] 3.1 Slider initialization & clamping invariants verified."

  testWithLeakCheck("3.2 Slider Stepping Quantization"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let s = newSlider(minVal = 0.0f, maxVal = 100.0f, currentVal = 0.0f, step = 10.0f)
    s.setValue(12.0f)
    doAssert approxEq(s.currentVal, 10.0f)

    s.setValue(17.0f)
    doAssert approxEq(s.currentVal, 20.0f)

    s.setValue(96.0f)
    doAssert approxEq(s.currentVal, 100.0f)

    s.setValue(3.0f)
    doAssert approxEq(s.currentVal, 0.0f)
    echo "  [PASS] 3.2 Slider stepping quantization verified."

  testWithLeakCheck("3.3 Slider FlexGrow Weight Calculation"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let s = newSlider(minVal = 0.0f, maxVal = 100.0f, currentVal = 50.0f)
    let root = Slider(tree, SlabId(-1), s, width = fixed(200.0f))
    tree.rootId = root
    tree.layoutTree(400.0f, 300.0f, atlas)

    # At 50%, fill and empty should have ratio 0.5
    s.updateSliderWeights(addr tree)
    let fillMode = tree.nodes[s.trackFillId].widthMode
    let emptyMode = tree.nodes[s.trackEmptyId].widthMode
    doAssert fillMode.kind == smFlexGrow
    doAssert emptyMode.kind == smFlexGrow
    doAssert approxEq(fillMode.val, 0.5f)
    doAssert approxEq(emptyMode.val, 0.5f)

    # At 100%, fill=1.0, empty=0.0001 (eps)
    s.setValue(100.0f, addr tree)
    let fillMode100 = tree.nodes[s.trackFillId].widthMode
    let emptyMode100 = tree.nodes[s.trackEmptyId].widthMode
    doAssert approxEq(fillMode100.val, 1.0f)
    doAssert approxEq(emptyMode100.val, 0.0001f)

    # At 0%, fill=0.0001 (eps), empty=1.0
    s.setValue(0.0f, addr tree)
    let fillMode0 = tree.nodes[s.trackFillId].widthMode
    let emptyMode0 = tree.nodes[s.trackEmptyId].widthMode
    doAssert approxEq(fillMode0.val, 0.0001f)
    doAssert approxEq(emptyMode0.val, 1.0f)
    echo "  [PASS] 3.3 Slider FlexGrow weight calculation verified."

  testWithLeakCheck("3.4 Slider Mouse Drag Emulation & Out-of-Bounds Clamping"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    var changedValues: seq[float32] = @[]
    let s = newSlider(
      minVal = 0.0f,
      maxVal = 100.0f,
      currentVal = 0.0f,
      thumbSize = 16.0f,
      onValueChange = proc(v: float32) = changedValues.add(v)
    )
    let root = Slider(tree, SlabId(-1), s, width = fixed(200.0f))
    tree.rootId = root
    tree.layoutTree(400.0f, 300.0f, atlas)

    let rect = tree.nodes[root].computedRect
    doAssert approxEq(rect.w, 200.0f)

    # 1. Mouse down at center of slider track -> jumps to ~50%
    let centerX = rect.x + rect.w * 0.5f
    let centerY = rect.y + rect.h * 0.5f
    let handledDown = s.handleMouseDown(centerX, centerY, addr tree)
    doAssert handledDown
    doAssert s.isDragging
    doAssert approxEq(s.currentVal, 50.0f, 1.0f)

    # 2. Mouse move dragging thumb to 75%
    let drag75X = rect.x + rect.w * 0.75f
    let handledMove = s.handleMouseMove(drag75X, centerY, addr tree)
    doAssert handledMove
    doAssert s.currentVal > 70.0f and s.currentVal < 80.0f

    # 3. Drag far beyond right edge -> clamped to maxVal (100.0)
    discard s.handleMouseMove(rect.x + rect.w + 500.0f, centerY, addr tree)
    doAssert approxEq(s.currentVal, 100.0f)

    # 4. Drag far beyond left edge -> clamped to minVal (0.0)
    discard s.handleMouseMove(rect.x - 500.0f, centerY, addr tree)
    doAssert approxEq(s.currentVal, 0.0f)

    # 5. Mouse up ends drag
    let handledUp = s.handleMouseUp(centerX, centerY)
    doAssert handledUp
    doAssert not s.isDragging

    # 6. Mouse move after mouse up does NOT change value
    let valBefore = s.currentVal
    discard s.handleMouseMove(centerX, centerY, addr tree)
    doAssert approxEq(s.currentVal, valBefore)
    doAssert changedValues.len > 0
    echo "  [PASS] 3.4 Slider mouse drag emulation & out-of-bounds clamping verified."

  testWithLeakCheck("3.5 Slider Keyboard Step Navigation"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let s = newSlider(minVal = 0.0f, maxVal = 100.0f, currentVal = 50.0f, step = 5.0f)
    discard Slider(tree, SlabId(-1), s, width = fixed(200.0f))

    # Right arrow increments
    discard s.handleKeyDown(KeyRight, addr tree)
    doAssert approxEq(s.currentVal, 55.0f)

    # Up arrow increments
    discard s.handleKeyDown(KeyUp, addr tree)
    doAssert approxEq(s.currentVal, 60.0f)

    # Left arrow decrements
    discard s.handleKeyDown(KeyLeft, addr tree)
    doAssert approxEq(s.currentVal, 55.0f)

    # Down arrow decrements
    discard s.handleKeyDown(KeyDown, addr tree)
    doAssert approxEq(s.currentVal, 50.0f)
    echo "  [PASS] 3.5 Slider keyboard step navigation verified."

  testWithLeakCheck("3.6 Slider Reactive Signal Two-Way Binding"):
    resetControls()
    var rt = initReactiveRuntime(testAlloc)
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      rt.destroy()
      resetControls()

    let sig = rt.createSignal(25.0f)
    let s = newSlider(minVal = 0.0f, maxVal = 100.0f, currentVal = 0.0f)
    discard Slider(tree, SlabId(-1), s)
    discard bindSlider(addr tree, addr rt, s, sig)

    # Signal -> Slider
    sig.set(80.0f)
    doAssert approxEq(s.currentVal, 80.0f)

    # Slider -> Signal
    s.setValue(33.0f, addr tree)
    doAssert approxEq(sig.get(), 33.0f)
    echo "  [PASS] 3.6 Slider reactive signal two-way binding verified."

# =============================================================================
# SUITE 4: Dropdown Opening, Selection & Outside Clicks
# =============================================================================

proc testDropdownSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 4] DROPDOWN OPENING, SELECTION & OUTSIDE CLICKS <<<"
  echo "================================================================="

  testWithLeakCheck("4.1 Dropdown Initialization & Closed State"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let dd = newDropdown(@["Vulkan 1.3", "DirectX 12", "Metal", "WebGPU"], selectedIndex = 0)
    let header = Dropdown(tree, SlabId(-1), dd, width = fixed(180.0f), height = fixed(36.0f))
    tree.rootId = header
    tree.layoutTree(400.0f, 300.0f, atlas)

    doAssert not dd.isOpen
    doAssert dd.selectedIndex == 0
    doAssert tree.nodes[dd.textId].text == "Vulkan 1.3"
    doAssert tree.nodes[dd.arrowId].text == "▼"
    doAssert tree.nodes[dd.headerId].borderColor == ColBorderCtl
    echo "  [PASS] 4.1 Dropdown initialization & closed state verified."

  testWithLeakCheck("4.2 Dropdown Open, Toggle & Chevron Transitions"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let dd = newDropdown(@["A", "B", "C"], selectedIndex = 0)
    let header = Dropdown(tree, SlabId(-1), dd)
    tree.rootId = header
    tree.layoutTree(400.0f, 300.0f, atlas)

    dd.open(addr tree)
    doAssert dd.isOpen
    doAssert tree.nodes[dd.arrowId].text == "▲"
    doAssert tree.nodes[dd.headerId].borderColor == ColFocusRing

    dd.close(addr tree)
    doAssert not dd.isOpen
    doAssert tree.nodes[dd.arrowId].text == "▼"
    doAssert tree.nodes[dd.headerId].borderColor == ColBorderCtl

    dd.toggle(addr tree)
    doAssert dd.isOpen
    dd.toggle(addr tree)
    doAssert not dd.isOpen
    echo "  [PASS] 4.2 Dropdown open, toggle & chevron transitions verified."

  testWithLeakCheck("4.3 Dropdown Option Selection via Mouse Click"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    var selectedHistory: seq[int] = @[]
    let dd = newDropdown(
      @["First", "Second", "Third", "Fourth"],
      selectedIndex = 0,
      itemHeight = 30.0f,
      onSelect = proc(idx: int) = selectedHistory.add(idx)
    )
    let header = Dropdown(tree, SlabId(-1), dd, width = fixed(180.0f), height = fixed(36.0f))
    tree.rootId = header
    tree.layoutTree(400.0f, 400.0f, atlas)

    let hRect = tree.nodes[header].computedRect

    # 1. Click header to open
    let handledHeader = dd.handleMouseDown(hRect.x + 10.0f, hRect.y + 10.0f, addr tree)
    doAssert handledHeader
    doAssert dd.isOpen

    # 2. Click on "Third" option (index 2)
    let (popX, popY, popW, popH) = dd.getPopupRect(addr tree)
    let opt2Y = popY + 4.0f + 2.0f * dd.itemHeight + dd.itemHeight * 0.5f
    let opt2X = popX + popW * 0.5f

    let handledOpt = dd.handleMouseDown(opt2X, opt2Y, addr tree)
    doAssert handledOpt
    doAssert not dd.isOpen # Closed after select
    doAssert dd.selectedIndex == 2
    doAssert tree.nodes[dd.textId].text == "Third"
    doAssert selectedHistory == @[2]
    echo "  [PASS] 4.3 Dropdown option selection via mouse click verified."

  testWithLeakCheck("4.4 Dropdown Outside Click Closing"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let dd = newDropdown(@["X", "Y", "Z"], selectedIndex = 0)
    let header = Dropdown(tree, SlabId(-1), dd, width = fixed(150.0f), height = fixed(32.0f))
    tree.rootId = header
    tree.layoutTree(400.0f, 400.0f, atlas)

    dd.open(addr tree)
    doAssert dd.isOpen

    # Click far away in bottom right corner (350, 350)
    let handledOutside = dd.handleMouseDown(350.0f, 350.0f, addr tree)
    doAssert handledOutside
    doAssert not dd.isOpen
    doAssert dd.selectedIndex == 0 # Selection preserved
    echo "  [PASS] 4.4 Dropdown outside click closing verified."

  testWithLeakCheck("4.5 Dropdown Keyboard Navigation (Arrow Keys, Space, Escape)"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let dd = newDropdown(@["Apple", "Banana", "Cherry"], selectedIndex = 0)
    let header = Dropdown(tree, SlabId(-1), dd)
    tree.rootId = header
    tree.layoutTree(400.0f, 300.0f, atlas)

    # 1. Closed -> Space opens
    discard dd.handleKeyDown(KeySpace, addr tree)
    doAssert dd.isOpen

    # 2. Down arrow moves hover
    discard dd.handleKeyDown(KeyDown, addr tree)
    doAssert dd.hoveredIndex == 1 # Banana

    # 3. Down arrow moves hover to Cherry
    discard dd.handleKeyDown(KeyDown, addr tree)
    doAssert dd.hoveredIndex == 2 # Cherry

    # 4. Return commits selection and closes
    discard dd.handleKeyDown(KeyReturn, addr tree)
    doAssert not dd.isOpen
    doAssert dd.selectedIndex == 2
    doAssert tree.nodes[dd.textId].text == "Cherry"

    # 5. Open and press Escape -> closes without change
    discard dd.handleKeyDown(KeySpace, addr tree)
    doAssert dd.isOpen
    discard dd.handleKeyDown(KeyUp, addr tree) # hover on Banana
    discard dd.handleKeyDown(KeyEscape, addr tree)
    doAssert not dd.isOpen
    doAssert dd.selectedIndex == 2 # Kept Cherry
    echo "  [PASS] 4.5 Dropdown keyboard navigation verified."

  testWithLeakCheck("4.6 Dropdown Overlay Rendering Instances"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let dd = newDropdown(@["Item A", "Item B"], selectedIndex = 0)
    let header = Dropdown(tree, SlabId(-1), dd, width = fixed(180.0f), height = fixed(36.0f))
    tree.rootId = header
    tree.layoutTree(400.0f, 300.0f, atlas)

    dd.open(addr tree)
    dd.hoveredIndex = 1

    var instances = newSeq[UiDrawInstance]()
    dd.renderOverlay(instances, atlas, addr tree)

    # Must contain background card quad + item highlight quad + text runs
    doAssert instances.len >= 3
    doAssert instances[0].color == ColBgSurface
    doAssert instances[0].borderColor == ColBorderCtl
    echo "  [PASS] 4.6 Dropdown overlay rendering instances verified."

  testWithLeakCheck("4.7 Dropdown Reactive Two-Way Signal Binding"):
    resetControls()
    var rt = initReactiveRuntime(testAlloc)
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      rt.destroy()
      resetControls()

    let sig = rt.createSignal(0)
    let dd = newDropdown(@["Red", "Green", "Blue"], selectedIndex = 0)
    discard Dropdown(tree, SlabId(-1), dd)
    discard bindDropdown(addr tree, addr rt, dd, sig)

    # Signal -> Dropdown
    sig.set(2)
    doAssert dd.selectedIndex == 2
    doAssert tree.nodes[dd.textId].text == "Blue"

    # Dropdown -> Signal
    dd.select(1, addr tree)
    doAssert sig.get() == 1
    echo "  [PASS] 4.7 Dropdown reactive two-way signal binding verified."

# =============================================================================
# SUITE 5: Tooltip Hover Trigger & Geometry Bounds
# =============================================================================

proc testTooltipSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 5] TOOLTIP HOVER TRIGGER & GEOMETRY BOUNDS <<<"
  echo "================================================================="

  testWithLeakCheck("5.1 Tooltip Hover Trigger & Visibility Invariants"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let btn = Button(tree, SlabId(-1), label = "Action Target", size = 14.0f)
    tree.rootId = btn
    tree.nodes[btn].widthMode = fixed(120.0f)
    tree.nodes[btn].heightMode = fixed(40.0f)
    let tt = Tooltip(tree, btn, "Helpful explanatory text", tpAuto)

    tree.layoutTree(800.0f, 600.0f, atlas)

    # Initially not hovered -> not visible
    tt.update(tree, atlas, 800.0f, 600.0f)
    doAssert not tt.visible

    # Hover target node
    tree.nodes[btn].isHovered = true
    tt.update(tree, atlas, 800.0f, 600.0f)
    doAssert tt.visible
    doAssert tt.computedRect.w > 0.0f
    doAssert tt.computedRect.h > 0.0f

    # Unhover target node
    tree.nodes[btn].isHovered = false
    tt.update(tree, atlas, 800.0f, 600.0f)
    doAssert not tt.visible
    echo "  [PASS] 5.1 Tooltip hover trigger & visibility invariants verified."

  testWithLeakCheck("5.2 Tooltip Geometry Placement (Above vs Below)"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    # Target placed at y=200 (plenty of room above)
    let container = Box(tree, SlabId(-1), width = fixed(800.0f), height = fixed(600.0f), padding = 200.0f)
    tree.rootId = container
    let btn = Button(tree, container, label = "Target", size = 14.0f)
    tree.nodes[btn].widthMode = fixed(100.0f)
    tree.nodes[btn].heightMode = fixed(40.0f)

    let ttAbove = newTooltip(btn, "Above tooltip", tpAbove)
    let ttBelow = newTooltip(btn, "Below tooltip", tpBelow)

    tree.layoutTree(800.0f, 600.0f, atlas)
    tree.nodes[btn].isHovered = true

    ttAbove.update(tree, atlas, 800.0f, 600.0f)
    ttBelow.update(tree, atlas, 800.0f, 600.0f)

    let targetY = tree.nodes[btn].computedRect.y
    let targetH = tree.nodes[btn].computedRect.h

    # tpAbove: cy < targetY
    doAssert ttAbove.computedRect.y < targetY
    # tpBelow: cy >= targetY + targetH
    doAssert ttBelow.computedRect.y >= targetY + targetH
    echo "  [PASS] 5.2 Tooltip geometry placement (above vs below) verified."

  testWithLeakCheck("5.3 Tooltip Screen Edge Clamping"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    # Target placed at far right edge (x=780 on an 800px screen)
    let container = Box(tree, SlabId(-1), width = fixed(800.0f), height = fixed(600.0f))
    tree.rootId = container
    let btnRight = Button(tree, container, label = "Far Right", size = 14.0f)
    tree.nodes[btnRight].computedRect = (780.0f, 100.0f, 80.0f, 30.0f)
    tree.nodes[btnRight].isHovered = true

    let tt = newTooltip(btnRight, "A relatively wide tooltip message text", tpBelow)
    tt.update(tree, atlas, screenW = 800.0f, screenH = 600.0f)

    # Tooltip right edge must not exceed screenW - 4.0f
    doAssert tt.computedRect.x + tt.computedRect.w <= 800.0f
    doAssert tt.computedRect.x >= 4.0f
    echo "  [PASS] 5.3 Tooltip screen edge clamping verified."

  testWithLeakCheck("5.4 Tooltip Overlay Rendering Instances"):
    resetControls()
    var tree = initUiTree(testAlloc)
    defer:
      tree.destroy()
      resetControls()

    let btn = Button(tree, SlabId(-1), label = "Target", size = 14.0f)
    tree.rootId = btn
    tree.layoutTree(400.0f, 300.0f, atlas)
    tree.nodes[btn].isHovered = true

    let tt = newTooltip(btn, "Tooltip message", tpBelow)
    tt.update(tree, atlas, 400.0f, 300.0f)

    var instances = newSeq[UiDrawInstance]()
    tt.renderOverlay(instances, atlas)

    doAssert instances.len >= 2 # card + text runes
    doAssert instances[0].color == ColBgSurface
    echo "  [PASS] 5.4 Tooltip overlay rendering instances verified."

# =============================================================================
# SUITE 6: System & Headless Clipboard Round-Trip
# =============================================================================

proc testClipboardSuite() =
  echo "\n================================================================="
  echo ">>> [SUITE 6] CLIPBOARD ENCODING & HEADLESS / SYSTEM ROUNDTRIP <<<"
  echo "================================================================="

  testWithLeakCheck("6.1 UTF-8 <-> UTF-16 Conversion Fidelity"):
    let testStrings = [
      "",
      "Hello, NimUI!",
      "Obsidian & Monochrome Tokens 2026",
      "Привет, мир! Высокопроизводительный UI",
      "日本語テスト - 高速レンダリング",
      "Surrogate Pairs: 🚀⚡✨🔥🎨",
      "Multiline:\nLine 1\r\nLine 2\tTabbed\nLine 3"
    ]

    for s in testStrings:
      let u16 = utf8ToUtf16(s)
      doAssert u16.len > 0
      doAssert u16[^1] == 0'u16 # Null-terminated
      let back = utf16ToUtf8(cast[ptr UncheckedArray[uint16]](unsafeAddr u16[0]))
      doAssert back == s, &"UTF-16 roundtrip mismatch for '{s}': got '{back}'"
    echo "  [PASS] 6.1 UTF-8 <-> UTF-16 conversion fidelity verified."

  testWithLeakCheck("6.2 In-Memory Fallback Buffer Roundtrip"):
    setClipboardForceFallback(true)
    defer: setClipboardForceFallback(false)

    clearClipboardFallback()
    doAssert getClipboardText() == ""

    let testPayload = "Headless NimUI In-Memory Fallback String ⚡"
    let ok = setClipboardText(testPayload)
    doAssert ok
    doAssert getClipboardText() == testPayload
    doAssert getClipboardFallback() == testPayload

    clearClipboard()
    doAssert getClipboardText() == ""
    echo "  [PASS] 6.2 In-memory fallback buffer roundtrip verified."

  testWithLeakCheck("6.3 System Clipboard Roundtrip (Windows Native or Fallback)"):
    setClipboardForceFallback(false)
    let payload = "NimUI Win32 Native Clipboard Verification 🚀"
    let ok = setClipboardText(payload)
    doAssert ok
    let readBack = getClipboardText()
    doAssert readBack == payload, &"Expected '{payload}', got '{readBack}'"
    clearClipboard()
    echo "  [PASS] 6.3 System clipboard roundtrip verified."

# =============================================================================
# SUITE 7: Multiline Text Word-Wrapping & Line Break Engine
# =============================================================================

proc testMultilineSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 7] MULTILINE TEXT WORD-WRAPPING & LINE BREAK ENGINE <<<"
  echo "================================================================="

  testWithLeakCheck("7.1 Explicit Line Delimiter Splitting (LF & CRLF)"):
    doAssert splitLogicalLines("") == @[""]
    doAssert splitLogicalLines("SingleLine") == @["SingleLine"]
    doAssert splitLogicalLines("Line 1\nLine 2\nLine 3") == @["Line 1", "Line 2", "Line 3"]
    doAssert splitLogicalLines("Win 1\r\nWin 2\r\nWin 3") == @["Win 1", "Win 2", "Win 3"]
    doAssert splitLogicalLines("Mixed 1\r\nMixed 2\nMixed 3") == @["Mixed 1", "Mixed 2", "Mixed 3"]
    doAssert splitLogicalLines("Empty\n\nDouble\n") == @["Empty", "", "Double", ""]
    echo "  [PASS] 7.1 Explicit line delimiter splitting verified."

  testWithLeakCheck("7.2 Word-Wrapping at Boundary Whitespace"):
    let text = "The quick brown fox jumps over the lazy dog."
    let wrapped = wrapTextToLines(text, maxWidth = 120.0f, atlas = atlas, fontSize = 14.0f)

    doAssert wrapped.len >= 2
    for line in wrapped:
      let w = atlas.measureText(line, 14.0f).width
      doAssert w <= 120.0f, &"Line '{line}' width {w} exceeded maxWidth 120.0"

    # Reconstituted words should match original words
    let joined = wrapped.join(" ")
    doAssert "quick" in joined and "brown" in joined and "fox" in joined
    echo "  [PASS] 7.2 Word-wrapping at boundary whitespace verified."

  testWithLeakCheck("7.3 Oversized Single Word Rune Splitting"):
    let superWord = "Supercalifragilisticexpialidocious_ExtraordinarilyLongWordWithoutSpaces"
    let wrapped = wrapTextToLines(superWord, maxWidth = 80.0f, atlas = atlas, fontSize = 14.0f)

    doAssert wrapped.len >= 3
    for line in wrapped:
      let w = atlas.measureText(line, 14.0f).width
      doAssert w <= 80.0f, &"Chunk '{line}' width {w} exceeded maxWidth 80.0"

    # Total characters should match
    var totalChars = 0
    for line in wrapped:
      totalChars += line.len
    doAssert totalChars == superWord.len
    echo "  [PASS] 7.3 Oversized single word rune splitting verified."

  testWithLeakCheck("7.4 Multiline Text Measurement & Bounding Box"):
    let code = "proc main() =\n  let x = 42\n  echo x"
    let metrics = measureMultilineText(code, maxWidth = 400.0f, atlas = atlas, fontSize = 16.0f)

    doAssert metrics.lineCount == 3
    doAssert metrics.lines == @["proc main() =", "  let x = 42", "  echo x"]
    doAssert metrics.width > 0.0f
    doAssert metrics.height >= 3.0f * metrics.lineHeight
    doAssert metrics.lineWidths.len == 3
    echo "  [PASS] 7.4 Multiline text measurement & bounding box verified."

  testWithLeakCheck("7.5 Linear Index <-> (Row, Col) Mapping Invariants"):
    let lines = @["Hello", "World", "NimUI!"]
    # Line 0: "Hello" (len 5), \n -> index 0..5
    # Line 1: "World" (len 5), \n -> index 6..11
    # Line 2: "NimUI!" (len 6)    -> index 12..17

    doAssert posToLinear(lines, 0, 0) == 0
    doAssert posToLinear(lines, 0, 5) == 5
    doAssert posToLinear(lines, 1, 0) == 6
    doAssert posToLinear(lines, 1, 5) == 11
    doAssert posToLinear(lines, 2, 0) == 12
    doAssert posToLinear(lines, 2, 6) == 18

    # Roundtrip check across all points
    for r in 0 ..< lines.len:
      for c in 0 .. runeLen(lines[r]):
        let linear = posToLinear(lines, r, c)
        let (backR, backC) = linearToPos(lines, linear)
        doAssert backR == r and backC == c, &"Mismatch at ({r}, {c}): linear={linear}, back=({backR}, {backC})"
    echo "  [PASS] 7.5 Linear index <-> (Row, Col) mapping invariants verified."

# =============================================================================
# SUITE 8: TextArea Editing, Selection, Navigation & Clipboard
# =============================================================================

proc testTextAreaSuite(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 8] TEXTAREA EDITING, SELECTION & CLIPBOARD <<<"
  echo "================================================================="

  testWithLeakCheck("8.1 TextArea Initialization & Typing"):
    var ta = initTextArea("Initial text")
    doAssert ta.getText() == "Initial text"
    doAssert ta.lines == @["Initial text"]
    doAssert ta.caretRow == 0
    doAssert ta.caretCol == 0
    doAssert not ta.hasSelection()

    # Move to end and type
    ta.moveEnd()
    ta.insertText(" added")
    doAssert ta.getText() == "Initial text added"
    doAssert ta.caretCol == runeLen("Initial text added")

    # Insert newline
    ta.insertText("\nSecond line")
    doAssert ta.lines.len == 2
    doAssert ta.caretRow == 1
    doAssert ta.lines[1] == "Second line"
    echo "  [PASS] 8.1 TextArea initialization & typing verified."

  testWithLeakCheck("8.2 TextArea Backspace & Delete Across Lines"):
    var ta = initTextArea("First\nSecond")
    ta.setCaret(1, 0) # Caret at start of "Second"

    # Backspace at start of line 1 merges lines
    ta.deleteBackward()
    doAssert ta.lines.len == 1
    doAssert ta.getText() == "FirstSecond"
    doAssert ta.caretRow == 0
    doAssert ta.caretCol == 5

    # Delete in middle of line (at index 5, which is 'S')
    ta.deleteForward() # deletes 'S'
    doAssert ta.getText() == "Firstecond"
    echo "  [PASS] 8.2 TextArea backspace & delete across lines verified."

  testWithLeakCheck("8.3 TextArea Navigation (Arrows, Home, End)"):
    var ta = initTextArea("Row0 ABC\nRow1 DEF\nRow2 GHI")
    ta.setCaret(0, 0)

    # Move right 4 times
    for _ in 1 .. 4: ta.moveRight()
    doAssert ta.caretRow == 0 and ta.caretCol == 4

    # Move down
    ta.moveDown()
    doAssert ta.caretRow == 1 and ta.caretCol == 4

    # Move Home
    ta.moveHome()
    doAssert ta.caretRow == 1 and ta.caretCol == 0

    # Move End
    ta.moveEnd()
    doAssert ta.caretRow == 1 and ta.caretCol == 8

    # Move Up
    ta.moveUp()
    doAssert ta.caretRow == 0 and ta.caretCol == 8
    echo "  [PASS] 8.3 TextArea navigation verified."

  testWithLeakCheck("8.4 TextArea Selection Range & Replacement"):
    var ta = initTextArea("The quick brown fox")
    # Select "quick " (index 4..10)
    ta.setSelection(4, 10)
    doAssert ta.hasSelection()
    doAssert ta.getSelectedText() == "quick "

    # Typing replaces selection
    ta.insertText("slow ")
    doAssert ta.getText() == "The slow brown fox"
    doAssert not ta.hasSelection()

    # Select all and delete
    ta.selectAll()
    doAssert ta.getSelectedText() == "The slow brown fox"
    ta.deleteSelection()
    doAssert ta.getText() == ""
    doAssert ta.lines == @[""]
    echo "  [PASS] 8.4 TextArea selection range & replacement verified."

  testWithLeakCheck("8.5 TextArea Clipboard Shortcuts (Ctrl+A, Ctrl+C, Ctrl+V, Ctrl+X)"):
    setClipboardForceFallback(true)
    defer: setClipboardForceFallback(false)
    clearClipboardFallback()

    var ta = initTextArea("Line Alpha\nLine Beta")
    ta.isFocused = true

    # 1. Ctrl+A (Select All)
    ta.handleKeyDown(0x41'u32, ctrlDown = true) # 'A'
    doAssert ta.hasSelection()
    doAssert ta.getSelectedText() == "Line Alpha\nLine Beta"

    # 2. Ctrl+C (Copy)
    ta.handleKeyDown(0x43'u32, ctrlDown = true) # 'C'
    doAssert getClipboardText() == "Line Alpha\nLine Beta"

    # 3. Deselect and paste
    ta.clearSelection()
    ta.setText("")
    doAssert ta.getText() == ""

    # 4. Ctrl+V (Paste)
    ta.handleKeyDown(0x56'u32, ctrlDown = true) # 'V'
    doAssert ta.getText() == "Line Alpha\nLine Beta"

    # 5. Select "Beta" and Ctrl+X (Cut)
    ta.setSelection(16, 20)
    doAssert ta.getSelectedText() == "Beta"
    ta.handleKeyDown(0x58'u32, ctrlDown = true) # 'X'
    doAssert getClipboardText() == "Beta"
    doAssert ta.getText() == "Line Alpha\nLine "
    echo "  [PASS] 8.5 TextArea clipboard shortcuts verified."

  testWithLeakCheck("8.6 TextArea Mouse Drag Selection Emulation"):
    var ta = initTextArea(
      "Line One of text\nLine Two of text",
      fontSize = 14.0f,
      bounds = (0.0f, 0.0f, 300.0f, 150.0f)
    )

    # Mouse down at (20, 15) -> inside Line One
    ta.handleMouseDown(20.0f, 15.0f, atlas)
    doAssert ta.isFocused
    doAssert ta.isDragging

    # Drag down to Line Two at (80, 45)
    ta.handleMouseMove(80.0f, 45.0f, atlas)
    doAssert ta.hasSelection()
    doAssert ta.caretRow == 1

    # Mouse up finishes drag
    ta.handleMouseUp(80.0f, 45.0f)
    doAssert not ta.isDragging
    doAssert ta.hasSelection()
    echo "  [PASS] 8.6 TextArea mouse drag selection emulation verified."

  testWithLeakCheck("8.7 TextArea Draw Instances & Selection Highlight Emission"):
    var ta = initTextArea(
      "Sample line 1\nSample line 2",
      fontSize = 14.0f,
      bounds = (10.0f, 10.0f, 250.0f, 100.0f)
    )
    ta.isFocused = true
    ta.setSelection(2, 10) # Highlights across line 1

    var instances = newSeq[UiDrawInstance]()
    ta.emitDrawInstances(instances, atlas)

    # Must contain background, selection quad, text glyphs, and caret quad
    doAssert instances.len >= 4
    # Find selection highlight quad (borderWidth == 0.0f, cornerRadius == 2.0f)
    var foundSelQuad = false
    var foundCaretQuad = false
    for inst in instances:
      if inst.cornerRadius == 2.0f and inst.borderWidth == 0.0f and inst.color == ta.selectionColor:
        foundSelQuad = true
      if inst.cornerRadius == 0.5f and inst.color == ta.caretColor:
        foundCaretQuad = true

    doAssert foundSelQuad, "Selection highlight quad was not emitted"
    doAssert foundCaretQuad, "Caret quad was not emitted"
    echo "  [PASS] 8.7 TextArea draw instances & selection highlight emission verified."

# =============================================================================
# SUITE 9: Strict Zero-Leak Audits (1,000 Cycles)
# =============================================================================

proc testZeroLeakAudits(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 9] STRICT 1,000-CYCLE LIFECYCLE & ZERO-LEAK AUDITS <<<"
  echo "================================================================="

  testWithLeakCheck("9.1 1,000-Cycle Checkbox Lifecycle Audit"):
    for cycle in 0 ..< 1000:
      resetControls()
      var tree = initUiTree(testAlloc)
      let cb = newCheckbox("Cycle CB " & $cycle, checked = (cycle mod 2 == 0))
      let root = Checkbox(tree, SlabId(-1), cb)
      tree.rootId = root
      tree.layoutTree(300.0f, 100.0f, atlas)
      cb.toggle(addr tree)
      cb.toggle(addr tree)
      tree.destroy()
      resetControls()
    echo "  [PASS] 9.1 1,000 Checkbox lifecycles passed with 0 leaks."

  testWithLeakCheck("9.2 1,000-Cycle RadioGroup Lifecycle Audit"):
    for cycle in 0 ..< 1000:
      resetControls()
      var tree = initUiTree(testAlloc)
      let (container, group) = RadioGroup(
        tree, SlabId(-1),
        options = ["Low", "Medium", "High"],
        selectedIndex = cycle mod 3
      )
      tree.rootId = container
      tree.layoutTree(300.0f, 200.0f, atlas)
      group.select((cycle + 1) mod 3, addr tree)
      tree.destroy()
      resetControls()
    echo "  [PASS] 9.2 1,000 RadioGroup lifecycles passed with 0 leaks."

  testWithLeakCheck("9.3 1,000-Cycle Slider Lifecycle Audit"):
    for cycle in 0 ..< 1000:
      resetControls()
      var tree = initUiTree(testAlloc)
      let s = newSlider(minVal = 0.0f, maxVal = 100.0f, currentVal = float32(cycle mod 100), step = 5.0f)
      let root = Slider(tree, SlabId(-1), s, width = fixed(200.0f))
      tree.rootId = root
      tree.layoutTree(300.0f, 100.0f, atlas)
      s.setValue(float32((cycle * 7) mod 100), addr tree)
      tree.destroy()
      resetControls()
    echo "  [PASS] 9.3 1,000 Slider lifecycles passed with 0 leaks."

  testWithLeakCheck("9.4 1,000-Cycle Dropdown Lifecycle & Overlay Audit"):
    for cycle in 0 ..< 1000:
      resetControls()
      var tree = initUiTree(testAlloc)
      let dd = newDropdown(@["Item 0", "Item 1", "Item 2"], selectedIndex = 0)
      let root = Dropdown(tree, SlabId(-1), dd, width = fixed(180.0f), height = fixed(36.0f))
      tree.rootId = root
      tree.layoutTree(300.0f, 200.0f, atlas)
      dd.open(addr tree)
      dd.select(cycle mod 3, addr tree)
      dd.close(addr tree)
      tree.destroy()
      resetControls()
    echo "  [PASS] 9.4 1,000 Dropdown lifecycles passed with 0 leaks."

  testWithLeakCheck("9.5 1,000-Cycle Tooltip Lifecycle & Overlay Audit"):
    for cycle in 0 ..< 1000:
      resetControls()
      var tree = initUiTree(testAlloc)
      let btn = Button(tree, SlabId(-1), label = "Btn", size = 14.0f)
      tree.rootId = btn
      let tt = Tooltip(tree, btn, "Tooltip " & $cycle, tpAuto)
      tree.layoutTree(300.0f, 100.0f, atlas)
      tree.nodes[btn].isHovered = (cycle mod 2 == 0)
      tt.update(tree, atlas, 300.0f, 100.0f)
      tree.destroy()
      resetControls()
    echo "  [PASS] 9.5 1,000 Tooltip lifecycles passed with 0 leaks."

  testWithLeakCheck("9.6 1,000-Cycle Clipboard Roundtrip Audit"):
    setClipboardForceFallback(true)
    defer: setClipboardForceFallback(false)
    for cycle in 0 ..< 1000:
      let txt = "Test Payload Iteration " & $cycle & " ⚡"
      discard setClipboardText(txt)
      let res = getClipboardText()
      doAssert res == txt
      clearClipboard()
    echo "  [PASS] 9.6 1,000 Clipboard roundtrips passed with 0 leaks."

  testWithLeakCheck("9.7 1,000-Cycle TextArea Editing & Draw Emission Audit"):
    for cycle in 0 ..< 1000:
      var ta = initTextArea("Initial text for cycle " & $cycle)
      ta.isFocused = true
      ta.insertText(" + more")
      ta.setSelection(2, 8)
      ta.deleteSelection()
      ta.insertText("rep")
      var instances = newSeq[UiDrawInstance]()
      ta.emitDrawInstances(instances, atlas)
      doAssert instances.len > 0
    echo "  [PASS] 9.7 1,000 TextArea lifecycles passed with 0 leaks."

  testWithLeakCheck("9.8 1,000-Cycle Full Integrated UI Tree Audit"):
    for cycle in 0 ..< 1000:
      resetControls()
      var rt = initReactiveRuntime(testAlloc)
      var tree = initUiTree(testAlloc)

      let sigBool = rt.createSignal(cycle mod 2 == 0)
      let sigVal = rt.createSignal(float32(cycle mod 100))

      let root = VStack(tree, SlabId(-1), width = fixed(600.0f), height = fixed(800.0f), gap = 10.0f)
      tree.rootId = root

      # Checkbox
      let cb = newCheckbox("Integrated CB", checked = false)
      discard Checkbox(tree, root, cb)
      discard bindCheckbox(addr tree, addr rt, cb, sigBool)

      # RadioGroup
      let (rgContainer, rg) = RadioGroup(tree, root, ["Mode A", "Mode B", "Mode C"], selectedIndex = 0)

      # Slider
      let s = newSlider(0.0f, 100.0f, 0.0f)
      discard Slider(tree, root, s)
      discard bindSlider(addr tree, addr rt, s, sigVal)

      # Dropdown
      let dd = newDropdown(@["Option 1", "Option 2"], selectedIndex = 0)
      discard Dropdown(tree, root, dd)

      # Tooltip
      discard Tooltip(tree, rgContainer, "Radio Options Tooltip", tpBelow)

      # TextArea
      discard TextAreaNode(tree, root, "Integrated multiline notes")

      tree.layoutTree(800.0f, 600.0f, atlas)

      # Simulate interactive updates
      sigBool.set(not sigBool.get())
      sigVal.set(float32((cycle * 3) mod 100))
      rg.select(cycle mod 3, addr tree)

      discard tree.buildDrawInstances(atlas)
      renderControlOverlays(tree, atlas, 800.0f, 600.0f)

      tree.destroy()
      rt.destroy()
      resetControls()
    echo "  [PASS] 9.8 1,000 Full integrated UI trees passed with 0 leaks."

# =============================================================================
# Main Entry Point
# =============================================================================

proc main() =
  echo "================================================================="
  echo ">>> STARTING COMPREHENSIVE NIMUI WIDGETS & CONTROLS SUITE <<<"
  echo "================================================================="

  let atlas = initFontAtlas("Segoe UI", 16.0f)
  doAssert atlas.width in [512, 1024] and atlas.height in [512, 1024]

  testCheckboxSuite(atlas)
  testRadioSuite(atlas)
  testSliderSuite(atlas)
  testDropdownSuite(atlas)
  testTooltipSuite(atlas)
  testClipboardSuite()
  testMultilineSuite(atlas)
  testTextAreaSuite(atlas)
  testZeroLeakAudits(atlas)

  echo "\n================================================================="
  echo ">>> [SUCCESS] ALL NIMUI WIDGETS TESTS PASSED WITH 0 LEAKS! <<<"
  echo "================================================================="

when isMainModule:
  main()
