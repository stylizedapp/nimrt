# Project: Nim High-Performance Core Ecosystem

## Architecture & Boundary Invariants
The Nim High-Performance Core Ecosystem provides a zero-overhead, memory-safe, cross-platform systems foundation engineered for extreme throughput and low latency.

### Strict Architectural Rule: Pure Runtime in `src/`
To maintain documentation and structural integrity, the project strictly enforces:
- **`src/`**: Strictly reserved for foundational systems runtime modules (`corex`, `algx`, and future `netx`). Application code, CLI binaries, and end-user tools must never be added to `src/`.
- **`apps/`**: Downstream applications, CLI tools, and production case studies (e.g. `apps/wiztree`).
- **`tools/`**: Developer scaffolding, utilities, and build scripts.
- **`tests/`**: Automated test suites and leak verification harnesses.
- **`benchmarks/`**: High-performance micro-benchmarks and hardware saturation suites.

The runtime itself is structured into three decoupled layers:

1. **`corex` (Foundational Primitives)**:
   - `corex/allocators`: Pluggable memory allocators (`Allocator` vtable, `FixedBufferAllocator`, `ArenaAllocator`, `PoolAllocator`, `PageAllocator`, `TrackingAllocator`).
   - `corex/memory`: Zero-cost memory safety abstractions (`Span[T]`, `ByteSpan`, `Owned[T]` single-ownership RAII pointer).
   - `corex/result`: Monadic `Result[T, E]`, early return `?`, assertive unwrapping (`unwrap`, `unwrapErr`), and Zig-style `errdefer`.
   - `corex/adt`: Tagged union macro (`sumType`), pattern matching (`match`), and built-in `Option[T]` (`Some`/`None`).
   - `corex/concurrency`: Lock-free and low-overhead thread synchronization (`Atomic[T]`, `SpinLock`, `SysLock`, `RwLock`, `withLock` guards, `Barrier`, `WaitGroup`, `SpscQueue`, `MpmcQueue`, `ThreadPool`).
   - `corex/containers`: Explicit allocator containers (`BufSeq[T]`, `BufStr`) with full ARC/ORC lifecycle hooks (`=destroy`, `=copy`, `=sink`) and element cleanup.
   - `corex/io`: RAII `FileHandle`, `BufferedReader`, `BufferedWriter` with auto-flush on destruction.
   - `corex/fs`: High-level cross-platform filesystem interface (`FileStat`, `DirEntry`, `VolumeInfo`, `walkDirFast`).
   - `corex/traits`: Fat-pointer polymorphism macro (`Dyn[Trait]`).
   - `corex/testing`: Property-based testing (`quickCheck`), benchmarking (`bench`), and zero-leak verifier (`testWithLeakCheck`).

2. **`sysx` / `platform` (Platform Isolation Layer)**:
   - `corex/platform/windows/win32_fs`: High-speed directory enumeration via `FindFirstFileExW` (`FindExInfoBasic`, `FIND_FIRST_EX_LARGE_FETCH`), cluster geometry calculation ("Size on Disk"), and direct MFT/USN Journal streaming (`FSCTL_ENUM_USN_DATA`) for downstream WizTree-scale workloads.
   - `corex/platform/posix/posix_fs`: Clean POSIX fallback using `opendir`/`readdir_r` and `statvfs`.

3. **`algx` (High-Throughput Algorithms)**:
   - `algx/ultrasort`: Multi-threaded MSD Radix + L1 Insertion hybrid sort.
   - `algx/swissmap`: SwissTable-style `FastMap[K, V]` flat hash table.
   - `algx/zeropack`: POD zero-copy binary serialization and zero-DOM JSON stringifier.
   - `algx/simdscan`: 8-way unrolled superscalar analytics.

---

## Feature Inventory

Every feature from the Phase 0 Survey is cataloged below with its assigned milestone:

