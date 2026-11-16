## nimui/gpu/vulkan_backend — High-Performance 2D SDF Vulkan 1.1+ Backend
##
## Strict invariants:
## - Direct dynamic linking to vulkan-1.dll (Win32) / libvulkan.so.1 (Linux).
## - Zero third-party dependencies (no SDL/GLFW/Qt).
## - Instanced 2D SDF pipeline with single vkCmdDrawIndexed per frame.
## - Cache-line aligned 64-byte UiDrawInstance.
## - HostVisible + HostCoherent mapped ring instance buffers.
## - Complete leak-free resource destruction before vkDestroyDevice.

import ./vulkan_api
import ./shaders
import ./font_atlas
import corex/result

const
  MaxFramesInFlight* = 2
  MaxInstancesPerFrame* = 16384 # 1MB per frame (2MB total ring buffer), supports 16K UI primitives per frame

type
  UiDrawInstance* {.packed.} = object
    pos*: array[2, float32]         # Screen coords x, y (8B)
    size*: array[2, float32]        # Width, height (8B)
    uvPos*: array[2, float32]       # Texture atlas u, v (8B)
    uvSize*: array[2, float32]      # Atlas width, height (8B, uvSize.x == 0 => solid SDF primitive)
    color*: uint32                  # RGBA8 packed (4B)
    borderColor*: uint32            # RGBA8 packed (4B)
    cornerRadius*: float32          # Corner radius in pixels (4B)
    borderWidth*: float32           # Border width in pixels (4B)
    softness*: float32              # Edge anti-aliasing / soft shadow (4B)
    clipRect*: array[4, uint16]     # Hardware/shader clip [minX, minY, maxX, maxY] (8B)
    pad*: uint32                    # Padding to exact 64 bytes (4B)

  PushConstants* = object
    resolution*: array[2, float32]

  VulkanBackend* = object
    api*: VulkanApi
    instance*: VkInstance
    physicalDevice*: VkPhysicalDevice
    device*: VkDevice
    graphicsQueue*: VkQueue
    presentQueue*: VkQueue
    graphicsQueueFamily*: uint32
    presentQueueFamily*: uint32
    surface*: VkSurfaceKHR

    # Swapchain
    swapchain*: VkSwapchainKHR
    swapchainFormat*: uint32
    swapchainExtent*: VkExtent2D
    swapchainImages*: seq[VkImage]
    swapchainImageViews*: seq[VkImageView]
    framebuffers*: seq[VkFramebuffer]
    renderPass*: VkRenderPass

    # Synchronization
    imageAvailableSemaphores*: array[MaxFramesInFlight, VkSemaphore]
    renderFinishedSemaphores*: array[MaxFramesInFlight, VkSemaphore]
    inFlightFences*: array[MaxFramesInFlight, VkFence]
    currentFrame*: int

    # Command Pool & Buffers
    commandPool*: VkCommandPool
    commandBuffers*: array[MaxFramesInFlight, VkCommandBuffer]

    # Pipeline & Descriptors
    descriptorSetLayout*: VkDescriptorSetLayout
    descriptorPool*: VkDescriptorPool
    descriptorSet*: VkDescriptorSet
    pipelineLayout*: VkPipelineLayout
    pipeline*: VkPipeline

    # Mesh Buffers (Unit Quad)
    quadVertexBuffer*: VkBuffer
    quadVertexMemory*: VkDeviceMemory
    quadIndexBuffer*: VkBuffer
    quadIndexMemory*: VkDeviceMemory

    # Host-Mapped Ring Instance Buffers
    instanceBuffers*: array[MaxFramesInFlight, VkBuffer]
    instanceMemories*: array[MaxFramesInFlight, VkDeviceMemory]
    mappedInstances*: array[MaxFramesInFlight, ptr UncheckedArray[UiDrawInstance]]

    # Font Atlas Texture
    fontImage*: VkImage
    fontImageMemory*: VkDeviceMemory
    fontImageView*: VkImageView
    fontSampler*: VkSampler
    fontTexWidth*: int
    fontTexHeight*: int

    hwnd*: pointer
    isInitialized*: bool
    needsResize*: bool
    isMinimized*: bool
    deviceLost*: bool
    lastVkResult*: VkResult
    lastError*: string
    validationEnabled*: bool
    validationActive*: bool
    dpiScale*: float32

# Static Unit Quad Vertices (4 vertices, 6 indices)
const quadVertices: array[8, float32] = [
  0.0f, 0.0f,
  1.0f, 0.0f,
  1.0f, 1.0f,
  0.0f, 1.0f
]

const quadIndices: array[6, uint16] = [
  0'u16, 1'u16, 2'u16,
  2'u16, 3'u16, 0'u16
]

# Ensure UiDrawInstance is exactly 64 bytes
static:
  doAssert sizeof(UiDrawInstance) == 64, "UiDrawInstance must be exactly 64 bytes"

# =============================================================================
# Forward Declarations
# =============================================================================

proc destroy*(backend: var VulkanBackend) {.raises: [].}
proc recreateSwapchain*(backend: var VulkanBackend, width, height: uint32): bool {.trustedUnsafe, raises: [].}

proc recordVkError*(backend: var VulkanBackend, res: VkResult, op: string) {.raises: [].} =
  backend.lastVkResult = res
  if res == VK_SUCCESS:
    return
  if res == VK_ERROR_DEVICE_LOST:
    backend.deviceLost = true
    backend.lastError = "VK_ERROR_DEVICE_LOST in " & op
  else:
    backend.lastError = op & " failed with VkResult " & $res

proc checkVk*(backend: var VulkanBackend, res: VkResult, op: string): Result[void, string] {.raises: [].} =
  backend.recordVkError(res, op)
  if res == VK_SUCCESS:
    return ok[void, string]()
  err[void, string](backend.lastError)

proc isDeviceLost*(backend: VulkanBackend): bool {.inline, raises: [].} =
  backend.deviceLost

proc setDpiScale*(backend: var VulkanBackend, dpiScale: float32) {.inline, raises: [].} =
  backend.dpiScale = if dpiScale > 0.1f: dpiScale else: 1.0f

proc logicalExtent*(backend: VulkanBackend): tuple[width, height: float32] {.inline, raises: [].} =
  let scale = if backend.dpiScale > 0.1f: backend.dpiScale else: 1.0f
  (float32(backend.swapchainExtent.width) / scale, float32(backend.swapchainExtent.height) / scale)

# Safe: queries Vulkan instance layer properties into stack/heap seq via vkEnumerateInstanceLayerProperties.
proc hasValidationLayer(api: VulkanApi): bool {.trustedUnsafe, raises: [].} =
  if api.vkEnumerateInstanceLayerProperties.isNil:
    return false
  var count: uint32 = 0
  if api.vkEnumerateInstanceLayerProperties(addr count, nil) != VK_SUCCESS or count == 0:
    return false
  var layers = newSeq[VkLayerProperties](count)
  if api.vkEnumerateInstanceLayerProperties(addr count, addr layers[0]) != VK_SUCCESS:
    return false
  const target = "VK_LAYER_KHRONOS_validation"
  for layer in layers:
    var matched = true
    for i in 0 ..< target.len:
      if layer.layerName[i] != target[i]:
        matched = false
        break
    if matched and layer.layerName[target.len] == '\0':
      return true
  false

# =============================================================================
# Memory Helper
# =============================================================================

# Safe: queries Vulkan physical device memory properties into local VkPhysicalDeviceMemoryProperties.
proc findMemoryType(api: VulkanApi, physicalDevice: VkPhysicalDevice, typeFilter: uint32, properties: VkFlags): int32 {.trustedUnsafe, raises: [].} =
  var memProps: VkPhysicalDeviceMemoryProperties
  api.vkGetPhysicalDeviceMemoryProperties(physicalDevice, addr memProps)
  for i in 0 ..< int32(memProps.memoryTypeCount):
    if (typeFilter and (1'u32 shl i)) != 0 and (memProps.memoryTypes[i].propertyFlags and properties) == properties:
      return i
  -1'i32

# =============================================================================
# Buffer & Image Allocations
# =============================================================================

# Safe: allocates and binds a Vulkan buffer + device memory; destroys buffer on failure.
proc createBuffer(
  backend: VulkanBackend,
  size: VkDeviceSize,
  usage: VkFlags,
  properties: VkFlags,
  outBuffer: var VkBuffer,
  outMemory: var VkDeviceMemory
): bool {.trustedUnsafe, raises: [].} =
  var bufferInfo = VkBufferCreateInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    size: size,
    usage: usage,
    sharingMode: VK_SHARING_MODE_EXCLUSIVE
  )
  if backend.api.vkCreateBuffer(backend.device, addr bufferInfo, nil, addr outBuffer) != VK_SUCCESS:
    return false

  var memReqs: VkMemoryRequirements
  backend.api.vkGetBufferMemoryRequirements(backend.device, outBuffer, addr memReqs)

  let memTypeIdx = findMemoryType(backend.api, backend.physicalDevice, memReqs.memoryTypeBits, properties)
  if memTypeIdx < 0:
    backend.api.vkDestroyBuffer(backend.device, outBuffer, nil)
    return false

  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: memReqs.size,
    memoryTypeIndex: uint32(memTypeIdx)
  )
  if backend.api.vkAllocateMemory(backend.device, addr allocInfo, nil, addr outMemory) != VK_SUCCESS:
    backend.api.vkDestroyBuffer(backend.device, outBuffer, nil)
    return false

  if backend.api.vkBindBufferMemory(backend.device, outBuffer, outMemory, 0) != VK_SUCCESS:
    backend.api.vkFreeMemory(backend.device, outMemory, nil)
    backend.api.vkDestroyBuffer(backend.device, outBuffer, nil)
    return false

  true

