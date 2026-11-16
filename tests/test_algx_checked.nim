## tests/test_algx_checked.nim
## Verifies that `algx` modules work with `-d:algxChecked` (even under `-d:release`)
## and that runtime bounds checks catch out-of-bounds access in `algx`.

import std/os
when defined(algxChecked):
  import std/[osproc, strutils]
import algx/algx

proc runNormalChecks() =
  # 1. BinaryHeap
  var h = initBinaryHeap[int](capacity = 8)
  h.push(30)
  h.push(10)
  h.push(20)
  doAssert h.pop() == 10
  doAssert h.pop() == 20
  doAssert h.pop() == 30

  # 2. FastMap
  var m = initFastMap[int, int](16)
  m[42] = 100
  doAssert m[42] == 100

  # 3. UltraSort
  var arr = @[5'i64, 1, 4, 2, 3]
  var aux = newSeq[int64](arr.len)
  discard ultraSort(arr, aux)
  doAssert arr == @[1'i64, 2, 3, 4, 5]

  # 4. ZeroPack
  let packed = packBin(12345'i32)
  var off = 0
  var unpacked: int32
  readBin(packed, off, unpacked)
  doAssert unpacked == 12345'i32

  # 5. SimdScan
  doAssert fastSum(arr) == 15'i64

proc triggerOob() =
  var emptyBuf: seq[byte] = @[]
  var off = 10
  var val: int32
  readBin(emptyBuf, off, val)

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--trigger-oob":
    triggerOob()
  else:
    runNormalChecks()
    when defined(algxChecked):
      let (outp, code) = execCmdEx(quoteShell(getAppFilename()) & " --trigger-oob")
      doAssert code != 0, "Expected out-of-bounds access to fail under -d:algxChecked"
      doAssert ("IndexDefect" in outp) or ("out of bounds" in outp) or ("index" in outp.toLowerAscii()),
        "Expected IndexDefect/out-of-bounds panic, got: " & outp
      echo "[test_algx_checked] Verified OOB access caught at runtime under -d:algxChecked."
    echo "[test_algx_checked] ALL CHECKS PASSED"