| # | Feature | Description | Milestone | Source | Status |
|---|---------|-------------|-----------|--------|--------|
| 1 | Ecosystem Manifest (`MANIFEST.md`) | Developer manifesto detailing 3D chess systems philosophy, cache locality, zero-allocation OS interop, deterministic ARC/ORC lifetimes, and concurrency vs syntax sugar | M1 | R1 Spec | DONE |
| 2 | Root Compiler Config (`nim.cfg`) | Root compiler configuration enabling `--path:"src"`, `--mm:orc`, `--threads:on`, `--panics:on` for seamless imports | M1 | Survey (E3) | DONE |
| 3 | Ecosystem Package Manifest (`nim_ecosystem.nimble`) | Package manifest defining package metadata and tasks (`test`, `bench`, `showcase`) | M1 | Survey (E3) | DONE |
| 4 | Root Package Facades (`src/corex.nim`, `src/algx.nim`) | Root forwarding modules ensuring top-level `import corex` and `import algx` resolve cleanly | M1 | Survey (E1/E3) | DONE |
| 5 | Allocator VTable & AllocError | Polymorphic `Allocator` record (`allocFn`, `freeFn`, `resetFn`) and error codes | M2 | Observed / R2 | DONE |
| 6 | FixedBufferAllocator | Bump allocator on static or stack-allocated buffers with alignment handling | M2 | Observed / R2 | DONE |
| 7 | ArenaAllocator | Linear region allocator on shared heap memory with O(1) bulk reset | M2 | Observed / R2 | DONE |
| 8 | PoolAllocator | Fixed-size chunk allocator with intrusive free-list for O(1) uniform node allocations | M2 | R2 Spec | DONE |
| 9 | PageAllocator | Virtual memory page-aligned allocator (`VirtualAlloc` on Windows) for large buffers | M2 | R2 Spec | DONE |
| 10 | TrackingAllocator | Memory leak tracker tracking active/peak allocations, active bytes, and reporting leaks | M2 | Observed / R4 | DONE |
| 11 | Allocator Destroy with Destructor | Fix `destroy[T]` in `allocators.nim` to invoke `=destroy(p[])` before freeing memory | M2 | Survey (E1) | DONE |
| 12 | Span[T] Non-Owning View | Contiguous slice view with bounds-checked indexing, slicing, and zero overhead | M2 | R2 Spec | DONE |
| 13 | ByteSpan | Specialized byte slice view with binary parsing and zero-copy POD casting | M2 | R2 Spec | DONE |
| 14 | Owned[T] Smart Pointer | Single-ownership RAII pointer with `=destroy`, `=sink`, and disabled `=copy` | M2 | R2 Spec | DONE |
| 15 | BufSeq[T] ARC/ORC Lifecycle Hooks | Fix `BufSeq[T]` in `containers.nim` by adding `=destroy`, `=copy`, `=sink` and element cleanup | M2 | Survey (E1/R4) | DONE |
| 16 | BufStr ARC/ORC Lifecycle Hooks | Fix `BufStr` in `containers.nim` with explicit allocator support and lifecycle hooks | M2 | Survey (E1/R4) | DONE |
| 17 | Result[T, E] Core Type | Flat tagged union for zero-overhead error propagation without exceptions | M3 | Observed / R2 | DONE |
| 18 | Monadic Chaining (`flatMap`, `andThen`, `orElse`, `mapError`) | Functional pipeline combinators for `Result[T, E]` transformations | M3 | R2 Spec | DONE |
| 19 | Assertive Unwrapping (`unwrap`, `unwrapErr`) | Extracts value or error with diagnostic messages | M3 | R2 Spec | DONE |
| 20 | Early-Return Operator `?` | Early-return macro unwrapping Ok or returning Err from caller | M3 | Observed / R2 | DONE |
| 21 | Zig-style `errdefer` | Defers cleanup execution to block exit if and only if function returns Err | M3 | Observed / R2 | DONE |
| 22 | Generic `sumType` DSL | Macro generating type-safe tagged union objects supporting generic parameters | M3 | Survey (E1/R2) | DONE |
| 23 | Pattern Matching `match` Macro | Pattern matching macro with wildcard `_` and guard clauses | M3 | Observed / R2 | DONE |
| 24 | `Option[T]` Sum Type | Standard `Option[T]` (`Some(val)` / `None`) with conversions to/from `Result[T, E]` | M3 | R2 Spec | DONE |
| 25 | Atomic[T] Primitives | Atomic operations with explicit memory orders (`load`, `store`, `exchange`, `compareExchange`, `fetchAdd`, `fetchSub`) | M4 | R2 Spec | PLANNED |
| 26 | SpinLock | User-space spinlock with atomic test-and-set and `cpuRelax()` backoff | M4 | R2 Spec | PLANNED |
| 27 | SysLock (OS Mutex) | OS-level lightweight critical section (SRWLOCK on Windows, pthread_mutex on POSIX) | M4 | R2 Spec | PLANNED |
| 28 | RwLock (Reader-Writer Lock) | Shared-read exclusive-write lock for high-concurrency file indexing | M4 | R2 Spec | PLANNED |
| 29 | RAII Lock Guards | `withLock`, `withReadLock`, `withWriteLock` automatic scoped lock management | M4 | R2 Spec | PLANNED |
| 30 | Barrier | Rendezvous synchronization barrier for N threads across algorithmic phases | M4 | Observed / R2 | PLANNED |
| 31 | WaitGroup | Atomic counter coordination primitive (`add`, `done`, `wait`) for batch tasks | M4 | R2 Spec | PLANNED |
| 32 | SpscQueue[T, Cap] | Cache-line aligned lock-free single-producer single-consumer circular queue | M4 | R2 Spec | PLANNED |
| 33 | MpmcQueue[T, Cap] | Multi-producer multi-consumer bounded ring buffer with atomic sequence turns | M4 | R2 Spec | PLANNED |
| 34 | ThreadPool & `parallelFor` | Worker thread pool with task queue and parallel range chunk dispatcher | M4 | R2 Spec | PLANNED |
| 35 | FileHandle RAII Wrapper | Encapsulates OS file descriptor with deterministic `=destroy` auto-close | M5 | R2 Spec | PLANNED |
| 36 | BufferedReader | 64KB buffered sequential reader minimizing syscalls | M5 | R2 Spec | PLANNED |
| 37 | BufferedWriter | Buffered sequential writer with automatic flush on destruction | M5 | R2 Spec | PLANNED |
| 38 | FileStat & FileAttributes | Cross-platform metadata struct (size, nanosecond timestamps, attributes) | M5 | R2 Spec | PLANNED |
| 39 | Uniform Filesystem Interface (`corex/fs.nim`) | Cross-platform directory walking and volume inspection | M5 | R2/R3 Spec | PLANNED |
| 40 | Win32 Fast Directory Scanner (`win32_fs.nim`) | `FindFirstFileExW` with `FindExInfoBasic` and `FIND_FIRST_EX_LARGE_FETCH` | M5 | R3 Spec | PLANNED |
| 41 | Win32 Volume & Cluster Geometry | Query volume information and calculate cluster size ("Size on Disk") | M5 | R3 Spec | PLANNED |
| 42 | Win32 MFT/USN Journal Engine | Direct MFT record enumeration structures (`UsnRecordV2`) for WizTree | M5 | R3 Spec | PLANNED |
| 43 | POSIX Filesystem Fallback (`posix_fs.nim`) | Fallback using `opendir`/`readdir_r` and `statvfs` | M5 | R3 Spec | PLANNED |
| 44 | Algx Zeropack Warnings Fix | Eliminate unused import `strutils` and unreachable code after return | M6 | Survey (E1/E3) | PLANNED |
| 45 | Algx Swissmap / Ultrasort Verification | Verify algorithm modules compile cleanly and integrate with corex | M6 | Survey (E1/E3) | PLANNED |
| 46 | Benchmark Execution & Validation | Run `benchmarks/run_benchmarks.ps1` and report objective latency/throughput | M6 | R4 Spec | PLANNED |
| 47 | Full Automated Test Suite Execution | Execute `nim c -r tests/...` with zero compilation or runtime failures | M7 | Acceptance Criteria | PLANNED |
| 48 | Zero-Leak ARC/ORC Verification | Verify memory safety with zero leaks during test execution | M7 | Acceptance Criteria | PLANNED |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Build Configuration & Ecosystem Manifest | Create `nim.cfg`, `nim_ecosystem.nimble`, `MANIFEST.md`, and root forwarders `src/corex.nim`, `src/algx.nim` | none | DONE |
| M2 | Memory Allocators, Safety Abstractions & Value Containers | Enhance `allocators.nim` (Pool, Page, Tracking, `=destroy`), create `memory.nim` (`Span`, `ByteSpan`, `Owned`), fix `containers.nim` (`BufSeq`, `BufStr` ARC/ORC hooks) | M1 | DONE |
| M3 | Result & ADT Error Handling | Enhance `result.nim` (monadic chaining, unwrap, `?`, `errdefer`) and `adt.nim` (generics, `Option[T]`, pattern match) | M1 | DONE |
| M4 | Concurrency & Thread Synchronization Primitives | Implement `corex/concurrency.nim` (`Atomic[T]`, `SpinLock`, `SysLock`, `RwLock`, `Barrier`, `WaitGroup`, `SpscQueue`, `MpmcQueue`, `ThreadPool`) | M1, M2 | PLANNED |
| M5 | I/O, Filesystem & Cross-Platform Abstraction (WizTree Prep) | Implement `corex/io.nim` (RAII `FileHandle`, `BufferedReader`, `BufferedWriter`), `corex/fs.nim`, and `corex/platform/windows/win32_fs.nim` + POSIX fallback | M1, M2, M3 | PLANNED |
| M6 | Algx Polish & Core Performance Benchmarks | Fix warnings in `zeropack.nim`, verify `algx`, execute `benchmarks/run_benchmarks.ps1`, verify latency and throughput | M1, M2, M4 | PLANNED |
| M7 | Full Test Suite Execution & Zero-Leak Verification | Compile and execute full automated test suite (`nim c -r tests/...`) with zero failures and zero leaks under ARC/ORC | M1-M6 | PLANNED |

