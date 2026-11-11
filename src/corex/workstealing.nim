## corex/workstealing — High-Performance Chase-Lev Lock-Free Work-Stealing Deque
##
## Provides a zero-allocation steady-state, lock-free work-stealing deque based on the
## dynamic circular array Chase-Lev algorithm with weak memory model fence optimizations
## (Chase & Lev SPAA '05; Le, Pop, Cohen, Nardelli PPoPP '13):
##
## - Model: Single-producer (owner thread) Multi-consumer (thief threads).
## - Owner operations:
##   - `push`: Fast LIFO push to bottom. Amortized O(1), dynamically expands buffer.
##   - `pop`: Fast LIFO pop from bottom. O(1) wait-free when uncontended, handles race
##     with thieves using atomic SeqCst fences and compareExchange on top.
## - Thief operations:
##   - `steal`: Lock-free FIFO steal from top using atomic compareExchange.
## - Cache-aligned fields: 64-byte alignment on `bottom`, `top`, and `buffer` to eliminate
##   false sharing between owner and thief threads.
## - Zero memory leaks under --mm:orc --threads:on --panics:on.

import std/atomics
import std/sysatomics
import std/typetraits
import ./adt

export atomics.Atomic
export sysatomics.cpuRelax
export typetraits.supportsCopyMem
export adt.Option, adt.Some, adt.None, adt.some, adt.none, adt.isSome, adt.isNone, adt.get, adt.getOr

const CacheLineSize = 64

type
  JobProc* = proc(arg: pointer) {.nimcall, gcsafe.}

  Job* = object
    ## Unit of executable work in the thread pool and work-stealing schedulers.
    fn*: JobProc
    arg*: pointer
    cleanup*: JobProc

  Buffer[T] = object
    capacity: int
    mask: int64
    data: ptr UncheckedArray[T]

  WorkStealDeque*[T] = object
    ## Lock-free single-producer multi-consumer Chase-Lev work-stealing deque.
    bottom {.align: CacheLineSize.}: Atomic[int64]
    padBottom: array[CacheLineSize - sizeof(Atomic[int64]), byte]

    top {.align: CacheLineSize.}: Atomic[int64]
    padTop: array[CacheLineSize - sizeof(Atomic[int64]), byte]

    buffer {.align: CacheLineSize.}: Atomic[ptr Buffer[T]]
    retired: ptr UncheckedArray[ptr Buffer[T]]
    retiredCap: int
    retiredCount: int
    padBuffer: array[CacheLineSize - sizeof(Atomic[ptr Buffer[T]]) - sizeof(pointer) - sizeof(int)*2, byte]

  JobDeque* = WorkStealDeque[Job]

proc `=copy`*[T](dest: var WorkStealDeque[T], src: WorkStealDeque[T]) {.
  error: "WorkStealDeque cannot be copied; pass by pointer or var reference".}

# =============================================================================
# Helper Utilities
# =============================================================================

func nextPowerOfTwo(n: int): int {.inline.} =
  if n <= 1: return 1
  var v = n - 1
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  v = v or (v shr 8)
  v = v or (v shr 16)
  when sizeof(int) == 8:
    v = v or (v shr 32)
  return v + 1

proc initJob*(fn: JobProc, arg: pointer = nil, cleanup: JobProc = nil): Job {.inline.} =
  Job(fn: fn, arg: arg, cleanup: cleanup)

proc execute*(job: var Job) {.inline.} =
  ## Executes the job function and invokes cleanup (if provided).
  if job.fn != nil:
    try:
      job.fn(job.arg)
    except CatchableError, Defect:
      discard
    finally:
      if job.cleanup != nil:
        job.cleanup(job.arg)

# =============================================================================
# Buffer Management & Lifecycle
# =============================================================================

proc allocateBuffer[T](cap: int): ptr Buffer[T] =
  result = cast[ptr Buffer[T]](allocShared0(sizeof(Buffer[T])))
  result.capacity = cap
  result.mask = int64(cap - 1)
  result.data = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * cap))

proc freeBuffer[T](buf: ptr Buffer[T]) =
  if buf != nil:
    if buf.data != nil:
      deallocShared(buf.data)
      buf.data = nil
    deallocShared(buf)

