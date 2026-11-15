## nimui — High-Performance Native Immediate/Retained UI with Vulkan 1.1+ Backend
##
## Unified facade module exporting:
## - GPU backend & Font Atlas (vulkan_backend, font_atlas)
## - OS Windowing & Event Loop (window)
## - Zero-allocation Flexbox Layout & Retained UI Tree (layout)
## - Declarative UI DSL & Reactive Components (dsl)
## - Fine-grained Reactive Signals (corex/signals)

import nimui/gpu/vulkan_backend
import nimui/gpu/font_atlas
import nimui/window
import nimui/layout
import nimui/dsl
import nimui/controls
import nimui/clipboard
import nimui/multiline
import nimui/rasterizer
import nimui/html_css
import corex/signals
import corex/result
import corex/slab
import corex/allocators

export vulkan_backend
export font_atlas
export window
export layout
export dsl
export controls
export clipboard
export multiline
export rasterizer
export html_css
export signals
export result
export slab
export allocators
