## tests/test_png.nim — Unit tests for PNG encoder
import corex
import ../src/png

proc parseIhdr(bytes: seq[byte]): tuple[validSig: bool, width, height: int, bitDepth, colorType: int] =
  let expectedSig: array[8, byte] = [0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8]
  if bytes.len < 8 + 8 + 13:
    return (false, 0, 0, 0, 0)
  for i in 0 ..< 8:
    if bytes[i] != expectedSig[i]:
      return (false, 0, 0, 0, 0)
  if bytes[12] != byte('I') or bytes[13] != byte('H') or bytes[14] != byte('D') or bytes[15] != byte('R'):
    return (false, 0, 0, 0, 0)
  let w = (int(bytes[16]) shl 24) or (int(bytes[17]) shl 16) or (int(bytes[18]) shl 8) or int(bytes[19])
  let h = (int(bytes[20]) shl 24) or (int(bytes[21]) shl 16) or (int(bytes[22]) shl 8) or int(bytes[23])
  let depth = int(bytes[24])
  let colType = int(bytes[25])
  (true, w, h, depth, colType)

# Test 1: 4x4 red image signature valid
testWithLeakCheck("4x4 red signature valid"):
  var img = newImage(4, 4, testAlloc)
  let red = rgba(255'u8, 0'u8, 0'u8, 255'u8)
  for i in 0 ..< 16:
    img.pixels[i] = red
  let pngData = encodePng(img)
  assert pngData.len >= 8
  let expectedSig: array[8, byte] = [0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8]
  for i in 0 ..< 8:
    assert pngData[i] == expectedSig[i]
  img.deinit()

# Test 2: 4x4 red image manual IHDR parse
testWithLeakCheck("4x4 IHDR w=4 h=4 manual parse"):
  var img = newImage(4, 4, testAlloc)
  let red = rgba(255'u8, 0'u8, 0'u8, 255'u8)
  for i in 0 ..< 16:
    img.pixels[i] = red
  let pngData = encodePng(img)
  let parsed = parseIhdr(pngData)
  assert parsed.validSig
  assert parsed.width == 4
  assert parsed.height == 4
  assert parsed.bitDepth == 8
  assert parsed.colorType == 6 # RGBA
  img.deinit()

# Test 3: 4x4 red image size exactly 136 bytes
testWithLeakCheck("4x4 size exactly 136 bytes"):
  var img = newImage(4, 4, testAlloc)
  let red = rgba(255'u8, 0'u8, 0'u8, 255'u8)
  for i in 0 ..< 16:
    img.pixels[i] = red
  let pngData = encodePng(img)
  assert pngData.len == 136
  img.deinit()

# Test 4: 100x100 size exactly 40168 bytes
testWithLeakCheck("100x100 size exactly 40168 bytes"):
  var img = newImage(100, 100, testAlloc)
  let green = rgba(0'u8, 255'u8, 0'u8, 255'u8)
  for i in 0 ..< 100 * 100:
    img.pixels[i] = green
  let pngData = encodePng(img)
  assert pngData.len == 40168
  let parsed = parseIhdr(pngData)
  assert parsed.validSig
  assert parsed.width == 100
  assert parsed.height == 100
  img.deinit()

# Test 5: 800x600 size > 0, signature valid, IHDR w/h correct
testWithLeakCheck("800x600 size > 0, signature valid, IHDR correct"):
  var img = newImage(800, 600, testAlloc)
  let blue = rgba(0'u8, 0'u8, 255'u8, 255'u8)
  for i in 0 ..< 800 * 600:
    img.pixels[i] = blue
  let pngData = encodePng(img)
  assert pngData.len > 0
  let parsed = parseIhdr(pngData)
  assert parsed.validSig
  assert parsed.width == 800
  assert parsed.height == 600
  img.deinit()

echo "All 5 PNG tests passed!"
