## corex/containers — Zero-overhead, explicit-allocator containers with ARC/ORC hooks
##
## Provides `BufSeq[T]` and `BufStr` with:
## - Full deterministic ARC/ORC lifecycle hooks (=destroy, =copy, =sink, =wasMoved)
## - Deep element-wise destruction on deinit, destroy, and clear
## - Explicit bounds checking on element access (IndexDefect panics)
## - ZeroMem protection against uninitialized slot destruction

import ./result
import ./allocators
import ./memory

type
  BufSeq*[T] = object
    data*: ptr UncheckedArray[T]
    len*: int
    cap*: int
    alloc*: Allocator

# =============================================================================
# Lifecycle Hooks for BufSeq[T]
# =============================================================================

proc `=destroy`*[T](s: var BufSeq[T]) {.raises: [].} =
  if not s.data.isNil:
    for i in 0 ..< s.len:
      `=destroy`(s.data[i])
    if s.cap > 0 and not s.alloc.freeFn.isNil:
      s.alloc.dealloc(s.data, sizeof(T) * s.cap)
    s.data = nil
    s.len = 0
    s.cap = 0

proc `=wasMoved`*[T](s: var BufSeq[T]) {.inline, raises: [].} =
  s.data = nil
  s.len = 0
  s.cap = 0

proc `=sink`*[T](dest: var BufSeq[T], src: BufSeq[T]) {.raises: [].} =
  if dest.data != src.data:
    `=destroy`(dest)
  dest.data = src.data
  dest.len = src.len
  dest.cap = src.cap
  dest.alloc = src.alloc

proc `=copy`*[T](dest: var BufSeq[T], src: BufSeq[T]) {.raises: [].} =
  if dest.data == src.data and not dest.data.isNil:
    return
  `=destroy`(dest)
  dest.alloc = src.alloc
  if src.cap == 0 or src.data.isNil:
    dest.data = nil
    dest.len = 0
    dest.cap = 0
    return
  let allocCap = max(src.cap, src.len)
  let raw = dest.alloc.rawAlloc(sizeof(T) * allocCap, alignof(T))
  if raw.isOk:
    let p = raw.get
    zeroMem(p, sizeof(T) * allocCap)
    dest.data = cast[ptr UncheckedArray[T]](p)
    dest.cap = allocCap
    dest.len = 0
    for i in 0 ..< src.len:
      dest.data[i] = src.data[i]
      dest.len = i + 1
  else:
    dest.data = nil
    dest.len = 0
    dest.cap = 0
    raise (ref Defect)(msg: "BufSeq.=copy: out of memory allocating buffer")

# =============================================================================
# BufSeq[T] Construction & Operations
# =============================================================================

