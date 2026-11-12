## tests/test_ironclad_heap.nim
## Independent adversarial verification suite for BinaryHeap and heapify.
## Verifies 50,000 random push/pop operations against HeapQueue ground truth,
## heap invariant preservation, and in-place heapify sorted order.

import std/[heapqueue, algorithm, strformat]
import algx/heap

# Independent PRNG
type
  Prng = object
    state: uint64

proc initPrng(seed: uint64 = 0x1357_9BDF_2468_ACE0'u64): Prng =
  Prng(state: seed)

proc nextU64(p: var Prng): uint64 =
  p.state = p.state + 0x9E37_79B9_7F4A_7C15'u64
  var z = p.state
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

proc nextInt(p: var Prng, minVal, maxVal: int): int =
  let span = uint64(maxVal - minVal + 1)
  minVal + int(p.nextU64() mod span)

# =============================================================================
# 1. 50,000 Randomized Operations: Min-Heap Property Test vs HeapQueue
# =============================================================================

proc testMinHeapStress() =
  echo "[test_ironclad_heap] Running 50,000 randomized ops on BinaryHeap (min-heap) vs HeapQueue..."

  var h = initBinaryHeap[int](capacity = 64, isMinHeap = true)
  var hq = initHeapQueue[int]()
  var prng = initPrng(0xACE1_BEEF_9876_5432'u64)

  const TotalOps = 50_000

  for op in 0 ..< TotalOps:
    let roll = prng.nextInt(0, 99)

    # 60% push, 40% pop (ensures heap grows and shrinks dynamically)
    if roll < 60 or h.len == 0:
      let val = prng.nextInt(-100_000, 100_000)
      h.push(val)
      hq.push(val)
    else:
      # Verify peek before popping
      let peekH = h.peek()
      let peekHq = hq[0]
      doAssert peekH == peekHq, &"Peek mismatch at op {op}: BinaryHeap={peekH}, HeapQueue={peekHq}"

      let poppedH = h.pop()
      let poppedHq = hq.pop()
      doAssert poppedH == poppedHq, &"Pop mismatch at op {op}: BinaryHeap={poppedH}, HeapQueue={poppedHq}"

    doAssert h.len == hq.len, &"Length mismatch at op {op}: BinaryHeap={h.len}, HeapQueue={hq.len}"

  # Empty the remaining heap and verify sorted order
  var prev = -2_000_000_000
  while h.len > 0:
    let val = h.pop()
    let refVal = hq.pop()
    doAssert val == refVal, "Remaining pop mismatch"
    doAssert val >= prev, &"Heap invariant violation on drain: {val} < {prev}"
    prev = val

  doAssert h.len == 0
  doAssert hq.len == 0

  echo "[test_ironclad_heap] Min-Heap 50,000 ops PASSED with 100% invariant consistency."

# =============================================================================
# 2. 50,000 Randomized Operations: Max-Heap Property Test
# =============================================================================

proc testMaxHeapStress() =
  echo "[test_ironclad_heap] Running 50,000 randomized ops on BinaryHeap (max-heap)..."

  var h = initBinaryHeap[int](capacity = 64, isMinHeap = false)
  var refHq = initHeapQueue[int]() # stores negated values to simulate max-heap
  var prng = initPrng(0x5432_10FE_DCBA_9876'u64)

  const TotalOps = 50_000

  for op in 0 ..< TotalOps:
    let roll = prng.nextInt(0, 99)

    if roll < 60 or h.len == 0:
      let val = prng.nextInt(-100_000, 100_000)
      h.push(val)
      refHq.push(-val)
    else:
      let peekH = h.peek()
      let peekRef = -refHq[0]
      doAssert peekH == peekRef, &"MaxHeap peek mismatch at op {op}: got {peekH}, expected {peekRef}"

      let poppedH = h.pop()
      let poppedRef = -refHq.pop()
      doAssert poppedH == poppedRef, &"MaxHeap pop mismatch at op {op}: got {poppedH}, expected {poppedRef}"

    doAssert h.len == refHq.len

  var prev = 2_000_000_000
  while h.len > 0:
    let val = h.pop()
    let refVal = -refHq.pop()
    doAssert val == refVal
    doAssert val <= prev, &"Max-heap invariant violation on drain: {val} > {prev}"
    prev = val

  echo "[test_ironclad_heap] Max-Heap 50,000 ops PASSED with 100% invariant consistency."

# =============================================================================
# 3. Heapify Verification (10,000 random elements)
# =============================================================================

proc testHeapify() =
  echo "[test_ironclad_heap] Testing heapify on 10,000 random elements..."

  var prng = initPrng(0x7777_8888_9999_AAAA'u64)
  const N = 10_000
  var data = newSeq[int](N)
  for i in 0 ..< N:
    data[i] = prng.nextInt(-1_000_000, 1_000_000)

  var sortedExpected = data
  sortedExpected.sort()

  # Test in-place heapify(var openArray[T])
  var heapifiedData = data
  heapify(heapifiedData)

  # 1. Verify binary heap invariant on the raw slice
  for i in 0 ..< N:
    let leftChild = 2 * i + 1
    let rightChild = 2 * i + 2
    if leftChild < N:
      doAssert heapifiedData[i] <= heapifiedData[leftChild],
        &"Heapify invariant violated at index {i}: parent={heapifiedData[i]} > leftChild={heapifiedData[leftChild]}"
    if rightChild < N:
      doAssert heapifiedData[i] <= heapifiedData[rightChild],
        &"Heapify invariant violated at index {i}: parent={heapifiedData[i]} > rightChild={heapifiedData[rightChild]}"

  # 2. Successive pops verification:
  # Load into BinaryHeap or pop sequentially to verify exact sorted order
  var heap = initBinaryHeap[int](capacity = N, isMinHeap = true)
  for val in heapifiedData:
    heap.push(val)

  var poppedElements = newSeq[int](N)
  for i in 0 ..< N:
    poppedElements[i] = heap.pop()

  doAssert poppedElements == sortedExpected, "Successive pops from heapified data did not match exact sorted order!"
  echo &"[test_ironclad_heap] Heapify on {N} elements PASSED: exact sorted order verified."

# =============================================================================
# 4. Clear and Edge Cases
# =============================================================================

proc testEdgeCases() =
  echo "[test_ironclad_heap] Testing clear and edge cases..."

  var h = initBinaryHeap[int](capacity = 4, isMinHeap = true)
  doAssert h.len == 0
  doAssert h.tryPeek().isNone()
  doAssert h.tryPop().isNone()

  h.push(42)
  doAssert h.len == 1
  doAssert h.tryPeek().isSome()
  doAssert h.tryPeek().get() == 42
  doAssert h.peek() == 42
  h.clear()
  doAssert h.len == 0
  doAssert h.tryPeek().isNone()
  doAssert h.tryPop().isNone()

  # Push duplicates
  for _ in 0 ..< 100:
    h.push(7)
  doAssert h.len == 100
  doAssert h.tryPeek().get() == 7
  for _ in 0 ..< 100:
    let popped = h.tryPop()
    doAssert popped.isSome()
    doAssert popped.get() == 7
  doAssert h.len == 0
  doAssert h.tryPop().isNone()

  echo "[test_ironclad_heap] Edge cases PASSED."

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  testMinHeapStress()
  testMaxHeapStress()
  testHeapify()
  testEdgeCases()
  echo "\n>>> [test_ironclad_heap] ALL TESTS PASSED UNCOMPROMISINGLY <<<"
