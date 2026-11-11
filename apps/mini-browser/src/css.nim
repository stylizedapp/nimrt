## apps/mini-browser/src/css.nim
## CSS Tokenizer and Level 0 Parser for the Nim High-Performance Mini-Browser
import corex

type
  CssTokenKind* = enum
    ctIdent,        # selector, property name, keyword (e.g. h1, color, red, none)
    ctHash,         # #ff0000, #fff
    ctDimension,    # 24px, 100px, 1.5em
    ctNumber,       # 0, 100, 24
    ctLBrace,       # {
    ctRBrace,       # }
    ctColon,        # :
    ctSemicolon,    # ;
    ctComma,        # ,
    ctEof           # End of input

  CssToken* = object
    kind*: CssTokenKind
    text*: Span[byte]
    offset*: int

  Declaration* = object
    property*: Span[byte]
    value*: Span[byte]

  Rule* = object
    selector*: Span[byte]
    declarations*: BufSeq[Declaration]

  StyleSheet* = object
    rules*: BufSeq[Rule]
    source*: Span[byte]

  CssError* = object
    msg*: string
    offset*: int

# =============================================================================
# String & Span Utilities
# =============================================================================

proc `==`(s: Span[byte], str: string): bool {.inline, raises: [].} =
  if s.len != str.len: return false
  if s.len == 0: return true
  if s.data.isNil: return false
  for i in 0 ..< s.len:
    if s.data[i] != byte(str[i]): return false
  return true

proc `==`(str: string, s: Span[byte]): bool {.inline, raises: [].} =
  s == str

proc eqIgnoreCase*(s: Span[byte], str: string): bool {.inline, raises: [].} =
  if s.len != str.len: return false
  if s.len == 0: return true
  if s.data.isNil: return false
  for i in 0 ..< s.len:
    var c1 = s.data[i]
    var c2 = byte(str[i])
    if c1 >= byte('A') and c1 <= byte('Z'): c1 = c1 + 32'u8
    if c2 >= byte('A') and c2 <= byte('Z'): c2 = c2 + 32'u8
    if c1 != c2: return false
  return true

proc eqIgnoreCase*(a: Span[byte], b: Span[byte]): bool {.inline, raises: [].} =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    var c1 = a.data[i]
    var c2 = b.data[i]
    if c1 >= byte('A') and c1 <= byte('Z'): c1 = c1 + 32'u8
    if c2 >= byte('A') and c2 <= byte('Z'): c2 = c2 + 32'u8
    if c1 != c2: return false
  return true

template isWhitespace(b: byte): bool =
  b == byte(' ') or b == byte('\t') or b == byte('\r') or b == byte('\n')

template isDigit(b: byte): bool =
  b >= byte('0') and b <= byte('9')

template isIdentStart(b: byte): bool =
  (b >= byte('a') and b <= byte('z')) or
  (b >= byte('A') and b <= byte('Z')) or
  b == byte('_') or b == byte('-')

template isIdentChar(b: byte): bool =
  isIdentStart(b) or isDigit(b)

template isHexChar(b: byte): bool =
  isDigit(b) or
  (b >= byte('a') and b <= byte('f')) or
  (b >= byte('A') and b <= byte('F'))

# =============================================================================
# Tokenizer Implementation
# =============================================================================

proc skipWhitespaceAndComments(source: openArray[byte], pos: var int): Result[void, CssError] {.raises: [].} =
  let totalLen = source.len
  while pos < totalLen:
    let b = source[pos]
    if isWhitespace(b):
      inc(pos)
    elif b == byte('/') and pos + 1 < totalLen and source[pos + 1] == byte('*'):
      # CSS comment /* ... */
      let commentStart = pos
      pos += 2
      var closed = false
      while pos + 1 < totalLen:
        if source[pos] == byte('*') and source[pos + 1] == byte('/'):
          pos += 2
          closed = true
          break
        inc(pos)
      if not closed:
        return err[void, CssError](CssError(msg: "Unclosed CSS comment", offset: commentStart))
    else:
      break
  ok[void, CssError]()

