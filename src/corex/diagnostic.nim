## corex/diagnostic — Rustc/Clang-Style Rich Diagnostic Renderer
##
## Provides pinpoint source code error reporting with line/column binary search,
## multiline visual underlines, child notes/helps, ANSI terminal colorization,
## and Windows Console API support.

import std/[strutils, terminal]
import ./allocators
import ./result
import ./memory

type
  Severity* = enum
    sevError
    sevWarning
    sevNote
    sevHelp

  SourceFile* = object
    content*: Span[byte]        # Borrowed buffer (caller keeps alive)
    lineOffsets*: seq[int]      # Byte offsets of the start of each line
    alloc*: Allocator

  SourceSpan* = object
    start*: int                 # Byte offset
    `end`*: int                 # Byte offset (exclusive)

  Diagnostic* = object
    severity*: Severity
    message*: string
    file*: string               # Path for display
    span*: SourceSpan
    children*: seq[Diagnostic]  # Notes, help

proc span*(startOffset, endOffset: int): SourceSpan {.inline, raises: [].} =
  SourceSpan(start: max(0, startOffset), `end`: max(startOffset, endOffset))

# =============================================================================
# SourceFile Creation & Indexing
# =============================================================================

proc newSourceFile*(content: Span[byte], alloc: Allocator = Allocator()): Result[SourceFile, AllocError] {.raises: [].} =
  var offsets: seq[int] = @[0]
  if content.len > 0 and not content.rawData.isNil:
    for i in 0 ..< content.len:
      if content[i] == 0x0A'u8: # '\n'
        if i + 1 < content.len:
          offsets.add(i + 1)
  ok[SourceFile, AllocError](SourceFile(
    content: content,
    lineOffsets: offsets,
    alloc: alloc
  ))

proc lineCol*(sf: SourceFile, offset: int): tuple[line, col: int] {.raises: [].} =
  ## Binary search on lineOffsets. Returns 1-based (line, col).
  if sf.lineOffsets.len == 0:
    return (1, 1)

  let clampedOffset = max(0, min(offset, sf.content.len))
  var low = 0
  var high = sf.lineOffsets.len - 1
  var lineIdx = 0

  while low <= high:
    let mid = (low + high) div 2
    if sf.lineOffsets[mid] <= clampedOffset:
      lineIdx = mid
      low = mid + 1
    else:
      high = mid - 1

  let lineStart = sf.lineOffsets[lineIdx]
  let col = (clampedOffset - lineStart) + 1
  (lineIdx + 1, col)

# =============================================================================
# Line Extraction & Formatting
# =============================================================================

proc getLineContent(sf: SourceFile, lineIdx: int): string {.raises: [].} =
  if lineIdx < 0 or lineIdx >= sf.lineOffsets.len:
    return ""
  let startOffset = sf.lineOffsets[lineIdx]
  let endOffset = if lineIdx + 1 < sf.lineOffsets.len:
    sf.lineOffsets[lineIdx + 1]
  else:
    sf.content.len

  if startOffset >= sf.content.len:
    return ""

  var rawLen = endOffset - startOffset
  # Strip trailing '\n' and '\r'
  while rawLen > 0 and (sf.content[startOffset + rawLen - 1] == 0x0A'u8 or sf.content[startOffset + rawLen - 1] == 0x0D'u8):
    dec(rawLen)

  if rawLen <= 0:
    return ""

  result = newString(rawLen)
  copyMem(addr result[0], addr sf.content[startOffset], rawLen)

proc severityLabel(s: Severity): string {.inline, raises: [].} =
  case s
  of sevError: "error"
  of sevWarning: "warning"
  of sevNote: "note"
  of sevHelp: "help"

# =============================================================================
# Plain Text Renderer
# =============================================================================

