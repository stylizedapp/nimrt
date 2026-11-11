## apps/mini-browser/src/png.nim — Minimal PNG encoder
import corex

type
  Rgba* = uint32  # bytes in memory: R, G, B, A (little-endian)
  RgbaImage* = object
    width*, height*: int
    pixels*: ptr UncheckedArray[uint32]
    alloc*: Allocator

proc rgba*(r, g, b, a: uint8): Rgba {.inline, raises: [].} =
  ## Layout in memory: [R, G, B, A] — compatible with PNG colortype=6
  uint32(r) or (uint32(g) shl 8) or (uint32(b) shl 16) or (uint32(a) shl 24)

proc rgba*(r, g, b: uint8): Rgba {.inline, raises: [].} =
  rgba(r, g, b, 255'u8)

proc newImage*(w, h: int, alloc: Allocator): RgbaImage {.raises: [].} =
  ## w*h*4 bytes via alloc.allocSlice, zeroed
  result.width = w
  result.height = h
  result.alloc = alloc
  if w > 0 and h > 0:
    let res = alloc.allocSlice(uint32, w * h)
    result.pixels = res.getOr(nil)
    if result.pixels.isNil:
      result.width = 0
      result.height = 0
  else:
    result.pixels = nil

proc deinit*(img: var RgbaImage) {.raises: [].} =
  ## alloc.dealloc(pixels, w*h*4); zeroes fields
  if img.pixels != nil and img.width > 0 and img.height > 0:
    img.alloc.dealloc(img.pixels, img.width * img.height * sizeof(uint32))
  img.pixels = nil
  img.width = 0
  img.height = 0

proc crc32Table(): array[256, uint32] =
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      c = if (c and 1) != 0: (c shr 1) xor 0xEDB88320'u32 else: c shr 1
    result[i] = c

const Crc32Table = crc32Table()

proc crc32(data: openArray[byte]): uint32 =
  var c = 0xFFFFFFFF'u32
  for b in data:
    c = (c shr 8) xor Crc32Table[int((c xor uint32(b)) and 0xFF)]
  c xor 0xFFFFFFFF'u32

proc adler32(data: openArray[byte]): uint32 =
  var a = 1'u32
  var b = 0'u32
  for byte in data:
    a = (a + uint32(byte)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc addBe32(dst: var seq[byte], v: uint32) {.inline.} =
  dst.add(uint8((v shr 24) and 0xFF))
  dst.add(uint8((v shr 16) and 0xFF))
  dst.add(uint8((v shr 8) and 0xFF))
  dst.add(uint8(v and 0xFF))

proc addChunk(dst: var seq[byte], chunkType: string, data: openArray[byte]) =
  addBe32(dst, uint32(data.len))
  for c in chunkType: dst.add(uint8(c))
  for b in data: dst.add(b)
  var crcData = newSeq[byte](4 + data.len)
  for i, c in chunkType: crcData[i] = uint8(c)
  for i, b in data: crcData[4 + i] = b
  addBe32(dst, crc32(crcData))

proc deflateStore(raw: openArray[byte]): seq[byte] =
  ## zlib store: header + N stored blocks (max 65535 each) + adler32
  result.add(0x78'u8)  # CMF: 32K window, deflate
  result.add(0x01'u8)  # FLG: no dict, check bits
  var pos = 0
  while pos < raw.len:
    let blockLen = min(65535, raw.len - pos)
    let isFinal = pos + blockLen >= raw.len
    result.add(if isFinal: 0x01'u8 else: 0x00'u8)
    result.add(uint8(blockLen and 0xFF))
    result.add(uint8((blockLen shr 8) and 0xFF))
    let nlen = not uint16(blockLen)
    result.add(uint8(nlen and 0xFF))
    result.add(uint8((nlen shr 8) and 0xFF))
    for i in 0 ..< blockLen: result.add(raw[pos + i])
    pos += blockLen
  let ad = adler32(raw)
  result.add(uint8((ad shr 24) and 0xFF))
  result.add(uint8((ad shr 16) and 0xFF))
  result.add(uint8((ad shr 8) and 0xFF))
  result.add(uint8(ad and 0xFF))

proc encodePng*(img: RgbaImage): seq[byte] {.raises: [].} =
  # signature
  for b in [0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8]:
    result.add(b)
  # IHDR
  var ihdr: seq[byte]
  addBe32(ihdr, uint32(img.width))
  addBe32(ihdr, uint32(img.height))
  ihdr.add(0x08'u8)  # bit depth 8
  ihdr.add(0x06'u8)  # color type 6 (RGBA)
  ihdr.add(0x00'u8)  # compression
  ihdr.add(0x00'u8)  # filter
  ihdr.add(0x00'u8)  # interlace
  addChunk(result, "IHDR", ihdr)
  # raw scanlines with filter byte 0
  var raw = newSeq[byte](img.height * (1 + img.width * 4))
  var pos = 0
  for y in 0 ..< img.height:
    raw[pos] = 0x00; inc pos  # filter None
    for x in 0 ..< img.width:
      let px = img.pixels[y * img.width + x]
      raw[pos] = uint8(px and 0xFF); inc pos           # R
      raw[pos] = uint8((px shr 8) and 0xFF); inc pos   # G
      raw[pos] = uint8((px shr 16) and 0xFF); inc pos  # B
      raw[pos] = uint8((px shr 24) and 0xFF); inc pos  # A
  # IDAT
  addChunk(result, "IDAT", deflateStore(raw))
  # IEND
  addChunk(result, "IEND", [])
