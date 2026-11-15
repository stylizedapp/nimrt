# Pure-Nim HTML5 + CSS3 Engine (Zero-JS) for NimUI
#
# Preserves Safety (Result/Option, {.raises: [].}, 0 leaks under ORC),
# Explicitness (no hidden global JS runtime; pure Nim binding registry),
# and Simplicity (declarative HTML5 + CSS3 mounted directly onto UiTree).

import corex/unicode
import corex/adt
import corex/result
import corex/slab
import corex/smallvec
import corex/signals
import algx/swissmap
import ./layout
import ./dsl

type
  HtmlNodeKind* = enum
    hnkDocument
    hnkElement
    hnkText

  HtmlAttr* = object
    name*: string
    value*: string

  HtmlNode* = object
    kind*: HtmlNodeKind
    tag*: string
    id*: string
    classes*: seq[string]
    attrs*: seq[HtmlAttr]
    text*: string
    parent*: int
    children*: seq[int]

  HtmlDoc* = object
    nodes*: seq[HtmlNode]
    embeddedCss*: string

  CssPseudoKind* = enum
    cpkNone
    cpkHover
    cpkActive

  CssSimpleSelector* = object
    isUniversal*: bool
    tag*: string
    id*: string
    classes*: seq[string]
    pseudo*: CssPseudoKind

  CssSelector* = object
    parts*: seq[CssSimpleSelector]
    directChild*: seq[bool]
    specificity*: int

  CssDeclaration* = object
    prop*: string
    value*: string

  CssRule* = object
    selector*: CssSelector
    declarations*: seq[CssDeclaration]
    order*: int

  CssStylesheet* = object
    rules*: seq[CssRule]

  CssDisplay* = enum
    cdBlock
    cdFlex
    cdInline
    cdNone

  CssSizeKind* = enum
    cskAuto
    cskPx
    cskPercent
    cskFlexGrow

  CssSize* = object
    kind*: CssSizeKind
    value*: float32

  CssComputedStyle* = object
    display*: CssDisplay
    flexDirection*: FlexDirection
    flexDirectionSet*: bool
    justifyContent*: JustifyContent
    alignItems*: AlignItems
    alignItemsSet*: bool
    width*: CssSize
    height*: CssSize
    flexGrow*: float32
    hasFlexGrow*: bool
    padding*: array[4, float32]
    paddingSet*: array[4, bool]
    gap*: float32
    fgColor*: uint32
    fgColorSet*: bool
    bgColor*: uint32
    bgHoverColor*: uint32
    bgActiveColor*: uint32
    borderColor*: uint32
    borderHoverColor*: uint32
    borderWidth*: float32
    borderRadius*: float32
    fontSize*: float32
    fontSizeSet*: bool
    overflowY*: bool

  HtmlClickProc* = proc() {.closure, gcsafe, raises: [].}
  HtmlInputProc* = proc(text: string) {.closure, gcsafe, raises: [].}
  HtmlTextProc* = proc(): string {.closure, gcsafe, raises: [].}

  HtmlBindingRegistry* = object
    clickHandlers*: FastMap[string, HtmlClickProc]
    inputHandlers*: FastMap[string, HtmlInputProc]
    textSignals*: FastMap[string, Signal[string]]
    textProcs*: FastMap[string, HtmlTextProc]
    inputSignals*: FastMap[string, Signal[string]]
    idToSlab*: FastMap[string, SlabId]

const
  HtmlVoidTags = [
    "area", "base", "br", "col", "embed", "hr", "img",
    "input", "link", "meta", "param", "source", "track", "wbr"
  ]
  HtmlSkipMountTags = ["head", "style", "meta", "link", "title"]

# =============================================================================
# Exception-Free ASCII, String & Number Helpers ({.raises: [].})
# =============================================================================

proc isSpaceChar(c: char): bool {.inline, raises: [].} =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f' or c == '\v'

proc isAlphaAscii(c: char): bool {.inline, raises: [].} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc isDigitAscii(c: char): bool {.inline, raises: [].} =
  c >= '0' and c <= '9'

proc isHexDigitAscii(c: char): bool {.inline, raises: [].} =
  (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

proc toLowerChar(c: char): char {.inline, raises: [].} =
  if c >= 'A' and c <= 'Z':
    char(ord(c) + 32)
  else:
    c

proc toLowerAscii(s: string): string {.raises: [].} =
  result = newString(s.len)
  for i in 0 ..< s.len:
    result[i] = toLowerChar(s[i])

proc stripAscii(s: string): string {.raises: [].} =
  var i = 0
  var j = s.len - 1
  while i <= j and isSpaceChar(s[i]):
    inc i
  while j >= i and isSpaceChar(s[j]):
    dec j
  if i > j:
    return ""
  result = s[i .. j]

proc startsWithAscii(s, prefix: string): bool {.inline, raises: [].} =
  if prefix.len > s.len:
    return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]:
      return false
  true

proc startsWithIgnoreCase(s, prefix: string; offset = 0): bool {.inline, raises: [].} =
  if offset < 0 or offset + prefix.len > s.len:
    return false
  for i in 0 ..< prefix.len:
    if toLowerChar(s[offset + i]) != toLowerChar(prefix[i]):
      return false
  true

proc eqIgnoreCase(a, b: string): bool {.inline, raises: [].} =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if toLowerChar(a[i]) != toLowerChar(b[i]):
      return false
  true

proc containsTag(list: openArray[string], tag: string): bool {.inline, raises: [].} =
  for item in list:
    if item == tag:
      return true
  false

proc splitWhitespace(s: string): seq[string] {.raises: [].} =
  result = @[]
  var i = 0
  while i < s.len:
    while i < s.len and isSpaceChar(s[i]):
      inc i
    if i >= s.len:
      break
    let start = i
    while i < s.len and not isSpaceChar(s[i]):
      inc i
    result.add(s[start ..< i])

proc collapseHtmlWhitespace(s: string): string {.raises: [].} =
  result = newStringOfCap(s.len)
  var inSpace = false
  for i in 0 ..< s.len:
    let c = s[i]
    if isSpaceChar(c):
      if not inSpace:
        result.add(' ')
        inSpace = true
    else:
      result.add(c)
      inSpace = false

proc parseIntSafe(s: string): Option[int] {.raises: [].} =
  let t = stripAscii(s)
  if t.len == 0:
    return none[int]()
  var idx = 0
  var neg = false
  if t[idx] == '-':
    neg = true
    inc idx
  elif t[idx] == '+':
    inc idx
  if idx >= t.len:
    return none[int]()
  var acc = 0
  while idx < t.len:
    let c = t[idx]
    if not isDigitAscii(c):
      return none[int]()
    let d = ord(c) - ord('0')
    if acc > (high(int) - d) div 10:
      return none[int]()
    acc = acc * 10 + d
    inc idx
  if neg:
    some(-acc)
  else:
    some(acc)

proc parseHexUintSafe(s: string): Option[uint32] {.raises: [].} =
  if s.len == 0:
    return none[uint32]()
  var acc = 0'u32
  for c in s:
    var d: uint32
    if c >= '0' and c <= '9':
      d = uint32(ord(c) - ord('0'))
    elif c >= 'a' and c <= 'f':
      d = uint32(ord(c) - ord('a') + 10)
    elif c >= 'A' and c <= 'F':
      d = uint32(ord(c) - ord('A') + 10)
    else:
      return none[uint32]()
    if acc > 0x0FFFFFFF'u32:
      return none[uint32]()
    acc = (acc shl 4) or d
  some(acc)

proc parseFloatSafe(s: string): Option[float32] {.raises: [].} =
  let t = stripAscii(s)
  if t.len == 0:
    return none[float32]()
  var idx = 0
  var sign = 1.0'f64
  if t[idx] == '-':
    sign = -1.0'f64
    inc idx
  elif t[idx] == '+':
    inc idx
  if idx >= t.len:
    return none[float32]()

  var val = 0.0'f64
  var sawDigits = false
  while idx < t.len and isDigitAscii(t[idx]):
    sawDigits = true
    val = val * 10.0'f64 + float64(ord(t[idx]) - ord('0'))
    inc idx

  if idx < t.len and t[idx] == '.':
    inc idx
    var frac = 0.1'f64
    while idx < t.len and isDigitAscii(t[idx]):
      sawDigits = true
      val += float64(ord(t[idx]) - ord('0')) * frac
      frac *= 0.1'f64
      inc idx

  if not sawDigits:
    return none[float32]()

  if idx < t.len and (t[idx] == 'e' or t[idx] == 'E'):
    inc idx
    var expNeg = false
    if idx < t.len and (t[idx] == '-' or t[idx] == '+'):
      expNeg = t[idx] == '-'
      inc idx
    if idx >= t.len or not isDigitAscii(t[idx]):
      return none[float32]()
    var expVal = 0
    while idx < t.len and isDigitAscii(t[idx]):
      if expVal < 100:
        expVal = expVal * 10 + (ord(t[idx]) - ord('0'))
      inc idx
    var mult = 1.0'f64
    for _ in 0 ..< expVal:
      mult *= 10.0'f64
    if expNeg:
      val /= mult
    else:
      val *= mult

  if idx != t.len:
    return none[float32]()

  some(float32(sign * val))

