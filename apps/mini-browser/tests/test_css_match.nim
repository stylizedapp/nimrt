## apps/mini-browser/tests/test_css_match.nim
## Unit tests for CSS Selector Matching (10+ tests)
import corex/[testing, allocators, memory, result, containers]
import ../src/[html, css, css_match]

testWithLeakCheck("M01: exact type selector match"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert matches(elem, "h1")

testWithLeakCheck("M02: case-insensitive selector"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert matches(elem, "H1")
  assert matches(elem, "h1")

testWithLeakCheck("M03: uppercase tag matches lowercase selector"):
  let doc = parseHtml("<DIV>Content</DIV>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert matches(elem, "div")
  assert matches(elem, "DIV")

testWithLeakCheck("M04: different tag does not match"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert not matches(elem, "h2")
  assert not matches(elem, "p")
  assert not matches(elem, "body")

testWithLeakCheck("M05: text node never matches element selector"):
  let doc = parseHtml("<h1>Hello</h1>", testAlloc).unwrap()
  let textNode = doc.nodes[doc.nodes[doc.root].firstChild]
  assert textNode.kind == nkText
  assert not matches(textNode, "h1")
  assert not matches(textNode, "Hello")

testWithLeakCheck("M06: class selector (.foo) does not match"):
  let doc = parseHtml("<div class=\"foo\">Text</div>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert not matches(elem, ".foo")
  assert not matches(elem, ".bar")

testWithLeakCheck("M07: id selector (#bar) does not match"):
  let doc = parseHtml("<div id=\"bar\">Text</div>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert not matches(elem, "#bar")
  assert not matches(elem, "#title")

testWithLeakCheck("M08: body and paragraph match"):
  let doc = parseHtml("<body><p>Text</p></body>", testAlloc).unwrap()
  let bodyNode = doc.nodes[doc.root]
  let pNode = doc.nodes[bodyNode.firstChild]
  assert matches(bodyNode, "body")
  assert not matches(bodyNode, "p")
  assert matches(pNode, "p")
  assert not matches(pNode, "body")

testWithLeakCheck("M09: empty selector does not match"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert not matches(elem, "")

testWithLeakCheck("M10: match via Rule object"):
  let doc = parseHtml("<h1>Title</h1>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  let sheet = parseCss("h1 { color: red } p { color: blue }", testAlloc).unwrap()
  assert matches(elem, sheet.rules[0])
  assert not matches(elem, sheet.rules[1])

testWithLeakCheck("M11: partial name does not match"):
  let doc = parseHtml("<header>Nav</header>", testAlloc).unwrap()
  let elem = doc.nodes[doc.root]
  assert not matches(elem, "head")
  assert not matches(elem, "h")
  assert matches(elem, "header")

testWithLeakCheck("M12: root-level text node"):
  let doc = parseHtml("Just plain text", testAlloc).unwrap()
  assert doc.nodes.len == 1
  let textNode = doc.nodes[0]
  assert not matches(textNode, "div")
  assert not matches(textNode, "p")

echo "[PASS] test_css_match: all 12 selector matching tests passed"