# =============================================================================
# Swapchain Setup & Recreation
# =============================================================================

proc cleanupSwapchain(backend: var VulkanBackend) {.raises: [].} =
  if backend.device.isNil:
    return

  for fb in backend.framebuffers:
    if fb != 0:
      backend.api.vkDestroyFramebuffer(backend.device, fb, nil)
  backend.framebuffers.setLen(0)

  for iv in backend.swapchainImageViews:
    if iv != 0:
      backend.api.vkDestroyImageView(backend.device, iv, nil)
  backend.swapchainImageViews.setLen(0)

  if backend.swapchain != 0:
    backend.api.vkDestroySwapchainKHR(backend.device, backend.swapchain, nil)
    backend.swapchain = 0

# Safe: queries Vulkan surface capabilities/formats/present modes for a live VkSurfaceKHR.
proc initSurfaceConfig*(backend: var VulkanBackend, width, height: uint32): bool {.trustedUnsafe, raises: [].} =
  var surfCaps: VkSurfaceCapabilitiesKHR
  let capRes = backend.api.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(backend.physicalDevice, backend.surface, addr surfCaps)
  if capRes != VK_SUCCESS:
    backend.recordVkError(capRes, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
    return false

  var desiredExtent = VkExtent2D(width: max(1'u32, width), height: max(1'u32, height))
  if surfCaps.currentExtent.width != 0xFFFFFFFF'u32:
    desiredExtent = surfCaps.currentExtent
  else:
    desiredExtent.width = max(surfCaps.minImageExtent.width, min(surfCaps.maxImageExtent.width, desiredExtent.width))
    desiredExtent.height = max(surfCaps.minImageExtent.height, min(surfCaps.maxImageExtent.height, desiredExtent.height))
  backend.swapchainExtent = desiredExtent

  # Query surface formats
  var formatCount: uint32 = 0
  if backend.api.vkGetPhysicalDeviceSurfaceFormatsKHR(backend.physicalDevice, backend.surface, addr formatCount, nil) != VK_SUCCESS or formatCount == 0:
    return false
  var formats = newSeq[VkSurfaceFormatKHR](formatCount)
  if backend.api.vkGetPhysicalDeviceSurfaceFormatsKHR(backend.physicalDevice, backend.surface, addr formatCount, addr formats[0]) != VK_SUCCESS:
    return false

  var chosenFormat = formats[0]
  for f in formats:
    if (f.format == VK_FORMAT_B8G8R8A8_UNORM or f.format == VK_FORMAT_R8G8B8A8_UNORM) and f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR:
      chosenFormat = f
      break
  backend.swapchainFormat = chosenFormat.format
  true

# Safe: creates Vulkan swapchain, image views, and framebuffers for live device/surface.
proc createSwapchain(backend: var VulkanBackend, width, height: uint32, oldSwapchain: VkSwapchainKHR = 0): bool {.trustedUnsafe, raises: [].} =
  if width == 0 or height == 0:
    backend.isMinimized = true
    return false

  var surfCaps: VkSurfaceCapabilitiesKHR
  let capRes = backend.api.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(backend.physicalDevice, backend.surface, addr surfCaps)
  if capRes != VK_SUCCESS:
    backend.recordVkError(capRes, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
    return false

  var desiredExtent = VkExtent2D(width: width, height: height)
  if surfCaps.currentExtent.width != 0xFFFFFFFF'u32:
    desiredExtent = surfCaps.currentExtent
  else:
    desiredExtent.width = max(surfCaps.minImageExtent.width, min(surfCaps.maxImageExtent.width, desiredExtent.width))
    desiredExtent.height = max(surfCaps.minImageExtent.height, min(surfCaps.maxImageExtent.height, desiredExtent.height))

  if desiredExtent.width == 0 or desiredExtent.height == 0:
    backend.isMinimized = true
    return false

  backend.isMinimized = false
  backend.swapchainExtent = desiredExtent

  var imageCount = surfCaps.minImageCount + 1
  if surfCaps.maxImageCount > 0 and imageCount > surfCaps.maxImageCount:
    imageCount = surfCaps.maxImageCount

  # Query surface formats
  var formatCount: uint32 = 0
  if backend.api.vkGetPhysicalDeviceSurfaceFormatsKHR(backend.physicalDevice, backend.surface, addr formatCount, nil) != VK_SUCCESS or formatCount == 0:
    return false
  var formats = newSeq[VkSurfaceFormatKHR](formatCount)
  if backend.api.vkGetPhysicalDeviceSurfaceFormatsKHR(backend.physicalDevice, backend.surface, addr formatCount, addr formats[0]) != VK_SUCCESS:
    return false

  var chosenFormat = formats[0]
  for f in formats:
    if (f.format == VK_FORMAT_B8G8R8A8_UNORM or f.format == VK_FORMAT_R8G8B8A8_UNORM) and f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR:
      chosenFormat = f
      break
  backend.swapchainFormat = chosenFormat.format

  # Present mode (Prefer Mailbox for low latency, FIFO for standard vsync)
  var presentModeCount: uint32 = 0
  if backend.api.vkGetPhysicalDeviceSurfacePresentModesKHR(backend.physicalDevice, backend.surface, addr presentModeCount, nil) != VK_SUCCESS or presentModeCount == 0:
    return false
  var presentModes = newSeq[uint32](presentModeCount)
  if backend.api.vkGetPhysicalDeviceSurfacePresentModesKHR(backend.physicalDevice, backend.surface, addr presentModeCount, addr presentModes[0]) != VK_SUCCESS:
    return false

  var chosenPresentMode: uint32 = VK_PRESENT_MODE_FIFO_KHR
  for pm in presentModes:
    if pm == VK_PRESENT_MODE_MAILBOX_KHR:
      chosenPresentMode = VK_PRESENT_MODE_MAILBOX_KHR
      break

  var swapchainInfo = VkSwapchainCreateInfoKHR(
    sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
    surface: backend.surface,
    minImageCount: imageCount,
    imageFormat: chosenFormat.format,
    imageColorSpace: chosenFormat.colorSpace,
    imageExtent: desiredExtent,
    imageArrayLayers: 1,
    imageUsage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
    preTransform: surfCaps.currentTransform,
    compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    presentMode: chosenPresentMode,
    clipped: 1,
    oldSwapchain: oldSwapchain
  )

  var queueFamilies = [backend.graphicsQueueFamily, backend.presentQueueFamily]
  if backend.graphicsQueueFamily != backend.presentQueueFamily:
    swapchainInfo.imageSharingMode = VK_SHARING_MODE_CONCURRENT
    swapchainInfo.queueFamilyIndexCount = 2
    swapchainInfo.pQueueFamilyIndices = addr queueFamilies[0]

  let scRes = backend.api.vkCreateSwapchainKHR(backend.device, addr swapchainInfo, nil, addr backend.swapchain)
  if scRes != VK_SUCCESS:
    backend.recordVkError(scRes, "vkCreateSwapchainKHR")
    return false

  # Retrieve swapchain images
  var actualImageCount: uint32 = 0
  if backend.api.vkGetSwapchainImagesKHR(backend.device, backend.swapchain, addr actualImageCount, nil) != VK_SUCCESS or actualImageCount == 0:
    return false
  backend.swapchainImages.setLen(actualImageCount)
  if backend.api.vkGetSwapchainImagesKHR(backend.device, backend.swapchain, addr actualImageCount, addr backend.swapchainImages[0]) != VK_SUCCESS:
    return false

  # Create image views
  backend.swapchainImageViews.setLen(actualImageCount)
  for i in 0 ..< int(actualImageCount):
    var viewInfo = VkImageViewCreateInfo(
      sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      image: backend.swapchainImages[i],
      viewType: VK_IMAGE_VIEW_TYPE_2D,
      format: backend.swapchainFormat,
      components: VkComponentMapping(
        r: VK_COMPONENT_SWIZZLE_IDENTITY,
        g: VK_COMPONENT_SWIZZLE_IDENTITY,
        b: VK_COMPONENT_SWIZZLE_IDENTITY,
        a: VK_COMPONENT_SWIZZLE_IDENTITY
      ),
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
        baseMipLevel: 0,
        levelCount: 1,
        baseArrayLayer: 0,
        layerCount: 1
      )
    )
    let ivRes = backend.api.vkCreateImageView(backend.device, addr viewInfo, nil, addr backend.swapchainImageViews[i])
    if ivRes != VK_SUCCESS:
      backend.recordVkError(ivRes, "vkCreateImageView")
      return false

  # Create framebuffers
  backend.framebuffers.setLen(actualImageCount)
  for i in 0 ..< int(actualImageCount):
    var attachments = [backend.swapchainImageViews[i]]
    var fbInfo = VkFramebufferCreateInfo(
      sType: VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
      renderPass: backend.renderPass,
      attachmentCount: 1,
      pAttachments: addr attachments[0],
      width: desiredExtent.width,
      height: desiredExtent.height,
      layers: 1
    )
    let fbRes = backend.api.vkCreateFramebuffer(backend.device, addr fbInfo, nil, addr backend.framebuffers[i])
    if fbRes != VK_SUCCESS:
      backend.recordVkError(fbRes, "vkCreateFramebuffer")
      return false

  true

# Safe: waits for device idle and recreates swapchain via createSwapchain.
proc recreateSwapchain*(backend: var VulkanBackend, width, height: uint32): bool {.trustedUnsafe, raises: [].} =
  if backend.device.isNil or backend.deviceLost:
    return false
  if width == 0 or height == 0:
    backend.isMinimized = true
    return false

  # Check surface capabilities BEFORE tearing down active swapchain resources
  var surfCaps: VkSurfaceCapabilitiesKHR
  let capRes = backend.api.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(backend.physicalDevice, backend.surface, addr surfCaps)
  if capRes != VK_SUCCESS:
    backend.recordVkError(capRes, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
    return false
  if surfCaps.currentExtent.width != 0xFFFFFFFF'u32 and
     (surfCaps.currentExtent.width == 0 or surfCaps.currentExtent.height == 0):
    backend.isMinimized = true
    return false

  let waitIdleRes = backend.api.vkDeviceWaitIdle(backend.device)
  if waitIdleRes == VK_ERROR_DEVICE_LOST:
    backend.recordVkError(waitIdleRes, "vkDeviceWaitIdle")
    return false

  let oldSwapchain = backend.swapchain
  backend.swapchain = 0

  # Clean old views & framebuffers
  for fb in backend.framebuffers:
    if fb != 0:
      backend.api.vkDestroyFramebuffer(backend.device, fb, nil)
  backend.framebuffers.setLen(0)

  for iv in backend.swapchainImageViews:
    if iv != 0:
      backend.api.vkDestroyImageView(backend.device, iv, nil)
  backend.swapchainImageViews.setLen(0)

  let ok = createSwapchain(backend, width, height, oldSwapchain)
  if oldSwapchain != 0:
    backend.api.vkDestroySwapchainKHR(backend.device, oldSwapchain, nil)

  backend.needsResize = false
  ok

# =============================================================================
# Pipeline, RenderPass, and Shaders
# =============================================================================

# Safe: creates Vulkan render pass, shader modules, descriptor sets, and graphics pipeline.
proc createPipeline(backend: var VulkanBackend, atlas: FontAtlas): bool {.trustedUnsafe, raises: [].} =
  # 1. RenderPass
  var colorAttachment = VkAttachmentDescription(
    format: backend.swapchainFormat,
    samples: 1,
    loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
    storeOp: VK_ATTACHMENT_STORE_OP_STORE,
    stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
    finalLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
  )
  var colorRef = VkAttachmentReference(
    attachment: 0,
    layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
  )
  var subpass = VkSubpassDescription(
    pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
    colorAttachmentCount: 1,
    pColorAttachments: addr colorRef
  )
  var dependency = VkSubpassDependency(
    srcSubpass: 0xFFFFFFFF'u32, # VK_SUBPASS_EXTERNAL
    dstSubpass: 0,
    srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    srcAccessMask: 0,
    dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
  )
  var renderPassInfo = VkRenderPassCreateInfo(
    sType: VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
    attachmentCount: 1,
    pAttachments: addr colorAttachment,
    subpassCount: 1,
    pSubpasses: addr subpass,
    dependencyCount: 1,
    pDependencies: addr dependency
  )
  if backend.api.vkCreateRenderPass(backend.device, addr renderPassInfo, nil, addr backend.renderPass) != VK_SUCCESS:
    return false

  # 2. Font Atlas Texture Creation
  var imgInfo = VkImageCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    imageType: 1, # 2D
    format: VK_FORMAT_R8_UNORM,
    extent: VkExtent3D(width: uint32(atlas.width), height: uint32(atlas.height), depth: 1),
    mipLevels: 1,
    arrayLayers: 1,
    samples: 1,
    tiling: 0, # OPTIMAL
    usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT or VK_IMAGE_USAGE_SAMPLED_BIT,
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED
  )
  if backend.api.vkCreateImage(backend.device, addr imgInfo, nil, addr backend.fontImage) != VK_SUCCESS:
    return false

  var imgMemReqs: VkMemoryRequirements
  backend.api.vkGetImageMemoryRequirements(backend.device, backend.fontImage, addr imgMemReqs)
  let imgMemType = findMemoryType(backend.api, backend.physicalDevice, imgMemReqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
  var imgAlloc = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: imgMemReqs.size,
    memoryTypeIndex: uint32(imgMemType)
  )
  if backend.api.vkAllocateMemory(backend.device, addr imgAlloc, nil, addr backend.fontImageMemory) != VK_SUCCESS:
    return false
  if backend.api.vkBindImageMemory(backend.device, backend.fontImage, backend.fontImageMemory, 0) != VK_SUCCESS:
    return false
  backend.fontTexWidth = atlas.width
  backend.fontTexHeight = atlas.height

  # Staging buffer to upload pixels
  let imageBytes = VkDeviceSize(atlas.width * atlas.height)
  var stagingBuf: VkBuffer
  var stagingMem: VkDeviceMemory
  if not createBuffer(backend, imageBytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      stagingBuf, stagingMem):
    return false

  var pData: pointer = nil
  if backend.api.vkMapMemory(backend.device, stagingMem, 0, imageBytes, 0, addr pData) != VK_SUCCESS:
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return false
  if not pData.isNil and atlas.pixels.len > 0:
    copyMem(pData, unsafeAddr atlas.pixels[0], int(imageBytes))
  backend.api.vkUnmapMemory(backend.device, stagingMem)

  # One-shot command to transition image and copy buffer to image
  var allocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: backend.commandPool,
    level: 0,
    commandBufferCount: 1
  )
  var oneShotCmd: VkCommandBuffer
  if backend.api.vkAllocateCommandBuffers(backend.device, addr allocInfo, addr oneShotCmd) != VK_SUCCESS:
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return false
  var beginInfo = VkCommandBufferBeginInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    flags: 0x00000001 # ONE_TIME_SUBMIT
  )
  if backend.api.vkBeginCommandBuffer(oneShotCmd, addr beginInfo) != VK_SUCCESS:
    backend.api.vkFreeCommandBuffers(backend.device, backend.commandPool, 1, addr oneShotCmd)
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return false

  # Transition UNDEFINED -> TRANSFER_DST_OPTIMAL
  var barrier = VkImageMemoryBarrier(
    sType: 45, # VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
    oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
    newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    srcQueueFamilyIndex: 0xFFFFFFFF'u32,
    dstQueueFamilyIndex: 0xFFFFFFFF'u32,
    image: backend.fontImage,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1
    ),
    srcAccessMask: 0,
    dstAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT
  )
  backend.api.vkCmdPipelineBarrier(
    oneShotCmd,
    VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    VK_PIPELINE_STAGE_TRANSFER_BIT,
    0, 0, nil, 0, nil, 1, addr barrier
  )

  var copyRegion = VkBufferImageCopy(
    bufferOffset: 0,
    bufferRowLength: 0,
    bufferImageHeight: 0,
    imageSubresource: VkImageSubresourceLayers(
      aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
      mipLevel: 0,
      baseArrayLayer: 0,
      layerCount: 1
    ),
    imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
    imageExtent: VkExtent3D(width: uint32(atlas.width), height: uint32(atlas.height), depth: 1)
  )
  backend.api.vkCmdCopyBufferToImage(
    oneShotCmd, stagingBuf, backend.fontImage,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, addr copyRegion
  )

  # Transition TRANSFER_DST_OPTIMAL -> SHADER_READ_ONLY_OPTIMAL
  barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
  barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT
  barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT
  backend.api.vkCmdPipelineBarrier(
    oneShotCmd,
    VK_PIPELINE_STAGE_TRANSFER_BIT,
    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    0, 0, nil, 0, nil, 1, addr barrier
  )

  if backend.api.vkEndCommandBuffer(oneShotCmd) != VK_SUCCESS:
    backend.api.vkFreeCommandBuffers(backend.device, backend.commandPool, 1, addr oneShotCmd)
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return false
  var submitInfo = VkSubmitInfo(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,
    commandBufferCount: 1,
    pCommandBuffers: addr oneShotCmd
  )
  let subRes = backend.api.vkQueueSubmit(backend.graphicsQueue, 1, addr submitInfo, 0)
  let waitRes = backend.api.vkQueueWaitIdle(backend.graphicsQueue)
  backend.api.vkFreeCommandBuffers(backend.device, backend.commandPool, 1, addr oneShotCmd)
  backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
  backend.api.vkFreeMemory(backend.device, stagingMem, nil)
  if subRes != VK_SUCCESS or waitRes != VK_SUCCESS:
    return false

  # Font Image View & Sampler
  var fontViewInfo = VkImageViewCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    image: backend.fontImage,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: VK_FORMAT_R8_UNORM,
    components: VkComponentMapping(
      r: VK_COMPONENT_SWIZZLE_IDENTITY,
      g: VK_COMPONENT_SWIZZLE_IDENTITY,
      b: VK_COMPONENT_SWIZZLE_IDENTITY,
      a: VK_COMPONENT_SWIZZLE_IDENTITY
    ),
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1
    )
  )
  if backend.api.vkCreateImageView(backend.device, addr fontViewInfo, nil, addr backend.fontImageView) != VK_SUCCESS:
    return false

  var samplerInfo = VkSamplerCreateInfo(
    sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    magFilter: VK_FILTER_LINEAR,
    minFilter: VK_FILTER_LINEAR,
    mipmapMode: 0,
    addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
  )
  if backend.api.vkCreateSampler(backend.device, addr samplerInfo, nil, addr backend.fontSampler) != VK_SUCCESS:
    return false

  # 3. Descriptor Set Layout & Pool
  var samplerBinding = VkDescriptorSetLayoutBinding(
    binding: 0,
    descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    descriptorCount: 1,
    stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT
  )
  var layoutInfo = VkDescriptorSetLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount: 1,
    pBindings: addr samplerBinding
  )
  if backend.api.vkCreateDescriptorSetLayout(backend.device, addr layoutInfo, nil, addr backend.descriptorSetLayout) != VK_SUCCESS:
    return false

  var poolSize = VkDescriptorPoolSize(
    descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    descriptorCount: 1
  )
  var poolInfo = VkDescriptorPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    maxSets: 1,
    poolSizeCount: 1,
    pPoolSizes: addr poolSize
  )
  if backend.api.vkCreateDescriptorPool(backend.device, addr poolInfo, nil, addr backend.descriptorPool) != VK_SUCCESS:
    return false

  var setAllocInfo = VkDescriptorSetAllocateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool: backend.descriptorPool,
    descriptorSetCount: 1,
    pSetLayouts: addr backend.descriptorSetLayout
  )
  if backend.api.vkAllocateDescriptorSets(backend.device, addr setAllocInfo, addr backend.descriptorSet) != VK_SUCCESS:
    return false

  var imageDescriptorInfo = VkDescriptorImageInfo(
    sampler: backend.fontSampler,
    imageView: backend.fontImageView,
    imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
  )
  var writeDesc = VkWriteDescriptorSet(
    sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    dstSet: backend.descriptorSet,
    dstBinding: 0,
    dstArrayElement: 0,
    descriptorCount: 1,
    descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    pImageInfo: addr imageDescriptorInfo
  )
  backend.api.vkUpdateDescriptorSets(backend.device, 1, addr writeDesc, 0, nil)

  # 4. Pipeline Layout with Push Constants
  var pushRange = VkPushConstantRange(
    stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
    offset: 0,
    size: uint32(sizeof(PushConstants))
  )
  var pipelineLayoutInfo = VkPipelineLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount: 1,
    pSetLayouts: addr backend.descriptorSetLayout,
    pushConstantRangeCount: 1,
    pPushConstantRanges: addr pushRange
  )
  if backend.api.vkCreatePipelineLayout(backend.device, addr pipelineLayoutInfo, nil, addr backend.pipelineLayout) != VK_SUCCESS:
    return false

  # 5. Shaders
  var vertModuleInfo = VkShaderModuleCreateInfo(
    sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    codeSize: uint(uiVertexShaderSpv.len * sizeof(uint32)),
    pCode: unsafeAddr uiVertexShaderSpv[0]
  )
  var vertModule: VkShaderModule
  if backend.api.vkCreateShaderModule(backend.device, addr vertModuleInfo, nil, addr vertModule) != VK_SUCCESS:
    return false

  var fragModuleInfo = VkShaderModuleCreateInfo(
    sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    codeSize: uint(uiFragmentShaderSpv.len * sizeof(uint32)),
    pCode: unsafeAddr uiFragmentShaderSpv[0]
  )
  var fragModule: VkShaderModule
  if backend.api.vkCreateShaderModule(backend.device, addr fragModuleInfo, nil, addr fragModule) != VK_SUCCESS:
    backend.api.vkDestroyShaderModule(backend.device, vertModule, nil)
    return false

  var shaderStages = [
    VkPipelineShaderStageCreateInfo(
      sType: 18, # VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
      stage: VK_SHADER_STAGE_VERTEX_BIT,
      module: vertModule,
      pName: "main"
    ),
    VkPipelineShaderStageCreateInfo(
      sType: 18,
      stage: VK_SHADER_STAGE_FRAGMENT_BIT,
      module: fragModule,
      pName: "main"
    )
  ]

  # 6. Vertex & Instance Input Layout
  # Binding 0: Per-vertex unit quad
  # Binding 1: Per-instance UiDrawInstance
  var bindings = [
    VkVertexInputBindingDescription(
      binding: 0,
      stride: uint32(sizeof(float32) * 2),
      inputRate: VK_VERTEX_INPUT_RATE_VERTEX
    ),
    VkVertexInputBindingDescription(
      binding: 1,
      stride: uint32(sizeof(UiDrawInstance)),
      inputRate: VK_VERTEX_INPUT_RATE_INSTANCE
    )
  ]

  var attributes = [
    # Binding 0: Quad pos
    VkVertexInputAttributeDescription(location: 0, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: 0),
    # Binding 1: Instance data
    VkVertexInputAttributeDescription(location: 1, binding: 1, format: VK_FORMAT_R32G32_SFLOAT, offset: 0),   # pos
    VkVertexInputAttributeDescription(location: 2, binding: 1, format: VK_FORMAT_R32G32_SFLOAT, offset: 8),   # size
    VkVertexInputAttributeDescription(location: 3, binding: 1, format: VK_FORMAT_R32G32_SFLOAT, offset: 16),  # uvPos
    VkVertexInputAttributeDescription(location: 4, binding: 1, format: VK_FORMAT_R32G32_SFLOAT, offset: 24),  # uvSize
    VkVertexInputAttributeDescription(location: 5, binding: 1, format: VK_FORMAT_R32_UINT, offset: 32),       # color
    VkVertexInputAttributeDescription(location: 6, binding: 1, format: VK_FORMAT_R32_UINT, offset: 36),       # borderColor
    VkVertexInputAttributeDescription(location: 7, binding: 1, format: VK_FORMAT_R32_SFLOAT, offset: 40),     # cornerRadius
    VkVertexInputAttributeDescription(location: 8, binding: 1, format: VK_FORMAT_R32_SFLOAT, offset: 44),     # borderWidth
    VkVertexInputAttributeDescription(location: 9, binding: 1, format: VK_FORMAT_R32_SFLOAT, offset: 48),     # softness
    VkVertexInputAttributeDescription(location: 10, binding: 1, format: VK_FORMAT_R16G16B16A16_UINT, offset: 52) # clipRect
  ]

  var vertexInputState = VkPipelineVertexInputStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount: 2,
    pVertexBindingDescriptions: addr bindings[0],
    vertexAttributeDescriptionCount: uint32(attributes.len),
    pVertexAttributeDescriptions: addr attributes[0]
  )

  var inputAssembly = VkPipelineInputAssemblyStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
  )

  var viewportState = VkPipelineViewportStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount: 1,
    scissorCount: 1
  )

  var rasterizer = VkPipelineRasterizationStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode: VK_POLYGON_MODE_FILL,
    cullMode: VK_CULL_MODE_NONE,
    frontFace: VK_FRONT_FACE_CLOCKWISE,
    lineWidth: 1.0f
  )

  var multisampling = VkPipelineMultisampleStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples: 1
  )

  # Alpha Blending for SDF and Text
  var colorBlendAttachment = VkPipelineColorBlendAttachmentState(
    blendEnable: 1,
    srcColorBlendFactor: VK_BLEND_FACTOR_SRC_ALPHA,
    dstColorBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    colorBlendOp: VK_BLEND_OP_ADD,
    srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
    dstAlphaBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    alphaBlendOp: VK_BLEND_OP_ADD,
    colorWriteMask: 0xF
  )

  var colorBlending = VkPipelineColorBlendStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount: 1,
    pAttachments: addr colorBlendAttachment
  )

  var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
  var dynamicState = VkPipelineDynamicStateCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount: 2,
    pDynamicStates: addr dynamicStates[0]
  )

  var pipelineInfo = VkGraphicsPipelineCreateInfo(
    sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount: 2,
    pStages: addr shaderStages[0],
    pVertexInputState: addr vertexInputState,
    pInputAssemblyState: addr inputAssembly,
    pViewportState: addr viewportState,
    pRasterizationState: addr rasterizer,
    pMultisampleState: addr multisampling,
    pColorBlendState: addr colorBlending,
    pDynamicState: addr dynamicState,
    layout: backend.pipelineLayout,
    renderPass: backend.renderPass,
    subpass: 0
  )

  let pipeRes = backend.api.vkCreateGraphicsPipelines(backend.device, nil, 1, addr pipelineInfo, nil, addr backend.pipeline)

  # Destroy shader modules immediately after pipeline compilation
  backend.api.vkDestroyShaderModule(backend.device, vertModule, nil)
  backend.api.vkDestroyShaderModule(backend.device, fragModule, nil)

  pipeRes == VK_SUCCESS

