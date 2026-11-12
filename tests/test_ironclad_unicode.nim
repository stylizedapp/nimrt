## tests/test_ironclad_unicode.nim
## Independent adversarial verification suite for RFC 3629 UTF-8 validation,
## Rune decode/encode, UAX #29 Grapheme Cluster Segmentation, and Display Width.

import std/[strformat, sequtils]
import corex/unicode

# =============================================================================
# 1. RFC 3629 UTF-8 Validation & Adversarial Rejection
# =============================================================================

proc testUtf8Validation() =
  echo "[test_ironclad_unicode] Testing UTF-8 validation against RFC 3629..."

  # --- A. Valid UTF-8 sequences ---
  # Empty string
  doAssert validateUtf8("") == true

  # 1-byte ASCII (including full 8-byte and >64-byte SWAR blocks)
  doAssert validateUtf8("a") == true
  doAssert validateUtf8("The quick brown fox jumps over the lazy dog.") == true
  doAssert validateUtf8("1234567812345678123456781234567812345678123456781234567812345678") == true

  # 2-byte sequences (Latin, Cyrillic, Greek, Hebrew, Arabic)
  doAssert validateUtf8("Привет, мир!") == true
  doAssert validateUtf8("Καλημέρα κόσμε") == true
  doAssert validateUtf8("café résumé naïve") == true

  # 3-byte sequences (CJK, Devanagari, Symbols)
  doAssert validateUtf8("日本語テスト") == true
  doAssert validateUtf8("中文测试数据") == true
  doAssert validateUtf8("한국어 텍스트") == true
  doAssert validateUtf8("₹ 1000 — Currency symbol") == true

  # 4-byte sequences (Emoji, Supplementary Ideographs)
  doAssert validateUtf8("😀🚀🦀🎉💡🔥") == true
  doAssert validateUtf8("𠀀 𪚥 🀄") == true

  # Mixed text
  doAssert validateUtf8("Nim 2.0: Быстрый, безопасный и выразительный! 🚀 (Unicode 日本語)") == true

  # --- B. Adversarial Rejection: Overlong Encodings (RFC 3629 Section 3) ---
  # Overlong encodings MUST return false

  # 2-byte overlongs
  doAssert validateUtf8("\xC0\x80") == false            # NUL overlong (2 bytes)
  doAssert validateUtf8("\xC0\xAF") == false            # '/' (0x2F) overlong (2 bytes)
  doAssert validateUtf8("\xC1\xBF") == false            # 0x7F overlong (2 bytes)
  doAssert validateUtf8("prefix\xC0\x80suffix") == false

  # 3-byte overlongs
  doAssert validateUtf8("\xE0\x80\x80") == false        # NUL overlong (3 bytes)
  doAssert validateUtf8("\xE0\x9F\xBF") == false        # 0x07FF overlong (3 bytes)
  doAssert validateUtf8("abc\xE0\x82\x80def") == false

  # 4-byte overlongs
  doAssert validateUtf8("\xF0\x80\x80\x80") == false    # NUL overlong (4 bytes)
  doAssert validateUtf8("\xF0\x8F\xBF\xBF") == false    # 0xFFFF overlong (4 bytes)

  # --- C. Adversarial Rejection: UTF-16 Surrogates (U+D800..U+DFFF) ---
  # Surrogates are strictly prohibited in UTF-8
  doAssert validateUtf8("\xED\xA0\x80") == false        # U+D800 (start of high surrogates)
  doAssert validateUtf8("\xED\xAD\xBF") == false        # U+DB7F
  doAssert validateUtf8("\xED\xAE\x80") == false        # U+DB80
  doAssert validateUtf8("\xED\xAF\xBF") == false        # U+DBFF (end of high surrogates)
  doAssert validateUtf8("\xED\xB0\x80") == false        # U+DC00 (start of low surrogates)
  doAssert validateUtf8("\xED\xBF\xBF") == false        # U+DFFF (end of low surrogates)
  doAssert validateUtf8("test\xED\xA0\x80test") == false

  # --- D. Adversarial Rejection: Out of Range (> U+10FFFF) ---
  doAssert validateUtf8("\xF4\x90\x80\x80") == false    # U+110000 (first invalid code point)
  doAssert validateUtf8("\xF4\xBF\xBF\xBF") == false
  doAssert validateUtf8("\xF5\x80\x80\x80") == false
  doAssert validateUtf8("\xF7\xBF\xBF\xBF") == false

  # 5-byte and 6-byte obsolete sequences
  doAssert validateUtf8("\xF8\x88\x80\x80\x80") == false
  doAssert validateUtf8("\xFC\x84\x80\x80\x80\x80") == false

  # Invalid start bytes
  doAssert validateUtf8("\xFE") == false
  doAssert validateUtf8("\xFF") == false
  doAssert validateUtf8("\xC0") == false
  doAssert validateUtf8("\xC1") == false

  # --- E. Adversarial Rejection: Truncated & Malformed sequences ---
  # Lone continuation bytes
  doAssert validateUtf8("\x80") == false
  doAssert validateUtf8("\x90") == false
  doAssert validateUtf8("\xBF") == false
  doAssert validateUtf8("\x80\x80\x80") == false
  doAssert validateUtf8("hello\x80world") == false

  # Missing continuation bytes (truncated at end of string)
  doAssert validateUtf8("\xC2") == false
  doAssert validateUtf8("\xE2\x82") == false
  doAssert validateUtf8("\xF0\x9F\x98") == false

  # Corrupted continuation bytes
  doAssert validateUtf8("\xC2\x20") == false
  doAssert validateUtf8("\xE2\x20\x80") == false
  doAssert validateUtf8("\xE2\x82\x20") == false
  doAssert validateUtf8("\xF0\x20\x80\x80") == false
  doAssert validateUtf8("\xF0\x9F\x20\x80") == false
  doAssert validateUtf8("\xF0\x9F\x98\x20") == false

  # Lead byte followed by another lead byte
  doAssert validateUtf8("\xC2\xC2") == false
  doAssert validateUtf8("\xE2\xE2\x80") == false

  echo "[test_ironclad_unicode] UTF-8 RFC 3629 validation PASSED."

