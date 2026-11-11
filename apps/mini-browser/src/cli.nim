## apps/mini-browser/src/cli.nim
## CLI entry point for the Nim High-Performance Mini-Browser
import std/[os, strutils]
import corex
import ./html
import ./css
import ./layout
import ./paint
import ./png

proc printUsage() =
  stderr.writeLine("Usage: cli render <in> <out> [--width N] [--height N] [--css <file>]")

proc main() =
  if paramCount() < 3:
    printUsage()
    quit(1)

  let cmd = paramStr(1)
  if cmd != "render":
    stderr.writeLine("Error: unknown command '" & cmd & "'. Expected 'render'")
    printUsage()
    quit(1)

  let inPath = paramStr(2)
  let outPath = paramStr(3)

  var width = 800
  var height = 600
  var cssPath = ""

  var i = 4
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--width":
      if i + 1 > paramCount():
        stderr.writeLine("Error: missing value for --width")
        quit(1)
      try:
        width = parseInt(paramStr(i + 1))
      except ValueError:
        stderr.writeLine("Error: invalid integer for --width: " & paramStr(i + 1))
        quit(1)
      inc(i, 2)
    elif arg.startsWith("--width=") or arg.startsWith("--width:"):
      let valStr = arg[8 .. ^1]
      try:
        width = parseInt(valStr)
      except ValueError:
        stderr.writeLine("Error: invalid integer for --width: " & valStr)
        quit(1)
      inc(i)
    elif arg == "--height":
      if i + 1 > paramCount():
        stderr.writeLine("Error: missing value for --height")
        quit(1)
      try:
        height = parseInt(paramStr(i + 1))
      except ValueError:
        stderr.writeLine("Error: invalid integer for --height: " & paramStr(i + 1))
        quit(1)
      inc(i, 2)
    elif arg.startsWith("--height=") or arg.startsWith("--height:"):
      let valStr = arg[9 .. ^1]
      try:
        height = parseInt(valStr)
      except ValueError:
        stderr.writeLine("Error: invalid integer for --height: " & valStr)
        quit(1)
      inc(i)
    elif arg == "--css":
      if i + 1 > paramCount():
        stderr.writeLine("Error: missing value for --css")
        quit(1)
      cssPath = paramStr(i + 1)
      inc(i, 2)
    elif arg.startsWith("--css=") or arg.startsWith("--css:"):
      cssPath = arg[6 .. ^1]
      inc(i)
    else:
      stderr.writeLine("Error: unknown option '" & arg & "'")
      printUsage()
      quit(1)

  if width <= 0 or height <= 0:
    stderr.writeLine("Error: width and height must be positive integers")
    quit(1)

  # 1. Read input HTML using corex/io openBufferedReader
  var readerRes = openBufferedReader(inPath)
  if readerRes.isErr:
    stderr.writeLine("Error: failed to open input file '" & inPath & "': " & readerRes.errVal.msg)
    quit(1)
  var reader = readerRes.get()

  let contentRes = reader.readAll()
  if contentRes.isErr:
    stderr.writeLine("Error: failed to read input file '" & inPath & "': " & contentRes.errVal.msg)
    quit(1)
  let content = contentRes.get()

  var inputBytes = newSeq[byte](content.len)
  if content.len > 0:
    copyMem(addr inputBytes[0], unsafeAddr content[0], content.len)

  # 2. Parse HTML
  let parseRes = parseHtml(inputBytes, defaultHeapAllocator())
  if parseRes.isErr:
    stderr.writeLine("Error: HTML parse error at offset " & $parseRes.errVal.offset & ": " & parseRes.errVal.msg)
    quit(1)
  let doc = parseRes.get()

  # 3. Parse optional CSS
  var styleSheet = StyleSheet()
  if cssPath.len > 0:
    var cssReaderRes = openBufferedReader(cssPath)
    if cssReaderRes.isErr:
      stderr.writeLine("Error: failed to open CSS file '" & cssPath & "': " & cssReaderRes.errVal.msg)
      quit(1)
    var cssReader = cssReaderRes.get()
    let cssContentRes = cssReader.readAll()
    if cssContentRes.isErr:
      stderr.writeLine("Error: failed to read CSS file '" & cssPath & "': " & cssContentRes.errVal.msg)
      quit(1)
    let cssContent = cssContentRes.get()
    var cssBytes = newSeq[byte](cssContent.len)
    if cssContent.len > 0:
      copyMem(addr cssBytes[0], unsafeAddr cssContent[0], cssContent.len)
    let parseCssRes = parseCss(cssBytes, defaultHeapAllocator())
    if parseCssRes.isErr:
      stderr.writeLine("Error: CSS parse error at offset " & $parseCssRes.errVal.offset & ": " & parseCssRes.errVal.msg)
      quit(1)
    styleSheet = parseCssRes.get()

  # 4. Compute layout
  let layoutTree = layout(doc, width, height, defaultHeapAllocator(), styleSheet)

  # 5. Paint
  var img = newImage(width, height, defaultHeapAllocator())
  if img.pixels.isNil and width > 0 and height > 0:
    stderr.writeLine("Error: failed to allocate image buffer")
    quit(1)
  defer: img.deinit()

  # Fill background white (rgba(255, 255, 255, 255))
  img.fillRect(0, 0, width, height, png.rgba(255'u8, 255'u8, 255'u8, 255'u8))

  # Render layout boxes
  for idx in 0 ..< layoutTree.boxes.len:
    let b = layoutTree.boxes[idx]
    case b.kind
    of bkElement:
      img.fillRect(int(b.x), int(b.y), int(b.w), int(b.h), b.bgColor)
    of bkText:
      img.drawTextPlaceholder(int(b.x), int(b.y), b.textContent, int(b.h), b.textColor)

  # 6. Encode PNG
  let pngBytes = encodePng(img)

  # 7. Ensure output directory exists and write PNG using FileHandle
  let parent = parentDir(outPath)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  var fhRes = openFile(outPath, fmWrite)
  if fhRes.isErr:
    stderr.writeLine("Error: failed to open output file '" & outPath & "': " & fhRes.errVal.msg)
    quit(1)
  var fh = fhRes.get()

  if pngBytes.len > 0:
    let writeRes = fh.write(pngBytes)
    if writeRes.isErr:
      stderr.writeLine("Error: failed to write PNG data to '" & outPath & "': " & writeRes.errVal.msg)
      quit(1)

  let flushRes = fh.flush()
  if flushRes.isErr:
    stderr.writeLine("Error: failed to flush output file '" & outPath & "': " & flushRes.errVal.msg)
    quit(1)

  discard fh.close()

when isMainModule:
  main()
