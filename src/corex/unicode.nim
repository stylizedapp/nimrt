## corex/unicode — High-Performance Unicode & UTF-8 Primitives
##
## Features:
## - Zero-allocation branchless / SWAR UTF-8 validation (RFC 3629 compliant)
##   with 8-byte fast path, strict rejection of surrogates (0xD800..0xDFFF),
##   overlong encodings, and values > 0x10FFFF.
## - Fast Rune decoding and encoding (decodeRune, encodeRune).
## - UAX #29 Grapheme Cluster Segmentation handling ZWJ emoji sequences
##   (e.g. 👨‍👩‍👧‍👦), regional indicator flag pairs, and combining diacritics.
## - Display width calculation (East Asian wide / emoji = 2, standard = 1,
##   zero-width marks = 0).

# =============================================================================
# 1. Zero-Allocation Branchless / SWAR UTF-8 Validation (RFC 3629)
# =============================================================================

func validateUtf8*(s: openArray[char]): bool {.raises: [].} =
  ## Validates whether `s` is well-formed UTF-8 according to RFC 3629.
  ## Uses an 8-byte SWAR fast path for ASCII text and strictly rejects:
  ## - Overlong byte sequences
  ## - UTF-16 surrogates (U+D800..U+DFFF)
  ## - Code points above U+10FFFF
  ## - Truncated, malformed, or obsolete multi-byte sequences
  var i = 0
  let n = s.len

  # 8-byte SWAR fast-path for ASCII chunks
  while i + 8 <= n:
    var w: uint64
    copyMem(addr w, unsafeAddr s[i], 8)
    if (w and 0x8080808080808080'u64) == 0:
      i += 8
    else:
      break

  while i < n:
    let b0 = uint8(s[i])
    if b0 < 0x80'u8:
      inc i
      # Check if we can resume 8-byte SWAR jumps
      while i + 8 <= n:
        var w: uint64
        copyMem(addr w, unsafeAddr s[i], 8)
        if (w and 0x8080808080808080'u64) == 0:
          i += 8
        else:
          break
    elif b0 in 0xC2'u8 .. 0xDF'u8:
      if i + 1 >= n: return false
      let b1 = uint8(s[i + 1])
      if (b1 and 0xC0'u8) != 0x80'u8: return false
      i += 2
    elif b0 == 0xE0'u8:
      if i + 2 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      if b1 notin 0xA0'u8 .. 0xBF'u8: return false
      if (b2 and 0xC0'u8) != 0x80'u8: return false
      i += 3
    elif (b0 in 0xE1'u8 .. 0xEC'u8) or (b0 in 0xEE'u8 .. 0xEF'u8):
      if i + 2 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      if (b1 and 0xC0'u8) != 0x80'u8 or (b2 and 0xC0'u8) != 0x80'u8: return false
      i += 3
    elif b0 == 0xED'u8:
      if i + 2 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      # Exclude UTF-16 surrogates: U+D800..U+DFFF -> 0xED 0xA0..0xBF
      if b1 notin 0x80'u8 .. 0x9F'u8: return false
      if (b2 and 0xC0'u8) != 0x80'u8: return false
      i += 3
    elif b0 == 0xF0'u8:
      if i + 3 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      let b3 = uint8(s[i + 3])
      if b1 notin 0x90'u8 .. 0xBF'u8: return false
      if (b2 and 0xC0'u8) != 0x80'u8 or (b3 and 0xC0'u8) != 0x80'u8: return false
      i += 4
    elif b0 in 0xF1'u8 .. 0xF3'u8:
      if i + 3 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      let b3 = uint8(s[i + 3])
      if (b1 and 0xC0'u8) != 0x80'u8 or (b2 and 0xC0'u8) != 0x80'u8 or (b3 and 0xC0'u8) != 0x80'u8: return false
      i += 4
    elif b0 == 0xF4'u8:
      if i + 3 >= n: return false
      let b1 = uint8(s[i + 1])
      let b2 = uint8(s[i + 2])
      let b3 = uint8(s[i + 3])
      # Maximum valid Unicode code point is U+10FFFF -> 0xF4 0x8F 0xBF 0xBF
      if b1 notin 0x80'u8 .. 0x8F'u8: return false
      if (b2 and 0xC0'u8) != 0x80'u8 or (b3 and 0xC0'u8) != 0x80'u8: return false
      i += 4
    else:
      return false

  return true

# =============================================================================
# 2. Fast Rune Decoding & Encoding
# =============================================================================

func decodeRune*(s: openArray[char], pos: int): tuple[rune: uint32, len: int] {.inline, raises: [].} =
  ## Decodes a single Unicode code point from `s` starting at index `pos`.
  ## Returns the decoded `rune` and byte `len`.
  ## If the sequence is malformed or out-of-bounds, returns (0xFFFD, 1).
  if pos < 0 or pos >= s.len:
    return (0'u32, 0)

  let b0 = uint8(s[pos])
  if b0 < 0x80'u8:
    return (uint32(b0), 1)
  elif b0 in 0xC2'u8 .. 0xDF'u8:
    if pos + 1 < s.len:
      let b1 = uint8(s[pos + 1])
      if (b1 and 0xC0'u8) == 0x80'u8:
        let r = (uint32(b0 and 0x1F'u8) shl 6) or uint32(b1 and 0x3F'u8)
        return (r, 2)
    return (0xFFFD'u32, 1)
  elif b0 in 0xE0'u8 .. 0xEF'u8:
    if pos + 2 < s.len:
      let b1 = uint8(s[pos + 1])
      let b2 = uint8(s[pos + 2])
      if (b1 and 0xC0'u8) == 0x80'u8 and (b2 and 0xC0'u8) == 0x80'u8:
        if (b0 == 0xE0'u8 and b1 < 0xA0'u8) or (b0 == 0xED'u8 and b1 >= 0xA0'u8):
          return (0xFFFD'u32, 1)
        let r = (uint32(b0 and 0x0F'u8) shl 12) or
                (uint32(b1 and 0x3F'u8) shl 6) or
                uint32(b2 and 0x3F'u8)
        return (r, 3)
    return (0xFFFD'u32, 1)
  elif b0 in 0xF0'u8 .. 0xF4'u8:
    if pos + 3 < s.len:
      let b1 = uint8(s[pos + 1])
      let b2 = uint8(s[pos + 2])
      let b3 = uint8(s[pos + 3])
      if (b1 and 0xC0'u8) == 0x80'u8 and (b2 and 0xC0'u8) == 0x80'u8 and (b3 and 0xC0'u8) == 0x80'u8:
        if (b0 == 0xF0'u8 and b1 < 0x90'u8) or (b0 == 0xF4'u8 and b1 > 0x8F'u8):
          return (0xFFFD'u32, 1)
        let r = (uint32(b0 and 0x07'u8) shl 18) or
                (uint32(b1 and 0x3F'u8) shl 12) or
                (uint32(b2 and 0x3F'u8) shl 6) or
                uint32(b3 and 0x3F'u8)
        return (r, 4)
    return (0xFFFD'u32, 1)
  else:
    return (0xFFFD'u32, 1)

func encodeRune*(rune: uint32): string {.raises: [].} =
  ## Encodes `rune` as a UTF-8 string (1 to 4 bytes).
  ## If `rune` is in the surrogate range (0xD800..0xDFFF) or > 0x10FFFF,
  ## encodes U+FFFD (replacement character).
  if rune <= 0x7F'u32:
    result = newString(1)
    result[0] = char(rune)
  elif rune <= 0x7FF'u32:
    result = newString(2)
    result[0] = char(0xC0'u32 or (rune shr 6))
    result[1] = char(0x80'u32 or (rune and 0x3F'u32))
  elif rune <= 0xFFFF'u32:
    if rune in 0xD800'u32 .. 0xDFFF'u32:
      return "\xEF\xBF\xBD"
    result = newString(3)
    result[0] = char(0xE0'u32 or (rune shr 12))
    result[1] = char(0x80'u32 or ((rune shr 6) and 0x3F'u32))
    result[2] = char(0x80'u32 or (rune and 0x3F'u32))
  elif rune <= 0x10FFFF'u32:
    result = newString(4)
    result[0] = char(0xF0'u32 or (rune shr 18))
    result[1] = char(0x80'u32 or ((rune shr 12) and 0x3F'u32))
    result[2] = char(0x80'u32 or ((rune shr 6) and 0x3F'u32))
    result[3] = char(0x80'u32 or (rune and 0x3F'u32))
  else:
    return "\xEF\xBF\xBD"

# =============================================================================
# 3. Grapheme Cluster Segmentation (UAX #29)
# =============================================================================

type
  GraphemeCategory = enum
    gcOther,
    gcCR,
    gcLF,
    gcControl,
    gcExtend,
    gcZWJ,
    gcRegionalIndicator,
    gcExtendedPictographic,
    gcL,
    gcV,
    gcT,
    gcLV,
    gcLVT

func graphemeCategory(r: uint32): GraphemeCategory {.inline, raises: [].} =
  if r == 0x000D'u32: return gcCR
  if r == 0x000A'u32: return gcLF
  if (r <= 0x001F'u32) or (r in 0x007F'u32 .. 0x009F'u32): return gcControl
  if r == 0x200D'u32: return gcZWJ
  if r in 0x1F1E6'u32 .. 0x1F1FF'u32: return gcRegionalIndicator

  # Combining marks / Extend
  if (r in 0x0300'u32 .. 0x036F'u32) or # Combining Diacritical Marks
     (r in 0x1AB0'u32 .. 0x1AFF'u32) or # Combining Diacritical Marks Extended
     (r in 0x1DC0'u32 .. 0x1DFF'u32) or # Combining Diacritical Marks Supplement
     (r in 0x20D0'u32 .. 0x20FF'u32) or # Combining Marks for Symbols
     (r in 0xFE00'u32 .. 0xFE0F'u32) or # Variation Selectors (e.g. VS16 0xFE0F)
     (r in 0xE0100'u32 .. 0xE01EF'u32) or # Variation Selectors Supplement
     (r in 0x1F3FB'u32 .. 0x1F3FF'u32) or # Emoji Modifiers (Fitzpatrick skin tones)
     (r in 0xE0020'u32 .. 0xE007F'u32) or # Tags
     (r == 0x200C'u32) or                 # ZWNJ
     (r in 0x0483'u32 .. 0x0489'u32) or   # Cyrillic combining
     (r in 0x0591'u32 .. 0x05BD'u32) or r == 0x05BF'u32 or (r in 0x05C1'u32 .. 0x05C2'u32) or (r in 0x05C4'u32 .. 0x05C5'u32) or r == 0x05C7'u32 or # Hebrew
     (r in 0x0610'u32 .. 0x061A'u32) or (r in 0x064B'u32 .. 0x065F'u32) or r == 0x0670'u32 or (r in 0x06D6'u32 .. 0x06DC'u32) or (r in 0x06DF'u32 .. 0x06E4'u32) or (r in 0x06E7'u32 .. 0x06E8'u32) or (r in 0x06EA'u32 .. 0x06ED'u32) or # Arabic
     (r in 0x0900'u32 .. 0x0903'u32) or (r in 0x093A'u32 .. 0x094D'u32) or (r in 0x0951'u32 .. 0x0957'u32) or (r in 0x0962'u32 .. 0x0963'u32): # Devanagari
    return gcExtend

  # Extended Pictographic (Emoji)
  if (r in 0x1F300'u32 .. 0x1F5FF'u32) or # Misc Symbols and Pictographs (e.g. 🏳, 🌈, 👍)
     (r in 0x1F600'u32 .. 0x1F64F'u32) or # Emoticons (😀, etc.)
     (r in 0x1F680'u32 .. 0x1F6FF'u32) or # Transport and Map (🚀, etc.)
     (r in 0x1F900'u32 .. 0x1F9FF'u32) or # Supplemental Symbols and Pictographs
     (r in 0x1FA70'u32 .. 0x1FAFF'u32) or # Symbols and Pictographs Extended-A
     (r in 0x2600'u32 .. 0x26FF'u32) or   # Misc Symbols (⚡, ☕, ⚠, etc.)
     (r in 0x2700'u32 .. 0x27BF'u32) or   # Dingbats (🎉 is 1F389, ✂, etc.)
     (r in 0x2300'u32 .. 0x23FF'u32) or
     (r in [0x203C'u32, 0x2049'u32, 0x2122'u32, 0x2139'u32, 0x2B50'u32, 0x3030'u32, 0x303D'u32, 0x3297'u32, 0x3299'u32]):
    return gcExtendedPictographic

  # Hangul
  if (r in 0x1100'u32 .. 0x115F'u32) or (r in 0xA960'u32 .. 0xA97C'u32): return gcL
  if (r in 0x1160'u32 .. 0x11A7'u32) or (r in 0xD7B0'u32 .. 0xD7C6'u32): return gcV
  if (r in 0x11A8'u32 .. 0x11FF'u32) or (r in 0xD7CB'u32 .. 0xD7FB'u32): return gcT
  if r in 0xAC00'u32 .. 0xD7A3'u32:
    if (r - 0xAC00'u32) mod 28'u32 == 0:
      return gcLV
    else:
      return gcLVT

  return gcOther

iterator graphemes*(s: string): tuple[slice: Slice[int], text: string] {.raises: [].} =
  ## Iterates over extended grapheme clusters in `s` according to Unicode UAX #29.
  ## Handles:
  ## - Combining diacritical marks (e.g. 'e' + '\u0301' -> "é")
  ## - ZWJ emoji sequences (e.g. 👨‍👩‍👧‍👦, 🏳️‍🌈)
  ## - Emoji modifiers & skin tone pairs (e.g. 👍🏽)
  ## - Regional Indicator flag pairs (e.g. 🇺🇸)
  ## - Hangul syllable sequences
  if s.len > 0:
    var startPos = 0
    var (prevRune, prevLen) = decodeRune(s, 0)
    var prevCat = graphemeCategory(prevRune)
    var currPos = prevLen

    # Cluster state
    var hasExtPic = (prevCat == gcExtendedPictographic)
    var afterZwj = false
    var riCount = if prevCat == gcRegionalIndicator: 1 else: 0

    while currPos < s.len:
      let (currRune, currLen) = decodeRune(s, currPos)
      let currCat = graphemeCategory(currRune)

      var breakBoundary = false

      # GB3: CR x LF
      if prevCat == gcCR and currCat == gcLF:
        breakBoundary = false
      # GB4: (Control | CR | LF) ÷
      elif prevCat in {gcCR, gcLF, gcControl}:
        breakBoundary = true
      # GB5: ÷ (Control | CR | LF)
      elif currCat in {gcCR, gcLF, gcControl}:
        breakBoundary = true
      # GB6: L x (L | V | LV | LVT)
      elif prevCat == gcL and currCat in {gcL, gcV, gcLV, gcLVT}:
        breakBoundary = false
      # GB7: (LV | V) x (V | T)
      elif prevCat in {gcLV, gcV} and currCat in {gcV, gcT}:
        breakBoundary = false
      # GB8: (LVT | T) x T
      elif prevCat in {gcLVT, gcT} and currCat == gcT:
        breakBoundary = false
      # GB9: x (Extend | ZWJ)
      elif currCat in {gcExtend, gcZWJ}:
        breakBoundary = false
      # GB11: \p{Extended_Pictographic} Extend* ZWJ x \p{Extended_Pictographic}
      elif afterZwj and currCat == gcExtendedPictographic:
        breakBoundary = false
      # GB12 / GB13: Regional Indicator pairs: (RI RI)* RI x RI
      elif currCat == gcRegionalIndicator and prevCat == gcRegionalIndicator:
        if (riCount mod 2) == 1:
          breakBoundary = false
        else:
          breakBoundary = true
      else:
        breakBoundary = true

      if breakBoundary:
        let slice = startPos .. (currPos - 1)
        yield (slice: slice, text: s[startPos ..< currPos])
        startPos = currPos
        hasExtPic = (currCat == gcExtendedPictographic)
        afterZwj = false
        riCount = if currCat == gcRegionalIndicator: 1 else: 0
      else:
        if currCat == gcExtendedPictographic:
          hasExtPic = true
        if currCat == gcZWJ and hasExtPic:
          afterZwj = true
        elif currCat != gcExtend and currCat != gcZWJ:
          afterZwj = false
        if currCat == gcRegionalIndicator:
          inc riCount

      prevRune = currRune
      prevLen = currLen
      prevCat = currCat
      currPos += currLen

    # Yield trailing grapheme cluster
    if startPos < s.len:
      let slice = startPos .. (s.len - 1)
      yield (slice: slice, text: s[startPos ..< s.len])

# =============================================================================
# 4. Display Width Calculation
# =============================================================================

func runeWidth*(r: uint32): int {.inline, raises: [].} =
  ## Returns the terminal display width of a single rune:
  ## - 0 for control chars, ZWJ, combining marks, variation selectors
  ## - 2 for wide East Asian characters, Emojis, Regional Indicators
  ## - 1 for standard characters
  # Zero-width
  if (r <= 0x001F'u32) or (r in 0x007F'u32 .. 0x009F'u32) or
     (r == 0x00AD'u32) or (r in 0x200B'u32 .. 0x200F'u32) or
     (r in 0x2028'u32 .. 0x202E'u32) or (r in 0x2060'u32 .. 0x206F'u32) or
     (r in 0xFE00'u32 .. 0xFE0F'u32) or (r == 0xFEFF'u32) or
     (r in 0xE0100'u32 .. 0xE01EF'u32) or (r in 0x1F3FB'u32 .. 0x1F3FF'u32) or
     (r in 0x0300'u32 .. 0x036F'u32) or (r in 0x1AB0'u32 .. 0x1AFF'u32) or
     (r in 0x1DC0'u32 .. 0x1DFF'u32) or (r in 0x20D0'u32 .. 0x20FF'u32) or
     (r in 0x0483'u32 .. 0x0489'u32) or (r in 0x0591'u32 .. 0x05BD'u32) or
     (r == 0x05BF'u32) or (r in 0x05C1'u32 .. 0x05C2'u32) or
     (r in 0x05C4'u32 .. 0x05C5'u32) or (r == 0x05C7'u32) or
     (r in 0x0610'u32 .. 0x061A'u32) or (r in 0x064B'u32 .. 0x065F'u32) or
     (r == 0x0670'u32) or (r in 0x06D6'u32 .. 0x06DC'u32) or
     (r in 0x06DF'u32 .. 0x06E4'u32) or (r in 0x06E7'u32 .. 0x06E8'u32) or
     (r in 0x06EA'u32 .. 0x06ED'u32) or (r in 0x0900'u32 .. 0x0903'u32) or
     (r in 0x093A'u32 .. 0x094D'u32) or (r in 0x0951'u32 .. 0x0957'u32) or
     (r in 0x0962'u32 .. 0x0963'u32):
    return 0

  # Wide East Asian / Emoji / Regional Indicator
  if (r in 0x1100'u32 .. 0x11FF'u32) or (r in 0x2E80'u32 .. 0x303E'u32) or
     (r in 0x3040'u32 .. 0x309F'u32) or (r in 0x30A0'u32 .. 0x30FF'u32) or
     (r in 0x3100'u32 .. 0x312F'u32) or (r in 0x3130'u32 .. 0x318F'u32) or
     (r in 0x3190'u32 .. 0x31E3'u32) or (r in 0x3200'u32 .. 0x32FF'u32) or
     (r in 0x3300'u32 .. 0x33FF'u32) or (r in 0x3400'u32 .. 0x4DBF'u32) or
     (r in 0x4E00'u32 .. 0x9FFF'u32) or (r in 0xAC00'u32 .. 0xD7A3'u32) or
     (r in 0xF900'u32 .. 0xFAFF'u32) or (r in 0xFE10'u32 .. 0xFE19'u32) or
     (r in 0xFE30'u32 .. 0xFE6F'u32) or (r in 0xFF01'u32 .. 0xFF60'u32) or
     (r in 0xFFE0'u32 .. 0xFFE6'u32) or (r in 0x20000'u32 .. 0x2FFFD'u32) or
     (r in 0x30000'u32 .. 0x3FFFD'u32) or (r in 0x1F1E6'u32 .. 0x1F1FF'u32) or
     (r in 0x1F300'u32 .. 0x1FAFF'u32) or (r in 0x2600'u32 .. 0x27BF'u32) or
     (r in 0x2300'u32 .. 0x23FF'u32):
    return 2

  return 1

func clusterWidth(gText: string): int {.inline, raises: [].} =
  var maxW = 0
  var pos = 0
  while pos < gText.len:
    let (r, length) = decodeRune(gText, pos)
    if length <= 0: break
    let w = runeWidth(r)
    if w > maxW:
      maxW = w
    pos += length
  maxW

proc displayWidth*(s: string): int {.raises: [].} =
  ## Calculates the visual monospace terminal display width of `s`.
  ## Wide East Asian characters and Emojis count as 2 columns,
  ## standard characters as 1 column, and zero-width marks/joiners as 0.
  # Fast-path for pure printable ASCII
  var allAsciiPrintable = true
  for i in 0 ..< s.len:
    let c = ord(s[i])
    if c < 0x20 or c > 0x7E:
      allAsciiPrintable = false
      break
  if allAsciiPrintable:
    return s.len

  var total = 0
  for g in graphemes(s):
    total += clusterWidth(g.text)
  total
