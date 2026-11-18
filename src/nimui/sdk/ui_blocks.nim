## nimui/sdk/ui_blocks — Minimal Component SDK UI Blocks
##
## Provides the 11 minimal UI building blocks on top of UiTree & nimui/dsl:
##   1. Text       2. Button     3. Input      4. List       5. Table
##   6. Image      7. Tabs       8. Modal      9. Toast      10. FilePicker
##   11. Timer
##
## Strict invariants:
## - Zero-exception {.raises: [].} APIs.
## - FilePicker requires `permFs`; OS-level Toast notifications require `permNotifications`.
## - All UI blocks render into UiTree without allocating raw OS handles during headless tests.

import corex/[slab, result]
import ../layout
import ../dsl
import ./permissions

type
  ImageFit* = enum
    ifContain = "contain"
    ifCover = "cover"
    ifFill = "fill"

  TableColumn* = object
    key*: string
    title*: string
    width*: float32

  TableBlock* = object
    rootId*: SlabId
    headerId*: SlabId
    bodyId*: SlabId
    columns*: seq[TableColumn]
    rows*: seq[seq[string]]

  TabItem* = object
    id*: string
    label*: string
    buttonId*: SlabId
    panelId*: SlabId

  TabsBlock* = object
    rootId*: SlabId
    tabBarId*: SlabId
    contentId*: SlabId
    activeIndex*: int
    tabs*: seq[TabItem]

  ModalBlock* = object
    backdropId*: SlabId
    dialogId*: SlabId
    titleId*: SlabId
    bodyId*: SlabId
    isOpen*: bool

  ToastLevel* = enum
    tlInfo = "info"
    tlSuccess = "success"
    tlWarn = "warn"
    tlError = "error"

  ToastBlock* = object
    rootId*: SlabId
    labelId*: SlabId
    visible*: bool
    level*: ToastLevel
    message*: string
    durationMs*: int
    remainingMs*: int
    osNotification*: bool

  FilePickerMode* = enum
    fpOpenFile = "open"
    fpSaveFile = "save"
    fpSelectDir = "directory"

  FilePickerBlock* = object
    rootId*: SlabId
    buttonId*: SlabId
    pathTextId*: SlabId
    mode*: FilePickerMode
    filters*: seq[string]
    selectedPath*: string

  TimerBlock* = object
    intervalMs*: int
    elapsedMs*: int
    repeat*: bool
    running*: bool
    tickCount*: int
    onTick*: proc(tickCount: int) {.closure, gcsafe, raises: [].}

# =============================================================================
# 1. Text, 2. Button, 3. Input, 4. List (wrapping nimui/dsl)
# =============================================================================

proc sdkText*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  text: string = "",
  size: float32 = 14.0f,
  color: uint32 = 0xFFFFFFFF'u32,
  padding: float32 = 0.0f
): SlabId {.inline, raises: [].} =
  dsl.Text(tree, parent, text, size, color, padding)

proc sdkButton*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  label: string = "",
  size: float32 = 14.0f,
  onClick: proc() {.closure, gcsafe, raises: [].} = nil
): SlabId {.inline, raises: [].} =
  dsl.Button(tree, parent, label = label, size = size, onClick = onClick)

proc sdkInput*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  placeholder: string = "",
  text: string = "",
  width: SizeMode = fixed(240.0f),
  height: SizeMode = fixed(36.0f),
  onInput: proc(s: string) {.closure, gcsafe, raises: [].} = nil
): SlabId {.inline, raises: [].} =
  dsl.TextInput(tree, parent, placeholder = placeholder, text = text, width = width, height = height, onInput = onInput)

proc sdkList*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  count: int = 0,
  itemHeight: float32 = 32.0f,
  width: SizeMode = flexGrow(),
  height: SizeMode = fixed(240.0f),
  renderItem: RenderVirtualItemProc = nil
): SlabId {.inline, raises: [].} =
  dsl.VirtualList(tree, parent, count = count, itemHeight = itemHeight, width = width, height = height, renderItem = renderItem)

# =============================================================================
# 5. Table
# =============================================================================

