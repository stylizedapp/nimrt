## algx/heap — Cache-friendly Priority Queue & Binary Heap
##
## Features:
## - `BinaryHeap[T]`: Zero heap allocations when pre-allocated with `initBinaryHeap`
## - Fast branch-minimized hole-filtering sift-up and sift-down
## - Configurable min-heap (default) or max-heap
## - In-place O(N) Floyd's heapify for any openArray[T]

import corex/adt
export adt

when not defined(algxChecked):
  when defined(release) or defined(danger):
    {.push checks: off, optimization: speed.}
  else:
    {.push optimization: speed.}
else:
  {.push checks: on.}

type
  BinaryHeap*[T] = object
    data*: seq[T]
    isMinHeap*: bool

template higherPriority[T](a, b: T, isMinHeap: bool): bool =
  if isMinHeap: a < b else: b < a

proc siftUp[T](data: var openArray[T], startIdx, idx: int, isMinHeap: bool) {.inline.} =
  var child = idx
  var item = move(data[child])
  while child > startIdx:
    let parent = (child - 1) shr 1
    if higherPriority(item, data[parent], isMinHeap):
      data[child] = move(data[parent])
      child = parent
    else:
      break
  data[child] = move(item)

proc siftDown[T](data: var openArray[T], startIdx, endIdx: int, isMinHeap: bool) {.inline.} =
  var root = startIdx
  var item = move(data[root])
  let half = endIdx shr 1
  while root < half:
    var child = (root shl 1) + 1
    let right = child + 1
    if right < endIdx and higherPriority(data[right], data[child], isMinHeap):
      child = right
    if higherPriority(data[child], item, isMinHeap):
      data[root] = move(data[child])
      root = child
    else:
      break
  data[root] = move(item)

proc initBinaryHeap*[T](capacity: int = 16, isMinHeap: bool = true): BinaryHeap[T] {.inline.} =
  ## Initializes an empty BinaryHeap with pre-allocated capacity.
  ## Pushes up to `capacity` elements incur zero heap re-allocations.
  BinaryHeap[T](
    data: newSeqOfCap[T](max(capacity, 0)),
    isMinHeap: isMinHeap
  )

proc len*[T](h: BinaryHeap[T]): int {.inline.} =
  ## Returns the number of elements in the heap.
  h.data.len

proc isEmpty*[T](h: BinaryHeap[T]): bool {.inline.} =
  ## Returns true if the heap contains no elements.
  h.data.len == 0

proc tryPeek*[T](h: BinaryHeap[T]): Option[T] {.inline, raises: [].} =
  ## Inspects the root element without removing it, returning Some(root) or None if empty.
  ## Safe and non-panicking in all modes.
  if h.data.len == 0:
    return none(T)
  some[T](h.data[0])

proc peek*[T](h: BinaryHeap[T]): lent T {.inline, raises: [].} =
  ## Inspects the root element without removing it.
  ## In a min-heap, this is the minimum element; in a max-heap, the maximum.
  ## Guards against out-of-bounds access even when `checks: off` / `-d:danger`.
  if unlikely(h.data.len == 0):
    raiseAssert("BinaryHeap.peek: heap is empty")
  h.data[0]

proc push*[T](h: var BinaryHeap[T], item: sink T) {.inline.} =
  ## Inserts an element into the heap in O(log N) time.
  h.data.add(item)
  siftUp(h.data, 0, h.data.len - 1, h.isMinHeap)

proc tryPop*[T](h: var BinaryHeap[T]): Option[T] {.inline, raises: [].} =
  ## Removes and returns the root element wrapped in Some, or None if the heap is empty.
  ## Safe and non-panicking in all modes.
  if h.data.len == 0:
    return none(T)
  var last = h.data.pop()
  if h.data.len == 0:
    return some[T](last)
  var root = move(h.data[0])
  h.data[0] = move(last)
  siftDown(h.data, 0, h.data.len, h.isMinHeap)
  some[T](root)

proc pop*[T](h: var BinaryHeap[T]): T {.inline, raises: [].} =
  ## Removes and returns the root element from the heap in O(log N) time.
  ## Guards against out-of-bounds access even when `checks: off` / `-d:danger`.
  if unlikely(h.data.len == 0):
    raiseAssert("BinaryHeap.pop: heap is empty")
  var last = h.data.pop()
  if h.data.len == 0:
    return last
  result = move(h.data[0])
  h.data[0] = move(last)
  siftDown(h.data, 0, h.data.len, h.isMinHeap)

proc clear*[T](h: var BinaryHeap[T]) {.inline.} =
  ## Clears all elements from the heap while preserving allocated capacity.
  h.data.setLen(0)

proc heapify*[T](data: var openArray[T], isMinHeap: bool = true) {.inline.} =
  ## Converts an openArray into a valid heap in-place in O(N) time using Floyd's algorithm.
  let n = data.len
  if n <= 1:
    return
  for i in countdown((n shr 1) - 1, 0):
    siftDown(data, i, n, isMinHeap)

{.pop.}
