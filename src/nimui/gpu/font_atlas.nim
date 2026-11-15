## nimui/gpu/font_atlas — System Font Rasterizer & Texture Atlas
##
## Strict invariants:
## - Native OS rasterization (GDI GetGlyphOutlineW on Windows) with zero external C dependencies.
## - Supports full ASCII (32..126) + Cyrillic (U+0400..U+04FF) + General Punctuation + Symbols & Dingbats.
## - Built-in fallback bitmap generator for Linux / headless environments.
## - Produces an R8_UNORM texture map with normalized UV coordinates.

import ../../corex/unicode
import ../../algx/swissmap
export unicode

type
  GlyphInfo* = object
    uvMin*: array[2, float32]
    uvMax*: array[2, float32]
    width*: float32
    height*: float32
    bearingX*: float32
    bearingY*: float32
    advance*: float32

  FontAtlas* = object
    width*: int
    height*: int
    baseSize*: float32
    lineHeight*: float32
    ascender*: float32
    descender*: float32
    pixels*: seq[uint8]               # R8_UNORM pixel buffer
    glyphs*: array[0x0500, GlyphInfo] # Fast direct lookup for 0..0x04FF (ASCII, Latin-1, Cyrillic)
    extendedGlyphs*: FastMap[uint32, GlyphInfo] # Lookup for codepoints >= 0x0500
    kerningAscii*: seq[int8]          # Fast O(1) 256x256 direct lookup for ASCII/Latin-1
    kerningPairs*: FastMap[uint64, float32] # Kerning adjustments for extended/Unicode pairs

# =============================================================================
# Windows GDI Interop
# =============================================================================

when defined(windows):
  type
    HANDLE = pointer
    HDC = pointer
    HFONT = pointer
    HGDIOBJ = pointer
    BOOL = int32
    WORD = uint16
    DWORD = uint32
    UINT = uint32

    POINT = object
      x: int32
      y: int32

    FIXED = object
      fract: WORD
      value: int16

    MAT2 = object
      eM11: FIXED
      eM12: FIXED
      eM21: FIXED
      eM22: FIXED

    GLYPHMETRICS = object
      gmBlackBoxX: UINT
      gmBlackBoxY: UINT
      gmptGlyphOrigin: POINT
      gmCellIncX: int16
      gmCellIncY: int16

    KERNINGPAIR = object
      wFirst: WORD
      wSecond: WORD
      iKernAmount: int32

    TEXTMETRICW = object
      tmHeight: int32
      tmAscent: int32
      tmDescent: int32
      tmInternalLeading: int32
      tmExternalLeading: int32
      tmAveCharWidth: int32
      tmMaxCharWidth: int32
      tmWeight: int32
      tmOverhang: int32
      tmDigitizedAspectX: int32
      tmDigitizedAspectY: int32
      tmFirstChar: uint16
      tmLastChar: uint16
      tmDefaultChar: uint16
      tmBreakChar: uint16
      tmItalic: uint8
      tmUnderlined: uint8
      tmStruckOut: uint8
      tmPitchAndFamily: uint8
      tmCharSet: uint8

  const
    GGO_GRAY8_BITMAP = 6'u32
    DEFAULT_CHARSET = 1'i32
    OUT_DEFAULT_PRECIS = 0'i32
    CLIP_DEFAULT_PRECIS = 0'i32
    CLEARTYPE_QUALITY = 5'i32
    DEFAULT_PITCH = 0'i32
    FF_DONTCARE = 0'i32
    FW_NORMAL = 400'i32
    GDI_ERROR = 0xFFFFFFFF'u32

  proc CreateCompatibleDC(hdc: HDC): HDC {.stdcall, dynlib: "gdi32", importc: "CreateCompatibleDC", raises: [].}
  proc DeleteDC(hdc: HDC): BOOL {.stdcall, dynlib: "gdi32", importc: "DeleteDC", raises: [].}
  proc SelectObject(hdc: HDC, h: HGDIOBJ): HGDIOBJ {.stdcall, dynlib: "gdi32", importc: "SelectObject", raises: [].}
  proc DeleteObject(ho: HGDIOBJ): BOOL {.stdcall, dynlib: "gdi32", importc: "DeleteObject", raises: [].}
  proc CreateFontW(
    cHeight, cWidth, cEscapement, cOrientation, cWeight: int32,
    bItalic, bUnderline, bStrikeOut, iCharSet, iOutPrecision,
    iClipPrecision, iQuality, iPitchAndFamily: int32,
    pszFaceName: WideCString
  ): HFONT {.stdcall, dynlib: "gdi32", importc: "CreateFontW", raises: [].}
  proc GetTextMetricsW(hdc: HDC, lptm: ptr TEXTMETRICW): BOOL {.stdcall, dynlib: "gdi32", importc: "GetTextMetricsW", raises: [].}
  proc GetKerningPairsW(hdc: HDC, nPairs: DWORD, lpKernPair: ptr KERNINGPAIR): DWORD {.stdcall, dynlib: "gdi32", importc: "GetKerningPairsW", raises: [].}
  proc GetGlyphOutlineW(
    hdc: HDC, uChar: UINT, fuFormat: UINT, lpgm: ptr GLYPHMETRICS,
    cjBuffer: DWORD, pvBuffer: pointer, lpmat2: ptr MAT2
  ): DWORD {.stdcall, dynlib: "gdi32", importc: "GetGlyphOutlineW", raises: [].}

