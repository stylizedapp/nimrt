## corex/interner — O(1) String Deduplication Interner (`StringInterner`)
##
## Deduplicates frequent strings (HTML tags, CSS attributes, JSON keys, AST tokens)
## into lightweight 32-bit `InternedStr` handles.
##
## Architecture:
## - Backed by `StringArena` for zero-heap chunk allocations.
## - `BufMap[uint64, BufSeq[InternedStr]]` for collision-resistant O(1) hash lookup.
## - Direct resolution table `BufSeq[Span[byte]]` for zero-copy reverse lookups.

import ./allocators
import ./result
import ./adt
import ./containers
import ./memory
import ./bufmap
import ./stringarena

type
  InternedStr* = distinct int32

  StringInterner* = object
    arena: StringArena
    table: BufMap[uint64, BufSeq[InternedStr]]  # hash -> all collision candidates
    resolve*: BufSeq[Span[byte]]                # InternedStr -> Span[byte]
    alloc: Allocator

proc `==`*(a, b: InternedStr): bool {.inline, raises: [].} =
  int32(a) == int32(b)

proc `$`*(id: InternedStr): string {.raises: [].} =
  "InternedStr(" & $int32(id) & ")"

proc rawIndex*(id: InternedStr): int32 {.inline, raises: [].} =
  int32(id)

# =============================================================================
# Hash Functions
# =============================================================================

proc fnv1a(text: openArray[byte]): uint64 {.inline, raises: [].} =
  var h = 0xcbf29ce484222325'u64
  for b in text:
    h = (h xor uint64(b)) * 0x100000001b3'u64
  h

# =============================================================================
# Lifecycle Hooks
# =============================================================================

proc `=destroy`*(s: var StringInterner) {.raises: [].} =
  `=destroy`(s.resolve)
  `=destroy`(s.table)
  `=destroy`(s.arena)

proc `=wasMoved`*(s: var StringInterner) {.inline, raises: [].} =
  `=wasMoved`(s.resolve)
  `=wasMoved`(s.table)
  `=wasMoved`(s.arena)

proc `=sink`*(dest: var StringInterner, src: StringInterner) {.raises: [].} =
  `=destroy`(dest)
  dest.arena = src.arena
  dest.table = src.table
  dest.resolve = src.resolve
  dest.alloc = src.alloc

# =============================================================================
# Construction & Operations
# =============================================================================

proc initStringInterner*(alloc: Allocator, initialCapacity: int = 64): Result[StringInterner, AllocError] {.raises: [].} =
  let arena = ?initStringArena(alloc, max(4096, initialCapacity * 32))
  let table = ?initBufMap[uint64, BufSeq[InternedStr]](alloc, initialCapacity)
  let resolve = ?initBufSeq[Span[byte]](alloc, initialCapacity)

  ok[StringInterner, AllocError](StringInterner(
    arena: arena,
    table: table,
    resolve: resolve,
    alloc: alloc
  ))

proc deinit*(s: var StringInterner) {.inline, raises: [].} =
  `=destroy`(s)

proc len*(s: StringInterner): int {.inline, raises: [].} =
  s.resolve.len

proc intern*(s: var StringInterner, text: openArray[byte]): Result[InternedStr, AllocError] {.raises: [].} =
  let h = fnv1a(text)
  let candOpt = s.table.get(h)
  if candOpt.isSome:
    let bucket = candOpt.get
    for i in 0 ..< bucket.len:
      let candidateId = bucket[i]
      let sp = s.resolve[int32(candidateId)]
      if sp.len == text.len:
        if text.len == 0 or equalMem(sp.rawData, unsafeAddr text[0], text.len):
          return ok[InternedStr, AllocError](candidateId)

  # Not yet interned: allocate inside arena
  let sp = ?s.arena.intern(text)
  let newId = InternedStr(int32(s.resolve.len))
  ?s.resolve.tryAdd(sp)

  if candOpt.isSome:
    var bucket = candOpt.get
    ?bucket.tryAdd(newId)
    ?s.table.put(h, bucket)
  else:
    var newBucket = ?initBufSeq[InternedStr](s.alloc, 2)
    ?newBucket.tryAdd(newId)
    ?s.table.put(h, newBucket)

  ok[InternedStr, AllocError](newId)

proc internString*(s: var StringInterner, text: string): Result[InternedStr, AllocError] {.inline, raises: [].} =
  if text.len == 0:
    s.intern(toOpenArray(cast[ptr UncheckedArray[byte]](nil), 0, -1))
  else:
    s.intern(toOpenArray(cast[ptr UncheckedArray[byte]](unsafeAddr text[0]), 0, text.len - 1))

proc resolve*(s: StringInterner, id: InternedStr): Span[byte] {.inline, raises: [].} =
  let idx = int32(id)
  doAssert idx >= 0 and idx < s.resolve.len, "StringInterner: invalid InternedStr ID"
  s.resolve[idx]

proc resolveString*(s: StringInterner, id: InternedStr): string {.raises: [].} =
  let sp = s.resolve(id)
  if sp.len == 0: return ""
  result = newString(sp.len)
  copyMem(addr result[0], sp.rawData, sp.len)
