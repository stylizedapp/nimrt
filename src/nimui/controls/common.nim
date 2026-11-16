## nimui/controls/common — Shared Design Tokens, Key Constants, Types & Registry

import corex/slab
import algx/swissmap

const
  ColBgPage*      = 0x0A0A0CFF'u32  # Deep obsidian page background
  ColBgSurface*   = 0x121215FF'u32  # Primary card surface
  ColBgRaised*    = 0x1A1A1EFF'u32  # Control surface
  ColBgHover*     = 0x222227FF'u32  # Hover state
  ColBgActive*    = 0x2C2C33FF'u32  # Active / selected state
  ColBorder*      = 0x202025FF'u32  # Subtle layout border
  ColBorderCtl*   = 0x323238FF'u32  # Interactive element border
  ColFocusRing*   = 0x666670FF'u32  # High-contrast focus / active border
  ColTextPrim*    = 0xF2F2F2FF'u32  # High-contrast primary text
  ColTextSec*     = 0x8E8E93FF'u32  # Secondary metadata text
  ColTextTert*    = 0x545458FF'u32  # Annotations and shortcuts

const
  KeyBackspace* = 0x08'u32
  KeyTab*       = 0x09'u32
  KeyReturn*    = 0x0D'u32
  KeyEscape*    = 0x1B'u32
  KeySpace*     = 0x20'u32
  KeyLeft*      = 0x25'u32
  KeyUp*        = 0x26'u32
  KeyRight*     = 0x27'u32
  KeyDown*      = 0x28'u32

type
  CheckboxControl* = ref object
    checked*: bool
    disabled*: bool
    label*: string
    size*: float32
    boxId*: SlabId
    checkId*: SlabId
    labelId*: SlabId
    rootId*: SlabId
    onToggle*: proc(checked: bool) {.closure, gcsafe, raises: [].}

  RadioGroupControl* = ref object
    selectedValue*: string
    selectedInt*: int
    radios*: seq[RadioButtonControl]
    containerId*: SlabId
    onSelect*: proc(value: string) {.closure, gcsafe, raises: [].}
    onSelectInt*: proc(idx: int) {.closure, gcsafe, raises: [].}

  RadioGroupState* = RadioGroupControl
  CheckboxState* = CheckboxControl

  RadioButtonControl* = ref object
    group*: RadioGroupControl
    value*: string
    valueInt*: int
    selected*: bool
    disabled*: bool
    label*: string
    size*: float32
    outerRingId*: SlabId
    innerCircleId*: SlabId
    labelId*: SlabId
    rootId*: SlabId
    onSelect*: proc() {.closure, gcsafe, raises: [].}

  RadioButtonState* = RadioButtonControl
  SliderState* = SliderControl
  DropdownState* = DropdownControl
  TooltipState* = TooltipControl

  SliderControl* = ref object
    minVal*: float32
    maxVal*: float32
    step*: float32
    currentVal*: float32
    disabled*: bool
    isDragging*: bool
    width*: float32
    trackHeight*: float32
    thumbSize*: float32
    rootId*: SlabId
    trackFillId*: SlabId
    thumbId*: SlabId
    trackEmptyId*: SlabId
    onValueChange*: proc(val: float32) {.closure, gcsafe, raises: [].}

  DropdownControl* = ref object
    items*: seq[string]
    selectedIndex*: int
    isOpen*: bool
    disabled*: bool
    hoveredIndex*: int
    headerId*: SlabId
    textId*: SlabId
    arrowId*: SlabId
    itemHeight*: float32
    fontSize*: float32
    onSelect*: proc(idx: int) {.closure, gcsafe, raises: [].}
    computedHeaderRect*: tuple[x, y, w, h: float32]

  TooltipPlacement* = enum
    tpAbove
    tpBelow
    tpAuto

  TooltipControl* = ref object
    text*: string
    targetId*: SlabId
    visible*: bool
    placement*: TooltipPlacement
    fontSize*: float32
    padding*: float32
    bg*: uint32
    borderColor*: uint32
    borderWidth*: float32
    radius*: float32
    computedRect*: tuple[x, y, w, h: float32]

  ControlRegistry* = ref object
    checkboxes*: seq[CheckboxControl]
    radioGroups*: seq[RadioGroupControl]
    sliders*: seq[SliderControl]
    dropdowns*: seq[DropdownControl]
    tooltips*: seq[TooltipControl]
    nodeToCheckbox*: FastMap[SlabId, CheckboxControl]
    nodeToRadio*: FastMap[SlabId, RadioButtonControl]
    nodeToSlider*: FastMap[SlabId, SliderControl]
    nodeToDropdown*: FastMap[SlabId, DropdownControl]

var gDefaultRegistry {.threadvar.}: ControlRegistry

proc getRegistry*(): ControlRegistry {.raises: [].} =
  if gDefaultRegistry.isNil:
    gDefaultRegistry = ControlRegistry(
      checkboxes: @[],
      radioGroups: @[],
      sliders: @[],
      dropdowns: @[],
      tooltips: @[],
      nodeToCheckbox: initFastMap[SlabId, CheckboxControl](),
      nodeToRadio: initFastMap[SlabId, RadioButtonControl](),
      nodeToSlider: initFastMap[SlabId, SliderControl](),
      nodeToDropdown: initFastMap[SlabId, DropdownControl]()
    )
  gDefaultRegistry

proc resetControls*() {.raises: [].} =
  if not gDefaultRegistry.isNil:
    for cb in gDefaultRegistry.checkboxes:
      if not cb.isNil:
        cb.onToggle = nil
    for rg in gDefaultRegistry.radioGroups:
      if not rg.isNil:
        rg.onSelect = nil
        rg.onSelectInt = nil
        for rb in rg.radios:
          if not rb.isNil:
            rb.group = nil
            rb.onSelect = nil
        rg.radios.setLen(0)
    for rb in gDefaultRegistry.nodeToRadio.vals:
      if not rb.isNil:
        rb.group = nil
        rb.onSelect = nil
    for sl in gDefaultRegistry.sliders:
      if not sl.isNil:
        sl.onValueChange = nil
    for dd in gDefaultRegistry.dropdowns:
      if not dd.isNil:
        dd.onSelect = nil
    reset(gDefaultRegistry.checkboxes)
    reset(gDefaultRegistry.radioGroups)
    reset(gDefaultRegistry.sliders)
    reset(gDefaultRegistry.dropdowns)
    reset(gDefaultRegistry.tooltips)
    reset(gDefaultRegistry.nodeToCheckbox)
    reset(gDefaultRegistry.nodeToRadio)
    reset(gDefaultRegistry.nodeToSlider)
    reset(gDefaultRegistry.nodeToDropdown)
    gDefaultRegistry = nil
