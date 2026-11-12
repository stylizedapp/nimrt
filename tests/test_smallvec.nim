import corex/[allocators, result, testing]
import corex/smallvec

type
  ManagedItem = ref object
    name: string

proc runSmallVecTests() =
  echo "=== RUNNING SMALLVEC[T, N] UNIT TESTS ==="

  # Test 1: Stack inline without heap allocations
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv = initSmallVec[int, 4](alloc)
    doAssert sv.len == 0
    doAssert sv.isInline
    discard sv.add(10)
    discard sv.add(20)
    discard sv.add(30)
    discard sv.add(40)
    doAssert sv.len == 4
    doAssert sv.isInline # Still inline!
    doAssert sv[0] == 10
    doAssert sv[3] == 40
    # Zero heap allocations made!
    doAssert tracker.allocCount == 0
    sv.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: In-place stack storage (0 heap allocations for <= N)"

  # Test 2: Spill over to heap on N+1
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv = initSmallVec[int, 4](alloc)
    for i in 1 .. 4:
      discard sv.add(i)
    doAssert sv.isInline

    # 5th element triggers heap allocation
    discard sv.add(5)
    doAssert not sv.isInline
    doAssert sv.len == 5
    doAssert tracker.allocCount > 0
    for i in 0 ..< 5:
      doAssert sv[i] == i + 1
    sv.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Spillover to heap storage on N+1 element"

  # Test 3: Multiple grow operations on heap
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv = initSmallVec[int, 2](alloc)
    for i in 0 ..< 100:
      discard sv.add(i * 5)
    doAssert sv.len == 100
    for i in 0 ..< 100:
      doAssert sv[i] == i * 5
    sv.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: Multiple grow expansions on heap"

  # Test 4: In-place mutation
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv = initSmallVec[string, 2](alloc)
    discard sv.add("init1")
    discard sv.add("init2")
    sv[0] = "mod1"
    sv[1] = "mod2"
    doAssert sv[0] == "mod1"
    doAssert sv[1] == "mod2"
    sv.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: In-place element mutation"

  # Test 5: Clear
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv = initSmallVec[string, 3](alloc)
    discard sv.add("a")
    discard sv.add("b")
    sv.clear()
    doAssert sv.len == 0
    discard sv.add("fresh")
    doAssert sv.len == 1
    doAssert sv[0] == "fresh"
    sv.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Clear and re-populate"

  # Test 6: Managed ref objects in inline and heap
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var sv = initSmallVec[ManagedItem, 2](alloc)
      discard sv.add(ManagedItem(name: "item1"))
      discard sv.add(ManagedItem(name: "item2"))
      discard sv.add(ManagedItem(name: "item3")) # Heap spilled
    # Scope exited, all ManagedItems destroyed
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Managed ref objects in inline and heap storage"

  # Test 7: Deep copy isolation (=copy)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv1 = initSmallVec[int, 2](alloc)
    discard sv1.add(100)
    discard sv1.add(200)
    discard sv1.add(300) # on heap

    var sv2 = sv1 # =copy
    doAssert sv2.len == 3
    sv2[0] = 999
    doAssert sv2[0] == 999
    doAssert sv1[0] == 100 # sv1 unaffected

    sv1.deinit()
    sv2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Deep copy semantics (=copy)"

  # Test 8: Move / Sink semantics
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv1 = initSmallVec[string, 2](alloc)
    discard sv1.add("x")
    discard sv1.add("y")
    discard sv1.add("z")

    var sv2 = move(sv1)
    doAssert sv1.len == 0
    doAssert sv2.len == 3
    doAssert sv2[2] == "z"

    sv1.deinit()
    sv2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Sink / Move semantics (=sink)"

  # Test 9: testWithLeakCheck with 100 SmallVec instances
  testWithLeakCheck("100 SmallVec heap instances"):
    for _ in 0 ..< 100:
      var sv = initSmallVec[string, 4](testAlloc)
      for j in 0 ..< 10:
        discard sv.add("str_" & $j)
      sv.deinit()
  echo "[OK] 09: testWithLeakCheck on 100 SmallVec instances"

  # Test 10: Iterators (items, mitems)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sv = initSmallVec[int, 2](alloc)
    discard sv.add(1)
    discard sv.add(2)
    discard sv.add(3)

    for item in sv.mitems:
      item *= 10

    var sum = 0
    for item in sv.items:
      sum += item
    doAssert sum == 60

    sv.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 10: Iterators items and mitems"

  echo "=== ALL 10 SMALLVEC TESTS PASSED WITH 0 LEAKS ==="

when isMainModule:
  runSmallVecTests()
