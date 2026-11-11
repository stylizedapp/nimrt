## apps/mini-browser/src/html.nim
## Level 0 HTML parser for the Nim High-Performance Mini-Browser
##
## Zero-overhead HTML parsing into a flat Node sequence with hierarchical
## parent / firstChild / nextSibling indexing. Node tags and texts are
## zero-copy Spans borrowed from source.

import corex

type
  NodeKind* = enum
    nkElement,
    nkText

  Node* = object
    kind*: NodeKind
    parent*: int32
    firstChild*: int32
    nextSibling*: int32
    tag*: Span[byte]
    text*: Span[byte]

  Document* = object
    nodes*: BufSeq[Node]
    root*: int32
    source*: Span[byte]

  ParseError* = object
    msg*: string
    offset*: int

# =============================================================================
# String & Span Utilities
# =============================================================================

proc `==`*(s: Span[byte], str: string): bool {.inline, raises: [].} =
  if s.len != str.len: return false
  if s.len == 0: return true
  if s.data.isNil: return false
  for i in 0 ..< s.len:
    if s.data[i] != byte(str[i]): return false
  return true

proc `==`*(str: string, s: Span[byte]): bool {.inline, raises: [].} =
  s == str

proc isAllWhitespace(s: Span[byte]): bool {.inline, raises: [].} =
  if s.len == 0: return true
  for i in 0 ..< s.len:
    let b = s.data[i]
    if b != byte(' ') and b != byte('\t') and b != byte('\r') and b != byte('\n'):
      return false
  return true

proc eqIgnoreCase(a: Span[byte], b: Span[byte]): bool {.inline, raises: [].} =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    var c1 = a.data[i]
    var c2 = b.data[i]
    if c1 >= byte('A') and c1 <= byte('Z'):
      c1 = c1 + (byte('a') - byte('A'))
    if c2 >= byte('A') and c2 <= byte('Z'):
      c2 = c2 + (byte('a') - byte('A'))
    if c1 != c2:
      return false
  return true

template isWhitespaceByte(b: byte): bool =
  b == byte(' ') or b == byte('\t') or b == byte('\r') or b == byte('\n')

# =============================================================================
# Parser Implementation
# =============================================================================

