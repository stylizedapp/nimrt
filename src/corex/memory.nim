## corex/memory — Zero-Cost Memory Safety Abstractions
##
## Provides foundational memory safety and ownership abstractions for Nim ARC/ORC:
## - `Span[T]`: Non-owning contiguous slice view with bounds-checked indexing,
##   slicing (`subspan`), `lent T` accessors, and zero runtime overhead.
## - `ByteSpan`: Specialized byte slice view with binary parsing, cursor reading (`ByteReader`),
##   and compile-time validated zero-copy POD casting via `supportsCopyMem`.
## - `Owned[T]`: RAII single-ownership smart pointer backed by `Allocator` VTable,
##   guaranteeing inner destructor invocation before memory deallocation, clean `=sink` moves,
##   and compile-time disabled copy semantics (`{.error.}`).

import std/typetraits
import ./result
import ./allocators

# =============================================================================
# 1. Span[T] — Contiguous Non-Owning Slice View
# =============================================================================

type
  Span*[T] = object
    data*: ptr UncheckedArray[T]
    len*: int

  ByteSpan* = Span[byte]

template isBlittable*(T: typedesc): bool =
  ## Returns true if T is Plain Old Data (blittable) and safe for copyMem.
  supportsCopyMem(T)

proc span*[T](): Span[T] {.inline, raises: [].} =
  ## Creates an empty Span.
  Span[T](data: nil, len: 0)

proc span*[T](p: ptr UncheckedArray[T], len: int): Span[T] {.inline, raises: [].} =
  ## Creates a Span from a pointer to UncheckedArray and length.
  if p.isNil or len <= 0: Span[T](data: nil, len: 0)
  else: Span[T](data: p, len: len)

proc span*[T](p: ptr T, len: int): Span[T] {.inline, raises: [].} =
  ## Creates a Span from a raw pointer and element count.
  if p.isNil or len <= 0: Span[T](data: nil, len: 0)
  else: Span[T](data: cast[ptr UncheckedArray[T]](p), len: len)

proc span*[T](oa: openArray[T]): Span[T] {.inline, raises: [].} =
  ## Creates a Span borrowing the buffer of an openArray (seq, array, etc.).
  if oa.len == 0: Span[T](data: nil, len: 0)
  else: Span[T](data: cast[ptr UncheckedArray[T]](unsafeAddr oa[0]), len: oa.len)

proc toSpan*[T](oa: openArray[T]): Span[T] {.inline, raises: [].} =
  ## Alias for `span(oa)`.
  span(oa)

proc spanFromVar*[T](v: var T): Span[T] {.inline, raises: [].} =
  ## Creates a 1-element Span viewing a mutable variable.
  Span[T](data: cast[ptr UncheckedArray[T]](addr v), len: 1)

proc len*[T](s: Span[T]): int {.inline, raises: [].} = s.len
proc isEmpty*[T](s: Span[T]): bool {.inline, raises: [].} = s.len == 0
proc rawData*[T](s: Span[T]): ptr UncheckedArray[T] {.inline, raises: [].} = s.data
proc rawPtr*[T](s: Span[T]): ptr T {.inline, raises: [].} = cast[ptr T](s.data)
proc byteSize*[T](s: Span[T]): int {.inline, raises: [].} = s.len * sizeof(T)

proc `[]`*[T](s: Span[T], idx: int): lent T {.inline, raises: [].} =
  ## Bounds-checked read-only indexing returning a lent view.
  if idx < 0 or idx >= s.len:
    raise (ref IndexDefect)(msg: "Span index out of bounds: " & $idx & " not in 0 ..< " & $s.len)
  s.data[idx]

proc `[]`*[T](s: var Span[T], idx: int): var T {.inline, raises: [].} =
  ## Bounds-checked mutable indexing returning a var view.
  if idx < 0 or idx >= s.len:
    raise (ref IndexDefect)(msg: "Span index out of bounds: " & $idx & " not in 0 ..< " & $s.len)
  s.data[idx]

proc `[]=`*[T](s: Span[T], idx: int, val: T) {.inline, raises: [].} =
  ## Bounds-checked element assignment.
  if idx < 0 or idx >= s.len:
    raise (ref IndexDefect)(msg: "Span index out of bounds: " & $idx & " not in 0 ..< " & $s.len)
  s.data[idx] = val

