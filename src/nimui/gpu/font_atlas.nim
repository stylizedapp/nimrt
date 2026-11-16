## nimui/gpu/font_atlas — System Font Rasterizer, Dynamic LRU Texture Atlas & Metrics
##
## Architecture & Rendering Mechanism:
## - Shapes/primitives in NimUI use analytical 2D SDF (`sdRoundedBox` in `ui.frag` / `rasterizer.nim`).
## - Text glyphs in `FontAtlas` use Windows GDI `GetGlyphOutlineW(..., GGO_GRAY8_BITMAP, ...)`
##   65-level anti-aliased grayscale coverage bitmaps packed into an `R8_UNORM` atlas texture
##   (sampled bilinearly in `ui.frag` with `pow(rawAlpha, 0.78)` gamma compensation), NOT SDF.
## - High-DPI crispness: `dpiScale` rasterizes GDI glyphs at `fontSize * dpiScale` physical pixels
##   while keeping logical DIP metrics (`baseSize = fontSize`), eliminating upscaling blur at 125%-150%+ DPI.
## - Unicode coverage: ASCII (32..126), UI Symbols & Dingbats, Latin-1 Supplement (U+00A0..U+00FF),
##   Latin Extended-A & Extended-B (U+0100..U+024F), Cyrillic (U+0400..U+04FF), plus U+FFFD tofu fallback.
## - Missing glyph detection: `GetGlyphIndicesW(GGI_MARK_NONEXISTING_GLYPHS)` + multi-font GDI fallback
##   (`Segoe UI Symbol`, `Microsoft YaHei`, `Malgun Gothic`) + guaranteed pinned tofu box (`missingGlyph`).
## - Genuine LRU eviction + shelf compaction/repack when full, returning explicit `Result` errors if a
##   single glyph cannot fit even after evicting all evictable entries.

import std/algorithm
import ../../corex/unicode
import ../../corex/result
import ../../algx/swissmap
export unicode, result

type
  GlyphInfo* = object
    uvMin*: array[2, float32]
    uvMax*: array[2, float32]
    width*: float32
    height*: float32
    bearingX*: float32
    bearingY*: float32
    advance*: float32

  AtlasGlyphSlot* = object
    cp*: uint32
    x*: uint16
    y*: uint16
    w*: uint16
    h*: uint16
    lastUsedTick*: uint64
    pinned*: bool
    active*: bool

  FontAtlas* = object
    width*: int
    height*: int
    baseSize*: float32
    dpiScale*: float32
    rasterSize*: float32
    fontName*: string
    lineHeight*: float32
    ascender*: float32
    descender*: float32
    pixels*: seq[uint8]               # R8_UNORM pixel buffer
    glyphs*: array[0x0500, GlyphInfo] # Fast direct lookup for 0..0x04FF (ASCII, Latin-1/Ext-A/B, Cyrillic)
    extendedGlyphs*: FastMap[uint32, GlyphInfo] # Lookup for codepoints >= 0x0500
    kerningAscii*: seq[int8]          # Fast O(1) 256x256 direct lookup for ASCII/Latin-1
    kerningPairs*: FastMap[uint64, float32] # Kerning adjustments for extended/Unicode pairs

    # Shelf packer & LRU eviction state
    curX*: int
    curY*: int
    rowH*: int
    lruTick*: uint64
    epoch*: uint64
    evictionCount*: uint64
    overflowCount*: uint64
    lastError*: string
    atlasNeedsUpload*: bool
    missingGlyph*: GlyphInfo
    slots*: seq[AtlasGlyphSlot]
    cpToSlot*: FastMap[uint32, int]

# =============================================================================
# Windows GDI Interop
# =============================================================================

