## nimui/multiline — Multiline Text Layout, Word Wrapping Engine & Interactive TextArea
##
## Strict invariants:
## - Rune-aware word wrapping engine preserving whitespace and logical paragraphs.
## - Multiline layout, line heights, bounding box calculation (measureMultilineText).
## - Interactive TextArea widget:
##   - Caret row & column navigation (Up, Down, Left, Right, Home, End).
##   - Selection range [selStart..selEnd] with semi-transparent graphite/accent highlight quad.
##   - Full keyboard shortcuts: Ctrl+C, Ctrl+V, Ctrl+X, Ctrl+A, Enter, Backspace, Delete.
##   - Mouse drag selection across lines.
##   - Caret rendering at current position.
## - Follows NimUI patterns: zero runtime memory leaks, monochrome design tokens, ARC/ORC compliance.

import corex/unicode
import corex/[slab, result]
import ./gpu/font_atlas
import ./gpu/vulkan_backend
import ./layout
import ./clipboard

when defined(windows):
  # Safe: standard Win32 user32.dll GetKeyState query by virtual key code, no pointers.
  proc GetKeyState(nVirtKey: int32): int16 {.trustedUnsafe, stdcall, dynlib: "user32", importc: "GetKeyState", raises: [].}

# =============================================================================
# Monochrome Design Tokens
# =============================================================================

const
  ColBgTextArea*        = 0x141416FF'u32  # Dark obsidian container surface
  ColBorderTextArea*    = 0x2A2A30FF'u32  # Subtle layout border
  ColBorderFocused*     = 0x666670FF'u32  # High-contrast focus border
  ColTextDefault*       = 0xF2F2F2FF'u32  # High-contrast primary text
  ColSelectionDefault*  = 0x3A3A4888'u32  # Semi-transparent graphite/accent highlight
  ColCaretDefault*      = 0xF2F2F2FF'u32  # Crisp caret

# =============================================================================
# Logical Lines & Word Wrapping Helpers
# =============================================================================

proc splitLogicalLines*(text: string): seq[string] {.raises: [].} =
  ## Splits text by newline delimiters (\n or \r\n), preserving empty lines.
  if text.len == 0:
    return @[""]

  var start = 0
  var i = 0
  while i < text.len:
    if text[i] == '\r':
      if i + 1 < text.len and text[i + 1] == '\n':
        result.add(text[start ..< i])
        i += 2
        start = i
        continue
      else:
        result.add(text[start ..< i])
        i += 1
        start = i
        continue
    elif text[i] == '\n':
      result.add(text[start ..< i])
      i += 1
      start = i
      continue
    else:
      inc(i)
  result.add(text[start ..< text.len])

proc isWhitespaceRune(r: Rune): bool {.inline, raises: [].} =
  r == Rune(32) or r == Rune(9) or r == Rune(0x00A0)

proc tokenizeParagraph(p: string): seq[string] {.raises: [].} =
  if p.len == 0:
    return @[]
  var pos = 0
  while pos < p.len:
    var r: Rune
    let startByte = pos
    fastRuneAt(p, pos, r, true)
    let isWs = isWhitespaceRune(r)
    while pos < p.len:
      var nextPos = pos
      var nextR: Rune
      fastRuneAt(p, nextPos, nextR, true)
      if isWhitespaceRune(nextR) != isWs:
        break
      pos = nextPos
    result.add(p[startByte ..< pos])