proc `[]`*[T](s: Span[T], idx: BackwardsIndex): lent T {.inline, raises: [].} =
  ## Bounds-checked read-only indexing with BackwardsIndex (e.g. s[^1]).
  s[s.len - int(idx)]

proc `[]`*[T](s: var Span[T], idx: BackwardsIndex): var T {.inline, raises: [].} =
  ## Bounds-checked mutable indexing with BackwardsIndex (e.g. s[^1]).
  s[s.len - int(idx)]

proc `[]=`*[T](s: Span[T], idx: BackwardsIndex, val: T) {.inline, raises: [].} =
  ## Bounds-checked assignment with BackwardsIndex (e.g. s[^1] = val).
  s[s.len - int(idx)] = val

proc `[]=`*[T](s: var Span[T], idx: BackwardsIndex, val: T) {.inline, raises: [].} =
  ## Bounds-checked assignment on mutable Span with BackwardsIndex.
  s[s.len - int(idx)] = val

proc unsafeAt*[T](s: Span[T], idx: int): lent T {.inline, raises: [].} =
  ## Unchecked read-only indexing for performance-critical loops.
  s.data[idx]

proc unsafeAtMut*[T](s: var Span[T], idx: int): var T {.inline, raises: [].} =
  ## Unchecked mutable indexing for performance-critical loops.
  s.data[idx]

proc first*[T](s: Span[T]): lent T {.inline, raises: [].} =
  if s.len == 0:
    raise (ref IndexDefect)(msg: "Span is empty")
  s.data[0]

proc last*[T](s: Span[T]): lent T {.inline, raises: [].} =
  if s.len == 0:
    raise (ref IndexDefect)(msg: "Span is empty")
  s.data[s.len - 1]

proc subspan*[T](s: Span[T], start: int, length: int = -1): Span[T] {.inline, raises: [].} =
  ## Returns a subspan slice starting at `start` with `length` elements.
  ## If length == -1, slices from `start` to the end of the span.
  if start < 0 or start > s.len:
    raise (ref IndexDefect)(msg: "subspan start out of bounds: " & $start & " not in 0.." & $s.len)
  let count = if length < 0: s.len - start else: length
  if count < 0 or start + count > s.len:
    raise (ref IndexDefect)(msg: "subspan length out of bounds: start=" & $start & " count=" & $count & " len=" & $s.len)
  if count == 0:
    return Span[T](data: nil, len: 0)
  let offsetPtr = cast[ptr UncheckedArray[T]](cast[uint](s.data) + uint(start * sizeof(T)))
  Span[T](data: offsetPtr, len: count)

proc `[]`*[T](s: Span[T], slice: HSlice[int, int]): Span[T] {.inline, raises: [].} =
  ## Slices a Span using Nim slice syntax: `s[0 .. 3]`.
  let b = if slice.b < 0: s.len + slice.b else: slice.b
  let a = slice.a
  if a < 0 or a > s.len or b < a - 1 or b >= s.len:
    raise (ref IndexDefect)(msg: "Span slice out of bounds")
  let length = b - a + 1
  s.subspan(a, length)

proc `[]`*[T](s: Span[T], slice: HSlice[int, BackwardsIndex]): Span[T] {.inline, raises: [].} =
  ## Slices a Span using BackwardsIndex end: `s[0 .. ^1]`.
  let b = s.len - int(slice.b)
  let a = slice.a
  if a < 0 or a > s.len or b < a - 1 or b >= s.len:
    raise (ref IndexDefect)(msg: "Span slice out of bounds")
  let length = b - a + 1
  s.subspan(a, length)

proc `[]`*[T](s: Span[T], slice: HSlice[BackwardsIndex, BackwardsIndex]): Span[T] {.inline, raises: [].} =
  ## Slices a Span with BackwardsIndex bounds: `s[^3 .. ^1]`.
  let a = s.len - int(slice.a)
  let b = s.len - int(slice.b)
  if a < 0 or a > s.len or b < a - 1 or b >= s.len:
    raise (ref IndexDefect)(msg: "Span slice out of bounds")
  let length = b - a + 1
  s.subspan(a, length)

