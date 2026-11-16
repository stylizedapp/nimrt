## nimui/controls/tooltip — Tooltip Control & Overlay Renderer

import corex/slab
import ../layout
import ../gpu/font_atlas
import ../gpu/vulkan_backend
import ./common

proc newTooltip*(
  targetId: SlabId,
  text: string,
  placement: TooltipPlacement = tpAuto,
  fontSize: float32 = 12.0f,
  padding: float32 = 8.0f
): TooltipControl {.raises: [].} =
  TooltipControl(
    text: text,
    targetId: targetId,
    visible: false,
    placement: placement,
    fontSize: fontSize,
    padding: padding,
    bg: ColBgSurface,
    borderColor: ColBorderCtl,
    borderWidth: 1.0f,
    radius: 4.0f,
    computedRect: (0.0f, 0.0f, 0.0f, 0.0f)
  )

proc update*(
  tt: TooltipControl,
  tree: UiTree,
  atlas: FontAtlas,
  screenW: float32 = 1920.0f,
  screenH: float32 = 1080.0f
) {.raises: [].} =
  if tt == nil: return
  if tt.targetId == SlabId(-1) or not tree.nodes.contains(tt.targetId):
    tt.visible = false
    return

  let target = addr tree.nodes[tt.targetId]
  let isHovered = target.isHovered or (tree.hoveredNode == tt.targetId)
  tt.visible = isHovered

  if tt.visible:
    let (tw, th) = if atlas.baseSize > 0.0f:
      atlas.measureText(tt.text, tt.fontSize)
    else:
      (float32(tt.text.len) * 8.0f, 16.0f)

    let cw = tw + tt.padding * 2.0f
    let ch = th + tt.padding * 1.5f
    let (tx, ty, twTarget, thTarget) = target.computedRect

    var cx = tx + (twTarget - cw) * 0.5f
    cx = max(4.0f, min(screenW - cw - 4.0f, cx))

    var cy = 0.0f
    case tt.placement
    of tpAbove:
      cy = ty - ch - 6.0f
    of tpBelow:
      cy = ty + thTarget + 6.0f
    of tpAuto:
      if ty - ch - 6.0f >= 0.0f:
        cy = ty - ch - 6.0f
      else:
        cy = ty + thTarget + 6.0f

    tt.computedRect = (cx, cy, cw, ch)

proc renderOverlay*(
  tt: TooltipControl,
  instances: var seq[UiDrawInstance],
  atlas: FontAtlas
) {.raises: [].} =
  if tt == nil or not tt.visible or tt.text.len == 0: return

  let clipAll: array[4, uint16] = [0'u16, 0'u16, 0xFFFF'u16, 0xFFFF'u16]
  let (cx, cy, cw, ch) = tt.computedRect

  var cardInst: UiDrawInstance
  cardInst.pos = [cx, cy]
  cardInst.size = [cw, ch]
  cardInst.uvPos = [0.0f, 0.0f]
  cardInst.uvSize = [0.0f, 0.0f]
  cardInst.color = tt.bg
  cardInst.borderColor = tt.borderColor
  cardInst.cornerRadius = tt.radius
  cardInst.borderWidth = tt.borderWidth
  cardInst.softness = 2.0f
  cardInst.clipRect = clipAll
  cardInst.pad = 0'u32
  instances.add(cardInst)

  let textY = cy + tt.padding * 0.75f
  emitTextRun(instances, tt.text, cx + tt.padding, textY, tt.fontSize, ColTextPrim, clipAll, atlas)

proc Tooltip*(
  tree: var UiTree,
  targetId: SlabId,
  text: string,
  placement: TooltipPlacement = tpAuto
): TooltipControl {.discardable, raises: [].} =
  let tt = newTooltip(targetId, text, placement)
  getRegistry().tooltips.add(tt)
  tt
