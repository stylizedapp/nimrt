## compiler/mem_safe_pass.nim
##
## Static AST & Borrow-Safety Audit Pass for `--mem-safe` and `--safe-mode`.
## Enforces:
## - [MEM-SAFE-001] Forbid unsafe type casts `cast[T](x)`
## - [MEM-SAFE-002] Forbid raw `ptr T` / `pointer` types and dereferences
## - [MEM-SAFE-003] Forbid raw heap/memory ops (`alloc`, `dealloc`, `copyMem`, `moveMem`, `zeroMem`, `unsafeAddr`)
## - [MEM-SAFE-004] Forbid inline C/ASM `{.emit.}` in safe user code
## - [MEM-SAFE-005] Forbid unprotected mutable module-level globals (require `let`/`const`/`threadvar`)
## - [MEM-SAFE-006] Forbid stack address escape (`addr local` / returning local pointers)
## - [MEM-SAFE-007] Forbid disabling runtime checks via `{.push checks: off.}` / `{.checks: off.}` / `{.boundChecks: off.}`
## - Borrow checking via `varpartitions.computeGraphPartitions` + `checkBorrowedLocations`
## - [SAFE-MODE-001] Forbid `raise` statements in `--safe-mode` (use `Result[T, E]` / `Option[T]`)
## - [SAFE-MODE-002] Enforce exception-free signatures (`{.raises: [].}`) on user procedures
## - [SAFE-MODE-003] Reject silent `discard` of `Result[T, E]` / `Option[T]` in strict mode
##
## Escape hatch: procedures or blocks annotated with `{.trustedUnsafe.}` are
## explicitly permitted (analogous to Rust `unsafe {}`).

import std/[strutils, sets]
import ast, astalgo, types, options, msgs, lineinfos, renderer, modulegraphs, pathutils
import varpartitions, wordrecg
from trees import whichPragma
import safety_config

const
  BannedUnsafeMemProcs = [
    "alloc", "alloc0", "realloc", "realloc0", "dealloc",
    "allocImpl", "alloc0Impl", "reallocImpl", "realloc0Impl", "deallocImpl",
    "allocShared", "allocShared0", "reallocShared", "reallocShared0", "deallocShared",
    "allocSharedImpl", "allocShared0Impl", "reallocSharedImpl", "reallocShared0Impl",
    "create", "createU", "createShared", "createSharedU", "resize", "resizeShared",
    "copyMem", "moveMem", "zeroMem", "equalMem", "cmpMem",
    "unsafeAddr"
  ]

proc normSlash(p: string): string =
  p.replace('\\', '/')

proc isTrustedRuntimePath(conf: ConfigRef; info: TLineInfo): bool =
  if info == unknownLineInfo or info.fileIndex == InvalidFileIdx:
    return false
  let fullPath = normSlash(toFullPath(conf, info))
  let libDir = normSlash(conf.libpath.string)
  if libDir.len > 0 and fullPath.startsWith(libDir):
    return true
  if not gSafety.strictMode and (fullPath.contains("/src/corex/") or fullPath.contains("/src/algx/")):
    return true
  false

proc isUserAuditedModule*(graph: ModuleGraph; module: PSym): bool =
  if module == nil:
    return false
  if sfSystemModule in module.flags:
    return false
  if belongsToStdlib(graph, module):
    return false
  let fullPath = normSlash(toFullPath(graph.config, module.fileIdx))
  if fullPath.len == 0:
    return false
  let libDir = normSlash(graph.config.libpath.string)
  if libDir.len > 0 and fullPath.startsWith(libDir):
    return false
  if not gSafety.strictMode and (fullPath.contains("/src/corex/") or fullPath.contains("/src/algx/")):
    return false
  true

proc hasPragmaNamed(pragmas: PNode; name: string): bool =
  if pragmas == nil or pragmas.kind == nkEmpty:
    return false
  for i in 0 ..< pragmas.safeLen:
    let it = pragmas[i]
    var key = if it.kind in nkPragmaCallKinds and it.len > 0: it[0] else: it
    if key.kind == nkIdent and key.ident != nil and cmpIgnoreStyle(key.ident.s, name) == 0:
      return true
    elif key.kind == nkSym and key.sym != nil and cmpIgnoreStyle(key.sym.name.s, name) == 0:
      return true
  false