proc get*[T: BufSeq, E](r: sink Result[T, E]): T {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc get*[T: BufSeq, E](r: var Result[T, E]): T {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc unwrap*[T: BufSeq, E](r: sink Result[T, E]): T {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result"
  move(r.val)

proc unwrap*[T: BufSeq, E](r: var Result[T, E]): T {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result"
  move(r.val)

proc initBufSeq*[T](a: Allocator, initialCap: int = 0): Result[BufSeq[T], AllocError] {.inline, raises: [].} =
  if initialCap <= 0:
    return Result[BufSeq[T], AllocError](isOk: true, val: BufSeq[T](data: nil, len: 0, cap: 0, alloc: a))
  let raw = ?a.rawAlloc(sizeof(T) * initialCap, alignof(T))
  zeroMem(raw, sizeof(T) * initialCap)
  Result[BufSeq[T], AllocError](isOk: true, val: BufSeq[T](
    data: cast[ptr UncheckedArray[T]](raw),
    len: 0,
    cap: initialCap,
    alloc: a
  ))

proc deinit*[T](s: var BufSeq[T]) {.inline, raises: [].} =
  `=destroy`(s)

proc len*[T](s: BufSeq[T]): int {.inline, raises: [].} =
  s.len

proc cap*[T](s: BufSeq[T]): int {.inline, raises: [].} =
  s.cap

proc allocator*[T](s: BufSeq[T]): Allocator {.inline, raises: [].} =
  s.alloc

proc reserve*[T](s: var BufSeq[T], newCap: int): Result[void, AllocError] {.inline, raises: [].} =
  if newCap <= s.cap:
    return ok(void, AllocError)
  let raw = ?s.alloc.rawAlloc(sizeof(T) * newCap, alignof(T))
  let newData = cast[ptr UncheckedArray[T]](raw)
  zeroMem(newData, sizeof(T) * newCap)
  if s.len > 0 and not s.data.isNil:
    copyMem(newData, s.data, sizeof(T) * s.len)
  if not s.data.isNil and s.cap > 0 and not s.alloc.freeFn.isNil:
    s.alloc.dealloc(s.data, sizeof(T) * s.cap)
  s.data = newData
  s.cap = newCap
  ok(void, AllocError)

proc tryAdd*[T](s: var BufSeq[T], item: sink T): Result[void, AllocError] {.inline, raises: [].} =
  if s.len >= s.cap:
    let nextCap = if s.cap == 0: 8 else: s.cap * 2
    ?s.reserve(nextCap)
  s.data[s.len] = item
  inc(s.len)
  ok(void, AllocError)

proc add*[T](s: var BufSeq[T], item: sink T) {.raises: [].} =
  let res = s.tryAdd(item)
  if res.isErr:
    raise (ref OutOfMemDefect)(msg: "BufSeq.add: out of memory")

proc clear*[T](s: var BufSeq[T]) {.inline, raises: [].} =
  if not s.data.isNil:
    for i in 0 ..< s.len:
      `=destroy`(s.data[i])
      zeroMem(addr s.data[i], sizeof(T))
  s.len = 0

proc `[]`*[T](s: BufSeq[T], i: int): lent T {.inline, raises: [].} =
  if unlikely(i < 0 or i >= s.len):
    raise (ref IndexDefect)(msg: "IndexDefect: index out of bounds")
  s.data[i]

proc `[]`*[T](s: var BufSeq[T], i: int): var T {.inline, raises: [].} =
  if unlikely(i < 0 or i >= s.len):
    raise (ref IndexDefect)(msg: "IndexDefect: index out of bounds")
  s.data[i]

proc `[]=`*[T](s: var BufSeq[T], i: int, val: T) {.inline, raises: [].} =
  if unlikely(i < 0 or i >= s.len):
    raise (ref IndexDefect)(msg: "IndexDefect: index out of bounds")
  s.data[i] = val

proc `[]`*[T](s: BufSeq[T], i: BackwardsIndex): lent T {.inline, raises: [].} =
  s[s.len - int(i)]

proc `[]`*[T](s: var BufSeq[T], i: BackwardsIndex): var T {.inline, raises: [].} =
  s[s.len - int(i)]

proc `[]=`*[T](s: var BufSeq[T], i: BackwardsIndex, val: T) {.inline, raises: [].} =
  s[s.len - int(i)] = val

proc toSpan*[T](s: BufSeq[T]): Span[T] {.inline, raises: [].} =
  if s.len == 0 or s.data.isNil: Span[T](data: nil, len: 0)
  else: Span[T](data: s.data, len: s.len)

iterator items*[T](s: BufSeq[T]): lent T =
  var i = 0
  let n = s.len
  while i < n:
    yield s.data[i]
    inc(i)

iterator mitems*[T](s: var BufSeq[T]): var T =
  var i = 0
  let n = s.len
  while i < n:
    yield s.data[i]
    inc(i)

# =============================================================================
# BufStr — String Buffer with ARC/ORC Lifecycle Hooks
# =============================================================================

type
  BufStr* = object
    bytes*: BufSeq[char]

proc `=destroy`*(s: var BufStr) {.inline, raises: [].} =
  `=destroy`(s.bytes)

proc `=wasMoved`*(s: var BufStr) {.inline, raises: [].} =
  `=wasMoved`(s.bytes)

proc `=sink`*(dest: var BufStr, src: BufStr) {.inline, raises: [].} =
  `=sink`(dest.bytes, src.bytes)

proc `=copy`*(dest: var BufStr, src: BufStr) {.inline, raises: [].} =
  `=copy`(dest.bytes, src.bytes)

proc get*[E](r: sink Result[BufStr, E]): BufStr {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc get*[E](r: var Result[BufStr, E]): BufStr {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc unwrap*[E](r: sink Result[BufStr, E]): BufStr {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result"
  move(r.val)

proc unwrap*[E](r: var Result[BufStr, E]): BufStr {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result"
  move(r.val)

proc initBufStr*(a: Allocator, initialCap: int = 32): Result[BufStr, AllocError] {.inline, raises: [].} =
  var b = ?initBufSeq[char](a, initialCap)
  Result[BufStr, AllocError](isOk: true, val: BufStr(bytes: move(b)))

proc deinit*(s: var BufStr) {.inline, raises: [].} =
  `=destroy`(s.bytes)

proc len*(s: BufStr): int {.inline, raises: [].} =
  s.bytes.len

proc cap*(s: BufStr): int {.inline, raises: [].} =
  s.bytes.cap

proc `[]`*(s: BufStr, i: int): char {.inline, raises: [].} =
  s.bytes[i]

proc `[]`*(s: var BufStr, i: int): var char {.inline, raises: [].} =
  s.bytes[i]

proc `[]=`*(s: var BufStr, i: int, val: char) {.inline, raises: [].} =
  s.bytes[i] = val

proc `[]`*(s: BufStr, i: BackwardsIndex): char {.inline, raises: [].} =
  s.bytes[s.len - int(i)]

proc `[]`*(s: var BufStr, i: BackwardsIndex): var char {.inline, raises: [].} =
  s.bytes[s.len - int(i)]

proc `[]=`*(s: var BufStr, i: BackwardsIndex, val: char) {.inline, raises: [].} =
  s.bytes[s.len - int(i)] = val

proc tryAppend*(s: var BufStr, text: openArray[char]): Result[void, AllocError] {.inline, raises: [].} =
  let needed = s.bytes.len + text.len
  if needed > s.bytes.cap:
    var nextCap = if s.bytes.cap == 0: 32 else: s.bytes.cap
    while nextCap < needed:
      nextCap *= 2
    ?s.bytes.reserve(nextCap)
  if text.len > 0:
    copyMem(addr s.bytes.data[s.bytes.len], unsafeAddr text[0], text.len)
    s.bytes.len = needed
  ok(void, AllocError)

proc append*(s: var BufStr, text: openArray[char]) {.raises: [].} =
  let res = s.tryAppend(text)
  if res.isErr:
    raise (ref OutOfMemDefect)(msg: "BufStr.append: out of memory")

proc tryAdd*(s: var BufStr, c: char): Result[void, AllocError] {.inline, raises: [].} =
  s.bytes.tryAdd(c)

proc add*(s: var BufStr, c: char) {.raises: [].} =
  s.bytes.add(c)

proc clear*(s: var BufStr) {.inline, raises: [].} =
  s.bytes.clear()

proc `$`*(s: BufStr): string {.inline, raises: [].} =
  if s.bytes.len == 0 or s.bytes.data.isNil: return ""
  result = newString(s.bytes.len)
  copyMem(addr result[0], s.bytes.data, s.bytes.len)

proc toSpan*(s: BufStr): Span[char] {.inline, raises: [].} =
  s.bytes.toSpan()

proc toByteSpan*(s: BufStr): ByteSpan {.inline, raises: [].} =
  if s.bytes.len == 0 or s.bytes.data.isNil: Span[byte](data: nil, len: 0)
  else: Span[byte](data: cast[ptr UncheckedArray[byte]](s.bytes.data), len: s.bytes.len)

iterator items*(s: BufStr): char =
  var i = 0
  let n = s.bytes.len
  while i < n:
    yield s.bytes.data[i]
    inc(i)
