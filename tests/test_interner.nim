import corex/[allocators, result, testing, memory]
import corex/interner

proc runInternerTests() =
  echo "=== RUNNING STRINGINTERNER UNIT TESTS ==="

  # Test 1: Basic initialization
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var interner = initStringInterner(alloc, 32).unwrap()
    doAssert interner.len == 0
    interner.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: Basic initialization"

  # Test 2: Intern and Resolve identical strings
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var interner = initStringInterner(alloc, 32).unwrap()
    let id1 = interner.internString("div").unwrap()
    let id2 = interner.internString("div").unwrap()
    doAssert id1 == id2 # Same ID returned!
    doAssert interner.len == 1
    doAssert interner.resolveString(id1) == "div"
    interner.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Deduplication of identical strings"

  # Test 3: Multiple distinct strings
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var interner = initStringInterner(alloc, 32).unwrap()
    let idDiv = interner.internString("div").unwrap()
    let idSpan = interner.internString("span").unwrap()
    let idClass = interner.internString("class").unwrap()
    doAssert idDiv != idSpan
    doAssert idSpan != idClass
    doAssert interner.len == 3
    doAssert interner.resolveString(idDiv) == "div"
    doAssert interner.resolveString(idSpan) == "span"
    doAssert interner.resolveString(idClass) == "class"
    interner.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: Distinct strings get unique IDs"

  # Test 4: Empty string interning
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var interner = initStringInterner(alloc, 32).unwrap()
    let idEmpty1 = interner.internString("").unwrap()
    let idEmpty2 = interner.internString("").unwrap()
    doAssert idEmpty1 == idEmpty2
    doAssert interner.resolveString(idEmpty1) == ""
    interner.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: Empty string deduplication"

  # Test 5: 10,000 distinct strings (checking collision resistance and scale)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var interner = initStringInterner(alloc, 256).unwrap()
    var ids: seq[InternedStr] = @[]
    for i in 0 ..< 10_000:
      let s = "dom_node_tag_identifier_" & $i
      ids.add(interner.internString(s).unwrap())

    doAssert interner.len == 10_000
    for i in 0 ..< 100:
      let s = "dom_node_tag_identifier_" & $i
      doAssert interner.resolveString(ids[i]) == s

    # Re-intern first 100 and verify they match earlier IDs
    for i in 0 ..< 100:
      let s = "dom_node_tag_identifier_" & $i
      let reId = interner.internString(s).unwrap()
      doAssert reId == ids[i]

    doAssert interner.len == 10_000
    interner.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: 10,000 distinct strings scaling test"

  # Test 6: Repeated interning of high-frequency tokens (HTML/CSS simulator)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var interner = initStringInterner(alloc, 64).unwrap()
    const tags = ["div", "span", "p", "a", "table", "tr", "td", "button", "input", "form"]
    for _ in 0 ..< 10_000:
      for t in tags:
        discard interner.internString(t).unwrap()
    doAssert interner.len == tags.len
    for i, t in tags:
      let id = interner.internString(t).unwrap()
      doAssert interner.resolveString(id) == t
    interner.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Heavy repeat interning keeps count strictly bounded"

  # Test 7: Sink / Move semantics
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var in1 = initStringInterner(alloc, 32).unwrap()
    let id1 = in1.internString("sample").unwrap()

    var in2 = move(in1)
    doAssert in2.len == 1
    doAssert in2.resolveString(id1) == "sample"

    in1.deinit()
    in2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Sink / Move semantics"

  # Test 8: Scope-based RAII destruction
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var inScope = initStringInterner(alloc, 64).unwrap()
      for i in 0 ..< 500:
        discard inScope.internString("token_" & $i)
    # Scope exited, all tables, arenas and spans destroyed
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Scope-based RAII destruction"

  # Test 9: OOM with FixedBufferAllocator
  block:
    var buffer: array[32, byte]
    var fixed = initFixedBufferAllocator(addr buffer[0], buffer.len)
    let alloc = fixed.allocator()
    let res = initStringInterner(alloc, 1024)
    doAssert res.isErr
    echo "[OK] 09: OOM error handling"

  # Test 10: testWithLeakCheck with 5000 strings
  testWithLeakCheck("StringInterner leak check with 5000 strings"):
    var interner = initStringInterner(testAlloc, 128).unwrap()
    for i in 0 ..< 5000:
      discard interner.internString("val_" & $i)
    interner.deinit()
  echo "[OK] 10: testWithLeakCheck 5000 strings verified"

  echo "=== ALL 10 STRINGINTERNER TESTS PASSED WITH 0 LEAKS ==="

when isMainModule:
  runInternerTests()
