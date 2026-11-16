# Package
version       = "0.1.0"
author        = "Nim High-Performance Core Ecosystem"
description   = "High-performance systems foundation and platform-isolated primitives for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

# Tasks
task test, "Run the automated ecosystem test suite":
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
    exec "powershell -ExecutionPolicy Bypass -File benchmarks/run_benchmarks.ps1"
  else:
    exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_full_suite.nim"

task showcase, "Run the ultra showcase comparison":
  exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_ultra_showcase.nim"

task showcase_html, "Generate Nim vs Rust HTML comparison report in benchmarks/":
  exec "python benchmarks/generate_showcase.py"

task test_ui, "Run NimUI layout, widget, and Zero-JS HTML/CSS tests":
  exec "nim c -r tests/test_nimui_layout.nim"
  exec "nim c -r tests/test_nimui_widgets.nim"
  exec "nim c -r tests/test_nimui_html_css.nim"

task test_js, "Run NimUI + QuickJS hybrid engine, philosophy checks & Pomodoro tests":
  exec "nim c -r tests/test_nimui_quickjs.nim"

task test_showcase, "Run automated headless verification of all 4 showcase apps":
  exec "nim c -r tests/test_showcase_apps.nim"

task html_desktop, "Run standalone HTML5/CSS3 Desktop Renderer (Tauri alternative)":
  exec "nim c -r apps/html_desktop/src/main.nim"

task pomodoro, "Run interactive 1-3s Pomodoro Debug Timer (Nim + QuickJS + Vulkan SDF)":
  exec "nim c -r apps/html_desktop/src/main.nim --pomodoro"

task pomodoro_test, "Run headless verification of 1-3s Pomodoro Timer":
  exec "nim c -r apps/html_desktop/src/main.nim --pomodoro-test"

task build_compiler, "Build Hybrid Memory-Safe Nim Compiler (bin/nim_safe.exe)":
  exec "nim c --skipParentCfg:on -d:release -o:bin/nim_safe.exe compiler/nim_safe.nim"

task test_compiler, "Run Hybrid Memory-Safe Compiler (--mem-safe, --safe-mode, --check-safe-atf) suite":
  exec "nim c -r tests/test_safe_compiler.nim"

task studio, "Run NimUI HTML5/CSS3 Zero-JS Studio":
  exec "nim c -r apps/html_css_studio/src/main.nim"

task gallery, "Run NimUI Component, SDF & Unicode Gallery":
  exec "nim c -r apps/widget_gallery/src/main.nim"

task demo, "Run Singularity Lab Relativistic Kerr Black Hole Demo":
  exec "nim c -r apps/nimui_demo/src/main.nim"

task test_wiztree, "Run WizTree engine verification test suite":
  exec "nim c -r tests/test_wiztree.nim"

task bench_wiztree, "Run WizTree engine 1M node benchmark suite":
  exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/bench_wiztree.nim"

task wiztree, "Build and run WizTree CLI":
  exec "nim c -d:danger --opt:speed apps/wiztree/wiztree.nim"
