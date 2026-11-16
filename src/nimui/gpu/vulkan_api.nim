## nimui/gpu/vulkan_api — Zero-Dependency Vulkan 1.1+ Dynamic API Bindings
##
## Strict invariants:
## - Pure dynamic linking (vulkan-1.dll on Windows / libvulkan.so.1 on Linux).
## - Clean Win32 and cross-platform surface integration.
## - Zero external dependencies.

import std/dynlib
import corex/result

type
  VkHandle* = pointer
  VkNonDispatchableHandle* = uint64

  VkInstance* = VkHandle
  VkPhysicalDevice* = VkHandle
  VkDevice* = VkHandle
  VkQueue* = VkHandle
  VkCommandBuffer* = VkHandle

  VkSemaphore* = VkNonDispatchableHandle
  VkFence* = VkNonDispatchableHandle
  VkDeviceMemory* = VkNonDispatchableHandle
  VkBuffer* = VkNonDispatchableHandle
  VkImage* = VkNonDispatchableHandle
  VkImageView* = VkNonDispatchableHandle
  VkShaderModule* = VkNonDispatchableHandle
  VkPipeline* = VkNonDispatchableHandle
  VkPipelineLayout* = VkNonDispatchableHandle
  VkSampler* = VkNonDispatchableHandle
  VkDescriptorSetLayout* = VkNonDispatchableHandle
  VkDescriptorPool* = VkNonDispatchableHandle
  VkDescriptorSet* = VkNonDispatchableHandle
  VkRenderPass* = VkNonDispatchableHandle
  VkFramebuffer* = VkNonDispatchableHandle
  VkCommandPool* = VkNonDispatchableHandle
  VkSurfaceKHR* = VkNonDispatchableHandle
  VkSwapchainKHR* = VkNonDispatchableHandle

  VkResult* = int32
  VkStructureType* = int32
  VkFlags* = uint32
  VkDeviceSize* = uint64
  VkSampleCountFlags* = uint32