# =============================================================================
# Initialization & Setup
# =============================================================================

# Safe: initializes Vulkan instance, Win32 surface, device, swapchain, pipeline, and ring buffers.
proc initVulkanBackend*(
  hwnd: pointer,
  width, height: uint32,
  fontAtlas: FontAtlas,
  enableValidation: bool = defined(nimuiValidation),
  dpiScale: float32 = 1.0f
): Result[VulkanBackend, string] {.trustedUnsafe, raises: [].} =
  var b: VulkanBackend
  b.hwnd = hwnd
  b.dpiScale = if dpiScale > 0.1f: dpiScale else: 1.0f
  b.validationEnabled = enableValidation
  b.api = loadVulkanApi()
  if b.api.lib.isNil:
    return err[VulkanBackend, string]("Could not load Vulkan driver (vulkan-1.dll / libvulkan.so)")

  # 1. VkInstance Creation
  var appInfo = VkApplicationInfo(
    sType: VK_STRUCTURE_TYPE_APPLICATION_INFO,
    pApplicationName: "NimUI",
    applicationVersion: 1,
    pEngineName: "NimUI Engine",
    engineVersion: 1,
    apiVersion: (1'u32 shl 22) or (1'u32 shl 12) # Vulkan 1.1
  )

  when defined(windows):
    var extNames = [cstring"VK_KHR_surface", cstring"VK_KHR_win32_surface"]
  else:
    var extNames = [cstring"VK_KHR_surface", cstring"VK_KHR_xlib_surface"]

  var validationLayers = [cstring"VK_LAYER_KHRONOS_validation"]
  let useValidation = enableValidation and hasValidationLayer(b.api)
  b.validationActive = useValidation

  var instInfo = VkInstanceCreateInfo(
    sType: VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    pApplicationInfo: addr appInfo,
    enabledLayerCount: if useValidation: 1'u32 else: 0'u32,
    ppEnabledLayerNames: if useValidation: cast[cstringArray](addr validationLayers[0]) else: nil,
    enabledExtensionCount: uint32(extNames.len),
    ppEnabledExtensionNames: cast[cstringArray](addr extNames[0])
  )

  if b.api.vkCreateInstance(addr instInfo, nil, addr b.instance) != VK_SUCCESS:
    b.api.unload()
    return err[VulkanBackend, string]("vkCreateInstance failed")

  b.api.loadInstanceProcs(b.instance)

  # 2. Native Surface Creation
  when defined(windows):
    var surfInfo = VkWin32SurfaceCreateInfoKHR(
      sType: VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
      hwnd: hwnd
    )
    if b.api.vkCreateWin32SurfaceKHR(b.instance, addr surfInfo, nil, addr b.surface) != VK_SUCCESS:
      b.api.vkDestroyInstance(b.instance, nil)
      b.api.unload()
      return err[VulkanBackend, string]("vkCreateWin32SurfaceKHR failed")
  else:
    b.api.vkDestroyInstance(b.instance, nil)
    b.api.unload()
    return err[VulkanBackend, string]("Unsupported platform surface")

  # 3. Physical Device Selection
  var devCount: uint32 = 0
  if b.api.vkEnumeratePhysicalDevices(b.instance, addr devCount, nil) != VK_SUCCESS or devCount == 0:
    b.api.vkDestroySurfaceKHR(b.instance, b.surface, nil)
    b.api.vkDestroyInstance(b.instance, nil)
    b.api.unload()
    return err[VulkanBackend, string]("No Vulkan physical devices found")

  var physicalDevices = newSeq[VkPhysicalDevice](devCount)
  if b.api.vkEnumeratePhysicalDevices(b.instance, addr devCount, addr physicalDevices[0]) != VK_SUCCESS:
    b.api.vkDestroySurfaceKHR(b.instance, b.surface, nil)
    b.api.vkDestroyInstance(b.instance, nil)
    b.api.unload()
    return err[VulkanBackend, string]("vkEnumeratePhysicalDevices failed")

  var bestDevice: VkPhysicalDevice = nil
  var bestScore = -1
  var bestGfxQueue = 0'u32
  var bestPresentQueue = 0'u32

  for dev in physicalDevices:
    var props: VkPhysicalDeviceProperties
    b.api.vkGetPhysicalDeviceProperties(dev, addr props)

    var qCount: uint32 = 0
    b.api.vkGetPhysicalDeviceQueueFamilyProperties(dev, addr qCount, nil)
    var qProps = newSeq[VkQueueFamilyProperties](qCount)
    b.api.vkGetPhysicalDeviceQueueFamilyProperties(dev, addr qCount, addr qProps[0])

    var gfxIdx = -1'i32
    var presentIdx = -1'i32

    for i in 0 ..< int(qCount):
      if (qProps[i].queueFlags and VK_QUEUE_GRAPHICS_BIT) != 0:
        gfxIdx = int32(i)
      var supported: uint32 = 0
      if b.api.vkGetPhysicalDeviceSurfaceSupportKHR(dev, uint32(i), b.surface, addr supported) == VK_SUCCESS and supported != 0:
        presentIdx = int32(i)
      if gfxIdx >= 0 and presentIdx >= 0:
        break

    if gfxIdx >= 0 and presentIdx >= 0:
      var score = 100
      if props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:
        score += 1000
      elif props.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU:
        score += 500
      if score > bestScore:
        bestScore = score
        bestDevice = dev
        bestGfxQueue = uint32(gfxIdx)
        bestPresentQueue = uint32(presentIdx)

  if bestDevice.isNil:
    b.api.vkDestroySurfaceKHR(b.instance, b.surface, nil)
    b.api.vkDestroyInstance(b.instance, nil)
    b.api.unload()
    return err[VulkanBackend, string]("No suitable Vulkan physical device with graphics & presentation support")

  b.physicalDevice = bestDevice
  b.graphicsQueueFamily = bestGfxQueue
  b.presentQueueFamily = bestPresentQueue

  # 4. Logical Device Creation
  var qPriorities = [1.0f]
  var queueCreateInfos: seq[VkDeviceQueueCreateInfo] = @[]

  queueCreateInfos.add(VkDeviceQueueCreateInfo(
    sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    queueFamilyIndex: bestGfxQueue,
    queueCount: 1,
    pQueuePriorities: addr qPriorities[0]
  ))
  if bestGfxQueue != bestPresentQueue:
    queueCreateInfos.add(VkDeviceQueueCreateInfo(
      sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      queueFamilyIndex: bestPresentQueue,
      queueCount: 1,
      pQueuePriorities: addr qPriorities[0]
    ))

  var devExtNames = [cstring"VK_KHR_swapchain"]
  var devCreateInfo = VkDeviceCreateInfo(
    sType: VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    queueCreateInfoCount: uint32(queueCreateInfos.len),
    pQueueCreateInfos: addr queueCreateInfos[0],
    enabledExtensionCount: uint32(devExtNames.len),
    ppEnabledExtensionNames: cast[cstringArray](addr devExtNames[0])
  )

  if b.api.vkCreateDevice(b.physicalDevice, addr devCreateInfo, nil, addr b.device) != VK_SUCCESS:
    b.api.vkDestroySurfaceKHR(b.instance, b.surface, nil)
    b.api.vkDestroyInstance(b.instance, nil)
    b.api.unload()
    return err[VulkanBackend, string]("vkCreateDevice failed")

  b.api.loadDeviceProcs(b.device)
  b.api.vkGetDeviceQueue(b.device, b.graphicsQueueFamily, 0, addr b.graphicsQueue)
  b.api.vkGetDeviceQueue(b.device, b.presentQueueFamily, 0, addr b.presentQueue)

  # 5. Command Pool & Buffers
  var poolInfo = VkCommandPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    flags: VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    queueFamilyIndex: b.graphicsQueueFamily
  )
  if b.api.vkCreateCommandPool(b.device, addr poolInfo, nil, addr b.commandPool) != VK_SUCCESS:
    b.destroy()
    return err[VulkanBackend, string]("vkCreateCommandPool failed")

  var cmdAllocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: b.commandPool,
    level: 0,
    commandBufferCount: MaxFramesInFlight
  )
  if b.api.vkAllocateCommandBuffers(b.device, addr cmdAllocInfo, addr b.commandBuffers[0]) != VK_SUCCESS:
    b.destroy()
    return err[VulkanBackend, string]("vkAllocateCommandBuffers failed")

  # 6. Static Unit Quad Vertex & Index Buffers
  let quadVtxBytes = VkDeviceSize(sizeof(quadVertices))
  if not createBuffer(b, quadVtxBytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      b.quadVertexBuffer, b.quadVertexMemory):
    b.destroy()
    return err[VulkanBackend, string]("Failed to allocate quad vertex buffer")

  var pVtx: pointer = nil
  if b.api.vkMapMemory(b.device, b.quadVertexMemory, 0, quadVtxBytes, 0, addr pVtx) != VK_SUCCESS or pVtx.isNil:
    b.destroy()
    return err[VulkanBackend, string]("Failed to map quad vertex buffer")
  copyMem(pVtx, unsafeAddr quadVertices[0], int(quadVtxBytes))
  b.api.vkUnmapMemory(b.device, b.quadVertexMemory)

  let quadIdxBytes = VkDeviceSize(sizeof(quadIndices))
  if not createBuffer(b, quadIdxBytes, VK_BUFFER_USAGE_INDEX_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      b.quadIndexBuffer, b.quadIndexMemory):
    b.destroy()
    return err[VulkanBackend, string]("Failed to allocate quad index buffer")

  var pIdx: pointer = nil
  if b.api.vkMapMemory(b.device, b.quadIndexMemory, 0, quadIdxBytes, 0, addr pIdx) != VK_SUCCESS or pIdx.isNil:
    b.destroy()
    return err[VulkanBackend, string]("Failed to map quad index buffer")
  copyMem(pIdx, unsafeAddr quadIndices[0], int(quadIdxBytes))
  b.api.vkUnmapMemory(b.device, b.quadIndexMemory)

  # 7. HostVisible + HostCoherent Ring Instance Buffers (Double Buffering)
  let instanceBufBytes = VkDeviceSize(MaxInstancesPerFrame * sizeof(UiDrawInstance))
  for i in 0 ..< MaxFramesInFlight:
    if not createBuffer(b, instanceBufBytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                        b.instanceBuffers[i], b.instanceMemories[i]):
      b.destroy()
      return err[VulkanBackend, string]("Failed to allocate ring instance buffer")

    var pMapped: pointer = nil
    if b.api.vkMapMemory(b.device, b.instanceMemories[i], 0, instanceBufBytes, 0, addr pMapped) != VK_SUCCESS:
      b.destroy()
      return err[VulkanBackend, string]("Failed to map ring instance buffer")
    b.mappedInstances[i] = cast[ptr UncheckedArray[UiDrawInstance]](pMapped)

  # 8. Configure Surface Format & Extent
  if not initSurfaceConfig(b, width, height):
    b.destroy()
    return err[VulkanBackend, string]("Failed to configure surface formats")

  # 9. Pipeline & Render Pass (Uses configured b.swapchainFormat)
  if not createPipeline(b, fontAtlas):
    b.destroy()
    return err[VulkanBackend, string]("Failed to create SDF graphics pipeline")

  # 10. Swapchain & Framebuffers
  if not createSwapchain(b, width, height):
    b.destroy()
    return err[VulkanBackend, string]("Failed to create swapchain")

  # 10. Sync Primitives (Semaphores & Fences)
  var semInfo = VkSemaphoreCreateInfo(sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)
  var fenceInfo = VkFenceCreateInfo(
    sType: VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    flags: VK_FENCE_CREATE_SIGNALED_BIT
  )

  for i in 0 ..< MaxFramesInFlight:
    if b.api.vkCreateSemaphore(b.device, addr semInfo, nil, addr b.imageAvailableSemaphores[i]) != VK_SUCCESS or
       b.api.vkCreateSemaphore(b.device, addr semInfo, nil, addr b.renderFinishedSemaphores[i]) != VK_SUCCESS or
       b.api.vkCreateFence(b.device, addr fenceInfo, nil, addr b.inFlightFences[i]) != VK_SUCCESS:
      b.destroy()
      return err[VulkanBackend, string]("Failed to create sync semaphores/fences")

  b.currentFrame = 0
  b.isInitialized = true
  ok[VulkanBackend, string](b)

