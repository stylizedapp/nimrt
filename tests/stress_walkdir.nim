import std/[os, strformat]
import corex/fs
import corex/platform/windows/win32_fs

when defined(windows):
  type HANDLE = pointer
  type BOOL = int32
  type DWORD = uint32

  proc getCurrentProcess(): HANDLE {.stdcall, dynlib: "kernel32", importc: "GetCurrentProcess".}
  proc getProcessHandleCount(hProcess: HANDLE, pdwHandleCount: ptr DWORD): BOOL {.stdcall, dynlib: "kernel32", importc: "GetProcessHandleCount".}

  proc getHandleCount(): int =
    var count: DWORD = 0
    if getProcessHandleCount(getCurrentProcess(), addr count) != 0:
      return int(count)
    return -1

proc testEmptyDir() =
  echo "[TEST 1] Empty directory test..."
  let emptyPath = "temp_challenger1/empty_dir"
  createDir(emptyPath)
  defer: removeDir(emptyPath)

  var countNonRec = 0
  for entry in walkDirFast(emptyPath, recursive = false):
    inc countNonRec
  doAssert countNonRec == 0, &"Expected 0 entries, got {countNonRec}"

  var countRec = 0
  for entry in walkDirFast(emptyPath, recursive = true):
    inc countRec
  doAssert countRec == 0, &"Expected 0 entries in recursive walk, got {countRec}"

  let seqEntries = walkDirFastSeq(emptyPath, recursive = true)
  doAssert seqEntries.len == 0, &"Expected 0 entries in seq, got {seqEntries.len}"
  echo "  PASS: Empty directory yields 0 entries."

proc testDeeplyNested() =
  echo "[TEST 2] Deeply nested directories (25 levels)..."
  let basePath = "temp_challenger1/deep_root"
  var curr = basePath
  createDir(curr)
  defer: removeDir(basePath)

  for i in 1..25:
    curr = curr / &"lvl_{i}"
    createDir(curr)

  let deepFile = curr / "target_file.txt"
  writeFile(deepFile, "hello from level 25")

  # 1. Non-recursive walk on basePath should only find lvl_1
  var nonRecCount = 0
  var foundLvl1 = false
  for entry in walkDirFast(basePath, recursive = false):
    inc nonRecCount
    if entry.name == "lvl_1":
      foundLvl1 = true
  doAssert nonRecCount == 1, &"Expected 1 entry at root, got {nonRecCount}"
  doAssert foundLvl1, "Expected lvl_1 to be found"

  # 2. Recursive walk on basePath should find all 25 dirs + 1 file = 26 entries
  var recCount = 0
  var fileFound = false
  for entry in walkDirFast(basePath, recursive = true):
    inc recCount
    if entry.name == "target_file.txt":
      fileFound = true
      doAssert entry.stat.size == 19
      doAssert not entry.isDir

  doAssert recCount == 26, &"Expected 26 total entries, got {recCount}"
  doAssert fileFound, "Deepest file target_file.txt was not found"
  echo "  PASS: Deeply nested directory (25 levels) traversed successfully, found all 26 entries."

proc testThousandsOfFiles() =
  echo "[TEST 3] Directory with 3,000 files..."
  let dirPath = "temp_challenger1/many_files"
  createDir(dirPath)
  defer: removeDir(dirPath)

  const TotalFiles = 3000
  for i in 0 ..< TotalFiles:
    writeFile(dirPath / &"file_{i:04d}.dat", "x")

  var count = 0
  for entry in walkDirFast(dirPath, recursive = false):
    inc count
    doAssert entry.stat.size == 1
    doAssert not entry.isDir

  doAssert count == TotalFiles, &"Expected {TotalFiles} files, got {count}"
  echo &"  PASS: Successfully enumerated {count} files in flat directory."

proc testEarlyBreakHandleLeaks() =
  echo "[TEST 4] Early break handle leak stress test..."
  when not defined(windows):
    echo "  SKIPPED on non-Windows"
    return

  let dirPath = "temp_challenger1/leak_test_dir"
  createDir(dirPath)
  defer: removeDir(dirPath)

  for i in 0 ..< 50:
    writeFile(dirPath / &"dummy_{i:02d}.txt", "data")

  # Warm up
  for entry in walkDirFast(dirPath):
    break

  let initialHandles = getHandleCount()
  echo &"  Initial handle count: {initialHandles}"

  # Perform 2,000 early breaks on non-recursive walkDirFast
  const Iterations = 2000
  for k in 1 .. Iterations:
    for entry in walkDirFast(dirPath):
      break

  let handlesAfterNonRec = getHandleCount()
  echo &"  Handle count after {Iterations} non-recursive early breaks: {handlesAfterNonRec}"
  let diffNonRec = handlesAfterNonRec - initialHandles
  echo &"  Handle difference: {diffNonRec}"
  doAssert diffNonRec <= 5, &"Potential handle leak detected! diff = {diffNonRec}"

  # Perform 2,000 early breaks on win32WalkDir directly
  let handlesBeforeWin32 = getHandleCount()
  for k in 1 .. Iterations:
    for entry in win32WalkDir(dirPath):
      break

  let handlesAfterWin32 = getHandleCount()
  let diffWin32 = handlesAfterWin32 - handlesBeforeWin32
  echo &"  Handle count after {Iterations} win32WalkDir early breaks: {handlesAfterWin32} (diff: {diffWin32})"
  doAssert diffWin32 <= 5, &"Potential handle leak detected in win32WalkDir! diff = {diffWin32}"

  echo "  PASS: Zero handle leaks on early break."

proc main() =
  echo "=== Running walkDirFast Adversarial Stress Tests ==="
  testEmptyDir()
  testDeeplyNested()
  testThousandsOfFiles()
  testEarlyBreakHandleLeaks()
  echo "=== All walkDirFast Stress Tests PASSED ==="

main()
