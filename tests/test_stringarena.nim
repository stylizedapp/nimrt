import corex/[allocators, result, adt, testing, memory]
import corex/stringarena

proc spanToString(sp: Span[byte]): string =
  if sp.len == 0: return ""
  result = newString(sp.len)
  copyMem(addr result[0], sp.rawData, sp.len)

proc runStringArenaTests() =
  echo "=== RUNNING STRINGARENA UNIT TESTS ==="

  # Test 1: Basic initialization
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var arena = initStringArena(alloc, 256).unwrap()
    doAssert arena.bytesUsed == 0
    doAssert arena.bytesAllocated == 256
    arena.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: Basic initialization"

  # Test 2: Intern and Span validity
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var arena = initStringArena(alloc, 256).unwrap()
    let sp1 = arena.internString("hello").unwrap()
    let sp2 = arena.internString("world").unwrap()
    doAssert sp1.len == 5
    doAssert sp2.len == 5
    doAssert spanToString(sp1) == "hello"
    doAssert spanToString(sp2) == "world"
    doAssert arena.bytesUsed == 10
    arena.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Intern and Span contents"

  # Test 3: Empty string interning
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var arena = initStringArena(alloc, 256).unwrap()
    let sp = arena.internString("").unwrap()
    doAssert sp.len == 0
    doAssert arena.bytesUsed == 0
    arena.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: Empty string interning"

  # Test 4: Chunk growth beyond initial chunk
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var arena = initStringArena(alloc, 128).unwrap()
    var spans: seq[Span[byte]] = @[]
    for i in 0 ..< 100:
      let s = "string_number_" & $i
      spans.add(arena.internString(s).unwrap())
    doAssert arena.chunks.len > 1
    doAssert arena.bytesAllocated > arena.bytesUsed
    for i in 0 ..< 100:
      doAssert spanToString(spans[i]) == "string_number_" & $i
    arena.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: Chunk growth and multi-chunk span integrity"

  # Test 5: Reset keeps first chunk and resets bytesUsed to 0
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var arena = initStringArena(alloc, 128).unwrap()
    for i in 0 ..< 100:
      discard arena.internString("long_sample_payload_item_" & $i)
    doAssert arena.chunks.len > 1
    arena.reset()
    doAssert arena.chunks.len == 1
    doAssert arena.bytesUsed == 0
    doAssert arena.bytesAllocated == 128

    # Intern new strings after reset
    let sp = arena.internString("fresh_string").unwrap()
    doAssert spanToString(sp) == "fresh_string"
    doAssert arena.bytesUsed == 12

    arena.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Reset cleans secondary chunks and resets used bytes"

  # Test 6: Huge single string larger than initial chunk
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var arena = initStringArena(alloc, 64).unwrap()
    let huge = newString(1000)
    let sp = arena.internString(huge).unwrap()
    doAssert sp.len == 1000
    arena.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Huge string larger than default chunk capacity"

  # Test 7: Sink / Move semantics
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a1 = initStringArena(alloc, 256).unwrap()
    discard a1.internString("alpha")
    var a2 = move(a1)
    doAssert a2.bytesUsed == 5
    let sp = a2.internString("beta").unwrap()
    doAssert spanToString(sp) == "beta"
    a1.deinit()
    a2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Sink / Move semantics"

  # Test 8: RAII `=destroy` on scope exit
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var arena = initStringArena(alloc, 128).unwrap()
      for i in 0 ..< 50:
        discard arena.internString("scope_token_" & $i)
    # Scope exited
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Scope-based RAII destruction"

  # Test 9: OOM with FixedBufferAllocator
  block:
    var buffer: array[32, byte]
    var fixed = initFixedBufferAllocator(addr buffer[0], buffer.len)
    let alloc = fixed.allocator()
    let res = initStringArena(alloc, 4096)
    doAssert res.isErr
    echo "[OK] 09: OOM error handling"

  # Test 10: testWithLeakCheck with 1000 intern + reset + deinit
  testWithLeakCheck("StringArena 1000 intern + reset"):
    var arena = initStringArena(testAlloc, 256).unwrap()
    for iter in 0 ..< 10:
      for i in 0 ..< 100:
        discard arena.internString("item_" & $i)
      arena.reset()
    arena.deinit()
  echo "[OK] 10: testWithLeakCheck repeated churn verified"

  echo "=== ALL 10 STRINGARENA TESTS PASSED WITH 0 LEAKS ==="

when isMainModule:
  runStringArenaTests()
