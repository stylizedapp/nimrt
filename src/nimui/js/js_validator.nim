## src/nimui/js/js_validator.nim
##
## Project Philosophy Validator for QuickJS Scripts:
## - Rust Safety:   Requires strict mode, forbids `var`, loose `==`/`!=`, `eval`,
##                  `Function`, `with`, and `__proto__` mutation.
## - Zig Explicitness: Enforces explicit capability sets (`dom`, `timers`, `nim`, `console`).
## - Python Simplicity: Keeps valid declarative/functional JS clean with zero hidden magic.

import corex/result

type
  JsCapability* = enum
    jcDom = "dom"
    jcTimers = "timers"
    jcStorage = "storage"
    jcNetwork = "network"
    jcFs = "fs"
    jcProcess = "process"
    jcNimBridge = "nim"
    jcConsole = "console"

  JsCapabilities* = set[JsCapability]

  JsValidationConfig* = object
    forbidVar*: bool
    forbidLooseEquality*: bool
    forbidEvalAndWith*: bool
    forbidDynamicImports*: bool
    requireExplicitCaps*: bool
    allowedCaps*: JsCapabilities

proc defaultJsValidationConfig*(
  caps: JsCapabilities = {jcDom, jcTimers, jcNimBridge, jcConsole}
): JsValidationConfig {.inline, raises: [].} =
  JsValidationConfig(
    forbidVar: true,
    forbidLooseEquality: true,
    forbidEvalAndWith: true,
    forbidDynamicImports: true,
    requireExplicitCaps: true,
    allowedCaps: caps
  )

proc isJsSpace(c: char): bool {.inline, raises: [].} =
  c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\f' or c == '\v'

proc isIdentStart(c: char): bool {.inline, raises: [].} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$'

proc isIdentCont(c: char): bool {.inline, raises: [].} =
  isIdentStart(c) or (c >= '0' and c <= '9')

proc toLowerAsciiSimple(s: string): string {.raises: [].} =
  result = newString(s.len)
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      result[i] = char(ord(c) + 32)
    else:
      result[i] = c

proc stripAsciiSimple(s: string): string {.raises: [].} =
  var a = 0
  var b = s.len - 1
  while a <= b and isJsSpace(s[a]): inc a
  while b >= a and isJsSpace(s[b]): dec b
  if a > b: return ""
  s[a .. b]

proc parseScriptCaps*(capsStr: string): Result[JsCapabilities, string] {.raises: [].} =
  ## Parses explicit comma-separated capabilities (e.g. "dom,timers,nim,console").
  let trimmed = stripAsciiSimple(capsStr)
  if trimmed.len == 0:
    return ok[JsCapabilities, string]({jcDom, jcConsole})

  var caps: JsCapabilities = {}
  var i = 0
  while i <= trimmed.len:
    var start = i
    while i < trimmed.len and trimmed[i] != ',':
      inc i
    let tok = toLowerAsciiSimple(stripAsciiSimple(trimmed[start ..< i]))
    if tok.len > 0:
      case tok
      of "dom": caps.incl(jcDom)
      of "timers": caps.incl(jcTimers)
      of "storage": caps.incl(jcStorage)
      of "network": caps.incl(jcNetwork)
      of "fs": caps.incl(jcFs)
      of "process": caps.incl(jcProcess)
      of "nim", "nimbridge": caps.incl(jcNimBridge)
      of "console": caps.incl(jcConsole)
      of "all": caps = {jcDom, jcTimers, jcNimBridge, jcConsole}
      of "none": caps = {}
      else:
        return err[JsCapabilities, string](
          "Zig-Explicitness Violation [JS-Z00]: unknown capability '" & tok &
          "' (expected dom, timers, storage, network, fs, process, nim, console, all, none)"
        )
    inc i
  ok[JsCapabilities, string](caps)

type
  PrevTokenKind = enum
    ptStartOrOp
    ptValueOrClose

