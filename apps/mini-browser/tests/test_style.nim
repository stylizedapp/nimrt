## apps/mini-browser/tests/test_style.nim
## Comprehensive unit tests for Style resolution & CSS value parsing (15+ tests)
import corex/[testing, allocators, memory, result, containers, adt]
import ../src/[png, html, css, style]

testWithLeakCheck("S01: parseColor named colors"):
  assert parseColor("red").unwrap() == rgba(255'u8, 0'u8, 0'u8, 255'u8)
  assert parseColor("blue").unwrap() == rgba(0'u8, 0'u8, 255'u8, 255'u8)
  assert parseColor("green").unwrap() == rgba(0'u8, 128'u8, 0'u8, 255'u8)
  assert parseColor("white").unwrap() == rgba(255'u8, 255'u8, 255'u8, 255'u8)
  assert parseColor("black").unwrap() == rgba(0'u8, 0'u8, 0'u8, 255'u8)
  assert parseColor("transparent").unwrap() == rgba(0'u8, 0'u8, 0'u8, 0'u8)

testWithLeakCheck("S02: parseColor 3-digit hex"):
  assert parseColor("#f00").unwrap() == rgba(255'u8, 0'u8, 0'u8, 255'u8)
  assert parseColor("#0f0").unwrap() == rgba(0'u8, 255'u8, 0'u8, 255'u8)
  assert parseColor("#00f").unwrap() == rgba(0'u8, 0'u8, 255'u8, 255'u8)
  assert parseColor("#fff").unwrap() == rgba(255'u8, 255'u8, 255'u8, 255'u8)

testWithLeakCheck("S03: parseColor 6-digit hex"):
  assert parseColor("#ff0000").unwrap() == rgba(255'u8, 0'u8, 0'u8, 255'u8)
  assert parseColor("#ffffff").unwrap() == rgba(255'u8, 255'u8, 255'u8, 255'u8)
  assert parseColor("#123456").unwrap() == rgba(0x12'u8, 0x34'u8, 0x56'u8, 255'u8)

testWithLeakCheck("S04: parseColor 8-digit hex with alpha"):
  assert parseColor("#ff000080").unwrap() == rgba(255'u8, 0'u8, 0'u8, 128'u8)

testWithLeakCheck("S05: parseColor invalid errors"):
  assert parseColor("not-a-color").isErr
  assert parseColor("#xyz").isErr
  assert parseColor("#12").isErr
  assert parseColor("").isErr

testWithLeakCheck("S06: parseLength valid px and zero"):
  assert parseLength("24px").unwrap() == 24.0f32
  assert parseLength("100px").unwrap() == 100.0f32
  assert parseLength("16.5px").unwrap() == 16.5f32
  assert parseLength("0").unwrap() == 0.0f32
  assert parseLength("0px").unwrap() == 0.0f32

testWithLeakCheck("S07: parseLength invalid errors"):
  assert parseLength("abc").isErr
  assert parseLength("").isErr

testWithLeakCheck("S08: parseDisplay values"):
  assert parseDisplay("none").unwrap() == dkNone
  assert parseDisplay("block").unwrap() == dkBlock
  assert parseDisplay("inline").unwrap() == dkInline
  assert parseDisplay("NONE").unwrap() == dkNone

testWithLeakCheck("S09: parseDisplay invalid errors"):
  assert parseDisplay("flex").isErr
  assert parseDisplay("grid").isErr
  assert parseDisplay("").isErr

testWithLeakCheck("S10: default element style without css"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  let emptySheet = parseCss("", testAlloc).unwrap()
  let style = resolveStyle(elem, emptySheet)
  assert style.display == dkBlock
  assert style.color == rgba(0'u8, 0'u8, 0'u8, 255'u8)
  assert style.backgroundColor == rgba(200'u8, 200'u8, 200'u8, 255'u8)

testWithLeakCheck("S11: single rule styling"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  let sheet = parseCss("h1 { color: #ff0000; background-color: #ffffff; height: 50px }", testAlloc).unwrap()
  let style = resolveStyle(elem, sheet)
  assert style.color == rgba(255'u8, 0'u8, 0'u8, 255'u8)
  assert style.backgroundColor == rgba(255'u8, 255'u8, 255'u8, 255'u8)
  assert style.height == some(50.0f32)

testWithLeakCheck("S12: last-wins within same rule"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  let sheet = parseCss("h1 { color: red; color: blue; }", testAlloc).unwrap()
  let style = resolveStyle(elem, sheet)
  assert style.color == rgba(0'u8, 0'u8, 255'u8, 255'u8)

testWithLeakCheck("S13: last-wins across cascading rules"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  let sheet = parseCss("h1 { color: red } h1 { color: green }", testAlloc).unwrap()
  let style = resolveStyle(elem, sheet)
  assert style.color == rgba(0'u8, 128'u8, 0'u8, 255'u8)

testWithLeakCheck("S14: display none on element"):
  let doc = parseHtml("<div>Hidden</div>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  let sheet = parseCss("div { display: none }", testAlloc).unwrap()
  let style = resolveStyle(elem, sheet)
  assert style.display == dkNone

testWithLeakCheck("S15: text node inherits parent color"):
  let doc = parseHtml("<h1>Hello</h1>", testAlloc).unwrap()
  let h1 = doc.nodes[doc.root]
  let sheet = parseCss("h1 { color: red }", testAlloc).unwrap()
  let h1Style = resolveStyle(h1, sheet)
  assert h1Style.color == rgba(255'u8, 0'u8, 0'u8, 255'u8)

  let textNode = doc.nodes[h1.firstChild]
  let textStyle = resolveStyle(textNode, sheet, some(h1Style))
  assert textStyle.color == rgba(255'u8, 0'u8, 0'u8, 255'u8)

testWithLeakCheck("S16: text node inherits display none"):
  let doc = parseHtml("<div>Hidden</div>", testAlloc).unwrap()
  let divNode = doc.nodes[doc.root]
  let sheet = parseCss("div { display: none }", testAlloc).unwrap()
  let divStyle = resolveStyle(divNode, sheet)
  assert divStyle.display == dkNone

  let textNode = doc.nodes[divNode.firstChild]
  let textStyle = resolveStyle(textNode, sheet, some(divStyle))
  assert textStyle.display == dkNone

echo "[PASS] test_style: all 16 style resolution tests passed"
