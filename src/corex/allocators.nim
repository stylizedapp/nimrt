## corex/allocators — Explicit Zig-style Allocators
##
## Provides deterministic, zero-overhead memory management:
## - `Allocator`: Polymorphic VTable interface (`allocFn`, `freeFn`, `resetFn`, `ctx`).
## - `FixedBufferAllocator`: Stack/static bump allocator without global heap calls.
## - `ArenaAllocator`: Linear region allocator with O(1) bulk reset.
## - `PoolAllocator`: Fixed-size chunk allocator with intrusive singly-linked free-list for O(1) alloc/free.
## - `PageAllocator`: Virtual memory page-aligned allocator (`VirtualAlloc` on Windows, `mmap` on POSIX).
## - `TrackingAllocator`: Decorator allocator tracking allocations, alignment, byte balance, and leak detection.
## - `destroy[T]`: Invokes `=destroy(p[])` before `freeFn` to cleanly release inner managed fields.

import ./result

type
  AllocError* = enum
    aeOutOfMemory = "OutOfMemory: allocator capacity exhausted"
    aeInvalidAlignment = "InvalidAlignment: alignment must be power of two"

  AllocFn* = proc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].}
  FreeFn* = proc(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].}
  ResetFn* = proc(ctx: pointer) {.nimcall, gcsafe, raises: [].}

  Allocator* = object
    ctx*: pointer
    allocFn*: AllocFn
    freeFn*: FreeFn
    resetFn*: ResetFn

proc alignForward*(addrVal: uint, align: uint): uint {.inline, raises: [].} =
  let mask = align - 1'u
  (addrVal + mask) and (not mask)

proc rawAlloc*(a: Allocator, size: int, align: int = 8): Result[pointer, AllocError] {.inline, raises: [].} =
  if (align and (align - 1)) != 0 or align <= 0:
    return err[pointer, AllocError](aeInvalidAlignment)
  if size <= 0:
    return ok[pointer, AllocError](nil)
  if a.allocFn.isNil:
    return err[pointer, AllocError](aeOutOfMemory)
  let p = a.allocFn(a.ctx, size, align)
  if p.isNil:
    return err[pointer, AllocError](aeOutOfMemory)
  ok[pointer, AllocError](p)

proc create*[T](a: Allocator, val: sink T): Result[ptr T, AllocError] {.inline, raises: [].} =
  let raw = ?a.rawAlloc(sizeof(T), alignof(T))
  zeroMem(raw, sizeof(T))
  let typedPtr = cast[ptr T](raw)
  # Bitwise move into fresh memory: `typedPtr[] = move(val)` would run `=destroy`
  # on the zeroed slot first, which is wrong for types whose zero state is not
  # "empty" (e.g. a POSIX fd 0 = stdin).
  copyMem(typedPtr, addr val, sizeof(T))
  wasMoved(val)
  ok[ptr T, AllocError](typedPtr)

proc allocSlice*[T](a: Allocator, len: int): Result[ptr UncheckedArray[T], AllocError] {.inline, raises: [].} =
  if len <= 0:
    return ok[ptr UncheckedArray[T], AllocError](nil)
  let raw = ?a.rawAlloc(sizeof(T) * len, alignof(T))
  zeroMem(raw, sizeof(T) * len)
  ok[ptr UncheckedArray[T], AllocError](cast[ptr UncheckedArray[T]](raw))

proc allocSlice*[T](a: Allocator, TType: typedesc[T], len: int): Result[ptr UncheckedArray[T], AllocError] {.inline, raises: [].} =
  allocSlice[T](a, len)

proc dealloc*(a: Allocator, p: pointer, size: int) {.inline, raises: [].} =
  if not p.isNil and not a.freeFn.isNil:
    a.freeFn(a.ctx, p, size)

proc destroy*[T](a: Allocator, p: ptr T) {.inline, raises: [].} =
  if not p.isNil:
    `=destroy`(p[])
    if not a.freeFn.isNil:
      a.freeFn(a.ctx, p, sizeof(T))