proc grow[T](deque: var WorkStealDeque[T], b, t: int64) =
  let oldBuf = deque.buffer.load(moRelaxed)
  let oldCap = oldBuf.capacity
  let newCap = oldCap * 2
  let newBuf = allocateBuffer[T](newCap)

  # Copy existing active range [t, b)
  var i = t
  while i < b:
    let oldSlot = int(i and oldBuf.mask)
    let newSlot = int(i and newBuf.mask)
    copyMem(addr newBuf.data[newSlot], addr oldBuf.data[oldSlot], sizeof(T))
    inc(i)

  # Retire oldBuf for safe reclamation upon deque destruction
  if deque.retiredCount == deque.retiredCap:
    let newRetCap = if deque.retiredCap == 0: 16 else: deque.retiredCap * 2
    let newRet = cast[ptr UncheckedArray[ptr Buffer[T]]](allocShared0(sizeof(ptr Buffer[T]) * newRetCap))
    if deque.retired != nil and deque.retiredCount > 0:
      copyMem(newRet, deque.retired, sizeof(ptr Buffer[T]) * deque.retiredCount)
      deallocShared(deque.retired)
    deque.retired = newRet
    deque.retiredCap = newRetCap

  deque.retired[deque.retiredCount] = oldBuf
  inc(deque.retiredCount)

  # Store new buffer with Release ordering
  atomics.fence(moRelease)
  deque.buffer.store(newBuf, moRelease)

proc initWorkStealDeque*[T](deque: var WorkStealDeque[T], initialCapacity: int = 64) =
  ## Initializes an existing WorkStealDeque in-place.
  when not supportsCopyMem(T):
    {.error: "WorkStealDeque[T] requires POD (supportsCopyMem); got " & $T.}
  let cap = max(16, nextPowerOfTwo(initialCapacity))
  let buf = allocateBuffer[T](cap)
  deque.bottom.store(0, moRelaxed)
  deque.top.store(0, moRelaxed)
  deque.buffer.store(buf, moRelaxed)
  deque.retired = nil
  deque.retiredCap = 0
  deque.retiredCount = 0

proc initWorkStealDeque*[T](initialCapacity: int = 64): WorkStealDeque[T] =
  ## Creates and initializes a new WorkStealDeque value.
  when not supportsCopyMem(T):
    {.error: "WorkStealDeque[T] requires POD (supportsCopyMem); got " & $T.}
  initWorkStealDeque(result, initialCapacity)

proc newWorkStealDeque*[T](initialCapacity: int = 64): ptr WorkStealDeque[T] =
  ## Allocates and initializes a new WorkStealDeque on the shared heap.
  when not supportsCopyMem(T):
    {.error: "WorkStealDeque[T] requires POD (supportsCopyMem); got " & $T.}
  result = cast[ptr WorkStealDeque[T]](allocShared0(sizeof(WorkStealDeque[T])))
  initWorkStealDeque(result[], initialCapacity)

proc destroy*[T](deque: var WorkStealDeque[T]) =
  ## Reclaims all buffers and cleans up remaining items.
  ## Safe to call multiple times (idempotent).
  let cur = deque.buffer.load(moRelaxed)
  if cur != nil:
    let t = deque.top.load(moRelaxed)
    let b = deque.bottom.load(moRelaxed)
    if b > t and cur.data != nil:
      var i = t
      while i < b:
        let slot = int(i and cur.mask)
        when T is Job:
          if cur.data[slot].cleanup != nil:
            cur.data[slot].cleanup(cur.data[slot].arg)
        elif compiles((var x: T; `=destroy`(x))):
          `=destroy`(cur.data[slot])
        inc(i)
    freeBuffer(cur)
    deque.buffer.store(nil, moRelaxed)

  if deque.retired != nil:
    for i in 0 ..< deque.retiredCount:
      freeBuffer(deque.retired[i])
    deallocShared(deque.retired)
    deque.retired = nil
    deque.retiredCount = 0
    deque.retiredCap = 0

proc `=destroy`*[T](deque: var WorkStealDeque[T]) =
  destroy(deque)

proc destroy*[T](deque: ptr WorkStealDeque[T]) {.inline.} =
  ## Destroys the contents of a pointer-referenced WorkStealDeque without freeing the pointer itself.
  if deque != nil:
    destroy(deque[])

proc destroyWorkStealDeque*[T](deque: ptr WorkStealDeque[T]) =
  ## Destroys a heap-allocated WorkStealDeque and frees its memory.
  if deque != nil:
    destroy(deque[])
    deallocShared(deque)

# =============================================================================
# Owner Operations (Single Producer)
# =============================================================================

proc push*[T](deque: var WorkStealDeque[T], item: sink T) =
  ## Pushes an item to the bottom of the deque (LIFO order for owner).
  ## Must ONLY be called by the owner thread.
  ## Expands the internal circular buffer dynamically when capacity is reached.
  var b = deque.bottom.load(moRelaxed)
  var t = deque.top.load(moAcquire)
  var buf = deque.buffer.load(moRelaxed)

  if (b - t) >= int64(buf.capacity - 1):
    deque.grow(b, t)
    buf = deque.buffer.load(moRelaxed)

  let slot = int(b and buf.mask)
  buf.data[slot] = item
  atomics.fence(moRelease)
  deque.bottom.store(b + 1, moRelease)

