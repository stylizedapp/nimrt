## src/wiztree/cli.nim — Command-Line Interface and Presentation Layer for WizTree
##
## Implements:
## 1. CLI Parameter Parsing: drive/path (e.g. `C:`, `.`, `D:\`), `--format:table|json|csv`,
##    `--top:N` (default 20), `--sort:size|disk|count`, `--mode:mft|fast`.
## 2. Visual Output (Human-Readable Tables):
##    - Drive/Scan Summary: volume name, filesystem, total/free/used capacity, cluster size,
##      files/dirs scanned, time elapsed, throughput (items/sec), scan mode.
##    - Top N Largest Files: rank, size, size on disk, percentage of volume, full path.
##    - Top N Largest Folders: rank, size, total items (recursive count), percentage of volume, full path.
##    - File Type / Extension Distribution: extension, file count, total size, percentage, visual bar.
## 3. Streaming JSON Export: Zero-DOM streaming using `algx/zeropack` (appendFastInt / appendJsonFast).
## 4. Structured CSV Export: Multi-section escaped CSV for spreadsheets and data pipelines.
## 5. Main Execution Workflow: `runCli(args)` and `runScanAndReport(config)`.

import std/os
import std/strutils
import std/algorithm
import std/monotimes
import std/times

import corex/result
import algx/zeropack
import ./types
import ./tree
import ./scanner

export types
export tree
export scanner

# =============================================================================
# 1. Configuration & Argument Parsing
# =============================================================================

type
  CliConfig* = object
    targetPath*: string           ## Target path or drive to scan (default: ".")
    format*: OutputFormat         ## Output format: ofTable, ofJson, ofCsv (default: ofTable)
    topCount*: int                ## Number of top files/folders to display (default: 20)
    sortCriterion*: SortCriterion ## Sort key: scSize, scSizeOnDisk, scItemCount (default: scSize)
    scanMode*: ScanMode           ## Scan strategy preference (default: smMftDirect)
    showHelp*: bool               ## User requested --help
    showVersion*: bool            ## User requested --version
    quiet*: bool                  ## Omit banner and formatting decorations

proc defaultCliConfig*(): CliConfig {.inline, raises: [].} =
  ## Returns default CLI configuration.
  CliConfig(
    targetPath: ".",
    format: ofTable,
    topCount: 20,
    sortCriterion: scSize,
    scanMode: smMftDirect,
    showHelp: false,
    showVersion: false,
    quiet: false
  )

proc parseArgs*(args: openArray[string]): CliConfig {.raises: [].} =
  ## Robust command-line argument parser supporting both `--flag:val` and `--flag=val`.
  result = defaultCliConfig()
  var pathSpecified = false

  for arg in args:
    if arg.len == 0:
      continue

    # Check for help / version switches
    if arg in ["--help", "-h", "-?", "/?", "/h", "/help"]:
      result.showHelp = true
      return
    if arg in ["--version", "-v", "/v", "/version"]:
      result.showVersion = true
      return

    # Option flag parsing (starts with '-' or '--')
    if arg.startsWith("-"):
      var key = ""
      var val = ""
      let sepPos = arg.find({':', '='})
      if sepPos >= 0:
        key = arg[0 ..< sepPos].strip(chars = {'-'}).toLowerAscii()
        val = arg[sepPos + 1 .. ^1].strip()
      else:
        key = arg.strip(chars = {'-'}).toLowerAscii()
        val = ""

      let valLower = val.toLowerAscii()

      case key
      of "format", "f":
        case valLower
        of "json": result.format = ofJson
        of "csv": result.format = ofCsv
        of "table": result.format = ofTable
        else: discard
      of "top", "n", "t", "limit":
        try:
          let n = parseInt(val)
          if n > 0:
            result.topCount = n
        except:
          discard
      of "sort", "s":
        case valLower
        of "size", "bytes", "logical":
          result.sortCriterion = scSize
        of "disk", "sizeondisk", "physical", "allocated":
          result.sortCriterion = scSizeOnDisk
        of "count", "items", "itemcount":
          result.sortCriterion = scItemCount
        else:
          discard
      of "mode", "m", "scanmode", "scan-mode":
        case valLower
        of "mft", "direct", "usn":
          result.scanMode = smMftDirect
        of "fast", "win32", "win32fast", "fallback", "walk":
          result.scanMode = smWin32Fast
        else:
          discard
      of "path", "p", "target", "dir", "drive":
        if val.len > 0:
          result.targetPath = val
          pathSpecified = true
      of "quiet", "q":
        result.quiet = true
      else:
        discard
    else:
      # Positional argument represents the drive or target path
      if not pathSpecified:
        result.targetPath = arg
        pathSpecified = true

