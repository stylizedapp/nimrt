## corex/traits — Статические и динамические трейты (`dyn Trait`) без `ref object`
##
## Позволяет в Nim использовать полиморфизм через fat-pointer (`dataPtr` + `vtablePtr`)
## для обычных стековых `object`, без принудительных аллокаций в куче и ООП-наследования.

import std/macros

macro defTrait*(traitName: untyped, methods: untyped): untyped =
  ## Создаёт интерфейс (Trait) с таблицей виртуальных методов (VTable) и fat-pointer обёрткой.
  ##
  ## Пример:
  ## ```nim
  ## defTrait Metric:
  ##   proc score(self): int
  ##   proc label(self): string
  ## ```
  let tNameStr = $traitName
  let vtableName = ident(tNameStr & "VTable")
  let dynName = ident("Dyn" & tNameStr)

  var vtableFields = nnkRecList.newTree()
  var wrapperProcs = newStmtList()
  var vtableInitPairs: seq[(NimNode, NimNode)] = @[]

  for m in methods:
    if m.kind in {nnkProcDef, nnkMethodDef}:
      let mName = m.name
      let params = m.params
      let retType = if params[0].kind == nnkEmpty: ident"void" else: params[0]

      var vtParams = nnkFormalParams.newTree(retType)
      vtParams.add(nnkIdentDefs.newTree(ident"selfPtr", ident"pointer", newEmptyNode()))

      var callArgs = @[newDotExpr(ident"d", ident"data")]
      var wrapperParams = @[retType, nnkIdentDefs.newTree(ident"d", dynName, newEmptyNode())]

      for i in 1 ..< params.len:
        let p = params[i]
        if p.kind == nnkIdentDefs and $p[0] == "self":
          continue
        vtParams.add(copyNimTree(p))
        wrapperParams.add(copyNimTree(p))
        for j in 0 ..< p.len - 2:
          callArgs.add(p[j])

      let procType = nnkProcTy.newTree(
        vtParams,
        nnkPragma.newTree(ident"nimcall", ident"gcsafe")
      )

      vtableFields.add(
        nnkIdentDefs.newTree(
          nnkPostfix.newTree(ident"*", mName),
          procType,
          newEmptyNode()
        )
      )

      var vtFieldCall = nnkCall.newTree(
        newDotExpr(newDotExpr(ident"d", ident"vtable"), mName)
      )
      for ca in callArgs:
        vtFieldCall.add(ca)

      wrapperProcs.add(
        newProc(
          name = nnkPostfix.newTree(ident"*", mName),
          params = wrapperParams,
          body = newStmtList(vtFieldCall),
          pragmas = nnkPragma.newTree(ident"inline")
        )
      )
      vtableInitPairs.add((mName, params))

  let asDynName = ident("asDyn" & tNameStr)
  let tGeneric = ident"T"
  var thunkDefs = newStmtList()
  var vtConstr = nnkObjConstr.newTree(vtableName)

  for (mName, params) in vtableInitPairs:
    thunkDefs.add(nnkMixinStmt.newTree(mName))
    let retType = if params[0].kind == nnkEmpty: ident"void" else: params[0]
    let thunkName = genSym(nskProc, $mName & "Thunk")
    var thunkParams = nnkFormalParams.newTree(retType)
    let selfPtrSym = ident"selfPtr"
    thunkParams.add(nnkIdentDefs.newTree(selfPtrSym, ident"pointer", newEmptyNode()))

    var realCall = nnkCall.newTree(
      mName,
      nnkBracketExpr.newTree(
        nnkCast.newTree(nnkPtrTy.newTree(tGeneric), selfPtrSym)
      )
    )
    for i in 1 ..< params.len:
      let p = params[i]
      if p.kind == nnkIdentDefs and $p[0] == "self":
        continue
      thunkParams.add(copyNimTree(p))
      for j in 0 ..< p.len - 2:
        realCall.add(p[j])

    thunkDefs.add(
      nnkProcDef.newTree(
        thunkName,
        newEmptyNode(),
        newEmptyNode(),
        thunkParams,
        nnkPragma.newTree(ident"nimcall", ident"gcsafe"),
        newEmptyNode(),
        newStmtList(realCall)
      )
    )
    vtConstr.add(nnkExprColonExpr.newTree(mName, thunkName))

  let vtGlobalSym = genSym(nskVar, "vtInstance")
  let dynFields = nnkRecList.newTree(
    nnkIdentDefs.newTree(nnkPostfix.newTree(ident"*", ident"data"), ident"pointer", newEmptyNode()),
    nnkIdentDefs.newTree(nnkPostfix.newTree(ident"*", ident"vtable"), nnkPtrTy.newTree(vtableName), newEmptyNode())
  )

  let typeSec = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      nnkPostfix.newTree(ident"*", vtableName),
      newEmptyNode(),
      nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), vtableFields)
    ),
    nnkTypeDef.newTree(
      nnkPostfix.newTree(ident"*", dynName),
      newEmptyNode(),
      nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), dynFields)
    )
  )

  let asDynProc = quote do:
    proc `asDynName`*[`tGeneric`](target: var `tGeneric`): `dynName` {.inline.} =
      `thunkDefs`
      var `vtGlobalSym` {.global.} = `vtConstr`
      `dynName`(data: addr target, vtable: addr `vtGlobalSym`)

  result = newStmtList(typeSec, wrapperProcs, asDynProc)
