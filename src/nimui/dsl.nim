## nimui/dsl — Declarative Macro DSL & Fine-Grained Reactive Bindings
##
## Strict invariants:
## - Fine-grained reactivity powered by corex/signals.
## - Zero idle GPU usage: signal mutations set isDirty/isLayoutDirty without polling.
## - AST macro `ui` translating declarative syntax to direct Slab node creations and effects.
## - First-class components: Box, VStack, HStack, Text, Button, TextInput, VirtualList.

import std/macros
import corex/[signals, slab, result]
import ./layout

# =============================================================================
# Reactive Bindings for UiNode
# =============================================================================

# Safe: tree/rt are non-owning pointers to caller-owned UiTree and ReactiveRuntime
# that outlive the reactive effect closures; guarded by `tree != nil`.
proc bindText*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  id: SlabId,
  computeFn: proc(): string {.closure, gcsafe, raises: [].}
): EffectId {.trustedUnsafe, discardable, raises: [].} =
  rt.createEffect(proc() =
    let val = computeFn()
    if tree != nil and tree.nodes.contains(id):
      tree.nodes[id].text = val
      tree.isLayoutDirty = true
      tree.isDirty = true
  )

# Safe: tree/rt outlive the reactive effect closure; guarded by `tree != nil`.
proc bindBg*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  id: SlabId,
  computeFn: proc(): uint32 {.closure, gcsafe, raises: [].}
): EffectId {.trustedUnsafe, discardable, raises: [].} =
  rt.createEffect(proc() =
    let col = computeFn()
    if tree != nil and tree.nodes.contains(id):
      tree.nodes[id].bgColor = col
      tree.isDirty = true # Color change only triggers redraw, 0 layout cost!
  )

# Safe: tree/rt outlive the reactive effect and onInput closures; guarded by `tree != nil`.
proc bindInput*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  id: SlabId,
  sig: Signal[string]
) {.trustedUnsafe, raises: [].} =
  # 1. Signal -> Text input node
  discard rt.createEffect(proc() =
    let val = sig.get()
    if tree != nil and tree.nodes.contains(id):
      if tree.nodes[id].text != val:
        tree.nodes[id].text = val
        let rLen = runeLen(val)
        tree.nodes[id].caretPos = clamp(tree.nodes[id].caretPos, 0, rLen)
        tree.nodes[id].selStart = clamp(tree.nodes[id].selStart, 0, rLen)
        tree.nodes[id].selEnd = clamp(tree.nodes[id].selEnd, 0, rLen)
        tree.isLayoutDirty = true
        tree.isDirty = true
  )

  # 2. Text input node -> Signal
  if tree != nil and tree.nodes.contains(id):
    tree.nodes[id].onInput = proc(text: string) {.gcsafe, raises: [].} =
      var copy = newStringOfCap(text.len)
      copy.add(text)
      sig.set(copy)

# Safe: tree/rt outlive the reactive effect closure; guarded by `tree != nil`.
proc bindVirtualCount*(
  tree: ptr UiTree,
  rt: ptr ReactiveRuntime,
  id: SlabId,
  sig: Signal[int]
) {.trustedUnsafe, raises: [].} =
  discard rt.createEffect(proc() =
    let c = sig.get()
    if tree != nil and tree.nodes.contains(id):
      tree.nodes[id].virtualCount = c
      tree.isLayoutDirty = true
      tree.isDirty = true
  )

# =============================================================================
# Component Constructors
# =============================================================================

proc Box*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  width: SizeMode = fitContent(),
  height: SizeMode = fitContent(),
  padding: float32 = 0.0f,
  gap: float32 = 0.0f,
  bg: uint32 = 0x00000000'u32,
  borderColor: uint32 = 0x00000000'u32,
  radius: float32 = 0.0f,
  borderWidth: float32 = 0.0f,
  softness: float32 = 1.0f,
  direction: FlexDirection = fdColumn,
  alignItems: AlignItems = aiStart,
  justifyContent: JustifyContent = jcStart
): SlabId {.raises: [].} =
  let id = tree.createNode(nkBox)
  template n: untyped = tree.nodes[id]
  n.widthMode = width
  n.heightMode = height
  n.padding = [padding, padding, padding, padding]
  n.gap = gap
  n.bgColor = bg
  n.borderColor = borderColor
  n.radius = radius
  n.borderWidth = borderWidth
  n.softness = softness
  n.direction = direction
  n.alignItems = alignItems
  n.justifyContent = justifyContent
  if parent != SlabId(-1):
    tree.addChild(parent, id)
  id