# =============================================================================
# 2. String & Numeric Formatting Utilities
# =============================================================================

proc formatBytes*(bytes: int64): string {.raises: [].} =
  ## Converts byte count into human-readable representation (B, KB, MB, GB, TB).
  if bytes < 0:
    return "0 B"
  if bytes < 1024:
    return $bytes & " B"

  let kb = float64(bytes) / 1024.0
  if kb < 1024.0:
    return (try: formatFloat(kb, ffDecimal, 2) except: $int64(kb)) & " KB"

  let mb = kb / 1024.0
  if mb < 1024.0:
    return (try: formatFloat(mb, ffDecimal, 2) except: $int64(mb)) & " MB"

  let gb = mb / 1024.0
  if gb < 1024.0:
    return (try: formatFloat(gb, ffDecimal, 2) except: $int64(gb)) & " GB"

  let tb = gb / 1024.0
  return (try: formatFloat(tb, ffDecimal, 2) except: $int64(tb)) & " TB"

proc formatNumber*(n: int64): string {.raises: [].} =
  ## Formats an integer with thousands comma separators (e.g. 1,452,190).
  var s = $n
  if s.len <= 3:
    return s
  let start = if s[0] == '-': 1 else: 0
  let numDigits = s.len - start
  let commas = (numDigits - 1) div 3
  if commas == 0:
    return s

  result = newString(s.len + commas)
  var src = s.len - 1
  var dst = result.len - 1
  var count = 0
  while src >= start:
    result[dst] = s[src]
    dec(dst)
    dec(src)
    inc(count)
    if count == 3 and src >= start:
      result[dst] = ','
      dec(dst)
      count = 0
  if start == 1:
    result[0] = '-'

proc formatPercent*(pct: float64): string {.raises: [].} =
  ## Formats a float as percentage with two decimal places (e.g. "45.23%").
  if pct <= 0.0:
    "0.00%"
  elif pct < 0.01:
    "<0.01%"
  else:
    (try: formatFloat(pct, ffDecimal, 2) except: "0.00") & "%"

proc renderProgressBar*(pct: float64, width: int = 20): string {.raises: [].} =
  ## Generates a Unicode visual progress bar using block characters: [████████░░░░░░░░░░].
  let w = max(5, width)
  let clamped = max(0.0, min(100.0, pct))
  let filled = int((clamped / 100.0) * float64(w) + 0.5)
  let fillCount = min(w, max(0, filled))
  let emptyCount = w - fillCount
  var bar = newStringOfCap(w * 3 + 2)
  bar.add('[')
  for _ in 0 ..< fillCount:
    bar.add("█")
  for _ in 0 ..< emptyCount:
    bar.add("░")
  bar.add(']')
  bar

proc alignRight*(s: string, width: int): string {.inline, raises: [].} =
  ## Right-aligns string in a field of given width.
  if s.len >= width: s
  else: spaces(width - s.len) & s

proc alignLeft*(s: string, width: int): string {.inline, raises: [].} =
  ## Left-aligns string in a field of given width.
  if s.len >= width: s
  else: s & spaces(width - s.len)

# =============================================================================
# 3. Visual Table Rendering (Drive Summary, Top Files, Top Folders, Extensions)
# =============================================================================

const
  TableSep80  = "================================================================================"
  TableSep100 = "----------------------------------------------------------------------------------------------------"

