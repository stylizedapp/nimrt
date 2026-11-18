## tests/test_nimui_vulkan_fallback.nim — Vulkan 1.1+ Min Config, Diagnostics & CPU Fallback Tests

import corex
import nimui/gpu/vulkan_api
import nimui/gpu/vulkan_backend
import nimui/gpu/font_atlas
import nimui/layout
import nimui/rasterizer
import nimui/renderer

proc main() =
  echo "================================================================="
  echo ">>> STARTING VULKAN FALLBACK & DIAGNOSTICS TEST SUITE <<<"
  echo "================================================================="

  let atlas = initFontAtlas("Segoe UI", 16.0f)

  testWithLeakCheck("1. Minimum Vulkan 1.1 Config & Version Formatting"):
    doAssert MinVulkanApiMajor == 1'u32
    doAssert MinVulkanApiMinor == 1'u32
    doAssert formatVulkanVersion(MinVulkanApiVersion) == "1.1.0"
    let vk10 = (1'u32 shl 22) or (0'u32 shl 12)
    doAssert vk10 < MinVulkanApiVersion
    doAssert formatVulkanVersion(vk10) == "1.0.0"
    echo "  [PASS] 1. Minimum Vulkan 1.1 config verified."

  testWithLeakCheck("2. Diagnostic Classification (4 Required Categories)"):
    let dUnavail = makeVulkanDiagnostic("could not load vulkan-1.dll")
    doAssert dUnavail.kind == vkdVulkanUnavailable
    doAssert dUnavail.message.len > 0

    let dOld = makeVulkanDiagnostic("GPU driver supports Vulkan 1.0.0, minimum required is 1.1.0", VK_ERROR_INCOMPATIBLE_DRIVER)
    doAssert dOld.kind == vkdDriverTooOld

    let dShader = makeVulkanDiagnostic("vkCreateShaderModule(vertex) returned VkResult -1")
    doAssert dShader.kind == vkdShaderCompilationFailed

    let dLost = makeVulkanDiagnostic("VK_ERROR_DEVICE_LOST in vkQueueSubmit", VK_ERROR_DEVICE_LOST)
    doAssert dLost.kind == vkdDeviceLost
    echo "  [PASS] 2. All 4 Vulkan diagnostic categories verified."

  testWithLeakCheck("3. Graceful Fallback on Unavailable HWND & Explicit CPU Mode"):
    var rNil = initRenderer(nil, 320'u32, 240'u32, atlas)
    defer: rNil.destroy()
    doAssert rNil.isUsingCpuFallback()
    doAssert rNil.diagnostic.kind == vkdVulkanUnavailable
    doAssert rNil.cpuFb.width == 320 and rNil.cpuFb.height == 240

    var rCpu = initRenderer(nil, 200'u32, 150'u32, atlas, forceCpu = true)
    defer: rCpu.destroy()
    doAssert rCpu.isUsingCpuFallback()

    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let root = tree.createNode(nkBox)
    tree.rootId = root
    tree.nodes[root].widthMode = fixed(200.0f)
    tree.nodes[root].heightMode = fixed(150.0f)
    tree.nodes[root].bgColor = 0x1E293BFF'u32

    let child = tree.createNode(nkBox)
    tree.nodes[child].widthMode = fixed(80.0f)
    tree.nodes[child].heightMode = fixed(40.0f)
    tree.nodes[child].bgColor = 0x38BDF8FF'u32
    tree.addChild(root, child)

    tree.layoutTree(200.0f, 150.0f, atlas)
    discard tree.buildDrawInstances(atlas)

    let res = rCpu.renderFrame(tree.drawInstances, atlas, clearColor = 0x0A0A0CFF'u32)
    doAssert res.isOk
    doAssert rCpu.cpuFb.getPixel(40, 20) == 0x38BDF8FF'u32
    doAssert rCpu.cpuFb.getPixel(150, 100) == 0x1E293BFF'u32
    echo "  [PASS] 3. Graceful CPU fallback rendering verified."

  testWithLeakCheck("4. Runtime Device-Lost Fallback Transition"):
    var r = initRenderer(nil, 160'u32, 120'u32, atlas, forceCpu = true)
    defer: r.destroy()
    r.transitionToCpuFallback("VK_ERROR_DEVICE_LOST during vkQueueSubmit", VK_ERROR_DEVICE_LOST)
    doAssert r.isUsingCpuFallback()
    doAssert r.diagnostic.kind == vkdDeviceLost
    doAssert r.deviceLostFallbackCount == 1

    var inst = UiDrawInstance(
      pos: [10.0f, 10.0f],
      size: [50.0f, 50.0f],
      color: 0xEF4444FF'u32,
      softness: 1.0f,
      clipRect: [0'u16, 0'u16, 160'u16, 120'u16]
    )
    let res = r.renderFrame([inst], atlas, clearColor = 0x000000FF'u32)
    doAssert res.isOk
    doAssert r.cpuFb.getPixel(35, 35) == 0xEF4444FF'u32
    echo "  [PASS] 4. Runtime device-lost fallback verified with 0 leaks."

  echo "================================================================="
  echo ">>> [SUCCESS] ALL VULKAN FALLBACK TESTS PASSED WITH 0 LEAKS! <<<"
  echo "================================================================="

when isMainModule:
  main()