proc tokenizeCss*(source: openArray[byte], alloc: Allocator = defaultHeapAllocator()): Result[BufSeq[CssToken], CssError] {.raises: [].} =
  let a = if alloc.allocFn != nil: alloc else: defaultHeapAllocator()
  var tokensRes = initBufSeq[CssToken](a, 16)
  if tokensRes.isErr:
    return err[BufSeq[CssToken], CssError](CssError(msg: "Out of memory", offset: 0))
  var tokens = tokensRes.get()

  let sourceSpan = if source.len > 0: span(source) else: Span[byte](data: nil, len: 0)
  var pos = 0
  let totalLen = source.len

  while pos < totalLen:
    let skipRes = skipWhitespaceAndComments(source, pos)
    if skipRes.isErr:
      return err[BufSeq[CssToken], CssError](skipRes.errVal)
    if pos >= totalLen:
      break

    let start = pos
    let b = source[pos]

    case b
    of byte('{'):
      tokens.add(CssToken(kind: ctLBrace, text: sourceSpan.subspan(start, 1), offset: start))
      inc(pos)
    of byte('}'):
      tokens.add(CssToken(kind: ctRBrace, text: sourceSpan.subspan(start, 1), offset: start))
      inc(pos)
    of byte(':'):
      tokens.add(CssToken(kind: ctColon, text: sourceSpan.subspan(start, 1), offset: start))
      inc(pos)
    of byte(';'):
      tokens.add(CssToken(kind: ctSemicolon, text: sourceSpan.subspan(start, 1), offset: start))
      inc(pos)
    of byte(','):
      tokens.add(CssToken(kind: ctComma, text: sourceSpan.subspan(start, 1), offset: start))
      inc(pos)
    of byte('#'):
      # Hash token (#ff0000, #abc)
      inc(pos)
      let hashStart = pos
      while pos < totalLen and (isHexChar(source[pos]) or isIdentChar(source[pos])):
        inc(pos)
      if pos == hashStart:
        return err[BufSeq[CssToken], CssError](CssError(msg: "Expected identifier or hex code after '#'", offset: start))
      tokens.add(CssToken(kind: ctHash, text: sourceSpan.subspan(start, pos - start), offset: start))
    of byte('0') .. byte('9'), byte('.'):
      # Number or Dimension
      var hasDot = b == byte('.')
      inc(pos)
      while pos < totalLen:
        let cur = source[pos]
        if cur == byte('.'):
          if hasDot: break
          hasDot = true
          inc(pos)
        elif isDigit(cur):
          inc(pos)
        else:
          break
      # Check if unit follows (dimension, e.g. px, em, rem, %)
      let numEnd = pos
      if pos < totalLen and source[pos] == byte('%'):
        inc(pos)
        tokens.add(CssToken(kind: ctDimension, text: sourceSpan.subspan(start, pos - start), offset: start))
      elif pos < totalLen and isIdentStart(source[pos]):
        while pos < totalLen and isIdentChar(source[pos]):
          inc(pos)
        tokens.add(CssToken(kind: ctDimension, text: sourceSpan.subspan(start, pos - start), offset: start))
      else:
        tokens.add(CssToken(kind: ctNumber, text: sourceSpan.subspan(start, numEnd - start), offset: start))
    else:
      if isIdentStart(b):
        inc(pos)
        while pos < totalLen and isIdentChar(source[pos]):
          inc(pos)
        tokens.add(CssToken(kind: ctIdent, text: sourceSpan.subspan(start, pos - start), offset: start))
      else:
        return err[BufSeq[CssToken], CssError](CssError(msg: "Unexpected character in CSS: '" & $char(b) & "'", offset: start))

  tokens.add(CssToken(kind: ctEof, text: Span[byte](data: nil, len: 0), offset: pos))
  ok[BufSeq[CssToken], CssError](tokens)

proc tokenizeCss*(source: string, alloc: Allocator = defaultHeapAllocator()): Result[BufSeq[CssToken], CssError] {.inline, raises: [].} =
  if source.len == 0:
    var empty: array[0, byte]
    tokenizeCss(empty, alloc)
  else:
    tokenizeCss(source.toOpenArrayByte(0, source.len - 1), alloc)

# =============================================================================
# Level 0 Parser Implementation
# =============================================================================