proc push*[T](deque: ptr WorkStealDeque[T], item: sink T) {.inline.} =
  push(deque[], item)

proc pop*[T](deque: var WorkStealDeque[T], item: var T): bool =
  ## Pops an item from the bottom of the deque (LIFO order for owner).
  ## Must ONLY be called by the owner thread.
  ## Returns true if an item was popped into `item`, false if empty.
  var b = deque.bottom.load(moRelaxed)
  let buf = deque.buffer.load(moRelaxed)
  dec(b)
  deque.bottom.store(b, moRelaxed)
  atomics.fence(moSequentiallyConsistent)
  var t = deque.top.load(moRelaxed)

  if t <= b:
    # Deque is not empty
    if t == b:
      # Exactly 1 element remaining: race with thief threads!
      var expectedTop = t
      let won = deque.top.compareExchange(expectedTop, t + 1, moSequentiallyConsistent, moRelaxed)
      deque.bottom.store(t + 1, moRelaxed)
      if won:
        let slot = int(b and buf.mask)
        copyMem(addr item, addr buf.data[slot], sizeof(T))
        return true
      else:
        return false
    else:
      # More than 1 element: no race with thieves
      let slot = int(b and buf.mask)
      copyMem(addr item, addr buf.data[slot], sizeof(T))
      return true
  else:
    # Deque was already empty
    deque.bottom.store(t, moRelaxed)
    return false

proc pop*[T](deque: var WorkStealDeque[T]): Option[T] =
  ## Ergonomic Option pop: Returns Some(item) or None.
  var val: T
  if deque.pop(val):
    result = some(val)
  else:
    result = none(T)

proc pop*[T](deque: ptr WorkStealDeque[T], item: var T): bool {.inline.} =
  pop(deque[], item)

proc pop*[T](deque: ptr WorkStealDeque[T]): Option[T] {.inline.} =
  pop(deque[])

# =============================================================================
# Thief Operations (Multi-Consumer)
# =============================================================================

proc steal*[T](deque: var WorkStealDeque[T], item: var T): bool =
  ## Steals an item from the top of the deque (FIFO order for thieves).
  ## May be called concurrently by any number of thief threads.
  ## Lock-free: uses atomic SeqCst fences and compareExchange.
  ## Returns true if an item was stolen into `item`, false if empty or race lost.
  var t = deque.top.load(moAcquire)
  atomics.fence(moSequentiallyConsistent)
  var b = deque.bottom.load(moAcquire)

  if t < b:
    let buf = deque.buffer.load(moAcquire)
    let slot = int(t and buf.mask)

    var val: T
    copyMem(addr val, addr buf.data[slot], sizeof(T))

    var expectedTop = t
    if deque.top.compareExchange(expectedTop, t + 1, moSequentiallyConsistent, moRelaxed):
      copyMem(addr item, addr val, sizeof(T))
      zeroMem(addr val, sizeof(T))
      return true
    else:
      zeroMem(addr val, sizeof(T))
      return false

  return false

proc steal*[T](deque: var WorkStealDeque[T]): Option[T] =
  ## Ergonomic Option steal: Returns Some(item) or None.
  var val: T
  if deque.steal(val):
    result = some(val)
  else:
    result = none(T)

proc steal*[T](deque: ptr WorkStealDeque[T], item: var T): bool {.inline.} =
  steal(deque[], item)

proc steal*[T](deque: ptr WorkStealDeque[T]): Option[T] {.inline.} =
  steal(deque[])

# =============================================================================
# Queue Inspection
# =============================================================================

proc len*[T](deque: var WorkStealDeque[T]): int {.inline.} =
  ## Returns the approximate number of items currently in the deque.
  let b = deque.bottom.load(moRelaxed)
  let t = deque.top.load(moRelaxed)
  if b > t: int(b - t) else: 0

proc len*[T](deque: ptr WorkStealDeque[T]): int {.inline.} =
  len(deque[])

proc empty*[T](deque: var WorkStealDeque[T]): bool {.inline.} =
  deque.len == 0

proc empty*[T](deque: ptr WorkStealDeque[T]): bool {.inline.} =
  deque[].len == 0

proc capacity*[T](deque: var WorkStealDeque[T]): int {.inline.} =
  ## Returns the current buffer capacity.
  let buf = deque.buffer.load(moRelaxed)
  if buf != nil: buf.capacity else: 0

proc capacity*[T](deque: ptr WorkStealDeque[T]): int {.inline.} =
  capacity(deque[])