proc wrapTextToLines*(
  text: string,
  maxWidth: float32,
  atlas: FontAtlas,
  fontSize: float32
): seq[string] {.raises: [].} =
  ## Rune-aware word wrapping engine preserving whitespace and explicit newlines.
  if text.len == 0:
    return @[""]

  let paragraphs = splitLogicalLines(text)
  if maxWidth <= 0.0f:
    return paragraphs

  for p in paragraphs:
    if p.len == 0:
      result.add("")
      continue

    if atlas.measureText(p, fontSize).width <= maxWidth:
      result.add(p)
      continue

    let tokens = tokenizeParagraph(p)
    var curLine = ""

    for tok in tokens:
      var firstR: Rune
      var tmpPos = 0
      if tok.len > 0: fastRuneAt(tok, tmpPos, firstR, false)
      let isWs = (tok.len > 0 and isWhitespaceRune(firstR))
      if isWs:
        if curLine.len == 0:
          curLine = tok
        else:
          curLine.add(tok)
      else:
        let candidate = curLine & tok
        let candW = atlas.measureText(candidate, fontSize).width
        if candW <= maxWidth:
          curLine = candidate
        else:
          if curLine.len > 0:
            result.add(curLine)
            curLine = ""
          let tokW = atlas.measureText(tok, fontSize).width
          if tokW <= maxWidth:
            curLine = tok
          else:
            # Word wider than maxWidth: break rune-by-rune
            var chunk = ""
            for r in runes(tok):
              let rStr = toUTF8(r)
              if chunk.len > 0 and atlas.measureText(chunk & rStr, fontSize).width > maxWidth:
                result.add(chunk)
                chunk = rStr
              else:
                chunk.add(rStr)
            curLine = chunk

    if curLine.len > 0:
      result.add(curLine)

# =============================================================================
# Multiline Layout & Measurement
# =============================================================================

type
  MultilineMetrics* = object
    width*: float32
    height*: float32
    lineHeight*: float32
    lineCount*: int
    lines*: seq[string]
    lineWidths*: seq[float32]

proc measureMultilineText*(
  text: string,
  maxWidth: float32,
  atlas: FontAtlas,
  fontSize: float32,
  lineSpacing: float32 = 0.0f
): MultilineMetrics {.raises: [].} =
  ## Computes multiline bounding box, wrapped lines, line widths, and total height.
  let scale = if atlas.baseSize > 0.0f: fontSize / atlas.baseSize else: 1.0f
  result.lineHeight = if atlas.baseSize > 0.0f: atlas.lineHeight * scale else: fontSize * 1.3f
  result.lines = wrapTextToLines(text, maxWidth, atlas, fontSize)
  result.lineCount = result.lines.len
  result.lineWidths = newSeq[float32](result.lineCount)

  var maxW = 0.0f
  for i in 0 ..< result.lineCount:
    let lw = atlas.measureText(result.lines[i], fontSize).width
    result.lineWidths[i] = lw
    if lw > maxW:
      maxW = lw

  result.width = maxW
  result.height = if result.lineCount > 0:
    float32(result.lineCount) * result.lineHeight + float32(max(0, result.lineCount - 1)) * lineSpacing
  else:
    0.0f

proc measureMultilineText*(
  lines: seq[string],
  atlas: FontAtlas,
  fontSize: float32,
  lineSpacing: float32 = 0.0f
): MultilineMetrics {.raises: [].} =
  let scale = if atlas.baseSize > 0.0f: fontSize / atlas.baseSize else: 1.0f
  result.lineHeight = if atlas.baseSize > 0.0f: atlas.lineHeight * scale else: fontSize * 1.3f
  result.lines = lines
  result.lineCount = lines.len
  result.lineWidths = newSeq[float32](result.lineCount)

  var maxW = 0.0f
  for i in 0 ..< result.lineCount:
    let lw = atlas.measureText(lines[i], fontSize).width
    result.lineWidths[i] = lw
    if lw > maxW:
      maxW = lw

  result.width = maxW
  result.height = if result.lineCount > 0:
    float32(result.lineCount) * result.lineHeight + float32(max(0, result.lineCount - 1)) * lineSpacing
  else:
    0.0f

proc measurePrefixWidth*(atlas: FontAtlas, line: string, col: int, fontSize: float32): float32 {.raises: [].} =
  ## Measures width of the first `col` runes in `line` without heap allocations.
  if col <= 0 or line.len == 0:
    return 0.0f
  let scale = if atlas.baseSize > 0.0f: fontSize / atlas.baseSize else: 1.0f
  var curW = 0.0f
  var hasPrev = false
  var prevRune = Rune(0)
  var lastExtra = 0.0f
  var idx = 0
  for r in runes(line):
    if idx >= col:
      break
    inc(idx)
    if isIgnoredCodepoint(uint32(r)):
      continue
    if hasPrev:
      curW += atlas.getKerning(prevRune, r) * scale
    let g = atlas.getGlyph(r)
    lastExtra = max(0.0f, (g.bearingX + g.width - g.advance) * scale)
    curW += g.advance * scale
    prevRune = r
    hasPrev = true
  curW + lastExtra

