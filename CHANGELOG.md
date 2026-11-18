# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [04.03.03] (4.3.3) - 2026-11-19

Production-readiness, security hardening, deterministic UI, and DX release (aligned with the `00.00.00` major/minor/patch hierarchy across `CoreX`/`AlgX`, `NimUI`, `nim_safe`, and `Component SDK`).

### Added
- **Benchmarking & DX**: Canonical benchmark app (`benchmarks/canonical_bench.nim`) with headless JSON/CSV output, `docs/BENCHMARK_METHODOLOGY.md`, `tools/doctor.nim` (`nimble doctor`), and automatic QuickJS static library bootstrap (`ensureQuickJs()`).
- **UI & Graphics Reliability**: Vulkan 1.1+ diagnostics and graceful CPU rasterizer fallback (`src/nimui/renderer.nim`), machine-readable HTML5/CSS3 compatibility manifest (`docs/html_css_manifest.json`, `src/nimui/html/manifest.nim`), layout cycle/depth/`NaN` guards, `zIndex` ordering, deterministic `snapshotUiTree`, and visual diff tests.
- **Security Hardening**: QuickJS C-level hardening (`eval`, `Function`, `Proxy`, `Reflect`, dynamic `import()`), capability separation + audit log; MFT `mpmStrict` mode, `explicitConsent` enforcement, and 100k+ fuzz tests; `[MEM-SAFE-008]` FFI/external-C rejection and bypass negative tests in `compiler/mem_safe_pass.nim`.
- **Component SDK & Release Polish**: `src/nimui/sdk.nim` (11 UI blocks, 6 system blocks, default-deny permissions, SemVer `BlockRegistry`), `docs/FOCUS.md`, `docs/DISTRIBUTION.md`, `docs/RELEASES.md`, and enhanced `.github/workflows/release.yml`.

### Fixed
- **USN Monitor Admin CI Crash**: Stored `Thread[ptr UsnMonitorContext]` inside heap-allocated `UsnMonitorContext` (`allocShared0`) so returning/moving `Result[UsnMonitor, IOError]` in elevated Windows CI runners never leaves `CreateThread`'s `lpParameter` dangling on a popped stack frame.

## [0.2.0] - 2026-11-17

### Fixed & Improved
- `nim_safe` `--mem-safe --safe-mode` compliance across `src/nimui` and `apps/`.
- Win32 `ptr culong` GCC 14 compatibility and elevated Admin runner handling in `test_cli`.
- CI hardening (`nightly_concurrency.yml`, `strict-warnings`, `ubuntu` cross-check).

## [0.1.0] - 2026-11-16

Initial MVP release of the **Nim Native Ecosystem & NimUI** (Windows-first).

### Added

#### `corex` — Foundational Systems Core (`src/corex/`)
- **Allocators & Memory**: `Allocator` interface with `FixedBufferAllocator`, `ArenaAllocator`, `PoolAllocator`, `PageAllocator`, and `TrackingAllocator`; zero-cost wrappers (`Span[T]`, `ByteSpan`, `Owned[T]`, `Arc[T]`); `Slab[T]`, `StringArena`, `StringInterner`, `SmallVec`, `BufSeq[T]`, `BufStr`, and `BufMap[K, V]`.
- **Error Handling & ADTs**: `Result[T, E]`, `?` early-return operator, `errdefer`, `sumType` / `match` algebraic data type macros, `Option[T]`, `Dyn[Trait]` fat-pointer polymorphism, and source `diagnostic` formatting.
- **Concurrency & Async**: `Atomic[T]`, `SpinLock`, `SysLock`, `RwLock`, `Barrier`, `WaitGroup`, `SpscQueue`, `MpmcQueue`, `ThreadPool` with Chase-Lev work-stealing deques (`workstealing.nim`), cooperative `parallelFor`, and Windows IOCP async reactor (`async.nim`, `win32_iocp.nim`).
- **Reactive Engine**: Slab-backed `ReactiveRuntime`, `Signal[T]`, `Computed[T]`, `effect`, and `batch` (`signals.nim`).
- **I/O, Filesystem, MFT & Unicode**: RAII `FileHandle`, `BufferedReader`, `BufferedWriter`, `walkDirFast` (`win32_fs` / experimental `posix_fs`), `win32_volume`, raw NTFS `$MFT` record parser with FIXUP validation, runlist decoding, and `$ATTRIBUTE_LIST` support (`mft.nim`, `win32_mft.nim`), UTF-8 / UAX #29 grapheme utilities (`unicode.nim`), `bitops`, and `testing` helpers (`quickCheck`, `bench`, `testWithLeakCheck`).