when defined(windows):
  type
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
    GGI_MARK_NONEXISTING_GLYPHS = 0x0001'u32

  # Safe: standard Win32 gdi32.dll font/glyph rasterization FFI bindings.
  proc CreateCompatibleDC(hdc: HDC): HDC {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "CreateCompatibleDC", raises: [].}
  proc DeleteDC(hdc: HDC): BOOL {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "DeleteDC", raises: [].}
  proc SelectObject(hdc: HDC, h: HGDIOBJ): HGDIOBJ {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "SelectObject", raises: [].}
  proc DeleteObject(ho: HGDIOBJ): BOOL {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "DeleteObject", raises: [].}
  proc CreateFontW(
    cHeight, cWidth, cEscapement, cOrientation, cWeight: int32,
    bItalic, bUnderline, bStrikeOut, iCharSet, iOutPrecision,
    iClipPrecision, iQuality, iPitchAndFamily: int32,
    pszFaceName: WideCString
  ): HFONT {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "CreateFontW", raises: [].}
  proc GetTextMetricsW(hdc: HDC, lptm: ptr TEXTMETRICW): BOOL {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "GetTextMetricsW", raises: [].}
  proc GetKerningPairsW(hdc: HDC, nPairs: DWORD, lpKernPair: ptr KERNINGPAIR): DWORD {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "GetKerningPairsW", raises: [].}
  proc GetGlyphIndicesW(hdc: HDC, lpstr: ptr WORD, c: int32, pgi: ptr WORD, fl: DWORD): DWORD {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "GetGlyphIndicesW", raises: [].}
  proc GetGlyphOutlineW(
    hdc: HDC, uChar: UINT, fuFormat: UINT, lpgm: ptr GLYPHMETRICS,
    cjBuffer: DWORD, pvBuffer: pointer, lpmat2: ptr MAT2
  ): DWORD {.trustedUnsafe, stdcall, dynlib: "gdi32", importc: "GetGlyphOutlineW", raises: [].}

  # Safe: queries GDI glyph index using stack-local ch16/gIdx pointers.
  proc fontHasGlyph(hdc: HDC, cp: uint32): bool {.trustedUnsafe, inline, raises: [].} =
    if cp > 0xFFFF'u32:
      return true # Let GetGlyphOutlineW check/skip surrogate outside BMP
    var ch16 = uint16(cp)
    var gIdx: uint16 = 0'u16
    let res = GetGlyphIndicesW(hdc, addr ch16, 1, addr gIdx, GGI_MARK_NONEXISTING_GLYPHS)
    if res == GDI_ERROR:
      return true
    gIdx != 0xFFFF'u16

# =============================================================================
# Helper: Standard Unicode Ranges for UI Rendering
# =============================================================================

proc collectCandidateCodepoints*(): seq[uint32] {.raises: [].} =
  result = @[]
  # 1. ASCII printable (32..126)
  for c in 32'u32 .. 126'u32:
    result.add(c)

  # 2. High-Priority UI Symbols & Dingbats (Checkmarks, Badges, Astrometrics, Bullets)
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

  # 3. Latin-1 Supplement (0x00A0..0x00FF: é, ü, ß, ñ, etc.)
  for c in 0x00A0'u32 .. 0x00FF'u32:
    if c notin prioritySymbols:
      result.add(c)

  # 4. Latin Extended-A & Latin Extended-B (0x0100..0x024F)
  for c in 0x0100'u32 .. 0x024F'u32:
    result.add(c)

  # 5. Full Cyrillic Block (0x0400..0x04FF)
  for c in 0x0400'u32 .. 0x04FF'u32:
    result.add(c)

# =============================================================================
# Shelf Packing & Genuine LRU Eviction Engine
# =============================================================================

proc storeGlyphEntry(atlas: var FontAtlas, cp: uint32, g: GlyphInfo) {.inline, raises: [].} =
  if cp < 0x0500'u32:
    atlas.glyphs[cp] = g
  else:
    atlas.extendedGlyphs[cp] = g

proc removeGlyphEntry(atlas: var FontAtlas, cp: uint32) {.inline, raises: [].} =
  if cp < 0x0500'u32:
    atlas.glyphs[cp] = GlyphInfo()
  else:
    discard atlas.extendedGlyphs.del(cp)

proc getStoredGlyph(atlas: FontAtlas, cp: uint32): GlyphInfo {.inline, raises: [].} =
  if cp < 0x0500'u32:
    atlas.glyphs[cp]
  else:
    atlas.extendedGlyphs.getOrDefault(cp)

proc advanceFrame*(atlas: var FontAtlas) {.inline, raises: [].} =
  inc(atlas.lruTick)

proc touchGlyph*(atlas: var FontAtlas, cp: uint32) {.inline, raises: [].} =
  let slotIdx = atlas.cpToSlot.getOrDefault(cp, -1)
  if slotIdx >= 0 and slotIdx < atlas.slots.len and atlas.slots[slotIdx].active:
    inc(atlas.lruTick)
    atlas.slots[slotIdx].lastUsedTick = atlas.lruTick

proc activeGlyphCount*(atlas: FontAtlas): int {.inline, raises: [].} =
  for s in atlas.slots:
    if s.active:
      inc(result)

proc hasResidentGlyph*(atlas: FontAtlas, cp: uint32): bool {.inline, raises: [].} =
  let idx = atlas.cpToSlot.getOrDefault(cp, -1)
  idx >= 0 and idx < atlas.slots.len and atlas.slots[idx].active

