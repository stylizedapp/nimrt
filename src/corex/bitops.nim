## corex/bitops — High-Performance Bit Manipulation & Intrinsics
##
## Features:
## - Fast bit intrinsics with safe zero-handling (popcount, countLeadingZeros,
##   countTrailingZeros, rotateLeft, rotateRight, reverseBits, nextPowerOfTwo, isPowerOfTwo)
## - Zero-allocation stack-allocated BitSet[N] with bitwise operators and bit queries
## - SWAR (SIMD Within A Register) 64-bit byte matching primitives

import std/bitops

# =============================================================================
# Helper Templates
# =============================================================================

template toUnsigned*(x: typed): untyped =
  when sizeof(x) == 1: cast[uint8](x)
  elif sizeof(x) == 2: cast[uint16](x)
  elif sizeof(x) == 4: cast[uint32](x)
  else: cast[uint64](x)

# =============================================================================
# Fast Bit Intrinsics
# =============================================================================

func popcount*[T: SomeInteger](x: T): int {.inline, raises: [].} =
  ## Returns the number of 1-bits set in `x`.
  when sizeof(T) <= 4:
    countSetBits(cast[uint32](toUnsigned(x)))
  else:
    countSetBits(cast[uint64](toUnsigned(x)))

func countLeadingZeros*[T: SomeInteger](x: T): int {.inline, raises: [].} =
  ## Returns the number of leading zero bits in `x`.
  ## If `x == 0`, returns the bit width `sizeof(T) * 8`.
  if x == 0:
    return sizeof(T) * 8
  when sizeof(T) <= 4:
    let u = cast[uint32](toUnsigned(x))
    countLeadingZeroBits(u) - (32 - sizeof(T) * 8)
  else:
    countLeadingZeroBits(cast[uint64](toUnsigned(x)))

func countTrailingZeros*[T: SomeInteger](x: T): int {.inline, raises: [].} =
  ## Returns the number of trailing zero bits in `x`.
  ## If `x == 0`, returns the bit width `sizeof(T) * 8`.
  if x == 0:
    return sizeof(T) * 8
  when sizeof(T) <= 4:
    let u = cast[uint32](toUnsigned(x))
    min(sizeof(T) * 8, countTrailingZeroBits(u))
  else:
    countTrailingZeroBits(cast[uint64](toUnsigned(x)))

func rotateLeft*[T: SomeInteger](x: T, amount: int): T {.inline, raises: [].} =
  ## Bitwise rotates `x` left by `amount` positions.
  const bits = sizeof(T) * 8
  let shift = ((amount mod bits) + bits) mod bits
  if shift == 0:
    return x
  let u = toUnsigned(x)
  let res = (u shl shift) or (u shr (bits - shift))
  cast[T](res)

func rotateRight*[T: SomeInteger](x: T, amount: int): T {.inline, raises: [].} =
  ## Bitwise rotates `x` right by `amount` positions.
  const bits = sizeof(T) * 8
  let shift = ((amount mod bits) + bits) mod bits
  if shift == 0:
    return x
  let u = toUnsigned(x)
  let res = (u shr shift) or (u shl (bits - shift))
  cast[T](res)

func reverseBits*[T: SomeInteger](x: T): T {.inline, raises: [].} =
  ## Reverses all bits in `x`.
  cast[T](bitops.reverseBits(toUnsigned(x)))

func isPowerOfTwo*[T: SomeInteger](x: T): bool {.inline, raises: [].} =
  ## Returns true if `x` is a positive power of two.
  x > 0 and (x and (x - 1)) == 0

func nextPowerOfTwo*[T: SomeInteger](x: T): T {.inline, raises: [].} =
  ## Returns the smallest power of two greater than or equal to `x`.
  ## If `x <= 1`, returns 1.
  if x <= 1:
    return 1
  var v = x - 1
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  when sizeof(T) >= 2:
    v = v or (v shr 8)
  when sizeof(T) >= 4:
    v = v or (v shr 16)
  when sizeof(T) >= 8:
    v = v or (v shr 32)
  v + 1

# =============================================================================
# SWAR (SIMD Within A Register) Byte Primitives for uint64
# =============================================================================