# =============================================================================
# Linear <-> (Row, Col) Mapping
# =============================================================================

proc posToLinear*(lines: seq[string], row, col: int): int {.raises: [].} =
  var idx = 0
  let rCount = min(row, lines.len)
  for r in 0 ..< rCount:
    idx += runeLen(lines[r]) + 1 # +1 for newline character
  if row < lines.len:
    idx += clamp(col, 0, runeLen(lines[row]))
  idx

proc linearToPos*(lines: seq[string], linearIdx: int): tuple[row, col: int] {.raises: [].} =
  if lines.len == 0:
    return (0, 0)
  var rem = max(0, linearIdx)
  for r in 0 ..< lines.len:
    let rLen = runeLen(lines[r])
    if rem <= rLen:
      return (r, rem)
    rem -= (rLen + 1) # account for \n
  (lines.len - 1, runeLen(lines[^1]))

# =============================================================================
# Interactive TextArea Component / Widget
# =============================================================================

type
  TextArea* = object
    text*: string
    lines*: seq[string]
    caretRow*: int
    caretCol*: int
    selStart*: int # Linear rune index
    selEnd*: int   # Linear rune index
    isFocused*: bool
    isDragging*: bool
    bounds*: tuple[x, y, w, h: float32]
    fontSize*: float32
    lineHeight*: float32
    padding*: array[4, float32] # [top, right, bottom, left]
    scrollOffsetY*: float32
    scrollOffsetX*: float32
    bgColor*: uint32
    borderColor*: uint32
    borderFocusedColor*: uint32
    textColor*: uint32
    selectionColor*: uint32
    caretColor*: uint32
    radius*: float32
    borderWidth*: float32
    softness*: float32
    onTextChange*: proc(newText: string) {.closure, gcsafe, raises: [].}

proc initTextArea*(
  text: string = "",
  fontSize: float32 = 14.0f,
  bounds: tuple[x, y, w, h: float32] = (0.0f, 0.0f, 320.0f, 180.0f),
  padding: array[4, float32] = [8.0f, 8.0f, 8.0f, 8.0f],
  bg: uint32 = ColBgTextArea,
  borderColor: uint32 = ColBorderTextArea,
  borderFocused: uint32 = ColBorderFocused,
  textColor: uint32 = ColTextDefault,
  selectionColor: uint32 = ColSelectionDefault,
  caretColor: uint32 = ColCaretDefault,
  radius: float32 = 6.0f,
  borderWidth: float32 = 1.0f,
  onTextChange: proc(newText: string) {.closure, gcsafe, raises: [].} = nil
): TextArea {.raises: [].} =
  result.fontSize = fontSize
  result.lineHeight = fontSize * 1.3f
  result.bounds = bounds
  result.padding = padding
  result.bgColor = bg
  result.borderColor = borderColor
  result.borderFocusedColor = borderFocused
  result.textColor = textColor
  result.selectionColor = selectionColor
  result.caretColor = caretColor
  result.radius = radius
  result.borderWidth = borderWidth
  result.softness = 1.0f
  result.onTextChange = onTextChange
  result.text = text
  result.lines = splitLogicalLines(text)
  if result.lines.len == 0:
    result.lines = @[""]
  result.caretRow = 0
  result.caretCol = 0
  result.selStart = 0
  result.selEnd = 0
  result.isFocused = false
  result.isDragging = false
  result.scrollOffsetY = 0.0f
  result.scrollOffsetX = 0.0f

proc setText*(ta: var TextArea, newText: string) {.raises: [].} =
  ta.text = newText
  ta.lines = splitLogicalLines(newText)
  if ta.lines.len == 0:
    ta.lines = @[""]
  ta.caretRow = clamp(ta.caretRow, 0, ta.lines.len - 1)
  ta.caretCol = clamp(ta.caretCol, 0, runeLen(ta.lines[ta.caretRow]))
  let curLinear = posToLinear(ta.lines, ta.caretRow, ta.caretCol)
  ta.selStart = clamp(ta.selStart, 0, curLinear)
  ta.selEnd = clamp(ta.selEnd, 0, curLinear)

proc getText*(ta: TextArea): string {.inline, raises: [].} =
  ta.text

