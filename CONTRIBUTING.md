# Contributing to NimRT

Thank you for your interest in contributing to the **Nim Native Ecosystem & NimUI** (NimRT)! We welcome contributions ranging from bug fixes and documentation improvements to new CSS features, performance optimizations, and platform ports.

> [!IMPORTANT]
> NimRT is engineered for high performance, deterministic memory, and zero runtime overhead. Please read these guidelines and adhere to the project standards before submitting a pull request.

---

## Code of Conduct

This project and everyone participating in it is governed by the [NimRT Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior following the instructions in `CODE_OF_CONDUCT.md`.

---

## Prerequisites (Windows-First)

- **Nim `>= 2.0.0`** (tested and verified on Nim `2.2.12`) and **Nimble** in `PATH`.
- **C Compiler**: MinGW-W64 `gcc` / `ar` (bundled with Nim on Windows or standalone) in `PATH`.
- **PowerShell** (Windows PowerShell 5.1+ or PowerShell 7+) for QuickJS static library builds.
- **Python 3** (optional, required only for `nimble showcase_html`).
- **Vulkan 1.1+ driver** (required only for interactive GPU windows; all headless tests and PNG exports run deterministically on CPU via the software rasterizer).
- **GLSL compiler (`glslangValidator`)** (optional, required only when modifying `tools/shaders/ui.vert` or `ui.frag`; precompiled `.spv` bytecode and `src/nimui/gpu/shaders.nim` are already checked in).
- **Nim compiler source tree at `C:/nim`** (required to build `bin/nim_safe.exe` via `compiler/nim.cfg`).

---

## Initial Setup

1. **Clone the repository:**
   ```powershell
   git clone https://github.com/stylizedapp/nimrt.git
   cd nimrt
   ```

2. **Build the embedded QuickJS C static library (`src/nimui/js/libquickjs.a`):**
   ```powershell
   nimble build_quickjs
   # Or directly: powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1
   ```

3. **Build the experimental hybrid memory-safe compiler (`bin/nim_safe.exe`):**
   ```powershell
   nimble build_compiler
   ```

---

## Development Workflow & Running Tests

Before submitting any code, verify that all test suites pass:

```powershell
# 1. Run corex + algx + MFT + IOCP + signals test suite
nimble test

# 2. Run NimUI layout, widgets, and Zero-JS HTML5/CSS3 tests
nimble test_ui

# 3. Run QuickJS hybrid engine, philosophy validator, and Pomodoro tests
nimble test_js

# 4. Run headless integration verification across all 4 showcase apps
nimble test_showcase

# 5. Run nim_safe compiler verification (--mem-safe, --safe-mode, --check-safe-atf)
nimble test_compiler

# 6. Run WizTree disk-scanner verification suite
nimble test_wiztree

# 7. Run the FULL repository test suite (all tests in tests/)
nimble test_all
```

> [!TIP]
> You can also run checked builds of `algx` to ensure SIMD and SwissTable bounds checking:
> ```powershell
> nim c -d:algxChecked -r tests/test_algx_checked.nim
> nim c -d:algxChecked -r tests/test_ecosystem.nim
> ```

---

## Coding & Safety Guidelines

- **Memory Model**: All code must compile and pass tests under `--mm:orc --threads:on --panics:on` (default in `nim.cfg`).
- **Explicit Errors**: Prefer `Result[T, E]` / `Option[T]` and `{.raises: [].}` in core modules. Do not swallow `Defect` with bare `except:`.
- **Zero-Leak Guarantee**: Use `testWithLeakCheck` (`corex/testing`) for allocator-backed code, and verify ORC heap stability via `assertZeroOrcLeaks()`.
- **Zero-Warning Hygiene**: Avoid unused imports and unused declarations. Verify changes with strict compiler checks:
  ```powershell
  nim check --hints:on --warnings:on --warningAsError[UnusedImport]:on src/corex.nim
  nim check --hints:on --warnings:on --warningAsError[UnusedImport]:on src/algx.nim
  nim check --hints:on --warnings:on --warningAsError[UnusedImport]:on src/nimui.nim
  ```
- **Architectural Boundary**: Keep `src/` strictly for reusable runtime libraries (`corex`, `algx`, `nimui`). Place end-user executables and showcase applications under `apps/`.

---

## Shader Rebuilding (Optional)

If you modify `tools/shaders/ui.vert` or `tools/shaders/ui.frag`:

1. Compile GLSL to SPIR-V into `tools/shaders/ui.vert.spv` and `tools/shaders/ui.frag.spv` (e.g. using `glslangValidator -V`).
2. Regenerate `src/nimui/gpu/shaders.nim`:
   ```powershell
   nim c -r tools/spv_to_nim.nim
   ```

---

## Submitting Pull Requests

1. Create a feature branch: `git checkout -b feat/my-awesome-feature`.
2. Commit your changes with clear, descriptive commit messages.
3. Push to your branch and open a Pull Request using the [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md).
4. Ensure all CI checks pass.