# =============================================================================
# Rendering & Frame Submission
# =============================================================================

# Safe: stages and uploads FontAtlas pixel buffer to GPU VkImage via one-shot command buffer.
proc uploadFontAtlas*(backend: var VulkanBackend, atlas: FontAtlas): Result[void, string] {.trustedUnsafe, raises: [].} =
  ## Re-uploads FontAtlas pixel data (e.g., after dynamic LRU eviction or DPI rebuild) to the GPU texture.
  if not backend.isInitialized or backend.device.isNil:
    return err[void, string]("Backend not initialized")
  if backend.deviceLost:
    return err[void, string]("VK_ERROR_DEVICE_LOST: cannot upload font atlas")
  if atlas.width <= 0 or atlas.height <= 0 or atlas.pixels.len < atlas.width * atlas.height:
    return err[void, string]("Invalid FontAtlas dimensions or pixel buffer")
  if atlas.width != backend.fontTexWidth or atlas.height != backend.fontTexHeight:
    return err[void, string]("FontAtlas dimensions changed; full pipeline/image recreate required")

  let idleRes = backend.api.vkDeviceWaitIdle(backend.device)
  let idleChk = backend.checkVk(idleRes, "vkDeviceWaitIdle(uploadFontAtlas)")
  if idleChk.isErr:
    return idleChk

  let imageBytes = VkDeviceSize(atlas.width * atlas.height)
  var stagingBuf: VkBuffer
  var stagingMem: VkDeviceMemory
  if not createBuffer(backend, imageBytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      stagingBuf, stagingMem):
    return err[void, string]("Failed to allocate staging buffer for font atlas upload")

  var pData: pointer = nil
  let mapRes = backend.checkVk(backend.api.vkMapMemory(backend.device, stagingMem, 0, imageBytes, 0, addr pData), "vkMapMemory(uploadFontAtlas)")
  if mapRes.isErr:
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return mapRes
  if not pData.isNil:
    copyMem(pData, unsafeAddr atlas.pixels[0], int(imageBytes))
  backend.api.vkUnmapMemory(backend.device, stagingMem)

  var allocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: backend.commandPool,
    level: 0,
    commandBufferCount: 1
  )
  var oneShotCmd: VkCommandBuffer
  let allocRes = backend.checkVk(backend.api.vkAllocateCommandBuffers(backend.device, addr allocInfo, addr oneShotCmd), "vkAllocateCommandBuffers(uploadFontAtlas)")
  if allocRes.isErr:
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return allocRes

  var beginInfo = VkCommandBufferBeginInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    flags: 0x00000001
  )
  let beginRes = backend.checkVk(backend.api.vkBeginCommandBuffer(oneShotCmd, addr beginInfo), "vkBeginCommandBuffer(uploadFontAtlas)")
  if beginRes.isErr:
    backend.api.vkFreeCommandBuffers(backend.device, backend.commandPool, 1, addr oneShotCmd)
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return beginRes

  var barrier = VkImageMemoryBarrier(
    sType: 45,
    oldLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    newLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    srcQueueFamilyIndex: 0xFFFFFFFF'u32,
    dstQueueFamilyIndex: 0xFFFFFFFF'u32,
    image: backend.fontImage,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1
    ),
    srcAccessMask: VK_ACCESS_SHADER_READ_BIT,
    dstAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT
  )
  backend.api.vkCmdPipelineBarrier(
    oneShotCmd,
    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    VK_PIPELINE_STAGE_TRANSFER_BIT,
    0, 0, nil, 0, nil, 1, addr barrier
  )

  var copyRegion = VkBufferImageCopy(
    bufferOffset: 0,
    bufferRowLength: 0,
    bufferImageHeight: 0,
    imageSubresource: VkImageSubresourceLayers(
      aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
      mipLevel: 0,
      baseArrayLayer: 0,
      layerCount: 1
    ),
    imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
    imageExtent: VkExtent3D(width: uint32(atlas.width), height: uint32(atlas.height), depth: 1)
  )
  backend.api.vkCmdCopyBufferToImage(
    oneShotCmd, stagingBuf, backend.fontImage,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, addr copyRegion
  )

  barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
  barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT
  barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT
  backend.api.vkCmdPipelineBarrier(
    oneShotCmd,
    VK_PIPELINE_STAGE_TRANSFER_BIT,
    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    0, 0, nil, 0, nil, 1, addr barrier
  )

  let endRes = backend.checkVk(backend.api.vkEndCommandBuffer(oneShotCmd), "vkEndCommandBuffer(uploadFontAtlas)")
  if endRes.isErr:
    backend.api.vkFreeCommandBuffers(backend.device, backend.commandPool, 1, addr oneShotCmd)
    backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
    backend.api.vkFreeMemory(backend.device, stagingMem, nil)
    return endRes

  var submitInfo = VkSubmitInfo(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,
    commandBufferCount: 1,
    pCommandBuffers: addr oneShotCmd
  )
  let subRes = backend.checkVk(backend.api.vkQueueSubmit(backend.graphicsQueue, 1, addr submitInfo, 0), "vkQueueSubmit(uploadFontAtlas)")
  let waitRes = backend.checkVk(backend.api.vkQueueWaitIdle(backend.graphicsQueue), "vkQueueWaitIdle(uploadFontAtlas)")
  backend.api.vkFreeCommandBuffers(backend.device, backend.commandPool, 1, addr oneShotCmd)
  backend.api.vkDestroyBuffer(backend.device, stagingBuf, nil)
  backend.api.vkFreeMemory(backend.device, stagingMem, nil)
  if subRes.isErr: return subRes
  waitRes