#### `algx` — High-Throughput Algorithms & Data Structures (`src/algx/`)
- `ultrasort`: Multi-threaded 3-level Cache-Aware MSD Radix Sort + L1 Insertion Sort.
- `swissmap`: Flat SwissTable-style hash map (`FastMap[K, V]`) returning `Option[V]`.
- `zeropack`: Zero-copy POD binary packing and streaming zero-DOM JSON serializer.
- `simdscan`: 8-way unrolled vector array analytics.
- `heap`: Cache-friendly `BinaryHeap[T]` with non-throwing `tryPeek` / `tryPop`.

#### `nimui` — Declarative UI, HTML5/CSS3 & Vulkan SDF (`src/nimui/`)
- **Layout & Widgets**: O(N) Flexbox engine (`LayoutPool`, `UiTree`, `UiNode`) with scissor clipping, declarative Nim UI DSL (`VStack`, `HStack`, `Box`, `Text`, `Button`, `TextInput`, `TextArea`, `Checkbox`, `RadioGroup`, `Slider`, `Dropdown`, `Tooltip`, `VirtualList`), clipboard, and multiline editing.
- **HTML5/CSS3 Engine**: Embedded HTML5/CSS3 subset parser and cascade compiler (`html_css.nim`) with strict Zero-JS mode (`allowJs = false` by default) and `HtmlBindingRegistry` reactive bindings.
- **GPU & Software Rasterizer**: Vulkan 1.1+ instanced SDF renderer (`vulkan_backend.nim`, `vulkan_api.nim`, `shaders.nim`), GDI/LRU glyph `font_atlas.nim`, Win32 `window.nim`, and deterministic CPU `rasterizer.nim` with PNG export for headless verification.

#### QuickJS Hybrid Engine (`src/nimui/js/`)
- Embedded QuickJS C runtime (`libquickjs.a` via `tools/build_quickjs.ps1`) with all allocations routed through `corex/allocators.Allocator` and configurable step/memory limits (`js_engine.nim`, `qjs_bridge.c`).
- Static JS philosophy validator (`js_validator.nim`) rejecting `var`, `==`/`!=`, `eval`, `Function`, `with`, `__proto__`, and enforcing explicit `<script data-caps="...">` capabilities.
- Bidirectional Nim/DOM/Signal bridge (`html_js_bridge.nim`) demonstrated with the interactive Pomodoro timer (`apps/html_desktop/ui/pomodoro.html`).

#### `nim_safe` — Hybrid Memory-Safe Nim Compiler (`compiler/`)
- Experimental compiler wrapper over Nim 2.2.x (`nim_safe.nim`, `safety_config.nim`, `mem_safe_pass.nim`, `atf_c_checker.nim`) supporting `--mem-safe`, `--safe-mode`, `--check-safe-atf`, and `--atf-report:<path>`, with `{.trustedUnsafe.}` / `block trustedUnsafe:` escape hatches.

#### Applications & Tooling (`apps/`, `tools/`, `tests/`)
- `apps/wiztree`: Fast NTFS MFT / Win32 disk usage analyzer CLI with table, CSV, and streaming JSON output.
- `apps/everything`: NTFS MFT + USN Journal real-time file indexer and search CLI/GUI.
- Showcase UI applications: `apps/html_desktop`, `apps/html_css_studio`, `apps/widget_gallery`, `apps/nimui_demo`, plus `apps/mini-browser` prototype.
- Developer tools: `tools/build_quickjs.ps1`, `tools/spv_to_nim.nim` + precompiled `tools/shaders/*.spv`.
- Infrastructure: `LICENSE` (MIT), `CONTRIBUTING.md`, `nim_ecosystem.nimble` task suite (`test_all`, `test`, `test_ui`, `test_js`, `test_showcase`, `test_compiler`, `test_wiztree`), and GitHub Actions Windows CI workflow (`.github/workflows/ci.yml`).
