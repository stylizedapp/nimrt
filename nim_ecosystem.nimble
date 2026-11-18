# Package
version       = "0.3.0"
author        = "sanalyny"
description   = "High-performance systems foundation and platform-isolated primitives for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

# External Tools (documented per task):
# - gcc / ar (MinGW-W64): Required for Nim C backend and `tools/build_quickjs.ps1`
# - powershell: Required on Windows for `build_quickjs` and `bench`
# - python: Required for `showcase_html` (`benchmarks/generate_showcase.py`)
# - glslangValidator (optional, tools/glslang/): Only needed if regenerating `tools/shaders/*.spv`;
#   precompiled `.spv` binaries and `src/nimui/gpu/shaders.nim` are checked in.

proc ensureQuickJs() =
  when defined(windows):
    if not fileExists("src/nimui/js/libquickjs.a"):
      echo "[first-run] src/nimui/js/libquickjs.a not found; building QuickJS static library..."
      exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"

# Tasks
task doctor, "Check Nim, GCC/MinGW, Vulkan driver, QuickJS, fonts, permissions, and cache":
  exec "nim c -r tools/doctor.nim"

task bench_canonical, "Build and run canonical UI + CoreX/AlgX benchmark in release headless mode":
  ensureQuickJs()
  exec "nim c -d:release --opt:speed --nimcache:nimcache/canonical_bench -o:bin/canonical_bench.exe benchmarks/canonical_bench.nim"
  exec (when defined(windows): "bin\\canonical_bench.exe --headless" else: "./bin/canonical_bench.exe --headless")
task build_quickjs, "Build embedded QuickJS static library (requires PowerShell + gcc/ar)":
  echo "[tool] Building src/nimui/js/libquickjs.a via PowerShell + MinGW gcc/ar..."
  exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"

task build_shaders, "Regenerate src/nimui/gpu/shaders.nim from tools/shaders/*.spv (requires glslangValidator if editing GLSL)":
  echo "[tool] Converting tools/shaders/*.spv -> src/nimui/gpu/shaders.nim (edit .spv via glslangValidator first if GLSL changed)..."
  exec "nim c -r tools/spv_to_nim.nim"

task test, "Run the automated core ecosystem test suite":
  exec "nim c -r tests/test_ecosystem.nim"
  exec "nim c -r tests/test_workstealing.nim"
  exec "nim c -r tests/test_ironclad_bitops.nim"
  exec "nim c -r tests/test_ironclad_heap.nim"
  exec "nim c -r tests/test_ironclad_map_stress.nim"
  exec "nim c -r tests/test_ironclad_unicode.nim"
  exec "nim c -r tests/test_ironclad_mft.nim"
  exec "nim c -r tests/test_ironclad_async_iocp.nim"
  exec "nim c -r tests/test_ironclad_signals.nim"

task test_signals, "Run Ironclad Signals reactive engine test suite":
  exec "nim c -r tests/test_ironclad_signals.nim"

task test_mft, "Run Ironclad MFT parser & fixup test suite":
  exec "nim c -r tests/test_ironclad_mft.nim"

task test_async, "Run Ironclad IOCP async & reactor concurrency test suite":
  exec "nim c -r tests/test_ironclad_async_iocp.nim"

task bench, "Run the core performance benchmark suite":
  when defined(windows):
    echo "[tool] Running benchmarks via PowerShell..."
    exec "powershell -ExecutionPolicy Bypass -File benchmarks/run_benchmarks.ps1"
  else:
    exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_full_suite.nim"

task showcase, "Run the ultra showcase comparison":
  exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_ultra_showcase.nim"

task showcase_html, "Generate Nim vs Rust HTML comparison report in benchmarks/ (requires Python)":
  echo "[tool] Generating HTML showcase via Python (benchmarks/generate_showcase.py)..."
  exec "python benchmarks/generate_showcase.py"

task test_ui, "Run NimUI layout, widget, and Zero-JS HTML/CSS tests":
  when defined(windows):
    if not fileExists("src/nimui/js/libquickjs.a"):
      exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"
  exec "nim c -r tests/test_nimui_layout.nim"
  exec "nim c -r tests/test_nimui_widgets.nim"
  exec "nim c -r tests/test_nimui_html_css.nim"
  exec "nim c -r tests/test_nimui_vulkan_fallback.nim"
  exec "nim c -r tests/test_nimui_manifest_golden.nim"
  exec "nim c -r tests/test_nimui_layout_snapshots.nim"

task test_js, "Run NimUI + QuickJS hybrid engine, philosophy checks & Pomodoro tests":
  when defined(windows):
    if not fileExists("src/nimui/js/libquickjs.a"):
      exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"
  exec "nim c -r tests/test_nimui_quickjs.nim"

task test_showcase, "Run automated headless verification of all 4 showcase apps":
  when defined(windows):
    if not fileExists("src/nimui/js/libquickjs.a"):
      exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"
  exec "nim c -r tests/test_showcase_apps.nim"

task html_desktop, "Run standalone HTML5/CSS3 Desktop Renderer (Tauri alternative)":
  ensureQuickJs()
  exec "nim c -r apps/html_desktop/src/main.nim"

task pomodoro, "Run interactive 1-3s Pomodoro Debug Timer (Nim + QuickJS + Vulkan SDF)":
  ensureQuickJs()
  exec "nim c -r apps/html_desktop/src/main.nim --pomodoro"

task pomodoro_test, "Run headless verification of 1-3s Pomodoro Timer":
  ensureQuickJs()
  exec "nim c -r apps/html_desktop/src/main.nim --pomodoro-test"

task build_compiler, "Build Hybrid Memory-Safe Nim Compiler (bin/nim_safe.exe)":
  exec "nim c --skipParentCfg:on -d:release -o:bin/nim_safe.exe compiler/nim_safe.nim"

