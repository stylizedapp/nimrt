import std/[os, strformat, times]
import corex/io
import corex/result
import corex/allocators
import corex/testing
import corex/memory

const TestTmpDir = "temp_stress_io"

proc setupTmp() =
  if dirExists(TestTmpDir):
    removeDir(TestTmpDir)
  createDir(TestTmpDir)

proc cleanupTmp() =
  if dirExists(TestTmpDir):
    try:
      removeDir(TestTmpDir)
    except CatchableError:
      discard

# -----------------------------------------------------------------------------
# Test 1: FileHandle Lifecycle & Edge Cases
# -----------------------------------------------------------------------------
proc testFileHandleLifecycle() =
  echo "[1.1] Testing Double Close Idempotency..."
  let path1 = TestTmpDir / "test_double_close.bin"
  var f1Res = openFile(path1, fmWrite)
  doAssert f1Res.isOk, "openFile failed: " & $f1Res.unwrapErr
  var f1 = f1Res.get
  doAssert f1.isOpen

  let w1 = f1.write("test data")
  doAssert w1.isOk and w1.get == 9

  let c1 = f1.close()
  doAssert c1.isOk, "First close failed: " & $c1.unwrapErr
  doAssert not f1.isOpen

  # Second close must be idempotent (return ok with no crash)
  let c2 = f1.close()
  doAssert c2.isOk, "Second close failed: " & $c2.unwrapErr
  doAssert not f1.isOpen

  # Third close
  let c3 = f1.close()
  doAssert c3.isOk, "Third close failed: " & $c3.unwrapErr

  echo "  -> Double and triple close succeeded idempotently."

  echo "[1.2] Testing Moved-out Handle Safety..."
  let path2 = TestTmpDir / "test_move_safety.bin"
  var f2Res = openFile(path2, fmWrite)
  doAssert f2Res.isOk
  var f2 = f2Res.get

  var f2Moved = move(f2)
  doAssert not f2.isOpen, "f2 should not be open after move"
  doAssert f2Moved.isOpen, "f2Moved should be open"

  # Operations on moved-out handle must return IOError and not crash
  var dummyBuf: array[16, byte]
  let writeOnMoved = f2.write("crash?")
  doAssert writeOnMoved.isErr, "Write on moved handle should fail"

  let readOnMoved = f2.read(dummyBuf)
  doAssert readOnMoved.isErr, "Read on moved handle should fail"

  let seekOnMoved = f2.seek(0, soBegin)
  doAssert seekOnMoved.isErr, "Seek on moved handle should fail"

  let flushOnMoved = f2.flush()
  doAssert flushOnMoved.isErr, "Flush on moved handle should fail"

  let closeOnMoved = f2.close()
  doAssert closeOnMoved.isOk, "Close on moved handle should be ok (no-op)"

  # Operations on recipient f2Moved must work normally
  let writeRecipient = f2Moved.write("active content")
  doAssert writeRecipient.isOk and writeRecipient.get == 14
  let closeRecipient = f2Moved.close()
  doAssert closeRecipient.isOk

  echo "  -> Moved-out handle safety verified."

  echo "[1.3] Testing Seek past EOF and Negative Offsets..."
  let path3 = TestTmpDir / "test_seek.bin"
  var f3Res = openFile(path3, fmWrite)
  doAssert f3Res.isOk
  var f3 = f3Res.get
  discard f3.write("0123456789") # 10 bytes
  discard f3.close()

  # Re-open in read mode
  var f3ReadRes = openFile(path3, fmRead)
  doAssert f3ReadRes.isOk
  var f3Read = f3ReadRes.get

  # Seek past EOF
  let seekPastEof = f3Read.seek(100, soBegin)
  doAssert seekPastEof.isOk, "Seeking past EOF should succeed at OS level: " & $seekPastEof.unwrapErr
  doAssert seekPastEof.get == 100

  # Read at position past EOF should return 0 bytes (EOF)
  var readBuf: array[10, byte]
  let readPastEof = f3Read.read(readBuf)
  doAssert readPastEof.isOk and readPastEof.get == 0, "Read past EOF should return 0 bytes"

  # Negative offset from soBegin must fail
  let seekNegBegin = f3Read.seek(-5, soBegin)
  doAssert seekNegBegin.isErr, "Seeking negative offset from soBegin must fail"

  # Seek from soEnd
  let seekEndBack = f3Read.seek(-3, soEnd)
  doAssert seekEndBack.isOk, "Seek from soEnd with negative offset should succeed: " & $seekEndBack.unwrapErr
  doAssert seekEndBack.get == 7 # 10 - 3 = 7

  let readAt7 = f3Read.read(readBuf)
  doAssert readAt7.isOk and readAt7.get == 3
  doAssert cast[string](readBuf[0..2]) == "789"

  # Negative seek before beginning of file from soEnd
  let seekNegBeforeStart = f3Read.seek(-50, soEnd)
  doAssert seekNegBeforeStart.isErr, "Seek before start of file must fail"

  # Seek from soCurrent
  discard f3Read.seek(5, soBegin)
  let seekCurFwd = f3Read.seek(3, soCurrent)
  doAssert seekCurFwd.isOk and seekCurFwd.get == 8
  let seekCurBack = f3Read.seek(-4, soCurrent)
  doAssert seekCurBack.isOk and seekCurBack.get == 4
  let seekCurNegInvalid = f3Read.seek(-10, soCurrent)
  doAssert seekCurNegInvalid.isErr, "Negative seek before file start from current pos must fail"

  discard f3Read.close()
  echo "  -> Seek boundary conditions passed."

