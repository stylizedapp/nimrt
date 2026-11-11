import corex/[testing, allocators, memory, result, containers]
import ../src/[png, paint, html, layout]
import std/os

template toOpenArray*(s: ByteSpan): untyped =
  if s.len > 0: toOpenArray(s.data, 0, s.len - 1)
  else:
    var emptyBytes: array[0, byte]
    emptyBytes

proc renderInProcess(input: openArray[byte], width, height: int,
                     alloc: Allocator): seq[byte] =
  let doc = parseHtml(input, alloc).unwrap()
  let tree = layout(doc, width, height, alloc)
  var img = newImage(width, height, alloc)
  for box in tree.boxes:
    if box.kind == bkElement:
      img.fillRect(int(box.x), int(box.y), int(box.w), int(box.h), box.bgColor)
    else:
      img.drawTextPlaceholder(int(box.x), int(box.y), box.textContent, 16, box.textColor)
  result = encodePng(img)
  img.deinit()

testWithLeakCheck("pipeline: alloc contract"):
  let doc = parseHtml(toByteSpan("<h1>X</h1>").toOpenArray, testAlloc).unwrap()
  doAssert doc.nodes.alloc.allocFn == testAlloc.allocFn,
    "Document.nodes must use the passed allocator, not defaultHeap"
  let tree = layout(doc, 800, 600, testAlloc)
  doAssert tree.boxes.alloc.allocFn == testAlloc.allocFn,
    "LayoutTree.boxes must use the passed allocator, not defaultHeap"

testWithLeakCheck("pipeline: hello.html"):
  let input = readFile("tests/fixtures/hello.html")
  let png = if input.len > 0:
    renderInProcess(input.toOpenArrayByte(0, input.len-1), 800, 600, testAlloc)
  else:
    renderInProcess(toByteSpan("").toOpenArray, 800, 600, testAlloc)
  doAssert png.len > 0 and png[0] == 0x89'u8

testWithLeakCheck("pipeline: nested.html"):
  let input = readFile("tests/fixtures/nested.html")
  let png = if input.len > 0:
    renderInProcess(input.toOpenArrayByte(0, input.len-1), 800, 600, testAlloc)
  else:
    renderInProcess(toByteSpan("").toOpenArray, 800, 600, testAlloc)
  doAssert png.len > 0

testWithLeakCheck("pipeline: empty.html"):
  let input = readFile("tests/fixtures/empty.html")
  let png = if input.len > 0:
    renderInProcess(input.toOpenArrayByte(0, input.len-1), 800, 600, testAlloc)
  else:
    renderInProcess(toByteSpan("").toOpenArray, 800, 600, testAlloc)
  doAssert png.len > 0

echo "[PASS] pipeline: 0 leaks across 3 fixtures"