proc destroySlice*[T](a: Allocator, p: ptr UncheckedArray[T], len: int) {.inline, raises: [].} =
  if not p.isNil:
    for i in 0 ..< len:
      `=destroy`(p[i])
    if not a.freeFn.isNil and len > 0:
      a.freeFn(a.ctx, p, sizeof(T) * len)

proc reset*(a: Allocator) {.inline, raises: [].} =
  if not a.resetFn.isNil:
    a.resetFn(a.ctx)

# =============================================================================
# 1. FixedBufferAllocator (Stack / buffer bump allocator)
# =============================================================================

type
  FixedBufferAllocator* = object
    buffer*: ptr UncheckedArray[byte]
    capacity*: int
    offset*: int

proc initFixedBufferAllocator*(buffer: pointer, capacity: int): FixedBufferAllocator {.inline, raises: [].} =
  FixedBufferAllocator(
    buffer: cast[ptr UncheckedArray[byte]](buffer),
    capacity: capacity,
    offset: 0
  )

proc initFixedBufferAllocator*(buf: var openArray[byte]): FixedBufferAllocator {.inline, raises: [].} =
  FixedBufferAllocator(
    buffer: if buf.len > 0: cast[ptr UncheckedArray[byte]](addr buf[0]) else: nil,
    capacity: buf.len,
    offset: 0
  )

proc reset*(self: var FixedBufferAllocator) {.inline, raises: [].} =
  self.offset = 0

proc fbaAlloc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr FixedBufferAllocator](ctx)
  if self.buffer.isNil or size <= 0: return nil
  let baseAddr = cast[uint](self.buffer)
  let curAddr = baseAddr + uint(self.offset)
  let alignedAddr = alignForward(curAddr, uint(align))
  let newOffset = int(alignedAddr - baseAddr) + size
  if newOffset > self.capacity:
    return nil
  self.offset = newOffset
  cast[pointer](alignedAddr)

proc fbaFree(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].} =
  discard # No-op for linear bump buffer

proc fbaReset(ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr FixedBufferAllocator](ctx)
  self.offset = 0

proc allocator*(self: var FixedBufferAllocator): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: addr self,
    allocFn: fbaAlloc,
    freeFn: fbaFree,
    resetFn: fbaReset
  )

# =============================================================================
# 2. ArenaAllocator (Fast linear region allocator with O(1) bulk reset)
# =============================================================================

type
  ArenaAllocator* = object
    backing*: pointer
    capacity*: int
    offset*: int
    peakUsed*: int

proc initArena*(capacityBytes: int): ArenaAllocator {.raises: [].} =
  let mem = if capacityBytes > 0: allocShared0(capacityBytes) else: nil
  ArenaAllocator(
    backing: mem,
    capacity: capacityBytes,
    offset: 0,
    peakUsed: 0
  )

proc initArenaAllocator*(capacityBytes: int): ArenaAllocator {.inline, raises: [].} =
  initArena(capacityBytes)

proc deinit*(self: var ArenaAllocator) {.raises: [].} =
  if not self.backing.isNil:
    deallocShared(self.backing)
    self.backing = nil
    self.capacity = 0
    self.offset = 0

proc reset*(self: var ArenaAllocator) {.inline, raises: [].} =
  self.offset = 0

proc arenaAlloc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr ArenaAllocator](ctx)
  if self.backing.isNil or size <= 0: return nil
  let baseAddr = cast[uint](self.backing)
  let curAddr = baseAddr + uint(self.offset)
  let alignedAddr = alignForward(curAddr, uint(align))
  let newOffset = int(alignedAddr - baseAddr) + size
  if newOffset > self.capacity:
    return nil
  self.offset = newOffset
  if newOffset > self.peakUsed:
    self.peakUsed = newOffset
  cast[pointer](alignedAddr)

proc arenaFree(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].} =
  discard

proc arenaReset(ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr ArenaAllocator](ctx)
  self.offset = 0

proc allocator*(self: var ArenaAllocator): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: addr self,
    allocFn: arenaAlloc,
    freeFn: arenaFree,
    resetFn: arenaReset
  )

# =============================================================================
# 3. PoolAllocator (Fixed-size chunk allocator with intrusive free-list)
# =============================================================================

