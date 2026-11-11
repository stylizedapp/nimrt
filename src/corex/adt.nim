## corex/adt — Algebraic Data Types (Sum Types), Pattern Matching (`match`), and `Option[T]`
##
## Eliminates Nim's verbose `case object` boilerplate with clean Rust-style `enum`
## syntax, generic sum types, automatic equality, and bidirectional Result interop.

import std/macros
import std/strutils
import ./result
export result

type FieldDesc = object
  name: NimNode
  typ: NimNode

proc parseVariantFields(branch: NimNode): seq[FieldDesc] =
  result = @[]
  if branch.kind in {nnkCall, nnkObjConstr}:
    var pendingNames: seq[NimNode] = @[]
    for i in 1 ..< branch.len:
      let arg = branch[i]
      if arg.kind == nnkIdent:
        pendingNames.add(arg)
      elif arg.kind == nnkExprColonExpr:
        let typ = arg[1]
        for pName in pendingNames:
          result.add(FieldDesc(name: pName, typ: typ))
        pendingNames.setLen(0)
        result.add(FieldDesc(name: arg[0], typ: typ))
      else:
        error("Unexpected variant field syntax: " & arg.repr, arg)
    if pendingNames.len > 0:
      error("Field without type in variant: " & pendingNames[0].repr, pendingNames[0])