proc parseCssLength(s: string): Option[float32] {.raises: [].} =
  let t = toLowerAscii(stripAscii(s))
  if t.len == 0:
    return none[float32]()
  if t == "0":
    return some(0.0'f32)
  if t.len >= 3 and t[^2] == 'p' and t[^1] == 'x':
    return parseFloatSafe(t[0 ..< t.len - 2])
  if t.len >= 4 and t[^3] == 'r' and t[^2] == 'e' and t[^1] == 'm':
    let n = parseFloatSafe(t[0 ..< t.len - 3])
    if n.isSome:
      return some(n.get() * 16.0'f32)
    return none[float32]()
  if t.len >= 3 and t[^2] == 'e' and t[^1] == 'm':
    let n = parseFloatSafe(t[0 ..< t.len - 2])
    if n.isSome:
      return some(n.get() * 16.0'f32)
    return none[float32]()
  if t[^1] == '%':
    return none[float32]()
  parseFloatSafe(t)

proc parseCssPercent(s: string): Option[float32] {.raises: [].} =
  let t = stripAscii(s)
  if t.len >= 2 and t[^1] == '%':
    return parseFloatSafe(t[0 ..< t.len - 1])
  none[float32]()

proc decodeCodePointSafe(cp: uint32): string {.raises: [].} =
  if cp == 0'u32 or cp > 0x10FFFF'u32 or (cp >= 0xD800'u32 and cp <= 0xDFFF'u32):
    return "?"
  toUTF8(Rune(cp))

proc decodeHtmlEntities*(s: string): string {.raises: [].} =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '&':
      var j = i + 1
      while j < s.len and j - i <= 12 and s[j] != ';' and not isSpaceChar(s[j]) and s[j] != '&':
        inc j
      if j < s.len and s[j] == ';':
        let entity = s[i + 1 ..< j]
        if entity == "amp":
          result.add('&')
          i = j + 1
          continue
        elif entity == "lt":
          result.add('<')
          i = j + 1
          continue
        elif entity == "gt":
          result.add('>')
          i = j + 1
          continue
        elif entity == "quot":
          result.add('"')
          i = j + 1
          continue
        elif entity == "apos":
          result.add('\'')
          i = j + 1
          continue
        elif entity == "nbsp":
          result.add(' ')
          i = j + 1
          continue
        elif entity.len >= 2 and entity[0] == '#':
          if entity.len >= 3 and (entity[1] == 'x' or entity[1] == 'X'):
            let hexOpt = parseHexUintSafe(entity[2 ..< entity.len])
            if hexOpt.isSome:
              result.add(decodeCodePointSafe(hexOpt.get()))
              i = j + 1
              continue
          else:
            let decOpt = parseIntSafe(entity[1 ..< entity.len])
            if decOpt.isSome and decOpt.get() >= 0:
              result.add(decodeCodePointSafe(uint32(decOpt.get())))
              i = j + 1
              continue
    result.add(s[i])
    inc i

# =============================================================================
# Result Constructors
# =============================================================================

proc resOk[T](val: T): Result[T, string] {.inline, raises: [].} =
  Result[T, string].ok(val)

proc resErr[T](msg: string): Result[T, string] {.inline, raises: [].} =
  Result[T, string].err(msg)

# =============================================================================
# HTML5 Parser & Zero-JS Security Enforcement
# =============================================================================

proc root*(doc: HtmlDoc): int {.inline, raises: [].} =
  if doc.nodes.len > 0: 0 else: -1

proc getAttr*(node: HtmlNode, attrName: string): Option[string] {.raises: [].} =
  let key = toLowerAscii(attrName)
  for a in node.attrs:
    if a.name == key:
      return some(a.value)
  none[string]()

proc hasClass*(node: HtmlNode, cls: string): bool {.raises: [].} =
  for c in node.classes:
    if c == cls:
      return true
  false

proc innerText*(doc: HtmlDoc, nodeIdx: int): string {.raises: [].} =
  if nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return ""
  let node = doc.nodes[nodeIdx]
  if node.kind == hnkText:
    return node.text
  result = ""
  for childIdx in node.children:
    result.add(doc.innerText(childIdx))

proc findById*(doc: HtmlDoc, id: string): Option[int] {.raises: [].} =
  for i in 0 ..< doc.nodes.len:
    if doc.nodes[i].kind == hnkElement and doc.nodes[i].id == id:
      return some(i)
  none[int]()

proc isForbiddenEventAttr(attrName: string): bool {.inline, raises: [].} =
  # Inline JS event handlers follow on<event> (e.g., onclick, oninput, onload).
  attrName.len > 2 and attrName[0] == 'o' and attrName[1] == 'n' and isAlphaAscii(attrName[2])

proc isJavascriptUrl(val: string): bool {.raises: [].} =
  let t = stripAscii(val)
  startsWithIgnoreCase(t, "javascript:")

proc parseHtmlDoc*(html: string): Result[HtmlDoc, string] {.raises: [].} =
  var doc = HtmlDoc(
    nodes: @[HtmlNode(kind: hnkDocument, parent: -1, children: @[])],
    embeddedCss: ""
  )
  var stack: seq[int] = @[0]
  var pos = 0

  while pos < html.len:
    if html[pos] == '<':
      # 1. HTML comment <!-- ... -->
      if pos + 3 < html.len and html[pos + 1] == '!' and html[pos + 2] == '-' and html[pos + 3] == '-':
        var closePos = pos + 4
        while closePos + 2 < html.len:
          if html[closePos] == '-' and html[closePos + 1] == '-' and html[closePos + 2] == '>':
            break
          inc closePos
        if closePos + 2 < html.len:
          pos = closePos + 3
        else:
          pos = html.len
        continue

      # 2. DOCTYPE / <!...> / <?...?>
      if pos + 1 < html.len and (html[pos + 1] == '!' or html[pos + 1] == '?'):
        var endPos = pos + 2
        while endPos < html.len and html[endPos] != '>':
          inc endPos
        pos = if endPos < html.len: endPos + 1 else: html.len
        continue

      # 3. Closing tag </tag>
      if pos + 1 < html.len and html[pos + 1] == '/':
        var idx = pos + 2
        while idx < html.len and isSpaceChar(html[idx]):
          inc idx
        let nameStart = idx
        while idx < html.len and html[idx] != '>' and not isSpaceChar(html[idx]):
          inc idx
        let closeTag = toLowerAscii(html[nameStart ..< idx])
        if closeTag == "script":
          return resErr[HtmlDoc]("Zero-JS policy violation: <script> tag is forbidden")
        while idx < html.len and html[idx] != '>':
          inc idx
        pos = if idx < html.len: idx + 1 else: html.len

        # Pop stack back to matching tag
        var matchPos = -1
        for sIdx in countdown(stack.len - 1, 1):
          if doc.nodes[stack[sIdx]].tag == closeTag:
            matchPos = sIdx
            break
        if matchPos > 0:
          stack.setLen(matchPos)
        continue

      # 4. Opening tag <tag ...>
      var idx = pos + 1
      if idx >= html.len or isSpaceChar(html[idx]):
        # Literal stray '<' as text
        let curParent = stack[^1]
        let txtIdx = doc.nodes.len
        doc.nodes.add(HtmlNode(kind: hnkText, text: "<", parent: curParent, children: @[]))
        doc.nodes[curParent].children.add(txtIdx)
        inc pos
        continue

      let tagStart = idx
      while idx < html.len and not isSpaceChar(html[idx]) and html[idx] != '>' and html[idx] != '/':
        inc idx
      let tagName = toLowerAscii(html[tagStart ..< idx])
      if tagName == "script":
        return resErr[HtmlDoc]("Zero-JS policy violation: <script> tag is forbidden")

      var node = HtmlNode(
        kind: hnkElement,
        tag: tagName,
        id: "",
        classes: @[],
        attrs: @[],
        text: "",
        parent: stack[^1],
        children: @[]
      )

      var selfClosing = false
      while idx < html.len:
        while idx < html.len and isSpaceChar(html[idx]):
          inc idx
        if idx >= html.len:
          break
        if html[idx] == '>':
          inc idx
          break
        if html[idx] == '/' and idx + 1 < html.len and html[idx + 1] == '>':
          selfClosing = true
          idx += 2
          break
        if html[idx] == '/':
          inc idx
          continue

        let attrStart = idx
        while idx < html.len and html[idx] != '=' and html[idx] != '>' and html[idx] != '/' and not isSpaceChar(html[idx]):
          inc idx
        let attrName = toLowerAscii(html[attrStart ..< idx])
        if attrName.len == 0:
          inc idx
          continue
        if isForbiddenEventAttr(attrName):
          return resErr[HtmlDoc]("Zero-JS policy violation: inline event attribute '" & attrName & "' is forbidden")

        var attrVal = ""
        while idx < html.len and isSpaceChar(html[idx]):
          inc idx
        if idx < html.len and html[idx] == '=':
          inc idx
          while idx < html.len and isSpaceChar(html[idx]):
            inc idx
          if idx < html.len and (html[idx] == '"' or html[idx] == '\''):
            let quote = html[idx]
            inc idx
            let valStart = idx
            while idx < html.len and html[idx] != quote:
              inc idx
            attrVal = decodeHtmlEntities(html[valStart ..< idx])
            if idx < html.len and html[idx] == quote:
              inc idx
          else:
            let valStart = idx
            while idx < html.len and not isSpaceChar(html[idx]) and html[idx] != '>':
              if html[idx] == '/' and idx + 1 < html.len and html[idx + 1] == '>':
                break
              inc idx
            attrVal = decodeHtmlEntities(html[valStart ..< idx])

        if (attrName == "href" or attrName == "src" or attrName == "action") and isJavascriptUrl(attrVal):
          return resErr[HtmlDoc]("Zero-JS policy violation: javascript: URI in '" & attrName & "' is forbidden")

        node.attrs.add(HtmlAttr(name: attrName, value: attrVal))
        if attrName == "id":
          node.id = attrVal
        elif attrName == "class":
          node.classes = splitWhitespace(attrVal)

      pos = idx
      let curParent = stack[^1]
      let nodeIdx = doc.nodes.len
      doc.nodes.add(node)
      doc.nodes[curParent].children.add(nodeIdx)

      if tagName == "style" and not selfClosing:
        # Capture raw CSS until </style>
        let cssStart = pos
        var cssEnd = pos
        while cssEnd < html.len:
          if html[cssEnd] == '<' and startsWithIgnoreCase(html, "</style", cssEnd):
            break
          inc cssEnd
        let cssChunk = stripAscii(html[cssStart ..< cssEnd])
        if cssChunk.len > 0:
          if doc.embeddedCss.len > 0:
            doc.embeddedCss.add('\n')
          doc.embeddedCss.add(cssChunk)
        pos = cssEnd
        if pos < html.len:
          while pos < html.len and html[pos] != '>':
            inc pos
          if pos < html.len and html[pos] == '>':
            inc pos
        continue

      if not selfClosing and not containsTag(HtmlVoidTags, tagName):
        stack.add(nodeIdx)
    else:
      let textStart = pos
      while pos < html.len and html[pos] != '<':
        inc pos
      let collapsed = collapseHtmlWhitespace(html[textStart ..< pos])
      let decoded = decodeHtmlEntities(collapsed)
      if stripAscii(decoded).len > 0:
        let curParent = stack[^1]
        let txtIdx = doc.nodes.len
        doc.nodes.add(HtmlNode(
          kind: hnkText,
          text: decoded,
          parent: curParent,
          children: @[]
        ))
        doc.nodes[curParent].children.add(txtIdx)

  resOk(doc)

# =============================================================================
# CSS3 Color, Stylesheet, Selector & Cascade Engine
# =============================================================================

proc hexDigitVal(c: char): uint32 {.inline, raises: [].} =
  if c >= '0' and c <= '9':
    uint32(ord(c) - ord('0'))
  elif c >= 'a' and c <= 'f':
    uint32(ord(c) - ord('a') + 10)
  elif c >= 'A' and c <= 'F':
    uint32(ord(c) - ord('A') + 10)
  else:
    0'u32

proc parseHexByte(hi, lo: char): uint32 {.inline, raises: [].} =
  (hexDigitVal(hi) shl 4) or hexDigitVal(lo)

proc clampByteF(v: float32): uint32 {.inline, raises: [].} =
  if v <= 0.0'f32: 0'u32
  elif v >= 255.0'f32: 255'u32
  else: uint32(v + 0.5'f32)

proc packRgba(r, g, b, a: uint32): uint32 {.inline, raises: [].} =
  ((r and 0xFF'u32) shl 24) or ((g and 0xFF'u32) shl 16) or ((b and 0xFF'u32) shl 8) or (a and 0xFF'u32)

proc parseCssColor*(raw: string): Option[uint32] {.raises: [].} =
  let s = toLowerAscii(stripAscii(raw))
  if s.len == 0:
    return none[uint32]()

  if s[0] == '#':
    let hex = s[1 ..< s.len]
    for c in hex:
      if not isHexDigitAscii(c):
        return none[uint32]()
    case hex.len
    of 3:
      let r = hexDigitVal(hex[0]) * 17'u32
      let g = hexDigitVal(hex[1]) * 17'u32
      let b = hexDigitVal(hex[2]) * 17'u32
      return some(packRgba(r, g, b, 255'u32))
    of 4:
      let r = hexDigitVal(hex[0]) * 17'u32
      let g = hexDigitVal(hex[1]) * 17'u32
      let b = hexDigitVal(hex[2]) * 17'u32
      let a = hexDigitVal(hex[3]) * 17'u32
      return some(packRgba(r, g, b, a))
    of 6:
      let r = parseHexByte(hex[0], hex[1])
      let g = parseHexByte(hex[2], hex[3])
      let b = parseHexByte(hex[4], hex[5])
      return some(packRgba(r, g, b, 255'u32))
    of 8:
      let r = parseHexByte(hex[0], hex[1])
      let g = parseHexByte(hex[2], hex[3])
      let b = parseHexByte(hex[4], hex[5])
      let a = parseHexByte(hex[6], hex[7])
      return some(packRgba(r, g, b, a))
    else:
      return none[uint32]()

  if startsWithAscii(s, "rgb(") or startsWithAscii(s, "rgba("):
    let openIdx = if startsWithAscii(s, "rgba("): 5 else: 4
    if s[^1] != ')':
      return none[uint32]()
    let inner = s[openIdx ..< s.len - 1]
    var parts: seq[string] = @[]
    var start = 0
    for i in 0 ..< inner.len:
      if inner[i] == ',' or inner[i] == '/':
        let tok = stripAscii(inner[start ..< i])
        if tok.len > 0:
          parts.add(tok)
        start = i + 1
    let lastTok = stripAscii(inner[start ..< inner.len])
    if lastTok.len > 0:
      parts.add(lastTok)
    if parts.len == 1:
      parts = splitWhitespace(inner)
    if parts.len < 3 or parts.len > 4:
      return none[uint32]()
    let ro = parseFloatSafe(parts[0])
    let go = parseFloatSafe(parts[1])
    let bo = parseFloatSafe(parts[2])
    if ro.isNone or go.isNone or bo.isNone:
      return none[uint32]()
    var aByte = 255'u32
    if parts.len == 4:
      let ao = parseFloatSafe(parts[3])
      if ao.isNone:
        return none[uint32]()
      let af = ao.get()
      if af <= 1.0'f32:
        aByte = clampByteF(af * 255.0'f32)
      else:
        aByte = clampByteF(af)
    return some(packRgba(clampByteF(ro.get()), clampByteF(go.get()), clampByteF(bo.get()), aByte))

  case s
  of "transparent": some(0x00000000'u32)
  of "black": some(0x000000FF'u32)
  of "white": some(0xFFFFFFFF'u32)
  of "red": some(0xFF0000FF'u32)
  of "green": some(0x008000FF'u32)
  of "lime": some(0x00FF00FF'u32)
  of "blue": some(0x0000FFFF'u32)
  of "yellow": some(0xFFFF00FF'u32)
  of "cyan", "aqua": some(0x00FFFFFF'u32)
  of "magenta", "fuchsia": some(0xFF00FFFF'u32)
  of "silver": some(0xC0C0C0FF'u32)
  of "gray", "grey": some(0x808080FF'u32)
  of "orange": some(0xFFA500FF'u32)
  of "purple": some(0x800080FF'u32)
  of "navy": some(0x000080FF'u32)
  of "teal": some(0x008080FF'u32)
  of "slate": some(0x64748BFF'u32)
  of "indigo": some(0x4F46E5FF'u32)
  of "emerald": some(0x10B981FF'u32)
  of "rose": some(0xF43F5EFF'u32)
  of "amber": some(0xF59E0BFF'u32)
  of "obsidian": some(0x0A0A0CFF'u32)
  of "midnight": some(0x111116FF'u32)
  else: none[uint32]()

proc stripCssComments(css: string): string {.raises: [].} =
  result = newStringOfCap(css.len)
  var i = 0
  var inQuote = '\0'
  while i < css.len:
    let c = css[i]
    if inQuote != '\0':
      result.add(c)
      if c == '\\' and i + 1 < css.len:
        inc i
        result.add(css[i])
      elif c == inQuote:
        inQuote = '\0'
      inc i
      continue
    if c == '"' or c == '\'':
      inQuote = c
      result.add(c)
      inc i
      continue
    if c == '/' and i + 1 < css.len and css[i + 1] == '*':
      i += 2
      while i + 1 < css.len and not (css[i] == '*' and css[i + 1] == '/'):
        inc i
      if i + 1 < css.len:
        i += 2
      else:
        i = css.len
      result.add(' ')
      continue
    result.add(c)
    inc i

proc parseSimpleSelector(raw: string): Option[CssSimpleSelector] {.raises: [].} =
  let s = stripAscii(raw)
  if s.len == 0:
    return none[CssSimpleSelector]()
  var sel = CssSimpleSelector(
    isUniversal: false,
    tag: "",
    id: "",
    classes: @[],
    pseudo: cpkNone
  )
  var i = 0
  if s[0] == '*':
    sel.isUniversal = true
    inc i
  elif s[0] != '.' and s[0] != '#' and s[0] != ':':
    let start = i
    while i < s.len and s[i] != '.' and s[i] != '#' and s[i] != ':':
      inc i
    sel.tag = toLowerAscii(s[start ..< i])

  while i < s.len:
    let marker = s[i]
    inc i
    let start = i
    while i < s.len and s[i] != '.' and s[i] != '#' and s[i] != ':':
      inc i
    let ident = s[start ..< i]
    if ident.len == 0:
      return none[CssSimpleSelector]()
    case marker
    of '.':
      sel.classes.add(ident)
    of '#':
      sel.id = ident
    of ':':
      let p = toLowerAscii(ident)
      if p == "hover":
        sel.pseudo = cpkHover
      elif p == "active":
        sel.pseudo = cpkActive
    else:
      discard
  some(sel)

proc parseComplexSelector(raw: string): Option[CssSelector] {.raises: [].} =
  let s = stripAscii(raw)
  if s.len == 0:
    return none[CssSelector]()
  var parts: seq[CssSimpleSelector] = @[]
  var directChild: seq[bool] = @[]
  var i = 0
  var pendingDirect = false

  while i < s.len:
    while i < s.len and isSpaceChar(s[i]):
      inc i
    if i >= s.len:
      break
    if s[i] == '>':
      pendingDirect = true
      inc i
      continue
    let start = i
    while i < s.len and not isSpaceChar(s[i]) and s[i] != '>':
      inc i
    let tok = s[start ..< i]
    let simp = parseSimpleSelector(tok)
    if simp.isNone:
      return none[CssSelector]()
    let simpleSel = simp.get()
    parts.add(simpleSel)
    directChild.add(pendingDirect)
    pendingDirect = false

  if parts.len == 0:
    return none[CssSelector]()

  var spec = 0
  for p in parts:
    if p.id.len > 0:
      spec += 10000
    spec += p.classes.len * 100
    if p.tag.len > 0:
      spec += 1
    if p.pseudo != cpkNone:
      spec += 100

  some(CssSelector(parts: parts, directChild: directChild, specificity: spec))

proc parseCssDeclarations*(body: string): seq[CssDeclaration] {.raises: [].} =
  result = @[]
  var i = 0
  var declStart = 0
  var inQuote = '\0'
  var parenDepth = 0

  while i <= body.len:
    let atEnd = i == body.len
    let c = if atEnd: ';' else: body[i]
    if not atEnd:
      if inQuote != '\0':
        if c == '\\' and i + 1 < body.len:
          inc i
        elif c == inQuote:
          inQuote = '\0'
        inc i
        continue
      if c == '"' or c == '\'':
        inQuote = c
        inc i
        continue
      if c == '(':
        inc parenDepth
        inc i
        continue
      elif c == ')' and parenDepth > 0:
        dec parenDepth
        inc i
        continue

    if c == ';' and parenDepth == 0:
      let declText = stripAscii(body[declStart ..< i])
      if declText.len > 0:
        var colonIdx = -1
        for k in 0 ..< declText.len:
          if declText[k] == ':':
            colonIdx = k
            break
        if colonIdx > 0:
          let propName = toLowerAscii(stripAscii(declText[0 ..< colonIdx]))
          let propVal = stripAscii(declText[colonIdx + 1 ..< declText.len])
          if propName.len > 0 and propVal.len > 0:
            result.add(CssDeclaration(prop: propName, value: propVal))
      declStart = i + 1
    inc i

proc splitCssValueTokens(val: string): seq[string] {.raises: [].} =
  # Keeps parenthesized sub-expressions like rgb(1, 2, 3) together as one token.
  result = @[]
  var i = 0
  while i < val.len:
    while i < val.len and isSpaceChar(val[i]):
      inc i
    if i >= val.len:
      break
    let start = i
    var depth = 0
    while i < val.len:
      let c = val[i]
      if c == '(':
        inc depth
      elif c == ')' and depth > 0:
        dec depth
      elif isSpaceChar(c) and depth == 0:
        break
      inc i
    result.add(val[start ..< i])

proc parseCssSheet*(css: string): CssStylesheet {.raises: [].} =
  result = CssStylesheet(rules: @[])
  let clean = stripCssComments(css)
  var i = 0
  var orderCounter = 0

  while i < clean.len:
    while i < clean.len and isSpaceChar(clean[i]):
      inc i
    if i >= clean.len:
      break

    # Skip @-rules (@media, @keyframes, etc.) safely
    if clean[i] == '@':
      while i < clean.len and clean[i] != '{' and clean[i] != ';':
        inc i
      if i < clean.len and clean[i] == '{':
        var depth = 1
        inc i
        while i < clean.len and depth > 0:
          if clean[i] == '{': inc depth
          elif clean[i] == '}': dec depth
          inc i
      elif i < clean.len:
        inc i
      continue

    let selStart = i
    while i < clean.len and clean[i] != '{' and clean[i] != '}':
      inc i
    if i >= clean.len:
      break
    if clean[i] == '}':
      inc i
      continue

    let selectorListStr = clean[selStart ..< i]
    inc i # skip '{'

    let bodyStart = i
    var depth = 1
    var inQuote = '\0'
    while i < clean.len and depth > 0:
      let c = clean[i]
      if inQuote != '\0':
        if c == '\\' and i + 1 < clean.len:
          inc i
        elif c == inQuote:
          inQuote = '\0'
      else:
        if c == '"' or c == '\'':
          inQuote = c
        elif c == '{':
          inc depth
        elif c == '}':
          dec depth
          if depth == 0:
            break
      inc i

    let bodyStr = clean[bodyStart ..< i]
    if i < clean.len and clean[i] == '}':
      inc i

    let decls = parseCssDeclarations(bodyStr)
    if decls.len == 0:
      continue

    # Split selectorListStr by ','
    var sStart = 0
    for k in 0 .. selectorListStr.len:
      if k == selectorListStr.len or selectorListStr[k] == ',':
        let selOpt = parseComplexSelector(selectorListStr[sStart ..< k])
        if selOpt.isSome:
          result.rules.add(CssRule(
            selector: selOpt.get(),
            declarations: decls,
            order: orderCounter
          ))
          inc orderCounter
        sStart = k + 1

proc matchesSimple*(node: HtmlNode, simp: CssSimpleSelector): bool {.raises: [].} =
  if node.kind != hnkElement:
    return false
  if simp.tag.len > 0 and node.tag != simp.tag:
    return false
  if simp.id.len > 0 and node.id != simp.id:
    return false
  for cls in simp.classes:
    if not node.hasClass(cls):
      return false
  true

proc matchesSelector*(doc: HtmlDoc, nodeIdx: int, sel: CssSelector): bool {.raises: [].} =
  if sel.parts.len == 0 or nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return false
  let lastIdx = sel.parts.len - 1
  if not matchesSimple(doc.nodes[nodeIdx], sel.parts[lastIdx]):
    return false

  var curNode = doc.nodes[nodeIdx].parent
  for pIdx in countdown(lastIdx - 1, 0):
    let needDirect = sel.directChild[pIdx + 1]
    if needDirect:
      if curNode <= 0 or curNode >= doc.nodes.len:
        return false
      if not matchesSimple(doc.nodes[curNode], sel.parts[pIdx]):
        return false
      curNode = doc.nodes[curNode].parent
    else:
      var found = false
      while curNode > 0 and curNode < doc.nodes.len:
        if matchesSimple(doc.nodes[curNode], sel.parts[pIdx]):
          found = true
          curNode = doc.nodes[curNode].parent
          break
        curNode = doc.nodes[curNode].parent
      if not found:
        return false
  true

proc applyDeclaration(style: var CssComputedStyle, prop, rawVal: string) {.raises: [].} =
  let val = stripAscii(rawVal)
  let low = toLowerAscii(val)

  case prop
  of "display":
    case low
    of "none": style.display = cdNone
    of "flex": style.display = cdFlex
    of "inline", "inline-block": style.display = cdInline
    else: style.display = cdBlock
  of "flex-direction":
    style.flexDirectionSet = true
    if low == "column" or low == "column-reverse":
      style.flexDirection = fdColumn
    else:
      style.flexDirection = fdRow
  of "justify-content":
    case low
    of "center": style.justifyContent = jcCenter
    of "flex-end", "end": style.justifyContent = jcEnd
    of "space-between": style.justifyContent = jcSpaceBetween
    else: style.justifyContent = jcStart
  of "align-items":
    style.alignItemsSet = true
    case low
    of "center": style.alignItems = aiCenter
    of "flex-end", "end": style.alignItems = aiEnd
    of "stretch": style.alignItems = aiStretch
    else: style.alignItems = aiStart
  of "width":
    if low == "auto":
      style.width = CssSize(kind: cskAuto, value: 0.0'f32)
    else:
      let pct = parseCssPercent(val)
      if pct.isSome:
        style.width = CssSize(kind: cskPercent, value: pct.get())
      else:
        let px = parseCssLength(val)
        if px.isSome:
          style.width = CssSize(kind: cskPx, value: px.get())
  of "height":
    if low == "auto":
      style.height = CssSize(kind: cskAuto, value: 0.0'f32)
    else:
      let pct = parseCssPercent(val)
      if pct.isSome:
        style.height = CssSize(kind: cskPercent, value: pct.get())
      else:
        let px = parseCssLength(val)
        if px.isSome:
          style.height = CssSize(kind: cskPx, value: px.get())
  of "flex-grow":
    let fg = parseFloatSafe(val)
    if fg.isSome:
      style.flexGrow = fg.get()
      style.hasFlexGrow = fg.get() > 0.0'f32
  of "flex":
    if low == "none":
      style.flexGrow = 0.0'f32
      style.hasFlexGrow = false
    else:
      let toks = splitCssValueTokens(val)
      if toks.len > 0:
        let fg = parseFloatSafe(toks[0])
        if fg.isSome:
          style.flexGrow = fg.get()
          style.hasFlexGrow = fg.get() > 0.0'f32
  of "padding":
    let toks = splitCssValueTokens(val)
    var vals: array[4, float32]
    var parsed: seq[float32] = @[]
    for tok in toks:
      let l = parseCssLength(tok)
      if l.isSome:
        parsed.add(l.get())
    if parsed.len == 1:
      vals = [parsed[0], parsed[0], parsed[0], parsed[0]]
    elif parsed.len == 2:
      vals = [parsed[0], parsed[1], parsed[0], parsed[1]]
    elif parsed.len == 3:
      vals = [parsed[0], parsed[1], parsed[2], parsed[1]]
    elif parsed.len >= 4:
      vals = [parsed[0], parsed[1], parsed[2], parsed[3]]
    if parsed.len > 0:
      style.padding = vals
      style.paddingSet = [true, true, true, true]
  of "padding-top":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[0] = l.get()
      style.paddingSet[0] = true
  of "padding-right":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[1] = l.get()
      style.paddingSet[1] = true
  of "padding-bottom":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[2] = l.get()
      style.paddingSet[2] = true
  of "padding-left":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[3] = l.get()
      style.paddingSet[3] = true
  of "gap":
    let toks = splitCssValueTokens(val)
    if toks.len > 0:
      let g = parseCssLength(toks[0])
      if g.isSome:
        style.gap = g.get()
  of "color":
    let c = parseCssColor(val)
    if c.isSome:
      style.fgColor = c.get()
      style.fgColorSet = true
  of "background", "background-color":
    if low == "none":
      style.bgColor = 0x00000000'u32
    else:
      let c = parseCssColor(val)
      if c.isSome:
        style.bgColor = c.get()
      else:
        for tok in splitCssValueTokens(val):
          let tc = parseCssColor(tok)
          if tc.isSome:
            style.bgColor = tc.get()
            break
  of "border":
    if low == "none" or low == "0":
      style.borderWidth = 0.0'f32
      style.borderColor = 0x00000000'u32
    else:
      for tok in splitCssValueTokens(val):
        let tl = toLowerAscii(tok)
        if tl == "solid" or tl == "dashed" or tl == "dotted":
          continue
        let c = parseCssColor(tok)
        if c.isSome:
          style.borderColor = c.get()
          continue
        let w = parseCssLength(tok)
        if w.isSome:
          style.borderWidth = w.get()
  of "border-width":
    let w = parseCssLength(val)
    if w.isSome:
      style.borderWidth = w.get()
  of "border-color":
    let c = parseCssColor(val)
    if c.isSome:
      style.borderColor = c.get()
  of "border-radius":
    let toks = splitCssValueTokens(val)
    if toks.len > 0:
      let r = parseCssLength(toks[0])
      if r.isSome:
        style.borderRadius = r.get()
  of "font-size":
    let fs = parseCssLength(val)
    if fs.isSome:
      style.fontSize = fs.get()
      style.fontSizeSet = true
  of "overflow", "overflow-y":
    style.overflowY = (low == "auto" or low == "scroll")
  of "text-align":
    case low
    of "center":
      style.justifyContent = jcCenter
      if not style.alignItemsSet:
        style.alignItems = aiCenter
    of "right", "end":
      style.justifyContent = jcEnd
      if not style.alignItemsSet:
        style.alignItems = aiEnd
    else:
      style.justifyContent = jcStart
  else:
    discard

proc defaultElementStyle(tag: string, parentStyle: CssComputedStyle): CssComputedStyle {.raises: [].} =
  result = CssComputedStyle(
    display: cdBlock,
    flexDirection: fdColumn,
    flexDirectionSet: false,
    justifyContent: jcStart,
    alignItems: aiStretch,
    alignItemsSet: false,
    width: CssSize(kind: cskAuto, value: 0.0'f32),
    height: CssSize(kind: cskAuto, value: 0.0'f32),
    flexGrow: 0.0'f32,
    hasFlexGrow: false,
    padding: [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32],
    paddingSet: [false, false, false, false],
    gap: 0.0'f32,
    fgColor: parentStyle.fgColor,
    fgColorSet: false,
    bgColor: 0x00000000'u32,
    bgHoverColor: 0x00000000'u32,
    bgActiveColor: 0x00000000'u32,
    borderColor: 0x00000000'u32,
    borderHoverColor: 0x00000000'u32,
    borderWidth: 0.0'f32,
    borderRadius: 0.0'f32,
    fontSize: parentStyle.fontSize,
    fontSizeSet: false,
    overflowY: false
  )

  case tag
  of "h1":
    result.fontSize = 24.0'f32
  of "h2":
    result.fontSize = 20.0'f32
  of "h3":
    result.fontSize = 16.0'f32
  of "span", "label", "strong", "em", "a":
    result.display = cdInline
  of "button":
    result.display = cdInline
    result.bgColor = 0x1E293BFF'u32
    result.bgHoverColor = 0x334155FF'u32
    result.bgActiveColor = 0x0F172AFF'u32
    result.borderColor = 0x475569FF'u32
    result.borderWidth = 1.0'f32
    result.borderRadius = 6.0'f32
    result.padding = [6.0'f32, 12.0'f32, 6.0'f32, 12.0'f32]
    result.fgColor = 0xF8FAFCFF'u32
    result.fontSize = 13.0'f32
    result.alignItems = aiCenter
    result.justifyContent = jcCenter
  of "input":
    result.display = cdInline
    result.bgColor = 0x0F172AFF'u32
    result.borderColor = 0x334155FF'u32
    result.borderHoverColor = 0x64748BFF'u32
    result.borderWidth = 1.0'f32
    result.borderRadius = 6.0'f32
    result.padding = [6.0'f32, 10.0'f32, 6.0'f32, 10.0'f32]
    result.fgColor = 0xF8FAFCFF'u32
    result.fontSize = 13.0'f32
  else:
    discard

proc defaultRootStyle*(): CssComputedStyle {.raises: [].} =
  CssComputedStyle(
    display: cdBlock,
    flexDirection: fdColumn,
    fgColor: 0xF8FAFCFF'u32,
    fontSize: 14.0'f32
  )

proc applyPseudoDeclarations(style: var CssComputedStyle, pseudo: CssPseudoKind, decls: seq[CssDeclaration]) {.raises: [].} =
  for d in decls:
    case pseudo
    of cpkHover:
      if d.prop == "background" or d.prop == "background-color":
        let c = parseCssColor(d.value)
        if c.isSome:
          style.bgHoverColor = c.get()
      elif d.prop == "border-color":
        let c = parseCssColor(d.value)
        if c.isSome:
          style.borderHoverColor = c.get()
    of cpkActive:
      if d.prop == "background" or d.prop == "background-color":
        let c = parseCssColor(d.value)
        if c.isSome:
          style.bgActiveColor = c.get()
    of cpkNone:
      discard

proc sortMatchedRuleIndices(indices: var seq[int], sheet: CssStylesheet) {.raises: [].} =
  # Simple insertion sort by (specificity, source order) — tiny rule counts per element
  for i in 1 ..< indices.len:
    let keyIdx = indices[i]
    let keySpec = sheet.rules[keyIdx].selector.specificity
    let keyOrder = sheet.rules[keyIdx].order
    var j = i - 1
    while j >= 0:
      let curIdx = indices[j]
      let curSpec = sheet.rules[curIdx].selector.specificity
      let curOrder = sheet.rules[curIdx].order
      if curSpec > keySpec or (curSpec == keySpec and curOrder > keyOrder):
        indices[j + 1] = curIdx
        dec j
      else:
        break
    indices[j + 1] = keyIdx

proc computeNodeStyle*(
  doc: HtmlDoc,
  nodeIdx: int,
  sheet: CssStylesheet,
  parentStyle: CssComputedStyle
): CssComputedStyle {.raises: [].} =
  if nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return defaultRootStyle()

  let node = doc.nodes[nodeIdx]
  if node.kind != hnkElement:
    return parentStyle

  var style = defaultElementStyle(node.tag, parentStyle)
  var baseRules: seq[int] = @[]
  var pseudoRules: seq[int] = @[]

  for rIdx in 0 ..< sheet.rules.len:
    if matchesSelector(doc, nodeIdx, sheet.rules[rIdx].selector):
      let pseudo = sheet.rules[rIdx].selector.parts[^1].pseudo
      if pseudo == cpkNone:
        baseRules.add(rIdx)
      else:
        pseudoRules.add(rIdx)

  sortMatchedRuleIndices(baseRules, sheet)
  sortMatchedRuleIndices(pseudoRules, sheet)

  for rIdx in baseRules:
    for d in sheet.rules[rIdx].declarations:
      style.applyDeclaration(d.prop, d.value)

  # Apply inline style="..." (highest specificity)
  let inlineOpt = node.getAttr("style")
  if inlineOpt.isSome:
    for d in parseCssDeclarations(inlineOpt.get()):
      style.applyDeclaration(d.prop, d.value)

  # Resolve display: flex default direction if flex-direction was omitted
  if style.display == cdFlex and not style.flexDirectionSet:
    style.flexDirection = fdRow
  elif style.display == cdBlock and not style.flexDirectionSet:
    style.flexDirection = fdColumn

  # Apply :hover and :active pseudo-rules after base style
  for rIdx in pseudoRules:
    let pseudo = sheet.rules[rIdx].selector.parts[^1].pseudo
    style.applyPseudoDeclarations(pseudo, sheet.rules[rIdx].declarations)

  style

# =============================================================================
# Pure-Nim Binding Registry & Reactive DOM Mounter
# =============================================================================

proc initHtmlBindingRegistry*(): HtmlBindingRegistry {.raises: [].} =
  HtmlBindingRegistry(
    clickHandlers: initFastMap[string, HtmlClickProc](16),
    inputHandlers: initFastMap[string, HtmlInputProc](16),
    textSignals: initFastMap[string, Signal[string]](16),
    textProcs: initFastMap[string, HtmlTextProc](16),
    inputSignals: initFastMap[string, Signal[string]](16),
    idToSlab: initFastMap[string, SlabId](32)
  )

proc destroy*(reg: var HtmlBindingRegistry) {.raises: [].} =
  reg.clickHandlers.clear()
  reg.inputHandlers.clear()
  reg.textSignals.clear()
  reg.textProcs.clear()
  reg.inputSignals.clear()
  reg.idToSlab.clear()

proc onClick*(reg: var HtmlBindingRegistry, name: string, cb: HtmlClickProc) {.raises: [].} =
  reg.clickHandlers.put(name, cb)

proc onInput*(reg: var HtmlBindingRegistry, name: string, cb: HtmlInputProc) {.raises: [].} =
  reg.inputHandlers.put(name, cb)

proc bindTextSignal*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string]) {.raises: [].} =
  reg.textSignals.put(name, sig)

proc bindText*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string]) {.raises: [].} =
  reg.textSignals.put(name, sig)

proc bindText*(reg: var HtmlBindingRegistry, name: string, fn: HtmlTextProc) {.raises: [].} =
  reg.textProcs.put(name, fn)

proc bindInputSignal*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string]) {.raises: [].} =
  reg.inputSignals.put(name, sig)

proc getNodeById*(reg: HtmlBindingRegistry, id: string): Option[SlabId] {.raises: [].} =
  if reg.idToSlab.contains(id):
    return some(reg.idToSlab.getOrDefault(id))
  none[SlabId]()

proc toLayoutPadding(p: array[4, float32]): array[4, float32] {.inline, raises: [].} =
  # layout.nim UiNode.padding uses [top, right, bottom, left] — identical to CSS order.
  p

proc resolveSizeMode(
  sz: CssSize,
  hasFlexGrow: bool,
  flexWeight: float32,
  isPrimaryAxis: bool,
  parentFixedInner: float32,
  defaultPx: float32 = -1.0'f32
): SizeMode {.raises: [].} =
  case sz.kind
  of cskPx:
    fixed(sz.value)
  of cskPercent:
    if parentFixedInner >= 0.0'f32:
      fixed(parentFixedInner * (sz.value / 100.0'f32))
    else:
      let w = sz.value / 100.0'f32
      flexGrow(if w > 0.01'f32: w else: 0.01'f32)
  of cskFlexGrow:
    flexGrow(if sz.value > 0.0'f32: sz.value else: 1.0'f32)
  of cskAuto:
    if hasFlexGrow and isPrimaryAxis:
      flexGrow(flexWeight)
    elif defaultPx >= 0.0'f32:
      fixed(defaultPx)
    else:
      fitContent()

proc computeChildFixedInner(sz: SizeMode, padA, padB: float32): float32 {.inline, raises: [].} =
  if sz.kind == smFixed:
    let inner = sz.val - padA - padB
    if inner >= 0.0'f32: inner else: 0.0'f32
  else:
    -1.0'f32

proc hasVisualBoxStyle(style: CssComputedStyle): bool {.raises: [].} =
  style.bgColor != 0'u32 or
  style.borderWidth > 0.0'f32 or
  style.borderRadius > 0.0'f32 or
  style.padding[0] != 0.0'f32 or
  style.padding[1] != 0.0'f32 or
  style.padding[2] != 0.0'f32 or
  style.padding[3] != 0.0'f32 or
  style.width.kind != cskAuto or
  style.height.kind != cskAuto or
  style.hasFlexGrow

proc collectDirectTextAndElementChildren(
  doc: HtmlDoc,
  nodeIdx: int,
  outElemChildren: var seq[int],
  outDirectText: var string
) {.raises: [].} =
  for cIdx in doc.nodes[nodeIdx].children:
    let child = doc.nodes[cIdx]
    if child.kind == hnkElement:
      if not containsTag(HtmlSkipMountTags, child.tag):
        outElemChildren.add(cIdx)
    elif child.kind == hnkText:
      let t = stripAscii(child.text)
      if t.len > 0:
        if outDirectText.len > 0:
          outDirectText.add(' ')
        outDirectText.add(t)

proc attachReactiveBindings(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  bindings: var HtmlBindingRegistry,
  htmlNode: HtmlNode,
  containerSlab: SlabId,
  textSlab: SlabId,
  isInput: bool
) {.raises: [].} =
  let clickOpt = htmlNode.getAttr("data-click")
  if clickOpt.isSome:
    let actionName = clickOpt.get()
    if bindings.clickHandlers.contains(actionName):
      let cb = bindings.clickHandlers.getOrDefault(actionName)
      if cb != nil:
        tree.nodes[containerSlab].onClick = cb

  if isInput:
    let bindOpt = htmlNode.getAttr("data-bind")
    let modelOpt = if bindOpt.isSome: bindOpt else: htmlNode.getAttr("data-model")
    var hasBoundSig = false
    var boundSig: Signal[string]

    if modelOpt.isSome and bindings.inputSignals.contains(modelOpt.get()):
      boundSig = bindings.inputSignals.getOrDefault(modelOpt.get())
      hasBoundSig = true
      if rt != nil:
        if boundSig.get().len == 0 and tree.nodes[containerSlab].text.len > 0:
          boundSig.set(tree.nodes[containerSlab].text)
        bindInput(addr tree, rt, containerSlab, boundSig)

    let inputOpt = htmlNode.getAttr("data-input")
    if inputOpt.isSome and bindings.inputHandlers.contains(inputOpt.get()):
      let userCb = bindings.inputHandlers.getOrDefault(inputOpt.get())
      if userCb != nil:
        if hasBoundSig and tree.nodes[containerSlab].onInput != nil:
          let existingCb = tree.nodes[containerSlab].onInput
          tree.nodes[containerSlab].onInput = proc(text: string) {.closure, gcsafe, raises: [].} =
            existingCb(text)
            userCb(text)
        else:
          tree.nodes[containerSlab].onInput = userCb
  else:
    let dataTextOpt = htmlNode.getAttr("data-text")
    let textKeyOpt = if dataTextOpt.isSome: dataTextOpt else: htmlNode.getAttr("data-bind")
    if textKeyOpt.isSome:
      let key = textKeyOpt.get()
      if bindings.textSignals.contains(key):
        let sig = bindings.textSignals.getOrDefault(key)
        if rt != nil:
          if sig.get().len == 0 and tree.nodes[textSlab].text.len > 0:
            sig.set(tree.nodes[textSlab].text)
          bindText(addr tree, rt, textSlab, proc(): string {.closure, gcsafe, raises: [].} =
            sig.get()
          )
      elif bindings.textProcs.contains(key):
        let fn = bindings.textProcs.getOrDefault(key)
        if rt != nil and fn != nil:
          bindText(addr tree, rt, textSlab, fn)

proc propagateOnClickRecursive(tree: var UiTree, nodeId: SlabId, cb: HtmlClickProc) {.raises: [].} =
  if cb.isNil or not tree.nodes.contains(nodeId):
    return
  let childCount = tree.nodes[nodeId].children.len
  for i in 0 ..< childCount:
    let childId = tree.nodes[nodeId].children[i]
    if tree.nodes.contains(childId):
      if tree.nodes[childId].kind != nkTextInput and tree.nodes[childId].onClick.isNil:
        tree.nodes[childId].onClick = cb
      propagateOnClickRecursive(tree, childId, cb)

proc mountElementRecursive(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  doc: HtmlDoc,
  nodeIdx: int,
  sheet: CssStylesheet,
  parentStyle: CssComputedStyle,
  parentDir: FlexDirection,
  parentAlign: AlignItems,
  parentInnerW, parentInnerH: float32,
  bindings: var HtmlBindingRegistry,
  parentSlab: SlabId
): SlabId {.raises: [].} =
  let node = doc.nodes[nodeIdx]
  if containsTag(HtmlSkipMountTags, node.tag):
    return SlabId(-1)

  let style = computeNodeStyle(doc, nodeIdx, sheet, parentStyle)
  if style.display == cdNone:
    return SlabId(-1)

  if node.tag == "input":
    let typeOpt = node.getAttr("type")
    if typeOpt.isSome and eqIgnoreCase(typeOpt.get(), "hidden"):
      return SlabId(-1)

    let slab = tree.createNode(nkTextInput)
    let valOpt = node.getAttr("value")
    if valOpt.isSome:
      tree.nodes[slab].text = valOpt.get()
    let phOpt = node.getAttr("placeholder")
    if phOpt.isSome:
      tree.nodes[slab].placeholder = phOpt.get()

    tree.nodes[slab].padding = toLayoutPadding(style.padding)
    tree.nodes[slab].widthMode = resolveSizeMode(
      style.width, style.hasFlexGrow, style.flexGrow,
      parentDir == fdRow, parentInnerW, defaultPx = 180.0'f32
    )
    tree.nodes[slab].heightMode = resolveSizeMode(
      style.height, style.hasFlexGrow, style.flexGrow,
      parentDir == fdColumn, parentInnerH,
      defaultPx = style.fontSize + style.padding[0] + style.padding[2] + 6.0'f32
    )
    tree.nodes[slab].bgColor = style.bgColor
    tree.nodes[slab].bgHoverColor = style.bgHoverColor
    tree.nodes[slab].bgActiveColor = style.bgActiveColor
    tree.nodes[slab].borderColor = style.borderColor
    tree.nodes[slab].borderHoverColor = style.borderHoverColor
    tree.nodes[slab].borderWidth = style.borderWidth
    tree.nodes[slab].radius = style.borderRadius
    tree.nodes[slab].textColor = style.fgColor
    tree.nodes[slab].fontSize = style.fontSize

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = true)

    if parentSlab != SlabId(-1):
      tree.addChild(parentSlab, slab)
    return slab

  var elemChildren: seq[int] = @[]
  var directText = ""
  collectDirectTextAndElementChildren(doc, nodeIdx, elemChildren, directText)

  if node.tag == "button":
    let slab = tree.createNode(nkButton)
    tree.nodes[slab].text = if directText.len > 0: directText else: stripAscii(doc.innerText(nodeIdx))
    tree.nodes[slab].padding = toLayoutPadding(style.padding)
    tree.nodes[slab].widthMode = resolveSizeMode(
      style.width, style.hasFlexGrow, style.flexGrow,
      parentDir == fdRow, parentInnerW
    )
    tree.nodes[slab].heightMode = resolveSizeMode(
      style.height, style.hasFlexGrow, style.flexGrow,
      parentDir == fdColumn, parentInnerH
    )
    tree.nodes[slab].alignItems = style.alignItems
    tree.nodes[slab].justifyContent = style.justifyContent
    tree.nodes[slab].bgColor = style.bgColor
    tree.nodes[slab].bgHoverColor = style.bgHoverColor
    tree.nodes[slab].bgActiveColor = style.bgActiveColor
    tree.nodes[slab].borderColor = style.borderColor
    tree.nodes[slab].borderHoverColor = style.borderHoverColor
    tree.nodes[slab].borderWidth = style.borderWidth
    tree.nodes[slab].radius = style.borderRadius
    tree.nodes[slab].textColor = style.fgColor
    tree.nodes[slab].fontSize = style.fontSize

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = false)

    if parentSlab != SlabId(-1):
      tree.addChild(parentSlab, slab)
    return slab

  let hasBoundText = node.getAttr("data-text").isSome or node.getAttr("data-bind").isSome
  let isPureLeafText =
    elemChildren.len == 0 and
    (directText.len > 0 or hasBoundText) and
    not style.hasVisualBoxStyle() and
    node.tag in ["span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label", "strong", "em", "a", "div"]

  if isPureLeafText:
    let slab = tree.createNode(nkText)
    tree.nodes[slab].text = directText
    tree.nodes[slab].textColor = style.fgColor
    tree.nodes[slab].fontSize = style.fontSize
    tree.nodes[slab].widthMode = fitContent()
    tree.nodes[slab].heightMode = fitContent()

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = false)

    if parentSlab != SlabId(-1):
      tree.addChild(parentSlab, slab)
    return slab

  # Container element -> nkBox
  let boxSlab = tree.createNode(nkBox)
  let dir = if style.display == cdFlex:
              if style.flexDirectionSet: style.flexDirection else: fdRow
            elif style.flexDirectionSet:
              style.flexDirection
            else:
              fdColumn

  tree.nodes[boxSlab].direction = dir
  tree.nodes[boxSlab].padding = toLayoutPadding(style.padding)
  tree.nodes[boxSlab].gap = style.gap
  tree.nodes[boxSlab].alignItems = style.alignItems
  tree.nodes[boxSlab].justifyContent = style.justifyContent
  tree.nodes[boxSlab].widthMode = resolveSizeMode(
    style.width, style.hasFlexGrow, style.flexGrow,
    parentDir == fdRow, parentInnerW
  )
  if style.width.kind == cskAuto and (style.display == cdBlock or style.display == cdFlex) and
     parentDir == fdColumn and parentAlign == aiStretch:
    tree.nodes[boxSlab].widthMode = flexGrow(1.0'f32)
  tree.nodes[boxSlab].heightMode = resolveSizeMode(
    style.height, style.hasFlexGrow, style.flexGrow,
    parentDir == fdColumn, parentInnerH
  )
  tree.nodes[boxSlab].bgColor = style.bgColor
  tree.nodes[boxSlab].bgHoverColor = style.bgHoverColor
  tree.nodes[boxSlab].bgActiveColor = style.bgActiveColor
  tree.nodes[boxSlab].borderColor = style.borderColor
  tree.nodes[boxSlab].borderHoverColor = style.borderHoverColor
  tree.nodes[boxSlab].borderWidth = style.borderWidth
  tree.nodes[boxSlab].radius = style.borderRadius
  tree.nodes[boxSlab].textColor = style.fgColor
  tree.nodes[boxSlab].fontSize = style.fontSize
  tree.nodes[boxSlab].isScrollable = style.overflowY

  if node.id.len > 0:
    bindings.idToSlab.put(node.id, boxSlab)

  if parentSlab != SlabId(-1):
    tree.addChild(parentSlab, boxSlab)

  let innerW = computeChildFixedInner(tree.nodes[boxSlab].widthMode, style.padding[1], style.padding[3])
  let innerH = computeChildFixedInner(tree.nodes[boxSlab].heightMode, style.padding[0], style.padding[2])

  var primaryTextSlab = boxSlab
  var attachedTextBinding = false

  for cIdx in doc.nodes[nodeIdx].children:
    let child = doc.nodes[cIdx]
    if child.kind == hnkText:
      let t = stripAscii(child.text)
      if t.len > 0:
        let txtSlab = tree.createNode(nkText)
        tree.nodes[txtSlab].text = t
        tree.nodes[txtSlab].textColor = style.fgColor
        tree.nodes[txtSlab].fontSize = style.fontSize
        tree.nodes[txtSlab].widthMode = fitContent()
        tree.nodes[txtSlab].heightMode = fitContent()
        tree.addChild(boxSlab, txtSlab)
        if not attachedTextBinding:
          primaryTextSlab = txtSlab
          attachedTextBinding = true
    elif child.kind == hnkElement:
      discard mountElementRecursive(
        tree, rt, doc, cIdx, sheet, style, dir, style.alignItems, innerW, innerH, bindings, boxSlab
      )

  if hasBoundText and not attachedTextBinding:
    let txtSlab = tree.createNode(nkText)
    tree.nodes[txtSlab].text = ""
    tree.nodes[txtSlab].textColor = style.fgColor
    tree.nodes[txtSlab].fontSize = style.fontSize
    tree.nodes[txtSlab].widthMode = fitContent()
    tree.nodes[txtSlab].heightMode = fitContent()
    tree.addChild(boxSlab, txtSlab)
    primaryTextSlab = txtSlab

  attachReactiveBindings(tree, rt, bindings, node, boxSlab, primaryTextSlab, isInput = false)
  if not tree.nodes[boxSlab].onClick.isNil:
    propagateOnClickRecursive(tree, boxSlab, tree.nodes[boxSlab].onClick)
  boxSlab

proc collectMountableTopElements(doc: HtmlDoc, outIndices: var seq[int]) {.raises: [].} =
  if doc.nodes.len == 0:
    return
  for cIdx in doc.nodes[0].children:
    let child = doc.nodes[cIdx]
    if child.kind != hnkElement:
      continue
    if child.tag == "html":
      for hcIdx in child.children:
        let hChild = doc.nodes[hcIdx]
        if hChild.kind == hnkElement and not containsTag(HtmlSkipMountTags, hChild.tag):
          outIndices.add(hcIdx)
    elif not containsTag(HtmlSkipMountTags, child.tag):
      outIndices.add(cIdx)

proc mergeStylesheets(a, b: CssStylesheet): CssStylesheet {.raises: [].} =
  result = CssStylesheet(rules: @[])
  var order = 0
  for r in a.rules:
    var copyR = r
    copyR.order = order
    inc order
    result.rules.add(copyR)
  for r in b.rules:
    var copyR = r
    copyR.order = order
    inc order
    result.rules.add(copyR)

proc mountHtml*(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  doc: HtmlDoc,
  sheet: CssStylesheet,
  bindings: var HtmlBindingRegistry,
  parentId: SlabId = SlabId(-1)
): Result[SlabId, string] {.raises: [].} =
  if doc.nodes.len == 0:
    return resErr[SlabId]("Cannot mount empty HtmlDoc")

  var topElements: seq[int] = @[]
  collectMountableTopElements(doc, topElements)

  var mountedTop: seq[SlabId] = @[]
  let baseStyle = defaultRootStyle()

  if parentId == SlabId(-1):
    # Count potentially visible elements so we only wrap when needed
    var visibleIndices: seq[int] = @[]
    for idx in topElements:
      let st = computeNodeStyle(doc, idx, sheet, baseStyle)
      if st.display != cdNone:
        visibleIndices.add(idx)

    if visibleIndices.len == 0:
      let emptyRoot = tree.createNode(nkBox)
      tree.nodes[emptyRoot].widthMode = flexGrow(1.0'f32)
      tree.nodes[emptyRoot].heightMode = flexGrow(1.0'f32)
      if tree.rootId == SlabId(-1):
        tree.rootId = emptyRoot
      return resOk(emptyRoot)

    if visibleIndices.len == 1:
      let rootSlab = mountElementRecursive(
        tree, rt, doc, visibleIndices[0], sheet, baseStyle, fdColumn, aiStretch, -1.0'f32, -1.0'f32,
        bindings, SlabId(-1)
      )
      if rootSlab != SlabId(-1):
        if doc.nodes[visibleIndices[0]].tag == "body":
          if tree.nodes[rootSlab].widthMode.kind == smFitContent:
            tree.nodes[rootSlab].widthMode = flexGrow(1.0'f32)
          if tree.nodes[rootSlab].heightMode.kind == smFitContent:
            tree.nodes[rootSlab].heightMode = flexGrow(1.0'f32)
        if tree.rootId == SlabId(-1):
          tree.rootId = rootSlab
      return resOk(rootSlab)

    let wrapper = tree.createNode(nkBox)
    tree.nodes[wrapper].direction = fdColumn
    tree.nodes[wrapper].alignItems = aiStretch
    tree.nodes[wrapper].widthMode = flexGrow(1.0'f32)
    tree.nodes[wrapper].heightMode = flexGrow(1.0'f32)
    if tree.rootId == SlabId(-1):
      tree.rootId = wrapper
    for idx in visibleIndices:
      discard mountElementRecursive(
        tree, rt, doc, idx, sheet, baseStyle, fdColumn, aiStretch, -1.0'f32, -1.0'f32,
        bindings, wrapper
      )
    return resOk(wrapper)

  # Mounting into existing parentId
  let pNode = tree.nodes[parentId]
  let pInnerW = computeChildFixedInner(pNode.widthMode, pNode.padding[1], pNode.padding[3])
  let pInnerH = computeChildFixedInner(pNode.heightMode, pNode.padding[0], pNode.padding[2])
  for idx in topElements:
    let mId = mountElementRecursive(
      tree, rt, doc, idx, sheet, baseStyle, pNode.direction, pNode.alignItems, pInnerW, pInnerH,
      bindings, parentId
    )
    if mId != SlabId(-1):
      mountedTop.add(mId)

  if mountedTop.len > 0:
    resOk(mountedTop[0])
  else:
    resOk(parentId)

proc mountHtmlString*(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  html: string,
  extraCss: string,
  bindings: var HtmlBindingRegistry,
  parentId: SlabId = SlabId(-1)
): Result[SlabId, string] {.raises: [].} =
  let docRes = parseHtmlDoc(html)
  if docRes.isErr():
    return resErr[SlabId](docRes.error())
  let doc = docRes.get()
  let embeddedSheet = parseCssSheet(doc.embeddedCss)
  let extraSheet = parseCssSheet(extraCss)
  let combined = mergeStylesheets(embeddedSheet, extraSheet)
  mountHtml(tree, rt, doc, combined, bindings, parentId)