proc renderSummary*(tree: Tree): string {.raises: [].} =
  ## Formats the Volume and Scan Execution Summary block.
  let vol = tree.volume
  let stats = tree.stats
  let volName = if vol.volumeName.len > 0: vol.volumeName else: "[Unlabeled]"
  let fsName = if vol.fsType.len > 0: vol.fsType else: "NTFS"
  let rootSpec = if vol.driveLetter.len > 0: vol.driveLetter else: "C:\\"

  var buf = newStringOfCap(1024)
  buf.add(TableSep80 & "\n")
  buf.add("  WizTree High-Performance Disk Scanner Engine\n")
  buf.add(TableSep80 & "\n")
  buf.add("  Target Path     : " & rootSpec & "\n")
  buf.add("  Volume Label    : " & volName & "\n")
  buf.add("  Filesystem      : " & fsName & "\n")

  if vol.totalBytes > 0:
    let freePct = if vol.totalBytes > 0: (float64(vol.freeBytes) / float64(vol.totalBytes)) * 100.0 else: 0.0
    let usedBytes = vol.usedBytes
    let usedPct = vol.usedPercentage
    buf.add("  Volume Capacity : " & formatBytes(vol.totalBytes) & " Total  |  " &
            formatBytes(vol.freeBytes) & " Free (" & formatPercent(freePct) & ")  |  " &
            formatBytes(usedBytes) & " Used (" & formatPercent(usedPct) & ")\n")
  else:
    buf.add("  Volume Capacity : [Unknown / Non-Drive Target]\n")

  let clusterStr = if vol.clusterSize > 0:
                     formatNumber(int64(vol.clusterSize)) & " bytes (" & $(vol.clusterSize div 1024) & " KB)"
                   else:
                     "4,096 bytes (4 KB)"
  buf.add("  Cluster Size    : " & clusterStr & "\n")

  let totalItems = stats.scannedFiles + stats.scannedDirs
  buf.add("  Files Scanned   : " & formatNumber(stats.scannedFiles) & " files, " &
          formatNumber(stats.scannedDirs) & " directories (" & formatNumber(totalItems) & " total)\n")

  buf.add("  Total Scanned   : " & formatBytes(stats.totalBytes) &
          " (Allocated on Disk: " & formatBytes(stats.totalBytesOnDisk) & ")\n")

  let elapsedStr = try: formatFloat(stats.elapsedMs, ffDecimal, 2) except: $int64(stats.elapsedMs)
  buf.add("  Time Elapsed    : " & elapsedStr & " ms\n")

  let rateStr = formatNumber(int64(stats.throughputFilesPerSec))
  buf.add("  Scan Rate       : " & rateStr & " files/sec\n")

  buf.add("  Scan Mode       : " & $stats.scanMode & "\n")
  buf.add(TableSep80 & "\n")
  result = buf

proc renderTopFilesTable*(
  tree: Tree,
  items: openArray[TopItem],
  criterion: SortCriterion = scSize
): string {.raises: [].} =
  ## Formats the Top N Largest Files table.
  var buf = newStringOfCap(2048)
  let sortLabel = case criterion
                  of scSize: "Logical Size"
                  of scSizeOnDisk: "Size on Disk"
                  of scItemCount: "Count"

  buf.add("\n" & TableSep100 & "\n")
  buf.add("  Top " & $items.len & " Largest Files (Sorted by " & sortLabel & ")\n")
  buf.add(TableSep100 & "\n")
  buf.add("  Rank          Size  Size on Disk  % Volume  Full Path\n")
  buf.add(TableSep100 & "\n")

  if items.len == 0:
    buf.add("  (No files found)\n")
  else:
    let refTotal = if tree.volume.totalBytes > 0: tree.volume.totalBytes else: tree.stats.totalBytes
    for i in 0 ..< items.len:
      let item = items[i]
      let rankStr = alignRight($(i + 1), 6)
      let sizeStr = alignRight(formatBytes(item.size), 12)
      let diskStr = alignRight(formatBytes(item.sizeOnDisk), 14)
      let pct = if refTotal > 0: (float64(item.size) / float64(refTotal)) * 100.0 else: 0.0
      let pctStr = alignRight(formatPercent(pct), 10)
      let path = tree.getFullPath(item.nodeIdx)

      buf.add(rankStr & "  " & sizeStr & "  " & diskStr & "  " & pctStr & "  " & path & "\n")

  buf.add(TableSep100 & "\n")
  result = buf