macro sumType*(head, body: untyped): untyped =
  ## Creates an algebraic data type (Tagged Union) with variant constructors.
  ## Supports generic sum types (e.g., Option[T], Either[L, R]) and non-generic types.
  var typeIdent: NimNode
  var genericParamsDefs = nnkGenericParams.newTree()
  var genericArgs = newSeq[NimNode]()
  var isGeneric = false

  if head.kind == nnkIdent:
    typeIdent = head
  elif head.kind == nnkBracketExpr:
    typeIdent = head[0]
    isGeneric = true
    for i in 1 ..< head.len:
      let param = head[i]
      if param.kind == nnkExprColonExpr:
        genericParamsDefs.add(nnkIdentDefs.newTree(param[0], param[1], newEmptyNode()))
        genericArgs.add(param[0])
      elif param.kind == nnkIdent:
        genericParamsDefs.add(nnkIdentDefs.newTree(param, newEmptyNode(), newEmptyNode()))
        genericArgs.add(param)
      else:
        error("Unexpected generic parameter syntax: " & param.repr, param)
  else:
    error("Unexpected sumType head syntax: " & head.repr, head)

  let fullTypeExpr = if isGeneric:
    var be = nnkBracketExpr.newTree(typeIdent)
    for a in genericArgs: be.add(a)
    be
  else:
    typeIdent

  let kindEnumName = ident($typeIdent & "Kind")
  var enumFields = nnkEnumTy.newTree(newEmptyNode())
  var recCase = nnkRecCase.newTree(
    nnkIdentDefs.newTree(
      nnkPostfix.newTree(ident"*", ident"kind"),
      kindEnumName,
      newEmptyNode()
    )
  )
  var constructors = newStmtList()
  var eqBranches = newSeq[NimNode]()
  var strBranches = newSeq[NimNode]()

  for branch in body:
    let bName = if branch.kind == nnkIdent: branch else: branch[0]
    let kindVal = ident("k" & $bName)
    enumFields.add(kindVal)
    let fields = parseVariantFields(branch)

    if fields.len == 0:
      recCase.add(nnkOfBranch.newTree(kindVal, nnkRecList.newTree(newNilLit())))

      var procDef = nnkProcDef.newTree(
        nnkPostfix.newTree(ident"*", bName),
        newEmptyNode(),
        if isGeneric: genericParamsDefs.copyNimTree else: newEmptyNode(),
        nnkFormalParams.newTree(fullTypeExpr.copyNimTree),
        nnkPragma.newTree(ident"inline"),
        newEmptyNode(),
        newStmtList(
          nnkObjConstr.newTree(
            fullTypeExpr.copyNimTree,
            nnkExprColonExpr.newTree(ident"kind", kindVal)
          )
        )
      )
      constructors.add(procDef)

      # Typedesc overload for generic unit variants: None(int)
      if isGeneric and genericArgs.len == 1:
        let typedescParam = nnkIdentDefs.newTree(
          ident"_",
          nnkBracketExpr.newTree(ident"typedesc", genericArgs[0]),
          newEmptyNode()
        )
        var typedescProc = nnkProcDef.newTree(
          nnkPostfix.newTree(ident"*", bName),
          newEmptyNode(),
          genericParamsDefs.copyNimTree,
          nnkFormalParams.newTree(fullTypeExpr.copyNimTree, typedescParam),
          nnkPragma.newTree(ident"inline"),
          newEmptyNode(),
          newStmtList(
            nnkObjConstr.newTree(
              fullTypeExpr.copyNimTree,
              nnkExprColonExpr.newTree(ident"kind", kindVal)
            )
          )
        )
        constructors.add(typedescProc)

      eqBranches.add(nnkOfBranch.newTree(kindVal, ident"true"))
      strBranches.add(nnkOfBranch.newTree(kindVal, newLit($bName)))
    else:
      var branchRecList = nnkRecList.newTree()
      var formalParams = nnkFormalParams.newTree(fullTypeExpr.copyNimTree)
      var objConstr = nnkObjConstr.newTree(
        fullTypeExpr.copyNimTree,
        nnkExprColonExpr.newTree(ident"kind", kindVal)
      )
      var eqChecks = newSeq[NimNode]()
      var strParts = newSeq[NimNode]()
      strParts.add(newLit($bName & "("))

      for idx, f in fields:
        let internalField = ident($bName & "_" & $f.name)
        branchRecList.add(
          nnkIdentDefs.newTree(
            nnkPostfix.newTree(ident"*", internalField),
            f.typ,
            newEmptyNode()
          )
        )
        formalParams.add(nnkIdentDefs.newTree(f.name, nnkCommand.newTree(ident"sink", f.typ), newEmptyNode()))
        objConstr.add(nnkExprColonExpr.newTree(internalField, nnkCall.newTree(ident"move", f.name)))

        eqChecks.add(
          infix(
            newDotExpr(ident"a", internalField),
            "==",
            newDotExpr(ident"b", internalField)
          )
        )

        if idx > 0: strParts.add(newLit(", "))
        if fields.len > 1 or $f.name != "val":
          strParts.add(newLit($f.name & ": "))
        strParts.add(prefix(newDotExpr(ident"self", internalField), "$"))

      strParts.add(newLit(")"))
      recCase.add(nnkOfBranch.newTree(kindVal, branchRecList))

      var procDef = nnkProcDef.newTree(
        nnkPostfix.newTree(ident"*", bName),
        newEmptyNode(),
        if isGeneric: genericParamsDefs.copyNimTree else: newEmptyNode(),
        formalParams,
        nnkPragma.newTree(ident"inline"),
        newEmptyNode(),
        newStmtList(objConstr)
      )
      constructors.add(procDef)

      var eqExpr = eqChecks[0]
      for i in 1 ..< eqChecks.len:
        eqExpr = infix(eqExpr, "and", eqChecks[i])
      eqBranches.add(nnkOfBranch.newTree(kindVal, eqExpr))

      var strExpr = strParts[0]
      for i in 1 ..< strParts.len:
        strExpr = infix(strExpr, "&", strParts[i])
      strBranches.add(nnkOfBranch.newTree(kindVal, strExpr))

  # Generate == proc
  var eqCaseStmt = nnkCaseStmt.newTree(newDotExpr(ident"a", ident"kind"))
  for b in eqBranches: eqCaseStmt.add(b)
  let eqProcDef = nnkProcDef.newTree(
    nnkPostfix.newTree(ident"*", ident"=="),
    newEmptyNode(),
    if isGeneric: genericParamsDefs.copyNimTree else: newEmptyNode(),
    nnkFormalParams.newTree(
      ident"bool",
      nnkIdentDefs.newTree(ident"a", fullTypeExpr.copyNimTree, newEmptyNode()),
      nnkIdentDefs.newTree(ident"b", fullTypeExpr.copyNimTree, newEmptyNode())
    ),
    nnkPragma.newTree(ident"inline"),
    newEmptyNode(),
    newStmtList(
      nnkIfStmt.newTree(
        nnkElifBranch.newTree(
          infix(newDotExpr(ident"a", ident"kind"), "!=", newDotExpr(ident"b", ident"kind")),
          nnkReturnStmt.newTree(ident"false")
        )
      ),
      eqCaseStmt
    )
  )

  # Generate $ proc
  var strCaseStmt = nnkCaseStmt.newTree(newDotExpr(ident"self", ident"kind"))
  for b in strBranches: strCaseStmt.add(b)
  let strProcDef = nnkProcDef.newTree(
    nnkPostfix.newTree(ident"*", ident"$"),
    newEmptyNode(),
    if isGeneric: genericParamsDefs.copyNimTree else: newEmptyNode(),
    nnkFormalParams.newTree(
      ident"string",
      nnkIdentDefs.newTree(ident"self", fullTypeExpr.copyNimTree, newEmptyNode())
    ),
    nnkPragma.newTree(ident"inline"),
    newEmptyNode(),
    newStmtList(strCaseStmt)
  )

  result = newStmtList()
  result.add(
    nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        nnkPostfix.newTree(ident"*", kindEnumName),
        newEmptyNode(),
        enumFields
      ),
      nnkTypeDef.newTree(
        nnkPostfix.newTree(ident"*", typeIdent),
        if isGeneric: genericParamsDefs else: newEmptyNode(),
        nnkObjectTy.newTree(
          newEmptyNode(),
          newEmptyNode(),
          nnkRecList.newTree(recCase)
        )
      )
    )
  )
  result.add(constructors)
  result.add(eqProcDef)
  result.add(strProcDef)