proc VStack*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  padding: float32 = 0.0f,
  gap: float32 = 0.0f,
  bg: uint32 = 0x00000000'u32,
  borderColor: uint32 = 0x00000000'u32,
  radius: float32 = 0.0f,
  borderWidth: float32 = 0.0f,
  softness: float32 = 1.0f,
  width: SizeMode = fitContent(),
  height: SizeMode = fitContent(),
  alignItems: AlignItems = aiStart,
  justifyContent: JustifyContent = jcStart
): SlabId {.inline, raises: [].} =
  Box(tree, parent, width, height, padding, gap, bg, borderColor, radius, borderWidth, softness, fdColumn, alignItems, justifyContent)

proc HStack*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  padding: float32 = 0.0f,
  gap: float32 = 0.0f,
  bg: uint32 = 0x00000000'u32,
  borderColor: uint32 = 0x00000000'u32,
  radius: float32 = 0.0f,
  borderWidth: float32 = 0.0f,
  softness: float32 = 1.0f,
  width: SizeMode = fitContent(),
  height: SizeMode = fitContent(),
  alignItems: AlignItems = aiStart,
  justifyContent: JustifyContent = jcStart
): SlabId {.inline, raises: [].} =
  Box(tree, parent, width, height, padding, gap, bg, borderColor, radius, borderWidth, softness, fdRow, alignItems, justifyContent)

proc Text*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  text: string = "",
  size: float32 = 14.0f,
  color: uint32 = 0xFFFFFFFF'u32,
  padding: float32 = 0.0f
): SlabId {.raises: [].} =
  let id = tree.createNode(nkText)
  template n: untyped = tree.nodes[id]
  n.text = text
  n.fontSize = size
  n.textColor = color
  n.padding = [padding, padding, padding, padding]
  if parent != SlabId(-1):
    tree.addChild(parent, id)
  id