proc renderTopFoldersTable*(
  tree: Tree,
  items: openArray[TopItem],
  criterion: SortCriterion = scSize
): string {.raises: [].} =
  ## Formats the Top N Largest Folders table.
  var buf = newStringOfCap(2048)
  let sortLabel = case criterion
                  of scSize: "Logical Size"
                  of scSizeOnDisk: "Size on Disk"
                  of scItemCount: "Total Items"

  buf.add("\n" & TableSep100 & "\n")
  buf.add("  Top " & $items.len & " Largest Folders (Sorted by " & sortLabel & ")\n")
  buf.add(TableSep100 & "\n")
  buf.add("  Rank          Size   Total Items  % Volume  Full Path\n")
  buf.add(TableSep100 & "\n")

  if items.len == 0:
    buf.add("  (No folders found)\n")
  else:
    let refTotal = if tree.volume.totalBytes > 0: tree.volume.totalBytes else: tree.stats.totalBytes
    for i in 0 ..< items.len:
      let item = items[i]
      let rankStr = alignRight($(i + 1), 6)
      let sizeStr = alignRight(formatBytes(item.size), 12)
      let countStr = alignRight(formatNumber(int64(item.childCount)), 13)
      let pct = if refTotal > 0: (float64(item.size) / float64(refTotal)) * 100.0 else: 0.0
      let pctStr = alignRight(formatPercent(pct), 10)
      let path = tree.getFullPath(item.nodeIdx)

      buf.add(rankStr & "  " & sizeStr & "  " & countStr & "  " & pctStr & "  " & path & "\n")

  buf.add(TableSep100 & "\n")
  result = buf

proc renderExtensionTable*(
  stats: openArray[ExtensionStat],
  tree: Tree
): string {.raises: [].} =
  ## Formats the File Type / Extension Distribution table with visual percentage bar.
  var buf = newStringOfCap(2048)
  buf.add("\n" & TableSep100 & "\n")
  buf.add("  File Type / Extension Distribution\n")
  buf.add(TableSep100 & "\n")
  buf.add("  Extension             Files    Total Size  % Volume  Visual Distribution\n")
  buf.add(TableSep100 & "\n")

  if stats.len == 0:
    buf.add("  (No extensions found)\n")
  else:
    let refTotal = if tree.volume.totalBytes > 0: tree.volume.totalBytes else: tree.stats.totalBytes
    let displayCount = min(20, stats.len)
    for i in 0 ..< displayCount:
      let s = stats[i]
      let extName = if s.ext.len == 0: "[no ext]" else: s.ext
      let extStr = alignLeft(extName, 14)
      let filesStr = alignRight(formatNumber(s.fileCount), 12)
      let sizeStr = alignRight(formatBytes(s.totalBytes), 13)
      let volPct = if refTotal > 0: (float64(s.totalBytes) / float64(refTotal)) * 100.0 else: 0.0
      let volPctStr = alignRight(formatPercent(volPct), 10)
      let bar = renderProgressBar(s.percentage, 20)
      let barPct = alignRight(formatPercent(s.percentage), 7)

      buf.add("  " & extStr & "  " & filesStr & "  " & sizeStr & "  " & volPctStr & "  " & bar & " " & barPct & "\n")

  buf.add(TableSep100 & "\n")
  result = buf

proc renderTable*(
  tree: Tree,
  topFiles: openArray[TopItem],
  topFolders: openArray[TopItem],
  extStats: openArray[ExtensionStat],
  config: CliConfig
): string {.raises: [].} =
  ## Combines drive summary, top files, top folders, and extension tables into one output.
  var res = newStringOfCap(8192)
  if not config.quiet:
    res.add(renderSummary(tree))
  res.add(renderTopFilesTable(tree, topFiles, config.sortCriterion))
  res.add(renderTopFoldersTable(tree, topFolders, config.sortCriterion))
  res.add(renderExtensionTable(extStats, tree))
  result = res

# =============================================================================
# 4. Structured Streaming JSON Export (via algx/zeropack)
# =============================================================================

proc appendJsonEscapedStr*(dst: var string, s: string) {.inline, raises: [].} =
  ## Encodes string with JSON escape sequences.
  dst.add('"')
  for c in s:
    case c
    of '\\': dst.add("\\\\")
    of '"': dst.add("\\\"")
    of '\b': dst.add("\\b")
    of '\f': dst.add("\\f")
    of '\n': dst.add("\\n")
    of '\r': dst.add("\\r")
    of '\t': dst.add("\\t")
    else:
      if ord(c) < 32:
        dst.add("\\u00")
        let h = toHex(ord(c), 2)
        dst.add(h)
      else:
        dst.add(c)
  dst.add('"')

