## tests/test_safe_compiler.nim — Automated Verification Suite for Hybrid Memory-Safe Nim Compiler
##
## Verifies `bin/nim_safe.exe` across:
## 1. Valid memory-safe Nim code (`Result[T, E]`, `Option[T]`, `Owned[T]`, `{.raises: [].}`)
##    with `--mem-safe --safe-mode --check-safe-atf --atf-report:...`
## 2. Rejecting `cast` / `ptr` operations (`[MEM-SAFE-001]` / `[MEM-SAFE-002]`)
## 3. Rejecting raw heap `alloc`/`dealloc` (`[MEM-SAFE-003]`)
## 4. Rejecting unprotected mutable globals (`[MEM-SAFE-005]`)
## 5. Rejecting borrow/mutation violations via `varpartitions` (`--mem-safe`)
## 6. Rejecting local stack address escapes (`[MEM-SAFE-006]`)
## 7. Rejecting exceptions / `raise` under `--safe-mode` (`[SAFE-MODE-001]`)
## 8. Rejecting smuggled unsafe C (`strcpy`, `malloc`, `free`) via After-Codegen-Finish
##    (`--check-safe-atf` `[ATF-001]`) BEFORE C compilation!
## 9. Rejecting `-d:danger` with `--check-safe-atf` (`[ATF-005]`)
## 10. Permitting explicitly audited `{.trustedUnsafe.}` procs and blocks.

import std/[os, osproc, strutils]

const
  CompilerBin = "bin" / "nim_safe.exe"
  FixturesDir = "tests" / "fixtures" / "safe_compiler"

proc runNimSafe(args: string): tuple[output: string, exitCode: int] =
  let exePath = if fileExists(CompilerBin): CompilerBin
                else: "bin/nim_safe.exe"
  doAssert fileExists(exePath), "Compiler binary missing: " & exePath & " (run build first)"
  let cmd = exePath & " " & args
  execCmdEx(cmd)

proc expectRejected(name, file, flags, expectedToken: string) =
  let srcPath = FixturesDir / file
  doAssert fileExists(srcPath), "Missing fixture: " & srcPath
  let (outStr, code) = runNimSafe("c -f " & flags & " " & srcPath)
  doAssert code != 0, name & " MUST be rejected, but compiled cleanly!\nOutput:\n" & outStr
  doAssert outStr.contains(expectedToken),
    name & " expected error '" & expectedToken & "', got:\n" & outStr
  echo "  [PASS] ", name, " -> rejected (", expectedToken, ")"

