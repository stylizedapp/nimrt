import corex/[allocators, result, adt, testing]
import corex/slab

type
  ManagedNode = ref object
    tag: string
    id: int

proc runSlabTests() =
  echo "=== RUNNING SLAB[T] UNIT TESTS ==="

  # Test 1: Basic initialization
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[int](alloc, 16).unwrap()
    doAssert s.len == 0
    doAssert s.cap == 16
    doAssert not s.contains(SlabId(0))
    doAssert not s.contains(SlabId(-1))
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: Basic initialization"

  # Test 2: Insert & Access
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[string](alloc, 16).unwrap()
    let id1 = s.insert("hello").unwrap()
    let id2 = s.insert("world").unwrap()
    doAssert s.len == 2
    doAssert s.contains(id1)
    doAssert s.contains(id2)
    doAssert s[id1] == "hello"
    doAssert s[id2] == "world"
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Insert and access"

  # Test 3: Mutating element in-place via var []
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[int](alloc, 16).unwrap()
    let id = s.insert(42).unwrap()
    s[id] = 100
    doAssert s[id] == 100
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: In-place mutation"

  # Test 4: Remove
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[string](alloc, 16).unwrap()
    let id = s.insert("to_remove").unwrap()
    doAssert s.len == 1
    let valOpt = s.remove(id)
    doAssert valOpt.isSome
    doAssert valOpt.get() == "to_remove"
    doAssert s.len == 0
    doAssert not s.contains(id)
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: Remove element"

  # Test 5: Remove non-existent ID
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[int](alloc, 16).unwrap()
    doAssert s.remove(SlabId(0)).isNone
    doAssert s.remove(SlabId(999)).isNone
    doAssert s.remove(SlabId(-5)).isNone
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Remove invalid IDs returns None"

  # Test 6: Free-list reuse
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[int](alloc, 4).unwrap()
    let id0 = s.insert(10).unwrap()
    let id1 = s.insert(20).unwrap()
    let id2 = s.insert(30).unwrap()
    discard s.remove(id1) # free slot 1
    let idReused = s.insert(999).unwrap()
    doAssert idReused == id1 # Reused slot 1!
    doAssert s[idReused] == 999
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Free slot reuse"

  # Test 7: Grow & SlabId stability
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[string](alloc, 4).unwrap()
    let idA = s.insert("NodeA").unwrap()
    let idB = s.insert("NodeB").unwrap()

    # Grow by inserting 1000 items
    var ids: seq[SlabId] = @[]
    for i in 0 ..< 1000:
      ids.add(s.insert("Item" & $i).unwrap())

    doAssert s.len == 1002
    doAssert s.cap >= 1002
    # Verify idA and idB remained stable!
    doAssert s[idA] == "NodeA"
    doAssert s[idB] == "NodeB"
    for i in 0 ..< 1000:
      doAssert s[ids[i]] == "Item" & $i

    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Grow and SlabId stability across reallocations"

  # Test 8: Partial removal and reuse after grow
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[int](alloc, 16).unwrap()
    var ids: seq[SlabId] = @[]
    for i in 0 ..< 100:
      ids.add(s.insert(i).unwrap())
    doAssert s.len == 100
    # Remove 50 elements
    for i in 0 ..< 50:
      doAssert s.remove(ids[i]).get() == i
    doAssert s.len == 50
    # Insert 50 elements again
    for i in 0 ..< 50:
      discard s.insert(i + 500).unwrap()
    doAssert s.len == 100

    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Remove 50, re-insert 50 reuse pattern"

  # Test 9: Clear
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s = initSlab[string](alloc, 16).unwrap()
    for i in 0 ..< 10:
      discard s.insert("str" & $i)
    doAssert s.len == 10
    s.clear()
    doAssert s.len == 0
    let idNew = s.insert("first_after_clear").unwrap()
    doAssert s.len == 1
    doAssert s[idNew] == "first_after_clear"
    s.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 09: Clear and re-populate"

  # Test 10: RAII `=destroy` on scope exit with managed ref objects
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var s = initSlab[ManagedNode](alloc, 8).unwrap()
      for i in 0 ..< 100:
        discard s.insert(ManagedNode(tag: "div", id: i))
    # Scope exited, all 100 nodes destroyed
    doAssert not tracker.hasLeaks()
    echo "[OK] 10: Automatic RAII cleanup of 100 ref objects"

  # Test 11: Deep Copy isolation (=copy)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s1 = initSlab[string](alloc, 8).unwrap()
    let id1 = s1.insert("alpha").unwrap()
    let id2 = s1.insert("beta").unwrap()

    var s2 = s1 # =copy
    doAssert s2.len == 2
    doAssert s2[id1] == "alpha"
    doAssert s2[id2] == "beta"
    discard s2.remove(id1)
    doAssert not s2.contains(id1)
    doAssert s1.contains(id1) # s1 untouched

    s1.deinit()
    s2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 11: Deep copy isolation"

  # Test 12: Move / Sink semantics
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var s1 = initSlab[int](alloc, 8).unwrap()
    let id = s1.insert(12345).unwrap()

    var s2 = move(s1)
    doAssert s2.len == 1
    doAssert s2[id] == 12345
    doAssert s1.len == 0

    s1.deinit()
    s2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 12: Sink / Move semantics"

  # Test 13: OOM with FixedBufferAllocator
  block:
    var buffer: array[16, byte]
    var fixed = initFixedBufferAllocator(addr buffer[0], buffer.len)
    let alloc = fixed.allocator()
    let res = initSlab[int](alloc, 512)
    doAssert res.isErr
    echo "[OK] 13: OOM handling in initSlab"

  # Test 14: testWithLeakCheck macro integration
  testWithLeakCheck("Slab 1000 items life cycle"):
    var s = initSlab[ManagedNode](testAlloc, 32).unwrap()
    var ids: seq[SlabId] = @[]
    for i in 0 ..< 1000:
      ids.add(s.insert(ManagedNode(tag: "span", id: i)).unwrap())
    doAssert s.len == 1000
    for i in 0 ..< 500:
      discard s.remove(ids[i])
    doAssert s.len == 500
    s.clear()
    doAssert s.len == 0
    s.deinit()
  echo "[OK] 14: testWithLeakCheck 1000 nodes verified"

  # Test 15: SlabId distinct comparison and formatting
  block:
    let id1 = SlabId(5)
    let id2 = SlabId(5)
    let id3 = SlabId(6)
    doAssert id1 == id2
    doAssert not (id1 == id3)
    doAssert $id1 == "SlabId(5)"
    echo "[OK] 15: SlabId equality and formatting"

  echo "=== ALL 15 SLAB TESTS PASSED WITH 0 LEAKS ==="

when isMainModule:
  runSlabTests()
