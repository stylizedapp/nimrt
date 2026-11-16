## src/nimui/html/compiler.nim
##
## Pure-Nim Binding Registry (`HtmlBindingRegistry`) and Reactive DOM Mounter
## compiling parsed `HtmlDoc` + `CssStylesheet` directly onto `UiTree`.

import corex/adt
import corex/result
import corex/slab
import corex/smallvec
import corex/signals
import algx/swissmap
import ../layout
import ../dsl
import ./types
import ./parser
import ./cascade

# =============================================================================
# Pure-Nim Binding Registry
# =============================================================================

proc initHtmlBindingRegistry*(): HtmlBindingRegistry {.raises: [].} =
  HtmlBindingRegistry(
    clickHandlers: initFastMap[string, HtmlClickProc](16),
    inputHandlers: initFastMap[string, HtmlInputProc](16),
    textSignals: initFastMap[string, Signal[string]](16),
    textProcs: initFastMap[string, HtmlTextProc](16),
    inputSignals: initFastMap[string, Signal[string]](16),
    idToSlab: initFastMap[string, SlabId](32)
  )

proc destroy*(reg: var HtmlBindingRegistry) {.raises: [].} =
  reset(reg.clickHandlers)
  reset(reg.inputHandlers)
  reset(reg.textSignals)
  reset(reg.textProcs)
  reset(reg.inputSignals)
  reset(reg.idToSlab)

proc onClick*(reg: var HtmlBindingRegistry, name: string, cb: HtmlClickProc) {.raises: [].} =
  reg.clickHandlers.put(name, cb)

proc onInput*(reg: var HtmlBindingRegistry, name: string, cb: HtmlInputProc) {.raises: [].} =
  reg.inputHandlers.put(name, cb)

proc bindTextSignal*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string]) {.raises: [].} =
  reg.textSignals.put(name, sig)

proc bindText*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string]) {.raises: [].} =
  reg.textSignals.put(name, sig)

proc bindText*(reg: var HtmlBindingRegistry, name: string, fn: HtmlTextProc) {.raises: [].} =
  reg.textProcs.put(name, fn)

proc bindInputSignal*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string]) {.raises: [].} =
  reg.inputSignals.put(name, sig)

proc getNodeById*(reg: HtmlBindingRegistry, id: string): Option[SlabId] {.raises: [].} =
  if reg.idToSlab.contains(id):
    return some(reg.idToSlab.getOrDefault(id))
  none[SlabId]()

# =============================================================================
# Layout Size & Constraint Mapping Helpers
# =============================================================================

proc toLayoutPadding(p: array[4, float32]): array[4, float32] {.inline, raises: [].} =
  # layout.nim UiNode.padding uses [top, right, bottom, left] — identical to CSS order.
  p

proc resolveConstraintPx(sz: CssSize, parentFixedInner: float32): float32 {.inline, raises: [].} =
  case sz.kind
  of cskPx:
    max(0.0'f32, sz.value)
  of cskPercent:
    if parentFixedInner >= 0.0'f32:
      max(0.0'f32, parentFixedInner * (sz.value / 100.0'f32))
    else:
      -1.0'f32
  else:
    -1.0'f32

proc clampByMinMax(
  val: float32,
  minSz, maxSz: CssSize,
  parentFixedInner: float32
): float32 {.inline, raises: [].} =
  result = val
  let maxPx = resolveConstraintPx(maxSz, parentFixedInner)
  if maxPx >= 0.0'f32 and result > maxPx:
    result = maxPx
  let minPx = resolveConstraintPx(minSz, parentFixedInner)
  if minPx >= 0.0'f32 and result < minPx:
    result = minPx
  if result < 0.0'f32:
    result = 0.0'f32

