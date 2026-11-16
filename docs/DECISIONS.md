# Architecture Decisions Log (DECISIONS.md)

This log documents critical architectural, safety, and environment decisions made for the Nim High-Performance Core Ecosystem (`corex`, `algx`, `wiztree`).

---

## 1. 2026-11-11 — parallelFor rollback on push failure

### Context & Problem
In `src/corex/concurrency.nim`, `parallelFor` partitions loop iterations into chunked ranges and submits corresponding `Job` items either to the calling worker thread's local `WorkStealDeque` or to the pool's global injection queue. 

Before enqueuing each chunk job, the coordination primitive increments the wait count:
```nim
wgPtr.add(1)
```
If enqueuing into the local deque or injection queue fails (e.g., due to an exception during queue expansion, queue full condition, or during a concurrent pool shutdown sequence), `wgPtr` was already incremented, but the job would never be executed by any worker thread. Consequently, `wg.done()` would never be called for that abandoned chunk. When the coordinating thread subsequently invoked `wg.wait()`, it entered an indefinite sleep waiting for a counter that could never reach zero, resulting in an unrecoverable **deadlock**.

### Decision & Implementation
Inside `src/corex/concurrency/parallel.nim` (re-exported by `src/corex/concurrency.nim`), `parallelForImpl` uses `Result`-based submission (`pool.trySubmitJob(job)`) and decrements `WaitGroup` cleanly if submission returns `Err`. The outer block catches only `CatchableError` (never `Defect`, in strict compliance with the M11 zero-exception / `Defect` policy):

```nim
wgPtr.add(1)
let job = Job(fn: runChunkJob, arg: addr jobs[idx], cleanup: nil)
let subRes = pool.trySubmitJob(job)
if subRes.isErr:
  wgPtr.add(-1) # rollback: task not queued, done() will not be called
  stoppedDuringPush = true
  break
inc(pushedChunks)
...
except CatchableError:
  if pushedChunks > 0:
    wgPtr.wait()
  raise
```

### Verification & Impact
- **Reproducibility Test**: `tests/test_parallel_for_shutdown.nim` was constructed with a 5-second watchdog thread. Before the fix, shutdown races triggered `[FAIL] DEADLOCK detected (5s timeout)` (exit code 1).
- **Post-Fix Resolution**: With the rollback handler in place, all 50 rapid shutdown iterations pass cleanly in ~1.07s without deadlocks (`[PASS] 50 shutdown iterations without deadlock`).
- **Regression**: All 24 tests in `tests/test_concurrency.nim` continue to pass with 0 errors.

---

## 2. 2026-11-11 — WorkStealDeque[T] POD constraint

### Context & Problem
`WorkStealDeque[T]` (`src/corex/workstealing.nim`) implements a lock-free Chase-Lev single-producer multi-consumer work-stealing deque. To achieve extreme throughput (>50M ops/s) with zero overhead:
- The circular buffer is allocated as unmanaged raw memory (`UncheckedArray[T]`).
- Buffer growth and thief steal operations use pointer arithmetic and `copyMem`.
- Elements are moved without calling Nim ARC/ORC lifecycle hooks (`=copy`, `=sink`, `=destroy`, `=wasMoved`).

If managed types (such as `string`, `seq[T]`, `ref object`, or types containing ARC/ORC managed fields) were stored in `WorkStealDeque[T]`, memory corruption, dangling references, double-free faults, or severe memory leaks would occur.

### Decision & Implementation
Enforce a strict compile-time constraint on element type `T` in both `initWorkStealDeque*` and `newWorkStealDeque*`:

```nim
when not supportsCopyMem(T):
  {.error: "WorkStealDeque[T] requires POD (supportsCopyMem); got " & $T.}
```

`std/typetraits.supportsCopyMem` is re-exported via `src/corex/workstealing.nim`. Any attempt to instantiate `WorkStealDeque[T]` with a non-POD type (such as `string` or types with non-trivial destructors) fails at compile time with a clear, descriptive compiler diagnostic. Plain Old Data (POD) types (such as `Job`, `int`, raw pointers, value structs) continue to compile and operate at full native speed.

### Verification & Impact
- **Compile-Time Rejection**: Verified via `tests/test_workstealing_pod.nim`:
  ```nim
  static:
    doAssert not compiles(initWorkStealDeque[string](64)),
      "WorkStealDeque[string] must not compile (non-POD)"
  ```
- **Positive Compilation**: Validated that `WorkStealDeque[int]` and `WorkStealDeque[Job]` compile and operate without issue (`capacity == 64`).
- **Output**: `[PASS] POD constraint verified`.
- **Regression**: All 10 tests in `tests/test_workstealing.nim` pass cleanly.

---

## 3. 2026-11-11 — ThreadSanitizer (TSAN) Not Run on Windows/MinGW

### Context & Problem
ThreadSanitizer (TSAN / `-fsanitize=thread`) was evaluated to inspect memory race conditions and validate Acquire/Release memory fences across lock-free primitives (`Atomic[T]`, `WorkStealDeque[T]`, and `ThreadPool`).

However, the current development and verification environment runs on **Windows x64 with MinGW-w64 GCC 11.1.0**.