proc renderJson*(
  tree: Tree,
  topFiles: openArray[TopItem],
  topFolders: openArray[TopItem],
  extStats: openArray[ExtensionStat]
): string {.raises: [].} =
  ## Streams structured report directly into a JSON string using `algx/zeropack`.
  ## Completely avoids building an intermediate DOM tree.
  var res = newStringOfCap(8192)
  res.add("{\n")

  # Section 1: Volume Metadata
  res.add("  \"volume\": {\n")
  res.add("    \"volumeName\": ")
  res.appendJsonEscapedStr(tree.volume.volumeName)
  res.add(",\n    \"driveLetter\": ")
  res.appendJsonEscapedStr(tree.volume.driveLetter)
  res.add(",\n    \"fsType\": ")
  res.appendJsonEscapedStr(tree.volume.fsType)
  res.add(",\n    \"totalBytes\": ")
  res.appendFastInt(tree.volume.totalBytes)
  res.add(",\n    \"freeBytes\": ")
  res.appendFastInt(tree.volume.freeBytes)
  res.add(",\n    \"usedBytes\": ")
  res.appendFastInt(tree.volume.usedBytes)
  res.add(",\n    \"clusterSize\": ")
  res.appendFastInt(int64(tree.volume.clusterSize))
  res.add(",\n    \"sectorSize\": ")
  res.appendFastInt(int64(tree.volume.sectorSize))
  res.add("\n  },\n")

  # Section 2: Scan Execution Metrics
  res.add("  \"stats\": {\n")
  res.add("    \"scannedFiles\": ")
  res.appendFastInt(tree.stats.scannedFiles)
  res.add(",\n    \"scannedDirs\": ")
  res.appendFastInt(tree.stats.scannedDirs)
  res.add(",\n    \"totalItems\": ")
  res.appendFastInt(tree.stats.totalItems)
  res.add(",\n    \"totalBytes\": ")
  res.appendFastInt(tree.stats.totalBytes)
  res.add(",\n    \"totalBytesOnDisk\": ")
  res.appendFastInt(tree.stats.totalBytesOnDisk)
  res.add(",\n    \"elapsedMs\": ")
  res.appendJsonFast(tree.stats.elapsedMs)
  res.add(",\n    \"throughputFilesPerSec\": ")
  res.appendJsonFast(tree.stats.throughputFilesPerSec)
  res.add(",\n    \"scanMode\": ")
  res.appendJsonEscapedStr($tree.stats.scanMode)
  res.add("\n  },\n")

  let refTotal = if tree.volume.totalBytes > 0: tree.volume.totalBytes else: tree.stats.totalBytes

  # Section 3: Top Files
  res.add("  \"topFiles\": [\n")
  for i in 0 ..< topFiles.len:
    let item = topFiles[i]
    let path = tree.getFullPath(item.nodeIdx)
    let pct = if refTotal > 0: (float64(item.size) / float64(refTotal)) * 100.0 else: 0.0
    if i > 0: res.add(",\n")
    res.add("    {\n")
    res.add("      \"rank\": ")
    res.appendFastInt(int64(i + 1))
    res.add(",\n      \"path\": ")
    res.appendJsonEscapedStr(path)
    res.add(",\n      \"size\": ")
    res.appendFastInt(item.size)
    res.add(",\n      \"sizeOnDisk\": ")
    res.appendFastInt(item.sizeOnDisk)
    res.add(",\n      \"volumePercent\": ")
    res.appendJsonFast(pct)
    res.add("\n    }")
  res.add("\n  ],\n")

  # Section 4: Top Folders
  res.add("  \"topFolders\": [\n")
  for i in 0 ..< topFolders.len:
    let item = topFolders[i]
    let path = tree.getFullPath(item.nodeIdx)
    let pct = if refTotal > 0: (float64(item.size) / float64(refTotal)) * 100.0 else: 0.0
    if i > 0: res.add(",\n")
    res.add("    {\n")
    res.add("      \"rank\": ")
    res.appendFastInt(int64(i + 1))
    res.add(",\n      \"path\": ")
    res.appendJsonEscapedStr(path)
    res.add(",\n      \"size\": ")
    res.appendFastInt(item.size)
    res.add(",\n      \"sizeOnDisk\": ")
    res.appendFastInt(item.sizeOnDisk)
    res.add(",\n      \"totalItems\": ")
    res.appendFastInt(int64(item.childCount))
    res.add(",\n      \"volumePercent\": ")
    res.appendJsonFast(pct)
    res.add("\n    }")
  res.add("\n  ],\n")

  # Section 5: Extensions
  res.add("  \"extensions\": [\n")
  for i in 0 ..< extStats.len:
    let s = extStats[i]
    if i > 0: res.add(",\n")
    res.add("    {\n")
    res.add("      \"extension\": ")
    res.appendJsonEscapedStr(s.ext)
    res.add(",\n      \"fileCount\": ")
    res.appendFastInt(s.fileCount)
    res.add(",\n      \"totalBytes\": ")
    res.appendFastInt(s.totalBytes)
    res.add(",\n      \"totalBytesOnDisk\": ")
    res.appendFastInt(s.totalBytesOnDisk)
    res.add(",\n      \"percentage\": ")
    res.appendJsonFast(s.percentage)
    res.add("\n    }")
  res.add("\n  ]\n")

  res.add("}\n")
  result = res

