## apps/mini-browser/tests/test_layout.nim
## Tests for Block Layout Engine (including Day 2 CSS & display: none)

import corex
import html
import layout
import css

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc test1() =
  # 1. Element boxes
  let input = toBytes("<h1>Hello</h1>")
  let parseRes = parseHtml(input, defaultHeapAllocator())
  doAssert parseRes.isOk, "Failed to parse HTML"
  let doc = parseRes.get()

  let tree = layout(doc, 800, 600, defaultHeapAllocator())
  doAssert tree.boxes.len == 2, "Expected 2 boxes, got " & $tree.boxes.len
  doAssert tree.root == 0, "Expected root to be 0"

  let elemBox = tree.boxes[0]
  doAssert elemBox.kind == bkElement, "Expected box 0 to be bkElement"
  doAssert elemBox.nodeIdx == 0, "Expected nodeIdx 0"
  doAssert elemBox.x == 0.0f32, "Expected x=0"
  doAssert elemBox.y == 0.0f32, "Expected y=0"
  doAssert elemBox.w == 800.0f32, "Expected w=800"
  doAssert elemBox.h == 24.0f32, "Expected h=24"
  doAssert elemBox.bgColor == rgba(200, 200, 200, 255), "Expected bgColor=rgba(200,200,200,255)"

  let textBox = tree.boxes[1]
  doAssert textBox.kind == bkText, "Expected box 1 to be bkText"
  doAssert textBox.nodeIdx == 1, "Expected nodeIdx 1"
  doAssert textBox.x == 0.0f32, "Expected x=0"
  doAssert textBox.y == 24.0f32, "Expected y=24"
  doAssert textBox.w == 800.0f32, "Expected w=800"
  doAssert textBox.h == 16.0f32, "Expected h=16"
  doAssert textBox.textColor == rgba(0, 0, 0, 255), "Expected textColor=rgba(0,0,0,255)"
  doAssert textBox.textContent == "Hello", "Expected textContent 'Hello'"

  echo "[PASS] Test 1: element boxes layout correctly"

proc test2() =
  # 2. Text boxes
  let input = toBytes("Plain text only")
  let parseRes = parseHtml(input, defaultHeapAllocator())
  doAssert parseRes.isOk, "Failed to parse HTML"
  let doc = parseRes.get()

  let tree = layout(doc, 1024, 768, defaultHeapAllocator())
  doAssert tree.boxes.len == 1, "Expected 1 box, got " & $tree.boxes.len
  let textBox = tree.boxes[0]
  doAssert textBox.kind == bkText, "Expected bkText"
  doAssert textBox.nodeIdx == 0, "Expected nodeIdx 0"
  doAssert textBox.x == 0.0f32, "Expected x=0"
  doAssert textBox.y == 0.0f32, "Expected y=0"
  doAssert textBox.w == 1024.0f32, "Expected w=1024"
  doAssert textBox.h == 16.0f32, "Expected h=16"
  doAssert textBox.textColor == rgba(0, 0, 0, 255), "Expected textColor=rgba(0,0,0,255)"
  doAssert textBox.textContent == "Plain text only", "Expected textContent 'Plain text only'"

  echo "[PASS] Test 2: text boxes layout correctly"

proc test3() =
  # 3. Empty doc
  var input: seq[byte] = @[]
  let parseRes = parseHtml(input, defaultHeapAllocator())
  doAssert parseRes.isOk, "Failed to parse empty HTML"
  let doc = parseRes.get()

  let tree = layout(doc, 800, 600, defaultHeapAllocator())
  doAssert tree.boxes.len == 0, "Expected 0 boxes, got " & $tree.boxes.len
  doAssert tree.root == -1, "Expected root to be -1"

  echo "[PASS] Test 3: empty doc layout correctly"

proc test4() =
  # 4. display: none does NOT create boxes
  let input = toBytes("<div>Hidden</div><h1>Visible</h1>")
  let doc = parseHtml(input, defaultHeapAllocator()).unwrap()
  let sheet = parseCss("div { display: none }", defaultHeapAllocator()).unwrap()

  let tree = layout(doc, 800, 600, defaultHeapAllocator(), sheet)
  # div and its text "Hidden" must NOT create boxes!
  # only h1 and its text "Visible" should create boxes (2 boxes total)
  doAssert tree.boxes.len == 2, "Expected exactly 2 boxes for h1 and text, got: " & $tree.boxes.len
  doAssert tree.boxes[0].kind == bkElement
  doAssert tree.boxes[0].y == 0.0f32
  doAssert tree.boxes[1].kind == bkText
  doAssert tree.boxes[1].textContent == "Visible"
  doAssert tree.boxes[1].y == 24.0f32

  echo "[PASS] Test 4: display: none does not create box"

proc test5() =
  # 5. Custom height and color from CSS
  let input = toBytes("<h1>Styled</h1>")
  let doc = parseHtml(input, defaultHeapAllocator()).unwrap()
  let sheet = parseCss("h1 { color: #ff0000; background-color: #ffffff; height: 50px }", defaultHeapAllocator()).unwrap()

  let tree = layout(doc, 800, 600, defaultHeapAllocator(), sheet)
  doAssert tree.boxes.len == 2
  let h1Box = tree.boxes[0]
  doAssert h1Box.h == 50.0f32, "Expected h=50, got: " & $h1Box.h
  doAssert h1Box.bgColor == png.rgba(255'u8, 255'u8, 255'u8, 255'u8), "Expected white bgColor"

  let textBox = tree.boxes[1]
  doAssert textBox.y == 50.0f32, "Expected text y=50 following h1 h=50"
  doAssert textBox.textColor == png.rgba(255'u8, 0'u8, 0'u8, 255'u8), "Expected red textColor"

  echo "[PASS] Test 5: custom height and color from CSS layout correctly"

proc main() =
  echo "=== Running Layout Tests ==="
  test1()
  test2()
  test3()
  test4()
  test5()
  echo "All 5/5 layout tests passed."

when isMainModule:
  main()