type
  PoolAllocator* = object
    rawBuffer*: pointer
    buffer*: ptr UncheckedArray[byte]
    capacity*: int
    chunkSize*: int
    alignment*: int
    head*: pointer
    totalChunks*: int
    freeChunks*: int
    ownsBuffer*: bool

proc initPoolAllocator*(buffer: pointer, totalSize: int, chunkSize: int, alignment: int = sizeof(pointer)): PoolAllocator {.raises: [].} =
  if buffer.isNil or totalSize <= 0 or chunkSize <= 0:
    return PoolAllocator()

  let reqAlign = if alignment <= 0: sizeof(pointer) else: alignment
  let align = max(reqAlign, sizeof(pointer))
  let rawAddr = cast[uint](buffer)
  let alignedBase = alignForward(rawAddr, uint(align))
  let adjustment = int(alignedBase - rawAddr)
  let usableSize = totalSize - adjustment
  
  let minChunk = max(chunkSize, sizeof(pointer))
  let chunkStride = int(alignForward(uint(minChunk), uint(align)))
  let count = if chunkStride > 0 and usableSize >= chunkStride: usableSize div chunkStride else: 0
  
  result = PoolAllocator(
    rawBuffer: buffer,
    buffer: cast[ptr UncheckedArray[byte]](alignedBase),
    capacity: totalSize,
    chunkSize: chunkStride,
    alignment: align,
    head: nil,
    totalChunks: count,
    freeChunks: count,
    ownsBuffer: false
  )

  if count > 0:
    var curr = alignedBase
    for i in 0 ..< count - 1:
      let nextPtr = curr + uint(chunkStride)
      cast[ptr pointer](curr)[] = cast[pointer](nextPtr)
      curr = nextPtr
    cast[ptr pointer](curr)[] = nil
    result.head = cast[pointer](alignedBase)

proc initPoolAllocator*(buf: var openArray[byte], chunkSize: int, alignment: int = sizeof(pointer)): PoolAllocator {.inline, raises: [].} =
  if buf.len == 0: PoolAllocator()
  else: initPoolAllocator(addr buf[0], buf.len, chunkSize, alignment)

proc initPoolAllocator*(totalSize: int, chunkSize: int, alignment: int = sizeof(pointer)): PoolAllocator {.raises: [].} =
  let mem = if totalSize > 0: allocShared0(totalSize) else: nil
  result = initPoolAllocator(mem, totalSize, chunkSize, alignment)
  result.ownsBuffer = true

proc deinit*(self: var PoolAllocator) {.raises: [].} =
  if self.ownsBuffer and not self.rawBuffer.isNil:
    deallocShared(self.rawBuffer)
    self.rawBuffer = nil
    self.buffer = nil
  self.head = nil
  self.totalChunks = 0
  self.freeChunks = 0
  self.capacity = 0

proc reset*(self: var PoolAllocator) {.raises: [].} =
  if self.totalChunks <= 0 or self.buffer.isNil:
    self.head = nil
    self.freeChunks = 0
    return
  let base = cast[uint](self.buffer)
  var curr = base
  for i in 0 ..< self.totalChunks - 1:
    let nextPtr = curr + uint(self.chunkSize)
    cast[ptr pointer](curr)[] = cast[pointer](nextPtr)
    curr = nextPtr
  cast[ptr pointer](curr)[] = nil
  self.head = cast[pointer](base)
  self.freeChunks = self.totalChunks

proc allocBlock*(self: var PoolAllocator): pointer {.inline, raises: [].} =
  if self.head.isNil:
    return nil
  let p = self.head
  self.head = cast[ptr pointer](p)[]
  dec(self.freeChunks)
  p

proc tryAllocBlock*(self: var PoolAllocator): Result[pointer, AllocError] {.inline, raises: [].} =
  let p = self.allocBlock()
  if p.isNil:
    err[pointer, AllocError](aeOutOfMemory)
  else:
    ok[pointer, AllocError](p)

proc freeBlock*(self: var PoolAllocator, p: pointer) {.inline, raises: [].} =
  if p.isNil: return
  cast[ptr pointer](p)[] = self.head
  self.head = p
  inc(self.freeChunks)