proc `[]`*[T](s: Span[T], slice: HSlice[BackwardsIndex, int]): Span[T] {.inline, raises: [].} =
  ## Slices a Span starting from BackwardsIndex to forward int: `s[^3 .. 4]`.
  let a = s.len - int(slice.a)
  let b = if slice.b < 0: s.len + slice.b else: slice.b
  if a < 0 or a > s.len or b < a - 1 or b >= s.len:
    raise (ref IndexDefect)(msg: "Span slice out of bounds")
  let length = b - a + 1
  s.subspan(a, length)

iterator items*[T](s: Span[T]): lent T {.inline.} =
  var i = 0
  let n = s.len
  while i < n:
    yield s.data[i]
    inc(i)

iterator mitems*[T](s: var Span[T]): var T {.inline.} =
  var i = 0
  let n = s.len
  while i < n:
    yield s.data[i]
    inc(i)

iterator pairs*[T](s: Span[T]): tuple[key: int, val: lent T] {.inline.} =
  var i = 0
  let n = s.len
  while i < n:
    yield (i, s.data[i])
    inc(i)

proc `==`*[T](a, b: Span[T]): bool {.inline, raises: [].} =
  ## Compares two spans for element-wise equality.
  if a.len != b.len: return false
  if a.data == b.data: return true
  when supportsCopyMem(T):
    if a.len == 0: return true
    equalMem(a.data, b.data, a.len * sizeof(T))
  else:
    for i in 0 ..< a.len:
      if a.data[i] != b.data[i]: return false
    true

proc fill*[T](s: var Span[T], val: T) {.inline, raises: [].} =
  ## Fills every element in the span with `val`.
  for i in 0 ..< s.len:
    s.data[i] = val

# =============================================================================
# 2. ByteSpan — Specialized Byte Slice View & POD Casting
# =============================================================================

proc toByteSpan*(oa: openArray[byte]): ByteSpan {.inline, raises: [].} = span(oa)

proc toByteSpan*(oa: openArray[char]): ByteSpan {.inline, raises: [].} =
  if oa.len == 0: Span[byte](data: nil, len: 0)
  else: Span[byte](data: cast[ptr UncheckedArray[byte]](unsafeAddr oa[0]), len: oa.len)

proc toByteSpan*(s: string): ByteSpan {.inline, raises: [].} =
  if s.len == 0: Span[byte](data: nil, len: 0)
  else: Span[byte](data: cast[ptr UncheckedArray[byte]](unsafeAddr s[0]), len: s.len)

proc byteSpan*(p: pointer, len: int): ByteSpan {.inline, raises: [].} =
  if p.isNil or len <= 0: Span[byte](data: nil, len: 0)
  else: Span[byte](data: cast[ptr UncheckedArray[byte]](p), len: len)

proc asRef*[T](s: ByteSpan, offset: int = 0): ptr T {.inline, raises: [].} =
  ## Returns a zero-copy pointer to a POD type T at `offset`.
  when not supportsCopyMem(T):
    {.error: "asRef requires a blittable POD type".}
  if offset < 0 or offset + sizeof(T) > s.len:
    raise (ref IndexDefect)(msg: "ByteSpan out of bounds for asRef: requires " & $(offset + sizeof(T)) & " bytes, have " & $s.len)
  cast[ptr T](cast[uint](s.data) + uint(offset))

proc asRef*[T](s: ByteSpan, _: typedesc[T], offset: int = 0): ptr T {.inline, raises: [].} =
  asRef[T](s, offset)

proc asRefMut*[T](s: var ByteSpan, offset: int = 0): ptr T {.inline, raises: [].} =
  when not supportsCopyMem(T):
    {.error: "asRefMut requires a blittable POD type".}
  if offset < 0 or offset + sizeof(T) > s.len:
    raise (ref IndexDefect)(msg: "ByteSpan out of bounds for asRefMut")
  cast[ptr T](cast[uint](s.data) + uint(offset))

proc asRefMut*[T](s: var ByteSpan, _: typedesc[T], offset: int = 0): ptr T {.inline, raises: [].} =
  asRefMut[T](s, offset)

