# Baseline & Before/After Comparison (`До` / `После`)

Baseline captured on branch `swarm-baseline-91204ea7` (base commit `fc9486b`) **before** any swarm feature edits.

- **Environment**: Windows (amd64), Nim `2.2.12` (`--mm:orc --threads:on --panics:on`), MinGW-W64 GCC `11.1.0`, Nimble `v0.24.1`

---

## 1. До (Before) — Baseline State

### 1.1 Speed: Startup, Benchmarks & Binary Sizes

#### Release Binary Sizes (`nimble build_release` + `tools/build_quickjs.ps1`)
| Artifact | Size (bytes) | Size (human) |
|---|---:|---:|
| `bin/wiztree.exe` | 475,844 | ~464.7 KiB |
| `bin/widget_gallery.exe` | 717,689 | ~700.9 KiB |
| `bin/html_desktop.exe` | 2,051,226 | ~1.96 MiB |
| `bin/nim_safe.exe` | 8,704,726 | ~8.30 MiB |
| `src/nimui/js/libquickjs.a` | 1,129,964 | ~1.08 MiB |

#### CLI Startup Latency (`Measure-Command`)
- `bin/wiztree.exe --help`: cold `413.97 ms`; warm (3 runs): `249.03 ms`, `53.34 ms`, `173.04 ms`
- `bin/nim_safe.exe --version`: `1,177.19 ms`

#### Symmetric CoreX/AlgX vs Rust Benchmark (`nimble bench`, `-d:danger --mm:orc -march=native -O3 -flto`, 2 warmup + 11 runs)
| Benchmark | Nim (`corex` + `algx`) Min / Med / Mean / Max (ms) | Rust `1.96.0` (LTO=fat, native) Med (ms) |
|---|---|---|
| `UltraSort` (10M `int64`, 4T) | `87.23 / 98.55 / 100.11 / 131.00` | `111.38` |
| `FastMap` SplitMix64 (3M ops) | `185.86 / 203.99 / 206.74 / 239.10` | `158.72` (`std::HashMap`) / `188.64` (`RustFastMap`) |
| `ZeroPack POD` (2M × 32B = 64MB) | `13.30 / 14.34 / 14.31 / 14.88` | `57.01` |
| `SimdScan 8-Way` (25M `int64`) | `44.91 / 47.73 / 49.24 / 56.11` | `53.50` |

#### WizTree 1M-Node Benchmark (`nimble bench_wiztree`)
- 500,000-node ingestion: `358.77 ms` (`1.39 M nodes/s`, `30.5 MB`)
- **Failure**: Crashes with `SIGSEGV: Illegal storage access` before completing the 1,000,000-node phase.

---

### 1.2 Safety: QuickJS, MFT & `nim_safe`

- **QuickJS (`src/nimui/js/`)**:
  - `allowJs = false` by default (Zero-JS mode).
  - `tests/test_nimui_quickjs.nim` passes 4/4 suites (`js_validator` static checks, `TrackingAllocator` bridge, 30-cycle stress, Pomodoro).
  - *Gaps at baseline*: No C-level `qjs_harden_context` disabling `eval`/`Function`/`Proxy`/`Reflect` or dynamic `import()`, no separated `storage`/`network`/`fs`/`process` capability enforcement, no structured audit log.
- **NTFS MFT (`src/corex/mft.nim`, `src/corex/platform/windows/win32_mft.nim`)**:
  - `tests/test_win32_mft.nim`, `tests/test_ironclad_mft.nim`, and `tests/test_fuzz_mft.nim` (100,000 inputs) pass with 0 leaks.
  - *Gaps at baseline*: No explicit `mpmStrict` parsing mode or `explicitConsent` parameter on raw volume MFT streaming.