# =============================================================================
# Helper: Standard Unicode Ranges for UI Rendering
# =============================================================================

proc collectCandidateCodepoints(): seq[uint32] {.raises: [].} =
  result = @[]
  # 1. ASCII printable (32..126)
  for c in 32'u32 .. 126'u32: result.add(c)
  
  # 2. High-Priority UI Symbols & Dingbats (Checkmarks, Badges, Astrometrics, Bullets)
  #    Always placed immediately after ASCII so they are guaranteed atlas slots.
  let prioritySymbols = [
    0x2713'u32, # ✓ Checkmark
    0x2714'u32, # ✔ Heavy checkmark
    0x2715'u32, # ✕ Multiplication X
    0x2716'u32, # ✖ Heavy X
    0x2609'u32, # ☉ Sun / Solar mass symbol
    0x2022'u32, # • Bullet
    0x00B7'u32, # · Middle dot
    0x25CF'u32, # ● Black circle
    0x25CB'u32, # ○ White circle
    0x25A0'u32, # ■ Black square
    0x25A1'u32, # □ White square
    0x25B2'u32, # ▲ Up triangle
    0x25BC'u32, # ▼ Down triangle
    0x25C0'u32, # ◀ Left triangle
    0x25B6'u32, # ▶ Right triangle
    0x25C6'u32, # ◆ Diamond
    0x25C7'u32, # ◇ White diamond
    0x2190'u32, # ← Left arrow
    0x2191'u32, # ↑ Up arrow
    0x2192'u32, # → Right arrow
    0x2193'u32, # ↓ Down arrow
    0x21BB'u32, # ↻ Clockwise reload
    0x21BA'u32, # ↺ Counterclockwise
    0x26A0'u32, # ⚠ Warning
    0x26A1'u32, # ⚡ High voltage
    0x2699'u32, # ⚙ Gear
    0x2605'u32, # ★ Black star
    0x2606'u32, # ☆ White star
    0x221E'u32, # ∞ Infinity
    0x221A'u32, # √ Square root
    0x2260'u32, # ≠ Not equal
    0x2264'u32, # ≤ Less or equal
    0x2265'u32, # ≥ Greater or equal
    0x2248'u32, # ≈ Almost equal
    0x20AC'u32, # € Euro
    0x20BD'u32, # ₽ Ruble
    0x00A3'u32, # £ Pound
    0x00A5'u32, # ¥ Yen
    0x00B0'u32, # ° Degree
    0x00B1'u32, # ± Plus-minus
    0x00D7'u32, # × Multiplication
    0x00F7'u32, # ÷ Division
    0x2026'u32, # … Ellipsis
    0x2014'u32, # — Em dash
    0x2013'u32, # – En dash
    0x201C'u32, # “ Left double quote
    0x201D'u32, # ” Right double quote
    0x2018'u32, # ‘ Left single quote
    0x2019'u32  # ’ Right single quote
  ]
  for s in prioritySymbols:
    result.add(s)

  # 3. Latin-1 Supplement (0x00A0..0x00FF)
  for c in 0x00A0'u32 .. 0x00FF'u32:
    if c notin prioritySymbols:
      result.add(c)

  # 4. Cyrillic Basic (0x0400..0x045F: Russian, Ukrainian, Belarusian alphabets)
  for c in 0x0400'u32 .. 0x045F'u32:
    result.add(c)

