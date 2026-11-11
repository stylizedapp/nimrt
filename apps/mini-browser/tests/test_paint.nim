## tests/test_paint.nim — Unit tests for paint primitives
import corex
import ../src/png
import ../src/paint

# Test 1: 10x10 red rect in 20x20 -> check 4 inside (red), 4 outside (zero)
testWithLeakCheck("10x10 red rect in 20x20"):
  var img = newImage(20, 20, testAlloc)
  let red = rgba(255'u8, 0'u8, 0'u8, 255'u8)
  # Fill 10x10 rect at (5, 5)
  fillRect(img, 5, 5, 10, 10, red)

  # Check 4 pixels inside (should be red)
  assert img.pixels[5 * 20 + 5] == red
  assert img.pixels[5 * 20 + 14] == red
  assert img.pixels[14 * 20 + 5] == red
  assert img.pixels[14 * 20 + 14] == red

  # Check 4 pixels outside (should be 0)
  assert img.pixels[0 * 20 + 0] == 0'u32
  assert img.pixels[4 * 20 + 4] == 0'u32
  assert img.pixels[15 * 20 + 15] == 0'u32
  assert img.pixels[19 * 20 + 19] == 0'u32

  img.deinit()

# Test 2: Rect clipping with (-5, -5, 10, 10) in 20x20
testWithLeakCheck("Rect clipping with negative offsets"):
  var img = newImage(20, 20, testAlloc)
  let blue = rgba(0'u8, 0'u8, 255'u8, 255'u8)
  fillRect(img, -5, -5, 10, 10, blue)

  # Clipped region should be [0..4, 0..4]
  assert img.pixels[0 * 20 + 0] == blue
  assert img.pixels[0 * 20 + 4] == blue
  assert img.pixels[4 * 20 + 0] == blue
  assert img.pixels[4 * 20 + 4] == blue

  # Pixels outside [0..4, 0..4] must remain 0
  assert img.pixels[0 * 20 + 5] == 0'u32
  assert img.pixels[5 * 20 + 0] == 0'u32
  assert img.pixels[5 * 20 + 5] == 0'u32
  assert img.pixels[10 * 20 + 10] == 0'u32

  # Also test completely outside rects (e.g. negative or beyond dimensions)
  fillRect(img, -20, -20, 10, 10, blue)
  fillRect(img, 25, 25, 10, 10, blue)
  assert img.pixels[19 * 20 + 19] == 0'u32

  img.deinit()

# Test 3: drawTextPlaceholder
testWithLeakCheck("drawTextPlaceholder 2 columns in 20x20"):
  var img = newImage(20, 20, testAlloc)
  let black = rgba(0'u8, 0'u8, 0'u8, 255'u8)

  # "Hi" -> 2 characters at x=0, fontSize=16
  drawTextPlaceholder(img, 0, 0, "Hi", 16, black)

  # First character: x in 0..6, y in 0..15 -> black
  assert img.pixels[0 * 20 + 0] == black
  assert img.pixels[0 * 20 + 6] == black
  assert img.pixels[15 * 20 + 0] == black
  assert img.pixels[15 * 20 + 6] == black

  # Inter-character gap at x=7 -> 0
  assert img.pixels[0 * 20 + 7] == 0'u32
  assert img.pixels[10 * 20 + 7] == 0'u32

  # Second character: x in 8..14, y in 0..15 -> black
  assert img.pixels[0 * 20 + 8] == black
  assert img.pixels[0 * 20 + 14] == black
  assert img.pixels[15 * 20 + 8] == black
  assert img.pixels[15 * 20 + 14] == black

  # Trailing gap at x=15 -> 0
  assert img.pixels[0 * 20 + 15] == 0'u32
  assert img.pixels[10 * 20 + 15] == 0'u32

  # Outside vertical range y >= 16 -> 0
  assert img.pixels[16 * 20 + 0] == 0'u32
  assert img.pixels[16 * 20 + 8] == 0'u32

  img.deinit()

echo "All 3 Paint tests passed!"