proc readPOD*[T](s: ByteSpan, offset: var int): T {.inline, raises: [].} =
  ## Reads a POD value of type T from `offset` and advances `offset`.
  when not supportsCopyMem(T):
    {.error: "readPOD requires a blittable POD type".}
  if offset < 0 or offset + sizeof(T) > s.len:
    raise (ref IndexDefect)(msg: "ByteSpan out of bounds for readPOD")
  copyMem(addr result, cast[pointer](cast[uint](s.data) + uint(offset)), sizeof(T))
  offset += sizeof(T)

proc readPOD*[T](s: ByteSpan, _: typedesc[T], offset: var int): T {.inline, raises: [].} =
  readPOD[T](s, offset)

proc castSpan*[T](s: ByteSpan): Span[T] {.inline, raises: [].} =
  ## Zero-copy reinterprets a ByteSpan as a typed Span[T].
  when not supportsCopyMem(T):
    {.error: "castSpan requires a blittable POD type".}
  let count = if sizeof(T) > 0: s.len div sizeof(T) else: 0
  Span[T](data: cast[ptr UncheckedArray[T]](s.data), len: count)

proc castSpan*[T](s: ByteSpan, _: typedesc[T]): Span[T] {.inline, raises: [].} =
  castSpan[T](s)

proc readU8*(s: ByteSpan, offset: var int): uint8 {.inline, raises: [].} =
  if offset < 0 or offset + 1 > s.len:
    raise (ref IndexDefect)(msg: "readU8 out of bounds")
  result = s.data[offset]
  inc(offset)

proc readI8*(s: ByteSpan, offset: var int): int8 {.inline, raises: [].} =
  cast[int8](s.readU8(offset))

proc readU16LE*(s: ByteSpan, offset: var int): uint16 {.inline, raises: [].} =
  if offset < 0 or offset + 2 > s.len:
    raise (ref IndexDefect)(msg: "readU16LE out of bounds")
  let b0 = uint16(s.data[offset])
  let b1 = uint16(s.data[offset + 1])
  offset += 2
  b0 or (b1 shl 8)

proc readU16BE*(s: ByteSpan, offset: var int): uint16 {.inline, raises: [].} =
  if offset < 0 or offset + 2 > s.len:
    raise (ref IndexDefect)(msg: "readU16BE out of bounds")
  let b1 = uint16(s.data[offset])
  let b0 = uint16(s.data[offset + 1])
  offset += 2
  b0 or (b1 shl 8)

proc readI16LE*(s: ByteSpan, offset: var int): int16 {.inline, raises: [].} =
  cast[int16](s.readU16LE(offset))

proc readI16BE*(s: ByteSpan, offset: var int): int16 {.inline, raises: [].} =
  cast[int16](s.readU16BE(offset))

proc readU32LE*(s: ByteSpan, offset: var int): uint32 {.inline, raises: [].} =
  if offset < 0 or offset + 4 > s.len:
    raise (ref IndexDefect)(msg: "readU32LE out of bounds")
  let b0 = uint32(s.data[offset])
  let b1 = uint32(s.data[offset + 1])
  let b2 = uint32(s.data[offset + 2])
  let b3 = uint32(s.data[offset + 3])
  offset += 4
  b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc readU32BE*(s: ByteSpan, offset: var int): uint32 {.inline, raises: [].} =
  if offset < 0 or offset + 4 > s.len:
    raise (ref IndexDefect)(msg: "readU32BE out of bounds")
  let b3 = uint32(s.data[offset])
  let b2 = uint32(s.data[offset + 1])
  let b1 = uint32(s.data[offset + 2])
  let b0 = uint32(s.data[offset + 3])
  offset += 4
  b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc readI32LE*(s: ByteSpan, offset: var int): int32 {.inline, raises: [].} =
  cast[int32](s.readU32LE(offset))

proc readI32BE*(s: ByteSpan, offset: var int): int32 {.inline, raises: [].} =
  cast[int32](s.readU32BE(offset))

