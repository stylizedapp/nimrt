## nimui/rasterizer — Pure-Nim Software 2D SDF Rasterizer & Zero-Dependency PNG Encoder
##
## Features:
## - Evaluates the exact same 2D SDF rounded box, inset border, AA softness,
##   scissor clipRect, and FontAtlas alpha-blended glyph pipeline as Vulkan.
## - Enables pixel-accurate headless rendering, snapshot verification, and automated
##   visual debugging without requiring an interactive GPU swapchain.
## - Self-contained pure-Nim PNG encoder (stored Deflate RFC 1950/1951 + Adler32 + CRC32)
##   with zero external C dependencies and {.raises: [].}.

import std/math
import corex/io
import ./gpu/font_atlas
import ./gpu/vulkan_backend

type
  SoftwareFramebuffer* = object
    width*: int
    height*: int
    pixels*: seq[uint32] # Packed 0xRRGGBBAA'u32

proc initSoftwareFramebuffer*(width, height: int, clearColor: uint32 = 0x0A0A0CFF'u32): SoftwareFramebuffer {.raises: [].} =
  let w = max(1, width)
  let h = max(1, height)
  result.width = w
  result.height = h
  result.pixels = newSeq[uint32](w * h)
  for i in 0 ..< result.pixels.len:
    result.pixels[i] = clearColor

proc clear*(fb: var SoftwareFramebuffer, clearColor: uint32 = 0x0A0A0CFF'u32) {.inline, raises: [].} =
  for i in 0 ..< fb.pixels.len:
    fb.pixels[i] = clearColor

proc getPixel*(fb: SoftwareFramebuffer, x, y: int): uint32 {.inline, raises: [].} =
  if x < 0 or x >= fb.width or y < 0 or y >= fb.height:
    return 0'u32
  fb.pixels[y * fb.width + x]

proc unpackRgba(c: uint32): tuple[r, g, b, a: float32] {.inline, raises: [].} =
  let r = float32((c shr 24) and 0xFF'u32) / 255.0f
  let g = float32((c shr 16) and 0xFF'u32) / 255.0f
  let b = float32((c shr 8) and 0xFF'u32) / 255.0f
  let a = float32(c and 0xFF'u32) / 255.0f
  (r, g, b, a)

proc packRgba(r, g, b, a: float32): uint32 {.inline, raises: [].} =
  let ri = uint32(clamp(int(r * 255.0f + 0.5f), 0, 255))
  let gi = uint32(clamp(int(g * 255.0f + 0.5f), 0, 255))
  let bi = uint32(clamp(int(b * 255.0f + 0.5f), 0, 255))
  let ai = uint32(clamp(int(a * 255.0f + 0.5f), 0, 255))
  (ri shl 24) or (gi shl 16) or (bi shl 8) or ai

proc smoothstep(edge0, edge1, x: float32): float32 {.inline, raises: [].} =
  let denom = edge1 - edge0
  if abs(denom) < 1e-6f:
    return if x < edge0: 0.0f else: 1.0f
  let t = clamp((x - edge0) / denom, 0.0f, 1.0f)
  t * t * (3.0f - 2.0f * t)

proc blendOver(fb: var SoftwareFramebuffer, idx: int, srcR, srcG, srcB, srcA: float32) {.inline, raises: [].} =
  if srcA <= 0.001f:
    return
  if srcA >= 0.999f:
    fb.pixels[idx] = packRgba(srcR, srcG, srcB, 1.0f)
    return
  let dst = unpackRgba(fb.pixels[idx])
  let invA = 1.0f - srcA
  let outR = srcR * srcA + dst.r * invA
  let outG = srcG * srcA + dst.g * invA
  let outB = srcB * srcA + dst.b * invA
  let outA = srcA + dst.a * invA
  fb.pixels[idx] = packRgba(outR, outG, outB, outA)

proc sampleAtlasBilinear(atlas: FontAtlas, u, v: float32): float32 {.inline, raises: [].} =
  if atlas.pixels.len == 0 or atlas.width <= 0 or atlas.height <= 0:
    return 0.0f
  let fx = clamp(u, 0.0f, 1.0f) * float32(atlas.width) - 0.5f
  let fy = clamp(v, 0.0f, 1.0f) * float32(atlas.height) - 0.5f
  let x0 = clamp(int(floor(fx)), 0, atlas.width - 1)
  let y0 = clamp(int(floor(fy)), 0, atlas.height - 1)
  let x1 = min(x0 + 1, atlas.width - 1)
  let y1 = min(y0 + 1, atlas.height - 1)
  let tx = fx - floor(fx)
  let ty = fy - floor(fy)

  let c00 = float32(atlas.pixels[y0 * atlas.width + x0]) / 255.0f
  let c10 = float32(atlas.pixels[y0 * atlas.width + x1]) / 255.0f
  let c01 = float32(atlas.pixels[y1 * atlas.width + x0]) / 255.0f
  let c11 = float32(atlas.pixels[y1 * atlas.width + x1]) / 255.0f

  let top = c00 + (c10 - c00) * tx
  let bot = c01 + (c11 - c01) * tx
  top + (bot - top) * ty

proc sdRoundedBox(lx, ly, halfW, halfH, radius: float32): float32 {.inline, raises: [].} =
  let r = min(max(0.0f, radius), min(halfW, halfH))
  let qx = abs(lx) - halfW + r
  let qy = abs(ly) - halfH + r
  let outDist = sqrt(max(qx, 0.0f) * max(qx, 0.0f) + max(qy, 0.0f) * max(qy, 0.0f))
  let inDist = min(max(qx, qy), 0.0f)
  outDist + inDist - r

proc renderInstancesToBuffer*(
  fb: var SoftwareFramebuffer,
  instances: openArray[UiDrawInstance],
  atlas: FontAtlas,
  clearColor: uint32 = 0x0A0A0CFF'u32,
  shouldClear: bool = true
) {.raises: [].} =
  if shouldClear:
    fb.clear(clearColor)
  if fb.width <= 0 or fb.height <= 0:
    return

  for inst in instances:
    let x = inst.pos[0]
    let y = inst.pos[1]
    let w = inst.size[0]
    let h = inst.size[1]
    if w <= 0.0f or h <= 0.0f:
      continue

    let isText = inst.uvSize[0] > 0.0f and inst.uvSize[1] > 0.0f
    let aa = max(0.5f, max(1.0f, inst.softness) * 0.5f)
    let pad = if isText: 0.0f else: ceil(aa)

    let clipMinX = max(0, int(inst.clipRect[0]))
    let clipMinY = max(0, int(inst.clipRect[1]))
    let clipMaxX = min(fb.width, int(inst.clipRect[2]))
    let clipMaxY = min(fb.height, int(inst.clipRect[3]))
    if clipMinX >= clipMaxX or clipMinY >= clipMaxY:
      continue

    let minPx = max(clipMinX, int(floor(x - pad)))
    let minPy = max(clipMinY, int(floor(y - pad)))
    let maxPx = min(clipMaxX, int(ceil(x + w + pad)))
    let maxPy = min(clipMaxY, int(ceil(y + h + pad)))
    if minPx >= maxPx or minPy >= maxPy:
      continue

    let col = unpackRgba(inst.color)

    if isText:
      if col.a <= 0.0f:
        continue
      let invW = 1.0f / w
      let invH = 1.0f / h
      for py in minPy ..< maxPy:
        let vNorm = (float32(py) + 0.5f - y) * invH
        let uvV = inst.uvPos[1] + vNorm * inst.uvSize[1]
        let rowBase = py * fb.width
        for px in minPx ..< maxPx:
          let uNorm = (float32(px) + 0.5f - x) * invW
          let uvU = inst.uvPos[0] + uNorm * inst.uvSize[0]
          let glyphCov = sampleAtlasBilinear(atlas, uvU, uvV)
          if glyphCov > 0.002f:
            fb.blendOver(rowBase + px, col.r, col.g, col.b, col.a * glyphCov)
    else:
      let bCol = unpackRgba(inst.borderColor)
      let halfW = w * 0.5f
      let halfH = h * 0.5f
      let centerX = x + halfW
      let centerY = y + halfH
      let hasBorder = inst.borderWidth > 0.0f and bCol.a > 0.0f
      if col.a <= 0.0f and not hasBorder:
        continue

      for py in minPy ..< maxPy:
        let ly = (float32(py) + 0.5f) - centerY
        let rowBase = py * fb.width
        for px in minPx ..< maxPx:
          let lx = (float32(px) + 0.5f) - centerX
          let d = sdRoundedBox(lx, ly, halfW, halfH, inst.cornerRadius)
          let outerCov = smoothstep(aa, -aa, d)
          if outerCov <= 0.001f:
            continue

          if not hasBorder:
            fb.blendOver(rowBase + px, col.r, col.g, col.b, col.a * outerCov)
          else:
            let innerCov = smoothstep(aa, -aa, d + inst.borderWidth)
            let borderCov = max(0.0f, outerCov - innerCov)
            if col.a > 0.0f and innerCov > 0.001f:
              fb.blendOver(rowBase + px, col.r, col.g, col.b, col.a * innerCov)
            if borderCov > 0.001f:
              fb.blendOver(rowBase + px, bCol.r, bCol.g, bCol.b, bCol.a * borderCov)

# =============================================================================
# Pure-Nim Zero-Dependency PNG Encoder (Stored Deflate RFC 1950/1951)
# =============================================================================

proc appendBE32(buf: var seq[byte], v: uint32) {.inline, raises: [].} =
  buf.add(byte((v shr 24) and 0xFF'u32))
  buf.add(byte((v shr 16) and 0xFF'u32))
  buf.add(byte((v shr 8) and 0xFF'u32))
  buf.add(byte(v and 0xFF'u32))

proc appendLE16(buf: var seq[byte], v: uint16) {.inline, raises: [].} =
  buf.add(byte(v and 0xFF'u16))
  buf.add(byte((v shr 8) and 0xFF'u16))

proc crc32Update(crc0: uint32, data: openArray[byte]): uint32 {.raises: [].} =
  var c = crc0
  for b in data:
    c = c xor uint32(b)
    for _ in 0 ..< 8:
      if (c and 1'u32) != 0'u32:
        c = (c shr 1) xor 0xEDB88320'u32
      else:
        c = c shr 1
  c

proc computeCrc32*(tag: array[4, char], payload: openArray[byte]): uint32 {.raises: [].} =
  var c = 0xFFFFFFFF'u32
  var tagBytes: array[4, byte]
  for i in 0 ..< 4:
    tagBytes[i] = byte(tag[i])
  c = crc32Update(c, tagBytes)
  if payload.len > 0:
    c = crc32Update(c, payload)
  not c

proc appendPngChunk(dst: var seq[byte], tag: array[4, char], payload: openArray[byte]) {.raises: [].} =
  dst.appendBE32(uint32(payload.len))
  for ch in tag:
    dst.add(byte(ch))
  for b in payload:
    dst.add(b)
  dst.appendBE32(computeCrc32(tag, payload))

proc encodePng*(fb: SoftwareFramebuffer): seq[byte] {.raises: [].} =
  ## Encodes the framebuffer into a valid RGBA PNG byte stream with zero C dependencies.
  if fb.width <= 0 or fb.height <= 0 or fb.pixels.len < fb.width * fb.height:
    return @[]

  let stride = 1 + fb.width * 4
  let rawLen = stride * fb.height

  # Build raw scanlines (Filter 0 = None)
  var raw = newSeq[byte](rawLen)
  var pos = 0
  for y in 0 ..< fb.height:
    raw[pos] = 0'u8
    inc(pos)
    let rowBase = y * fb.width
    for x in 0 ..< fb.width:
      let px = fb.pixels[rowBase + x]
      raw[pos + 0] = byte((px shr 24) and 0xFF'u32)
      raw[pos + 1] = byte((px shr 16) and 0xFF'u32)
      raw[pos + 2] = byte((px shr 8) and 0xFF'u32)
      raw[pos + 3] = byte(px and 0xFF'u32)
      pos += 4

  # Compute Adler-32 checksum over raw scanline stream
  var s1 = 1'u32
  var s2 = 0'u32
  for b in raw:
    s1 = (s1 + uint32(b)) mod 65521'u32
    s2 = (s2 + s1) mod 65521'u32
  let adler = (s2 shl 16) or s1

  # Wrap raw scanlines in RFC 1950 zlib stored Deflate blocks (max 65535 bytes/block)
  let numBlocks = (rawLen + 65534) div 65535
  var idat = newSeqOfCap[byte](2 + rawLen + numBlocks * 5 + 4)
  idat.add(0x78'u8) # CMF: Deflate, 32K window
  idat.add(0x01'u8) # FLG: no preset dict, FCHECK valid ((0x78*256+0x01) mod 31 == 0)

  var offset = 0
  while offset < rawLen:
    let blockLen = min(65535, rawLen - offset)
    let isLast = (offset + blockLen) >= rawLen
    idat.add(if isLast: 0x01'u8 else: 0x00'u8)
    let uLen = uint16(blockLen)
    let nLen = not uLen
    idat.appendLE16(uLen)
    idat.appendLE16(nLen)
    for i in 0 ..< blockLen:
      idat.add(raw[offset + i])
    offset += blockLen
  idat.appendBE32(adler)

  # Assemble PNG stream
  result = newSeqOfCap[byte](8 + 25 + 12 + idat.len + 12)
  for b in [137'u8, 80'u8, 78'u8, 71'u8, 13'u8, 10'u8, 26'u8, 10'u8]:
    result.add(b)

  var ihdr: array[13, byte]
  var ihdrSeq = newSeqOfCap[byte](13)
  ihdrSeq.appendBE32(uint32(fb.width))
  ihdrSeq.appendBE32(uint32(fb.height))
  ihdrSeq.add(8'u8) # Bit depth
  ihdrSeq.add(6'u8) # Color type: RGBA
  ihdrSeq.add(0'u8) # Compression method
  ihdrSeq.add(0'u8) # Filter method
  ihdrSeq.add(0'u8) # Interlace method
  for i in 0 ..< 13:
    ihdr[i] = ihdrSeq[i]

  result.appendPngChunk(['I', 'H', 'D', 'R'], ihdr)
  result.appendPngChunk(['I', 'D', 'A', 'T'], idat)
  result.appendPngChunk(['I', 'E', 'N', 'D'], [])

proc savePng*(fb: SoftwareFramebuffer, path: string): bool {.raises: [].} =
  let bytes = encodePng(fb)
  if bytes.len == 0:
    return false
  var fhRes = openFile(path, fmWrite)
  if fhRes.isErr:
    return false
  var fh = fhRes.get
  let wrRes = fh.write(unsafeAddr bytes[0], bytes.len)
  discard fh.close()
  wrRes.isOk and wrRes.get == bytes.len