---

## Interface Contracts

### Allocators ↔ Memory ↔ Containers
- `Allocator` is a value object holding `(ctx: pointer, allocFn, freeFn, resetFn)`.
- `allocBlock(var PoolAllocator): Result[pointer, AllocError]`.
- `Span[T]` is `(data: ptr UncheckedArray[T], len: int)` with `lent T` accessors and bounds checks.
- `Owned[T]` is `(val: ptr T, alloc: Allocator)` with `=destroy`, `=sink`, and compile-time disabled `=copy`.
- `BufSeq[T]` and `BufStr` implement `=destroy` (calling `=destroy(s.data[i])` for every element), `=copy`, and `=sink`.

### Result ↔ ADT
- `Result[T, E]` is an unchecked tagged union `(case isOk: bool of true: val: T of false: errVal: E)`.
- `flatMap`, `andThen`, `orElse`, `mapError` return new `Result`.
- `Option[T]` has `Some(val: T)` and `None`. `toResult(opt, err)` converts `Option` to `Result`.

### Concurrency Primitives
- `Atomic[T]` encapsulates atomic loads, stores, CAS, and arithmetic with `MemoryOrder`.
- `SpinLock` has `acquire()`, `tryAcquire() -> bool`, `release()`.
- `SysLock` wraps OS SRWLOCK on Windows, pthread_mutex on POSIX.
- `RwLock` wraps OS SRWLOCK on Windows, pthread_rwlock on POSIX.
- `ThreadPool` provides `spawn(proc() {.gcsafe.})` and `parallelFor(start, end, proc(s, e) {.gcsafe.})`.

