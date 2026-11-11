## apps/mini-browser/src/paint.nim — RGBA buffer + drawing primitives
import corex
import ./png

proc fillRect*(img: var RgbaImage, x, y, w, h: int, color: Rgba) {.raises: [].} =
  if img.pixels == nil or img.width <= 0 or img.height <= 0:
    return
  let x0 = max(0, x)
  let y0 = max(0, y)
  let x1 = min(img.width, x + w)
  let y1 = min(img.height, y + h)
  if x0 >= x1 or y0 >= y1:
    return
  for row in y0 ..< y1:
    let rowOffset = row * img.width
    for col in x0 ..< x1:
      img.pixels[rowOffset + col] = color

proc drawTextPlaceholder*(img: var RgbaImage, x, y: int,
                          text: openArray[byte], fontSize: int, color: Rgba) {.raises: [].} =
  ## charWidth = 8; fills width 7, height fontSize per byte at x + i * 8
  for i in 0 ..< text.len:
    fillRect(img, x + i * 8, y, 7, fontSize, color)

proc drawTextPlaceholder*(img: var RgbaImage, x, y: int,
                          text: string, fontSize: int, color: Rgba) {.inline, raises: [].} =
  if text.len > 0:
    drawTextPlaceholder(img, x, y, toOpenArrayByte(text, 0, text.len - 1), fontSize, color)

proc drawTextPlaceholder*(img: var RgbaImage, x, y: int,
                          text: Span[byte], fontSize: int, color: Rgba) {.raises: [].} =
  for i in 0 ..< text.len:
    fillRect(img, x + i * 8, y, 7, fontSize, color)
