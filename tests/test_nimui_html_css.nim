## tests/test_nimui_html_css.nim — Comprehensive Tests for Pure-Nim HTML5/CSS3 Engine (Zero-JS)
##
## Covers:
## 1.1 HTML5 parser: comments, DOCTYPE, void/self-closing tags, <style> capture, entities, DOM helpers
## 1.2 Zero-JS policy: strict rejection of <script>, on* event attributes, javascript: URIs
## 2.1 CSS3 parser & cascade: colors (hex/rgb/rgba/named/obsidian), specificity, combinators, pseudo-states
## 3.1 Flexbox layout integration: mountHtml + layoutTree geometry, display:none skip, padding [T,R,B,L]
## 4.1 Pure-Nim reactivity: HtmlBindingRegistry + ReactiveRuntime (data-click, data-text, data-bind)
## 5.1 Software rasterizer + PNG verification + 500-cycle TrackingAllocator zero-leak audit

import corex
import nimui
import nimui/gpu/font_atlas

proc approxEq(a, b: float32, eps: float32 = 0.05f): bool {.inline, raises: [].} =
  abs(a - b) <= eps

proc containsAsciiTag(buf: seq[uint8], tag: string): bool {.raises: [].} =
  if tag.len == 0 or buf.len < tag.len:
    return false
  for i in 0 .. (buf.len - tag.len):
    var matched = true
    for j in 0 ..< tag.len:
      if buf[i + j] != uint8(ord(tag[j])):
        matched = false
        break
    if matched:
      return true
  false

# =============================================================================
# 1.1 & 1.2 HTML5 Parser + Zero-JS Enforcement
# =============================================================================

proc testHtmlParserAndZeroJs() =
  echo "\n================================================================="
  echo ">>> [SUITE 1] HTML5 PARSER & ZERO-JS POLICY VERIFICATION <<<"
  echo "================================================================="

  testWithLeakCheck("1.1 HTML5 Parsing, Entities, Void Tags & Embedded CSS"):
    let rawHtml = """
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="utf-8">
          <!-- Pure-Nim styling inside <style> -->
          <style>
            .card { background: #1E293B; padding: 12px; }
          </style>
        </head>
        <body>
          <div id="main-card" class="card primary" data-role="panel">
            <h1>Title &amp; Status</h1>
            <p id="entities">A &lt; B &gt; C &quot;Q&quot; &#39;S&#39; &apos;P&apos; X&nbsp;Y &#65;&#x42;</p>
            <input id="q" type="text" placeholder="Search..." value=hello disabled />
            <br>
          </div>
        </body>
      </html>
    """
    let res = parseHtmlDoc(rawHtml)
    doAssert res.isOk(), "Valid HTML5 should parse cleanly"
    let doc = res.get()

    doAssert doc.embeddedCss.len > 0
    let sheet = parseCssSheet(doc.embeddedCss)
    doAssert sheet.rules.len == 1

    let cardOpt = doc.findById("main-card")
    doAssert cardOpt.isSome()
    let cardNode = doc.nodes[cardOpt.get()]
    doAssert cardNode.tag == "div"
    doAssert cardNode.hasClass("card")
    doAssert cardNode.hasClass("primary")
    doAssert not cardNode.hasClass("missing")
    doAssert cardNode.getAttr("data-role").getOr("") == "panel"

    let entOpt = doc.findById("entities")
    doAssert entOpt.isSome()
    let txt = doc.innerText(entOpt.get())
    doAssert txt == "A < B > C \"Q\" 'S' 'P' X Y AB", "Entity decoding mismatch: " & txt

    let inOpt = doc.findById("q")
    doAssert inOpt.isSome()
    let inNode = doc.nodes[inOpt.get()]
    doAssert inNode.tag == "input"
    doAssert inNode.getAttr("placeholder").getOr("") == "Search..."
    doAssert inNode.getAttr("value").getOr("") == "hello"
    doAssert inNode.getAttr("disabled").isSome()
    echo "  [PASS] 1.1 HTML5 parsing, entities, void tags & embedded <style> verified."

  testWithLeakCheck("1.2 Strict Zero-JS Rejection (<script>, on*, javascript:)"):
    let badCases = [
      "<div id='x'><script>alert(1)</script></div>",
      "<SCRIPT src='evil.js'></SCRIPT>",
      "<script/>",
      "<button onclick='doJs()'>Bad</button>",
      "<input oninput=\"track()\" type=\"text\">",
      "<body ONLOAD='init()'><p>Hi</p></body>",
      "<a href='javascript:void(0)'>Link</a>",
      "<div onmouseover='steal()'>Hover</div>"
    ]
    for sample in badCases:
      let res = parseHtmlDoc(sample)
      doAssert res.isErr(), "Zero-JS policy MUST reject: " & sample

    let goodReactive = """<div data-click="reset" data-bind="filter" data-text="msg">Safe Nim</div>"""
    let okRes = parseHtmlDoc(goodReactive)
    doAssert okRes.isOk(), "Declarative data-* attributes must be allowed"
    echo "  [PASS] 1.2 Zero-JS strict rejection verified across 8 forbidden patterns."

