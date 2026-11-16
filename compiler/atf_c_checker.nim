## compiler/atf_c_checker.nim
##
## After-Codegen-Finish (ATF) C Memory-Safety Verifier (`--check-safe-atf`).
## Runs immediately after C code generation finishes (`cgenWriteModules`) and
## BEFORE invoking the C compiler (`extccomp.callCCompiler`).
##
## Inspects generated `.c` artifacts in `nimcache` for user modules:
## - [ATF-001] Banned unsafe C functions (`malloc`, `calloc`, `realloc`, `free`,
##             `alloca`, `gets`, `strcpy`, `strcat`, `sprintf`, `vsprintf`,
##             `strncpy`, `strncat`, `system`, `popen`, and raw `memcpy`/`memmove`
##             outside Nim's `nimCopyMem` helper)
## - [ATF-002] Unchecked raw C pointer casts / pointer arithmetic injected via emit
## - [ATF-003] ARC/ORC lifecycle hook (`eqdestroy_`/`eqsink_`/`eqcopy_`) integrity
## - [ATF-004] Stack frame address escape (`return &local;`) in C functions
## - [ATF-005] Missing runtime safety guards (forbids `-d:danger` with ATF)

import std/[os, strutils, sets, syncio]
import options, msgs, lineinfos, pathutils
import safety_config

type
  AtfViolation* = object
    rule*: string
    cFile*: string
    cLine*: int
    nimFile*: string
    nimLine*: int
    message*: string

const
  AlwaysBannedCCalls = [
    "malloc", "calloc", "realloc", "free", "alloca", "_alloca",
    "gets", "strcpy", "strcat", "sprintf", "vsprintf",
    "strncpy", "strncat", "system", "popen", "_popen"
  ]

  RawCopyCCalls = ["memcpy", "memmove"]

proc isStdlibCArtifact(cf: Cfile): bool =
  let cname = cf.cname.string.replace('\\', '/')
  let base = cname.extractFilename()
  if base.startsWith("@psystem") or base.startsWith("@pstd@s"):
    return true
  if not gSafety.strictMode and (base.startsWith("@pcorex@s") or base.startsWith("@palgx@s")):
    return true
  if base.startsWith("stdlib_"):
    return true
  if cf.nimname in ["system", "dollars", "exceptions", "assertions", "syncio", "widestrs",
                    "cmdline", "exitprocs", "formatfloat", "digitsutils", "schubfach",
                    "win_setenv", "terminal", "times", "winlean", "dynlib", "os",
                    "strutils", "osproc", "paths", "dirs", "files", "symlinks"]:
    return true
  if gSafety.userModuleNames.len > 0 and cf.nimname notin gSafety.userModuleNames:
    # Check if base matches @m<main>
    if not base.startsWith("@m"):
      return true
  false

