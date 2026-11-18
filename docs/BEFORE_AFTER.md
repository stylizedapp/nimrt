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

*(To be filled after all swarm branches are merged and verified.)*

### 2.1 Speed (Startup, Benchmarks & Binary Sizes)
- _Pending integration_

### 2.2 Safety (QuickJS, MFT & `nim_safe`)
- _Pending integration_

### 2.3 Code Clarity & Simplicity
- _Pending integration_

### 2.4 CI Test Status
- _Pending integration_