proc Button*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  label: string = "",
  size: float32 = 14.0f,
  bg: uint32 = 0x242428FF'u32,
  bgHover: uint32 = 0x2E2E34FF'u32,
  bgActive: uint32 = 0x1E1E22FF'u32,
  borderColor: uint32 = 0x38383EFF'u32,
  radius: float32 = 6.0f,
  borderWidth: float32 = 1.0f,
  color: uint32 = 0xFFFFFFFF'u32,
  padding: float32 = 8.0f,
  onClick: proc() {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let id = tree.createNode(nkButton)
  template n: untyped = tree.nodes[id]
  n.text = label
  n.fontSize = size
  n.bgColor = bg
  n.bgHoverColor = bgHover
  n.bgActiveColor = bgActive
  n.borderColor = borderColor
  n.radius = radius
  n.borderWidth = borderWidth
  n.textColor = color
  n.padding = [padding * 0.5f, padding, padding * 0.5f, padding]
  n.onClick = onClick
  if parent != SlabId(-1):
    tree.addChild(parent, id)
  id

proc TextInput*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  placeholder: string = "",
  text: string = "",
  size: float32 = 14.0f,
  width: SizeMode = fixed(240.0f),
  height: SizeMode = fixed(36.0f),
  bg: uint32 = 0x1C1C1EFF'u32,
  borderColor: uint32 = 0x38383EFF'u32,
  radius: float32 = 6.0f,
  borderWidth: float32 = 1.0f,
  color: uint32 = 0xFFFFFFFF'u32,
  onInput: proc(s: string) {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let id = tree.createNode(nkTextInput)
  template n: untyped = tree.nodes[id]
  n.placeholder = placeholder
  n.text = text
  n.fontSize = size
  n.widthMode = width
  n.heightMode = height
  n.bgColor = bg
  n.borderColor = borderColor
  n.radius = radius
  n.borderWidth = borderWidth
  n.textColor = color
  n.padding = [4.0f, 8.0f, 4.0f, 8.0f]
  n.onInput = onInput
  if parent != SlabId(-1):
    tree.addChild(parent, id)
  id

proc VirtualList*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  count: int = 0,
  itemHeight: float32 = 32.0f,
  width: SizeMode = flexGrow(),
  height: SizeMode = flexGrow(),
  bg: uint32 = 0x161618FF'u32,
  renderItem: RenderVirtualItemProc = nil,
  onSelect: proc(idx: int) {.closure, gcsafe, raises: [].} = nil
): SlabId {.raises: [].} =
  let id = tree.createNode(nkVirtualList)
  template n: untyped = tree.nodes[id]
  n.virtualCount = count
  n.itemHeight = itemHeight
  n.widthMode = width
  n.heightMode = height
  n.bgColor = bg
  n.renderItemProc = renderItem
  n.onSelect = onSelect
  n.isScrollable = true
  if parent != SlabId(-1):
    tree.addChild(parent, id)
  id

# =============================================================================
# AST Macro `ui`
# =============================================================================

proc containsSignalGet(n: NimNode): bool =
  if n.kind == nnkDotExpr:
    if n.len == 2 and n[1].strVal == "get":
      return true
  for child in n:
    if containsSignalGet(child):
      return true
  false

proc transformNode(n: NimNode, treeIdent, rtIdent, parentIdent: NimNode): NimNode =
  result = newStmtList()

  case n.kind
  of nnkCommand, nnkCall:
    let head = n[0]
    let headStr = head.strVal

    if headStr == "state":
      # state name = createSignal(rt, value)
      if n.len > 1 and n[1].kind == nnkExprEqExpr:
        let varIdent = n[1][0]
        let varVal = n[1][1]
        result.add(newVarStmt(varIdent, varVal))
      return result

    # Component call: VStack, HStack, Box, Text, Button, TextInput, VirtualList
    let tempId = genSym(nskLet, "uiNode_")
    var callArgs = newSeq[NimNode]()
    callArgs.add(head)
    callArgs.add(treeIdent)
    callArgs.add(parentIdent)

    var hasStmtList = false
    var childStmtList: NimNode = nil
    var dynamicTextExpr: NimNode = nil
    var signalValueBinding: NimNode = nil

    # Inspect arguments
    for i in 1 ..< n.len:
      let arg = n[i]
      if arg.kind == nnkStmtList:
        hasStmtList = true
        childStmtList = arg
      elif arg.kind == nnkExprEqExpr:
        let key = arg[0].strVal
        let val = arg[1]
        if key == "value" and headStr == "TextInput":
          signalValueBinding = val
        elif key == "padding":
          callArgs.add(newTree(nnkExprEqExpr, ident("padding"), newCall(ident("float32"), val)))
        elif key == "gap":
          callArgs.add(newTree(nnkExprEqExpr, ident("gap"), newCall(ident("float32"), val)))
        elif key == "size":
          callArgs.add(newTree(nnkExprEqExpr, ident("size"), newCall(ident("float32"), val)))
        elif key == "bg":
          callArgs.add(newTree(nnkExprEqExpr, ident("bg"), newCall(ident("uint32"), val)))
        elif key == "color":
          callArgs.add(newTree(nnkExprEqExpr, ident("color"), newCall(ident("uint32"), val)))
        elif key == "width":
          callArgs.add(newTree(nnkExprEqExpr, ident("width"), val))
        elif key == "height":
          callArgs.add(newTree(nnkExprEqExpr, ident("height"), val))
        else:
          callArgs.add(arg)
      else:
        # Positional arg (e.g. text/label)
        if containsSignalGet(arg):
          dynamicTextExpr = arg
          callArgs.add(newLit("")) # Initial empty string, effect will populate immediately
        else:
          callArgs.add(arg)

    let nodeCall = newTree(nnkCall, callArgs)
    result.add(newLetStmt(tempId, nodeCall))

    # Dynamic text reactivity
    if dynamicTextExpr != nil:
      let lambdaProc = newProc(
        procType = nnkLambda,
        params = [ident("string")],
        body = newStmtList(dynamicTextExpr)
      )
      result.add(newTree(
        nnkDiscardStmt,
        newCall(
          ident("bindText"),
          newCall(ident("addr"), treeIdent),
          rtIdent,
          tempId,
          lambdaProc
        )
      ))

    # Two-way text input binding
    if signalValueBinding != nil:
      result.add(newCall(
        ident("bindInput"),
        newCall(ident("addr"), treeIdent),
        rtIdent,
        tempId,
        signalValueBinding
      ))

    # Nested children
    if hasStmtList and childStmtList != nil:
      for child in childStmtList:
        result.add(transformNode(child, treeIdent, rtIdent, tempId))

  of nnkStmtList:
    for child in n:
      result.add(transformNode(child, treeIdent, rtIdent, parentIdent))
  else:
    result.add(n)

macro ui*(name, body: untyped): untyped =
  ## Macro compiling declarative UI hierarchy into zero-overhead Slab and Effect bindings.
  let treeIdent = ident("tree")
  let rtIdent = ident("rt")
  let nilParent = newCall(ident("SlabId"), newLit(-1))

  let transformed = transformNode(body, treeIdent, rtIdent, nilParent)

  result = quote do:
    template `name`(`treeIdent`: var UiTree, `rtIdent`: ptr ReactiveRuntime) =
      `transformed`
