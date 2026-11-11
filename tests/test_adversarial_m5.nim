import corex
import std/options

proc runAdversarialTests() =
  echo "--- 1. Testing lines longer than 64KB in BufferedReader ---"
  block:
    let testPath = "adv_longline.tmp"
    let longLen = 150 * 1024 # 150 KB line
    var longStr = newString(longLen)
    for i in 0 ..< longLen:
      longStr[i] = char(byte('a') + byte(i mod 26))
    
    # Write line to file
    var fh = openFile(testPath, fmWrite).unwrap()
    discard fh.write(longStr & "\n")
    discard fh.close()

    # Read back via BufferedReader
    var br = openBufferedReader(testPath).unwrap()
    var lineRead = ""
    let okRead = br.readLine(lineRead).unwrap()
    doAssert okRead, "readLine failed on 150KB line"
    doAssert lineRead.len == longLen, "Length mismatch: expected " & $longLen & ", got " & $lineRead.len
    doAssert lineRead == longStr, "Content mismatch on 150KB line"
    discard br.close()
    echo "  [PASS] 150KB single line handled correctly across multiple buffer fills"

  echo "--- 2. Testing UTF-16 surrogate pairs and international text ---"
  block:
    # Test UTF-16 with emoji and multi-byte unicode
    # "Hello 🌍 World" in UTF-16
    # 'H','e','l','l','o',' ' (ASCII)
    # Earth globe emoji 🌍 = U+1F30F -> UTF-16 surrogate pair 0xD83C, 0xDF0F
    # ' ','W','o','r','l','d' (ASCII)
    var u16Data: array[15, uint16] = [
      uint16('H'), uint16('e'), uint16('l'), uint16('l'), uint16('o'), uint16(' '),
      0xD83C'u16, 0xDF0F'u16,
      uint16(' '), uint16('W'), uint16('o'), uint16('r'), uint16('l'), uint16('d'),
      0'u16
    ]
    var resStr: string
    utf16ToUtf8Fast(cast[ptr UncheckedArray[uint16]](addr u16Data[0]), resStr)
    echo "  Transcoded result: '", resStr, "'"
    doAssert resStr == "Hello 🌏 World", "Transcoding mismatch: " & resStr
    echo "  [PASS] Multi-byte surrogate pair transcoded correctly"

  echo "--- 3. Testing dot skipping edge cases ---"
  block:
    # Test "."
    var dot1: array[2, uint16] = [uint16('.'), 0'u16]
    doAssert isDotOrDotDot(cast[ptr UncheckedArray[uint16]](addr dot1[0])) == true
    # Test ".."
    var dot2: array[3, uint16] = [uint16('.'), uint16('.'), 0'u16]
    doAssert isDotOrDotDot(cast[ptr UncheckedArray[uint16]](addr dot2[0])) == true
    # Test ".git"
    var dot3: array[5, uint16] = [uint16('.'), uint16('g'), uint16('i'), uint16('t'), 0'u16]
    doAssert isDotOrDotDot(cast[ptr UncheckedArray[uint16]](addr dot3[0])) == false
    # Test "..."
    var dot4: array[4, uint16] = [uint16('.'), uint16('.'), uint16('.'), 0'u16]
    doAssert isDotOrDotDot(cast[ptr UncheckedArray[uint16]](addr dot4[0])) == false
    # Test "a"
    var notDot: array[2, uint16] = [uint16('a'), 0'u16]
    doAssert isDotOrDotDot(cast[ptr UncheckedArray[uint16]](addr notDot[0])) == false
    echo "  [PASS] Dot skipping handles '.', '..', '.git', '...' correctly"

  echo "--- 4. Testing 48-bit mftIndex edge cases ---"
  block:
    # 48-bit mask: 0x0000FFFFFFFFFFFF
    let max48 = 0x0000FFFFFFFFFFFF'u64
    let seq = 0xABCD'u16
    let frn = (uint64(seq) shl 48) or max48
    doAssert mftIndex(frn) == max48
    doAssert sequenceNumber(frn) == seq
    echo "  [PASS] 48-bit mftIndex extraction accurate up to 2^48 - 1"

  echo "--- 5. Testing calculateSizeOnDisk edge cases ---"
  block:
    doAssert calculateSizeOnDisk(0, 4096) == 0
    doAssert calculateSizeOnDisk(-100, 4096) == 0
    doAssert calculateSizeOnDisk(100, 0) == 100
    doAssert calculateSizeOnDisk(100, -512) == 100
    doAssert calculateSizeOnDisk(4096, 4096) == 4096
    doAssert calculateSizeOnDisk(4097, 4096) == 8192
    echo "  [PASS] calculateSizeOnDisk edge cases verified"

  # Cleanup
  when defined(windows):
    proc winDeleteFileW(lpFileName: WideCString): int32 {.importc: "DeleteFileW", header: "<windows.h>", stdcall.}
    discard winDeleteFileW(newWideCString("adv_longline.tmp"))

runAdversarialTests()
echo "=== ALL ADVERSARIAL STRESS TESTS PASSED ==="