# -----------------------------------------------------------------------------
# Test 2: BufferedWriter Boundary Conditions
# -----------------------------------------------------------------------------
proc testBufferedWriterBoundaries() =
  echo "[2.1] Saturation Auto-Flush Right at Boundary..."

  # Case 2.1.1: Exactly 65,535 bytes (capacity - 1)
  let p65535 = TestTmpDir / "bw_65535.bin"
  var bwRes1 = openBufferedWriter(p65535, fmWrite)
  doAssert bwRes1.isOk
  var bw1 = bwRes1.get
  var data65535 = newSeq[byte](65535)
  for i in 0 ..< 65535: data65535[i] = byte(i mod 251)
  let wres1 = bw1.writeBytes(data65535)
  doAssert wres1.isOk and wres1.get == 65535
  # Before flush, buffer has not wrapped or saturated to disk
  doAssert bw1.tail == 65535
  let fRes1 = bw1.flush()
  doAssert fRes1.isOk
  doAssert bw1.tail == 0
  discard bw1.close()
  doAssert getFileSize(p65535) == 65535

  # Verify content
  var check1 = readFile(p65535)
  doAssert check1.len == 65535
  for i in 0 ..< 65535:
    doAssert byte(check1[i]) == byte(i mod 251)

  # Case 2.1.2: Exactly 65,536 bytes (exact capacity single write -> triggers direct kernel bypass)
  let p65536 = TestTmpDir / "bw_65536.bin"
  var bwRes2 = openBufferedWriter(p65536, fmWrite)
  doAssert bwRes2.isOk
  var bw2 = bwRes2.get
  var data65536 = newSeq[byte](65536)
  for i in 0 ..< 65536: data65536[i] = byte((i + 13) mod 251)
  let wres2 = bw2.writeBytes(data65536)
  doAssert wres2.isOk and wres2.get == 65536
  doAssert bw2.tail == 0, "Direct kernel bypass should leave tail at 0"
  discard bw2.close()
  doAssert getFileSize(p65536) == 65536
  var check2 = readFile(p65536)
  doAssert check2.len == 65536
  for i in 0 ..< 65536:
    doAssert byte(check2[i]) == byte((i + 13) mod 251)

  # Case 2.1.3: Incremental saturation (65535 bytes + 1 byte + 1 byte)
  let p65537_inc = TestTmpDir / "bw_65537_inc.bin"
  var bwRes3 = openBufferedWriter(p65537_inc, fmWrite)
  doAssert bwRes3.isOk
  var bw3 = bwRes3.get
  # Write 65535 bytes
  discard bw3.writeBytes(data65535)
  doAssert bw3.tail == 65535
  # Write 1 byte -> buffer is completely full (tail == 65536)
  let oneByte = [42'u8]
  discard bw3.writeBytes(oneByte)
  doAssert bw3.tail == 65536
  # Next 1 byte write should trigger auto-flush of the 65536 bytes and buffer the new byte
  let nextByte = [99'u8]
  discard bw3.writeBytes(nextByte)
  doAssert bw3.tail == 1
  # Close will flush the remaining 1 byte
  discard bw3.close()
  doAssert getFileSize(p65537_inc) == 65537
  var check3 = readFile(p65537_inc)
  doAssert check3.len == 65537
  for i in 0 ..< 65535:
    doAssert byte(check3[i]) == byte(i mod 251)
  doAssert byte(check3[65535]) == 42'u8
  doAssert byte(check3[65536]) == 99'u8

  # Case 2.1.4: Exactly 65,537 bytes single write (direct write kernel bypass)
  let p65537_dir = TestTmpDir / "bw_65537_dir.bin"
  var bwRes4 = openBufferedWriter(p65537_dir, fmWrite)
  doAssert bwRes4.isOk
  var bw4 = bwRes4.get
  var data65537 = newSeq[byte](65537)
  for i in 0 ..< 65537: data65537[i] = byte((i * 7) mod 251)
  let wres4 = bw4.writeBytes(data65537)
  doAssert wres4.isOk and wres4.get == 65537
  doAssert bw4.tail == 0
  discard bw4.close()
  doAssert getFileSize(p65537_dir) == 65537
  var check4 = readFile(p65537_dir)
  doAssert check4.len == 65537
  for i in 0 ..< 65537:
    doAssert byte(check4[i]) == byte((i * 7) mod 251)

  echo "  -> Saturation and boundary tests (65535, 65536, 65537) passed."

  echo "[2.2] Massive Single Write (1MB & 5MB Kernel Bypass)..."
  let p1mb = TestTmpDir / "bw_1mb.bin"
  var bwRes5 = openBufferedWriter(p1mb, fmWrite)
  doAssert bwRes5.isOk
  var bw5 = bwRes5.get
  const Size1MB = 1024 * 1024
  var data1mb = newSeq[byte](Size1MB)
  for i in 0 ..< Size1MB: data1mb[i] = byte((i * 31 + 17) and 0xFF)
  let wres5 = bw5.writeBytes(data1mb)
  doAssert wres5.isOk and wres5.get == Size1MB
  discard bw5.close()
  doAssert getFileSize(p1mb) == Size1MB
  var check5 = readFile(p1mb)
  doAssert check5.len == Size1MB
  for i in 0 ..< Size1MB:
    doAssert byte(check5[i]) == data1mb[i]

  # Massive write with dirty buffer: 10,000 bytes buffered + 1MB write + 20,000 bytes buffered
  let pMixed = TestTmpDir / "bw_mixed.bin"
  var bwRes6 = openBufferedWriter(pMixed, fmWrite)
  doAssert bwRes6.isOk
  var bw6 = bwRes6.get
  var headData = newSeq[byte](10000)
  for i in 0 ..< 10000: headData[i] = byte(i and 0xFF)
  var tailData = newSeq[byte](20000)
  for i in 0 ..< 20000: tailData[i] = byte((i + 77) and 0xFF)

  discard bw6.writeBytes(headData)
  doAssert bw6.tail == 10000
  discard bw6.writeBytes(data1mb)
  discard bw6.writeBytes(tailData)
  discard bw6.close()

  let expectedSize = 10000 + Size1MB + 20000
  doAssert getFileSize(pMixed) == expectedSize
  var check6 = readFile(pMixed)
  doAssert check6.len == expectedSize
  for i in 0 ..< 10000: doAssert byte(check6[i]) == headData[i]
  for i in 0 ..< Size1MB: doAssert byte(check6[10000 + i]) == data1mb[i]
  for i in 0 ..< 20000: doAssert byte(check6[10000 + Size1MB + i]) == tailData[i]

  echo "  -> Massive write with dirty buffer kernel bypass verified."

  echo "[2.3] Destruction Auto-Flush..."
  let pDestroy = TestTmpDir / "bw_destroy_flush.bin"
  block:
    var bwRes = openBufferedWriter(pDestroy, fmWrite)
    doAssert bwRes.isOk
    var bw = bwRes.get
    discard bw.write("Auto-flush on destruction without calling flush() explicitly!")
    # No flush() and no close()! bw goes out of scope and `=destroy` executes.
  
  doAssert fileExists(pDestroy)
  var checkDestroy = readFile(pDestroy)
  doAssert checkDestroy == "Auto-flush on destruction without calling flush() explicitly!",
    "Destruction failed to flush buffer: got '" & checkDestroy & "'"

  # Destruction with multiple chunks (130,000 bytes)
  let pDestroyLarge = TestTmpDir / "bw_destroy_large.bin"
  var data130k = newSeq[byte](130000)
  for i in 0 ..< 130000: data130k[i] = byte((i * 13) and 0xFF)
  block:
    var bwRes = openBufferedWriter(pDestroyLarge, fmWrite)
    var bw = bwRes.get
    discard bw.writeBytes(data130k)
    # Exits scope without close/flush
  
  doAssert getFileSize(pDestroyLarge) == 130000
  var checkLarge = readFile(pDestroyLarge)
  for i in 0 ..< 130000:
    doAssert byte(checkLarge[i]) == data130k[i]

  echo "  -> Destruction auto-flush verified."

# -----------------------------------------------------------------------------
# Test 3: BufferedReader Torture Tests
# -----------------------------------------------------------------------------
proc testBufferedReaderTorture() =
  echo "[3.1] File Without Trailing Newline..."
  let pNoNl = TestTmpDir / "br_no_nl.txt"
  writeFile(pNoNl, "single line with no newline at EOF")
  block:
    var brRes = openBufferedReader(pNoNl)
    doAssert brRes.isOk
    var br = brRes.get
    var line = ""
    let hasLine1 = br.readLine(line)
    doAssert hasLine1.isOk and hasLine1.get == true
    doAssert line == "single line with no newline at EOF"

    let hasLine2 = br.readLine(line)
    doAssert hasLine2.isOk and hasLine2.get == false
    doAssert br.close().isOk

  echo "  -> File without trailing newline passed."

  echo "[3.2] File with Only Newlines..."
  let pOnlyNl = TestTmpDir / "br_only_nl.txt"
  writeFile(pOnlyNl, "\n\n\n")
  block:
    var brRes = openBufferedReader(pOnlyNl)
    var br = brRes.get
    var line = ""
    for i in 1..3:
      let hasLine = br.readLine(line)
      doAssert hasLine.isOk and hasLine.get == true
      doAssert line == "", &"Expected empty line {i}, got '{line}'"
    let hasLine4 = br.readLine(line)
    doAssert hasLine4.isOk and hasLine4.get == false
    discard br.close()

  echo "  -> File with only newlines passed."

  echo "[3.3] Mixed CRLF and LF with Varied Endings..."
  let pMixedNl = TestTmpDir / "br_mixed_nl.txt"
  writeFile(pMixedNl, "alpha\r\nbeta\ngamma\r\ndelta\nomega")
  block:
    var brRes = openBufferedReader(pMixedNl)
    var br = brRes.get
    let l1 = br.readLine()
    doAssert l1.isOk and l1.get.isSome and l1.get.get == "alpha"
    let l2 = br.readLine()
    doAssert l2.isOk and l2.get.isSome and l2.get.get == "beta"
    let l3 = br.readLine()
    doAssert l3.isOk and l3.get.isSome and l3.get.get == "gamma"
    let l4 = br.readLine()
    doAssert l4.isOk and l4.get.isSome and l4.get.get == "delta"
    let l5 = br.readLine()
    doAssert l5.isOk and l5.get.isSome and l5.get.get == "omega"
    let l6 = br.readLine()
    doAssert l6.isOk and l6.get.isNone
    discard br.close()

  echo "  -> Mixed CRLF and LF passed."

  echo "[3.4] Buffer Boundary Split CRLF (\\r at 65535, \\n at 65536)..."
  let pBoundaryCrlf = TestTmpDir / "br_boundary_crlf.txt"
  # 65535 bytes of 'A', followed by \r, then \n, then "second line"
  var boundaryContent = newString(65535)
  for i in 0 ..< 65535: boundaryContent[i] = 'A'
  boundaryContent.add("\r\nsecond line\r\n")
  writeFile(pBoundaryCrlf, boundaryContent)

  block:
    var brRes = openBufferedReader(pBoundaryCrlf)
    var br = brRes.get
    var line = ""
    let res1 = br.readLine(line)
    doAssert res1.isOk and res1.get == true
    doAssert line.len == 65535, &"Expected line 1 len 65535, got {line.len}"
    doAssert line[^1] == 'A', "Line 1 should not have trailing \\r"

    let res2 = br.readLine(line)
    doAssert res2.isOk and res2.get == true
    doAssert line == "second line"

    let res3 = br.readLine(line)
    doAssert res3.isOk and res3.get == false
    discard br.close()

  echo "  -> Buffer boundary split CRLF passed."

  echo "[3.5] Massive Single Line (> 100KB, Exceeding 64KB Buffer)..."
  let pMassiveLine = TestTmpDir / "br_massive_line.txt"
  const MassiveLen = 150_000
  var massiveContent = newString(MassiveLen)
  for i in 0 ..< MassiveLen: massiveContent[i] = chr(ord('0') + (i mod 10))
  massiveContent.add("\n")
  massiveContent.add("trailer\n")
  writeFile(pMassiveLine, massiveContent)

  block:
    var brRes = openBufferedReader(pMassiveLine)
    var br = brRes.get
    var line = ""
    let h1 = br.readLine(line)
    doAssert h1.isOk and h1.get == true
    doAssert line.len == MassiveLen, &"Expected line len {MassiveLen}, got {line.len}"
    for i in 0 ..< MassiveLen:
      doAssert line[i] == chr(ord('0') + (i mod 10))

    let h2 = br.readLine(line)
    doAssert h2.isOk and h2.get == true
    doAssert line == "trailer"

    let h3 = br.readLine(line)
    doAssert h3.isOk and h3.get == false
    discard br.close()

  echo "  -> Massive single line passed."

  echo "[3.6] Direct Read Bypass for Chunks >= 64KB..."
  let pDirectRead = TestTmpDir / "br_direct_read.bin"
  const TotalDirect = 250_000
  var directData = newSeq[byte](TotalDirect)
  for i in 0 ..< TotalDirect: directData[i] = byte((i * 41 + 7) and 0xFF)
  writeFile(pDirectRead, cast[string](directData))

  # Test 3.6.1: Fresh reader direct read >= 64KB
  block:
    var brRes = openBufferedReader(pDirectRead)
    var br = brRes.get
    var dest = newSeq[byte](100_000)
    let r1 = br.readBytes(dest)
    doAssert r1.isOk and r1.get == 100_000
    for i in 0 ..< 100_000:
      doAssert dest[i] == directData[i]

    var dest2 = newSeq[byte](150_000)
    let r2 = br.readBytes(dest2)
    doAssert r2.isOk and r2.get == 150_000
    for i in 0 ..< 150_000:
      doAssert dest2[i] == directData[100_000 + i]

    let r3 = br.readBytes(dest2)
    doAssert r3.isOk and r3.get == 0 # EOF
    discard br.close()

  # Test 3.6.2: Unaligned cached read followed by massive direct read
  block:
    var brRes = openBufferedReader(pDirectRead)
    var br = brRes.get
    # Read 50 bytes (this fills 64KB buffer, consumes 50)
    var small = newSeq[byte](50)
    let rSmall = br.readBytes(small)
    doAssert rSmall.isOk and rSmall.get == 50
    for i in 0 ..< 50: doAssert small[i] == directData[i]
    doAssert br.available() == 65536 - 50

    # Now request 150,000 bytes:
    # First drains remaining 65486 bytes from buffer, then remaining 84514 >= 65536 directly bypasses kernel
    var big = newSeq[byte](150_000)
    let rBig = br.readBytes(big)
    doAssert rBig.isOk and rBig.get == 150_000
    for i in 0 ..< 150_000:
      doAssert big[i] == directData[50 + i], &"Mismatch at index {i}"
    
    # Read rest
    var rest = newSeq[byte](TotalDirect - 150_050)
    let rRest = br.readBytes(rest)
    doAssert rRest.isOk and rRest.get == rest.len
    for i in 0 ..< rest.len:
      doAssert rest[i] == directData[150_050 + i]

    discard br.close()

  echo "  -> Direct read bypass and unaligned transitions verified."

  echo "[3.7] peekSpan and consume Boundary Validation..."
  block:
    var brRes = openBufferedReader(pDirectRead)
    var br = brRes.get
    
    # Initially buffer is empty, peekSpan returns empty span
    let span0 = br.peekSpan()
    doAssert span0.len == 0

    # Read 1 byte to trigger buffer fill
    var oneB: array[1, byte]
    discard br.readBytes(oneB)
    doAssert oneB[0] == directData[0]

    # Now buffer has 65535 bytes
    let span1 = br.peekSpan()
    doAssert span1.len == 65535
    doAssert span1[0] == directData[1]
    doAssert span1[100] == directData[101]

    # Test consume(10)
    br.consume(10)
    let span2 = br.peekSpan()
    doAssert span2.len == 65525
    doAssert span2[0] == directData[11]

    # Test consume with negative number (should be clamped to 0)
    br.consume(-10)
    let span3 = br.peekSpan()
    doAssert span3.len == 65525

    # Test consume beyond available (should clamp to tail, not overflow)
    br.consume(100_000)
    let span4 = br.peekSpan()
    doAssert span4.len == 0
    doAssert br.available() == 0

    discard br.close()

  echo "  -> peekSpan and consume boundary tests passed."

# -----------------------------------------------------------------------------
# Test 4: ARC/ORC Zero-Leak Validation
# -----------------------------------------------------------------------------
proc testZeroLeaks() =
  echo "[4.1] Zero-Leak Validation with TrackingAllocator..."
  testWithLeakCheck("BufferedReader and BufferedWriter Zero-Leak Lifecycle"):
    for iter in 1 .. 50:
      let testPath = TestTmpDir / &"leak_test_{iter}.bin"
      
      # 1. Scoped write with custom tracking allocator
      block:
        var fhRes = openFile(testPath, fmWrite)
        doAssert fhRes.isOk
        var bwRes = initBufferedWriter(move(fhRes.get), 65536, testAlloc)
        doAssert bwRes.isOk
        var bw = move(bwRes.get)
        
        var chunk = newSeq[byte](1000)
        for i in 0 ..< 1000: chunk[i] = byte(i mod 256)
        discard bw.writeBytes(chunk)
        # Destruction auto-flush and dealloc of buffer
      
      # 2. Scoped read with custom tracking allocator
      block:
        var fhRes = openFile(testPath, fmRead)
        doAssert fhRes.isOk
        var brRes = initBufferedReader(move(fhRes.get), 65536, testAlloc)
        doAssert brRes.isOk
        var br = move(brRes.get)
        
        var readChunk = newSeq[byte](1000)
        let n = br.readBytes(readChunk)
        doAssert n.isOk and n.get == 1000
        # Destruction dealloc of buffer

  echo "  -> 50 cycles of BufferedWriter & BufferedReader completed with 0 leaked bytes!"

# -----------------------------------------------------------------------------
# Main Runner
# -----------------------------------------------------------------------------
proc main() =
  echo "=== Running Adversarial Stress Test Suite for corex/io ==="
  setupTmp()
  try:
    testFileHandleLifecycle()
    testBufferedWriterBoundaries()
    testBufferedReaderTorture()
    testZeroLeaks()
    echo "\n=== ALL ADVERSARIAL STRESS TESTS PASSED SUCCESSFULLY! ==="
  finally:
    cleanupTmp()

main()
