## corex/arc — Thread-Safe Reference-Counted Smart Pointer (`Arc[T]`)
##
## Provides deterministic, allocator-controlled reference counting with atomic operations:
## - `Arc[T]`: Copyable, thread-safe reference counted smart pointer.
## - `clone()`: Non-failing atomic increment for zero-cost sharing.
## - Full ARC/ORC lifecycle integration (=destroy, =copy, =sink, =wasMoved).
##
## NOTE: `Arc[T]` manages thread-safe refcounts. For cross-thread sharing,
## `T` should be Send / safe to access concurrently across threads.

import std/atomics
import ./allocators
import ./result

type
  ArcInner*[T] = object
    refcount*: Atomic[int]
    data*: T

  Arc*[T] = object
    inner*: ptr ArcInner[T]
    alloc*: Allocator

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*[T](a: var Arc[T]) {.raises: [].} =
  if not a.inner.isNil:
    let prev = a.inner.refcount.fetchSub(1, MemoryOrder.moAcquireRelease)
    if prev == 1:
      # Refcount reached 0: Invoke =destroy on inner data, then deallocate backing memory
      `=destroy`(a.inner.data)
      if not a.alloc.freeFn.isNil:
        a.alloc.dealloc(a.inner, sizeof(ArcInner[T]))
    a.inner = nil

proc `=wasMoved`*[T](a: var Arc[T]) {.inline, raises: [].} =
  a.inner = nil

proc `=sink`*[T](dest: var Arc[T], src: Arc[T]) {.raises: [].} =
  if dest.inner != src.inner:
    `=destroy`(dest)
  dest.inner = src.inner
  dest.alloc = src.alloc

proc `=copy`*[T](dest: var Arc[T], src: Arc[T]) {.raises: [].} =
  if dest.inner == src.inner:
    return
  if not src.inner.isNil:
    discard src.inner.refcount.fetchAdd(1, MemoryOrder.moRelaxed)
  if not dest.inner.isNil:
    let prev = dest.inner.refcount.fetchSub(1, MemoryOrder.moAcquireRelease)
    if prev == 1:
      `=destroy`(dest.inner.data)
      if not dest.alloc.freeFn.isNil:
        dest.alloc.dealloc(dest.inner, sizeof(ArcInner[T]))
  dest.inner = src.inner
  dest.alloc = src.alloc

# =============================================================================
# Construction & Operations
# =============================================================================

proc newArc*[T](alloc: Allocator, val: sink T): Result[Arc[T], AllocError] {.raises: [].} =
  ## Allocates backing memory via `alloc.rawAlloc`, initializes refcount to 1,
  ## and moves `val` into inner.data.
  let raw = ?alloc.rawAlloc(sizeof(ArcInner[T]), max(alignof(ArcInner[T]), 8))
  zeroMem(raw, sizeof(ArcInner[T]))
  let innerPtr = cast[ptr ArcInner[T]](raw)
  innerPtr.refcount.store(1, MemoryOrder.moRelaxed)
  copyMem(addr innerPtr.data, addr val, sizeof(T))
  wasMoved(val)
  ok[Arc[T], AllocError](Arc[T](inner: innerPtr, alloc: alloc))

proc clone*[T](a: Arc[T]): Arc[T] {.inline, raises: [].} =
  ## Atomically increments refcount and returns an Arc referencing the same data.
  ## Infallible: never raises or fails.
  if not a.inner.isNil:
    discard a.inner.refcount.fetchAdd(1, MemoryOrder.moRelaxed)
  Arc[T](inner: a.inner, alloc: a.alloc)

proc deinit*[T](a: var Arc[T]) {.inline, raises: [].} =
  `=destroy`(a)

proc `[]`*[T](a: Arc[T]): lent T {.inline, raises: [].} =
  doAssert not a.inner.isNil, "Attempted to dereference nil Arc[T]"
  a.inner.data

proc count*[T](a: Arc[T]): int {.inline, raises: [].} =
  if a.inner.isNil: 0 else: a.inner.refcount.load(MemoryOrder.moAcquire)

proc isNil*[T](a: Arc[T]): bool {.inline, raises: [].} =
  a.inner.isNil

proc ptrVal*[T](a: Arc[T]): ptr T {.inline, raises: [].} =
  if a.inner.isNil: nil else: addr a.inner.data