proc hasTrustedUnsafePragma*(pragmas: PNode): bool =
  hasPragmaNamed(pragmas, "trustedUnsafe")

proc isTrustedBlockStmt(n: PNode): bool =
  ## Supports `{.trustedUnsafe.}: ...` pragma block or `block trustedUnsafe: ...` syntax.
  if n.kind == nkPragmaBlock and n.len >= 2:
    return hasTrustedUnsafePragma(n[0])
  if n.kind in {nkBlockStmt, nkBlockExpr} and n.len >= 1:
    let lbl = n[0]
    if lbl.kind == nkSym and lbl.sym != nil and cmpIgnoreStyle(lbl.sym.name.s, "trustedUnsafe") == 0:
      return true
    elif lbl.kind == nkIdent and lbl.ident != nil and cmpIgnoreStyle(lbl.ident.s, "trustedUnsafe") == 0:
      return true
  false

proc reportSafetyError(conf: ConfigRef; info: TLineInfo; code, msg: string) =
  inc gSafety.stats.astViolations
  localError(conf, info, "[" & code & "] " & msg)

proc recordCheckSuppression(conf: ConfigRef; info: TLineInfo; msg: string) =
  if gSafety.memSafeEnabled:
    reportSafetyError(conf, info, "MEM-SAFE-007", msg)
  if gSafety.checkSafeAtfEnabled:
    gSafety.checkSuppressions.add(CheckSuppression(
      file: toFullPath(conf, info),
      line: info.line.int,
      detail: msg
    ))

proc isCheckSuppressionPragmaItem(item: PNode): bool =
  if item == nil or item.kind == nkEmpty:
    return false
  let w = whichPragma(item)
  if w notin {wChecks, wBoundChecks, wOverflowChecks, wRangeChecks,
              wObjChecks, wFieldChecks, wNilChecks}:
    return false
  if item.kind in nkPragmaCallKinds and item.len >= 2:
    let val = item[1]
    if val.kind == nkIdent and val.ident != nil and cmpIgnoreStyle(val.ident.s, "off") == 0:
      return true
    if val.kind == nkSym and val.sym != nil and cmpIgnoreStyle(val.sym.name.s, "off") == 0:
      return true
    if val.kind in {nkCharLit .. nkUInt64Lit} and val.intVal == 0:
      return true
  false

proc isRawPointerType(t: PType): bool =
  if t == nil:
    return false
  let base = t.skipTypes({tyGenericInst, tyAlias, tyDistinct, tySink, tyLent, tyVar, tyOwned})
  base.kind in {tyPtr, tyPointer}

proc isRawPointerTypeNode(typNode: PNode): bool =
  if typNode == nil or typNode.kind == nkEmpty:
    return false
  if typNode.typ != nil and isRawPointerType(typNode.typ):
    return true
  case typNode.kind
  of nkPtrTy:
    return true
  of nkIdent:
    return typNode.ident != nil and typNode.ident.s == "pointer"
  of nkSym:
    return typNode.sym != nil and typNode.sym.name.s == "pointer"
  else:
    return false

proc extractIdentDefInfo(node: PNode): tuple[name: string, sym: PSym, pragmas: PNode] =
  var cur = node
  while cur != nil:
    case cur.kind
    of nkSym:
      return (cur.sym.name.s, cur.sym, result.pragmas)
    of nkIdent:
      let n = if cur.ident != nil: cur.ident.s else: ""
      return (n, nil, result.pragmas)
    of nkPragmaExpr:
      if cur.len >= 2:
        result.pragmas = cur[1]
        cur = cur[0]
      else:
        return ("", nil, nil)
    of nkPostfix:
      if cur.len >= 2:
        cur = cur[1]
      else:
        return ("", nil, nil)
    else:
      return ("", nil, nil)
  ("", nil, nil)