proc poolAlloc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr PoolAllocator](ctx)
  if size <= 0 or size > self.chunkSize or align > self.alignment:
    return nil
  self[].allocBlock()

proc poolFree(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr PoolAllocator](ctx)
  self[].freeBlock(p)

proc poolReset(ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr PoolAllocator](ctx)
  self[].reset()

proc allocator*(self: var PoolAllocator): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: addr self,
    allocFn: poolAlloc,
    freeFn: poolFree,
    resetFn: poolReset
  )

# =============================================================================
# 4. PageAllocator (Virtual memory page-aligned allocator)
# =============================================================================

when defined(windows):
  const
    MEM_COMMIT = 0x00001000'u32
    MEM_RESERVE = 0x00002000'u32
    MEM_RELEASE = 0x00008000'u32
    PAGE_READWRITE = 0x04'u32

  proc winVirtualAlloc(lpAddress: pointer, dwSize: int, flAllocationType: uint32, flProtect: uint32): pointer {.
    stdcall, dynlib: "kernel32", importc: "VirtualAlloc".}

  proc winVirtualFree(lpAddress: pointer, dwSize: int, dwFreeType: uint32): int32 {.
    stdcall, dynlib: "kernel32", importc: "VirtualFree".}
elif defined(posix):
  const
    PROT_READ = 0x1
    PROT_WRITE = 0x2
    MAP_PRIVATE = 0x02
    MAP_ANONYMOUS = 0x20

  proc posixMmap(address: pointer, len: int, prot: cint, flags: cint, fd: cint, offset: int): pointer {.
    importc: "mmap", header: "<sys/mman.h>".}
  proc posixMunmap(address: pointer, len: int): cint {.
    importc: "munmap", header: "<sys/mman.h>".}

type
  PageAllocator* = object
    pageSize*: int

proc initPageAllocator*(pageSize: int = 4096): PageAllocator {.inline, raises: [].} =
  PageAllocator(pageSize: if pageSize > 0: pageSize else: 4096)

proc pageAlloc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].} =
  if size <= 0: return nil
  when defined(windows):
    winVirtualAlloc(nil, size, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE)
  elif defined(posix):
    let p = posixMmap(nil, size, cint(PROT_READ or PROT_WRITE), cint(MAP_PRIVATE or MAP_ANONYMOUS), cint(-1), 0)
    if cast[int](p) == -1: nil else: p
  else:
    allocShared0(size)

proc pageFree(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].} =
  if p.isNil: return
  when defined(windows):
    discard winVirtualFree(p, 0, MEM_RELEASE)
  elif defined(posix):
    discard posixMunmap(p, size)
  else:
    deallocShared(p)

proc pageReset(ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  discard

proc allocator*(self: var PageAllocator): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: addr self,
    allocFn: pageAlloc,
    freeFn: pageFree,
    resetFn: pageReset
  )

proc pageAllocator*(): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: nil,
    allocFn: pageAlloc,
    freeFn: pageFree,
    resetFn: pageReset
  )

# =============================================================================
# 5. TrackingAllocator & Heap Allocator (Leak detector & alignment support)
# =============================================================================

type
  TrackHeader = object
    rawPtr: pointer
    totalSize: int
    reqSize: int
    pad: int

  TrackingAllocator* = object
    upstream*: Allocator
    allocCount*: int
    freeCount*: int
    bytesAllocated*: int
    bytesFreed*: int
    peakBytes*: int
    activeAllocs*: int
    activeBytes*: int