proc parseCssTokens*(tokens: BufSeq[CssToken], sourceSpan: Span[byte], alloc: Allocator = defaultHeapAllocator()): Result[StyleSheet, CssError] {.raises: [].} =
  let a = if alloc.allocFn != nil: alloc else: defaultHeapAllocator()
  var rulesRes = initBufSeq[Rule](a, 4)
  if rulesRes.isErr:
    return err[StyleSheet, CssError](CssError(msg: "Out of memory", offset: 0))
  var rules = rulesRes.get()

  var idx = 0
  let n = tokens.len

  while idx < n:
    let tok = tokens[idx]
    if tok.kind == ctEof:
      break

    # 1. Selector
    if tok.kind != ctIdent:
      return err[StyleSheet, CssError](CssError(msg: "Expected selector identifier, got " & $tok.kind, offset: tok.offset))

    let selector = tok.text
    inc(idx)

    # Allow comma-separated selectors (for level 0, we can expand or take single)
    # E.g. h1, h2 { ... }
    var extraSelectors: seq[Span[byte]] = @[]
    while idx < n and tokens[idx].kind == ctComma:
      inc(idx) # skip comma
      if idx >= n or tokens[idx].kind != ctIdent:
        return err[StyleSheet, CssError](CssError(msg: "Expected selector after comma", offset: if idx < n: tokens[idx].offset else: tok.offset))
      extraSelectors.add(tokens[idx].text)
      inc(idx)

    # 2. Left brace '{'
    if idx >= n or tokens[idx].kind != ctLBrace:
      let off = if idx < n: tokens[idx].offset else: tok.offset
      return err[StyleSheet, CssError](CssError(msg: "Expected '{' after selector", offset: off))
    inc(idx) # skip '{'

    # 3. Declarations until '}'
    var declsRes = initBufSeq[Declaration](a, 4)
    if declsRes.isErr:
      return err[StyleSheet, CssError](CssError(msg: "Out of memory", offset: 0))
    var decls = declsRes.get()

    while idx < n and tokens[idx].kind != ctRBrace and tokens[idx].kind != ctEof:
      if tokens[idx].kind == ctSemicolon:
        inc(idx)
        continue

      # Property name
      let propTok = tokens[idx]
      if propTok.kind != ctIdent:
        return err[StyleSheet, CssError](CssError(msg: "Expected property name, got " & $propTok.kind, offset: propTok.offset))
      let propName = propTok.text
      inc(idx)

      # Colon ':'
      if idx >= n or tokens[idx].kind != ctColon:
        let off = if idx < n: tokens[idx].offset else: propTok.offset
        return err[StyleSheet, CssError](CssError(msg: "Expected ':' after property name", offset: off))
      inc(idx) # skip ':'

      # Value: collect tokens until ';' or '}'
      let valStartIdx = idx
      if idx >= n or tokens[idx].kind == ctSemicolon or tokens[idx].kind == ctRBrace:
        let off = if idx < n: tokens[idx].offset else: propTok.offset
        return err[StyleSheet, CssError](CssError(msg: "Expected value for property", offset: off))

      # Find value start offset and end offset in source
      let firstValTok = tokens[idx]
      var lastValTok = firstValTok

      while idx < n and tokens[idx].kind != ctSemicolon and tokens[idx].kind != ctRBrace and tokens[idx].kind != ctEof:
        lastValTok = tokens[idx]
        inc(idx)

      let valStartOffset = firstValTok.offset
      let valEndOffset = lastValTok.offset + lastValTok.text.len
      let valSpan = sourceSpan.subspan(valStartOffset, valEndOffset - valStartOffset)

      decls.add(Declaration(property: propName, value: valSpan))

      if idx < n and tokens[idx].kind == ctSemicolon:
        inc(idx) # skip ';'

    # Check for closing '}'
    if idx >= n or tokens[idx].kind != ctRBrace:
      let off = if idx < n: tokens[idx].offset else: tok.offset
      return err[StyleSheet, CssError](CssError(msg: "Unclosed rule: expected '}'", offset: off))
    inc(idx) # skip '}'

    rules.add(Rule(selector: selector, declarations: decls))
    for s in extraSelectors:
      # Shallow copy decls for extra selectors
      var extraDeclsRes = initBufSeq[Declaration](a, decls.len)
      if extraDeclsRes.isOk:
        var extraDecls = extraDeclsRes.get()
        for d in decls: extraDecls.add(d)
        rules.add(Rule(selector: s, declarations: extraDecls))

  ok[StyleSheet, CssError](StyleSheet(rules: rules, source: sourceSpan))

proc parseCss*(source: openArray[byte], alloc: Allocator = defaultHeapAllocator()): Result[StyleSheet, CssError] {.raises: [].} =
  let a = if alloc.allocFn != nil: alloc else: defaultHeapAllocator()
  let sourceSpan = if source.len > 0: span(source) else: Span[byte](data: nil, len: 0)
  if source.len == 0:
    var emptyRulesRes = initBufSeq[Rule](a, 0)
    let emptyRules = if emptyRulesRes.isOk: emptyRulesRes.get() else: BufSeq[Rule]()
    return ok[StyleSheet, CssError](StyleSheet(rules: emptyRules, source: sourceSpan))

  let tokensRes = tokenizeCss(source, a)
  if tokensRes.isErr:
    return err[StyleSheet, CssError](tokensRes.errVal)

  parseCssTokens(tokensRes.get(), sourceSpan, a)

proc parseCss*(source: string, alloc: Allocator = defaultHeapAllocator()): Result[StyleSheet, CssError] {.inline, raises: [].} =
  if source.len == 0:
    var empty: array[0, byte]
    parseCss(empty, alloc)
  else:
    parseCss(source.toOpenArrayByte(0, source.len - 1), alloc)
