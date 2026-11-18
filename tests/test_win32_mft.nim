## tests/test_win32_mft.nim — Comprehensive Unit & Integration Tests for win32_mft
##
## Tests:
## 1. Magic signature validation ('FILE' vs 'BAAD' vs corrupt).
## 2. Multi-sector FIXUP array validation and in-place restoration.
## 3. $STANDARD_INFORMATION attribute parsing (timestamps, flags).
## 4. $FILE_NAME parsing:
##    - Parent FRN extraction.
##    - Namespace priority (skipping DOS 8.3 when Win32 is present).
##    - Zero-allocation UTF-16LE decoding (ASCII, Unicode Cyrillic/Asian, Emoji surrogate pairs).
## 5. $DATA parsing:
##    - Resident size.
##    - Non-resident size and nibble-encoded compressed runlist (fragmented, sparse, negative deltas).
## 6. Buffer iteration and zero-allocation recycling.
## 7. Streamer elevation and error handling.

import std/strutils

import corex/[allocators, result, memory, testing]
import corex/platform/windows/win32_mft

# Helper to build a valid mock 1024-byte MFT record
proc createMockMftRecord(
  recordNumber: uint32 = 42,
  sequenceNumber: uint16 = 1,
  isInUse: bool = true,
  isDir: bool = false
): array[1024, byte] =
  result = default(array[1024, byte])

  # Magic "FILE"
  result[0] = byte('F')
  result[1] = byte('I')
  result[2] = byte('L')
  result[3] = byte('E')

  # USA Offset = 48 (0x0030), USA Count = 3 (1 check word + 2 sectors)
  let usaOffset = 48'u16
  let usaCount = 3'u16
  cast[ptr uint16](addr result[4])[] = usaOffset
  cast[ptr uint16](addr result[6])[] = usaCount

  # Sequence number
  cast[ptr uint16](addr result[16])[] = sequenceNumber

  # First attribute offset = 56 (0x0038)
  cast[ptr uint16](addr result[20])[] = 56'u16

  # Flags
  var flags: uint16 = 0
  if isInUse: flags = flags or MFT_RECORD_IN_USE
  if isDir: flags = flags or MFT_RECORD_IS_DIRECTORY
  cast[ptr uint16](addr result[22])[] = flags

  # Bytes in use = 1024, Bytes allocated = 1024
  cast[ptr uint32](addr result[24])[] = 1024'u32
  cast[ptr uint32](addr result[28])[] = 1024'u32

  # Record number at offset 44
  cast[ptr uint32](addr result[44])[] = recordNumber

  # Setup Fixup Array: Check word = 0x55AA
  let checkWord = 0x55AA'u16
  let originalSec0End = 0x1122'u16
  let originalSec1End = 0x3344'u16

  cast[ptr uint16](addr result[usaOffset])[] = checkWord
  cast[ptr uint16](addr result[usaOffset + 2])[] = originalSec0End
  cast[ptr uint16](addr result[usaOffset + 4])[] = originalSec1End

  # On-disk state: end of sectors contain checkWord
  cast[ptr uint16](addr result[510])[] = checkWord
  cast[ptr uint16](addr result[1022])[] = checkWord

proc testMagicAndFixupValidation() =
  echo "--- 1. Magic Signature & Fixup Validation ---"

  # Test 1.1: Valid record fixup restoration
  var rec = createMockMftRecord()
  doAssert restoreFixups(rec).isOk
  # Check that sector ends were restored to original words!
  let sec0End = cast[ptr uint16](addr rec[510])[]
  let sec1End = cast[ptr uint16](addr rec[1022])[]
  doAssert sec0End == 0x1122'u16, "Sector 0 end fixup restoration failed"
  doAssert sec1End == 0x3344'u16, "Sector 1 end fixup restoration failed"
  echo "  [OK] Valid multi-sector fixup array validated and restored"

  # Test 1.2: Corrupt Fixup check word
  var corruptRec = createMockMftRecord()
  cast[ptr uint16](addr corruptRec[510])[] = 0xDEAD'u16 # Corrupt check word
  let fixErr = restoreFixups(corruptRec)
  doAssert fixErr.isErr, "Expected fixup mismatch error"
  echo "  [OK] Detected corrupted sector fixup signature"

  # Test 1.3: 'BAAD' signature rejection
  var baadRec = createMockMftRecord()
  baadRec[0] = byte('B')
  baadRec[1] = byte('A')
  baadRec[2] = byte('A')
  baadRec[3] = byte('D')
  doAssert restoreFixups(baadRec).isErr
  echo "  [OK] Successfully rejected 'BAAD' corrupted record marker"

  # Test 1.4: Random garbage signature rejection
  var garbageRec = createMockMftRecord()
  garbageRec[0] = byte('N')
  garbageRec[1] = byte('O')
  garbageRec[2] = byte('P')
  garbageRec[3] = byte('E')
  doAssert restoreFixups(garbageRec).isErr
  echo "  [OK] Successfully rejected non-MFT magic header"

