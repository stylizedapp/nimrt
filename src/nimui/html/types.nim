## src/nimui/html/types.nim
##
## Core types, constants, and exception-free ({.raises: [].}) string/number
## primitives for the NimUI HTML5 + CSS3 engine.

import corex/unicode
import corex/adt
import corex/result
import corex/slab
import corex/signals
import algx/swissmap
import ../layout

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

  HtmlScriptBlock* = object
    code*: string
    caps*: string

  HtmlDoc* = object
    nodes*: seq[HtmlNode]
    embeddedCss*: string
    scripts*: seq[HtmlScriptBlock]

  CssPseudoKind* = enum
    cpkNone
    cpkHover
    cpkActive
    cpkFocus
    cpkDisabled
    cpkRoot
    cpkUnknown

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

  CssMediaContext* = object
    viewportWidth*: float32
    viewportHeight*: float32
    prefersDark*: bool

  CssStylesheet* = object
    rules*: seq[CssRule]
    unsupportedProperties*: seq[string]

  CssDisplay* = enum
    cdBlock
    cdFlex
    cdInline
    cdNone

  CssPosition* = enum
    cpStatic
    cpRelative
    cpAbsolute
    cpFixed

  CssFlexWrap* = enum
    cfwNoWrap
    cfwWrap
    cfwWrapReverse

  CssAlignSelf* = enum
    casAuto
    casStart
    casCenter
    casEnd
    casStretch

  CssSizeKind* = enum
    cskAuto
    cskPx
    cskPercent
    cskFlexGrow

  CssSize* = object
    kind*: CssSizeKind
    value*: float32

  CssBoxShadow* = object
    offsetX*: float32
    offsetY*: float32
    blur*: float32
    spread*: float32
    color*: uint32
    inset*: bool

  CssGradientStop* = object
    color*: uint32
    pos*: float32
    hasPos*: bool

  CssLinearGradient* = object
    active*: bool
    angleDeg*: float32
    stops*: seq[CssGradientStop]

  CssCustomVar* = object
    name*: string
    value*: string

  CssComputedStyle* = object
    display*: CssDisplay
    position*: CssPosition
    zIndex*: int
    zIndexSet*: bool
    top*: CssSize
    right*: CssSize
    bottom*: CssSize
    left*: CssSize
    flexDirection*: FlexDirection
    flexDirectionSet*: bool
    flexWrap*: CssFlexWrap
    justifyContent*: JustifyContent
    alignItems*: AlignItems
    alignItemsSet*: bool
    alignSelf*: CssAlignSelf
    width*: CssSize
    height*: CssSize
    minWidth*: CssSize
    maxWidth*: CssSize
    minHeight*: CssSize
    maxHeight*: CssSize
    flexGrow*: float32
    hasFlexGrow*: bool
    flexShrink*: float32
    hasFlexShrink*: bool
    flexBasis*: CssSize
    padding*: array[4, float32]
    paddingSet*: array[4, bool]
    margin*: array[4, float32]
    marginSet*: array[4, bool]
    marginAuto*: array[4, bool]
    gap*: float32
    rowGap*: float32
    columnGap*: float32
    rowGapSet*: bool
    columnGapSet*: bool
    fgColor*: uint32
    fgColorSet*: bool
    bgColor*: uint32
    bgHoverColor*: uint32
    bgActiveColor*: uint32
    bgFocusColor*: uint32
    fgFocusColor*: uint32
    borderColor*: uint32
    borderHoverColor*: uint32
    borderFocusColor*: uint32
    borderWidth*: float32
    borderRadius*: float32
    opacity*: float32
    opacitySet*: bool
    boxShadows*: seq[CssBoxShadow]
    bgGradient*: CssLinearGradient
    fontSize*: float32
    fontSizeSet*: bool
    fontWeight*: int
    fontWeightSet*: bool
    fontFamily*: string
    fontFamilySet*: bool
    lineHeight*: float32
    lineHeightIsPx*: bool
    lineHeightSet*: bool
    cursor*: string
    cursorSet*: bool
    textOverflow*: string
    whiteSpace*: string
    whiteSpaceSet*: bool
    listStyleType*: string
    listStyleSet*: bool
    transition*: string
    overflowY*: bool
    customVars*: seq[CssCustomVar]
    unsupportedProperties*: seq[string]

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
  HtmlVoidTags* = [
    "area", "base", "br", "col", "embed", "hr", "img",
    "input", "link", "meta", "param", "source", "track", "wbr"
  ]
  HtmlSkipMountTags* = ["head", "style", "script", "meta", "link", "title"]
  SvgChildTags* = [
    "path", "circle", "rect", "line", "polygon", "polyline", "ellipse",
    "g", "defs", "lineargradient", "radialgradient", "stop", "use",
    "title", "desc", "clippath", "mask", "pattern"
  ]
  MaxHtmlNestingDepth* = 512
  MaxCssVarDepth* = 16
  MaxMediaRecursionDepth* = 16
  MaxMountDepth* = 256

  ## Opt-in CSS custom property palette for NimUI's legacy theme tokens.
  NimUiThemePaletteCss* = """
:root {
  --slate: #64748B;
  --indigo: #4F46E5;
  --emerald: #10B981;
  --rose: #F43F5E;
  --amber: #F59E0B;
  --obsidian: #0A0A0C;
  --midnight: #111116;
}
"""