proc readU64LE*(s: ByteSpan, offset: var int): uint64 {.inline, raises: [].} =
  if offset < 0 or offset + 8 > s.len:
    raise (ref IndexDefect)(msg: "readU64LE out of bounds")
  let lo = uint64(s.readU32LE(offset))
  let hi = uint64(s.readU32LE(offset))
  lo or (hi shl 32)

proc readU64BE*(s: ByteSpan, offset: var int): uint64 {.inline, raises: [].} =
  if offset < 0 or offset + 8 > s.len:
    raise (ref IndexDefect)(msg: "readU64BE out of bounds")
  let hi = uint64(s.readU32BE(offset))
  let lo = uint64(s.readU32BE(offset))
  (hi shl 32) or lo

proc readI64LE*(s: ByteSpan, offset: var int): int64 {.inline, raises: [].} =
  cast[int64](s.readU64LE(offset))

proc readI64BE*(s: ByteSpan, offset: var int): int64 {.inline, raises: [].} =
  cast[int64](s.readU64BE(offset))

proc readF32LE*(s: ByteSpan, offset: var int): float32 {.inline, raises: [].} =
  let u = s.readU32LE(offset)
  cast[float32](u)

proc readF64LE*(s: ByteSpan, offset: var int): float64 {.inline, raises: [].} =
  let u = s.readU64LE(offset)
  cast[float64](u)

proc readBytes*(s: ByteSpan, offset: var int, count: int): ByteSpan {.inline, raises: [].} =
  result = s.subspan(offset, count)
  offset += count

proc asString*(s: ByteSpan): string {.inline, raises: [].} =
  if s.len == 0: return ""
  result = newString(s.len)
  copyMem(addr result[0], s.data, s.len)

proc toHex*(s: ByteSpan): string {.raises: [].} =
  const hexChars = "0123456789abcdef"
  result = newString(s.len * 2)
  for i in 0 ..< s.len:
    let b = s.data[i]
    result[i * 2] = hexChars[(b shr 4) and 0x0f]
    result[i * 2 + 1] = hexChars[b and 0x0f]

proc `$`*(s: ByteSpan): string {.raises: [].} =
  s.asString()

# =============================================================================
# 3. ByteReader — Streaming Cursor over ByteSpan
# =============================================================================

type
  ByteReader* = object
    span*: ByteSpan
    offset*: int

proc initByteReader*(s: ByteSpan, offset: int = 0): ByteReader {.inline, raises: [].} =
  ByteReader(span: s, offset: offset)

proc remaining*(r: ByteReader): int {.inline, raises: [].} =
  r.span.len - r.offset

proc hasRemaining*(r: ByteReader, count: int = 1): bool {.inline, raises: [].} =
  r.offset + count <= r.span.len

proc readU8*(r: var ByteReader): uint8 {.inline, raises: [].} =
  r.span.readU8(r.offset)

proc readI8*(r: var ByteReader): int8 {.inline, raises: [].} =
  r.span.readI8(r.offset)

proc readU16LE*(r: var ByteReader): uint16 {.inline, raises: [].} =
  r.span.readU16LE(r.offset)

proc readU16BE*(r: var ByteReader): uint16 {.inline, raises: [].} =
  r.span.readU16BE(r.offset)

proc readI16LE*(r: var ByteReader): int16 {.inline, raises: [].} =
  r.span.readI16LE(r.offset)

proc readI16BE*(r: var ByteReader): int16 {.inline, raises: [].} =
  r.span.readI16BE(r.offset)

proc readU32LE*(r: var ByteReader): uint32 {.inline, raises: [].} =
  r.span.readU32LE(r.offset)

proc readU32BE*(r: var ByteReader): uint32 {.inline, raises: [].} =
  r.span.readU32BE(r.offset)

proc readI32LE*(r: var ByteReader): int32 {.inline, raises: [].} =
  r.span.readI32LE(r.offset)

proc readI32BE*(r: var ByteReader): int32 {.inline, raises: [].} =
  r.span.readI32BE(r.offset)

proc readU64LE*(r: var ByteReader): uint64 {.inline, raises: [].} =
  r.span.readU64LE(r.offset)

proc readU64BE*(r: var ByteReader): uint64 {.inline, raises: [].} =
  r.span.readU64BE(r.offset)