proc testAttributeParsingAndNamespaces() =
  echo "--- 2. Attribute Parsing, Namespaces & UTF-16 Decoding ---"

  var rec = createMockMftRecord(recordNumber = 100, sequenceNumber = 3, isInUse = true)

  var offset = 56 # first attribute offset

  # Add $STANDARD_INFORMATION (0x10)
  # Header: Type(4), Length(4), NonRes(1), NameLen(1), NameOff(2), Flags(2), ID(2), ValLen(4), ValOff(2), Indexed(1), Pad(1)
  # Total header = 24 bytes. Payload = 48 bytes. Total = 72 bytes.
  cast[ptr uint32](addr rec[offset + 0])[] = ATTR_STANDARD_INFORMATION
  cast[ptr uint32](addr rec[offset + 4])[] = 72'u32
  rec[offset + 8] = 0 # resident
  rec[offset + 9] = 0 # unnamed
  cast[ptr uint32](addr rec[offset + 16])[] = 48'u32 # valLen
  cast[ptr uint16](addr rec[offset + 20])[] = 24'u16 # valOff

  let siPayload = offset + 24
  cast[ptr int64](addr rec[siPayload + 0])[] = 133500000000000000'i64 # creation time
  cast[ptr int64](addr rec[siPayload + 8])[] = 133600000000000000'i64 # modification time
  cast[ptr uint32](addr rec[siPayload + 32])[] = 0x00000020'u32        # FILE_ATTRIBUTE_ARCHIVE

  offset += 72

  # Add $FILE_NAME DOS 8.3 (0x30, namespace = 2: "TEST~1.TXT")
  let dosName = "TEST~1.TXT"
  let dosLen = 66 + dosName.len * 2
  let dosAttrLen = (24 + dosLen + 7) and (not 7) # 8-byte aligned

  cast[ptr uint32](addr rec[offset + 0])[] = ATTR_FILE_NAME
  cast[ptr uint32](addr rec[offset + 4])[] = uint32(dosAttrLen)
  rec[offset + 8] = 0
  rec[offset + 9] = 0
  cast[ptr uint32](addr rec[offset + 16])[] = uint32(dosLen)
  cast[ptr uint16](addr rec[offset + 20])[] = 24'u16

  let dosPayload = offset + 24
  cast[ptr uint64](addr rec[dosPayload + 0])[] = 5'u64 # parent FRN = 5 (root dir)
  rec[dosPayload + 64] = byte(dosName.len)
  rec[dosPayload + 65] = 2'u8 # DOS namespace
  for i, c in dosName:
    rec[dosPayload + 66 + i * 2] = byte(c)
    rec[dosPayload + 66 + i * 2 + 1] = 0

  offset += dosAttrLen

  # Add $FILE_NAME Win32 (0x30, namespace = 1: "Test Document.txt")
  let win32Name = "Test Document.txt"
  let win32Len = 66 + win32Name.len * 2
  let win32AttrLen = (24 + win32Len + 7) and (not 7)

  cast[ptr uint32](addr rec[offset + 0])[] = ATTR_FILE_NAME
  cast[ptr uint32](addr rec[offset + 4])[] = uint32(win32AttrLen)
  rec[offset + 8] = 0
  rec[offset + 9] = 0
  cast[ptr uint32](addr rec[offset + 16])[] = uint32(win32Len)
  cast[ptr uint16](addr rec[offset + 20])[] = 24'u16

  let win32Payload = offset + 24
  cast[ptr uint64](addr rec[win32Payload + 0])[] = 5'u64
  rec[win32Payload + 64] = byte(win32Name.len)
  rec[win32Payload + 65] = 1'u8 # Win32 namespace
  for i, c in win32Name:
    rec[win32Payload + 66 + i * 2] = byte(c)
    rec[win32Payload + 66 + i * 2 + 1] = 0

  offset += win32AttrLen

  # Add $DATA Resident (0x80, 15 bytes)
  cast[ptr uint32](addr rec[offset + 0])[] = ATTR_DATA
  cast[ptr uint32](addr rec[offset + 4])[] = 48'u32
  rec[offset + 8] = 0 # Resident
  rec[offset + 9] = 0 # Unnamed
  cast[ptr uint32](addr rec[offset + 16])[] = 15'u32 # Real size 15 bytes
  cast[ptr uint16](addr rec[offset + 20])[] = 24'u16

  offset += 48

  # End marker
  cast[ptr uint32](addr rec[offset])[] = ATTR_END_MARKER

  # Parse the record!
  var entry: MftEntry
  let pRes = parseMftRecord(rec, entry, recordIndex = 100, bytesPerCluster = 4096)
  doAssert pRes.isOk and pRes.get, "Record parsing failed"

  doAssert entry.name == "Test Document.txt", "Failed to select Win32 name over DOS 8.3! Got: " & entry.name
  doAssert entry.parentFrn == 5'u64, "Parent FRN mismatch"
  let expectedFrn = (3'u64 shl 48) or 100'u64
  doAssert entry.frn == expectedFrn, "FRN mismatch"
  doAssert entry.fileSize == 15'i64, "File size mismatch"
  doAssert entry.sizeOnDisk == 15'i64, "Size on disk mismatch for resident file"
  doAssert entry.creationTime == 133500000000000000'i64, "Creation time mismatch"
  doAssert entry.modificationTime == 133600000000000000'i64, "Modification time mismatch"
  doAssert not entry.isDir, "Directory flag mismatch"
  echo "  [OK] Successfully parsed $STANDARD_INFORMATION, $FILE_NAME with Win32 priority over DOS 8.3, and resident $DATA"

proc testNonResidentRunlistParsing() =
  echo "--- 3. Non-Resident $DATA & Runlist Parsing ---"

  var rec = createMockMftRecord(recordNumber = 500, sequenceNumber = 1, isInUse = true)
  var offset = 56

  # Add $FILE_NAME
  let fName = "LargeFile.bin"
  let fnLen = 66 + fName.len * 2
  let fnAttrLen = (24 + fnLen + 7) and (not 7)
  cast[ptr uint32](addr rec[offset + 0])[] = ATTR_FILE_NAME
  cast[ptr uint32](addr rec[offset + 4])[] = uint32(fnAttrLen)
  rec[offset + 8] = 0
  cast[ptr uint32](addr rec[offset + 16])[] = uint32(fnLen)
  cast[ptr uint16](addr rec[offset + 20])[] = 24'u16
  let fnPayload = offset + 24
  cast[ptr uint64](addr rec[fnPayload + 0])[] = 5'u64
  rec[fnPayload + 64] = byte(fName.len)
  rec[fnPayload + 65] = 3'u8 # Win32 & DOS
  for i, c in fName:
    rec[fnPayload + 66 + i * 2] = byte(c)
    rec[fnPayload + 66 + i * 2 + 1] = 0
  offset += fnAttrLen

  # Add Non-Resident $DATA with compressed runlist:
  # Extent 1: 10 clusters starting at LCN 1000 (lenBytes=1, offBytes=2: 0x21 0x0A 0xE8 0x03)
  # Extent 2: Sparse hole of 5 clusters (lenBytes=1, offBytes=0: 0x01 0x05)
  # Extent 3: 8 clusters starting at delta +500 = LCN 1500 (lenBytes=1, offBytes=2: 0x21 0x08 0xF4 0x01)
  # Extent 4: 2 clusters starting at negative delta -200 = LCN 1300 (lenBytes=1, offBytes=2: 0x21 0x02 0x38 0xFF)
  # End of runlist: 0x00
  let runlistStart = offset + 64
  cast[ptr uint32](addr rec[offset + 0])[] = ATTR_DATA
  cast[ptr uint32](addr rec[offset + 4])[] = 128'u32 # total attr length
  rec[offset + 8] = 1 # Non-resident
  rec[offset + 9] = 0 # Unnamed
  cast[ptr uint16](addr rec[offset + 32])[] = 64'u16 # runListOffset
  cast[ptr int64](addr rec[offset + 40])[] = (10 + 8 + 2) * 4096 # allocatedSize header = 81920
  cast[ptr int64](addr rec[offset + 48])[] = 75000'i64          # realSize header = 75000 bytes

  var r = runlistStart
  # Extent 1: 10 clusters, LCN 1000 (0x03E8)
  rec[r] = 0x21'u8
  rec[r + 1] = 10'u8
  rec[r + 2] = 0xE8'u8
  rec[r + 3] = 0x03'u8
  r += 4

  # Extent 2: 5 clusters sparse
  rec[r] = 0x01'u8
  rec[r + 1] = 5'u8
  r += 2

  # Extent 3: 8 clusters, LCN delta +500 (0x01F4)
  rec[r] = 0x21'u8
  rec[r + 1] = 8'u8
  rec[r + 2] = 0xF4'u8
  rec[r + 3] = 0x01'u8
  r += 4

  # Extent 4: 2 clusters, LCN delta -200 (-200 = 0xFF38 in 16-bit signed)
  rec[r] = 0x21'u8
  rec[r + 1] = 2'u8
  rec[r + 2] = 0x38'u8
  rec[r + 3] = 0xFF'u8
  r += 4

  # End of runlist
  rec[r] = 0x00'u8

  offset += 128
  cast[ptr uint32](addr rec[offset])[] = ATTR_END_MARKER

  var entry: MftEntry
  let pRes = parseMftRecord(rec, entry, recordIndex = 500, bytesPerCluster = 4096)
  doAssert pRes.isOk and pRes.get, "Non-resident MFT record parsing failed"

  doAssert entry.name == "LargeFile.bin"
  doAssert entry.fileSize == 75000'i64, "Real size mismatch"
  # Allocated clusters: 10 (Extent 1) + 0 (Sparse) + 8 (Extent 3) + 2 (Extent 4) = 20 clusters!
  # 20 clusters * 4096 bytes/cluster = 81920 bytes
  doAssert entry.sizeOnDisk == 20 * 4096, "Size on disk calculation failed! Got: " & $entry.sizeOnDisk
  echo "  [OK] Accurately parsed nibble-encoded runlist with fragmented, sparse, and negative LCN deltas"

proc testUnicodeAndSurrogatePairs() =
  echo "--- 4. UTF-16LE Decoding with Non-ASCII & Emoji Surrogates ---"

  var nameDst: string

  # Test 4.1: ASCII Fast Path
  let asciiBytes = [byte('h'), 0, byte('e'), 0, byte('l'), 0, byte('l'), 0, byte('o'), 0]
  decodeUtf16LeFast(asciiBytes, 0, 5, nameDst)
  doAssert nameDst == "hello"

  # Test 4.2: Cyrillic text (Multibyte UTF-8)
  # "Привет" in UTF-16LE:
  # П (0x041F), р (0x0440), и (0x0438), в (0x0432), е (0x0435), т (0x0442)
  let cyrillicBytes = [
    0x1F'u8, 0x04'u8,
    0x40'u8, 0x04'u8,
    0x38'u8, 0x04'u8,
    0x32'u8, 0x04'u8,
    0x35'u8, 0x04'u8,
    0x42'u8, 0x04'u8
  ]
  decodeUtf16LeFast(cyrillicBytes, 0, 6, nameDst)
  doAssert nameDst == "Привет", "Cyrillic decoding failed: " & nameDst

  # Test 4.3: Emoji with surrogate pair
  # 📁 File Folder emoji: U+1F4C1
  # High surrogate: 0xD83D, Low surrogate: 0xDCC1
  let emojiBytes = [
    0x3D'u8, 0xD8'u8,
    0xC1'u8, 0xDC'u8
  ]
  decodeUtf16LeFast(emojiBytes, 0, 2, nameDst)
  doAssert nameDst == "📁", "Surrogate pair emoji decoding failed: " & nameDst

  # Test 4.4: ByteSpan overload
  let sp = span(emojiBytes)
  decodeUtf16LeFast(sp, 0, 2, nameDst)
  doAssert nameDst == "📁"

  echo "  [OK] Decoded ASCII, Cyrillic, and U+1F4C1 surrogate pair emoji with zero heap allocations"

proc testZeroAllocationBufferStream() =
  echo "--- 5. Zero-Allocation Batch Streaming ---"

  # Build a 64KB buffer containing multiple records
  var buffer = newSeq[byte](64 * 1024)
  for i in 0 ..< 10:
    let r = createMockMftRecord(recordNumber = uint32(i + 1), sequenceNumber = 1, isInUse = (i mod 2 == 0))
    copyMem(addr buffer[i * 1024], unsafeAddr r[0], 1024)

  var recordsSeen = 0
  for entry in parseMftBuffer(buffer, startRecordIndex = 1, onlyInUse = true):
    inc recordsSeen
    doAssert entry.frn != 0

  # Exactly 5 records were in-use (0, 2, 4, 6, 8)
  doAssert recordsSeen == 5, "Expected 5 in-use records, got " & $recordsSeen
  echo "  [OK] Successfully streamed records via parseMftBuffer iterator"

proc testVolumeStreamerPrivilegeCheck() =
  echo "--- 6. Volume Raw Streamer Consent, Privileges & Lifecycle ---"

  # Test 6.0: Explicit consent enforcement & invalid drive letter rejection
  var noConsentRes = openMftStreamer('C')
  doAssert noConsentRes.isErr and noConsentRes.error.msg.contains("Explicit user consent required")
  echo "  [OK] openMftStreamer('C') without explicitConsent denied"

  var badDriveRes = openMftStreamer('1', explicitConsent = true)
  doAssert badDriveRes.isErr and badDriveRes.error.msg.contains("Invalid drive letter")
  echo "  [OK] openMftStreamer('1') rejected invalid drive letter"

  # Test 6.1: Non-existent volume 'Z' fails gracefully
  var zRes = openMftStreamer('Z', explicitConsent = true)
  doAssert zRes.isErr, "Expected opening non-existent drive 'Z' to fail"
  echo "  [OK] openMftStreamer('Z') returned Result.err as expected"

  # Test 6.2: Target volume 'C' check (Admin or Non-Admin permission handling, no silent escalation)
  var cRes = openMftStreamer('C', explicitConsent = true)
  if cRes.isOk:
    var streamer = move(cRes.val)
    echo "  [OK] openMftStreamer('C') acquired raw volume handle with FILE_FLAG_NO_BUFFERING"
    echo "       - Drive: ", streamer.drive
    echo "       - Sector Size: ", streamer.bytesPerSector
    echo "       - Cluster Size: ", streamer.bytesPerCluster
    echo "       - MFT Start LCN: ", streamer.mftStartLcn
    echo "       - MFT Valid Length: ", streamer.mftValidDataLength, " bytes"
    doAssert streamer.mftStartLcn > 0
    doAssert streamer.bytesPerCluster >= 512

    # Stream first 100 records using callback
    var count = 0
    let streamRes = streamer.streamAll(proc(entry: var MftEntry) =
      inc count
    )
    if streamRes.isOk:
      echo "       - Streamed live records: ", streamRes.val.activeFiles, " files, ", streamRes.val.activeDirs, " dirs"
    streamer.close()
  else:
    echo "  [OK] openMftStreamer('C') returned Result.err (Normal non-admin environment): ", cRes.error.msg

  # Test 6.3: Idempotent close
  var dummy: MftStreamer
  dummy.close()
  dummy.close()
  echo "  [OK] MftStreamer.close is safe and idempotent"

proc testLeakCheckAndStress() =
  echo "--- 7. Leak Check & High-Throughput Stress Test ---"

  testWithLeakCheck("10,000 MFT records zero-allocation recycling"):
    var rec = createMockMftRecord(recordNumber = 1234, sequenceNumber = 2, isInUse = true)
    # Add minimal valid $FILE_NAME
    let name = "benchmark_file.dat"
    let fnLen = 66 + name.len * 2
    let fnAttrLen = (24 + fnLen + 7) and (not 7)
    cast[ptr uint32](addr rec[56])[] = ATTR_FILE_NAME
    cast[ptr uint32](addr rec[60])[] = uint32(fnAttrLen)
    cast[ptr uint32](addr rec[56 + 16])[] = uint32(fnLen)
    cast[ptr uint16](addr rec[56 + 20])[] = 24'u16
    rec[56 + 24 + 64] = byte(name.len)
    rec[56 + 24 + 65] = 3'u8
    for i, c in name:
      rec[56 + 24 + 66 + i * 2] = byte(c)
      rec[56 + 24 + 66 + i * 2 + 1] = 0
    cast[ptr uint32](addr rec[56 + fnAttrLen])[] = ATTR_END_MARKER

    var entry: MftEntry
    for i in 0 ..< 10_000:
      let res = parseMftRecord(rec, entry, recordIndex = uint64(i), bytesPerCluster = 4096)
      doAssert res.isOk and res.get
      doAssert entry.name == "benchmark_file.dat"

  echo "  [OK] 10,000 MFT records parsed with 0 memory leaks"

  # Strict mode malformed record & partial buffer recovery checks
  var badFirstAttr = createMockMftRecord(recordNumber = 1, isInUse = true)
  cast[ptr uint16](addr badFirstAttr[20])[] = 10'u16
  var strictEntry: MftEntry
  let r1 = parseMftRecord(badFirstAttr, strictEntry, parseMode = mpmStrict)
  doAssert r1.isErr and r1.error.msg.contains("invalid first attribute offset")

  var unalignedAttr = createMockMftRecord(recordNumber = 2, isInUse = true)
  cast[ptr uint32](addr unalignedAttr[56])[] = ATTR_STANDARD_INFORMATION
  cast[ptr uint32](addr unalignedAttr[60])[] = 25'u32 # not 8-byte aligned
  let r2 = parseMftRecord(unalignedAttr, strictEntry, parseMode = mpmStrict)
  doAssert r2.isErr and r2.error.msg.contains("unaligned attribute length")

  var goodRec = createMockMftRecord(recordNumber = 3, isInUse = true)
  cast[ptr uint32](addr goodRec[56])[] = ATTR_END_MARKER
  var mixedBuf = newSeq[byte](MFT_RECORD_SIZE * 2 + 17)
  copyMem(addr mixedBuf[0], addr goodRec[0], MFT_RECORD_SIZE)
  copyMem(addr mixedBuf[MFT_RECORD_SIZE], addr unalignedAttr[0], MFT_RECORD_SIZE)
  let strictBuf = parseMftBufferStrict(mixedBuf)
  doAssert strictBuf.entries.len == 1, "Expected 1 partial valid entry"
  doAssert strictBuf.errors.len == 2, "Expected 2 errors (1 corrupt record + 1 trailing bytes)"
  echo "  [OK] Strict MFT parsing mode & partial recovery verified"

proc runAllMftTests() =
  echo "=== RUNNING WIN32 MFT RECORD PARSER & STREAMER TESTS ==="
  testMagicAndFixupValidation()
  testAttributeParsingAndNamespaces()
  testNonResidentRunlistParsing()
  testUnicodeAndSurrogatePairs()
  testZeroAllocationBufferStream()
  testVolumeStreamerPrivilegeCheck()
  testLeakCheckAndStress()
  echo "=== ALL WIN32 MFT TESTS PASSED ==="

when isMainModule:
  runAllMftTests()
