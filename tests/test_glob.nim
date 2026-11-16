import ../apps/everything/src/search

proc runGlobTests() =
  echo "=== RUNNING MATCHGLOB TESTS ==="

  # Core requirements from mission
  doAssert matchGlob("report.pdf", "*.pdf") == true, "report.pdf should match *.pdf"
  doAssert matchGlob("Pdf", "*.pdf") == false, "Directory 'Pdf' must NOT match *.pdf"
  doAssert matchGlob("QtQuick", "*.pdf") == false, "QtQuick must not match *.pdf"
  doAssert matchGlob("report.PDF", "*.pdf") == true, "Uppercase extension .PDF must match *.pdf"
  doAssert matchGlob("document.Pdf", "*.pdf") == true, "Mixed case .Pdf must match *.pdf"

  # Regression tests on other patterns
  doAssert matchGlob("file.exe", "*.exe") == true, "file.exe should match *.exe"
  doAssert matchGlob("setup.EXE", "*.exe") == true, "setup.EXE should match *.exe"
  doAssert matchGlob("prefix_report.txt", "prefix_*") == true, "prefix matching"
  doAssert matchGlob("not_prefix.txt", "prefix_*") == false, "prefix mismatch"
  doAssert matchGlob("some_report_data.csv", "*report*") == true, "substring matching"
  doAssert matchGlob("other_data.csv", "*report*") == false, "substring mismatch"

  echo "[OK] matchGlob verified: report.pdf=true, Pdf=false, QtQuick=false, report.PDF=true"
  echo "=== ALL GLOB TESTS PASSED ==="

when isMainModule:
  runGlobTests()
