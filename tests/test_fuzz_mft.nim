## tests/test_fuzz_mft.nim — Deterministic 100,000-Iteration MFT Parser Fuzzer
##
## Fuzzes `corex/mft` (`parseMftRecord`, `parseMftBuffer`, `restoreFixups`,
## `parseRunList`, `calculateAllocatedClusters`, `decodeUtf16LeFast`) across:
## - Short, empty, truncated, and multi-record buffers
## - Corrupt signatures ('BAAD', garbage) and malformed USA fixup headers
## - Boundary/huge attribute offsets & lengths (resident & non-resident)
## - Malformed $ATTRIBUTE_LIST, $FILE_NAME UTF-16LE surrogates, and $DATA runlists
## - 8-byte nibble runlist overflow & sign-extension edge cases
##
## Verifies zero panics, zero OOB accesses (with checks ON), and zero ORC leaks.

import std/strformat
import corex/[mft, memory, result, testing]

when defined(windows):
  proc putU16(buf: var openArray[byte], offset: int, val: uint16) {.inline.} =
    buf[offset + 0] = byte(val and 0xFF'u16)
    buf[offset + 1] = byte((val shr 8) and 0xFF'u16)

  proc putU32(buf: var openArray[byte], offset: int, val: uint32) {.inline.} =
    buf[offset + 0] = byte(val and 0xFF'u32)
    buf[offset + 1] = byte((val shr 8) and 0xFF'u32)
    buf[offset + 2] = byte((val shr 16) and 0xFF'u32)
    buf[offset + 3] = byte((val shr 24) and 0xFF'u32)

  proc putU64(buf: var openArray[byte], offset: int, val: uint64) {.inline.} =
    for i in 0 .. 7:
      buf[offset + i] = byte((val shr (i * 8)) and 0xFF'u64)

  proc buildTemplateRecord(nonResidentData: bool): array[MFT_RECORD_SIZE, byte] =
    result = default(array[MFT_RECORD_SIZE, byte])
    putU32(result, 0, MFT_MAGIC_FILE)
    putU16(result, 4, 48'u16)   # usaOffset
    putU16(result, 6, 3'u16)    # usaCount (checkWord + 2 sectors)
    putU16(result, 16, 1'u16)   # sequenceNumber
    putU16(result, 18, 1'u16)   # linkCount
    putU16(result, 20, 56'u16)  # firstAttrOffset
    putU16(result, 22, MFT_RECORD_IN_USE)
    putU32(result, 24, 1024'u32)
    putU32(result, 28, 1024'u32)
    putU32(result, 44, 42'u32)

    let checkWord = 0xA55A'u16
    putU16(result, 48, checkWord)
    putU16(result, 50, 0x1122'u16)
    putU16(result, 52, 0x3344'u16)

    var off = 56

    # $STANDARD_INFORMATION (0x10)
    putU32(result, off + 0, ATTR_STANDARD_INFORMATION)
    putU32(result, off + 4, 72'u32)
    result[off + 8] = 0
    putU32(result, off + 16, 48'u32)
    putU16(result, off + 20, 24'u16)
    putU64(result, off + 24, 133500000000000000'u64)
    putU64(result, off + 32, 133600000000000000'u64)
    putU32(result, off + 56, 0x20'u32)
    off += 72

    # $FILE_NAME (0x30)
    let name = "fuzz_target.bin"
    let fnValLen = 66 + name.len * 2
    let fnAttrLen = (24 + fnValLen + 7) and (not 7)
    putU32(result, off + 0, ATTR_FILE_NAME)
    putU32(result, off + 4, uint32(fnAttrLen))
    result[off + 8] = 0
    putU32(result, off + 16, uint32(fnValLen))
    putU16(result, off + 20, 24'u16)
    putU64(result, off + 24, 5'u64)
    result[off + 24 + 64] = byte(name.len)
    result[off + 24 + 65] = 1'u8
    for i, c in name:
      result[off + 24 + 66 + i * 2] = byte(c)
    off += fnAttrLen

    # $DATA (0x80)
    if nonResidentData:
      putU32(result, off + 0, ATTR_DATA)
      putU32(result, off + 4, 72'u32)
      result[off + 8] = 1 # non-resident
      result[off + 9] = 0
      putU16(result, off + 32, 64'u16) # runListOff
      putU64(result, off + 40, 8192'u64)
      putU64(result, off + 48, 5000'u64)
      result[off + 64] = 0x21'u8 # 1 byte len, 2 byte off
      result[off + 65] = 0x02'u8
      result[off + 66] = 0x10'u8
      result[off + 67] = 0x00'u8
      result[off + 68] = 0x00'u8
      off += 72
    else:
      putU32(result, off + 0, ATTR_DATA)
      putU32(result, off + 4, 32'u32)
      result[off + 8] = 0
      putU32(result, off + 16, 8'u32)
      putU16(result, off + 20, 24'u16)
      off += 32

    putU32(result, off, ATTR_END_MARKER)

    # Apply on-disk check words at sector boundaries
    putU16(result, 510, checkWord)
    putU16(result, 1022, checkWord)

  proc fillRandomBytes(rng: var FuzzRng, buf: var openArray[byte]) =
    var i = 0
    while i + 8 <= buf.len:
      let v = rng.nextU64()
      copyMem(addr buf[i], unsafeAddr v, 8)
      i += 8
    if i < buf.len:
      var v = rng.nextU64()
      while i < buf.len:
        buf[i] = byte(v and 0xFF'u64)
        v = v shr 8
        inc(i)

  proc applyValidCheckWords(rec: var openArray[byte], checkWord: uint16) =
    putU16(rec, 48, checkWord)
    putU16(rec, 510, checkWord)
    putU16(rec, 1022, checkWord)

  proc runMftFuzzSuite() =
    echo "=== RUNNING 100,000-ITERATION MFT PARSER FUZZER ==="
    var rng = initFuzzRng(0x4D4654_F022_2026'u64)
    let baseRes = buildTemplateRecord(nonResidentData = false)
    let baseNonRes = buildTemplateRecord(nonResidentData = true)

    let orcBefore = orcOccupiedMem()

    var entry: MftEntry
    var runs: seq[MftDataRun] = @[]
    var okTrue = 0
    var okFalse = 0
    var errCount = 0
    var totalIters = 0

    proc recordOutcome(r: Result[bool, IOError]) =
      if r.isOk:
        if r.get: inc(okTrue)
        else: inc(okFalse)
      else:
        inc(errCount)

    # -------------------------------------------------------------------------
    # Category A: 10,000 Short / Truncated / Oversized Buffer Cases
    # -------------------------------------------------------------------------
    const ShortLens = [0, 1, 2, 4, 15, 64, 511, 512, 1023, 1024, 1025, 2048, 3072]
    for i in 0 ..< 10_000:
      let bufLen = ShortLens[i mod ShortLens.len]
      var buf = newSeq[byte](bufLen)
      if bufLen > 0:
        rng.fillRandomBytes(buf)
        if bufLen >= 4 and (i and 1) == 0:
          putU32(buf, 0, MFT_MAGIC_FILE)
      recordOutcome(parseMftRecord(buf, entry, uint64(i), 4096'u32, (i and 1) == 0))
      if bufLen > 0:
        let sp = span(addr buf[0], bufLen)
        discard parseMftRecord(sp, entry, uint64(i))
      var count = 0
      for e in parseMftBuffer(buf, uint64(i), 4096'u32, (i and 1) == 0):
        inc(count)
        if count > 10: break
      discard restoreFixups(buf)
      inc(totalIters)

    # -------------------------------------------------------------------------
    # Category B: 20,000 Pure Random 1024-byte Buffers (+ magic variations)
    # -------------------------------------------------------------------------
    for i in 0 ..< 20_000:
      var rec: array[MFT_RECORD_SIZE, byte]
      rng.fillRandomBytes(rec)
      case i mod 4
      of 0: putU32(rec, 0, MFT_MAGIC_FILE)
      of 1: putU32(rec, 0, MFT_MAGIC_BAAD)
      else: discard
      let clusterSize = case i mod 5
        of 0: 0'u32
        of 1: 512'u32
        of 2: 4096'u32
        of 3: 65536'u32
        else: uint32(rng.nextU64() and 0xFFFF_FFFF'u64)
      recordOutcome(parseMftRecord(rec, entry, uint64(i), clusterSize, (i and 1) == 0))
      inc(totalIters)

    # -------------------------------------------------------------------------
    # Category C: 25,000 Bad USA Fixups & Header Offset Mutations
    # -------------------------------------------------------------------------
    const BoundaryOffsets = [0'u16, 4'u16, 42'u16, 56'u16, 510'u16, 976'u16, 1000'u16, 1008'u16, 1016'u16, 1022'u16, 1023'u16, 1024'u16, 65535'u16]
    for i in 0 ..< 25_000:
      var rec = if (i and 1) == 0: baseRes else: baseNonRes
      case i mod 6
      of 0:
        putU16(rec, 4, BoundaryOffsets[rng.nextInt(0, BoundaryOffsets.len - 1)])
        putU16(rec, 6, uint16(rng.nextInt(0, 65535)))
      of 1:
        putU16(rec, 4, uint16(rng.nextInt(0, 1024)))
        putU16(rec, 6, uint16(rng.nextInt(0, 20)))
      of 2:
        # Corrupt sector check word
        putU16(rec, 510, uint16(rng.nextU64() and 0xFFFF'u64))
        if (i and 2) != 0:
          putU16(rec, 1022, uint16(rng.nextU64() and 0xFFFF'u64))
      of 3:
        # Extreme firstAttrOffset
        putU16(rec, 20, BoundaryOffsets[rng.nextInt(0, BoundaryOffsets.len - 1)])
      of 4:
        # Flip flags & record numbers
        putU16(rec, 22, uint16(rng.nextU64() and 0xFFFF'u64))
        putU32(rec, 44, uint32(rng.nextU64() and 0xFFFF_FFFF'u64))
      else:
        # Random byte flips inside header 0..56
        let numFlips = rng.nextInt(1, 8)
        for _ in 0 ..< numFlips:
          let pos = rng.nextInt(0, 55)
          rec[pos] = byte(rng.nextU64() and 0xFF'u64)
      recordOutcome(parseMftRecord(rec, entry, uint64(i), 4096'u32, onlyInUse = (i and 2) != 0))
      inc(totalIters)

    # -------------------------------------------------------------------------
    # Category D: 25,000 Malformed Attributes, Huge Offsets & Boundary Placements
    # -------------------------------------------------------------------------
    const AttrTypes = [
      ATTR_STANDARD_INFORMATION, ATTR_ATTRIBUTE_LIST, ATTR_FILE_NAME,
      ATTR_DATA, ATTR_INDEX_ROOT, ATTR_END_MARKER, 0'u32, 0x12345678'u32
    ]
    const EdgeAttrLens = [0'u32, 4'u32, 15'u32, 16'u32, 20'u32, 24'u32, 40'u32, 48'u32, 56'u32, 128'u32, 1024'u32, 0xFFFF_FFFF'u32]

    for i in 0 ..< 25_000:
      var rec = if (i and 1) == 0: baseRes else: baseNonRes
      case i mod 5
      of 0:
        # Place synthetic attribute near end of 1024-byte buffer (tests attrOffset + 48/56 boundary!)
        let attrOff = rng.nextInt(960, 1020)
        putU16(rec, 20, uint16(attrOff))
        putU32(rec, attrOff, AttrTypes[rng.nextInt(0, AttrTypes.len - 1)])
        if attrOff + 8 <= MFT_RECORD_SIZE:
          putU32(rec, attrOff + 4, EdgeAttrLens[rng.nextInt(0, EdgeAttrLens.len - 1)])
        if attrOff + 10 <= MFT_RECORD_SIZE:
          rec[attrOff + 8] = byte(rng.nextInt(0, 1))
          rec[attrOff + 9] = byte(rng.nextInt(0, 4))
        applyValidCheckWords(rec, 0xA55A'u16)
      of 1:
        # Corrupt resident $FILE_NAME lengths, valOff, charCount, UTF-16LE surrogates
        let off = 56 + 72 # $FILE_NAME offset in template
        putU32(rec, off + 4, EdgeAttrLens[rng.nextInt(0, EdgeAttrLens.len - 1)])
        putU32(rec, off + 16, uint32(rng.nextU64() and 0xFFFF_FFFF'u64)) # huge valLen
        putU16(rec, off + 20, uint16(rng.nextInt(0, 1200)))              # huge valOff
        rec[off + 24 + 64] = byte(rng.nextInt(0, 255))                   # charCount
        rec[off + 24 + 65] = byte(rng.nextInt(0, 255))                   # namespace
        for k in 0 ..< 16:
          rec[off + 24 + 66 + k] = byte(rng.nextU64() and 0xFF'u64)
        applyValidCheckWords(rec, 0xA55A'u16)
      of 2:
        # Corrupt non-resident $DATA headers and runlists
        let off = 56 + 72 + 120 # approximate offset; place directly at 248
        putU16(rec, 20, 248'u16)
        putU32(rec, 248, ATTR_DATA)
        putU32(rec, 252, uint32(rng.nextInt(16, 128)))
        rec[256] = 1'u8 # nonResident
        rec[257] = 0'u8
        putU16(rec, 280, uint16(rng.nextInt(0, 1200))) # runListOff
        for k in 288 ..< 360:
          rec[k] = byte(rng.nextU64() and 0xFF'u64)
        applyValidCheckWords(rec, 0xA55A'u16)
      of 3:
        # Malformed $ATTRIBUTE_LIST
        putU16(rec, 20, 56'u16)
        putU32(rec, 56, ATTR_ATTRIBUTE_LIST)
        putU32(rec, 60, uint32(rng.nextInt(16, 256)))
        rec[64] = byte(rng.nextInt(0, 1))
        putU32(rec, 72, uint32(rng.nextU64() and 0xFFFF'u64))
        putU16(rec, 76, uint16(rng.nextInt(0, 1024)))
        for k in 80 ..< 200:
          rec[k] = byte(rng.nextU64() and 0xFF'u64)
        applyValidCheckWords(rec, 0xA55A'u16)
      else:
        # Random mutations across attribute region 56..1021 while keeping valid fixups
        let numMutations = rng.nextInt(1, 24)
        for _ in 0 ..< numMutations:
          let pos = rng.nextInt(56, 1021)
          if pos != 510 and pos != 511:
            rec[pos] = byte(rng.nextU64() and 0xFF'u64)
        applyValidCheckWords(rec, 0xA55A'u16)

      recordOutcome(parseMftRecord(rec, entry, uint64(i), 4096'u32, onlyInUse = (i and 2) != 0))
      inc(totalIters)

    # -------------------------------------------------------------------------
    # Category E: 20,000 Direct Runlist & UTF-16LE Fuzzer Cases
    # -------------------------------------------------------------------------
    var decodedStr = ""
    for i in 0 ..< 20_000:
      var runBuf: array[64, byte]
      rng.fillRandomBytes(runBuf)
      if (i mod 4) == 0:
        # Stress 8-byte length/offset nibbles with max bytes (overflow + shl 64 edge cases)
        runBuf[0] = 0x88'u8
        for k in 1 .. 16:
          runBuf[k] = 0xFF'u8
        runBuf[17] = 0x88'u8
        for k in 18 .. 33:
          runBuf[k] = 0xFF'u8

      let startOff = case i mod 5
        of 0: 0
        of 1: -1
        of 2: 64
        of 3: 63
        else: rng.nextInt(0, 63)
      let maxLen = case i mod 4
        of 0: 64
        of 1: 0
        of 2: high(int)
        else: rng.nextInt(0, 128)

      discard calculateAllocatedClusters(runBuf, startOff, maxLen)
      discard parseRunList(runBuf, startOff, maxLen, runs)

      let charCnt = rng.nextInt(-2, 64)
      decodeUtf16LeFast(runBuf, startOff, charCnt, decodedStr)
      inc(totalIters)

    # Clean up reusable locals before checking ORC heap
    runs = @[]
    decodedStr = ""
    entry = MftEntry()

    doAssert totalIters == 100_000, &"Expected 100,000 fuzz iterations, ran {totalIters}"
    doAssert okTrue + okFalse + errCount == 80_000
    assertZeroOrcLeaks("MFT 100,000-iteration fuzzer", orcBefore, toleranceBytes = 4096)

    echo &"  [PASS] {totalIters} deterministic MFT fuzz cases completed with 0 panics, 0 crashes, 0 OOBs!"
    echo &"         parseMftRecord outcomes: ok(true)={okTrue}, ok(false)={okFalse}, err={errCount}"

  when isMainModule:
    runMftFuzzSuite()
else:
  when isMainModule:
    echo "[SKIP] test_fuzz_mft is Windows-specific (NTFS MFT parser)."
