# First-Run Experience, Doctor & QuickJS Delivery Strategy

## 1. One-Command First-Run Experience

On a fresh checkout (Windows), developers can verify their environment and launch any showcase app in a single command:

```powershell
# 1. Diagnose toolchain, Vulkan driver, QuickJS, fonts, permissions, and cache
nimble doctor

# 2. Launch showcase apps (auto-builds QuickJS on first run if missing)
nimble studio    # NimUI HTML5/CSS3 Zero-JS Studio
nimble gallery   # NimUI Component, SDF & Unicode Gallery
nimble demo      # Singularity Lab Relativistic Kerr Black Hole Demo

# 3. Run canonical benchmark (release headless mode + JSON/CSV output)
nimble bench_canonical
```

### `nimble doctor` Checks
[`tools/doctor.nim`](../tools/doctor.nim) checks:
1. **Nim Compiler** (`>= 2.0.0`) and **Nimble**.
2. **MinGW-W64 `gcc` & `ar`** (preferring `<nim>/dist/mingw64/bin`, falling back to `PATH`).
3. **Vulkan Loader & Driver** (`vulkan-1.dll`, `vkCreateInstance`, physical device API `>= 1.1`). Missing/older Vulkan warns cleanly and notes that headless software rasterization remains available.
4. **`glslangValidator`** (optional; precompiled `.spv` and `src/nimui/gpu/shaders.nim` are checked in).
5. **QuickJS Static Library** (`src/nimui/js/libquickjs.a` + `src/nimui/js/vendor/VERSION`).
6. **System Fonts** (`%WINDIR%\Fonts`: `segoeui.ttf`, `consola.ttf`, and Unicode/CJK fallbacks).
7. **Workspace Permissions & Elevation** (writeability of `.`, `bin/`, `nimcache/`, `benchmarks/results/`; standard user vs Admin note for raw MFT scans).
8. **Build Cache** (`nimcache/` file count & size).

---

## 2. QuickJS Delivery Strategy

### Background
`src/nimui.nim` exports `nimui/js/js_engine`, which links `src/nimui/js/libquickjs.a` via `{.passL: qjsLibPath.}`. On a fresh git clone, `libquickjs.a` is not committed as a binary blob, which previously caused `nimble studio`, `nimble demo`, and `nimble gallery` to fail at link time (`cannot find .../libquickjs.a`) unless `nimble build_quickjs` had been run manually.

### Strategy: Vendored Source-Build with Auto-Bootstrap + CI Caching + Zero-JS Opt-In

1. **Source-Built Vendored Default (Primary)**:
   - Full QuickJS C sources are vendored in `src/nimui/js/vendor/` alongside `src/nimui/js/qjs_bridge.c`.
   - `tools/build_quickjs.ps1` compiles them into `src/nimui/js/libquickjs.a` using Nim's bundled MinGW-W64 `gcc` and `ar` — **zero external downloads, zero MSVC/CMake dependency, and 100% reproducible**.
   - `nim_ecosystem.nimble` defines `ensureQuickJs()`, which checks `fileExists("src/nimui/js/libquickjs.a")` and automatically runs `tools/build_quickjs.ps1` on first invocation of `studio`, `gallery`, `demo`, `html_desktop`, `pomodoro`, `pomodoro_test`, `test_ui`, `test_js`, `test_showcase`, `build_release`, `test_all`, and `bench_canonical`.

2. **Prebuilt / CI Artifact Caching (Secondary)**:
   - In GitHub Actions (`.github/workflows/ci.yml`), `libquickjs.a` only needs to be compiled once per job (or cached keyed on `hashFiles('src/nimui/js/vendor/**', 'src/nimui/js/qjs_bridge.*', 'tools/build_quickjs.ps1')`).
   - For air-gapped or prebuilt distributions, dropping a matching `libquickjs.a` into `src/nimui/js/` skips compilation automatically.

3. **Zero-JS / Opt-In Isolation**:
   - Applications that do not execute JavaScript (`html_css_studio`, `widget_gallery`, `nimui_demo`) use the pure-Nim HTML5/CSS3 engine (`nimui/html_css`) and native `nimui/dsl` controls with zero JS runtime initialization.
   - Modules importing only `nimui/layout`, `nimui/dsl`, `nimui/rasterizer`, and `nimui/html_css` (without the `nimui` umbrella facade) do not trigger the `libquickjs.a` linker directive at all.