# =============================================================================
# 2. Rune Decoding & Encoding Roundtrip
# =============================================================================

proc testRuneCodec() =
  echo "[test_ironclad_unicode] Testing Rune decode/encode roundtrip..."

  let testRunes: seq[uint32] = @[
    0x0000'u32, 0x0020'u32, 0x0041'u32, 0x007E'u32, 0x007F'u32,   # 1-byte
    0x0080'u32, 0x00A9'u32, 0x03B1'u32, 0x041F'u32, 0x07FF'u32,   # 2-byte
    0x0800'u32, 0x20AC'u32, 0x3042'u32, 0x4E16'u32, 0xD7FF'u32,   # 3-byte before surrogates
    0xE000'u32, 0xFFFD'u32, 0xFFFF'u32,                             # 3-byte after surrogates
    0x10000'u32, 0x1F600'u32, 0x1F680'u32, 0x10FFFF'u32            # 4-byte
  ]

  for r in testRunes:
    let encoded = encodeRune(r)
    doAssert encoded.len in 1 .. 4, &"Rune {r:#x} encoded length out of bounds: {encoded.len}"
    doAssert validateUtf8(encoded) == true, &"Encoded rune {r:#x} failed validation"

    let (decodedRune, decLen) = decodeRune(encoded, 0)
    doAssert decodedRune == r, &"Decode mismatch for {r:#x}: got {decodedRune:#x}"
    doAssert decLen == encoded.len, &"Decode length mismatch for {r:#x}: got {decLen}, expected {encoded.len}"

  # Multi-rune sequence decoding
  let compound = "A привет 🚀"
  var pos = 0
  var extracted: seq[uint32] = @[]
  while pos < compound.len:
    let (rune, length) = decodeRune(compound, pos)
    doAssert length > 0
    extracted.add(rune)
    pos += length
  doAssert pos == compound.len
  doAssert extracted[0] == uint32('A')
  doAssert extracted[extracted.len - 1] == 0x1F680'u32 # rocket emoji

  echo "[test_ironclad_unicode] Rune decode/encode PASSED."

# =============================================================================
# 3. Grapheme Cluster Segmentation (UAX #29)
# =============================================================================

proc collectGraphemes(s: string): seq[string] =
  var res: seq[string] = @[]
  for g in graphemes(s):
    res.add(g.text)
  res