proc canPackSlots(
  atlasW, atlasH: int,
  slots: openArray[AtlasGlyphSlot],
  skipFlags: openArray[bool],
  newW, newH: int
): bool {.raises: [].} =
  var cx = 1
  var cy = 1
  var rh = 0

  for i in 0 ..< slots.len:
    if not slots[i].active or skipFlags[i]:
      continue
    let sw = int(slots[i].w)
    let sh = int(slots[i].h)
    if sw <= 0 or sh <= 0:
      continue
    if cx + sw + 2 >= atlasW:
      cx = 1
      cy += rh + 2
      rh = 0
    if cy + sh + 2 >= atlasH:
      return false
    cx += sw + 2
    if sh > rh:
      rh = sh

  if newW > 0 and newH > 0:
    if cx + newW + 2 >= atlasW:
      cx = 1
      cy += rh + 2
      rh = 0
    if cy + newH + 2 >= atlasH:
      return false

  true

proc evictLruAndRepack(atlas: var FontAtlas, neededW, neededH: int): Result[void, string] {.raises: [].} =
  var candidates = newSeqOfCap[tuple[tick: uint64, idx: int]](atlas.slots.len)
  for i in 0 ..< atlas.slots.len:
    if atlas.slots[i].active and not atlas.slots[i].pinned:
      candidates.add((atlas.slots[i].lastUsedTick, i))

  if candidates.len == 0:
    return err[void, string]("Atlas full and no evictable (non-pinned) glyphs remain")

  # Sort oldest-used first (genuine LRU order)
  candidates.sort(proc(a, b: tuple[tick: uint64, idx: int]): int =
    cmp(a.tick, b.tick)
  )

  var skipFlags = newSeq[bool](atlas.slots.len)
  # Check if even evicting every non-pinned glyph can fit the incoming glyph
  for c in candidates:
    skipFlags[c.idx] = true
  if not canPackSlots(atlas.width, atlas.height, atlas.slots, skipFlags, neededW, neededH):
    return err[void, string]("Glyph cannot fit in atlas even after evicting all LRU entries")

  # Binary search for the exact minimum number of LRU glyphs to evict
  var lo = 1
  var hi = candidates.len
  var bestK = candidates.len
  while lo <= hi:
    let mid = (lo + hi) div 2
    for i in 0 ..< skipFlags.len:
      skipFlags[i] = false
    for j in 0 ..< mid:
      skipFlags[candidates[j].idx] = true
    if canPackSlots(atlas.width, atlas.height, atlas.slots, skipFlags, neededW, neededH):
      bestK = mid
      hi = mid - 1
    else:
      lo = mid + 1

  for i in 0 ..< skipFlags.len:
    skipFlags[i] = false
  for j in 0 ..< bestK:
    let idx = candidates[j].idx
    skipFlags[idx] = true
    let cp = atlas.slots[idx].cp
    atlas.removeGlyphEntry(cp)
    discard atlas.cpToSlot.del(cp)
    atlas.slots[idx].active = false

  # Repack surviving glyphs into a clean pixel buffer (zero fragmentation)
  var newPixels = newSeq[uint8](atlas.width * atlas.height)
  var newSlots = newSeqOfCap[AtlasGlyphSlot](atlas.slots.len - bestK + 1)
  atlas.cpToSlot.clear()
  atlas.curX = 1
  atlas.curY = 1
  atlas.rowH = 0

  for i in 0 ..< atlas.slots.len:
    if not atlas.slots[i].active:
      continue
    var s = atlas.slots[i]
    let sw = int(s.w)
    let sh = int(s.h)
    if sw > 0 and sh > 0:
      if atlas.curX + sw + 2 >= atlas.width:
        atlas.curX = 1
        atlas.curY += atlas.rowH + 2
        atlas.rowH = 0

      let oldX = int(s.x)
      let oldY = int(s.y)
      let nx = atlas.curX
      let ny = atlas.curY
      for r in 0 ..< sh:
        for c in 0 ..< sw:
          newPixels[(ny + r) * atlas.width + nx + c] = atlas.pixels[(oldY + r) * atlas.width + oldX + c]

      s.x = uint16(nx)
      s.y = uint16(ny)
      var g = atlas.getStoredGlyph(s.cp)
      g.uvMin = [float32(nx) / float32(atlas.width), float32(ny) / float32(atlas.height)]
      g.uvMax = [float32(nx + sw) / float32(atlas.width), float32(ny + sh) / float32(atlas.height)]
      atlas.storeGlyphEntry(s.cp, g)

      atlas.curX += sw + 2
      if sh > atlas.rowH:
        atlas.rowH = sh

    let newIdx = newSlots.len
    newSlots.add(s)
    atlas.cpToSlot[s.cp] = newIdx

  atlas.slots = move(newSlots)
  atlas.pixels = move(newPixels)
  atlas.evictionCount += uint64(bestK)
  inc(atlas.epoch)
  atlas.atlasNeedsUpload = true
  ok[void, string]()