proc trackAlloc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].} =
  if size <= 0: return nil
  let self = cast[ptr TrackingAllocator](ctx)
  let effAlign = if align <= 0: sizeof(pointer) else: align
  let headerSize = sizeof(TrackHeader)
  let totalAllocSize = size + effAlign + headerSize
  let upstreamAlign = max(effAlign, sizeof(pointer))
  
  var raw: pointer
  if self.upstream.allocFn != nil:
    raw = self.upstream.allocFn(self.upstream.ctx, totalAllocSize, upstreamAlign)
  else:
    raw = allocShared0(totalAllocSize)
  
  if raw.isNil:
    return nil

  let rawAddr = cast[uint](raw)
  let userAddr = alignForward(rawAddr + uint(headerSize), uint(effAlign))
  let hdr = cast[ptr TrackHeader](userAddr - uint(headerSize))
  hdr.rawPtr = raw
  hdr.totalSize = totalAllocSize
  hdr.reqSize = size

  inc(self.allocCount)
  inc(self.activeAllocs)
  self.bytesAllocated += size
  self.activeBytes += size
  if self.activeBytes > self.peakBytes:
    self.peakBytes = self.activeBytes

  cast[pointer](userAddr)

proc trackFree(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].} =
  if p.isNil: return
  let self = cast[ptr TrackingAllocator](ctx)
  let headerSize = sizeof(TrackHeader)
  let hdr = cast[ptr TrackHeader](cast[uint](p) - uint(headerSize))
  let raw = hdr.rawPtr
  let totalAllocSize = hdr.totalSize
  let reqSize = hdr.reqSize
  let freedSize = if size > 0: size else: reqSize

  inc(self.freeCount)
  dec(self.activeAllocs)
  self.bytesFreed += freedSize
  self.activeBytes -= freedSize

  if self.upstream.freeFn != nil:
    self.upstream.freeFn(self.upstream.ctx, raw, totalAllocSize)
  elif self.upstream.allocFn == nil:
    deallocShared(raw)

proc trackReset(ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  let self = cast[ptr TrackingAllocator](ctx)
  if not self.upstream.resetFn.isNil:
    self.upstream.resetFn(self.upstream.ctx)
  self.activeAllocs = 0
  self.activeBytes = 0
  self.allocCount = 0
  self.freeCount = 0
  self.bytesAllocated = 0
  self.bytesFreed = 0

proc initTrackingAllocator*(): TrackingAllocator {.inline, raises: [].} =
  TrackingAllocator()

proc initTrackingAllocator*(upstream: Allocator): TrackingAllocator {.inline, raises: [].} =
  TrackingAllocator(upstream: upstream)

proc reset*(self: var TrackingAllocator) {.inline, raises: [].} =
  trackReset(addr self)

proc allocator*(self: var TrackingAllocator): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: addr self,
    allocFn: trackAlloc,
    freeFn: trackFree,
    resetFn: trackReset
  )

proc hasLeaks*(self: TrackingAllocator): bool {.inline, raises: [].} =
  self.activeAllocs != 0 or self.activeBytes != 0 or
    self.allocCount > self.freeCount or self.bytesAllocated > self.bytesFreed

# Global / Default Heap Allocator
proc heapAlloc(ctx: pointer, size: int, align: int): pointer {.nimcall, gcsafe, raises: [].} =
  if size <= 0: return nil
  let effAlign = if align <= 0: sizeof(pointer) else: align
  let headerSize = sizeof(TrackHeader)
  let totalAllocSize = size + effAlign + headerSize
  let raw = allocShared0(totalAllocSize)
  if raw.isNil: return nil
  let rawAddr = cast[uint](raw)
  let userAddr = alignForward(rawAddr + uint(headerSize), uint(effAlign))
  let hdr = cast[ptr TrackHeader](userAddr - uint(headerSize))
  hdr.rawPtr = raw
  hdr.totalSize = totalAllocSize
  hdr.reqSize = size
  cast[pointer](userAddr)

proc heapFree(ctx: pointer, p: pointer, size: int) {.nimcall, gcsafe, raises: [].} =
  if p.isNil: return
  let headerSize = sizeof(TrackHeader)
  let hdr = cast[ptr TrackHeader](cast[uint](p) - uint(headerSize))
  deallocShared(hdr.rawPtr)

proc heapReset(ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  discard

proc defaultHeapAllocator*(): Allocator {.inline, raises: [].} =
  Allocator(
    ctx: nil,
    allocFn: heapAlloc,
    freeFn: heapFree,
    resetFn: heapReset
  )

proc heapAllocator*(): Allocator {.inline, raises: [].} =
  defaultHeapAllocator()