proc validateJsPhilosophy*(
  code: string,
  cfg: JsValidationConfig = defaultJsValidationConfig()
): Result[void, string] {.raises: [].} =
  var i = 0
  var line = 1
  var afterDot = false
  var prevTok = ptStartOrOp
  var braceDepth = 0
  var tplBraceStack: seq[int] = @[]
  var inTemplateText = false

  while i < code.len:
    if inTemplateText:
      let c = code[i]
      if c == '\n':
        inc line
        inc i
      elif c == '\\' and i + 1 < code.len:
        if code[i + 1] == '\n': inc line
        i += 2
      elif c == '`':
        inTemplateText = false
        prevTok = ptValueOrClose
        afterDot = false
        inc i
      elif c == '$' and i + 1 < code.len and code[i + 1] == '{':
        inTemplateText = false
        tplBraceStack.add(braceDepth)
        inc braceDepth
        prevTok = ptStartOrOp
        afterDot = false
        i += 2
      else:
        inc i
      continue

    let c = code[i]

    if c == '\n':
      inc line
      inc i
      continue

    if isJsSpace(c):
      inc i
      continue

    # Comments
    if c == '/' and i + 1 < code.len:
      if code[i + 1] == '/':
        i += 2
        while i < code.len and code[i] != '\n':
          inc i
        continue
      elif code[i + 1] == '*':
        i += 2
        while i + 1 < code.len and not (code[i] == '*' and code[i + 1] == '/'):
          if code[i] == '\n': inc line
          inc i
        if i + 1 < code.len: i += 2
        else: i = code.len
        continue
      elif prevTok == ptStartOrOp:
        # Regex literal /.../
        i += 1
        var inClass = false
        while i < code.len and code[i] != '\n':
          let rc = code[i]
          if rc == '\\' and i + 1 < code.len:
            i += 2
            continue
          elif rc == '[':
            inClass = true
          elif rc == ']':
            inClass = false
          elif rc == '/' and not inClass:
            inc i
            while i < code.len and isIdentStart(code[i]):
              inc i
            break
          inc i
        prevTok = ptValueOrClose
        afterDot = false
        continue

    # Single or double quoted string literals
    if c == '\'' or c == '"':
      let q = c
      inc i
      while i < code.len:
        let sc = code[i]
        if sc == '\n':
          inc line
          inc i
          break
        if sc == '\\' and i + 1 < code.len:
          if code[i + 1] == '\n': inc line
          i += 2
          continue
        if sc == q:
          inc i
          break
        inc i
      prevTok = ptValueOrClose
      afterDot = false
      continue

    # Template literal start
    if c == '`':
      inTemplateText = true
      inc i
      continue

    # Braces (handling ${...} template re-entry)
    if c == '{':
      inc braceDepth
      prevTok = ptStartOrOp
      afterDot = false
      inc i
      continue

    if c == '}':
      if braceDepth > 0:
        dec braceDepth
      if tplBraceStack.len > 0 and tplBraceStack[^1] == braceDepth:
        discard tplBraceStack.pop()
        inTemplateText = true
      prevTok = ptValueOrClose
      afterDot = false
      inc i
      continue

    # Dot property access tracking
    if c == '.':
      afterDot = true
      prevTok = ptStartOrOp
      inc i
      continue

    # Strict equality checks (forbid == and != unless === or !==)
    if (c == '=' or c == '!') and i + 1 < code.len and code[i + 1] == '=':
      if i + 2 < code.len and code[i + 2] == '=':
        i += 3
        prevTok = ptStartOrOp
        afterDot = false
        continue
      else:
        if cfg.forbidLooseEquality:
          let op = if c == '=': "==" else: "!="
          let strictOp = if c == '=': "===" else: "!=="
          return err[void, string](
            "Rust-Safety Violation [JS-R02] (line " & $line & "): loose equality '" &
            op & "' is forbidden; use strict '" & strictOp & "'"
          )
        i += 2
        prevTok = ptStartOrOp
        afterDot = false
        continue

    # Identifiers & keywords
    if isIdentStart(c):
      let start = i
      inc i
      while i < code.len and isIdentCont(code[i]):
        inc i
      let ident = code[start ..< i]

      if cfg.forbidEvalAndWith and (ident == "__proto__" or ident == "setPrototypeOf"):
        return err[void, string](
          "Rust-Safety Violation [JS-R03] (line " & $line &
          "): prototype mutation via '" & ident & "' is forbidden"
        )

      var k = i
      while k < code.len and isJsSpace(code[k]):
        inc k
      let isPropKey = k < code.len and code[k] == ':'

      if not afterDot and not isPropKey:
        if cfg.forbidVar and ident == "var":
          return err[void, string](
            "Rust-Safety Violation [JS-R01] (line " & $line &
            "): 'var' is forbidden; use immutable 'const' or block-scoped 'let'"
          )
        if cfg.forbidEvalAndWith and (ident in ["eval", "Function", "with", "Proxy", "Reflect"]):
          return err[void, string](
            "Rust-Safety Violation [JS-R03] (line " & $line &
            "): dynamic/unsafe construct '" & ident & "' is forbidden"
          )
        if cfg.forbidDynamicImports and ident == "import":
          return err[void, string](
            "Rust-Safety Violation [JS-R04] (line " & $line &
            "): module/dynamic 'import' is forbidden in sandboxed scripts"
          )

        if cfg.requireExplicitCaps:
          if ident in ["setTimeout", "setInterval", "clearTimeout", "clearInterval"]:
            if jcTimers notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z01] (line " & $line &
                "): '" & ident & "' used without explicit 'timers' capability"
              )
          elif ident == "Nim":
            if jcNimBridge notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z02] (line " & $line &
                "): 'Nim' bridge used without explicit 'nim' capability"
              )
          elif ident == "document" or ident == "ui":
            if jcDom notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z03] (line " & $line &
                "): '" & ident & "' used without explicit 'dom' capability"
              )
          elif ident == "console":
            if jcConsole notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z04] (line " & $line &
                "): 'console' used without explicit 'console' capability"
              )
          elif ident in ["localStorage", "sessionStorage", "storage"]:
            if jcStorage notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z06] (line " & $line &
                "): '" & ident & "' used without explicit 'storage' capability"
              )
          elif ident in ["fetch", "XMLHttpRequest", "WebSocket", "network"]:
            if jcNetwork notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z07] (line " & $line &
                "): '" & ident & "' used without explicit 'network' capability"
              )
          elif ident in ["fs", "readFile", "writeFile"]:
            if jcFs notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z08] (line " & $line &
                "): '" & ident & "' used without explicit 'fs' capability"
              )
          elif ident in ["process", "child_process", "exec", "spawn"]:
            if jcProcess notin cfg.allowedCaps:
              return err[void, string](
                "Zig-Explicitness Violation [JS-Z09] (line " & $line &
                "): '" & ident & "' used without explicit 'process' capability"
              )

      afterDot = false
      prevTok = if ident in ["return", "throw", "typeof", "void", "delete", "new", "case", "else"]:
                  ptStartOrOp
                else:
                  ptValueOrClose
      continue

    # Numeric literals
    if c >= '0' and c <= '9':
      while i < code.len and (isIdentCont(code[i]) or code[i] == '.'):
        inc i
      prevTok = ptValueOrClose
      afterDot = false
      continue

    # Closing parens/brackets allow division next rather than regex
    if c == ')' or c == ']':
      prevTok = ptValueOrClose
    else:
      prevTok = ptStartOrOp

    afterDot = false
    inc i

  ok[void, string]()