proc packGlyphBitmap*(
  atlas: var FontAtlas,
  cp: uint32,
  bw, bh: int,
  bitmap: openArray[uint8],
  pitch: int,
  bearingX, bearingY, advance: float32,
  isGray64: bool = false,
  pinned: bool = false,
  allowEvict: bool = true
): Result[GlyphInfo, string] {.raises: [].} =
  ## Packs a rasterized glyph bitmap into the atlas shelf, triggering genuine LRU eviction
  ## and shelf compaction if full. Returns an explicit error if the glyph still cannot fit.
  let existingIdx = atlas.cpToSlot.getOrDefault(cp, -1)
  if existingIdx >= 0 and existingIdx < atlas.slots.len and atlas.slots[existingIdx].active:
    inc(atlas.lruTick)
    atlas.slots[existingIdx].lastUsedTick = atlas.lruTick
    if pinned:
      atlas.slots[existingIdx].pinned = true
    return ok[GlyphInfo, string](atlas.getStoredGlyph(cp))

  let invScale = if atlas.dpiScale > 0.1f: 1.0f / atlas.dpiScale else: 1.0f

  if bw <= 0 or bh <= 0 or cp == 32'u32:
    var g: GlyphInfo
    g.advance = advance * invScale
    atlas.storeGlyphEntry(cp, g)
    inc(atlas.lruTick)
    let idx = atlas.slots.len
    atlas.slots.add(AtlasGlyphSlot(
      cp: cp, x: 0, y: 0, w: 0, h: 0,
      lastUsedTick: atlas.lruTick, pinned: pinned, active: true
    ))
    atlas.cpToSlot[cp] = idx
    return ok[GlyphInfo, string](g)

  let slotW = bw + 2
  let slotH = bh + 2

  if slotW + 2 >= atlas.width or slotH + 2 >= atlas.height:
    let errMsg = "Glyph codepoint 0x" & $cp & " (" & $slotW & "x" & $slotH & ") exceeds atlas bounds (" & $atlas.width & "x" & $atlas.height & ")"
    atlas.lastError = errMsg
    inc(atlas.overflowCount)
    return err[GlyphInfo, string](errMsg)

  if atlas.curX + slotW + 2 >= atlas.width:
    atlas.curX = 1
    atlas.curY += atlas.rowH + 2
    atlas.rowH = 0

  if atlas.curY + slotH + 2 >= atlas.height:
    if not allowEvict:
      let errMsg = "Atlas full (" & $atlas.width & "x" & $atlas.height & ") during non-evicting pack"
      atlas.lastError = errMsg
      inc(atlas.overflowCount)
      return err[GlyphInfo, string](errMsg)

    let evictRes = atlas.evictLruAndRepack(slotW, slotH)
    if evictRes.isErr:
      atlas.lastError = evictRes.error
      inc(atlas.overflowCount)
      return err[GlyphInfo, string](evictRes.error)

    if atlas.curX + slotW + 2 >= atlas.width:
      atlas.curX = 1
      atlas.curY += atlas.rowH + 2
      atlas.rowH = 0
    if atlas.curY + slotH + 2 >= atlas.height:
      let errMsg = "Atlas full after LRU compaction"
      atlas.lastError = errMsg
      inc(atlas.overflowCount)
      return err[GlyphInfo, string](errMsg)

  let dstX = atlas.curX
  let dstY = atlas.curY

  for r in 0 ..< bh:
    for c in 0 ..< bw:
      let rawVal = bitmap[r * pitch + c]
      let alpha = if isGray64:
        uint8(min(255'u32, (uint32(rawVal) * 255'u32 + 32'u32) div 64'u32))
      else:
        rawVal
      atlas.pixels[(dstY + 1 + r) * atlas.width + (dstX + 1 + c)] = alpha

  var g: GlyphInfo
  g.advance = advance * invScale
  g.bearingX = (bearingX - 1.0f) * invScale
  g.bearingY = (bearingY + 1.0f) * invScale
  g.width = float32(slotW) * invScale
  g.height = float32(slotH) * invScale
  g.uvMin = [float32(dstX) / float32(atlas.width), float32(dstY) / float32(atlas.height)]
  g.uvMax = [float32(dstX + slotW) / float32(atlas.width), float32(dstY + slotH) / float32(atlas.height)]

  atlas.curX += slotW + 2
  if slotH > atlas.rowH:
    atlas.rowH = slotH

  atlas.storeGlyphEntry(cp, g)
  inc(atlas.lruTick)
  let slotIdx = atlas.slots.len
  atlas.slots.add(AtlasGlyphSlot(
    cp: cp,
    x: uint16(dstX), y: uint16(dstY),
    w: uint16(slotW), h: uint16(slotH),
    lastUsedTick: atlas.lruTick,
    pinned: pinned,
    active: true
  ))
  atlas.cpToSlot[cp] = slotIdx
  atlas.atlasNeedsUpload = true
  ok[GlyphInfo, string](g)

