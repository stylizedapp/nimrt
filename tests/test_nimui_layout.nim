## tests/test_nimui_layout.nim — Comprehensive Headless Tests for nimui/layout & nimui/dsl
##
## Strict invariants:
## 1. Flexbox layout geometry (Row/Column, Fixed, FlexGrow, FitContent, padding, gap, alignment).
## 2. Hit-testing in Z-order with hover, pressed, and focused state transitions.
## 3. VirtualList scrolling and visible index calculations for up to 1,000,000 items.
## 4. Reactive bindings with corex/signals: updating Signal[T] mutates node state and triggers isDirty/isLayoutDirty.
## 5. Strict zero-leak audit with testWithLeakCheck on all tests.
##
## Compilation: nim c -r tests/test_nimui_layout.nim under --mm:orc --threads:on --panics:on

import std/[unicode, strformat, monotimes, times]
import corex
import nimui/layout
import nimui/dsl
import nimui/gpu/font_atlas
import nimui/gpu/vulkan_backend

proc approxEq(a, b: float32, eps: float32 = 0.01f): bool {.inline, raises: [].} =
  abs(a - b) <= eps

# =============================================================================
# SUITE 1: Flexbox Layout Geometry
# =============================================================================

proc testFlexboxLayoutGeometry(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 1] FLEXBOX LAYOUT GEOMETRY & SIZING VERIFICATION <<<"
  echo "================================================================="

  testWithLeakCheck("1.1 Row Layout Fixed Dimensions, Padding, and Gap"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Container: 400 x 200, row direction, padding [10, 15, 20, 25] (T, R, B, L), gap 10
    let root = tree.createNode(nkBox)
    tree.rootId = root
    let rootNode = addr tree.nodes[root]
    rootNode.direction = fdRow
    rootNode.widthMode = fixed(400.0f)
    rootNode.heightMode = fixed(200.0f)
    rootNode.padding = [10.0f, 15.0f, 20.0f, 25.0f]
    rootNode.gap = 10.0f

    # Child 1: fixed 100 x 50
    let c1 = tree.createNode(nkBox)
    tree.nodes[c1].widthMode = fixed(100.0f)
    tree.nodes[c1].heightMode = fixed(50.0f)
    tree.addChild(root, c1)

    # Child 2: fixed 150 x 80
    let c2 = tree.createNode(nkBox)
    tree.nodes[c2].widthMode = fixed(150.0f)
    tree.nodes[c2].heightMode = fixed(80.0f)
    tree.addChild(root, c2)

    tree.layoutTree(800.0f, 600.0f, atlas)

    # Inner origin is x=25 (left padding), y=10 (top padding)
    let n1 = tree.nodes[c1]
    doAssert approxEq(n1.computedRect.x, 25.0f), &"Child1 X expected 25.0, got {n1.computedRect.x}"
    doAssert approxEq(n1.computedRect.y, 10.0f), &"Child1 Y expected 10.0, got {n1.computedRect.y}"
    doAssert approxEq(n1.computedRect.w, 100.0f), &"Child1 W expected 100.0, got {n1.computedRect.w}"
    doAssert approxEq(n1.computedRect.h, 50.0f), &"Child1 H expected 50.0, got {n1.computedRect.h}"

    # Child 2 starts after Child 1 width (100) + gap (10) = x=135
    let n2 = tree.nodes[c2]
    doAssert approxEq(n2.computedRect.x, 135.0f), &"Child2 X expected 135.0, got {n2.computedRect.x}"
    doAssert approxEq(n2.computedRect.y, 10.0f), &"Child2 Y expected 10.0, got {n2.computedRect.y}"
    doAssert approxEq(n2.computedRect.w, 150.0f), &"Child2 W expected 150.0, got {n2.computedRect.w}"
    doAssert approxEq(n2.computedRect.h, 80.0f), &"Child2 H expected 80.0, got {n2.computedRect.h}"
    echo "  [PASS] 1.1 Row layout fixed dimensions, padding, and gap verified."

  testWithLeakCheck("1.2 Row Layout Pure FlexGrow Distribution"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Container: 600 x 100, row direction, no padding, no gap
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].direction = fdRow
    tree.nodes[root].widthMode = fixed(600.0f)
    tree.nodes[root].heightMode = fixed(100.0f)

    # 3 Children with weights: 1.0, 2.0, 3.0 (sum = 6.0)
    let c1 = tree.createNode(nkBox)
    tree.nodes[c1].widthMode = flexGrow(1.0f)
    tree.addChild(root, c1)

    let c2 = tree.createNode(nkBox)
    tree.nodes[c2].widthMode = flexGrow(2.0f)
    tree.addChild(root, c2)

    let c3 = tree.createNode(nkBox)
    tree.nodes[c3].widthMode = flexGrow(3.0f)
    tree.addChild(root, c3)

    tree.layoutTree(800.0f, 600.0f, atlas)

    # Child 1: 1/6 * 600 = 100
    doAssert approxEq(tree.nodes[c1].computedRect.x, 0.0f)
    doAssert approxEq(tree.nodes[c1].computedRect.w, 100.0f)

    # Child 2: 2/6 * 600 = 200, x = 100
    doAssert approxEq(tree.nodes[c2].computedRect.x, 100.0f)
    doAssert approxEq(tree.nodes[c2].computedRect.w, 200.0f)

    # Child 3: 3/6 * 600 = 300, x = 300
    doAssert approxEq(tree.nodes[c3].computedRect.x, 300.0f)
    doAssert approxEq(tree.nodes[c3].computedRect.w, 300.0f)
    echo "  [PASS] 1.2 Row pure FlexGrow (1:2:3) distribution verified."

  testWithLeakCheck("1.3 Row Layout Mixed Fixed + FlexGrow + Gap"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Container: 500 x 120, row direction, gap 20.
    # Total available width = 500. Two gaps = 40.
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].direction = fdRow
    tree.nodes[root].widthMode = fixed(500.0f)
    tree.nodes[root].heightMode = fixed(120.0f)
    tree.nodes[root].gap = 20.0f

    # Child 1: fixed 100
    let c1 = tree.createNode(nkBox)
    tree.nodes[c1].widthMode = fixed(100.0f)
    tree.addChild(root, c1)

    # Child 2: flexGrow 1.0
    let c2 = tree.createNode(nkBox)
    tree.nodes[c2].widthMode = flexGrow(1.0f)
    tree.addChild(root, c2)

    # Child 3: flexGrow 2.0
    let c3 = tree.createNode(nkBox)
    tree.nodes[c3].widthMode = flexGrow(2.0f)
    tree.addChild(root, c3)

    tree.layoutTree(800.0f, 600.0f, atlas)

    # Remaining space = 500 - 100 - 40 = 360.
    # Child 2 width = 1/3 * 360 = 120.
    # Child 3 width = 2/3 * 360 = 240.
    doAssert approxEq(tree.nodes[c1].computedRect.x, 0.0f)
    doAssert approxEq(tree.nodes[c1].computedRect.w, 100.0f)

    doAssert approxEq(tree.nodes[c2].computedRect.x, 120.0f) # 100 + 20
    doAssert approxEq(tree.nodes[c2].computedRect.w, 120.0f)

    doAssert approxEq(tree.nodes[c3].computedRect.x, 260.0f) # 120 + 120 + 20
    doAssert approxEq(tree.nodes[c3].computedRect.w, 240.0f)

    # Total width reaches exactly 500
    doAssert approxEq(tree.nodes[c3].computedRect.x + tree.nodes[c3].computedRect.w, 500.0f)
    echo "  [PASS] 1.3 Row mixed Fixed + FlexGrow + Gap verified."

  testWithLeakCheck("1.4 Column Layout Geometry with Padding and Gap"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Container: 300 x 500, column direction, padding [20, 0, 20, 0], gap 15.
    # Inner height = 500 - 40 = 460.
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].direction = fdColumn
    tree.nodes[root].widthMode = fixed(300.0f)
    tree.nodes[root].heightMode = fixed(500.0f)
    tree.nodes[root].padding = [20.0f, 0.0f, 20.0f, 0.0f]
    tree.nodes[root].gap = 15.0f

    # 4 Children: Child 1 fixed 60, Child 2 fixed 100, Child 3 flexGrow 1, Child 4 flexGrow 1
    # 3 gaps = 45. Fixed = 160. Remaining = 460 - 160 - 45 = 255.
    # Child 3 and Child 4 each get 127.5.
    let c1 = tree.createNode(nkBox)
    tree.nodes[c1].heightMode = fixed(60.0f)
    tree.addChild(root, c1)

    let c2 = tree.createNode(nkBox)
    tree.nodes[c2].heightMode = fixed(100.0f)
    tree.addChild(root, c2)

    let c3 = tree.createNode(nkBox)
    tree.nodes[c3].heightMode = flexGrow(1.0f)
    tree.addChild(root, c3)

    let c4 = tree.createNode(nkBox)
    tree.nodes[c4].heightMode = flexGrow(1.0f)
    tree.addChild(root, c4)

    tree.layoutTree(800.0f, 600.0f, atlas)

    doAssert approxEq(tree.nodes[c1].computedRect.y, 20.0f)
    doAssert approxEq(tree.nodes[c1].computedRect.h, 60.0f)

    doAssert approxEq(tree.nodes[c2].computedRect.y, 95.0f) # 20 + 60 + 15
    doAssert approxEq(tree.nodes[c2].computedRect.h, 100.0f)

    doAssert approxEq(tree.nodes[c3].computedRect.y, 210.0f) # 95 + 100 + 15
    doAssert approxEq(tree.nodes[c3].computedRect.h, 127.5f)

    doAssert approxEq(tree.nodes[c4].computedRect.y, 352.5f) # 210 + 127.5 + 15
    doAssert approxEq(tree.nodes[c4].computedRect.h, 127.5f)

    doAssert approxEq(tree.nodes[c4].computedRect.y + tree.nodes[c4].computedRect.h, 480.0f)
    echo "  [PASS] 1.4 Column mixed Fixed + FlexGrow + Gap + Padding verified."

  testWithLeakCheck("1.5 FitContent Bottom-Up Intrinsic Sizing"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Container with fitContent width & height, Column direction, padding 10 on all sides, gap 5
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].direction = fdColumn
    tree.nodes[root].widthMode = fitContent()
    tree.nodes[root].heightMode = fitContent()
    tree.nodes[root].padding = [10.0f, 10.0f, 10.0f, 10.0f]
    tree.nodes[root].gap = 5.0f

    # Child 1: fixed 120 x 30
    let c1 = tree.createNode(nkBox)
    tree.nodes[c1].widthMode = fixed(120.0f)
    tree.nodes[c1].heightMode = fixed(30.0f)
    tree.addChild(root, c1)

    # Child 2: fixed 200 x 40
    let c2 = tree.createNode(nkBox)
    tree.nodes[c2].widthMode = fixed(200.0f)
    tree.nodes[c2].heightMode = fixed(40.0f)
    tree.addChild(root, c2)

    tree.layoutTree(1000.0f, 1000.0f, atlas)

    # Intrinsic calculation:
    # Width: max(120, 200) + 10 + 10 = 220
    # Height: 30 + 40 + 5 (gap) + 10 + 10 = 95
    doAssert approxEq(tree.nodes[root].intrinsicSize.w, 220.0f)
    doAssert approxEq(tree.nodes[root].intrinsicSize.h, 95.0f)
    doAssert approxEq(tree.nodes[root].computedRect.w, 220.0f)
    doAssert approxEq(tree.nodes[root].computedRect.h, 95.0f)
    echo "  [PASS] 1.5 FitContent bottom-up intrinsic sizing verified."

  testWithLeakCheck("1.6 Cross-Axis Alignment (Start, Center, End, Stretch)"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Row container of height 200
    let rootRow = tree.createNode(nkBox)
    tree.rootId = rootRow
    tree.nodes[rootRow].direction = fdRow
    tree.nodes[rootRow].widthMode = fixed(500.0f)
    tree.nodes[rootRow].heightMode = fixed(200.0f)

    # Test aiStart
    tree.nodes[rootRow].alignItems = aiStart
    let cStart = tree.createNode(nkBox)
    tree.nodes[cStart].widthMode = fixed(50.0f)
    tree.nodes[cStart].heightMode = fixed(40.0f)
    tree.addChild(rootRow, cStart)

    tree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(tree.nodes[cStart].computedRect.y, 0.0f)

    # Test aiCenter: (200 - 40) * 0.5 = 80
    tree.nodes[rootRow].alignItems = aiCenter
    tree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(tree.nodes[cStart].computedRect.y, 80.0f)

    # Test aiEnd: 200 - 40 = 160
    tree.nodes[rootRow].alignItems = aiEnd
    tree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(tree.nodes[cStart].computedRect.y, 160.0f)

    # Test aiStretch with flexGrow child in cross-axis
    tree.nodes[rootRow].alignItems = aiStretch
    let cStretch = tree.createNode(nkBox)
    tree.nodes[cStretch].widthMode = fixed(50.0f)
    tree.nodes[cStretch].heightMode = flexGrow(1.0f)
    tree.addChild(rootRow, cStretch)

    tree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(tree.nodes[cStretch].computedRect.h, 200.0f)

    # Column container of width 300
    var colTree = initUiTree(testAlloc)
    defer: colTree.destroy()

    let rootCol = colTree.createNode(nkBox)
    colTree.rootId = rootCol
    colTree.nodes[rootCol].direction = fdColumn
    colTree.nodes[rootCol].widthMode = fixed(300.0f)
    colTree.nodes[rootCol].heightMode = fixed(400.0f)

    let colChild = colTree.createNode(nkBox)
    colTree.nodes[colChild].widthMode = fixed(60.0f)
    colTree.nodes[colChild].heightMode = fixed(30.0f)
    colTree.addChild(rootCol, colChild)

    # Column aiCenter: (300 - 60) * 0.5 = 120
    colTree.nodes[rootCol].alignItems = aiCenter
    colTree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(colTree.nodes[colChild].computedRect.x, 120.0f)

    # Column aiEnd: 300 - 60 = 240
    colTree.nodes[rootCol].alignItems = aiEnd
    colTree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(colTree.nodes[colChild].computedRect.x, 240.0f)
    echo "  [PASS] 1.6 Cross-axis alignments (Start, Center, End, Stretch) verified."

  testWithLeakCheck("1.7 Deeply Nested Hierarchy"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    # Root Column: 800 x 600, padding 20
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].direction = fdColumn
    tree.nodes[root].alignItems = aiStretch
    tree.nodes[root].widthMode = fixed(800.0f)
    tree.nodes[root].heightMode = fixed(600.0f)
    tree.nodes[root].padding = [20.0f, 20.0f, 20.0f, 20.0f]
    tree.nodes[root].gap = 10.0f

    # Header Row: fixed height 60
    let header = tree.createNode(nkBox)
    tree.nodes[header].direction = fdRow
    tree.nodes[header].widthMode = flexGrow(1.0f)
    tree.nodes[header].heightMode = fixed(60.0f)
    tree.addChild(root, header)

    # Body Row: flexGrow 1.0 (available H = 600 - 40 - 10 - 60 = 490)
    let body = tree.createNode(nkBox)
    tree.nodes[body].direction = fdRow
    tree.nodes[body].alignItems = aiStretch
    tree.nodes[body].widthMode = flexGrow(1.0f)
    tree.nodes[body].heightMode = flexGrow(1.0f)
    tree.nodes[body].gap = 15.0f
    tree.addChild(root, body)

    # Sidebar: fixed width 200
    let sidebar = tree.createNode(nkBox)
    tree.nodes[sidebar].widthMode = fixed(200.0f)
    tree.nodes[sidebar].heightMode = flexGrow(1.0f)
    tree.addChild(body, sidebar)

    # Content: flexGrow 1.0 (available W = 800 - 40 - 15 - 200 = 545)
    let content = tree.createNode(nkBox)
    tree.nodes[content].widthMode = flexGrow(1.0f)
    tree.nodes[content].heightMode = flexGrow(1.0f)
    tree.addChild(body, content)

    tree.layoutTree(800.0f, 600.0f, atlas)

    doAssert approxEq(tree.nodes[header].computedRect.x, 20.0f)
    doAssert approxEq(tree.nodes[header].computedRect.y, 20.0f)
    doAssert approxEq(tree.nodes[header].computedRect.w, 760.0f)
    doAssert approxEq(tree.nodes[header].computedRect.h, 60.0f)

    doAssert approxEq(tree.nodes[body].computedRect.x, 20.0f)
    doAssert approxEq(tree.nodes[body].computedRect.y, 90.0f) # 20 + 60 + 10
    doAssert approxEq(tree.nodes[body].computedRect.w, 760.0f)
    doAssert approxEq(tree.nodes[body].computedRect.h, 490.0f)

    doAssert approxEq(tree.nodes[sidebar].computedRect.x, 20.0f)
    doAssert approxEq(tree.nodes[sidebar].computedRect.y, 90.0f)
    doAssert approxEq(tree.nodes[sidebar].computedRect.w, 200.0f)
    doAssert approxEq(tree.nodes[sidebar].computedRect.h, 490.0f)

    doAssert approxEq(tree.nodes[content].computedRect.x, 235.0f) # 20 + 200 + 15
    doAssert approxEq(tree.nodes[content].computedRect.y, 90.0f)
    doAssert approxEq(tree.nodes[content].computedRect.w, 545.0f)
    doAssert approxEq(tree.nodes[content].computedRect.h, 490.0f)
    echo "  [PASS] 1.7 Deeply nested hierarchy verified."

# =============================================================================
# SUITE 2: Hit-Testing in Z-Order and State Transitions
# =============================================================================

proc testHitTestingAndStateTransitions(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 2] HIT-TESTING & INTERACTIVE STATE MACHINE <<<"
  echo "================================================================="

  testWithLeakCheck("2.1 Reverse Z-Order Hit-Testing with Overlapping Siblings"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].computedRect = (0.0f, 0.0f, 500.0f, 500.0f)
    tree.nodes[root].clipRect = [0'u16, 0'u16, 500'u16, 500'u16]

    # Node A: (50, 50, 150, 150)
    let nodeA = tree.createNode(nkBox)
    tree.nodes[nodeA].computedRect = (50.0f, 50.0f, 150.0f, 150.0f)
    tree.nodes[nodeA].clipRect = [0'u16, 0'u16, 500'u16, 500'u16]
    tree.addChild(root, nodeA)

    # Node B: (100, 100, 150, 150) added AFTER Node A -> higher in Z-order
    let nodeB = tree.createNode(nkBox)
    tree.nodes[nodeB].computedRect = (100.0f, 100.0f, 150.0f, 150.0f)
    tree.nodes[nodeB].clipRect = [0'u16, 0'u16, 500'u16, 500'u16]
    tree.addChild(root, nodeB)

    # Test only Node A region (70, 70)
    doAssert tree.hitTestNode(root, 70.0f, 70.0f) == nodeA

    # Test overlap region (120, 120): reverse Z-order MUST hit Node B
    doAssert tree.hitTestNode(root, 120.0f, 120.0f) == nodeB

    # Test only Node B region (220, 220)
    doAssert tree.hitTestNode(root, 220.0f, 220.0f) == nodeB

    # Test outside children but inside root (20, 20)
    doAssert tree.hitTestNode(root, 20.0f, 20.0f) == root

    # Test outside root bounds (600, 600)
    doAssert tree.hitTestNode(root, 600.0f, 600.0f) == SlabId(-1'i32)
    echo "  [PASS] 2.1 Reverse Z-order hit-testing on overlapping siblings verified."

  testWithLeakCheck("2.2 Hover State Transitions (handleMouseMove)"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].computedRect = (0.0f, 0.0f, 400.0f, 400.0f)
    tree.nodes[root].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]

    let target = tree.createNode(nkButton)
    tree.nodes[target].computedRect = (50.0f, 50.0f, 100.0f, 40.0f)
    tree.nodes[target].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]
    tree.addChild(root, target)

    doAssert not tree.nodes[target].isHovered
    doAssert tree.hoveredNode == SlabId(-1'i32)

    # 1. Hover onto target
    tree.handleMouseMove(80.0f, 70.0f)
    doAssert tree.hoveredNode == target
    doAssert tree.nodes[target].isHovered
    doAssert tree.isDirty

    # 2. Move within target (no state change)
    tree.isDirty = false
    tree.handleMouseMove(90.0f, 75.0f)
    doAssert tree.hoveredNode == target
    doAssert tree.nodes[target].isHovered

    # 3. Move outside target into root
    tree.handleMouseMove(10.0f, 10.0f)
    doAssert tree.hoveredNode == root
    doAssert not tree.nodes[target].isHovered
    doAssert tree.nodes[root].isHovered

    # 4. Move outside window bounds
    tree.handleMouseMove(500.0f, 500.0f)
    doAssert tree.hoveredNode == SlabId(-1'i32)
    doAssert not tree.nodes[root].isHovered
    echo "  [PASS] 2.2 Hover state transitions verified."

  testWithLeakCheck("2.3 Pressed State Transitions & Click Trigger (handleMouseDown/Up)"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].computedRect = (0.0f, 0.0f, 400.0f, 400.0f)
    tree.nodes[root].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]

    var clickCount = 0
    let btn = tree.createNode(nkButton)
    tree.nodes[btn].computedRect = (50.0f, 50.0f, 120.0f, 40.0f)
    tree.nodes[btn].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]
    tree.nodes[btn].onClick = proc() = inc(clickCount)
    tree.addChild(root, btn)

    # Mouse down on button
    tree.handleMouseDown(80.0f, 70.0f)
    doAssert tree.pressedNode == btn
    doAssert tree.nodes[btn].isPressed
    doAssert clickCount == 0

    # Mouse up on button -> fires onClick
    tree.handleMouseUp(80.0f, 70.0f)
    doAssert tree.pressedNode == SlabId(-1'i32)
    doAssert not tree.nodes[btn].isPressed
    doAssert clickCount == 1

    # Mouse down on button, drag away, and release outside -> click cancelled!
    tree.handleMouseDown(80.0f, 70.0f)
    doAssert tree.nodes[btn].isPressed
    tree.handleMouseUp(300.0f, 300.0f) # Released over root, not button
    doAssert not tree.nodes[btn].isPressed
    doAssert clickCount == 1, "Click should NOT trigger when released outside button!"
    echo "  [PASS] 2.3 Pressed state and onClick trigger/cancel verified."

  testWithLeakCheck("2.4 Focus State Transitions & Keyboard Input (handleChar, handleKeyDown)"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].computedRect = (0.0f, 0.0f, 400.0f, 400.0f)
    tree.nodes[root].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]

    var input1Text = ""
    let input1 = tree.createNode(nkTextInput)
    tree.nodes[input1].computedRect = (10.0f, 10.0f, 150.0f, 30.0f)
    tree.nodes[input1].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]
    tree.nodes[input1].onInput = proc(s: string) = input1Text = s
    tree.addChild(root, input1)

    var input2Text = ""
    let input2 = tree.createNode(nkTextInput)
    tree.nodes[input2].computedRect = (10.0f, 50.0f, 150.0f, 30.0f)
    tree.nodes[input2].clipRect = [0'u16, 0'u16, 400'u16, 400'u16]
    tree.nodes[input2].onInput = proc(s: string) = input2Text = s
    tree.addChild(root, input2)

    # Click on Input1 -> gains focus
    tree.handleMouseDown(20.0f, 20.0f)
    tree.handleMouseUp(20.0f, 20.0f)
    doAssert tree.focusedNode == input1
    doAssert tree.nodes[input1].isFocused
    doAssert not tree.nodes[input2].isFocused

    # Type "Hello"
    for ch in "Hello":
      tree.handleChar(Rune(ch))
    doAssert tree.nodes[input1].text == "Hello"
    doAssert input1Text == "Hello"
    doAssert tree.nodes[input2].text == ""

    # Backspace once (VK_BACK = 0x08)
    tree.handleKeyDown(0x08'u32)
    doAssert tree.nodes[input1].text == "Hell"
    doAssert input1Text == "Hell"

    # Switch focus to Input2
    tree.handleMouseDown(20.0f, 60.0f)
    tree.handleMouseUp(20.0f, 60.0f)
    doAssert tree.focusedNode == input2
    doAssert not tree.nodes[input1].isFocused
    doAssert tree.nodes[input2].isFocused

    # Type "Nim" on Input2
    for ch in "Nim":
      tree.handleChar(Rune(ch))
    doAssert tree.nodes[input2].text == "Nim"
    doAssert input2Text == "Nim"
    doAssert tree.nodes[input1].text == "Hell" # Untouched
    echo "  [PASS] 2.4 Focus transitions and keyboard typing/backspace verified."

  testWithLeakCheck("2.5 Hardware/Shader Clipping Bounds Rejection"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].computedRect = (0.0f, 0.0f, 400.0f, 400.0f)
    tree.nodes[root].clipRect = [50'u16, 50'u16, 200'u16, 200'u16] # Clipped region

    let child = tree.createNode(nkBox)
    tree.nodes[child].computedRect = (0.0f, 0.0f, 300.0f, 300.0f)
    tree.nodes[child].clipRect = [50'u16, 50'u16, 200'u16, 200'u16]
    tree.addChild(root, child)

    # Point at (20, 20) is inside node geometry (0..300) but OUTSIDE clipRect (50..200)
    doAssert tree.hitTestNode(root, 20.0f, 20.0f) == SlabId(-1'i32)

    # Point at (100, 100) is inside both geometry and clipRect
    doAssert tree.hitTestNode(root, 100.0f, 100.0f) == child
    echo "  [PASS] 2.5 Clipping bounds hit-test rejection verified."

# =============================================================================
# SUITE 3: VirtualList Scrolling & Visible Index Calculations at Scale
# =============================================================================

proc testVirtualListScale(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 3] VIRTUALLIST SCALING & VIRTUALIZATION AUDIT <<<"
  echo "================================================================="

  testWithLeakCheck("3.1 1,000,000 Items Geometry & Virtualization Calculations"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let vlist = tree.createNode(nkVirtualList)
    tree.rootId = vlist
    let vNode = addr tree.nodes[vlist]
    vNode.virtualCount = 1_000_000
    vNode.itemHeight = 30.0f
    vNode.widthMode = fixed(400.0f)
    vNode.heightMode = fixed(600.0f)
    vNode.isScrollable = true

    tree.layoutTree(800.0f, 600.0f, atlas)

    # Total content height = 1,000,000 * 30 = 30,000,000 px!
    doAssert approxEq(tree.nodes[vlist].contentHeight, 30_000_000.0f)
    doAssert approxEq(tree.nodes[vlist].computedRect.w, 400.0f)
    doAssert approxEq(tree.nodes[vlist].computedRect.h, 600.0f)

    # Initial visible calculation at offset 0:
    # viewportH = 600, itemH = 30 -> 20 items visible + 1 buffer = firstIdx 0 .. lastIdx 21
    let offset0 = tree.nodes[vlist].scrollOffset
    let first0 = max(0, int(offset0 / 30.0f))
    let last0 = min(1_000_000 - 1, int((offset0 + 600.0f) / 30.0f) + 1)
    doAssert first0 == 0
    doAssert last0 == 21

    # Emit draw instances: zero OOM, renders only 22 visible items (~177 instances for bg + glyphs)
    discard tree.buildDrawInstances(atlas)
    doAssert tree.drawInstances.len > 20 and tree.drawInstances.len < 500
    echo &"  [OK] Rendered {tree.drawInstances.len} draw instances for 1,000,000 items (O(1) memory)."

  testWithLeakCheck("3.2 Mouse Wheel Scrolling & Clamping at Boundaries"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let vlist = tree.createNode(nkVirtualList)
    tree.rootId = vlist
    tree.nodes[vlist].virtualCount = 1_000_000
    tree.nodes[vlist].itemHeight = 30.0f
    tree.nodes[vlist].widthMode = fixed(400.0f)
    tree.nodes[vlist].heightMode = fixed(600.0f)
    tree.nodes[vlist].isScrollable = true
    tree.nodes[vlist].computedRect = (0.0f, 0.0f, 400.0f, 600.0f)
    tree.nodes[vlist].clipRect = [0'u16, 0'u16, 400'u16, 600'u16]
    tree.nodes[vlist].contentHeight = 30_000_000.0f

    # Wheel down: delta = -250.0f -> scrollOffset increases by 250 * 0.4 = 100.0f
    tree.handleMouseWheel(200.0f, 300.0f, -250.0f)
    doAssert approxEq(tree.nodes[vlist].scrollOffset, 100.0f)
    doAssert tree.isDirty
    doAssert tree.isLayoutDirty

    # Visible indices at offset 100:
    # firstIdx = int(100 / 30) = 3
    # lastIdx = int((100 + 600) / 30) + 1 = 24
    let first = max(0, int(tree.nodes[vlist].scrollOffset / 30.0f))
    let last = min(1_000_000 - 1, int((tree.nodes[vlist].scrollOffset + 600.0f) / 30.0f) + 1)
    doAssert first == 3
    doAssert last == 24

    # Wheel up past top -> clamped to 0.0f
    tree.handleMouseWheel(200.0f, 300.0f, 10_000.0f)
    doAssert approxEq(tree.nodes[vlist].scrollOffset, 0.0f)

    # Wheel down past bottom -> clamped to maxScroll = 30_000_000 - 600 = 29_999_400.0f
    tree.handleMouseWheel(200.0f, 300.0f, -100_000_000.0f)
    let maxScroll = 30_000_000.0f - 600.0f
    doAssert approxEq(tree.nodes[vlist].scrollOffset, maxScroll)
    echo "  [PASS] 3.2 Mouse wheel scrolling and boundary clamping verified."

  testWithLeakCheck("3.3 Deep Scrolling & Item Selection at 500,000th Row"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    var selectedItem = -1
    let vlist = tree.createNode(nkVirtualList)
    tree.rootId = vlist
    tree.nodes[vlist].virtualCount = 1_000_000
    tree.nodes[vlist].itemHeight = 30.0f
    tree.nodes[vlist].widthMode = fixed(400.0f)
    tree.nodes[vlist].heightMode = fixed(600.0f)
    tree.nodes[vlist].computedRect = (0.0f, 0.0f, 400.0f, 600.0f)
    tree.nodes[vlist].clipRect = [0'u16, 0'u16, 400'u16, 600'u16]
    tree.nodes[vlist].contentHeight = 30_000_000.0f
    tree.nodes[vlist].onSelect = proc(idx: int) = selectedItem = idx

    # Jump directly to item 500,000: offset = 500,000 * 30 = 15,000,000 px
    tree.nodes[vlist].scrollOffset = 15_000_000.0f

    let first = max(0, int(tree.nodes[vlist].scrollOffset / 30.0f))
    let last = min(1_000_000 - 1, int((tree.nodes[vlist].scrollOffset + 600.0f) / 30.0f) + 1)
    doAssert first == 500_000
    doAssert last == 500_021

    # Click on the 5th visible item on screen (y = 120 px from top of list)
    # relY = 120 + 15,000,000 = 15,000,120 px -> index = int(15,000,120 / 30) = 500,004
    tree.handleMouseDown(200.0f, 120.0f)
    doAssert tree.nodes[vlist].selectedIndex == 500_004
    doAssert selectedItem == 500_004
    echo "  [PASS] 3.3 Deep scrolling and item selection at 500,000 verified."

  testWithLeakCheck("3.4 Microbenchmark: 1,000,000 Items Layout & Draw Passes"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let vlist = tree.createNode(nkVirtualList)
    tree.rootId = vlist
    tree.nodes[vlist].virtualCount = 1_000_000
    tree.nodes[vlist].itemHeight = 30.0f
    tree.nodes[vlist].widthMode = fixed(500.0f)
    tree.nodes[vlist].heightMode = fixed(700.0f)

    let t0 = getMonoTime()
    for iter in 0 ..< 100:
      tree.layoutTree(800.0f, 600.0f, atlas)
      discard tree.buildDrawInstances(atlas)
    let elapsedMs = (getMonoTime() - t0).inMicroseconds.float / 1000.0
    let perFrameUs = (elapsedMs / 100.0) * 1000.0
    echo &"  [BENCH] 1,000,000 items layout + draw pass: {perFrameUs:.2f} µs/frame (< 500 µs target)"
    doAssert perFrameUs < 500.0, "Performance defect: Frame layout time exceeded 0.5 ms!"
    echo "  [PASS] 3.4 Microbenchmark passed."

# =============================================================================
# SUITE 4: Reactive Bindings with corex/signals
# =============================================================================

proc testReactiveSignalsIntegration(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 4] FINE-GRAINED REACTIVE BINDINGS (corex/signals) <<<"
  echo "================================================================="

  testWithLeakCheck("4.1 bindText Reactive State Mutation & Dirty Flags"):
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let txtNode = tree.createNode(nkText)
    tree.rootId = txtNode

    let textSig = rt.createSignal("Initial Title")
    discard bindText(addr tree, addr rt, txtNode, proc(): string = textSig.get())

    # Initial effect execution
    doAssert tree.nodes[txtNode].text == "Initial Title"
    doAssert tree.isDirty
    doAssert tree.isLayoutDirty

    # Reset flags after layout pass
    tree.layoutTree(800.0f, 600.0f, atlas)
    tree.isDirty = false
    tree.isLayoutDirty = false

    # Mutate signal
    textSig.set("Updated Title via Signal")
    doAssert tree.nodes[txtNode].text == "Updated Title via Signal"
    doAssert tree.isDirty, "Tree isDirty should be true after signal update!"
    doAssert tree.isLayoutDirty, "Tree isLayoutDirty should be true after text mutation!"
    echo "  [PASS] 4.1 bindText reactive state mutation and dirty flags verified."

  testWithLeakCheck("4.2 bindBg Visual Reactivity (0 Layout Cost Invariant)"):
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let boxNode = tree.createNode(nkBox)
    tree.rootId = boxNode

    let colorSig = rt.createSignal(0x123456FF'u32)
    discard bindBg(addr tree, addr rt, boxNode, proc(): uint32 = colorSig.get())

    doAssert tree.nodes[boxNode].bgColor == 0x123456FF'u32

    # Clean layout state
    tree.layoutTree(800.0f, 600.0f, atlas)
    tree.isDirty = false
    tree.isLayoutDirty = false

    # Mutate color signal
    colorSig.set(0xABCDEFFF'u32)
    doAssert tree.nodes[boxNode].bgColor == 0xABCDEFFF'u32
    doAssert tree.isDirty, "Tree isDirty must be true for visual redraw!"
    doAssert not tree.isLayoutDirty, "CRITICAL: Color change MUST NOT trigger layout reflow!"
    echo "  [PASS] 4.2 bindBg visual reactivity with zero-layout-cost verified."

  testWithLeakCheck("4.3 bindVirtualCount Dynamic Reactive Scaling"):
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let vlistNode = tree.createNode(nkVirtualList)
    tree.rootId = vlistNode
    tree.nodes[vlistNode].itemHeight = 25.0f

    let countSig = rt.createSignal(50)
    bindVirtualCount(addr tree, addr rt, vlistNode, countSig)

    doAssert tree.nodes[vlistNode].virtualCount == 50

    # Clean layout state
    tree.layoutTree(800.0f, 600.0f, atlas)
    tree.isDirty = false
    tree.isLayoutDirty = false

    # Mutate count to 1,000,000
    countSig.set(1_000_000)
    doAssert tree.nodes[vlistNode].virtualCount == 1_000_000
    doAssert tree.isDirty
    doAssert tree.isLayoutDirty

    tree.layoutTree(800.0f, 600.0f, atlas)
    doAssert approxEq(tree.nodes[vlistNode].contentHeight, 25_000_000.0f)
    echo "  [PASS] 4.3 bindVirtualCount reactive scaling verified."

  testWithLeakCheck("4.4 bindInput Bidirectional Reactivity"):
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let inputNode = tree.createNode(nkTextInput)
    tree.rootId = inputNode

    let querySig = rt.createSignal("Initial Query")
    bindInput(addr tree, addr rt, inputNode, querySig)

    doAssert tree.nodes[inputNode].text == "Initial Query"

    # Direction 1: Signal -> Node
    querySig.set("Search Documents")
    doAssert tree.nodes[inputNode].text == "Search Documents"

    # Direction 2: Node (User input) -> Signal
    tree.nodes[inputNode].onInput("User Typing...")
    doAssert querySig.get() == "User Typing..."
    echo "  [PASS] 4.4 bindInput bidirectional reactivity verified."

  testWithLeakCheck("4.5 Declarative ui Macro AST Expansion & Component Reactivity"):
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()

    let titleSig = rt.createSignal("Counter: 0")
    var clickTally = 0
    let clickCb = proc() =
      inc(clickTally)
      titleSig.set(&"Counter: {clickTally}")

    ui testCard:
      VStack(padding = 16.0f, gap = 8.0f):
        Text(titleSig.get())
        Button("Click Me", onClick = clickCb)

    testCard(tree, addr rt)

    doAssert tree.nodes.len == 3 # Root VStack, Text, Button
    let textNode = tree.nodes[tree.rootId].children[0]
    let btnNode = tree.nodes[tree.rootId].children[1]

    doAssert tree.nodes[textNode].text == "Counter: 0"

    # Simulate button click
    tree.nodes[btnNode].onClick()
    doAssert clickTally == 1
    doAssert tree.nodes[textNode].text == "Counter: 1"

    tree.nodes[btnNode].onClick()
    doAssert clickTally == 2
    doAssert tree.nodes[textNode].text == "Counter: 2"
    echo "  [PASS] 4.5 Declarative ui macro AST expansion and reactive dispatch verified."

# =============================================================================
# SUITE 5: Strict Zero-Leak Audit
# =============================================================================

proc testZeroLeakAudit(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 5] STRICT 1,000-CYCLE LIFECYCLE & ZERO-LEAK AUDIT <<<"
  echo "================================================================="

  testWithLeakCheck("5.1 1,000-Cycle UiTree Creation, Spilled Children & Destruction"):
    for cycle in 0 ..< 1000:
      var tree = initUiTree(testAlloc)
      let root = tree.createNode(nkBox)
      tree.rootId = root
      tree.nodes[root].direction = fdColumn
      tree.nodes[root].widthMode = fixed(400.0f)
      tree.nodes[root].heightMode = fixed(400.0f)

      # Add 12 children (exceeds inline SmallVec capacity of 8 -> forces heap spill)
      for i in 0 ..< 12:
        let ch = tree.createNode(nkText)
        tree.nodes[ch].text = "Item " & $i
        tree.nodes[ch].heightMode = fixed(20.0f)
        tree.addChild(root, ch)

      doAssert tree.nodes[root].children.len == 12
      doAssert not tree.nodes[root].children.isInline

      tree.layoutTree(800.0f, 600.0f, atlas)
      discard tree.buildDrawInstances(atlas)
      tree.destroy()
    echo "  [PASS] 5.1 1,000 UiTree creation/layout/destroy cycles (with SmallVec spills) passed with 0 leaks."

  testWithLeakCheck("5.2 1,000-Cycle Combined Reactive Engine + UI Trees"):
    for cycle in 0 ..< 1000:
      var rt = initReactiveRuntime(testAlloc)
      var tree = initUiTree(testAlloc)

      let s = rt.createSignal(cycle)
      let box = tree.createNode(nkBox)
      tree.rootId = box
      let txt = tree.createNode(nkText)
      tree.addChild(box, txt)

      discard bindText(addr tree, addr rt, txt, proc(): string = "Val: " & $s.get())
      doAssert tree.nodes[txt].text == "Val: " & $cycle

      s.set(cycle * 2)
      doAssert tree.nodes[txt].text == "Val: " & $(cycle * 2)

      tree.destroy()
      rt.destroy()
    echo "  [PASS] 5.2 1,000 Reactive + UI combined lifecycles passed with 0 leaks."

# =============================================================================
# Test Runner Main Entry
# =============================================================================

proc main() =
  echo "================================================================="
  echo ">>> STARTING COMPREHENSIVE NIMUI LAYOUT TEST SUITE <<<"
  echo "================================================================="

  let atlas = initFontAtlas("Segoe UI", 16.0f)
  doAssert atlas.width == 512 and atlas.height == 512

  testFlexboxLayoutGeometry(atlas)
  testHitTestingAndStateTransitions(atlas)
  testVirtualListScale(atlas)
  testReactiveSignalsIntegration(atlas)
  testZeroLeakAudit(atlas)

  echo "\n================================================================="
  echo ">>> [SUCCESS] ALL NIMUI LAYOUT TESTS PASSED WITH 0 LEAKS! <<<"
  echo "================================================================="

when isMainModule:
  main()
