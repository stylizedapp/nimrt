## apps/mini-browser/src/style.nim
## ComputedStyle resolution and CSS value parsing for Level 0
import std/strutils
import corex
import ./png
import ./html
import ./css
import ./css_match

type
  DisplayKind* = enum
    dkBlock,
    dkInline,
    dkNone

  ComputedStyle* = object
    display*: DisplayKind
    color*: Rgba             # text color
    backgroundColor*: Rgba   # background color
    width*: Option[float32]  # optional explicit width
    height*: Option[float32] # optional explicit height

  StyleError* = object
    msg*: string

# =============================================================================
# Helper Utilities
# =============================================================================

proc trimSpan(s: Span[byte]): Span[byte] {.raises: [].} =
  if s.len == 0 or s.data.isNil: return s
  var start = 0
  while start < s.len and (s.data[start] == byte(' ') or s.data[start] == byte('\t') or s.data[start] == byte('\r') or s.data[start] == byte('\n')):
    inc(start)
  var finish = s.len - 1
  while finish >= start and (s.data[finish] == byte(' ') or s.data[finish] == byte('\t') or s.data[finish] == byte('\r') or s.data[finish] == byte('\n')):
    dec(finish)
  if finish < start:
    Span[byte](data: nil, len: 0)
  else:
    s.subspan(start, finish - start + 1)

proc parseHexNibble(b: byte): int {.inline, raises: [].} =
  if b >= byte('0') and b <= byte('9'): int(b - byte('0'))
  elif b >= byte('a') and b <= byte('f'): int(b - byte('a') + 10)
  elif b >= byte('A') and b <= byte('F'): int(b - byte('A') + 10)
  else: -1

# =============================================================================
# Value Parsers
# =============================================================================