const
  VK_SUCCESS*: VkResult = 0
  VK_NOT_READY*: VkResult = 1
  VK_TIMEOUT*: VkResult = 2
  VK_EVENT_SET*: VkResult = 3
  VK_EVENT_RESET*: VkResult = 4
  VK_INCOMPLETE*: VkResult = 5
  VK_ERROR_OUT_OF_HOST_MEMORY*: VkResult = -1
  VK_ERROR_OUT_OF_DEVICE_MEMORY*: VkResult = -2
  VK_ERROR_INITIALIZATION_FAILED*: VkResult = -3
  VK_ERROR_DEVICE_LOST*: VkResult = -4
  VK_ERROR_MEMORY_MAP_FAILED*: VkResult = -5
  VK_ERROR_LAYER_NOT_PRESENT*: VkResult = -6
  VK_ERROR_EXTENSION_NOT_PRESENT*: VkResult = -7
  VK_ERROR_FEATURE_NOT_PRESENT*: VkResult = -8
  VK_ERROR_INCOMPATIBLE_DRIVER*: VkResult = -9
  VK_ERROR_TOO_MANY_OBJECTS*: VkResult = -10
  VK_ERROR_FORMAT_NOT_SUPPORTED*: VkResult = -11
  VK_ERROR_FRAGMENTED_POOL*: VkResult = -12
  VK_ERROR_SURFACE_LOST_KHR*: VkResult = -1000000000
  VK_ERROR_NATIVE_WINDOW_IN_USE_KHR*: VkResult = -1000000001
  VK_SUBOPTIMAL_KHR*: VkResult = 1000001003
  VK_ERROR_OUT_OF_DATE_KHR*: VkResult = -1000001004

  VK_STRUCTURE_TYPE_APPLICATION_INFO*: VkStructureType = 0
  VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO*: VkStructureType = 1
  VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO*: VkStructureType = 2
  VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO*: VkStructureType = 3
  VK_STRUCTURE_TYPE_SUBMIT_INFO*: VkStructureType = 4
  VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO*: VkStructureType = 5
  VK_STRUCTURE_TYPE_FENCE_CREATE_INFO*: VkStructureType = 8
  VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO*: VkStructureType = 9
  VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO*: VkStructureType = 12
  VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO*: VkStructureType = 14
  VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO*: VkStructureType = 15
  VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO*: VkStructureType = 16
  VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO*: VkStructureType = 19
  VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO*: VkStructureType = 20
  VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO*: VkStructureType = 22
  VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO*: VkStructureType = 23
  VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO*: VkStructureType = 24
  VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO*: VkStructureType = 26
  VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO*: VkStructureType = 27
  VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO*: VkStructureType = 28
  VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO*: VkStructureType = 31
  VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO*: VkStructureType = 32
  VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO*: VkStructureType = 33
  VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO*: VkStructureType = 34
  VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET*: VkStructureType = 35
  VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO*: VkStructureType = 37
  VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO*: VkStructureType = 38
  VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO*: VkStructureType = 39
  VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO*: VkStructureType = 40
  VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO*: VkStructureType = 42
  VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO*: VkStructureType = 43
  VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO*: VkStructureType = 28
  VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR*: VkStructureType = 1000001000
  VK_STRUCTURE_TYPE_PRESENT_INFO_KHR*: VkStructureType = 1000001001
  VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR*: VkStructureType = 1000009000

  # Physical device types
  VK_PHYSICAL_DEVICE_TYPE_OTHER*: uint32 = 0
  VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU*: uint32 = 1
  VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU*: uint32 = 2
  VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU*: uint32 = 3
  VK_PHYSICAL_DEVICE_TYPE_CPU*: uint32 = 4

  # Queue flags
  VK_QUEUE_GRAPHICS_BIT*: uint32 = 0x00000001
  VK_QUEUE_COMPUTE_BIT*: uint32 = 0x00000002
  VK_QUEUE_TRANSFER_BIT*: uint32 = 0x00000004

  # Formats
  VK_FORMAT_UNDEFINED*: uint32 = 0
  VK_FORMAT_R8_UNORM*: uint32 = 9
  VK_FORMAT_R8G8B8A8_UNORM*: uint32 = 37
  VK_FORMAT_B8G8R8A8_UNORM*: uint32 = 44
  VK_FORMAT_B8G8R8A8_SRGB*: uint32 = 50
  VK_FORMAT_R32G32_SFLOAT*: uint32 = 103
  VK_FORMAT_R32G32B32A32_SFLOAT*: uint32 = 109
  VK_FORMAT_R32_UINT*: uint32 = 98
  VK_FORMAT_R32_SFLOAT*: uint32 = 100
  VK_FORMAT_R16G16B16A16_UINT*: uint32 = 75

  # Color spaces
  VK_COLOR_SPACE_SRGB_NONLINEAR_KHR*: uint32 = 0

  # Present modes
  VK_PRESENT_MODE_IMMEDIATE_KHR*: uint32 = 0
  VK_PRESENT_MODE_MAILBOX_KHR*: uint32 = 1
  VK_PRESENT_MODE_FIFO_KHR*: uint32 = 2
  VK_PRESENT_MODE_FIFO_RELAXED_KHR*: uint32 = 3

  # Buffer usage
  VK_BUFFER_USAGE_TRANSFER_SRC_BIT*: uint32 = 0x00000001
  VK_BUFFER_USAGE_TRANSFER_DST_BIT*: uint32 = 0x00000002
  VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT*: uint32 = 0x00000010
  VK_BUFFER_USAGE_STORAGE_BUFFER_BIT*: uint32 = 0x00000020
  VK_BUFFER_USAGE_INDEX_BUFFER_BIT*: uint32 = 0x00000040
  VK_BUFFER_USAGE_VERTEX_BUFFER_BIT*: uint32 = 0x00000080

  # Memory properties
  VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT*: uint32 = 0x00000001
  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT*: uint32 = 0x00000002
  VK_MEMORY_PROPERTY_HOST_COHERENT_BIT*: uint32 = 0x00000004
  VK_MEMORY_PROPERTY_HOST_CACHED_BIT*: uint32 = 0x00000008

  # Image usage
  VK_IMAGE_USAGE_TRANSFER_SRC_BIT*: uint32 = 0x00000001
  VK_IMAGE_USAGE_TRANSFER_DST_BIT*: uint32 = 0x00000002
  VK_IMAGE_USAGE_SAMPLED_BIT*: uint32 = 0x00000004
  VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT*: uint32 = 0x00000010

  # Image layouts
  VK_IMAGE_LAYOUT_UNDEFINED*: uint32 = 0
  VK_IMAGE_LAYOUT_GENERAL*: uint32 = 1
  VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL*: uint32 = 2
  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL*: uint32 = 6
  VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL*: uint32 = 7
  VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL*: uint32 = 5
  VK_IMAGE_LAYOUT_PRESENT_SRC_KHR*: uint32 = 1000001002

  # Pipeline stage flags
  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT*: uint32 = 0x00000001
  VK_PIPELINE_STAGE_VERTEX_INPUT_BIT*: uint32 = 0x00000004
  VK_PIPELINE_STAGE_VERTEX_SHADER_BIT*: uint32 = 0x00000008
  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT*: uint32 = 0x00000080
  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT*: uint32 = 0x00000400
  VK_PIPELINE_STAGE_TRANSFER_BIT*: uint32 = 0x00001000
  VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT*: uint32 = 0x00002000

  # Access flags
  VK_ACCESS_INDIRECT_COMMAND_READ_BIT*: uint32 = 0x00000001
  VK_ACCESS_INDEX_READ_BIT*: uint32 = 0x00000002
  VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT*: uint32 = 0x00000004
  VK_ACCESS_UNIFORM_READ_BIT*: uint32 = 0x00000008
  VK_ACCESS_SHADER_READ_BIT*: uint32 = 0x00000020
  VK_ACCESS_SHADER_WRITE_BIT*: uint32 = 0x00000040
  VK_ACCESS_COLOR_ATTACHMENT_READ_BIT*: uint32 = 0x00000080
  VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT*: uint32 = 0x00000100
  VK_ACCESS_TRANSFER_READ_BIT*: uint32 = 0x00000800
  VK_ACCESS_TRANSFER_WRITE_BIT*: uint32 = 0x00001000
  VK_ACCESS_HOST_READ_BIT*: uint32 = 0x00002000
  VK_ACCESS_HOST_WRITE_BIT*: uint32 = 0x00004000
  VK_ACCESS_MEMORY_READ_BIT*: uint32 = 0x00008000
  VK_ACCESS_MEMORY_WRITE_BIT*: uint32 = 0x00010000

  # Shader stage
  VK_SHADER_STAGE_VERTEX_BIT*: uint32 = 0x00000001
  VK_SHADER_STAGE_FRAGMENT_BIT*: uint32 = 0x00000010

  # Vertex input rate
  VK_VERTEX_INPUT_RATE_VERTEX*: uint32 = 0
  VK_VERTEX_INPUT_RATE_INSTANCE*: uint32 = 1

  # Primitive topology
  VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST*: uint32 = 3

  # Polygon mode
  VK_POLYGON_MODE_FILL*: uint32 = 0

  # Cull mode
  VK_CULL_MODE_NONE*: uint32 = 0

  # Front face
  VK_FRONT_FACE_CLOCKWISE*: uint32 = 0
  VK_FRONT_FACE_COUNTER_CLOCKWISE*: uint32 = 1

  # Blend ops & factors
  VK_BLEND_FACTOR_ZERO*: uint32 = 0
  VK_BLEND_FACTOR_ONE*: uint32 = 1
  VK_BLEND_FACTOR_SRC_COLOR*: uint32 = 2
  VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR*: uint32 = 3
  VK_BLEND_FACTOR_DST_COLOR*: uint32 = 4
  VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR*: uint32 = 5
  VK_BLEND_FACTOR_SRC_ALPHA*: uint32 = 6
  VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA*: uint32 = 7
  VK_BLEND_FACTOR_DST_ALPHA*: uint32 = 8
  VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA*: uint32 = 9
  VK_BLEND_OP_ADD*: uint32 = 0

  # Dynamic states
  VK_DYNAMIC_STATE_VIEWPORT*: uint32 = 0
  VK_DYNAMIC_STATE_SCISSOR*: uint32 = 1

  # Attachment load / store
  VK_ATTACHMENT_LOAD_OP_LOAD*: uint32 = 0
  VK_ATTACHMENT_LOAD_OP_CLEAR*: uint32 = 1
  VK_ATTACHMENT_LOAD_OP_DONT_CARE*: uint32 = 2
  VK_ATTACHMENT_STORE_OP_STORE*: uint32 = 0
  VK_ATTACHMENT_STORE_OP_DONT_CARE*: uint32 = 1

  # Sampler filter
  VK_FILTER_NEAREST*: uint32 = 0
  VK_FILTER_LINEAR*: uint32 = 1

  # Sampler address mode
  VK_SAMPLER_ADDRESS_MODE_REPEAT*: uint32 = 0
  VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE*: uint32 = 2

  # Descriptor type
  VK_DESCRIPTOR_TYPE_SAMPLER*: uint32 = 0
  VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER*: uint32 = 1

  # Fence create flags
  VK_FENCE_CREATE_SIGNALED_BIT*: uint32 = 0x00000001

  # Command pool flags
  VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT*: uint32 = 0x00000002

  # Subpass contents
  VK_SUBPASS_CONTENTS_INLINE*: uint32 = 0

  # Index type
  VK_INDEX_TYPE_UINT16*: uint32 = 0
  VK_INDEX_TYPE_UINT32*: uint32 = 1

  # Sharing mode
  VK_SHARING_MODE_EXCLUSIVE*: uint32 = 0
  VK_SHARING_MODE_CONCURRENT*: uint32 = 1

  # Component swizzle
  VK_COMPONENT_SWIZZLE_IDENTITY*: uint32 = 0

  # Image view type
  VK_IMAGE_VIEW_TYPE_2D*: uint32 = 1

  # Aspect mask
  VK_IMAGE_ASPECT_COLOR_BIT*: uint32 = 0x00000001

  # Surface transform
  VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR*: uint32 = 0x00000001

  # Composite alpha
  VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR*: uint32 = 0x00000001

  # Pipeline bind point
  VK_PIPELINE_BIND_POINT_GRAPHICS*: uint32 = 0

