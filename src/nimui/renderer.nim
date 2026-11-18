## nimui/renderer — Unified Vulkan 1.1+ Renderer with Graceful CPU Rasterizer Fallback
##
## Policy:
## - Primary production renderer: Vulkan 1.1+ (`VulkanBackend`).
## - Graceful production & test fallback: Pure-Nim CPU SDF rasterizer (`SoftwareFramebuffer`)
##   whenever Vulkan 1.1+ is unavailable, the driver is too old, shader compilation fails,
##   or an unrecoverable `VK_ERROR_DEVICE_LOST` occurs at runtime.

import corex/result
import ./gpu/vulkan_api
import ./gpu/vulkan_backend
import ./gpu/font_atlas
import ./rasterizer

type
  RendererMode* = enum
    rmVulkan
    rmCpuFallback

  NimuiRenderer* = object
    mode*: RendererMode
    vulkan*: VulkanBackend
    cpuFb*: SoftwareFramebuffer
    diagnostic*: VulkanDiagnostic
    width*: uint32
    height*: uint32
    dpiScale*: float32
    hwnd*: pointer
    deviceLostFallbackCount*: int

proc isUsingCpuFallback*(r: NimuiRenderer): bool {.inline, raises: [].} =
  r.mode == rmCpuFallback

proc diagnosticSummary*(r: NimuiRenderer): string {.raises: [].} =
  let modeStr = if r.mode == rmVulkan: "Vulkan 1.1+" else: "CPU Fallback (SoftwareFramebuffer)"
  modeStr & " [" & $r.diagnostic.kind & "]: " & r.diagnostic.message

proc initRenderer*(
  hwnd: pointer,
  width, height: uint32,
  atlas: FontAtlas,
  forceCpu: bool = false,
  enableValidation: bool = defined(nimuiValidation),
  dpiScale: float32 = 1.0f,
  clearColor: uint32 = 0x0A0A0CFF'u32
): NimuiRenderer {.trustedUnsafe, raises: [].} =
  let w = max(1'u32, width)
  let h = max(1'u32, height)
  result.width = w
  result.height = h
  result.dpiScale = if dpiScale > 0.1f: dpiScale else: 1.0f
  result.hwnd = hwnd

  if forceCpu:
    result.mode = rmCpuFallback
    result.cpuFb = initSoftwareFramebuffer(int(w), int(h), clearColor)
    result.diagnostic = makeVulkanDiagnostic("CPU fallback explicitly requested")
    return result

  let vkRes = initVulkanBackend(hwnd, w, h, atlas, enableValidation, result.dpiScale)
  if vkRes.isOk:
    result.mode = rmVulkan
    result.vulkan = vkRes.val
    result.diagnostic = VulkanDiagnostic(
      kind: vkdOk,
      message: "Vulkan " & MinVulkanVersionString & "+ active",
      vkResult: VK_SUCCESS,
      driverApiVersion: MinVulkanApiVersion,
      deviceName: ""
    )
  else:
    result.mode = rmCpuFallback
    result.cpuFb = initSoftwareFramebuffer(int(w), int(h), clearColor)
    result.diagnostic = makeVulkanDiagnostic(vkRes.error)

proc resize*(r: var NimuiRenderer, width, height: uint32, clearColor: uint32 = 0x0A0A0CFF'u32) {.raises: [].} =
  let w = max(1'u32, width)
  let h = max(1'u32, height)
  r.width = w
  r.height = h
  if r.mode == rmVulkan:
    r.vulkan.needsResize = true
  else:
    if r.cpuFb.width != int(w) or r.cpuFb.height != int(h):
      r.cpuFb = initSoftwareFramebuffer(int(w), int(h), clearColor)

proc transitionToCpuFallback*(
  r: var NimuiRenderer,
  reason: string,
  vkRes: VkResult = VK_ERROR_DEVICE_LOST,
  clearColor: uint32 = 0x0A0A0CFF'u32
) {.raises: [].} =
  if r.mode == rmVulkan:
    r.vulkan.destroy()
  r.mode = rmCpuFallback
  if r.cpuFb.width != int(r.width) or r.cpuFb.height != int(r.height):
    r.cpuFb = initSoftwareFramebuffer(int(r.width), int(r.height), clearColor)
  r.diagnostic = makeVulkanDiagnostic(reason, vkRes)
  inc r.deviceLostFallbackCount

proc renderFrame*(
  r: var NimuiRenderer,
  instances: openArray[UiDrawInstance],
  atlas: FontAtlas,
  clearColor: uint32 = 0x121214FF'u32
): Result[void, string] {.trustedUnsafe, raises: [].} =
  if r.mode == rmCpuFallback:
    if r.cpuFb.width != int(r.width) or r.cpuFb.height != int(r.height):
      r.cpuFb = initSoftwareFramebuffer(int(r.width), int(r.height), clearColor)
    r.cpuFb.renderInstancesToBuffer(instances, atlas, clearColor = clearColor, shouldClear = true)
    return ok[void, string]()

  let acqRes = r.vulkan.beginFrame(r.width, r.height)
  if acqRes.isErr:
    let errMsg = acqRes.error
    if r.vulkan.isDeviceLost() or classifyVulkanDiagnostic(errMsg, r.vulkan.lastVkResult) == vkdDeviceLost:
      let recRes = r.vulkan.recoverFromDeviceLost(r.hwnd, r.width, r.height, atlas)
      if recRes.isOk:
        return ok[void, string]()
      r.transitionToCpuFallback("device lost: recovery failed (" & recRes.error & ")", VK_ERROR_DEVICE_LOST, clearColor)
      r.cpuFb.renderInstancesToBuffer(instances, atlas, clearColor = clearColor, shouldClear = true)
      return ok[void, string]()
    return err[void, string](errMsg)

  let imgIdx = acqRes.val
  let pInst = if instances.len > 0: unsafeAddr instances[0] else: nil
  let renRes = r.vulkan.renderInstancesResult(imgIdx, pInst, instances.len, clearColor)
  if renRes.isErr:
    let errMsg = renRes.error
    if r.vulkan.isDeviceLost() or classifyVulkanDiagnostic(errMsg, r.vulkan.lastVkResult) == vkdDeviceLost:
      let recRes = r.vulkan.recoverFromDeviceLost(r.hwnd, r.width, r.height, atlas)
      if recRes.isOk:
        return ok[void, string]()
      r.transitionToCpuFallback("device lost: recovery failed (" & recRes.error & ")", VK_ERROR_DEVICE_LOST, clearColor)
      r.cpuFb.renderInstancesToBuffer(instances, atlas, clearColor = clearColor, shouldClear = true)
      return ok[void, string]()
    return err[void, string](errMsg)

  ok[void, string]()

proc destroy*(r: var NimuiRenderer) {.raises: [].} =
  if r.mode == rmVulkan:
    r.vulkan.destroy()
  r.cpuFb.pixels.setLen(0)
  r.cpuFb.width = 0
  r.cpuFb.height = 0
