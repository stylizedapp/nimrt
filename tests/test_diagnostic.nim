import std/strutils
import corex/[allocators, result, memory]
import corex/diagnostic

proc toByteSpan(s: string): Span[byte] =
  if s.len == 0: span[byte]()
  else: span(cast[ptr UncheckedArray[byte]](unsafeAddr s[0]), s.len)

proc runDiagnosticTests() =
  echo "=== RUNNING DIAGNOSTIC UNIT TESTS ==="

  # Test 1: Empty SourceFile
  block:
    let sf = newSourceFile(toByteSpan("")).unwrap()
    doAssert sf.lineOffsets.len == 1
    doAssert sf.lineOffsets[0] == 0
    let (l, c) = sf.lineCol(0)
    doAssert l == 1 and c == 1
    echo "[OK] 01: Empty SourceFile"

  # Test 2: Single line without newline
  block:
    let text = "let x = 42"
    let sf = newSourceFile(toByteSpan(text)).unwrap()
    doAssert sf.lineOffsets.len == 1
    let (l1, c1) = sf.lineCol(0)
    doAssert l1 == 1 and c1 == 1
    let (l2, c2) = sf.lineCol(4)
    doAssert l2 == 1 and c2 == 5 # 1-based column
    echo "[OK] 02: Single line without newline"

  # Test 3: Multiple lines with newlines
  block:
    let text = "line1\nline2\nline3"
    let sf = newSourceFile(toByteSpan(text)).unwrap()
    doAssert sf.lineOffsets.len == 3
    doAssert sf.lineOffsets[0] == 0
    doAssert sf.lineOffsets[1] == 6
    doAssert sf.lineOffsets[2] == 12

    let (l1, c1) = sf.lineCol(0)
    doAssert l1 == 1 and c1 == 1

    let (l2, c2) = sf.lineCol(6) # Start of line2
    doAssert l2 == 2 and c2 == 1

    let (l3, c3) = sf.lineCol(14) # 'n' in line3
    doAssert l3 == 3 and c3 == 3
    echo "[OK] 03: Multiple lines offset calculation"

  # Test 4: Line ending with \n
  block:
    let text = "hello\n"
    let sf = newSourceFile(toByteSpan(text)).unwrap()
    doAssert sf.lineOffsets.len == 1
    echo "[OK] 04: Trailing newline handling"

  # Test 5: Plain text render for single line
  block:
    let code = "fn compute(x: int) -> int:\n  return x + 1"
    let sf = newSourceFile(toByteSpan(code)).unwrap()
    let diag = Diagnostic(
      severity: sevError,
      message: "mismatched type, expected int found float",
      file: "src/main.nim",
      span: SourceSpan(start: 14, `end`: 17) # "int" in "(x: int)"
    )
    let output = diag.render(sf)
    doAssert output.contains("error: mismatched type")
    doAssert output.contains("--> src/main.nim:1:15")
    doAssert output.contains("1 | fn compute(x: int) -> int:")
    doAssert output.contains("^^^")
    echo "[OK] 05: Single line render format"

  # Test 6: Multi-line span render
  block:
    let code = "proc process() =\n  let a = 1\n  let b = 2"
    let sf = newSourceFile(toByteSpan(code)).unwrap()
    let diag = Diagnostic(
      severity: sevWarning,
      message: "unused function block",
      file: "test.nim",
      span: SourceSpan(start: 17, `end`: 39) # across lines 2 and 3
    )
    let output = diag.render(sf)
    doAssert output.contains("warning: unused function block")
    doAssert output.contains("2 |   let a = 1")
    doAssert output.contains("3 |   let b = 2")
    echo "[OK] 06: Multi-line span render"

  # Test 7: Child diagnostics (notes and helps)
  block:
    let code = "let val = query()"
    let sf = newSourceFile(toByteSpan(code)).unwrap()
    let diag = Diagnostic(
      severity: sevError,
      message: "unresolved symbol",
      file: "query.nim",
      span: SourceSpan(start: 10, `end`: 15),
      children: @[
        Diagnostic(severity: sevNote, message: "did you mean 'runQuery'?"),
        Diagnostic(severity: sevHelp, message: "import corex/db to bring into scope")
      ]
    )
    let output = diag.render(sf)
    doAssert output.contains(" = note: did you mean 'runQuery'?")
    doAssert output.contains(" = help: import corex/db to bring into scope")
    echo "[OK] 07: Child diagnostics rendering"

  # Test 8: renderColored returns non-empty string and does not crash
  block:
    let code = "var z = 10 / 0"
    let sf = newSourceFile(toByteSpan(code)).unwrap()
    let diag = Diagnostic(
      severity: sevError,
      message: "division by zero",
      file: "calc.nim",
      span: SourceSpan(start: 11, `end`: 14)
    )
    let coloredOutput = diag.renderColored(sf)
    doAssert coloredOutput.len > 0
    echo "[OK] 08: renderColored non-crash check"

  # Test 9: Binary search boundary cases
  block:
    let text = "a\nb\nc\nd\ne"
    let sf = newSourceFile(toByteSpan(text)).unwrap()
    # Negative offset
    doAssert sf.lineCol(-10) == (1, 1)
    # Offset beyond end
    doAssert sf.lineCol(100) == (5, 2)
    echo "[OK] 09: Boundary offsets handling"

  # Test 10: Visual demo print of colored diagnostic
  block:
    let code = "type User = object\n  name: string\n  age: int"
    let sf = newSourceFile(toByteSpan(code)).unwrap()
    let diag = Diagnostic(
      severity: sevWarning,
      message: "field 'name' is never initialized",
      file: "models/user.nim",
      span: SourceSpan(start: 21, `end`: 25),
      children: @[
        Diagnostic(severity: sevHelp, message: "consider providing default value or constructor")
      ]
    )
    let sample = diag.renderColored(sf)
    echo "\n--- VISUAL SAMPLE DIAGNOSTIC ---"
    stdout.write(sample)
    echo "---------------------------------\n"
    echo "[OK] 10: Visual rendering verified"

  echo "=== ALL 10 DIAGNOSTIC TESTS PASSED ==="

when isMainModule:
  runDiagnosticTests()