proc resolveSizeMode(
  sz: CssSize,
  flexBasis: CssSize,
  minSz: CssSize,
  maxSz: CssSize,
  hasFlexGrow: bool,
  flexWeight: float32,
  isPrimaryAxis: bool,
  parentFixedInner: float32,
  defaultPx: float32 = -1.0'f32,
  isEmptyLeaf: bool = false
): SizeMode {.raises: [].} =
  let effSz = if sz.kind == cskAuto and isPrimaryAxis and flexBasis.kind != cskAuto:
                flexBasis
              else:
                sz

  case effSz.kind
  of cskPx:
    fixed(clampByMinMax(effSz.value, minSz, maxSz, parentFixedInner))
  of cskPercent:
    if parentFixedInner >= 0.0'f32:
      let rawPx = parentFixedInner * (effSz.value / 100.0'f32)
      fixed(clampByMinMax(rawPx, minSz, maxSz, parentFixedInner))
    else:
      let maxPx = resolveConstraintPx(maxSz, parentFixedInner)
      if maxPx >= 0.0'f32 and effSz.value >= 99.9'f32:
        fixed(clampByMinMax(maxPx, minSz, maxSz, parentFixedInner))
      else:
        let w = effSz.value / 100.0'f32
        flexGrow(if w > 0.01'f32: w else: 0.01'f32)
  of cskFlexGrow:
    flexGrow(if effSz.value > 0.0'f32: effSz.value else: 1.0'f32)
  of cskAuto:
    if hasFlexGrow and isPrimaryAxis:
      flexGrow(flexWeight)
    elif defaultPx >= 0.0'f32:
      fixed(clampByMinMax(defaultPx, minSz, maxSz, parentFixedInner))
    elif isEmptyLeaf:
      let minPx = resolveConstraintPx(minSz, parentFixedInner)
      if minPx > 0.0'f32:
        fixed(clampByMinMax(minPx, minSz, maxSz, parentFixedInner))
      else:
        fitContent()
    else:
      fitContent()

proc computeChildFixedInner(sz: SizeMode, padA, padB: float32): float32 {.inline, raises: [].} =
  if sz.kind == smFixed:
    let inner = sz.val - padA - padB
    if inner >= 0.0'f32: inner else: 0.0'f32
  else:
    -1.0'f32

proc hasVisualBoxStyle(style: CssComputedStyle): bool {.raises: [].} =
  style.bgColor != 0'u32 or
  style.bgGradient.active or
  style.borderWidth > 0.0'f32 or
  style.borderRadius > 0.0'f32 or
  style.boxShadows.len > 0 or
  style.padding[0] != 0.0'f32 or
  style.padding[1] != 0.0'f32 or
  style.padding[2] != 0.0'f32 or
  style.padding[3] != 0.0'f32 or
  style.margin[0] != 0.0'f32 or
  style.margin[1] != 0.0'f32 or
  style.margin[2] != 0.0'f32 or
  style.margin[3] != 0.0'f32 or
  style.width.kind != cskAuto or
  style.height.kind != cskAuto or
  style.minWidth.kind != cskAuto or
  style.minHeight.kind != cskAuto or
  style.hasFlexGrow

proc parseHtmlAttrDim(node: HtmlNode, attrName: string): CssSize {.raises: [].} =
  let opt = node.getAttr(attrName)
  if opt.isNone:
    return CssSize(kind: cskAuto, value: 0.0'f32)
  let raw = htmlStripAscii(opt.get())
  let pct = parseCssPercent(raw)
  if pct.isSome:
    return CssSize(kind: cskPercent, value: pct.get())
  let px = parseCssLength(raw)
  if px.isSome:
    return CssSize(kind: cskPx, value: max(0.0'f32, px.get()))
  CssSize(kind: cskAuto, value: 0.0'f32)

proc parseSvgViewBoxSize(node: HtmlNode): tuple[hasSize: bool, w, h: float32] {.raises: [].} =
  let vbOpt = node.getAttr("viewbox")
  if vbOpt.isNone:
    return (false, 0.0'f32, 0.0'f32)
  let toks = htmlSplitWhitespace(vbOpt.get())
  if toks.len >= 4:
    let wo = parseFloatSafe(toks[2])
    let ho = parseFloatSafe(toks[3])
    if wo.isSome and ho.isSome and wo.get() > 0.0'f32 and ho.get() > 0.0'f32:
      return (true, wo.get(), ho.get())
  (false, 0.0'f32, 0.0'f32)

proc collectDirectTextAndElementChildren(
  doc: HtmlDoc,
  nodeIdx: int,
  outElemChildren: var seq[int],
  outDirectText: var string
) {.raises: [].} =
  for cIdx in doc.nodes[nodeIdx].children:
    let child = doc.nodes[cIdx]
    if child.kind == hnkElement:
      if not containsTag(HtmlSkipMountTags, child.tag):
        outElemChildren.add(cIdx)
    elif child.kind == hnkText:
      let t = htmlStripAscii(child.text)
      if t.len > 0:
        if outDirectText.len > 0:
          outDirectText.add(' ')
        outDirectText.add(t)

proc attachReactiveBindings(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  bindings: var HtmlBindingRegistry,
  htmlNode: HtmlNode,
  containerSlab: SlabId,
  textSlab: SlabId,
  isInput: bool,
  isDisabled: bool
) {.raises: [].} =
  if not isDisabled:
    let clickOpt = htmlNode.getAttr("data-click")
    if clickOpt.isSome:
      let actionName = clickOpt.get()
      if bindings.clickHandlers.contains(actionName):
        let cb = bindings.clickHandlers.getOrDefault(actionName)
        if cb != nil:
          tree.nodes[containerSlab].onClick = cb

  if isInput:
    let bindOpt = htmlNode.getAttr("data-bind")
    let modelOpt = if bindOpt.isSome: bindOpt else: htmlNode.getAttr("data-model")
    var hasBoundSig = false
    var boundSig: Signal[string]

    if modelOpt.isSome and bindings.inputSignals.contains(modelOpt.get()):
      boundSig = bindings.inputSignals.getOrDefault(modelOpt.get())
      hasBoundSig = true
      if rt != nil:
        if boundSig.get().len == 0 and tree.nodes[containerSlab].text.len > 0:
          boundSig.set(tree.nodes[containerSlab].text)
        bindInput(addr tree, rt, containerSlab, boundSig)

    if not isDisabled:
      let inputOpt = htmlNode.getAttr("data-input")
      if inputOpt.isSome and bindings.inputHandlers.contains(inputOpt.get()):
        let userCb = bindings.inputHandlers.getOrDefault(inputOpt.get())
        if userCb != nil:
          if hasBoundSig and tree.nodes[containerSlab].onInput != nil:
            let existingCb = tree.nodes[containerSlab].onInput
            tree.nodes[containerSlab].onInput = proc(text: string) {.closure, gcsafe, raises: [].} =
              existingCb(text)
              userCb(text)
          else:
            tree.nodes[containerSlab].onInput = userCb
  else:
    let dataTextOpt = htmlNode.getAttr("data-text")
    let textKeyOpt = if dataTextOpt.isSome: dataTextOpt else: htmlNode.getAttr("data-bind")
    if textKeyOpt.isSome:
      let key = textKeyOpt.get()
      if bindings.textSignals.contains(key):
        let sig = bindings.textSignals.getOrDefault(key)
        if rt != nil:
          if sig.get().len == 0 and tree.nodes[textSlab].text.len > 0:
            sig.set(tree.nodes[textSlab].text)
          bindText(addr tree, rt, textSlab, proc(): string {.closure, gcsafe, raises: [].} =
            sig.get()
          )
      elif bindings.textProcs.contains(key):
        let fn = bindings.textProcs.getOrDefault(key)
        if rt != nil and fn != nil:
          bindText(addr tree, rt, textSlab, fn)

proc propagateOnClickRecursive*(tree: var UiTree, nodeId: SlabId, cb: HtmlClickProc) {.raises: [].} =
  ## Iterative click handler propagation across non-input descendant UI nodes.
  if cb.isNil or not tree.nodes.contains(nodeId):
    return
  var stack: seq[SlabId] = @[nodeId]
  while stack.len > 0:
    let cur = stack.pop()
    if not tree.nodes.contains(cur):
      continue
    let childCount = tree.nodes[cur].children.len
    for i in 0 ..< childCount:
      let childId = tree.nodes[cur].children[i]
      if tree.nodes.contains(childId):
        if tree.nodes[childId].kind != nkTextInput and tree.nodes[childId].onClick.isNil:
          tree.nodes[childId].onClick = cb
        stack.add(childId)

proc wrapWithMarginIfNeeded(
  tree: var UiTree,
  elemSlab: SlabId,
  style: CssComputedStyle,
  parentDir: FlexDirection,
  parentSlab: SlabId
): SlabId {.raises: [].} =
  let mTop = max(0.0'f32, style.margin[0])
  let mRight = max(0.0'f32, style.margin[1])
  let mBottom = max(0.0'f32, style.margin[2])
  let mLeft = max(0.0'f32, style.margin[3])
  let centerHoriz = style.marginAuto[1] and style.marginAuto[3] and parentDir == fdColumn

  if mTop == 0.0'f32 and mRight == 0.0'f32 and mBottom == 0.0'f32 and mLeft == 0.0'f32 and not centerHoriz:
    if parentSlab != SlabId(-1):
      tree.addChild(parentSlab, elemSlab)
    return elemSlab

  let wrapper = tree.createNode(nkBox)
  tree.nodes[wrapper].direction = fdColumn
  tree.nodes[wrapper].padding = [mTop, mRight, mBottom, mLeft]
  tree.nodes[wrapper].alignItems = if centerHoriz: aiCenter else: aiStretch

  if centerHoriz:
    tree.nodes[wrapper].widthMode = flexGrow(1.0'f32)
  elif style.hasFlexGrow:
    if parentDir == fdRow:
      tree.nodes[wrapper].widthMode = flexGrow(style.flexGrow)
      tree.nodes[elemSlab].widthMode = flexGrow(1.0'f32)
    else:
      tree.nodes[wrapper].heightMode = flexGrow(style.flexGrow)
      tree.nodes[elemSlab].heightMode = flexGrow(1.0'f32)
  elif style.width.kind == cskPercent and style.width.value >= 99.9'f32 and parentDir == fdColumn:
    tree.nodes[wrapper].widthMode = flexGrow(1.0'f32)

  tree.addChild(wrapper, elemSlab)
  if parentSlab != SlabId(-1):
    tree.addChild(parentSlab, wrapper)
  wrapper

proc applyVisualOpacity(node: var UiNode, style: CssComputedStyle) {.inline, raises: [].} =
  if style.opacitySet and style.opacity < 1.0'f32:
    node.bgColor = applyColorOpacity(style.bgColor, style.opacity)
    node.bgHoverColor = applyColorOpacity(style.bgHoverColor, style.opacity)
    node.bgActiveColor = applyColorOpacity(style.bgActiveColor, style.opacity)
    node.borderColor = applyColorOpacity(style.borderColor, style.opacity)
    node.borderHoverColor = applyColorOpacity(style.borderHoverColor, style.opacity)
    node.textColor = applyColorOpacity(style.fgColor, style.opacity)
  else:
    node.bgColor = style.bgColor
    node.bgHoverColor = style.bgHoverColor
    node.bgActiveColor = style.bgActiveColor
    node.borderColor = style.borderColor
    node.borderHoverColor = style.borderHoverColor
    node.textColor = style.fgColor

proc mountElementRecursive(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  doc: HtmlDoc,
  nodeIdx: int,
  sheet: CssStylesheet,
  parentStyle: CssComputedStyle,
  parentDir: FlexDirection,
  parentAlign: AlignItems,
  parentInnerW, parentInnerH: float32,
  bindings: var HtmlBindingRegistry,
  parentSlab: SlabId,
  listMarkerPrefix: string = "",
  depth: int = 0
): SlabId {.raises: [].} =
  if depth >= MaxMountDepth or nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return SlabId(-1)

  let node = doc.nodes[nodeIdx]
  if containsTag(HtmlSkipMountTags, node.tag):
    return SlabId(-1)

  var style = computeNodeStyle(doc, nodeIdx, sheet, parentStyle)
  if style.display == cdNone:
    return SlabId(-1)

  let isDisabled = node.getAttr("disabled").isSome
  let effectiveAlign = case style.alignSelf
    of casStart: aiStart
    of casCenter: aiCenter
    of casEnd: aiEnd
    of casStretch: aiStretch
    of casAuto: parentAlign

  # 1. <br> line break spacer
  if node.tag == "br":
    let brSlab = tree.createNode(nkBox)
    tree.nodes[brSlab].widthMode = fixed(0.0'f32)
    tree.nodes[brSlab].heightMode = fixed(max(4.0'f32, style.fontSize * 0.6'f32))
    return wrapWithMarginIfNeeded(tree, brSlab, style, parentDir, parentSlab)

  # 2. <hr> horizontal rule
  if node.tag == "hr":
    let hrSlab = tree.createNode(nkBox)
    tree.nodes[hrSlab].widthMode = resolveSizeMode(
      style.width, style.flexBasis, style.minWidth, style.maxWidth,
      style.hasFlexGrow, style.flexGrow, parentDir == fdRow, parentInnerW,
      isEmptyLeaf = true
    )
    if style.width.kind == cskPercent and style.width.value >= 99.9'f32 and parentDir == fdColumn and parentInnerW < 0.0'f32:
      tree.nodes[hrSlab].widthMode = flexGrow(1.0'f32)
    tree.nodes[hrSlab].heightMode = resolveSizeMode(
      style.height, style.flexBasis, style.minHeight, style.maxHeight,
      style.hasFlexGrow, style.flexGrow, parentDir == fdColumn, parentInnerH,
      defaultPx = 1.0'f32, isEmptyLeaf = true
    )
    applyVisualOpacity(tree.nodes[hrSlab], style)
    if node.id.len > 0:
      bindings.idToSlab.put(node.id, hrSlab)
    return wrapWithMarginIfNeeded(tree, hrSlab, style, parentDir, parentSlab)

  # 3. <input> & <textarea>
  if node.tag == "input" or node.tag == "textarea":
    if node.tag == "input":
      let typeOpt = node.getAttr("type")
      if typeOpt.isSome and htmlEqIgnoreCase(typeOpt.get(), "hidden"):
        return SlabId(-1)

    let slab = tree.createNode(nkTextInput)
    if node.tag == "textarea":
      let txt = doc.innerText(nodeIdx)
      if txt.len > 0:
        tree.nodes[slab].text = txt
    else:
      let valOpt = node.getAttr("value")
      if valOpt.isSome:
        tree.nodes[slab].text = valOpt.get()

    let phOpt = node.getAttr("placeholder")
    if phOpt.isSome:
      tree.nodes[slab].placeholder = phOpt.get()

    var defW = 180.0'f32
    var defH = style.fontSize + style.padding[0] + style.padding[2] + 6.0'f32
    if node.tag == "textarea":
      defW = 240.0'f32
      var rows = 3
      let rowsOpt = node.getAttr("rows")
      if rowsOpt.isSome:
        let rInt = parseIntSafe(rowsOpt.get())
        if rInt.isSome and rInt.get() > 0:
          rows = min(rInt.get(), 40)
      let colsOpt = node.getAttr("cols")
      if colsOpt.isSome:
        let cInt = parseIntSafe(colsOpt.get())
        if cInt.isSome and cInt.get() > 0:
          defW = float32(min(cInt.get(), 160)) * (style.fontSize * 0.6'f32)
      defH = float32(rows) * (style.fontSize * 1.35'f32) + style.padding[0] + style.padding[2]

    tree.nodes[slab].padding = toLayoutPadding(style.padding)
    tree.nodes[slab].widthMode = resolveSizeMode(
      style.width, style.flexBasis, style.minWidth, style.maxWidth,
      style.hasFlexGrow, style.flexGrow, parentDir == fdRow, parentInnerW,
      defaultPx = defW
    )
    tree.nodes[slab].heightMode = resolveSizeMode(
      style.height, style.flexBasis, style.minHeight, style.maxHeight,
      style.hasFlexGrow, style.flexGrow, parentDir == fdColumn, parentInnerH,
      defaultPx = defH
    )
    applyVisualOpacity(tree.nodes[slab], style)
    tree.nodes[slab].borderWidth = style.borderWidth
    tree.nodes[slab].radius = style.borderRadius
    tree.nodes[slab].fontSize = style.fontSize

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = true, isDisabled = isDisabled)

    return wrapWithMarginIfNeeded(tree, slab, style, parentDir, parentSlab)

  # 4. <select> with <option> children
  if node.tag == "select":
    var optLabels: seq[string] = @[]
    var selectedIdx = 0
    for cIdx in doc.nodes[nodeIdx].children:
      let ch = doc.nodes[cIdx]
      if ch.kind == hnkElement and ch.tag == "option":
        let lbl = htmlStripAscii(doc.innerText(cIdx))
        let val = ch.getAttr("value").getOr(lbl)
        let displayLbl = if lbl.len > 0: lbl else: val
        if ch.getAttr("selected").isSome:
          selectedIdx = optLabels.len
        optLabels.add(displayLbl)

    let slab = tree.createNode(nkButton)
    let initialText = if optLabels.len > 0: optLabels[selectedIdx] & " ▾" else: "▾"
    tree.nodes[slab].text = initialText
    tree.nodes[slab].padding = toLayoutPadding(style.padding)
    tree.nodes[slab].widthMode = resolveSizeMode(
      style.width, style.flexBasis, style.minWidth, style.maxWidth,
      style.hasFlexGrow, style.flexGrow, parentDir == fdRow, parentInnerW,
      defaultPx = 160.0'f32
    )
    tree.nodes[slab].heightMode = resolveSizeMode(
      style.height, style.flexBasis, style.minHeight, style.maxHeight,
      style.hasFlexGrow, style.flexGrow, parentDir == fdColumn, parentInnerH,
      defaultPx = style.fontSize + style.padding[0] + style.padding[2] + 8.0'f32
    )
    tree.nodes[slab].alignItems = aiCenter
    tree.nodes[slab].justifyContent = jcSpaceBetween
    applyVisualOpacity(tree.nodes[slab], style)
    tree.nodes[slab].borderWidth = style.borderWidth
    tree.nodes[slab].radius = style.borderRadius
    tree.nodes[slab].fontSize = style.fontSize

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = false, isDisabled = isDisabled)

    if not isDisabled and optLabels.len > 1 and tree.nodes[slab].onClick.isNil:
      var curIdx = selectedIdx
      let optsCopy = optLabels
      let treePtr = addr tree
      tree.nodes[slab].onClick = proc() {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          curIdx = (curIdx + 1) mod optsCopy.len
          if treePtr[].nodes.contains(slab):
            treePtr[].nodes[slab].text = optsCopy[curIdx] & " ▾"
            treePtr[].nodes[slab].isDirty = true
            treePtr[].isDirty = true

    return wrapWithMarginIfNeeded(tree, slab, style, parentDir, parentSlab)

  # 5. <img> & <svg> safe bounding-box containers
  if node.tag == "img" or node.tag == "svg":
    var effW = style.width
    var effH = style.height
    if effW.kind == cskAuto:
      effW = parseHtmlAttrDim(node, "width")
    if effH.kind == cskAuto:
      effH = parseHtmlAttrDim(node, "height")
    var defW = if node.tag == "img": 64.0'f32 else: 48.0'f32
    var defH = if node.tag == "img": 48.0'f32 else: 48.0'f32
    if node.tag == "svg" and (effW.kind == cskAuto or effH.kind == cskAuto):
      let vb = parseSvgViewBoxSize(node)
      if vb.hasSize:
        defW = vb.w
        defH = vb.h

    let boxSlab = tree.createNode(nkBox)
    tree.nodes[boxSlab].direction = fdRow
    tree.nodes[boxSlab].alignItems = aiCenter
    tree.nodes[boxSlab].justifyContent = jcCenter
    tree.nodes[boxSlab].padding = toLayoutPadding(style.padding)
    tree.nodes[boxSlab].widthMode = resolveSizeMode(
      effW, style.flexBasis, style.minWidth, style.maxWidth,
      style.hasFlexGrow, style.flexGrow, parentDir == fdRow, parentInnerW,
      defaultPx = defW, isEmptyLeaf = true
    )
    tree.nodes[boxSlab].heightMode = resolveSizeMode(
      effH, style.flexBasis, style.minHeight, style.maxHeight,
      style.hasFlexGrow, style.flexGrow, parentDir == fdColumn, parentInnerH,
      defaultPx = defH, isEmptyLeaf = true
    )
    if style.bgColor == 0'u32 and style.borderWidth == 0.0'f32 and node.tag == "img":
      style.bgColor = 0x1E293B66'u32
      style.borderColor = 0x334155FF'u32
      style.borderWidth = 1.0'f32
    applyVisualOpacity(tree.nodes[boxSlab], style)
    tree.nodes[boxSlab].borderWidth = style.borderWidth
    tree.nodes[boxSlab].radius = style.borderRadius
    tree.nodes[boxSlab].fontSize = style.fontSize

    if node.tag == "img":
      let altOpt = node.getAttr("alt")
      if altOpt.isSome and htmlStripAscii(altOpt.get()).len > 0:
        let altTxt = tree.createNode(nkText)
        tree.nodes[altTxt].text = htmlStripAscii(altOpt.get())
        tree.nodes[altTxt].textColor = tree.nodes[boxSlab].textColor
        tree.nodes[altTxt].fontSize = style.fontSize
        tree.nodes[altTxt].widthMode = fitContent()
        tree.nodes[altTxt].heightMode = fitContent()
        tree.addChild(boxSlab, altTxt)

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, boxSlab)
    attachReactiveBindings(tree, rt, bindings, node, boxSlab, boxSlab, isInput = false, isDisabled = isDisabled)
    return wrapWithMarginIfNeeded(tree, boxSlab, style, parentDir, parentSlab)

  var elemChildren: seq[int] = @[]
  var directText = ""
  collectDirectTextAndElementChildren(doc, nodeIdx, elemChildren, directText)

  # 6. <button>
  if node.tag == "button":
    let slab = tree.createNode(nkButton)
    tree.nodes[slab].text = if directText.len > 0: directText else: htmlStripAscii(doc.innerText(nodeIdx))
    tree.nodes[slab].padding = toLayoutPadding(style.padding)
    tree.nodes[slab].widthMode = resolveSizeMode(
      style.width, style.flexBasis, style.minWidth, style.maxWidth,
      style.hasFlexGrow, style.flexGrow, parentDir == fdRow, parentInnerW
    )
    tree.nodes[slab].heightMode = resolveSizeMode(
      style.height, style.flexBasis, style.minHeight, style.maxHeight,
      style.hasFlexGrow, style.flexGrow, parentDir == fdColumn, parentInnerH
    )
    tree.nodes[slab].alignItems = style.alignItems
    tree.nodes[slab].justifyContent = style.justifyContent
    applyVisualOpacity(tree.nodes[slab], style)
    tree.nodes[slab].borderWidth = style.borderWidth
    tree.nodes[slab].radius = style.borderRadius
    tree.nodes[slab].fontSize = style.fontSize

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = false, isDisabled = isDisabled)

    return wrapWithMarginIfNeeded(tree, slab, style, parentDir, parentSlab)

  # 7. Pure leaf text optimization
  let hasBoundText = node.getAttr("data-text").isSome or node.getAttr("data-bind").isSome
  let isPureLeafText =
    listMarkerPrefix.len == 0 and
    elemChildren.len == 0 and
    (directText.len > 0 or hasBoundText) and
    not style.hasVisualBoxStyle() and
    node.tag in ["span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label", "strong", "b", "em", "a", "div", "option"]

  if isPureLeafText:
    let slab = tree.createNode(nkText)
    tree.nodes[slab].text = directText
    tree.nodes[slab].textColor = if style.opacitySet and style.opacity < 1.0'f32:
                                   applyColorOpacity(style.fgColor, style.opacity)
                                 else:
                                   style.fgColor
    tree.nodes[slab].fontSize = style.fontSize
    tree.nodes[slab].widthMode = fitContent()
    tree.nodes[slab].heightMode = fitContent()

    if node.id.len > 0:
      bindings.idToSlab.put(node.id, slab)
    attachReactiveBindings(tree, rt, bindings, node, slab, slab, isInput = false, isDisabled = isDisabled)

    if parentSlab != SlabId(-1):
      tree.addChild(parentSlab, slab)
    return slab

  # 8. Container element -> nkBox
  let boxSlab = tree.createNode(nkBox)
  let dir = if style.display == cdFlex:
              if style.flexDirectionSet: style.flexDirection else: fdRow
            elif style.flexDirectionSet:
              style.flexDirection
            else:
              fdColumn

  var growVal = style.flexGrow
  var hasGrow = style.hasFlexGrow
  if (node.tag == "th" or node.tag == "td") and not hasGrow and style.width.kind == cskAuto:
    let csOpt = node.getAttr("colspan")
    if csOpt.isSome:
      let cs = parseIntSafe(csOpt.get())
      if cs.isSome and cs.get() > 1:
        growVal = float32(cs.get())
        hasGrow = true

  let effGap = if dir == fdRow:
                 if style.columnGapSet: style.columnGap else: style.gap
               else:
                 if style.rowGapSet: style.rowGap else: style.gap

  tree.nodes[boxSlab].direction = dir
  tree.nodes[boxSlab].padding = toLayoutPadding(style.padding)
  tree.nodes[boxSlab].gap = effGap
  tree.nodes[boxSlab].alignItems = style.alignItems
  tree.nodes[boxSlab].justifyContent = style.justifyContent
  let isEmptyLeaf = elemChildren.len == 0 and directText.len == 0 and not hasBoundText and listMarkerPrefix.len == 0
  tree.nodes[boxSlab].widthMode = resolveSizeMode(
    style.width, style.flexBasis, style.minWidth, style.maxWidth,
    hasGrow, growVal, parentDir == fdRow, parentInnerW, isEmptyLeaf = isEmptyLeaf
  )
  if style.width.kind == cskAuto and (style.display == cdBlock or style.display == cdFlex) and
     parentDir == fdColumn and effectiveAlign == aiStretch:
    let maxW = resolveConstraintPx(style.maxWidth, parentInnerW)
    if maxW < 0.0'f32:
      tree.nodes[boxSlab].widthMode = flexGrow(1.0'f32)
  tree.nodes[boxSlab].heightMode = resolveSizeMode(
    style.height, style.flexBasis, style.minHeight, style.maxHeight,
    hasGrow, growVal, parentDir == fdColumn, parentInnerH, isEmptyLeaf = isEmptyLeaf
  )
  applyVisualOpacity(tree.nodes[boxSlab], style)
  tree.nodes[boxSlab].borderWidth = style.borderWidth
  tree.nodes[boxSlab].radius = style.borderRadius
  tree.nodes[boxSlab].fontSize = style.fontSize
  tree.nodes[boxSlab].isScrollable = style.overflowY

  if node.id.len > 0:
    bindings.idToSlab.put(node.id, boxSlab)

  let outerSlab = wrapWithMarginIfNeeded(tree, boxSlab, style, parentDir, parentSlab)

  let innerW = computeChildFixedInner(tree.nodes[boxSlab].widthMode, style.padding[1], style.padding[3])
  let innerH = computeChildFixedInner(tree.nodes[boxSlab].heightMode, style.padding[0], style.padding[2])

  var primaryTextSlab = boxSlab
  var attachedTextBinding = false

  if listMarkerPrefix.len > 0:
    let markerSlab = tree.createNode(nkText)
    tree.nodes[markerSlab].text = listMarkerPrefix
    tree.nodes[markerSlab].textColor = tree.nodes[boxSlab].textColor
    tree.nodes[markerSlab].fontSize = style.fontSize
    tree.nodes[markerSlab].widthMode = fitContent()
    tree.nodes[markerSlab].heightMode = fitContent()
    tree.addChild(boxSlab, markerSlab)

  var liOrdinal = 0
  for cIdx in doc.nodes[nodeIdx].children:
    let child = doc.nodes[cIdx]
    if child.kind == hnkText:
      let t = htmlStripAscii(child.text)
      if t.len > 0:
        let txtSlab = tree.createNode(nkText)
        tree.nodes[txtSlab].text = t
        tree.nodes[txtSlab].textColor = tree.nodes[boxSlab].textColor
        tree.nodes[txtSlab].fontSize = style.fontSize
        tree.nodes[txtSlab].widthMode = fitContent()
        tree.nodes[txtSlab].heightMode = fitContent()
        tree.addChild(boxSlab, txtSlab)
        if not attachedTextBinding:
          primaryTextSlab = txtSlab
          attachedTextBinding = true
    elif child.kind == hnkElement:
      if containsTag(SvgChildTags, child.tag):
        continue
      var childMarker = ""
      if child.tag == "li" and (node.tag == "ul" or node.tag == "ol") and style.listStyleType != "none":
        inc liOrdinal
        if node.tag == "ol" or style.listStyleType == "decimal":
          childMarker = $liOrdinal & "."
        elif style.listStyleType == "square":
          childMarker = "■"
        elif style.listStyleType == "circle":
          childMarker = "○"
        else:
          childMarker = "•"
      let mountedChild = mountElementRecursive(
        tree, rt, doc, cIdx, sheet, style, dir, style.alignItems, innerW, innerH, bindings, boxSlab,
        listMarkerPrefix = childMarker, depth = depth + 1
      )
      if mountedChild == SlabId(-1):
        discard

  if hasBoundText and not attachedTextBinding:
    let txtSlab = tree.createNode(nkText)
    tree.nodes[txtSlab].text = ""
    tree.nodes[txtSlab].textColor = tree.nodes[boxSlab].textColor
    tree.nodes[txtSlab].fontSize = style.fontSize
    tree.nodes[txtSlab].widthMode = fitContent()
    tree.nodes[txtSlab].heightMode = fitContent()
    tree.addChild(boxSlab, txtSlab)
    primaryTextSlab = txtSlab

  attachReactiveBindings(tree, rt, bindings, node, boxSlab, primaryTextSlab, isInput = false, isDisabled = isDisabled)
  if not isDisabled and not tree.nodes[boxSlab].onClick.isNil:
    propagateOnClickRecursive(tree, boxSlab, tree.nodes[boxSlab].onClick)
  outerSlab

proc collectMountableTopElements(doc: HtmlDoc, outIndices: var seq[int]) {.raises: [].} =
  if doc.nodes.len == 0:
    return
  for cIdx in doc.nodes[0].children:
    let child = doc.nodes[cIdx]
    if child.kind != hnkElement:
      continue
    if child.tag == "html":
      for hcIdx in child.children:
        let hChild = doc.nodes[hcIdx]
        if hChild.kind == hnkElement and not containsTag(HtmlSkipMountTags, hChild.tag):
          outIndices.add(hcIdx)
    elif not containsTag(HtmlSkipMountTags, child.tag):
      outIndices.add(cIdx)

proc mountHtml*(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  doc: HtmlDoc,
  sheet: CssStylesheet,
  bindings: var HtmlBindingRegistry,
  parentId: SlabId = SlabId(-1)
): Result[SlabId, string] {.raises: [].} =
  if doc.nodes.len == 0:
    return resErr[SlabId]("Cannot mount empty HtmlDoc")

  var topElements: seq[int] = @[]
  collectMountableTopElements(doc, topElements)

  var mountedTop: seq[SlabId] = @[]
  # Inherit :root style (e.g. --var declarations on :root or <html>) into body/top elements
  var baseStyle = defaultRootStyle()
  if doc.nodes.len > 0:
    for cIdx in doc.nodes[0].children:
      if doc.nodes[cIdx].kind == hnkElement and doc.nodes[cIdx].tag == "html":
        baseStyle = computeNodeStyle(doc, cIdx, sheet, baseStyle)
        break

  if parentId == SlabId(-1):
    var visibleIndices: seq[int] = @[]
    for idx in topElements:
      let st = computeNodeStyle(doc, idx, sheet, baseStyle)
      if st.display != cdNone:
        visibleIndices.add(idx)

    if visibleIndices.len == 0:
      let emptyRoot = tree.createNode(nkBox)
      tree.nodes[emptyRoot].widthMode = flexGrow(1.0'f32)
      tree.nodes[emptyRoot].heightMode = flexGrow(1.0'f32)
      if tree.rootId == SlabId(-1):
        tree.rootId = emptyRoot
      return resOk(emptyRoot)

    if visibleIndices.len == 1:
      let rootSlab = mountElementRecursive(
        tree, rt, doc, visibleIndices[0], sheet, baseStyle, fdColumn, aiStretch, -1.0'f32, -1.0'f32,
        bindings, SlabId(-1)
      )
      if rootSlab != SlabId(-1):
        if doc.nodes[visibleIndices[0]].tag == "body":
          if tree.nodes[rootSlab].widthMode.kind == smFitContent:
            tree.nodes[rootSlab].widthMode = flexGrow(1.0'f32)
          if tree.nodes[rootSlab].heightMode.kind == smFitContent:
            tree.nodes[rootSlab].heightMode = flexGrow(1.0'f32)
        if tree.rootId == SlabId(-1):
          tree.rootId = rootSlab
      return resOk(rootSlab)

    let wrapper = tree.createNode(nkBox)
    tree.nodes[wrapper].direction = fdColumn
    tree.nodes[wrapper].alignItems = aiStretch
    tree.nodes[wrapper].widthMode = flexGrow(1.0'f32)
    tree.nodes[wrapper].heightMode = flexGrow(1.0'f32)
    if tree.rootId == SlabId(-1):
      tree.rootId = wrapper
    for idx in visibleIndices:
      let mounted = mountElementRecursive(
        tree, rt, doc, idx, sheet, baseStyle, fdColumn, aiStretch, -1.0'f32, -1.0'f32,
        bindings, wrapper
      )
      if mounted == SlabId(-1):
        discard
    return resOk(wrapper)

  # Mounting into existing parentId
  let pNode = tree.nodes[parentId]
  let pInnerW = computeChildFixedInner(pNode.widthMode, pNode.padding[1], pNode.padding[3])
  let pInnerH = computeChildFixedInner(pNode.heightMode, pNode.padding[0], pNode.padding[2])
  for idx in topElements:
    let mId = mountElementRecursive(
      tree, rt, doc, idx, sheet, baseStyle, pNode.direction, pNode.alignItems, pInnerW, pInnerH,
      bindings, parentId
    )
    if mId != SlabId(-1):
      mountedTop.add(mId)

  if mountedTop.len > 0:
    resOk(mountedTop[0])
  else:
    resOk(parentId)

proc mountHtmlString*(
  tree: var UiTree,
  rt: ptr ReactiveRuntime,
  html: string,
  extraCss: string,
  bindings: var HtmlBindingRegistry,
  parentId: SlabId = SlabId(-1)
): Result[SlabId, string] {.raises: [].} =
  let docRes = parseHtmlDoc(html)
  if docRes.isErr():
    return resErr[SlabId](docRes.error())
  let doc = docRes.get()
  let embeddedSheet = parseCssSheet(doc.embeddedCss)
  let extraSheet = parseCssSheet(extraCss)
  let combined = mergeStylesheets(embeddedSheet, extraSheet)
  mountHtml(tree, rt, doc, combined, bindings, parentId)