proc parseColor*(s: Span[byte]): Result[Rgba, StyleError] {.raises: [].} =
  let spanTrimmed = trimSpan(s)
  if spanTrimmed.len == 0:
    return err[Rgba, StyleError](StyleError(msg: "Empty color value"))

  # 1. Hex color: #rgb, #rgba, #rrggbb, #rrggbbaa
  if spanTrimmed.data[0] == byte('#'):
    let hexLen = spanTrimmed.len - 1
    case hexLen
    of 3: # #rgb -> #rrggbb
      let r = parseHexNibble(spanTrimmed.data[1])
      let g = parseHexNibble(spanTrimmed.data[2])
      let b = parseHexNibble(spanTrimmed.data[3])
      if r < 0 or g < 0 or b < 0:
        return err[Rgba, StyleError](StyleError(msg: "Invalid hex color: " & spanTrimmed.asString()))
      let r8 = uint8(r * 17)
      let g8 = uint8(g * 17)
      let b8 = uint8(b * 17)
      return ok[Rgba, StyleError](png.rgba(r8, g8, b8, 255'u8))
    of 4: # #rgba
      let r = parseHexNibble(spanTrimmed.data[1])
      let g = parseHexNibble(spanTrimmed.data[2])
      let b = parseHexNibble(spanTrimmed.data[3])
      let a = parseHexNibble(spanTrimmed.data[4])
      if r < 0 or g < 0 or b < 0 or a < 0:
        return err[Rgba, StyleError](StyleError(msg: "Invalid hex color: " & spanTrimmed.asString()))
      return ok[Rgba, StyleError](png.rgba(uint8(r * 17), uint8(g * 17), uint8(b * 17), uint8(a * 17)))
    of 6: # #rrggbb
      let r1 = parseHexNibble(spanTrimmed.data[1])
      let r0 = parseHexNibble(spanTrimmed.data[2])
      let g1 = parseHexNibble(spanTrimmed.data[3])
      let g0 = parseHexNibble(spanTrimmed.data[4])
      let b1 = parseHexNibble(spanTrimmed.data[5])
      let b0 = parseHexNibble(spanTrimmed.data[6])
      if r1 < 0 or r0 < 0 or g1 < 0 or g0 < 0 or b1 < 0 or b0 < 0:
        return err[Rgba, StyleError](StyleError(msg: "Invalid hex color: " & spanTrimmed.asString()))
      let r8 = uint8((r1 shl 4) or r0)
      let g8 = uint8((g1 shl 4) or g0)
      let b8 = uint8((b1 shl 4) or b0)
      return ok[Rgba, StyleError](png.rgba(r8, g8, b8, 255'u8))
    of 8: # #rrggbbaa
      let r1 = parseHexNibble(spanTrimmed.data[1])
      let r0 = parseHexNibble(spanTrimmed.data[2])
      let g1 = parseHexNibble(spanTrimmed.data[3])
      let g0 = parseHexNibble(spanTrimmed.data[4])
      let b1 = parseHexNibble(spanTrimmed.data[5])
      let b0 = parseHexNibble(spanTrimmed.data[6])
      let a1 = parseHexNibble(spanTrimmed.data[7])
      let a0 = parseHexNibble(spanTrimmed.data[8])
      if r1 < 0 or r0 < 0 or g1 < 0 or g0 < 0 or b1 < 0 or b0 < 0 or a1 < 0 or a0 < 0:
        return err[Rgba, StyleError](StyleError(msg: "Invalid hex color: " & spanTrimmed.asString()))
      let r8 = uint8((r1 shl 4) or r0)
      let g8 = uint8((g1 shl 4) or g0)
      let b8 = uint8((b1 shl 4) or b0)
      let a8 = uint8((a1 shl 4) or a0)
      return ok[Rgba, StyleError](png.rgba(r8, g8, b8, a8))
    else:
      return err[Rgba, StyleError](StyleError(msg: "Invalid hex color length: " & spanTrimmed.asString()))

  # 2. Named colors (case-insensitive)
  if eqIgnoreCase(spanTrimmed, "red"):
    ok[Rgba, StyleError](png.rgba(255'u8, 0'u8, 0'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "green"):
    ok[Rgba, StyleError](png.rgba(0'u8, 128'u8, 0'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "lime"):
    ok[Rgba, StyleError](png.rgba(0'u8, 255'u8, 0'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "blue"):
    ok[Rgba, StyleError](png.rgba(0'u8, 0'u8, 255'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "white"):
    ok[Rgba, StyleError](png.rgba(255'u8, 255'u8, 255'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "black"):
    ok[Rgba, StyleError](png.rgba(0'u8, 0'u8, 0'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "gray") or eqIgnoreCase(spanTrimmed, "grey"):
    ok[Rgba, StyleError](png.rgba(128'u8, 128'u8, 128'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "lightgray") or eqIgnoreCase(spanTrimmed, "lightgrey"):
    ok[Rgba, StyleError](png.rgba(211'u8, 211'u8, 211'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "yellow"):
    ok[Rgba, StyleError](png.rgba(255'u8, 255'u8, 0'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "cyan"):
    ok[Rgba, StyleError](png.rgba(0'u8, 255'u8, 255'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "magenta"):
    ok[Rgba, StyleError](png.rgba(255'u8, 0'u8, 255'u8, 255'u8))
  elif eqIgnoreCase(spanTrimmed, "transparent"):
    ok[Rgba, StyleError](png.rgba(0'u8, 0'u8, 0'u8, 0'u8))
  else:
    err[Rgba, StyleError](StyleError(msg: "Unknown color name: " & spanTrimmed.asString()))

proc parseColor*(s: string): Result[Rgba, StyleError] {.inline, raises: [].} =
  if s.len == 0:
    var empty: array[0, byte]
    parseColor(toByteSpan(empty))
  else:
    parseColor(toByteSpan(s))

proc parseLength*(s: Span[byte]): Result[float32, StyleError] {.raises: [].} =
  let spanTrimmed = trimSpan(s)
  if spanTrimmed.len == 0:
    return err[float32, StyleError](StyleError(msg: "Empty length value"))

  var str = spanTrimmed.asString()
  if str.endsWith("px"):
    str = str[0 .. ^3]

  try:
    let val = parseFloat(str)
    ok[float32, StyleError](float32(val))
  except ValueError:
    err[float32, StyleError](StyleError(msg: "Invalid float length: " & spanTrimmed.asString()))

proc parseLength*(s: string): Result[float32, StyleError] {.inline, raises: [].} =
  if s.len == 0:
    var empty: array[0, byte]
    parseLength(toByteSpan(empty))
  else:
    parseLength(toByteSpan(s))

proc parseDisplay*(s: Span[byte]): Result[DisplayKind, StyleError] {.raises: [].} =
  let spanTrimmed = trimSpan(s)
  if eqIgnoreCase(spanTrimmed, "none"):
    ok[DisplayKind, StyleError](dkNone)
  elif eqIgnoreCase(spanTrimmed, "block"):
    ok[DisplayKind, StyleError](dkBlock)
  elif eqIgnoreCase(spanTrimmed, "inline"):
    ok[DisplayKind, StyleError](dkInline)
  else:
    err[DisplayKind, StyleError](StyleError(msg: "Unknown display value: " & spanTrimmed.asString()))

proc parseDisplay*(s: string): Result[DisplayKind, StyleError] {.inline, raises: [].} =
  if s.len == 0:
    var empty: array[0, byte]
    parseDisplay(toByteSpan(empty))
  else:
    parseDisplay(toByteSpan(s))

# =============================================================================
# Defaults & Cascade Resolution (Last-Wins without specificity)
# =============================================================================

proc defaultElementStyle*(): ComputedStyle {.inline, raises: [].} =
  ComputedStyle(
    display: dkBlock,
    color: png.rgba(0'u8, 0'u8, 0'u8, 255'u8),
    backgroundColor: png.rgba(200'u8, 200'u8, 200'u8, 255'u8),
    width: none(float32),
    height: none(float32)
  )

proc defaultTextStyle*(): ComputedStyle {.inline, raises: [].} =
  ComputedStyle(
    display: dkInline,
    color: png.rgba(0'u8, 0'u8, 0'u8, 255'u8),
    backgroundColor: png.rgba(0'u8, 0'u8, 0'u8, 0'u8),
    width: none(float32),
    height: none(float32)
  )

proc resolveStyle*(node: Node, sheet: StyleSheet, parentStyle: Option[ComputedStyle] = none(ComputedStyle)): ComputedStyle {.raises: [].} =
  if node.kind == nkText:
    var style = defaultTextStyle()
    if parentStyle.isSome:
      let p = parentStyle.get()
      style.color = p.color
      if p.display == dkNone:
        style.display = dkNone
    return style

  var style = defaultElementStyle()
  if parentStyle.isSome:
    let p = parentStyle.get()
    style.color = p.color
    if p.display == dkNone:
      style.display = dkNone

  # Last-wins without specificity
  for i in 0 ..< sheet.rules.len:
    let rule = sheet.rules[i]
    if matches(node, rule):
      for j in 0 ..< rule.declarations.len:
        let decl = rule.declarations[j]
        if eqIgnoreCase(decl.property, "color"):
          let c = parseColor(decl.value)
          if c.isOk: style.color = c.get()
        elif eqIgnoreCase(decl.property, "background-color") or eqIgnoreCase(decl.property, "background"):
          let c = parseColor(decl.value)
          if c.isOk: style.backgroundColor = c.get()
        elif eqIgnoreCase(decl.property, "display"):
          let d = parseDisplay(decl.value)
          if d.isOk: style.display = d.get()
        elif eqIgnoreCase(decl.property, "width"):
          let w = parseLength(decl.value)
          if w.isOk: style.width = some(w.get())
        elif eqIgnoreCase(decl.property, "height"):
          let h = parseLength(decl.value)
          if h.isOk: style.height = some(h.get())

  style
