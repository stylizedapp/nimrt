## apps/mini-browser/src/layout.nim
## Block layout engine for the Nim High-Performance Mini-Browser
import corex
import ./html
import ./png
import ./css
import ./style

export html
export png
export css
export style

type
  BoxKind* = enum
    bkElement,
    bkText

  Box* = object
    nodeIdx*: int32
    kind*: BoxKind
    x*, y*, w*, h*: float32
    bgColor*: Rgba
    textColor*: Rgba
    textContent*: Span[byte]

  LayoutTree* = object
    boxes*: BufSeq[Box]
    root*: int32

proc rgba*(r, g, b, a: int): Rgba {.inline, raises: [].} =
  png.rgba(uint8(r and 0xFF), uint8(g and 0xFF), uint8(b and 0xFF), uint8(a and 0xFF))

proc rgba*(r, g, b: int): Rgba {.inline, raises: [].} =
  png.rgba(uint8(r and 0xFF), uint8(g and 0xFF), uint8(b and 0xFF), 255'u8)

proc layout*(doc: Document, viewportW, viewportH: int, alloc: Allocator = defaultHeapAllocator(), sheet: StyleSheet = StyleSheet()): LayoutTree {.raises: [].} =
  let a = if alloc.allocFn != nil: alloc else: defaultHeapAllocator()
  if doc.nodes.len == 0:
    var emptyBoxes = initBufSeq[Box](a, 0).get()
    return LayoutTree(boxes: move(emptyBoxes), root: -1)

  var boxesRes = initBufSeq[Box](a, doc.nodes.len)
  var boxes = if boxesRes.isOk: boxesRes.get() else: initBufSeq[Box](a, 0).get()
  var curY: float32 = 0.0f32
  let defaultW = float32(viewportW)

  # 1. Resolve computed styles for all nodes with inheritance
  var nodeStyles = newSeq[ComputedStyle](doc.nodes.len)
  for i in 0 ..< doc.nodes.len:
    let node = doc.nodes[i]
    let parentOpt = if node.parent >= 0 and node.parent < i:
      some(nodeStyles[node.parent])
    else:
      none(ComputedStyle)
    nodeStyles[i] = resolveStyle(node, sheet, parentOpt)

  # 2. Build layout boxes (skipping display: none)
  for i in 0 ..< doc.nodes.len:
    let style = nodeStyles[i]
    if style.display == dkNone:
      # display: none -> do not create box
      continue

    let node = doc.nodes[i]
    case node.kind
    of nkElement:
      let h = if style.height.isSome: style.height.get() else: 24.0f32
      let w = if style.width.isSome: style.width.get() else: defaultW
      boxes.add(Box(
        nodeIdx: int32(i),
        kind: bkElement,
        x: 0.0f32,
        y: curY,
        w: w,
        h: h,
        bgColor: style.backgroundColor,
        textColor: style.color,
        textContent: span[byte]()
      ))
      curY += h
    of nkText:
      let h = if style.height.isSome: style.height.get() else: 16.0f32
      let w = if style.width.isSome: style.width.get() else: defaultW
      boxes.add(Box(
        nodeIdx: int32(i),
        kind: bkText,
        x: 0.0f32,
        y: curY,
        w: w,
        h: h,
        bgColor: style.backgroundColor,
        textColor: style.color,
        textContent: node.text
      ))
      curY += h

  LayoutTree(
    boxes: move(boxes),
    root: doc.root
  )