proc parseHtml*(source: openArray[byte], alloc: Allocator = defaultHeapAllocator()): Result[Document, ParseError] {.raises: [].} =
  let a = if alloc.allocFn != nil: alloc else: defaultHeapAllocator()
  let sourceSpan = if source.len > 0: span(source) else: Span[byte](data: nil, len: 0)

  if source.len == 0:
    let emptyNodes = initBufSeq[Node](a, 0)
    if emptyNodes.isErr:
      return err[Document, ParseError](ParseError(msg: "Out of memory", offset: 0))
    return ok[Document, ParseError](Document(
      nodes: emptyNodes.get(),
      root: -1,
      source: sourceSpan
    ))

  var nodesRes = initBufSeq[Node](a, 8)
  if nodesRes.isErr:
    return err[Document, ParseError](ParseError(msg: "Out of memory", offset: 0))
  var nodes = nodesRes.get()

  var stack: seq[int32] = @[]
  var root: int32 = -1
  var pos = 0
  let totalLen = source.len

  while pos < totalLen:
    if source[pos] == byte('<'):
      # Check if closing tag </tag>
      if pos + 1 < totalLen and source[pos + 1] == byte('/'):
        let closeStart = pos
        pos += 2 # skip '</'
        while pos < totalLen and isWhitespaceByte(source[pos]):
          inc(pos)
        let tagStart = pos
        while pos < totalLen and source[pos] != byte('>') and not isWhitespaceByte(source[pos]):
          inc(pos)
        let tagEnd = pos
        if tagEnd == tagStart:
          return err[Document, ParseError](ParseError(msg: "Empty closing tag name", offset: closeStart))
        let closeTag = sourceSpan.subspan(tagStart, tagEnd - tagStart)

        while pos < totalLen and source[pos] != byte('>'):
          inc(pos)
        if pos >= totalLen or source[pos] != byte('>'):
          return err[Document, ParseError](ParseError(msg: "Unclosed angle bracket in closing tag", offset: closeStart))
        inc(pos) # skip '>'

        if stack.len == 0:
          return err[Document, ParseError](ParseError(msg: "Unexpected closing tag </" & closeTag.asString() & ">", offset: closeStart))

        let topIdx = stack[^1]
        let openTag = nodes[topIdx].tag
        if not eqIgnoreCase(openTag, closeTag):
          return err[Document, ParseError](ParseError(
            msg: "Mismatched closing tag </" & closeTag.asString() & ">, expected </" & openTag.asString() & ">",
            offset: closeStart
          ))

        discard stack.pop()

      elif pos + 1 < totalLen and source[pos + 1] == byte('!'):
        # Comment or DOCTYPE
        let specialStart = pos
        if pos + 3 < totalLen and source[pos + 2] == byte('-') and source[pos + 3] == byte('-'):
          # Comment <!-- ... -->
          pos += 4
          var closed = false
          while pos + 2 < totalLen:
            if source[pos] == byte('-') and source[pos + 1] == byte('-') and source[pos + 2] == byte('>'):
              pos += 3
              closed = true
              break
            inc(pos)
          if not closed:
            return err[Document, ParseError](ParseError(msg: "Unclosed comment", offset: specialStart))
        else:
          # DOCTYPE or similar <! ... >
          while pos < totalLen and source[pos] != byte('>'):
            inc(pos)
          if pos < totalLen and source[pos] == byte('>'):
            inc(pos)

      else:
        # Opening tag <tag ...>
        let openStart = pos
        inc(pos) # skip '<'
        while pos < totalLen and isWhitespaceByte(source[pos]):
          inc(pos)
        let tagStart = pos
        while pos < totalLen and source[pos] != byte('>') and source[pos] != byte('/') and not isWhitespaceByte(source[pos]):
          inc(pos)
        let tagEnd = pos
        if tagEnd == tagStart:
          return err[Document, ParseError](ParseError(msg: "Empty tag name", offset: openStart))
        let tagSpan = sourceSpan.subspan(tagStart, tagEnd - tagStart)

        # Skip attributes or find self-closing '/>'
        var selfClosing = false
        while pos < totalLen and source[pos] != byte('>'):
          if source[pos] == byte('/') and pos + 1 < totalLen and source[pos + 1] == byte('>'):
            selfClosing = true
            pos += 1
            break
          inc(pos)

        if pos >= totalLen or source[pos] != byte('>'):
          return err[Document, ParseError](ParseError(msg: "Unclosed tag angle bracket", offset: openStart))
        inc(pos) # skip '>'

        let nodeIdx = int32(nodes.len)
        var elemNode = Node(
          kind: nkElement,
          parent: -1,
          firstChild: -1,
          nextSibling: -1,
          tag: tagSpan,
          text: Span[byte](data: nil, len: 0)
        )

        if stack.len > 0:
          let pIdx = stack[^1]
          elemNode.parent = pIdx
          if nodes[pIdx].firstChild == -1:
            nodes[pIdx].firstChild = nodeIdx
          else:
            var lastChild = nodes[pIdx].firstChild
            while nodes[lastChild].nextSibling != -1:
              lastChild = nodes[lastChild].nextSibling
            nodes[lastChild].nextSibling = nodeIdx
        else:
          if root == -1:
            root = nodeIdx

        nodes.add(elemNode)
        if not selfClosing:
          stack.add(nodeIdx)

    else:
      # Text content
      let textStart = pos
      while pos < totalLen and source[pos] != byte('<'):
        inc(pos)
      let textEnd = pos
      let textSpan = sourceSpan.subspan(textStart, textEnd - textStart)

      let wsOnly = isAllWhitespace(textSpan)
      if stack.len == 0:
        if root == -1 and not wsOnly:
          # Root-level text
          var textNode = Node(
            kind: nkText,
            parent: -1,
            firstChild: -1,
            nextSibling: -1,
            tag: Span[byte](data: nil, len: 0),
            text: textSpan
          )
          nodes.add(textNode)
          # root remains -1
      else:
        if not wsOnly:
          let nodeIdx = int32(nodes.len)
          let pIdx = stack[^1]
          var textNode = Node(
            kind: nkText,
            parent: pIdx,
            firstChild: -1,
            nextSibling: -1,
            tag: Span[byte](data: nil, len: 0),
            text: textSpan
          )
          if nodes[pIdx].firstChild == -1:
            nodes[pIdx].firstChild = nodeIdx
          else:
            var lastChild = nodes[pIdx].firstChild
            while nodes[lastChild].nextSibling != -1:
              lastChild = nodes[lastChild].nextSibling
            nodes[lastChild].nextSibling = nodeIdx
          nodes.add(textNode)

  if stack.len > 0:
    let unclosedIdx = stack[^1]
    let unclosedTag = nodes[unclosedIdx].tag
    return err[Document, ParseError](ParseError(
      msg: "Unclosed tag <" & unclosedTag.asString() & ">",
      offset: totalLen
    ))

  return ok[Document, ParseError](Document(
    nodes: nodes,
    root: root,
    source: sourceSpan
  ))

proc parseHtml*(source: openArray[char], alloc: Allocator = defaultHeapAllocator()): Result[Document, ParseError] {.raises: [].} =
  if source.len == 0:
    var empty: array[0, byte]
    parseHtml(empty, alloc)
  else:
    parseHtml(toOpenArray(cast[ptr UncheckedArray[byte]](unsafeAddr source[0]), 0, source.len - 1), alloc)