proc main() =
  echo "================================================================="
  echo ">>> HYBRID MEMORY-SAFE NIM COMPILER VERIFICATION SUITE <<<"
  echo "================================================================="

  let reportPath = "tests" / "fixtures" / "safe_compiler" / "atf_audit_report.md"
  if fileExists(reportPath):
    removeFile(reportPath)

  echo "\n[SUITE 1] Valid Memory-Safe Program (--mem-safe --safe-mode --check-safe-atf)..."
  let safeSrc = FixturesDir / "safe_valid.nim"
  let (safeOut, safeCode) = runNimSafe(
    "c -r -f --mem-safe --safe-mode --check-safe-atf --atf-report:" & reportPath & " " & safeSrc
  )
  doAssert safeCode == 0, "Safe program failed:\n" & safeOut
  doAssert safeOut.contains("[ATF-SAFE] Verified"), "Missing ATF summary:\n" & safeOut
  doAssert safeOut.contains("SAFE_VALID_OK:42"), "Missing runtime output:\n" & safeOut
  doAssert fileExists(reportPath), "ATF audit report was not written: " & reportPath
  let repText = readFile(reportPath)
  doAssert repText.contains("Status: PASSED"), "Unexpected ATF report:\n" & repText
  echo "  [PASS] 1.1 Valid memory-safe program compiled, passed ATF, and ran cleanly."

  let safeGenSrc = FixturesDir / "safe_generic_valid.nim"
  let (safeGenOut, safeGenCode) = runNimSafe(
    "c -r -f --mem-safe --safe-mode --check-safe-atf " & safeGenSrc
  )
  doAssert safeGenCode == 0, "Safe generic program failed:\n" & safeGenOut
  doAssert safeGenOut.contains("[ATF-SAFE] Verified"), "Missing ATF summary for generic:\n" & safeGenOut
  doAssert safeGenOut.contains("SAFE_GENERIC_OK:42"), "Missing runtime output for generic:\n" & safeGenOut
  echo "  [PASS] 1.2 Safe generic proc compiled, passed ATF, and ran cleanly."

  echo "\n[SUITE 2] --mem-safe AST & Borrow Safety Enforcement..."
  expectRejected("2.1 Unsafe cast", "unsafe_cast_ptr.nim", "--mem-safe", "MEM-SAFE-001")
  expectRejected("2.2 Raw alloc/dealloc", "unsafe_raw_alloc.nim", "--mem-safe", "MEM-SAFE-003")
  expectRejected("2.3 Mutable global var", "unsafe_global_var.nim", "--mem-safe", "MEM-SAFE-005")
  expectRejected("2.4 Borrow-during-mutation", "unsafe_borrow.nim", "--mem-safe", "borrows from")
  expectRejected("2.5 Stack address escape", "unsafe_stack_escape.nim", "--mem-safe", "MEM-SAFE-002")
  expectRejected("2.6 Generic proc unsafe cast/ptr", "unsafe_generic_cast.nim", "--mem-safe", "MEM-SAFE-001")
  expectRejected("2.7 Pragma {.push checks: off.}", "unsafe_push_checks_off.nim", "--mem-safe", "MEM-SAFE-007")

  echo "\n[SUITE 3] --safe-mode Zero-Exception Policy..."
  expectRejected("3.1 Explicit raise statement rejected", "unsafe_raise_stmt.nim", "--safe-mode", "SAFE-MODE-001")
  expectRejected("3.2 Raising signature rejected", "unsafe_raise_exc.nim", "--safe-mode", "SAFE-MODE-002")

  echo "\n[SUITE 4] --check-safe-atf After-Codegen-Finish C Code Verification..."
  expectRejected(
    "4.1 Smuggled strcpy/malloc/free caught post-codegen",
    "unsafe_c_emit_atf.nim",
    "--check-safe-atf",
    "ATF-001"
  )
  expectRejected(
    "4.2 Stripping runtime checks (-d:danger) rejected by ATF",
    "safe_valid.nim",
    "-d:danger --check-safe-atf",
    "ATF-005"
  )
  expectRejected(
    "4.3 Local {.push checks: off.} rejected by ATF",
    "unsafe_push_checks_off.nim",
    "--check-safe-atf",
    "ATF-005"
  )

  echo "\n[SUITE 5] Explicit {.trustedUnsafe.} Escape Hatch (Rust unsafe equivalent)..."
  let trustedSrc = FixturesDir / "trusted_unsafe_escape_hatch.nim"
  let (trOut, trCode) = runNimSafe(
    "c -r -f --mem-safe --safe-mode --check-safe-atf " & trustedSrc
  )
  doAssert trCode == 0, "Trusted unsafe escape hatch failed:\n" & trOut
  doAssert trOut.contains("[ATF-SAFE] Verified"), "Missing ATF summary for trustedUnsafe:\n" & trOut
  doAssert trOut.contains("TRUSTED_UNSAFE_OK:42"), "Missing runtime output for trustedUnsafe:\n" & trOut
  echo "  [PASS] 5.1 Audited {.trustedUnsafe.} proc & block compiled and passed ATF."

  # Clean up generated fixture executables/report artifacts
  for stem in ["safe_valid", "safe_generic_valid", "trusted_unsafe_escape_hatch"]:
    let exeF = FixturesDir / (stem & ".exe")
    if fileExists(exeF): removeFile(exeF)
  if fileExists(reportPath):
    removeFile(reportPath)

  echo "\n================================================================="
  echo ">>> [SUCCESS] ALL HYBRID MEMORY-SAFE COMPILER TESTS PASSED! <<<"
  echo "================================================================="

when isMainModule:
  main()