proc defaultCssMediaContext*(): CssMediaContext {.inline, raises: [].} =
  CssMediaContext(viewportWidth: 1440.0'f32, viewportHeight: 900.0'f32, prefersDark: true)

# =============================================================================
# Exception-Free ASCII, String & Number Helpers ({.raises: [].})
# =============================================================================

proc isSpaceChar*(c: char): bool {.inline, raises: [].} =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f' or c == '\v'

proc isAlphaAscii*(c: char): bool {.inline, raises: [].} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc isDigitAscii*(c: char): bool {.inline, raises: [].} =
  c >= '0' and c <= '9'

proc isHexDigitAscii*(c: char): bool {.inline, raises: [].} =
  (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

proc toLowerChar*(c: char): char {.inline, raises: [].} =
  if c >= 'A' and c <= 'Z':
    char(ord(c) + 32)
  else:
    c

proc htmlToLowerAscii*(s: string): string {.raises: [].} =
  result = newString(s.len)
  for i in 0 ..< s.len:
    result[i] = toLowerChar(s[i])

proc htmlStripAscii*(s: string): string {.raises: [].} =
  var i = 0
  var j = s.len - 1
  while i <= j and isSpaceChar(s[i]):
    inc i
  while j >= i and isSpaceChar(s[j]):
    dec j
  if i > j:
    return ""
  result = s[i .. j]

proc htmlStartsWithAscii*(s, prefix: string): bool {.inline, raises: [].} =
  if prefix.len > s.len:
    return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]:
      return false
  true

proc htmlEndsWithAscii*(s, suffix: string): bool {.inline, raises: [].} =
  if suffix.len > s.len:
    return false
  let off = s.len - suffix.len
  for i in 0 ..< suffix.len:
    if s[off + i] != suffix[i]:
      return false
  true

proc htmlStartsWithIgnoreCase*(s, prefix: string; offset = 0): bool {.inline, raises: [].} =
  if offset < 0 or offset + prefix.len > s.len:
    return false
  for i in 0 ..< prefix.len:
    if toLowerChar(s[offset + i]) != toLowerChar(prefix[i]):
      return false
  true

proc htmlEqIgnoreCase*(a, b: string): bool {.inline, raises: [].} =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if toLowerChar(a[i]) != toLowerChar(b[i]):
      return false
  true

proc containsTag*(list: openArray[string], tag: string): bool {.inline, raises: [].} =
  for item in list:
    if item == tag:
      return true
  false

proc htmlSplitWhitespace*(s: string): seq[string] {.raises: [].} =
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

proc collapseHtmlWhitespace*(s: string): string {.raises: [].} =
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

proc parseIntSafe*(s: string): Option[int] {.raises: [].} =
  let t = htmlStripAscii(s)
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

proc parseHexUintSafe*(s: string): Option[uint32] {.raises: [].} =
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

proc parseFloatSafe*(s: string): Option[float32] {.raises: [].} =
  let t = htmlStripAscii(s)
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

proc parseCssLength*(s: string): Option[float32] {.raises: [].} =
  let t = htmlToLowerAscii(htmlStripAscii(s))
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

proc parseCssPercent*(s: string): Option[float32] {.raises: [].} =
  let t = htmlStripAscii(s)
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

proc resOk*[T](val: T): Result[T, string] {.inline, raises: [].} =
  Result[T, string].ok(val)

proc resErr*[T](msg: string): Result[T, string] {.inline, raises: [].} =
  Result[T, string].err(msg)
