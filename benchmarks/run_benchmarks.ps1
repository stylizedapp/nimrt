# benchmarks/run_benchmarks.ps1 — Единый воспроизводимый скрипт сборки и запуска симметричного стенда Nim vs Rust

$ErrorActionPreference = "Stop"

Write-Host "[1/3] Compiling Nim symmetric suite (nim 2.2.12, -d:danger --mm:arc -march=native -O3 -flto)..."
nim c -d:danger --opt:speed --mm:arc --threads:on --panics:on --passC:"-march=native -O3 -flto" --passL:"-flto -s" -o:benchmarks/nim_full_suite.exe benchmarks/nim_full_suite.nim

Write-Host "[2/3] Compiling Rust symmetric suite (rustc 1.96.0, -C opt-level=3 -C target-cpu=native -C lto=fat)..."
rustc --edition=2021 -C opt-level=3 -C target-cpu=native -C codegen-units=1 -C lto=fat -C panic=abort -o benchmarks/rust_full_suite.exe benchmarks/rust_full_suite.rs

Write-Host "[3/3] Running both suites (2 Warmup + 11 Measured Runs per discipline)..."
& .\benchmarks\rust_full_suite.exe
& .\benchmarks\nim_full_suite.exe