proc readI64LE*(r: var ByteReader): int64 {.inline, raises: [].} =
  r.span.readI64LE(r.offset)

proc readI64BE*(r: var ByteReader): int64 {.inline, raises: [].} =
  r.span.readI64BE(r.offset)

proc readF32LE*(r: var ByteReader): float32 {.inline, raises: [].} =
  r.span.readF32LE(r.offset)

proc readF64LE*(r: var ByteReader): float64 {.inline, raises: [].} =
  r.span.readF64LE(r.offset)

proc readBytes*(r: var ByteReader, count: int): ByteSpan {.inline, raises: [].} =
  r.span.readBytes(r.offset, count)

proc readPOD*[T](r: var ByteReader): T {.inline, raises: [].} =
  r.span.readPOD[T](r.offset)

proc readPOD*[T](r: var ByteReader, _: typedesc[T]): T {.inline, raises: [].} =
  r.span.readPOD[T](r.offset)

proc asRef*[T](r: var ByteReader): ptr T {.inline, raises: [].} =
  result = r.span.asRef[T](r.offset)
  r.offset += sizeof(T)

proc asRef*[T](r: var ByteReader, _: typedesc[T]): ptr T {.inline, raises: [].} =
  result = r.span.asRef[T](r.offset)
  r.offset += sizeof(T)

# =============================================================================
# 4. Owned[T] — RAII Single-Ownership Smart Pointer
# =============================================================================

type
  Owned*[T] = object
    val*: ptr T
    alloc*: Allocator

proc rawPtr*[T](o: Owned[T]): ptr T {.inline, raises: [].} =
  o.val

proc `=destroy`*[T](o: var Owned[T]) {.raises: [].} =
  ## Destroys inner managed fields via `=destroy(o.val[])` before freeing memory block.
  if not o.val.isNil:
    `=destroy`(o.val[])
    if not o.alloc.freeFn.isNil:
      o.alloc.freeFn(o.alloc.ctx, o.val, sizeof(T))
    o.val = nil

proc `=copy`*[T](dest: var Owned[T], src: Owned[T]) {.error: "Owned[T] cannot be copied; use move semantics".}

proc `=wasMoved`*[T](o: var Owned[T]) {.inline, raises: [].} =
  o.val = nil

proc `=sink`*[T](dest: var Owned[T], src: Owned[T]) {.raises: [].} =
  ## Move semantics: cleans up prior destination allocation before transferring ownership.
  if dest.val != src.val:
    `=destroy`(dest)
  dest.val = src.val
  dest.alloc = src.alloc

proc isNil*[T](o: Owned[T]): bool {.inline, raises: [].} =
  o.val.isNil

proc get*[T](o: Owned[T]): lent T {.inline, raises: [].} =
  ## Dereferences value as lent view.
  if o.val.isNil:
    raise (ref NilAccessDefect)(msg: "Attempt to dereference nil Owned[" & $typeof(T) & "]")
  o.val[]

proc getMut*[T](o: var Owned[T]): var T {.inline, raises: [].} =
  ## Dereferences value as mutable var.
  if o.val.isNil:
    raise (ref NilAccessDefect)(msg: "Attempt to dereference nil Owned[" & $typeof(T) & "]")
  o.val[]

proc `[]`*[T](o: Owned[T]): lent T {.inline, raises: [].} =
  o.get()

proc `[]`*[T](o: var Owned[T]): var T {.inline, raises: [].} =
  o.getMut()

proc `[]=`*[T](o: var Owned[T], val: sink T) {.inline, raises: [].} =
  if o.val.isNil:
    raise (ref NilAccessDefect)(msg: "Attempt to dereference nil Owned[" & $typeof(T) & "]")
  o.val[] = move(val)

proc allocator*[T](o: Owned[T]): Allocator {.inline, raises: [].} =
  o.alloc

proc release*[T](o: var Owned[T]): ptr T {.inline, raises: [].} =
  ## Relinquishes ownership of raw pointer without invoking destructor or allocator free.
  result = o.val
  o.val = nil