# =============================================================================
# 2.1 CSS3 Parser, Colors, Selectors & Cascade
# =============================================================================

proc testCssCascadeAndColors() =
  echo "\n================================================================="
  echo ">>> [SUITE 2] CSS3 COLORS, SELECTORS & SPECIFICITY CASCADE <<<"
  echo "================================================================="

  testWithLeakCheck("2.1 Colors, Specificity Cascade, Combinators & Pseudo-States"):
    doAssert parseCssColor("#abc").getOr(0'u32) == 0xAABBCCFF'u32
    doAssert parseCssColor("#1234").getOr(0'u32) == 0x11223344'u32
    doAssert parseCssColor("#112233").getOr(0'u32) == 0x112233FF'u32
    doAssert parseCssColor("#11223380").getOr(0'u32) == 0x11223380'u32
    doAssert parseCssColor("rgb(10, 20, 30)").getOr(0'u32) == 0x0A141EFF'u32
    doAssert parseCssColor("rgba(255, 0, 128, 0.5)").getOr(0'u32) == 0xFF008080'u32
    doAssert parseCssColor("hsl(120, 100%, 50%)").getOr(0'u32) == 0x00FF00FF'u32
    doAssert parseCssColor("transparent").getOr(0'u32) == 0x00000000'u32
    doAssert parseCssColor("not-a-color").isNone()
    # Non-standard theme color names must NOT resolve in standard CSS resolver
    for nonStd in ["slate", "indigo", "emerald", "rose", "amber", "obsidian", "midnight"]:
      doAssert parseCssColor(nonStd).isNone(), "Standard resolver must reject non-standard color: " & nonStd
    # Opt-in theme resolver still supports them
    doAssert parseThemeColor("obsidian").getOr(0'u32) == 0x0A0A0CFF'u32
    doAssert parseThemeColor("indigo").getOr(0'u32) == 0x4F46E5FF'u32

    let html = """
      <div id="root" class="shell">
        <div class="row">
          <button id="act" class="btn primary" style="border-radius: 9px;">Go</button>
        </div>
        <h1 id="hdr">Heading</h1>
      </div>
    """
    let css = """
      /* Lowest specificity: tag */
      button { background-color: #111111; color: #AAAAAA; border: 1px solid #222222; }
      /* Class (100) + Descendant (200) */
      .shell .btn { background-color: #333333; padding: 8px 16px 10px 12px; }
      /* Compound class (200), later in source */
      .btn.primary { background-color: #2563EB; }
      /* Direct child combinator */
      .shell > .row > .btn { color: #FFFFFF; }
      /* ID overrides background (10000), inline style overrides border-radius */
      #act { border-radius: 4px; }
      #act:hover { background-color: #3B82F6; border-color: #93C5FD; }
      #act:active { background-color: #1D4ED8; }
      .shell { color: #10B981; font-size: 18px; }
    """
    let docRes = parseHtmlDoc(html)
    doAssert docRes.isOk()
    let doc = docRes.get()
    let sheet = parseCssSheet(css)

    let rootIdx = doc.findById("root").get()
    let rootStyle = computeNodeStyle(doc, rootIdx, sheet, defaultRootStyle())
    doAssert rootStyle.fgColor == 0x10B981FF'u32
    doAssert approxEq(rootStyle.fontSize, 18.0f)

    # Child <h1> inherits color from .shell, preserves semantic h1 font-size = 24
    let hdrIdx = doc.findById("hdr").get()
    let hdrStyle = computeNodeStyle(doc, hdrIdx, sheet, rootStyle)
    doAssert hdrStyle.fgColor == 0x10B981FF'u32
    doAssert approxEq(hdrStyle.fontSize, 24.0f)

    let rowIdx = doc.nodes[rootIdx].children[0]
    let rowStyle = computeNodeStyle(doc, rowIdx, sheet, rootStyle)

    let actIdx = doc.findById("act").get()
    let actStyle = computeNodeStyle(doc, actIdx, sheet, rowStyle)
    doAssert actStyle.bgColor == 0x2563EBFF'u32, "Expected .btn.primary later rule to win equal 200 specificity"
    doAssert actStyle.fgColor == 0xFFFFFFFF'u32, "Expected .shell > .row > .btn color to win"
    doAssert actStyle.borderColor == 0x222222FF'u32
    doAssert approxEq(actStyle.borderWidth, 1.0f)
    doAssert approxEq(actStyle.borderRadius, 9.0f), "Inline style border-radius must override #act"
    doAssert approxEq(actStyle.padding[0], 8.0f)
    doAssert approxEq(actStyle.padding[1], 16.0f)
    doAssert approxEq(actStyle.padding[2], 10.0f)
    doAssert approxEq(actStyle.padding[3], 12.0f)
    doAssert actStyle.bgHoverColor == 0x3B82F6FF'u32
    doAssert actStyle.borderHoverColor == 0x93C5FDFF'u32
    doAssert actStyle.bgActiveColor == 0x1D4ED8FF'u32
    echo "  [PASS] 2.1 CSS3 colors, specificity cascade, combinators & pseudo-states verified."

# =============================================================================
# 3.1 mountHtml + layoutTree Flexbox Geometry
# =============================================================================

proc testMountAndFlexboxLayout(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 3] HTML/CSS FLEXBOX MOUNT & GEOMETRY VERIFICATION <<<"
  echo "================================================================="

  testWithLeakCheck("3.1 Mount HTML Flexbox, Percentage/Grow, Padding & display:none"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()

    let html = """
      <style>
        #shell {
          display: flex;
          flex-direction: row;
          width: 500px;
          height: 120px;
          padding: 10px 20px;
          gap: 10px;
          background: #0A0A0C;
        }
        #left-pane {
          flex: 1;
          height: 100%;
          background: #1E293B;
        }
        #right-pane {
          flex: 2;
          height: 100%;
          background: #334155;
        }
        #ghost {
          display: none;
        }
      </style>
      <div id="shell">
        <div id="left-pane">Left</div>
        <div id="ghost">Should Not Mount</div>
        <div id="right-pane">Right</div>
      </div>
    """

    let mountRes = mountHtmlString(tree, addr rt, html, "", bindings)
    doAssert mountRes.isOk()
    doAssert bindings.getNodeById("ghost").isNone(), "display:none element must be skipped"

    tree.layoutTree(800.0f, 600.0f, atlas)

    let shellId = bindings.getNodeById("shell").get()
    let leftId = bindings.getNodeById("left-pane").get()
    let rightId = bindings.getNodeById("right-pane").get()

    let sr = tree.nodes[shellId].computedRect
    doAssert approxEq(sr.w, 500.0f) and approxEq(sr.h, 120.0f)

    # Inner width = 500 - 20 - 20 = 460; gap = 10 -> flex pool = 450 -> 150 and 300.
    # Inner height = 120 - 10 - 10 = 100.
    let lr = tree.nodes[leftId].computedRect
    let rr = tree.nodes[rightId].computedRect
    doAssert approxEq(lr.x, 20.0f), "Expected left.x = 20, got " & $lr.x
    doAssert approxEq(lr.y, 10.0f), "Expected left.y = 10, got " & $lr.y
    doAssert approxEq(lr.w, 150.0f), "Expected left.w = 150, got " & $lr.w
    doAssert approxEq(lr.h, 100.0f), "Expected left.h = 100, got " & $lr.h

    doAssert approxEq(rr.x, 180.0f), "Expected right.x = 180, got " & $rr.x
    doAssert approxEq(rr.y, 10.0f), "Expected right.y = 10, got " & $rr.y
    doAssert approxEq(rr.w, 300.0f), "Expected right.w = 300, got " & $rr.w
    doAssert approxEq(rr.h, 100.0f), "Expected right.h = 100, got " & $rr.h
    echo "  [PASS] 3.1 HTML Flexbox geometry, padding, flex-grow & display:none verified."

# =============================================================================
# 4.1 Pure-Nim Interactive & Reactive Bindings
# =============================================================================

proc testPureNimReactivity(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 4] PURE-NIM HTML REACTIVE BINDINGS VERIFICATION <<<"
  echo "================================================================="

  testWithLeakCheck("4.1 HtmlBindingRegistry + ReactiveRuntime Click, Text & Two-Way Input"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()

    let statusSig = rt.createSignal("Ready")
    let querySig = rt.createSignal("")
    var clickCount = 0
    var mirroredInput = ""

    bindings.onClick("increment", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc clickCount
        statusSig.set("Clicks: " & $clickCount)
    )
    bindings.bindTextSignal("status-label", statusSig)
    bindings.bindInputSignal("search-query", querySig)
    bindings.onInput("track-query", proc(text: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        mirroredInput = text
    )

    let html = """
      <div id="toolbar" style="display: flex; flex-direction: row; gap: 8px; width: 500px; height: 60px;">
        <button id="btn-inc" data-click="increment">Increment</button>
        <input id="search-box" data-bind="search-query" data-input="track-query" placeholder="Filter..." />
        <div id="status-pill" data-text="status-label" style="background: #1E293B; padding: 6px;"></div>
      </div>
    """
    let mountRes = mountHtmlString(tree, addr rt, html, "", bindings)
    doAssert mountRes.isOk()
    tree.layoutTree(800.0f, 600.0f, atlas)

    let btnId = bindings.getNodeById("btn-inc").get()
    let inId = bindings.getNodeById("search-box").get()
    let pillId = bindings.getNodeById("status-pill").get()
    let pillTextChild = tree.nodes[pillId].children[0]

    doAssert tree.nodes[pillTextChild].text == "Ready"

    # Trigger pure-Nim click callback -> updates Signal -> reactive bindText mutates UiNode
    doAssert tree.nodes[btnId].onClick != nil
    tree.nodes[btnId].onClick()
    tree.nodes[btnId].onClick()
    doAssert clickCount == 2
    doAssert tree.nodes[pillTextChild].text == "Clicks: 2"

    # Simulate user typing into <input> -> updates querySig AND calls onInput hook
    doAssert tree.nodes[inId].onInput != nil
    tree.nodes[inId].onInput("andromeda")
    doAssert querySig.get() == "andromeda"
    doAssert mirroredInput == "andromeda"

    # Programmatic signal update -> syncs back into <input> node
    querySig.set("orion")
    doAssert tree.nodes[inId].text == "orion"
    echo "  [PASS] 4.1 Pure-Nim click, two-way input & reactive text bindings verified."

# =============================================================================
# 5.1 Rasterizer Render Check & 500-Cycle Zero-Leak Stress Audit
# =============================================================================

proc testRasterizerAndLeakStress(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 5] SOFTWARE RASTERIZER & 500-CYCLE ZERO-LEAK AUDIT <<<"
  echo "================================================================="

  testWithLeakCheck("5.1 End-to-End HTML/CSS Rasterization & Valid PNG Output"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()

    let html = """
      <style>
        #frame {
          width: 220px;
          height: 110px;
          padding: 16px;
          background: #0A0A0C;
          flex-direction: column;
          gap: 10px;
        }
        #cta {
          width: 140px;
          height: 36px;
          background: #E03030;
          color: #FFFFFF;
          border-radius: 6px;
        }
      </style>
      <div id="frame">
        <button id="cta">Launch</button>
      </div>
    """
    let mountRes = mountHtmlString(tree, addr rt, html, "", bindings)
    doAssert mountRes.isOk()
    tree.layoutTree(220.0f, 110.0f, atlas)
    discard tree.buildDrawInstances(atlas)

    var fb = initSoftwareFramebuffer(220, 110, 0x000000FF'u32)
    fb.renderInstancesToBuffer(tree.drawInstances, atlas, clearColor = 0x000000FF'u32)

    # Obsidian background outside CTA button
    doAssert fb.getPixel(5, 5) == 0x0A0A0CFF'u32
    # Red CTA button interior (padding top=16, left=16, size=140x36)
    doAssert fb.getPixel(30, 34) == 0xE03030FF'u32

    let png = encodePng(fb)
    doAssert png.len > 40
    doAssert png[0 .. 7] == @[137'u8, 80'u8, 78'u8, 71'u8, 13'u8, 10'u8, 26'u8, 10'u8]
    doAssert png[12 .. 15] == @[byte('I'), byte('H'), byte('D'), byte('R')]
    doAssert containsAsciiTag(png, "IDAT")
    doAssert containsAsciiTag(png, "IEND")
    echo "  [PASS] 5.1 End-to-end HTML/CSS rasterization & PNG output verified."

  testWithLeakCheck("5.2 500-Cycle HTML Parse + CSS Cascade + Mount + Destroy Zero-Leak Audit"):
    let html = """
      <style>
        .panel { display: flex; flex-direction: column; gap: 6px; padding: 8px; background: #0A0A0C; }
        .item { color: #E2E8F0; font-size: 13px; }
      </style>
      <div class="panel">
        <button id="b" data-click="act">Run</button>
        <input id="in" data-bind="q" placeholder="Type" />
        <span class="item" data-text="st">Init</span>
      </div>
    """
    for iter in 0 ..< 500:
      var tree = initUiTree(testAlloc)
      var rt = initReactiveRuntime(testAlloc)
      var bindings = initHtmlBindingRegistry()
      let s1 = rt.createSignal("Run-" & $iter)
      let s2 = rt.createSignal("")
      bindings.onClick("act", proc() {.closure, gcsafe, raises: [].} = discard)
      bindings.bindTextSignal("st", s1)
      bindings.bindInputSignal("q", s2)

      let res = mountHtmlString(tree, addr rt, html, "", bindings)
      doAssert res.isOk()
      tree.layoutTree(400.0f, 300.0f, atlas)
      discard tree.buildDrawInstances(atlas)
      s1.set("Done-" & $iter)

      bindings.destroy()
      tree.destroy()
      rt.destroy()
    echo "  [PASS] 5.2 500-cycle HTML/CSS/Reactive lifecycle leaked 0 bytes."

# =============================================================================
# 6.1 Extended CSS3 Properties, Custom Vars, @media, :focus/:disabled & HTML Tags
# =============================================================================

proc testExtendedCssAndHtmlTags(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 6] EXTENDED CSS3 PROPERTIES, @MEDIA & HTML TAGS <<<"
  echo "================================================================="

  testWithLeakCheck("6.1 var(--x), linear-gradient, box-shadow, opacity, @media, :focus, :disabled"):
    let html = """
      <html>
        <head>
          <style>
            :root {
              --BrandColor: #4F46E5;
              --surface: #0A0A0C;
            }
            .box {
              background: linear-gradient(135deg, #4F46E5 0%, #10B981 100%);
              box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
              opacity: 0.5;
              font-weight: bold;
              font-family: "Inter", sans-serif;
              line-height: 1.5;
              cursor: pointer;
              text-overflow: ellipsis;
              white-space: nowrap;
              position: relative;
              z-index: 42;
              flex-wrap: wrap;
              flex-shrink: 0;
              flex-basis: 120px;
              align-self: center;
              row-gap: 12px;
              column-gap: 20px;
              transition: background-color 150ms ease-in-out;
              color: var(--BrandColor);
              border: 1px solid var(--missing, #10B981);
            }
            input:focus {
              border-color: #38BDF8;
              background-color: #1E293B;
            }
            button:disabled {
              background-color: #334155;
              color: #94A3B8;
            }
            @media (min-width: 800px) and (prefers-color-scheme: dark) {
              .responsive { width: 320px; }
            }
            @media (max-width: 400px) {
              .responsive { width: 100px; }
            }
          </style>
        </head>
        <body>
          <div id="bx" class="box responsive">Card</div>
          <input id="inp" type="text" value="hi" />
          <button id="dis-btn" disabled data-click="nope">Locked</button>
        </body>
      </html>
    """
    let docRes = parseHtmlDoc(html)
    doAssert docRes.isOk()
    let doc = docRes.get()
    let sheet = parseCssSheet(doc.embeddedCss, CssMediaContext(viewportWidth: 1200.0f, viewportHeight: 800.0f, prefersDark: true))

    let rootIdx = doc.findById("bx").get()
    let htmlIdx = doc.nodes[0].children[0]
    let bodyIdx = doc.nodes[htmlIdx].children[^1]
    let rootBase = computeNodeStyle(doc, htmlIdx, sheet, defaultRootStyle())
    let bodyBase = computeNodeStyle(doc, bodyIdx, sheet, rootBase)
    let bxStyle = computeNodeStyle(doc, rootIdx, sheet, bodyBase)

    doAssert bxStyle.fgColor == 0x4F46E5FF'u32, "var(--BrandColor) case-sensitive lookup failed"
    doAssert bxStyle.borderColor == 0x10B981FF'u32, "var(--missing, fallback) failed"
    doAssert bxStyle.bgGradient.active and bxStyle.bgGradient.stops.len == 2
    doAssert bxStyle.boxShadows.len == 1 and approxEq(bxStyle.boxShadows[0].blur, 12.0f)
    doAssert approxEq(bxStyle.opacity, 0.5f)
    doAssert bxStyle.fontWeight == 700
    doAssert bxStyle.fontFamily == "\"Inter\", sans-serif"
    doAssert approxEq(bxStyle.lineHeight, 1.5f)
    doAssert bxStyle.cursor == "pointer"
    doAssert bxStyle.textOverflow == "ellipsis"
    doAssert bxStyle.whiteSpace == "nowrap"
    doAssert bxStyle.position == cpRelative
    doAssert bxStyle.zIndexSet and bxStyle.zIndex == 42
    doAssert bxStyle.flexWrap == cfwWrap
    doAssert approxEq(bxStyle.flexShrink, 0.0f)
    doAssert bxStyle.flexBasis.kind == cskPx and approxEq(bxStyle.flexBasis.value, 120.0f)
    doAssert bxStyle.alignSelf == casCenter
    doAssert approxEq(bxStyle.rowGap, 12.0f) and approxEq(bxStyle.columnGap, 20.0f)
    doAssert bxStyle.width.kind == cskPx and approxEq(bxStyle.width.value, 320.0f), "@media min-width failed"

    let inpStyle = computeNodeStyle(doc, doc.findById("inp").get(), sheet, bodyBase)
    doAssert inpStyle.borderFocusColor == 0x38BDF8FF'u32
    doAssert inpStyle.bgFocusColor == 0x1E293BFF'u32

    let disStyle = computeNodeStyle(doc, doc.findById("dis-btn").get(), sheet, bodyBase)
    doAssert disStyle.bgColor == 0x334155FF'u32
    doAssert disStyle.fgColor == 0x94A3B8FF'u32

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()
    var clickedDisabled = false
    bindings.onClick("nope", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        clickedDisabled = true
    )
    doAssert mountHtml(tree, addr rt, doc, sheet, bindings).isOk()
    let disSlab = bindings.getNodeById("dis-btn").get()
    doAssert tree.nodes[disSlab].onClick.isNil, "Disabled button must not attach onClick"
    let bxSlab = bindings.getNodeById("bx").get()
    doAssert (tree.nodes[bxSlab].textColor and 0xFF'u32) == 128'u32, "Opacity 0.5 must modulate alpha"
    echo "  [PASS] 6.1 Extended CSS3 properties, var(), @media, :focus, :disabled & opacity verified."

  testWithLeakCheck("6.2 Margin, Min/Max Constraints & Missing HTML Tags (table/list/select/textarea/img/svg/br/hr)"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()

    let html = """
      <style>
        #wrap { width: 500px; height: 500px; padding: 10px; display: flex; flex-direction: column; row-gap: 6px; }
        #margined { width: 100px; height: 30px; margin: 10px 20px; background: #2563EB; }
        #clamped { width: 100%; max-width: 240px; min-height: 40px; height: 20px; background: #10B981; }
      </style>
      <div id="wrap">
        <div id="margined">Box</div>
        <div id="clamped">Clamped</div>
        <hr id="divider" />
        <br />
        <img id="pic" width="80" height="40" alt="Logo" />
        <svg id="vec" viewBox="0 0 32 32"><circle cx="16" cy="16" r="10" /><path d="M0 0 L10 10" /></svg>
        <ul id="ulist"><li>One</li><li>Two</li></ul>
        <ol id="olist"><li>First</li><li>Second</li></ol>
        <table id="tbl">
          <thead><tr><th>Key</th><th>Val</th></tr></thead>
          <tbody><tr><td>Mode</td><td>Fast</td></tr></tbody>
        </table>
        <select id="sel">
          <option value="a">Alpha</option>
          <option value="b" selected>Beta</option>
        </select>
        <textarea id="ta" rows="3" cols="20" placeholder="Notes">Hello &amp; Nim</textarea>
      </div>
    """
    let mRes = mountHtmlString(tree, addr rt, html, "", bindings)
    doAssert mRes.isOk(), mRes.error()
    tree.layoutTree(800.0f, 600.0f, atlas)

    let mSlab = bindings.getNodeById("margined").get()
    let mr = tree.nodes[mSlab].computedRect
    # wrap padding left=10 + margin-left=20 => x = 30
    doAssert approxEq(mr.x, 30.0f), "Expected margined x=30, got " & $mr.x
    doAssert approxEq(mr.w, 100.0f)

    let cSlab = bindings.getNodeById("clamped").get()
    let cr = tree.nodes[cSlab].computedRect
    doAssert approxEq(cr.w, 240.0f), "Expected max-width clamp 240, got " & $cr.w
    doAssert approxEq(cr.h, 40.0f), "Expected min-height clamp 40, got " & $cr.h

    let vecSlab = bindings.getNodeById("vec").get()
    let vr = tree.nodes[vecSlab].computedRect
    doAssert approxEq(vr.w, 32.0f) and approxEq(vr.h, 32.0f)
    doAssert tree.nodes[vecSlab].children.len == 0

    let selSlab = bindings.getNodeById("sel").get()
    doAssert tree.nodes[selSlab].kind == nkButton
    doAssert tree.nodes[selSlab].text == "Beta ▾"
    tree.nodes[selSlab].onClick()
    doAssert tree.nodes[selSlab].text == "Alpha ▾"

    let taSlab = bindings.getNodeById("ta").get()
    doAssert tree.nodes[taSlab].kind == nkTextInput
    doAssert tree.nodes[taSlab].text == "Hello & Nim"

    # Zero-JS inside <svg> must still be rejected
    doAssert parseHtmlDoc("<svg><script>evil()</script></svg>").isErr()
    echo "  [PASS] 6.2 Margin, min/max constraints & HTML5 tags verified."

proc main() =
  echo "================================================================="
  echo ">>> STARTING PURE-NIM HTML5/CSS3 ENGINE TEST SUITE <<<"
  echo "================================================================="
  let atlas = initFontAtlas("Segoe UI", 16.0f)
  testHtmlParserAndZeroJs()
  testCssCascadeAndColors()
  testMountAndFlexboxLayout(atlas)
  testPureNimReactivity(atlas)
  testRasterizerAndLeakStress(atlas)
  testExtendedCssAndHtmlTags(atlas)
  echo "\n================================================================="
  echo ">>> [SUCCESS] ALL HTML5/CSS3 TESTS PASSED WITH 0 LEAKS! <<<"
  echo "================================================================="

when isMainModule:
  main()