# Safe: destroys lost Vulkan device and re-initializes via initVulkanBackend with valid HWND.
proc recoverFromDeviceLost*(
  backend: var VulkanBackend,
  hwnd: pointer,
  width, height: uint32,
  fontAtlas: FontAtlas
): Result[void, string] {.trustedUnsafe, raises: [].} =
  ## Tears down a lost Vulkan device cleanly and attempts full backend re-initialization.
  let useVal = backend.validationEnabled
  let dpi = backend.dpiScale
  backend.destroy()
  let reinit = initVulkanBackend(hwnd, max(1'u32, width), max(1'u32, height), fontAtlas, useVal, dpi)
  if reinit.isErr:
    return err[void, string](reinit.error)
  backend = reinit.val
  ok[void, string]()

# Safe: waits on frame fence and acquires next Vulkan swapchain image.
proc beginFrame*(backend: var VulkanBackend, width, height: uint32): Result[uint32, string] {.trustedUnsafe, raises: [].} =
  if not backend.isInitialized:
    return err[uint32, string]("Backend not initialized")
  if backend.deviceLost:
    return err[uint32, string]("VK_ERROR_DEVICE_LOST: Vulkan device is lost")
  if width == 0 or height == 0:
    backend.isMinimized = true
    return err[uint32, string]("Window minimized (0x0 extent); skipping frame")
  backend.isMinimized = false

  let fence = backend.inFlightFences[backend.currentFrame]
  let waitRes = backend.api.vkWaitForFences(backend.device, 1, unsafeAddr fence, 1, 1_000_000_000'u64) # 1 sec timeout
  if waitRes != VK_SUCCESS:
    let chk = backend.checkVk(waitRes, "vkWaitForFences")
    return err[uint32, string](chk.error)

  var imageIndex: uint32 = 0
  let acqRes = backend.api.vkAcquireNextImageKHR(
    backend.device,
    backend.swapchain,
    1_000_000_000'u64,
    backend.imageAvailableSemaphores[backend.currentFrame],
    0,
    addr imageIndex
  )

  if acqRes == VK_ERROR_DEVICE_LOST:
    backend.recordVkError(acqRes, "vkAcquireNextImageKHR")
    return err[uint32, string]("VK_ERROR_DEVICE_LOST during vkAcquireNextImageKHR")

  if acqRes == VK_ERROR_SURFACE_LOST_KHR:
    backend.recordVkError(acqRes, "vkAcquireNextImageKHR")
    return err[uint32, string]("VK_ERROR_SURFACE_LOST_KHR during vkAcquireNextImageKHR")

  if acqRes == VK_ERROR_OUT_OF_DATE_KHR or acqRes == VK_SUBOPTIMAL_KHR or backend.needsResize:
    if not recreateSwapchain(backend, width, height):
      if backend.deviceLost:
        return err[uint32, string]("VK_ERROR_DEVICE_LOST during swapchain recreation")
      if backend.isMinimized:
        return err[uint32, string]("Window minimized (0x0 swapchain extent); skipping frame")
      return err[uint32, string]("Swapchain recreation failed on acquire")
    return err[uint32, string]("Swapchain out of date, recreated")

  if acqRes != VK_SUCCESS:
    backend.recordVkError(acqRes, "vkAcquireNextImageKHR")
    return err[uint32, string]("vkAcquireNextImageKHR failed with code: " & $acqRes)

  let resetRes = backend.api.vkResetFences(backend.device, 1, unsafeAddr fence)
  if resetRes != VK_SUCCESS:
    let chk = backend.checkVk(resetRes, "vkResetFences")
    return err[uint32, string](chk.error)
  ok[uint32, string](imageIndex)

# Safe: copies bounded drawCount instances into mapped ring buffer and records/presents Vulkan frame.
proc renderInstancesResult*(
  backend: var VulkanBackend,
  imageIndex: uint32,
  instances: ptr UiDrawInstance,
  count: int,
  clearColor: uint32 = 0x121214FF
): Result[void, string] {.trustedUnsafe, raises: [].} =
  if not backend.isInitialized:
    return err[void, string]("Backend not initialized")
  if backend.deviceLost:
    return err[void, string]("VK_ERROR_DEVICE_LOST: Vulkan device is lost")
  if backend.isMinimized or backend.swapchainExtent.width == 0 or backend.swapchainExtent.height == 0:
    return ok[void, string]()
  if count <= 0 or instances.isNil:
    return ok[void, string]()

  let frameIdx = backend.currentFrame
  let drawCount = min(count, MaxInstancesPerFrame)

  # Copy instances into ring instance buffer in 1 copyMem
  copyMem(backend.mappedInstances[frameIdx], instances, drawCount * sizeof(UiDrawInstance))

  let cmdBuf = backend.commandBuffers[frameIdx]
  let rstCmdRes = backend.checkVk(backend.api.vkResetCommandBuffer(cmdBuf, 0), "vkResetCommandBuffer")
  if rstCmdRes.isErr:
    return rstCmdRes

  var beginInfo = VkCommandBufferBeginInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    flags: 0x00000001 # ONE_TIME_SUBMIT
  )
  let begCmdRes = backend.checkVk(backend.api.vkBeginCommandBuffer(cmdBuf, addr beginInfo), "vkBeginCommandBuffer")
  if begCmdRes.isErr:
    return begCmdRes

  # Unpack clear color (0xRRGGBBAA)
  let cr = float32((clearColor shr 24) and 0xFF'u32) / 255.0f
  let cg = float32((clearColor shr 16) and 0xFF'u32) / 255.0f
  let cb = float32((clearColor shr 8) and 0xFF'u32) / 255.0f
  let ca = float32(clearColor and 0xFF'u32) / 255.0f

  var clearValue: VkClearValue
  clearValue.color.float32Values = [cr, cg, cb, ca]

  var renderPassBegin = VkRenderPassBeginInfo(
    sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    renderPass: backend.renderPass,
    framebuffer: backend.framebuffers[imageIndex],
    renderArea: VkRect2D(
      offset: VkOffset2D(x: 0, y: 0),
      extent: backend.swapchainExtent
    ),
    clearValueCount: 1,
    pClearValues: addr clearValue
  )

  backend.api.vkCmdBeginRenderPass(cmdBuf, addr renderPassBegin, VK_SUBPASS_CONTENTS_INLINE)
  backend.api.vkCmdBindPipeline(cmdBuf, VK_PIPELINE_BIND_POINT_GRAPHICS, backend.pipeline)

  # Set Dynamic Viewport & Scissor
  var viewport = VkViewport(
    x: 0.0f, y: 0.0f,
    width: float32(backend.swapchainExtent.width),
    height: float32(backend.swapchainExtent.height),
    minDepth: 0.0f, maxDepth: 1.0f
  )
  backend.api.vkCmdSetViewport(cmdBuf, 0, 1, addr viewport)

  var scissor = VkRect2D(
    offset: VkOffset2D(x: 0, y: 0),
    extent: backend.swapchainExtent
  )
  backend.api.vkCmdSetScissor(cmdBuf, 0, 1, addr scissor)

  # Push constants: Screen Resolution
  var push = PushConstants(
    resolution: [float32(backend.swapchainExtent.width), float32(backend.swapchainExtent.height)]
  )
  backend.api.vkCmdPushConstants(
    cmdBuf, backend.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, uint32(sizeof(PushConstants)), addr push
  )

  # Bind Font Atlas Descriptor Set
  backend.api.vkCmdBindDescriptorSets(
    cmdBuf, VK_PIPELINE_BIND_POINT_GRAPHICS, backend.pipelineLayout, 0, 1, addr backend.descriptorSet, 0, nil
  )

  # Bind Unit Quad Vertex Buffer (Binding 0) & Instance Buffer (Binding 1)
  var buffers = [backend.quadVertexBuffer, backend.instanceBuffers[frameIdx]]
  var offsets: array[2, VkDeviceSize] = [0'u64, 0'u64]
  backend.api.vkCmdBindVertexBuffers(cmdBuf, 0, 2, addr buffers[0], addr offsets[0])

  # Bind Quad Index Buffer
  backend.api.vkCmdBindIndexBuffer(cmdBuf, backend.quadIndexBuffer, 0, VK_INDEX_TYPE_UINT16)

  # 1 single Instanced Draw call!
  backend.api.vkCmdDrawIndexed(
    cmdBuf,
    indexCount = 6,
    instanceCount = uint32(drawCount),
    firstIndex = 0,
    vertexOffset = 0,
    firstInstance = 0
  )

  backend.api.vkCmdEndRenderPass(cmdBuf)
  let endCmdRes = backend.checkVk(backend.api.vkEndCommandBuffer(cmdBuf), "vkEndCommandBuffer")
  if endCmdRes.isErr:
    return endCmdRes

  # Submit Command Buffer
  var waitStages: array[1, VkFlags] = [VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT]
  var submitInfo = VkSubmitInfo(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,
    waitSemaphoreCount: 1,
    pWaitSemaphores: addr backend.imageAvailableSemaphores[frameIdx],
    pWaitDstStageMask: addr waitStages[0],
    commandBufferCount: 1,
    pCommandBuffers: addr backend.commandBuffers[frameIdx],
    signalSemaphoreCount: 1,
    pSignalSemaphores: addr backend.renderFinishedSemaphores[frameIdx]
  )

  let subRes = backend.checkVk(
    backend.api.vkQueueSubmit(backend.graphicsQueue, 1, addr submitInfo, backend.inFlightFences[frameIdx]),
    "vkQueueSubmit"
  )
  if subRes.isErr:
    return subRes

  # Present Swapchain Image
  var swapchains = [backend.swapchain]
  var imageIndices = [imageIndex]
  var presentInfo = VkPresentInfoKHR(
    sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
    waitSemaphoreCount: 1,
    pWaitSemaphores: addr backend.renderFinishedSemaphores[frameIdx],
    swapchainCount: 1,
    pSwapchains: addr swapchains[0],
    pImageIndices: addr imageIndices[0]
  )

  let presRes = backend.api.vkQueuePresentKHR(backend.presentQueue, addr presentInfo)
  if presRes == VK_ERROR_OUT_OF_DATE_KHR or presRes == VK_SUBOPTIMAL_KHR:
    backend.needsResize = true
  elif presRes == VK_ERROR_DEVICE_LOST:
    return backend.checkVk(presRes, "vkQueuePresentKHR")
  elif presRes != VK_SUCCESS:
    return backend.checkVk(presRes, "vkQueuePresentKHR")

  backend.currentFrame = (backend.currentFrame + 1) mod MaxFramesInFlight
  ok[void, string]()

# Safe: forwards instances pointer to renderInstancesResult (nil/count-guarded).
proc renderInstances*(
  backend: var VulkanBackend,
  imageIndex: uint32,
  instances: ptr UiDrawInstance,
  count: int,
  clearColor: uint32 = 0x121214FF
) {.trustedUnsafe, raises: [].} =
  let res = backend.renderInstancesResult(imageIndex, instances, count, clearColor)
  if res.isErr:
    backend.lastError = res.error

# =============================================================================
# Clean Shutdown & Resource Deallocation
# =============================================================================

proc destroy*(backend: var VulkanBackend) {.raises: [].} =
  if not backend.isInitialized and backend.device.isNil and backend.instance.isNil and backend.api.lib.isNil:
    return
  backend.isInitialized = false

  if not backend.device.isNil:
    if not backend.deviceLost:
      let idleRes = backend.api.vkDeviceWaitIdle(backend.device)
      if idleRes == VK_ERROR_DEVICE_LOST:
        backend.deviceLost = true

    # 1. Sync primitives
    for i in 0 ..< MaxFramesInFlight:
      if backend.inFlightFences[i] != 0:
        backend.api.vkDestroyFence(backend.device, backend.inFlightFences[i], nil)
        backend.inFlightFences[i] = 0
      if backend.imageAvailableSemaphores[i] != 0:
        backend.api.vkDestroySemaphore(backend.device, backend.imageAvailableSemaphores[i], nil)
        backend.imageAvailableSemaphores[i] = 0
      if backend.renderFinishedSemaphores[i] != 0:
        backend.api.vkDestroySemaphore(backend.device, backend.renderFinishedSemaphores[i], nil)
        backend.renderFinishedSemaphores[i] = 0

    # 2. Command pool & buffers
    if backend.commandPool != 0:
      backend.api.vkDestroyCommandPool(backend.device, backend.commandPool, nil)

    # 3. Pipeline & layout
    if backend.pipeline != 0:
      backend.api.vkDestroyPipeline(backend.device, backend.pipeline, nil)
    if backend.pipelineLayout != 0:
      backend.api.vkDestroyPipelineLayout(backend.device, backend.pipelineLayout, nil)

    # 4. Descriptor pool & layout
    if backend.descriptorPool != 0:
      backend.api.vkDestroyDescriptorPool(backend.device, backend.descriptorPool, nil)
    if backend.descriptorSetLayout != 0:
      backend.api.vkDestroyDescriptorSetLayout(backend.device, backend.descriptorSetLayout, nil)

    # 5. Font atlas image & sampler
    if backend.fontSampler != 0:
      backend.api.vkDestroySampler(backend.device, backend.fontSampler, nil)
    if backend.fontImageView != 0:
      backend.api.vkDestroyImageView(backend.device, backend.fontImageView, nil)
    if backend.fontImage != 0:
      backend.api.vkDestroyImage(backend.device, backend.fontImage, nil)
    if backend.fontImageMemory != 0:
      backend.api.vkFreeMemory(backend.device, backend.fontImageMemory, nil)

    # 6. Ring instance buffers & unmap
    for i in 0 ..< MaxFramesInFlight:
      if not backend.mappedInstances[i].isNil:
        backend.api.vkUnmapMemory(backend.device, backend.instanceMemories[i])
        backend.mappedInstances[i] = nil
      if backend.instanceBuffers[i] != 0:
        backend.api.vkDestroyBuffer(backend.device, backend.instanceBuffers[i], nil)
      if backend.instanceMemories[i] != 0:
        backend.api.vkFreeMemory(backend.device, backend.instanceMemories[i], nil)

    # 7. Quad mesh buffers
    if backend.quadVertexBuffer != 0:
      backend.api.vkDestroyBuffer(backend.device, backend.quadVertexBuffer, nil)
    if backend.quadVertexMemory != 0:
      backend.api.vkFreeMemory(backend.device, backend.quadVertexMemory, nil)
    if backend.quadIndexBuffer != 0:
      backend.api.vkDestroyBuffer(backend.device, backend.quadIndexBuffer, nil)
    if backend.quadIndexMemory != 0:
      backend.api.vkFreeMemory(backend.device, backend.quadIndexMemory, nil)

    # 8. Framebuffers & swapchain image views
    cleanupSwapchain(backend)

    # 9. Render pass
    if backend.renderPass != 0:
      backend.api.vkDestroyRenderPass(backend.device, backend.renderPass, nil)

    # 10. Logical device
    backend.api.vkDestroyDevice(backend.device, nil)
    backend.device = nil

  # 11. Surface & Instance
  if not backend.instance.isNil:
    if backend.surface != 0:
      backend.api.vkDestroySurfaceKHR(backend.instance, backend.surface, nil)
      backend.surface = 0
    backend.api.vkDestroyInstance(backend.instance, nil)
    backend.instance = nil

  # 12. Dynamic library
  backend.api.unload()