type
  VkOffset2D* = object
    x*: int32
    y*: int32

  VkExtent2D* = object
    width*: uint32
    height*: uint32

  VkExtent3D* = object
    width*: uint32
    height*: uint32
    depth*: uint32

  VkRect2D* = object
    offset*: VkOffset2D
    extent*: VkExtent2D

  VkViewport* = object
    x*: float32
    y*: float32
    width*: float32
    height*: float32
    minDepth*: float32
    maxDepth*: float32

  VkClearColorValue* {.union.} = object
    float32Values*: array[4, float32]
    int32Values*: array[4, int32]
    uint32Values*: array[4, uint32]

  VkClearDepthStencilValue* = object
    depth*: float32
    stencil*: uint32

  VkClearValue* {.union.} = object
    color*: VkClearColorValue
    depthStencil*: VkClearDepthStencilValue

  VkApplicationInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    pApplicationName*: cstring
    applicationVersion*: uint32
    pEngineName*: cstring
    engineVersion*: uint32
    apiVersion*: uint32

  VkInstanceCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    pApplicationInfo*: ptr VkApplicationInfo
    enabledLayerCount*: uint32
    ppEnabledLayerNames*: cstringArray
    enabledExtensionCount*: uint32
    ppEnabledExtensionNames*: cstringArray

  VkLayerProperties* = object
    layerName*: array[256, char]
    specVersion*: uint32
    implementationVersion*: uint32
    description*: array[256, char]

  VkQueueFamilyProperties* = object
    queueFlags*: VkFlags
    queueCount*: uint32
    timestampValidBits*: uint32
    minImageTransferGranularity*: VkExtent3D

  VkPhysicalDeviceLimits* = object
    data*: array[504, uint8]

  VkPhysicalDeviceSparseProperties* = object
    data*: array[20, uint8]

  VkPhysicalDeviceProperties* = object
    apiVersion*: uint32
    driverVersion*: uint32
    vendorID*: uint32
    deviceID*: uint32
    deviceType*: uint32
    deviceName*: array[256, char]
    pipelineCacheUUID*: array[16, uint8]
    limits*: VkPhysicalDeviceLimits
    sparseProperties*: VkPhysicalDeviceSparseProperties

  VkPhysicalDeviceFeatures* = object
    robustBufferAccess*: uint32
    fullDrawIndexUint32*: uint32
    imageCubeArray*: uint32
    independentBlend*: uint32
    geometryShader*: uint32
    tessellationShader*: uint32
    sampleRateShading*: uint32
    dualSrcBlend*: uint32
    logicOp*: uint32
    multiDrawIndirect*: uint32
    drawIndirectFirstInstance*: uint32
    depthClamp*: uint32
    depthBiasClamp*: uint32
    fillModeNonSolid*: uint32
    depthBounds*: uint32
    wideLines*: uint32
    largePoints*: uint32
    alphaToOne*: uint32
    multiViewport*: uint32
    samplerAnisotropy*: uint32
    textureCompressionETC2*: uint32
    textureCompressionASTC_LDR*: uint32
    textureCompressionBC*: uint32
    occlusionQueryPrecise*: uint32
    pipelineStatisticsQuery*: uint32
    vertexPipelineStoresAndAtomics*: uint32
    fragmentStoresAndAtomics*: uint32
    shaderTessellationAndGeometryPointSize*: uint32
    shaderImageGatherExtended*: uint32
    shaderStorageImageExtendedFormats*: uint32
    shaderStorageImageMultisample*: uint32
    shaderStorageImageReadWithoutFormat*: uint32
    shaderStorageImageWriteWithoutFormat*: uint32
    shaderUniformBufferArrayDynamicIndexing*: uint32
    shaderSampledImageArrayDynamicIndexing*: uint32
    shaderStorageBufferArrayDynamicIndexing*: uint32
    shaderStorageImageArrayDynamicIndexing*: uint32
    shaderClipDistance*: uint32
    shaderCullDistance*: uint32
    shaderFloat64*: uint32
    shaderInt64*: uint32
    shaderInt16*: uint32
    shaderResourceResidency*: uint32
    shaderResourceMinLod*: uint32
    sparseBinding*: uint32
    sparseResidencyBuffer*: uint32
    sparseResidencyImage2D*: uint32
    sparseResidencyImage3D*: uint32
    sparseResidency2Samples*: uint32
    sparseResidency4Samples*: uint32
    sparseResidency8Samples*: uint32
    sparseResidency16Samples*: uint32
    sparseResidencyAliased*: uint32
    variableMultisampleRate*: uint32
    inheritedQueries*: uint32

  VkMemoryType* = object
    propertyFlags*: VkFlags
    heapIndex*: uint32

  VkMemoryHeap* = object
    size*: VkDeviceSize
    flags*: VkFlags

  VkPhysicalDeviceMemoryProperties* = object
    memoryTypeCount*: uint32
    memoryTypes*: array[32, VkMemoryType]
    memoryHeapCount*: uint32
    memoryHeaps*: array[16, VkMemoryHeap]

  VkDeviceQueueCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    queueFamilyIndex*: uint32
    queueCount*: uint32
    pQueuePriorities*: ptr float32

  VkDeviceCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    queueCreateInfoCount*: uint32
    pQueueCreateInfos*: ptr VkDeviceQueueCreateInfo
    enabledLayerCount*: uint32
    ppEnabledLayerNames*: cstringArray
    enabledExtensionCount*: uint32
    ppEnabledExtensionNames*: cstringArray
    pEnabledFeatures*: ptr VkPhysicalDeviceFeatures

  VkWin32SurfaceCreateInfoKHR* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    hinstance*: pointer
    hwnd*: pointer

  VkSurfaceCapabilitiesKHR* = object
    minImageCount*: uint32
    maxImageCount*: uint32
    currentExtent*: VkExtent2D
    minImageExtent*: VkExtent2D
    maxImageExtent*: VkExtent2D
    maxImageArrayLayers*: uint32
    supportedTransforms*: VkFlags
    currentTransform*: uint32
    supportedCompositeAlpha*: VkFlags
    supportedUsageFlags*: VkFlags

  VkSurfaceFormatKHR* = object
    format*: uint32
    colorSpace*: uint32

  VkSwapchainCreateInfoKHR* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    surface*: VkSurfaceKHR
    minImageCount*: uint32
    imageFormat*: uint32
    imageColorSpace*: uint32
    imageExtent*: VkExtent2D
    imageArrayLayers*: uint32
    imageUsage*: VkFlags
    imageSharingMode*: uint32
    queueFamilyIndexCount*: uint32
    pQueueFamilyIndices*: ptr uint32
    preTransform*: uint32
    compositeAlpha*: uint32
    presentMode*: uint32
    clipped*: uint32
    oldSwapchain*: VkSwapchainKHR

  VkComponentMapping* = object
    r*: uint32
    g*: uint32
    b*: uint32
    a*: uint32

  VkImageSubresourceRange* = object
    aspectMask*: VkFlags
    baseMipLevel*: uint32
    levelCount*: uint32
    baseArrayLayer*: uint32
    layerCount*: uint32

  VkImageViewCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    image*: VkImage
    viewType*: uint32
    format*: uint32
    components*: VkComponentMapping
    subresourceRange*: VkImageSubresourceRange

  VkShaderModuleCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    codeSize*: uint
    pCode*: ptr uint32

  VkAttachmentDescription* = object
    flags*: VkFlags
    format*: uint32
    samples*: uint32
    loadOp*: uint32
    storeOp*: uint32
    stencilLoadOp*: uint32
    stencilStoreOp*: uint32
    initialLayout*: uint32
    finalLayout*: uint32

  VkAttachmentReference* = object
    attachment*: uint32
    layout*: uint32

  VkSubpassDescription* = object
    flags*: VkFlags
    pipelineBindPoint*: uint32
    inputAttachmentCount*: uint32
    pInputAttachments*: ptr VkAttachmentReference
    colorAttachmentCount*: uint32
    pColorAttachments*: ptr VkAttachmentReference
    pResolveAttachments*: ptr VkAttachmentReference
    pDepthStencilAttachment*: ptr VkAttachmentReference
    preserveAttachmentCount*: uint32
    pPreserveAttachments*: ptr uint32

  VkSubpassDependency* = object
    srcSubpass*: uint32
    dstSubpass*: uint32
    srcStageMask*: VkFlags
    dstStageMask*: VkFlags
    srcAccessMask*: VkFlags
    dstAccessMask*: VkFlags
    dependencyFlags*: VkFlags

  VkRenderPassCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    attachmentCount*: uint32
    pAttachments*: ptr VkAttachmentDescription
    subpassCount*: uint32
    pSubpasses*: ptr VkSubpassDescription
    dependencyCount*: uint32
    pDependencies*: ptr VkSubpassDependency

  VkFramebufferCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    renderPass*: VkRenderPass
    attachmentCount*: uint32
    pAttachments*: ptr VkImageView
    width*: uint32
    height*: uint32
    layers*: uint32

  VkCommandPoolCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    queueFamilyIndex*: uint32

  VkCommandBufferAllocateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    commandPool*: VkCommandPool
    level*: uint32
    commandBufferCount*: uint32

  VkCommandBufferBeginInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    pInheritanceInfo*: pointer

  VkBufferCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    size*: VkDeviceSize
    usage*: VkFlags
    sharingMode*: uint32
    queueFamilyIndexCount*: uint32
    pQueueFamilyIndices*: ptr uint32

  VkMemoryRequirements* = object
    size*: VkDeviceSize
    alignment*: VkDeviceSize
    memoryTypeBits*: uint32

  VkMemoryAllocateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    allocationSize*: VkDeviceSize
    memoryTypeIndex*: uint32

  VkImageCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    imageType*: uint32
    format*: uint32
    extent*: VkExtent3D
    mipLevels*: uint32
    arrayLayers*: uint32
    samples*: uint32
    tiling*: uint32
    usage*: VkFlags
    sharingMode*: uint32
    queueFamilyIndexCount*: uint32
    pQueueFamilyIndices*: ptr uint32
    initialLayout*: uint32

  VkSamplerCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    magFilter*: uint32
    minFilter*: uint32
    mipmapMode*: uint32
    addressModeU*: uint32
    addressModeV*: uint32
    addressModeW*: uint32
    mipLodBias*: float32
    anisotropyEnable*: uint32
    maxAnisotropy*: float32
    compareEnable*: uint32
    compareOp*: uint32
    minLod*: float32
    maxLod*: float32
    borderColor*: uint32
    unnormalizedCoordinates*: uint32

  VkDescriptorSetLayoutBinding* = object
    binding*: uint32
    descriptorType*: uint32
    descriptorCount*: uint32
    stageFlags*: VkFlags
    pImmutableSamplers*: ptr VkSampler

  VkDescriptorSetLayoutCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    bindingCount*: uint32
    pBindings*: ptr VkDescriptorSetLayoutBinding

  VkDescriptorPoolSize* = object
    descriptorType*: uint32
    descriptorCount*: uint32

  VkDescriptorPoolCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    maxSets*: uint32
    poolSizeCount*: uint32
    pPoolSizes*: ptr VkDescriptorPoolSize

  VkDescriptorSetAllocateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    descriptorPool*: VkDescriptorPool
    descriptorSetCount*: uint32
    pSetLayouts*: ptr VkDescriptorSetLayout

  VkDescriptorImageInfo* = object
    sampler*: VkSampler
    imageView*: VkImageView
    imageLayout*: uint32

  VkWriteDescriptorSet* = object
    sType*: VkStructureType
    pNext*: pointer
    dstSet*: VkDescriptorSet
    dstBinding*: uint32
    dstArrayElement*: uint32
    descriptorCount*: uint32
    descriptorType*: uint32
    pImageInfo*: ptr VkDescriptorImageInfo
    pBufferInfo*: pointer
    pTexelBufferView*: pointer

  VkPushConstantRange* = object
    stageFlags*: VkFlags
    offset*: uint32
    size*: uint32

  VkPipelineLayoutCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    setLayoutCount*: uint32
    pSetLayouts*: ptr VkDescriptorSetLayout
    pushConstantRangeCount*: uint32
    pPushConstantRanges*: ptr VkPushConstantRange

  VkVertexInputBindingDescription* = object
    binding*: uint32
    stride*: uint32
    inputRate*: uint32

  VkVertexInputAttributeDescription* = object
    location*: uint32
    binding*: uint32
    format*: uint32
    offset*: uint32

  VkPipelineVertexInputStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    vertexBindingDescriptionCount*: uint32
    pVertexBindingDescriptions*: ptr VkVertexInputBindingDescription
    vertexAttributeDescriptionCount*: uint32
    pVertexAttributeDescriptions*: ptr VkVertexInputAttributeDescription

  VkPipelineInputAssemblyStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    topology*: uint32
    primitiveRestartEnable*: uint32

  VkPipelineViewportStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    viewportCount*: uint32
    pViewports*: ptr VkViewport
    scissorCount*: uint32
    pScissors*: ptr VkRect2D

  VkPipelineRasterizationStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    depthClampEnable*: uint32
    rasterizerDiscardEnable*: uint32
    polygonMode*: uint32
    cullMode*: uint32
    frontFace*: uint32
    depthBiasEnable*: uint32
    depthBiasConstantFactor*: float32
    depthBiasClamp*: float32
    depthBiasSlopeFactor*: float32
    lineWidth*: float32

  VkPipelineMultisampleStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    rasterizationSamples*: uint32
    sampleShadingEnable*: uint32
    minSampleShading*: float32
    pSampleMask*: ptr uint32
    alphaToCoverageEnable*: uint32
    alphaToOneEnable*: uint32

  VkPipelineColorBlendAttachmentState* = object
    blendEnable*: uint32
    srcColorBlendFactor*: uint32
    dstColorBlendFactor*: uint32
    colorBlendOp*: uint32
    srcAlphaBlendFactor*: uint32
    dstAlphaBlendFactor*: uint32
    alphaBlendOp*: uint32
    colorWriteMask*: VkFlags

  VkPipelineColorBlendStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    logicOpEnable*: uint32
    logicOp*: uint32
    attachmentCount*: uint32
    pAttachments*: ptr VkPipelineColorBlendAttachmentState
    blendConstants*: array[4, float32]

  VkPipelineDynamicStateCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    dynamicStateCount*: uint32
    pDynamicStates*: ptr uint32

  VkPipelineShaderStageCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    stage*: uint32
    module*: VkShaderModule
    pName*: cstring
    pSpecializationInfo*: pointer

  VkGraphicsPipelineCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags
    stageCount*: uint32
    pStages*: ptr VkPipelineShaderStageCreateInfo
    pVertexInputState*: ptr VkPipelineVertexInputStateCreateInfo
    pInputAssemblyState*: ptr VkPipelineInputAssemblyStateCreateInfo
    pTessellationState*: pointer
    pViewportState*: ptr VkPipelineViewportStateCreateInfo
    pRasterizationState*: ptr VkPipelineRasterizationStateCreateInfo
    pMultisampleState*: ptr VkPipelineMultisampleStateCreateInfo
    pDepthStencilState*: pointer
    pColorBlendState*: ptr VkPipelineColorBlendStateCreateInfo
    pDynamicState*: ptr VkPipelineDynamicStateCreateInfo
    layout*: VkPipelineLayout
    renderPass*: VkRenderPass
    subpass*: uint32
    basePipelineHandle*: VkPipeline
    basePipelineIndex*: int32

  VkSemaphoreCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags

  VkFenceCreateInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    flags*: VkFlags

  VkSubmitInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    waitSemaphoreCount*: uint32
    pWaitSemaphores*: ptr VkSemaphore
    pWaitDstStageMask*: ptr VkFlags
    commandBufferCount*: uint32
    pCommandBuffers*: ptr VkCommandBuffer
    signalSemaphoreCount*: uint32
    pSignalSemaphores*: ptr VkSemaphore

  VkPresentInfoKHR* = object
    sType*: VkStructureType
    pNext*: pointer
    waitSemaphoreCount*: uint32
    pWaitSemaphores*: ptr VkSemaphore
    swapchainCount*: uint32
    pSwapchains*: ptr VkSwapchainKHR
    pImageIndices*: ptr uint32
    pResults*: ptr VkResult

  VkRenderPassBeginInfo* = object
    sType*: VkStructureType
    pNext*: pointer
    renderPass*: VkRenderPass
    framebuffer*: VkFramebuffer
    renderArea*: VkRect2D
    clearValueCount*: uint32
    pClearValues*: ptr VkClearValue

  VkBufferImageCopy* = object
    bufferOffset*: VkDeviceSize
    bufferRowLength*: uint32
    bufferImageHeight*: uint32
    imageSubresource*: VkImageSubresourceLayers
    imageOffset*: VkOffset3D
    imageExtent*: VkExtent3D

  VkImageSubresourceLayers* = object
    aspectMask*: VkFlags
    mipLevel*: uint32
    baseArrayLayer*: uint32
    layerCount*: uint32

  VkOffset3D* = object
    x*: int32
    y*: int32
    z*: int32

  VkImageMemoryBarrier* = object
    sType*: VkStructureType
    pNext*: pointer
    srcAccessMask*: VkFlags
    dstAccessMask*: VkFlags
    oldLayout*: uint32
    newLayout*: uint32
    srcQueueFamilyIndex*: uint32
    dstQueueFamilyIndex*: uint32
    image*: VkImage
    subresourceRange*: VkImageSubresourceRange