proc render*(d: Diagnostic, sf: SourceFile): string {.raises: [].} =
  var res = ""
  let (startLine, startCol) = sf.lineCol(d.span.start)
  let (endLine, endCol) = sf.lineCol(d.span.`end`)

  # Header: e.g. "error: <message>"
  res.add(severityLabel(d.severity) & ": " & d.message & "\n")

  # Location: e.g. " --> file:42:5"
  let fileStr = if d.file.len > 0: d.file else: "<input>"
  let gutterWidth = max(2, len($endLine))
  let indent = spaces(gutterWidth)

  res.add(indent & "--> " & fileStr & ":" & $startLine & ":" & $startCol & "\n")
  res.add(indent & " |\n")

  if startLine == endLine:
    let lineIdx = startLine - 1
    let lineText = sf.getLineContent(lineIdx)
    let lineNumStr = align($startLine, gutterWidth)
    res.add(lineNumStr & " | " & lineText & "\n")

    let lineStartOffset = sf.lineOffsets[lineIdx]
    let colInLine = max(0, d.span.start - lineStartOffset)
    let spanLen = max(1, d.span.`end` - d.span.start)
    res.add(indent & " | " & spaces(colInLine) & repeat('^', spanLen) & "\n")
  else:
    # Multi-line span
    for l in startLine .. endLine:
      let lineIdx = l - 1
      let lineText = sf.getLineContent(lineIdx)
      let lineNumStr = align($l, gutterWidth)
      res.add(lineNumStr & " | " & lineText & "\n")

      let lineStartOffset = sf.lineOffsets[lineIdx]
      if l == startLine:
        let colInLine = max(0, d.span.start - lineStartOffset)
        let underlineLen = max(1, lineText.len - colInLine)
        res.add(indent & " | " & spaces(colInLine) & repeat('^', underlineLen) & "\n")
      elif l == endLine:
        let colInLine = max(1, d.span.`end` - lineStartOffset)
        res.add(indent & " | " & repeat('^', colInLine) & "\n")
      else:
        let underlineLen = max(1, lineText.len)
        res.add(indent & " | " & repeat('^', underlineLen) & "\n")

  # Child diagnostics
  for child in d.children:
    res.add(indent & " = " & severityLabel(child.severity) & ": " & child.message & "\n")

  res

# =============================================================================
# Colored Renderer (ANSI / Windows Terminal)
# =============================================================================

proc renderColored*(d: Diagnostic, sf: SourceFile): string {.raises: [].} =
  # If not a terminal, fallback to plain text
  var isTty = false
  try:
    isTty = terminal.isatty(stdout)
  except CatchableError:
    isTty = false

  if not isTty:
    return render(d, sf)

  # ANSI color codes
  const
    Reset = "\e[0m"
    Bold = "\e[1m"
    BoldRed = "\e[1;31m"
    BoldYellow = "\e[1;33m"
    BoldCyan = "\e[1;36m"
    BoldGreen = "\e[1;32m"
    BoldBlue = "\e[1;34m"

  let (sevColor, caretColor) = case d.severity
    of sevError: (BoldRed, BoldRed)
    of sevWarning: (BoldYellow, BoldYellow)
    of sevNote: (BoldCyan, BoldCyan)
    of sevHelp: (BoldGreen, BoldGreen)

  var res = ""
  let (startLine, startCol) = sf.lineCol(d.span.start)
  let (endLine, _) = sf.lineCol(d.span.`end`)

  # Header
  res.add(sevColor & severityLabel(d.severity) & ": " & Bold & d.message & Reset & "\n")

  let fileStr = if d.file.len > 0: d.file else: "<input>"
  let gutterWidth = max(2, len($endLine))
  let indent = spaces(gutterWidth)

  res.add(BoldBlue & indent & "--> " & Reset & fileStr & ":" & $startLine & ":" & $startCol & "\n")
  res.add(BoldBlue & indent & " |\n" & Reset)

  if startLine == endLine:
    let lineIdx = startLine - 1
    let lineText = sf.getLineContent(lineIdx)
    let lineNumStr = align($startLine, gutterWidth)
    res.add(BoldBlue & lineNumStr & " | " & Reset & lineText & "\n")

    let lineStartOffset = sf.lineOffsets[lineIdx]
    let colInLine = max(0, d.span.start - lineStartOffset)
    let spanLen = max(1, d.span.`end` - d.span.start)
    res.add(BoldBlue & indent & " | " & Reset & spaces(colInLine) & caretColor & repeat('^', spanLen) & Reset & "\n")
  else:
    for l in startLine .. endLine:
      let lineIdx = l - 1
      let lineText = sf.getLineContent(lineIdx)
      let lineNumStr = align($l, gutterWidth)
      res.add(BoldBlue & lineNumStr & " | " & Reset & lineText & "\n")

      let lineStartOffset = sf.lineOffsets[lineIdx]
      if l == startLine:
        let colInLine = max(0, d.span.start - lineStartOffset)
        let underlineLen = max(1, lineText.len - colInLine)
        res.add(BoldBlue & indent & " | " & Reset & spaces(colInLine) & caretColor & repeat('^', underlineLen) & Reset & "\n")
      elif l == endLine:
        let colInLine = max(1, d.span.`end` - lineStartOffset)
        res.add(BoldBlue & indent & " | " & Reset & caretColor & repeat('^', colInLine) & Reset & "\n")
      else:
        let underlineLen = max(1, lineText.len)
        res.add(BoldBlue & indent & " | " & Reset & caretColor & repeat('^', underlineLen) & Reset & "\n")

  for child in d.children:
    let childColor = case child.severity
      of sevError: BoldRed
      of sevWarning: BoldYellow
      of sevNote: BoldCyan
      of sevHelp: BoldGreen
    res.add(BoldBlue & indent & " = " & childColor & severityLabel(child.severity) & ": " & Reset & child.message & "\n")

  res