func hasZeroByte*(word: uint64): bool {.inline, raises: [].} =
  ## Branchless SWAR check: returns true if any byte in `word` is 0x00.
  ((word - 0x0101010101010101'u64) and (not word) and 0x8080808080808080'u64) != 0

func matchByteMask64*(word: uint64, byteVal: uint8): uint64 {.inline, raises: [].} =
  ## Broadcasts `byteVal` across all 8 bytes and matches against `word`.
  ## Returns a bitmask where each matching byte position has its MSB (0x80) set.
  let pattern = uint64(byteVal) * 0x0101010101010101'u64
  let diff = word xor pattern
  ((diff - 0x0101010101010101'u64) and (not diff) and 0x8080808080808080'u64)

func firstMatchingByteIndex*(mask: uint64): int {.inline, raises: [].} =
  ## Given a SWAR match mask (from `matchByteMask64`), returns the 0-based
  ## index (0..7) of the first matching byte (in little-endian byte order),
  ## or -1 if no byte matched (mask == 0).
  if mask == 0'u64:
    return -1
  countTrailingZeros(mask) shr 3

# =============================================================================
# Stack-Allocated Fixed BitSet[N]
# =============================================================================

type
  BitSet*[N: static int] = object
    ## Stack-allocated fixed bitset of N bits, zero allocations.
    data*: array[max(1, (N + 63) div 64), uint64]

func initBitSet*[N: static int](): BitSet[N] {.inline, raises: [].} =
  ## Initializes an empty BitSet with all bits cleared to 0.
  discard

proc maskExcessBits*[N: static int](b: var BitSet[N]) {.inline, raises: [].} =
  ## Clears padding bits beyond N in the last word.
  when N <= 0:
    b.data[0] = 0
  else:
    const rem = N mod 64
    when rem != 0:
      const mask = (1'u64 shl rem) - 1'u64
      b.data[b.data.high] = b.data[b.data.high] and mask

func len*[N: static int](b: BitSet[N]): int {.inline, raises: [].} =
  ## Total number of bits in this BitSet.
  N

func setBit*[N: static int](b: var BitSet[N], idx: int) {.inline, raises: [].} =
  ## Sets the bit at `idx` to 1.
  assert idx >= 0 and idx < N, "BitSet index out of bounds"
  let wordIdx = idx shr 6
  let bitIdx = idx and 63
  b.data[wordIdx] = b.data[wordIdx] or (1'u64 shl bitIdx)

func clearBit*[N: static int](b: var BitSet[N], idx: int) {.inline, raises: [].} =
  ## Clears the bit at `idx` to 0.
  assert idx >= 0 and idx < N, "BitSet index out of bounds"
  let wordIdx = idx shr 6
  let bitIdx = idx and 63
  b.data[wordIdx] = b.data[wordIdx] and not (1'u64 shl bitIdx)

func testBit*[N: static int](b: BitSet[N], idx: int): bool {.inline, raises: [].} =
  ## Tests whether the bit at `idx` is 1.
  assert idx >= 0 and idx < N, "BitSet index out of bounds"
  let wordIdx = idx shr 6
  let bitIdx = idx and 63
  (b.data[wordIdx] and (1'u64 shl bitIdx)) != 0

func `[]`*[N: static int](b: BitSet[N], idx: int): bool {.inline, raises: [].} =
  b.testBit(idx)

func `[]=`*[N: static int](b: var BitSet[N], idx: int, val: bool) {.inline, raises: [].} =
  if val:
    b.setBit(idx)
  else:
    b.clearBit(idx)

func contains*[N: static int](b: BitSet[N], idx: int): bool {.inline, raises: [].} =
  b.testBit(idx)

func clear*[N: static int](b: var BitSet[N]) {.inline, raises: [].} =
  ## Clears all bits in the bitset to 0.
  for i in 0 ..< b.data.len:
    b.data[i] = 0

func fill*[N: static int](b: var BitSet[N]) {.inline, raises: [].} =
  ## Sets all bits in the bitset to 1.
  for i in 0 ..< b.data.len:
    b.data[i] = not 0'u64
  b.maskExcessBits()

func count*[N: static int](b: BitSet[N]): int {.inline, raises: [].} =
  ## Returns the total number of set bits (popcount).
  var total = 0
  for i in 0 ..< b.data.len:
    total += popcount(b.data[i])
  total

func firstSet*[N: static int](b: BitSet[N]): int {.inline, raises: [].} =
  ## Returns the index of the first bit set to 1, or -1 if no bits are set.
  when N <= 0:
    return -1
  else:
    for i in 0 ..< b.data.len:
      let w = b.data[i]
      if w != 0:
        let bit = countTrailingZeros(w)
        let idx = (i shl 6) + bit
        if idx < N:
          return idx
        return -1
    return -1

func firstClear*[N: static int](b: BitSet[N]): int {.inline, raises: [].} =
  ## Returns the index of the first bit cleared to 0, or -1 if all bits are set.
  when N <= 0:
    return -1
  else:
    for i in 0 ..< b.data.len:
      var w = not b.data[i]
      if i == b.data.high:
        const rem = N mod 64
        when rem != 0:
          const mask = (1'u64 shl rem) - 1'u64
          w = w and mask
      if w != 0:
        let bit = countTrailingZeros(w)
        let idx = (i shl 6) + bit
        if idx < N:
          return idx
        return -1
    return -1

# =============================================================================
# Bitwise Operators for BitSet[N]
# =============================================================================

func `and`*[N: static int](a, b: BitSet[N]): BitSet[N] {.inline, raises: [].} =
  for i in 0 ..< a.data.len:
    result.data[i] = a.data[i] and b.data[i]

func `or`*[N: static int](a, b: BitSet[N]): BitSet[N] {.inline, raises: [].} =
  for i in 0 ..< a.data.len:
    result.data[i] = a.data[i] or b.data[i]

func `xor`*[N: static int](a, b: BitSet[N]): BitSet[N] {.inline, raises: [].} =
  for i in 0 ..< a.data.len:
    result.data[i] = a.data[i] xor b.data[i]

func `not`*[N: static int](a: BitSet[N]): BitSet[N] {.inline, raises: [].} =
  for i in 0 ..< a.data.len:
    result.data[i] = not a.data[i]
  result.maskExcessBits()
