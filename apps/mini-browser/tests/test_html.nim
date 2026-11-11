## apps/mini-browser/tests/test_html.nim
## Tests for Level 0 HTML Parser

import corex
import html

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc test1() =
  # 1. <h1>Hello</h1> -> root=h1, 1 child text 'Hello'
  let input = toBytes("<h1>Hello</h1>")
  let res = parseHtml(input, defaultHeapAllocator())
  doAssert res.isOk, "Test 1 failed to parse"
  let doc = res.get()
  doAssert doc.root == 0, "Expected root to be 0"
  doAssert doc.nodes.len == 2, "Expected 2 nodes, got " & $doc.nodes.len
  let h1 = doc.nodes[doc.root]
  doAssert h1.kind == nkElement, "Expected root to be nkElement"
  doAssert h1.tag == "h1", "Expected root tag 'h1', got: " & h1.tag.asString()
  doAssert h1.parent == -1, "Expected h1 parent to be -1"
  doAssert h1.firstChild == 1, "Expected h1 firstChild to be 1"
  doAssert h1.nextSibling == -1, "Expected h1 nextSibling to be -1"
  
  let txt = doc.nodes[h1.firstChild]
  doAssert txt.kind == nkText, "Expected child to be nkText"
  doAssert txt.text == "Hello", "Expected text 'Hello', got: " & txt.text.asString()
  doAssert txt.parent == 0, "Expected txt parent to be 0"
  doAssert txt.firstChild == -1, "Expected txt firstChild to be -1"
  doAssert txt.nextSibling == -1, "Expected txt nextSibling to be -1"
  echo "[PASS] Test 1: <h1>Hello</h1> -> root=h1, 1 child text 'Hello'"

proc test2() =
  # 2. <html><body><h1>X</h1></body></html> -> 4 nodes or 5 with text 'X', root=html
  let input = toBytes("<html><body><h1>X</h1></body></html>")
  let res = parseHtml(input, defaultHeapAllocator())
  doAssert res.isOk, "Test 2 failed to parse"
  let doc = res.get()
  doAssert doc.root == 0, "Expected root to be 0"
  doAssert doc.nodes.len == 4 or doc.nodes.len == 5, "Expected 4 or 5 nodes, got " & $doc.nodes.len
  let htmlNode = doc.nodes[doc.root]
  doAssert htmlNode.kind == nkElement, "Expected root to be nkElement"
  doAssert htmlNode.tag == "html", "Expected root tag 'html', got: " & htmlNode.tag.asString()

  var foundX = false
  for i in 0 ..< doc.nodes.len:
    if doc.nodes[i].kind == nkText and doc.nodes[i].text == "X":
      foundX = true
      break
  doAssert foundX, "Expected to find text 'X' among nodes"
  echo "[PASS] Test 2: <html><body><h1>X</h1></body></html> -> 4 nodes or 5 with text 'X', root=html"

proc test3() =
  # 3. 'Hello' (only text) -> root=-1, 1 text node
  let input = toBytes("Hello")
  let res = parseHtml(input, defaultHeapAllocator())
  doAssert res.isOk, "Test 3 failed to parse"
  let doc = res.get()
  doAssert doc.root == -1, "Expected root to be -1, got " & $doc.root
  doAssert doc.nodes.len == 1, "Expected 1 node, got " & $doc.nodes.len
  let node = doc.nodes[0]
  doAssert node.kind == nkText, "Expected node to be nkText"
  doAssert node.text == "Hello", "Expected text 'Hello', got: " & node.text.asString()
  doAssert node.parent == -1, "Expected parent to be -1"
  echo "[PASS] Test 3: 'Hello' (only text) -> root=-1, 1 text node"

proc test4() =
  # 4. </foo> without <foo> -> Err
  let input = toBytes("</foo>")
  let res = parseHtml(input, defaultHeapAllocator())
  doAssert res.isErr, "Test 4 expected Err, got Ok"
  let err = res.errVal
  doAssert err.msg.len > 0, "Expected non-empty error message"
  echo "[PASS] Test 4: </foo> without <foo> -> Err"

proc test5() =
  # 5. <h1>Unclosed -> Err
  let input = toBytes("<h1>Unclosed")
  let res = parseHtml(input, defaultHeapAllocator())
  doAssert res.isErr, "Test 5 expected Err, got Ok"
  let err = res.errVal
  doAssert err.msg.len > 0, "Expected non-empty error message"
  echo "[PASS] Test 5: <h1>Unclosed -> Err"

proc test6() =
  # 6. empty input -> root=-1, nodes.len=0
  var input: seq[byte] = @[]
  let res = parseHtml(input, defaultHeapAllocator())
  doAssert res.isOk, "Test 6 failed to parse"
  let doc = res.get()
  doAssert doc.root == -1, "Expected root to be -1, got " & $doc.root
  doAssert doc.nodes.len == 0, "Expected 0 nodes, got " & $doc.nodes.len
  echo "[PASS] Test 6: empty input -> root=-1, nodes.len=0"

proc main() =
  echo "=== Running HTML Parser Tests ==="
  test1()
  test2()
  test3()
  test4()
  test5()
  test6()
  echo "=== ALL 6 HTML PARSER TESTS PASSED ==="

when isMainModule:
  main()
