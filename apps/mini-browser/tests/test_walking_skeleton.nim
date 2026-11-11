## apps/mini-browser/tests/test_walking_skeleton.nim
## End-to-end walking skeleton integration tests for mini-browser (including Day 2 CSS)

import std/[os, osproc, streams, strutils]

const PngSignature: array[8, byte] = [
  0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8
]

proc findCli(): string =
  let appDir = getAppDir()
  let exeSuffix = when defined(windows): ".exe" else: ""
  let candidates = [
    "src" / ("cli" & exeSuffix),
    ".." / "src" / ("cli" & exeSuffix),
    appDir / "src" / ("cli" & exeSuffix),
    appDir / ".." / "src" / ("cli" & exeSuffix),
    "cli" & exeSuffix
  ]
  for c in candidates:
    if fileExists(c):
      return absolutePath(c)
  raise newException(IOError, "Could not locate compiled mini-browser CLI binary")

proc findFixture(filename: string): string =
  let appDir = getAppDir()
  let candidates = [
    "tests" / "fixtures" / filename,
    "fixtures" / filename,
    appDir / "fixtures" / filename,
    appDir / "tests" / "fixtures" / filename,
    appDir / ".." / "tests" / "fixtures" / filename
  ]
  for c in candidates:
    if fileExists(c):
      return absolutePath(c)
  raise newException(IOError, "Could not locate fixture: " & filename)

proc verifyPngSignature(path: string) =
  doAssert fileExists(path), "Output file does not exist: " & path
  let size = getFileSize(path)
  doAssert size > 0, "Output file is empty (size 0): " & path
  var f = open(path, fmRead)
  var sig: array[8, byte]
  let n = f.readBytes(sig, 0, 8)
  f.close()
  doAssert n == 8, "Failed to read 8 bytes from " & path
  for i in 0 ..< 8:
    doAssert sig[i] == PngSignature[i], "Mismatch in PNG signature at byte " & $i

proc hasRgbaColor(path: string, r, g, b, a: byte): bool =
  ## Scans raw PNG bytes for RGBA pixel value (stored uncompressed via zlib store)
  let content = readFile(path)
  if content.len < 4: return false
  for i in 0 .. content.len - 4:
    if byte(content[i]) == r and byte(content[i+1]) == g and
       byte(content[i+2]) == b and byte(content[i+3]) == a:
      return true
  return false

proc runCli(cli: string, inPath, outPath: string, extraArgs: openArray[string] = []): tuple[exitCode: int, outStr, errStr: string] =
  var args = @["render", inPath, outPath]
  for a in extraArgs: args.add(a)
  let p = startProcess(
    cli,
    args = args,
    options = {poUsePath}
  )
  let exitCode = p.waitForExit()
  let outStr = p.outputStream.readAll()
  let errStr = p.errorStream.readAll()
  p.close()
  (exitCode, outStr, errStr)

proc main() =
  echo "=== Running Walking Skeleton Integration Tests ==="
  let cli = findCli()
  echo "Using CLI binary: ", cli

  let tmpDir = getTempDir() / "mini_browser_skeleton_tests"
  createDir(tmpDir)
  defer:
    removeDir(tmpDir)

  # 1. Test hello.html
  block:
    let inPath = findFixture("hello.html")
    let outPath = tmpDir / "hello.png"
    if fileExists(outPath): removeFile(outPath)

    let (exitCode, _, errStr) = runCli(cli, inPath, outPath)
    doAssert exitCode == 0, "hello.html render failed with exit code " & $exitCode & ": " & errStr
    verifyPngSignature(outPath)
    echo "[PASS] hello.html -> file exists, size > 0, valid PNG signature"

  # 2. Test nested.html
  block:
    let inPath = findFixture("nested.html")
    let outPath = tmpDir / "nested.png"
    if fileExists(outPath): removeFile(outPath)

    let (exitCode, _, errStr) = runCli(cli, inPath, outPath)
    doAssert exitCode == 0, "nested.html render failed with exit code " & $exitCode & ": " & errStr
    verifyPngSignature(outPath)
    echo "[PASS] nested.html -> file exists, size > 0, valid PNG signature"

  # 3. Test empty.html
  block:
    let inPath = findFixture("empty.html")
    let outPath = tmpDir / "empty.png"
    if fileExists(outPath): removeFile(outPath)

    let (exitCode, _, errStr) = runCli(cli, inPath, outPath)
    doAssert exitCode == 0, "empty.html render failed with exit code " & $exitCode & ": " & errStr
    verifyPngSignature(outPath)
    echo "[PASS] empty.html -> file exists, size > 0, valid PNG signature"

  # 4. Test unclosed.html
  block:
    let inPath = findFixture("unclosed.html")
    let outPath = tmpDir / "unclosed.png"
    if fileExists(outPath): removeFile(outPath)

    let (exitCode, _, errStr) = runCli(cli, inPath, outPath)
    doAssert exitCode == 1, "Expected exit code 1 for unclosed.html, got: " & $exitCode
    doAssert errStr.len > 0, "Expected non-empty stderr for unclosed.html"
    echo "[PASS] unclosed.html -> exit code 1 and non-empty stderr (stderr: ", errStr.strip(), ")"

  # 5. Test styled.html + styled.css -> red <h1> in PNG
  block:
    let inPath = findFixture("styled.html")
    let cssPath = findFixture("styled.css")
    let outPath = tmpDir / "styled.png"
    if fileExists(outPath): removeFile(outPath)

    let (exitCode, _, errStr) = runCli(cli, inPath, outPath, ["--css", cssPath])
    doAssert exitCode == 0, "styled.html render failed with exit code " & $exitCode & ": " & errStr
    verifyPngSignature(outPath)
    doAssert hasRgbaColor(outPath, 255'u8, 0'u8, 0'u8, 255'u8), "Expected red text color in styled.png"
    echo "[PASS] styled.html + styled.css -> file exists, valid PNG, <h1> is red (RGBA 255,0,0,255 found)"

  # 6. Test hidden.html + hidden.css -> display: none succeeds
  block:
    let inPath = findFixture("hidden.html")
    let cssPath = findFixture("hidden.css")
    let outPath = tmpDir / "hidden.png"
    if fileExists(outPath): removeFile(outPath)

    let (exitCode, _, errStr) = runCli(cli, inPath, outPath, ["--css", cssPath])
    doAssert exitCode == 0, "hidden.html render failed with exit code " & $exitCode & ": " & errStr
    verifyPngSignature(outPath)
    echo "[PASS] hidden.html + hidden.css -> file exists, valid PNG, display: none skips box"

  echo "All walking skeleton tests passed successfully."

when isMainModule:
  main()
