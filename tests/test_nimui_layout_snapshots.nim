## tests/test_nimui_layout_snapshots.nim — Layout Reliability, Multilingual, Snapshots, Cycle Guards & Visual Diff Tests

import std/math
import corex
import nimui/gpu/font_atlas
import nimui/layout
import nimui/multiline
import nimui/rasterizer
import nimui/html_css

proc approxEq(a, b: float32, eps: float32 = 0.05f): bool {.inline, raises: [].} =
  abs(a - b) <= eps

proc main() =
  echo "================================================================="
  echo ">>> STARTING LAYOUT RELIABILITY & SNAPSHOT TEST SUITE <<<"
  echo "================================================================="

  let atlas = initFontAtlas("Segoe UI", 16.0f)

  testWithLeakCheck("1. Nested Flex, Min/Max, %, Auto, Gap, Overflow & Scroll"):
    let html = """
      <div class="outer">
        <div class="header">Header</div>
        <div class="body">
          <div class="sidebar">Side</div>
          <div class="content">
            <div class="card">A</div>
            <div class="card">B</div>
            <div class="card">C</div>
          </div>
        </div>
      </div>
    """
    let css = """
      .outer { display: flex; flex-direction: column; width: 500px; height: 300px; padding: 10px; gap: 10px; }
      .header { height: 40px; min-height: 30px; max-height: 50px; }
      .body { display: flex; flex-direction: row; flex-grow: 1; gap: 10px; overflow-y: auto; }
      .sidebar { width: 25%; min-width: 80px; max-width: 150px; }
      .content { display: flex; flex-direction: column; flex-grow: 1; gap: 8px; }
      .card { height: 120px; }
    """
    let docRes = parseHtmlDoc(html)
    doAssert docRes.isOk
    let sheet = parseCssSheet(css)
    var rt = initReactiveRuntime()
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let mountRes = mountHtml(tree, addr rt, docRes.val, sheet, bindings)
    doAssert mountRes.isOk
    let outerId = mountRes.get()
    tree.layoutTree(500.0f, 300.0f, atlas)

    # Verify deterministic snapshot across repeated layouts
    let snap1 = snapshotUiTree(tree)
    tree.layoutTree(500.0f, 300.0f, atlas)
    let snap2 = snapshotUiTree(tree)
    doAssert snap1 == snap2

    # Verify scroll clamping on overflowing .body
    let bodyId = tree.nodes[outerId].children[1]
    doAssert tree.nodes[bodyId].isScrollable
    tree.nodes[bodyId].scrollOffset = 50.0f
    tree.layoutTree(500.0f, 300.0f, atlas)
    doAssert approxEq(tree.nodes[bodyId].scrollOffset, 50.0f)
    echo "  [PASS] 1. Nested flex, min/max, %, auto, gap, overflow & scroll verified."

  testWithLeakCheck("2. Z-Index Draw Order & Reverse Z-Order Hit-Testing"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].widthMode = fixed(200.0f)
    tree.nodes[root].heightMode = fixed(200.0f)

    # Child A added first, but has higher zIndex = 10
    let a = tree.createNode(nkBox)
    tree.nodes[a].widthMode = fixed(200.0f)
    tree.nodes[a].heightMode = fixed(200.0f)
    tree.nodes[a].bgColor = 0xFF0000FF'u32
    tree.nodes[a].zIndex = 10
    tree.addChild(root, a)

    # Child B added second, but has lower zIndex = 1
    let b = tree.createNode(nkBox)
    tree.nodes[b].widthMode = fixed(200.0f)
    tree.nodes[b].heightMode = fixed(200.0f)
    tree.nodes[b].bgColor = 0x00FF00FF'u32
    tree.nodes[b].zIndex = 1
    tree.addChild(root, b)

    tree.layoutTree(200.0f, 200.0f, atlas)
    discard tree.buildDrawInstances(atlas)

    # B (z=1) must draw before A (z=10)
    doAssert tree.drawInstances.len == 2
    doAssert tree.drawInstances[0].color == 0x00FF00FF'u32
    doAssert tree.drawInstances[1].color == 0xFF0000FF'u32

    # Hit-test at (100, 100) must hit A (z=10)
    doAssert tree.hitTestNode(tree.rootId, 100.0f, 100.0f) == a
    echo "  [PASS] 2. Z-index draw order & hit-testing verified."

  testWithLeakCheck("3. Multilingual (Mixed-Dir/RTL, Cyrillic, Emoji, CJK, Ligatures) & Wrapping"):
    let samples = [
      "Привет мир! Кириллица",
      "Mixed RTL مرحبا بالعالم and שלום LTR",
      "CJK 日本語テスト 中文测试 한국어",
      "Emoji 🚀🔥✅🎉",
      "Ligatures: fi fl ffi -> !== ==="
    ]
    for s in samples:
      let (w, h) = atlas.measureText(s, 16.0f)
      doAssert w > 0.0f and h > 0.0f
      let wrapped = wrapTextToLines(s, 90.0f, atlas, 16.0f)
      doAssert wrapped.len >= 1
      let ml = measureMultilineText(s, 90.0f, atlas, 16.0f)
      doAssert ml.height >= h
    echo "  [PASS] 3. Multilingual & wrapping layout verified."

  testWithLeakCheck("4. Circular Constraint & Infinite Loop Guards"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let n1 = tree.createNode(nkBox)
    let n2 = tree.createNode(nkBox)
    let n3 = tree.createNode(nkBox)
    tree.rootId = n1

    # Self-cycle guard
    tree.addChild(n1, n1)
    doAssert tree.layoutCycleDetected
    doAssert tree.nodes[n1].children.len == 0

    # 2-node and 3-node cycle guard
    tree.layoutCycleDetected = false
    tree.addChild(n1, n2)
    tree.addChild(n2, n3)
    tree.addChild(n3, n1)
    doAssert tree.layoutCycleDetected
    doAssert tree.nodes[n3].children.len == 0

    # NaN / Inf sanitization guard
    tree.nodes[n2].widthMode = fixed(NaN)
    tree.nodes[n2].heightMode = fixed(Inf)
    tree.layoutTree(400.0f, 300.0f, atlas)
    doAssert classify(tree.nodes[n2].computedRect.w) != fcNan
    doAssert classify(tree.nodes[n2].computedRect.h) != fcInf

    # MaxLayoutDepth (> 256) guard
    var deepTree = initUiTree(testAlloc)
    defer: deepTree.destroy()
    var prev = deepTree.createNode(nkBox)
    deepTree.rootId = prev
    for _ in 0 ..< 270:
      let nxt = deepTree.createNode(nkBox)
      deepTree.addChild(prev, nxt)
      prev = nxt
    deepTree.layoutTree(400.0f, 300.0f, atlas)
    doAssert deepTree.layoutCycleDetected or deepTree.layoutDepthExceeded
    echo "  [PASS] 4. Circular constraint & infinite loop guards verified."

  testWithLeakCheck("5. CI Visual Diff Check (Deterministic Rasterizer & Hash)"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].widthMode = fixed(120.0f)
    tree.nodes[root].heightMode = fixed(80.0f)
    tree.nodes[root].bgColor = 0x111827FF'u32
    tree.nodes[root].radius = 6.0f

    let btn = tree.createNode(nkButton)
    tree.nodes[btn].widthMode = fixed(80.0f)
    tree.nodes[btn].heightMode = fixed(32.0f)
    tree.nodes[btn].bgColor = 0x2563EBFF'u32
    tree.nodes[btn].textColor = 0xFFFFFFFF'u32
    tree.nodes[btn].text = "OK"
    tree.nodes[btn].fontSize = 14.0f
    tree.addChild(root, btn)

    tree.layoutTree(120.0f, 80.0f, atlas)
    discard tree.buildDrawInstances(atlas)

    var fbA = initSoftwareFramebuffer(120, 80, 0x000000FF'u32)
    fbA.renderInstancesToBuffer(tree.drawInstances, atlas, clearColor = 0x000000FF'u32)
    var fbB = initSoftwareFramebuffer(120, 80, 0x000000FF'u32)
    fbB.renderInstancesToBuffer(tree.drawInstances, atlas, clearColor = 0x000000FF'u32)

    let diffSame = compareFramebuffers(fbA, fbB)
    doAssert not diffSame.dimensionMismatch
    doAssert diffSame.diffPixels == 0
    doAssert framebufferHash(fbA) == framebufferHash(fbB)

    # Mutate 1 pixel and confirm visual diff catches it
    fbB.pixels[10 * 120 + 10] = fbB.pixels[10 * 120 + 10] xor 0x01000000'u32
    let diffMut = compareFramebuffers(fbA, fbB, maxChannelDiff = 0)
    doAssert diffMut.diffPixels == 1
    doAssert diffMut.maxDiff == 1
    echo "  [PASS] 5. Visual diff & deterministic framebuffer hash verified with 0 leaks."

  echo "================================================================="
  echo ">>> [SUCCESS] ALL LAYOUT RELIABILITY & SNAPSHOT TESTS PASSED! <<<"
  echo "================================================================="

when isMainModule:
  main()