When attempting to compile and link with `-fsanitize=thread`:
```
$ gcc -fsanitize=thread test_tsan.c
c:/nim/dist/mingw64/bin/../lib/gcc/x86_64-w64-mingw32/11.1.0/../../../../x86_64-w64-mingw32/bin/ld.exe: cannot find -ltsan
collect2.exe: error: ld returned 1 exit status
```
MinGW-w64 does not distribute `libtsan.a` / `libtsan.dll` for Windows target ABI. ThreadSanitizer is effectively unsupported by MinGW on Windows.

### Decision & Mitigation Strategy
1. **Decision**: Formally document that ThreadSanitizer was **not run on Windows/MinGW** due to the absence of `libtsan` in the toolchain.
2. **Mitigation**: Multi-threaded safety and race freedom are rigorously verified through:
   - **Formal Memory Model**: Implementation conforms to Chase & Lev (2005) and Le et al. (2013) memory fences (`atomicFence(moRelease)`, `atomicFence(moSeqCst)`, `atomicCompareExchange(..., moSeqCst, moAcquire)`).
   - **High-Contention Stress Harnesses**:
     - `tests/test_concurrency.nim`: 24 test suites covering atomics, spinlocks, rwlocks, barriers, queues, and thread pool.
     - `tests/test_workstealing.nim`: 10 test suites including multi-thief concurrent stealing (100,000 items across multiple threads), 8-thief rapid churn, and single-element contention.
     - `tests/test_parallel_for_shutdown.nim`: 50 rapid shutdown iterations under heavy contention with an aggressive 5-second watchdog timer.
   - **Zero-Defect ORC Cleanliness**: All test suites compile with `--mm:orc --threads:on --panics:on -d:danger` and exit with returncode 0 with 0 memory leaks.
   - **Future CI Target**: Execution of TSAN will be integrated into Linux/Clang or WSL CI pipelines where LLVM compiler-rt TSAN runtime is natively supported.

---

## 4. 2026-11-16 — v0.1.0 Scope: Windows-First, Optional QuickJS Hybrid, and `nim_safe`

### Context & Problem
During v0.1.0 stabilization, several documentation discrepancies were identified:
- `README.md` previously described the ecosystem as strictly "without JavaScript" while simultaneously documenting `src/nimui/js/` (QuickJS) and `compiler/nim_safe.nim`.
- Cross-platform support was implied broadly even though `async.nim` (IOCP), `mft.nim` (`win32_mft`), `nimui/window.nim` (Win32), and CI target **Windows**, while `posix_fs.nim` is unverified in CI.

### Decision & Scope
1. **Include QuickJS hybrid + `nim_safe` in v0.1.0**: `html_css` remains Zero-JS by default (`allowJs = false`), with an explicit opt-in sandboxed QuickJS runtime (`allowJs = true`, capability-gated via `<script data-caps="...">`, memory/stack/step budgets, routed through `corex/allocators.Allocator`), and `compiler/nim_safe` (`--mem-safe`, `--safe-mode`, `--check-safe-atf`) is included as an experimental safety checker/wrapper.
2. **HTML5/CSS3 accuracy**: Document `html_css` as a practical HTML/CSS subset + optional sandboxed QuickJS hybrid, rather than full browser HTML5/CSS3.
3. **Windows-first support**: Explicitly mark v0.1.0 as **Windows-first** (Windows 10/11 x64 + Vulkan 1.1+); keep Linux/macOS support and `posix_fs.nim` CI verification in the backlog.

---

## 5. 2026-11-16 — Honest Safety, Leak Accounting, and Benchmark Methodology

### Context & Problem
- High-level claims such as "memory-safe like Rust" obscured the fact that `corex`/`algx`/`nimui` encapsulate low-level `cast`, `ptr`, `importc`, and release-only `{.push checks: off.}` inside internal modules.
- `TrackingAllocator` only accounts for allocations routed through `corex/allocators.Allocator`, not standard Nim ORC heap objects (`seq`, `string`, `ref`).
- `benchmarks/run_benchmarks.ps1` compiled Nim with `--mm:arc`, whereas `nim.cfg` sets `--mm:orc` across the project.
- Legacy M14 benchmark numbers (`0.020 ms` / `50,000 FPS` and `68 KB` working set) conflated `buildDrawInstances` CPU build time with GPU+present FPS and `EmptyWorkingSet()`-trimmed headless memory with interactive Vulkan Process Working Set.

### Decision
1. **Safety wording**: Document the project as providing a safe high-level API surface over an explicit low-level core (`cast`/`ptr`/`importc`, release `{.push checks: off.}` in `algx`), experimentally checked with `nim_safe`.
2. **Leak accounting**: Document that `TrackingAllocator` verifies `corex` allocator balance (`0 bytes leaked`), while ORC heap (`seq`/`string`/`ref`) is verified separately via `GC_fullCollect()` + `getOccupiedMem()`.
3. **Benchmarks**: Standardize `benchmarks/run_benchmarks.ps1` on `--mm:orc` (matching `nim.cfg`), and report single-machine specs, MinGW GCC vs Rust MSVC toolchain differences, allocator page-fault effects, and variance caveats in `docs/BENCHMARK_SHOWCASE.md`.
4. **M14 metrics**: Relabel `0.020 ms` as CPU `buildDrawInstances` build time (and ~50,000 instance-builds/s theoretical CPU rate) and `68 KB` as legacy trimmed headless RAM (`EmptyWorkingSet()`), separate from interactive Singularity Lab Vulkan working set (`~5 MB` trimmed / full driver working set).