# =============================================================================
# 5. Structured CSV Export
# =============================================================================

proc escapeCsv*(s: string): string {.raises: [].} =
  ## Quotes and escapes string for CSV export.
  var needsQuote = false
  for c in s:
    if c in {',', '"', '\n', '\r'}:
      needsQuote = true
      break
  if not needsQuote:
    return s

  result = newStringOfCap(s.len + 8)
  result.add('"')
  for c in s:
    if c == '"':
      result.add("\"\"")
    else:
      result.add(c)
  result.add('"')

proc renderCsv*(
  tree: Tree,
  topFiles: openArray[TopItem],
  topFolders: openArray[TopItem],
  extStats: openArray[ExtensionStat]
): string {.raises: [].} =
  ## Generates multi-section standard CSV export.
  var buf = newStringOfCap(8192)
  let vol = tree.volume
  let stats = tree.stats
  let refTotal = if vol.totalBytes > 0: vol.totalBytes else: stats.totalBytes

  # Section 1: Volume
  buf.add("# Section: Volume\n")
  buf.add("Drive,VolumeName,Filesystem,TotalBytes,FreeBytes,UsedBytes,ClusterSize\n")
  buf.add(escapeCsv(vol.driveLetter) & "," &
          escapeCsv(vol.volumeName) & "," &
          escapeCsv(vol.fsType) & "," &
          $vol.totalBytes & "," &
          $vol.freeBytes & "," &
          $vol.usedBytes & "," &
          $vol.clusterSize & "\n\n")

  # Section 2: Summary
  buf.add("# Section: Summary\n")
  buf.add("FilesScanned,DirsScanned,TotalItems,TotalBytes,TotalBytesOnDisk,ElapsedMs,ThroughputItemsPerSec,ScanMode\n")
  let elapsedStr = try: formatFloat(stats.elapsedMs, ffDecimal, 2) except: $int64(stats.elapsedMs)
  let tputStr = try: formatFloat(stats.throughputFilesPerSec, ffDecimal, 2) except: $int64(stats.throughputFilesPerSec)
  buf.add($stats.scannedFiles & "," &
          $stats.scannedDirs & "," &
          $stats.totalItems & "," &
          $stats.totalBytes & "," &
          $stats.totalBytesOnDisk & "," &
          elapsedStr & "," &
          tputStr & "," &
          escapeCsv($stats.scanMode) & "\n\n")

  # Section 3: Top Files
  buf.add("# Section: Top Files\n")
  buf.add("Rank,Path,Size,SizeOnDisk,VolumePercent\n")
  for i in 0 ..< topFiles.len:
    let item = topFiles[i]
    let path = tree.getFullPath(item.nodeIdx)
    let pct = if refTotal > 0: (float64(item.size) / float64(refTotal)) * 100.0 else: 0.0
    let pctStr = try: formatFloat(pct, ffDecimal, 4) except: "0.0"
    buf.add($(i + 1) & "," &
            escapeCsv(path) & "," &
            $item.size & "," &
            $item.sizeOnDisk & "," &
            pctStr & "\n")
  buf.add("\n")

  # Section 4: Top Folders
  buf.add("# Section: Top Folders\n")
  buf.add("Rank,Path,Size,SizeOnDisk,TotalItems,VolumePercent\n")
  for i in 0 ..< topFolders.len:
    let item = topFolders[i]
    let path = tree.getFullPath(item.nodeIdx)
    let pct = if refTotal > 0: (float64(item.size) / float64(refTotal)) * 100.0 else: 0.0
    let pctStr = try: formatFloat(pct, ffDecimal, 4) except: "0.0"
    buf.add($(i + 1) & "," &
            escapeCsv(path) & "," &
            $item.size & "," &
            $item.sizeOnDisk & "," &
            $item.childCount & "," &
            pctStr & "\n")
  buf.add("\n")

  # Section 5: Extensions
  buf.add("# Section: Extensions\n")
  buf.add("Extension,FileCount,TotalBytes,TotalBytesOnDisk,Percentage\n")
  for s in extStats:
    let pctStr = try: formatFloat(s.percentage, ffDecimal, 4) except: "0.0"
    buf.add(escapeCsv(s.ext) & "," &
            $s.fileCount & "," &
            $s.totalBytes & "," &
            $s.totalBytesOnDisk & "," &
            pctStr & "\n")

  result = buf

