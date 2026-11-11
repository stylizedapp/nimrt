# Package
version       = "0.1.0"
author        = "Nim High-Performance Core Ecosystem"
description   = "High-performance systems foundation and platform-isolated primitives for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

# Tasks
task test, "Run the automated ecosystem test suite":
  exec "nim c -r tests/test_ecosystem.nim"

task bench, "Run the core performance benchmark suite":
  when defined(windows):
    exec "powershell -ExecutionPolicy Bypass -File benchmarks/run_benchmarks.ps1"
  else:
    exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_full_suite.nim"

task showcase, "Run the ultra showcase comparison":
  exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_ultra_showcase.nim"

task test_wiztree, "Run WizTree engine verification test suite":
  exec "nim c -r tests/test_wiztree.nim"

task bench_wiztree, "Run WizTree engine 1M node benchmark suite":
  exec "nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/bench_wiztree.nim"

task wiztree, "Build and run WizTree CLI":
  exec "nim c -d:danger --opt:speed apps/wiztree/wiztree.nim"
