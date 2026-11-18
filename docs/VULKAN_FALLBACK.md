# NimUI Vulkan 1.1+ Backend & CPU Fallback Policy

## Minimum Supported Vulkan Configuration

NimUI targets **Vulkan 1.1.0** (`MinVulkanApiVersion = (1 shl 22) or (1 shl 12)`) with zero third-party windowing/GPU dependencies (`vulkan-1.dll` on Windows, `libvulkan.so.1` on Linux).

| Requirement | Minimum Value | Notes |
| --- | --- | --- |
| Vulkan API Version | `1.1.0` | Checked at both instance creation (`VkApplicationInfo.apiVersion`) and physical device selection (`VkPhysicalDeviceProperties.apiVersion`). |
| Instance Extensions | `VK_KHR_surface`, `VK_KHR_win32_surface` (Windows) / `VK_KHR_xlib_surface` (Linux) | Required for native OS surface presentation. |
| Device Extensions | `VK_KHR_swapchain` | Required for swapchain presentation. |
| Queue Families | Graphics (`VK_QUEUE_GRAPHICS_BIT`) + Presentation (`vkGetPhysicalDeviceSurfaceSupportKHR`) | Discrete GPUs are preferred over integrated GPUs. |
| Surface Format | `VK_FORMAT_B8G8R8A8_SRGB` or `VK_FORMAT_B8G8R8A8_UNORM` | Fallback to first available surface format if neither is present. |
| Instance Buffer | 64-byte `UiDrawInstance`, `MaxInstancesPerFrame = 16384` | Host-visible + host-coherent mapped ring buffer (2 frames in flight). |

## CPU Rasterizer Fallback Policy (Production & Test)

**Status:** **Production graceful fallback** AND **primary headless/CI test rasterizer**.

- **Primary Production Renderer:** `VulkanBackend` (Vulkan 1.1+ hardware-accelerated 2D SDF pipeline).
- **Automatic Production Fallback:** `NimuiRenderer` (`src/nimui/renderer.nim`) automatically falls back to `SoftwareFramebuffer` (`src/nimui/rasterizer.nim`) whenever:
  1. `vulkan-1.dll` / `libvulkan.so.1` is missing or no suitable GPU/surface is available (`vkdVulkanUnavailable`),
  2. The Vulkan loader or GPU driver only supports `< 1.1.0` (`vkdDriverTooOld`),
  3. SPIR-V shader module or graphics pipeline creation fails (`vkdShaderCompilationFailed`), or
  4. `VK_ERROR_DEVICE_LOST` occurs at runtime and `recoverFromDeviceLost` cannot re-initialize Vulkan (`vkdDeviceLost`).
- **Headless & CI Snapshot Testing:** `SoftwareFramebuffer` evaluates the exact same 2D SDF rounded box, inset border, anti-aliasing, scissor `clipRect`, and `FontAtlas` glyph blending as the Vulkan fragment shader, enabling deterministic pixel-level visual diffing in CI without a GPU swapchain.
- **Performance Trade-off:** CPU fallback is intended for resilience (VMs, RDP sessions, legacy GPUs, recovery after driver reset) and headless verification; high-refresh-rate animation should run on Vulkan 1.1+.

## Diagnostic Categories

`classifyVulkanDiagnostic` and `makeVulkanDiagnostic` in `src/nimui/gpu/vulkan_backend.nim` categorize all initialization and runtime failures into four explicit diagnostics:

1. **`Vulkan unavailable`** (`vkdVulkanUnavailable`): Driver DLL/SO missing, `hwnd` is `nil`, `vkCreateInstance` failed, no physical devices enumerated, or no device with graphics + present queues.
2. **`driver too old`** (`vkdDriverTooOld`): `VK_ERROR_INCOMPATIBLE_DRIVER` from `vkCreateInstance`, or all physical devices report `apiVersion < 1.1.0`.
3. **`shader compilation failed`** (`vkdShaderCompilationFailed`): Empty SPIR-V bytecode, `vkCreateShaderModule` failure, or `vkCreateGraphicsPipelines` failure.
4. **`device lost`** (`vkdDeviceLost`): `VK_ERROR_DEVICE_LOST` during fence wait, image acquire, queue submit, present, or swapchain recreation.
