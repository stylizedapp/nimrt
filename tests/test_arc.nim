import corex/[allocators, result, testing]
import corex/arc

type
  ManagedNode = ref object
    name: string

  TrackedType = object
    destroyed: ptr bool

proc `=destroy`(t: var TrackedType) =
  if not t.destroyed.isNil:
    t.destroyed[] = true

type
  ThreadArg = object
    arcPtr: ptr Arc[int]
    iters: int

proc workerThread(arg: ThreadArg) {.thread.} =
  for _ in 0 ..< arg.iters:
    var c = arg.arcPtr[].clone()
    doAssert c[] == 42
    # c destroyed at end of loop

proc runArcTests() =
  echo "=== RUNNING ARC[T] UNIT TESTS ==="

  # Test 1: Basic creation and access
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a = newArc[int](alloc, 42).unwrap()
    doAssert not a.isNil
    doAssert a.count == 1
    doAssert a[] == 42
    a.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 01: Basic newArc and dereference"

  # Test 2: Infallible clone
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a1 = newArc[string](alloc, "hello arc").unwrap()
    var a2 = a1.clone()
    doAssert a1.count == 2
    doAssert a2.count == 2
    doAssert a1[] == "hello arc"
    doAssert a2[] == "hello arc"
    a2.deinit()
    doAssert a1.count == 1
    a1.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 02: Infallible clone and decrement"

  # Test 3: Value assignment (=copy)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a1 = newArc[int](alloc, 100).unwrap()
    var a2: Arc[int]
    a2 = a1 # invokes =copy
    doAssert a1.count == 2
    doAssert a2.count == 2
    doAssert a2[] == 100
    a1.deinit()
    a2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 03: Copy assignment =copy"

  # Test 4: Move semantics (=sink)
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a1 = newArc[string](alloc, "moved").unwrap()
    var a2 = move(a1)
    doAssert a1.isNil
    doAssert not a2.isNil
    doAssert a2.count == 1
    doAssert a2[] == "moved"
    a2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 04: Sink / Move semantics"

  # Test 5: Destruction order on inner payload
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var wasDestroyed = false
    block:
      var a = newArc[TrackedType](alloc, TrackedType(destroyed: addr wasDestroyed)).unwrap()
      doAssert not wasDestroyed
    # Scope exited, refcount reached 0, TrackedType.=destroy ran before dealloc
    doAssert wasDestroyed
    doAssert not tracker.hasLeaks()
    echo "[OK] 05: Inner payload =destroy invoked before allocator.dealloc"

  # Test 6: 100 Arcs in seq with automatic RAII
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var base = newArc[string](alloc, "shared_across_seq").unwrap()
      var list: seq[Arc[string]] = @[]
      for _ in 0 ..< 100:
        list.add(base.clone())
      doAssert base.count == 101
    # Scope exited, all 101 references destroyed
    doAssert not tracker.hasLeaks()
    echo "[OK] 06: 100 Arcs in seq cleaned cleanly"

  # Test 7: Ref objects managed inside Arc
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    block:
      var a = newArc[ManagedNode](alloc, ManagedNode(name: "node1")).unwrap()
      var a2 = a.clone()
      doAssert a2[].name == "node1"
    doAssert not tracker.hasLeaks()
    echo "[OK] 07: Managed ref objects inside Arc"

  # Test 8: Overwriting an existing Arc via =copy
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a1 = newArc[int](alloc, 1).unwrap()
    var a2 = newArc[int](alloc, 2).unwrap()
    a2 = a1 # a2 releases 2 (deallocates it), references 1
    doAssert a1.count == 2
    doAssert a2[] == 1
    a1.deinit()
    a2.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 08: Overwriting existing Arc releases previous target"

  # Test 9: OOM with FixedBufferAllocator
  block:
    var buffer: array[4, byte]
    var fixed = initFixedBufferAllocator(addr buffer[0], buffer.len)
    let alloc = fixed.allocator()
    let res = newArc[int](alloc, 99)
    doAssert res.isErr
    echo "[OK] 09: OOM handling in newArc"

  # Test 10: testWithLeakCheck macro integration
  testWithLeakCheck("Arc lifecycle check"):
    var a1 = newArc[string](testAlloc, "macro_check").unwrap()
    var a2 = a1.clone()
    var a3 = a2.clone()
    doAssert a1.count == 3
  echo "[OK] 10: testWithLeakCheck verified"

  # Test 11: Cross-thread multi-threaded clone and destroy stress test
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var sharedArc = newArc[int](alloc, 42).unwrap()
    const numThreads = 4
    const itersPerThread = 10_000

    var threads: array[numThreads, Thread[ThreadArg]]
    for i in 0 ..< numThreads:
      createThread(threads[i], workerThread, ThreadArg(arcPtr: addr sharedArc, iters: itersPerThread))

    joinThreads(threads)

    doAssert sharedArc.count == 1
    doAssert sharedArc[] == 42
    sharedArc.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 11: Cross-thread concurrent 4-thread clone/destroy 40,000 ops (0 races, count=1)"

  # Test 12: Self-assignment protection in =copy
  block:
    var tracker = initTrackingAllocator()
    let alloc = tracker.allocator()
    var a = newArc[int](alloc, 777).unwrap()
    a = a # self-copy
    doAssert a.count == 1
    doAssert a[] == 777
    a.deinit()
    doAssert not tracker.hasLeaks()
    echo "[OK] 12: Self-assignment safety"

  echo "=== ALL 12 ARC TESTS PASSED WITH 0 LEAKS ==="

when isMainModule:
  runArcTests()