- **`nim_safe` (`compiler/`)**:
  - `tests/test_safe_compiler.nim` passes 5/5 suites (`--mem-safe` `MEM-SAFE-001..007`, `--safe-mode` `SAFE-MODE-001..003`, `--check-safe-atf` `ATF-001..005`, `{.trustedUnsafe.}`).
  - *Gaps at baseline*: No explicit FFI/external C/unsafe-import rejection (`MEM-SAFE-008`) or bypass test suite for `importc`/`dynlib`/`header` pragmas.
- **Leak Verification**: `tests/test_leak_check.nim` passes (negative `TrackingAllocator` + ORC leak triggers and positive 0-leak check).

---

### 1.3 Codebase Structure, Clarity & Simplicity

| Directory | Files | Lines of Code | Notes |
|---|---:|---:|---|
| `src/corex` | 32 | 10,100 | Allocators, concurrency/workstealing, IOCP async, MFT, signals, Win32/POSIX platform layers |
| `src/algx` | 6 | 1,092 | `ultrasort`, `swissmap`, `zeropack`, `simdscan`, `heap`, `algx` |
| `src/nimui` | 27 | 13,298 | Layout, controls, HTML/CSS subset, Vulkan 1.1+ backend, CPU rasterizer, QuickJS bridge (excluding vendored C) |
| `compiler` | 6 | 1,819 | `nim_safe` compiler & ATF C checker |
| `apps` | 33 | 10,904 | `wiztree`, `everything`, `html_desktop`, `html_css_studio`, `widget_gallery`, `nimui_demo`, `mini-browser` |
| `tests` | 65 | 12,638 | Unit, stress, fuzz, headless UI, QuickJS, and `nim_safe` tests + fixtures |

- **Clarity & Warnings**:
  - `nim check` with strict flags (`--warningAsError[UnusedImport]:on --hintAsError[XDeclaredButNotUsed]:on`) passes with 0 errors on `src/corex.nim`, `src/algx.nim`, and `src/nimui.nim`.
  - `nim doc --project` exits 0 on all 3 root facades, with `[BrokenLink]` doc warnings in `corex` and `nimui`.
  - `nim check --os:linux --cpu:amd64 src/corex.nim` exits 0 with 7 `[UnusedImport]` warnings (`src/corex/async.nim` lines 14–19, `src/corex/mft.nim` line 15).
  - `apps/wiztree/cli.nim` and several test files emit `[UnusedImport]` warnings.
  - No canonical UI/app benchmark suite or `nimble doctor` onboarding check exists at baseline.

---

### 1.4 CI Test Status (`.github/workflows/ci.yml` & Item 16 Diagnosis)

Local verification of all 3 jobs defined in `.github/workflows/ci.yml`:

| CI Job | Checks Run Locally | Result |
|---|---|---|
| `test` (`Build & Test (Windows)`) | `tools/build_quickjs.ps1`, `nimble build_compiler`, `nimble build_release`, `nimble test_all` (all 37 targets incl. `test_ui`, `test_js`, `test_showcase`, `test_compiler`), `algxChecked` (4 targets) | **PASS** (exit 0) |
| `strict-warnings` (`Strict Warnings, Nimble Check & Docs`) | `nimble check`, `nim check @strictFlags` (`corex`, `algx`, `nimui`), `nim doc --project` (`corex`, `algx`, `nimui`) | **PASS** (exit 0) |
| `ubuntu` (`Ubuntu Portability Check`) | `nim check --os:linux --cpu:amd64 src/corex.nim`, `src/algx.nim` | **PASS** (exit 0) |

**Item 16 Diagnosis**:
- On `main` at `fc9486b`, all 3 CI jobs in `.github/workflows/ci.yml` pass locally. Prior commits `87118fa` (GCC 14 `ptr culong` Win32 parameters) and `764bc7f` (elevated Admin runner handling in `tests/test_cli.nim`) already resolved the Windows CI failures on `main`.
- Separate from `.github/workflows/ci.yml`, `nimble bench_wiztree` fails with a `SIGSEGV` after 500k-node ingestion.

---

## 2. После (After) — Post-Swarm Integration State

