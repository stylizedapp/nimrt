# Canonical Benchmark Methodology & Metrics Architecture

This document defines the reproducible benchmarking methodology for the Nim Ecosystem (`corex`, `algx`, `nimui`) via [`benchmarks/canonical_bench.nim`](../benchmarks/canonical_bench.nim).

## 1. Metric Layer Separation

To prevent conflating algorithmic kernel speed, UI layout/rasterization cost, and OS process overhead, metrics are strictly separated into three layers:

1. **`corex_algx` (CoreX & AlgX Engine)**
   - `algx_ultrasort_1m`: Parallel 4-thread hybrid MSD radix sort on 1,000,000 `int64` elements (`algx/ultrasort`).
   - `algx_swissmap_300k`: 16-byte SSE2 SwissTable `FastMap` (`algx/swissmap`) executing 100K inserts + 100K hits + 100K misses.
   - `corex_signals_10k`: Fine-grained reactive signal propagation (`corex/signals`) across 10,000 `Signal.set()` mutations.
   - `corex_arena_alloc_100k`: Bump-pointer `ArenaAllocator` (`corex/allocators`) throughput for 100,000 allocations + O(1) reset.

2. **`ui_engine` (NimUI Layout, HTML/CSS & Rasterization)**
   - `ui_minimal_layout_draw`: Minimal UI (`UiTree` ~12 nodes) two-pass Flexbox `layoutTree` + `buildDrawInstances`.
   - `ui_table_200x6_layout_draw`: 200-row × 6-column table (1,400+ nodes) `layoutTree` + `buildDrawInstances`.
   - `ui_forms_reactive_layout_draw`: Reactive form (inputs, labels, buttons, `bindText`/`bindInput` signal updates) `layoutTree` + `buildDrawInstances`.
   - `ui_virtuallist_100k_scroll`: `nkVirtualList` with 100,000 virtual rows, scrolling + `layoutTree` + `buildDrawInstances`.
   - `ui_html_css_mount`: Pure-Nim Zero-JS HTML5/CSS3 parsing, cascade, and `UiTree` mounting (`mountHtmlString`).
   - `ui_software_sdf_raster_1280x720`: Full-frame 1280×720 analytical 2D SDF + `FontAtlas` glyph rasterization (`renderInstancesToBuffer`).

3. **`full_app` (End-to-End Application & Process Metrics)**
   - `app_cold_start_ms`: First subprocess launch with `--ping` (process spawn → `FontAtlas` init → minimal `UiTree` layout + draw instances → exit).
   - `app_warm_start_ms`: Subsequent `--ping` subprocess launches (`p50`, `p95`, `min`, `mean`, `max`).
   - `app_binary_size_bytes`: Release executable size on disk (`bin/canonical_bench.exe`).
   - `app_rss_current_bytes` / `app_rss_peak_bytes`: Process Working Set and Peak Working Set via Windows `K32GetProcessMemoryInfo`.
   - `app_e2e_frame_headless_ms`: Complete headless frame (signal mutation → VirtualList scroll → `layoutTree` → `buildDrawInstances` → 1280×720 `renderInstancesToBuffer`).

---

## 2. Environment & Hardware Recording

Every JSON output (`benchmarks/results/canonical_bench.json`) records runtime environment metadata automatically, and local reference runs should document:

- **Hardware**: CPU model, physical/logical core count, RAM capacity.
- **Windows Build & Power Plan**: OS version/build (`winver` / `[System.Environment]::OSVersion`), active power plan (e.g., High Performance).
- **Toolchain Versions** (verified via `nimble doctor`):
  - Nim compiler version (e.g., `2.2.12`, `--mm:orc --threads:on --panics:on` from `nim.cfg`).
  - MinGW-W64 GCC version (e.g., `11.1.0` `x86_64-posix-seh`).
  - Vulkan loader & GPU driver version (e.g., Vulkan `1.3.x` via `tools/doctor.nim`).
- **Build Flags**: Release mode `-d:release --opt:speed` (CI & `nimble bench_canonical`).

---

## 3. Statistical Protocol

- **Warmup**: `3` unmeasured warmup iterations per discipline (`--warmup:3`) to stabilize CPU frequency, instruction cache, and Nim ORC allocator pools.
- **Measured Runs**: `15` measured iterations per discipline (`--runs:15`).
- **Reported Statistics**:
  - `min`: Fastest observed run (lower bound on hardware).
  - `p50` (median): Typical latency, resilient to OS scheduling spikes.
  - `mean`: Arithmetic average across measured runs.
  - `p95`: Tail latency (`sorted[int((n - 1) * 0.95)]`).
  - `max`: Worst observed run.
- **Cold vs. Warm Start**:
  - *Cold start* is the first `--ping` invocation (OS page-cache / font-cache cold).
  - *Warm start* aggregates subsequent `--ping` invocations in the same session.

---

## 4. Reproducing & Raw Outputs

Run locally in one command:
```powershell
nimble bench_canonical
```
Or directly with custom parameters:
```powershell
nim c -d:release --opt:speed -o:bin/canonical_bench.exe benchmarks/canonical_bench.nim
.\bin\canonical_bench.exe --headless --warmup:3 --runs:15 --json:benchmarks/results/canonical_bench.json --csv:benchmarks/results/canonical_bench.csv
```

Interactive Vulkan window mode (requires Vulkan 1.1+ GPU):
```powershell
.\bin\canonical_bench.exe --gui
```

Raw outputs are written to:
- **JSON**: `benchmarks/results/canonical_bench.json` (schema v1, includes `environment`, `config`, and `metrics[]`)
- **CSV**: `benchmarks/results/canonical_bench.csv` (`layer,name,unit,runs,min,p50,mean,p95,max,extra`)