proc generateTofuBitmap(charW, charH: int): seq[uint8] {.raises: [].} =
  let w = max(4, charW)
  let h = max(6, charH)
  let stroke = max(1, min(w, h) div 6)
  result = newSeq[uint8](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let isBorder = (x < stroke or x >= w - stroke or y < stroke or y >= h - stroke)
      if isBorder:
        result[y * w + x] = 220'u8

proc ensurePinnedMissingGlyph(atlas: var FontAtlas) {.raises: [].} =
  let charW = max(6, int(atlas.rasterSize * 0.55f))
  let charH = max(8, int(atlas.rasterSize * 0.78f))
  let tofu = generateTofuBitmap(charW, charH)
  let res = atlas.packGlyphBitmap(
    0xFFFD'u32, charW, charH, tofu, charW,
    bearingX = 1.0f,
    bearingY = float32(charH),
    advance = float32(charW + max(2, int(atlas.rasterSize * 0.1f))),
    isGray64 = false,
    pinned = true,
    allowEvict = true
  )
  if res.isOk:
    atlas.missingGlyph = res.val

# =============================================================================
# Fallback Glyph Generation (Cross-Platform / Headless)
# =============================================================================

proc initAtlasBase(
  atlas: var FontAtlas,
  fontName: string,
  fontSize: float32,
  dpiScale: float32,
  atlasWidth, atlasHeight: int
) {.raises: [].} =
  let effDpi = if dpiScale > 0.1f: dpiScale else: 1.0f
  let effW = max(64, atlasWidth)
  let effH = max(64, atlasHeight)
  atlas.width = effW
  atlas.height = effH
  atlas.baseSize = fontSize
  atlas.dpiScale = effDpi
  atlas.rasterSize = fontSize * effDpi
  atlas.fontName = fontName
  atlas.pixels = newSeq[uint8](effW * effH)
  atlas.extendedGlyphs = initFastMap[uint32, GlyphInfo](2048)
  atlas.kerningAscii = newSeq[int8](256 * 256)
  atlas.kerningPairs = initFastMap[uint64, float32]()
  atlas.curX = 1
  atlas.curY = 1
  atlas.rowH = 0
  atlas.lruTick = 0
  atlas.epoch = 1
  atlas.evictionCount = 0
  atlas.overflowCount = 0
  atlas.lastError = ""
  atlas.atlasNeedsUpload = true
  atlas.slots = newSeqOfCap[AtlasGlyphSlot](1024)
  atlas.cpToSlot = initFastMap[uint32, int](2048)

proc initFallbackAtlas(atlas: var FontAtlas, fontSize: float32) {.raises: [].} =
  let rs = atlas.rasterSize
  atlas.lineHeight = fontSize * 1.25f
  atlas.ascender = fontSize * 0.9f
  atlas.descender = fontSize * 0.25f

  atlas.ensurePinnedMissingGlyph()

  let charW = max(4, int(rs * 0.6f))
  let charH = max(6, int(rs * 0.85f))
  var bmp = newSeq[uint8](charW * charH)
  for y in 0 ..< charH:
    for x in 0 ..< charW:
      let isBorder = (x == 0 or x == charW - 1 or y == 0 or y == charH - 1)
      bmp[y * charW + x] = if isBorder: 220'u8 else: 180'u8

  let candidates = collectCandidateCodepoints()
  for code in candidates:
    let isCore = code <= 126'u32
    let res = if code == 32'u32:
      atlas.packGlyphBitmap(
        code, 0, 0, bmp, charW,
        0.0f, 0.0f, float32(charW + 2),
        isGray64 = false, pinned = (code == uint32('?')), allowEvict = false
      )
    else:
      atlas.packGlyphBitmap(
        code, charW, charH, bmp, charW,
        0.0f, float32(charH), float32(charW + 2),
        isGray64 = false, pinned = (code == uint32('?')), allowEvict = false
      )
    if res.isErr:
      if isCore:
        # Retry with LRU eviction for core ASCII if needed
        let retry = atlas.packGlyphBitmap(
          code, charW, charH, bmp, charW,
          0.0f, float32(charH), float32(charW + 2),
          isGray64 = false, pinned = (code == uint32('?')), allowEvict = true
        )
        if retry.isErr:
          atlas.storeGlyphEntry(code, atlas.missingGlyph)
      else:
        break

# =============================================================================
# System Atlas Generation (Windows GDI) & Dynamic Glyph Rasterization
# =============================================================================

when defined(windows):
  # Safe: Win32 GDI glyph outline query using valid HDC and sized tempBuf.
  proc queryGdiGlyph(
    hdc: HDC,
    fonts: openArray[HFONT],
    ch: uint32,
    tempBuf: var seq[uint8],
    outGm: var GLYPHMETRICS,
    outReqSize: var uint32
  ): bool {.trustedUnsafe, raises: [].} =
    var mat: MAT2
    mat.eM11.value = 1
    mat.eM22.value = 1

    for i, fnt in fonts:
      if fnt == nil:
        continue
      discard SelectObject(hdc, fnt)
      if i > 0 and not fontHasGlyph(hdc, ch):
        continue
      if i == 0 and not fontHasGlyph(hdc, ch):
        continue

      var gm: GLYPHMETRICS
      let reqSize = GetGlyphOutlineW(hdc, ch, GGO_GRAY8_BITMAP, addr gm, 0, nil, addr mat)
      if reqSize == GDI_ERROR:
        continue
      if reqSize == 0 and ch != 32'u32 and gm.gmCellIncX == 0:
        continue

      if reqSize > 0 and gm.gmBlackBoxX > 0 and gm.gmBlackBoxY > 0 and ch != 32'u32:
        if tempBuf.len < int(reqSize):
          tempBuf.setLen(int(reqSize))
        let fetched = GetGlyphOutlineW(hdc, ch, GGO_GRAY8_BITMAP, addr gm, reqSize, addr tempBuf[0], addr mat)
        if fetched != reqSize:
          continue

      outGm = gm
      outReqSize = reqSize
      return true

    false

# Safe: Win32 GDI DC/HFONT handles are nil-checked and released before return.
proc ensureGlyph*(atlas: var FontAtlas, cp: uint32): Result[GlyphInfo, string] {.trustedUnsafe, raises: [].} =
  ## Ensures `cp` is resident in the atlas, dynamically rasterizing it (via GDI on Windows)
  ## and evicting LRU entries if the atlas is full.
  let existingIdx = atlas.cpToSlot.getOrDefault(cp, -1)
  if existingIdx >= 0 and existingIdx < atlas.slots.len and atlas.slots[existingIdx].active:
    inc(atlas.lruTick)
    atlas.slots[existingIdx].lastUsedTick = atlas.lruTick
    return ok[GlyphInfo, string](atlas.getStoredGlyph(cp))

  when defined(windows):
    let hdc = CreateCompatibleDC(nil)
    if hdc == nil:
      return err[GlyphInfo, string]("CreateCompatibleDC failed")

    let rSize = max(1'i32, int32(atlas.rasterSize + 0.5f))
    let hPrimary = CreateFontW(
      -rSize, 0, 0, 0, FW_NORMAL, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
      newWideCString(if atlas.fontName.len > 0: atlas.fontName else: "Segoe UI")
    )
    let hSymbol = CreateFontW(
      -rSize, 0, 0, 0, FW_NORMAL, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
      newWideCString("Segoe UI Symbol")
    )
    let hCjk = CreateFontW(
      -rSize, 0, 0, 0, FW_NORMAL, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
      newWideCString("Microsoft YaHei")
    )
    let hKr = CreateFontW(
      -rSize, 0, 0, 0, FW_NORMAL, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
      newWideCString("Malgun Gothic")
    )
    let oldFont = SelectObject(hdc, hPrimary)
    var tempBuf = newSeq[uint8](4096)
    var gm: GLYPHMETRICS
    var reqSize: uint32 = 0

    let found = queryGdiGlyph(hdc, [hPrimary, hSymbol, hCjk, hKr], cp, tempBuf, gm, reqSize)
    discard SelectObject(hdc, oldFont)
    if hPrimary != nil: discard DeleteObject(hPrimary)
    if hSymbol != nil: discard DeleteObject(hSymbol)
    if hCjk != nil: discard DeleteObject(hCjk)
    if hKr != nil: discard DeleteObject(hKr)
    discard DeleteDC(hdc)

    if not found:
      if atlas.missingGlyph.width > 0.0f:
        return ok[GlyphInfo, string](atlas.missingGlyph)
      return err[GlyphInfo, string]("Codepoint 0x" & $cp & " has no glyph in system fonts")

    if reqSize > 0 and gm.gmBlackBoxX > 0 and gm.gmBlackBoxY > 0 and cp != 32'u32:
      let bw = int(gm.gmBlackBoxX)
      let bh = int(gm.gmBlackBoxY)
      let pitch = (bw + 3) and not 3
      return atlas.packGlyphBitmap(
        cp, bw, bh, tempBuf, pitch,
        float32(gm.gmptGlyphOrigin.x), float32(gm.gmptGlyphOrigin.y),
        float32(gm.gmCellIncX), isGray64 = true, pinned = false, allowEvict = true
      )
    else:
      return atlas.packGlyphBitmap(
        cp, 0, 0, tempBuf, 0,
        0.0f, 0.0f, float32(gm.gmCellIncX),
        isGray64 = true, pinned = false, allowEvict = true
      )
  else:
    let charW = max(4, int(atlas.rasterSize * 0.55f))
    let charH = max(6, int(atlas.rasterSize * 0.78f))
    let tofu = generateTofuBitmap(charW, charH)
    atlas.packGlyphBitmap(
      cp, charW, charH, tofu, charW,
      1.0f, float32(charH), float32(charW + 2),
      isGray64 = false, pinned = false, allowEvict = true
    )

# Safe: Win32 GDI DC/HFONT handles are nil-checked and released before return.
proc initFontAtlas*(
  fontName: string = "Segoe UI",
  fontSize: float32 = 32.0f,
  dpiScale: float32 = 1.0f,
  atlasWidth: int = 1024,
  atlasHeight: int = 1024
): FontAtlas {.trustedUnsafe, raises: [].} =
  initAtlasBase(result, fontName, fontSize, dpiScale, atlasWidth, atlasHeight)

  when defined(windows):
    let hdc = CreateCompatibleDC(nil)
    if hdc == nil:
      initFallbackAtlas(result, fontSize)
      return

    let rSize = max(1'i32, int32(result.rasterSize + 0.5f))
    let invDpi = if result.dpiScale > 0.1f: 1.0f / result.dpiScale else: 1.0f

    let wFontName = newWideCString(fontName)
    let hFont = CreateFontW(
      -rSize, 0, 0, 0, FW_NORMAL,
      0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
      CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
      wFontName
    )

    if hFont == nil:
      discard DeleteDC(hdc)
      initFallbackAtlas(result, fontSize)
      return

    let hFallbackSymbol = if fontName != "Segoe UI Symbol":
      CreateFontW(
        -rSize, 0, 0, 0, FW_NORMAL,
        0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH or FF_DONTCARE,
        newWideCString("Segoe UI Symbol")
      )
    else:
      nil

    let oldFont = SelectObject(hdc, hFont)

    # Query kerning pairs for the primary font (convert to logical DIPs)
    let kernCount = GetKerningPairsW(hdc, 0, nil)
    if kernCount > 0:
      var pairs = newSeq[KERNINGPAIR](kernCount)
      let fetched = GetKerningPairsW(hdc, kernCount, addr pairs[0])
      for i in 0 ..< int(fetched):
        let f = pairs[i].wFirst
        let s = pairs[i].wSecond
        let amt = float32(pairs[i].iKernAmount) * invDpi
        if f < 256 and s < 256:
          result.kerningAscii[(int(f) shl 8) or int(s)] = int8(clamp(int(amt), -127, 127))
        else:
          let key = (uint64(f) shl 32) or uint64(s)
          result.kerningPairs[key] = amt

    if hFallbackSymbol != nil:
      discard SelectObject(hdc, hFallbackSymbol)
      let fbKernCount = GetKerningPairsW(hdc, 0, nil)
      if fbKernCount > 0:
        var fbPairs = newSeq[KERNINGPAIR](fbKernCount)
        let fbFetched = GetKerningPairsW(hdc, fbKernCount, addr fbPairs[0])
        for i in 0 ..< int(fbFetched):
          let f = fbPairs[i].wFirst
          let s = fbPairs[i].wSecond
          let amt = float32(fbPairs[i].iKernAmount) * invDpi
          if f < 256 and s < 256:
            let idx = (int(f) shl 8) or int(s)
            if result.kerningAscii[idx] == 0:
              result.kerningAscii[idx] = int8(clamp(int(amt), -127, 127))
          else:
            let key = (uint64(f) shl 32) or uint64(s)
            if not result.kerningPairs.contains(key):
              result.kerningPairs[key] = amt
      discard SelectObject(hdc, hFont)

    var tm: TEXTMETRICW
    if GetTextMetricsW(hdc, addr tm) != 0:
      result.lineHeight = float32(tm.tmHeight + tm.tmExternalLeading) * invDpi
      result.ascender = float32(tm.tmAscent) * invDpi
      result.descender = float32(tm.tmDescent) * invDpi
    else:
      result.lineHeight = fontSize * 1.3f
      result.ascender = fontSize * 0.9f
      result.descender = fontSize * 0.3f

    # Always pin a guaranteed tofu replacement glyph first
    result.ensurePinnedMissingGlyph()

    var tempBuf = newSeq[uint8](4096)
    let charsToRasterize = collectCandidateCodepoints()
    let fonts = [hFont, hFallbackSymbol]

    for ch in charsToRasterize:
      var gm: GLYPHMETRICS
      var reqSize: uint32 = 0
      if not queryGdiGlyph(hdc, fonts, ch, tempBuf, gm, reqSize):
        continue

      let isPinned = (ch == uint32('?') or ch == 32'u32)
      let packRes = if reqSize > 0 and gm.gmBlackBoxX > 0 and gm.gmBlackBoxY > 0 and ch != 32'u32:
        let bw = int(gm.gmBlackBoxX)
        let bh = int(gm.gmBlackBoxY)
        let pitch = (bw + 3) and not 3
        result.packGlyphBitmap(
          ch, bw, bh, tempBuf, pitch,
          float32(gm.gmptGlyphOrigin.x), float32(gm.gmptGlyphOrigin.y),
          float32(gm.gmCellIncX), isGray64 = true, pinned = isPinned, allowEvict = false
        )
      else:
        result.packGlyphBitmap(
          ch, 0, 0, tempBuf, 0,
          0.0f, 0.0f, float32(gm.gmCellIncX),
          isGray64 = true, pinned = isPinned, allowEvict = false
        )

      if packRes.isErr:
        # Atlas capacity reached during prewarm: keep already-packed high-priority ranges
        # intact (or retry with LRU eviction only if core ASCII isn't complete yet).
        if ch <= 126'u32:
          let retry = if reqSize > 0 and gm.gmBlackBoxX > 0 and gm.gmBlackBoxY > 0 and ch != 32'u32:
            let bw = int(gm.gmBlackBoxX)
            let bh = int(gm.gmBlackBoxY)
            let pitch = (bw + 3) and not 3
            result.packGlyphBitmap(
              ch, bw, bh, tempBuf, pitch,
              float32(gm.gmptGlyphOrigin.x), float32(gm.gmptGlyphOrigin.y),
              float32(gm.gmCellIncX), isGray64 = true, pinned = isPinned, allowEvict = true
            )
          else:
            ok[GlyphInfo, string](GlyphInfo())
          if retry.isErr:
            result.storeGlyphEntry(ch, result.missingGlyph)
        else:
          result.lastError = packRes.error
          break

    # Refresh LRU ticks on core ASCII + symbols so extended glyphs are evicted first if dynamic pressure occurs
    for c in 32'u32 .. 126'u32:
      result.touchGlyph(c)

    discard SelectObject(hdc, oldFont)
    discard DeleteObject(hFont)
    if hFallbackSymbol != nil:
      discard DeleteObject(hFallbackSymbol)
    discard DeleteDC(hdc)
  else:
    initFallbackAtlas(result, fontSize)

proc rebuildForDpi*(atlas: var FontAtlas, dpiScale: float32) {.raises: [].} =
  ## Rebuilds the font atlas at the given DPI scale while preserving font name, logical size, and atlas dimensions.
  let effDpi = if dpiScale > 0.1f: dpiScale else: 1.0f
  if abs(atlas.dpiScale - effDpi) < 1e-4f:
    return
  let name = if atlas.fontName.len > 0: atlas.fontName else: "Segoe UI"
  let sz = if atlas.baseSize > 0.0f: atlas.baseSize else: 32.0f
  let w = if atlas.width > 0: atlas.width else: 1024
  let h = if atlas.height > 0: atlas.height else: 1024
  let prevEpoch = atlas.epoch
  atlas = initFontAtlas(name, sz, effDpi, w, h)
  atlas.epoch = prevEpoch + 1
  atlas.atlasNeedsUpload = true

# =============================================================================
# Text Measurement & Glyph Query Helpers
# =============================================================================

{.push stacktrace: off, linetrace: off.}

proc isIgnoredCodepoint*(cp: uint32): bool {.inline, raises: [].} =
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

  # Non-covered codepoints fall back cleanly to the pinned tofu replacement box (never silently vanish)
  if atlas.missingGlyph.width > 0.0f or atlas.missingGlyph.advance > 0.0f:
    return atlas.missingGlyph
  result = atlas.glyphs[ord('?')]

proc getGlyphMut*(atlas: var FontAtlas, r: Rune): GlyphInfo {.inline, raises: [].} =
  ## Looks up a glyph and updates its LRU timestamp (dynamically rasterizing if missing).
  let cp = uint32(r)
  if isIgnoredCodepoint(cp):
    return GlyphInfo()
  let slotIdx = atlas.cpToSlot.getOrDefault(cp, -1)
  if slotIdx >= 0 and slotIdx < atlas.slots.len and atlas.slots[slotIdx].active:
    inc(atlas.lruTick)
    atlas.slots[slotIdx].lastUsedTick = atlas.lruTick
    return atlas.getStoredGlyph(cp)
  let res = atlas.ensureGlyph(cp)
  if res.isOk:
    return res.val
  atlas.getGlyph(r)

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
    let overhang = max(0.0f, (g.bearingX + g.width - g.advance) * scale)
    lastGlyphExtra = overhang
    curLineW += g.advance * scale
    prevRune = r
    hasPrev = true

  if curLineW + lastGlyphExtra > maxW: maxW = curLineW + lastGlyphExtra
  (maxW, totalH)

{.pop.}