proc extractCalleeName(n: PNode): string =
  if n == nil:
    return ""
  case n.kind
  of nkSym:
    if n.sym != nil: return n.sym.name.s
  of nkIdent:
    if n.ident != nil: return n.ident.s
  of nkOpenSymChoice, nkClosedSymChoice:
    if n.len > 0 and n[0].kind == nkSym and n[0].sym != nil:
      return n[0].sym.name.s
  else:
    discard
  ""

proc isLocalStackSym(owner: PSym; s: PSym): bool =
  if s == nil or owner == nil:
    return false
  if s.kind notin {skVar, skLet, skParam, skTemp, skForVar}:
    return false
  if sfGlobal in s.flags or sfThread in s.flags:
    return false
  s.owner == owner

proc extractAddrBaseSym(n: PNode): PSym =
  var cur = n
  while cur != nil:
    case cur.kind
    of nkSym:
      return cur.sym
    of nkDotExpr, nkBracketExpr, nkObjUpConv, nkObjDownConv, nkCheckedFieldExpr,
       nkHiddenStdConv, nkHiddenSubConv, nkConv:
      if cur.len > 0:
        cur = cur[0]
      else:
        return nil
    else:
      return nil
  nil

proc containsLocalAddrEscape(n: PNode; owner: PSym; escapedName: var string): bool =
  if n == nil:
    return false
  case n.kind
  of nkAddr, nkHiddenAddr:
    if n.len > 0:
      let s = extractAddrBaseSym(n[0])
      if isLocalStackSym(owner, s):
        escapedName = s.name.s
        return true
  of nkStmtList, nkStmtListExpr, nkIfExpr, nkIfStmt, nkElifBranch, nkElse, nkCaseStmt, nkOfBranch:
    for i in 0 ..< n.safeLen:
      if containsLocalAddrEscape(n[i], owner, escapedName):
        return true
  else:
    discard
  false

proc isResultOrOptionType(t: PType): bool =
  if t == nil:
    return false
  let base = t.skipTypes({tyGenericInst, tyAlias, tySink})
  if base.sym != nil:
    let name = base.sym.name.s
    if name == "Result" or name == "Option":
      return true
  if t.kind == tyGenericInst and t.len > 0 and t[0].sym != nil:
    let name = t[0].sym.name.s
    if name == "Result" or name == "Option":
      return true
  false

proc isSafeWrapperType(t: PType): bool =
  if t == nil:
    return false
  var name = ""
  if t.sym != nil:
    name = t.sym.name.s
  elif t.kind == tyGenericInst and t.len > 0 and t[0].sym != nil:
    name = t[0].sym.name.s
  name in ["Atomic", "SysLock", "RwLock", "SpinLock", "Barrier", "WaitGroup"]

proc auditProcSignature(graph: ModuleGraph; s: PSym) =
  if s == nil or s.typ == nil:
    return
  let conf = graph.config
  if gSafety.memSafeEnabled:
    let params = s.typ.n
    if params != nil:
      for i in 1 ..< params.safeLen:
        if params[i].kind == nkSym:
          let pSym = params[i].sym
          if isRawPointerType(pSym.typ):
            reportSafetyError(
              conf, pSym.info, "MEM-SAFE-002",
              "Raw pointer parameter '" & pSym.name.s & "' is forbidden in --mem-safe mode; use 'ref', 'Owned[T]', or 'Span[T]'"
            )
    if s.typ.returnType != nil and isRawPointerType(s.typ.returnType):
      reportSafetyError(
        conf, s.info, "MEM-SAFE-002",
        "Returning raw pointer from '" & s.name.s & "' is forbidden in --mem-safe mode"
      )

  if gSafety.safeModeEnabled and s.kind in {skProc, skFunc, skMethod, skConverter}:
    if s.typ.n != nil and s.typ.n.len > 0 and s.typ.n[0].kind == nkEffectList:
      let eff = s.typ.n[0]
      if eff.len > exceptionEffects and eff[exceptionEffects] != nil:
        let excList = eff[exceptionEffects]
        if excList.len > 0:
          var names: seq[string] = @[]
          for i in 0 ..< excList.len:
            if excList[i].typ != nil:
              names.add(typeToString(excList[i].typ))
          if names.len > 0:
            reportSafetyError(
              conf, s.info, "SAFE-MODE-002",
              "Procedure '" & s.name.s & "' may raise [" & names.join(", ") &
              "]; --safe-mode requires '{.raises: [].}' with explicit Result[T, E] / Option[T]"
            )