# =============================================================================
# Fallback Glyph Generation (Cross-Platform)
# =============================================================================

proc initFallbackAtlas(atlas: var FontAtlas, fontSize: float32) =
  atlas.width = 1024
  atlas.height = 1024
  atlas.baseSize = fontSize
  atlas.lineHeight = fontSize * 1.25f
  atlas.ascender = fontSize * 0.9f
  atlas.descender = fontSize * 0.25f
  atlas.pixels = newSeq[uint8](atlas.width * atlas.height)
  atlas.extendedGlyphs = initFastMap[uint32, GlyphInfo](1024)
  atlas.kerningAscii = newSeq[int8](256 * 256)
  atlas.kerningPairs = initFastMap[uint64, float32]()

  # Provide a minimal readable proportional glyph generator
  let charW = int(fontSize * 0.6f)
  let charH = int(fontSize * 0.85f)
  var curX = 1
  var curY = 1

  let candidates = collectCandidateCodepoints()

  for code in candidates:
    if curX + charW + 2 >= atlas.width:
      curX = 1
      curY += charH + 2
    if curY + charH + 2 >= atlas.height:
      break

    if code != 32'u32: # Non-space glyph
      for y in 0 ..< charH:
        for x in 0 ..< charW:
          let isBorder = (x == 0 or x == charW - 1 or y == 0 or y == charH - 1)
          let val = if isBorder: 220'u8 else: 180'u8
          atlas.pixels[(curY + y) * atlas.width + (curX + x)] = val

    var g: GlyphInfo
    g.width = if code == 32'u32: 0.0f else: float32(charW)
    g.height = if code == 32'u32: 0.0f else: float32(charH)
    g.bearingX = 0.0f
    g.bearingY = float32(charH)
    g.advance = float32(charW + 2)
    g.uvMin = [float32(curX) / float32(atlas.width), float32(curY) / float32(atlas.height)]
    g.uvMax = [float32(curX + charW) / float32(atlas.width), float32(curY + charH) / float32(atlas.height)]

    if code < 0x0500'u32:
      atlas.glyphs[code] = g
    else:
      atlas.extendedGlyphs[code] = g

    curX += charW + 2

# =============================================================================
# System Atlas Generation (Windows GDI)
# =============================================================================

