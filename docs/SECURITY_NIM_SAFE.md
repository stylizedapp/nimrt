# `nim_safe` Compiler Security Boundaries

`nim_safe` (`compiler/nim_safe.nim`) is an experimental memory- and exception-safety enforcement layer built on top of the Nim compiler. It separates enforcement into three distinct stages.

## 1. Three-Stage Enforcement Architecture

### Stage 1: Static AST & Borrow Analysis (`compiler/mem_safe_pass.nim`)
Runs post-semantic-check on user modules (excluding Nim stdlib and, in non-strict mode, `corex`/`algx` runtime internals):
- `[MEM-SAFE-001]`: Forbids `cast[T](x)` (including inside expanded macros and generics).
- `[MEM-SAFE-002]`: Forbids raw `ptr T`, `pointer`, and pointer dereferences in user signatures and expressions.
- `[MEM-SAFE-003]`: Forbids raw memory ops (`alloc`, `dealloc`, `copyMem`, `moveMem`, `zeroMem`, `unsafeAddr`).
- `[MEM-SAFE-004]`: Forbids inline C/ASM `{.emit.}` and unannotated `{.importc.}` FFI.
- `[MEM-SAFE-005]`: Forbids unprotected mutable module-level globals (requires `let`, `const`, `threadvar`, or atomic/lock types).
- `[MEM-SAFE-006]`: Forbids taking stack addresses (`addr local`) and returning local pointers.
- `[MEM-SAFE-007]`: Forbids disabling runtime checks (`{.push checks: off.}`, `{.boundChecks: off.}`, etc.).
- `[MEM-SAFE-008]`: Forbids external C / FFI pragmas (`{.compile.}`, `{.passC.}`, `{.passL.}`, `{.dynlib.}`, `{.header.}`) and unsafe low-level imports (`dynlib`, `osproc`, `memfiles`, `winlean`, `posix`, `ansi_c`).
- Borrow checking via `varpartitions.computeGraphPartitions` + `checkBorrowedLocations`.
- `--safe-mode`: `[SAFE-MODE-001]` forbids `raise`, `[SAFE-MODE-002]` requires `{.raises: [].}`, `[SAFE-MODE-003]` (strict) forbids silent `discard` of `Result`/`Option`.

### Stage 2: Runtime Checks (`compiler/safety_config.nim`)
When `--mem-safe` or `--safe-mode` is active:
- Forces deterministic `--mm:orc` (`gcOrc`), `optPanics`, `optThreads`, `optThreadAnalysis`, `strictFuncs`.
- Enables `optObjCheck`, `optFieldCheck`, `optRangeCheck`, `optBoundsCheck`, `optOverflowCheck`, `optAssert`, `optSinkInference`, `optCursorInference`.

### Stage 3: Post-Codegen C Validation (`compiler/atf_c_checker.nim`)
Runs after C codegen and **before** GCC invocation (`--check-safe-atf`):
- `[ATF-001]`: Rejects banned CRT calls (`malloc`, `free`, `strcpy`, `sprintf`, `system`, `popen`, raw `memcpy`/`memmove`) in user C files.
- `[ATF-002]`: Rejects unchecked raw C pointer casts/arithmetic injected via emit.
- `[ATF-003]`: Audits ARC/ORC lifecycle hooks (`eqdestroy_`/`eqsink_`/`eqcopy_`).
- `[ATF-004]`: Rejects C stack address escapes (`return &local;`).
- `[ATF-005]`: Rejects `-d:danger` (which strips runtime bounds/overflow guards).

## 2. Exact Guarantees vs Non-Guarantees

**Guaranteed (in audited user modules without `{.trustedUnsafe.}`)**:
- No raw `ptr`/`pointer` arithmetic, `cast`, manual `alloc`/`dealloc`, or unannotated C FFI.
- Deterministic ORC memory management with runtime bounds, range, and overflow checks active.
- Under `--safe-mode`, user procedures are exception-free (`{.raises: [].}`).

**Non-Guarantees (Explicit Boundaries)**:
- **Escape Hatch**: Code annotated with `{.trustedUnsafe.}` (or `block trustedUnsafe:`) bypasses AST checks, just like Rust `unsafe {}`.
- **Stdlib / Runtime**: Nim's `system`/stdlib and (in non-strict mode) `src/corex/` & `src/algx/` are trusted runtime foundations.
- **External C / Linker**: Precompiled static libraries linked externally or `{.trustedUnsafe.}` FFI bindings are not memory-verified by `nim_safe`.
- **Logic / Concurrency Races**: `nim_safe` does not prove absence of deadlocks, OOMs, or logic bugs.