proc testGraphemeSegmentation() =
  echo "[test_ironclad_unicode] Testing UAX #29 Grapheme Cluster Segmentation..."

  # 1. ASCII text: 'Hello' MUST be 5 graphemes
  let asciiText = "Hello"
  let gAscii = collectGraphemes(asciiText)
  doAssert gAscii.len == 5, &"Expected 5 graphemes for 'Hello', got {gAscii.len}: {gAscii}"
  doAssert gAscii == @["H", "e", "l", "l", "o"]

  # 2. Combining diacritics: 'e' + combining acute accent (\u0301) MUST be 1 grapheme cluster
  let combiningE = "e\u0301" # U+0065 + U+0301
  let gCombining = collectGraphemes(combiningE)
  doAssert gCombining.len == 1, &"Expected 1 grapheme for 'e\\u0301', got {gCombining.len}: {gCombining}"
  doAssert gCombining[0] == combiningE

  # Multi-combining: 'a' + acute + tilde
  let multiCombining = "a\u0301\u0303"
  let gMulti = collectGraphemes(multiCombining)
  doAssert gMulti.len == 1, &"Expected 1 grapheme for multi-combining, got {gMulti.len}"

  # 3. Multi-codepoint emoji ZWJ sequences:
  # '👨‍👩‍👧‍👦' (Man + ZWJ + Woman + ZWJ + Girl + ZWJ + Boy) MUST be parsed as exactly 1 grapheme cluster
  let familyEmoji = "👨‍👩‍👧‍👦"
  let gFamily = collectGraphemes(familyEmoji)
  doAssert gFamily.len == 1, &"Expected 1 grapheme for family ZWJ emoji, got {gFamily.len}: {gFamily}"
  doAssert gFamily[0] == familyEmoji

  # Rainbow flag: '🏳️‍🌈' (Waving white flag + VS16 + ZWJ + Rainbow) MUST be 1 grapheme cluster
  let rainbowFlag = "🏳️‍🌈"
  let gRainbow = collectGraphemes(rainbowFlag)
  doAssert gRainbow.len == 1, &"Expected 1 grapheme for rainbow flag, got {gRainbow.len}: {gRainbow}"

  # Skin tone modifier: '👍🏽' (Thumbs up + Medium skin tone) MUST be 1 grapheme cluster
  let skinTone = "👍🏽"
  let gSkin = collectGraphemes(skinTone)
  doAssert gSkin.len == 1, &"Expected 1 grapheme for skin-tone emoji, got {gSkin.len}: {gSkin}"

  # 4. Flag sequences:
  # '🇺🇸' (Regional Indicator Symbol Letter U + Letter S) MUST be parsed as exactly 1 grapheme cluster
  let usFlag = "🇺🇸"
  let gUS = collectGraphemes(usFlag)
  doAssert gUS.len == 1, &"Expected 1 grapheme for US flag, got {gUS.len}: {gUS}"
  doAssert gUS[0] == usFlag

  # Two adjacent flags: '🇺🇸🇩🇪' MUST be parsed as exactly 2 grapheme clusters
  let twoFlags = "🇺🇸🇩🇪"
  let gTwoFlags = collectGraphemes(twoFlags)
  doAssert gTwoFlags.len == 2, &"Expected 2 graphemes for two flags, got {gTwoFlags.len}: {gTwoFlags}"
  doAssert gTwoFlags[0] == "🇺🇸"
  doAssert gTwoFlags[1] == "🇩🇪"

  # Mixed text with graphemes
  let mixed = "Hi 👨‍👩‍👧‍👦 🇺🇸!"
  let gMixed = collectGraphemes(mixed)
  # 'H', 'i', ' ', '👨‍👩‍👧‍👦', ' ', '🇺🇸', '!' -> 7 clusters
  doAssert gMixed.len == 7, &"Expected 7 graphemes for mixed text, got {gMixed.len}: {gMixed}"

  echo "[test_ironclad_unicode] Grapheme Cluster Segmentation PASSED."

# =============================================================================
# 4. Display Width
# =============================================================================

proc testDisplayWidth() =
  echo "[test_ironclad_unicode] Testing Display Width..."

  # ASCII = 1 per char
  doAssert displayWidth("A") == 1
  doAssert displayWidth("Hello") == 5
  doAssert displayWidth("Hello, World!") == 13

  # East Asian wide = 2 per char
  doAssert displayWidth("中") == 2
  doAssert displayWidth("中文") == 4
  doAssert displayWidth("日本語") == 6
  doAssert displayWidth("한국어") == 6

  # Emoji = 2
  doAssert displayWidth("😀") == 2
  doAssert displayWidth("🚀") == 2
  doAssert displayWidth("🎉") == 2
  doAssert displayWidth("👨‍👩‍👧‍👦") == 2
  doAssert displayWidth("🇺🇸") == 2

  # Combining marks / ZWJ = 0
  doAssert displayWidth("\u0301") == 0        # Combining acute accent alone
  doAssert displayWidth("\u200D") == 0        # Zero-width joiner alone
  doAssert displayWidth("\uFE0F") == 0        # Variation selector-16 alone

  # Combining character cluster: 'e' (1) + combining acute (0) = 1
  doAssert displayWidth("e\u0301") == 1

  # Mixed sentences
  # "Hello, 世界! 🚀"
  # "Hello, " (7) + "世界" (4) + "! " (2) + "🚀" (2) = 15
  doAssert displayWidth("Hello, 世界! 🚀") == 15

  echo "[test_ironclad_unicode] Display Width PASSED."

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  testUtf8Validation()
  testRuneCodec()
  testGraphemeSegmentation()
  testDisplayWidth()
  echo "\n>>> [test_ironclad_unicode] ALL TESTS PASSED UNCOMPROMISINGLY <<<"
