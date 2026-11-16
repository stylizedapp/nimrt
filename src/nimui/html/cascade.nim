## src/nimui/html/cascade.nim
##
## CSS3 color, gradient, box-shadow, media-query, custom-property (`var()`),
## selector matching, and specificity cascade engine.

import std/math
import corex/adt
import ../layout
import ./types
import ./parser

# =============================================================================
# Color Parsing (Standard CSS3 Named Colors + Hex + RGB/RGBA + HSL/HSLA)
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

proc clampByteF*(v: float32): uint32 {.inline, raises: [].} =
  if v <= 0.0'f32: 0'u32
  elif v >= 255.0'f32: 255'u32
  else: uint32(v + 0.5'f32)

proc packRgba*(r, g, b, a: uint32): uint32 {.inline, raises: [].} =
  ((r and 0xFF'u32) shl 24) or ((g and 0xFF'u32) shl 16) or ((b and 0xFF'u32) shl 8) or (a and 0xFF'u32)

proc applyColorOpacity*(col: uint32, opacity: float32): uint32 {.inline, raises: [].} =
  if col == 0'u32 or opacity >= 1.0'f32:
    return col
  let clampedOp = if opacity <= 0.0'f32: 0.0'f32 else: opacity
  let a = float32(col and 0xFF'u32)
  let newA = clampByteF(a * clampedOp)
  (col and 0xFFFFFF00'u32) or newA

proc hueToRgb(p, q, tIn: float32): float32 {.inline, raises: [].} =
  var t = tIn
  if t < 0.0'f32: t += 1.0'f32
  if t > 1.0'f32: t -= 1.0'f32
  if t < 1.0'f32 / 6.0'f32: return p + (q - p) * 6.0'f32 * t
  if t < 0.5'f32: return q
  if t < 2.0'f32 / 3.0'f32: return p + (q - p) * (2.0'f32 / 3.0'f32 - t) * 6.0'f32
  p

proc splitFuncArgs(inner: string): seq[string] {.raises: [].} =
  var parts: seq[string] = @[]
  var start = 0
  for i in 0 ..< inner.len:
    if inner[i] == ',' or inner[i] == '/':
      let tok = htmlStripAscii(inner[start ..< i])
      if tok.len > 0:
        parts.add(tok)
      start = i + 1
  let lastTok = htmlStripAscii(inner[start ..< inner.len])
  if lastTok.len > 0:
    parts.add(lastTok)
  if parts.len == 1:
    parts = htmlSplitWhitespace(inner)
  parts

proc parseAlphaComponent(tok: string): Option[uint32] {.raises: [].} =
  let pct = parseCssPercent(tok)
  if pct.isSome:
    let p = clamp(pct.get(), 0.0'f32, 100.0'f32)
    return some(clampByteF((p / 100.0'f32) * 255.0'f32))
  let ao = parseFloatSafe(tok)
  if ao.isNone:
    return none[uint32]()
  let af = ao.get()
  if af <= 1.0'f32:
    some(clampByteF(af * 255.0'f32))
  else:
    some(clampByteF(af))

proc parseCssColor*(raw: string): Option[uint32] {.raises: [].} =
  ## Parses standard CSS3 colors: #hex, rgb/rgba, hsl/hsla, and standard named colors.
  let s = htmlToLowerAscii(htmlStripAscii(raw))
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

  if htmlStartsWithAscii(s, "rgb(") or htmlStartsWithAscii(s, "rgba("):
    let openIdx = if htmlStartsWithAscii(s, "rgba("): 5 else: 4
    if s[^1] != ')':
      return none[uint32]()
    let parts = splitFuncArgs(s[openIdx ..< s.len - 1])
    if parts.len < 3 or parts.len > 4:
      return none[uint32]()
    var rgbVals: array[3, uint32]
    for i in 0 ..< 3:
      let pct = parseCssPercent(parts[i])
      if pct.isSome:
        rgbVals[i] = clampByteF((clamp(pct.get(), 0.0'f32, 100.0'f32) / 100.0'f32) * 255.0'f32)
      else:
        let fo = parseFloatSafe(parts[i])
        if fo.isNone:
          return none[uint32]()
        rgbVals[i] = clampByteF(fo.get())
    var aByte = 255'u32
    if parts.len == 4:
      let ao = parseAlphaComponent(parts[3])
      if ao.isNone:
        return none[uint32]()
      aByte = ao.get()
    return some(packRgba(rgbVals[0], rgbVals[1], rgbVals[2], aByte))

  if htmlStartsWithAscii(s, "hsl(") or htmlStartsWithAscii(s, "hsla("):
    let openIdx = if htmlStartsWithAscii(s, "hsla("): 5 else: 4
    if s[^1] != ')':
      return none[uint32]()
    let parts = splitFuncArgs(s[openIdx ..< s.len - 1])
    if parts.len < 3 or parts.len > 4:
      return none[uint32]()
    var hStr = parts[0]
    if hStr.len > 3 and htmlEndsWithAscii(hStr, "deg"):
      hStr = hStr[0 ..< hStr.len - 3]
    let ho = parseFloatSafe(hStr)
    let so = parseCssPercent(parts[1])
    let lo = parseCssPercent(parts[2])
    if ho.isNone or so.isNone or lo.isNone:
      return none[uint32]()
    var h = (ho.get() mod 360.0'f32)
    if h < 0.0'f32: h += 360.0'f32
    h /= 360.0'f32
    let sat = clamp(so.get(), 0.0'f32, 100.0'f32) / 100.0'f32
    let lit = clamp(lo.get(), 0.0'f32, 100.0'f32) / 100.0'f32
    var rF, gF, bF: float32
    if sat == 0.0'f32:
      rF = lit; gF = lit; bF = lit
    else:
      let q = if lit < 0.5'f32: lit * (1.0'f32 + sat) else: lit + sat - lit * sat
      let p = 2.0'f32 * lit - q
      rF = hueToRgb(p, q, h + 1.0'f32 / 3.0'f32)
      gF = hueToRgb(p, q, h)
      bF = hueToRgb(p, q, h - 1.0'f32 / 3.0'f32)
    var aByte = 255'u32
    if parts.len == 4:
      let ao = parseAlphaComponent(parts[3])
      if ao.isNone:
        return none[uint32]()
      aByte = ao.get()
    return some(packRgba(clampByteF(rF * 255.0'f32), clampByteF(gF * 255.0'f32), clampByteF(bF * 255.0'f32), aByte))

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
  of "maroon": some(0x800000FF'u32)
  of "olive": some(0x808000FF'u32)
  of "orange": some(0xFFA500FF'u32)
  of "purple": some(0x800080FF'u32)
  of "rebeccapurple": some(0x663399FF'u32)
  of "navy": some(0x000080FF'u32)
  of "teal": some(0x008080FF'u32)
  of "coral": some(0xFF7F50FF'u32)
  of "crimson": some(0xDC143CFF'u32)
  of "gold": some(0xFFD700FF'u32)
  of "pink": some(0xFFC0CBFF'u32)
  of "brown": some(0xA52A2AFF'u32)
  of "violet": some(0xEE82EEFF'u32)
  of "skyblue": some(0x87CEEBFF'u32)
  of "royalblue": some(0x4169E1FF'u32)
  of "dodgerblue": some(0x1E90FFFF'u32)
  of "steelblue": some(0x4682B4FF'u32)
  of "tomato": some(0xFF6347FF'u32)
  of "salmon": some(0xFA8072FF'u32)
  of "plum": some(0xDDA0DDFF'u32)
  of "orchid": some(0xDA70D6FF'u32)
  of "turquoise": some(0x40E0D0FF'u32)
  of "khaki": some(0xF0E68CFF'u32)
  of "lavender": some(0xE6E6FAFF'u32)
  of "ivory": some(0xFFFFF0FF'u32)
  of "beige": some(0xF5F5DCFF'u32)
  of "snow": some(0xFFFAFAFF'u32)
  of "midnightblue": some(0x191970FF'u32)
  of "slategray", "slategrey": some(0x708090FF'u32)
  of "darkslategray", "darkslategrey": some(0x2F4F4FFF'u32)
  of "lightslategray", "lightslategrey": some(0x778899FF'u32)
  of "darkred": some(0x8B0000FF'u32)
  of "darkgreen": some(0x006400FF'u32)
  of "darkblue": some(0x00008BFF'u32)
  of "lightgray", "lightgrey": some(0xD3D3D3FF'u32)
  of "darkgray", "darkgrey": some(0xA9A9A9FF'u32)
  else: none[uint32]()

proc parseThemeColor*(raw: string): Option[uint32] {.raises: [].} =
  ## Opt-in theme resolver supporting standard CSS3 colors plus NimUI named palette tokens.
  let stdCol = parseCssColor(raw)
  if stdCol.isSome:
    return stdCol
  case htmlToLowerAscii(htmlStripAscii(raw))
  of "slate": some(0x64748BFF'u32)
  of "indigo": some(0x4F46E5FF'u32)
  of "emerald": some(0x10B981FF'u32)
  of "rose": some(0xF43F5EFF'u32)
  of "amber": some(0xF59E0BFF'u32)
  of "obsidian": some(0x0A0A0CFF'u32)
  of "midnight": some(0x111116FF'u32)
  else: none[uint32]()

# =============================================================================
# CSS Comments, Tokenizing & Custom Property (`var()`) Resolution
# =============================================================================

proc stripCssComments*(css: string): string {.raises: [].} =
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

proc splitCssValueTokens*(val: string): seq[string] {.raises: [].} =
  # Keeps parenthesized sub-expressions like rgb(1, 2, 3) and quoted strings together.
  result = @[]
  var i = 0
  while i < val.len:
    while i < val.len and isSpaceChar(val[i]):
      inc i
    if i >= val.len:
      break
    let start = i
    var depth = 0
    var inQuote = '\0'
    while i < val.len:
      let c = val[i]
      if inQuote != '\0':
        if c == '\\' and i + 1 < val.len:
          inc i
        elif c == inQuote:
          inQuote = '\0'
      else:
        if c == '"' or c == '\'':
          inQuote = c
        elif c == '(':
          inc depth
        elif c == ')' and depth > 0:
          dec depth
        elif isSpaceChar(c) and depth == 0:
          break
      inc i
    result.add(val[start ..< i])

proc splitTopLevelCommas*(s: string): seq[string] {.raises: [].} =
  result = @[]
  var start = 0
  var depth = 0
  var inQuote = '\0'
  for i in 0 ..< s.len:
    let c = s[i]
    if inQuote != '\0':
      if c == inQuote and (i == 0 or s[i - 1] != '\\'):
        inQuote = '\0'
    else:
      if c == '"' or c == '\'':
        inQuote = c
      elif c == '(':
        inc depth
      elif c == ')' and depth > 0:
        dec depth
      elif c == ',' and depth == 0:
        result.add(htmlStripAscii(s[start ..< i]))
        start = i + 1
  if start <= s.len:
    let tail = htmlStripAscii(s[start ..< s.len])
    if tail.len > 0 or result.len > 0:
      result.add(tail)

proc setCustomVar(vars: var seq[CssCustomVar], name, val: string) {.raises: [].} =
  for i in 0 ..< vars.len:
    if vars[i].name == name:
      vars[i].value = val
      return
  vars.add(CssCustomVar(name: name, value: val))

proc lookupCustomVar(vars: seq[CssCustomVar], name: string): Option[string] {.raises: [].} =
  for i in countdown(vars.len - 1, 0):
    if vars[i].name == name:
      return some(vars[i].value)
  none[string]()

proc resolveCssVarsImpl(
  val: string,
  vars: seq[CssCustomVar],
  depth: int,
  visiting: var seq[string]
): string {.raises: [].} =
  ## Expands CSS custom property calls `var(--name)` and `var(--name, fallback)` with cycle detection.
  if depth >= MaxCssVarDepth:
    return ""
  if val.len < 6:
    return val

  result = newStringOfCap(val.len)
  var i = 0
  var inQuote = '\0'
  while i < val.len:
    let c = val[i]
    if inQuote != '\0':
      result.add(c)
      if c == '\\' and i + 1 < val.len:
        inc i
        result.add(val[i])
      elif c == inQuote:
        inQuote = '\0'
      inc i
      continue

    if c == '"' or c == '\'':
      inQuote = c
      result.add(c)
      inc i
      continue

    if (c == 'v' or c == 'V') and htmlStartsWithIgnoreCase(val, "var(", i):
      let prevOk = (i == 0) or (not isAlphaAscii(val[i - 1]) and not isDigitAscii(val[i - 1]) and val[i - 1] != '-' and val[i - 1] != '_')
      if prevOk:
        var j = i + 4
        var pDepth = 1
        var q = '\0'
        while j < val.len and pDepth > 0:
          let ch = val[j]
          if q != '\0':
            if ch == '\\' and j + 1 < val.len:
              inc j
            elif ch == q:
              q = '\0'
          else:
            if ch == '"' or ch == '\'':
              q = ch
            elif ch == '(':
              inc pDepth
            elif ch == ')':
              dec pDepth
              if pDepth == 0:
                break
          inc j

        if pDepth == 0 and j < val.len and val[j] == ')':
          let inner = val[i + 4 ..< j]
          var commaPos = -1
          var innerDepth = 0
          var innerQ = '\0'
          for k in 0 ..< inner.len:
            let ic = inner[k]
            if innerQ != '\0':
              if ic == innerQ and (k == 0 or inner[k - 1] != '\\'):
                innerQ = '\0'
            else:
              if ic == '"' or ic == '\'':
                innerQ = ic
              elif ic == '(':
                inc innerDepth
              elif ic == ')' and innerDepth > 0:
                dec innerDepth
              elif ic == ',' and innerDepth == 0:
                commaPos = k
                break

          let varName = if commaPos >= 0: htmlStripAscii(inner[0 ..< commaPos]) else: htmlStripAscii(inner)
          let hasFallback = commaPos >= 0
          let fallbackRaw = if hasFallback: htmlStripAscii(inner[commaPos + 1 ..< inner.len]) else: ""

          if varName.len >= 2 and varName[0] == '-' and varName[1] == '-':
            var isCycle = false
            for v in visiting:
              if v == varName:
                isCycle = true
                break
            if not isCycle:
              let found = lookupCustomVar(vars, varName)
              if found.isSome and found.get().len > 0:
                visiting.add(varName)
                let resolved = resolveCssVarsImpl(found.get(), vars, depth + 1, visiting)
                discard visiting.pop()
                if resolved.len > 0:
                  result.add(resolved)
                  i = j + 1
                  continue
            if hasFallback:
              result.add(resolveCssVarsImpl(fallbackRaw, vars, depth + 1, visiting))
              i = j + 1
              continue
            else:
              i = j + 1
              continue
    result.add(c)
    inc i

proc resolveCssVars*(val: string, vars: seq[CssCustomVar], depth: int = 0): string {.raises: [].} =
  var visiting: seq[string] = @[]
  resolveCssVarsImpl(val, vars, depth, visiting)

# =============================================================================
# Linear Gradient & Box Shadow Parsers
# =============================================================================

proc lerpByte(a, b: uint32, t: float32): uint32 {.inline, raises: [].} =
  clampByteF(float32(a) + (float32(b) - float32(a)) * t)

proc blendColorMidpoint(a, b: uint32): uint32 {.inline, raises: [].} =
  let ar = (a shr 24) and 0xFF'u32
  let ag = (a shr 16) and 0xFF'u32
  let ab = (a shr 8) and 0xFF'u32
  let aa = a and 0xFF'u32
  let br = (b shr 24) and 0xFF'u32
  let bg = (b shr 16) and 0xFF'u32
  let bb = (b shr 8) and 0xFF'u32
  let ba = b and 0xFF'u32
  packRgba(lerpByte(ar, br, 0.5'f32), lerpByte(ag, bg, 0.5'f32), lerpByte(ab, bb, 0.5'f32), lerpByte(aa, ba, 0.5'f32))

proc parseGradientAngle(tok: string): Option[float32] {.raises: [].} =
  let s = htmlToLowerAscii(htmlStripAscii(tok))
  if s.len == 0:
    return none[float32]()
  if htmlEndsWithAscii(s, "deg"):
    return parseFloatSafe(s[0 ..< s.len - 3])
  if htmlEndsWithAscii(s, "turn"):
    let f = parseFloatSafe(s[0 ..< s.len - 4])
    if f.isSome: return some(f.get() * 360.0'f32)
    return none[float32]()
  if htmlEndsWithAscii(s, "grad"):
    let f = parseFloatSafe(s[0 ..< s.len - 4])
    if f.isSome: return some(f.get() * 0.9'f32)
    return none[float32]()
  if htmlEndsWithAscii(s, "rad"):
    let f = parseFloatSafe(s[0 ..< s.len - 3])
    if f.isSome: return some(f.get() * (180.0'f32 / PI.float32))
    return none[float32]()
  if htmlStartsWithAscii(s, "to "):
    let dir = htmlStripAscii(s[3 ..< s.len])
    case dir
    of "top": return some(0.0'f32)
    of "right": return some(90.0'f32)
    of "bottom": return some(180.0'f32)
    of "left": return some(270.0'f32)
    of "top right", "right top": return some(45.0'f32)
    of "bottom right", "right bottom": return some(135.0'f32)
    of "bottom left", "left bottom": return some(225.0'f32)
    of "top left", "left top": return some(315.0'f32)
    else: return none[float32]()
  none[float32]()

proc parseLinearGradient*(raw: string): Option[CssLinearGradient] {.raises: [].} =
  let s = htmlStripAscii(raw)
  if not htmlStartsWithIgnoreCase(s, "linear-gradient(") or s.len < 18 or s[^1] != ')':
    return none[CssLinearGradient]()
  let inner = htmlStripAscii(s[16 ..< s.len - 1])
  if inner.len == 0:
    return none[CssLinearGradient]()

  let args = splitTopLevelCommas(inner)
  if args.len == 0:
    return none[CssLinearGradient]()

  var angle = 180.0'f32
  var startIdx = 0
  let angleOpt = parseGradientAngle(args[0])
  if angleOpt.isSome:
    angle = angleOpt.get()
    startIdx = 1

  var stops: seq[CssGradientStop] = @[]
  for i in startIdx ..< args.len:
    let toks = splitCssValueTokens(args[i])
    if toks.len == 0:
      continue
    let colOpt = parseCssColor(toks[0])
    if colOpt.isNone:
      continue
    var stop = CssGradientStop(color: colOpt.get(), pos: 0.0'f32, hasPos: false)
    if toks.len >= 2:
      let pct = parseCssPercent(toks[1])
      if pct.isSome:
        stop.pos = clamp(pct.get() / 100.0'f32, 0.0'f32, 1.0'f32)
        stop.hasPos = true
      else:
        let px = parseCssLength(toks[1])
        if px.isSome:
          stop.pos = px.get()
          stop.hasPos = true
    stops.add(stop)

  if stops.len == 0:
    return none[CssLinearGradient]()
  some(CssLinearGradient(active: true, angleDeg: angle, stops: stops))

proc parseBoxShadows*(raw: string): seq[CssBoxShadow] {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(raw))
  if low.len == 0 or low == "none":
    return @[]
  result = @[]
  for layer in splitTopLevelCommas(raw):
    if layer.len == 0:
      continue
    var sh = CssBoxShadow(color: 0x00000080'u32)
    var lengths: seq[float32] = @[]
    for tok in splitCssValueTokens(layer):
      if htmlEqIgnoreCase(tok, "inset"):
        sh.inset = true
      else:
        let cOpt = parseCssColor(tok)
        if cOpt.isSome:
          sh.color = cOpt.get()
        else:
          let lOpt = parseCssLength(tok)
          if lOpt.isSome:
            lengths.add(lOpt.get())
    if lengths.len >= 2:
      sh.offsetX = lengths[0]
      sh.offsetY = lengths[1]
      if lengths.len >= 3:
        sh.blur = max(0.0'f32, lengths[2])
      if lengths.len >= 4:
        sh.spread = lengths[3]
      result.add(sh)

# =============================================================================
# Selectors, Media Queries, Declarations & Stylesheet Parsing
# =============================================================================

proc parseSimpleSelector(raw: string): Option[CssSimpleSelector] {.raises: [].} =
  let s = htmlStripAscii(raw)
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
  elif s[0] != '.' and s[0] != '#' and s[0] != ':' and s[0] != '[':
    let start = i
    while i < s.len and s[i] != '.' and s[i] != '#' and s[i] != ':' and s[i] != '[':
      inc i
    sel.tag = htmlToLowerAscii(s[start ..< i])

  while i < s.len:
    let marker = s[i]
    if marker == '[':
      # Consume attribute selector [...] cleanly; treat as non-matching unknown if unhandled
      inc i
      var inQ = '\0'
      while i < s.len:
        if inQ != '\0':
          if s[i] == inQ and (i == 0 or s[i - 1] != '\\'):
            inQ = '\0'
        else:
          if s[i] == '"' or s[i] == '\'':
            inQ = s[i]
          elif s[i] == ']':
            inc i
            break
        inc i
      sel.pseudo = cpkUnknown
      continue

    inc i
    if marker == ':' and i < s.len and s[i] == ':':
      # Pseudo-element ::before / ::after -> consume and mark unknown
      inc i
      while i < s.len and s[i] != '.' and s[i] != '#' and s[i] != ':' and s[i] != '[':
        inc i
      sel.pseudo = cpkUnknown
      continue

    let start = i
    var parenD = 0
    while i < s.len:
      let ch = s[i]
      if ch == '(':
        inc parenD
      elif ch == ')' and parenD > 0:
        dec parenD
      elif parenD == 0 and (ch == '.' or ch == '#' or ch == ':' or ch == '['):
        break
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
      let p = htmlToLowerAscii(ident)
      case p
      of "hover": sel.pseudo = cpkHover
      of "active": sel.pseudo = cpkActive
      of "focus", "focus-visible", "focus-within": sel.pseudo = cpkFocus
      of "disabled": sel.pseudo = cpkDisabled
      of "root": sel.pseudo = cpkRoot
      else: sel.pseudo = cpkUnknown
    else:
      discard
  some(sel)

proc parseComplexSelector(raw: string): Option[CssSelector] {.raises: [].} =
  let s = htmlStripAscii(raw)
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
    if s[i] == '+' or s[i] == '~':
      # Sibling combinators aren't matched natively; fail selector cleanly rather than mis-matching
      return none[CssSelector]()
    let start = i
    var inBracket = false
    var inParen = 0
    while i < s.len:
      let c = s[i]
      if c == '[': inBracket = true
      elif c == ']': inBracket = false
      elif c == '(': inc inParen
      elif c == ')' and inParen > 0: dec inParen
      elif not inBracket and inParen == 0 and (isSpaceChar(c) or c == '>' or c == '+' or c == '~'):
        break
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
      let declText = htmlStripAscii(body[declStart ..< i])
      if declText.len > 0:
        var colonIdx = -1
        for k in 0 ..< declText.len:
          if declText[k] == ':':
            colonIdx = k
            break
        if colonIdx > 0:
          let rawProp = htmlStripAscii(declText[0 ..< colonIdx])
          # CSS custom properties (--var) are case-sensitive per spec; standard properties are ASCII case-insensitive.
          let propName = if rawProp.len >= 2 and rawProp[0] == '-' and rawProp[1] == '-':
                           rawProp
                         else:
                           htmlToLowerAscii(rawProp)
          let propVal = htmlStripAscii(declText[colonIdx + 1 ..< declText.len])
          if propName.len > 0 and propVal.len > 0:
            result.add(CssDeclaration(prop: propName, value: propVal))
      declStart = i + 1
    inc i

proc evalMediaFeature(expr: string, media: CssMediaContext): bool {.raises: [].} =
  let inner = htmlStripAscii(expr)
  if inner.len == 0:
    return true
  var colonIdx = -1
  for i in 0 ..< inner.len:
    if inner[i] == ':':
      colonIdx = i
      break
  if colonIdx < 0:
    let low = htmlToLowerAscii(inner)
    return low == "screen" or low == "all"
  let key = htmlToLowerAscii(htmlStripAscii(inner[0 ..< colonIdx]))
  let val = htmlToLowerAscii(htmlStripAscii(inner[colonIdx + 1 ..< inner.len]))
  case key
  of "min-width":
    let l = parseCssLength(val)
    if l.isSome: return media.viewportWidth >= l.get()
    false
  of "max-width":
    let l = parseCssLength(val)
    if l.isSome: return media.viewportWidth <= l.get()
    false
  of "min-height":
    let l = parseCssLength(val)
    if l.isSome: return media.viewportHeight >= l.get()
    false
  of "max-height":
    let l = parseCssLength(val)
    if l.isSome: return media.viewportHeight <= l.get()
    false
  of "prefers-color-scheme":
    if val == "dark": return media.prefersDark
    elif val == "light": return not media.prefersDark
    false
  else:
    false

proc evalSingleMediaBranch(branch: string, media: CssMediaContext): bool {.raises: [].} =
  let s = htmlStripAscii(branch)
  if s.len == 0:
    return false
  var negate = false
  var pos = 0
  if htmlStartsWithIgnoreCase(s, "not ") or htmlStartsWithIgnoreCase(s, "not\t"):
    negate = true
    pos = 4
  elif htmlStartsWithIgnoreCase(s, "only ") or htmlStartsWithIgnoreCase(s, "only\t"):
    pos = 5

  var allOk = true
  while pos < s.len:
    while pos < s.len and isSpaceChar(s[pos]):
      inc pos
    if pos >= s.len:
      break
    if s[pos] == '(':
      let start = pos + 1
      var depth = 1
      inc pos
      while pos < s.len and depth > 0:
        if s[pos] == '(': inc depth
        elif s[pos] == ')':
          dec depth
          if depth == 0:
            break
        inc pos
      let feat = s[start ..< pos]
      if pos < s.len and s[pos] == ')':
        inc pos
      if not evalMediaFeature(feat, media):
        allOk = false
        break
    else:
      let start = pos
      while pos < s.len and not isSpaceChar(s[pos]) and s[pos] != '(':
        inc pos
      let word = htmlToLowerAscii(s[start ..< pos])
      if word == "and":
        continue
      elif word == "screen" or word == "all":
        continue
      elif word == "print" or word == "speech":
        allOk = false
        break
      else:
        allOk = false
        break

  if negate: not allOk else: allOk

proc evalMediaQuery*(query: string, media: CssMediaContext): bool {.raises: [].} =
  let branches = splitTopLevelCommas(query)
  if branches.len == 0:
    return true
  for br in branches:
    if evalSingleMediaBranch(br, media):
      return true
  false

proc parseCssSheetInternal(
  clean: string,
  media: CssMediaContext,
  orderCounter: var int,
  outRules: var seq[CssRule],
  depth: int
) {.raises: [].} =
  if depth >= MaxMediaRecursionDepth:
    return
  var i = 0
  while i < clean.len:
    while i < clean.len and isSpaceChar(clean[i]):
      inc i
    if i >= clean.len:
      break

    # Handle @-rules (@media evaluated against media context; others skipped cleanly)
    if clean[i] == '@':
      let atStart = i
      while i < clean.len and clean[i] != '{' and clean[i] != ';':
        inc i
      let prelude = htmlStripAscii(clean[atStart ..< i])
      if i < clean.len and clean[i] == '{':
        inc i
        let bodyStart = i
        var bDepth = 1
        var inQ = '\0'
        while i < clean.len and bDepth > 0:
          let ch = clean[i]
          if inQ != '\0':
            if ch == '\\' and i + 1 < clean.len:
              inc i
            elif ch == inQ:
              inQ = '\0'
          else:
            if ch == '"' or ch == '\'':
              inQ = ch
            elif ch == '{':
              inc bDepth
            elif ch == '}':
              dec bDepth
              if bDepth == 0:
                break
          inc i
        let blockBody = clean[bodyStart ..< i]
        if i < clean.len and clean[i] == '}':
          inc i
        if htmlStartsWithIgnoreCase(prelude, "@media"):
          let query = htmlStripAscii(prelude[6 ..< prelude.len])
          if evalMediaQuery(query, media):
            parseCssSheetInternal(blockBody, media, orderCounter, outRules, depth + 1)
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
    var bDepth = 1
    var inQuote = '\0'
    while i < clean.len and bDepth > 0:
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
          inc bDepth
        elif c == '}':
          dec bDepth
          if bDepth == 0:
            break
      inc i

    let bodyStr = clean[bodyStart ..< i]
    if i < clean.len and clean[i] == '}':
      inc i

    let decls = parseCssDeclarations(bodyStr)
    if decls.len == 0:
      continue

    var sStart = 0
    for k in 0 .. selectorListStr.len:
      if k == selectorListStr.len or selectorListStr[k] == ',':
        let selOpt = parseComplexSelector(selectorListStr[sStart ..< k])
        if selOpt.isSome:
          outRules.add(CssRule(
            selector: selOpt.get(),
            declarations: decls,
            order: orderCounter
          ))
          inc orderCounter
        sStart = k + 1

proc parseCssSheet*(
  css: string,
  media: CssMediaContext = defaultCssMediaContext()
): CssStylesheet {.raises: [].} =
  result = CssStylesheet(rules: @[])
  let clean = stripCssComments(css)
  var orderCounter = 0
  parseCssSheetInternal(clean, media, orderCounter, result.rules, 0)

proc mergeStylesheets*(a, b: CssStylesheet): CssStylesheet {.raises: [].} =
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

# =============================================================================
# Selector Matching & Cascade
# =============================================================================

proc docHasHtmlRoot(doc: HtmlDoc): bool {.inline, raises: [].} =
  if doc.nodes.len == 0:
    return false
  for cIdx in doc.nodes[0].children:
    if cIdx >= 0 and cIdx < doc.nodes.len and doc.nodes[cIdx].kind == hnkElement and doc.nodes[cIdx].tag == "html":
      return true
  false

proc matchesSimple*(node: HtmlNode, simp: CssSimpleSelector): bool {.raises: [].} =
  if node.kind != hnkElement:
    return false
  if simp.pseudo == cpkUnknown:
    return false
  if simp.pseudo == cpkDisabled and node.getAttr("disabled").isNone:
    return false
  if simp.pseudo == cpkRoot and node.parent != 0 and node.tag != "html":
    return false
  if simp.tag.len > 0 and node.tag != simp.tag:
    return false
  if simp.id.len > 0 and node.id != simp.id:
    return false
  for cls in simp.classes:
    if not node.hasClass(cls):
      return false
  true

proc matchesSimpleInDoc(doc: HtmlDoc, nodeIdx: int, simp: CssSimpleSelector): bool {.raises: [].} =
  if nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return false
  let node = doc.nodes[nodeIdx]
  if not matchesSimple(node, simp):
    return false
  if simp.pseudo == cpkRoot:
    if docHasHtmlRoot(doc):
      return node.tag == "html"
    return node.parent == 0
  true

proc matchesSelector*(doc: HtmlDoc, nodeIdx: int, sel: CssSelector): bool {.raises: [].} =
  if sel.parts.len == 0 or nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return false
  let lastIdx = sel.parts.len - 1
  if not matchesSimpleInDoc(doc, nodeIdx, sel.parts[lastIdx]):
    return false

  var curNode = doc.nodes[nodeIdx].parent
  for pIdx in countdown(lastIdx - 1, 0):
    let needDirect = sel.directChild[pIdx + 1]
    if needDirect:
      if curNode <= 0 or curNode >= doc.nodes.len:
        return false
      if not matchesSimpleInDoc(doc, curNode, sel.parts[pIdx]):
        return false
      curNode = doc.nodes[curNode].parent
    else:
      var found = false
      while curNode > 0 and curNode < doc.nodes.len:
        if matchesSimpleInDoc(doc, curNode, sel.parts[pIdx]):
          found = true
          curNode = doc.nodes[curNode].parent
          break
        curNode = doc.nodes[curNode].parent
      if not found:
        return false
  true

proc parseCssSizeOrAuto(val: string): Option[CssSize] {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(val))
  if low == "auto" or low == "none":
    return some(CssSize(kind: cskAuto, value: 0.0'f32))
  let pct = parseCssPercent(val)
  if pct.isSome:
    return some(CssSize(kind: cskPercent, value: pct.get()))
  let px = parseCssLength(val)
  if px.isSome:
    return some(CssSize(kind: cskPx, value: px.get()))
  none[CssSize]()

proc applyBoxSpacingShorthand(
  rawVal: string,
  allowAuto: bool,
  clampNeg: bool,
  vals: var array[4, float32],
  setFlags: var array[4, bool],
  autoFlags: var array[4, bool]
) {.raises: [].} =
  let toks = splitCssValueTokens(rawVal)
  var parsed: seq[tuple[val: float32, isAuto: bool]] = @[]
  for tok in toks:
    if allowAuto and htmlEqIgnoreCase(tok, "auto"):
      parsed.add((0.0'f32, true))
    else:
      let l = parseCssLength(tok)
      if l.isSome:
        let v = if clampNeg and l.get() < 0.0'f32: 0.0'f32 else: l.get()
        parsed.add((v, false))
  if parsed.len == 0:
    return
  var t, r, b, l: tuple[val: float32, isAuto: bool]
  if parsed.len == 1:
    t = parsed[0]; r = parsed[0]; b = parsed[0]; l = parsed[0]
  elif parsed.len == 2:
    t = parsed[0]; r = parsed[1]; b = parsed[0]; l = parsed[1]
  elif parsed.len == 3:
    t = parsed[0]; r = parsed[1]; b = parsed[2]; l = parsed[1]
  else:
    t = parsed[0]; r = parsed[1]; b = parsed[2]; l = parsed[3]
  vals = [t.val, r.val, b.val, l.val]
  setFlags = [true, true, true, true]
  autoFlags = [t.isAuto, r.isAuto, b.isAuto, l.isAuto]

proc applyDeclaration*(style: var CssComputedStyle, prop, rawVal: string) {.raises: [].} =
  let val = htmlStripAscii(rawVal)
  let low = htmlToLowerAscii(val)

  case prop
  of "display":
    case low
    of "none": style.display = cdNone
    of "flex": style.display = cdFlex
    of "inline", "inline-block": style.display = cdInline
    else: style.display = cdBlock
  of "position":
    case low
    of "relative": style.position = cpRelative
    of "absolute": style.position = cpAbsolute
    of "fixed": style.position = cpFixed
    else: style.position = cpStatic
  of "z-index":
    if low == "auto":
      style.zIndex = 0
      style.zIndexSet = false
    else:
      let zi = parseIntSafe(val)
      if zi.isSome:
        style.zIndex = zi.get()
        style.zIndexSet = true
  of "top":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.top = sz.get()
  of "right":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.right = sz.get()
  of "bottom":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.bottom = sz.get()
  of "left":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.left = sz.get()
  of "flex-direction":
    style.flexDirectionSet = true
    if low == "column" or low == "column-reverse":
      style.flexDirection = fdColumn
    else:
      style.flexDirection = fdRow
  of "flex-wrap":
    case low
    of "wrap": style.flexWrap = cfwWrap
    of "wrap-reverse": style.flexWrap = cfwWrapReverse
    else: style.flexWrap = cfwNoWrap
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
  of "align-self":
    case low
    of "flex-start", "start": style.alignSelf = casStart
    of "center": style.alignSelf = casCenter
    of "flex-end", "end": style.alignSelf = casEnd
    of "stretch": style.alignSelf = casStretch
    else: style.alignSelf = casAuto
  of "width":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.width = sz.get()
  of "height":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.height = sz.get()
  of "min-width":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.minWidth = sz.get()
  of "max-width":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.maxWidth = sz.get()
  of "min-height":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.minHeight = sz.get()
  of "max-height":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.maxHeight = sz.get()
  of "flex-grow":
    let fg = parseFloatSafe(val)
    if fg.isSome and fg.get() >= 0.0'f32:
      style.flexGrow = fg.get()
      style.hasFlexGrow = fg.get() > 0.0'f32
  of "flex-shrink":
    let fs = parseFloatSafe(val)
    if fs.isSome and fs.get() >= 0.0'f32:
      style.flexShrink = fs.get()
      style.hasFlexShrink = true
  of "flex-basis":
    let sz = parseCssSizeOrAuto(val)
    if sz.isSome: style.flexBasis = sz.get()
  of "flex":
    if low == "none":
      style.flexGrow = 0.0'f32
      style.hasFlexGrow = false
      style.flexShrink = 0.0'f32
      style.hasFlexShrink = true
      style.flexBasis = CssSize(kind: cskAuto, value: 0.0'f32)
    elif low == "auto":
      style.flexGrow = 1.0'f32
      style.hasFlexGrow = true
      style.flexShrink = 1.0'f32
      style.hasFlexShrink = true
      style.flexBasis = CssSize(kind: cskAuto, value: 0.0'f32)
    else:
      let toks = splitCssValueTokens(val)
      if toks.len > 0:
        let fg = parseFloatSafe(toks[0])
        if fg.isSome:
          style.flexGrow = max(0.0'f32, fg.get())
          style.hasFlexGrow = style.flexGrow > 0.0'f32
          if toks.len >= 2:
            let fsh = parseFloatSafe(toks[1])
            if fsh.isSome:
              style.flexShrink = max(0.0'f32, fsh.get())
              style.hasFlexShrink = true
              if toks.len >= 3:
                let fb = parseCssSizeOrAuto(toks[2])
                if fb.isSome: style.flexBasis = fb.get()
            else:
              let fb = parseCssSizeOrAuto(toks[1])
              if fb.isSome: style.flexBasis = fb.get()
        else:
          let fb = parseCssSizeOrAuto(toks[0])
          if fb.isSome: style.flexBasis = fb.get()
  of "padding":
    var dummyAuto: array[4, bool]
    applyBoxSpacingShorthand(val, allowAuto = false, clampNeg = true, style.padding, style.paddingSet, dummyAuto)
  of "padding-top":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[0] = max(0.0'f32, l.get())
      style.paddingSet[0] = true
  of "padding-right":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[1] = max(0.0'f32, l.get())
      style.paddingSet[1] = true
  of "padding-bottom":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[2] = max(0.0'f32, l.get())
      style.paddingSet[2] = true
  of "padding-left":
    let l = parseCssLength(val)
    if l.isSome:
      style.padding[3] = max(0.0'f32, l.get())
      style.paddingSet[3] = true
  of "margin":
    applyBoxSpacingShorthand(val, allowAuto = true, clampNeg = false, style.margin, style.marginSet, style.marginAuto)
  of "margin-top":
    if low == "auto":
      style.margin[0] = 0.0'f32; style.marginSet[0] = true; style.marginAuto[0] = true
    else:
      let l = parseCssLength(val)
      if l.isSome:
        style.margin[0] = l.get(); style.marginSet[0] = true; style.marginAuto[0] = false
  of "margin-right":
    if low == "auto":
      style.margin[1] = 0.0'f32; style.marginSet[1] = true; style.marginAuto[1] = true
    else:
      let l = parseCssLength(val)
      if l.isSome:
        style.margin[1] = l.get(); style.marginSet[1] = true; style.marginAuto[1] = false
  of "margin-bottom":
    if low == "auto":
      style.margin[2] = 0.0'f32; style.marginSet[2] = true; style.marginAuto[2] = true
    else:
      let l = parseCssLength(val)
      if l.isSome:
        style.margin[2] = l.get(); style.marginSet[2] = true; style.marginAuto[2] = false
  of "margin-left":
    if low == "auto":
      style.margin[3] = 0.0'f32; style.marginSet[3] = true; style.marginAuto[3] = true
    else:
      let l = parseCssLength(val)
      if l.isSome:
        style.margin[3] = l.get(); style.marginSet[3] = true; style.marginAuto[3] = false
  of "gap":
    let toks = splitCssValueTokens(val)
    if toks.len >= 1:
      let g1 = parseCssLength(toks[0])
      if g1.isSome:
        let gv1 = max(0.0'f32, g1.get())
        style.gap = gv1
        style.rowGap = gv1
        style.rowGapSet = true
        if toks.len >= 2:
          let g2 = parseCssLength(toks[1])
          if g2.isSome:
            style.columnGap = max(0.0'f32, g2.get())
            style.columnGapSet = true
        else:
          style.columnGap = gv1
          style.columnGapSet = true
  of "row-gap":
    let g = parseCssLength(val)
    if g.isSome:
      style.rowGap = max(0.0'f32, g.get())
      style.rowGapSet = true
      if not style.columnGapSet:
        style.gap = style.rowGap
  of "column-gap":
    let g = parseCssLength(val)
    if g.isSome:
      style.columnGap = max(0.0'f32, g.get())
      style.columnGapSet = true
      if not style.rowGapSet:
        style.gap = style.columnGap
  of "color":
    let c = parseCssColor(val)
    if c.isSome:
      style.fgColor = c.get()
      style.fgColorSet = true
  of "background", "background-color", "background-image":
    if low == "none":
      style.bgColor = 0x00000000'u32
      style.bgGradient = CssLinearGradient(active: false, angleDeg: 180.0'f32, stops: @[])
    else:
      let c = parseCssColor(val)
      if c.isSome:
        style.bgColor = c.get()
        if prop == "background":
          style.bgGradient = CssLinearGradient(active: false, angleDeg: 180.0'f32, stops: @[])
      else:
        for tok in splitCssValueTokens(val):
          let gradOpt = parseLinearGradient(tok)
          if gradOpt.isSome:
            let g = gradOpt.get()
            style.bgGradient = g
            if g.stops.len >= 2:
              style.bgColor = blendColorMidpoint(g.stops[0].color, g.stops[^1].color)
            elif g.stops.len == 1:
              style.bgColor = g.stops[0].color
            break
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
        let tl = htmlToLowerAscii(tok)
        if tl == "solid" or tl == "dashed" or tl == "dotted" or tl == "none":
          continue
        let c = parseCssColor(tok)
        if c.isSome:
          style.borderColor = c.get()
          continue
        let w = parseCssLength(tok)
        if w.isSome:
          style.borderWidth = max(0.0'f32, w.get())
  of "border-width":
    let w = parseCssLength(val)
    if w.isSome:
      style.borderWidth = max(0.0'f32, w.get())
  of "border-color":
    let c = parseCssColor(val)
    if c.isSome:
      style.borderColor = c.get()
  of "border-radius":
    let toks = splitCssValueTokens(val)
    if toks.len > 0:
      let r = parseCssLength(toks[0])
      if r.isSome:
        style.borderRadius = max(0.0'f32, r.get())
  of "opacity":
    let pct = parseCssPercent(val)
    if pct.isSome:
      style.opacity = clamp(pct.get() / 100.0'f32, 0.0'f32, 1.0'f32)
      style.opacitySet = true
    else:
      let op = parseFloatSafe(val)
      if op.isSome:
        style.opacity = clamp(op.get(), 0.0'f32, 1.0'f32)
        style.opacitySet = true
  of "box-shadow":
    style.boxShadows = parseBoxShadows(val)
  of "font-size":
    let fs = parseCssLength(val)
    if fs.isSome and fs.get() > 0.0'f32:
      style.fontSize = fs.get()
      style.fontSizeSet = true
  of "font-weight":
    case low
    of "normal":
      style.fontWeight = 400
      style.fontWeightSet = true
    of "bold", "bolder":
      style.fontWeight = 700
      style.fontWeightSet = true
    of "lighter":
      style.fontWeight = 300
      style.fontWeightSet = true
    else:
      let fw = parseIntSafe(val)
      if fw.isSome:
        style.fontWeight = clamp(fw.get(), 100, 900)
        style.fontWeightSet = true
  of "font-family":
    style.fontFamily = val
    style.fontFamilySet = true
  of "line-height":
    if low == "normal":
      style.lineHeight = 1.2'f32
      style.lineHeightIsPx = false
      style.lineHeightSet = true
    else:
      let pct = parseCssPercent(val)
      if pct.isSome and pct.get() > 0.0'f32:
        style.lineHeight = pct.get() / 100.0'f32
        style.lineHeightIsPx = false
        style.lineHeightSet = true
      else:
        let lhUnitless = parseFloatSafe(val)
        if lhUnitless.isSome and lhUnitless.get() > 0.0'f32:
          style.lineHeight = lhUnitless.get()
          style.lineHeightIsPx = false
          style.lineHeightSet = true
        else:
          let lhPx = parseCssLength(val)
          if lhPx.isSome and lhPx.get() > 0.0'f32:
            style.lineHeight = lhPx.get()
            style.lineHeightIsPx = true
            style.lineHeightSet = true
  of "cursor":
    style.cursor = low
    style.cursorSet = true
  of "text-overflow":
    style.textOverflow = low
  of "white-space":
    style.whiteSpace = low
    style.whiteSpaceSet = true
  of "list-style", "list-style-type":
    let toks = splitCssValueTokens(low)
    if toks.len > 0:
      style.listStyleType = toks[0]
      style.listStyleSet = true
  of "transition", "transition-property", "transition-duration", "transition-timing-function", "transition-delay":
    style.transition = val
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

proc defaultElementStyle*(tag: string, parentStyle: CssComputedStyle): CssComputedStyle {.raises: [].} =
  result = CssComputedStyle(
    display: cdBlock,
    position: cpStatic,
    zIndex: 0,
    zIndexSet: false,
    top: CssSize(kind: cskAuto, value: 0.0'f32),
    right: CssSize(kind: cskAuto, value: 0.0'f32),
    bottom: CssSize(kind: cskAuto, value: 0.0'f32),
    left: CssSize(kind: cskAuto, value: 0.0'f32),
    flexDirection: fdColumn,
    flexDirectionSet: false,
    flexWrap: cfwNoWrap,
    justifyContent: jcStart,
    alignItems: aiStretch,
    alignItemsSet: false,
    alignSelf: casAuto,
    width: CssSize(kind: cskAuto, value: 0.0'f32),
    height: CssSize(kind: cskAuto, value: 0.0'f32),
    minWidth: CssSize(kind: cskAuto, value: 0.0'f32),
    maxWidth: CssSize(kind: cskAuto, value: 0.0'f32),
    minHeight: CssSize(kind: cskAuto, value: 0.0'f32),
    maxHeight: CssSize(kind: cskAuto, value: 0.0'f32),
    flexGrow: 0.0'f32,
    hasFlexGrow: false,
    flexShrink: 1.0'f32,
    hasFlexShrink: false,
    flexBasis: CssSize(kind: cskAuto, value: 0.0'f32),
    padding: [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32],
    paddingSet: [false, false, false, false],
    margin: [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32],
    marginSet: [false, false, false, false],
    marginAuto: [false, false, false, false],
    gap: 0.0'f32,
    rowGap: 0.0'f32,
    columnGap: 0.0'f32,
    rowGapSet: false,
    columnGapSet: false,
    fgColor: parentStyle.fgColor,
    fgColorSet: false,
    bgColor: 0x00000000'u32,
    bgHoverColor: 0x00000000'u32,
    bgActiveColor: 0x00000000'u32,
    bgFocusColor: 0x00000000'u32,
    fgFocusColor: 0x00000000'u32,
    borderColor: 0x00000000'u32,
    borderHoverColor: 0x00000000'u32,
    borderFocusColor: 0x00000000'u32,
    borderWidth: 0.0'f32,
    borderRadius: 0.0'f32,
    opacity: 1.0'f32,
    opacitySet: false,
    boxShadows: @[],
    bgGradient: CssLinearGradient(active: false, angleDeg: 180.0'f32, stops: @[]),
    fontSize: parentStyle.fontSize,
    fontSizeSet: false,
    fontWeight: parentStyle.fontWeight,
    fontWeightSet: false,
    fontFamily: parentStyle.fontFamily,
    fontFamilySet: false,
    lineHeight: parentStyle.lineHeight,
    lineHeightIsPx: parentStyle.lineHeightIsPx,
    lineHeightSet: false,
    cursor: parentStyle.cursor,
    cursorSet: false,
    textOverflow: "clip",
    whiteSpace: parentStyle.whiteSpace,
    whiteSpaceSet: false,
    listStyleType: parentStyle.listStyleType,
    listStyleSet: false,
    transition: "",
    overflowY: false,
    customVars: parentStyle.customVars
  )

  case tag
  of "h1":
    result.fontSize = 24.0'f32
    result.fontWeight = 700
  of "h2":
    result.fontSize = 20.0'f32
    result.fontWeight = 700
  of "h3":
    result.fontSize = 16.0'f32
    result.fontWeight = 700
  of "strong", "b":
    result.display = cdInline
    result.fontWeight = 700
  of "span", "label", "em", "a":
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
    result.cursor = "pointer"
  of "input", "select":
    result.display = cdInline
    result.bgColor = 0x0F172AFF'u32
    result.borderColor = 0x334155FF'u32
    result.borderHoverColor = 0x64748BFF'u32
    result.borderWidth = 1.0'f32
    result.borderRadius = 6.0'f32
    result.padding = [6.0'f32, 10.0'f32, 6.0'f32, 10.0'f32]
    result.fgColor = 0xF8FAFCFF'u32
    result.fontSize = 13.0'f32
  of "textarea":
    result.display = cdBlock
    result.bgColor = 0x0F172AFF'u32
    result.borderColor = 0x334155FF'u32
    result.borderHoverColor = 0x64748BFF'u32
    result.borderWidth = 1.0'f32
    result.borderRadius = 6.0'f32
    result.padding = [8.0'f32, 10.0'f32, 8.0'f32, 10.0'f32]
    result.fgColor = 0xF8FAFCFF'u32
    result.fontSize = 13.0'f32
  of "hr":
    result.display = cdBlock
    result.width = CssSize(kind: cskPercent, value: 100.0'f32)
    result.height = CssSize(kind: cskPx, value: 1.0'f32)
    result.bgColor = 0x334155FF'u32
    result.margin = [6.0'f32, 0.0'f32, 6.0'f32, 0.0'f32]
  of "ul":
    result.display = cdBlock
    result.padding = [0.0'f32, 0.0'f32, 0.0'f32, 18.0'f32]
    if not parentStyle.listStyleSet:
      result.listStyleType = "disc"
  of "ol":
    result.display = cdBlock
    result.padding = [0.0'f32, 0.0'f32, 0.0'f32, 20.0'f32]
    if not parentStyle.listStyleSet:
      result.listStyleType = "decimal"
  of "li":
    result.display = cdFlex
    result.flexDirection = fdRow
    result.alignItems = aiCenter
    result.gap = 6.0'f32
  of "table", "thead", "tbody", "tfoot":
    result.display = cdFlex
    result.flexDirection = fdColumn
    result.alignItems = aiStretch
  of "tr":
    result.display = cdFlex
    result.flexDirection = fdRow
    result.alignItems = aiStretch
  of "th":
    result.display = cdFlex
    result.flexDirection = fdRow
    result.alignItems = aiCenter
    result.padding = [6.0'f32, 10.0'f32, 6.0'f32, 10.0'f32]
    result.fontWeight = 700
    result.flexGrow = 1.0'f32
    result.hasFlexGrow = true
  of "td":
    result.display = cdFlex
    result.flexDirection = fdRow
    result.alignItems = aiCenter
    result.padding = [6.0'f32, 10.0'f32, 6.0'f32, 10.0'f32]
    result.flexGrow = 1.0'f32
    result.hasFlexGrow = true
  else:
    discard

proc defaultRootStyle*(): CssComputedStyle {.raises: [].} =
  CssComputedStyle(
    display: cdBlock,
    position: cpStatic,
    flexDirection: fdColumn,
    flexWrap: cfwNoWrap,
    alignItems: aiStretch,
    alignSelf: casAuto,
    flexShrink: 1.0'f32,
    fgColor: 0xF8FAFCFF'u32,
    opacity: 1.0'f32,
    fontSize: 14.0'f32,
    fontWeight: 400,
    fontFamily: "Segoe UI",
    lineHeight: 1.25'f32,
    cursor: "default",
    textOverflow: "clip",
    whiteSpace: "normal",
    listStyleType: "disc",
    customVars: @[]
  )

proc applyPseudoDeclarations(style: var CssComputedStyle, pseudo: CssPseudoKind, decls: seq[CssDeclaration]) {.raises: [].} =
  for d in decls:
    let resolvedVal = resolveCssVars(d.value, style.customVars)
    case pseudo
    of cpkHover:
      if d.prop == "background" or d.prop == "background-color":
        let c = parseCssColor(resolvedVal)
        if c.isSome:
          style.bgHoverColor = c.get()
      elif d.prop == "border-color":
        let c = parseCssColor(resolvedVal)
        if c.isSome:
          style.borderHoverColor = c.get()
    of cpkActive:
      if d.prop == "background" or d.prop == "background-color":
        let c = parseCssColor(resolvedVal)
        if c.isSome:
          style.bgActiveColor = c.get()
    of cpkFocus:
      if d.prop == "background" or d.prop == "background-color":
        let c = parseCssColor(resolvedVal)
        if c.isSome:
          style.bgFocusColor = c.get()
      elif d.prop == "border-color":
        let c = parseCssColor(resolvedVal)
        if c.isSome:
          style.borderFocusColor = c.get()
      elif d.prop == "color":
        let c = parseCssColor(resolvedVal)
        if c.isSome:
          style.fgFocusColor = c.get()
    of cpkNone, cpkDisabled, cpkRoot, cpkUnknown:
      discard

proc sortMatchedRuleIndices(indices: var seq[int], sheet: CssStylesheet) {.raises: [].} =
  # Insertion sort by (specificity, source order)
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
      if pseudo in {cpkNone, cpkDisabled, cpkRoot}:
        baseRules.add(rIdx)
      elif pseudo in {cpkHover, cpkActive, cpkFocus}:
        pseudoRules.add(rIdx)

  sortMatchedRuleIndices(baseRules, sheet)
  sortMatchedRuleIndices(pseudoRules, sheet)

  let inlineOpt = node.getAttr("style")
  let inlineDecls = if inlineOpt.isSome: parseCssDeclarations(inlineOpt.get()) else: @[]

  # Pass 1: Collect custom property (--var) declarations in cascade order
  for rIdx in baseRules:
    for d in sheet.rules[rIdx].declarations:
      if d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-':
        setCustomVar(style.customVars, d.prop, d.value)
  for d in inlineDecls:
    if d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-':
      setCustomVar(style.customVars, d.prop, d.value)

  # Pass 2: Apply standard declarations with var() resolution
  for rIdx in baseRules:
    for d in sheet.rules[rIdx].declarations:
      if not (d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-'):
        let resolvedVal = resolveCssVars(d.value, style.customVars)
        if resolvedVal.len > 0:
          style.applyDeclaration(d.prop, resolvedVal)

  for d in inlineDecls:
    if not (d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-'):
      let resolvedVal = resolveCssVars(d.value, style.customVars)
      if resolvedVal.len > 0:
        style.applyDeclaration(d.prop, resolvedVal)

  # Resolve display: flex default direction if flex-direction was omitted
  if style.display == cdFlex and not style.flexDirectionSet:
    style.flexDirection = fdRow
  elif style.display == cdBlock and not style.flexDirectionSet:
    style.flexDirection = fdColumn

  # Apply :hover, :active, :focus pseudo-rules after base style
  for rIdx in pseudoRules:
    let pseudo = sheet.rules[rIdx].selector.parts[^1].pseudo
    style.applyPseudoDeclarations(pseudo, sheet.rules[rIdx].declarations)

  style