Verified on `main` at `108c07a` after merging all 5 feature branches (`product-sdk`, `security`, `bench-dx`, `baseline`, `ui-gfx`).

### 2.1 Speed (Startup, Benchmarks & Binary Sizes)

#### Release Binary Sizes (`nimble build_release` + `nimble bench_canonical`)
| Artifact | Size (bytes) | Size (human) | Delta vs До |
|---|---:|---:|---:|
| `bin/wiztree.exe` | 475,844 | ~464.7 KiB | 0 B |
| `bin/widget_gallery.exe` | 726,096 | ~709.1 KiB | +8,407 B |
| `bin/canonical_bench.exe` | 977,540 | ~954.6 KiB | *(new)* |
| `bin/html_desktop.exe` | 2,086,743 | ~1.99 MiB | +35,517 B |
| `bin/nim_safe.exe` | 8,652,943 | ~8.25 MiB | -51,783 B |
| `src/nimui/js/libquickjs.a` | 1,132,028 | ~1.08 MiB | +2,064 B |

#### CLI Startup Latency (`Measure-Command`)
- `bin/wiztree.exe --help`: cold `243.66 ms`; warm `22.14 ms`
- `bin/nim_safe.exe --version`: `1,079.09 ms`

#### Canonical Headless Benchmark (`nimble bench_canonical`, `-d:release --opt:speed`, 3 warmup + 15 runs, 4 CPUs)
Results saved to `benchmarks/results/canonical_bench.json` and `benchmarks/results/canonical_bench.csv`:

| Layer | Metric | Min | p50 | p95 | Unit |
|---|---|---:|---:|---:|---|
| `corex_algx` | `algx_ultrasort_1m` | 16.00 | 76.30 | 145.04 | ms |
| `corex_algx` | `algx_swissmap_300k` | 18.21 | 20.97 | 26.71 | ms |
| `corex_algx` | `corex_signals_10k` | 3.01 | 3.17 | 5.68 | ms |
| `corex_algx` | `corex_arena_alloc_100k` | 0.45 | 0.58 | 1.03 | ms |
| `ui_engine` | `ui_minimal_layout_draw` (179 inst) | 0.019 | 0.019 | 0.019 | ms |
| `ui_engine` | `ui_table_200x6_layout_draw` (747 inst) | 0.677 | 0.722 | 1.260 | ms |
| `ui_engine` | `ui_forms_reactive_layout_draw` (149 inst) | 0.024 | 0.025 | 0.026 | ms |
| `ui_engine` | `ui_virtuallist_100k_scroll` (829 inst) | 0.090 | 0.092 | 0.093 | ms |
| `ui_engine` | `ui_html_css_mount` | 0.257 | 0.296 | 0.796 | ms |
| `ui_engine` | `ui_software_sdf_raster_1280x720` (988 inst) | 66.83 | 95.44 | 110.12 | ms |
| `full_app` | `app_cold_start_ms` | 203.43 | 203.43 | 203.43 | ms |
| `full_app` | `app_warm_start_ms` | 204.91 | 214.18 | 214.18 | ms |
| `full_app` | `app_e2e_frame_headless_ms` (1280×720, 987 inst) | 79.75 | 121.80 | 151.53 | ms |
| `full_app` | `app_rss_current_bytes` / `app_rss_peak_bytes` | — | 33,742,848 / 33,746,944 | — | bytes (~32.2 MiB) |