proc caretIndex*(ta: TextArea): int {.inline, raises: [].} =
  posToLinear(ta.lines, ta.caretRow, ta.caretCol)

proc setCaret*(ta: var TextArea, row, col: int, keepSelection: bool = false) {.raises: [].} =
  if ta.lines.len == 0:
    ta.lines = @[""]
  ta.caretRow = clamp(row, 0, ta.lines.len - 1)
  ta.caretCol = clamp(col, 0, runeLen(ta.lines[ta.caretRow]))
  let idx = posToLinear(ta.lines, ta.caretRow, ta.caretCol)
  if not keepSelection:
    ta.selStart = idx
    ta.selEnd = idx
  else:
    ta.selEnd = idx

proc setCaretIndex*(ta: var TextArea, index: int, keepSelection: bool = false) {.raises: [].} =
  let (r, c) = linearToPos(ta.lines, index)
  ta.setCaret(r, c, keepSelection)

proc hasSelection*(ta: TextArea): bool {.inline, raises: [].} =
  ta.selStart != ta.selEnd

proc clearSelection*(ta: var TextArea) {.inline, raises: [].} =
  let cur = ta.caretIndex()
  ta.selStart = cur
  ta.selEnd = cur

proc selectAll*(ta: var TextArea) {.raises: [].} =
  let totalRunes = runeLen(ta.text)
  ta.selStart = 0
  ta.selEnd = totalRunes
  let (r, c) = linearToPos(ta.lines, totalRunes)
  ta.caretRow = r
  ta.caretCol = c

proc setSelection*(ta: var TextArea, startIdx, endIdx: int) {.raises: [].} =
  let total = runeLen(ta.text)
  ta.selStart = clamp(startIdx, 0, total)
  ta.selEnd = clamp(endIdx, 0, total)
  let (r, c) = linearToPos(ta.lines, ta.selEnd)
  ta.caretRow = r
  ta.caretCol = c

proc getSelectedText*(ta: TextArea): string {.raises: [].} =
  if not ta.hasSelection():
    return ""
  let startIdx = min(ta.selStart, ta.selEnd)
  let endIdx = max(ta.selStart, ta.selEnd)
  let rSeq = toRunes(ta.text)
  if startIdx < rSeq.len:
    let validEnd = min(endIdx, rSeq.len)
    return $rSeq[startIdx ..< validEnd]
  ""

proc deleteSlice[T](s: var seq[T], first, last: int) {.raises: [].} =
  if first > last or first >= s.len or last < 0: return
  let f = max(0, first)
  let l = min(s.len - 1, last)
  let count = l - f + 1
  for i in f ..< (s.len - count):
    s[i] = s[i + count]
  s.setLen(s.len - count)

proc insertSeq[T](s: var seq[T], items: seq[T], index: int) {.raises: [].} =
  if items.len == 0: return
  let idx = clamp(index, 0, s.len)
  let oldLen = s.len
  s.setLen(oldLen + items.len)
  for i in countdown(oldLen - 1, idx):
    s[i + items.len] = s[i]
  for i in 0 ..< items.len:
    s[idx + i] = items[i]

proc deleteSelection*(ta: var TextArea) {.raises: [].} =
  if not ta.hasSelection():
    return
  let startIdx = min(ta.selStart, ta.selEnd)
  let endIdx = max(ta.selStart, ta.selEnd)
  var rSeq = toRunes(ta.text)
  if startIdx < rSeq.len:
    let validEnd = min(endIdx, rSeq.len)
    deleteSlice(rSeq, startIdx, validEnd - 1)
    let newStr = $rSeq
    ta.setText(newStr)
    ta.setCaretIndex(startIdx, keepSelection = false)
    if not ta.onTextChange.isNil:
      ta.onTextChange(ta.text)

proc insertText*(ta: var TextArea, str: string) {.raises: [].} =
  if ta.hasSelection():
    ta.deleteSelection()
  if str.len == 0:
    return
  let cur = ta.caretIndex()
  var rSeq = toRunes(ta.text)
  let insSeq = toRunes(str)
  let clampedCur = clamp(cur, 0, rSeq.len)
  insertSeq(rSeq, insSeq, clampedCur)
  let newStr = $rSeq
  ta.setText(newStr)
  ta.setCaretIndex(clampedCur + insSeq.len, keepSelection = false)
  if not ta.onTextChange.isNil:
    ta.onTextChange(ta.text)

