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

proc hasTrustedUnsafePragma*(pragmas: PNode): bool =
  if pragmas == nil or pragmas.kind == nkEmpty:
    return false
  for i in 0 ..< pragmas.safeLen:
    let it = pragmas[i]
    var key = if it.kind in nkPragmaCallKinds and it.len > 0: it[0] else: it
    if key.kind == nkIdent and key.ident != nil and cmpIgnoreStyle(key.ident.s, "trustedUnsafe") == 0:
      return true
    elif key.kind == nkSym and key.sym != nil and cmpIgnoreStyle(key.sym.name.s, "trustedUnsafe") == 0:
      return true
  false

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

proc isRawPointerType(t: PType): bool =
  if t == nil:
    return false
  let base = t.skipTypes({tyGenericInst, tyAlias, tyDistinct, tySink, tyLent, tyVar, tyOwned})
  base.kind in {tyPtr, tyPointer}

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
      if s == nil or isGenericRoutine(s):
        return
      if sfForward in s.flags or sfImportc in s.flags:
        if sfImportc in s.flags and gSafety.memSafeEnabled and not inTrusted and
           not hasTrustedUnsafePragma(s.ast[pragmasPos]) and not nodeFromStdlib:
          reportSafetyError(
            conf, s.info, "MEM-SAFE-004",
            "Raw C importc '" & s.name.s & "' requires '{.trustedUnsafe.}' in --mem-safe mode"
          )
        return
      if hasTrustedUnsafePragma(s.ast[pragmasPos]):
        return
      inc gSafety.stats.procsChecked
      auditProcSignature(graph, s)
      if n.len > bodyPos and n[bodyPos] != nil and n[bodyPos].kind != nkEmpty:
        let body = n[bodyPos]
        if gSafety.memSafeEnabled and s.kind in {skProc, skFunc, skMethod, skConverter}:
          var partitions = computeGraphPartitions(s, body, graph, {borrowChecking, constParameters})
          checkBorrowedLocations(partitions, body, conf)
          inc gSafety.stats.procsBorrowChecked
        auditNode(graph, module, body, s, isTopLevel = false, inTrusted = false)
    return

  of nkPragma:
    if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib:
      for i in 0 ..< n.safeLen:
        if whichPragma(n[i]) == wEmit:
          reportSafetyError(
            conf, n[i].info, "MEM-SAFE-004",
            "Inline C/ASM '{.emit.}' is forbidden in --mem-safe mode (annotate with {.trustedUnsafe.} if audited)"
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
          if def[j].kind == nkSym:
            let sym = def[j].sym
            if sfGenSym in sym.flags or sym.name.s.startsWith(":"):
              continue
            if gSafety.memSafeEnabled and not inTrusted and not nodeFromStdlib:
              if isRawPointerType(sym.typ):
                reportSafetyError(
                  conf, sym.info, "MEM-SAFE-002",
                  "Raw pointer variable '" & sym.name.s & "' is forbidden in --mem-safe mode"
                )
              if n.kind == nkVarSection and (isTopLevel or sfGlobal in sym.flags) and
                 sfThread notin sym.flags and not isSafeWrapperType(sym.typ):
                reportSafetyError(
                  conf, sym.info, "MEM-SAFE-005",
                  "Mutable global variable '" & sym.name.s &
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
    if gSafety.memSafeEnabled and not inTrusted and n.len > 0 and n[0].kind == nkSym:
      let callee = n[0].sym
      let fromAllocTemplate = isTrustedRuntimePath(conf, n.info) and
        normSlash(toFullPath(conf, n.info)).endsWith("/system/memalloc.nim")
      if (not nodeFromStdlib or fromAllocTemplate) and callee.name.s in BannedUnsafeMemProcs:
        let calleeMod = astalgo.getModule(callee)
        if calleeMod == nil or sfSystemModule in calleeMod.flags or belongsToStdlib(graph, calleeMod):
          reportSafetyError(
            conf, n.info, "MEM-SAFE-003",
            "Raw memory procedure '" & callee.name.s & "' is forbidden in --mem-safe mode"
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

  if not gSafety.memSafeEnabled and not gSafety.safeModeEnabled:
    return
  if semNode == nil or semNode.kind == nkEmpty:
    return

  inc gSafety.stats.astModulesChecked
  auditNode(graph, module, semNode, ownerProc = nil, isTopLevel = true, inTrusted = false)