proc auditNode*(
  graph: ModuleGraph;
  module: PSym;
  n: PNode;
  ownerProc: PSym;
  isTopLevel: bool;
  inTrusted: bool
) =
  if n == nil or n.kind == nkEmpty:
    return

  if not inTrusted and isTrustedBlockStmt(n):
    return

  let conf = graph.config
  let nodeFromStdlib = isTrustedRuntimePath(conf, n.info)

  case n.kind
  of nkProcDef, nkFuncDef, nkMethodDef, nkConverterDef, nkIteratorDef:
    if n.len > namePos and n[namePos].kind == nkSym:
      let s = n[namePos].sym
      if s == nil:
        return
      let isGeneric = isGenericRoutine(s)
      if sfForward in s.flags or sfImportc in s.flags:
        if sfImportc in s.flags and gSafety.memSafeEnabled and not inTrusted and
           not hasTrustedUnsafePragma(s.ast[pragmasPos]) and not nodeFromStdlib:
          reportSafetyError(
            conf, s.info, "MEM-SAFE-004",
            "Raw C importc '" & s.name.s & "' requires '{.trustedUnsafe.}' in --mem-safe mode"
          )
        return
      let hasTrusted = hasTrustedUnsafePragma(s.ast[pragmasPos]) or
        (n.len > pragmasPos and hasTrustedUnsafePragma(n[pragmasPos]))
      if hasTrusted:
        return
      if not inTrusted and not nodeFromStdlib:
        if (conf.options * {optBoundsCheck, optOverflowCheck}) - s.options != {}:
          recordCheckSuppression(
            conf, s.info,
            "Procedure '" & s.name.s & "' has runtime bounds/overflow checks disabled (e.g. via {.push checks: off.} or {.checks: off.})"
          )
        if n.len > pragmasPos:
          auditNode(graph, module, n[pragmasPos], s, isTopLevel = false, inTrusted = false)
      inc gSafety.stats.procsChecked
      auditProcSignature(graph, s)
      if n.len > bodyPos and n[bodyPos] != nil and n[bodyPos].kind != nkEmpty:
        let body = n[bodyPos]
        if not isGeneric and gSafety.memSafeEnabled and s.kind in {skProc, skFunc, skMethod, skConverter}:
          var partitions = computeGraphPartitions(s, body, graph, {borrowChecking, constParameters})
          checkBorrowedLocations(partitions, body, conf)
          inc gSafety.stats.procsBorrowChecked
        auditNode(graph, module, body, s, isTopLevel = false, inTrusted = false)
    else:
      let hasTrusted = n.len > pragmasPos and hasTrustedUnsafePragma(n[pragmasPos])
      if hasTrusted:
        return
      if not inTrusted and not nodeFromStdlib and n.len > pragmasPos:
        auditNode(graph, module, n[pragmasPos], ownerProc, isTopLevel = false, inTrusted = false)
      if n.len > bodyPos and n[bodyPos] != nil and n[bodyPos].kind != nkEmpty:
        auditNode(graph, module, n[bodyPos], ownerProc, isTopLevel = false, inTrusted = false)
    return

  of nkPragma:
    if not inTrusted and not nodeFromStdlib:
      for i in 0 ..< n.safeLen:
        if gSafety.memSafeEnabled and whichPragma(n[i]) == wEmit:
          reportSafetyError(
            conf, n[i].info, "MEM-SAFE-004",
            "Inline C/ASM '{.emit.}' is forbidden in --mem-safe mode (annotate with {.trustedUnsafe.} if audited)"
          )
        elif isCheckSuppressionPragmaItem(n[i]):
          recordCheckSuppression(
            conf, n[i].info,
            "Disabling runtime safety checks via pragma ('" & renderTree(n[i], {renderNoComments}) & "') is forbidden in safe mode"
          )
    return

  of nkCast:
    if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib:
      reportSafetyError(
        conf, n.info, "MEM-SAFE-001",
        "Unsafe type cast '" & renderTree(n, {renderNoComments}) & "' is forbidden in --mem-safe mode"
      )

  of nkAddr:
    if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib:
      reportSafetyError(
        conf, n.info, "MEM-SAFE-006",
        "Taking raw pointer address via 'addr' is forbidden in --mem-safe mode; use 'var'/'lent' or 'Owned[T]'"
      )

  of nkDerefExpr, nkHiddenDeref:
    if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib and n.len > 0:
      if isRawPointerType(n[0].typ):
        reportSafetyError(
          conf, n.info, "MEM-SAFE-002",
          "Dereferencing raw pointer '" & renderTree(n[0], {renderNoComments}) & "' is forbidden in --mem-safe mode"
        )

  of nkBracketExpr:
    if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib and n.len > 0:
      if isRawPointerType(n[0].typ):
        reportSafetyError(
          conf, n.info, "MEM-SAFE-002",
          "Unchecked pointer indexing '" & renderTree(n, {renderNoComments}) & "' is forbidden in --mem-safe mode"
        )

  of nkVarSection, nkLetSection:
    for i in 0 ..< n.safeLen:
      let def = n[i]
      if def.kind == nkIdentDefs:
        for j in 0 ..< max(0, def.len - 2):
          let infoItem = extractIdentDefInfo(def[j])
          let sym = infoItem.sym
          let varName = infoItem.name
          if sym != nil and (sfGenSym in sym.flags or sym.name.s.startsWith(":")):
            continue
          if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib and varName.len > 0:
            let errInfo = if sym != nil: sym.info else: def[j].info
            let isRawPtr = (sym != nil and isRawPointerType(sym.typ)) or
                           ((sym == nil or sym.typ == nil) and def.len >= 2 and isRawPointerTypeNode(def[^2]))
            if isRawPtr:
              reportSafetyError(
                conf, errInfo, "MEM-SAFE-002",
                "Raw pointer variable '" & varName & "' is forbidden in --mem-safe mode"
              )
            let isGlobalVar = isTopLevel or
                              (sym != nil and sfGlobal in sym.flags) or
                              hasPragmaNamed(infoItem.pragmas, "global")
            let isThreadVar = (sym != nil and sfThread in sym.flags) or
                              hasPragmaNamed(infoItem.pragmas, "threadvar")
            if n.kind == nkVarSection and isGlobalVar and not isThreadVar and
               not (sym != nil and isSafeWrapperType(sym.typ)):
              reportSafetyError(
                conf, errInfo, "MEM-SAFE-005",
                "Mutable global variable '" & varName &
                "' is forbidden in --mem-safe mode; use 'let'/'const', '{.threadvar.}', or 'Atomic[T]'"
              )
        # Audit initializer expression
        if def.len > 0:
          auditNode(graph, module, def[^1], ownerProc, isTopLevel = false, inTrusted = inTrusted)
    return

  of nkReturnStmt:
    if gSafety.memSafeEnabled and not inTrusted and ownerProc != nil and n.len > 0:
      var escapedName = ""
      if containsLocalAddrEscape(n[0], ownerProc, escapedName):
        reportSafetyError(
          conf, n.info, "MEM-SAFE-006",
          "Stack address escape: cannot return address of local variable '" & escapedName & "'"
        )

  of nkAsgn, nkFastAsgn:
    if gSafety.memSafeEnabled and not inTrusted and ownerProc != nil and n.len >= 2:
      if n[0].kind == nkSym and n[0].sym.kind == skResult:
        var escapedName = ""
        if containsLocalAddrEscape(n[1], ownerProc, escapedName):
          reportSafetyError(
            conf, n.info, "MEM-SAFE-006",
            "Stack address escape: cannot assign address of local variable '" & escapedName & "' to 'result'"
          )

  of nkRaiseStmt:
    if gSafety.safeModeEnabled and not inTrusted and not nodeFromStdlib:
      reportSafetyError(
        conf, n.info, "SAFE-MODE-001",
        "Exceptions ('raise') are forbidden in --safe-mode; return Result[T, E] or Option[T]"
      )

  of nkDiscardStmt:
    if gSafety.safeModeEnabled and gSafety.strictMode and not inTrusted and not nodeFromStdlib and n.len > 0:
      if n[0].kind != nkEmpty and isResultOrOptionType(n[0].typ):
        reportSafetyError(
          conf, n.info, "SAFE-MODE-003",
          "Silent 'discard' of Result/Option value is forbidden in strict --safe-mode"
        )

  of nkCallKinds:
    if gSafety.memSafeEnabled and not inTrusted and n.len > 0:
      let fromAllocTemplate = isTrustedRuntimePath(conf, n.info) and
        normSlash(toFullPath(conf, n.info)).endsWith("/system/memalloc.nim")
      if n[0].kind == nkSym:
        let callee = n[0].sym
        if (not nodeFromStdlib or fromAllocTemplate) and callee.name.s in BannedUnsafeMemProcs:
          let calleeMod = astalgo.getModule(callee)
          if calleeMod == nil or sfSystemModule in calleeMod.flags or belongsToStdlib(graph, calleeMod):
            reportSafetyError(
              conf, n.info, "MEM-SAFE-003",
              "Raw memory procedure '" & callee.name.s & "' is forbidden in --mem-safe mode"
            )
        elif not nodeFromStdlib and callee.name.s == "addr":
          reportSafetyError(
            conf, n.info, "MEM-SAFE-006",
            "Taking raw pointer address via 'addr' is forbidden in --mem-safe mode; use 'var'/'lent' or 'Owned[T]'"
          )
      else:
        let calleeName = extractCalleeName(n[0])
        if (not nodeFromStdlib or fromAllocTemplate) and calleeName in BannedUnsafeMemProcs:
          var isStdlibChoice = n[0].kind == nkIdent
          if n[0].kind in {nkOpenSymChoice, nkClosedSymChoice}:
            for k in 0 ..< n[0].len:
              if n[0][k].kind == nkSym:
                let calleeMod = astalgo.getModule(n[0][k].sym)
                if calleeMod == nil or sfSystemModule in calleeMod.flags or belongsToStdlib(graph, calleeMod):
                  isStdlibChoice = true
                  break
          if isStdlibChoice:
            reportSafetyError(
              conf, n.info, "MEM-SAFE-003",
              "Raw memory procedure '" & calleeName & "' is forbidden in --mem-safe mode"
            )
        elif not nodeFromStdlib and calleeName == "addr":
          reportSafetyError(
            conf, n.info, "MEM-SAFE-006",
            "Taking raw pointer address via 'addr' is forbidden in --mem-safe mode; use 'var'/'lent' or 'Owned[T]'"
          )

  else:
    discard

  for i in 0 ..< n.safeLen:
    let childTop = isTopLevel and n.kind == nkStmtList
    auditNode(graph, module, n[i], ownerProc, childTop, inTrusted)

proc auditModuleSafety*(graph: ModuleGraph; module: PSym; semNode: PNode) =
  if graph == nil or module == nil:
    return
  if not isUserAuditedModule(graph, module):
    return

  gSafety.userModuleNames.incl(module.name.s)
  let modPath = toFullPath(graph.config, module.fileIdx)
  if modPath.len > 0:
    gSafety.userModuleCStems.incl(AbsoluteFile(modPath).splitFile().name)

  if not gSafety.memSafeEnabled and not gSafety.safeModeEnabled and not gSafety.checkSafeAtfEnabled:
    return
  if semNode == nil or semNode.kind == nkEmpty:
    return

  inc gSafety.stats.astModulesChecked
  auditNode(graph, module, semNode, ownerProc = nil, isTopLevel = true, inTrusted = false)
