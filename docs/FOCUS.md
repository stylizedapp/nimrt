# Project Focus & Product Positioning (`docs/FOCUS.md`)

> **Item 15 Specification** — Core Product Definition, Libraries vs Product Features, First Vertical, Explicit Non-Goals, and 1-Sentence Pitch.

---

## 1. One-Sentence Pitch

> **NimRT is a Windows-first native desktop runtime and Vulkan 1.1+ SDF UI engine that lets you ship <40 ms startup, ~25 MB RAM desktop tools using Nim + a practical HTML5/CSS3 subset without Chromium or Electron.**

---

## 2. Core Product Definition

**NimRT** is a **native desktop application runtime and UI engine** written in Nim 2.x (`--mm:orc`). It replaces heavy browser wrappers (Electron / WebView2) with:
- A deterministic, zero-GC-pause systems foundation (`corex` + `algx`),
- A single-draw-call Vulkan 1.1+ instanced SDF renderer + Flexbox layout engine (`nimui`),
- A strict **Zero-JS by default** HTML5/CSS3 subset with opt-in capability-gated QuickJS (`nimui/js`) and a typed Component SDK (`nimui/sdk`).

---

## 3. Libraries vs Product Features

To prevent scope creep and keep `src/` strictly pure, NimRT separates **reusable runtime libraries** from **product features & reference apps**:

| Layer | Location | Role | Examples |
| :--- | :--- | :--- | :--- |
| **Core Libraries** | `src/corex/`, `src/algx/` | Reusable, zero-leak systems & algorithm primitives | `TrackingAllocator`, `Result[T, E]`, `signals`, `workstealing`, `async` (IOCP), `mft`, `ultrasort`, `swissmap`, `zeropack`, `simdscan` |
| **UI & SDK Engine** | `src/nimui/` | Native UI tree, Flexbox, HTML5/CSS3 subset, Vulkan SDF, CPU rasterizer, QuickJS sandbox, Component SDK | `layout`, `dsl`, `controls`, `html_css`, `gpu/vulkan_backend`, `sdk/*` |
| **Product / Reference Apps** | `apps/` | End-user tools & showcase products built *on top of* the libraries | `apps/html_desktop` (standalone HTML5/CSS3 runner), `apps/html_css_studio`, `apps/widget_gallery`, `apps/wiztree`, `apps/everything`, `apps/nimui_demo` |
| **Experimental Research** | `compiler/` | Opt-in static/ATF safety tooling (not required to use NimRT) | `compiler/nim_safe.nim` (`--mem-safe`, `--check-safe-atf`) |

---

## 4. First Vertical

NimRT's **first target vertical** is:

> **High-speed local Windows system utilities, developer tools, and internal operations dashboards.**

Why this vertical fits NimRT's strengths:
1. **Instant launch & tiny footprint:** Sub-40 ms cold start, ~20–35 MB idle RAM, ~8–15 MB single-file `.exe`.
2. **Direct OS & hardware access:** Native Win32 IOCP, direct NTFS `$MFT` / USN Journal streaming (`wiztree`, `everything`), and Per-Monitor v2 DPI without IPC serialization overhead.
3. **Predictable security:** Zero-JS by default; when scripting or third-party blocks are enabled, capabilities (`fs`, `network`, `process`, `clipboard`, `notifications`) are explicit and default-deny.

---

## 5. Explicit Non-Goals

NimRT explicitly **does NOT** aim to be:
1. **A general-purpose web browser:** No full HTML5 living standard, no CSS Grid, no `:has()`, no `<canvas>`/`WebGL`, no `<iframe>`, no browser extensions.
2. **A drop-in Node.js / npm / Electron replacement:** No Node.js APIs, no npm ecosystem compatibility, no V8/Chromium runtime.
3. **A mobile or web-WASM framework first:** Windows 10/11 x64 is the primary target for v0.1.x; Linux (Wayland/X11) and macOS (Metal/MoltenVK) are future ports, not current MVP blockers.
4. **A silent background telemetry or auto-updater platform:** Zero hidden network calls, zero background services.