### 2.2 Safety (QuickJS, MFT, `nim_safe` & Component SDK)
- **QuickJS (`src/nimui/js/`)**: `tests/test_nimui_quickjs.nim` passes all 5 suites including Suite 5 (`5.1 Bypass prevention, capability separation & audit log verified`, `5.2 HtmlJsSession fail-closed host capabilities & audit verified`) with 0 leaks.
- **NTFS MFT (`src/corex/mft.nim`, `src/corex/platform/windows/win32_mft.nim`)**: `tests/test_win32_mft.nim`, `tests/test_ironclad_mft.nim`, and `tests/test_fuzz_mft.nim` (100,000 deterministic fuzz cases: 0 panics, 0 crashes, 0 OOBs) pass; `mpmStrict` and `explicitConsent` modes integrated.
- **`nim_safe` (`compiler/`)**: `tests/test_safe_compiler.nim` passes 5/5 suites (`--mem-safe` `MEM-SAFE-001..008`, 14 AST/borrow/FFI/pointer-arithmetic rejection checks, `--safe-mode` `SAFE-MODE-001..003`, `--check-safe-atf` `ATF-001..005`, `{.trustedUnsafe.}`).
- **Component SDK (`tests/test_component_sdk.nim`)**: Passes 4/4 suites (Permissions & Audit Log, Third-Party Block Contract & SemVer Compatibility, 11 Minimal UI Blocks + Flexbox Layout, 6 System Blocks: HTTP, JSON, SQLite, CSV, LocalStorage, Shell) with 0 leaks.

### 2.3 Code Clarity & Simplicity

| Directory | `.nim` Files | Lines of Code | Delta vs До |
|---|---:|---:|---|
| `src/corex` | 32 | 11,890 | +1,790 LOC |
| `src/algx` | 6 | 1,256 | +164 LOC |
| `src/nimui` *(excl. vendored QuickJS C)* | 32 | 16,386 | +5 files, +3,088 LOC |
| `compiler` | 7 | 2,066 | +1 file, +247 LOC |
| `apps` | 33 | 12,330 | +1,426 LOC |
| `tests` | 74 | 15,860 | +9 files, +3,222 LOC |

- **Diagnostics & Strict Checks**:
  - `nimble doctor`: `9 OK, 0 WARN, 0 FAIL` (Nim `2.2.12`, Nimble `v0.24.1`, MinGW-W64 GCC `11.1.0`, Vulkan `1.3.250` / `1.3.260`, QuickJS static lib, system fonts, workspace permissions, nimcache).
  - `nimble check`: valid (`nim_ecosystem`).
  - `nim check` with `--warningAsError[UnusedImport]:on --hintAsError[XDeclaredButNotUsed]:on`: 0 errors on `src/corex.nim`, `src/algx.nim`, `src/nimui.nim`.
  - `nim check --os:linux --cpu:amd64`: exits 0 on `src/corex.nim` (7 `[UnusedImport]` warnings in `async.nim` / `mft.nim`) and `src/algx.nim` (0 warnings).
  - `nimble test_ui`: passes all 6 suites (layout, widgets, HTML5/CSS3, Vulkan fallback diagnostics, HTML/CSS manifest & golden snapshots, layout reliability & framebuffer hash snapshots) with 0 leaks.

### 2.4 Verification & CI Status on `main`
| Command / Suite | Scope | Result |
|---|---|---|
| `nimble check` | Package manifest & dependency validation | **PASS** |
| `nimble doctor` | Environment & toolchain first-run diagnostics | **PASS** (`9 OK, 0 WARN, 0 FAIL`) |
| `nimble build_release` | `html_desktop`, `wiztree`, `widget_gallery`, `nim_safe` | **PASS** |
| `nimble bench_canonical` | 16 canonical metrics (CoreX/AlgX, UI engine, full app) | **PASS** |
| `nimble test_ui` | 6 NimUI suites (layout, widgets, HTML/CSS, Vulkan fallback, manifest/golden, snapshots) | **PASS** (0 leaks) |
| `nim c -r tests/test_component_sdk.nim` | 4 Component SDK suites (11 UI + 6 system blocks) | **PASS** (0 leaks) |
| `nimble test_all` | All 40 test targets (CoreX, AlgX, Everything, WizTree, UI, QuickJS, 100k MFT & HTML/CSS fuzzers, 4 showcase apps / 9 PNGs, `nim_safe`) | **PASS** (exit 0) |