# =============================================================================
# Built-in Option[T] Definition
# =============================================================================

sumType Option[T]:
  Some(val: T)
  None

proc some*[T](val: sink T): Option[T] {.inline.} =
  Some(move(val))

proc none*[T](): Option[T] {.inline.} =
  None[T]()

proc none*[T](_: typedesc[T]): Option[T] {.inline.} =
  None[T]()

proc isSome*[T](opt: Option[T]): bool {.inline, raises: [].} =
  opt.kind == kSome

proc isNone*[T](opt: Option[T]): bool {.inline, raises: [].} =
  opt.kind == kNone

proc get*[T](opt: var Option[T]): T {.inline.} =
  doAssert opt.kind == kSome, "Attempted to .get() a None Option"
  move(opt.Some_val)

proc get*[T](opt: sink Option[T]): T {.inline.} =
  doAssert opt.kind == kSome, "Attempted to .get() a None Option"
  move(opt.Some_val)

proc getOr*[T](opt: var Option[T], defaultVal: sink T): T {.inline, raises: [].} =
  ## Returns the inner value if Some, otherwise moves `defaultVal`.
  ## For copyable types, returns a copy without modifying `opt`.
  ## For move-only types, moves the value out of `opt` (destructive extraction).
  if opt.kind == kSome:
    when compiles(block: (var x: T = opt.Some_val)):
      opt.Some_val
    else:
      move(opt.Some_val)
  else:
    move(defaultVal)

proc getOr*[T](opt: sink Option[T], defaultVal: sink T): T {.inline, raises: [].} =
  if opt.kind == kSome: move(opt.Some_val) else: move(defaultVal)

template val*[T](opt: Option[T]): T =
  get(opt)

# =============================================================================
# Result & Option Interoperability
# =============================================================================

proc toResult*[T, E](opt: sink Option[T], errVal: sink E): Result[T, E] {.inline, raises: [].} =
  ## Converts Option[T] to Result[T, E]. Returns Ok(val) if Some, or Err(errVal) if None.
  if opt.kind == kSome:
    ok[T, E](move(opt.Some_val))
  else:
    err[T, E](move(errVal))

proc toOption*[T, E](r: sink Result[T, E]): Option[T] {.inline, raises: [].} =
  ## Converts Result[T, E] to Option[T]. Returns Some(val) if Ok, or None[T]() if Err.
  when T is void:
    {.error: "Cannot convert Result[void, E] to Option[void]".}
  else:
    if r.isOk:
      some[T](move(r.val))
    else:
      none[T]()

# =============================================================================
# Pattern Matching `match` Macro
# =============================================================================

