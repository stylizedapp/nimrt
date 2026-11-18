## tests/test_nimui_manifest_golden.nim — HTML/CSS Compatibility Manifest, Unsupported Errors & Golden Tests

import std/strutils
import corex
import nimui/gpu/font_atlas
import nimui/layout
import nimui/html_css

proc main() =
  echo "================================================================="
  echo ">>> STARTING HTML/CSS MANIFEST & GOLDEN TEST SUITE <<<"
  echo "================================================================="

  let atlas = initFontAtlas("Segoe UI", 16.0f)

  testWithLeakCheck("1. Machine-Readable Manifest Matches Checked-In JSON"):
    let generated = buildHtmlCssManifestJson()
    let onDisk = readFile("docs/html_css_manifest.json")
    doAssert generated == onDisk, "docs/html_css_manifest.json is out of sync with buildHtmlCssManifestJson()"
    doAssert "\"tags\"" in onDisk
    doAssert "\"attributes\"" in onDisk
    doAssert "\"selectors\"" in onDisk
    doAssert "\"properties\"" in onDisk
    doAssert "\"events\"" in onDisk
    doAssert "\"limits\"" in onDisk
    doAssert "\"parsedOnly\"" in onDisk
    echo "  [PASS] 1. Machine-readable manifest verified."

  testWithLeakCheck("2. Supported vs Parsed-Only vs Unsupported Separation"):
    doAssert classifyTag("div") == fslSupported
    doAssert classifyTag("button") == fslSupported
    doAssert classifyTag("table") == fslParsedOnly
    doAssert classifyTag("meta") == fslParsedOnly
    doAssert classifyTag("canvas") == fslUnsupported
    doAssert classifyTag("svg") == fslUnsupported

    doAssert classifyCssProperty("flex-direction") == fslSupported
    doAssert classifyCssProperty("padding-left") == fslSupported
    doAssert classifyCssProperty("position") == fslParsedOnly
    doAssert classifyCssProperty("transition") == fslParsedOnly
    doAssert classifyCssProperty("display:grid") == fslUnsupported
    doAssert classifyCssProperty("grid-template-columns") == fslUnsupported

    doAssert classifyCssSelector(".card:hover") == fslSupported
    doAssert classifyCssSelector(":has(.active)") == fslUnsupported
    echo "  [PASS] 2. Supported vs parsed-only vs unsupported classification verified."

  testWithLeakCheck("3. Clear Unsupported Errors (CSS Grid, :has(), <canvas>)"):
    let htmlRes = parseHtmlDoc("<div><canvas id='c'></canvas></div>")
    doAssert htmlRes.isOk
    let css = parseCssSheet("""
      .box { display: grid; grid-template-columns: 1fr 1fr; }
      .card:has(.title) { color: #ffffff; }
    """)
    let valRes = validateHtmlCssCompatibility(htmlRes.val, css, ucpWarnOnce)
    doAssert valRes.isErr
    let errs = valRes.error.join("\n")
    doAssert "<canvas>" in errs
    doAssert "CSS Grid" in errs
    doAssert ":has()" in errs
    echo "  [PASS] 3. Clear unsupported errors verified."

  testWithLeakCheck("4. UnknownCssPolicy (Ignore / WarnOnce / Error)"):
    let htmlRes = parseHtmlDoc("<div class='x'>Hello</div>")
    doAssert htmlRes.isOk
    let css = parseCssSheet(".x { color: #ffffff; backdrop-filter: blur(8px); backdrop-filter: blur(4px); }")
    doAssert css.unsupportedProperties.len == 1
    doAssert css.unsupportedProperties[0] == "backdrop-filter"

    doAssert validateHtmlCssCompatibility(htmlRes.val, css, ucpIgnore).isOk
    doAssert validateHtmlCssCompatibility(htmlRes.val, css, ucpWarnOnce).isOk
    let errRes = validateHtmlCssCompatibility(htmlRes.val, css, ucpError)
    doAssert errRes.isErr
    doAssert "backdrop-filter" in errRes.error[0]
    echo "  [PASS] 4. UnknownCssPolicy verified."

  testWithLeakCheck("5. Golden HTML+CSS -> UiTree Snapshot"):
    let html = """
      <div class="row">
        <div class="left">Left</div>
        <div class="right">Right</div>
      </div>
    """
    let css = """
      .row { display: flex; flex-direction: row; width: 400px; height: 100px; padding: 10px; gap: 20px; }
      .left { width: 100px; height: 80px; }
      .right { flex-grow: 1; height: 80px; }
    """
    let docRes = parseHtmlDoc(html)
    doAssert docRes.isOk
    let sheet = parseCssSheet(css)
    doAssert validateHtmlCssCompatibility(docRes.val, sheet, ucpError).isOk

    var rt = initReactiveRuntime()
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let mountRes = mountHtml(tree, addr rt, docRes.val, sheet, bindings)
    doAssert mountRes.isOk
    tree.layoutTree(400.0f, 100.0f, atlas)

    let snap = snapshotUiTree(tree)
    doAssert "nkBox rect=(0.00,0.00,400.00,100.00)" in snap
    doAssert "text=\"Left\"" in snap
    doAssert "text=\"Right\"" in snap
    let snap2 = snapshotUiTree(tree)
    doAssert snap == snap2
    echo "  [PASS] 5. Golden HTML+CSS -> UiTree snapshot verified with 0 leaks."

  echo "================================================================="
  echo ">>> [SUCCESS] ALL MANIFEST & GOLDEN TESTS PASSED WITH 0 LEAKS! <<<"
  echo "================================================================="

when isMainModule:
  main()