proc sdkTable*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  columns: openArray[TableColumn],
  rows: openArray[seq[string]] = @[],
  rowHeight: float32 = 28.0f
): TableBlock {.raises: [].} =
  let rootId = dsl.VStack(
    tree, parent,
    padding = 0.0f, gap = 0.0f,
    bg = 0x18181BFF'u32, borderColor = 0x2E2E34FF'u32,
    radius = 6.0f, borderWidth = 1.0f,
    width = flexGrow()
  )
  let headerId = dsl.HStack(
    tree, rootId,
    padding = 8.0f, gap = 8.0f,
    bg = 0x222227FF'u32,
    width = flexGrow(), height = fixed(rowHeight + 8.0f),
    alignItems = aiCenter
  )
  for col in columns:
    let colW = if col.width > 0.0f: fixed(col.width) else: flexGrow()
    let cell = dsl.Box(tree, headerId, width = colW, height = fitContent())
    discard dsl.Text(tree, cell, col.title, size = 13.0f, color = 0xE4E4E7FF'u32)

  let bodyId = dsl.VStack(tree, rootId, padding = 0.0f, gap = 1.0f, width = flexGrow())
  for row in rows:
    let rowId = dsl.HStack(
      tree, bodyId,
      padding = 6.0f, gap = 8.0f,
      bg = 0x18181BFF'u32,
      width = flexGrow(), height = fixed(rowHeight),
      alignItems = aiCenter
    )
    for cIdx, col in columns:
      let colW = if col.width > 0.0f: fixed(col.width) else: flexGrow()
      let cell = dsl.Box(tree, rowId, width = colW, height = fitContent())
      let val = if cIdx < row.len: row[cIdx] else: ""
      discard dsl.Text(tree, cell, val, size = 13.0f, color = 0xD4D4D8FF'u32)

  TableBlock(
    rootId: rootId,
    headerId: headerId,
    bodyId: bodyId,
    columns: @columns,
    rows: @rows
  )

# =============================================================================
# 6. Image
# =============================================================================

proc sdkImage*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  src: string,
  alt: string = "",
  width: float32 = 128.0f,
  height: float32 = 128.0f,
  fit: ImageFit = ifContain,
  radius: float32 = 4.0f
): SlabId {.raises: [].} =
  ## Scaffolds an Image container node in UiTree; `src` and `alt` are preserved on the node.
  let boxId = dsl.Box(
    tree, parent,
    width = fixed(width), height = fixed(height),
    bg = 0x1F1F24FF'u32, borderColor = 0x323238FF'u32,
    radius = radius, borderWidth = 1.0f,
    alignItems = aiCenter, justifyContent = jcCenter
  )
  tree.nodes[boxId].placeholder = src
  if alt.len > 0:
    discard dsl.Text(tree, boxId, alt, size = 12.0f, color = 0x9CA3AFFF'u32)
  else:
    discard dsl.Text(tree, boxId, "[" & $fit & ": " & src & "]", size = 11.0f, color = 0x9CA3AFFF'u32)
  boxId

# =============================================================================
# 7. Tabs
# =============================================================================

proc sdkTabs*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  labels: openArray[string],
  activeIndex: int = 0
): TabsBlock {.raises: [].} =
  let rootId = dsl.VStack(tree, parent, padding = 0.0f, gap = 8.0f, width = flexGrow())
  let tabBarId = dsl.HStack(
    tree, rootId,
    padding = 4.0f, gap = 6.0f,
    bg = 0x18181BFF'u32, borderColor = 0x2E2E34FF'u32,
    radius = 6.0f, borderWidth = 1.0f
  )
  let contentId = dsl.VStack(tree, rootId, padding = 8.0f, gap = 6.0f, width = flexGrow())

  let clampedActive = if labels.len == 0: -1 else: clamp(activeIndex, 0, labels.len - 1)
  var items: seq[TabItem] = @[]
  for i, lbl in labels:
    let isActive = (i == clampedActive)
    let btnBg = if isActive: 0x3F3F46FF'u32 else: 0x242428FF'u32
    let btnId = dsl.Button(tree, tabBarId, label = lbl, bg = btnBg)
    let panelId = dsl.VStack(tree, contentId, padding = 4.0f, width = flexGrow())
    if not isActive:
      tree.nodes[panelId].heightMode = fixed(0.0f)
    items.add(TabItem(id: "tab-" & $i, label: lbl, buttonId: btnId, panelId: panelId))

  TabsBlock(
    rootId: rootId,
    tabBarId: tabBarId,
    contentId: contentId,
    activeIndex: clampedActive,
    tabs: items
  )

proc switchTab*(tabs: var TabsBlock, tree: var UiTree, index: int): SdkResult[void] {.raises: [].} =
  if index < 0 or index >= tabs.tabs.len:
    return SdkResult[void].err(makeSdkErr(sdkErrInvalidInput, "Tab index out of range: " & $index))
  tabs.activeIndex = index
  for i, item in tabs.tabs:
    let isActive = (i == index)
    if tree.nodes.contains(item.buttonId):
      tree.nodes[item.buttonId].bgColor = if isActive: 0x3F3F46FF'u32 else: 0x242428FF'u32
    if tree.nodes.contains(item.panelId):
      tree.nodes[item.panelId].heightMode = if isActive: fitContent() else: fixed(0.0f)
  tree.isLayoutDirty = true
  tree.isDirty = true
  SdkResult[void].ok()

# =============================================================================
# 8. Modal
# =============================================================================

proc sdkModal*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  title: string,
  isOpen: bool = false,
  width: float32 = 420.0f
): ModalBlock {.raises: [].} =
  let backdropId = dsl.VStack(
    tree, parent,
    padding = 24.0f,
    bg = 0x000000AA'u32,
    width = flexGrow(),
    height = (if isOpen: flexGrow() else: fixed(0.0f)),
    alignItems = aiCenter,
    justifyContent = jcCenter
  )
  let dialogId = dsl.VStack(
    tree, backdropId,
    padding = 16.0f, gap = 12.0f,
    bg = 0x1E1E22FF'u32, borderColor = 0x3F3F46FF'u32,
    radius = 8.0f, borderWidth = 1.0f,
    width = fixed(width)
  )
  let titleId = dsl.Text(tree, dialogId, title, size = 16.0f, color = 0xFFFFFFFF'u32)
  let bodyId = dsl.VStack(tree, dialogId, padding = 0.0f, gap = 8.0f, width = flexGrow())

  ModalBlock(
    backdropId: backdropId,
    dialogId: dialogId,
    titleId: titleId,
    bodyId: bodyId,
    isOpen: isOpen
  )

proc setModalOpen*(modal: var ModalBlock, tree: var UiTree, open: bool) {.raises: [].} =
  modal.isOpen = open
  if tree.nodes.contains(modal.backdropId):
    tree.nodes[modal.backdropId].heightMode = if open: flexGrow() else: fixed(0.0f)
  tree.isLayoutDirty = true
  tree.isDirty = true

# =============================================================================
# 9. Toast
# =============================================================================

proc toastBg(level: ToastLevel): uint32 {.inline, raises: [].} =
  case level
  of tlInfo: 0x1E293BFF'u32
  of tlSuccess: 0x14532DFF'u32
  of tlWarn: 0x713F12FF'u32
  of tlError: 0x7F1D1DFF'u32

proc sdkToast*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  message: string = "",
  level: ToastLevel = tlInfo,
  durationMs: int = 3000,
  osNotification: bool = false
): ToastBlock {.raises: [].} =
  let rootId = dsl.HStack(
    tree, parent,
    padding = 10.0f, gap = 8.0f,
    bg = toastBg(level), borderColor = 0x52525BFF'u32,
    radius = 6.0f, borderWidth = 1.0f,
    height = fixed(0.0f),
    alignItems = aiCenter
  )
  let labelId = dsl.Text(tree, rootId, message, size = 13.0f, color = 0xFFFFFFFF'u32)
  ToastBlock(
    rootId: rootId,
    labelId: labelId,
    visible: false,
    level: level,
    message: message,
    durationMs: durationMs,
    remainingMs: 0,
    osNotification: osNotification
  )

proc showToast*(
  toast: var ToastBlock,
  tree: var UiTree,
  policy: var PermissionPolicy,
  message: string,
  level: ToastLevel = tlInfo,
  durationMs: int = 3000
): SdkResult[void] {.raises: [].} =
  ## Displays an in-app toast; if `toast.osNotification` is true, requires `permNotifications`.
  if toast.osNotification:
    let perm = policy.requirePermission(permNotifications, "toast:show", message)
    if perm.isErr:
      return perm
  toast.visible = true
  toast.level = level
  toast.message = message
  toast.durationMs = durationMs
  toast.remainingMs = durationMs
  if tree.nodes.contains(toast.rootId):
    tree.nodes[toast.rootId].bgColor = toastBg(level)
    tree.nodes[toast.rootId].heightMode = fitContent()
  if tree.nodes.contains(toast.labelId):
    tree.nodes[toast.labelId].text = message
  tree.isLayoutDirty = true
  tree.isDirty = true
  SdkResult[void].ok()

proc tickToast*(toast: var ToastBlock, tree: var UiTree, elapsedMs: int) {.raises: [].} =
  if not toast.visible or elapsedMs <= 0:
    return
  toast.remainingMs -= elapsedMs
  if toast.remainingMs <= 0:
    toast.visible = false
    toast.remainingMs = 0
    if tree.nodes.contains(toast.rootId):
      tree.nodes[toast.rootId].heightMode = fixed(0.0f)
    tree.isLayoutDirty = true
    tree.isDirty = true

# =============================================================================
# 10. FilePicker
# =============================================================================

proc sdkFilePicker*(
  tree: var UiTree,
  parent: SlabId = SlabId(-1),
  buttonLabel: string = "Choose File...",
  mode: FilePickerMode = fpOpenFile,
  filters: openArray[string] = @[]
): FilePickerBlock {.raises: [].} =
  let rootId = dsl.HStack(tree, parent, padding = 4.0f, gap = 8.0f, alignItems = aiCenter)
  let buttonId = dsl.Button(tree, rootId, label = buttonLabel)
  let pathTextId = dsl.Text(tree, rootId, "No file selected", size = 13.0f, color = 0xA1A1AAFF'u32)
  FilePickerBlock(
    rootId: rootId,
    buttonId: buttonId,
    pathTextId: pathTextId,
    mode: mode,
    filters: @filters,
    selectedPath: ""
  )

proc pickFile*(
  picker: var FilePickerBlock,
  tree: var UiTree,
  policy: var PermissionPolicy,
  selectedPath: string
): SdkResult[string] {.raises: [].} =
  ## Validates `permFs` (and write access for `fpSaveFile`) and records the selected path.
  let permRes =
    if picker.mode == fpSaveFile:
      policy.requireFsWrite("file_picker:save", selectedPath)
    else:
      policy.requirePermission(permFs, "file_picker:" & $picker.mode, selectedPath)
  if permRes.isErr:
    return SdkResult[string].err(permRes.unwrapErr())
  if selectedPath.len == 0:
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "Selected path cannot be empty"))
  picker.selectedPath = selectedPath
  if tree.nodes.contains(picker.pathTextId):
    tree.nodes[picker.pathTextId].text = selectedPath
  tree.isLayoutDirty = true
  tree.isDirty = true
  SdkResult[string].ok(selectedPath)

# =============================================================================
# 11. Timer
# =============================================================================

proc sdkTimer*(
  intervalMs: int = 1000,
  repeat: bool = true,
  autoStart: bool = false,
  onTick: proc(tickCount: int) {.closure, gcsafe, raises: [].} = nil
): TimerBlock {.raises: [].} =
  TimerBlock(
    intervalMs: max(1, intervalMs),
    elapsedMs: 0,
    repeat: repeat,
    running: autoStart,
    tickCount: 0,
    onTick: onTick
  )

proc start*(t: var TimerBlock) {.inline, raises: [].} =
  t.running = true

proc stop*(t: var TimerBlock) {.inline, raises: [].} =
  t.running = false

proc reset*(t: var TimerBlock) {.inline, raises: [].} =
  t.elapsedMs = 0
  t.tickCount = 0

proc tick*(t: var TimerBlock, deltaMs: int): int {.raises: [].} =
  ## Advances timer by `deltaMs`; returns number of fired ticks in this step.
  if not t.running or deltaMs <= 0:
    return 0
  t.elapsedMs += deltaMs
  var fired = 0
  while t.elapsedMs >= t.intervalMs:
    t.elapsedMs -= t.intervalMs
    inc t.tickCount
    inc fired
    if t.onTick != nil:
      t.onTick(t.tickCount)
    if not t.repeat:
      t.running = false
      t.elapsedMs = 0
      break
  fired