# =============================================================================
# 6. Help & Version Messages
# =============================================================================

proc getHelpMessage*(): string {.raises: [].} =
  ## Returns formatted CLI usage instructions.
  """
WizTree High-Performance Disk Scanner Engine
Usage: wiztree [options] [path]

Arguments:
  path                        Target path or drive to scan (e.g. C:, D:\, ., C:\Users) [default: .]

Options:
  --format:<table|json|csv>   Output format: human-readable table, streaming JSON, or CSV [default: table]
  --top:<N>                   Number of largest files and folders to display [default: 20]
  --sort:<size|disk|count>    Sort criterion: logical size, size on disk, or items count [default: size]
  --mode:<mft|fast>           Scan strategy preference: direct NTFS MFT stream or fast Win32 traversal [default: mft]
  --quiet, -q                 Omit extra header banners
  --help, -h                  Show this help message and exit
  --version, -v               Show version information and exit

Examples:
  wiztree C:
  wiztree . --format:json --top:50
  wiztree D:\ --sort:disk --format:csv
"""

proc getVersionMessage*(): string {.raises: [].} =
  "wiztree 1.0.0 (x86_64-pc-windows-gnu / orc / threads)"

# =============================================================================
# 7. Main Execution Pipeline
# =============================================================================

proc runScanAndReport*(config: CliConfig): Result[string, string] {.raises: [].} =
  ## Executes the scan and returns the rendered output string according to `config`.
  var options = defaultScanOptions(config.targetPath)
  options.scanModePreference = config.scanMode

  let scanRes = scanVolume(options)
  if scanRes.isErr:
    return err[string, string]("Scan failed: " & scanRes.error)

  var tree = scanRes.get

  # Link hierarchy if parent FRNs are present or MFT direct mode was used
  if tree.parentFrns.len > 0 or tree.stats.scanMode == smMftDirect:
    tree.linkHierarchy()

  # Bottom-up directory rollup
  tree.calculateSizes()

  # Query top items and extension stats
  let topFiles = tree.getTopFiles(config.topCount, config.sortCriterion)
  let topFolders = tree.getTopFolders(config.topCount, config.sortCriterion, includeRoot = false)
  let extStats = tree.getExtensionStats()

  let reportStr = case config.format
                  of ofTable: renderTable(tree, topFiles, topFolders, extStats, config)
                  of ofJson: renderJson(tree, topFiles, topFolders, extStats)
                  of ofCsv: renderCsv(tree, topFiles, topFolders, extStats)

  ok[string, string](reportStr)

proc runCli*(args: openArray[string]): int {.raises: [].} =
  ## Main entry point parsing args, running scan, printing results, returning exit code.
  let config = parseArgs(args)

  if config.showHelp:
    try:
      stdout.write(getHelpMessage())
    except:
      discard
    return 0

  if config.showVersion:
    try:
      stdout.writeLine(getVersionMessage())
    except:
      discard
    return 0

  let res = runScanAndReport(config)
  if res.isErr:
    try:
      stderr.writeLine("Error: " & res.error)
    except:
      discard
    return 1

  try:
    stdout.write(res.get)
  except:
    discard

  return 0