proc insertChar*(ta: var TextArea, r: Rune) {.raises: [].} =
  ta.insertText(toUTF8(r))

proc deleteBackward*(ta: var TextArea) {.raises: [].} =
  if ta.hasSelection():
    ta.deleteSelection()
  else:
    let cur = ta.caretIndex()
    if cur > 0:
      var rSeq = toRunes(ta.text)
      deleteSlice(rSeq, cur - 1, cur - 1)
      let newStr = $rSeq
      ta.setText(newStr)
      ta.setCaretIndex(cur - 1, keepSelection = false)
      if not ta.onTextChange.isNil:
        ta.onTextChange(ta.text)

proc deleteForward*(ta: var TextArea) {.raises: [].} =
  if ta.hasSelection():
    ta.deleteSelection()
  else:
    let cur = ta.caretIndex()
    var rSeq = toRunes(ta.text)
    if cur < rSeq.len:
      deleteSlice(rSeq, cur, cur)
      let newStr = $rSeq
      ta.setText(newStr)
      ta.setCaretIndex(cur, keepSelection = false)
      if not ta.onTextChange.isNil:
        ta.onTextChange(ta.text)

# =============================================================================
# Navigation
# =============================================================================

proc moveLeft*(ta: var TextArea, select: bool = false) {.raises: [].} =
  let cur = ta.caretIndex()
  if cur > 0:
    ta.setCaretIndex(cur - 1, keepSelection = select)

proc moveRight*(ta: var TextArea, select: bool = false) {.raises: [].} =
  let cur = ta.caretIndex()
  let total = runeLen(ta.text)
  if cur < total:
    ta.setCaretIndex(cur + 1, keepSelection = select)

proc moveUp*(ta: var TextArea, select: bool = false) {.raises: [].} =
  if ta.caretRow > 0:
    let newRow = ta.caretRow - 1
    let targetCol = min(ta.caretCol, runeLen(ta.lines[newRow]))
    ta.setCaret(newRow, targetCol, keepSelection = select)

proc moveDown*(ta: var TextArea, select: bool = false) {.raises: [].} =
  if ta.caretRow < ta.lines.len - 1:
    let newRow = ta.caretRow + 1
    let targetCol = min(ta.caretCol, runeLen(ta.lines[newRow]))
    ta.setCaret(newRow, targetCol, keepSelection = select)

proc moveHome*(ta: var TextArea, select: bool = false) {.raises: [].} =
  ta.setCaret(ta.caretRow, 0, keepSelection = select)

proc moveEnd*(ta: var TextArea, select: bool = false) {.raises: [].} =
  ta.setCaret(ta.caretRow, runeLen(ta.lines[ta.caretRow]), keepSelection = select)

# =============================================================================
# Clipboard Actions
# =============================================================================

proc copyToClipboard*(ta: TextArea): bool {.raises: [].} =
  if ta.hasSelection():
    return setClipboardText(ta.getSelectedText())
  false

proc cutToClipboard*(ta: var TextArea): bool {.raises: [].} =
  if ta.hasSelection():
    result = setClipboardText(ta.getSelectedText())
    ta.deleteSelection()

proc pasteFromClipboard*(ta: var TextArea): bool {.raises: [].} =
  let txt = getClipboardText()
  if txt.len > 0:
    ta.insertText(txt)
    return true
  false

# =============================================================================
# Keyboard & Character Event Handling
# =============================================================================