task test_compiler, "Run Hybrid Memory-Safe Compiler (--mem-safe, --safe-mode, --check-safe-atf) suite":
  if not fileExists("bin/nim_safe.exe"):
    exec "nim c --skipParentCfg:on -d:release -o:bin/nim_safe.exe compiler/nim_safe.nim"
  exec "nim c -r tests/test_safe_compiler.nim"

task studio, "Run NimUI HTML5/CSS3 Zero-JS Studio":
  ensureQuickJs()
  exec "nim c -r apps/html_css_studio/src/main.nim"

task gallery, "Run NimUI Component, SDF & Unicode Gallery":
  ensureQuickJs()
  exec "nim c -r apps/widget_gallery/src/main.nim"

task demo, "Run Singularity Lab Relativistic Kerr Black Hole Demo":
  ensureQuickJs()
  exec "nim c -r apps/nimui_demo/src/main.nim"

task test_wiztree, "Run WizTree engine verification test suite":
  exec "nim c -r tests/test_wiztree.nim"

task bench_wiztree, "Run WizTree engine 1M node benchmark suite":
  exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/bench_wiztree.nim"

task wiztree, "Build and run WizTree CLI":
  exec "nim c -d:danger --opt:speed apps/wiztree/wiztree.nim"

task test_stress, "Run adversarial I/O and filesystem walk stress tests":
  exec "nim c -r tests/stress_m5_io.nim"
  exec "nim c -r tests/stress_walkdir.nim"

task build_release, "Build release binaries (html_desktop, wiztree, widget_gallery, nim_safe) into bin/":
  when defined(windows):
    if not fileExists("src/nimui/js/libquickjs.a"):
      exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"
  exec "nim c -d:release --opt:speed --nimcache:nimcache/rel_html_desktop -o:bin/html_desktop.exe apps/html_desktop/src/main.nim"
  exec "nim c -d:release --opt:speed --nimcache:nimcache/rel_wiztree -o:bin/wiztree.exe apps/wiztree/wiztree.nim"
  exec "nim c -d:release --opt:speed --nimcache:nimcache/rel_widget_gallery -o:bin/widget_gallery.exe apps/widget_gallery/src/main.nim"
  exec "nim c --skipParentCfg:on -d:release --nimcache:nimcache/rel_nim_safe -o:bin/nim_safe.exe compiler/nim_safe.nim"

task test_all, "Run ALL ecosystem, UI, QuickJS, showcase, compiler, and disconnected tests":
  # Core ecosystem suite (`nimble test`)
  exec "nim c -r tests/test_ecosystem.nim"
  exec "nim c -r tests/test_workstealing.nim"
  exec "nim c -r tests/test_ironclad_bitops.nim"
  exec "nim c -r tests/test_ironclad_heap.nim"
  exec "nim c -r tests/test_ironclad_map_stress.nim"
  exec "nim c -r tests/test_ironclad_unicode.nim"
  exec "nim c -r tests/test_ironclad_mft.nim"
  exec "nim c -r tests/test_ironclad_async_iocp.nim"
  exec "nim c -r tests/test_ironclad_signals.nim"

  # CoreX / AlgX / Win32 / M5 / Workstealing unit & stress tests
  exec "nim c -d:release -r tests/test_concurrency.nim"
  exec "nim c -r tests/test_slab.nim"
  exec "nim c -r tests/test_stringarena.nim"
  exec "nim c -r tests/test_smallvec.nim"
  exec "nim c -r tests/test_bufmap.nim"
  exec "nim c -r tests/test_arc.nim"
  exec "nim c -r tests/test_interner.nim"
  exec "nim c -r tests/test_win32_mft.nim"
  exec "nim c -r tests/test_adversarial_m5.nim"
  exec "nim c -r tests/test_diagnostic.nim"
  exec "nim c -r tests/test_m5_verification.nim"
  exec "nim c -r tests/test_parallel_for_shutdown.nim"
  exec "nim c -r tests/test_volume.nim"
  exec "nim c -r tests/test_workstealing_pod.nim"

  # Everything-Nim & WizTree tests
  exec "nim c -r tests/test_cli.nim"
  exec "nim c -r tests/test_glob.nim"
  exec "nim c -r tests/test_gui_headless.nim"
  exec "nim c -r tests/test_indexer.nim"
  exec "nim c -r tests/test_search.nim"
  exec "nim c -d:release -r tests/test_search_speed.nim"
  exec "nim c -r tests/test_usn_sync.nim"
  exec "nim c -r tests/test_wiztree.nim"
  exec "nim c -r tests/test_types_verification.nim"

  # NimUI, QuickJS, Showcase & Safe Compiler suites
  when defined(windows):
    if not fileExists("src/nimui/js/libquickjs.a"):
      exec "powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1"
  exec "nim c -r tests/test_nimui_layout.nim"
  exec "nim c -r tests/test_nimui_widgets.nim"
  exec "nim c -r tests/test_nimui_html_css.nim"
  exec "nim c -r tests/test_nimui_vulkan_fallback.nim"
  exec "nim c -r tests/test_nimui_manifest_golden.nim"
  exec "nim c -r tests/test_nimui_layout_snapshots.nim"
  exec "nim c -r tests/test_nimui_quickjs.nim"
  exec "nim c -r tests/test_fuzz_mft.nim"
  exec "nim c -r tests/test_fuzz_html_css.nim"
  exec "nim c -r tests/test_showcase_apps.nim"
  if not fileExists("bin/nim_safe.exe"):
    exec "nim c --skipParentCfg:on -d:release -o:bin/nim_safe.exe compiler/nim_safe.nim"
  exec "nim c -r tests/test_safe_compiler.nim"