### I/O & Platform Filesystem ↔ WizTree Engine
- `FileHandle` wraps OS handle (`HANDLE` on Windows, `cint` on POSIX) with `=destroy` closing handle.
- `BufferedReader` buffers 64KB reads, `BufferedWriter` buffers 64KB writes with auto-flush on `=destroy`.
- `corex/fs.nim` provides uniform `walkDirFast(dirPath: string): DirEntry` and `getVolumeInfo(path: string): Result[VolumeInfo, IOError]`.
- `win32_fs.nim` provides `win32FindFirstFast` (using `FindExInfoBasic` and `FIND_FIRST_EX_LARGE_FETCH`), `win32GetClusterGeometry`, and `win32ScanMftJournal`.

---

## Code Layout

```
c:\Users\sanal\Desktop\nim\
├── nim.cfg                     # Compiler flags (--path:"src", --mm:orc, --threads:on, --panics:on)
├── nim_ecosystem.nimble        # Nimble package specification and tasks
├── MANIFEST.md                 # Developer-facing ecosystem specification (R1)
├── BENCHMARK_SHOWCASE.md       # Benchmark documentation
├── src/
│   ├── corex.nim               # Root package export (forwarder to corex/corex.nim)
│   ├── algx.nim                # Root package export (forwarder to algx/algx.nim)
│   ├── corex/
│   │   ├── corex.nim           # corex facade (exports allocators, memory, containers, result, adt, traits, testing, concurrency, io, fs)
│   │   ├── adt.nim             # Sum types, Option, pattern matching
│   │   ├── allocators.nim      # FixedBuffer, Arena, Pool, Page, Tracking allocators
│   │   ├── memory.nim          # Span[T], ByteSpan, Owned[T]
│   │   ├── containers.nim      # BufSeq, BufStr with ARC/ORC hooks
│   │   ├── result.nim          # Result[T, E], monadic combinators, ?, errdefer
│   │   ├── traits.nim          # DynTrait fat pointers
│   │   ├── testing.nim         # testWithLeakCheck, quickCheck, bench
│   │   ├── concurrency.nim     # Atomics, SpinLock, SysLock, RwLock, Queues, ThreadPool
│   │   ├── io.nim              # FileHandle, BufferedReader, BufferedWriter
│   │   ├── fs.nim              # Cross-platform FileStat, DirEntry, walkDirFast
│   │   └── platform/           # Platform abstraction layer
│   │       ├── windows/
│   │       │   └── win32_fs.nim # Win32 FindFirstFileExW, cluster geometry, USN/MFT
│   │       └── posix/
│   │           └── posix_fs.nim # POSIX opendir/readdir_r fallback
│   └── algx/
│       ├── algx.nim            # algx facade
│       ├── ultrasort.nim       # Cache-aware MSD radix sort
│       ├── swissmap.nim        # FastMap flat hash table
│       ├── zeropack.nim        # Zero-copy POD binary & JSON serialization
│       └── simdscan.nim        # 8-way super-scalar analytics
├── benchmarks/                 # Performance benchmark suite
└── tests/                      # Automated test suite (untouched per integrity constraint)
```
