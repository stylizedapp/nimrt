## tests/test_leak_check.nim — Negative & positive verification of corex/testing leak detectors

import std/[os, osproc, strutils]
import ../src/corex/corex

type
  OrcLeakNode = ref object
    payload: array[4096, byte]

var gPinnedLeaks: seq[OrcLeakNode]

proc runChildTrigger(flag: string) =
  if flag == "--trigger-alloc-leak":
    testWithLeakCheck("negative_alloc_leak"):
      let r = testAlloc.rawAlloc(128, 8)
      doAssert r.isOk
      # Intentionally omit testAlloc.dealloc(r.get(), 128)
  elif flag == "--trigger-orc-leak":
    testWithOrcLeakCheck("negative_orc_leak", toleranceBytes = 0):
      # Pin a large ref object in a global seq so GC_fullCollect() cannot reclaim it.
      for _ in 0 ..< 4:
        gPinnedLeaks.add(OrcLeakNode())

proc runNegativeSelfChecks() =
  let exe = getAppFilename()

  block allocLeakCheck:
    let (output, exitCode) = execCmdEx(quoteShell(exe) & " --trigger-alloc-leak")
    doAssert exitCode != 0, "Expected non-zero exit code for --trigger-alloc-leak"
    doAssert "[LEAK DETECTED]" in output,
      "Expected [LEAK DETECTED] in output, got:\n" & output
    echo "[OK] Negative alloc leak check triggered non-zero exit with [LEAK DETECTED]"

  block orcLeakCheck:
    let (output, exitCode) = execCmdEx(quoteShell(exe) & " --trigger-orc-leak")
    doAssert exitCode != 0, "Expected non-zero exit code for --trigger-orc-leak"
    doAssert "[ORC LEAK DETECTED]" in output,
      "Expected [ORC LEAK DETECTED] in output, got:\n" & output
    echo "[OK] Negative ORC leak check triggered non-zero exit with [ORC LEAK DETECTED]"

  block positiveCheck:
    testWithLeakCheck("positive_clean_alloc"):
      let r = testAlloc.rawAlloc(256, 16)
      doAssert r.isOk
      testAlloc.dealloc(r.get(), 256)
    echo "[OK] Positive clean alloc + ORC check passed with 0 leaks"

when isMainModule:
  if paramCount() >= 1 and paramStr(1) in ["--trigger-alloc-leak", "--trigger-orc-leak"]:
    runChildTrigger(paramStr(1))
  else:
    runNegativeSelfChecks()