macro match*(val: typed, body: untyped): untyped =
  ## Pattern matching with positional and named field extraction, guards, and wildcards.
  let tmpSym = genSym(nskLet, "matchVal")

  var typ = val.getTypeImpl
  if typ.kind == nnkTypeDef: typ = typ[2]
  if typ.kind == nnkRefTy: typ = typ[0].getTypeImpl
  if typ.kind == nnkDistinctTy: typ = typ[0].getTypeImpl

  proc findRecCase(n: NimNode): NimNode =
    if n == nil: return nil
    if n.kind == nnkRecCase: return n
    for child in n:
      let f = findRecCase(child)
      if f != nil: return f
    return nil

  let rc = findRecCase(typ)
  if rc == nil:
    error("match requires an object with variant fields (tagged union)", val)

  let discField = ident(rc[0][0].repr)
  let enumSym = rc[0][1]
  let enumImpl = enumSym.getTypeImpl

  type VariantMeta = object
    kindVal: NimNode
    fields: seq[NimNode]

  var metaTable: seq[(string, VariantMeta)] = @[]

  for i in 1 ..< rc.len:
    let branch = rc[i]
    if branch.kind == nnkOfBranch:
      var kVal: NimNode
      if branch[0].kind in {nnkIntLit .. nnkInt64Lit}:
        let ordVal = int(branch[0].intVal)
        if ordVal + 1 < enumImpl.len:
          kVal = enumImpl[1 + ordVal]
        else:
          kVal = branch[0]
      else:
        kVal = branch[0]

      var vName = kVal.repr
      if vName.startsWith("k") and vName.len > 1 and vName[1].isUpperAscii:
        vName = vName[1..^1]

      var fields: seq[NimNode] = @[]
      for j in 1 ..< branch.len:
        let rList = branch[j]
        if rList.kind == nnkRecList:
          for defNode in rList:
            if defNode.kind == nnkIdentDefs:
              fields.add(ident(defNode[0].repr))

      metaTable.add((vName, VariantMeta(kindVal: kVal, fields: fields)))

  proc getMeta(name: string): (NimNode, seq[NimNode]) =
    for (vName, meta) in metaTable:
      if cmpIgnoreCase(vName, name) == 0:
        return (meta.kindVal, meta.fields)
    error("Unknown variant in match: " & name)

  type
    ParsedBranch = object
      variantName: string
      isWildcard: bool
      isNamed: bool
      namedArgs: seq[(string, NimNode)]
      posArgs: seq[NimNode]
      guard: NimNode
      action: NimNode

  var parsed: seq[ParsedBranch] = @[]

  proc parseOneBranch(node: NimNode) =
    case node.kind
    of nnkElse:
      parsed.add(ParsedBranch(isWildcard: true, action: node[0]))
    of nnkCommand:
      let pat = node[0]
      var guardCond: NimNode = nil
      var action: NimNode = nil
      if node[1].kind == nnkIfExpr and node[1].len > 0 and node[1][0].kind == nnkElifExpr:
        guardCond = node[1][0][0]
        action = node[1][0][1]
      else:
        error("Unexpected syntax in guarded match branch", node)

      if pat.kind == nnkCall:
        let vName = pat[0].repr
        var pos: seq[NimNode] = @[]
        for i in 1 ..< pat.len:
          pos.add(pat[i])
        parsed.add(ParsedBranch(variantName: vName, posArgs: pos, guard: guardCond, action: action))
      elif pat.kind == nnkObjConstr:
        let vName = pat[0].repr
        var named: seq[(string, NimNode)] = @[]
        for i in 1 ..< pat.len:
          let arg = pat[i]
          if arg.kind == nnkExprColonExpr:
            named.add((arg[0].repr, arg[1]))
          else:
            error("Expected named field in pattern", arg)
        parsed.add(ParsedBranch(variantName: vName, isNamed: true, namedArgs: named, guard: guardCond, action: action))
      elif pat.kind == nnkIdent:
        let vName = pat.repr
        if vName == "_":
          parsed.add(ParsedBranch(isWildcard: true, guard: guardCond, action: action))
        else:
          parsed.add(ParsedBranch(variantName: vName, guard: guardCond, action: action))
      else:
        error("Unsupported pattern in guarded branch: " & pat.repr, pat)
    of nnkCall:
      var attachedElse: NimNode = nil
      var callNode = node
      if callNode[^1].kind == nnkElse:
        attachedElse = callNode[^1]
        callNode = callNode.copyNimTree
        callNode.del(callNode.len - 1)

      if callNode[0].kind == nnkObjConstr:
        let objC = callNode[0]
        let vName = objC[0].repr
        var named: seq[(string, NimNode)] = @[]
        for i in 1 ..< objC.len:
          let arg = objC[i]
          if arg.kind == nnkExprColonExpr:
            named.add((arg[0].repr, arg[1]))
        parsed.add(ParsedBranch(variantName: vName, isNamed: true, namedArgs: named, action: callNode[1]))
      elif callNode[0].kind == nnkIdent:
        let idStr = callNode[0].repr
        if idStr == "_" or idStr == "else":
          parsed.add(ParsedBranch(isWildcard: true, action: callNode[1]))
        elif callNode.len == 2 and callNode[1].kind == nnkStmtList:
          parsed.add(ParsedBranch(variantName: idStr, action: callNode[1]))
        else:
          let action = callNode[^1]
          var pos: seq[NimNode] = @[]
          for i in 1 ..< callNode.len - 1:
            pos.add(callNode[i])
          parsed.add(ParsedBranch(variantName: idStr, posArgs: pos, action: action))
      else:
        error("Unsupported call pattern: " & callNode.repr, callNode)

      if attachedElse != nil:
        parsed.add(ParsedBranch(isWildcard: true, action: attachedElse[0]))
    of nnkOfBranch:
      let pat = node[0]
      let action = node[1]
      if pat.kind == nnkIdent:
        let idStr = pat.repr
        if idStr == "_":
          parsed.add(ParsedBranch(isWildcard: true, action: action))
        else:
          parsed.add(ParsedBranch(variantName: idStr, action: action))
      elif pat.kind == nnkCall:
        let vName = pat[0].repr
        var pos: seq[NimNode] = @[]
        for i in 1 ..< pat.len:
          pos.add(pat[i])
        parsed.add(ParsedBranch(variantName: vName, posArgs: pos, action: action))
      elif pat.kind == nnkObjConstr:
        let vName = pat[0].repr
        var named: seq[(string, NimNode)] = @[]
        for i in 1 ..< pat.len:
          let arg = pat[i]
          if arg.kind == nnkExprColonExpr:
            named.add((arg[0].repr, arg[1]))
        parsed.add(ParsedBranch(variantName: vName, isNamed: true, namedArgs: named, action: action))
      elif pat.kind == nnkInfix and pat[0].repr == "and":
        let subPat = pat[1]
        let guardCond = pat[2]
        if subPat.kind == nnkCall:
          let vName = subPat[0].repr
          var pos: seq[NimNode] = @[]
          for i in 1 ..< subPat.len:
            pos.add(subPat[i])
          parsed.add(ParsedBranch(variantName: vName, posArgs: pos, guard: guardCond, action: action))
        elif subPat.kind == nnkIdent:
          parsed.add(ParsedBranch(variantName: subPat.repr, guard: guardCond, action: action))
      else:
        error("Unsupported of branch pattern: " & pat.repr, pat)
    else:
      error("Unexpected branch in match: " & node.repr, node)

  for branch in body:
    parseOneBranch(branch)

  var wildcardAction: NimNode = nil
  for b in parsed:
    if b.isWildcard and b.guard == nil:
      wildcardAction = b.action
      break

  var variantGroups: seq[(string, seq[ParsedBranch])] = @[]
  for b in parsed:
    if b.isWildcard: continue
    var found = false
    for i in 0 ..< variantGroups.len:
      if cmpIgnoreCase(variantGroups[i][0], b.variantName) == 0:
        variantGroups[i][1].add(b)
        found = true
        break
    if not found:
      variantGroups.add((b.variantName, @[b]))

  var caseStmt = nnkCaseStmt.newTree(newDotExpr(tmpSym, discField))

  for (vName, bList) in variantGroups:
    let (kindVal, fields) = getMeta(vName)

    var hasGuards = false
    for b in bList:
      if b.guard != nil:
        hasGuards = true
        break

    if not hasGuards and bList.len == 1:
      let b = bList[0]
      var blk = newStmtList()
      if b.isNamed:
        for (fName, bindVar) in b.namedArgs:
          if bindVar.repr != "_":
            let expectedInternal = vName & "_" & fName
            var foundField: NimNode = nil
            for f in fields:
              if cmpIgnoreCase(f.repr, fName) == 0 or cmpIgnoreCase(f.repr, expectedInternal) == 0:
                foundField = f
                break
            if foundField == nil:
              error("Variant " & vName & " has no field " & fName)
            blk.add(newLetStmt(bindVar, newDotExpr(tmpSym, foundField)))
      else:
        for idx, bindVar in b.posArgs:
          if bindVar.repr != "_":
            if idx >= fields.len:
              error("Too many arguments in pattern for variant " & vName)
            blk.add(newLetStmt(bindVar, newDotExpr(tmpSym, fields[idx])))
      blk.add(b.action)
      caseStmt.add(nnkOfBranch.newTree(kindVal, blk))
    else:
      var blk = newStmtList()
      var ifStmt = nnkIfStmt.newTree()
      for b in bList:
        var branchBlk = newStmtList()
        if b.isNamed:
          for (fName, bindVar) in b.namedArgs:
            if bindVar.repr != "_":
              let expectedInternal = vName & "_" & fName
              var foundField: NimNode = nil
              for f in fields:
                if cmpIgnoreCase(f.repr, fName) == 0 or cmpIgnoreCase(f.repr, expectedInternal) == 0:
                  foundField = f
                  break
              if foundField == nil:
                error("Variant " & vName & " has no field " & fName)
              branchBlk.add(newLetStmt(bindVar, newDotExpr(tmpSym, foundField)))
        else:
          for idx, bindVar in b.posArgs:
            if bindVar.repr != "_":
              branchBlk.add(newLetStmt(bindVar, newDotExpr(tmpSym, fields[idx])))

        if b.guard != nil:
          branchBlk.add(b.action)
          var condBlock = newStmtList()
          if b.isNamed:
            for (fName, bindVar) in b.namedArgs:
              if bindVar.repr != "_":
                let expectedInternal = vName & "_" & fName
                var foundField: NimNode = nil
                for f in fields:
                  if cmpIgnoreCase(f.repr, fName) == 0 or cmpIgnoreCase(f.repr, expectedInternal) == 0:
                    foundField = f
                    break
                if foundField == nil:
                  error("Variant " & vName & " has no field " & fName)
                condBlock.add(newLetStmt(bindVar, newDotExpr(tmpSym, foundField)))
          else:
            for idx, bindVar in b.posArgs:
              if bindVar.repr != "_":
                condBlock.add(newLetStmt(bindVar, newDotExpr(tmpSym, fields[idx])))
          condBlock.add(b.guard)

          let guardExpr = nnkBlockExpr.newTree(newEmptyNode(), condBlock)
          ifStmt.add(nnkElifBranch.newTree(guardExpr, branchBlk))
        else:
          branchBlk.add(b.action)
          ifStmt.add(nnkElse.newTree(branchBlk))

      if ifStmt[^1].kind != nnkElse:
        if wildcardAction != nil:
          ifStmt.add(nnkElse.newTree(wildcardAction))
        else:
          let panicStmt = quote do:
            raiseAssert("Non-exhaustive guard conditions in match for " & `vName`)
          ifStmt.add(nnkElse.newTree(panicStmt))

      blk.add(ifStmt)
      caseStmt.add(nnkOfBranch.newTree(kindVal, blk))

  if wildcardAction != nil:
    caseStmt.add(nnkElse.newTree(wildcardAction))

  let pragmaExpr = nnkPragmaExpr.newTree(tmpSym, nnkPragma.newTree(ident"cursor"))
  result = nnkBlockStmt.newTree(
    newEmptyNode(),
    newStmtList(
      nnkLetSection.newTree(
        nnkIdentDefs.newTree(pragmaExpr, newEmptyNode(), val)
      ),
      caseStmt
    )
  )