proc isControlKeyDown(): bool {.inline, raises: [].} =
  when defined(windows):
    GetKeyState(0x11'i32) < 0
  else:
    false

proc isShiftKeyDown(): bool {.inline, raises: [].} =
  when defined(windows):
    GetKeyState(0x10'i32) < 0
  else:
    false

proc handleKeyDown*(
  ta: var TextArea,
  keyCode: uint32,
  ctrlDown: bool = false,
  shiftDown: bool = false
): bool {.discardable, raises: [].} =
  let isCtrl = ctrlDown or isControlKeyDown()
  let isShift = shiftDown or isShiftKeyDown()

  if isCtrl:
    case keyCode
    of 0x41'u32, 0x61'u32: # 'A', 'a'
      ta.selectAll()
      return true
    of 0x43'u32, 0x63'u32: # 'C', 'c'
      discard ta.copyToClipboard()
      return true
    of 0x56'u32, 0x76'u32: # 'V', 'v'
      discard ta.pasteFromClipboard()
      return true
    of 0x58'u32, 0x78'u32: # 'X', 'x'
      discard ta.cutToClipboard()
      return true
    else: discard

  case keyCode
  of 0x08'u32: # VK_BACK
    ta.deleteBackward()
    return true
  of 0x2E'u32: # VK_DELETE
    ta.deleteForward()
    return true
  of 0x0D'u32: # VK_RETURN
    ta.insertText("\n")
    return true
  of 0x25'u32: # VK_LEFT
    ta.moveLeft(select = isShift)
    return true
  of 0x27'u32: # VK_RIGHT
    ta.moveRight(select = isShift)
    return true
  of 0x26'u32: # VK_UP
    ta.moveUp(select = isShift)
    return true
  of 0x28'u32: # VK_DOWN
    ta.moveDown(select = isShift)
    return true
  of 0x24'u32: # VK_HOME
    ta.moveHome(select = isShift)
    return true
  of 0x23'u32: # VK_END
    ta.moveEnd(select = isShift)
    return true
  else:
    return false

proc handleChar*(ta: var TextArea, r: Rune): bool {.discardable, raises: [].} =
  let code = int32(r)
  if code < 32:
    case code
    of 1: # Ctrl+A
      ta.selectAll()
      return true
    of 3: # Ctrl+C
      discard ta.copyToClipboard()
      return true
    of 22: # Ctrl+V
      discard ta.pasteFromClipboard()
      return true
    of 24: # Ctrl+X
      discard ta.cutToClipboard()
      return true
    of 8: # Backspace
      ta.deleteBackward()
      return true
    of 10, 13: # Newline
      ta.insertText("\n")
      return true
    else:
      return false
  else:
    ta.insertChar(r)
    return true

# =============================================================================
# Mouse Interaction & Hit-Testing
# =============================================================================

proc hitTestPos*(ta: TextArea, px, py: float32, atlas: FontAtlas): tuple[row, col: int] {.raises: [].} =
  if ta.lines.len == 0:
    return (0, 0)
  let lh = if ta.lineHeight > 0.0f: ta.lineHeight
           elif atlas.baseSize > 0.0f: atlas.lineHeight * (ta.fontSize / atlas.baseSize)
           else: ta.fontSize * 1.3f
  let innerX = ta.bounds.x + ta.padding[3] - ta.scrollOffsetX
  let innerY = ta.bounds.y + ta.padding[0] - ta.scrollOffsetY
  let relY = py - innerY
  let row = if relY <= 0.0f: 0
            else: clamp(int(relY / lh), 0, ta.lines.len - 1)

  let line = ta.lines[row]
  let relX = px - innerX
  if relX <= 0.0f or line.len == 0:
    return (row, 0)

  let scale = if atlas.baseSize > 0.0f: ta.fontSize / atlas.baseSize else: 1.0f
  var prevX = 0.0f
  var curX = 0.0f
  var hasPrev = false
  var prevRune = Rune(0)
  var colIdx = 0
  for r in runes(line):
    if not isIgnoredCodepoint(uint32(r)):
      if hasPrev:
        curX += atlas.getKerning(prevRune, r) * scale
      let g = atlas.getGlyph(r)
      curX += g.advance * scale
      prevRune = r
      hasPrev = true
    let midX = prevX + (curX - prevX) * 0.5f
    if relX < midX:
      return (row, colIdx)
    prevX = curX
    inc(colIdx)

  (row, colIdx)

proc handleMouseDown*(ta: var TextArea, px, py: float32, atlas: FontAtlas): bool {.discardable, raises: [].} =
  if px >= ta.bounds.x and px <= ta.bounds.x + ta.bounds.w and
     py >= ta.bounds.y and py <= ta.bounds.y + ta.bounds.h:
    ta.isFocused = true
    let (row, col) = ta.hitTestPos(px, py, atlas)
    ta.setCaret(row, col, keepSelection = false)
    ta.isDragging = true
    return true
  else:
    ta.isFocused = false
    return false

proc handleMouseMove*(ta: var TextArea, px, py: float32, atlas: FontAtlas): bool {.discardable, raises: [].} =
  if ta.isDragging:
    let (row, col) = ta.hitTestPos(px, py, atlas)
    ta.setCaret(row, col, keepSelection = true)
    return true
  false

proc handleMouseUp*(ta: var TextArea, px, py: float32): bool {.discardable, raises: [].} =
  if ta.isDragging:
    ta.isDragging = false
    return true
  false

# =============================================================================
# Drawing Instance Emission & Visual Selection Highlight
# =============================================================================

proc emitDrawInstances*(
  ta: var TextArea,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas,
  clip: array[4, uint16] = [0'u16, 0'u16, 0xFFFF'u16, 0xFFFF'u16]
) {.raises: [].} =
  let (bx, by, bw, bh) = ta.bounds
  if bw <= 0.0f or bh <= 0.0f:
    return

  let effectiveClip: array[4, uint16] = [
    max(clip[0], uint16(max(0.0f, bx))),
    max(clip[1], uint16(max(0.0f, by))),
    min(clip[2], uint16(max(0.0f, bx + bw))),
    min(clip[3], uint16(max(0.0f, by + bh)))
  ]

  let lh = if ta.lineHeight > 0.0f: ta.lineHeight
           elif atlas.baseSize > 0.0f: atlas.lineHeight * (ta.fontSize / atlas.baseSize)
           else: ta.fontSize * 1.3f
  ta.lineHeight = lh

  # 1. Background & Border
  let borderCol = if ta.isFocused: ta.borderFocusedColor else: ta.borderColor
  if ta.bgColor != 0 or borderCol != 0:
    var bgInst: UiDrawInstance
    bgInst.pos = [bx, by]
    bgInst.size = [bw, bh]
    bgInst.uvPos = [0.0f, 0.0f]
    bgInst.uvSize = [0.0f, 0.0f]
    bgInst.color = ta.bgColor
    bgInst.borderColor = borderCol
    bgInst.cornerRadius = ta.radius
    bgInst.borderWidth = ta.borderWidth
    bgInst.softness = max(1.0f, ta.softness)
    bgInst.clipRect = effectiveClip
    bgInst.pad = 0'u32
    instances.add(bgInst)

  let innerX = bx + ta.padding[3] - ta.scrollOffsetX
  let innerY = by + ta.padding[0] - ta.scrollOffsetY

  let firstVisibleRow = if ta.lines.len > 0:
    clamp(int((ta.scrollOffsetY - ta.padding[0]) / lh), 0, ta.lines.len - 1)
  else: 0
  let lastVisibleRow = if ta.lines.len > 0:
    clamp(int((ta.scrollOffsetY + bh) / lh) + 1, 0, ta.lines.len - 1)
  else: -1

  # 2. Visual Selection Highlight Quad(s) (semi-transparent graphite/accent fill behind selected glyphs)
  if ta.hasSelection() and firstVisibleRow <= lastVisibleRow:
    let selMin = min(ta.selStart, ta.selEnd)
    let selMax = max(ta.selStart, ta.selEnd)

    for row in firstVisibleRow .. lastVisibleRow:
      let lineStart = posToLinear(ta.lines, row, 0)
      let lineRunesCount = runeLen(ta.lines[row])
      let lineEnd = lineStart + lineRunesCount

      if selMin < lineEnd + 1 and selMax > lineStart:
        let colStart = clamp(selMin - lineStart, 0, lineRunesCount)
        let colEnd = clamp(selMax - lineStart, 0, lineRunesCount)

        let x1 = measurePrefixWidth(atlas, ta.lines[row], colStart, ta.fontSize)
        var x2 = measurePrefixWidth(atlas, ta.lines[row], colEnd, ta.fontSize)
        if selMax > lineEnd and colEnd == lineRunesCount:
          x2 += max(6.0f, ta.fontSize * 0.4f)

        if x2 > x1:
          var selInst: UiDrawInstance
          selInst.pos = [innerX + x1, innerY + float32(row) * lh]
          selInst.size = [x2 - x1, lh]
          selInst.uvPos = [0.0f, 0.0f]
          selInst.uvSize = [0.0f, 0.0f]
          selInst.color = ta.selectionColor
          selInst.borderColor = 0'u32
          selInst.cornerRadius = 2.0f
          selInst.borderWidth = 0.0f
          selInst.softness = 1.0f
          selInst.clipRect = effectiveClip
          selInst.pad = 0'u32
          instances.add(selInst)

  # 3. Text lines rendering (virtualized to visible viewport rows)
  if firstVisibleRow <= lastVisibleRow:
    for row in firstVisibleRow .. lastVisibleRow:
      let lineStr = ta.lines[row]
      if lineStr.len > 0:
        let lineY = innerY + float32(row) * lh
        emitTextRun(instances, lineStr, innerX, lineY, ta.fontSize, ta.textColor, effectiveClip, atlas)

  # 4. Caret rendering at current position
  if ta.isFocused:
    let caretRowClamped = clamp(ta.caretRow, 0, max(0, ta.lines.len - 1))
    let caretColClamped = if ta.lines.len > 0: clamp(ta.caretCol, 0, runeLen(ta.lines[caretRowClamped])) else: 0
    let caretPrefixW = if ta.lines.len > 0: measurePrefixWidth(atlas, ta.lines[caretRowClamped], caretColClamped, ta.fontSize) else: 0.0f

    let caretX = innerX + caretPrefixW
    let caretY = innerY + float32(caretRowClamped) * lh

    if caretY + lh >= float32(effectiveClip[1]) and caretY <= float32(effectiveClip[3]):
      var caretInst: UiDrawInstance
      caretInst.pos = [caretX - 0.5f, caretY]
      caretInst.size = [1.5f, lh]
      caretInst.uvPos = [0.0f, 0.0f]
      caretInst.uvSize = [0.0f, 0.0f]
      caretInst.color = ta.caretColor
      caretInst.borderColor = 0'u32
      caretInst.cornerRadius = 0.5f
      caretInst.borderWidth = 0.0f
      caretInst.softness = 1.0f
      caretInst.clipRect = effectiveClip
      caretInst.pad = 0'u32
      instances.add(caretInst)

proc render*(
  ta: var TextArea,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas,
  clip: array[4, uint16] = [0'u16, 0'u16, 0xFFFF'u16, 0xFFFF'u16]
) {.inline, raises: [].} =
  emitDrawInstances(ta, instances, atlas, clip)

# =============================================================================
# Declarative DSL Component Constructor
# =============================================================================

type
  TextAreaState* = TextArea
  TextAreaWidget* = TextArea

proc TextAreaNode*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  text: string = "",
  size: float32 = 14.0f,
  width: SizeMode = fixed(320.0f),
  height: SizeMode = fixed(180.0f),
  bg: uint32 = ColBgTextArea,
  borderColor: uint32 = ColBorderTextArea,
  radius: float32 = 6.0f,
  borderWidth: float32 = 1.0f,
  color: uint32 = ColTextDefault,
  onInput: proc(s: string) {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let id = tree.createNode(nkBox)
  template n: untyped = tree.nodes[id]
  n.text = text
  n.fontSize = size
  n.widthMode = width
  n.heightMode = height
  n.bgColor = bg
  n.borderColor = borderColor
  n.radius = radius
  n.borderWidth = borderWidth
  n.textColor = color
  n.padding = [8.0f, 8.0f, 8.0f, 8.0f]
  n.onInput = onInput
  if parent != SlabId(-1):
    tree.addChild(parent, id)
  id

proc syncWithNode*(ta: var TextArea, tree: UiTree, nodeId: SlabId, atlas: FontAtlas) {.raises: [].} =
  ## Automatically syncs TextArea bounds, focus state, and line height from a UiTree layout node.
  if not tree.nodes.contains(nodeId):
    return
  template n: untyped = tree.nodes[nodeId]
  ta.bounds = (
    x: n.computedRect.x + n.padding[3],
    y: n.computedRect.y + n.padding[0],
    w: max(32.0f, n.computedRect.w - n.padding[3] - n.padding[1]),
    h: max(24.0f, n.computedRect.h - n.padding[0] - n.padding[2])
  )
  ta.isFocused = n.isFocused
  if atlas.baseSize > 0.0f:
    ta.lineHeight = atlas.lineHeight * (ta.fontSize / atlas.baseSize)