# =============================================================================
# Vulkan Function Pointer Types
# =============================================================================

type
  PFN_vkGetInstanceProcAddr* = proc(instance: VkInstance, pName: cstring): pointer {.stdcall, raises: [].}
  PFN_vkGetDeviceProcAddr* = proc(device: VkDevice, pName: cstring): pointer {.stdcall, raises: [].}

  PFN_vkCreateInstance* = proc(pCreateInfo: ptr VkInstanceCreateInfo, pAllocator: pointer, pInstance: ptr VkInstance): VkResult {.stdcall, raises: [].}
  PFN_vkEnumerateInstanceLayerProperties* = proc(pPropertyCount: ptr uint32, pProperties: ptr VkLayerProperties): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyInstance* = proc(instance: VkInstance, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkEnumeratePhysicalDevices* = proc(instance: VkInstance, pPhysicalDeviceCount: ptr uint32, pPhysicalDevices: ptr VkPhysicalDevice): VkResult {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceProperties* = proc(physicalDevice: VkPhysicalDevice, pProperties: ptr VkPhysicalDeviceProperties) {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceFeatures* = proc(physicalDevice: VkPhysicalDevice, pFeatures: ptr VkPhysicalDeviceFeatures) {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceQueueFamilyProperties* = proc(physicalDevice: VkPhysicalDevice, pQueueFamilyPropertyCount: ptr uint32, pQueueFamilyProperties: ptr VkQueueFamilyProperties) {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceMemoryProperties* = proc(physicalDevice: VkPhysicalDevice, pMemoryProperties: ptr VkPhysicalDeviceMemoryProperties) {.stdcall, raises: [].}
  PFN_vkCreateDevice* = proc(physicalDevice: VkPhysicalDevice, pCreateInfo: ptr VkDeviceCreateInfo, pAllocator: pointer, pDevice: ptr VkDevice): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyDevice* = proc(device: VkDevice, pAllocator: pointer) {.stdcall, raises: [].}

  # Surface KHR
  PFN_vkDestroySurfaceKHR* = proc(instance: VkInstance, surface: VkSurfaceKHR, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceSurfaceSupportKHR* = proc(physicalDevice: VkPhysicalDevice, queueFamilyIndex: uint32, surface: VkSurfaceKHR, pSupported: ptr uint32): VkResult {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR* = proc(physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceCapabilities: ptr VkSurfaceCapabilitiesKHR): VkResult {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceSurfaceFormatsKHR* = proc(physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceFormatCount: ptr uint32, pSurfaceFormats: ptr VkSurfaceFormatKHR): VkResult {.stdcall, raises: [].}
  PFN_vkGetPhysicalDeviceSurfacePresentModesKHR* = proc(physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pPresentModeCount: ptr uint32, pPresentModes: ptr uint32): VkResult {.stdcall, raises: [].}
  PFN_vkCreateWin32SurfaceKHR* = proc(instance: VkInstance, pCreateInfo: ptr VkWin32SurfaceCreateInfoKHR, pAllocator: pointer, pSurface: ptr VkSurfaceKHR): VkResult {.stdcall, raises: [].}

  # Device queues
  PFN_vkGetDeviceQueue* = proc(device: VkDevice, queueFamilyIndex: uint32, queueIndex: uint32, pQueue: ptr VkQueue) {.stdcall, raises: [].}
  PFN_vkQueueSubmit* = proc(queue: VkQueue, submitCount: uint32, pSubmits: ptr VkSubmitInfo, fence: VkFence): VkResult {.stdcall, raises: [].}
  PFN_vkQueueWaitIdle* = proc(queue: VkQueue): VkResult {.stdcall, raises: [].}
  PFN_vkDeviceWaitIdle* = proc(device: VkDevice): VkResult {.stdcall, raises: [].}

  # Swapchain KHR
  PFN_vkCreateSwapchainKHR* = proc(device: VkDevice, pCreateInfo: ptr VkSwapchainCreateInfoKHR, pAllocator: pointer, pSwapchain: ptr VkSwapchainKHR): VkResult {.stdcall, raises: [].}
  PFN_vkDestroySwapchainKHR* = proc(device: VkDevice, swapchain: VkSwapchainKHR, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkGetSwapchainImagesKHR* = proc(device: VkDevice, swapchain: VkSwapchainKHR, pSwapchainImageCount: ptr uint32, pSwapchainImages: ptr VkImage): VkResult {.stdcall, raises: [].}
  PFN_vkAcquireNextImageKHR* = proc(device: VkDevice, swapchain: VkSwapchainKHR, timeout: uint64, semaphore: VkSemaphore, fence: VkFence, pImageIndex: ptr uint32): VkResult {.stdcall, raises: [].}
  PFN_vkQueuePresentKHR* = proc(queue: VkQueue, pPresentInfo: ptr VkPresentInfoKHR): VkResult {.stdcall, raises: [].}

  # Image view
  PFN_vkCreateImageView* = proc(device: VkDevice, pCreateInfo: ptr VkImageViewCreateInfo, pAllocator: pointer, pView: ptr VkImageView): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyImageView* = proc(device: VkDevice, imageView: VkImageView, pAllocator: pointer) {.stdcall, raises: [].}

  # Shaders & Render pass
  PFN_vkCreateShaderModule* = proc(device: VkDevice, pCreateInfo: ptr VkShaderModuleCreateInfo, pAllocator: pointer, pShaderModule: ptr VkShaderModule): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyShaderModule* = proc(device: VkDevice, shaderModule: VkShaderModule, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkCreateRenderPass* = proc(device: VkDevice, pCreateInfo: ptr VkRenderPassCreateInfo, pAllocator: pointer, pRenderPass: ptr VkRenderPass): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyRenderPass* = proc(device: VkDevice, renderPass: VkRenderPass, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkCreateFramebuffer* = proc(device: VkDevice, pCreateInfo: ptr VkFramebufferCreateInfo, pAllocator: pointer, pFramebuffer: ptr VkFramebuffer): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyFramebuffer* = proc(device: VkDevice, framebuffer: VkFramebuffer, pAllocator: pointer) {.stdcall, raises: [].}

  # Command pool & buffer
  PFN_vkCreateCommandPool* = proc(device: VkDevice, pCreateInfo: ptr VkCommandPoolCreateInfo, pAllocator: pointer, pCommandPool: ptr VkCommandPool): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyCommandPool* = proc(device: VkDevice, commandPool: VkCommandPool, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkAllocateCommandBuffers* = proc(device: VkDevice, pAllocateInfo: ptr VkCommandBufferAllocateInfo, pCommandBuffers: ptr VkCommandBuffer): VkResult {.stdcall, raises: [].}
  PFN_vkFreeCommandBuffers* = proc(device: VkDevice, commandPool: VkCommandPool, commandBufferCount: uint32, pCommandBuffers: ptr VkCommandBuffer) {.stdcall, raises: [].}
  PFN_vkBeginCommandBuffer* = proc(commandBuffer: VkCommandBuffer, pBeginInfo: ptr VkCommandBufferBeginInfo): VkResult {.stdcall, raises: [].}
  PFN_vkEndCommandBuffer* = proc(commandBuffer: VkCommandBuffer): VkResult {.stdcall, raises: [].}
  PFN_vkResetCommandBuffer* = proc(commandBuffer: VkCommandBuffer, flags: VkFlags): VkResult {.stdcall, raises: [].}

  # Buffers & Memory
  PFN_vkCreateBuffer* = proc(device: VkDevice, pCreateInfo: ptr VkBufferCreateInfo, pAllocator: pointer, pBuffer: ptr VkBuffer): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyBuffer* = proc(device: VkDevice, buffer: VkBuffer, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkGetBufferMemoryRequirements* = proc(device: VkDevice, buffer: VkBuffer, pMemoryRequirements: ptr VkMemoryRequirements) {.stdcall, raises: [].}
  PFN_vkAllocateMemory* = proc(device: VkDevice, pAllocateInfo: ptr VkMemoryAllocateInfo, pAllocator: pointer, pMemory: ptr VkDeviceMemory): VkResult {.stdcall, raises: [].}
  PFN_vkFreeMemory* = proc(device: VkDevice, memory: VkDeviceMemory, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkBindBufferMemory* = proc(device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, memoryOffset: VkDeviceSize): VkResult {.stdcall, raises: [].}
  PFN_vkMapMemory* = proc(device: VkDevice, memory: VkDeviceMemory, offset: VkDeviceSize, size: VkDeviceSize, flags: VkFlags, ppData: ptr pointer): VkResult {.stdcall, raises: [].}
  PFN_vkUnmapMemory* = proc(device: VkDevice, memory: VkDeviceMemory) {.stdcall, raises: [].}

  # Images & Samplers
  PFN_vkCreateImage* = proc(device: VkDevice, pCreateInfo: ptr VkImageCreateInfo, pAllocator: pointer, pImage: ptr VkImage): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyImage* = proc(device: VkDevice, image: VkImage, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkGetImageMemoryRequirements* = proc(device: VkDevice, image: VkImage, pMemoryRequirements: ptr VkMemoryRequirements) {.stdcall, raises: [].}
  PFN_vkBindImageMemory* = proc(device: VkDevice, image: VkImage, memory: VkDeviceMemory, memoryOffset: VkDeviceSize): VkResult {.stdcall, raises: [].}
  PFN_vkCreateSampler* = proc(device: VkDevice, pCreateInfo: ptr VkSamplerCreateInfo, pAllocator: pointer, pSampler: ptr VkSampler): VkResult {.stdcall, raises: [].}
  PFN_vkDestroySampler* = proc(device: VkDevice, sampler: VkSampler, pAllocator: pointer) {.stdcall, raises: [].}

  # Descriptors
  PFN_vkCreateDescriptorSetLayout* = proc(device: VkDevice, pCreateInfo: ptr VkDescriptorSetLayoutCreateInfo, pAllocator: pointer, pSetLayout: ptr VkDescriptorSetLayout): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyDescriptorSetLayout* = proc(device: VkDevice, descriptorSetLayout: VkDescriptorSetLayout, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkCreateDescriptorPool* = proc(device: VkDevice, pCreateInfo: ptr VkDescriptorPoolCreateInfo, pAllocator: pointer, pDescriptorPool: ptr VkDescriptorPool): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyDescriptorPool* = proc(device: VkDevice, descriptorPool: VkDescriptorPool, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkAllocateDescriptorSets* = proc(device: VkDevice, pAllocateInfo: ptr VkDescriptorSetAllocateInfo, pDescriptorSets: ptr VkDescriptorSet): VkResult {.stdcall, raises: [].}
  PFN_vkUpdateDescriptorSets* = proc(device: VkDevice, descriptorWriteCount: uint32, pDescriptorWrites: ptr VkWriteDescriptorSet, descriptorCopyCount: uint32, pDescriptorCopies: pointer) {.stdcall, raises: [].}

  # Pipelines
  PFN_vkCreatePipelineLayout* = proc(device: VkDevice, pCreateInfo: ptr VkPipelineLayoutCreateInfo, pAllocator: pointer, pPipelineLayout: ptr VkPipelineLayout): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyPipelineLayout* = proc(device: VkDevice, pipelineLayout: VkPipelineLayout, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkCreateGraphicsPipelines* = proc(device: VkDevice, pipelineCache: VkHandle, createInfoCount: uint32, pCreateInfos: ptr VkGraphicsPipelineCreateInfo, pAllocator: pointer, pPipelines: ptr VkPipeline): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyPipeline* = proc(device: VkDevice, pipeline: VkPipeline, pAllocator: pointer) {.stdcall, raises: [].}

  # Sync
  PFN_vkCreateSemaphore* = proc(device: VkDevice, pCreateInfo: ptr VkSemaphoreCreateInfo, pAllocator: pointer, pSemaphore: ptr VkSemaphore): VkResult {.stdcall, raises: [].}
  PFN_vkDestroySemaphore* = proc(device: VkDevice, semaphore: VkSemaphore, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkCreateFence* = proc(device: VkDevice, pCreateInfo: ptr VkFenceCreateInfo, pAllocator: pointer, pFence: ptr VkFence): VkResult {.stdcall, raises: [].}
  PFN_vkDestroyFence* = proc(device: VkDevice, fence: VkFence, pAllocator: pointer) {.stdcall, raises: [].}
  PFN_vkWaitForFences* = proc(device: VkDevice, fenceCount: uint32, pFences: ptr VkFence, waitAll: uint32, timeout: uint64): VkResult {.stdcall, raises: [].}
  PFN_vkResetFences* = proc(device: VkDevice, fenceCount: uint32, pFences: ptr VkFence): VkResult {.stdcall, raises: [].}

  # Commands
  PFN_vkCmdBeginRenderPass* = proc(commandBuffer: VkCommandBuffer, pRenderPassBegin: ptr VkRenderPassBeginInfo, contents: uint32) {.stdcall, raises: [].}
  PFN_vkCmdEndRenderPass* = proc(commandBuffer: VkCommandBuffer) {.stdcall, raises: [].}
  PFN_vkCmdBindPipeline* = proc(commandBuffer: VkCommandBuffer, pipelineBindPoint: uint32, pipeline: VkPipeline) {.stdcall, raises: [].}
  PFN_vkCmdBindVertexBuffers* = proc(commandBuffer: VkCommandBuffer, firstBinding: uint32, bindingCount: uint32, pBuffers: ptr VkBuffer, pOffsets: ptr VkDeviceSize) {.stdcall, raises: [].}
  PFN_vkCmdBindIndexBuffer* = proc(commandBuffer: VkCommandBuffer, buffer: VkBuffer, offset: VkDeviceSize, indexType: uint32) {.stdcall, raises: [].}
  PFN_vkCmdBindDescriptorSets* = proc(commandBuffer: VkCommandBuffer, pipelineBindPoint: uint32, layout: VkPipelineLayout, firstSet: uint32, descriptorSetCount: uint32, pDescriptorSets: ptr VkDescriptorSet, dynamicOffsetCount: uint32, pDynamicOffsets: ptr uint32) {.stdcall, raises: [].}
  PFN_vkCmdPushConstants* = proc(commandBuffer: VkCommandBuffer, layout: VkPipelineLayout, stageFlags: VkFlags, offset: uint32, size: uint32, pValues: pointer) {.stdcall, raises: [].}
  PFN_vkCmdSetViewport* = proc(commandBuffer: VkCommandBuffer, firstViewport: uint32, viewportCount: uint32, pViewports: ptr VkViewport) {.stdcall, raises: [].}
  PFN_vkCmdSetScissor* = proc(commandBuffer: VkCommandBuffer, firstScissor: uint32, scissorCount: uint32, pScissors: ptr VkRect2D) {.stdcall, raises: [].}
  PFN_vkCmdDraw* = proc(commandBuffer: VkCommandBuffer, vertexCount: uint32, instanceCount: uint32, firstVertex: uint32, firstInstance: uint32) {.stdcall, raises: [].}
  PFN_vkCmdDrawIndexed* = proc(commandBuffer: VkCommandBuffer, indexCount: uint32, instanceCount: uint32, firstIndex: uint32, vertexOffset: int32, firstInstance: uint32) {.stdcall, raises: [].}
  PFN_vkCmdCopyBufferToImage* = proc(commandBuffer: VkCommandBuffer, srcBuffer: VkBuffer, dstImage: VkImage, dstImageLayout: uint32, regionCount: uint32, pRegions: ptr VkBufferImageCopy) {.stdcall, raises: [].}
  PFN_vkCmdPipelineBarrier* = proc(commandBuffer: VkCommandBuffer, srcStageMask: VkFlags, dstStageMask: VkFlags, dependencyFlags: VkFlags, memoryBarrierCount: uint32, pMemoryBarriers: pointer, bufferMemoryBarrierCount: uint32, pBufferMemoryBarriers: pointer, imageMemoryBarrierCount: uint32, pImageMemoryBarriers: ptr VkImageMemoryBarrier) {.stdcall, raises: [].}

# =============================================================================
# Loaded Function Pointers Table
# =============================================================================

type
  VulkanApi* = object
    lib*: LibHandle

    # Core Loader
    vkGetInstanceProcAddr*: PFN_vkGetInstanceProcAddr
    vkGetDeviceProcAddr*: PFN_vkGetDeviceProcAddr

    # Instance
    vkCreateInstance*: PFN_vkCreateInstance
    vkEnumerateInstanceLayerProperties*: PFN_vkEnumerateInstanceLayerProperties
    vkDestroyInstance*: PFN_vkDestroyInstance
    vkEnumeratePhysicalDevices*: PFN_vkEnumeratePhysicalDevices
    vkGetPhysicalDeviceProperties*: PFN_vkGetPhysicalDeviceProperties
    vkGetPhysicalDeviceFeatures*: PFN_vkGetPhysicalDeviceFeatures
    vkGetPhysicalDeviceQueueFamilyProperties*: PFN_vkGetPhysicalDeviceQueueFamilyProperties
    vkGetPhysicalDeviceMemoryProperties*: PFN_vkGetPhysicalDeviceMemoryProperties
    vkCreateDevice*: PFN_vkCreateDevice
    vkDestroyDevice*: PFN_vkDestroyDevice

    # Surface KHR
    vkDestroySurfaceKHR*: PFN_vkDestroySurfaceKHR
    vkGetPhysicalDeviceSurfaceSupportKHR*: PFN_vkGetPhysicalDeviceSurfaceSupportKHR
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR*: PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR
    vkGetPhysicalDeviceSurfaceFormatsKHR*: PFN_vkGetPhysicalDeviceSurfaceFormatsKHR
    vkGetPhysicalDeviceSurfacePresentModesKHR*: PFN_vkGetPhysicalDeviceSurfacePresentModesKHR
    vkCreateWin32SurfaceKHR*: PFN_vkCreateWin32SurfaceKHR

    # Device Queues
    vkGetDeviceQueue*: PFN_vkGetDeviceQueue
    vkQueueSubmit*: PFN_vkQueueSubmit
    vkQueueWaitIdle*: PFN_vkQueueWaitIdle
    vkDeviceWaitIdle*: PFN_vkDeviceWaitIdle

    # Swapchain KHR
    vkCreateSwapchainKHR*: PFN_vkCreateSwapchainKHR
    vkDestroySwapchainKHR*: PFN_vkDestroySwapchainKHR
    vkGetSwapchainImagesKHR*: PFN_vkGetSwapchainImagesKHR
    vkAcquireNextImageKHR*: PFN_vkAcquireNextImageKHR
    vkQueuePresentKHR*: PFN_vkQueuePresentKHR

    # Images, Shaders, Pipelines
    vkCreateImageView*: PFN_vkCreateImageView
    vkDestroyImageView*: PFN_vkDestroyImageView
    vkCreateShaderModule*: PFN_vkCreateShaderModule
    vkDestroyShaderModule*: PFN_vkDestroyShaderModule
    vkCreateRenderPass*: PFN_vkCreateRenderPass
    vkDestroyRenderPass*: PFN_vkDestroyRenderPass
    vkCreateFramebuffer*: PFN_vkCreateFramebuffer
    vkDestroyFramebuffer*: PFN_vkDestroyFramebuffer

    # Commands
    vkCreateCommandPool*: PFN_vkCreateCommandPool
    vkDestroyCommandPool*: PFN_vkDestroyCommandPool
    vkAllocateCommandBuffers*: PFN_vkAllocateCommandBuffers
    vkFreeCommandBuffers*: PFN_vkFreeCommandBuffers
    vkBeginCommandBuffer*: PFN_vkBeginCommandBuffer
    vkEndCommandBuffer*: PFN_vkEndCommandBuffer
    vkResetCommandBuffer*: PFN_vkResetCommandBuffer

    # Memory & Buffers
    vkCreateBuffer*: PFN_vkCreateBuffer
    vkDestroyBuffer*: PFN_vkDestroyBuffer
    vkGetBufferMemoryRequirements*: PFN_vkGetBufferMemoryRequirements
    vkAllocateMemory*: PFN_vkAllocateMemory
    vkFreeMemory*: PFN_vkFreeMemory
    vkBindBufferMemory*: PFN_vkBindBufferMemory
    vkMapMemory*: PFN_vkMapMemory
    vkUnmapMemory*: PFN_vkUnmapMemory

    # Images & Samplers
    vkCreateImage*: PFN_vkCreateImage
    vkDestroyImage*: PFN_vkDestroyImage
    vkGetImageMemoryRequirements*: PFN_vkGetImageMemoryRequirements
    vkBindImageMemory*: PFN_vkBindImageMemory
    vkCreateSampler*: PFN_vkCreateSampler
    vkDestroySampler*: PFN_vkDestroySampler

    # Descriptors & Pipelines
    vkCreateDescriptorSetLayout*: PFN_vkCreateDescriptorSetLayout
    vkDestroyDescriptorSetLayout*: PFN_vkDestroyDescriptorSetLayout
    vkCreateDescriptorPool*: PFN_vkCreateDescriptorPool
    vkDestroyDescriptorPool*: PFN_vkDestroyDescriptorPool
    vkAllocateDescriptorSets*: PFN_vkAllocateDescriptorSets
    vkUpdateDescriptorSets*: PFN_vkUpdateDescriptorSets
    vkCreatePipelineLayout*: PFN_vkCreatePipelineLayout
    vkDestroyPipelineLayout*: PFN_vkDestroyPipelineLayout
    vkCreateGraphicsPipelines*: PFN_vkCreateGraphicsPipelines
    vkDestroyPipeline*: PFN_vkDestroyPipeline

    # Sync
    vkCreateSemaphore*: PFN_vkCreateSemaphore
    vkDestroySemaphore*: PFN_vkDestroySemaphore
    vkCreateFence*: PFN_vkCreateFence
    vkDestroyFence*: PFN_vkDestroyFence
    vkWaitForFences*: PFN_vkWaitForFences
    vkResetFences*: PFN_vkResetFences

    # Draw Commands
    vkCmdBeginRenderPass*: PFN_vkCmdBeginRenderPass
    vkCmdEndRenderPass*: PFN_vkCmdEndRenderPass
    vkCmdBindPipeline*: PFN_vkCmdBindPipeline
    vkCmdBindVertexBuffers*: PFN_vkCmdBindVertexBuffers
    vkCmdBindIndexBuffer*: PFN_vkCmdBindIndexBuffer
    vkCmdBindDescriptorSets*: PFN_vkCmdBindDescriptorSets
    vkCmdPushConstants*: PFN_vkCmdPushConstants
    vkCmdSetViewport*: PFN_vkCmdSetViewport
    vkCmdSetScissor*: PFN_vkCmdSetScissor
    vkCmdDraw*: PFN_vkCmdDraw
    vkCmdDrawIndexed*: PFN_vkCmdDrawIndexed
    vkCmdCopyBufferToImage*: PFN_vkCmdCopyBufferToImage
    vkCmdPipelineBarrier*: PFN_vkCmdPipelineBarrier

# =============================================================================
# Dynamic Loader
# =============================================================================

# Safe: dynamic loader for vulkan-1.dll / libvulkan.so function pointers via vkGetInstanceProcAddr.
proc loadVulkanApi*(): VulkanApi {.trustedUnsafe, raises: [].} =
  when defined(windows):
    result.lib = loadLib("vulkan-1.dll")
  elif defined(macosx):
    result.lib = loadLib("libMoltenVK.dylib")
    if result.lib.isNil:
      result.lib = loadLib("libvulkan.1.dylib")
  else:
    result.lib = loadLib("libvulkan.so.1")
    if result.lib.isNil:
      result.lib = loadLib("libvulkan.so")

  if result.lib.isNil:
    return

  result.vkGetInstanceProcAddr = cast[PFN_vkGetInstanceProcAddr](result.lib.symAddr("vkGetInstanceProcAddr"))
  if result.vkGetInstanceProcAddr.isNil:
    unloadLib(result.lib)
    result.lib = nil
    return

  # Load base instance creation & layer enumeration procs
  result.vkCreateInstance = cast[PFN_vkCreateInstance](result.vkGetInstanceProcAddr(nil, "vkCreateInstance"))
  result.vkEnumerateInstanceLayerProperties = cast[PFN_vkEnumerateInstanceLayerProperties](result.vkGetInstanceProcAddr(nil, "vkEnumerateInstanceLayerProperties"))

# Safe: resolves Vulkan instance function pointers via vkGetInstanceProcAddr for a live VkInstance.
proc loadInstanceProcs*(api: var VulkanApi, instance: VkInstance) {.trustedUnsafe, raises: [].} =
  template load(field, name) =
    field = cast[typeof(field)](api.vkGetInstanceProcAddr(instance, name))

  load(api.vkDestroyInstance, "vkDestroyInstance")
  load(api.vkEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices")
  load(api.vkGetPhysicalDeviceProperties, "vkGetPhysicalDeviceProperties")
  load(api.vkGetPhysicalDeviceFeatures, "vkGetPhysicalDeviceFeatures")
  load(api.vkGetPhysicalDeviceQueueFamilyProperties, "vkGetPhysicalDeviceQueueFamilyProperties")
  load(api.vkGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties")
  load(api.vkCreateDevice, "vkCreateDevice")
  load(api.vkDestroyDevice, "vkDestroyDevice")
  load(api.vkGetDeviceProcAddr, "vkGetDeviceProcAddr")

  load(api.vkDestroySurfaceKHR, "vkDestroySurfaceKHR")
  load(api.vkGetPhysicalDeviceSurfaceSupportKHR, "vkGetPhysicalDeviceSurfaceSupportKHR")
  load(api.vkGetPhysicalDeviceSurfaceCapabilitiesKHR, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
  load(api.vkGetPhysicalDeviceSurfaceFormatsKHR, "vkGetPhysicalDeviceSurfaceFormatsKHR")
  load(api.vkGetPhysicalDeviceSurfacePresentModesKHR, "vkGetPhysicalDeviceSurfacePresentModesKHR")

  when defined(windows):
    load(api.vkCreateWin32SurfaceKHR, "vkCreateWin32SurfaceKHR")

# Safe: resolves Vulkan device function pointers via vkGetDeviceProcAddr for a live VkDevice.
proc loadDeviceProcs*(api: var VulkanApi, device: VkDevice) {.trustedUnsafe, raises: [].} =
  template load(field, name) =
    if not api.vkGetDeviceProcAddr.isNil:
      field = cast[typeof(field)](api.vkGetDeviceProcAddr(device, name))
    if field.isNil and not api.vkGetInstanceProcAddr.isNil:
      field = cast[typeof(field)](api.vkGetInstanceProcAddr(nil, name))

  load(api.vkGetDeviceQueue, "vkGetDeviceQueue")
  load(api.vkQueueSubmit, "vkQueueSubmit")
  load(api.vkQueueWaitIdle, "vkQueueWaitIdle")
  load(api.vkDeviceWaitIdle, "vkDeviceWaitIdle")

  load(api.vkCreateSwapchainKHR, "vkCreateSwapchainKHR")
  load(api.vkDestroySwapchainKHR, "vkDestroySwapchainKHR")
  load(api.vkGetSwapchainImagesKHR, "vkGetSwapchainImagesKHR")
  load(api.vkAcquireNextImageKHR, "vkAcquireNextImageKHR")
  load(api.vkQueuePresentKHR, "vkQueuePresentKHR")

  load(api.vkCreateImageView, "vkCreateImageView")
  load(api.vkDestroyImageView, "vkDestroyImageView")
  load(api.vkCreateShaderModule, "vkCreateShaderModule")
  load(api.vkDestroyShaderModule, "vkDestroyShaderModule")
  load(api.vkCreateRenderPass, "vkCreateRenderPass")
  load(api.vkDestroyRenderPass, "vkDestroyRenderPass")
  load(api.vkCreateFramebuffer, "vkCreateFramebuffer")
  load(api.vkDestroyFramebuffer, "vkDestroyFramebuffer")

  load(api.vkCreateCommandPool, "vkCreateCommandPool")
  load(api.vkDestroyCommandPool, "vkDestroyCommandPool")
  load(api.vkAllocateCommandBuffers, "vkAllocateCommandBuffers")
  load(api.vkFreeCommandBuffers, "vkFreeCommandBuffers")
  load(api.vkBeginCommandBuffer, "vkBeginCommandBuffer")
  load(api.vkEndCommandBuffer, "vkEndCommandBuffer")
  load(api.vkResetCommandBuffer, "vkResetCommandBuffer")

  load(api.vkCreateBuffer, "vkCreateBuffer")
  load(api.vkDestroyBuffer, "vkDestroyBuffer")
  load(api.vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements")
  load(api.vkAllocateMemory, "vkAllocateMemory")
  load(api.vkFreeMemory, "vkFreeMemory")
  load(api.vkBindBufferMemory, "vkBindBufferMemory")
  load(api.vkMapMemory, "vkMapMemory")
  load(api.vkUnmapMemory, "vkUnmapMemory")

  load(api.vkCreateImage, "vkCreateImage")
  load(api.vkDestroyImage, "vkDestroyImage")
  load(api.vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements")
  load(api.vkBindImageMemory, "vkBindImageMemory")
  load(api.vkCreateSampler, "vkCreateSampler")
  load(api.vkDestroySampler, "vkDestroySampler")

  load(api.vkCreateDescriptorSetLayout, "vkCreateDescriptorSetLayout")
  load(api.vkDestroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout")
  load(api.vkCreateDescriptorPool, "vkCreateDescriptorPool")
  load(api.vkDestroyDescriptorPool, "vkDestroyDescriptorPool")
  load(api.vkAllocateDescriptorSets, "vkAllocateDescriptorSets")
  load(api.vkUpdateDescriptorSets, "vkUpdateDescriptorSets")
  load(api.vkCreatePipelineLayout, "vkCreatePipelineLayout")
  load(api.vkDestroyPipelineLayout, "vkDestroyPipelineLayout")
  load(api.vkCreateGraphicsPipelines, "vkCreateGraphicsPipelines")
  load(api.vkDestroyPipeline, "vkDestroyPipeline")

  load(api.vkCreateSemaphore, "vkCreateSemaphore")
  load(api.vkDestroySemaphore, "vkDestroySemaphore")
  load(api.vkCreateFence, "vkCreateFence")
  load(api.vkDestroyFence, "vkDestroyFence")
  load(api.vkWaitForFences, "vkWaitForFences")
  load(api.vkResetFences, "vkResetFences")

  load(api.vkCmdBeginRenderPass, "vkCmdBeginRenderPass")
  load(api.vkCmdEndRenderPass, "vkCmdEndRenderPass")
  load(api.vkCmdBindPipeline, "vkCmdBindPipeline")
  load(api.vkCmdBindVertexBuffers, "vkCmdBindVertexBuffers")
  load(api.vkCmdBindIndexBuffer, "vkCmdBindIndexBuffer")
  load(api.vkCmdBindDescriptorSets, "vkCmdBindDescriptorSets")
  load(api.vkCmdPushConstants, "vkCmdPushConstants")
  load(api.vkCmdSetViewport, "vkCmdSetViewport")
  load(api.vkCmdSetScissor, "vkCmdSetScissor")
  load(api.vkCmdDraw, "vkCmdDraw")
  load(api.vkCmdDrawIndexed, "vkCmdDrawIndexed")
  load(api.vkCmdCopyBufferToImage, "vkCmdCopyBufferToImage")
  load(api.vkCmdPipelineBarrier, "vkCmdPipelineBarrier")

proc unload*(api: var VulkanApi) {.raises: [].} =
  if not api.lib.isNil:
    unloadLib(api.lib)
    api.lib = nil
