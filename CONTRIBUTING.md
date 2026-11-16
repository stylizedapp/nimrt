# Contributing

Thank you for contributing to the **Nim Native Ecosystem & NimUI**!

## Prerequisites (Windows-First)

- **Nim `>= 2.0.0`** (tested on Nim `2.2.12`) and **Nimble** in `PATH`
- **C Compiler**: MinGW-W64 `gcc` / `ar` (bundled with Nim on Windows or standalone) in `PATH`
- **PowerShell** (Windows PowerShell 5.1+ or PowerShell 7+) for QuickJS static library builds
- **Python 3** (optional, required only for `nimble showcase_html`)
- **Vulkan 1.1+ driver** (required only for interactive GPU windows; all headless tests and PNG exports use the CPU software rasterizer)
- **GLSL compiler (`glslangValidator`)** (optional, required only when modifying `tools/shaders/ui.vert` or `ui.frag`; precompiled `.spv` binaries and `src/nimui/gpu/shaders.nim` are already checked in)
- **Nim compiler source tree at `C:/nim`** (required to build `bin/nim_safe.exe` via `compiler/nim.cfg`)

## Initial Setup

1. Build the embedded QuickJS C static library (`src/nimui/js/libquickjs.a`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1
   ```
   (Or run `nimble build_quickjs`.)

2. Build the experimental hybrid memory-safe compiler (`bin/nim_safe.exe`):
   ```powershell
   nimble build_compiler
   ```

## Running Tests

```powershell
# Run corex + algx + MFT + IOCP + signals test suite
nimble test

# Run NimUI layout, widgets, and Zero-JS HTML5/CSS3 tests
nimble test_ui

# Run QuickJS hybrid engine, philosophy validator, and Pomodoro tests
nimble test_js

# Run headless integration verification across all 4 showcase apps
nimble test_showcase

# Run nim_safe compiler verification (--mem-safe, --safe-mode, --check-safe-atf)
nimble test_compiler

# Run WizTree disk-scanner verification suite
nimble test_wiztree

# Run the full repository test suite (all tests in tests/)
nimble test_all
```

## Shader Rebuilding (Optional)

If you modify `tools/shaders/ui.vert` or `tools/shaders/ui.frag`:

1. Compile GLSL to SPIR-V into `tools/shaders/ui.vert.spv` and `tools/shaders/ui.frag.spv` (e.g. using `glslangValidator -V` from `tools/glslang/`, which is gitignored).
2. Regenerate `src/nimui/gpu/shaders.nim`:
   ```powershell
   nim c -r tools/spv_to_nim.nim
   ```

## Coding & Safety Guidelines

- **Memory model**: All code compiles under `--mm:orc --threads:on --panics:on` (configured in `nim.cfg`).
- **Explicit errors**: Prefer `Result[T, E]` / `Option[T]` and `{.raises: [].}` in core modules; do not swallow `Defect` with bare `except:`.
- **Zero-leak verification**: Use `testWithLeakCheck` (`corex/testing`) for allocator-backed code, and verify ORC heap stability where applicable.
- **Zero-warning hygiene**: Avoid unused imports and unused declarations. Verify changes with strict compiler checks:
  ```powershell
  nim check --hints:on --warnings:on --warningAsError[UnusedImport]:on src/corex.nim
  nim check --hints:on --warnings:on --warningAsError[UnusedImport]:on src/algx.nim
  nim check --hints:on --warnings:on --warningAsError[UnusedImport]:on src/nimui.nim
  ```
- **Architectural boundary**: Keep `src/` strictly for reusable runtime libraries (`corex`, `algx`, `nimui`). Place end-user executables and demos under `apps/`.