proc unwrap*[T](o: sink Owned[T]): T {.raises: [].} =
  ## Consumes an rvalue Owned[T], extracting and moving the contained value
  ## while cleanly deallocating the heap memory block.
  if o.val.isNil:
    raise (ref NilAccessDefect)(msg: "Attempt to unwrap nil Owned[" & $typeof(T) & "]")
  result = move(o.val[])
  if not o.alloc.freeFn.isNil:
    o.alloc.freeFn(o.alloc.ctx, o.val, sizeof(T))
  o.val = nil

proc unwrap*[T](o: var Owned[T]): T {.raises: [].} =
  ## Consumes an lvalue Owned[T], extracting and moving the contained value
  ## while cleanly deallocating the heap memory block.
  if o.val.isNil:
    raise (ref NilAccessDefect)(msg: "Attempt to unwrap nil Owned[" & $typeof(T) & "]")
  result = move(o.val[])
  if not o.alloc.freeFn.isNil:
    o.alloc.freeFn(o.alloc.ctx, o.val, sizeof(T))
  o.val = nil

proc toSpan*[T](o: Owned[T]): Span[T] {.inline, raises: [].} =
  ## Borrows Owned[T] as a 1-element Span[T].
  if o.val.isNil: Span[T](data: nil, len: 0)
  else: Span[T](data: cast[ptr UncheckedArray[T]](o.val), len: 1)

proc tryOwned*[T](val: sink T, alloc: Allocator): Result[Owned[T], AllocError] {.raises: [].} =
  ## Fallible constructor returning Result[Owned[T], AllocError].
  let rawRes = alloc.rawAlloc(sizeof(T), alignof(T))
  if rawRes.isErr:
    return Result[Owned[T], AllocError](isOk: false, errVal: rawRes.error)
  let p = cast[ptr T](rawRes.get)
  zeroMem(p, sizeof(T))
  p[] = move(val)
  Result[Owned[T], AllocError](isOk: true, val: Owned[T](val: p, alloc: alloc))

proc owned*[T](val: sink T, alloc: Allocator): Owned[T] {.raises: [].} =
  ## Allocates and moves value into Owned[T]. Raises OutOfMemDefect if allocation fails.
  var r = tryOwned(val, alloc)
  if r.isErr:
    raise (ref OutOfMemDefect)(msg: "Failed to allocate Owned[" & $typeof(T) & "]: " & $r.error)
  move(r.val)

proc newOwned*[T](val: sink T, alloc: Allocator): Owned[T] {.inline, raises: [].} =
  ## Alias for `owned(val, alloc)`.
  owned(val, alloc)

# -----------------------------------------------------------------------------
# Result Monad Ergonomics for Owned[T] (Move-Only Semantics)
# -----------------------------------------------------------------------------

proc ok*[T, E](v: sink Owned[T]): Result[Owned[T], E] {.inline, raises: [].} =
  Result[Owned[T], E](isOk: true, val: move(v))

proc get*[T, E](r: sink Result[Owned[T], E]): Owned[T] {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc get*[T, E](r: var Result[Owned[T], E]): Owned[T] {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc unwrap*[T, E](r: sink Result[Owned[T], E]): Owned[T] {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result"
  move(r.val)

proc unwrap*[T, E](r: var Result[Owned[T], E]): Owned[T] {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result"
  move(r.val)

proc unwrapErr*[T, E](r: Result[Owned[T], E]): E {.inline.} =
  doAssert not r.isOk, "Attempted to unwrapErr an Ok Result"
  r.errVal

proc unwrapErr*[T, E](r: var Result[Owned[T], E]): E {.inline.} =
  doAssert not r.isOk, "Attempted to unwrapErr an Ok Result"
  r.errVal

proc unwrapErr*[T, E](r: sink Result[Owned[T], E]): E {.inline.} =
  doAssert not r.isOk, "Attempted to unwrapErr an Ok Result"
  r.errVal

proc getOr*[T, E](r: sink Result[Owned[T], E], defaultVal: sink Owned[T]): Owned[T] {.inline, raises: [].} =
  if r.isOk: move(r.val) else: move(defaultVal)

proc getOr*[T, E](r: var Result[Owned[T], E], defaultVal: sink Owned[T]): Owned[T] {.inline, raises: [].} =
  if r.isOk: move(r.val) else: move(defaultVal)
