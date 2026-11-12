import std/[strformat, hashes]
import corex/[allocators, result, adt, testing, memory]
import corex/bufmap

type
  CustomKey = object
    id: int
    val: int

  ManagedRef = ref object
    data: string

proc hash(k: CustomKey): Hash {.raises: [].} =
  # Force collision for custom key testing
  Hash(42)

proc runBufMapTests() =
  echo "=== RUNNING BUFMAP[K, V] UNIT TESTS ==="

  # Test 1: Basic Empty Initialization
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, int](alloc, 16).unwrap()
    doAssert m.len == 0
    doAssert m.isEmpty
    doAssert not m.contains(10)
    doAssert m.get(10).isNone
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: Empty initialization and queries"

  # Test 2: Single element insert and get
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, string](alloc, 16).unwrap()
    doAssert m.put(1, "one").isOk
    doAssert m.len == 1
    doAssert not m.isEmpty
    doAssert m.contains(1)
    let opt = m.get(1)
    doAssert opt.isSome
    doAssert opt.get() == "one"
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Single element insert and get"

  # Test 3: Overwrite existing key
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, string](alloc, 16).unwrap()
    discard m.put(1, "first")
    discard m.put(1, "updated")
    doAssert m.len == 1
    doAssert m.get(1).get() == "updated"
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: Overwrite existing key"

  # Test 4: Deletion
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, string](alloc, 16).unwrap()
    discard m.put(1, "one")
    discard m.put(2, "two")
    doAssert m.len == 2
    doAssert m.del(1) == true
    doAssert m.len == 1
    doAssert not m.contains(1)
    doAssert m.contains(2)
    doAssert m.del(1) == false
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: Delete element"

  # Test 5: Clear
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, string](alloc, 16).unwrap()
    for i in 1 .. 10:
      discard m.put(i, "val" & $i)
    doAssert m.len == 10
    m.clear()
    doAssert m.len == 0
    doAssert m.isEmpty
    doAssert not m.contains(1)
    # Can insert again after clear
    discard m.put(99, "new")
    doAssert m.len == 1
    doAssert m.get(99).get() == "new"
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Clear and re-insertion"

  # Test 6: Grow beyond initial capacity
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, int](alloc, 16).unwrap()
    let initialCap = m.cap
    for i in 0 ..< 1000:
      discard m.put(i, i * 10)
    doAssert m.len == 1000
    doAssert m.cap > initialCap
    for i in 0 ..< 1000:
      let v = m.get(i)
      doAssert v.isSome and v.get() == i * 10
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: Grow 16 -> 1000+ elements"

  # Test 7: Hash collisions (all keys map to same hash)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[CustomKey, int](alloc, 32).unwrap()
    for i in 0 ..< 50:
      let k = CustomKey(id: i, val: i * 2)
      discard m.put(k, i)
    doAssert m.len == 50
    for i in 0 ..< 50:
      let k = CustomKey(id: i, val: i * 2)
      doAssert m.contains(k)
      doAssert m.get(k).get() == i
    for i in 0 ..< 25:
      let k = CustomKey(id: i, val: i * 2)
      doAssert m.del(k)
    doAssert m.len == 25
    for i in 25 ..< 50:
      let k = CustomKey(id: i, val: i * 2)
      doAssert m.contains(k)
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Linear probing with heavy hash collisions"

  # Test 8: OOM with FixedBufferAllocator
  block:
    var buffer: array[16, byte]
    var fixed = initFixedBufferAllocator(addr buffer[0], buffer.len)
    let alloc = fixed.allocator()
    let res = initBufMap[int, int](alloc, 128)
    doAssert res.isErr, "Expected OOM error with 16 byte buffer"
    echo "[OK] 08: OOM protection on initBufMap"

  # Test 9: Copy semantics
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m1 = initBufMap[string, int](alloc, 16).unwrap()
    discard m1.put("apple", 10)
    discard m1.put("banana", 20)

    var m2 = m1 # triggers =copy
    doAssert m2.len == 2
    doAssert m2.get("apple").get() == 10
    doAssert m2.get("banana").get() == 20
    discard m2.put("cherry", 30)
    doAssert m2.len == 3
    doAssert m1.len == 2 # m1 unaffected

    m1.deinit()
    m2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 09: Value copy (=copy) deep isolation"

  # Test 10: Sink / Move semantics
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m1 = initBufMap[string, int](alloc, 16).unwrap()
    discard m1.put("hello", 42)

    var m2 = move(m1) # triggers =sink
    doAssert m2.len == 1
    doAssert m2.get("hello").get() == 42
    doAssert m1.len == 0

    m1.deinit()
    m2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 10: Sink / Move semantics"

  # Test 11: Scope-based RAII destruction (=destroy without manual deinit)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var m = initBufMap[string, string](alloc, 32).unwrap()
      for i in 0 ..< 100:
        discard m.put("k" & $i, "v" & $i)
    # Exited scope, =destroy should have cleaned everything
    doAssert not tracker.hasLeaks()
    echo "[OK] 11: Scope-based RAII automatic destruction"

  # Test 12: Managed ref objects in values
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var m = initBufMap[int, ManagedRef](alloc, 16).unwrap()
      for i in 0 ..< 50:
        discard m.put(i, ManagedRef(data: "node_" & $i))
      doAssert m.del(10)
      m.clear()
      discard m.put(100, ManagedRef(data: "final"))
    doAssert not tracker.hasLeaks()
    echo "[OK] 12: Ref objects in values correctly managed without leaks"

  # Test 13: testWithLeakCheck macro integration
  testWithLeakCheck("BufMap 1000 items put + clear + deinit"):
    var m = initBufMap[string, int](testAlloc, 64).unwrap()
    for i in 0 ..< 1000:
      discard m.put("key_" & $i, i)
    doAssert m.len == 1000
    m.clear()
    doAssert m.len == 0
    m.deinit()
  echo "[OK] 13: testWithLeakCheck 1000 elements verified"

  # Test 14: Iterators pairs, keys, values
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[string, int](alloc, 16).unwrap()
    discard m.put("a", 1)
    discard m.put("b", 2)
    discard m.put("c", 3)

    var sum = 0
    for k, v in m.pairs:
      sum += v
    doAssert sum == 6

    var keyCount = 0
    for k in keys(m):
      inc(keyCount)
    doAssert keyCount == 3

    var valSum = 0
    for v in values(m):
      valSum += v
    doAssert valSum == 6
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 14: Iterators (pairs, keys, values)"

  # Test 15: Edge cases: delete all then insert again
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var m = initBufMap[int, int](alloc, 16).unwrap()
    for i in 1 .. 5:
      discard m.put(i, i * 100)
    for i in 1 .. 5:
      doAssert m.del(i)
    doAssert m.len == 0
    for i in 1 .. 5:
      discard m.put(i, i * 200)
    doAssert m.len == 5
    for i in 1 .. 5:
      doAssert m.get(i).get() == i * 200
    m.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 15: Delete all followed by reinsertion"

  echo "=== ALL 15 BUFMAP TESTS PASSED WITH 0 LEAKS ==="

when isMainModule:
  runBufMapTests()