proc initFontAtlas*(fontName: string = "Segoe UI", fontSize: float32 = 32.0f): FontAtlas {.raises: [].} =
  result.width = 1024
  result.height = 1024
  result.baseSize = fontSize
  result.pixels = newSeq[uint8](result.width * result.height)
  result.extendedGlyphs = initFastMap[uint32, GlyphInfo](2048)
  result.kerningAscii = newSeq[int8](256 * 256)
  result.kerningPairs = initFastMap[uint64, float32]()

  when defined(windows):
    let hdc = CreateCompatibleDC(nil)
    if hdc == nil:
      initFallbackAtlas(result, fontSize)
      return

    let wFontName = newWideCString(fontName)
    let hFont = CreateFontW(
      -int32(fontSize), 0, 0, 0, FW_NORMAL,
      0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
      CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
      wFontName
    )

    if hFont == nil:
      discard DeleteDC(hdc)
      initFallbackAtlas(result, fontSize)
      return

    # Secondary fallback font for symbols/dingbats not present in primary font
    let hFallbackFont = if fontName != "Segoe UI Symbol":
      CreateFontW(
        -int32(fontSize), 0, 0, 0, FW_NORMAL,
        0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
        newWideCString("Segoe UI Symbol")
      )
    else:
      nil

    let oldFont = SelectObject(hdc, hFont)

    # Query kerning pairs for the selected font
    let kernCount = GetKerningPairsW(hdc, 0, nil)
    if kernCount > 0:
      var pairs = newSeq[KERNINGPAIR](kernCount)
      let fetched = GetKerningPairsW(hdc, kernCount, addr pairs[0])
      for i in 0 ..< int(fetched):
        let f = pairs[i].wFirst
        let s = pairs[i].wSecond
        let amt = pairs[i].iKernAmount
        if f < 256 and s < 256:
          result.kerningAscii[(int(f) shl 8) or int(s)] = int8(amt)
        else:
          let key = (uint64(f) shl 32) or uint64(s)
          result.kerningPairs[key] = float32(amt)

    # If fallback font present, query its kerning pairs too
    if hFallbackFont != nil:
      discard SelectObject(hdc, hFallbackFont)
      let fbKernCount = GetKerningPairsW(hdc, 0, nil)
      if fbKernCount > 0:
        var fbPairs = newSeq[KERNINGPAIR](fbKernCount)
        let fbFetched = GetKerningPairsW(hdc, fbKernCount, addr fbPairs[0])
        for i in 0 ..< int(fbFetched):
          let f = fbPairs[i].wFirst
          let s = fbPairs[i].wSecond
          let amt = fbPairs[i].iKernAmount
          if f < 256 and s < 256:
            let idx = (int(f) shl 8) or int(s)
            if result.kerningAscii[idx] == 0:
              result.kerningAscii[idx] = int8(amt)
          else:
            let key = (uint64(f) shl 32) or uint64(s)
            if not result.kerningPairs.contains(key):
              result.kerningPairs[key] = float32(amt)
      discard SelectObject(hdc, hFont)

    var tm: TEXTMETRICW
    if GetTextMetricsW(hdc, addr tm) != 0:
      result.lineHeight = float32(tm.tmHeight + tm.tmExternalLeading)
      result.ascender = float32(tm.tmAscent)
      result.descender = float32(tm.tmDescent)
    else:
      result.lineHeight = fontSize * 1.3f
      result.ascender = fontSize * 0.9f
      result.descender = fontSize * 0.3f

    var mat: MAT2
    mat.eM11.value = 1
    mat.eM22.value = 1

    var curX = 1
    var curY = 1
    var rowH = 0

    var tempBuf = newSeq[uint8](4096)

    let charsToRasterize = collectCandidateCodepoints()

    for ch in charsToRasterize:
      var gm: GLYPHMETRICS
      var reqSize = GetGlyphOutlineW(hdc, ch, GGO_GRAY8_BITMAP, addr gm, 0, nil, addr mat)
      var switchedFont = false

      # If primary font failed or has no glyph for a non-space char, try fallback font
      if (reqSize == GDI_ERROR or (reqSize == 0 and ch != 32'u32)) and hFallbackFont != nil:
        discard SelectObject(hdc, hFallbackFont)
        switchedFont = true
        reqSize = GetGlyphOutlineW(hdc, ch, GGO_GRAY8_BITMAP, addr gm, 0, nil, addr mat)

      # If still error or invalid, restore font if switched and continue
      if reqSize == GDI_ERROR:
        if switchedFont:
          discard SelectObject(hdc, hFont)
        continue

      var g: GlyphInfo
      g.advance = float32(gm.gmCellIncX)

      if reqSize > 0 and gm.gmBlackBoxX > 0 and gm.gmBlackBoxY > 0 and ch != 32'u32:
        g.bearingX = float32(gm.gmptGlyphOrigin.x - 1)
        g.bearingY = float32(gm.gmptGlyphOrigin.y + 1)
        g.width = float32(gm.gmBlackBoxX + 2)
        g.height = float32(gm.gmBlackBoxY + 2)

        if tempBuf.len < int(reqSize):
          tempBuf.setLen(int(reqSize))

        let fetched = GetGlyphOutlineW(hdc, ch, GGO_GRAY8_BITMAP, addr gm, reqSize, addr tempBuf[0], addr mat)
        if fetched == reqSize:
          let bw = int(gm.gmBlackBoxX)
          let bh = int(gm.gmBlackBoxY)
          let slotW = bw + 2
          let slotH = bh + 2

          if curX + slotW + 2 >= result.width:
            curX = 1
            curY += rowH + 2
            rowH = 0

          if curY + slotH + 2 >= result.height:
            # Atlas full
            if switchedFont:
              discard SelectObject(hdc, hFont)
            break

          let pitch = (bw + 3) and not 3

          for r in 0 ..< bh:
            for c in 0 ..< bw:
              let val = uint32(tempBuf[r * pitch + c]) # 0..64
              let alpha = min(255'u32, (val * 255'u32 + 32'u32) div 64'u32)
              result.pixels[(curY + 1 + r) * result.width + (curX + 1 + c)] = uint8(alpha)

          g.uvMin = [float32(curX) / float32(result.width), float32(curY) / float32(result.height)]
          g.uvMax = [float32(curX + slotW) / float32(result.width), float32(curY + slotH) / float32(result.height)]

          curX += slotW + 2
          if slotH > rowH:
            rowH = slotH
      else:
        # Whitespace / zero-box glyphs must not emit geometry
        g.bearingX = 0.0f
        g.bearingY = 0.0f
        g.width = 0.0f
        g.height = 0.0f
        g.uvMin = [0.0f, 0.0f]
        g.uvMax = [0.0f, 0.0f]

      if switchedFont:
        discard SelectObject(hdc, hFont)

      if ch < 0x0500'u32:
        result.glyphs[ch] = g
      else:
        result.extendedGlyphs[ch] = g

    discard SelectObject(hdc, oldFont)
    discard DeleteObject(hFont)
    if hFallbackFont != nil:
      discard DeleteObject(hFallbackFont)
    discard DeleteDC(hdc)
  else:
    initFallbackAtlas(result, fontSize)

# =============================================================================
# Text Measurement & Glyph Query Helpers
# =============================================================================

{.push stacktrace: off, linetrace: off.}

proc isIgnoredCodepoint*(cp: uint32): bool {.inline, raises: [].} =
  # Variation selectors (U+FE00..U+FE0F, specifically U+FE0F)
  # Variation selectors supplement (U+E0100..U+E01EF)
  # Zero-width spaces, BOM, joiners, carriage return, null, word joiner, soft hyphen
  (cp >= 0xFE00'u32 and cp <= 0xFE0F'u32) or
  (cp >= 0xE0100'u32 and cp <= 0xE01EF'u32) or
  cp == 0'u32 or cp == 13'u32 or
  cp == 0x200B'u32 or cp == 0x200C'u32 or cp == 0x200D'u32 or
  cp == 0x2060'u32 or cp == 0xFEFF'u32 or cp == 0x00AD'u32

proc getKerning*(atlas: FontAtlas, prev, curr: uint32): float32 {.inline, raises: [].} =
  if prev < 256 and curr < 256:
    if atlas.kerningAscii.len == 65536:
      return float32(atlas.kerningAscii[(int(prev) shl 8) or int(curr)])
  elif atlas.kerningPairs.len > 0:
    let key = (uint64(prev) shl 32) or uint64(curr)
    return atlas.kerningPairs.getOrDefault(key, 0.0f)
  0.0f

proc getKerning*(atlas: FontAtlas, prev, curr: Rune): float32 {.inline, raises: [].} =
  atlas.getKerning(uint32(prev), uint32(curr))

proc getGlyph*(atlas: FontAtlas, r: Rune): GlyphInfo {.inline, raises: [].} =
  let cp = uint32(r)
  if isIgnoredCodepoint(cp):
    return GlyphInfo()

  if cp < 0x0500'u32:
    let g = atlas.glyphs[cp]
    if g.advance > 0.0f or g.width > 0.0f or cp == 32'u32:
      return g
  else:
    if atlas.extendedGlyphs.len > 0:
      let g = atlas.extendedGlyphs.getOrDefault(cp)
      if g.advance > 0.0f or g.width > 0.0f:
        return g

  # Fallback to question mark or space
  result = atlas.glyphs[ord('?')]

proc measureText*(atlas: FontAtlas, text: string, fontSize: float32): tuple[width, height: float32] {.raises: [].} =
  let scale = if atlas.baseSize > 0.0f: fontSize / atlas.baseSize else: 1.0f
  var curLineW = 0.0f
  var maxW = 0.0f
  var totalH = atlas.lineHeight * scale
  var hasPrev = false
  var prevRune = Rune(0)
  var lastGlyphExtra = 0.0f

  for r in runes(text):
    if r == Rune(10): # Newline
      totalH += atlas.lineHeight * scale
      if curLineW + lastGlyphExtra > maxW: maxW = curLineW + lastGlyphExtra
      curLineW = 0.0f
      lastGlyphExtra = 0.0f
      hasPrev = false
      continue

    if isIgnoredCodepoint(uint32(r)):
      continue

    if hasPrev:
      curLineW += atlas.getKerning(prevRune, r) * scale

    let g = atlas.getGlyph(r)
    # Account for visual right-side overhang past advance (italics, curves, serifs)
    let overhang = max(0.0f, (g.bearingX + g.width - g.advance) * scale)
    lastGlyphExtra = overhang
    curLineW += g.advance * scale
    prevRune = r
    hasPrev = true

  if curLineW + lastGlyphExtra > maxW: maxW = curLineW + lastGlyphExtra
  (maxW, totalH)

{.pop.}
