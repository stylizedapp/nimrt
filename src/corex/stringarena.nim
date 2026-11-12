## corex/stringarena — Zero-Heap Temporary String Arena with Bulk O(1) Reset
##
## Provides contiguous zero-copy `Span[byte]` interning for short-lived string tokens
## (HTML/CSS parsing, tokens, log formatting) with linear chunk growth
## and deterministic ARC/ORC lifecycle integration.

import ./allocators
import ./result
import ./containers
import ./memory

type
  ChunkHeader = object
    capacity: int

  StringArena* = object
    chunks*: BufSeq[ptr UncheckedArray[byte]]
    current*: ptr UncheckedArray[byte]
    currentCap*: int
    currentUsed*: int
    alloc*: Allocator

# =============================================================================
# Internal Chunk Helpers
# =============================================================================

proc allocateChunk(alloc: Allocator, capacity: int): Result[ptr UncheckedArray[byte], AllocError] {.raises: [].} =
  let totalSize = sizeof(ChunkHeader) + capacity
  let raw = ?alloc.rawAlloc(totalSize, 8)
  zeroMem(raw, totalSize)
  let hdr = cast[ptr ChunkHeader](raw)
  hdr.capacity = capacity
  let chunkPtr = cast[ptr UncheckedArray[byte]](cast[uint](raw) + uint(sizeof(ChunkHeader)))
  ok[ptr UncheckedArray[byte], AllocError](chunkPtr)

proc freeChunk(alloc: Allocator, chunkPtr: ptr UncheckedArray[byte]) {.raises: [].} =
  if chunkPtr.isNil or alloc.freeFn.isNil:
    return
  let raw = cast[pointer](cast[uint](chunkPtr) - uint(sizeof(ChunkHeader)))
  let cap = cast[ptr ChunkHeader](raw).capacity
  let totalSize = sizeof(ChunkHeader) + cap
  alloc.dealloc(raw, totalSize)

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*(s: var StringArena) {.raises: [].} =
  if s.chunks.len > 0 and not s.alloc.freeFn.isNil:
    for i in 0 ..< s.chunks.len:
      let p = s.chunks[i]
      if not p.isNil:
        freeChunk(s.alloc, p)
  `=destroy`(s.chunks)
  s.current = nil
  s.currentCap = 0
  s.currentUsed = 0

proc `=wasMoved`*(s: var StringArena) {.inline, raises: [].} =
  `=wasMoved`(s.chunks)
  s.current = nil
  s.currentCap = 0
  s.currentUsed = 0

proc `=sink`*(dest: var StringArena, src: StringArena) {.raises: [].} =
  if dest.current != src.current:
    `=destroy`(dest)
  dest.chunks = src.chunks
  dest.current = src.current
  dest.currentCap = src.currentCap
  dest.currentUsed = src.currentUsed
  dest.alloc = src.alloc

# =============================================================================
# Construction & Operations
# =============================================================================

proc initStringArena*(alloc: Allocator, initialChunkSize: int = 4096): Result[StringArena, AllocError] {.raises: [].} =
  let initSize = max(64, initialChunkSize)
  var seqRes = ?initBufSeq[ptr UncheckedArray[byte]](alloc, 4)
  let firstChunk = ?allocateChunk(alloc, initSize)
  ?seqRes.tryAdd(firstChunk)

  ok[StringArena, AllocError](StringArena(
    chunks: seqRes,
    current: firstChunk,
    currentCap: initSize,
    currentUsed: 0,
    alloc: alloc
  ))

proc deinit*(s: var StringArena) {.inline, raises: [].} =
  `=destroy`(s)

proc intern*(s: var StringArena, text: openArray[byte]): Result[Span[byte], AllocError] {.raises: [].} =
  ## Copies `text` into the current arena chunk and returns a non-owning `Span[byte]`.
  ## If `text` exceeds remaining chunk space, allocates a new chunk (>= 2x previous).
  ## WARNING: Returned Span[byte] becomes invalid upon `reset()` or `deinit()`.
  if text.len == 0:
    return ok[Span[byte], AllocError](span[byte]())

  if s.current.isNil or (s.currentUsed + text.len > s.currentCap):
    let newCap = max(if s.currentCap == 0: 4096 else: s.currentCap * 2, text.len)
    let newChunk = ?allocateChunk(s.alloc, newCap)
    ?s.chunks.tryAdd(newChunk)
    s.current = newChunk
    s.currentCap = newCap
    s.currentUsed = 0

  let dest = addr s.current[s.currentUsed]
  copyMem(dest, unsafeAddr text[0], text.len)
  s.currentUsed += text.len
  ok[Span[byte], AllocError](span(cast[ptr UncheckedArray[byte]](dest), text.len))

proc internString*(s: var StringArena, text: string): Result[Span[byte], AllocError] {.inline, raises: [].} =
  if text.len == 0:
    ok[Span[byte], AllocError](span[byte]())
  else:
    s.intern(toOpenArray(cast[ptr UncheckedArray[byte]](unsafeAddr text[0]), 0, text.len - 1))

proc reset*(s: var StringArena) {.raises: [].} =
  ## Bulk resets the arena: frees all chunks except the first one, and sets currentUsed to 0.
  ## O(1) bulk deallocation.
  ## IMPORTANT: All previously returned Span[byte] objects are immediately invalidated!
  if s.chunks.len > 1 and not s.alloc.freeFn.isNil:
    for i in 1 ..< s.chunks.len:
      let p = s.chunks[i]
      if not p.isNil:
        freeChunk(s.alloc, p)
    s.chunks.len = 1

  if s.chunks.len > 0:
    s.current = s.chunks[0]
    let raw = cast[pointer](cast[uint](s.current) - uint(sizeof(ChunkHeader)))
    s.currentCap = cast[ptr ChunkHeader](raw).capacity
  else:
    s.current = nil
    s.currentCap = 0
  s.currentUsed = 0

proc bytesUsed*(s: StringArena): int {.raises: [].} =
  if s.chunks.len <= 1:
    return s.currentUsed
  var total = 0
  for i in 0 ..< s.chunks.len - 1:
    let raw = cast[pointer](cast[uint](s.chunks[i]) - uint(sizeof(ChunkHeader)))
    total += cast[ptr ChunkHeader](raw).capacity
  total + s.currentUsed

proc bytesAllocated*(s: StringArena): int {.raises: [].} =
  var total = 0
  for i in 0 ..< s.chunks.len:
    let raw = cast[pointer](cast[uint](s.chunks[i]) - uint(sizeof(ChunkHeader)))
    total += cast[ptr ChunkHeader](raw).capacity
  total