proc isIdentStartC(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

proc isIdentContC(c: char): bool {.inline.} =
  isIdentStartC(c) or (c >= '0' and c <= '9')

proc stripCommentsAndStringsC(src: string; inBlockComment: var bool; trustedLine: var bool): string =
  result = newStringOfCap(src.len)
  trustedLine = false
  var i = 0
  while i < src.len:
    if inBlockComment:
      if src[i ..< min(src.len, i + 20)].startsWith("NIM_TRUSTED_UNSAFE"):
        trustedLine = true
      if i + 1 < src.len and src[i] == '*' and src[i + 1] == '/':
        inBlockComment = false
        i += 2
        result.add(' ')
      else:
        inc i
      continue

    let c = src[i]
    if c == '/' and i + 1 < src.len:
      if src[i + 1] == '/':
        if src[i ..< src.len].contains("NIM_TRUSTED_UNSAFE"):
          trustedLine = true
        break
      elif src[i + 1] == '*':
        inBlockComment = true
        i += 2
        result.add(' ')
        continue

    if c == '"' or c == '\'':
      let q = c
      result.add(q)
      inc i
      while i < src.len:
        if src[i] == '\\' and i + 1 < src.len:
          i += 2
        elif src[i] == q:
          result.add(q)
          inc i
          break
        else:
          inc i
      continue

    result.add(c)
    inc i

proc scanFuncCallAt(line: string; idx: int; ident: string): bool =
  let after = idx + ident.len
  if idx > 0 and (isIdentContC(line[idx - 1]) or line[idx - 1] == '.' or line[idx - 1] == '>'):
    return false
  var k = after
  while k < line.len and (line[k] == ' ' or line[k] == '\t'):
    inc k
  k < line.len and line[k] == '('

proc parseNimMarker(rawLine: string; nimFile: var string; nimLine: var int) =
  let trimmed = rawLine.strip()
  let lfPos = trimmed.find("nimlf_(")
  if lfPos >= 0:
    let comma = trimmed.find(',', lfPos + 7)
    if comma > lfPos + 7:
      try:
        nimLine = parseInt(trimmed[lfPos + 7 ..< comma].strip())
      except ValueError:
        discard
      let q1 = trimmed.find('"', comma)
      if q1 >= 0:
        let q2 = trimmed.find('"', q1 + 1)
        if q2 > q1:
          nimFile = trimmed[q1 + 1 ..< q2].replace("\\\\", "\\")
  else:
    let lnPos = trimmed.find("nimln_(")
    if lnPos >= 0:
      let rp = trimmed.find(')', lnPos + 7)
      if rp > lnPos + 7:
        try:
          nimLine = parseInt(trimmed[lnPos + 7 ..< rp].strip())
        except ValueError:
          discard

proc auditSingleCFile(
  conf: ConfigRef;
  cPath: string;
  violations: var seq[AtfViolation]
) =
  let raw = readFile(cPath)
  let lines = raw.splitLines()
  gSafety.stats.cLinesAudited += lines.len

  var inBlockComment = false
  var curNimFile = cPath
  var curNimLine = 0
  var curFuncName = ""
  var inOrcHook = false
  var orcHookBraceDepth = 0
  var inNimCopyHelper = false

  for idx, rawLine in lines:
    let cLineNo = idx + 1
    parseNimMarker(rawLine, curNimFile, curNimLine)

    var trustedLine = false
    let clean = stripCommentsAndStringsC(rawLine, inBlockComment, trustedLine)
    let trimmed = clean.strip()
    if trimmed.len == 0:
      continue

    if trimmed.startsWith("#"):
      continue

    # Track C function boundaries & ORC lifecycle hooks
    if trimmed.contains("nimCopyMem") and trimmed.contains("static N_INLINE"):
      inNimCopyHelper = true
    elif trimmed.contains("nimZeroMem") and trimmed.contains("static N_INLINE"):
      inNimCopyHelper = true

    if curFuncName.len == 0 and trimmed.contains("(") and trimmed.endsWith("{") and
       not trimmed.startsWith("if") and not trimmed.startsWith("while") and
       not trimmed.startsWith("for") and not trimmed.startsWith("switch"):
      curFuncName = trimmed
      if trimmed.contains("eqdestroy_") or trimmed.contains("eqsink_") or trimmed.contains("eqcopy_"):
        inOrcHook = true
        orcHookBraceDepth = 0

    for ch in clean:
      if ch == '{': inc orcHookBraceDepth
      elif ch == '}':
        dec orcHookBraceDepth
        if orcHookBraceDepth <= 0:
          inOrcHook = false
          inNimCopyHelper = false
          curFuncName = ""

    if trustedLine:
      continue

    let normNim = curNimFile.replace('\\', '/')
    let isStdlibLoc = normNim.startsWith(conf.libpath.string.replace('\\', '/')) or
                      (not gSafety.strictMode and (normNim.contains("/src/corex/") or normNim.contains("/src/algx/")))

    # [ATF-001] Always banned CRT unsafe calls
    for i in 0 ..< clean.len:
      if isIdentStartC(clean[i]):
        var endPos = i + 1
        while endPos < clean.len and isIdentContC(clean[endPos]):
          inc endPos
        if i == 0 or not isIdentContC(clean[i - 1]):
          let tok = clean[i ..< endPos]
          if tok in AlwaysBannedCCalls and scanFuncCallAt(clean, i, tok):
            if not isStdlibLoc:
              let ruleCode = if inOrcHook: "ATF-003" else: "ATF-001"
              violations.add(AtfViolation(
                rule: ruleCode,
                cFile: cPath,
                cLine: cLineNo,
                nimFile: curNimFile,
                nimLine: curNimLine,
                message: "Unsafe C call '" & tok & "()' detected in generated C (" &
                         cPath.extractFilename() & ":" & $cLineNo & ")"
              ))
          elif tok in RawCopyCCalls and scanFuncCallAt(clean, i, tok):
            if not inNimCopyHelper and not isStdlibLoc:
              violations.add(AtfViolation(
                rule: "ATF-001",
                cFile: cPath,
                cLine: cLineNo,
                nimFile: curNimFile,
                nimLine: curNimLine,
                message: "Direct raw memory copy '" & tok & "()' outside Nim copy helper in " &
                         cPath.extractFilename() & ":" & $cLineNo
              ))

    # [ATF-002] Raw C pointer arithmetic / unsafe raw cast via inline emit
    if not isStdlibLoc and not inNimCopyHelper:
      if trimmed.contains("*(int*)") or trimmed.contains("*(char*)") or
         trimmed.contains("*(void**)") or trimmed.contains("((void**)"):
        violations.add(AtfViolation(
          rule: "ATF-002",
          cFile: cPath,
          cLine: cLineNo,
          nimFile: curNimFile,
          nimLine: curNimLine,
          message: "Unchecked raw C pointer dereference/cast in generated C (" &
                   cPath.extractFilename() & ":" & $cLineNo & ")"
        ))

    # [ATF-004] Stack frame address escape in C (`return &...;`)
    if not isStdlibLoc:
      if trimmed.startsWith("return &") or trimmed.startsWith("return (&"):
        violations.add(AtfViolation(
          rule: "ATF-004",
          cFile: cPath,
          cLine: cLineNo,
          nimFile: curNimFile,
          nimLine: curNimLine,
          message: "Potential stack address escape ('return &...') in generated C (" &
                   cPath.extractFilename() & ":" & $cLineNo & ")"
        ))

proc writeAtfReport(path: string; violations: seq[AtfViolation]) =
  if path.len == 0:
    return
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var doc = "# Nim Safe Compiler — After-Codegen-Finish (ATF) C Memory-Safety Audit\n\n"
  doc.add("- C Files Audited: " & $gSafety.stats.cFilesAudited & "\n")
  doc.add("- C Lines Audited: " & $gSafety.stats.cLinesAudited & "\n")
  doc.add("- AST Modules Checked: " & $gSafety.stats.astModulesChecked & "\n")
  doc.add("- Procs Borrow-Checked: " & $gSafety.stats.procsBorrowChecked & "\n")
  doc.add("- ATF Violations Found: " & $violations.len & "\n\n")
  if violations.len == 0:
    doc.add("Status: PASSED (0 memory-safety violations in generated C)\n")
  else:
    doc.add("## Violations\n\n")
    for v in violations:
      doc.add("- [" & v.rule & "] " & v.message & " (Nim source: " & v.nimFile & ":" & $v.nimLine & ")\n")
  writeFile(path, doc)

proc runAtfCSafetyCheck*(conf: ConfigRef) =
  if not gSafety.checkSafeAtfEnabled or conf == nil:
    return

  var violations: seq[AtfViolation] = @[]

  # [ATF-005] Verify runtime safety guards were not stripped by -d:danger
  if isDefined(conf, "danger") and not gSafety.strictMode:
    discard # allow explicit check below
  if isDefined(conf, "danger") or
     (conf.options * {optBoundsCheck, optOverflowCheck} == {}):
    violations.add(AtfViolation(
      rule: "ATF-005",
      cFile: "",
      cLine: 0,
      nimFile: conf.projectFull.string,
      nimLine: 1,
      message: "Runtime bounds/overflow guards cannot be disabled (-d:danger / --checks:off) when --check-safe-atf is active"
    ))

  var auditedFiles = 0
  for cf in conf.toCompile:
    if CfileFlag.External in cf.flags:
      continue
    if isStdlibCArtifact(cf) and not gSafety.strictMode:
      continue
    let cPath = cf.cname.string
    if fileExists(cPath):
      inc auditedFiles
      auditSingleCFile(conf, cPath, violations)

  gSafety.stats.cFilesAudited = auditedFiles
  gSafety.stats.atfViolations = violations.len
  writeAtfReport(gSafety.atfReportPath, violations)

  if violations.len > 0:
    for v in violations:
      let info =
        if v.nimFile.len > 0 and fileExists(v.nimFile):
          newLineInfo(conf, AbsoluteFile(v.nimFile), max(1, v.nimLine), 1)
        else:
          gCmdLineInfo
      localError(conf, info, "[" & v.rule & "] ATF C-Safety Violation: " & v.message)
  else:
    msgWriteln(
      conf,
      "[ATF-SAFE] Verified " & $auditedFiles & " generated C module(s) (" &
      $gSafety.stats.cLinesAudited & " lines, " &
      $gSafety.stats.procsBorrowChecked & " borrow-checked procs) — 0 memory-safety violations.",
      {msgStdout}
    )
